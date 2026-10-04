# ForeverDuelersGuild: two-client validation and regression checklist

## Current test conclusion, 2026-10-04

The user reported "testing ist soweit abgeschlossen" for the current 0.4.5 build and subsequently approved release preparation and the first Beta publication. The current test round is therefore **completed (user-confirmed)**. No additional attempt count, individual case results, paired records, or diagnostic logs were supplied. This closes the pending general live-retest status; it does not mark every case below PASS or establish compatibility with every locale, realm, faction, or failure scenario.

Keep the following procedures for later regressions, issue investigation, and broader Beta coverage. Record **PASS**, **FAIL**, or **NOT TESTED** only when evidence exists for that specific case.

The public addon name is **ForeverDuelersGuild**, corrected before the first publication of 0.4.5. The installation folder `ForeverDuel`, manifest `ForeverDuel.toc`, SavedVariable `ForeverDuelDB`, `/duelrating` commands, channel, and protocol identifiers remain unchanged for compatibility. Historical observations below retain their original names; current UI and chat messages use ForeverDuelersGuild.

## Version 0.4.5 repeated-duel recovery — retained regression checks

**Historical 0.4.4 recurrence, 2026-10-04:** the first three duels succeeded, but on the fourth request only the receiver had the ForeverDuel dialog; the challenger could not propose rated. A subsequent duel succeeded. The user had already moved on, so paired status from the failed attempt was unavailable. The exact live cause and any debug dependency remain unconfirmed. The later general 0.4.5 test conclusion is recorded above.

Install **0.4.5 on both clients** and `/reload` both when upgrading from 0.4.3 or 0.4.4. Keep debug off initially and verify the printed setting. Record **PASS**, **FAIL**, or **NOT TESTED** per case and both versions.

1. **Repeated requests:** target each other and repeat at least ten requests, alternating the challenger. Complete several rated duels, including immediate rematches. Both players must get the correct addon dialog and independently consent; compare both results and persistence after reload. Record attempts individually, including failures between successes.
2. **Receiver consents first:** when the receiver's rated button becomes available, click it before the challenger proposes. If the challenger is still checking, leave the same request open. Pending discovery can recover within the original 50 seconds; only the receiver's existing consent may be resent, and the challenger must still explicitly agree. Mark actual delayed/lost-packet coverage NOT TESTED unless reproduced in a controlled setup.
3. **One-sided failure capture:** if either dialog is missing, run `/duelrating status` on both characters before another request or reload. Capture `State`, `Incoming request`, outgoing diagnostics including timestamps, `Last send`, `Last receive`, and `Last`. Record which character challenged, which dialog was visible, elapsed time, and any native notice. Status works with debug off; a subsequent successful duel does not clear the earlier failure from this checklist.
4. **Ordinary and terminal paths:** accept ordinary, decline/cancel, allow timeout, and repeat after reload or zoning. No old packet, retry, or consent may reopen or rate a terminated request. A local cancellation without a native acknowledgment/termination notice retains the original four-second ambiguity guard; wait for that guard before treating a rapid new request as a discovery failure. Confirm native cancellation/finish permits fresh attempts. Repeat the baseline with debug on only after recording debug-off results.

Automated simulations cover delayed prior HELLO, early acknowledgment loss, and early receiver consent; they do not prove the cause of the user's historical live failure. The 0.4.4 identity-recovery checks and historical discovery checks below remain available for regression and additional coverage.

## Version 0.4.4 incoming-dialog recovery — three successes followed by recurrence

**2026-10-04 user result:** after installation and retest instructions, the user reported "okay ist glaub ich stabil 3/3 duelle haben funktioniert". Retain those three successful duels as historical happy-path evidence. The fourth request failed on the challenger side while the receiver had the addon dialog, followed by a successful duel. This remains a historical recurrence; the later general 0.4.5 test-completion confirmation is recorded above. The exact debug setting, late-targeting setup, and paired saved records were not separately confirmed.

The user reports that some requests show only WoW's ordinary dialog and suspects disabling debug. No debug dependency has been reproduced. The preceding automated suites already ran with debug disabled; the live symptom's exact cause remains unconfirmed. For current regression testing, install **0.4.5 on both clients** and record **PASS**, **FAIL**, or **NOT TESTED**, both versions, and `/duelrating status` from each client. `/duelrating debug` is a toggle: use its printed confirmation to establish the intended setting.

1. **Debug off/on:** with both clients' debug logging off, target each other and perform several incoming requests, alternating the challenger. Verify the ForeverDuelersGuild dialog and explicit bilateral rated consent; complete one duel and compare results after reload. Repeat with debug on under the same targeting conditions. Logging must be the only behavior difference.
2. **Identity appears late:** on B, clear target/focus, leave shared groups, hide nameplates, and move the mouse away from A. A challenges B. If A is not otherwise exposed as a native unit, B must retain the ordinary WoW dialog and see the target-the-challenger hint. Leave that request open, then target A after several seconds. The same request should resolve on a half-second retry and show the addon dialog, subject to native popup API availability; both players still need to consent. Capture status if it remains ordinary. A directory listing alone must not establish duel identity.
3. **Accept or decline before resolution:** repeat the unresolved setup. Accept the ordinary WoW request, then target A; repeat separately with decline/cancel. No late addon dialog, revived negotiation, or rated record may appear. Also wait for native popup closure/expiry before targeting and verify no revival.
4. **Original deadline and lifecycle:** leave the unresolved request open beyond 50 seconds, then target A. It must not gain another 50-second window. Repeat with a cancelled/replaced request, reload, zoning, and combat entry; old retry callbacks must not affect a newer request or reopen a closed dialog. Record native visibility/API or taint failures rather than treating automated simulation as live coverage.
5. **Ambiguity remains terminal:** where two observable characters match the same incoming name, rated recovery must stop. Hiding one matching unit afterward must not select the other as the challenger. Retain the ordinary accept/decline path; use automated coverage if the naming setup is unavailable.

The 0.4.3 discovery happy path below remains historical evidence. The initial three successful 0.4.4 duels did not by themselves establish recovery from the later recurrence. The general 0.4.5 test conclusion does not supply individual results for these retained two-client cases.

## Version 0.4.3 directory discovery — happy path confirmed by user

For current regression testing, install **0.4.5 on both clients**. Fully restart when upgrading from before 0.4.3 to load its new `Roster.lua` manifest entry. Enable `/duelrating debug` and retain `/duelrating status` from each. The inspected Forever build is 1.60.1.70205. Record **PASS**, **FAIL**, or **NOT TESTED** per case; submitted sends alone do not prove receipt.

**2026-10-04 user result:** after installing 0.4.3 and receiving the no-target test instructions, the user reported "okay wurde alles sofort erkannt" (everything was detected immediately). Record the automatic-discovery happy path as **PASS (user-reported)** for this test pair. No new paired logs or confirmation of every setup/assertion were supplied; selection restoration, failure recovery, pacing, expiry, and other compatibility cases remain pending.

Live prerequisites confirmed separately: direct profile whispers work; channel 6 mapped to display row 9; the initially nil roster returned `Tester B`, flags, and a player GUID two seconds after selecting row 9. Version 0.4.2 YELL was rejected with result 4 (`InvalidChatType`). The previous Classic broadcast assumption failed on Forever.

1. **No-target discovery:** use adjacent same-faction characters on the same map, outside combat. Clear target/focus, leave any shared group, disable player nameplates, and reload to clear profile caches. Keep the native channel window closed. Open `/duelrating zone` and allow 30 seconds for two test clients. Both should list the other with correct full name, class, level, mode, and rating. Status should show `Zone roster` members loaded, a query/profile whisper, and an actual `WHISPER` presence receive. Do not target until after recording this result. No ordinary chat, duel dialog, consent, or rating change should appear.
2. **Selection and loading:** select another ordinary channel, close the native channel UI, and repeat. The previous selection should be restored after loading or five-second timeout. Open the native channel UI while a background request is pending, or change selection manually: the addon must not override the user. Once closed, directory work can resume. Retain logs if counts remain nil/zero or selection cannot be read.
3. **Rejected route and pacing:** after the first rejected YELL attempt, wait two minutes and change zones. No repeated YELL attempts should occur until a fresh UI session. Directory refresh/join attempts are at least 30 seconds apart; queries per peer are at least 45 seconds apart, replies at least five, and queued discovery whispers at least one second apart. A query can carry the sender profile; received profiles never cause reply loops.
4. **Membership, refresh, and expiry:** verify the dedicated `ForeverDuel` channel is joined on both clients. Leave it on one controlled client and check bounded automatic rejoining. A member that does not answer with a valid profile must not appear. Check map changes and remote rating updates after the next whisper query; stale profiles expire after 120 seconds without fresh traffic. Different realms/factions/phases require separate results; equal map IDs are not range or phase proof.
5. **Fallback and duel regression:** after the no-target case, targeting should retain the confirmed direct whisper fallback. A listing still requires a matching native unit for **Duel**. Complete ordinary and explicitly consented rated flows, verify rating/history consistency, then exercise the class/rating/sort/eligibility dropdowns. Discovery alone must never create or accept a duel.

Automated coverage includes two clients with no target/focus/group/nameplates, delayed counts, stale zero display counts, restoration, missing APIs, errors, user interaction, and rate limits. These automated cases are simulation evidence; the separate user-reported live happy path does not verify every case.

## Version 0.4.1 discovery and dropdown checks — target route confirmed; remaining cases pending

The user confirmed discovery worked after targeting on 2026-10-04. The supplied 0.4.1 screenshot shows a locally submitted channel send, a submitted whisper query, an actual `WHISPER` profile received on map 1420, and a submitted profile reply. This confirms the reported target route for that pair; it does not prove channel receipt, automatic no-target discovery, or every filter/transport case. The inspected client is 1.60.1.70205. The cases below are retained as historical 0.4.1 regression checks; the 0.4.3 procedure above replaces custom-channel and no-target expectations for the current version. Record **PASS**, **FAIL**, or **NOT TESTED** per route and case.

1. **Target discovery:** use two same-map characters outside combat. If the channel has not discovered them, target one from the other client and allow several seconds. Both should receive profiles with the correct full surname, class, level, mode, and rating. Status should identify `WHISPER` reception and a **Zone whisper** query/profile submission. Seeing or targeting a player without ForeverDuelersGuild must not invent a row or rating.
2. **Other available units:** repeat through focus, party/raid membership, and enabled player nameplates. Verify nameplate discovery without targeting. With no channel delivery, group/focus/target, or exposed player nameplate, an adjacent character need not be discoverable. Hovering alone must not initiate discovery or a duel.
3. **Channel independence:** retain separate channel and whisper diagnostics, especially rejected send codes. A missing/rejected channel must not prevent the target query/reply exchange. Still test channel-only delivery and renumbering separately; successful local submission is not delivery proof. Use automated regressions for absent native join APIs or native exceptions that cannot be reproduced safely in-game.
4. **Pacing and lifecycle:** hold a target for two minutes and repeat target/nameplate events. Expect no reply loop or ordinary chat payloads: queries are limited to every 45 seconds per player, replies to every five seconds, and queued discovery whispers to one per second. Check map transitions, reload, logout, and 120-second expiry after all announcements stop. Confirm discovery preserves a pending/active rated duel and never changes ratings/history or supplies consent.
5. **Dropdown selection:** open each Class, Rating, Sort, and Rated eligible menu and choose a nonadjacent option directly. Opening must not change the filter. Check the selected marker, outside-click dismissal, closing the browser, Escape, small-screen placement, long localized labels, and no click-through to Duel. Class contains All plus Warrior, Paladin, Hunter, Rogue, Priest, Shaman, Mage, Warlock, and Druid, with no Death Knight, Monk, Demon Hunter, or Evoker.
6. **Filter/duel regression:** combine literal name search with dropdowns, change page, narrow the search, and reset. Check same-mode rating windows and eligibility as below. Challenge a fresh listed player and complete the existing explicitly consented rated flow. A profile discovered through whisper must pass the same fresh native identity/level checks as a channel profile.

These checks supplement the retained rating/migration and earlier transport cases below. Version 0.4.0 retains rated compatibility but cannot answer `FDQ2` queries. The target-triggered 0.4.1 route has the bounded live evidence recorded above; remaining native rendering and transport cases stay unverified until separately recorded.

## Version 0.4.0 focused checks — NOT TESTED live

Install **0.4.0 on both clients**. Rated and presence protocols changed; older clients will not negotiate with 0.4.0. Back up each character's SavedVariables before the first login. Use the same maximum-level cap on both clients. These checks supplement the existing native-duel and failure matrix below.

1. **Migration:** load a valid 0.3.x character, open `/duelrating`, and inspect Legacy. Its rating, W/L and every old match must remain intact. Leveling and Max level each start at 1500/0-0. Reload and verify all three views plus minimap position/debug setting. Corrupt/unsupported data must remain untouched with rating disabled.
2. **Search:** discover several players, type a partial name including spaces or Lua pattern characters, select class/rating dropdown options, and switch sorting. Names are matched literally, case-insensitively. Rating windows compare only your current group/cap. Changing filters resets the page; Reset filters restores all fresh players. An empty filtered result must be distinguishable from no discoveries.
3. **Eligibility:** below cap, test differences 0, 5 and 6 in both directions. Five is allowed; six has a clear message, disabled rated action and working ordinary accept/decline. Repeat with one character just below cap and one at cap: this remains ordinary because groups differ. Unknown/skull levels never enable rated consent.
4. **Weighted transfer:** with fresh equal ratings, at equal levels verify +16/-16. With five levels difference and both below cap, verify +20/-20 for the lower-level winner; in a separately reset fresh pair verify +12/-12 for the higher-level winner. Confirm the predicted changes shown before consent, both stored level snapshots, shared match ID, bracket, and complementary deltas after reload.
5. **Separate groups:** retain leveling results, reach max level, and check that subsequent eligible max-level duels use the independent Max level pool. Leveling rating/history remains intact. Selecting a different overview tab never changes the pool used for a duel or advertised on the tooltip.
6. **Level changes:** a level-up during pending consent/countdown must invalidate rating while leaving ordinary native controls. Check peer level changes and local `PLAYER_LEVEL_UP` timing. Unrelated players leveling must not cancel the duel. A changed participant must not commit an outcome for the obsolete snapshot.
7. **Progression chart:** verify empty, single-duel, flat, alternating wins/losses and more-than-40-duel histories. The chart includes the correct rating before its first displayed duel, follows duel order and the selected group, and shows no stale lines after switching to an empty group. Cross-check its last value with the rating card. Legacy uses the old unweighted results.
8. **Layout/input:** check the 960x812 overview and 800x676 browser at normal and small UI sizes, long surnames, class cycling, text entry, Escape/Enter focus handling, page navigation, dragging and closing. Confirm chart lines render with the target client's native Line API. Simulator preview work is deferred.
9. **Presence/tooltips:** confirm updated payloads reach the other client, rows and tooltips show the right level/group/rating, and a level/rating change refreshes after the send interval. After a level-up, an old cached level must not show a misleading tooltip until fresh presence arrives. Discovery remains incomplete and advisory.
10. **Missing cap and compatibility:** if native level/cap data is temporarily unavailable, saved data should still load and ordinary duels work; a later available cap permits a new rated request. Mixed 0.3.x/0.4.0 clients stay unrated. Check player level/cap values against the character UI on the actual Forever build.

Lua simulations cover these logic paths; native rendering, API timing, channel delivery and actual protected actions remain unverified until these checks are recorded.

**The version 0.1.3 happy path was confirmed live on 2026-10-03.** Screenshots show incoming `HELLO`/`HELLO_ACK`, `READY`, bilateral `ACCEPT`, `COMMIT`, `RATED_CONFIRMED`, `START_OK`, localized countdown messages for 3/2/1, `IN_PROGRESS`, and `RESULT` traffic. The user then confirmed successful rating behavior and persistence after reload.

This is a bounded live result, not a blanket PASS for this checklist. Complete counterpart logs and paired stored records were not provided for independent comparison. Cross-faction/realm combinations, other locales, and the full loss/cancellation/UI-error matrix remain **NOT TESTED** live unless separately recorded. Keep the steps below for regression and remaining coverage.

The user confirmed the 0.2.0 overview worked and approved the 0.2.1 redesign on 2026-10-03. This does not establish every layout/scaling and details check in Test 13. Version 0.2.2 adds a minimap button and custom icon; the focused checks below are **NOT TESTED** live.

Version 0.3.0 adds shared-channel presence, a zone browser, and player-tooltip ratings. Its separate two-client checks below are **NOT TESTED** live until recorded; the earlier whisper-duel success does not establish custom-channel delivery.

## Minimap icon check (0.2.2)

1. Install the entire updated addon folder, including `Media/Icon.tga`, then fully restart WoW. Check for the crossed-swords icon in the addon list and beside the minimap, with transparent corners rather than a green/missing texture.
2. Hover for the controls, left-click to open the overview, then click again to close it. Check the shortcut with both empty and existing history; opening it must not change rating or records.
3. Drag the button around the standard round minimap. Releasing a drag should not also toggle the overview. Reload and verify the chosen position persists for this character.
4. Repeat with the user's UI scale and other minimap addons. Custom square-minimap boundary placement is not implemented; record any overlap, clipping, or scaling problems.
5. During a pending and an active duel, open/close the overview through the icon. The shortcut must not accept, decline, cancel, or alter the duel. The automated suite additionally exercises isolated button errors; retain any actual Lua errors from the live check.

## Preparation

1. Use two controlled characters, **A** and **B**, on two clients. Begin on the same realm/faction, outside combat, in an area that permits ordinary duels.
2. Install the same source revision on both. Record client version/build, interface version, locale, realm/faction, addon version/revision, and other enabled addons. Begin with unrelated addons disabled, then repeat integration cases with the normal addon set.
3. Back up each character's existing `SavedVariables/ForeverDuel.lua`, if present. Use fresh test characters or the explicit reset flow if both test participants intend to discard existing local results.
4. On both clients run `/console scriptErrors 1`, `/duelrating debug`, `/duelrating summary`, and `/duelrating status`. Enable debug only once: the command toggles it. `/duelrating` now opens the separate overview window.
5. Arrange for the receiver to have the challenger as target for the baseline cases. This provides a resolvable unit identity; later tests intentionally remove it. Use the normal player context-menu **Duel** action for baseline initiation.
6. Retain both clients' chat/debug logs or screenshots and any Lua errors. For a successful match record both full names/GUIDs, consent actions, match ID, pre-match ratings, countdown, result source, final rating, record count, and `/reload` outcome.
7. Check [API_VERIFICATION.md](docs/API_VERIFICATION.md), especially every **REQUIRES LIVE CLIENT VERIFICATION** note. If basic event routing fails, record the failure and fix the adapter before interpreting later tests as passed.

Use `/duelrating status` during pauses. Intermediate acknowledgment states may pass too quickly for manual inspection; the debug log must show their ordering. A missing rated result is a safe failure, but it is still a failed happy-path test.

## Test 1 — Addon loads

1. Log both clients into the world with fresh valid SavedVariables.
2. Run `/duelrating`, `/duelrating summary`, `/duelrating history`, and `/duelrating status` on both.
3. Open the native Lua error display if it appeared.

Expected: no Lua error; the overview opens with rating 1500, zero wins/losses/matches, best rating 1500, no win percentage, and empty-history guidance; chat summary agrees; state `IDLE`. Both characters have separate data. Future-version or damaged existing data must be preserved with rating disabled, rather than reset to a fresh ladder silently. Close the overview before baseline duel-dialog tests.

## Test 2 — Both players have the addon

1. A targets B and chooses the ordinary context-menu **Duel** action. B targets A.
2. Do not click any acceptance yet.
3. Observe B's dialog and both debug logs for at least one discovery exchange.

Expected: B sees ForeverDuelersGuild's incoming dialog with ordinary accept and decline available immediately. The native popup is hidden after a usable replacement appears, without overlapping or flickering permanently. After discovery, B's rated button becomes enabled and A can propose rated status. Displayed opponent/class, rating, and W/L refer to the intended participant. Each enters `READY` only after a compatible nonce-echoing acknowledgment.

On A, verify a captured outgoing attempt is followed by the native outgoing request notification before negotiation. Supported routes are `CHAT_MSG_SYSTEM`, `UI_INFO_MESSAGE`, and `UI_ERROR_MESSAGE`. If no matching notice arrives, record an adapter incompatibility; do not bypass the native-context gate.

### Focused handshake retest for 0.1.3

1. Install 0.1.3 and reload both clients; confirm that version with `/duelrating status`.
2. Enable debug on both clients, cancel any previous request, wait five seconds, and issue a new normal duel request with both players targeting one another.
3. Capture the challenger's outgoing capture/acknowledgment event source and both clients' last send/receive fields. For Forever characters with surnames, verify that the whisper target uses the native full name, including its space, and agrees with the received sender. A surname must not become a fictitious realm or a `Name-Surname` whisper target.
4. Leave both rated buttons untouched until both clients reach `READY`; discovery alone must not accept the duel. If four seconds elapse first, the receiver must show the normal accept/decline path with rated disabled, and status may show `DISCOVERY_WAIT`. The outgoing discovery frame stays hidden.
5. If delayed discovery arrives while that same request is still pending and before 50 seconds, verify it may enable rated choice, then require both explicit clicks as usual. If it does not arrive naturally, run the automated delayed-discovery regressions and mark live delayed-delivery coverage **NOT TESTED** unless a controlled network setup can reproduce it.
6. Repeat and choose **Accept Normal Duel** or **Decline** during `DISCOVERY_WAIT`. Delayed traffic must never revive rated choice or change rating for that request. Also run the automated expired-request and native-start cases.
7. Retain both logs if discovery still fails. Distinguish an absent outgoing acknowledgment, wrong full-name target/sender, transport rejection, and received-but-rejected packet. Run the one-delivered-HELLO and duplicate-acknowledgment regressions: both sides should become ready without loops or implied consent.

## Test 3 — Accept unrated

1. Repeat Test 2, then B clicks **Continue Unrated** before or after discovery, or **Accept Normal Duel** if the initial discovery check has elapsed.
2. Complete the ordinary duel.
3. Compare both ratings, W/L totals, and history with the values before the challenge.

Expected: ordinary native duel starts immediately; rated negotiation is cancelled; no rated match is saved and no rating/counter changes. Repeat once while discovery still says “Checking for ForeverDuelersGuild...” to prove communication does not block ordinary acceptance.

## Test 4 — Rated proposal

1. Start a new ordinary duel request and wait for discovery.
2. B clicks **Accept Rated Duel**; A does not click anything yet.
3. Observe for a few seconds, shorter than the 12-second negotiation timeout.

Expected: A sees the rated proposal with both ratings and a choice to accept or keep it unrated. B is `LOCAL_ACCEPTED` and A is `REMOTE_ACCEPTED`. The native duel has not started; no countdown, rating update, or history entry occurs.

## Test 5 — Both accept rated

1. Continue Test 4 before timeout and have A click **Accept Rated**.
2. Capture both clients' match IDs and state-transition logs.
3. Wait through the ordinary native countdown.

Expected: both explicit consent actions precede `PREPARED`. A sends `COMMIT`, B sends `CONFIRM`, and A sends `START_OK`. Both enter `RATED_CONFIRMED` before B's native acceptance attempt. Each logs the same canonical match ID and the original pre-match ratings. Each observes its own countdown, sends `START`, and enters `IN_PROGRESS` after the remaining seconds. No rating changes merely for starting.

**Live gate:** confirm the countdown message is readable and delivered to `CHAT_MSG_SYSTEM`. Do not accept an `IN_PROGRESS` state inferred solely from consent or elapsed negotiation time as a passing result.

## Test 6 — Player A wins

1. Complete the rated duel from Test 5 with A winning normally.
2. Run `/duelrating` and `/duelrating history` on both clients.
3. Compare both debug logs and records, including the winner GUID.

Expected on fresh equal ratings: A records `WIN`, +16, rating 1516, one win; B records `LOSS`, -16, rating 1484, one loss. Both save exactly one match with the same match ID and complementary results. Each independently observed native finish and a local system-message winner before relying on the peer result. Both records retain 1500 as each pre-match rating. `DUEL_FINISHED` itself is never interpreted as supplying a winner.

Repeat with B winning a later match. Unequal-rating deltas must remain complementary; do not expect every later transfer to be 16.

## Test 7 — `/reload`

1. After a successful completed match, record both current ratings and match IDs.
2. Run `/reload` on each client and then `/duelrating` and `/duelrating history`.
3. Log out cleanly, log back in, and repeat the queries.

Expected: rating, counters, history, and match IDs survive; no duplicate record appears. A clean reload/logout supplies the persistence test. A forced client termination is a separate data-loss limitation, not a guaranteed persistence path.

## Test 8 — Only one player has the addon

1. Disable ForeverDuelersGuild on A and reload A. Keep it enabled on B.
2. A challenges B normally. Immediately verify B can accept ordinarily or decline.
3. Wait longer than four seconds on another request.
4. Complete an ordinary duel, then reverse which client has the addon.

Expected: no rated match starts, no rating changes, and ordinary duels work in both directions. After four seconds B enters `DISCOVERY_WAIT` and explains that the peer has not responded; **Accept Normal Duel** and **Decline** remain available. The rated button stays disabled. Keeping a bounded late-discovery window must never delay ordinary acceptance.

## Test 9 — One player refuses rated

1. With both addons enabled, let B propose rated, then have A click **Keep Unrated**.
2. Let B accept the resulting normal duel and complete it.
3. Repeat with A proposing rated and B choosing **Continue Unrated**.
4. Repeat once using **Decline** instead of ordinary acceptance.

Expected: each refusal invalidates rated consent on both clients. Ordinary acceptance still works where applicable; decline cancels the native request and returns to idle. No rated history/counter changes occur.

## Test 10 — Duplicate duel-end processing

1. First run the automated suite from the repository root (`python tests/run.py` with Lupa installed, or `lua5.1 tests/run.lua`). Confirm duplicate result/finalization tests pass.
2. For a live replay check, use a temporary test copy only: in `Core.lua`, change the `DUEL_FINISHED` dispatch to call `FD.duel:Finished()` twice. Make that exact instrumentation change on one or both test clients; reload before the match.
3. Complete one agreed rated duel and compare ratings/history on both clients.
4. Restore the original unmodified `Core.lua` and reload both clients before further tests.

Expected: one history entry per client, one W/L increment, and one Elo transfer. A repeated `Finished()` after local completion is harmless. Do not leave instrumentation in a distributed addon. WoW has no supported command here that invents or broadcasts a native duel event.

## Test 11 — Negotiation timeout

1. Start discovery, let one player click rated, and leave the other player's confirmation untouched for more than 12 seconds.
2. Inspect status and the ordinary buttons.
3. Complete an ordinary duel if the native request is still pending.

Expected: rated negotiation cancels; no rating/history changes; normal acceptance/decline remains possible within the native request's lifetime. Late consent from the expired rated flow must not revive it. Record actual latency before changing centralized timeout values.

## Test 12 — Rematch

1. Complete one rated duel and note its match ID.
2. Start a new normal request between the same two characters, explicitly agree again, and complete a second duel.
3. Repeat once after a clean reload.

Expected: each rematch uses a different match ID, keeps the previous record intact, and snapshots the latest rating. Old packets/callbacks never complete or cancel a newer session. Each valid duel updates once.

## Test 13 — In-game overview and details, version 0.2.1

1. Upgrade with existing schema-1 history intact. Open `/duelrating`, close it with the same command, and repeat with `/duelrating ui`, **Close**, and Escape. Verify the charcoal/gold layout, four statistics cards, alternating history rows, and right-hand details panel. Drag the window and check screen-edge clamping; reopen at smaller resolutions and different UI scales to verify it fits without changing the global UI scale.
2. Compare rating, W/L, total matches, and recent results with `/duelrating summary` and `/duelrating history`. Check win rate against wins divided by total matches, best retained rating against the local history including the initial 1500, and current streak against consecutive newest results.
3. If at least nine legitimate rated records exist, use **Next** and **Previous**. Verify eight rows per page, newest-first order, no repeats/omissions, and disabled buttons at page boundaries. Mark multi-page live coverage **NOT TESTED** if fewer records exist; automated tests cover it without modifying live history.
4. Select different rows and verify the gold marker/arrow moves with the selection. The persistent details panel must update both players' names, class/spec where available, client-local date, duration, outcome, and rating before/after/delta. The opponent's post-match rating must visibly say **calculated**; it is not a peer-verified balance. Older records without spec/outcome metadata must still display without invented values. Inspect long surnames, fonts, clipping, and button placement at the intended resolution and UI scale.
5. Leave the overview open during a rated duel. Confirm it does not replace the request/consent dialog or supply consent; after finalization it shows the stored totals without double-counting the match. Close/reopen it during negotiation and verify the duel state is unaffected. An ordinary duel must not add history or change these statistics.
6. Reload and reopen: existing records/statistics must remain, with the newest page selected. On a disposable test character only, perform the confirmed reset procedure below with the overview visible; it must refresh to the empty state.
7. Run the automated presentation-error regression. It must preserve the active duel and saved data, hide the failing overview, and leave `/duelrating summary` available. Do not inject test failures into a distributed addon.

Expected: the window only reads the existing record; moving, paging, selection, and closing never change rating or consent. No new schema or protocol negotiation is required. Damage, healing, spell, and combat-timeline analytics are absent because they are not recorded. Retain an actual 0.2.1 client screenshot before marking its layout/details behavior PASS.

## Zone presence, browser, and tooltip checks (0.3.0)

Use two controlled characters with 0.3.0 installed, initially on the same realm/faction/map and outside combat. Retain `/duelrating status` and debug output from both clients. Record **PASS**, **FAIL**, or **NOT TESTED** separately for each case.

1. **Join and discovery:** log in, open `/duelrating zone`, and allow two 45-second heartbeat intervals. Both clients should join `ForeverDuel` and list the other with the correct full surname, rating, and class color. No payload should appear as ordinary chat. Discovery alone must not open a duel, grant consent, or change rating/history. Test characters from different guilds as well; the channel requires no shared guild.
2. **Channel availability:** record the channel number and prefix/send status. Leave/rejoin the custom channel or change other channel memberships so its local number changes. Verify discovery resolves the new number and ignores packets from an unrelated channel. Exercise delayed/rejected joins and throttling where reproducible; otherwise mark those live cases NOT TESTED and run their automated regressions. Retry attempts must remain paced, without chat floods or disruption of duel whispers. A send result of zero alone is not delivery proof.
3. **Map changes and phases:** move B to another map, wait for its update, and verify B disappears from A's list. Return and verify rediscovery. Test unavailable map data using the automated regression. On the same map but another phase or outside range, a listing may remain: Duel must either require a resolvable matching unit or let the native game reject the request without creating a rated result. Record realm/faction/phase combinations independently; do not infer broad support from one pair.
4. **Expiry and reload:** after A receives B, log B out or disable the addon on B. At 120 seconds after the last received announcement, B must disappear and its cached tooltip rating must no longer be available. Reload A: the cache must begin empty and repopulate only from new announcements, while A's saved rating/history survive. Loading screens must not expose stale actionable listings. The automated bounded-cache case covers more than 300 announced peers.
5. **Rating updates and reset:** complete an explicitly agreed rated duel, then verify each peer's list/tooltip rating updates from a fresh announcement. On a disposable character, perform a confirmed reset and verify 1500 propagates. Update attempts remain at least five seconds apart. A presence update must not overwrite frozen snapshots or change the other client's own rating.
6. **Browser navigation:** open `/duelrating`, click **Players in zone**, return with **Your record**, and toggle `/duelrating zone`. Check Escape, dragging, small-screen scaling, and pagination with enough peers. During pending and active duels, navigation and discovery refreshes must preserve the existing consent/unrated/decline controls.
7. **Native challenge and consent:** target a listed nearby peer and click its Duel button. Verify the normal native request, outgoing acknowledgment, and unchanged bilateral rated flow. Repeat with neither player consenting, only one consenting, ordinary acceptance, decline, and an already active/pending duel. No listed rating, hover, or presence packet may supply consent. Run the automated wrong-name/GUID and expired-entry challenge cases.
8. **Tooltips:** hover a known nearby peer and your own character; **Duel Rating** should match the appropriate fresh announcement or own local summary. Reopen/rebuild repeatedly: exactly one line per build. Unknown players, NPCs, expired entries, and a record whose GUID/full name does not match the visible unit must have no line. Hovering sends nothing. Test with the normal tooltip addon set and retain Lua/taint errors; restricted-value and malformed-packet cases remain covered by automated regressions where they cannot be reproduced safely live.

Expected: the browser contains recently reachable addon users on the same map, not every player in the zone. Channel/map/UI failures remain isolated from rated-duel state. Record actual cross-realm/faction delivery and phase behavior before advertising those combinations as supported.

## Additional release-gate cases

### Either player proposes; native acceptance race

1. A starts the normal native request, waits for discovery, and clicks **Propose Rated Duel** before B presses rated. B then agrees. Complete the duel.
2. Repeat with both players pressing rated almost simultaneously.
3. On a third request, accept the ordinary native duel through another supported native path while ForeverDuelersGuild is still negotiating.

Expected: either proposal order can reach the same agreement barrier. Simultaneous consent does not duplicate native acceptance. A countdown before `RATED_CONFIRMED` makes that duel unrated; no later packet can retroactively rate it.

### Outgoing attempt acknowledgment and rejected requests

1. Initiate an invalid native duel attempt, such as challenging an unavailable or disallowed target, and inspect A's log/status.
2. Start a valid request, then switch A's target to a third character before discovery completes.
3. Quickly cancel/reissue valid requests between the two test characters; separately test another visible candidate with a third controlled observer if available.
4. Try the native `/duel Name` path with no resolvable unit identity.

Expected: a rejected/unacknowledged attempt expires within four seconds and cannot create a rated session from a peer whisper. Target switching does not rewrite a captured opponent. Ambiguous, superseded, or unresolved candidates remain unrated. A bare native request-success message is not proof of which opponent was accepted; retain logs around rapid requests to verify the correlation assumption.

### Incoming identity missing or ambiguous

1. On B, clear target/focus, move the mouse away, leave any group with A, and hide enemy nameplates. A challenges B.
2. Repeat with A resolvable via target; switch B's target immediately after the request to a third character.
3. If available, test Forever characters with the same first name and different surnames; separately test identical short names across realms on clients supporting that naming model. Include a result message containing only ambiguous short names.

Expected: no uniquely resolvable incoming GUID leaves the normal Blizzard dialog available. Version 0.4.4 retries unavailable identities while the same native popup remains open and within the original deadline; observed ambiguity stops recovery for that request. A target switch never substitutes another opponent in the match. Native full names preserve surnames and their delimiter; recorded local realm metadata remains separate from the surname. Ambiguous short-name winner messages produce no rated result; distinct full names are required. Restore baseline targeting before the happy-path tests.

### Snapshot changes

1. Begin rated negotiation, then change the local specialization before agreement/start if the client permits it.
2. Run the automated stale-rating and changed-peer-profile tests. A rating mutation cannot normally be produced by the UI during an active duel because reset is blocked; use the test harness rather than editing live SavedVariables during a match.
3. Retry with unchanged identities/specs/ratings and complete a valid duel.

Expected: spec or pre-match rating changes invalidate the old rated flow. A peer changing rating/spec/class/W/L inside a session cannot replace the frozen profile. A fresh session can establish new snapshots.

### Malformed, incompatible, reordered, lost, and duplicate packets

1. Run the automated protocol/state suite. Retain the assertion count and pass/fail output.
2. Inspect its cases for wrong prefix/channel/sender/session/GUID/role, incompatible version, malformed numeric fields, long payloads, duplicate consent/results, changed profiles, delayed starts, mismatched winners, and missing evidence.
3. On live clients, introduce ordinary connection latency/loss with a controlled network test setup if available; otherwise explicitly mark network-fault live coverage **not tested**. Do not claim a malformed-packet live test merely because a normal duel passed.

Expected: unexpected input does not grant consent or change snapshots. Duplicates never double-charge rating. One lost result report can recover through the two immutable retries at one-second intervals, including after the sender has locally finalized. Missing evidence after bounded recovery causes local timeout/unrated handling. **Persistent one-way final-result loss can produce asymmetric local persistence:** one client may have sufficient evidence and commit while the other times out. Record this limitation; this release does not promise atomic two-client commits or server reconciliation.

### Reload, disconnect, zoning, and boundary retreat

1. Reload one client during negotiation, then during an active rated duel on another attempt. Let the other client finish or expire its session.
2. Repeat with disconnect/logout and a world-loading transition.
3. Complete a separate rated duel by leaving the duel boundary so the native retreat outcome occurs.

Expected: a reloaded/zoned client never resumes or rates an incomplete match. Its peer cannot finalize solely from its own result when required evidence is missing. An outcome already independently confirmed before a disconnect may already be committed; do not expect rollback. Retreat counts only when native finish plus an unambiguous localized retreat winner and matching peer evidence are available. Boundary-out/in events alone never determine a winner.

### Non-English locales and restricted messages

1. Repeat Tests 2, 5, and 6 with each intended supported client locale; preserve actual native countdown/knockout/retreat text and state logs when readable.
2. Explicitly include `koKR` and `ruRU` if those locales are intended: current grammatical rendering may not match this parser.
3. Repeat while the target client applies its ordinary PvP/chat messaging restrictions. Do not bypass or attempt to reveal secret values.

Expected: recognized localized placeholders preserve winner/loser order. Unrecognized Korean grammar or Russian declension produces no rated finalization. Restricted identity/countdown/result text is not compared, printed, or guessed; the duel remains ordinary or times out without a local rated record. This is a release blocker for any locale/environment advertised as supported.

### Cross-realm and cross-faction

1. Repeat discovery and a complete agreed duel across connected realms, different realms, and opposite factions wherever the game permits the underlying native duel.
2. Capture normalized sender/full names and whether addon whispers arrive.

Expected: a reachable, unambiguously identified peer may work. Unreachable or ambiguously named peers degrade to ordinary duels. Do not infer cross-faction/realm whisper support from same-realm success. Record each tested realm/faction combination explicitly.

### UI ordering, combat restrictions, Escape, and expiry

1. Repeat incoming requests immediately after reload and with other duel/UI addons enabled. Observe that either a usable addon dialog or the native dialog remains available.
2. Enter combat just before an incoming request, then on another attempt after the addon dialog has appeared. Inspect accept/decline behavior and Lua/taint errors.
3. Press Escape while the duel-request dialog is active; record whether the pending native request remains, closes, or requires a visible button. The request frame has no separate Escape registration; the independent overview window does and must not cancel the request when closed.
4. Leave a request untouched past the 50-second addon pending timeout and the actual native expiry. Verify the bounded native restoration attempt at timeout; it permits up to five seconds of watchdog grace, so check it against the actual server request lifetime. Repeat across combat entry: when native restoration is blocked, the addon-owned ordinary buttons must remain available with rated status invalidated. Then issue a fresh request.
5. Where the client prohibits the automated native acceptance attempt, verify the failure cancels rated status and restores a usable ordinary path when the native request is still valid. A silent rejection should time out awaiting a countdown after eight seconds.

Expected: no permanent Blizzard popup modifications, no late callback hides a newer request, and no rated result follows a failed/early native action. A request that is genuinely expired must not be resurrected. Inspect pending-timeout behavior against the real native lifetime; no hidden live request should leave the user stuck. Any taint or inaccessible normal accept/decline path blocks release until fixed.

### Reset confirmation and data integrity

1. With no active request, run `/duelrating reset confirm` alone. Then run `/duelrating reset`, wait more than 15 seconds, and attempt confirmation.
2. Begin a pending duel and try both reset commands.
3. End/cancel the request. On a disposable test character, run `/duelrating reset`, then confirm within 15 seconds.
4. Reload and inspect results. Test malformed/future schema loading with a backed-up disposable SavedVariable file only while the client is closed.

Expected: an unarmed/expired reset does nothing; pending/active reset is refused. A valid confirmed reset clears only that character's local rating/history to 1500/0/0, preserving debug settings and nonce-counter continuity. Malformed/future data disables rating without overwriting the source data. Restore the backup when finished.

## Acceptance record

For every case, record **PASS**, **FAIL**, or **NOT TESTED**, both client builds/locales, source revision, timestamp, logs, and observed deviations. A happy-path release requires the same match ID, pre-start explicit consent on both clients, independent local winner evidence, complementary results, exactly one rating update each, and successful persistence after reload. Also require ordinary duels to remain usable when the addon cannot safely negotiate.

The baseline happy path now has user-confirmed live success. Complete and retain the remaining failure-path evidence before claiming broad compatibility or production reliability. Backend, uploader, and website work require a separately agreed next phase; keep unsupported locales/transport combinations and untested client restrictions explicit in release notes.
