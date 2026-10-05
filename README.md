# ForeverDuelersGuild

A local 1v1 duel rating addon for **WoW: Forever** (client 1.60.1, interface 16001). You challenge someone with the ordinary WoW duel. When both players run the addon and both explicitly choose **Rated**, the duel counts for a per-character Elo rating with a match history. Everything else stays an ordinary duel. The addon also has a same-zone player browser and an opt-in matchmaking queue.

Current source version: **0.6.0** (not yet published). The public Beta on [CurseForge](https://www.curseforge.com/wow/addons/foreverduelersguild) is 0.4.5, and 0.6 cannot rate duels against it (see [Known limitations](#known-limitations)).

## Installation

- **Players:** copy the `ForeverDuel` folder into `Interface/AddOns`, so the manifest ends up at `Interface/AddOns/ForeverDuel/ForeverDuel.toc` without an extra nested folder. Keep the folder name `ForeverDuel`: the per-character SavedVariable `ForeverDuelDB` belongs to it, and renaming the folder loses access to your rating and history.
- **Testers:** install from a committed checkout with `tools/install-addon.ps1 -AddOnsDirectory "<WoW>\_classic_beta_\Interface\AddOns"`. The script refuses uncommitted addon changes, writes the commit into the installed TOC as `X-Build`, backs up the previous copy and never touches SavedVariables. `/duelrating status` shows the build on its first line.
- 0.6 adds new files. Restart the game client completely after installing; `/reload` is not enough.

Each rating mode (**Leveling** below the level cap, **Max level** at the cap) starts at 1500.

## How a rated duel works

1. Challenge the other player as usual: the unit menu's **Duel**, `/duel`, or the **Duel** button in Players in zone or the queue.
2. The receiver sees Blizzard's normal duel popup. The addon never hides or replaces it before acting.
3. As soon as the opponent's addon answers, a small panel appears. The receiver's panel sits below Blizzard's popup and offers **Accept as RATED duel**. The challenger gets its own panel with **Propose RATED duel** and **Keep unrated**. Players without the addon see nothing extra.
4. Both players click their rated button, in either order. The receiver's addon then accepts the duel itself and closes Blizzard's popup.
5. Blizzard's own **Accept** button starts an **unrated** duel. **Decline** or Esc on the popup refuses the request. Closing the addon panel keeps the duel unrated.
6. At the countdown the chat says either `RATED duel vs <name> (win +x / loss -y)` or `This duel is UNRATED: <reason>`. The other side is told why as well.
7. After the duel both clients must see the same winner. Each client then records the result once, for example `Rated WIN vs <name>: +16 rating (1516).`

The whole decision has to fit into the native request window (50 seconds). Rated duels need the same level cap, the same mode and at most 5 levels difference. Elo uses K=32 and weights each level as 20 rating points. The receiver's addon must see the challenger as a unit (target, mouseover, focus, group or nameplate); if it cannot, it keeps trying while the popup is open and may ask the receiver to target the challenger.

## The queue in brief

`/duelrating queue` opens the queue window. Choose a search reach (zone, continent or the whole ruleset) and a maximum level difference (0–5); the ruleset is detected automatically. Matches also need the same faction, level cap and mode. The rating window widens from ±100 to ±200 after two minutes and ±400 after five.

Matches use **tested meeting places**. After an ordinary duel that ended by knockout at a safe outdoor spot, leave the group and click **Save tested place** within five minutes. The place is sent to your test partner and counts as saved on both clients only when their client confirms.

When two players match, the one with the lower character GUID invites the other at once. Accept Blizzard's group invitation, or turn on auto-accept for queue invitations. Both then travel to a shared place before a 5–15 minute timer runs out. When both have arrived, the inviting player clicks **Request duel**, and both still choose Rated in the duel panel. A cancelled queue match never changes ratings. The window and chat explain every cancellation, also when it came from the opponent's client.

## Commands

| Command | Effect |
| --- | --- |
| `/duelrating` or `/duelrating ui` | Open or close the rating overview. The minimap button does the same. |
| `/duelrating zone` | Players in zone: addon users on your map, with filters and a Duel button. |
| `/duelrating summary` / `history` | Print ratings and recent results / up to 20 rated duels. |
| `/duelrating queue` | Open the queue. `queue join`, `leave`, `status`, `autoaccept on\|off`, `help`. |
| `/duelrating status` | Version and build, duel, transport, discovery and queue state. |
| `/duelrating diagnose [lifecycle\|transport]` | Saved diagnostics, recorded even with debug off. |
| `/duelrating errors` / `errors clear` | Saved addon errors with stack. |
| `/duelrating ping [name]` | Round trip of an addon message to your target or a named player (WHISPER, and PARTY when you two are grouped). |
| `/duelrating quiet` | Toggle quiet mode (below). |
| `/duelrating reset` / `reset confirm` | Delete this character's rating and history (confirm within 15 s). |
| `/duelrating repair` / `repair confirm` | Start fresh when saved data cannot be loaded; the old data is kept under `quarantine`. |
| `/duelrating debug` / `help` | Toggle debug chat output / list all commands. |

## Privacy

There is no server, account or upload. Everything is stored per character in SavedVariables, and ratings are local, unauthenticated self-reports.

- **Rated duel messages** go only to your duel opponent, by whisper or over PARTY when you two are alone in a group. They contain both GUIDs, your level, cap, class, specialization ID, current-mode rating and win/loss record, the addon version, request nonces and the winner.
- **Zone discovery** joins the chat channel `ForeverDuel` as a member directory. It asks for profiles only on demand: your target or mouseover when you look at them, and channel members while the zone window is open, the queue is searching, or after **Refresh**. It never asks during a duel request or a queue match. A profile holds GUID, rating, class, level, cap and map ID, and strangers get map 0. Replies go only to channel members, visible players and queue partners. Once per session one profile is posted to the channel to test whether channel messages work.
- **The queue** whispers a profile to discovered addon users while you search. It contains your faction, ruleset, rating, level, search settings, map, continent, rounded world position and short hashes of your tested places. During a match your position goes to your opponent only.
- **Quiet mode** (`/duelrating quiet`) stops every discovery and channel-directory send: no queries, replies, broadcasts, channel joins or roster loading. `ping` still works. Rated duels and the queue keep their own messages, but the queue only reaches players that discovery already knows.
- **Diagnostics** stay on your computer. They hold names and GUIDs of recent opponents, but never message contents, nonces, queue tickets or positions.

## Known limitations

- **Protocol 3 is incompatible with 0.5.x and 0.4.5.** Both players need 0.6 for rated duels. A 0.6 client recognizes an older opponent, says so in chat, and the duel stays ordinary. The 0.6 queue (protocol 2) does not see 0.5.x queue players.
- **Not yet verified in the live client:** the CHANNEL broadcast route, queue auto-accept, and the invite-first queue from start to finish. The 0.6 rated flow itself also needs the two-client run in [MANUAL_TESTING.md](MANUAL_TESTING.md).
- **Delayed addon whispers:** in earlier live tests, whispers between two clients arrived 30–45 seconds late in both directions, and only a restart helped. The cause is unknown. A late answer can miss the 50-second request window. Measure with `/duelrating ping`; MANUAL_TESTING.md lists the experiments.
- Results depend on the client's localized countdown and winner messages. Locales that use grammar codes in these strings (for example Korean or Russian) may not finalize, and such duels stay unrated.
- There is no atomic two-client commit. If the last RESULT message is lost, or a player logs out while results are exchanged, one client can record a duel that the other does not.
- Ordinary 1v1 duels only. A Hardcore duel to the death is never rated.

**Language:** the interface follows the client language. German clients use the German texts in `Locale_deDE.lua`, and any missing translation falls back to English. Some diagnostic output stays English.

## More documentation

- [CHANGELOG.md](CHANGELOG.md): changes per version.
- [ARCHITECTURE.md](ARCHITECTURE.md): modules, protocols, timings and safety rules.
- [MANUAL_TESTING.md](MANUAL_TESTING.md): the two-client test checklist and the latency experiments.
- [docs/README.md](docs/README.md): index of all documents. The [investigation logs](docs/investigations/) are dated history up to 0.5.7, not current behaviour.
- [web/README.md](web/README.md): the separate local website prototype. The addon never talks to it.

## Development

The addon has no runtime dependencies. The tests run the real Lua 5.1 modules against simulated clients:

```sh
python -m pip install --target .test-deps lupa
python tests/run.py
python -m unittest discover -s tests -p "test_*.py"
```

`lua5.1 tests/run.lua` works without Python. CI runs the same suites on every push. Uploads to CurseForge go through the gated [release pipeline](docs/curseforge/RELEASE_PIPELINE.md).

Released under the [MIT License](LICENSE).
