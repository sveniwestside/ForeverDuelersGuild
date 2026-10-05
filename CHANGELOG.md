# Changelog

Notable changes to ForeverDuelersGuild (addon folder `ForeverDuel`), newest first.

Only **0.4.5** has been published on CurseForge (the public Beta). Every other version was a local test build installed on the developer's own test clients and never uploaded. Detailed, dated investigation notes for these versions are archived in [docs/investigations/](docs/investigations/).

## [0.6.0] - unreleased

_Review-driven rework. Simulated in the test suites; the live two-client run ([MANUAL_TESTING.md](MANUAL_TESTING.md)) is still outstanding._

### Breaking

- Rated duels use **protocol 3**. A 0.6 client cannot rate duels against 0.5.x or the published 0.4.5. It recognizes such an opponent, says so in chat and keeps the duel ordinary, so both players must update.
- The queue uses **queue protocol 2** and does not see 0.5.x queue players.
- 0.6 adds new addon files: restart the game completely after updating. Saved ratings and history load unchanged.

### Rated duels

- No separate negotiation timer: both players can use the whole native request window (50 s) to choose Rated.
- Once both players have chosen Rated, the receiver's addon accepts the duel itself. The challenger needs no further confirmation round trip before the countdown.
- Discovery messages back off (0, 1, 3, 7, 15, 31 s) and acknowledgments are rate-limited. A rated choice is re-sent until the duel starts. START and RESULT are repeated, and a client that has already finished answers late results.
- A new challenge made while the previous duel's result is still being exchanged waits for that result, so it uses the updated rating. The winner message of a later duel (for example an unrated rematch) is never taken as the previous duel's result, a duel that ended without a winner message no longer holds the next challenge, and the opponent's cancellation of the previous duel releases the next challenge at once.
- A loading screen (portal, hearthstone, instance) after a rated duel has ended no longer cancels its result exchange; only logout and `/reload` do.
- Challenging the same player again replaces the pending request, and an out-of-range failure allows an immediate retry. A Hardcore duel to the death is never rated. One chat line explains when rated tracking could not attach to a challenge.
- Both players are told why a duel is unrated, including the reason from the opponent's side.

### Duel popup

- Blizzard's duel popup is never hidden or replaced before the addon accepts. The addon panel appears only after the opponent's addon has answered: below the popup for the receiver, and as a separate window for the challenger. It shows how many seconds the request has left.
- Blizzard's **Accept** starts an unrated duel. **Decline** or Esc on the popup refuses the request. Closing the addon panel keeps the duel unrated. Esc closes the challenger's panel through Blizzard's own window handling; the addon no longer registers an Esc handler, which tainted Esc for clearing the target, stopping a cast and the game menu.
- A player who is already in combat when the request begins sees the rated button disabled until combat ends within the request window. Entering combat while a request is pending makes the duel unrated for good.
- At the countdown the chat says `RATED duel vs <name> (win +x / loss -y)` or `This duel is UNRATED: <reason>`.

### Queue

- Invite-first pairing: the player with the lower character GUID sends the group invitation at once, and Blizzard's invitation is the pairing step. Optional auto-accept for the matched opponent (`/duelrating queue autoaccept on`). Declined, busy and expired invitations are recognized.
- Matches use only tested places that both players have. The meeting place is confirmed, or rejected and re-planned. Travel status is exchanged every 3 s over the group, both clients become ready together, and only the inviter requests the duel.
- Every cancellation names its reason, also when it came from the opponent's client. Technical problems requeue you with your waiting time kept. A decision pauses only that pairing for 2 minutes. A missed arrival is judged from your own position.
- Leaving the queue, logging out or reloading tells the opponent at once; a reload while searching also tells recently seen queue players. A client that is no longer queued refuses a late group invitation's match at once, so the inviter does not wait 45 s for it. A **Leave group** button handles a leftover queue group; it follows the roster while the window is open, and leaving the search keeps its advisory.
- A pair that grouped before it could re-key its sessions exchanges its profiles over the group, so slow whispers no longer make the inviter give up after 45 s.
- A group the two players form by hand after a declined or refused queue invitation is no longer left automatically.
- A player whose own group or pending invitation made the server refuse the queue invitation is told that the invitation could not be sent, instead of being told that the opponent is in another match.
- A shared tested place counts as saved on both clients only after the partner's client confirms it. Duplicate records of one spot are merged.

### Discovery

- Discovery runs on demand. Your target and mouseover are asked while the zone window is open or their tooltip shows; targeting with the window closed sends nothing. Channel members are asked while the zone window is open, the queue is searching, or after **Refresh**. There is no nameplate or raid scanning, and no asking during a duel request or a queue match. Queries carry your full profile, map ID included.
- Whispered replies go only to channel members, visible players and queue partners. Channel members that have not reported your map get map 0 in a reply; everyone else in that list gets your real map.
- Once per session your full profile, including your map ID, is posted to every member of the `ForeverDuel` channel to test whether channel messages work. If they do, a post every 60 s and after profile changes replaces per-member whispers. The YELL/SAY beacon and the logged-message route of 0.5.6 are gone.
- The channel is joined after the default chat channels. A password, a ban or a manual leave is detected and shown. Profiles stay valid for 3 minutes, and the browser marks entries older than 90 s (a missed refresh) as "last seen".
- A profile whispered by someone who is neither a channel member, a queue partner nor visible, and who did not answer your own query, is not listed and never receives your queue position. Loading screens no longer reset the 10-minute pause between queries to players without the addon.
- New `/duelrating quiet` stops all discovery traffic. New `/duelrating ping` measures the round trip of an addon message over WHISPER, and over PARTY in a two-player group. Pinging an offline name says so at once. Answers to other players' pings share a small budget, so several pingers cannot slow your own messages.
- All addon messages now go through one paced sender with priorities and a shared whisper budget, so discovery can never delay duel or queue messages.

### Diagnostics

- New `/duelrating errors` shows saved Lua errors with their stack. The chat mentions the first new error once. Errors in the queue window, zone browser, minimap button, player tooltip and in message callbacks are saved too.
- Traffic counters no longer show an old minute as "this minute", and the saved last minute records when it started.
- A client whose duel message formats contain grammar codes says so once at login.
- When the character identity cannot be read, commands say so instead of advising a repair of valid saved data, and `/duelrating repair` retries the start. `/duelrating reset` waits for a previous duel's result that is still being exchanged.
- `/duelrating diagnose lifecycle` and `diagnose transport` show separate saved logs, so message traffic can no longer push out duel evidence. Status and diagnose show traffic counters per addon prefix and route.
- `/duelrating status` shows the installed build, the discovery round trip and the opponent's addon version.

### Saved data

- History stays loadable when rating constants change: each record stores the rules it was calculated with, and loading checks the rating ledger instead of recomputing old matches.
- Saved data of an earlier character with the same name (for example after a Hardcore death) is archived instead of blocking the addon. The overview shows a notice.
- New `/duelrating repair` starts fresh when saved data cannot be read, and keeps the old data under `quarantine`. Reset keeps archives, quarantine and settings.

### Language

- Complete German localization: every user-facing text has a German entry, and status texts describe what the addon is doing instead of reading like instructions. Other client languages show English.
- `tests/locale_spec.lua` fails when a user-facing string has no German entry, a German entry is unused, or placeholders differ, so every new string needs a deDE entry.
- Diagnostic output stays English on purpose: the duel, transport and traffic lines of `/duelrating status`, the `diagnose` and `errors` entries, and debug chat output.

### Development

- Tests run on every push. A CurseForge upload runs only from a `v*` tag in the `curseforge` environment; the workflow stops unless that environment has required reviewers, and the uploader refuses a version without a recorded passed live test (`validation.userReportedTesting`). The release script refuses to upload from uncommitted changes other than the test results its own offline run records, and the release workflow installs the analysis test dependencies it runs.
- `tools/install-addon.ps1` installs a committed build for testers, writes the commit into the installed TOC, backs up the previous copy and verifies the files.

## [0.5.7] - 2026-10-05

_Local Alpha test build; not published._

- Queue grouping now tells party data that is still loading apart from a group that has really changed: missing party identity waits within the existing grouping deadline, while a wrong opponent, a third member or a raid still cancels.
- Cancelling right after the queue invitation is accepted now cleans up the queue-created two-player group correctly and never leaves an unverified or different group.
- Grouping and meeting-place deadlines are also checked when messages arrive, so late messages cannot extend them or start travel early.
- Queue state, group and planning diagnostics survive `/reload` with debug off; rated-duel diagnostics show whether a message never arrived or was rejected early. No message contents, queue tickets, nonces or positions are stored.
- A paired in-game queue retest is still outstanding.

## [0.5.6] - 2026-10-05

_Local Alpha test build; not published._

- Solo rated-duel discovery sends one extra HELLO over the game's logged addon channel after four seconds without an answer; ordinary whisper discovery stays active.
- The logged route is used for the rest of the duel only after the opponent acknowledges the current request through it; a missing API or a failed attempt never cancels ordinary discovery. A confirmed two-player group still prefers PARTY.
- `/duelrating status` shows whether the optional route is available, which route is in use and how long the current request took to be acknowledged.
- Live: the first retest failed; after restarting both clients, solo rated duels completed over ordinary whispers, both with only this addon and with all other addons enabled. The optional logged route was not needed.

## [0.5.5] - 2026-10-05

_Local Alpha test build; not published._

- The addon ignores its own PARTY messages echoed back by the game only when both GUID and sender match the player's own identity; the opponent's messages and diagnostics are unaffected.
- Queue control messages switch to PARTY once the exact two-player queue group is confirmed; discovery profiles, place sharing and solo reservations stay on whispers.
- A whisper fallback is sent once only after the game explicitly rejects PARTY; throttling and unknown results never cause duplicate sends.
- Reservation expiry is checked before late acknowledgments are processed, so an expired match cannot start grouping or restart its invitation timer.

## [0.5.4] - 2026-10-04

_Local Alpha test build; not published._

- Duel messages travel over PARTY when the game confirms a non-raid group of exactly the two duel participants; solo players and changed groups keep using whispers. Ordinary duels never create groups.
- Group membership is rechecked when sending and on every received PARTY message.
- If the game explicitly rejects PARTY, the message is resent once by whisper; other failures never cause duplicate sends.
- Repeated diagnostics are compacted with first/last time and a repeat count, so evidence from a failed attempt survives longer.
- Live: in a two-player group, both clients completed discovery within 1-2 seconds.

## [0.5.3] - 2026-10-04

_Local Alpha test build; not published._

- The challenger sees a waiting dialog as soon as the game acknowledges its duel request; Rated stays disabled until both addons have acknowledged the current request.
- `/duelrating status` and saved diagnostics explain why a received message was rejected (sender, GUID, role, level/cap/class, stale request, expiry, frozen profile) and keep that reason after a manual decline.
- Delayed messages from a cancelled request, even after reversing the duel direction, can no longer attach to the new request, supply consent or change ratings.
- Live: the game delivered addon messages up to about 35 seconds late; this build improves feedback and diagnostics but cannot remove that delay.

## [0.5.2] - 2026-10-04

_Local Alpha test build; not published._

- Fixed outgoing duel-request detection for typed player names (including Forever surnames) and for `/duel` without a name on the current target.
- Duel request and cancellation notices are recognised by their game error identifiers as well as their localized text; the 50-second request limit is kept.
- Queue profiles of enrolled players refresh every five seconds, and the queue shows concrete reasons why no match is possible, including both players' rating windows and missing tested places.
- Tested places can be saved and shared in the six Classic starting zones even when the game returns no territory or level data.
- New `/duelrating diagnose` shows recent request diagnostics even with chat debug off.

## [0.5.1] - 2026-10-04

_Local Alpha test build; not published._

- Fixed: joining the queue no longer fails when no meeting place is configured; the queue explains when a suitable opponent is waiting for a faction-friendly place.
- The ruleset (Normal, PvP, RP, Hardcore) is detected automatically; the manual ruleset selector and scope verification gates are gone, and all search scopes can be selected before joining.
- New **Save tested place** button: after a completed ordinary duel at an outdoor spot, it records the place and shares it with the test partner, whose own duel at that spot must match. Advanced manual capture/import commands remain.
- Queue cancellations never affect rating or history.

## [0.5.0] - 2026-10-04

_Local Alpha test build; not published._

- New opt-in rated-duel queue with a movable panel: choose search reach (zone, continent or whole ruleset) and level tolerance (0-5); players must also share faction, rating pool and level cap.
- The accepted rating gap widens from ±100 to ±200 after two minutes and ±400 after five.
- A matched pair is reserved, one player sends a group invitation, and both travel to a faction- and level-appropriate meeting place with a shared timer (estimates assume running below level 40 and a normal mount from level 40).
- No-shows never change ratings; a confirmed no-show gets a two-minute queue pause, while the player who arrived can requeue.
- Queue duels still use the existing explicit rated consent and result rules; queue state is not kept across reloads.
- Live: the queue panel loaded, but joining failed on the empty meeting-place list (fixed in 0.5.1).

## [0.4.5] - 2026-10-04

**Published on CurseForge as the first public Beta.**

- The addon is now presented as **ForeverDuelersGuild** (titles, tooltip and chat prefix). The addon folder `ForeverDuel`, saved data, `/duelrating` commands and network protocol are unchanged, so no data migration is needed.
- Fixed likely causes of an intermittent repeated-duel failure where only one side showed the rated dialog: a delayed message from a previous duel can no longer occupy the new request, because the opponent is only accepted after echoing the current request's nonce.
- Discovery retries after one second and then every two seconds, within the original 50-second limit.
- If the receiver chose Rated before the challenger finished discovery, that choice is re-sent instead of being lost (it never creates consent).
- `/duelrating status` keeps timestamped outgoing-request diagnostics with debug off.
- Testing of this build was reported complete by the project owner before publication.

## [0.4.4] - 2026-10-04

_Local test build; not published._

- Incoming requests whose challenger cannot be identified immediately no longer stay on the plain WoW dialog: identification is retried every half-second while the request is open, within the 50-second limit, with a chat hint to target the challenger.
- Recovery stops on accept, decline, countdown, completion, expiry, replacement, combat, world transitions or errors; an ambiguous name stays unrated.
- `/duelrating status` shows incoming-request recovery even with debug off.
- Live: three of three duels succeeded; a later intermittent failure was addressed in 0.4.5.

## [0.4.3] - 2026-10-04

_Local test build; not published._

- Automatic player discovery reworked because Forever rejects addon YELL: the addon joins its `ForeverDuel` channel only as a hidden member directory and asks listed players for their profile by addon whisper.
- The directory is refreshed every 30 seconds; each player is asked at most every 45 seconds, and at most one discovery whisper is sent per second.
- After the game rejects YELL, no further YELL attempts are made in that session.
- Adds the `Roster.lua` module: fully restart the game when upgrading from an earlier version.
- Live: automatic discovery found the other test character immediately.

## [0.4.2] - 2026-10-04

_Local test build; not published._

- Automatic discovery sends invisible addon announcements to nearby players via YELL every 15 seconds, without a custom channel, target, group or nameplates.
- Received announcements are accepted on SAY, YELL and Classic's UNKNOWN label and never trigger replies or consent.
- Direct whisper discovery and the dropdown filters are kept.
- Live: Forever rejected addon YELL, so this route did not work; replaced in 0.4.3.

## [0.4.1] - 2026-10-04

_Local test build; not published._

- Players are discovered directly through target, focus, group members and player nameplates using addon whispers when the shared channel does not deliver.
- Joining the channel is optional; requests are paced, retries are bounded and replies never loop.
- Class, rating window, sorting and rated-eligibility filters are dropdown menus instead of cycling buttons.
- Only the nine Classic classes appear in filters and profiles.
- Better empty-list guidance and whisper diagnostics in `/duelrating status`.
- Live: discovery worked after targeting the other character.

## [0.4.0] - 2026-10-03

_Local test build; not published._

- Separate **Leveling** and **Max level** ratings and win/loss records, each starting at 1500; reaching the level cap switches to the max-level rating.
- Earlier ratings and match history are kept in a read-only **Legacy** archive; data that cannot be validated is preserved with rating disabled.
- Rated duels require the same level cap and rating mode and at most five levels difference; other duels stay ordinary.
- Level-weighted Elo (K=32, 20 rating points per level); the consent dialog shows the projected change.
- Players in zone gains name search, class filter, rating window (All, ±100, ±200, ±400), rated-eligible filter and sorting by name, highest or closest rating.
- Progression chart of the latest 40 duels per mode, Leveling/Max level/Legacy views in the overview and levels in match details.
- Both players must update: the rated-duel and discovery protocols are incompatible with older versions.

## [0.3.0] - 2026-10-03

_Local test build; not published._

- New **Players in zone** list (overview and `/duelrating zone`) showing nearby addon users and their ratings, eight per page.
- A Duel button sends the normal WoW duel request after checking the player's identity; rated consent works as before.
- The addon announces itself every 45 seconds through the `ForeverDuel` chat channel; entries expire after 120 seconds.
- Player tooltips show the rating of other addon users.
- Rated-match protocol and saved data are unchanged.

## [0.2.2] - 2026-10-03

_Local test build; not published._

- Custom crossed-swords icon in the addon list.
- Minimap button with tooltip: left-click opens or closes the overview.
- The button can be dragged around the minimap; its position is saved per character.

## [0.2.1] - 2026-10-03

_Local test build; not published._

- Redesigned overview with statistics cards and eight history rows per page.
- Clicking a match shows persistent details for both players, including the opponent's calculated post-match rating and optional spec/outcome labels.
- The movable window scales down to fit smaller screens without changing the UI scale.

## [0.2.0] - 2026-10-03

_Local test build; not published._

- New read-only overview window with your rating, win/loss statistics and paginated match history.
- Match times are shown in local time; the window is movable and closes with Escape.
- Confirmed working in game.

## [0.1.3] - 2026-10-02

_Local test build; not published._

- Fixed player identity on Forever: characters are addressed by their full "Name Surname" (the surname is not a realm) for whispers, unit lookup and duel results.
- The initial four-second addon check now becomes a waiting state instead of failing, so a late reply within the 50-second request limit can still enable Rated.
- Live (2026-10-03): a complete rated duel, the rating change and persistence after `/reload` were confirmed.

## [0.1.2] - 2026-10-02

_Local test build; not published._

- Fixed a discovery race that left one client waiting: each client acknowledges its peer once on becoming ready, so a single late HELLO can complete the handshake.
- Duel request and cancellation notices are also recognised from on-screen UI messages.
- Added diagnostics for request detection.

## [0.1.1] - 2026-10-02

_Local test build; not published._

- The manifest targets the Forever interface version 16001, so the client lists the addon.
- Installation notes warn that some ZIP tools create an extra nested addon folder, which keeps the client from finding the addon.
- No gameplay or protocol changes.

## [0.1.0] - 2026-09-16

_Initial local build; not published. The archived logs do not record its exact version number._

- Opt-in rated duels on top of the ordinary WoW duel: an addon-owned dialog lets each player choose Rated or a normal duel, and both must choose Rated.
- The two addons agree over addon whispers and derive a shared match ID; players without the addon get the ordinary duel.
- A duel only counts after the game's countdown, the duel end and a matching winner on both clients; otherwise it stays unrated.
- Elo rating and match history are stored per character in SavedVariables.
- `/duelrating` commands with optional debug output.
