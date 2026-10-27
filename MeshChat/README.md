# Mesh Chat — Serverless P2P Chat (Internet via WebRTC, Nearby via MultipeerConnectivity)

Two transports, no server, no login, nothing stored remotely:

1. **Internet first** — when the internet is available and a WebRTC link to a peer is open, messages go directly device-to-device (see "Internet-first, mesh-fallback" below).
2. **Nearby mesh fallback** — otherwise, devices chat over Wi-Fi and Bluetooth with MultipeerConnectivity, described next.

Serverless, login-free chat between nearby devices over Wi-Fi and Bluetooth.
"Nearby" here specifically means *physically close*, not "on the same
network" — devices don't join a shared Wi-Fi router and don't pair over
Bluetooth in Settings first. MultipeerConnectivity discovers other devices
running the app over Bluetooth and negotiates its own ad hoc peer-to-peer
Wi-Fi link on the fly (Apple Wireless Direct Link, the same underlying tech
AirDrop uses), so two devices just need Wi-Fi and Bluetooth turned on and
need never have been "connected" to one another or a network beforehand.
Every device advertises and browses simultaneously (mesh, not hub-and-spoke)
— every peer relays messages it isn't the recipient of one hop closer to
their target, automatically, with no designated host — so the group's
effective reach is the union of everyone's individual range, not any one
device's.

## Opening the project

`MeshChat.xcodeproj` (one level up, in the `wchat` folder) is a real, ready-to-open Xcode project — double-click it, or `open MeshChat.xcodeproj` from Terminal. It defines a single multiplatform target ("Multiplatform App" style: one target, `SUPPORTED_PLATFORMS = iphoneos iphonesimulator macosx`) with:

- Deployment targets: iOS 17.0 / macOS 14.0
- Every `.swift` file below in the Sources build phase
- `MeshChat/Info.plist` wired in directly (`NSLocalNetworkUsageDescription`, `NSBonjourServices`, `NSBluetoothAlwaysUsageDescription`, photo library usage strings)
- `MeshChat/MeshChat.entitlements` applied only on macOS (`CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`) — App Sandbox + network client/server + Bluetooth + user-selected file read/write
- Automatic code signing (`CODE_SIGN_STYLE = Automatic`)
- One Swift package dependency, [`stasel/WebRTC`](https://github.com/stasel/WebRTC) (embedded framework) — Xcode downloads it on first open/build, so the first build needs internet access and takes longer

Before running:

1. Select the MeshChat target → Signing & Capabilities → set your Team (required to run on a physical device; Simulator/local Mac runs work without one).
2. Change `PRODUCT_BUNDLE_IDENTIFIER` (currently `com.example.meshchat`) to something under your own team, either in that same tab or by editing the two `PRODUCT_BUNDLE_IDENTIFIER` entries in `project.pbxproj`.
3. Pick a run destination — an iOS device/Simulator or "My Mac" — from the scheme selector next to the Run button.
4. Build and run on two *physical* devices (or a Mac + iPhone/iPad) within Wi-Fi/Bluetooth range of each other — they do **not** need to be on the same Wi-Fi network. The iOS Simulator can't do MultipeerConnectivity peer discovery, so at least one side needs real hardware.

`Info-additions.plist` and `macOS.entitlements` (in this folder) are the original drafts these were derived from — no longer needed since their contents are now the actual `Info.plist`/`MeshChat.entitlements` wired into the project; kept only for reference.

## Files

| File | Purpose |
|---|---|
| `ChatApp.swift` | App entry point; adaptive root (`NavigationSplitView` on macOS, `NavigationStack` on iOS); restores known groups and reopens the last-active group on launch |
| `Models.swift` | Codable message/peer/group/transfer models, wire-format envelope, discovery-info keys, log categories |
| `MeshManager.swift` | The core engine: MCSession/advertiser/browser wrapper, discovery, trust (`TrustStore`), end-to-end encryption, multi-hop relay + topology gossip, reconnect backoff, file transfer, notifications, structured logging |
| `CryptoIdentity.swift` | Curve25519 identity key (Keychain-backed) + AES-GCM per-peer encrypt/decrypt for end-to-end message encryption |
| `Persistence.swift` | SwiftData schema (`PersistedMessage`, `PersistedGroup`) + `MessageStore`; local `ProfileStore` (display name + avatar) |
| `PeerListView.swift` | Peer list with live connection state, trust prompt, group switcher |
| `ChatView.swift` | Message thread, composer, attachments (photo/video/document), stickers, cancellable transfer progress, route indicator |
| `RTCTransport.swift` | WebRTC data-channel links (offer/answer, ICE, send/receive) and the compact signal codec used for QR codes / pasted text |
| `InternetLinkView.swift` | "Internet Chat" sheet: create an invite (QR + text), paste a code, show the reply code |
| `QRScannerView.swift` | Camera QR scanner (AVFoundation) for invite/reply codes; needs camera permission (`NSCameraUsageDescription`, macOS camera entitlement) |
| `ProfileView.swift` | Edit your display name and avatar photo |
| `DiscoveryView.swift` | Live, dark "network ops" style visualization of the mesh topology graph |
| `Info.plist` | The target's actual Info.plist (Bonjour/local network/Bluetooth/photo usage keys) |
| `MeshChat.entitlements` | Sandbox entitlements applied to the macOS build |

## How the pieces fit together

- **Discovery**: `MeshManager` runs both an `MCNearbyServiceAdvertiser` and `MCNearbyServiceBrowser` per peer, over Bluetooth and ad hoc peer-to-peer Wi-Fi — no shared network or prior pairing required. `discoveryInfo["groupName"]` filters browse results so unrelated chat groups using the same `serviceType` don't cross-connect, and `discoveryInfo["publicKey"]` carries the device's encryption key (see below) the instant it's found.
- **Trust**: `TrustStore` persists trusted peer IDs (derived from `MCPeerID.displayName`) in `UserDefaults`. Trusted peers auto-invite/auto-accept; unknown peers trigger `pendingTrustRequest`, surfaced as a sheet with a "trust this device" toggle that actually controls whether the trust is persisted ("Trust & Connect" vs. one-time "Connect Once"). Trusted devices can be untrusted again from the peer list ("Forget Device").
- **Reconnection**: any known/trusted peer sitting at `.notConnected` gets re-invited automatically, backing off exponentially per peer on repeated failure (8s → 16s → 32s → 64s → capped at 120s) rather than hammering a peer that's genuinely out of range. A lexicographic tie-break (plus a small jitter on manual connects) avoids the double-invite race when both sides try to connect at once. Messages are deduplicated by `UUID` on receipt, so a re-invite never doubles up history.
- **Messaging**: text/sticker/typing messages are wrapped in a `MeshEnvelope` (adds hop count, origin, and target for relay) and sent via `session.send(_:toPeers:with:)` — `.reliable` for chat, `.unreliable` for typing indicators. Each connected peer gets its own separate 1:1 conversation thread rather than one merged group feed.
- **End-to-end encryption**: each device generates a Curve25519 key pair once (`IdentityKeyStore`, kept in the Keychain, not UserDefaults) and advertises its public key both via `discoveryInfo["publicKey"]` (for directly-discovered peers) and in every `.topology` gossip broadcast (`TopologyPeerInfo.publicKey` / `ControlMessage.senderPublicKey`), so keys propagate the same way names and routes do — a peer several hops away, never directly discovered, still gets its key learned before you need to message them. `.chatMessage` payloads are sealed with AES-GCM using an ECDH-derived per-peer shared key (`EncryptionManager`) *before* the envelope is handed off to send/relay; relay hops decide `isForMe` from envelope metadata alone and forward still-sealed envelopes without ever attempting to decrypt content not addressed to them. `.control`/topology messages stay in the clear — they have no single recipient and carry no message content, only routing/gossip metadata.
- **Internet-first, mesh-fallback (WebRTC)**: when the device has a network path (`NWPathMonitor`) and an open WebRTC data-channel link to a peer, messages go to that peer directly over the internet (peer-to-peer, DTLS on top of the same end-to-end encryption). If there's no internet, no link, or the link can't carry the message, `sendChatMessage` falls through to the nearby mesh exactly as before. There is **no signaling server**: links form either automatically — two devices on the mesh exchange the WebRTC offer/answer through the mesh itself as end-to-end-encrypted `.signaling` envelopes (the lexicographically-lower ID offers, so there's no glare) — or manually via the Internet Chat sheet (invite shown as a QR code/text, the reply pasted back). ICE gathering finishes before an offer/answer is shared, so no live signaling channel is needed. Public STUN servers (Google, Cloudflare) are used only to learn each device's public address. Nothing is stored: links and the messages they carry exist only in memory (messages still follow the normal 24h local history rule once received). Limits: only public STUN is built in, so networks that block direct peer-to-peer traffic (typical on mobile data) can't connect unless you add your own TURN relay under "Advanced" in the Internet Chat sheet (stored in the Keychain; it only forwards already-encrypted traffic); the sheet shows live connection progress and says plainly when no route exists; if a device's network changes the link drops and has to be re-established (automatically again when the devices meet on the mesh, otherwise via a new invite); files/photos still need a nearby MultipeerConnectivity session.
- **Multi-hop relay + topology gossip**: every peer forwards any envelope not addressed to it one hop closer to its target (hop-limited dynamically to the known mesh size, not a fixed cap), letting devices that aren't directly linked still exchange messages — there's no designated relay host, all peers behave the same way. Every peer also periodically (and on connect/disconnect) floods a report of its own direct connections (`broadcastTopology`); every device merges these into a full adjacency map (`topologyEdges`/`topologyNames`) used for `MeshManager.hopDistance(to:)` (the direct/multi-hop route indicator above the composer) and for `DiscoveryView`'s live topology graph. Peers known only through gossip, never discovered directly, still show up in the peer list as relay-reachable.
- **Files/photos/video**: `session.sendResource(at:withName:toPeer:withCompletionHandler:)` handles chunking/resumability; `Progress` is retained and surfaced as a cancellable transfer bar (only works for directly-connected peers, not relay-only ones). A large-file warning shows the estimated transfer time before sending. Received resources move into `Documents/Received/`.
- **Notifications**: a real system notification posts even while the app is active on macOS (normally suppressed); an in-app banner stands in for it while the relevant chat isn't already open (suppressed if you're already looking at that conversation).
- **Groups**: every group you create or join is persisted (SwiftData) and restored into the group switcher on relaunch, and the app reopens whichever group was active last time instead of always defaulting to "General."
- **Dependencies**: the only third-party dependency is Google's WebRTC build via the [`stasel/WebRTC`](https://github.com/stasel/WebRTC) Swift package (resolved automatically by Xcode/CI; used for data channels only, no audio/video).
- **Encryption at rest**: stored message text, sender names and attachment names/paths are AES-GCM encrypted (`LocalCrypto` in `Persistence.swift`) with a random per-install key in the Keychain, separate from the end-to-end identity key, so a copy of the database file is unreadable. IDs, timestamps and group names stay plain because queries and expiry need them. Received files in `Documents/Received/` are not encrypted by the app (rely on the OS / FileVault).
- **Persistence**: `MessageStore` (SwiftData) saves every appended message keyed by `groupID`; `MeshManager.loadPersistedHistory(from:)` hydrates history on launch and on group switch, deduped by message `id`. Messages older than 24h are purged automatically — this app doesn't keep chat logs indefinitely.
- **Logging**: structured `os.Logger` output (categorized discovery/connect/route/trust/error, subsystem = the app's bundle ID) so real device logs are inspectable in Console.app or Xcode's console when something needs debugging, without any in-app debug UI.

## Known simplifications (flagged, not hidden)

- Trust identity is `MCPeerID.displayName`-based since there's no auth layer — spoofing a display name is possible on a local network. Acceptable for the "no login" requirement, but worth knowing.
- The pending-invitation handler map lives in a small `MainActor`-isolated file-private store (`pendingInvitationHandlersStorage`) rather than as a stored property, to keep the non-Sendable `MCSession` completion closure out of the `@Published`/Combine graph. Functionally equivalent to an instance dictionary.
- Relay forwarding uses a hop-count limit rather than a full routing table — sufficient for the 15–20 peer target in the spec, not a general mesh router.
- Internet links use public STUN plus an optional user-supplied TURN relay (none is bundled — this project runs no servers) and share offer/answer codes manually or over the mesh — a pasted code is trusted as much as the channel you pass it over, though a code can never replace the encryption key already known for a peer.
- Encryption uses a long-lived per-install identity key, not per-session ephemeral keys — no Signal/Noise-style forward secrecy. A single compromised private key can decrypt that device's past traffic if an attacker also captured it off the wire. Chosen because multi-hop relay means a message can be in flight for seconds, and rotating keys mid-session would strand it. MultipeerConnectivity's own `encryptionPreference: .required` still protects each hop's link on top of this.

## Roadmap

- **Nostr integration (planned)**: add [Nostr](https://github.com/nostr-protocol/nostr) as an optional internet transport and signaling channel, so devices can find each other and re-establish internet links without exchanging codes by hand and without any server this project runs. Nostr is a network of independent, interchangeable relays that just store-and-forward signed events, which fits the no-central-server goal. Sketch: each device gets a Nostr identity key (kept in the Keychain, alongside the existing Curve25519 key); WebRTC offers/answers travel as short-lived, encrypted events (NIP-44 encryption; NIP-17/NIP-59 gift-wrapped direct messages so relays can't see who is talking to whom); once the WebRTC data channel opens, chat goes peer-to-peer and the relays are no longer involved. The nearby mesh stays the offline fallback, and the current invite/QR flow stays as the zero-infrastructure option. Not started yet.
- **Privacy-first and user-controlled (guiding principle for all of the above)**: nothing leaves the device unless the user turns it on. Any internet or Nostr feature is opt-in and can be switched off completely, leaving nearby-only mode. The user chooses which relays (or TURN/STUN servers) are used, can run their own, and can see exactly which are active — no default accounts, no phone number or email, no analytics or telemetry, no central directory. Metadata is kept to a minimum (ephemeral signaling events, gift-wrapped addressing), message content is always end-to-end encrypted, and stored history stays local, encrypted at rest and auto-expiring, with an optional memory-only (ephemeral) mode and per-device "forget" controls. Not started yet beyond what's already built (local-only storage, encryption in transit and at rest, per-device trust, optional relay settings).
- **Internet chat, with the mesh as fallback**: the serverless version is built (see "Internet-first, mesh-fallback (WebRTC)" above). Still open: a bundled/default TURN option (today you supply your own), re-establishing internet links without a fresh invite once devices have separated and their networks changed, and sending files/photos over the internet link.
- **Android support**: true iOS ↔ Android interop needs MultipeerConnectivity (Apple-only) replaced with a transport both platforms can speak, most likely Google's Nearby Connections API (it has both Android and iOS SDKs and isn't deprecated). The protocol built on top of it here — `MeshEnvelope`, flood relay, topology gossip, trust, and the E2E encryption scheme in `CryptoIdentity.swift` — is plain Codable/Swift logic with no MultipeerConnectivity dependency, so it should carry over largely unchanged once the transport itself is swapped. Not started yet.
