# Unraid-Testlauf (headless)

Checkliste zum Validieren der headless-Schnittstelle auf **echtem Unraid** – die
echten `zfs`/SSH-Pfade (lokal ist nur `bash -n` möglich).

> **Branch:** `plugin` &nbsp;·&nbsp; **Voraussetzung:** bash 4+ (Unraid hat das).
>
> ⚠️ = **destruktiv** (löscht Snapshots/Daten). Nur auf einem Testaufbau oder mit
> vollem Verständnis ausführen. Befunde bitte mit **Befehl + Ausgabe** zurückmelden.

## JSON prüfen (Unraid hat kein python3, aber `php`)

`--json`-Ausgaben direkt an `php` zum Validieren weiterleiten:

```bash
./zfs-backup.sh --status --json | php -r '$j=json_decode(file_get_contents("php://stdin")); echo (json_last_error()!==JSON_ERROR_NONE)?"UNGUELTIG: ".json_last_error_msg()."\n":json_encode($j,JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES)."\n";'
```

Ergebnis: schön formatiertes JSON oder `UNGUELTIG: …`.

## 0. Vorbereitung
- [ ] `git fetch && git checkout plugin && git pull`
- [ ] `bash --version` → 4.x oder höher
- [ ] `./zfs-backup.sh --version` → gibt die Versionsnummer aus
- [ ] `./zfs-backup.sh --help` → Hilfe, **kein Menü**
- [ ] `./zfs-backup.sh` (ohne Argumente) → zeigt **Hilfe** (kein Menü, **kein** Lauf!)

## 1. Konfiguration
- [ ] `--config-check` → läuft durch; zeigt Zeile `Pfade  Daten … | Laufzeit …`
- [ ] Boot-Erkennung: bei **USB-Flash** + Logs unter `/boot` erscheint ein Auslagerungs-Hinweis; bei **SSD/NVMe** **kein** Hinweis
- [ ] `--config-schema` → Tabelle; `--config-schema --json` → gültiges JSON
- [ ] `--get-config` → JSON aller Werte
- [ ] `--get-config KEEP_DAILY` → einzelner Wert
- [ ] `--set-config KEEP_DAILY 14` → „Gespeichert"; danach `--get-config KEEP_DAILY` → `14`
- [ ] `--set-config KEEP_DAILY abc` → Fehler (Validierung greift)
- [ ] `--set-config NOTIFY_ERROR alert` → „Gespeichert"; `--set-config NOTIFY_ERROR foo` → Fehler (enum-Validierung)
- [ ] `KEEP_*=0` deaktiviert den Typ: `--simulate` zeigt ihn als „deaktiviert", `--config-check` warnt erst, wenn **alle** KEEP_* = 0 sind.

## 2. Lese-Endpunkte (Text + JSON)
- [ ] `--status` und `--status --json`
- [ ] `--datasets` und `--datasets --json` → zeigt die **echten** aktiven Datasets
- [ ] `--snapshots` und `--snapshots --json` → echte Snapshot-Zähler je Dataset
- [ ] `--snapshot-tree --json` → Scopes „Quelle" + jedes aktive Ziel, je Dataset Zählungen + belegt; `--snapshot-tree --json --cached` liest nur den State (weckt nichts)
- [ ] `--dataset-snapshots <ds>` (Quelle) und `--dataset-snapshots <ziel-dataset> <ziel-id>` → Einzel-Snapshots aus dem jeweiligen Scope-Cache (kein Wecken)
- [ ] `--snapshot-ls <ds> <snapshot> source` → Verzeichnisinhalt als JSON (greift auf die Platte zu); mit Unterpfad als 4. Argument tiefer; ungültiger/`..`-Pfad → `{"error":…}`
- [ ] `--snapshot-cat <ds> <snapshot> source <datei>` → Dateiinhalt auf stdout; Pfad außerhalb des Snapshots (Symlink/`..`) → leer + Exit 1
- [ ] dieselben Befehle mit einer Remote-Ziel-ID als `<scope>` → Inhalt per SSH (weckt ggf. den Remote)
- [ ] `--snapshot-restore <ds> <snapshot> source <datei>` → Datei landet in `<quell-mp>/_restore/<snapshot>/<datei>`, Live-Datei unberührt; erneuter Restore → Zeitstempel-Suffix (kein Überschreiben); Ordner rekursiv; Symlink-/`..`-Ausbruch abgelehnt
- [ ] `--snapshot-restore <ziel-dataset> <snapshot> <ziel-id> <datei>` (lokales Ziel) → Eintrag landet im `_restore`-Ordner des **Quell**-Datasets (aus Ziel-Base abgeleitet)
- [ ] dasselbe mit einer **Remote**-Ziel-ID → tar-über-SSH, weckt den Host ggf., landet ebenfalls im Quell-`_restore`
- [ ] Quell-Dataset gelöscht + Restore aus Replikat → Fehler „Quell-Dataset existiert nicht (mehr)…" (kein Restore ohne Ziel-Dataset)
- [ ] GUI: im Snapshot-Browser „↩ Wiederherstellen" bei **allen** Scopes (Quelle + lokale + Remote-Ziele), Liste + Vorschau; Erfolgsmeldung zeigt den Zielpfad
- [ ] `--snapshot-restore <ds> <snapshot> <scope>` **ohne** Pfad (leeres 4. Argument) → GANZER Snapshot landet als `<quell-mp>/_restore/<snapshot>/` (lokal cp -a der Wurzel, remote tar der Wurzel)
- [ ] GUI: Breadcrumb-Link „↩ Ganzen Snapshot wiederherstellen" (Wurzel) bzw. „↩ Diesen Ordner wiederherstellen" (in einem Unterordner) – funktioniert für Quelle + lokale + Remote-Ziele
- [ ] GUI: beim Wiederherstellen läuft ein **Fortschrittsbalken** (Prozent bei bekannter Größe; bei Remote-Unterpfad „… kopiert" als Bytes), am Ende „✓ Wiederhergestellt nach: …"; Snapshots-Tab lädt danach neu
- [ ] `--snapshot-restore <ds> <snap> <scope> <pfad> progress` → gibt `FORTSCHRITT <pct>`-Zeilen und am Ende `ZIEL <pfad>` aus; **ohne** `progress` weiterhin nur der blanke Zielpfad
- [ ] `--targets` und `--targets --json`
- [ ] `--gui-init --json` → EIN JSON mit `status`/`capacity`/`schema`/`values`/`targets`; GUI-Seite lädt damit (ein Kern-Aufruf statt fünf)
- [ ] GUI: Plugin-Seite öffnet spürbar schneller als zuvor
- [ ] Dashboard: Kachel **ZFS Backup** erscheint als Karte in einer Spalte (Zustand, Lauf/Erfolg, Ziele); Dashboard lädt normal (kein Absturz), Zahnrad-Link führt zur Plugin-Seite

## 3. Ziele (CRUD)
- [ ] `--add-target testlocal local <dein-ziel-dataset>` → angelegt
- [ ] `--targets --json` → enthält `testlocal`
- [ ] `--edit-target testlocal LABEL "Testziel"` → gespeichert
- [ ] `--test-target testlocal` → erreichbar bzw. korrekte Fehlermeldung
- [ ] Remote: `--add-target testremote remote <remote-base-dataset> root@<host>` → angelegt
- [ ] `--test-target testremote` → weckt ggf. den Host und prüft
- [ ] `--delete-target testlocal` und `--delete-target testremote` → gelöscht

## 4. Simulation & echter Lauf
- [ ] `--simulate` → Vorschau, ändert nichts
- [ ] ⚠️ `--run` → **echter** Lauf (Snapshots + Replikation)
- [ ] **Während** `--run` läuft (zweites Terminal): `--status --json` → `"running": true` und `"progress": {"phase": …}`
- [ ] **Während** `--run`: `--log-tail` → letzte Logzeilen; `--log-tail 100`
- [ ] **Nach** `--run`: `--status` → letzter Lauf ERFOLG; `--status --json` → `"progress": null` (Fortschrittsdatei wurde aufgeräumt)
- [ ] Zwei `--run` gleichzeitig → der zweite meldet „Backup läuft bereits" (Lock)

## 5. Verify
- [ ] `--verify`
- [ ] `--verify-source` · `--verify-local` · `--verify-remote`
- [ ] `--verify-target <ziel-id>` → prüft nur dieses Ziel; ungültige/leere ID → Fehler
- [ ] GUI Wartung: „Snapshots prüfen" → Popup mit Alles / Nur Quelle / je Ziel; Auswahl startet den passenden Verify-Lauf

## 6. Maintenance (⚠️ destruktiv — am besten zuletzt)
- [ ] `--reset-statistics` **ohne** `--yes` → wird verweigert („--yes anhängen")
- [ ] `--reset-statistics --yes` → ok
- [ ] `--reset-run-status --yes` · `--delete-logs --yes`
- [ ] ⚠️ `--thin-history --yes` → dünnt die Historie auf den neuesten Daily aus
- [ ] ⚠️ `--delete-managed-snapshots --yes` → löscht **alle** verwalteten Snapshots auf **Quelle und aktiven Zielen** (keine Datasets/Dateien)
- [ ] Quell-Dataset löschen → normaler `--run`: Backups bleiben erhalten, Lauf **loggt** „verwaistes Ziel-Dataset" (löscht NICHTS automatisch)
- [ ] `--cleanup-orphans` (ohne `--yes`) → Dry-Run, listet „WÜRDE LÖSCHEN …", löscht nichts
- [ ] `--cleanup-orphans <ziel-id>` → Dry-Run nur für dieses Ziel; ungültige ID → Fehler
- [ ] ⚠️ `--cleanup-orphans [<ziel-id>] --yes` → löscht verwaiste Ziel-Datasets (alle oder nur das gewählte Ziel); GUI: Wartung Ziel-Auswahl + „Verwaiste Datasets anzeigen" (Dry-Run) + „… löschen" (getippte Bestätigung „VERWAISTE LOESCHEN")

## 7. Datenpfade
- [ ] Auslagerung: `ZFS_BACKUP_RUNTIME_DIR=/mnt/<pool>/zfsbackup-test ./zfs-backup.sh --config-check` → `Laufzeit` zeigt den neuen Pfad; ein anschließender Lauf schreibt Logs/State dorthin
- [ ] Plugin-Simulation: `ZFS_BACKUP_DATA_DIR=/mnt/<pool>/zfsdata-test ./zfs-backup.sh --status` → Config/State landen dort, das git-Skriptverzeichnis bleibt unberührt
