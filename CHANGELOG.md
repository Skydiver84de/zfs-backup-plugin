# Changelog

## 2026.06.20 – Seeding, sortierbare Ziele, frische Ausdünn-Anker

- **Snapshot-Seeding** legt wöchentliche, monatliche und jährliche Snapshots an,
  sobald die Periode noch keinen hat – nicht erst am Stichtag. Verpasste Stichtage
  (Server aus) heilen sich beim nächsten Lauf selbst.
- **Sortierbare Ziele:** die Backup-Reihenfolge lässt sich festlegen – per CLI und
  mit Auf/Ab-Buttons in der GUI.
- **Ausdünnen mit frischen Ankern** behält je aktivem Typ einen frischen Anker
  statt nur einem Daily. Der tiefe Jahres-Anker bleibt erhalten, der belegte Platz
  ist danach minimal.
- **Mehr Live-Fortschritt:** Wartungsaktionen zeigen den Fortschritt jetzt Schritt
  für Schritt, bei größeren Übertragungen zusätzlich in 25-%-Schritten.
- **Snapshots nach Typ gruppiert** in der GUI, plus diverse Status- und
  Anzeige-Verbesserungen.

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
