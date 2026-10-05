# ForeverDuelersGuild

A local 1v1 duel rating addon for **WoW: Forever** (client 1.60.1, interface 16001). When both players run the addon and both explicitly choose **Rated** for an ordinary WoW duel, it counts for a per-character Elo rating with a match history. The addon also has a same-zone player browser and an opt-in matchmaking queue.

**Finding other players:** join the in-game community **ForeverDuelersGuild** (Communities window, invitation or invite link from a member). It is the only route that connects addon users across the whole Forever mega-realm; the addon only reads its member list and never posts in it.

Source version **0.6.0** is unpublished. The public [CurseForge](https://www.curseforge.com/wow/addons/foreverduelersguild) Beta is 0.4.5, which 0.6 cannot rate against.

## Installation

- Copy the `ForeverDuel` folder into `Interface/AddOns` (manifest at `Interface/AddOns/ForeverDuel/ForeverDuel.toc`). Keep the folder name: the per-character SavedVariable `ForeverDuelDB` belongs to it.
- Testers install a committed build with `powershell -ExecutionPolicy Bypass -File tools\install-addon.ps1 -AddOnsDirectory "<WoW>\_classic_beta_\Interface\AddOns"`; `/duelrating status` shows its commit, and SavedVariables stay untouched.
- 0.6 adds new files: restart the game client completely after installing.

## Rated duels

Challenge as usual; Blizzard's popup is never hidden or replaced before the addon acts. Once the opponent's addon answers, a panel offers **Accept as RATED duel** to the receiver and **Propose RATED duel** or **Keep unrated** to the challenger. When both have clicked Rated, in either order, the receiver's addon accepts the duel. Blizzard's **Accept** starts an unrated duel, and **Decline** or Esc refuses it.

At the countdown the chat says whether the duel is rated, and a result counts only when both clients see the same winner. Everything must fit into the native 50-second request window. Rated duels need the same level cap and mode (**Leveling** below the cap, **Max level** at it, each starting at 1500) and at most 5 levels difference. Details: [ARCHITECTURE.md](ARCHITECTURE.md).

## Queue

In the queue window (`/duelrating queue`), choose a search reach and level difference. Matches use **tested meeting places**: after an ordinary duel that ended by knockout at a safe outdoor spot, leave the group and click **Save tested place** within five minutes. When two players match, the one with the lower character GUID sends a group invitation, both travel to a shared place within 5–15 minutes, and the inviter clicks **Request duel**. Both still choose Rated, and a cancelled queue match never changes ratings.

## Commands

`/duelrating` (or the minimap button) opens the rating overview. Subcommands:

- `zone`: Players in zone, with filters and a Duel button.
- `community [name|on|off]`: status of the community used as player directory (default `ForeverDuelersGuild`), choose another one or turn it off.
- `summary` / `history`: ratings and recent results / up to 20 rated duels.
- `queue`: the queue window; `queue join`, `leave`, `status`, `autoaccept on|off`, `help`.
- `status`, `diagnose [lifecycle|transport]`, `errors [clear]`: current state, saved diagnostics, saved addon errors.
- `ping [name]`: addon message round trip to your target or a named player.
- `quiet`: toggle quiet mode (below).
- `reset` / `repair`: delete this character's rating / start fresh after unreadable saved data (each asks for `confirm`).
- `debug` / `help`: toggle debug chat output / list all commands.

## Privacy

No server, account or upload: everything is stored per character in SavedVariables, and ratings are unauthenticated self-reports. [ARCHITECTURE.md](ARCHITECTURE.md#discovery-presence-roster-and-community) lists every message.

- **Rated duels** message only your opponent (whisper, or PARTY when you two are alone in a group): GUIDs, level, cap, class, spec, rating, record, addon version, nonces and the winner.
- **Discovery** profiles hold GUID, rating, class, level, cap and map ID. Queries carry your full profile and are whispered on demand only: to your target or mouseover while the zone window is open or their tooltip shows, to other visible players of your faction while the zone window is open (one at a time, each at most every 10 minutes), to `ForeverDuel` channel members while the zone window is open or the queue searches, and to online members of your faction in the directory community: those in your zone while the zone window is open, and everyone the queue's reach covers while it searches. On the Forever mega-realm the channel only connects characters of the same internal server (the number in their GUID); the community connects all of them. Every query is answered, because only addon users send one; the reply carries your real map only to visible players, queue partners and senders that reported the same map themselves, everyone else gets map 0.
- **The community** is only read: its member list (names, GUIDs, online state, zone, level, class, faction) stays in memory and is never saved. The addon never posts in it, invites or joins; you join and leave it yourself in the Communities window.
- **Channel posts reach every member of the `ForeverDuel` channel** with your full profile, map ID included: once after joining, then every 60 s while the zone window is open or the queue searches, and after changes while that route works.
- **The queue** whispers your GUID, faction, ruleset, rating, level, search settings, map, continent, world position (whole yards) and tested-place hashes to discovered addon users while you search: channel members, visible players, queue partners and players who answered or sent a discovery query, never to someone who only whispered you a plain profile. During a match your position goes to your opponent only.
- **Quiet mode** stops every discovery and channel send, including the queries to community members. `ping` and rated duels keep working; the queue then reaches only players discovery already knows.
- **Diagnostics** stay on your computer and hold opponents' names and GUIDs, never message contents or positions.

## Known limitations

- Both players need 0.6 (rated protocol 3, queue protocol 2); older versions get ordinary duels.
- The 0.6 rated flow, CHANNEL route, community directory and queue await the live two-client run in [MANUAL_TESTING.md](MANUAL_TESTING.md), which also covers the 30–45 s whisper delays seen earlier.
- Results are read from localized system messages; locales with grammar codes in them (Korean, Russian) may stay unrated.
- No atomic two-client commit: if the last result message is lost, one client can record a duel the other does not.
- Ordinary 1v1 duels only; a Hardcore duel to the death is never rated.

## Language

German clients are fully translated; other languages show English. Diagnostic output stays English on purpose: the duel, transport and traffic lines of `status`, the `diagnose` and `errors` entries, debug chat and internal codes.

## More documentation

[CHANGELOG.md](CHANGELOG.md), [ARCHITECTURE.md](ARCHITECTURE.md) (modules, protocols, timings, localization), [MANUAL_TESTING.md](MANUAL_TESTING.md) (live test checklist) and [docs/README.md](docs/README.md) (index of all documents, including the website prototype).

## Development

No runtime dependencies. The tests run the real Lua 5.1 modules against simulated clients (`lua5.1 tests/run.lua` also works):

```sh
python -m pip install --target .test-deps lupa
python tests/run.py
python -m unittest discover -s tests -p "test_*.py"
```

Every new user-facing string needs a German entry in `ForeverDuel/Locale_deDE.lua` (enforced by `tests/locale_spec.lua`). CI runs the suites on every push; CurseForge uploads use the gated [release pipeline](docs/curseforge/RELEASE_PIPELINE.md).

Released under the [MIT License](LICENSE).
