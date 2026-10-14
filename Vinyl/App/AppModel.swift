import AppKit
import Combine

/// Wires preferences, playback and system state to the on-screen renderers.
@MainActor
final class AppModel {
    static let shared = AppModel()

    private let prefs = Preferences.shared
    private let nowPlaying = NowPlayingService.shared
    private let system = SystemMonitor.shared
    private var cancellables = Set<AnyCancellable>()

    private lazy var desktop = DesktopSceneManager { [unowned self] scene in
        self.payload(scene: scene, mini: false)
    }

    private lazy var mini: MiniPlayerController = {
        let controller = MiniPlayerController { [unowned self] in
            self.payload(scene: .miniPlayer, mini: true)
        }
        controller.onOpenSettings = { SettingsWindow.shared.show() }
        return controller
    }()

    private init() {}

    func start() {
        system.start()
        nowPlaying.start()

        // Any change anywhere → one coalesced sync on the next runloop turn.
        Publishers.Merge3(prefs.objectWillChange, nowPlaying.objectWillChange, system.objectWillChange)
            .debounce(for: .milliseconds(10), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)

        sync()
        #if DEBUG
        scheduleDebugSnapshots()
        #endif
    }

    private func sync() {
        desktop.update(scene: prefs.desktopScene, target: prefs.displayTarget)
        mini.update(visible: prefs.showsMiniPlayer)

        desktop.setSystemPaused(system.systemIdle)
        mini.setSystemPaused(system.systemIdle)

        desktop.broadcast()
        mini.broadcast()

        let wantsDock = prefs.showInDock || NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    #if DEBUG
    /// `VINYL_SNAPSHOT_DIR=/path` writes a PNG of every renderer after a few
    /// seconds. Used by the UI smoke test in CI.
    private func scheduleDebugSnapshots() {
        guard let dir = ProcessInfo.processInfo.environment["VINYL_SNAPSHOT_DIR"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["VINYL_SNAPSHOT_DELAY"] ?? "") ?? 14
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (index, host) in (desktop.hosts + mini.hosts).enumerated() {
                host.webView.takeSnapshot(with: nil) { image, error in
                    guard let image, let tiff = image.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                    else {
                        NSLog("Vinyl snapshot \(index) failed: \(String(describing: error))")
                        return
                    }
                    try? png.write(to: url.appendingPathComponent("renderer-\(index).png"))
                }
            }
        }
    }
    #endif

    private var batterySaver: Bool {
        switch prefs.energy {
        case .quality: return false
        case .saver: return true
        case .automatic: return system.onBattery || system.lowPowerMode
        }
    }

    /// The complete renderer state; see `window.vinyl.update` in Renderer/js/main.js.
    func payload(scene: VinylScene, mini: Bool) -> [String: Any] {
        let saver = batterySaver
        let now = nowPlaying.now
        var state: [String: Any] = [
            "scene": scene.rawValue,
            "framing": prefs.framing.rawValue,
            "background": prefs.showBackground,
            "labelStyle": mini ? prefs.miniLabelStyle.rawValue : LabelStyle.label.rawValue,
            "tonearm": mini ? prefs.miniShowsTonearm : true,
            "idleSpin": prefs.spinWhenIdle,
            "motion": !system.reduceMotion,
            "fps": saver ? 30 : 60,
            "quality": (saver && !mini) ? "balanced" : "high",
            "playing": now.state == .playing,
            "position": now.position(at: Date()),
        ]
        if let track = now.track {
            state["track"] = [
                "id": track.id,
                "title": track.title,
                "artist": track.artist,
                "album": track.album,
                "duration": track.duration ?? 0,
                "artwork": nowPlaying.artworkFile.map { "vinyl://app/artwork/\($0)" } ?? NSNull(),
                "artworkPending": nowPlaying.artworkPending,
            ] as [String: Any]
        } else {
            state["track"] = NSNull()
        }
        state["recent"] = nowPlaying.recent.map { album -> [String: Any] in
            [
                "id": album.key,
                "title": album.title,
                "artist": album.artist,
                "artwork": "vinyl://app/artwork/\(album.artworkFile)",
            ]
        }
        return state
    }
}
