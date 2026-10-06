# Neue Versionen automatisch auf CurseForge hochladen

Stand: 04.10.2026. Die Pipeline bereitet neue Dateien für **ForeverDuelersGuild**, CurseForge-Projekt **1726452**, vor und lädt sie nach bestandenen Prüfungen hoch. Ziel ist [sveniwestside/ForeverDuelersGuild](https://github.com/sveniwestside/ForeverDuelersGuild). Version **0.4.5** ist bereits veröffentlicht und wird nicht erneut eingereicht. Ein erfolgreicher automatischer Live-Upload einer neuen Version ist noch nicht belegt.

Der [GitHub-Probelauf vom 04.10.2026](https://github.com/sveniwestside/ForeverDuelersGuild/actions/runs/37215915147) besteht: **48 Python-Tests**, **14 Lua-Suites / 4.551 Assertions**, Paketbau und echter lesender API-Zugriff. Die API liefert für **Forever 1.60.1** die Versions-ID **17053**. Das Paket bleibt bytegleich zum veröffentlichten ZIP. Ein separater lokaler Probelauf einer vorbereiteten 0.4.6 in einem temporären Verzeichnis prüfte außerdem den Versionswechsel und Uploadplan, ohne den tatsächlichen 0.4.5-Stand zu ändern oder eine Datei einzureichen.

## Eine neue Version vorbereiten

Vom Repository-Hauptverzeichnis aus, beispielsweise für 0.4.6:

```powershell
python tools/prepare_release.py 0.4.6 --changelog PATH --release-type beta
```

`PATH` durch die tatsächliche Datei mit den neuen Versionshinweisen ersetzen. Der optionale Datei-Typ ist `beta`, `alpha` oder `release`; im Beispiel wird ausdrücklich eine Beta vorbereitet. Die Versionsnummer muss zu den Änderungen gehören und neuer als der bisherige Stand sein.

Das Werkzeug aktualisiert die Version in `ForeverDuel/ForeverDuel.toc`, den Lua-Konstanten und `docs/curseforge/project.json`. Tragen TOC und Konstanten die neue Version schon (während der Entwicklung erhöht), bleiben sie unverändert; steht sie nur in einer der beiden Dateien, bricht das Werkzeug vor jeder Änderung ab. Es archiviert das vorherige Worksheet, für diesen Schritt als `docs/curseforge/releases/0.4.5.json`, und legt `docs/curseforge/changelog-0.4.6.txt` an. Veröffentlichungsstatus und Testnachweise werden für die neue Version zurückgesetzt: Die Freigabe und Tests von 0.4.5 gelten nicht automatisch für 0.4.6. Der interne Installationsordner `ForeverDuel`, gespeicherte Charakterdaten und Protokollnamen bleiben erhalten.

Die Versionsänderung und den Changelog prüfen. Nötige Ingame-Regressionen für die Änderung durchführen und konkrete Ergebnisse dokumentieren; der automatische Lauf bestätigt die native Clientfunktion nicht.

## Live-Test vermerken

Ein Upload setzt einen bestandenen Live-Test genau dieser Version voraus. Nach den Abschnitten 1–3 von [MANUAL_TESTING.md](../../MANUAL_TESTING.md) auf zwei Clients in `docs/curseforge/project.json` eintragen und committen:

```json
"userReportedTesting": { "status": "passed", "version": "0.4.6", "reference": "kurze Angabe zu Datum, Build und Clients" }
```

Ohne `status: "passed"` mit der Version des Pakets verweigern `tools/curseforge_upload.py --upload` und damit auch der Tag-Workflow die Einreichung vor jedem Netzwerkzugriff. `prepare_release.py` setzt den Eintrag für jede neue Version zurück.

## Lokal prüfen

```powershell
python -m pip install -r tests/requirements.txt -r tools/requirements-analysis.txt
python tools/release.py --tag v0.4.6
```

Die erste Zeile installiert die Lua-5.1-Laufzeit für die Tests und die Abhängigkeiten der Analyse-Tests (numpy, scipy), die `release.py` ebenfalls ausführt. Ohne `--upload` arbeitet der Lauf offline: Er prüft die Versions- und Tagkonsistenz, führt die Lua-5.1- und Python-Tests aus, baut und verifiziert das Paket und erzeugt den Uploadplan. Ein API-Token ist dafür nicht nötig. `--tag` ist optional; die Angabe prüft ausdrücklich den vorgesehenen Release-Tag gegen den vorbereiteten Stand. Der Lauf trägt seine Testergebnisse (`status`, `validation.automated`) in `docs/curseforge/project.json` ein. Ein anschließender lokaler Upload akzeptiert genau diese Änderung; jede andere nicht committete Änderung, auch am Worksheet, verhindert den Upload.

Für einen tatsächlichen lokalen Upload muss `CF_API_TOKEN` bereits privat in der Prozessumgebung gesetzt sein:

```powershell
python tools/release.py --tag v0.4.6 --upload
```

Dieser Befehl reicht die neue Datei auf CurseForge ein. Den Token nicht in den Befehl, ins Repository oder in den Chat schreiben. Der Uploader verwendet den HTTP-Header `X-Api-Token`, keine Token-Queryparameter, und gibt den Token nicht aus. Die [offizielle CurseForge-Upload-API](https://support.curseforge.com/support/solutions/articles/9000197321-curseforge-api) beschreibt Token-Erstellung, Authentifizierung, Versionsabfrage und Datei-Upload.

## GitHub Actions einrichten

Das Zielrepository ist [sveniwestside/ForeverDuelersGuild](https://github.com/sveniwestside/ForeverDuelersGuild), das Remote lautet `https://github.com/sveniwestside/ForeverDuelersGuild.git`. Der Quellstand einschließlich `.github/workflows/curseforge-release.yml` gehört in dieses Repository.

Im CurseForge-Autorenkonto einen API-Token für die Uploads erstellen. Ihn direkt in GitHub unter **Settings → Secrets and variables → Actions → New repository secret** als **`CF_API_TOKEN`** speichern. Der Wert wird privat in GitHub eingegeben. Einrichtung und Verwendung sind in der [GitHub-Anleitung für Actions-Secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets) beschrieben.

Das vom Nutzer bereits hinterlegte GitHub-Secret heißt **`FOREVERDUELERSGUILD`**. Der Workflow akzeptiert diesen Namen als Alternative und übergibt seinen Wert intern als `CF_API_TOKEN`; ein später angelegtes Secret `CF_API_TOKEN` hat Vorrang.

**Vor dem ersten Push dieses Workflows die Freigabe einrichten.** Unter **Settings → Environments** die Umgebung **`curseforge`** anlegen, **Required reviewers** setzen (mindestens eine Person) und unter **Deployment branches and tags** nur Tags `v*` sowie den Branch `main` (für den lesenden Probelauf über **Run workflow**) zulassen. Den Token dort als **Environment secret** `CF_API_TOKEN` speichern und die Repository-Secrets `FOREVERDUELERSGUILD` und `CF_API_TOKEN` danach löschen. GitHub legt eine im Workflow genannte, aber nicht eingerichtete Umgebung sonst automatisch **ohne** Schutzregeln an; ein Repository-Secret stünde dem Lauf dann ohne Freigabe zur Verfügung. Liegt der Token nur als Environment-Secret vor, hat eine automatisch angelegte Umgebung keinen Token. Zusätzlich bricht der Workflow bei einem Tag-Push als ersten Schritt ab, wenn `curseforge` keine Required reviewers hat.

Nach eingerichtetem Repository, Secret und bestandenem lokalem Probelauf den vorbereiteten Stand committen und pushen. Dann beispielsweise:

```powershell
git tag v0.4.6
git push origin v0.4.6
```

Der Push eines Tags `v*` startet `.github/workflows/curseforge-release.yml`. Der Lauf wartet auf die Freigabe der Umgebung `curseforge`; danach folgen Prüfungen, Tests, Paketbau und der automatische CurseForge-Upload, sofern ein bestandener Live-Test dieser Version vermerkt ist. Ein Fehler vor dem Upload beendet den Lauf ohne Einreichung. **Der Tag-Push löst eine Veröffentlichungspipeline aus**; ihn erst für den vorgesehenen Release-Stand ausführen.

Ein manueller Start über **Actions → Run workflow** (`workflow_dispatch`) führt den Probelauf aus und prüft mit dem hinterlegten Secret lesend den API-Zugriff und die Forever-Version. Er lädt keine Datei auf CurseForge hoch. Allgemeine Grundlagen stehen in der [GitHub-Actions-Dokumentation](https://docs.github.com/en/actions).

Die Pipeline erstellt keine GitHub-Release-Datei und verteilt das Addon ausschließlich über CurseForge. Die Wahl **Don't allow distribution to 3rd party** bleibt bestehen.

## Zielversion und Veröffentlichung

`docs/curseforge/automation.json` enthält die API-Basis **`https://wow.curseforge.com`**, den Forever-Versionstyp **88568** und **`publishAutomaticallyAfterApproval: true`**. Beim tatsächlichen Upload fragt das Werkzeug die offizielle Versionsliste ab und verlangt genau einen Treffer für **Forever** und die konfigurierte Spielversion. Fehlende oder mehrdeutige Treffer brechen den Upload ab; Retail oder ein anderer Classic-Typ wird nicht als Ersatz verwendet.

Neue Dateien werden nach erfolgreicher CurseForge-Freigabe automatisch veröffentlicht. Dazu setzt der Upload `isMarkedForManualRelease: false`. Dies betrifft neue Pipeline-Uploads; der historische manuelle Erstupload von 0.4.5 bleibt dokumentiert. Die API-Option und die zurückgegebene Datei-ID sind in der [CurseForge-Upload-API](https://support.curseforge.com/support/solutions/articles/9000197321-curseforge-api) beschrieben.

Nach einem erfolgreichen Upload speichert die Pipeline den Empfangsnachweis mit Datei-ID. Das bestätigt die Einreichung, noch keine Freigabe oder öffentliche Verfügbarkeit. Den tatsächlichen Status im Autorenportal prüfen; nach Veröffentlichung den öffentlichen Download und die Installation prüfen. Diese Ergebnisse separat erfassen.

Ein bereits veröffentlichter Stand oder ein lokal vermerkter früherer Uploadversuch wird gegen eine erneute Einreichung gesperrt. GitHub speichert schon **vor** dem POST einen Upload-Vorsatz mit dem Paketprüfbericht als `curseforge-upload-vX.Y.Z`; dieser sperrt einen weiteren Lauf desselben Tags auch bei einem späteren Runner-Abbruch. Versuchs- und Empfangsnachweise folgen separat als `curseforge-upload-result-vX.Y.Z`. Die Artefakte werden 90 Tage aufbewahrt; danach muss der tatsächliche CurseForge-Stand vor einer Wiederholung gesondert geprüft werden. Bei einem Netzwerkfehler kann CurseForge die Datei bereits erhalten haben: Erst im Autorenportal klären, ob eine Datei angelegt wurde, und den lokalen Nachweis mit dem Ergebnis abgleichen. Den Upload nicht blind erneut starten.

## Projektbeschreibung gesondert prüfen

Die Datei-Upload-API überträgt das ZIP und dessen Changelog; sie aktualisiert die Projektübersicht nicht. Bei jedem Versionswechsel `description.txt`, `description.html` und die tatsächlich gespeicherte CurseForge-Beschreibung prüfen und nötige Änderungen separat übernehmen. Der aktuelle Überblick für 0.4.5 und die Roadmap zu 1.0 werden durch den Pipeline-Upload nicht automatisch ersetzt.
