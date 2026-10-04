# ForeverDuelersGuild: Phase 1 implementation status

## Local web design and backend foundation, 2026-10-04

The user requested a local backend and website, then prioritized the design and explicitly requested official WoW class icons, Blizzard profile enrichment and a less generic presentation. The separate `web/` project now presents a duel register: a compact dark identity header, warm light surfaces, fine table rules, a prominent ladder and a chronological duel log beside it. The large marketing hero and abstract arena artwork are no longer part of the page. The nine original class icons were downloaded directly from Blizzard's render CDN and converted to PNG without changing decoded pixels; source URLs and checksums are retained in `web/public/assets/classes/manifest.json`, with attribution in `assets/branding/WOW_ASSETS.md` and the website footer. The design-only preview runs at `http://localhost:8788/?preview=1` with explicitly labeled sample data. Its sample reports are separate from persistent backend records. `web/README.md` contains the local run instructions.

The local Node.js/SQLite foundation provides public ladders, profiles and match history, GUID-bound upload tokens, strict schema-2 imports, bilateral report reconciliation and deterministic central Elo replay in separate mode/level-cap pools. The safe standard-library Python exporter parses SavedVariables without executing Lua or altering the source. No addon Lua, manifest, installed client data or public CurseForge artifact was changed for this work. The addon still uses its existing local ratings; automatic uploads and in-game central-rating synchronization are not implemented.

The user approved the register design and requested a dark-mode switch and English as the default. Website copy, accessible labels, class names, errors, forms and preview states are now English, with `en-GB` number/date formats and the same default Blizzard data locale. The header sun/moon toggle changes all register, chart, profile, modal and import colors. The first visit follows the system color preference; an explicit selection is saved locally and applied by `theme.js` before the stylesheet loads. Logic checks covered initial selection, system changes, persistence/reload, invalid preferences, unavailable storage, cross-tab changes and the accessible pressed state. Syntax and the existing 22 backend tests passed. Full browser rendering remains unverified because of the local URL block recorded below.

A server-side Blizzard client now supports OAuth client credentials, bounded requests, token renewal, coalesced requests, a five-minute profile cache and short failure caching. Optional profile, media and equipment data are returned separately from the duel identity and ratings. Administrator mappings require explicit API IDs, region, namespace, realm slug and full character name; no GUID or surname inference is used. A profile must match IDs, realm slug, name and class before enrichment is exposed. Armory links are only created for verified retail responses; Classic is not sent to retail Armory. Credentials remain in local environment configuration, never in public responses or browser code. `.env.example` documents the settings and npm commands load the optional ignored `.env` file.

**Forever API support remains unverified.** The default `BLIZZARD_GAME=forever` performs no speculative upstream calls and the profile explains the unavailable integration. No real API credentials were supplied and no live authenticated character lookup was claimed. The verified public OAuth metadata and official Classic API announcement are linked in `web/README.md`; they do not establish Forever support.

Validation: **22 backend tests pass**, including the original import/rating checks and mocked Blizzard OAuth, caching, identity, mapping, media and HTTP integration cases. The previous **23 parser/export tests** and synthetic bilateral exporter-to-backend check remain applicable because their implementation did not change. That check produced one confirmed match, two players at 1516/1484 and an unchanged duplicate re-import. Local HTTP checks after restarting the updated backend returned a healthy, empty real database and the explicit unverified-Forever integration state. The redesigned HTML, CSS, JavaScript, preview fixtures and all nine class images returned HTTP 200 with correct types. Static checks confirmed 38 unique HTML IDs, all 30 direct JavaScript ID references, local resources and JavaScript syntax; targeted date, win-rate and URL checks passed. Official icons were visually inspected. The in-app browser explicitly blocked local URL access; no full-page visual or browser interaction QA is claimed. Public deployment, native character ownership verification, anti-abuse controls and release readiness remain separate work.

## Public name correction before first publication, 2026-10-04

CurseForge project **1726452** was created under the signed-in `sveniwestside` account. The user's explicit preference to restrict distribution to the CurseForge ecosystem is saved as **Don't allow distribution to 3rd party**; MIT remains the project license. The first `ForeverDuelersGuild-0.4.5.zip` upload has file ID **9058783**, Beta type, and WoW Forever 1.60.1 selected. On **2026-10-04**, the user authorized publication and the manual Publish action completed. The author file page reports **Approved**, and its Publish button is gone. The [public project page](https://www.curseforge.com/wow/addons/foreverduelersguild) and [public file page](https://www.curseforge.com/wow/addons/foreverduelersguild/files/9058783) load; the public Files list confirms Beta 0.4.5 for Forever 1.60.1, and the project page shows the Roadmap 1.0. The author file page is <https://authors.curseforge.com/#/projects/1726452/files/9058783>.

The public browser download from the [download page](https://www.curseforge.com/wow/addons/foreverduelersguild/download/9058783) was verified on **2026-10-04**: 79,462 bytes, 21 ZIP entries, successful CRC validation, and byte-for-byte equality with the prepared package. SHA-256: `477af26f532a4c5a23218ff117825f9162db3c5ca12c81b47dd9504cabe18679`. The downloaded manifest confirms title ForeverDuelersGuild, version 0.4.5 and interface 16001. Evidence is saved in `dist/curseforge-0.4.5/public-download-verification.json`. Installation in the game or CurseForge app has not been tested; `installationVerified` remains false.

The user corrected the public addon and project name to **ForeverDuelersGuild** while the 0.4.5 release was still unpublished. The first Beta package is now named `dist/curseforge-0.4.5/ForeverDuelersGuild-0.4.5.zip`. The version remains 0.4.5. The technical installation folder `ForeverDuel`, manifest `ForeverDuel.toc`, `ForeverDuelDB` SavedVariable, `/duelrating` commands, channel, and protocol identifiers remain compatible; no data migration is required for the public name correction.

The original `ForeverDuel-0.4.5.zip` path and SHA-256 recorded in the implementation entry below identify the earlier, historically verified build under its former public name. They are not verification results for the renamed publication package. The test-completion conclusion below remains the same general user confirmation; the name correction adds no per-case gameplay results.

The renamed package was built and verified on 2026-10-04: 21 ZIP entries, 18 manifest-listed Lua modules, archive SHA-256 `477af26f532a4c5a23218ff117825f9162db3c5ca12c81b47dd9504cabe18679`. The Lua 5.1 suite was rerun after the visible branding changes: 33 files compile, 14 suites and 4,551 assertions pass. The project name, in-game titles, tooltip, and chat prefix use ForeverDuelersGuild; persistence and protocol identifiers remain unchanged. Project creation, file upload, and the confirmed distribution preference are recorded above.

## Test completion and Beta preparation, 2026-10-04

The user confirmed that testing of the current 0.4.5 build was complete ("testing ist soweit abgeschlossen") and approved the proposed release preparation and first Beta publication. Phase 1's current test round is **completed (user-confirmed)**, and the first Beta publication and public download validation are now complete. The next steps are installation validation followed by feedback from additional players. This is a general test conclusion: no new per-case results, attempt counts, paired saved records, or logs were supplied. It does not establish all compatibility and failure scenarios as PASS. [MANUAL_TESTING.md](../MANUAL_TESTING.md) retains the procedures and evidence limits for regression testing and wider Beta coverage.

The historical 0.4.4 recurrence and its unconfirmed cause remain recorded below. The current test round is complete, with the detailed checklist retained for future regression and coverage. Shared rankings, a backend, server rating authority, uploader, and website remain future Phase 2 work requiring explicit planning.

## Version 0.4.5: repeated-duel discovery recovery, 2026-10-04

**Historical trigger:** after the three successful 0.4.4 duels recorded below, the user reported that the fourth request showed the ForeverDuel dialog only on the receiver; the challenger could not propose rated. A subsequent duel succeeded. Status from the failed request was no longer available. This is an intermittent recurrence, not evidence that all 0.4.4 requests fail or that debug controls the behavior. The later user-confirmed general 0.4.5 test completion is recorded above.

Local reproduction identified two candidate causes: a delayed prior `HELLO` could bind an unproved peer nonce and block the new request; losing early incoming-to-outgoing acknowledgments could leave the challenger waiting after its only retry. Version 0.4.5 answers unbound `HELLO` without binding identity/profile/match ID, requiring `HELLO_ACK` to echo the current local nonce first. Discovery sends initially, after one second, then every two seconds only while the same session remains in `CHECKING_ADDON` or `DISCOVERY_WAIT`, within its original 50-second limit. A response to a current-peer discovery retry may resend an already explicit `ACCEPT`, covering receiver consent before the challenger reaches READY without creating consent or extending its deadline.

`/duelrating status` retains timestamped outgoing-request diagnostics with debug off. Confirmed native cancellation/finish and world lifecycle clear outgoing capture/quarantine state. Local accept/cancel hooks and adapter errors discard the captured candidate but retain its original acknowledgment ambiguity window, preventing a delayed unqualified native notice from confirming a rapid replacement request. Native acknowledgment, bilateral consent, protocol 2, schema 2, rating, and directory discovery remain unchanged.

Validation: **33 Lua files compile; 14 suites; 4,551 assertions pass** with `python tests/run.py` under Lua 5.1, including 555 adapter and 1,580 duel assertions. Regressions cover bounded discovery retries, delayed prior `HELLO`, early receiver consent, the local-action ambiguity barrier, and pending outgoing capture invalidation on native countdown/combat. These are simulations; the exact cause of the user's failed live request remains unconfirmed. The focused [manual checks](../MANUAL_TESTING.md) cover repeated rematches, receiver-first consent, debug-off status capture before the next request, and terminal/ordinary paths.

The existing `C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\ForeverDuel` installation was updated to 0.4.5 and all 21 source files matched SHA-256 after copying. The prior 0.4.4 folder is backed up under `dist/installation-backups/classic-beta-before-0.4.5-caafb26518b0424988168f87eb41d6df/ForeverDuel`. SavedVariables were not changed. Both running clients need `/reload`; no manifest module was added. The package `dist/curseforge-0.4.5/ForeverDuel-0.4.5.zip` was built and verified with 21 entries and 18 manifest-listed Lua modules; SHA-256 is `a7397ee1978b32e2a8366886935bb1e1160c6f39c91e6b0d0436127bdd2a2040`. No upload or publication was performed.

## Version 0.4.4: incoming identity recovery, 2026-10-04

The user reports intermittent incoming requests with only the ordinary WoW dialog and suspects disabling debug. Review found no gameplay branch controlled by the debug setting; previous automated suites already ran with debug disabled. A separate code-path gap was identified: an incoming name without an immediately resolvable native unit ended addon handling, even if the challenger became targetable moments later. This is a plausible cause of the reported symptom, not a confirmed diagnosis of that live occurrence.

An unresolved incoming request now retains its native name and original timestamp, prints a target-the-challenger hint independent of debug logging, and retries identity resolution every 0.5 seconds while the same readable native popup remains visible, outside combat and within the original 50-second pending limit. Resolution still requires native identity and bilateral consent. Observed name ambiguity is terminal; acceptance, decline/cancellation, countdown, finish, replacement, transition/logout, combat, and errors clear pending recovery. Missing popup visibility support preserves ordinary play. `/duelrating status` reports incoming recovery even with debug off. Schema 2, rated protocol 2, rating rules, and directory discovery are unchanged.

Validation: **33 Lua files compile; 14 suites; 4,102 assertions pass** with `python tests/run.py` under Lua 5.1 (including 338 adapter assertions; previous total 4,000). The delayed-identity regression failed before the fix. Two simulated clients complete an explicitly agreed rated duel after debug is switched on then off and the receiver's identity resolution initially fails; lifecycle and ambiguity guards are covered. These are simulation results, not confirmation that the reported live occurrence has the same cause.

The existing `C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\ForeverDuel` installation was updated to 0.4.4 and all 21 source files matched SHA-256 after copying. The prior folder is backed up under `dist/installation-backups/classic-beta-before-0.4.4-d9fd7eec88eb49f89842f75044678805/ForeverDuel`. SavedVariables were not changed. Both running clients need `/reload` to load the update from 0.4.3; no new manifest module was added. The package `dist/curseforge-0.4.4/ForeverDuel-0.4.4.zip` was built and verified with 21 entries and 18 manifest-listed Lua modules; SHA-256 is `483a2e400a9a115916bf5fbcbe7746e339f47c0ec4f065edcd54471d1f00c088`. No upload or publication was performed.

Live follow-up on 2026-10-04: after the 0.4.4 installation and retest instructions, the user reported "okay ist glaub ich stabil 3/3 duelle haben funktioniert". Retain **3/3 successful duels, PASS (user-reported happy path)** as the initial result. The fourth request subsequently failed on the challenger side while the receiver had the addon dialog; another duel then succeeded. That recurrence remains historical evidence; the subsequent general 0.4.5 test-completion confirmation is recorded above. The exact debug setting, late-identity recovery route, and paired saved records were not separately confirmed.

[API_VERIFICATION.md](API_VERIFICATION.md) records the pinned Retail popup helper source and the remaining Forever availability check. The focused [manual retest](../MANUAL_TESTING.md) retains debug off/on, late targeting, accept/decline, expiry, lifecycle cleanup, and ambiguous-identity cases for separate verification. The earlier 0.4.3 automatic-discovery confirmation below remains valid for that reported test pair.

## Version 0.4.3: native directory and whisper discovery, 2026-10-04

The 0.4.2 in-game screenshot rejected every YELL attempt with result 4. Matching Forever source identifies this as `InvalidChatType`; the previous transfer of Classic broadcast behavior to Forever was incorrect. The user then confirmed that channel 6 maps to display row 9, initially has no readable member, and returns `Tester B` plus a player GUID after selecting row 9 and waiting two seconds. Direct profile whispers already have live evidence.

`Roster.lua` now joins the dedicated `ForeverDuel` channel as a member directory, requests the hidden native roster asynchronously, and feeds validated names/GUIDs into the existing paced whisper queue. A readable prior channel selection is restored after completion or a five-second timeout unless the user takes over the native UI. Join/refresh attempts are bounded at 30 seconds; missing APIs or unrestorable selection defer requests. Roster membership alone never creates a player listing. Invalid YELL distribution disables that route for the rest of the session. World transitions clear pending work. `/duelrating status` adds `Zone roster` diagnostics. Existing dropdowns, nine Classic classes, rating data, consent, schema 2, and rated protocol 2 are preserved.

Validation: **33 Lua files compile; 14 suites; 4,000 assertions pass** with `python tests/run.py`. Native-adapter integration and a dedicated roster suite cover two clients with no targets/focus/groups/nameplates, delayed and event-only counts, stale zero display counts, restoration, user selection changes, unavailable APIs, exceptions, world transitions, rejected area traffic, and existing whisper pacing. These simulations establish no live delivery claim.

The package `dist/curseforge-0.4.3/ForeverDuel-0.4.3.zip` was built and verified with 21 entries and 18 manifest-listed Lua modules; SHA-256 is `932263aacb7338e8dc142f705124dae623bf9f3333eecdba992f2167a73e3d57`. The existing `C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\ForeverDuel` installation was updated and all 21 source files matched SHA-256 after copying. Its previous contents are backed up under `dist/installation-backups/classic-beta-before-0.4.3-d3e05c8e82874a94bb76304356e35195`. SavedVariables were not changed. No upload or publication was performed.

Both clients must fully restart after installation to load the new `Roster.lua` manifest entry. The user subsequently reported "okay wurde alles sofort erkannt" after receiving the paired no-target test instructions. Automatic discovery is **PASS (user-reported happy path, 2026-10-04)** for this test pair. No new paired logs or confirmation of every detailed setup/assertion were provided. [MANUAL_TESTING.md](../MANUAL_TESTING.md) retains focused selection, recovery, pacing, expiry, and compatibility cases as pending. Source and live evidence are separated in [API_VERIFICATION.md](API_VERIFICATION.md).

## Version 0.4.2: automatic nearby discovery, 2026-10-04 (historical; YELL rejected live)

The user confirmed that 0.4.1 discovery worked after taking the other character as a target. Their screenshot records a locally submitted custom-channel announcement, a discovery whisper query, an actual `WHISPER` profile received on map 1420, and a submitted profile reply. This is bounded live evidence for the target route; it does not demonstrate custom-channel receipt or passive no-target discovery.

That release replaced custom-channel broadcasts with periodic invisible addon `YELL` beacons. Blizzard's Classic API announcement explicitly disables addon `CHANNEL` traffic and allows local `SAY`/`YELL`; the production Musician addon uses `YELL` for non-mainline discovery. Matching Forever source exposes the APIs but does not enumerate supported distributions. Sources, payload restrictions, and the distinction between submission and receipt are recorded in [API_VERIFICATION.md](API_VERIFICATION.md).

Beacons carry validated colon-delimited ASCII profiles, repeat every 15 seconds, and preserve the five-second minimum attempt interval. Exact local-beacon profiles are accepted on `YELL`, `SAY`, and historically reported `UNKNOWN` receive distributions. Existing pipe-delimited whisper queries/replies remain compatible with 0.4.1. Incoming broadcasts do not cause broadcast replies. The addon no longer joins or sends through the custom `ForeverDuel` channel. Cache limits/expiry, map filtering, native challenge checks, explicit consent, schema 2, and rated protocol 2 remain unchanged.

Validation: **31 Lua files compile; 13 suites; 3,806 assertions pass** with `python tests/run.py`, including two-client local-broadcast and untargeted native-adapter simulations. A further user screenshot shows a finalized rated result and repeated result packets returning to idle without a second visible finalization; its discovery traffic is still `WHISPER`. This does not establish the new beacon route.

`dist/curseforge-0.4.2/ForeverDuel-0.4.2.zip` was built and verified with 20 entries and 17 manifest-listed Lua modules; SHA-256 is `65f02608d3c2133155ceae04dd4511bac1a1963c1c3df9a325d008f3d26b106b`. The existing `C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\ForeverDuel` installation was updated and all 20 files verified. The prior addon folder is preserved under `dist/installation-backups/classic-beta-before-0.4.2-cf355e72ce864fd1a0c22adae1cd7d38`. Both clients need `/reload` to load 0.4.2. No project upload or publication was performed.

**NOT TESTED live:** automatic no-target discovery on Forever 1.60.1.70205, actual broadcast range, and realm/faction/phase combinations. [MANUAL_TESTING.md](../MANUAL_TESTING.md) now begins with a two-client test that clears target/focus/group/nameplates and cache, then requires actual broadcast receive evidence. No live broadcast success or publishing is inferred from the source change or simulations.

## Version 0.4.1: discovery fallback and dropdown filters, 2026-10-04 (historical)

- Discovery no longer depends on joining or delivering through the custom channel. `FDQ2` queries and `FDP2` replies use the existing presence prefix over addon `WHISPER`, with native target/focus/party/raid/nameplate identities. Mouseover does not trigger queries; seeing a unit alone never creates a listing. If channel delivery fails, target the peer once or enable player nameplates. This is not arbitrary nearby-player enumeration.
- Queries are paced per recipient at 45 seconds, replies at five seconds, with one queued discovery whisper per second, at most 300 queued recipients, and 120-second expiry. Channel heartbeats retain 45-second / five-second pacing. Optional channel failures and scan failures are isolated, and world exit clears discovery work. Status now reports separate channel sends, discovery whisper sends, and receive routes. Rated consent, protocol 2, schema 2, and rating behavior are unchanged.
- Class, rating, sort, and rated-eligibility controls now use direct-selection dropdowns with a selected marker and outside-click dismissal. Class choices and presence profiles exclude Death Knight, Monk, Demon Hunter, and Evoker; the nine Classic classes remain.

The original installed 0.4.0 presence module matched repository bytes; two running clients used **1.60.1.70205**. The user's empty-list report is live symptom evidence, but no saved send/receive log established the precise channel failure. Source verification was updated against matching commit `e3ecc27b64d30fdc735a3f6579b866858f9f9df1`; event argument 7 was already correct. See [API_VERIFICATION.md](API_VERIFICATION.md).

Validation: **31 Lua files compile; 13 suites; 3,643 assertions pass** with `python tests/run.py`. The new `tests/presence_whisper_spec.lua` covers the query/reply path and channel-independent operation; existing transport/browser suites retain channel and filter regressions. Publication inputs were updated and `dist/curseforge-0.4.1/ForeverDuel-0.4.1.zip` was built and verified with 20 entries. The later user report and screenshot establish the target-triggered discovery success recorded above. Other native rendering and two-client cases remain pending in [MANUAL_TESTING.md](../MANUAL_TESTING.md); no upload is claimed.

The existing beta-client addon folder at `C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\ForeverDuel` was updated to 0.4.1 and all 20 installed files verified. Its prior contents were preserved under `dist/installation-backups/classic-beta-before-0.4.1-ce56f0d7e13d416c9555a78c63b270f4`. Both running clients need `/reload` to load the installed update.

## Initial 0.4.0 CurseForge preparation, 2026-10-04 (historical)

Prepared local publication materials under `docs/curseforge`: an English summary, equivalent plain-text/HTML description, 0.4.0 changelog, project/file field worksheet, and German upload guide with current official source links. The target is World of Warcraft / Forever / 1.60.1; project ID, account details and public URLs are not invented. The file is prepared as Beta while focused live validation remains outstanding. The guide distinguishes a Beta file from CurseForge's Experimental project flag and explains the documented Release-file prerequisite for app sync.

The then-current `python tools/prepare-curseforge.py` built `dist/curseforge-0.4.0/ForeverDuel-0.4.0.zip`, copies the original 1254x1254 project logo and publication texts, and emits SHA-256 checksums plus a build report. ZIP verification passed for 20 entries / 17 Lua modules, exact source bytes, one addon folder, manifest/version agreement and MIT license. The original root archive is unchanged. The helper uses only Python's standard library and performs no network or publishing operations.

The full Lua regression suite was rerun successfully: **30 files compiled; 12 suites; 3,428 assertions**. No addon runtime changes were made for this preparation. Account login, actual form/name availability, project creation, upload and moderation remain pending; no CurseForge project was created or submitted. No in-game gallery screenshots were fabricated. The current original branding was reused without edits.

## Version 0.4.0: search, progression and level-aware rating groups, 2026-10-03

Implemented the requested expansion without external UI simulator work:

- Zone browser: literal name search, class filter, all/±100/±200/±400 rating window, name/highest/closest sorting, rated-eligibility filter, reset filters, level/group column. Rating distances compare only the local group/cap. Ordinary challenges retain independent native identity checks and bilateral rated consent.
- Overview: separate Leveling, Max level and optional Legacy selectors; a native Line chart for the last 40 duels with a correct opening baseline; per-group stats/history/details. Historical identity details include levels. Bounds, chart continuity, win/loss/flat colors, and unused-line clearing have executable tests.
- Rated rules: native known levels and matching caps, same rating group, absolute difference at most five. Unknown/skull/restricted levels and cross-group duels remain ordinary. Level changes are checked through native events and consent/start/result barriers. Peer claims cannot replace native level snapshots.
- Elo: K=32 with 20 effective strength points per level, one rounded winner transfer and its exact negative for the loser. At equal ratings and a five-level gap the lower-level winner gains 20, higher-level winner gains 12. The consent dialog shows projected changes.
- Persistence: schema 2 contains independent Leveling/Max level pools starting at 1500, tagged records and native level/cap snapshots. Migration first validates complete schema-1 data and preserves a full separate Legacy archive. Settings/counter survive; unclassifiable old matches never seed either new rating. Invalid/future data is preserved with rating disabled. Missing runtime cap does not prevent data loading or later recovery.
- Compatibility: rated prefix/wire `ForeverDuel2` / `FD2`, presence `ForeverDuelZone2` / `FDP2`. Both players require 0.4.0. Presence advertises current-group rating/level/cap; tooltips discard stale native-level mismatches.

Validation executed with `python tests/run.py`: **30 Lua files compile; 12 suites; 3,428 assertions pass**. Breakdown: adapter 233, duel 1,348, history 428, minimap 86, presence 265, presence transport 203, profile chart 230, protocol 185, rating brackets 110, storage 124, tooltip 117, zone 99. New test files are `tests/rating_brackets_spec.lua` and `tests/profile_chart_spec.lua`; existing suites were extended for protocol/schema 2 and preserved regression coverage. Test execution required elevated read access to the existing `.test-deps` runtime; no runtime dependency is shipped.

Read-only integration review checked native level binding, snapshot freshness, pool isolation, old-data preservation and ordinary fallback. The native level-query assignment was tightened so readability is checked before truthiness. Additional adapter cases cover missing cap on initial login with Legacy migration and recovery, disappearing/changed native opponents, and unrelated level events.

Native UI rendering, custom-channel delivery, level/cap timing, protected actions and two-client gameplay are **NOT TESTED live for 0.4.0**. See the new focused section in `MANUAL_TESTING.md`. Earlier successful live evidence below applies to earlier builds, not this full change. No UI simulator was installed or used.

`ForeverDuel.zip` was rebuilt and verified byte-for-byte against the installable 0.4.0 folder: 20 files, 17 manifest-listed Lua modules, one top-level `ForeverDuel` directory, matching license, and a valid ZIP integrity check. Test dependencies are excluded. The prior archive is preserved as `ForeverDuel-0.3.0.zip`. Historical implementation entries follow.

## Version 0.3.0: zone discovery and player tooltips, 2026-10-03

The addon loads `Presence.lua`, `Zone.lua`, and `Tooltip.lua`. The overview includes **Players in zone**, with a direct `/duelrating zone` command. The browser paginates eight rows, displays names/ratings, and uses a fresh GUID/full-name/native-player check before a user-triggered native duel request. It preserves the existing outgoing hook, native acknowledgment, and bilateral rated consent. Cache queries copy records, filter the current map, and expire entries after 120 seconds.

The tooltip renderer reads only fresh cache entries (or the local rating), requires native player/GUID/full-name agreement, and resets duplicate suppression on native tooltip clearing. Its errors and browser errors are isolated from duel cancellation.

`Presence` automatically joins the `ForeverDuel` temporary WoW channel and registers the separate `ForeverDuelZone1` prefix. Announcements carry character GUID, current local rating, map ID, and class; the native sender supplies the full name. Heartbeats repeat every 45 seconds, with map/rating/reset changes announced through the same five-second minimum send interval. Failed sends retry at that interval, including native exceptions on unchanged heartbeats. Missing joins retry after at least 30 seconds. Channel numbers are resolved again rather than cached indefinitely. The cache is memory-only, bounded to 300 profiles, and cleared/suspended on world exit. Incoming packets never trigger reply loops, rated consent, or history writes. `/duelrating status` reports discovery state and last send/receive details.

Validation: `python tests/run.py` passed on 2026-10-03 with **28 Lua files compiled, 10 suites, 2,459 assertions**. This includes 254 cache/challenge, 185 channel-transport, 92 tooltip, 61 zone-browser, and 208 native-adapter assertions, plus the existing duel/history/protocol/storage/minimap coverage. Two simulated clients discover one another, complete a native-evidence rated duel after a browser-row challenge, then receive updated ratings and a confirmed reset. Failure cases cover malformed/restricted/wrong-channel packets, sender binding, expiry, channel renumbering/rejoin, throttling, world transitions, and isolated API errors.

Native rendering and actual channel delivery are **not yet verified live**. The target client must expose `JoinTemporaryChannel` and permit addon-channel messages; cross-realm/faction delivery and map/phase/range differences can limit discovery. Missing support is reported without cancelling the existing whisper-based duel flow. The installable 0.3.0 folder preserves schema/protocol version 1 for rated matches; no SavedVariables migration is required.

`ForeverDuel.zip` was rebuilt and verified byte-for-byte against the installable folder: 20 files, 17 manifest-listed Lua modules, one top-level `ForeverDuel` directory, version 0.3.0, and the matching packaged license. Development tests and dependencies are excluded.

Implemented on 2026-09-16 in an initially empty workspace. No existing files or Git history were present. This remains an experimental local addon; its 0.1.3 happy path and reload persistence were confirmed live by the user on 2026-10-03. No backend, website, uploader, account system, Glicko-2, or combat analytics were created.

Installation follow-up on 2026-10-02: version 0.1.1 corrects the manifest to Forever interface `16001` for the inspected 1.60.1.70170 client and documents the extra ZIP-extraction folder that prevented discovery. Gameplay code and protocol are unchanged. This does not replace live testing.

Discovery follow-up on 2026-10-02: version 0.1.2 fixed a reproduced asymmetric discovery race by acknowledging a valid peer nonce once on first reaching READY. It also added documented UI routes for native request/cancellation notices and diagnostics, retaining captured-opponent and timeout guards. The initial screenshot did not establish the reported live timeout's exact cause.

Forever compatibility follow-up on 2026-10-02: version 0.1.3 addresses a subsequent live trace that showed a concrete target/sender mismatch: `Name-Surname` was constructed locally while the received sender was `Name Surname`. Inspection of Forever 1.60.1.70170's native name utilities identifies the second unmodified-name component as a surname and supplies the correct full-name formatter. Identity and transport now use that native representation. Discovery's initial four-second check also becomes `DISCOVERY_WAIT`, preserving ordinary actions and allowing valid late nonce proof for the same request before its 50-second pending limit. Explicit unrated choice, native acceptance/start, cancellation, and expiry remain terminal for rating. Wire protocol and consent requirements are unchanged.

Live follow-up on 2026-10-03: screenshots show incoming discovery reaching `READY`, bilateral `ACCEPT`, `COMMIT`, `RATED_CONFIRMED`, `START_OK`, localized countdown messages for 3/2/1, `IN_PROGRESS`, and `RESULT` traffic. The user confirmed the rated flow worked, then confirmed rating behavior and reload persistence. Complete counterpart logs and paired stored records were not supplied, so exact cross-client record equality was not independently audited. Other locales, cross-faction/realm combinations, and the complete failure matrix remain unverified live.

The user confirmed the 0.2.0 overview worked in game on 2026-10-03 and approved the 0.2.1 redesign. Version 0.2.1 provides charcoal/gold statistics cards, eight alternating history rows, and persistent click-selected details for both players. The 960×652 movable window scales down on opening; opponent post-match ratings are explicitly calculated, and optional spec/outcome labels use existing metadata. No damage/healing/spell analytics, SavedVariables migration, or wire changes are added. Presentation errors remain isolated from duel recovery. The user's visual approval does not establish every layout/scaling check in the manual matrix.

Version 0.2.2 adds a custom crossed-swords icon, generated with built-in Imagegen, exported to a transparent 128 x 128 TGA. The manifest uses it in the addon list and a new 32-pixel minimap button toggles the overview on left click. Dragging moves it around the standard round minimap and saves `settings.minimapAngle` per character. Button failures are isolated from rated-duel recovery; protocol/schema versions are unchanged. The master image, exact prompt, and reproducible export script are retained in the repository. Native visual/click/drag checks remain pending.

## Result and architecture

The addon overlays the ordinary duel interaction with an owned dialog, bounded addon discovery, explicit consent on both clients, a nonce/GUID-derived shared match ID, and immutable pre-match rating snapshots. The receiving client attempts native acceptance only after the rated agreement barrier. Native acceptance through another path cancels pending rating immediately.

Each client independently needs a readable native countdown, elapsed countdown, native finish event, unambiguous local winner, and matching peer start/result evidence. Finalized matches update deterministic Elo and per-character SavedVariables exactly once. Protocol, game integration, state machine, UI, rating, and persistence are separate modules. See [ARCHITECTURE.md](../ARCHITECTURE.md).

## Executed verification

Command: `python tests/run.py`, using the optional local Lupa Lua 5.1 runtime. The complete automated 0.2.2 suite passed on 2026-10-03:

- **21 Lua files compile.**
- **6 suites pass, 1,835 assertions.**
- Adapter suite: 176 assertions, including row selection/details across navigation, stored/spec-ID name handling and guards, escaped markup, empty-state clearing, and window shrink-to-fit at 720×540 without changing global UI scale. Existing cases retain two separately loaded native-adapter instances completing a rated duel with the overview open, automatic record/reset refresh, presentation-error isolation, delayed surname discovery, consent, and strict identity checks.
- Two-client lifecycle suite: 1,105 assertions, including guarded late discovery, terminal unrated/start/cancel/expiry behavior, delayed outgoing detection, one delivered HELLO, and duplicate acknowledgments without loops, alongside consent, rematch, snapshot, and finalization coverage.
- History suite: 233 assertions covering derived statistics, empty records, streaks, peak rating, bounded pagination, newest-first ordering, copied win/loss details, unequal-rating opponent projections, and mutation guards.
- Protocol/result suite: 171 assertions covering strict parsing, malformed input, match IDs, localization, name ambiguity, and countdown formats.
- Rating/storage suite: 64 assertions covering Elo conservation, persistence integrity, duplicate finalization, schema rejection, reset, and copied history.
- Minimap suite: 86 assertions covering left-click toggle, tooltip, scale-aware dragging, release-click suppression, next-click recovery, saved angles, replacement settings after reset, invalid/restricted geometry, and button/logger error isolation without changing duel state or records.

The exported TGA header and pixel payload were verified as 128 x 128, uncompressed 32-bit, top-left origin with an 8-bit alpha channel (65,554 bytes). Transparent and opaque pixels are present, and the matching 128-pixel PNG was visually inspected. The manifest references all 14 Lua modules plus the packaged icon; the included license matches the root license.

These are executable Lua simulations. They do not test real frame rendering, actual protected-action permission, native message routing, cross-faction/realm delivery, or game-managed disk writes. The separate live happy-path evidence and user confirmation are recorded above. Substituting the pre-0.1.2 acknowledgment behavior in memory made its delayed-detection regression fail as expected.

## Every file added

All paths below are relative to the repository root. No pre-existing file was modified.

| File | Purpose |
| --- | --- |
| [ForeverDuel/ForeverDuel.toc](../ForeverDuel/ForeverDuel.toc) | Forever 16001 manifest and per-character SavedVariable. |
| [ForeverDuel/Constants.lua](../ForeverDuel/Constants.lua) | Versions, limits, timeouts, rating constants. |
| [ForeverDuel/Core.lua](../ForeverDuel/Core.lua) | Initialization, native event/hook dispatch, commands, error recovery. |
| [ForeverDuel/Wow.lua](../ForeverDuel/Wow.lua) | Native API/identity adapter and localized system-message routing. |
| [ForeverDuel/Duel.lua](../ForeverDuel/Duel.lua) | State machine, consent, start/result evidence, finalization. |
| [ForeverDuel/Comms.lua](../ForeverDuel/Comms.lua) | Paced bounded addon whisper transport. |
| [ForeverDuel/Protocol.lua](../ForeverDuel/Protocol.lua) | Versioned payload validation and shared match IDs. |
| [ForeverDuel/Results.lua](../ForeverDuel/Results.lua) | Pure localized countdown/winner parsing. |
| [ForeverDuel/Rating.lua](../ForeverDuel/Rating.lua) | Deterministic Elo. |
| [ForeverDuel/Database.lua](../ForeverDuel/Database.lua) | Versioned SavedVariables and validated idempotent commits. |
| [ForeverDuel/History.lua](../ForeverDuel/History.lua) | Copied match/page/details queries, statistics, and labeled opponent-rating projection. |
| [ForeverDuel/UI.lua](../ForeverDuel/UI.lua) | Owned dialogs, deferred native restoration, summary/history. |
| [ForeverDuel/Profile.lua](../ForeverDuel/Profile.lua) | Read-only overview, pagination, selected-match details, isolated UI errors. |
| [ForeverDuel/Minimap.lua](../ForeverDuel/Minimap.lua) | Minimap overview shortcut, tooltip, saved drag angle, isolated UI errors. |
| [ForeverDuel/Presence.lua](../ForeverDuel/Presence.lua) | Periodic local addon broadcasts, paced discovery whispers, bounded temporary cache, native identity check before challenges. |
| [ForeverDuel/Zone.lua](../ForeverDuel/Zone.lua) | Paged map-filtered discovery browser, dropdown filters, and Duel buttons. |
| [ForeverDuel/Tooltip.lua](../ForeverDuel/Tooltip.lua) | Native unit-tooltip rating line with fresh cache and identity checks. |
| [ForeverDuel/Media/Icon.tga](../ForeverDuel/Media/Icon.tga) | Packaged 128 x 128 crossed-swords icon with transparency. |
| [assets/branding/README.md](../assets/branding/README.md) | Generated PNG master/preview inventory, exact prompt, and built-in tool provenance. |
| [tools/export-icon.ps1](../tools/export-icon.ps1) | Reproducible PNG-to-TGA size/format conversion for the game asset. |
| [ForeverDuel/Debug.lua](../ForeverDuel/Debug.lua) | Optional prefixed diagnostic output. |
| [tests/run.lua](../tests/run.lua) | Native Lua runner and compilation checks. |
| [tests/run.py](../tests/run.py) | Optional Lua 5.1 runner via Lupa. |
| [tests/adapter_spec.lua](../tests/adapter_spec.lua) | Real-module native adapter simulations. |
| [tests/duel_spec.lua](../tests/duel_spec.lua) | Independent two-client state/protocol simulations. |
| [tests/protocol_spec.lua](../tests/protocol_spec.lua) | Wire/identity/localization tests. |
| [tests/storage_spec.lua](../tests/storage_spec.lua) | Elo, persistence, and finalization tests. |
| [tests/history_spec.lua](../tests/history_spec.lua) | Overview statistics, paging, and history immutability tests. |
| [tests/minimap_spec.lua](../tests/minimap_spec.lua) | Click/drag, saved position, invalid geometry, and isolated-error tests. |
| [tests/presence_spec.lua](../tests/presence_spec.lua) | Copied cache, expiry, maps, and exact native-unit challenge checks. |
| [tests/presence_transport_spec.lua](../tests/presence_transport_spec.lua) | Simulated nearby broadcast clients, pacing, wire validation, retry, transitions, and cache bounds. |
| [tests/presence_whisper_spec.lua](../tests/presence_whisper_spec.lua) | Independent query/reply discovery, native-unit scans, optional channel failures, pacing, retries, and lifecycle cleanup. |
| [tests/zone_spec.lua](../tests/zone_spec.lua) | Discovery rows, navigation, expired entries, and isolated UI failures. |
| [tests/tooltip_spec.lua](../tests/tooltip_spec.lua) | Native tooltip callbacks, identity, freshness, restricted values, and deduplication. |
| [README.md](../README.md) | Installation, use, status, commands, limitations. |
| [ARCHITECTURE.md](../ARCHITECTURE.md) | State/protocol/persistence/failure design. |
| [MANUAL_TESTING.md](../MANUAL_TESTING.md) | Two-client Tests 1–12, overview Test 13, and extended release gate. |
| [docs/API_VERIFICATION.md](API_VERIFICATION.md) | Pinned Retail API evidence and remaining assumptions. |
| [docs/IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) | This implementation report and file inventory. |
| [LICENSE](../LICENSE) | MIT license. |
| [ForeverDuel/LICENSE](../ForeverDuel/LICENSE) | Same license included inside the installable addon folder. |
| [.gitignore](../.gitignore) | Exclude local test dependencies and generated files. |

An ignored `.test-deps/` directory contains the downloaded Lupa test runtime. It is development tooling and must not be copied into the game addon folder.

## Native assumptions and known failure modes

Every used API category and its source is inventoried in [API_VERIFICATION.md](API_VERIFICATION.md). The successful happy path provides initial evidence for naming, negotiation, native start, rating, and reload persistence. The following still require broader live coverage:

1. Forever's native unmodified full-name representation works consistently for unit resolution, whisper targets/senders, and duel result text. Retail-derived API assumptions remain subject to Forever verification; its surnames must not be interpreted as realms.
2. Native outgoing-request acknowledgment arrives through a supported system/UI notice route; countdown and winner strings arrive through `CHAT_MSG_SYSTEM`, with readable evidence and usable ordering.
3. Secure initiation/acceptance hooks cover the native interaction paths; the outgoing unqualified acknowledgment corresponds to the captured unit attempt.
4. Deferred popup suppression/restoration preserves ordinary duel actions, including combat, expiry, Escape, and other-addon interactions.
5. `AcceptDuel()` can run from the confirmed protocol callback; a failed or silently blocked action safely returns to normal interaction.
6. Addon whispers work for the tested realm/faction combination, guarded late discovery does not revive accepted/cancelled/expired requests, and SavedVariables survive a normal reload/logout.

Unknown identities, stale/incompatible packets, negotiation/result timeout, changed snapshots, restricted/ambiguous result text, and incomplete start/result evidence decline local rating. Initial discovery timeout only changes the UI to a bounded waiting state; it neither grants consent nor prevents ordinary play. Korean/Russian grammatical result formats need further support. A reload or zoning transition abandons unfinished work. A crash may lose recent SavedVariables writes.

Result messages are retried twice. Persistent one-way loss or a disconnect after one client has sufficient evidence can still leave asymmetric local history/rating; no finite message exchange supplies a distributed atomic commit. The tests explicitly preserve and document this limitation. Client Lua and peer claims are not anti-cheat authority.

## Next three tasks

1. Publish the prepared 0.4.5 Beta after the user-confirmed test conclusion and collect feedback from additional Forever players.
2. Investigate Beta reports with paired client evidence where available; retain the two-client [manual checklist](../MANUAL_TESTING.md) for regressions and broader compatibility, and fix confirmed issues while preserving evidence requirements and ordinary-duel fallback.
3. Plan Phase 2 explicitly after Beta feedback; shared rankings, backend verification, server rating authority, uploader, and website remain future work.
