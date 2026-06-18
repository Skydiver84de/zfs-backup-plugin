# Changelog

## 2026.06.18 – Erstes Release

Erstes Release. ZFS-Backup-Framework für Unraid als natives Plugin mit Web-GUI.

- **Snapshots** je Typ (stündlich, täglich, wöchentlich, monatlich, jährlich) mit
  konfigurierbarer Aufbewahrung. Die Quelle ist maßgeblich; aktive Ziele werden an
  ihren verwalteten Snapshot-Bestand angeglichen.
- **Replikation** lokal und auf einen Remote-Host (SSH, Wake-on-LAN, fortsetzbare
  Übertragungen). Pruning und Verify (nur lesend).
- **Restore** von Datei, Ordner oder ganzem Snapshot – aus der Quelle und aus
  Replikaten (lokal/remote). Nicht destruktiv in einen `_restore`-Ordner, mit
  Fortschrittsanzeige. Anleitung für die vollständige Dataset-Wiederherstellung in
  der README.
- **Verwaiste Ziel-Datasets** werden erkannt und gemeldet, aber nie automatisch
  gelöscht; Aufräumen nur manuell mit Bestätigung.
- **Web-GUI** (Settings → ZFS Backup): Status mit „Lauf starten" und „Simulieren",
  Kapazitätsanzeige, Veraltet-Warnung, Konfiguration, Ziele, Snapshots mit
  Datei-Browser, Wartung, Logs (live) und Zeitplan (Cron).
- **Dashboard-Kachel** mit Kurzstatus auf der Unraid-Hauptseite.
- **Benachrichtigungen** über die native Unraid-Notification-Zentrale, je Ereignis
  abstufbar, plus Wächter gegen stillen Ausfall.
- **Headless-CLI** (`zfs-backup --help`) mit JSON-Ausgaben für alle Lese-Befehle.
