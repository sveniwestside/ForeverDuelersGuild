# ForeverDuelersGuild

ForeverDuelersGuild is an experimental, local 1v1 rating addon for **WoW: Forever**, targeting its stated compatibility with current Retail WoW APIs. Players initiate an ordinary WoW duel; both players must then explicitly agree before the addon can record a rated result.

**Local development version 0.5.7 fixes the queue's transition from native grouping to venue planning.** Native group flags can become available before the party member's identity. Missing data now waits within the existing deadlines; a verified wrong opponent, third member or raid still cancels. Exact group proof remains necessary for planning, travel and automatic cleanup. Cancellation arriving before the first group tick can no longer strand a later-verifiable queue group. Grouping and planning deadlines also apply to messages arriving between timer ticks. Rated protocol and SavedVariables schema remain version 2; the published Beta remains **0.4.5**, with no new upload or publication.

Ordinary solo WHISPER, the optional logged-addon probe from 0.5.6 and exact-pair PARTY rated transport are retained. Native identity, both explicit rated choices and result agreement remain required. The reported queue failure's asymmetric cancellation pattern is reproduced in the actual-addon harness and repaired there; paired 0.5.7 in-game queue acceptance remains pending.

**A complete solo rated duel is now live-confirmed on 0.5.6.** After disabling all addons and restarting, the user reported immediate ordinary whispers in both directions; after enabling only ForeverDuel and restarting again, ordinary whispers and Rated worked without a group. Both saved traces confirm current-request WHISPER acknowledgment after 1.1 seconds, both explicit choices, native countdown/start and complementary completed results: Tester A 1577→1554, Tester B 1423→1446. This successful run used ordinary WHISPER, not the optional logged route. The user then re-enabled all original addons, restarted both clients and confirmed immediate whispers plus two consecutive solo rated duels with opposite challengers. The earlier 0.5.6 failure had first peer HELLO receipts about 45 seconds after initial submission and no timely acknowledgment. Current recovery is established; its underlying cause and long-term reliability remain unproven, and no specific addon conflict was reproduced. The full queue remains unverified. Queue discovery, venue sharing and pre-group reservation retain their existing transport, 20-second budget and invitation order. Installation and dated evidence are recorded in [IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md).

**0.5.7 is installed locally**, with all 27 source/installed file hashes and 24 manifest modules verified and 0.5.6 backed up. Its release checks passed 23 Lua suites / **8,108 assertions** and 48 Python tests. Bounded queue transition/group/planning reasons and rated receive-entry diagnostics now survive reload with debug disabled, without recording packet payloads, queue tickets, negotiation nonces or positions. They cannot establish consent or change rating/history. Existing saved places and character data were not edited. Leave the previous group, reload both clients and repeat the full queue-to-rated flow; detailed procedure and evidence are in [MANUAL_TESTING.md](MANUAL_TESTING.md) and [IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md).

The public name was corrected to **ForeverDuelersGuild** before the first 0.4.5 publication. The installation folder remains `ForeverDuel`, with `ForeverDuel.toc`, the existing `ForeverDuelDB` SavedVariable, `/duelrating` commands, and compatible protocol identifiers. Keep that folder name when installing or upgrading so existing character data continues to load.

**Version 0.4.5 addresses reproduced gaps in repeated-duel discovery.** Only an acknowledgment of the current request binds the peer identity; pending discovery retries within the original 50-second limit. Already explicit consent can be resent when answering a discovery retry. Native acknowledgment and consent from both players remain required. Debug logging is optional.

**Testing of the current 0.4.5 build was completed by the user on 2026-10-04**, and the user approved preparation for the first Beta publication. This is a general test-completion confirmation; no new per-case results or paired logs were supplied. The earlier 0.4.4 recurrence remains historical evidence: after three successful duels, a fourth request showed the ForeverDuel dialog only on the receiver, followed by another successful duel. The failed attempt's status was unavailable, so its exact cause and any debug dependency remain unconfirmed. Incoming identity recovery from 0.4.4 remains: target the challenger if prompted while the ordinary request stays open.

Automatic discovery still uses the native channel member list and addon whispers. The user reported immediate detection after installing 0.4.3 on 2026-10-04. Install 0.4.5 on both clients; upgrading from 0.4.3 or 0.4.4 requires `/reload` on both. Dropdown filters with nine Classic classes, separate leveling/max-level ratings, the five-level eligibility limit, and level-weighted transfers remain. The earlier duel/reload flow and overview have user-confirmed live success. The addon targets Forever interface `16001`; the client inspected on 2026-10-04 is 1.60.1.70205.

The general test conclusion and historical happy-path confirmations do not certify every supported scenario. Complete counterpart logs were not provided for an independent record-by-record comparison. The [manual checklist](MANUAL_TESTING.md) retains regression procedures and separately unverified locales, cross-faction/realm combinations, and loss/error cases for broader Beta coverage.

## What is included

- An addon-owned incoming duel dialog with rated, ordinary, and decline paths.
- Addon discovery, explicit consent from each participant, shared match IDs, and pre-match rating snapshots.
- Conservative local start/result detection, peer result comparison, and duplicate-safe finalization.
- Separate leveling/max-level Elo ratings and W/L records, with a five-level rated limit and level-weighted transfers.
- A movable overview with rating-mode selectors, a progression chart for the latest 40 duels, paged history, and selected-match details.
- A same-map browser with name/class/rating/eligibility filters, sorting, an ordinary Duel button, and mode/level-aware tooltip ratings.
- Per-character SavedVariables and a retained read-only archive for validated pre-0.4.0 records.
- An original addon icon and draggable minimap shortcut with a per-character saved position.
- A local queue with automatic ruleset detection, player-selected reach and level gap, native party invitations, suitable venue selection, travel deadlines, and a separate queue panel.
- Debug output, a pure Lua test harness, and a documented two-client test procedure.

The addon itself has no backend connection, account service, combat analytics, or Glicko-2 implementation. A separate local website design and backend foundation are being developed under [web](web/README.md). The design preview uses explicitly labeled sample data; it does not change addon ratings or upload anything.

## Installation

1. Close the client or return to character selection.
2. Copy the repository's **`ForeverDuel` folder** into the target client's `Interface/AddOns` directory. The final manifest path must be `Interface/AddOns/ForeverDuel/ForeverDuel.toc`, without an extra nested repository folder. For the inspected Forever beta installation this is `_classic_beta_/Interface/AddOns/ForeverDuel/ForeverDuel.toc`. If Windows extracted the ZIP into another `ForeverDuel` folder, copy the inner folder containing the `.toc`; `AddOns/ForeverDuel/ForeverDuel/ForeverDuel.toc` will not be discovered.
3. Enable ForeverDuelersGuild in the character-selection addon list on both clients.
4. Log in and run `/duelrating`. Each rating mode starts independently at **1500**, with zero wins and losses. Upgrading preserves validated old records in **Legacy**; it does not assign unknown historical levels to either new mode.
5. Follow [MANUAL_TESTING.md](MANUAL_TESTING.md) before using it for any meaningful competition.

The release ZIP is named `ForeverDuelersGuild-0.4.5.zip` and contains one top-level `ForeverDuel` folder, with the `.toc`, Lua files, `Media` textures, and `LICENSE` inside it. Archive that folder alone; do not add the repository's root license as a separate ZIP entry.

The manifest's interface number identifies the target client, independently of API similarities with Retail. If a newly installed folder is absent from the addon list, check the exact path above and fully restart the client to force a fresh scan. An “out of date” warning on a different client build requires API verification; simply overriding that warning does not prove compatibility. No third-party runtime library is required in the addon itself.

## Using rated duels

1. Challenge the other player through WoW's normal player context-menu **Duel** action. After native acknowledgment, the challenger also sees the waiting dialog; Rated remains disabled until both addons confirm the current request.
2. The receiving client resolves the request's actual player identity. When successful and outside combat, it displays ForeverDuelersGuild's dialog while checking for the peer addon. **Continue Unrated** and **Decline** are available immediately. If only the ordinary WoW dialog appears, target the challenger while leaving that request open: identification retries every half-second when the client exposes readable popup visibility, within the original 50-second pending limit. Accepting or declining the ordinary request ends these retries.
3. Once compatible discovery and level eligibility succeed, either participant can propose rated status. The challenger sees **Propose Rated Duel**; the receiver sees **Accept Rated Duel**.
4. Each player clicks their rated button. The first click records only that player's consent. It does not accept the underlying incoming WoW request.
5. Both clients exchange acknowledgments and enter `RATED_CONFIRMED`. Only then does the receiving client attempt native duel acceptance.
6. A locally observed duel countdown supplies start evidence. After the duel, each client needs native finish evidence, an unambiguous local winner message, and a matching peer result before changing its rating.
7. `/duelrating` opens the rating/history window. `/duelrating summary` prints the compact chat summary; `/duelrating history` prints up to 20 recent records with match IDs.

After four seconds without mutual discovery, the receiver continues to offer ordinary accept/decline, with rated acceptance disabled. Discovery retries after one second and then every two seconds while checking or waiting, within the original 50-second pending limit. A valid delayed exchange can enable the rated option for that same pending request. It never grants consent. Choosing unrated, declining, cancelling, or starting the ordinary duel prevents later messages from making that duel rated.

**Rated eligibility:** both native levels and the native maximum level must be available. Both players must share the same cap and rating mode: **Leveling** below the cap, or **Max level** at the cap. The absolute level difference must be at most **5**. With a cap of 60, levels 30 and 35 can play rated; 30 and 36 cannot, and 59 versus 60 remains unrated because the modes differ. Ordinary duels remain available. The addon reads `UnitLevel` and `GetMaxPlayerLevel`; it does not guess a missing level or cap.

Each mode has its own rating and W/L record. Reaching the cap selects the max-level rating without moving the leveling rating into it. Elo uses **K=32**, with **20 effective rating points per level** when calculating the expected winner. At equal ratings and levels, a win transfers **16** points. At equal ratings with a five-level difference, the lower-level winner gains **20** points; the higher-level winner gains **12**. The loser always loses the same number. Records freeze both levels, the cap, mode, and pre-match ratings; later peer reports cannot replace those snapshots.

Selecting **Continue Unrated** (or **Accept Normal Duel** after the discovery check elapses) cancels rated negotiation and accepts the incoming ordinary duel. The challenger's **Keep Unrated** cancels rated negotiation while leaving the receiver responsible for ordinary acceptance. **Decline** or **Cancel Duel** declines/cancels the pending native request. Unrated duels never enter rated history.

## Commands

| Command | Behavior |
| --- | --- |
| `/duelrating` | Toggle the rating/history overview window. |
| `/duelrating ui` | Same overview-window toggle. |
| `/duelrating zone` | Toggle Players in zone, listing recently discovered addon users on your current map. |
| `/duelrating queue` | Toggle the separate queue window; choose search reach and a level gap from 0 to 5. Your ruleset is detected automatically. |
| `/duelrating queue join` / `leave` / `status` | Join, leave, or print queue and transport diagnostics. |
| `/duelrating queue help` | Tested-place button instructions and advanced venue commands. |
| `/duelrating summary` | Chat summary of all available rating modes, followed by five recent matches from the current level mode. |
| `/duelrating history` | Up to 20 recent rated matches for the current level mode, including match IDs. |
| `/duelrating status` | Addon version, duel transport/state, pending acknowledgment, recent packets/results, and directory status plus recent area/whisper send and receive diagnostics. |
| `/duelrating diagnose` | Print recent native-request summaries, recorded locally even with chat debug off and retained across reload. |
| `/duelrating debug` | Toggle detailed `[ForeverDuelersGuild]` event/protocol/state logs. |
| `/duelrating reset` | Explain destructive reset and open a 15-second confirmation window. |
| `/duelrating reset confirm` | Reset both rating modes and all history, including Legacy, after the preceding command; refused during a pending or active duel. |

Reset clears both rating modes and the Legacy archive, while preserving the nonce counter and settings, including debug and minimap position. Keep a backup before resetting. Chat debug is off by default; it is not required for discovery, consent, or rating. `/duelrating status` reports the outgoing argument/identity failure, current queue blocker and venue metadata source. `/duelrating diagnose` prints the latest 12 of at most 64 saved request summaries, including repeat counts and last timestamps for compacted traffic; they contain no packet payloads, queue positions, consent or result evidence and cannot resume a request.

Left-click the crossed-swords minimap icon to open or close the overview. Hold the left mouse button and drag it around the minimap to reposition it; its angle is saved per character and also survives a rating reset. The button uses the standard round minimap layout. Its tooltip shows the controls. The same icon is declared for the addon list. If a newly copied texture is missing, fully restart WoW once. The original PNG and generation prompt are in [assets/branding](assets/branding/README.md); the addon ships only the small TGA export.

The dark charcoal/gold overview has **Leveling** and **Max level** selectors, plus **Legacy** when old records were migrated. Each selector shows its own rating, W/L, win rate, best retained rating, total matches, and streak. Best rating includes the initial 1500. A progression chart shows up to the latest **40** duels in that mode, starting with the rating before the first displayed duel. History remains newest first with eight rows per page. Use **Previous**/**Next** and click a row: a gold marker identifies the selection and its details stay visible on the right. Changing the displayed mode only changes the view; rated matchmaking uses your actual native level.

Details show both players, their stored levels and class/spec when available, rating mode, local-client date, duration, stored knockout/retreat outcome, and rating changes. Your rating comes from the saved record; the opponent's post-match rating is explicitly **calculated** from the pre-match snapshots, not a verified current rating. Damage, healing, spells, and combat timelines are not recorded. Drag the window to move it; **Close**, Escape, or the command hides it. It scales down on opening to fit smaller screens and refreshes visible records after finalization/reset.

The window reads the active schema-2 records and the preserved schema-1 Legacy archive without changing ratings or consent. If displaying it fails, it closes without cancelling a duel; `/duelrating summary` remains the chat fallback. Live checks for layout, dragging, Escape, long names, and UI scaling are listed in [MANUAL_TESTING.md](MANUAL_TESTING.md).

Use **Players in zone** in the overview or `/duelrating zone` to see recently discovered ForeverDuelersGuild users with the same map ID. The addon joins the dedicated `ForeverDuel` channel to obtain native member names and GUIDs, then requests profiles by addon whisper. This supplies recipient identities without a target, group, or player nameplates. The profile contains character GUID, current mode rating, map ID, class, native level, and level cap; the native sender supplies the full name. Only a received valid profile establishes addon presence. A channel member alone never becomes a listing.

Directory requests repeat at most every 30 seconds. With the native channel window closed, the addon temporarily selects its display row, waits up to five seconds for members, and restores a readable previous selection. It defers when safe restoration is unavailable and respects user selection changes. Queries repeat no more than every 45 seconds per player; replies are limited to every five seconds per player and the whisper queue sends at most once per second. Target/focus/group/nameplate queries remain available. No ordinary chat is sent. A `YELL` capability attempt is disabled for the session after `InvalidChatType`; Forever does not support the Classic broadcast assumption used in 0.4.2. See [API evidence](docs/API_VERIFICATION.md).

Search names without case sensitivity and select options directly from the **Class**, **Rating**, **Sort**, and **Rated eligible** dropdowns. Classes are Warrior, Paladin, Hunter, Rogue, Priest, Shaman, Mage, Warlock, and Druid; Death Knight, Monk, Demon Hunter, and Evoker are omitted. Rating windows are **All / ±100 / ±200 / ±400**; sorting supports name, highest rating within a mode, or closest rating to yours. Rating windows and distance sorting compare only your own mode and level cap. **Rated eligible: Only** limits the list to the same mode/cap and at most five levels difference; it is an advisory filter, not a consent check. **Reset filters** restores the full discovered list. Rows show each player's level, rating mode, and rating.

Move close to a listed player, target them if needed, and click **Duel**. The button requires a locally resolved unit whose GUID and full name match the listing, then requests an ordinary native duel. Both players must still choose rated separately and pass fresh native level checks. The button can request an ordinary duel even when a listed player is ineligible for rated. Matching map IDs do not establish distance or the same phase. The list contains reachable addon users with recently received profiles; it is not a complete zone roster and does not require a shared guild. Directory and whisper reachability across realms/factions still need live verification.

Player tooltips show **Duel Rating** with the mode and level when the visible GUID, full name, level, and cap match a fresh cached announcement, or show your own current mode rating. A stale level announcement is omitted until discovery refreshes. Hovering never sends a request. Remote ratings are self-reports; stale entries expire after 120 seconds. Discovery keeps at most 300 remote profiles in memory, clears them on reload, and does not add them to SavedVariables or rated history. If players are missing, compare `/duelrating status` on both clients for directory loading, discovery whispers, and received profiles; a successful local send alone does not prove delivery. Targeting the other character remains a fallback for the separately confirmed whisper route.

If discovery does not complete or only one player sees the addon dialog, capture `/duelrating status` on **both** clients before starting another request or reloading. Keep the current debug setting; status works with debug off. Compare `State`, `Incoming request`, outgoing diagnostics, `Last send`, `Last receive`, and `Last`, including full surnames and timestamps. Additional debug logs can help a subsequent controlled retest. `DISCOVERY_WAIT` means the initial four-second check elapsed; ordinary actions remain available. “Registered” means only that the local prefix registered successfully. A send result or received packet alone does not prove mutual discovery or consent. See [MANUAL_TESTING.md](MANUAL_TESTING.md).

## Using the queue (local 0.5.1)

Your **Normal, PvP, RP, or Hardcore** ruleset is detected automatically from the client's game rules and displayed as read-only information; there is no ruleset question or manual override. Select **Zone**, **Continent**, or **Whole ruleset**, and the maximum level difference **0–5**. All three reach buttons are available before joining; the selected button stays clickable and is marked with `>`. Both players' limits apply. Matching requires the same faction, native ruleset, level cap and leveling/max-level pool. Rating tolerance starts at **±100**, widens to **±200 after two minutes**, and reaches **±400 after five minutes**. There is no server-wide queue position or guaranteed complete player roster.

**Save a tested place with the queue window's button.** Complete a successful ordinary native duel at a safe outdoor spot, leave the party, remain at that spot outside combat, and click **Save tested place** within five minutes. The addon fills the position, faction, the lower of the two tested character levels and zone level range automatically (native data, or bounded Classic metadata when absent) and sends the same record to that duel partner; no values form is needed. The receiving client requires its own matching native-duel evidence. The UI displays capture/sharing errors directly. A submitted send does not prove that the partner received the record.

The built-in catalog is empty; the addon ships no guessed duel coordinates. You may still join before saving a place. If a suitable opponent has been discovered but no tested place fits their scope, levels and travel limit, the queue explains that it is waiting for a meeting place and continues searching. Lower-level zones remain usable when the place's minimum player level allows both contestants.

For advanced catalog management, `/duelrating queue help` documents `queue venue add`, `import`, and `remove`. Add/import use normalized map fractions, not percentages, and both clients need identical coordinates and metadata. Only successfully tested outdoor places outside Stormwind for Alliance or Orgrimmar for Horde should be marked as a cross-continent `hub`.

Zone search is the initial option. Continent and whole-ruleset searches are selectable immediately and discover reachable addon users on a best-effort basis. One player's narrower preference constrains both. Broader reach is not a complete global roster; consult `/duelrating queue status` when no compatible enrolled player has been discovered.

Once matched, one client attempts a native party invitation; the recipient accepts WoW's ordinary invitation. A blocked attempt exposes **Invite opponent**. Both clients agree on a catalog venue chosen from fresh positions. The travel timer is **5–15 minutes**: estimated walking speed below level 40, normal **+60% mount** speed from level 40, with a buffer; cross-continent matches use a faction hub and 15 minutes. These are straight-line estimates, with no terrain routing or automatic travel. **Show waypoint** marks the destination when supported.

Both contestants must remain in the venue radius and have locally verifiable identity, proximity and phase before **Request duel** becomes available. Request the ordinary duel within **two minutes**, then explicitly accept rated on both clients in the existing dialog. A missed arrival cancels the queue match without changing rating: a confirmed arrived player returns to search with their waiting time retained; a confirmed local no-show gets a two-minute queue pause. Unknown positions, phase/loading/disconnect errors, grouping errors, and start timeout cancel without a no-show penalty. Only the unchanged queue-owned two-player party may be left automatically; changed groups require manual cleanup. Queue tickets are memory-only and are discarded on reload/logout.

## Persistence and local trust

The per-character schema-2 `ForeverDuelDB` SavedVariable stores separate `LEVELING` and `MAX_LEVEL` ratings and W/L counters, finalized matches with their mode and frozen levels, a match-ID index, settings, a nonce counter, and an optional Legacy archive. The client writes SavedVariables on a normal reload/logout; the addon cannot force a transactional disk flush. A crash or forced process termination may lose recent changes.

Unfinished negotiations and matches are deliberately not resumed after reload. Upgrading fully validates schema-1 data before copying it into the retained **Legacy** archive. The new leveling and max-level pools both start at 1500; old results keep their original unweighted rating calculations because their historical levels are unknown. Settings and the nonce counter survive migration. Unsupported schema versions or inconsistent saved data disable rating while preserving the original data. Back up the character's `SavedVariables/ForeverDuel.lua` before upgrading or manual repair.

Version 0.4.5 retains duel protocol **2** (`ForeverDuel2` / `FD2`) and the presence prefix `ForeverDuelZone2`. Pipe-delimited `FDQ2` queries and `FDP2` replies remain compatible with 0.4.1–0.4.4 whisper discovery. Version 0.4.0 peers retain rated compatibility but cannot answer discovery whispers. Install 0.4.5 on both clients to include current request recovery. Pre-0.4.0 peers cannot exchange these protocols; update both clients together.

Ratings and peer metadata are **local, unauthenticated claims**. A player can edit Lua or SavedVariables. This version supplies useful match evidence for future verification; it is not an anti-cheat authority.

## Known limitations and live verification

- **Start and winner evidence:** `DUEL_FINISHED` has no winner payload. There is no documented duel-start event used here. The adapter depends on runtime localized countdown/result strings arriving through `CHAT_MSG_SYSTEM`. The tested live countdown worked; other locales, event orderings, and PvP restrictions still require testing. Missing, restricted, or ambiguous evidence produces no rated result.
- **Identity:** incoming requests contain a name, not a GUID. Forever's unmodified unit-name API returns a name and surname; its native full-name helper supplies the delimiter used for whisper identities. A surname is not a realm. The tested full-name handshake worked. Same-first-name ambiguity and other naming/realm combinations remain unverified; the addon retains native UI if it cannot resolve one unique opponent from visible unit identities. Named `/duel` attempts without a resolvable unit may remain unrated.
- **Outgoing acknowledgment:** a `StartDuel` post-hook captures a candidate; the exact localized `ERR_DUEL_REQUESTED` notice must corroborate it within four seconds. Request/cancellation notices are accepted through `CHAT_MSG_SYSTEM`, `UI_INFO_MESSAGE`, or `UI_ERROR_MESSAGE`. UI notices never supply countdown or winner evidence. The request notice has no opponent field, so routing, ordering, rejected requests, and rapid replacement attempts require live testing.
- **Locales:** ordinary `%s`, `%1$s`, `%2$s`, and countdown integer formats are supported. Korean grammar selectors and Russian declension markup require further work and currently may prevent results from matching. Identical short names on different realms require unambiguous full names. UI text is English.
- **Transport:** addon whispers can fail, throttle, or be unavailable across realm/faction boundaries. An exact native two-player party enables PARTY duel messages, with live timing still unverified; pre-group queue reservations remain whispered. A local send success is not delivery proof. Initial discovery timeout permits guarded late discovery until the pending-request limit; negotiation and result timeouts still cancel rating. Result reports have two bounded retries, including after local finalization. There is no distributed atomic commit: persistent loss or disconnect at the end can leave one client with a committed record and the other without one.
- **Native actions/UI:** deferred popup replacement, combat restrictions, taint, Escape behavior, expiry, and interaction with other addons require live verification. A protected native acceptance may fail despite source-level API verification.
- **Levels and modes:** native level/cap availability, level changes around consent/start, transition to max level, and schema-1 migration still require live checks. A mode or level change invalidates pending rated snapshots rather than reusing consent.
- **Zone presence:** target-triggered whispers and manually requested native channel members have live evidence; the user also confirmed immediate detection with their automated combination in 0.4.3. Forever rejected 0.4.2's `YELL` sends. Unavailable channel membership/roster/selection APIs, missing or restricted native data, throttling, and realm/faction isolation can leave the list empty. Equal maps do not prove a shared phase. Discovery cannot enumerate every nearby player and never grants consent or changes rating.
- **Scope:** ordinary 1v1 duels only. Duel-to-the-death mode, recovery of abandoned matches, server reconciliation, seasons, history pruning, and sophisticated abuse detection are not implemented.

The full source-backed API inventory and remaining assumptions are in [docs/API_VERIFICATION.md](docs/API_VERIFICATION.md). Implementation details are in [ARCHITECTURE.md](ARCHITECTURE.md).

The complete added-file inventory and executed verification results are in [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md).

## Development and tests

Version 0.4.5 was approved and manually published as a Beta for Forever 1.60.1 on 2026-10-04: [ForeverDuelersGuild on CurseForge](https://www.curseforge.com/wow/addons/foreverduelersguild), [published file 9058783](https://www.curseforge.com/wow/addons/foreverduelersguild/files/9058783). The public ZIP download was verified byte-for-byte against the prepared archive. A new CurseForge app or in-game installation test has not been performed. Distribution through third parties remains disabled.

CurseForge project fields, English description, changelog and upload instructions are in [docs/curseforge/UPLOAD_GUIDE.md](docs/curseforge/UPLOAD_GUIDE.md). Run `python tools/prepare-curseforge.py` to generate `dist/curseforge-0.4.5/ForeverDuelersGuild-0.4.5.zip`, the original project logo and publication texts. The manual checklist remains available for regression testing and broader compatibility coverage.

The [release pipeline](docs/curseforge/RELEASE_PIPELINE.md) tests and packages version tags before uploading them to CurseForge. Run `python tools/release.py` for an offline check. New uploads publish automatically after moderation approval; the pipeline never resubmits the already published 0.4.5 package.

Run the pure Lua suite from the repository root:

```sh
python -m pip install --target .test-deps lupa
python tests/run.py
```

The Python runner uses Lupa's Lua 5.1 runtime. If a native Lua 5.1 interpreter is installed, the Lua runner can also be run directly:

```sh
lua5.1 tests/run.lua
```

These tests exercise strict version-2 protocols, match IDs, localized result parsing, level eligibility and weighted Elo, independent rating pools, schema migration, filtered search, rating progression, simulated duel lifecycles, and selected native-adapter behavior with stubs. They do not certify native game event routing, rendering, protected actions, whisper reachability, or client disk persistence. No test dependency ships inside the addon folder.

## Next priorities

**Deferred by the user on 2026-10-03:** the external visual preview with [WoW UI Simulator](https://github.com/Osso/wow-ui-sim) remains a saved follow-up. The earlier investigation noted a native Windows GUI and a `client-wowforever` build option; no simulator has been installed. Compatibility, automatic file reload, and a drag-and-drop editor remain unverified. If resumed, the intended workflow is to preview the actual addon with example match records and retain a final in-game check. This is not a scheduled task.

1. Publish the prepared 0.4.5 Beta and gather feedback from additional Forever players.
2. Investigate reported issues with paired client status/logs where available, use the retained manual checklist for regressions and wider compatibility, and add focused fixes without weakening the local evidence requirements.
3. Review the [local website design](web/README.md) as the first Phase 2 step. The separate backend/import foundation is local; public hosting, character ownership verification, abuse detection and any in-game synchronization need further integration and validation.

Released under the [MIT License](LICENSE).
