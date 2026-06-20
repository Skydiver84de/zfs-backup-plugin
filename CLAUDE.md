# CLAUDE.md

Projektkontext und Konventionen für die Arbeit an diesem Repository.
Bedienung/Setup stehen in [README.md](README.md), Versionshistorie in
[CHANGELOG.md](CHANGELOG.md), Planung in [ROADMAP.md](ROADMAP.md), der
Release-Prozess in [RELEASING.md](RELEASING.md).

## Projektziel

Eigenständiges ZFS-Backup-Framework für Unraid als **eine einzige Bash-Datei**
(`zfs-backup.sh`), die Snapshots, lokale und Remote-ZFS-Replikation, Pruning,
Verify und Benachrichtigungen verwaltet.

Bewusste Beschränkungen:

* Kein Docker, keine externe Datenbank.
* Keine zusätzlichen Abhängigkeiten außer Standard-Unraid-Tools und ZFS
  (optional `pv`, `etherwake`). Benachrichtigungen laufen über das native
  Unraid-Tool `/usr/local/emhttp/webGui/scripts/notify` (kein eigener
  Versand, kein `curl`).

## Architektur

* Eine Datei: `zfs-backup.sh`. Keine Modulstruktur, kein Sourcing von Code.
* `set -o pipefail`, kein `set -e`. Setzt bash 4+ voraus (Namerefs, `mapfile`).
* Datenpfade sind vom Skriptverzeichnis getrennt (Plugin-Updates überschreiben
  nur das Skript). `DATA_DIR` (Env `ZFS_BACKUP_DATA_DIR`, Default =
  Skriptverzeichnis) hält die **persistente Config**; `RUNTIME_DIR` (Env
  `ZFS_BACKUP_RUNTIME_DIR`, Default = `DATA_DIR`) hält die **schreiblastigen
  Laufzeitdaten** und ist optional auf einen Pool auslagerbar (USB-Stick
  schonen). INVARIANTE: weder `DATA_DIR` noch `RUNTIME_DIR` liegen je im
  Skriptverzeichnis.
  * Config: `<DATA_DIR>/zfs-backup.conf`
  * Logs: `<RUNTIME_DIR>/logs` (täglich `zfs-backup-YYYY-MM-DD.log`)
  * State: `<RUNTIME_DIR>/state` (Dataset-State unter `state/datasets`)
  * Lock: `<RUNTIME_DIR>/lock` (PID-Datei, Run-State)
* **Headless-first:** Bedienung ausschließlich über CLI-Flags, kein
  interaktives Menü. Lese-Befehle (`--status`, `--datasets`, `--snapshots`,
  `--targets`, `--config-schema`, `--get-config`) bieten `--json`; Config und
  Ziele werden über `--set-config`, `--add/edit/delete/test-target` und die
  Maintenance-Flags (`--reset-*`, `--delete-logs`, `--thin-history`,
  `--delete-managed-snapshots`) gepflegt. Destruktive Aktionen verlangen
  `--yes`. Diese JSON-Schnittstelle ist die Datenquelle der Unraid-Plugin-GUI.

## Modell

Die **Quelle ist maßgeblich**. Ziele spiegeln ausschließlich den verwalteten
Snapshot-Bestand der Quelle.

* Pruning auf der Quelle bestimmt, welche Snapshots erhalten bleiben.
* Zielabgleich entfernt Ziel-Snapshots, die auf der Quelle fehlen.
* Ein Replikationsfehler blockiert das Pruning für das betroffene Dataset.
* Destruktive Aktionen auf Replikat-Zielen laufen nur unterhalb des jeweiligen
  `BASE_DATASET` und über die zentralen `assert_safe_*_target_dataset`-Prüfungen.

## Konventionen

* **Sprache:** Code-Kommentare, Logs, CLI-Ausgaben und Doku auf Deutsch.
* **Datumsformat:** überall deutsch `TT.MM.JJJJ HH:MM:SS`. Snapshotnamen bleiben
  ISO, z. B. `nas1_daily_2026-06-06_02-00`,
  `nas1_weekly_2026-W23_02-00`, `nas1_monthly_2026-06_02-00`,
  `nas1_yearly_2026_02-00`. Prefix konfigurierbar (`SNAPSHOT_PREFIX`).
* **Version:** datumsbasiert, Schema `<datum>.rNN` (Release, z. B.
  `2026.06.20.r01`; gleichtägiger Hotfix `r02`) bzw. `<datum>.<HHMM>dev` (Test).
  Auf Unraids **byteweisen `strcmp`-Vergleich** abgestimmt (nicht `version_compare`)
  → ein gleichtägiges `r01` wird einem `…dev` als Update angeboten (`'r'` > Ziffer).
  `plugin/build.sh` stempelt die Version beim Paketbau in `SCRIPT_VERSION` der
  installierten Kopie; im Repo ist `SCRIPT_VERSION` nur der Platzhalter `"0-dev"`
  und wird **nicht** manuell gepflegt. Tags laufen als Release-Marker parallel
  (siehe RELEASING.md).
* **Updates:** laufen über die Unraid-Plugin-Seite (`.plg`-Version); kein
  In-Skript-Update.
* **Config:** wird bei jedem Start geprüft und in ein dokumentiertes
  Standardformat normalisiert. Neue Optionen kommen ins zentrale
  `config_schema` (Gruppe|Name|Typ|Beschreibung) und werden in
  `create_default_config` + `write_normalized_config` gepflegt.

## Designvorgaben

* Sicherheit wichtiger als Geschwindigkeit.
* Keine stillen Fehler — jede Aktion protokollieren.
* Verständliche Statusmeldungen, für Heimanwender nachvollziehbar.
* Snapshot- und Replikationsstatistiken führen.
* Readonly-Backups unterstützen.

## Validierung

Nach Änderungen an `zfs-backup.sh`:

```bash
bash -n zfs-backup.sh        # Syntax
shellcheck zfs-backup.sh     # optional; SC2329/SC1090 sind bekannte False Positives
```

ZFS-Funktionalität lässt sich nur auf dem Unraid-Zielsystem real testen (macOS
hat kein ZFS und nur bash 3.2 — `local -n`-Warnungen dort sind harmlos).
