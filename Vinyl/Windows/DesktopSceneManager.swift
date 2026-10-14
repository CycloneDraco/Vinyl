import AppKit
import Combine

/// Owns one borderless window per display, pinned to the desktop layer:
/// above the wallpaper, below desktop icons and every app window.
@MainActor
final class DesktopSceneManager {
    private var windows: [CGDirectDisplayID: DesktopWindow] = [:]
    private var scene: VinylScene?
    private var target: DisplayTarget = .main
    private var cancellables = Set<AnyCancellable>()
    private let payload: (VinylScene) -> [String: Any]

    /// `payload` builds the renderer state for a scene.
    init(payload: @escaping (VinylScene) -> [String: Any]) {
        self.payload = payload
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layoutWindows() }
            .store(in: &cancellables)
    }

    func update(scene: VinylScene?, target: DisplayTarget) {
        let changed = scene != self.scene || target != self.target
        self.scene = scene
        self.target = target
        if changed { layoutWindows() }
    }

    func broadcast() {
        guard let scene else { return }
        let state = payload(scene)
        windows.values.forEach { $0.host.send(state) }
    }

    var hosts: [RendererHost] { windows.values.compactMap(\.host) }

    func setSystemPaused(_ paused: Bool) {
        windows.values.forEach { $0.systemPaused = paused }
    }

    private func layoutWindows() {
        guard let scene else {
            windows.values.forEach { $0.close() }
            windows.removeAll()
            return
        }
        let screens: [NSScreen]
        switch target {
        case .main: screens = Array(NSScreen.screens.prefix(1)) // the menu-bar display
        case .all: screens = NSScreen.screens
        }
        var wanted: [CGDirectDisplayID: NSScreen] = [:]
        for screen in screens {
            if let id = screen.displayID { wanted[id] = screen }
        }
        for (id, window) in windows where wanted[id] == nil {
            window.close()
            windows[id] = nil
        }
        let state = payload(scene)
        for (id, screen) in wanted {
            if let window = windows[id] {
                window.setFrame(screen.frame, display: true)
                window.host.send(state)
            } else {
                let window = DesktopWindow(screen: screen, payload: state)
                windows[id] = window
                window.orderFrontRegardless()
            }
        }
    }
}

final class DesktopWindow: NSWindow {
    private(set) var host: RendererHost!
    var systemPaused = false { didSet { updatePaused() } }
    private var occlusion: AnyCancellable?

    // A convenience init keeps NSWindow's designated initializers inherited.
    convenience init(screen: NSScreen, payload: [String: Any]) {
        self.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        host = RendererHost(initial: payload)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        alphaValue = 0
        contentView = host.webView
        setFrame(screen.frame, display: false)
        host.onReady = { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.8
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self?.animator().alphaValue = 1
            }
        }
        // Stop drawing when every pixel is covered (full-screen apps, piles of
        // windows); the renderer resumes the moment any part is visible again.
        occlusion = NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification, object: self)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePaused() }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func updatePaused() {
        host.isPaused = systemPaused || !occlusionState.contains(.visible)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
