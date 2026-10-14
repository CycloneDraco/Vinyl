import AppKit
import Combine
import SwiftUI

/// The floating mini player: a spinning record (and tonearm) with the current
/// cover, drawn by the same renderer, plus transport controls on hover.
///
/// - Drag anywhere to move it; click the record to play/pause.
/// - Right-click for options.
@MainActor
final class MiniPlayerController: NSObject {
    /// Content aspect ratio (width / height); mirrors `MINI_BOUNDS*` in mini.js.
    static func aspect(showsTonearm: Bool) -> CGFloat {
        let m = 0.15 * 1.08
        return showsTonearm ? (m + 0.255) / (2 * m) : 1
    }

    private var panel: MiniPanel?
    private var host: RendererHost?
    private var controls: NSHostingView<MiniControlsView>?
    private let hover = MiniHoverState()
    private let payload: () -> [String: Any]
    private let prefs = Preferences.shared
    private var systemPaused = false

    var onOpenSettings: (() -> Void)?

    init(payload: @escaping () -> [String: Any]) {
        self.payload = payload
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func update(visible: Bool) {
        if visible {
            show()
            applyPreferences()
        } else if let panel {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: panel)
            panel.orderOut(nil)
            panel.close()
            self.panel = nil
            host = nil
            controls = nil
        }
    }

    func broadcast() {
        host?.send(payload())
    }

    func setSystemPaused(_ paused: Bool) {
        systemPaused = paused
        updatePaused()
    }

    // MARK: Window

    private func show() {
        guard panel == nil else { return }
        let size = contentSize()
        let origin = prefs.miniOrigin ?? defaultOrigin(for: size)
        let panel = MiniPanel(contentRect: NSRect(origin: origin, size: size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.configure()

        let host = RendererHost(initial: payload())
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.autoresizesSubviews = true

        host.webView.frame = container.bounds
        host.webView.autoresizingMask = [.width, .height]
        container.addSubview(host.webView)

        let interaction = MiniInteractionView(frame: container.bounds)
        interaction.autoresizingMask = [.width, .height]
        interaction.onHoverChanged = { [weak self] inside in self?.setHovering(inside) }
        interaction.onClick = { NowPlayingService.shared.send(.playPause) }
        interaction.onMoved = { [weak self] origin in self?.prefs.miniOrigin = origin }
        interaction.menuProvider = { [weak self] in self?.contextMenu() }
        container.addSubview(interaction)

        let controls = FirstMouseHostingView(rootView: MiniControlsView(hover: hover))
        controls.alphaValue = 0
        container.addSubview(controls)

        panel.contentView = container
        panel.alphaValue = 0
        host.onReady = { [weak panel] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                panel?.animator().alphaValue = 1
            }
        }
        self.panel = panel
        self.host = host
        self.controls = controls
        layoutControls()
        panel.orderFrontRegardless()
        clampToScreen()

        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: panel)
    }

    private func applyPreferences() {
        guard let panel else { return }
        panel.level = prefs.miniFloats ? .floating : .normal
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        if prefs.miniOnAllSpaces { behavior.insert(.canJoinAllSpaces) }
        panel.collectionBehavior = behavior

        // Resize around the centre when size or tonearm changes.
        let size = contentSize()
        if panel.frame.size != size {
            let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            let frame = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                               width: size.width, height: size.height)
            panel.setFrame(frame, display: true, animate: false)
            prefs.miniOrigin = frame.origin
            clampToScreen()
        }
        layoutControls()
    }

    private func contentSize() -> NSSize {
        let height = prefs.miniSize.height
        return NSSize(width: (height * Self.aspect(showsTonearm: prefs.miniShowsTonearm)).rounded(), height: height)
    }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        let visible = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - size.width - 32, y: visible.minY + 32)
    }

    /// Keeps at least most of the record on some screen.
    private func clampToScreen() {
        guard let panel else { return }
        let frame = panel.frame
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        var origin = frame.origin
        origin.x = min(max(origin.x, visible.minX - frame.width * 0.3), visible.maxX - frame.width * 0.7)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - frame.height)
        if origin != frame.origin {
            panel.setFrameOrigin(origin)
            prefs.miniOrigin = origin
        }
    }

    /// Centres the control capsule over the lower part of the record.
    private func layoutControls() {
        guard let controls, let panel else { return }
        hover.compact = prefs.miniSize == .small
        let size = panel.frame.size
        let fitting = controls.fittingSize
        let recordFraction = prefs.miniShowsTonearm ? (0.162 / (0.162 + 0.255)) : 0.5
        let centerX = size.width * recordFraction
        controls.frame = NSRect(
            x: (centerX - fitting.width / 2).rounded(),
            y: (size.height * 0.2 - fitting.height / 2).rounded(),
            width: fitting.width, height: fitting.height
        )
    }

    private func setHovering(_ inside: Bool) {
        hover.isHovering = inside
        layoutControls()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = inside ? 0.18 : 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            controls?.animator().alphaValue = inside ? 1 : 0
        }
    }

    @objc private func occlusionChanged() {
        updatePaused()
    }

    private func updatePaused() {
        guard let panel, let host else { return }
        host.isPaused = systemPaused || !panel.occlusionState.contains(.visible)
    }

    // MARK: Context menu

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let np = NowPlayingService.shared
        let playing = np.now.state == .playing
        menu.addItem(ActionItem(playing ? "Pause" : "Play") { np.send(.playPause) })
        menu.addItem(ActionItem("Next Track") { np.send(.next) })
        menu.addItem(ActionItem("Previous Track") { np.send(.previous) })
        menu.addItem(.separator())

        menu.addItem(ActionItem("Picture Disc", checked: prefs.miniLabelStyle == .picture) { [prefs] in
            prefs.miniLabelStyle = prefs.miniLabelStyle == .picture ? .label : .picture
        })
        menu.addItem(ActionItem("Show Tonearm", checked: prefs.miniShowsTonearm) { [prefs] in
            prefs.miniShowsTonearm.toggle()
        })
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for size in MiniSize.allCases {
            sizeMenu.addItem(ActionItem(size.title, checked: prefs.miniSize == size) { [prefs] in prefs.miniSize = size })
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        menu.addItem(ActionItem("Keep on Top", checked: prefs.miniFloats) { [prefs] in prefs.miniFloats.toggle() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Vinyl Settings…") { [weak self] in self?.onOpenSettings?() })
        menu.addItem(ActionItem("Hide Mini Player") { [prefs] in
            if prefs.scene == .miniPlayer { prefs.enabled = false } else { prefs.miniAlongside = false }
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Vinyl") { NSApp.terminate(nil) })
        return menu
    }
}

// MARK: - Panel + views

final class MiniPanel: NSPanel {
    func configure() {
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the renderer draws a soft shadow under the record
        isMovable = false // dragging is handled by MiniInteractionView
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        titleVisibility = .hidden
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Transparent layer over the record: hover tracking, 1:1 dragging that keeps
/// the grab offset, click-to-play and the right-click menu.
final class MiniInteractionView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onMoved: ((NSPoint) -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private var grabOffset: NSPoint?
    private var dragged = false
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        grabOffset = NSPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let grabOffset else { return }
        let mouse = NSEvent.mouseLocation
        let origin = NSPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y)
        if !dragged {
            // A little hysteresis so a slightly shaky click still counts as a click.
            let start = NSPoint(x: window.frame.minX + grabOffset.x, y: window.frame.minY + grabOffset.y)
            guard hypot(mouse.x - start.x, mouse.y - start.y) > 3 else { return }
            dragged = true
        }
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        defer { grabOffset = nil }
        if dragged {
            if let window { onMoved?(window.frame.origin) }
        } else if event.clickCount == 1 {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// Lets the first click on a control work even though the panel isn't key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// NSMenuItem with a closure.
final class ActionItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, checked: Bool = false, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(ActionItem.fire), keyEquivalent: "")
        self.handler = handler
        target = self
        state = checked ? .on : .off
    }

    @objc private func fire() { handler?() }
}

@MainActor
final class MiniHoverState: ObservableObject {
    @Published var isHovering = false
    @Published var compact = false
}
