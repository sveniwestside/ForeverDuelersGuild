# Two-client test checklist (0.6)

The Lua suites simulate two or more clients with latency, loss and throttling. They cannot show how the real client routes events, protects actions or delivers whispers, so this checklist exercises that part. Mark each case **PASS**, **FAIL** or **NOT TESTED**. A simulation never counts as a live PASS.

Roles: **A** challenges, **B** receives, unless a step says otherwise. **C** is an optional third client. Refer to the clients only as A, B and C in reports.

## 0. Preparation

1. Commit the source. On each PC run `powershell -ExecutionPolicy Bypass -File tools\install-addon.ps1 -AddOnsDirectory "<WoW>\_classic_beta_\Interface\AddOns"` (the bypass applies only to this call; Windows blocks unsigned scripts by default) from the same commit. Keep the JSON it prints (`version`, `build`, `savedVariablesModified: false`).
2. Restart both game clients completely. 0.6 adds new files, and `/reload` does not load them.
3. On both clients, `/duelrating status` must start with `Version: 0.6.0 (<build>) | Addon transport: registered`. `<build>` must be the same on both and equal `git rev-parse --short=12 HEAD`. There must be no `Saved data: unavailable` line, and the state must be `IDLE`.
4. Back up `WTF/Account/<account>/<realm>/<character>/SavedVariables/ForeverDuel.lua` on both PCs.
5. Run `/console scriptErrors 1` and `/duelrating errors clear`. Leave debug off (`Debug: disabled` in status).
6. Note for each client: PC, Battle.net account, locale, other enabled addons, and the home realm number (the digits after `Player-` in the character GUID).
7. For rated cases: same faction, same level cap, same mode (both below the cap or both at it), at most 5 levels apart, outside combat, where duels are allowed.
8. Horde characters join the in-game community `ForeverDuelersGuild` through the link `/duelrating community join` prints (section 5, step 4.1 tests this on a fresh character first); there is no Alliance community yet. The queue relies on it across zones.

## What to collect when something fails

Do this on **both** clients before starting another request or reloading:

1. `/duelrating status`: copy every line. The most important are `Version`, `State`, `Traffic`, `Native request`, `Peer confirmation`, `Discovery round trip`, `Last send`, `Last receive`, `Peer validation`, `Last pending rejection`, `Zone discovery`, `Discovery route` and the `Queue` lines. On a German client the zone and queue lines carry German labels (`Zonensuche`, `Suchweg`, `Warteschlange`); the duel and transport lines stay English.
2. `/duelrating diagnose lifecycle`: the last 30 lifecycle entries.
3. `/duelrating diagnose transport`: the last 30 transport entries, including pings and outbound failures.
4. `/duelrating errors`.
5. For queue cases also `/duelrating queue status`.
6. Then `/reload` once, so the client writes SavedVariables, and copy `ForeverDuel.lua` from both PCs.

Write down the wall-clock time and what was clicked. The diagnostics contain character names and GUIDs, but no message contents, nonces, queue tickets or positions. Share them privately.

## 1. Solo rated duel: happy path

Not grouped. For the baseline, B targets A.

1. A challenges B through the unit menu **Duel**.
2. B sees Blizzard's normal popup at once. Shortly after, a ForeverDuelersGuild panel appears below it. It shows A's level, class, rating and record, `Rated: win +x / loss -y`, "Blizzard's Accept starts an UNRATED duel.", "Decline or Esc refuses the duel request." and `Request expires in N s` counting down. A sees its own panel with "Your opponent also uses ForeverDuelersGuild.", **Propose RATED duel** and **Keep unrated**.
3. During the request, `/duelrating status` on both shows `Peer confirmation: bound to current request | peer addon 0.6.0` and `Discovery round trip: N s`. Record N.
4. A clicks **Propose RATED duel**. B's panel says "A proposes a RATED duel."
5. B clicks **Accept as RATED duel**. Blizzard's popup closes and the countdown starts without another click.
6. At the countdown, both chats say `RATED duel vs <other> (win +x / loss -y).` A may first say "Waiting for B to confirm the RATED duel." and then the RATED line.
7. Fight to a knockout. One client says `Rated WIN vs <other>: +x rating (r).`, the other `Rated LOSS vs <other>: -x rating (r).`, with complementary values.
8. Repeat with B clicking first, and with B as the challenger. Repeat once with the challenge from `/duel` and once from the Duel button in `/duelrating zone`.

## 2. Failure paths

In every case: no rated record, no rating change, and the ordinary duel stays possible.

1. **Blizzard Accept:** B clicks Blizzard's **Accept** instead of the panel. The duel starts. B says the duel is UNRATED ("You kept this duel unrated"); A says it is UNRATED ("Your opponent chose an unrated duel"). Repeat after A has already proposed rated: A must never show a RATED line.
2. **Keep unrated:** A clicks **Keep unrated**. Both say "This duel will be UNRATED: ...". B's panel closes, Blizzard's popup stays, and B can still accept an ordinary duel. Repeat with A pressing Esc on its panel, and with B closing its panel with the X. Esc also closes the panel when bags or another window are open (one Esc closes both), which keeps the duel unrated.
3. **Decline and Esc:** B clicks **Decline** on Blizzard's popup; on a second request B presses Esc. The request ends on both sides, and A may say "This duel will be UNRATED: The duel request was cancelled." Both return to `IDLE`, and A can challenge again at once.
4. **Combat:** (a) With the panel open, B enters combat. Both say "This duel will be UNRATED: Combat started." (b) B is already in combat when the request arrives: the rated button is disabled and the panel says "Leave combat to choose a rated duel." When B leaves combat within the window, the button works again.
5. **Out of range, then retry:** A challenges B from beyond duel range and notes the exact error text. A moves closer and challenges B again within a few seconds. The second request must be tracked normally: the panel appears, Rated works, and there is no "Rated tracking could not attach" line. The failure IDs behind this are not verified live, so record the error text.
6. **Outdated peer:** install 0.5.7 or 0.4.5 on B and challenge in both directions. A (0.6) says once "Your opponent uses an older ForeverDuel version. Rated duels need version 0.6 or newer on both sides.", and status shows `Peer addon: outdated (protocol 2)`. The duel stays ordinary on both. Reinstall 0.6 on B and restart the client afterwards.
7. **Not eligible:** 6 levels apart, or one character at the cap and one below it. No panel appears. A known addon user gets a reason such as "Rated unavailable: players must be within 5 levels of each other".
8. **Expiry:** nobody clicks the panel. After 50 s the panel closes and the chat says "This duel will be UNRATED: The request expired." Blizzard's popup keeps its own timer and can still start an ordinary duel.
9. **Challenger not visible:** B clears target and focus, turns nameplates off and moves the mouse away. A challenges. If A is a known addon user, B sees "Rated duel pending: target the challenger ...". Targeting A within 50 s brings the panel.
10. **Reload during a request:** A types `/reload` while the panels are open. B says "This duel will be UNRATED: Your opponent logged out or changed zones."
11. **Accept without a duel:** if a duel ever fails to start after the addon's accept, both clients report it within 8 s, and B sees "If no duel started, ask A to challenge you again." Collect the outputs.
12. **Esc stays Blizzard's:** run `/console taintLog 1` and `/reload`. With nothing open, target a mob and press Esc: the target clears. Start a cast and press Esc: the cast stops. In combat, Esc opens the game menu. No "ForeverDuelersGuild has been blocked" popup may appear, and `Logs/taint.log` must not mention ForeverDuel. Then `/console taintLog 0`.

## 3. Results and persistence

1. After each rated duel, `/duelrating history` on both shows the same match ID (starting with `FD3:`) with complementary changes. The overview and `/duelrating summary` agree.
2. With fresh equal ratings at equal levels: +16/-16. Five levels apart: the lower-level winner gains 20, the higher-level winner gains 12.
3. `/reload`, then log out and in again: same totals, no duplicates.
4. Leave the duel boundary in one duel: a RETREAT is rated the same way when both clients see the winner message.
5. Rematch immediately after a finished duel: a new match ID, using the updated rating. Repeat with the receiver accepting the rematch with Blizzard's **Accept** and the other player winning it: the first duel's record must keep its own winner, and the rematch creates no record.
6. Loading screen: right after a rated duel ends, the loser takes a portal or uses the hearthstone (cast started during the duel if possible). Both clients still record the duel with complementary changes, and nobody sees "Your opponent logged out or changed zones".
7. On a disposable character: `/duelrating reset`, then `/duelrating reset confirm` within 15 s, clears ratings and history. Debug and minimap settings stay. Right after a rated duel whose result is still being exchanged (for example declined rematch), reset says "Finish or cancel the pending duel before resetting." until the result has settled (at most 30 s).

## 4. Queue end-to-end

Both clients on 0.6, solo, outdoors in the open world, same faction, ruleset detected (shown in the queue window), and able to discover each other. The queue only reaches players that discovery knows. While the queue searches, discovery asks members of the `ForeverDuel` channel and the online members of your faction in the `ForeverDuelersGuild` community that the search reach covers (**Zone**: your zone; **Continent** and **Whole ruleset**: all), so both clients should show `Zone roster: ForeverDuel channel joined; N members known.` and `Community: ForeverDuelersGuild | ...` in status. Without the channel, open `/duelrating zone` on both and target (or hover over) the other player while the window is open, until each lists the other. Targeting with the zone window closed sends no query.

1. **Tested place:** A and B duel normally at a safe outdoor spot in friendly territory until a knockout. Leave any group. Within 5 minutes and within 40 yd of the spot, A clicks **Save tested place**. A: "Saved <place> here. Sending it to B; waiting for their client to confirm." B: "Saved the tested meeting place shared by A." A: "B saved the same place; it is now on both clients." When B saves the same spot too, both keep one shared record. Negative case: B walks more than 40 yd away first, so A gets "B could not save the place because ...". A duel that ended by retreat does not count.
2. **Happy path:** both open `/duelrating queue`, choose the same reach and level difference, and click **Join queue**. Usually within a minute, the player with the lower GUID (status: `you request the duel`) says "Queue match found: B. Group invitation sent." with a sound. The other gets Blizzard's group invitation plus "Accept the group invitation from A to start your rated queue match.", a sound and the queue window. After accepting, both show the same place and deadline and "Travel to <place> to duel <other>; the waypoint is set." On arrival both say "You and <other> are at the meeting place." Only the inviter's **Request duel** works; the other side reads "Waiting for A to send the duel request." The duel then follows section 1. Afterwards both say "Queue match completed. Join again to play another match." and the group is left automatically within about 15 s. Record the times from join to invitation and from acceptance to travel.
3. **Auto-accept:** the invitee ticks the auto-accept box (or types `/duelrating queue autoaccept on`). The invitation is accepted without a click and the dialog does not decline it.
4. **Decline:** the invitee declines Blizzard's invitation. Both report that the group invitation was declined (on one side possibly as "Your opponent's client cancelled because ..."), followed by "Searching again without <other> for two minutes; your waiting time is kept." They do not pair again for 2 minutes.
5. **Busy (with C):** three clients search at once. Exactly one pair forms and the third keeps searching. A busy refusal only happens when the third client has the lower GUID of its pair and offers a match to a player that is already matched. That player refuses without a chat line (its `diagnose lifecycle` shows `queue invite | busy`); if Blizzard's invitation from the third client reaches it, it may say "Ignore other group invitations; your queue match is with <opponent>." The third client then says "Your opponent's client cancelled because they are already in another queue match. Searching again; your waiting time is kept.", or "<name> is already in another queue match. ..." when the server refuses the native invitation first. A queued player that is itself grouped or invited elsewhere reads "Your opponent's client cancelled because the group invitation could not be sent.", never "they are already in another queue match". Record which line appeared on which client.
6. **Leave:** during travel, B clicks **Leave queue**. B goes idle without an extra chat line. A says "Your opponent's client cancelled because they left the queue. Searching again without B for two minutes; your waiting time is kept." The group is left automatically, and no rating changes. Repeat with B leaving (or typing `/reload`) right when A's group invitation appears and accepting the invitation anyway: A reports the same line within about 10 s and leaves the group; A must never wait 45 s and say "The client of B stopped responding."
7. **Reload or logout:** during travel, B types `/reload`. A says "Your opponent's client cancelled because they reloaded or logged out. Searching again; your waiting time is kept." After the reload B's queue is idle.
8. **No-show:** B stays away until the travel timer runs out. A, who arrived, searches again and keeps the waiting time. B gets "Queue paused for two minutes because you did not reach the meeting place." and cannot join for 2 minutes.
9. **Group changed:** invite a third player into the queue group during travel. Both report the changed group ("The group changed; it is no longer only you and <other>." or the opponent's-client form). The group is not left automatically; the open queue window shows "You are still in a group. Leave it manually if you no longer need it." **Leave group** stays disabled while the third player is in the group (the queue never leaves a group with an unrelated player). Click **Leave queue** (the automatic search waits paused while grouped): the advisory stays. When the third player leaves, **Leave group** enables within a second without reopening the window and leaves the remaining pair group. Once the group is gone, the line and the button disappear by themselves within a few seconds.
10. **Too far:** the inviter clicks **Request duel** more than 10 yd away. The window says "Move within 10 yards of <other> on the same level." and the match continues.

## 5. Discovery, quiet mode and ping

1. With both on one map, open `/duelrating zone`. Within a few seconds (or after **Refresh**) the other player is listed with level, mode and rating. Hovering them shows the rating line in the tooltip. Entries older than 90 s show "last seen N s ago"; a healthy peer never shows it.
2. Status shows `Zone roster: ForeverDuel channel joined; N members known.`, a `Zone channel send: experiment: ... (/<channel number>)` line and `Zone received: <profiles>, <queries>, <channel posts> | own channel echo: ... | channel members known: N`. Record these lines on both clients. With the zone window open on both clients and the characters standing near each other, each must list the other within about 10 s (visible players are asked one at a time; friendly player nameplates help) even if `N` stays 0; if not, record whether `channel posts` stays 0 (CHANNEL not delivered) and then target the other player with the zone window open: both clients must list each other within a few seconds. `Discovery route: CHANNEL broadcasts` appears only after another player's channel post arrived; this route is not yet verified live.
3. `/duelrating quiet` on both. Status shows `Quiet mode: on`, and the `ForeverDuelZone2` Traffic counters stop growing. A rated duel against a visible player still works, and so does `/duelrating ping`. Turn quiet mode off again.
4. **Community directory** (preparation step 8; best with A and B on different internal servers, that is different numbers after `Player-` in their GUIDs, where `channel posts` stays 0):
   1. **Join link and hint** (a fresh Horde character C that is not a member, or A before preparation step 8): log in (not `/reload`). Within about 30 s exactly one chat line appears: "Join the ForeverDuelersGuild community to find duel partners across the whole realm: [Join ForeverDuelersGuild] (hide this hint: /duelrating community hint off)". `/reload`: no second hint. `/duelrating status` shows `Community join link for the Horde: available (/duelrating community join).` Click the yellow link: Blizzard's Communities window opens with the community's invitation and a Join button. Click Join. Within about 10 s `/duelrating community` shows `Community: ForeverDuelersGuild | N members, ...`; log out and in again: no hint any more. Also record: `/duelrating community join` on an Alliance character says "There is no ForeverDuelersGuild community for the Alliance yet, so the addon has no join link for you." and prints no link; `/duelrating community hint off` stops the hint on the next login. Right after a login, `/duelrating diagnose transport` must not show `zone receive | community disabled` or a `community unsupported` before the first `community ok` or `community missing`. No message, invitation or other change from the addon may appear in the Communities window, and the addon never sends the link to anyone (Traffic counters unchanged by `community join`).
   2. `/duelrating community` on both: `Community: ForeverDuelersGuild | N members, M online, K in your zone`, with the other client counted online (and in your zone when you share one). A line `N member names could not be resolved and are skipped` is a FAIL: record how the other character's name appears in the Communities window member list.
   3. **Same zone, out of sight:** stand in the same zone but far apart, so neither is visible to the other. Open `/duelrating zone` on A only. Within about 15 s A lists B, and B's own zone window lists A. `/duelrating diagnose transport` shows `zone receive | community ok` on both and `zone send | first community query` on A.
   4. **Different zones:** B moves to another zone. A's zone window must not list B, and A must not whisper B for the zone window (B's `Zone received` query count stays the same while only A's zone window is open).
   5. **Queue across zones:** both set the reach to **Whole ruleset** and join the queue. Within about a minute both show `Queue profiles: 1 known` in `/duelrating queue status`, and the match continues as in section 4: other members are found across zones while the queue searches. Repeat with **Zone** reach on both, five minutes later: no match forms across zones.
   6. **Offline:** B logs out while A's zone window is open and A searches with **Whole ruleset**. Within about a minute A's `/duelrating community` counts one fewer online, and from then on A's `Zone whisper:` status line never names B.
   7. **Presence without the Communities window:** A types `/reload` and keeps the Communities and Channels windows closed; A opens `/duelrating zone`. B logs out, waits a minute and logs in again, then moves to A's zone. Within about 60 s of each change A's `/duelrating community` must follow (`M online` drops and rises again, `K in your zone` rises when B arrives) and A's zone window lists B. Record the delays. Repeat with A's zone window closed and no queue search: there the counts may lag by up to a minute; record what happens.
   8. **Blizzard's windows keep working:** with A's zone window open, open the Communities window and select another community, then ForeverDuelersGuild: both member lists show online state and zones as usual. Close it and open the Channels window with a community channel selected: its member list works too. After closing both, step 7 must still pass (the addon takes the presence subscription back).
   9. `/duelrating quiet` on A stops the community queries too (Traffic counters stand still); `/duelrating community off` shows `Community: off`, and `/duelrating community on` restores the line. The community is never written to: no message, invitation or other change from the addon appears in the Communities window.
5. `/duelrating ping` with the other player targeted: "PING sent to <other> via WHISPER." and then "PONG from <other> via WHISPER: N.NN s round trip". In a two-player group a PARTY probe runs at the same time. `/duelrating ping Nosuchname` reports "PING to Nosuchname via WHISPER: no such player online." at once.

## 6. German client

Switch one client to German (deDE) and restart it. The German localization is complete, so the rated panel, chat outcome lines, overview, Players in zone, queue window, minimap tooltip, cancellation texts and the zone and queue status lines must all appear in German. Status texts describe what the addon does ("Gegner wird eingeladen"); only steps the player must take are imperatives. Any English user-facing text is a FAIL: record it with the step that showed it. English by design: the duel, transport and traffic lines of `/duelrating status`, the `diagnose` and `errors` entries, debug chat, internal codes such as states and CANCEL reasons, slash commands, and the addon and channel names. There must never be a raw `%s` or `%d` or an empty label. A rated duel between the German and an English client must still finalize, because each client parses the countdown and winner messages in its own language. `/duelrating errors` stays empty.

## 7. Whisper-latency diagnosis

**Symptom:** addon whispers arrive tens of seconds late in both directions, so Rated never becomes available. The chat says "Addon messages to <other> are delayed ...", and `ping` shows a long round trip. Earlier traces showed a constant delay of 29–45 s after the send API had reported success, in order, without loss. Only restarting both clients cured it. Those clients ran on one PC under one Battle.net license, with characters on different home realms.

**Measurement used in every step:** from each client, `/duelrating ping <other>` three times about 10 s apart. Record each round trip, or "No PONG ... within 90 s". Send one ordinary typed whisper each way and note its delay. Collect `/duelrating status` (Traffic lines) and `/duelrating diagnose transport` on both. `/duelrating diagnose lifecycle` shows `session | login` or `session | reload` for each client; note which one applies.

- **E0 baseline:** both clients freshly started. The expected round trip is about 1 s or less.

When an episode starts (round trip over 5 s, or the delay line), run these in order:

- **E1:** `/reload` both clients, wait one minute, measure. Expected: still slow. If it is fast now, report it at once, because client Lua state would then be involved.
- **E3** (while still in the episode): form a two-player group and `/duelrating ping <other>`. It sends a WHISPER and a PARTY probe at the same moment. A fast PARTY with a slow WHISPER means grouping avoids the delay.
- **E2:** fully exit and restart only client A while B stays logged in, then measure from both sides. Both directions fast means the state belonged to A's client session. Only A's pings fast means sender-side state on A. Both still slow means the cause is not a client session (account, realm routing or server).
- **E4:** compare a same-realm pair with a cross-realm pair. The realm number is the digits after `Player-` in the GUID, shown as `Native self` and `Native opponent` in status during a request. Measure both pairs, ideally in the same episode.
- **A/B with quiet mode:** on both, `/duelrating quiet`, `/reload`, wait 2 minutes, ping three times each way and copy the Traffic lines. Then switch quiet mode off, `/reload`, wait 2 minutes and repeat. Compare round trips and the whispers per minute and recipients. Optionally compare about 2 hours of play with the addon disabled against 2 hours with it enabled, watching whether typed whispers become slow.
- **Separate PCs and accounts:** repeat E0–E4 with two independent Battle.net accounts on two different PCs, ideally on different networks. All earlier observations came from one PC and one license.

For every step, report: experiment, time, client, session kind (login or reload), route, the three round trips, the typed-whisper delay, and the WHISPER Traffic lines for `ForeverDuel2`, `ForeverDuelZone2` and `ForeverDuelQ2`.

## Acceptance record

For each case, record PASS, FAIL or NOT TESTED together with the build from `/duelrating status`, both locales, the realm relation (same or cross-realm), the PC and account setup, and the outputs listed above. Sections 1–3 cover the rated flow and should pass on both clients before 0.6 is published. Treat the queue (section 4), the CHANNEL route, the community directory (section 5, step 4) and auto-accept as unverified until their cases have passed live.
