import AppKit
import Combine
import os
import SwiftUI

/// The floating mini player: a small turntable (or just the record) with the
/// current cover, drawn by the same renderer, plus transport controls on hover.
///
/// - Drag anywhere to move it; click the record to play/pause.
/// - Drag the bottom-right corner, or pinch, to resize.
/// - Right-click for options.
@MainActor
final class MiniPlayerController: NSObject {
    /// Content geometry, mirroring `MINI_BOUNDS` in Renderer/js/scenes/mini.js
    /// (metres, seen from above, including room for the drop shadow).
    private struct Layout {
        let width: Double
        let height: Double
        let recordCenterX: Double // from the left edge
        let recordRadius: Double

        static func of(_ style: MiniStyle) -> Layout {
            switch style {
            case .turntable:
                // 46 × 40 cm deck + 2.5 cm margin; platter 4 cm left of centre.
                return Layout(width: 0.51, height: 0.45, recordCenterX: 0.255 - 0.04, recordRadius: 0.15)
            case .record:
                let side = 2 * 0.15 * 1.08
                return Layout(width: side, height: side, recordCenterX: side / 2, recordRadius: 0.15)
            }
        }

        var aspect: CGFloat { CGFloat(width / height) }
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Vinyl", category: "MiniPlayer")
    private var panel: MiniPanel?
    private var host: RendererHost?
    private var controls: MiniControlsHostingView<MiniControlsView>?
    private let hover = MiniHoverState()
    private let payload: () -> [String: Any]
    private let prefs = Preferences.shared
    private var systemPaused = false

    var onOpenSettings: (() -> Void)?

    init(payload: @escaping () -> [String: Any]) {
        self.payload = payload
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var hosts: [RendererHost] { host.map { [$0] } ?? [] }

    func update(visible: Bool) {
        if visible {
            show()
            applyPreferences()
        } else if let panel {
            endResize()
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
        interaction.onClick = {
            Self.log.notice("mini player record clicked")
            NowPlayingService.shared.send(.playPause)
        }
        interaction.onMoved = { [weak self] origin in self?.prefs.miniOrigin = origin }
        interaction.menuProvider = { [weak self] in self?.contextMenu() }
        interaction.onResize = { [weak self] height, anchor in self?.resize(toHeight: height, anchor: anchor) }
        interaction.onResizeEnded = { [weak self] in self?.commitResize() }
        interaction.aspect = { [weak self] in self?.layout.aspect ?? 1 }
        container.addSubview(interaction)

        let controls = MiniControlsHostingView(rootView: MiniControlsView(hover: hover))
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

        // Resize around the centre when the size or style changes elsewhere
        // (live drag/pinch resizes are already in place).
        let size = contentSize()
        if !isResizing, abs(panel.frame.width - size.width) > 0.5 || abs(panel.frame.height - size.height) > 0.5 {
            let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            let frame = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                               width: size.width, height: size.height)
            panel.setFrame(frame, display: true, animate: false)
            prefs.miniOrigin = frame.origin
            clampToScreen()
        }
        layoutControls()
    }

    private var layout: Layout { Layout.of(prefs.miniStyle) }

    private func contentSize(height: Double? = nil) -> NSSize {
        let h = (height ?? prefs.miniHeight).rounded()
        return NSSize(width: (h * layout.aspect).rounded(), height: h)
    }

    // MARK: Resizing

    private var isResizing: Bool { resizeAnchor != nil }
    /// The screen point that stays put during the current resize gesture,
    /// taken from the frame when the gesture started so rounding can't drift.
    private var resizeAnchor: NSPoint?
    /// Commits a resize whose end event never arrived (a pinch that finished
    /// with the pointer outside the shrunken player, say).
    private var resizeWatchdog: DispatchWorkItem?

    /// Live resize from the corner grip or a pinch. `anchor` is the point of
    /// the window (0…1 in each axis, from the bottom-left) that stays put.
    private func resize(toHeight height: Double, anchor: CGPoint) {
        guard let panel else { return }
        let old = panel.frame
        let fixed = resizeAnchor ?? NSPoint(x: old.minX + old.width * anchor.x, y: old.minY + old.height * anchor.y)
        resizeAnchor = fixed
        let range = Preferences.miniHeightRange
        let size = contentSize(height: min(max(height, range.lowerBound), range.upperBound))
        let frame = NSRect(x: (fixed.x - size.width * anchor.x).rounded(),
                           y: (fixed.y - size.height * anchor.y).rounded(),
                           width: size.width, height: size.height)
        if frame != old {
            panel.setFrame(frame, display: true, animate: false)
            layoutControls()
        }
        resizeWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in self?.commitResize() }
        resizeWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: watchdog)
    }

    private func commitResize() {
        guard isResizing else { return }
        endResize()
        guard let panel else { return }
        prefs.miniHeight = Double(panel.frame.height)
        prefs.miniOrigin = panel.frame.origin
        clampToScreen()
    }

    private func endResize() {
        resizeAnchor = nil
        resizeWatchdog?.cancel()
        resizeWatchdog = nil
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
        let size = panel.frame.size
        hover.compact = size.height < 230
        let fitting = controls.fittingSize
        let l = layout
        let centerX = size.width * (l.recordCenterX / l.width)
        let centerY = size.height * (0.5 - 0.55 * l.recordRadius / l.height)
        controls.frame = NSRect(
            x: (centerX - fitting.width / 2).rounded(),
            y: (centerY - fitting.height / 2).rounded(),
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

        for style in MiniStyle.allCases {
            menu.addItem(ActionItem(style.title, checked: prefs.miniStyle == style) { [prefs] in prefs.miniStyle = style })
        }
        menu.addItem(ActionItem("Picture Disc", checked: prefs.miniLabelStyle == .picture) { [prefs] in
            prefs.miniLabelStyle = prefs.miniLabelStyle == .picture ? .label : .picture
        })
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for size in MiniSize.allCases {
            let current = abs(prefs.miniHeight - size.height) < 1
            sizeMenu.addItem(ActionItem(size.title, checked: current) { [prefs] in prefs.miniHeight = size.height })
        }
        sizeMenu.addItem(.separator())
        let tip = NSMenuItem(title: "Drag the corner or pinch to resize", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        sizeMenu.addItem(tip)
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

/// Transparent layer over the player: hover tracking, 1:1 dragging that keeps
/// the grab offset, click-to-play, corner-grip and pinch resizing, and the
/// right-click menu.
final class MiniInteractionView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onMoved: ((NSPoint) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    /// New height plus the window point (0…1 from the bottom-left) to keep fixed.
    var onResize: ((Double, CGPoint) -> Void)?
    var onResizeEnded: (() -> Void)?
    var aspect: (() -> CGFloat)?

    private var grabOffset: NSPoint?
    private var dragged = false
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var resizeStart: (mouse: NSPoint, height: CGFloat)?
    private var pinch: (height: CGFloat, scale: CGFloat)?
    static let gripSize: CGFloat = 22

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        onHoverChanged?(false)
        if resizeStart == nil { NSCursor.arrow.set() }
    }

    override func mouseMoved(with event: NSEvent) {
        guard resizeStart == nil else { return }
        if inGrip(convert(event.locationInWindow, from: nil)) {
            Self.resizeCursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func inGrip(_ point: NSPoint) -> Bool {
        point.x >= bounds.maxX - Self.gripSize && point.y <= bounds.minY + Self.gripSize
    }

    private static var resizeCursor: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .bottomRight, directions: .all)
        }
        return NSCursor.crosshair
    }

    /// A small grip in the bottom-right corner while the pointer is over the player.
    override func draw(_ dirtyRect: NSRect) {
        guard hovering || resizeStart != nil else { return }
        let inset: CGFloat = 5
        let corner = NSPoint(x: bounds.maxX - inset, y: bounds.minY + inset)
        let backing = NSBezierPath(roundedRect: NSRect(x: corner.x - 16, y: corner.y, width: 16, height: 16),
                                   xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.35).setFill()
        backing.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        // Two diagonal strokes tucked into the corner.
        for length: CGFloat in [5, 9] {
            let line = NSBezierPath()
            line.lineWidth = 1.4
            line.lineCapStyle = .round
            line.move(to: NSPoint(x: corner.x - 4, y: corner.y + 4 + length))
            line.line(to: NSPoint(x: corner.x - 4 - length, y: corner.y + 4))
            line.stroke()
        }
    }

    override func magnify(with event: NSEvent) {
        guard let window else { return }
        if event.phase == .began || pinch == nil { pinch = (window.frame.height, 1) }
        guard var gesture = pinch else { return }
        // Accumulate the whole gesture so slow pinches and rounding add up,
        // and stop at the size limits so pinching back responds at once.
        let range = Preferences.miniHeightRange
        gesture.scale = min(max(gesture.scale * (1 + event.magnification), CGFloat(range.lowerBound) / gesture.height),
                            CGFloat(range.upperBound) / gesture.height)
        pinch = gesture
        onResize?(Double(gesture.height * gesture.scale), CGPoint(x: 0.5, y: 0.5))
        if event.phase == .ended || event.phase == .cancelled {
            pinch = nil
            onResizeEnded?()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        if inGrip(convert(event.locationInWindow, from: nil)) {
            resizeStart = (mouse, window.frame.height)
            return
        }
        grabOffset = NSPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = resizeStart {
            // Corner drag keeps the top-left corner fixed; follow whichever
            // axis the pointer moved further along, with the aspect locked.
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - start.mouse.x
            let dy = start.mouse.y - mouse.y
            let ratio = aspect?() ?? 1
            let grow = abs(dx / ratio) > abs(dy) ? dx / ratio : dy
            onResize?(Double(start.height + grow), CGPoint(x: 0, y: 1))
            return
        }
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
        if resizeStart != nil {
            resizeStart = nil
            onResizeEnded?()
            needsDisplay = true
            // The player may have shrunk out from under the pointer.
            if !inGrip(convert(event.locationInWindow, from: nil)) { NSCursor.arrow.set() }
            return
        }
        defer { grabOffset = nil }
        if dragged {
            if let window { onMoved?(window.frame.origin) }
        } else if event.clickCount <= 1 {
            // (Synthetic clicks from accessibility tools can report 0.)
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// Lets the first click on a control work even though the panel isn't key.
class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The hover controls: clicks in the capsule's shadow padding, or on the
/// resize grip underneath, fall through to the player.
final class MiniControlsHostingView<Content: View>: FirstMouseHostingView<Content> {
    /// Matches the `.padding(12)` around MiniControlsView's capsule.
    private let shadowInset: CGFloat = 12

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let container = superview {
            let grip = MiniInteractionView.gripSize
            if point.x >= container.bounds.maxX - grip && point.y <= container.bounds.minY + grip { return nil }
        }
        let local = convert(point, from: superview)
        guard bounds.insetBy(dx: shadowInset, dy: shadowInset).contains(local) else { return nil }
        return super.hitTest(point)
    }
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
