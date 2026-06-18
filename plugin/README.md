# zfs-backup – Unraid-Plugin

Verpackung + Web-GUI für Unraid. Der Backup-Code bleibt das eine Skript
`../zfs-backup.sh`; das Plugin installiert es, verdrahtet die Pfade und liefert
die GUI. Jede GUI-Seite ruft **ausschließlich** die headless-CLI über den Wrapper
(`/usr/local/sbin/zfs-backup … --json`) — kein ZFS-/Backup-Code im PHP.

## Voraussetzung: `cache/system` muss ein ZFS-Dataset sein

Die Laufzeitdaten (Logs/State) liegen im Ordner `cache/system/zfs-backup`.
`cache/system` (Docker/libvirt) wird vom Backup **fest ausgeschlossen** — das
funktioniert aber nur als Dataset-Grenze, wenn `cache/system` ein eigenes Dataset
ist (auf Unraid 6.12+ üblich). Ist es nur ein Ordner, vorab als Dataset anlegen.
Die Installation **bricht ab**, wenn es kein Dataset ist (`zfs list cache/system`).

## Pfade

| Zweck | Ort | Gesichert? |
|---|---|---|
| Programm (Skript + PHP) | `/usr/local/emhttp/plugins/zfs-backup/` | nein (Update überschreibt) |
| Config | `/boot/config/plugins/zfs-backup/` | ja (Teil von flash/boot) |
| Logs/State (Runtime) | `cache/system/zfs-backup` (Ordner) | nein (unter ausgeschlossenem `cache/system`) |

## Bauen & installieren

`plugin/build.sh` baut das Slackware-Paket (`.txz`) aus den Repo-Dateien —
**auf Unraid** (nutzt `makepkg`) — und füllt das `.plg` (Version + MD5):

```bash
bash plugin/build.sh             # nur bauen (Version = heutiges Datum)
bash plugin/build.sh 2026.06.11  # Version explizit
bash plugin/build.sh --install   # bauen UND sauber neu installieren (Sideload)
```

`--install` entfernt die alte Installation (`removepkg` – **Config/Runtime
bleiben**), installiert frisch (`installpkg` + `install.sh`) und kopiert
`.txz` + `.plg` nach `/boot/config/plugins` (Boot-Persistenz, Plugins-Seite). Die
Paketversion ist datumsbasiert (Unraid-Update-Vergleich) und unabhängig von der
internen `SCRIPT_VERSION`.

Manuell ohne `.plg`:

```bash
bash plugin/install.sh        # prüft, legt Runtime-Ordner an, installiert Skript + Wrapper
zfs-backup --config-check     # über den Wrapper (Pfade gesetzt), zeigt Pfade + Auto-Exclude
bash plugin/uninstall.sh           # Wrapper + Plugin-Dir entfernen (Config/Runtime bleiben)
bash plugin/uninstall.sh --purge   # zusätzlich Config + Runtime entfernen
```

Über die **Plugins-Seite**: `.plg` löst dieselben Schritte aus (MD5,
`upgradepkg`, `install.sh`, Boot-Persistenz, Remove-Hook). Im Sideload-Betrieb
liegt das `.txz` lokal unter `/boot/config/plugins/zfs-backup/` (kein Download).

## Web-GUI

Eine `zfs-backup.page` (Menü **Settings → ZFS Backup**) mit Tabs: **Status**
(inkl. „Lauf starten"/„Simulieren", Kapazität, Veraltet-Warnung), **Konfiguration**,
**Ziele**, **Snapshots** (inkl. Datei-Browser + Restore), **Wartung**, **Logs**,
**Zeitplan**. PHP-Endpunkte unter `include/` sind reiner Transport zum Wrapper;
Live-Ausgaben laufen per Server-Sent-Events. Beim Laden ruft die Seite den Kern
nur **einmal** auf (`--gui-init --json`, ein Aggregat statt fünf Einzelaufrufe).

Zusätzlich `zfs-backup-dashboard.page` + `include/dashboard-tile.php`: eine
**Kachel auf der Unraid-Hauptseite** (Kurzstatus) nach Vorbild des
Tailscale-Plugins – `$mytiles[...]['column2']` + `try/catch`, liest nur
`--status --json`.

Icons rendert Unraid als **PNG**: Logo doppelt als `zfs-backup.svg` (Seitenkopf)
und `zfs-backup.png` (128×128, Menü/Plugins-Liste; `.plg` `icon=`). Die
Kurzbeschreibung auf der Plugins-Seite kommt aus `package.README.md`.

## Bash-Completion

`install.sh` installiert eine Completion (`/etc/bash_completion.d/zfs-backup`):
Befehle/Flags und kontextabhängig Ziel-IDs bzw. Options-Namen über die
headless-Schnittstelle.

## Offen

* Öffentliche Verteilung: `.txz` als GitHub-Release-Asset + `.plg` mit `<URL>`
  für Community Applications (siehe [../ROADMAP.md](../ROADMAP.md)).
