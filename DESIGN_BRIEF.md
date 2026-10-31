# MeshChat — Design Brief

Hand-off document for the design module. It describes what the product is, every screen that exists today, the states each one has, and what we want designed. Everything under "Current" is built and working; "Design asks" is the work.

---

## 1. Product in one paragraph

MeshChat is a **private, serverless chat app for iPhone, iPad and Mac**. There are **no accounts, no phone numbers, no logins, and no company server**. People chat in two ways, and the app chooses automatically:

1. **Internet first** — when both people are online, messages go directly device-to-device (peer-to-peer).
2. **Nearby fallback** — when there's no internet, devices find each other over Wi-Fi and Bluetooth and chat directly, even with no router. Devices also **relay for each other**, so a message can hop across several nearby phones to reach someone out of direct range.

Messages are **end-to-end encrypted**, stored only on the device (encrypted), and **auto-delete after 24 hours**.

**One-line promise:** *Chat with people near you — or across the internet — with nothing in the middle that can read, store or shut it down.*

## 2. Who it's for and tone

- People who want chat that works **with no signal, in crowds, travelling, at events, in outages** — and people who simply want **no account and no tracking**.
- Tone: **calm, trustworthy, quietly technical**. Privacy is the product, so it should feel secure without feeling scary or nerdy. Plain words ("Nearby", "Internet", "Connected"), not jargon ("WebRTC", "TURN", "ICE", "AWDL").
- Principles: **privacy-first and user-controlled** — nothing leaves the device unless the user turns it on; the user can see and control how they're connected.

## 3. Platforms and technical constraints for design

| | |
|---|---|
| Platforms | iPhone, iPad (iOS/iPadOS 17+), Mac (macOS 14+) — one SwiftUI codebase |
| Native feel | Use **system components and SF Symbols**; follow Apple HIG. Not a custom-chrome app. |
| Layout | **iPhone:** navigation stack (list → chat). **Mac / iPad:** sidebar (peer list) + detail (chat), `NavigationSplitView`. |
| Tap targets | iOS ≥ 44pt (composer buttons currently 44pt with 30pt icons). Mac pointer-sized (28pt / 20pt icons). |
| Appearance | Light and dark. (The network map is always dark by design.) |
| Accent colour | Currently the **system accent** (default blue). No brand palette yet — see asks. |
| Accessibility | Must support Dynamic Type, VoiceOver, Reduce Motion, sufficient contrast. Not audited yet. |
| Name limits | Display names ≤ 60 characters; may be any language/emoji. |
| Real-time | State changes constantly (peers appear/disappear, links drop). Designs must show **in-between states**, not just happy paths. |

## 4. Vocabulary (keep consistent)

| Term | Meaning to the user |
|---|---|
| **Nearby device** | Another phone/Mac running MeshChat within Wi-Fi/Bluetooth range |
| **Connected / Connecting… / Not connected** | Link state with a device |
| **Direct** | Straight connection to that person |
| **Via relay / Multi-hop** | Message passes through other people's devices to reach them |
| **Internet · peer-to-peer** | Direct over the internet, no server |
| **Trusted** | You allowed this device to auto-connect in future |
| **Group** | A named room; only devices in the same group name see each other |
| **Invite code / Reply code** | The QR/text used to start an internet chat |

## 5. Screen inventory (current)

### 5.1 Peer list (home)
- Title = current **group name**. Toolbar: **Profile**, **Discovery** (network map), **Groups**, **Internet** (globe).
- Top row: wifi icon + "**N connected**" (green when ≥ 1, grey otherwise).
- **Permission banner** (when Local Network is denied): orange warning, explanation, "Open Settings" button (iOS).
- Section "**Nearby Devices**": one row per device:
  - status dot (green connected / yellow connecting / grey not connected)
  - name
  - status text + tags: "· via relay", "· internet", "· untrusted" (orange)
  - trailing: **Connect** button (not connected) or spinner (connecting)
  - context menu / swipe: **Forget Device** (destructive) for trusted devices
- Empty state: "Searching for nearby peers…"
- **Mac detail pane when nothing selected**, three variants: *No Peers Yet* (waiting on group "X", make sure Wi-Fi/Bluetooth are on) · *Check Nearby Peers* (devices found, none connected) · *Select a Peer*.

### 5.2 Chat (1:1 thread per device)
- Navigation title = person's name.
- **Message bubbles:** mine = right, accent colour; theirs = left, grey, with sender name above; time under each.
- **Stickers:** large (72pt) emoji, no bubble, Telegram-style.
- **Photo / video:** 160×120 thumbnail; video has a play icon overlay; tap opens full preview.
- **File:** doc icon, filename, size, save/open button.
- **Typing indicator:** "Name is typing…" row.
- **Transfer bar** (above composer, only while sending/receiving): filename, progress bar, percentage, **cancel (✕)**.
- **Route line** above the composer, small caption with icon + lock:
  - "Direct connection" (grey) · "Multi-hop · 3 hops via mesh" (orange) · "Internet · peer-to-peer" · "Connecting…" · "Route unknown"
  - The 🔒 means end-to-end encrypted on every route.
- **Notices:** when the person is reachable only via relay or internet, files/photos are unavailable — attach (+) is dimmed and a one-line explanation shows.
- **Composer:** **+** (attachment panel) · multiline text field · **send** arrow. Send disabled when empty.
- **Attachment panel** (popover/sheet): *Photo or Video*, *Document*, *Sticker* — coloured circular icons (blue / indigo / orange).
- **Sticker picker:** sheet with a 40-emoji grid.
- **Large-file alert:** "Large file — estimated transfer time N s over Wi-Fi/Bluetooth" → Send Anyway / Cancel.
- Mac extra: drag-and-drop files onto the chat.

### 5.3 Trust prompt (sheet, when someone connects to you)
Person-with-question-mark icon · "**Name wants to connect**" · toggle "Trust this device" · caption "Trusted devices auto-connect next time without asking." · buttons **Decline** (destructive) / **Trust & Connect** (becomes **Connect Once** when the toggle is off).

### 5.4 Groups (sheet)
List "Switch group" + "New group" with a name field and **Create & Join**.

### 5.5 Profile (sheet; also shown once on first launch)
96pt circular avatar · Name field · Choose / Remove photo · caption: *name is shown to nearby people; your photo stays on this device only*. Cancel / Save.

### 5.6 Discovery — live network map
Always dark: deep-navy gradient with a faint grid. **You** at the centre; every known device is a circular node (initials, radial-gradient fill, glowing ring). Lines = connections (**your direct links** thicker, coral; **multi-hop links** thinner, blue). Soft translucent **range halos** around nodes. Legend + a plain-language **coverage line** ("Coverage: 2 hops deep · roughly ~20 m of combined reach…"). Layout is force-directed and gently stable between refreshes.
- Palette used here: coral `#FF6B61` (you / direct), blue `#598CFF` (mesh links), navy background `#0F1424 → #0A0D1A`.

### 5.7 Internet Chat (sheet) — the most complex flow
Used to start a chat over the internet without a server.
1. **Status banner at top** (spinner / info / error) + live progress line ("Checking network routes…", "No direct route between these two networks…").
2. Connection indicator: "Internet connection available / No internet connection" + one-paragraph explanation.
3. **Step 1 · Invite someone** — "Create invite" → shows a **QR code** + the code as text + **Copy** / **Share**.
4. **Advanced: relay server (optional)** — collapsed disclosure; URL, username, password, Save.
5. **Step 2 · Scan or paste a code you received** — text field, live validity hint (green "Invite from X — press Connect" / orange "Not a valid MeshChat code"), **Scan QR** and **Paste** buttons, big **Connect** button; after connecting to an invite, a **reply code** (QR + text) appears to show back to the inviter.
6. **Connected over the internet** list (green check + name).
- **QR scanner:** full-screen camera, "Point the camera at the QR code" capsule, Close; camera-denied state.
- Flow in words: *A creates invite → B scans/pastes it → B shows reply → A scans/pastes reply → connected.* It's two rounds and easy to get lost — this is the screen that most needs design help.

### 5.8 Notifications
- **In-app banner** (message arrives while the app is open but that chat isn't): rounded toast at the top, message icon in an accent circle, **sender** (bold), group (small), 2-line preview; material background, soft shadow, tap to dismiss, auto-dismisses.
- **System notifications** (app in background; also on Mac while the app is open).

### 5.9 App icon
Exists in all required sizes (iOS, Mac, watch placeholders). Open to redesign — see asks.

## 6. Key user flows to design end-to-end

1. **First launch:** permissions (Local Network, Bluetooth, Notifications, Camera) → profile (name/photo) → empty peer list → first connection.
2. **Nearby connect:** see device → Connect → (other device sees trust prompt) → connected → chat.
3. **Chat when connection quality changes:** direct ↔ multi-hop ↔ internet ↔ dropped → reconnecting.
4. **Internet chat setup** (flow 5.7), including failure ("no direct route", expired invite, wrong code).
5. **Send a file/photo** with progress and cancel; large-file warning.
6. **Switch / create group.**
7. **Forget a device;** decline a device.
8. **Permission denied** recoveries (Local Network, Camera).

## 7. Current gaps — please design

These don't exist in the app yet and are open for proposals:

1. **Onboarding** that explains, in three short beats, *nearby vs internet*, *no account*, and *messages disappear after 24 hours*.
2. **Message delivery state** — there is none today (no sent / delivered / failed indicator).
3. **Expiry indicator** — how to show messages auto-delete after 24 h (global note? per-message countdown?).
4. **A clearer connection model** — one glanceable indicator of *how* each conversation is connected (nearby / relayed / internet) that replaces jargon.
5. **Internet-link setup** redesigned so the two-round code swap feels guided (stepper, clear "who shows what to whom", success moment).
6. **Privacy / security surface** — a place that shows encryption, what's stored, and the user's controls (internet on/off, relay choice, memory-only mode, forget everything). Roadmap includes **Nostr relays** and **ephemeral (memory-only) mode**, so leave room.
7. **Brand identity** — name treatment, logo/icon, accent colour, type usage (keep SF as the base), illustration/empty-state style.
8. **iPad layout** (currently just the Mac split view).
9. **Empty, error and loading states** for every screen above.
10. **Motion** — connecting, peer appearing, message arriving, link dropping (respect Reduce Motion).
11. **Group experience** — groups are currently just a name; consider how people understand/join/leave them.

## 8. Deliverables requested

- Hi-fi screens for **iPhone, iPad and Mac**, **light and dark**.
- A small **component/style library**: colours (incl. semantic status colours: connected / connecting / offline / warning / error / encrypted), type scale, spacing, corner radii, buttons, rows, bubbles, sheets, banners, empty states, SF Symbol set.
- **Flow diagrams** for the flows in section 6.
- **App icon** and brand marks.
- **Accessibility notes** (Dynamic Type behaviour, VoiceOver labels for status dots / route line / QR, contrast).
- Hand-off specs that map to **SwiftUI** (system fonts, semantic colours, SF Symbols preferred over custom assets).

## 9. Out of scope (for now)

Voice/video calls, public channels/discovery, accounts, read receipts, reactions, Android (planned later), web.

## 10. Reference: facts the design must respect

- No server, no account → **no avatars or profile data are sent to others**; people see only your display name. Your photo is local-only.
- Files and photos work **only with nearby devices** (not over relay or internet yet).
- Messages are end-to-end encrypted on every route; the 🔒 in the chat is a real guarantee, not decoration.
- History is local, encrypted, and **deleted after 24 hours**.
- Devices must be in the same **group name** to see each other nearby.
- iOS needs **Local Network** and **Bluetooth** permissions or nearby discovery cannot work at all — the denied state is a first-class screen, not an edge case.
