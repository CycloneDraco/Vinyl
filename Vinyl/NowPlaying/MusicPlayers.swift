import AppKit

enum PlayerCommand {
    case playPause, next, previous
}

/// One music app Vinyl can follow. Playback changes arrive as distributed
/// notifications (no permission needed); AppleScript is only used to read
/// the state at launch, keep the position in sync, fetch Apple Music artwork
/// and send transport commands.
protocol MusicPlayer: AnyObject {
    var source: PlayerSource { get }
    func snapshot(from userInfo: [AnyHashable: Any]) -> PlayerSnapshot
    func fetchSnapshot() async throws -> PlayerSnapshot?
    func fetchPosition() async throws -> TimeInterval?
    func send(_ command: PlayerCommand) async throws
    func artworkData() async -> Data?
}

extension MusicPlayer {
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleIdentifier).isEmpty
    }

    /// Shared AppleScript snapshot reader. Both apps answer the same shape:
    /// {state, id, name, artist, album, duration, position, album artist}
    func readSnapshot(script: String, durationInMilliseconds: Bool) async throws -> PlayerSnapshot? {
        guard isRunning else { return nil }
        let list = try await AppleScriptRunner.shared.run(script)
        let state = PlaybackState(playerString: list.item(1)?.stringValue)
        guard state != .stopped, list.numberOfItems >= 7 else { return .stopped }
        var duration = list.item(6)?.numberValue
        if durationInMilliseconds, let d = duration { duration = d / 1000 }
        let track = Track(
            id: list.item(2)?.stringValue ?? UUID().uuidString,
            title: list.item(3)?.stringValue ?? "",
            artist: list.item(4)?.stringValue ?? "",
            album: list.item(5)?.stringValue ?? "",
            albumArtist: list.item(8)?.stringValue,
            duration: duration,
            source: source
        )
        return PlayerSnapshot(track: track, state: state, position: list.item(7)?.numberValue ?? 0, positionDate: Date())
    }
}

final class SpotifyPlayer: MusicPlayer {
    let source = PlayerSource.spotify

    func snapshot(from info: [AnyHashable: Any]) -> PlayerSnapshot {
        let state = PlaybackState(playerString: info["Player State"] as? String)
        guard state != .stopped, let id = info["Track ID"] as? String else { return .stopped }
        let durationMs = (info["Duration"] as? NSNumber)?.doubleValue
        let track = Track(
            id: id,
            title: info["Name"] as? String ?? "",
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? "",
            albumArtist: info["Album Artist"] as? String,
            duration: durationMs.map { $0 / 1000 },
            source: source
        )
        let position = (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0
        return PlayerSnapshot(track: track, state: state, position: position, positionDate: Date())
    }

    func fetchSnapshot() async throws -> PlayerSnapshot? {
        try await readSnapshot(script: """
        if application id "com.spotify.client" is running then
            tell application id "com.spotify.client"
                set s to player state as string
                if s is "stopped" then return {"stopped"}
                set t to current track
                return {s, id of t, name of t, artist of t, album of t, duration of t, player position, album artist of t}
            end tell
        end if
        return {"stopped"}
        """, durationInMilliseconds: true)
    }

    func fetchPosition() async throws -> TimeInterval? {
        guard isRunning else { return nil }
        return try await AppleScriptRunner.shared.run(
            "tell application id \"com.spotify.client\" to return player position"
        ).numberValue
    }

    func send(_ command: PlayerCommand) async throws {
        guard isRunning else { return }
        let verb: String
        switch command {
        case .playPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        _ = try await AppleScriptRunner.shared.run("tell application id \"com.spotify.client\" to \(verb)")
    }

    /// Spotify artwork comes from the public oEmbed endpoint instead.
    func artworkData() async -> Data? { nil }
}

final class AppleMusicPlayer: MusicPlayer {
    let source = PlayerSource.appleMusic

    func snapshot(from info: [AnyHashable: Any]) -> PlayerSnapshot {
        let state = PlaybackState(playerString: info["Player State"] as? String)
        guard state != .stopped else { return .stopped }
        let id: String
        if let pid = info["PersistentID"] as? NSNumber {
            id = String(format: "%016llX", pid.int64Value)
        } else {
            id = [info["Name"], info["Artist"], info["Album"]].compactMap { $0 as? String }.joined(separator: "|")
        }
        let totalMs = (info["Total Time"] as? NSNumber)?.doubleValue
        let track = Track(
            id: id,
            title: info["Name"] as? String ?? "",
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? "",
            albumArtist: info["Album Artist"] as? String,
            duration: totalMs.map { $0 / 1000 },
            source: source
        )
        // Music doesn't include the position; the service asks for it when it can.
        return PlayerSnapshot(track: track, state: state, position: 0, positionDate: Date())
    }

    func fetchSnapshot() async throws -> PlayerSnapshot? {
        try await readSnapshot(script: """
        if application id "com.apple.Music" is running then
            tell application id "com.apple.Music"
                set s to player state as string
                if s is "stopped" then return {"stopped"}
                set t to current track
                return {s, persistent ID of t, name of t, artist of t, album of t, duration of t, player position, album artist of t}
            end tell
        end if
        return {"stopped"}
        """, durationInMilliseconds: false)
    }

    func fetchPosition() async throws -> TimeInterval? {
        guard isRunning else { return nil }
        return try await AppleScriptRunner.shared.run(
            "tell application id \"com.apple.Music\" to return player position"
        ).numberValue
    }

    func send(_ command: PlayerCommand) async throws {
        guard isRunning else { return }
        let verb: String
        switch command {
        case .playPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        _ = try await AppleScriptRunner.shared.run("tell application id \"com.apple.Music\" to \(verb)")
    }

    /// The exact artwork embedded in the playing track: no guessing from a
    /// search, so compilations and remixes always get the right cover.
    func artworkData() async -> Data? {
        guard isRunning else { return nil }
        let script = """
        tell application id "com.apple.Music"
            try
                return raw data of artwork 1 of current track
            on error
                return ""
            end try
        end tell
        """
        guard let result = try? await AppleScriptRunner.shared.run(script) else { return nil }
        let data = result.data
        return data.count > 64 ? data : nil
    }
}
