# ForeverDuelersGuild auf CurseForge vorbereiten und hochladen

Stand: 04.10.2026. Der Nutzer hat das Testing des aktuellen 0.4.5-Stands als soweit abgeschlossen bestätigt und die erste Beta-Veröffentlichung beauftragt. **ForeverDuelersGuild** wurde unter dem Eigentümer **sveniwestside** als **Projekt-ID 1726452** angelegt. Die erste Beta `ForeverDuelersGuild-0.4.5.zip` mit **Datei-ID 9058783** wurde am **04.10.2026** manuell veröffentlicht. Nach der bestätigten Publish-Aktion steht die [Dateiseite im Autorenportal](https://authors.curseforge.com/#/projects/1726452/files/9058783) auf **Approved**; die Publish-Schaltfläche ist nicht mehr vorhanden. Die öffentliche Projektseite und Dateiliste bestätigen **Beta 0.4.5 / WoW Forever / 1.60.1**. Der öffentliche ZIP-Download stimmt bytegenau mit dem vorbereiteten Paket überein; die Installation ist noch nicht geprüft.

Die [öffentliche Projektseite](https://www.curseforge.com/wow/addons/foreverduelersguild) und die [öffentliche Dateiseite](https://www.curseforge.com/wow/addons/foreverduelersguild/files/9058783) sind bestätigt; die Roadmap 1.0 ist auf der Projektseite sichtbar. Diese Adressen und die [Downloadseite](https://www.curseforge.com/wow/addons/foreverduelersguild/download/9058783) sind in `project.json` erfasst; der frühere `/preview`-Link bleibt separat als `previewUrl` erhalten. MIT-Lizenz und **Don't allow distribution to 3rd party** wurden im gespeicherten Projekt überprüft. Der Erstupload verwendet weiterhin **Beta**, **WoW Forever / 1.60.1**; die manuelle Veröffentlichung nach Freigabe ist abgeschlossen.

## Nächste Schritte nach Veröffentlichung

1. Die Installation und Versionsanzeige prüfen und erst nach diesem Test `installationVerified` bestätigen. Die Hinweise zur Beta-Verfügbarkeit in der App stehen weiter unten.
2. Rückmeldungen zusätzlicher Spieler sammeln und dokumentierte Regressionen für den nächsten Release-Stand auswerten.

Der öffentliche Download wurde am **04.10.2026** geprüft: **79.462 Bytes**, **21 ZIP-Einträge**, CRC-Prüfung erfolgreich und bytegenau gleich dem vorbereiteten Paket. SHA-256: `477af26f532a4c5a23218ff117825f9162db3c5ca12c81b47dd9504cabe18679`. Das Manifest nennt **ForeverDuelersGuild / 0.4.5 / Interface 16001**. Die Prüfergebnisse stehen in `dist/curseforge-0.4.5/public-download-verification.json`; sie bestätigen noch keine Installation im Spiel oder in der App.

## Fertige Dateien

Das vorbereitete Upload-Verzeichnis liegt nach dem Build unter `dist/curseforge-0.4.5/`:

| Datei | Verwendung |
| --- | --- |
| `ForeverDuelersGuild-0.4.5.zip` | **Nur diese Datei** in CurseForge als Addon-Datei hochladen. |
| `foreverduelersguild-logo.png` | Projektlogo; quadratisches Original in 1254 x 1254 Pixeln. |
| `summary.txt` | Englischer Kurztext für das Summary-Feld. |
| `description.txt` | Englische Beschreibung zum Einfügen in den Texteditor. |
| `description.html` | Dieselbe Beschreibung formatiert; gerenderten Inhalt in einen Rich-Text-Editor übernehmen. Rohes HTML nur verwenden, wenn der Editor ausdrücklich einen HTML-Quellmodus anbietet. |
| `changelog-0.4.5.txt` | Versionshinweise für den Datei-Upload. |
| `project.json` | Ausgefüllte Feldvorlage zum Nachschlagen; kein importierbarer API-Aufruf. |
| `SHA256SUMS.txt` | Prüfsummen für die vorbereiteten Dateien. Nicht als Addon hochladen. |
| `build-report.json` | Lokale Prüfung von Inhalt, Version, Lizenz und Logo. |

Die Textquellen liegen in diesem Verzeichnis. Das Addon-ZIP enthält ausschließlich den installierbaren Ordner `ForeverDuel`, einschließlich MIT-Lizenz und Laufzeit-Icon. Projekttexte und Logo-Master gehören nicht in `Interface/AddOns`.

Der technische Installationsordner `ForeverDuel`, `ForeverDuel.toc`, die gespeicherten Charakterdaten und `/duelrating` bleiben beim neuen Anzeigenamen erhalten. Das zuvor gebaute `ForeverDuel-0.4.5.zip` ist ein historisches Paket mit dem alten Anzeigenamen; für diese Einreichung die oben genannte Datei verwenden.

## Projekt anlegen

1. Mit dem Eigentümer-Account **sveniwestside** im [CurseForge-Autorenportal](https://authors.curseforge.com/#/projects/create/choose-game) anmelden. Die folgenden Schritte bleiben als Dokumentation der Projektanlage erhalten; Projekt **1726452** besteht bereits.
2. Die folgenden Werte übernehmen. Der Name **ForeverDuelersGuild**, der Slug **foreverduelersguild** und die tatsächliche öffentliche Projektseite sind bestätigt.

| Feld | Verwendeter Wert |
| --- | --- |
| Game | World of Warcraft |
| Project name | ForeverDuelersGuild |
| Class | Addons |
| Main category | PvP |
| Additional categories | Leer lassen |
| Summary | Inhalt von `summary.txt` |
| Description | Inhalt von `description.txt` oder formatierte HTML-Fassung |
| License | MIT License |
| Logo | `foreverduelersguild-logo.png` |
| Allow comments | Aktivieren, damit Nutzer Fehler melden können |
| Third-party distribution | **Don't allow distribution to 3rd party** auswählen; Pflichtauswahl im aktuellen Formular |
| Unlisted project | **Nicht aktivieren**; das Projekt soll regulär gelistet werden |
| Experimental project | **Nicht aktivieren**; siehe Unterscheidung zur Beta-Datei unten |
| Source / Issues / Website | Leer lassen, solange keine tatsächlichen öffentlichen Adressen vorhanden sind |

Am **04.10.2026** wählte der Nutzer ausdrücklich **„auf curseforge beschraenken“**. Daher ist die Verteilung durch Drittanbieter im gespeicherten Projekt deaktiviert (`allowThirdPartyDistribution: false`). **Unlisted project** bleibt entsprechend dem verwendeten Formular ebenfalls deaktiviert (`unlistedProject: false`). Das Projekt ist angelegt und die erste Beta-Datei ist freigegeben und veröffentlicht.

Die [Projektanleitung](https://support.curseforge.com/support/solutions/articles/9000199552-overview-of-the-project-submission-page) erlaubt quadratische PNG-Logos ab 400 Pixeln und beschreibt die Verkleinerung größerer Bilder. Der mitgelieferte Master erfüllt diese Vorgabe. Die Moderationsrichtlinie nennt 400 x 400 als Zielgröße; falls das Upload-Formular eine Anpassung anbietet, diese verwenden. Die 128-Pixel-Spieltextur ist dafür zu klein. Das Logo stammt aus der dokumentierten KI-Bilderzeugung und wird nicht als Screenshot ausgegeben.

## Version 0.4.5 hochladen

Im Projekt zu **Files / Upload file** wechseln. Die folgenden Angaben dokumentieren den erfolgreichen Erstupload mit Datei-ID **9058783**:

| Feld | Für den Erstupload verwendeter Wert |
| --- | --- |
| Upload file | `ForeverDuelersGuild-0.4.5.zip` aus dem Upload-Verzeichnis |
| Display name | ForeverDuelersGuild 0.4.5 |
| Release type | **Beta** |
| Flavor | **Forever** |
| Supported game version | **1.60.1** |
| Changelog | Inhalt von `changelog-0.4.5.txt` |
| Required dependencies | Keine |
| Veröffentlichung nach Moderation | Manuell; automatische Veröffentlichung deaktiviert |

`16001` ist die Interface-Angabe im Addon, `1.60.1.70205` der bisher untersuchte Clientbuild. Das passende CurseForge-Versionstag lautet **1.60.1**. Die Plattform führt Forever und diese Version bereits, etwa bei [ForeverUI](https://www.curseforge.com/wow/addons/foreverui/files/all?gameVersionTypeId=88568&page=1&pageSize=20&showAlphaFiles=hide). Die tatsächliche Auswahl im Autorenformular ist vor dem Absenden zu prüfen; keine Retail-/Classic-Ersatzzuordnung verwenden.

## Beta, Release und Installation über die App

Version 0.4.5 bindet die Gegenseite erst nach einer Bestätigung für die aktuelle Anfrage und wiederholt die Addon-Erkennung innerhalb der ursprünglichen 50 Sekunden. Eine bereits ausdrücklich erteilte Zustimmung kann bei einer Wiederholungsanfrage erneut gesendet werden; beide Spieler müssen weiterhin selbst zustimmen. Debug-Ausgabe ist dafür nicht erforderlich. Am 04.10.2026 bestätigte der Nutzer das Testing allgemein als soweit abgeschlossen. Dieser Abschluss gilt für die Vorbereitung der ersten Beta; es wurden keine neuen gepaarten Logs, Versuchszahlen oder Einzelbewertungen der gesamten Checkliste geliefert. Das frühere Dialogproblem mit 0.4.4 bleibt als historische Beobachtung dokumentiert, die genaue Live-Ursache unbestätigt. Bei erneutem Auftreten auf beiden Clients /duelrating status sichern, bevor eine weitere Anfrage oder ein Reload erfolgt. Die Lua-5.1-Suite wurde am 04.10.2026 erneut ausgeführt: 33 Dateien kompilieren, 14 Suites mit 4.551 Assertions bestehen.

Die neue Erkennung in 0.4.3 verwendet den automatisch beigetretenen Kanal `ForeverDuel` als Mitgliederverzeichnis. Das Addon wählt dessen ausgeblendete Mitgliederliste vorübergehend aus, wartet auf die asynchrone Aktualisierung, liest Namen und GUIDs und stellt die vorherige Auswahl wieder her. Profile werden anschließend per Addon-Flüstern abgefragt. Das Verzeichnis wird alle 30 Sekunden aktualisiert; Anfragen erfolgen höchstens alle 45 Sekunden pro Spieler und ausgehende Discovery-Flüsternachrichten höchstens einmal pro Sekunde.

Ein Live-Test bestätigte den entscheidenden Unterschied zwischen Kanalnummer und Verzeichniszeile: Kanal 6 lag in Anzeigezeile 9. Vor der Auswahl war der Mitgliedereintrag leer; nach Auswahl der Zeile und zwei Sekunden Wartezeit waren `Tester B` und seine GUID lesbar. Addon-`YELL` wurde vom Forever-Client mit Code 4 (`InvalidChatType`) abgewiesen. Nach einer solchen Ablehnung deaktiviert 0.4.3 weitere `YELL`-Versuche für die Sitzung.

Automatisierte Integrationstests für Verzeichnis und Profilaustausch bestehen. Die automatische Erkennung wurde bereits mit 0.4.3 vom Nutzer bestätigt. Mit dem nun gemeldeten Testabschluss geht 0.4.5 in die erste Beta-Veröffentlichung für weitere Spieler und Rückmeldungen. Nicht einzeln dokumentierte Fehlerfälle oder zusätzliche Client-/Sprachkombinationen erhalten dadurch keinen pauschalen PASS-Status. **Beta** bleibt der vereinbarte Datei-Typ für diesen ersten Rollout. Das ist getrennt vom CurseForge-Schalter **Experimental project**, der laut Projektanleitung die Synchronisierung mit dem CurseForge-Ökosystem verhindert.

Laut [Upload-Anleitung](https://support.curseforge.com/support/solutions/articles/9000197241-creating-and-submitting-a-project) benötigt ein Projekt mindestens eine **Release-Datei**, bevor es in die App synchronisiert wird; Beta-Dateien setzen außerdem die entsprechende Nutzerpräferenz voraus. Eine erste Beta-Veröffentlichung garantiert deshalb noch keine Installation über die App. Nach der ersten Beta Rückmeldungen und separat dokumentierte Regressionen auswerten und dann den nächsten Release-Stand festlegen. Die [Testcheckliste](../../MANUAL_TESTING.md) bleibt dafür erhalten. Den Datei-Typ nicht allein für Sichtbarkeit auf Release setzen.

Für die ausstehende Installationsprüfung: Forever-Installation in der App auswählen, ForeverDuelersGuild suchen, installieren und die installierte Version prüfen. Beide Duellteilnehmer sollten 0.4.5 verwenden. Beim Update von 0.4.3 oder 0.4.4 genügt `/reload` auf beiden Clients; es wurde kein neues Modul hinzugefügt. Beim Update von einer älteren Version als 0.4.3 beide Clients vollständig neu starten, damit `Roster.lua` geladen wird. Falls die App den Beta-Client nicht korrekt erkennt, die Zuordnung klären; der manuelle öffentliche Download ist bereits auf Integrität und Paketübereinstimmung geprüft.

## Screenshots und erste Rückmeldungen

Im Repository liegen derzeit keine passenden aktuellen Ingame-Screenshots für die Projektgalerie. Die Textbeschreibung funktioniert ohne erfundene Vorschaubilder. Sinnvolle spätere Motive sind die Übersicht mit Verlauf, die gefilterte Spielerliste und der Rated-Dialog. Nur echte Spielaufnahmen mit zutreffender Versionsangabe verwenden; private Chat-Inhalte bei Bedarf vor Aufnahme ausblenden. Das Logo ist Branding und kein Nachweis für das Aussehen der Benutzeroberfläche.

Die bestätigte Projekt-ID **1726452**, Datei-ID **9058783**, Autorenportal-URLs und öffentlichen Projekt-, Datei- und Downloadseiten sind in `project.json` erfasst; der `/preview`-Link bleibt separat. Kommentare können als Rückmeldekanal dienen. Ein eigener Webserver, GitHub-Account oder API-Schlüssel ist für den manuellen Upload nicht erforderlich.

## Paket erneut erzeugen

Vom Repository-Hauptverzeichnis aus:

```powershell
python tools/prepare-curseforge.py
```

Der Builder benötigt nur die Python-Standardbibliothek. Er prüft Versionsübereinstimmung, TOC-Einträge, Lizenz, Logo und jeden ZIP-Eintrag, kopiert die Veröffentlichungstexte und schreibt einen Prüfbericht. Er führt keine Anmeldung oder Netzwerkaufrufe aus. Die aktuelle `ForeverDuel.zip` im Hauptverzeichnis bleibt erhalten.

Aktuelle Vorgaben wurden am 04.10.2026 gegen die [Einreichungsanleitung](https://support.curseforge.com/support/solutions/articles/9000197241-creating-and-submitting-a-project), [Projektanleitung](https://support.curseforge.com/support/solutions/articles/9000199552-overview-of-the-project-submission-page) und [Moderationsrichtlinie](https://support.curseforge.com/support/solutions/articles/9000197279-project-and-modpack-moderation-policies) geprüft. Freigabe, manuelle Veröffentlichung und öffentlicher Download der ersten Beta sind bestätigt; die Installationsprüfung steht noch aus.
