import AppKit
import WebKit
import os

/// A transparent web view running the bundled three.js renderer
/// (`Renderer/index.html`). Native code drives it with `window.vinyl.update`.
@MainActor
final class RendererHost: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: RendererWebView
    /// Called once the first frames are on screen (used to fade windows in).
    var onReady: (() -> Void)?

    /// Paused hosts stop rendering entirely (occluded windows, sleeping displays).
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            evaluate(["paused": isPaused])
        }
    }

    private var greeted = false
    private var latest: [String: Any] = [:]
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Vinyl", category: "Renderer")

    init(initial payload: [String: Any]) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(RendererSchemeHandler.shared, forURLScheme: RendererSchemeHandler.scheme)
        config.suppressesIncrementalRendering = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        let proxy = WeakScriptMessageHandler()
        config.userContentController.add(proxy, name: "vinyl")
        webView = RendererWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), configuration: config)
        super.init()
        proxy.target = self
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        #if DEBUG
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        #endif
        latest = payload
        load()
    }

    /// Sends the full state; the renderer ignores anything unchanged.
    func send(_ payload: [String: Any]) {
        latest = payload
        guard greeted else { return }
        evaluate(payload)
    }

    private func load() {
        greeted = false
        var components = URLComponents()
        components.scheme = RendererSchemeHandler.scheme
        components.host = "app"
        components.path = "/index.html"
        // Initial options ride along in the URL so the very first frame is right.
        let keys = ["scene", "framing", "labelStyle", "fps", "quality"]
        var items = keys.compactMap { key in (latest[key]).map { URLQueryItem(name: key == "labelStyle" ? "label" : key, value: "\($0)") } }
        for key in ["background", "tonearm", "idleSpin", "motion"] {
            if let flag = latest[key] as? Bool { items.append(URLQueryItem(name: key, value: flag ? "1" : "0")) }
        }
        components.queryItems = items
        if let url = components.url {
            webView.load(URLRequest(url: url))
        }
    }

    private func evaluate(_ payload: [String: Any]) {
        var payload = payload
        payload["paused"] = isPaused
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript("window.vinyl && window.vinyl.update(\(json));") { [log] _, error in
            if let error { log.debug("update failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "hello":
            greeted = true
            evaluate(latest)
        case "ready":
            onReady?()
        case "error":
            log.error("renderer: \(String(describing: body["message"] ?? ""), privacy: .public)")
        default:
            break
        }
    }

    // MARK: WKNavigationDelegate

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("renderer process terminated; reloading")
        load()
    }
}

/// Never takes mouse or keyboard input: clicks fall through to whatever is
/// behind it (the desktop, or the mini player's own controls).
final class RendererWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

/// Breaks the WKUserContentController → handler retain cycle.
@MainActor
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Serves `vinyl://app/…` from the bundled `Renderer` folder and
/// `vinyl://app/artwork/…` from the artwork cache.
final class RendererSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "vinyl"
    static let shared = RendererSchemeHandler()

    private let root: URL = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
        .appendingPathComponent("Renderer", isDirectory: true)

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path
        let base: URL
        let relative: String
        if path.hasPrefix("/artwork/") {
            base = ArtworkStore.shared.directory
            relative = String(path.dropFirst("/artwork/".count))
        } else {
            base = root
            relative = String(path.drop { $0 == "/" })
        }
        let file = base.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(base.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: file)
        else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            task.didReceive(response)
            task.didFinish()
            return
        }
        let headers = [
            "Content-Type": Self.mimeType(for: file.pathExtension),
            "Content-Length": "\(data.count)",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json"
        case "css": return "text/css"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
}
