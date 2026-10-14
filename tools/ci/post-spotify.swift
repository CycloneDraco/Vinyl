// Posts the same distributed notification Spotify sends on every playback
// change, so the app can be exercised without Spotify installed.
//
//   swift tools/ci/post-spotify.swift <track-id> <title> <artist> <album> [Playing|Paused|Stopped] [position]
import Foundation

let args = CommandLine.arguments
guard args.count >= 5 else {
    print("usage: post-spotify.swift <track-id> <title> <artist> <album> [state] [position]")
    exit(1)
}
let info: [String: Any] = [
    "Player State": args.count > 5 ? args[5] : "Playing",
    "Track ID": "spotify:track:\(args[1])",
    "Name": args[2],
    "Artist": args[3],
    "Album Artist": args[3],
    "Album": args[4],
    "Duration": 215_000,
    "Playback Position": Double(args.count > 6 ? args[6] : "40") ?? 40,
]
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.spotify.client.PlaybackStateChanged"),
    object: "com.spotify.client",
    userInfo: info,
    deliverImmediately: true
)
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
print("posted \(args[2]) — \(info["Player State"]!)")
