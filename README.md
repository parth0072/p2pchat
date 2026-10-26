# MeshChat

Serverless, login-free P2P chat for iOS and macOS. No server, no account —
devices discover and message each other directly over Wi-Fi and Bluetooth
using Apple's MultipeerConnectivity, relaying through each other
automatically so a group's reach extends beyond any single device's range.
Messages are end-to-end encrypted. When the internet is available, devices
can also chat directly over WebRTC (still no server, nothing stored), with
the nearby mesh as the automatic fallback.

![Build MeshChat](https://github.com/parth0072/p2pchat/actions/workflows/build.yml/badge.svg)

## Download & run (macOS)

GitHub Actions builds the Mac app whenever a version tag (like `v1.0.0`) is pushed and publishes it as a GitHub Release; the newest one is the [**latest release**](https://github.com/parth0072/p2pchat/releases/latest). Requires **macOS 14 or newer**; you need two devices running MeshChat to chat.

**Easiest — one command in Terminal:**

```
curl -fsSL https://raw.githubusercontent.com/parth0072/p2pchat/main/install.sh | bash
```

It downloads the latest build, installs it to `~/Applications/MeshChat.app`, and launches it. Run the same command again any time to update.

**Manual download:**

1. Download [`MeshChat-macOS.zip`](https://github.com/parth0072/p2pchat/releases/latest/download/MeshChat-macOS.zip) and unzip it.
2. In Terminal run `xattr -cr ~/Downloads/MeshChat.app` (adjust the path), then open the app. Or open it once, then go to System Settings > Privacy & Security > **Open Anyway**.

The app isn't notarized — that needs a paid Apple Developer account — so macOS shows an "unidentified developer" warning for browser-downloaded copies. The steps above are the workaround; the `curl` command avoids the warning entirely.

On first launch, allow **Local Network**, **Bluetooth** and **Notifications** when asked (and **Camera** if you want to scan QR codes). Without them, nearby discovery can't work.

Built a zip yourself from a specific [Actions run](https://github.com/parth0072/p2pchat/actions) instead? Put `run-macos.sh` next to it and run it there.

For iPhone/iPad, build from source in Xcode (below) — App Store/TestFlight distribution needs a paid account.

## Build from source (iOS or macOS)

1. Open `MeshChat.xcodeproj` in Xcode (it fetches the WebRTC Swift package on first open, so the first build needs internet and takes a while).
2. Set your own Team under Signing & Capabilities (only required to run on a physical device).
3. Pick a run destination and hit Run.

Two devices just need to be within Wi-Fi/Bluetooth range of each other — not on the same network, no prior pairing required. To chat over the internet instead, tap the globe button for an invite/reply code exchange, or meet once nearby and the devices link up automatically. The iOS Simulator can't do peer discovery, so at least one side needs real hardware.

## Project layout

- `MeshChat/` — app source. See [`MeshChat/README.md`](MeshChat/README.md) for the full architecture, a file-by-file breakdown, and the roadmap.
- `MeshChat.xcodeproj` — the Xcode project.
- `install.sh` / `run-macos.sh` — install/launch scripts for prebuilt macOS releases.
- `.github/workflows/build.yml` — CI: builds only when a `v*` tag is pushed (or run by hand), and publishes a versioned GitHub Release.
## License

Proprietary — all rights reserved; see [LICENSE](LICENSE). You may download and run the released builds for personal use and read the source, but may not copy, modify, redistribute, or reuse it. The app bundles Google's WebRTC library (via [`stasel/WebRTC`](https://github.com/stasel/WebRTC)), which stays under its own BSD-style license.

## Documentation

[`MeshChat/README.md`](MeshChat/README.md) covers how discovery, trust, multi-hop relay, and end-to-end encryption actually work, what each source file does, known simplifications, and what's planned next (internet chat with the mesh as a local fallback, Android support).
