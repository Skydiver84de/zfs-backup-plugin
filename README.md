# ZFS Backup Framework

Bash-Backup-Framework für Unraid: ZFS-Snapshots, lokale + Remote-Replikation,
Pruning, Verify, Wake-on-LAN und native Unraid-Benachrichtigungen — als **eine**
Datei (`zfs-backup.sh`) und als natives **Unraid-Plugin mit Web-GUI**.

## Installation (Unraid-Plugin)

Unraid: **Plugins → Install Plugin** und diese URL einfügen:

```
https://raw.githubusercontent.com/Skydiver84de/zfs-backup-plugin/main/plugin/zfs-backup.plg
```

Voraussetzung: `cache/system` ist ein ZFS-Dataset (auf Unraid 6.12+ üblich).
Updates erscheinen automatisch über die Plugins-Seite. Danach unter
**Settings → ZFS Backup**.

**Grundmodell:** Die **Quelle ist maßgeblich**. Die Retention wird auf der Quelle
entschieden; aktive Ziele werden beim normalen Lauf an den verwalteten
Snapshot-Bestand der Quelle angeglichen (fehlende Snapshots replizieren,
zusätzliche verwaltete Ziel-Snapshots entfernen). Ein Replikationsfehler blockiert
das Pruning des betroffenen Datasets.

## Schnellstart

```bash
./zfs-backup.sh --help          # ohne Argumente zeigt das Skript ebenfalls die Hilfe
./zfs-backup.sh --config-check
./zfs-backup.sh --simulate      # Dry-Run, ändert nichts
./zfs-backup.sh --run
./zfs-backup.sh --status
./zfs-backup.sh --verify
```

Das Framework ist vollständig **headless** (kein interaktives Menü). Lese-Befehle
(`--status`, `--datasets`, `--snapshots`, `--snapshot-tree`, `--targets`,
`--capacity`, `--config-schema`, `--get-config`) unterstützen `--json`. Ziele und
Konfiguration werden über `--add/edit/delete/test-target` bzw.
`--get-config`/`--set-config` gepflegt; destruktive Aktionen verlangen `--yes`.
Diese CLI ist auch die Datenquelle der Plugin-GUI.

## Konfiguration

Die Config liegt in `DATA_DIR` (Standalone-Default = Skriptverzeichnis, im Plugin
`/boot/config/plugins/zfs-backup`). Logs/State liegen in `RUNTIME_DIR` (im Plugin
unter `cache/system/zfs-backup`); Logs täglich als `zfs-backup-YYYY-MM-DD.log`.

Die Config wird bei jedem Start geprüft und normalisiert (vorhandene Werte
bleiben, fehlende kommen mit sicheren Defaults dazu; vorher ein Backup daneben).
Nach einer Normalisierung startet `--run` aus Sicherheitsgründen erst wieder nach
`--config-check`; unkritische Befehle laufen weiter.

### Datasets

```bash
INCLUDES=( cache )
EXCLUDES=( cache/system )
```

Excludes wirken rekursiv; ein expliziter Include übersteuert einen
ausgeschlossenen Parent gezielt (z. B. `cache/system/backup` trotz
`EXCLUDES=(cache/system)`). Pool-Root-Datasets (`cache`, `services` …) werden
standardmäßig nicht selbst gesnapshottet (`SNAPSHOT_POOL_ROOTS="no"`, auf `yes`
setzbar). Listen werden beim Speichern alphabetisch sortiert. Die tool-eigenen
Datasets und `cache/system` werden hart von der Sicherung ausgeschlossen.

### Retention

```bash
KEEP_HOURLY=0      # 0 = Typ vollständig aus (Standard für hourly)
KEEP_DAILY=14
KEEP_WEEKLY=8
KEEP_MONTHLY=12
KEEP_YEARLY=3
ENABLE_SOURCE_PRUNING="yes"
```

`KEEP_*` gibt je Typ die Aufbewahrung an. **`0` deaktiviert den Typ komplett** —
es werden keine erstellt und vorhandene beim Pruning entfernt (kein separater
„Aktivieren"-Schalter).

## Ziele

Replikation läuft über Ziele: anzeigen (`--targets [--json]`), anlegen
(`--add-target <label> <local|remote> <base-dataset> [ssh-host]`), ändern
(`--edit-target`), testen (`--test-target`), löschen (`--delete-target`),
sortieren (`--reorder-targets <id,id,...>` oder `--move-target <id> <up|down>`).
Die **ID** ist numerisch und automatisch (1, 2, … – beim Löschen und Sortieren
lückenlos neu nummeriert); der frei wählbare Anzeigename ist das **Label**.

Die Reihenfolge der Ziele ist zugleich die **Backup-Reihenfolge** (erstes Ziel
zuerst, letztes zuletzt). So lässt sich z. B. festlegen, dass das schnelle
lokale Ziel vor dem langsamen Remote-Ziel gesichert wird.

```bash
TARGETS=( 1 2 )

# Lokal
TARGET_1_TYPE="local"
TARGET_1_LABEL="backups"
TARGET_1_ENABLED="yes"
TARGET_1_BASE_DATASET="backups/nas1"

# Remote
TARGET_2_TYPE="remote"
TARGET_2_LABEL="nas2"
TARGET_2_ENABLED="yes"
TARGET_2_HOST="root@192.168.1.50"
TARGET_2_BASE_DATASET="files/nas1"
TARGET_2_SSH_OPTIONS="-i /root/.ssh/zfs_backup_ed25519 -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes -o UpdateHostKeys=no"
TARGET_2_WAKE_ON_LAN="yes"
TARGET_2_WAKE_MAC="AA:BB:CC:DD:EE:FF"
TARGET_2_RETRY_ATTEMPTS=3
TARGET_2_RETRY_WAIT_SECONDS=10
```

Ein Ziel-Dataset heißt `<BASE_DATASET>/<quell-dataset>`, z. B.
`files/nas1/cache/appdata`. Replikat-Ziele werden beim Receive automatisch auf
den letzten gemeinsamen Snapshot zurückgerollt (Änderungen am Replikat werden
verworfen, die Quelle bleibt unberührt). Sends/Receives nutzen Resume-Tokens
(`zfs send -t`) und fortsetzbares `receive -s`. Ist der Remote nicht per Ping
erreichbar, weckt das Skript ihn per `etherwake` und wartet auf SSH/ZFS.

> **Hinweis – langes Deaktivieren erzwingt einen Neuaufbau.** Ein deaktiviertes
> Ziel hält das Quell-Pruning nicht auf: die Quelle prunt während der Pause
> normal weiter. Wird das Ziel **länger als die tiefste aktive Retention-Stufe**
> deaktiviert (z. B. länger als `KEEP_YEARLY` Jahre), existiert beim
> Reaktivieren kein gemeinsamer Snapshot mehr – der nächste Lauf baut das Ziel
> dann **komplett neu auf** (volle Übertragung) statt inkrementell aufzuholen.
> Innerhalb des Fensters fädelt es sich per Incremental Send wieder ein.

### Verwaiste Ziel-Datasets

Ein Ziel-Dataset, dessen Quell-Dataset nicht mehr existiert, gilt als „verwaist".
Ein normaler Lauf **löscht das nie automatisch**, sondern erkennt und loggt es nur
(und meldet es optional per Notification). So reißt ein versehentlich gelöschtes
Quell-Dataset nicht seine Backups mit. Aufräumen nur bewusst manuell:

```bash
./zfs-backup.sh --cleanup-orphans [<ziel-id>]          # Dry-Run: zeigt, was gelöscht würde
./zfs-backup.sh --cleanup-orphans [<ziel-id>] --yes    # löscht (rekursiv, nur unter BASE_DATASET)
```

In der GUI unter **Wartung** mit getippter Bestätigung; optional je Ziel.

## Maintenance

```bash
./zfs-backup.sh --thin-history --yes               # je aktivem Typ einen Anker behalten
./zfs-backup.sh --delete-managed-snapshots --yes   # alle verwalteten Snapshots löschen
./zfs-backup.sh --reset-statistics --yes
./zfs-backup.sh --reset-run-status --yes
./zfs-backup.sh --delete-logs --yes
```

Betroffen sind nur Snapshots mit `SNAPSHOT_PREFIX`; Datasets/Dateien bleiben
unberührt, rekursive Löschungen nur unterhalb des jeweiligen `BASE_DATASET`.

**Verify** prüft nur lesend (Reparatur/Abgleich macht der normale Lauf):
`--verify` (alles), `--verify-source`, `--verify-target <ziel-id>` (einzelnes
Ziel) bzw. `--verify-local`/`--verify-remote`. In der GUI als „Snapshots prüfen"
mit Umfang-Popup.

## Wiederherstellen

### Alltag: Datei, Ordner oder ganzer Snapshot

Im Plugin jeden Snapshot durchsuchen (**Snapshots → Durchsuchen**) — aus der
**Quelle** und aus jedem **Ziel** (lokal/remote). Per „↩ Wiederherstellen" holt
man eine Datei, einen Ordner oder über die Brotkrumen-Leiste den **ganzen
Snapshot** zurück. Headless:

```bash
./zfs-backup.sh --snapshot-restore <dataset> <snapshot> <scope> <unterpfad>
# <scope> = source ODER eine Ziel-ID; <unterpfad> leer = ganzer Snapshot
```

**Nicht destruktiv:** kopiert nach `<quell-mountpoint>/_restore/<snapshot>/` und
überschreibt nie (Konflikt → Zeitstempel-Suffix). Voraussetzung: das
**Quell-Dataset existiert und ist gemountet** (dort entsteht `_restore`). Für den
Normalfall (Quelle lebt, etwas versehentlich gelöscht) genügt das.

### Notfall: ganzes Dataset zurück auf die Quelle (Disaster Recovery)

Ist ein Quell-Dataset komplett verloren (Pool/Platte defekt) und sollen die
**kompletten Daten samt Snapshot-Historie und Eigenschaften** zurück — oder
handelt es sich um ein **zvol** (keine durchsuchbaren Dateien) — führt der Weg
über `zfs send | zfs receive`. Bewusst **nicht** in der GUI: es schreibt als
einzige Operation autoritativ auf die Quelle.

```bash
# 1. Neuesten Snapshot des Replikats ermitteln (lokal bzw. remote)
zfs list -t snapshot -o name -s creation backups/nas1/cache/appdata | tail -1
ssh root@<host> "zfs list -t snapshot -o name -s creation files/nas1/cache/appdata | tail -1"

# 2a. Aus lokalem Replikat (Quell-Dataset ist weg -> wird neu angelegt; -R = ganze Kette + Properties)
zfs send -R backups/nas1/cache/appdata@<snap> | zfs receive cache/appdata

# 2b. Aus Remote-Replikat (Host ggf. per etherwake wecken)
ssh root@<host> "zfs send -R files/nas1/cache/appdata@<snap>" | zfs receive cache/appdata
```

> ⚠️ `zfs receive -F` **nur**, wenn das Quell-Dataset noch existiert und bewusst
> überschrieben werden soll (`-F` verwirft dortige Änderungen). Fehlt das
> Quell-Dataset, **ohne `-F`** empfangen — dann kann nichts versehentlich
> überschrieben werden. Ziel-Namen vorher doppelt prüfen.

Danach Mountpoint prüfen (ein Replikat wird mit `receive -u` ungemountet
empfangen): `zfs get mountpoint,canmount …`, ggf. `zfs set canmount=on` +
`mountpoint=…`, dann `zfs mount`. Der nächste reguläre Lauf gleicht die Ziele an.

## Benachrichtigungen

Laufen über die native Unraid-Notification-Zentrale
(`/usr/local/emhttp/webGui/scripts/notify`); welcher Agent zustellt
(Pushover/Discord/Telegram/ntfy/E-Mail) wird einmalig in Unraid unter
**Einstellungen → Benachrichtigungen** eingerichtet. Kein `curl`, keine
Zugangsdaten im Skript. Je Ereignis die Stufe wählbar:

```bash
NOTIFY_START="aus"       # aus | normal | warning | alert
NOTIFY_SUCCESS="normal"
NOTIFY_ERROR="alert"
```

### Backup veraltet

```bash
STALE_AFTER_HOURS=26    # 0 = aus
```

Warnt, wenn das letzte **erfolgreiche** Backup älter als N Stunden ist (Schutz
gegen stillen Ausfall). Im Plugin als Badge/Banner; zusätzlich meldet ein Wächter
(`--check-stale`, stündlich, nur bei aktivem Zeitplan) das einmal per
Notification. Standalone `zfs-backup --check-stale` per eigener cron aufrufen.

## SSH einrichten

```bash
ssh-keygen -t ed25519 -f /root/.ssh/zfs_backup_ed25519 -C "zfs-backup"
ssh-copy-id -i /root/.ssh/zfs_backup_ed25519.pub root@192.168.1.50
ssh -i /root/.ssh/zfs_backup_ed25519 root@192.168.1.50          # Host-Key einmal bestätigen
# Test wie im Lauf:
ssh -i /root/.ssh/zfs_backup_ed25519 -o BatchMode=yes -o ConnectTimeout=10 \
    -o IdentitiesOnly=yes -o UpdateHostKeys=no root@192.168.1.50 "zfs list"
```

Empfohlen auf dem Remote: `PermitRootLogin prohibit-password`,
`PasswordAuthentication no`, `PubkeyAuthentication yes` (danach SSH neu laden).

## Empfohlener Ablauf

1. Skript einmal starten, Config erzeugen lassen.
2. `INCLUDES`/`EXCLUDES`/Retention prüfen, dann `--config-check` und `--simulate`.
3. Lokales Ziel anlegen und testen.
4. Remote-SSH + Wake-on-LAN testen, dann Remote-Ziel aktivieren.
5. `--run`, danach `--verify`.

## Zeitplan

Im **Plugin** legt der Tab **Zeitplan** fest, wann ein Lauf automatisch startet
(Preset stündlich/täglich/wöchentlich oder freier Cron-Ausdruck). Das Plugin
schreibt daraus eine native Unraid-Cron-Datei und aktiviert sie per `update_cron`
(beim Boot neu erzeugt). Standalone wird `./zfs-backup.sh --run` per eigener
`cron`/systemd-Timer geplant.

## Dateien

```text
zfs-backup.sh    Hauptskript (portabler Kern)
plugin/          Unraid-Plugin (GUI, Verpackung, Zeitplan)
README.md        diese Anleitung
CHANGELOG.md     Änderungen
ROADMAP.md       offene Punkte
CLAUDE.md        Projektkontext/Konventionen
RELEASING.md     Release-Prozess
TESTING.md       Unraid-Testcheckliste
```
