# Mesh Chat — MultipeerConnectivity P2P Chat

Serverless, login-free chat over Wi-Fi/AWDL + Bluetooth using
MultipeerConnectivity. Every device advertises and browses simultaneously
(mesh, not hub-and-spoke), with optional host/relay mode for groups larger
than full-mesh range.

## Opening the project

`MeshChat.xcodeproj` (one level up, in the `wchat` folder) is a real, ready-to-open Xcode project — double-click it, or `open MeshChat.xcodeproj` from Terminal. It defines a single multiplatform target ("Multiplatform App" style: one target, `SUPPORTED_PLATFORMS = iphoneos iphonesimulator macosx`) with:

- Deployment targets: iOS 17.0 / macOS 14.0
- All six `.swift` files in the Sources build phase
- `MeshChat/Info.plist` wired in directly (`NSLocalNetworkUsageDescription`, `NSBonjourServices`, `NSBluetoothAlwaysUsageDescription`, photo library usage strings)
- `MeshChat/MeshChat.entitlements` applied only on macOS (`CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`) — App Sandbox + network client/server + Bluetooth + user-selected file read/write
- Automatic code signing (`CODE_SIGN_STYLE = Automatic`)

Before running:

1. Select the MeshChat target → Signing & Capabilities → set your Team (required to run on a physical device; Simulator/local Mac runs work without one).
2. Change `PRODUCT_BUNDLE_IDENTIFIER` (currently `com.example.meshchat`) to something under your own team, either in that same tab or by editing the two `PRODUCT_BUNDLE_IDENTIFIER` entries in `project.pbxproj`.
3. Pick a run destination — an iOS device/Simulator or "My Mac" — from the scheme selector next to the Run button.
4. Build and run on two *physical* devices (or a Mac + iPhone/iPad) on the same Wi-Fi network or within Bluetooth range — the iOS Simulator can't do MultipeerConnectivity peer discovery, so at least one side needs real hardware.

`Info-additions.plist` and `macOS.entitlements` (in this folder) are the original drafts these were derived from — no longer needed since their contents are now the actual `Info.plist`/`MeshChat.entitlements` wired into the project; kept only for reference.

## Files

| File | Purpose |
|---|---|
| `Models.swift` | Codable message/peer/group/transfer models, wire-format envelope |
| `MeshManager.swift` | MCSession/advertiser/browser wrapper — discovery, trust, send/receive, relay forwarding, reconnection |
| `Persistence.swift` | SwiftData schema (`PersistedMessage`, `PersistedGroup`) + `MessageStore` |
| `PeerListView.swift` | Discovery screen, trust prompt, group switcher |
| `ChatView.swift` | Message bubbles, attachments, transfer progress, composer |
| `ChatApp.swift` | App entry point, adaptive root (`NavigationSplitView` on macOS, `NavigationStack` on iOS) |
| `Info.plist` | The target's actual Info.plist (Bonjour/local network/Bluetooth/photo usage keys) |
| `MeshChat.entitlements` | Sandbox entitlements applied to the macOS build |

## How the pieces fit together

- **Discovery**: `MeshManager` runs both an `MCNearbyServiceAdvertiser` and `MCNearbyServiceBrowser` per peer. `discoveryInfo["groupName"]` filters browse results so unrelated chat groups using the same `serviceType` don't cross-connect.
- **Trust**: `TrustStore` persists trusted peer IDs (derived from `MCPeerID.displayName`) in `UserDefaults`. Trusted peers auto-invite/auto-accept; unknown peers trigger `pendingTrustRequest`, surfaced as a sheet with a "trust this device" toggle.
- **Reconnection**: an 8s timer re-invites any known/trusted peer sitting at `.notConnected` that's still in `discoveredPeers`. Messages are deduplicated by `UUID` on receipt, so a re-invite never doubles up history.
- **Messaging**: text/control messages are wrapped in a `MeshEnvelope` (adds hop count + origin for relay mode) and sent via `session.send(_:toPeers:with:)`, `.reliable` for chat/control, `.unreliable` for typing indicators.
- **Files/video**: `session.sendResource(at:withName:toPeer:withCompletionHandler:)` handles chunking/resumability; `Progress` is observed via KVO and surfaced in the transfer bar. Received resources move into `Documents/Received/`.
- **Multi-hop relay**: every peer forwards any envelope not addressed to it one hop closer to its target (hop-limited dynamically to the known mesh size), letting devices that aren't directly linked still exchange messages. There's no designated relay host — all peers behave the same way.
- **Persistence**: `MessageStore` (SwiftData) saves every appended message keyed by `groupID`; `MeshManager.loadPersistedHistory(from:)` hydrates history on launch and on group switch, deduped by message `id`.

## Known simplifications (flagged, not hidden)

- Trust identity is `MCPeerID.displayName`-based since there's no auth layer — spoofing a display name is possible on a local network. Acceptable for the "no login" requirement, but worth knowing.
- The pending-invitation handler map lives in a small `MainActor`-isolated file-private store (`pendingInvitationHandlersStorage`) rather than as a stored property, to keep the non-Sendable `MCSession` completion closure out of the `@Published`/Combine graph. Functionally equivalent to an instance dictionary.
- Relay forwarding uses a hop-count limit rather than a full routing table — sufficient for the 15–20 peer target in the spec, not a general mesh router.
