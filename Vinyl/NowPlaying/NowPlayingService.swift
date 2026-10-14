import AppKit
import Combine
import os

/// Follows Spotify and Apple Music and publishes what's playing.
///
/// Track changes come from the players' distributed notifications, which need
/// no login and no permission. With Automation permission (asked once) Vinyl
/// can also read the state at launch, keep the tonearm in sync, show Apple
/// Music's embedded artwork and drive play/pause/skip.
@MainActor
final class NowPlayingService: ObservableObject {
    static let shared = NowPlayingService()

    /// What the followed player is doing.
    @Published private(set) var now: PlayerSnapshot = .stopped
    @Published private(set) var activeSource: PlayerSource?
    /// Cached artwork file (see `ArtworkStore`) for the album on the turntable.
    @Published private(set) var artworkFile: String?
    /// True while artwork for a new album is being fetched.
    @Published private(set) var artworkPending = false
    /// Recently played albums, newest first (excludes the current one).
    @Published private(set) var recent: [RecentAlbum] = []
    @Published private(set) var permissions: [PlayerSource: AutomationStatus] = [:]

    private let players: [PlayerSource: MusicPlayer] = [
        .spotify: SpotifyPlayer(),
        .appleMusic: AppleMusicPlayer(),
    ]
    private var snapshots: [PlayerSource: PlayerSnapshot] = [:]
    private var startedPlayingAt: [PlayerSource: Date] = [:]
    private var onTurntable: RecentAlbum?
    private var artworkTask: Task<Void, Never>?
    private var syncTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Vinyl", category: "NowPlaying")
    private let recentDefaultsKey = "recentAlbums"
    private static let maxRecent = 5

    private init() {}

    func isInstalled(_ source: PlayerSource) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleIdentifier) != nil
    }

    func isRunning(_ source: PlayerSource) -> Bool {
        players[source]?.isRunning ?? false
    }

    var hasRunningPlayer: Bool { PlayerSource.allCases.contains { isRunning($0) } }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        loadRecent()

        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(spotifyChanged(_:)),
                           name: PlayerSource.spotify.notificationName, object: nil,
                           suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(musicChanged(_:)),
                           name: PlayerSource.appleMusic.notificationName, object: nil,
                           suspensionBehavior: .deliverImmediately)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let source = Self.source(of: note) else { return }
                self?.update(source, .stopped)
                self?.permissions[source] = .notRunning
            }
            .store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard Self.source(of: note) != nil else { return }
                // Give the app a moment to register for Apple Events.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refreshPermissions() }
            }
            .store(in: &cancellables)

        Preferences.shared.$source
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)

        // Re-sync the position now and then so the tonearm stays honest.
        syncTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncPosition() }
        }
        syncTimer?.tolerance = 3

        Task { await probeRunningPlayers() }
    }

    // MARK: Commands

    func send(_ command: PlayerCommand) {
        let source = activeSource ?? PlayerSource.allCases.first { isRunning($0) }
        guard let source, let player = players[source] else { return }
        // Respond instantly: flip the state now, the player's notification confirms it.
        if command == .playPause, var snap = snapshots[source], snap.track != nil {
            snap.position = snap.position(at: Date())
            snap.positionDate = Date()
            snap.state = snap.state == .playing ? .paused : .playing
            update(source, snap)
        }
        Task {
            do {
                try await player.send(command)
                if permissions[source] != .granted { permissions[source] = .granted }
            } catch let error as AppleScriptRunner.ScriptError {
                log.error("\(source.displayName) command failed: \(error.description, privacy: .public)")
                if error.isPermissionDenied { permissions[source] = .denied }
                // Undo the optimistic flip.
                if let snap = try? await player.fetchSnapshot() { update(source, snap) }
            } catch {
                log.error("command failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Shows the macOS consent prompt for controlling `source`. The app has to
    /// be running for macOS to ask, so it's launched in the background first.
    func requestAccess(to source: PlayerSource) async {
        if !isRunning(source), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleIdentifier) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        let status = await AppleScriptRunner.shared.automationStatus(for: source.bundleIdentifier, ask: true)
        permissions[source] = status
        if status == .granted, let snap = try? await players[source]?.fetchSnapshot() {
            update(source, snap)
        }
    }

    func refreshPermissions() {
        Task {
            for source in PlayerSource.allCases {
                permissions[source] = await AppleScriptRunner.shared.automationStatus(for: source.bundleIdentifier, ask: false)
            }
        }
    }

    // MARK: Notifications

    @objc private func spotifyChanged(_ note: Notification) {
        handle(note, from: .spotify)
    }

    @objc private func musicChanged(_ note: Notification) {
        handle(note, from: .appleMusic)
    }

    private func handle(_ note: Notification, from source: PlayerSource) {
        guard let player = players[source], let info = note.userInfo else { return }
        var snap = player.snapshot(from: info)
        if source == .appleMusic, let previous = snapshots[source], previous.track?.id == snap.track?.id, snap.track != nil {
            // Music omits the position; carry our estimate across pause/resume.
            snap.position = previous.position(at: Date())
            snap.positionDate = Date()
        }
        update(source, snap)
        if source == .appleMusic, snap.state != .stopped {
            Task { await refreshPosition(of: source) }
        }
    }

    private func update(_ source: PlayerSource, _ snap: PlayerSnapshot) {
        if snap.state == .playing, snapshots[source]?.state != .playing {
            startedPlayingAt[source] = Date()
        }
        snapshots[source] = snap
        recompute()
    }

    /// Picks the player to follow: whatever started playing most recently,
    /// otherwise the last followed player that still has a (paused) track.
    private func recompute() {
        let preference = Preferences.shared.source
        let candidates: [PlayerSource]
        switch preference {
        case .automatic: candidates = PlayerSource.allCases
        case .spotify: candidates = [.spotify]
        case .appleMusic: candidates = [.appleMusic]
        }
        let playing = candidates
            .filter { snapshots[$0]?.state == .playing }
            .sorted { (startedPlayingAt[$0] ?? .distantPast) > (startedPlayingAt[$1] ?? .distantPast) }
        var chosen = playing.first
        if chosen == nil {
            if let active = activeSource, candidates.contains(active), snapshots[active]?.track != nil {
                chosen = active
            } else {
                chosen = candidates.first { snapshots[$0]?.track != nil }
            }
        }
        if activeSource != chosen { activeSource = chosen }
        let snap = chosen.flatMap { snapshots[$0] } ?? .stopped
        let albumChanged = snap.track?.albumKey != now.track?.albumKey
        if snap != now { now = snap }
        if albumChanged, snap.track?.isAdvertisement != true { albumDidChange() }
    }

    // MARK: Artwork + recent stack

    private func albumDidChange() {
        artworkTask?.cancel()
        guard let track = now.track else {
            // Player stopped or quit: the record goes back on the stack.
            moveToTurntable(nil)
            artworkFile = nil
            artworkPending = false
            return
        }
        artworkPending = true
        let player = players[track.source]
        let embedded: (() async -> Data?)?
        if track.source == .appleMusic, permissions[.appleMusic] == .granted {
            embedded = { await player?.artworkData() }
        } else {
            embedded = nil
        }
        artworkTask = Task { [weak self] in
            let file = await ArtworkStore.shared.artwork(for: track, embedded: embedded)
            guard let self, !Task.isCancelled, self.now.track?.albumKey == track.albumKey else { return }
            self.artworkFile = file
            self.artworkPending = false
            let album = RecentAlbum(
                key: track.albumKey,
                title: track.album.isEmpty ? track.title : track.album,
                artist: track.albumArtist?.isEmpty == false ? track.albumArtist! : track.artist,
                artworkFile: file ?? ""
            )
            self.moveToTurntable(album)
        }
    }

    /// Puts `album` on the turntable and slides the previous one onto the stack.
    private func moveToTurntable(_ album: RecentAlbum?) {
        var list = recent
        if let previous = onTurntable, previous.key != album?.key, !previous.artworkFile.isEmpty {
            list.removeAll { $0.key == previous.key }
            list.insert(previous, at: 0)
        }
        if let album { list.removeAll { $0.key == album.key } }
        onTurntable = album
        list = Array(list.prefix(Self.maxRecent))
        if list != recent {
            recent = list
            saveRecent()
        }
    }

    private func loadRecent() {
        guard let data = UserDefaults.standard.data(forKey: recentDefaultsKey),
              let list = try? JSONDecoder().decode([RecentAlbum].self, from: data)
        else { return }
        let fm = FileManager.default
        recent = list.filter { fm.fileExists(atPath: ArtworkStore.shared.url(forFile: $0.artworkFile).path) }
    }

    private func saveRecent() {
        if let data = try? JSONEncoder().encode(recent) {
            UserDefaults.standard.set(data, forKey: recentDefaultsKey)
        }
    }

    // MARK: Position sync

    private func syncPosition() {
        guard let source = activeSource, now.state == .playing else { return }
        Task { await refreshPosition(of: source) }
    }

    private func refreshPosition(of source: PlayerSource) async {
        guard permissions[source] == .granted, let player = players[source],
              let position = try? await player.fetchPosition(),
              var snap = snapshots[source], snap.track != nil
        else { return }
        snap.position = position
        snap.positionDate = Date()
        snapshots[source] = snap
        recompute()
    }

    /// At launch nothing has been announced yet, so ask running players
    /// directly — but only if permission was already granted (never prompt here).
    private func probeRunningPlayers() async {
        for source in PlayerSource.allCases {
            let status = await AppleScriptRunner.shared.automationStatus(for: source.bundleIdentifier, ask: false)
            permissions[source] = status
            guard status == .granted, let player = players[source],
                  let snap = try? await player.fetchSnapshot()
            else { continue }
            update(source, snap)
        }
    }

    private static func source(of note: Notification) -> PlayerSource? {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return nil }
        return PlayerSource.allCases.first { $0.bundleIdentifier == app.bundleIdentifier }
    }
}
