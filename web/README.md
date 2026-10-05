# ForeverDuelersGuild website

The website is a local duel register: the ladder and recent duels are the main screen, with a compact dark header, warm light surfaces, clear typography and restrained class colors. Character rows use the nine official WoW class icons, downloaded from Blizzard's render CDN. Their sources, checksums and attribution are recorded in [the icon manifest](public/assets/classes/manifest.json) and [WoW asset notes](../assets/branding/WOW_ASSETS.md).

## View the design

Requires Node.js 24.15 or later. There are no npm dependencies to install. From the repository root:

```powershell
cd web
npm run preview
```

Open <http://localhost:8788/?preview=1>. This preview is served only on the local computer. The explicitly labeled sample data exists to review the layout, filters and player details. It is not real player activity and does not create backend records.

The website defaults to English, including its forms, profile states and `en-GB` number/date formatting. The sun/moon control in the header switches between light and dark mode. It follows the system preference on the first visit, then stores an explicit choice locally under `fdg-theme`. The head script applies that choice before the stylesheet loads; the control still works when local storage is unavailable. Charts, dialogs and import states follow the selected theme.

The static preview has no import API. Running `npm start` uses the separate SQLite backend on port 8787, and the standard website view reads its API. Fictional preview characters never receive guessed Armory links. The addon's existing SavedVariables and local rating behavior are unchanged.

## Local backend foundation

```powershell
npm start
```

The real local API is at <http://localhost:8787>. It starts with an empty ladder. SQLite files persist under `web/data/`; they are excluded from source control. `HOST`, `PORT` and `DB_PATH` can override the defaults through environment variables or `web/.env`. The advertised addon version comes from `ForeverDuel/ForeverDuel.toc`, or from `ADDON_VERSION`. The npm start, demo and manage commands load that optional file automatically. Both the design preview and the backend bind to `127.0.0.1` by default.

`npm run demo` starts a separately stored, read-only backend demo on port 8787; stop the ordinary backend first. This is independent of the design-only `?preview=1` data.

The administrator can provision an upload credential for a character:

```powershell
npm run manage -- provision --guid Player-1-ABC --name "Example Character" --realm "Forever" --classFile MAGE --level 60 --maxLevel 60
```

Use the character's real GUID and identity values when integrating real history. The command prints one bearer token and replaces any previous token for that GUID. Treat it as a secret. `npm run manage -- revoke --guid Player-1-ABC` invalidates the current token. Provisioning is a local administrator assertion; it does not verify character ownership in WoW.

Convert a character's SavedVariables file to an import file from the repository root:

```powershell
python tools/export-history.py "C:\path\to\SavedVariables\ForeverDuel.lua" --output web/exports/history.json
```

Reload or log out normally before reading the saved file. The exporter parses only data, never executes Lua, omits settings and Legacy history, and rejects unsupported schemas. It never changes the source. Rated records of 0.5.x (protocol 2, match IDs `FD2:...`) and 0.6 (protocol 3, `FD3:...`) are both accepted. Larger histories are split into files of at most 200 reports. The website's live import dialog takes one JSON file and its character token.

An initial participant report is pending. A compatible opposite report confirms the match; disagreement makes it disputed. Re-importing the same report is safe. Changed reports are rejected. Only confirmed matches contribute to the central ladder. The backend recalculates its own Elo from 1500 in chronological order, separately by mode and level cap. Importing older matches can therefore change subsequent central ratings. These web ratings are independent of the addon's local ratings.

## Class boards and calibration

The **Overall** tab retains the existing Elo. The nine official class-icon tabs select separate class boards; their ranks are calculated before search and pagination, and their URLs can be shared. At maximum level 60 they sort by the additional matchup-adjusted **Class Rating**. Leveling class boards sort by ordinary Elo. Other level caps receive no unverified copy of the level-60 matrix. Supported profiles show both rating histories.

The first version uses the complete approved manual matrix. Its **Manual baseline** label means an assumption, not a measured Forever win rate. The comparison view shows confirmed counts, equal-level calibration counts, distinct characters/pairs, estimates and uncertainty by level band when an offline analysis has been published. Empty or undersized evidence is labeled **Insufficient data**. [CLASS_RATING.md](CLASS_RATING.md) records the matrix, formulas, safeguards and the population-centering limitation.

The recorded ruleset is chosen with `FD_RULESET_ID` (default `forever-v1`) and persisted in the database. Reopening that database under a different ruleset is rejected. Use a separate database for another ruleset. Schema-2 client reports do not record a historical game patch; this scope is an administrator assertion, so histories from different rule versions must not be mixed during import. Changing `BLIZZARD_GAME` cannot change the rating or analysis scope.

Calibration is an offline administrative task using Python, NumPy and SciPy; uploads and public HTTP requests never run it. Publishing a report only makes aggregate evidence visible. Each later matrix requires a separate explicit administrator approval, an immutable provenance record and a documented effective timestamp. No proposal is automatically activated. Failed or insufficient analyses leave the active matrix intact.

Install the analysis dependencies once, then export a fresh snapshot and calculate its report from `web/`:

```powershell
python -m pip install -r ../tools/requirements-analysis.txt
New-Item -ItemType Directory -Path exports -Force | Out-Null
$analysisStamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$analysisDataset = "exports/dataset-$analysisStamp.json"
$analysisReport = "exports/report-$analysisStamp.json"
$analysisCandidate = "exports/candidate-$analysisStamp.json"
npm run manage -- dataset-export --maxLevel 60 --dataCutoff $analysisStamp --out $analysisDataset
python ../tools/analyze-matchups.py $analysisDataset --output $analysisReport --candidate $analysisCandidate
npm run manage -- analysis-publish --file $analysisReport
npm run manage -- models
npm run manage -- audit
```

The export is registered immutably in SQLite, including the hash used to verify the Python input and published report. `dataset-export` writes a new file and refuses to overwrite an existing one. When no pair qualifies, the report still explains the blockers and **no candidate file is created**. Do not proceed to activation in that case.

After reviewing an eligible report and its provisional limitations, an administrator can explicitly schedule its matrix:

```powershell
$matrixEffectiveFrom = [DateTimeOffset]::UtcNow.AddMinutes(5).ToUnixTimeSeconds()
npm run manage -- model-activate --approve yes --file $analysisCandidate --effectiveFrom $matrixEffectiveFrom
```

The effective date must be in the future, after the data cutoff and after already confirmed history. The candidate must exactly match its published report and current baseline. A scheduled matrix applies to later duels when that timestamp is reached; it does not reset ratings. Older imported duels retain the appropriate historical version. A new proposal needs two validation windows entirely after the preceding model's data cutoff. Matrix, dataset and report rows reject updates and deletions.

The tool's defaults use 500 fixed-seed character-cluster bootstrap repetitions. Each validation window requires 100 weighted equal-level matches, 20 characters on each side and 30 character pairs. The pooled proposal fit additionally applies the same repeated-pair limit over the combined 28-day period. Direct max-level counterevidence is assessed separately; its current conservative guard uses 50 weighted matches, ten characters per side and 20 pairs before an opposing 95% interval blocks a proposal. These counterevidence thresholds are additional review defaults, **not a requirement to have max-level data**. A proposal supported only by Leveling remains provisional and always requires approval.

Useful checks:

```powershell
cd web
npm test
python -m unittest discover -s ../tools/tests -p test_analyze_matchups.py -v
```

From the repository root, run `python -m unittest discover -s tests -p test_export_history.py` for the safe parser/export tests. `GET /health`, `/api/v1/stats`, `/api/v1/ladder`, `/api/v1/matches` and `/api/v1/players/{guid}` expose the local read API. `POST /api/v1/import` requires the bearer token. No public deployment has been configured.

## Design structure

- A compact identity header and direct access to the register and import help.
- A ladder with separate leveling/max-level modes, class/name filters and clear rating/W/L columns.
- A chronological duel log alongside the ladder on wide screens.
- Character details with statistics, rating progression, match history and the Blizzard profile state.
- Official WoW class artwork instead of substitute class glyphs.
- A live import dialog for the exported history and character token.

Sample data must remain visibly marked. Do not turn mock activity or season statistics into production claims. Keep the standard API view empty until real corroborated reports exist. Two matching uploads are community corroboration, not proof from the WoW server.

The current CurseForge publication status is recorded under `docs/curseforge`; do not invent an approved public download URL or distribute another public copy of the addon.

## Blizzard character data

The backend includes a server-side Blizzard OAuth client and public character-profile, media and equipment requests. It can supply level, race, class, faction, guild, specialization and equipped item level when those fields are returned. A verified **retail** response also supplies the corresponding public Armory link. Classic profiles do not get a fabricated retail Armory link. These data enrich the profile; they do not verify character ownership or duel results and never change the ladder's Elo.

**Forever support has not been verified in Blizzard's official API documentation.** The default `BLIZZARD_GAME=forever` therefore makes no speculative upstream requests and reports that the profile integration is not yet available for this game. Do not switch a Forever player to a retail namespace merely to obtain a same-name profile. Adding credentials alone cannot establish Forever support.

For a documented, supported game, copy the example file locally and enter credentials in the resulting ignored file:

```powershell
Copy-Item .env.example .env
```

Set `BLIZZARD_CLIENT_ID` and `BLIZZARD_CLIENT_SECRET` from a client created in the [Battle.net Developer Portal](https://develop.battle.net/), and explicitly select `BLIZZARD_GAME=retail`, `classic` or `classic-era` as appropriate. `BLIZZARD_LOCALE=en_GB` is the default. Restart the backend after configuration changes. Keep credentials out of chat, public files and browser code.

Each character requires a local administrator mapping to its **actual API** region, namespace, realm slug, complete name, numeric realm ID and numeric character ID. Native GUID segments and surnames are not inferred as API IDs or realm slugs. Example syntax only, with placeholder identity values:

```powershell
npm run manage -- link-character --guid Player-1-ABC --region eu --namespace profile-eu --realmSlug argent-dawn --characterName FullName --realmId 1 --characterId 2748
npm run manage -- unlink-character --guid Player-1-ABC
```

The mapping command requires a character already known to the local accounts or ladder. Supported namespace forms are `profile-{region}` for retail, `profile-classic-{region}` for Classic and `profile-classic1x-{region}` for Classic Era. The selected game and mapping must agree. The API response must match both numeric IDs, the realm slug, name and class before the backend exposes any Blizzard profile or Armory link. Media and equipment subresponses are checked against the same character and realm IDs.

Credentials and OAuth tokens stay server-side. Requests use fixed Blizzard hosts, bearer headers, bounded timeouts and responses, coalesced requests, token renewal and short failure caching. Profile results are cached for five minutes; upstream failures are represented explicitly. `GET /api/v1/integrations/blizzard` exposes configuration/readiness without secrets. `GET /api/v1/players/{guid}` includes the `character` state and any verified enrichment.

Primary references: [Blizzard's current OAuth metadata](https://oauth.battle.net/.well-known/openid-configuration), [client-credentials example](https://github.com/Blizzard/java-signature-generator), [API namespaces](https://community.developer.battle.net/documentation/world-of-warcraft/guides/namespaces), and [Blizzard's Classic profile API announcement](https://us.forums.blizzard.com/en/wow/t/new-apis-now-available-for-testing/1645500). Live authenticated requests still need a locally configured client and real, supported character mappings.
