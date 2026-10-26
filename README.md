# MeshChat

Serverless, login-free P2P chat for iOS and macOS. No server, no account —
devices discover and message each other directly over Wi-Fi and Bluetooth
using Apple's MultipeerConnectivity, relaying through each other
automatically so a group's reach extends beyond any single device's range.
Messages are end-to-end encrypted. When the internet is available, devices
can also chat directly over WebRTC (still no server, nothing stored), with
the nearby mesh as the automatic fallback.

![Build MeshChat](https://github.com/parth0072/p2pchat/actions/workflows/build.yml/badge.svg)

## Install (macOS)

Prebuilt, unsigned macOS builds publish automatically from every push to `main`:

```
curl -fsSL https://raw.githubusercontent.com/parth0072/p2pchat/main/install.sh | bash
```

Downloads the latest build, strips the Gatekeeper quarantine flag (it's unsigned, so this is required), and installs it to `~/Applications`.

Already have a build artifact downloaded from a specific [Actions run](https://github.com/parth0072/p2pchat/actions) instead? Put `run-macos.sh` next to the zip and run it there.

## Build from source (iOS or macOS)

1. Open `MeshChat.xcodeproj` in Xcode (it fetches the WebRTC Swift package on first open, so the first build needs internet and takes a while).
2. Set your own Team under Signing & Capabilities (only required to run on a physical device).
3. Pick a run destination and hit Run.

Two devices just need to be within Wi-Fi/Bluetooth range of each other — not on the same network, no prior pairing required. To chat over the internet instead, tap the globe button for an invite/reply code exchange, or meet once nearby and the devices link up automatically. The iOS Simulator can't do peer discovery, so at least one side needs real hardware.

## Project layout

- `MeshChat/` — app source. See [`MeshChat/README.md`](MeshChat/README.md) for the full architecture, a file-by-file breakdown, and the roadmap.
- `MeshChat.xcodeproj` — the Xcode project.
- `install.sh` / `run-macos.sh` — install/launch scripts for prebuilt macOS releases.
- `.github/workflows/build.yml` — CI: builds on every push to `main`, publishes a rolling "latest" release.

## Documentation

[`MeshChat/README.md`](MeshChat/README.md) covers how discovery, trust, multi-hop relay, and end-to-end encryption actually work, what each source file does, known simplifications, and what's planned next (internet chat with the mesh as a local fallback, Android support).
