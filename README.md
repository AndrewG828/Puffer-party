# Puffer Party for iOS

A native SwiftUI client for **Krillion's Puffer Party** ([krillion.io/party](https://krillion.io/party)):
name an answer for the category and pass the puffer before it pops. Last one floating wins.

The app is a client of the **same live backend** as the website, so iPhone players sit in the same rooms as
web players. They also share public room lists, quick play and rated matchmaking, Elo, chat and moderation.
The category questions come from the server, as they do on the web, so the app always asks the same
questions as krillion.io with nothing to keep in sync.

| Piece | Web | iOS |
| --- | --- | --- |
| Guest identity | `GET/POST krillion.io/api/party/token` + Cloudflare Turnstile | same endpoint; the Turnstile widget runs in a `WKWebView` sheet |
| Rooms, quick play, rating | `party.krillion.io/rooms`, `/quick-play`, `/rating`, `/activity` | same |
| Realtime | `wss://party.krillion.io/rooms/{code}/ws` (snap / patch / ack / gone / removed) | same protocol, same patch reducer and reconnect backoff |
| Actions | `submit`, `typing`, `chat`, `settings`, `start`, `again`, `auto-join`, `leave`, `moderate`, `report`, `chat-enabled` | same |
| Round feedback | `POST krillion.io/api/feedback` | same |

## What's better than the mobile web version

Most of the work went into typing, which is where the mobile site struggles:

- **The keyboard never drops during a round.** The answer box is a `UITextField` that stays focused after Return,
  so you can keep typing through misses, rejects and passes.
- **Pre-type while someone else holds the puffer**, then fire with Return as soon as it reaches you.
  The box is focused automatically when the puffer arrives.
- **No autocorrect, auto-capitalisation, smart quotes or smart dashes.** These were silently changing answers
  (`don't` → `don’t`).
- **The layout fits above the keyboard.** The category card stays pinned at the top, the ring of seats scales
  into whatever space is left, and the dock (heart meter, answer box, fuse, SEND) sits right on the keyboard.
- **Haptics stand in for sound:** a buzz when it's your turn, rising ticks as the puffer swells, a thud on a pop,
  an error buzz on a rejected answer.
- **Native extras:** share-sheet invites, a 4-box room-code entry, pull to refresh, a "you're still seated →
  REJOIN" banner, Dynamic Type for the answer box, VoiceOver labels on every seat and control.

Everything else matches the web: the same copy ("pass the puffer · don't let it pop on you", "▼ WAKE THE PUFFER ▼",
"“x”: already said"…), rules, settings ranges, timings (1.3 s category swap, 1.5 s pop freeze, 220 ms typing
throttle), the jittered puffer-swell thresholds, tier colours, buddies and their streak unlocks, pixel art, and the
VT323 font.

## Build & run

Requirements: Xcode 15 or later (Xcode 16 recommended), iOS 17+.

1. Open `PufferParty.xcodeproj`.
2. Select the **PufferParty** target → *Signing & Capabilities* → choose your team.
3. Run on a simulator or device. `⌘U` runs the unit tests in `PufferPartyTests`.

> ⚠️ This code was written in a Linux container with no Swift compiler, so **it has not been compiled yet**.
> Expect to fix a few small compile errors the first time you build in Xcode.

The project file is generated. After adding or removing Swift files, run:

```sh
python3 scripts/generate_xcodeproj.py
```

## Server-side setup to finish

1. **Universal links.** The app claims `applinks:krillion.io` so that `krillion.io/party/ABCD` invite links open in
   the app. Serve `https://krillion.io/.well-known/apple-app-site-association` with:
   ```json
   { "applinks": { "details": [ { "appIDs": ["TEAMID.io.krillion.pufferparty"], "components": [ { "/": "/party/*" } ] } ] } }
   ```
   Until then, `pufferparty://party/ABCD` links work. To sign with a free Apple account, remove
   `CODE_SIGN_ENTITLEMENTS` from the target, because free accounts can't use Associated Domains.
2. **Turnstile.** The widget is loaded from an HTML page whose base URL is `https://krillion.io/party`, so it runs
   under the hostname the site key is registered for. If Cloudflare ever rejects in-app verification, consider an
   App Attest / DeviceCheck path on `/api/party/token` for iOS.
3. **Account sign-in** (Google, via Firebase on the web) is not in the app yet. iOS players are guests whose rating
   is kept by the `krillion-party-guest` cookie, the same way as a signed-out browser. Adding Sign in with Google
   means sending its ID token as `Authorization: Bearer …` to `/api/party/token`, as the web does.

## Not ported (yet)

- Sound effects: the web synthesises them. Haptics replace them on iOS.
- Admin/moderator console (`/api/party/admin`). Host moderation, chat reports and personal mutes are included.
- Buddy unlocks follow the web's daily-streak rule. The app has no daily game, so only the Krill is unlocked unless
  `PartyStorage.maxStreak` is set (for example from a future account sync).
- Seasonal sprite swaps, ads, the announcement modal, and preview/demo fixtures.

## Code map

```
PufferParty/
  App/PufferPartyApp.swift       entry point, navigation, deep links
  Core/                          Foundation-only logic ported from the web client
    Constants.swift              endpoints, limits, tiers, quick-play tables, name/code rules, categoryKey
    Characters.swift             buddies (ids, colours, unlock streaks)
    Models.swift                 Room, Player, events, chat, settings, rating
    RoomPatch.swift              websocket patch reducer
    Mechanics.swift              reconnect backoff, heart meter, puffer swell thresholds, typing telemetry
    Storage.swift                name/buddy/seat/seen-category persistence (same keys as the web)
    JSONValue.swift              lossless JSON for snapshots and patches
  Network/
    PartyAPI.swift               guest token + Turnstile, rooms, quick play, rating, HTTP act, feedback
    RoomConnection.swift         websocket: snapshots, patches, acks, pings, reconnects
  Game/RoomSession.swift         seat handling + game state machine (events → UI state)
  UI/                            SwiftUI screens (home, join, lobby, game, chat, settings, verification)
  Resources/                     asset catalog (art from krillion.io), VT323 font (SIL OFL)
PufferPartyTests/CoreTests.swift checks against values produced by the web client's own code
scripts/generate_xcodeproj.py    regenerates PufferParty.xcodeproj
```
