# Changelog

## Unveröffentlicht

- **Ausdünnen behält je Typ einen Anker:** `--thin-history` reduziert die
  Historie nicht mehr auf einen einzelnen Daily, sondern behält je aktivem
  Snapshot-Typ (Retention > 0) genau einen Anker (hourly/daily/weekly/monthly/
  yearly). So bleibt der tiefe Anker (z. B. yearly) erhalten — wichtig fürs
  Reaktivierungs-Fenster deaktivierter Ziele. Vereinfacht zugleich den Code
  (kein `force_daily`-Sonderpfad mehr; das Seeding erzeugt die Anker).

- **Snapshot-Seeding:** Wöchentliche, monatliche und jährliche Snapshots werden
  nicht mehr nur am Kalenderstichtag (So. / 1. des Monats / 1.1.) erstellt,
  sondern sobald für die aktuelle Periode (ISO-Woche/Monat/Jahr) noch keiner
  existiert. Der Erstlauf legt damit sofort alle Stufen an (tiefer Anker ab
  Tag 1), und ein verpasster Stichtag (z. B. Server am 1.1. aus) heilt sich beim
  nächsten Lauf selbst.
- **Ziel-Reihenfolge:** Neue Befehle `--reorder-targets <id,id,...>` und
  `--move-target <id> <up|down>` legen die Backup-Reihenfolge der Ziele fest
  (erstes Ziel zuerst). Grundlage für das Sortieren der Ziele in der GUI.

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
