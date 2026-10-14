<p align="center">
  <img src="docs/images/icon.png" width="128" alt="Vinyl app icon">
</p>

<h1 align="center">Vinyl</h1>

<p align="center">
  A spinning turntable for your Mac desktop that plays along with Spotify and Apple Music.<br>
  Free and open source.
</p>

![Listening Room](docs/images/listening-room.jpg)

Vinyl puts a turntable right on your desktop, behind your windows and on top of
your wallpaper. Play something in Spotify or Apple Music and the record spins,
the album goes up on the stand, the tonearm tracks through the song, and the
last few albums you played pile up beside the deck. No account, no login, no
API key.

## Four ways to listen

| | |
| --- | --- |
| **Listening Room**: golden afternoon sun through a window, with shadows from a plant moving gently across the wall. | ![Listening Room](docs/images/listening-room.jpg) |
| **After Hours**: the same desk late at night, lit by a glass lamp and a warm glow behind the print. | ![After Hours](docs/images/after-hours.jpg) |
| **Turntable**: the classic top-down view of the deck and its sleeve on a sunny desk, striped by window blinds. | ![Turntable](docs/images/turntable.jpg) |
| **Mini Player**: just the record, floating above your windows. It works like a widget: drag it anywhere, click the record to play or pause, and hover for controls. | ![Mini Player](docs/images/mini-player.jpg) |

Turn off the room background and the turntable, sleeves and lamp sit straight
on your own wallpaper, with real shadows:

![Transparent mode](docs/images/transparent.jpg)

## Features

- **Live album art**: covers show up on the record label, the stand and the sleeve, and change smoothly when the album changes. The previous cover stays up while the next one loads.
- **Spotify and Apple Music**: the active player is detected automatically. You can also make Vinyl follow just one of them.
- **A tonearm that follows the song**: it cues onto the record when you press play, moves inward as the track goes on, and lifts when you pause.
- **Recently played**: up to five of your last albums stacked beside the turntable. The stack is remembered between launches.
- **Wide, Mid and Close framing** for every desktop scene.
- **Transparent mode**: hide the room and keep only the objects on your wallpaper.
- **Mini player options**: plain label or full picture disc, tonearm on or off, three sizes, keep on top, and show on every Space.
- **Multiple displays**: show Vinyl on your main display or on all of them.
- **Lives in the menu bar**: close the window and Vinyl keeps running. It can also open at login.
- **Easy on the battery**: drawing stops completely when Vinyl is covered or the display sleeps, and it drops to 30 fps on battery. Reduce Motion is respected.
- **Works on its own**: with nothing playing, it spins built-in records.

## Install

1. Download `Vinyl.dmg` from the [latest release](https://github.com/CycloneDraco/Vinyl/releases). Or open a recent run of the [Build workflow](https://github.com/CycloneDraco/Vinyl/actions/workflows/build.yml) and download the **Vinyl** artifact.
2. Drag **Vinyl** into **Applications**.
3. Open it. Community builds aren't notarized by Apple, so the first time, **right-click Vinyl → Open → Open**. If macOS still says the app is damaged or can't be opened, run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Vinyl.app
   ```

Requires macOS 14 Sonoma or later. Works on both Apple silicon and Intel.

## Spotify & Apple Music

Vinyl works the moment you press play. Spotify and Music announce every track
change on your Mac, and Vinyl simply listens. There's no login, nothing is sent
to Spotify or Apple, and no developer account is needed.

Spotify covers come from Spotify's public embed service. For Apple Music, Vinyl
uses the exact artwork stored with the playing track. If that isn't available,
it falls back to the iTunes catalogue, and only accepts a result whose album
and artist both match.

**Connecting (optional).** In **Settings › Music**, click **Connect** next to
Spotify or Apple Music. macOS asks once whether Vinyl may control that app.
Allowing it lets Vinyl:

- show what's already playing when Vinyl starts,
- keep the tonearm exactly in time,
- use Apple Music's embedded artwork, and
- make the play, pause and skip buttons work in the menu bar and mini player.

You can change this at any time in **System Settings › Privacy & Security › Automation**.

## Using Vinyl

- **Menu bar icon**: what's playing, transport controls, scene picker, framing and quick toggles.
- **Settings window**: everything else. Opening Vinyl from Finder or Spotlight also brings it up.
- **Mini player**: drag it anywhere. Click the record to play or pause, hover to see the controls, and right-click for options.

## Build from source

You need Xcode 16 or later on macOS 14 or later.

```sh
git clone https://github.com/CycloneDraco/Vinyl.git
cd Vinyl
open Vinyl.xcodeproj   # then press ⌘R
```

Or from the terminal:

```sh
xcodebuild -project Vinyl.xcodeproj -scheme Vinyl -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- build
open build/Build/Products/Release/Vinyl.app
```

The project signs ad hoc ("Sign to Run Locally"), so no Apple Developer
account is needed. macOS ties the Automation permission to the signature. If
you rebuild often, choose your own team under *Signing & Capabilities* so you
aren't asked again after each build.

## How it works

```
Vinyl/                      Swift app (SwiftUI + AppKit)
  App/                      entry point, AppModel (glues everything together)
  NowPlaying/               Spotify & Music integration, artwork, recent albums
  Rendering/RendererHost    transparent WKWebView + vinyl:// scheme + JS bridge
  Windows/                  desktop-level scene windows, floating mini player
  Views/                    menu bar panel, settings window, controls
  Settings/Preferences      user settings
Renderer/                   the scenes: three.js, runs inside the app's web view
  js/scenes/                room.js (Listening Room, After Hours), topdown.js, mini.js
  js/models/                turntable (platter, record, tonearm), desk props
  js/textures.js            procedural grooves, gobos, built-in covers
```

- **Desktop scenes** are borderless windows at the desktop level, one per display: above the wallpaper, below desktop icons and every app. They ignore the mouse, appear on every Space, and pause when fully covered.
- **The mini player** is a non-activating floating panel. It uses the same renderer, with SwiftUI controls on top.
- **The renderer** is plain ES modules plus three.js, loaded from the app bundle through a custom `vinyl://` URL scheme. Native code sends it state with `window.vinyl.update({...})`, and it replies with `hello`, `ready` and `error` messages.

## Working on the renderer

The scenes are plain HTML and JavaScript, so you can work on them in any
browser with live reload and no Xcode:

```sh
npm install
npm run serve
# open http://localhost:8080/?demo&scene=listening-room
```

Demo mode plays the built-in records. Keys: **space** play/pause · **n** next ·
**1–4** scenes · **f** framing · **b** background · **l** label/picture disc ·
**a** tonearm · **s** stop.

`npm run snapshots` renders every scene to `snapshots/` with headless Chromium.
CI runs this on every push, so pull requests come with previews.

Ideas welcome: new rooms, a cassette deck, more turntable models…

## Privacy

Vinyl doesn't collect, store or send any personal data. It reads playback
notifications locally on your Mac. For artwork, it only contacts Spotify's
public embed service, Spotify's image CDN and Apple's iTunes Search API. Covers
are cached in `~/Library/Caches/io.github.cyclonedraco.vinyl/Artwork`.

## Credits

- Inspired by [Vinyl for Mac](https://vinylformac.com) by Shiv Shanmugam. This
  is an independent, open-source project. It isn't affiliated with that app,
  Spotify or Apple, and it shares none of their code or artwork.
- [three.js](https://threejs.org) (MIT), CC0 textures from [Poly Haven](https://polyhaven.com),
  and public-domain prints from [The Met Open Access](https://www.metmuseum.org/about-the-met/policies-and-documents/open-access).
  See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

[MIT](LICENSE)
