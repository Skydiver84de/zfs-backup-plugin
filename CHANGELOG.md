# Changelog

## 2026.07.23.r01 – Borg-Binary auf 1.4.5 aktualisiert

- **Borg 1.4.5:** Die mitgelieferte Borg-Binary wurde von 1.4.4 auf das
  Bugfix-Release 1.4.5 angehoben. Bestehende Repositories und Archive bleiben
  unverändert kompatibel. Beim nächsten Plugin-Update lädt die Box die neue Binary
  automatisch und verifiziert sie gegen die im Plugin hinterlegte Prüfsumme. Die
  Echtheit der Binary ist zusätzlich über die Provenance-Attestation von GitHub
  belegt. Voraussetzung ist nun glibc 2.35 oder neuer, was von der ohnehin
  vorausgesetzten Unraid-Version 6.12 aufwärts erfüllt wird.

## 2026.07.10.r01 – Hotfix: Plugin überlebt Reboots mit verschlüsseltem/manuell gestartetem Pool

- **Plugin bleibt nach dem Neustart installiert:** Wird das Array erst nach dem
  Boot manuell gestartet (etwa weil eine LUKS-Passphrase nötig ist) oder generell
  verzögert, war der ZFS-Pool zum Zeitpunkt der Plugin-Installation noch nicht da.
  Die Einrichtung brach dann mit einem Fehler ab, woraufhin Unraid das Plugin als
  fehlgeschlagen entfernte – es war nach jedem Neustart verschwunden und musste neu
  installiert werden. Die Einrichtung wird jetzt sauber auf den Moment des
  Array-Starts verschoben (sobald der Pool gemountet ist), sodass das Plugin einen
  Neustart zuverlässig übersteht.

## 2026.07.02.r03 – Snapshots prüfen: geprüfte Snapshot-Anzahl anzeigen

- **Snapshot-Anzahl im Prüfergebnis:** „Snapshots prüfen" (Wartung) vergleicht
  schon immer jeden einzelnen Snapshot mit dem Ziel; das Ergebnis nannte aber nur
  die Anzahl der Datasets. Es zeigt jetzt zusätzlich, wie viele Snapshots geprüft
  wurden – z. B. „23 Datasets / 428 Snapshots geprüft" – für Quelle, lokales,
  Remote- und Borg-Ziel.

## 2026.07.02.r02 – Hotfix: Snapshot-Anzeige nach Aufräumen und Ziel-Änderungen

- **Anzeige aktualisiert sich nach dem Aufräumen:** Nach dem Löschen eines
  verwaisten Datasets auf einem Remote- oder Borg-Ziel blieb das Dataset in der
  Snapshot-Übersicht stehen, bis man manuell „Live aktualisieren" drückte. Die
  Ansicht wird jetzt direkt nach dem Aufräumen korrekt neu aufgebaut.
- **Nicht erreichbare Ziele verschwinden nicht mehr aus der Anzeige:** Wenn ein
  Ziel gerade nicht erreichbar war (Remote schläft, Borg-Repository offline),
  konnte eine Aktion wie das Aufräumen auf einem anderen Ziel dessen
  Snapshot-Anzeige komplett leeren, obwohl die Sicherungen unverändert existieren.
  Solche Ziele behalten jetzt ihren letzten bekannten Stand, bis sie wieder
  erreichbar sind.
- **Korrekte Zuordnung nach Ziel-Änderungen:** Beim Löschen oder Umsortieren von
  Zielen werden die intern nach Ziel-Nummer benannten Anzeige-Daten sauber
  verworfen und neu aufgebaut – vorher konnte die Anzeige eines nicht erreichbaren
  Ziels nach einer Umnummerierung zum falschen Ziel gehören.
- **Schnellere Verwaisten-Prüfung:** Die Prüfung auf verwaiste Datasets (Wartung,
  Simulation, Lauf-Ende) arbeitet jetzt deutlich schneller – in der Praxis rund
  zehnmal so schnell, spürbar besonders bei vielen Datasets.

## 2026.07.02.r01 – Verwaiste Datasets: Borg, Anzeige und aufgeräumte Meldungen

- **Verwaiste Datasets bei Borg-Zielen:** Datasets, die aus dem Sicherungsumfang
  gefallen sind (Quell-Dataset gelöscht oder abgewählt), werden jetzt auch für
  Borg-Ziele erkannt, gemeldet und lassen sich über die Wartung aufräumen – bisher
  galt das nur für lokale und Remote-Ziele.
- **Verwaiste Datasets bleiben sichtbar:** In der Snapshot-Übersicht werden solche
  Datasets weiterhin angezeigt – farblich markiert mit dem Hinweis „verwaist" und
  alphabetisch an ihrer Stelle einsortiert – statt ausgeblendet zu werden. So sieht
  man auf einen Blick, wo noch alte Sicherungen liegen, und kann sie durchsuchen
  oder gezielt aufräumen.
- **Inhalt verwaister Datasets auch beim lokalen Ziel durchsuchbar:** Ein lokales
  Sicherungsziel, das gerade nicht eingehängt ist, wird fürs Durchsuchen nun bei
  Bedarf automatisch eingehängt – vorher blieb das Verzeichnis dort leer (bei
  Remote- und Borg-Zielen funktionierte es bereits).
- **Nur noch eine Lauf-Meldung:** Verwaiste Datasets stehen jetzt kurz in der
  normalen Erfolgs- bzw. Fehlermeldung, statt zusätzlich als eigene
  Benachrichtigung zu kommen (die bei vorhandenen Verwaisten bei jedem Lauf
  erschien). Die separate Verwaist-Benachrichtigung samt zugehöriger Einstellung
  entfällt.
- **Klarere Benachrichtigung:** Die Bilanz je Ziel ist nun einheitlich auf Datasets
  bezogen – auch bei Borg, mit der Archivzahl als Zusatz –, sodass die Ziele
  vergleichbar sind. Zusätzlich weist die Meldung die belegte Borg-Repository-Größe
  aus (dedupliziert und eigens gekennzeichnet, da eine andere Größe als der
  Snapshot-Speicher der ZFS-Ziele).
- **Dashboard-Kachel:** Die Zeile „Verwaiste Datasets / Snapshots" bricht bei Bedarf
  sauber um, statt sich mit dem Wert zu überschneiden.

## 2026.06.26.r03 – Borg-Anzeige und Benachrichtigung je Ziel

- **Borg bei „Aktive Ziele":** Borg-Ziele werden jetzt auf der Statusseite und im
  Dashboard-Kärtchen mitgezählt – vorher waren dort nur Lokal und Remote sichtbar.
- **Benachrichtigung je Ziel:** Die Replikations-Bilanz steht nun pro Ziel mit
  Namen – wie viele Datensätze bzw. Archive übertragen wurden, wie viele schon
  aktuell waren und wie viele Fehler – statt nur summiert pro Zieltyp.

## 2026.06.26.r02 – Borg-Lesecache: dynamisch statt fester Reserve

- **Borg-Lesecache verfeinert:** Die mit r01 eingeführte Reserve, die Borg davon
  abhält, unveränderte Dateien bei jedem Lauf neu zu lesen, wird jetzt automatisch
  passend zur Anzahl der gesicherten Snapshots gewählt statt fest hoch angesetzt.
  Das hält den Cache schlank und gibt den Speicher gelöschter Datensätze zeitnah
  wieder frei, während unveränderte Dateien zuverlässig übersprungen bleiben.

## 2026.06.26.r01 – Hotfix: Borg liest nicht mehr jeden Lauf alles neu

- **Borg-Lesecache korrigiert:** Borg verwarf seine Datei-Lesehistorie zu früh,
  wenn pro Lauf viele Datasets in dasselbe Repository gesichert werden. Dadurch
  wurde jedes Dataset – auch ein mehrere Terabyte großes – bei jedem Lauf komplett
  neu von der Platte gelesen statt nur der Änderungen. Der Cache hält die
  Leseinformationen jetzt dauerhaft, sodass unveränderte Dateien über Läufe hinweg
  zuverlässig übersprungen werden.

## 2026.06.25.r01 – Borg-Offsite-Backup

- **Neuer Zieltyp Borg:** Backups lassen sich jetzt zusätzlich in ein entferntes
  Borg-Repository spiegeln – etwa auf eine Hetzner Storage Box – verschlüsselt,
  dedupliziert und komprimiert. Mit Anbieter-Vorlagen für die Einrichtung,
  Datei-Browser samt Einzeldatei-Restore, Verify, Kapazitätsanzeige (frei und
  belegt) und automatischem Speicherfreigeben.
- **Robuste Übertragung:** unveränderte Dateien werden über Läufe hinweg nicht
  erneut gelesen, unterbrochene Übertragungen setzen am letzten Checkpoint fort,
  und transiente Aussetzer wie eine DSL-Zwangstrennung heilen sich per
  automatischem Neuversuch – mit denselben Einstellungen wie bei Remote-Zielen.
- **Lauf abbrechen:** ein laufender Backup-Lauf lässt sich jederzeit sauber
  stoppen, per Button in der GUI oder über die Kommandozeile.
- **Aktivitäts-Verlauf auf der Statusseite:** ein auf- und zuklappbares Panel zeigt
  Schritt für Schritt, was gerade läuft, und übersteht Tab-Wechsel und Neuladen.
- **Logbuch:** das angezeigte Tageslog ist auswählbar – heute live oder ältere
  Tage –, und jeder Schritt jedes Datasets und Archivs wird einheitlich
  protokolliert, durchgängig nachvollziehbar.
- **Mehr Sicherheit:** aus dem Sicherungsumfang gefallene Datasets werden nicht
  mehr automatisch gelöscht, sondern nur als verwaist gemeldet; fehlgeschlagene
  Aufräumschritte werden protokolliert statt still verschluckt.
- **Benachrichtigungen** schließen jetzt auch die Borg-Ziele ein.

## 2026.06.20.r01 – Seeding, sortierbare Ziele, frische Ausdünn-Anker

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
