# Two-client test checklist (0.6)

The Lua suites simulate two or more clients with latency, loss and throttling. They cannot show how the real client routes events, protects actions or delivers whispers, so this checklist exercises that part. Mark each case **PASS**, **FAIL** or **NOT TESTED**. A simulation never counts as a live PASS.

Roles: **A** challenges, **B** receives, unless a step says otherwise. **C** is an optional third client. Refer to the clients only as A, B and C in reports.

## 0. Preparation

1. Commit the source. On each PC run `tools/install-addon.ps1 -AddOnsDirectory "<WoW>\_classic_beta_\Interface\AddOns"` from the same commit. Keep the JSON it prints (`version`, `build`, `savedVariablesModified: false`).
2. Restart both game clients completely. 0.6 adds new files, and `/reload` does not load them.
3. On both clients, `/duelrating status` must start with `Version: 0.6.0 (<build>) | Addon transport: registered`. `<build>` must be the same on both and equal `git rev-parse --short=12 HEAD`. There must be no `Saved data: unavailable` line, and the state must be `IDLE`.
4. Back up `WTF/Account/<account>/<realm>/<character>/SavedVariables/ForeverDuel.lua` on both PCs.
5. Run `/console scriptErrors 1` and `/duelrating errors clear`. Leave debug off (`Debug: disabled` in status).
6. Note for each client: PC, Battle.net account, locale, other enabled addons, and the home realm number (the digits after `Player-` in the character GUID).
7. For rated cases: same faction, same level cap, same mode (both below the cap or both at it), at most 5 levels apart, outside combat, where duels are allowed.

## What to collect when something fails

Do this on **both** clients before starting another request or reloading:

1. `/duelrating status`: copy every line. The most important are `Version`, `State`, `Traffic`, `Native request`, `Peer confirmation`, `Discovery round trip`, `Last send`, `Last receive`, `Peer validation`, `Last pending rejection`, `Zone discovery`, `Discovery route` and the `Queue` lines.
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
2. **Keep unrated:** A clicks **Keep unrated**. Both say "This duel will be UNRATED: ...". B's panel closes, Blizzard's popup stays, and B can still accept an ordinary duel. Repeat with A pressing Esc on its panel, and with B closing its panel with the X.
3. **Decline and Esc:** B clicks **Decline** on Blizzard's popup; on a second request B presses Esc. The request ends on both sides, and A may say "This duel will be UNRATED: The duel request was cancelled." Both return to `IDLE`, and A can challenge again at once.
4. **Combat:** (a) With the panel open, B enters combat. Both say "This duel will be UNRATED: Combat started." (b) B is already in combat when the request arrives: the rated button is disabled and the panel says "Leave combat to choose a rated duel." When B leaves combat within the window, the button works again.
5. **Out of range, then retry:** A challenges B from beyond duel range and notes the exact error text. A moves closer and challenges B again within a few seconds. The second request must be tracked normally: the panel appears, Rated works, and there is no "Rated tracking could not attach" line. The failure IDs behind this are not verified live, so record the error text.
6. **Outdated peer:** install 0.5.7 or 0.4.5 on B and challenge in both directions. A (0.6) says once "Your opponent uses an older ForeverDuel version. Rated duels need version 0.6 or newer on both sides.", and status shows `Peer addon: outdated (protocol 2)`. The duel stays ordinary on both. Reinstall 0.6 on B and restart the client afterwards.
7. **Not eligible:** 6 levels apart, or one character at the cap and one below it. No panel appears. A known addon user gets a reason such as "Rated unavailable: players must be within 5 levels of each other".
8. **Expiry:** nobody clicks the panel. After 50 s the panel closes and the chat says "This duel will be UNRATED: The request expired." Blizzard's popup keeps its own timer and can still start an ordinary duel.
9. **Challenger not visible:** B clears target and focus, turns nameplates off and moves the mouse away. A challenges. If A is a known addon user, B sees "Rated duel pending: target the challenger ...". Targeting A within 50 s brings the panel.
10. **Reload during a request:** A types `/reload` while the panels are open. B says "This duel will be UNRATED: Your opponent logged out or changed zones."
11. **Accept without a duel:** if a duel ever fails to start after the addon's accept, both clients report it within 8 s, and B sees "If no duel started, ask A to challenge you again." Collect the outputs.

## 3. Results and persistence

1. After each rated duel, `/duelrating history` on both shows the same match ID (starting with `FD3:`) with complementary changes. The overview and `/duelrating summary` agree.
2. With fresh equal ratings at equal levels: +16/-16. Five levels apart: the lower-level winner gains 20, the higher-level winner gains 12.
3. `/reload`, then log out and in again: same totals, no duplicates.
4. Leave the duel boundary in one duel: a RETREAT is rated the same way when both clients see the winner message.
5. Rematch immediately after a finished duel: a new match ID, using the updated rating.
6. On a disposable character: `/duelrating reset`, then `/duelrating reset confirm` within 15 s, clears ratings and history. Debug and minimap settings stay.

## 4. Queue end-to-end

Both clients on 0.6, solo, outdoors in the open world, same faction, ruleset detected (shown in the queue window), and known to each other through discovery (open `/duelrating zone` or target each other).

1. **Tested place:** A and B duel normally at a safe outdoor spot in friendly territory until a knockout. Leave any group. Within 5 minutes and within 40 yd of the spot, A clicks **Save tested place**. A: "Saved <place> here. Sending it to B; waiting for their client to confirm." B: "Saved the tested meeting place shared by A." A: "B saved the same place; it is now on both clients." When B saves the same spot too, both keep one shared record. Negative case: B walks more than 40 yd away first, so A gets "B could not save the place because ...". A duel that ended by retreat does not count.
2. **Happy path:** both open `/duelrating queue`, choose the same reach and level difference, and click **Join queue**. Usually within a minute, the player with the lower GUID (status: `you request the duel`) says "Queue match found: B. Group invitation sent." with a sound. The other gets Blizzard's group invitation plus "Accept the group invitation from A to start your rated queue match.", a sound and the queue window. After accepting, both show the same place and deadline and "Travel to <place> to duel <other>; the waypoint is set." On arrival both say "You and <other> are at the meeting place." Only the inviter's **Request duel** works; the other side reads "Waiting for A to send the duel request." The duel then follows section 1. Afterwards both say "Queue match completed. Join again to play another match." and the group is left automatically within about 15 s. Record the times from join to invitation and from acceptance to travel.
3. **Auto-accept:** the invitee ticks the auto-accept box (or types `/duelrating queue autoaccept on`). The invitation is accepted without a click and the dialog does not decline it.
4. **Decline:** the invitee declines Blizzard's invitation. Both report that the group invitation was declined (on one side possibly as "Your opponent's client cancelled because ..."), followed by "Searching again without <other> for two minutes; your waiting time is kept." They do not pair again for 2 minutes.
5. **Busy (with C):** three clients search at once. Exactly one pair forms and the third keeps searching. If C reports "<name> is already in another queue match.", record it.
6. **Leave:** during travel, B clicks **Leave queue**. B goes idle without an extra chat line. A says "Your opponent's client cancelled because they left the queue. Searching again without B for two minutes; your waiting time is kept." The group is left automatically, and no rating changes.
7. **Reload or logout:** during travel, B types `/reload`. A says "Your opponent's client cancelled because they reloaded or logged out. Searching again; your waiting time is kept." After the reload B's queue is idle.
8. **No-show:** B stays away until the travel timer runs out. A, who arrived, searches again and keeps the waiting time. B gets "Queue paused for two minutes because you did not reach the meeting place." and cannot join for 2 minutes.
9. **Group changed:** invite a third player into the queue group during travel. Both report the changed group ("The group changed; it is no longer only you and <other>." or the opponent's-client form). The group is not left automatically; the queue window says "You are still in a group. Leave it manually if you no longer need it."
10. **Too far:** the inviter clicks **Request duel** more than 10 yd away. The window says "Move within 10 yards of <other> on the same level." and the match continues.

## 5. Discovery, quiet mode and ping

1. With both on one map, open `/duelrating zone`. Within a few seconds (or after **Refresh**) the other player is listed with level, mode and rating. Hovering them shows the rating line in the tooltip. Entries older than 45 s show "last seen N s ago".
2. Status shows `Zone roster: ForeverDuel channel joined; N members known.` and a `Zone channel send: experiment: ...` line. Record that line. `Discovery route: CHANNEL broadcasts` appears only after another player's channel post arrived; this route is not yet verified live.
3. `/duelrating quiet` on both. Status shows `Quiet mode: on`, and the `ForeverDuelZone2` Traffic counters stop growing. A rated duel against a visible player still works, and so does `/duelrating ping`. Turn quiet mode off again.
4. `/duelrating ping` with the other player targeted: "PING sent to <other> via WHISPER." and then "PONG from <other> via WHISPER: N.NN s round trip". In a two-player group a PARTY probe runs at the same time.

## 6. German client

Switch one client to German (deDE) and restart it. The rated panel, chat outcome lines, overview, Players in zone, queue window and cancellation texts must appear in German where a translation exists, and in English otherwise. There must never be a raw `%s` or `%d` or an empty label. A rated duel between the German and an English client must still finalize, because each client parses the countdown and winner messages in its own language. `/duelrating errors` stays empty. Some diagnostic lines are English by design.

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

For each case, record PASS, FAIL or NOT TESTED together with the build from `/duelrating status`, both locales, the realm relation (same or cross-realm), the PC and account setup, and the outputs listed above. Sections 1–3 cover the rated flow and should pass on both clients before 0.6 is published. Treat the queue (section 4), the CHANNEL route and auto-accept as unverified until their cases have passed live.
