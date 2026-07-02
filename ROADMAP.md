# Roadmap

## Abgeschlossen: Zieltyp `borg` (entferntes Borg-Repository als Offsite-Ziel)

> **Ausgeliefert** ab `2026.06.25.r01` (Folge-Releases bis `2026.06.26.r03`).
> Doku (README-Abschnitt „Borg-Ziel") und CHANGELOG sind gepflegt; nichts mehr
> offen. Der Abschnitt bleibt als Referenz zur Umsetzung stehen.

**Stand:** Engine + CLI + Config sind in `zfs-backup.sh` implementiert (Zieltyp
`borg`: `--add-target <label> borg <repo-url>`, `--edit-target … REPO/PASSPHRASE/
SSH_OPTIONS/COMPACT_EVERY`, `--test-target`). Replikation (`borg create` je
verwaltetem Snapshot aus `<mountpoint>/.zfs/snapshot/<snap>`), Zielabgleich
(löscht nur Archive im eigenen Namespace `<dataset>__<snap>`, nie fremde),
`borg compact` alle `COMPACT_EVERY` Läufe, Fehler blockiert das Quell-Pruning
des Datasets. Passphrase liegt als Config-Feld (conf bleibt 600). Ein gemeinsames
Repo hält mehrere Datasets namespaced (Wiederverwendung des bestehenden Repos).

**Erledigt:**
* **Docs/CHANGELOG:** README-Abschnitt „Borg-Ziel" und CHANGELOG-Einträge
  (ab `2026.06.25.r01`) gepflegt.
* **GUI-Datei-Browser + Einzeldatei-Restore für borg-Archive:** der Datei-Browser
  (`--snapshot-ls`/`--snapshot-cat`) unterstützt jetzt borg-Ziele – Auflisten je
  Verzeichnisebene über `borg list ::archiv <pfad>` (auf direkte Kinder gefiltert,
  gleiches Roh-Format wie lokal/remote), Vorschau/Download per `borg extract
  --stdout`, Einzeldatei-/Ordner-Restore in den `_restore`-Ordner des Quell-
  Datasets. Nur die vom Plugin verwalteten Archive (`<ds%>__<snap>`); fremde
  Archive im selben Repo verwaltet das Plugin bewusst NICHT (bei Bedarf direkt per
  borg-Terminalbefehlen).
* **borg-Versions-Update-Check (informativ):** vergleicht die installierte
  borg-Version mit der neuesten GitHub-Release (gecacht 1×/Tag), Hinweis in
  `--config-check`/GUI/`--borg-check-update`. Kein Auto-Update (Binary gepinnt;
  Major-Sprung = Repo-Format wird markiert).
* **Fortschritt bei der borg-Übertragung:** `borg create --log-json --progress`
  -> % gegen die referenzierte Snapshot-Größe in der Status-Box.
* **Verify** für borg-Ziele: `--verify-borg` bzw. in `--verify`/`--verify-target`
  (rein meldend – fehlende/zusätzliche Archive).
* **Restore (CLI)** aus borg-Archiven: `--snapshot-restore <quell-dataset>
  <snapshot> <borg-ziel-id> [<unterpfad>]` via `borg extract` in den
  `_restore`-Ordner (nicht destruktiv). Archive anzeigen: `--borg-archives`.
* **Binary-Bereitstellung:** `plugin/borg-setup.sh` lädt eine gepinnte,
  SHA256-verifizierte Standalone-Binary nach `<RUNTIME_DIR>/borg/` (Pool →
  persistent), ausgelöst von `install.sh` beim Array-Start (sofern ein borg-Ziel
  konfiguriert ist) bzw. bedarfsweise vom Skript.
* **GUI (PHP):** Zieltyp `borg` in der Ziele-Seite – Anlegen über „Ziel
  hinzufügen" (Typ borg), Bearbeiten (Repo, Passphrase, SSH-Optionen, Compact),
  Testen, Tabellen-/Status-Anzeige.
* **Snapshots-Seite:** borg-Ziele erscheinen wie remote als eigener Scope mit
  Datasets + Archiv-Zählungen; beim Aufklappen die einzelnen Archive mit
  Erstellzeit. Cache-basiert über `borg list` + Demangling `<ds%>__<snap>`. Nur
  die verwalteten Archive; fremde Archive im selben Repo werden ignoriert.
* **Kapazität:** borg-Ziele zeigen die deduplizierte Repo-Größe (belegt) aus
  `borg info` in der Kapazitätstabelle (kein Frei/Limit – Repo ohne festes Limit).
* **Archivgröße:** Größe je Archiv (original/dedupliziert) wird beim Erstellen per
  `borg info ::archive` ermittelt und persistent gecacht (ändert sich nie); alte
  Archive zieht der Abgleich begrenzt nach. Anzeige in den Spalten Größe/Belegt.
* **Anbieter-Vorlagen (Provider-Presets):** Datenquelle `--borg-providers --json`
  (Start: Hetzner Storage Box + generischer SSH-Host). Die GUI-Auswahl füllt
  Repo-URL-Muster und `SSH_OPTIONS` vor und zeigt die Einrichtungsschritte
  (Key-Upload via Hetzners `install-ssh-key`, `borg init`, Caveats). Weitere
  Anbieter (rsync.net, BorgBase) kommen als weitere Blöcke dazu.

### Ursprüngliche Planung (Referenz)

Ein zusätzlicher, **optionaler** Zieltyp neben den bestehenden ZFS-Zielen
(lokal/remote). Deckt die Lücke ab, die unsere `zfs send/recv`-Replikation nicht
abdeckt: ein **Offsite-Ziel, das selbst kein ZFS braucht** (rsync.net, BorgBase,
Hetzner Storage Box oder ein beliebiger SSH-Host mit `borg`).

Die bestehenden ZFS-Ziele bleiben unverändert das primäre, eigenschafts-
erhaltende Modell. Der borg-Zieltyp ist eine Ergänzung, kein Ersatz.

### Grundprinzip

* Borg arbeitet **dateibasiert mit Dedup**, nicht über `zfs send`. Der Snapshot
  dient nur als konsistenter Lesezustand.
* Wir nutzen **unsere bereits verwalteten** Snapshots als Quelle (kein eigener
  Wegwerf-Snapshot wie borgmatic): lesen über
  `<mountpoint>/.zfs/snapshot/<snap>/` — exakt der Pfad, den Datei-Browser und
  Restore schon verwenden (`snapshot_browse_root`, `resolve_snapshot_browse`).
* **„Quelle ist maßgeblich" bleibt erhalten:** `borg prune` kommt **nie** zum
  Einsatz. Stattdessen spiegelt der Zielabgleich unseren Snapshot-Bestand 1:1
  in borg-Archive — genau das Muster der bestehenden
  `prune_remote_extra_snapshots`.

### Archiv ↔ Snapshot-Mapping

* Pro verwaltetem Snapshot **ein borg-Archiv, benannt wie der Snapshot**
  (z. B. Archiv `nas1_daily_2026-06-06_02-00`).
* Ein Repo kann mehrere Datasets halten; Namensraum pro Dataset im Archivnamen
  (Design-Detail: Präfix `<dataset>__<snap>` oder ein Repo pro Quelle — Dedup
  wirkt nur innerhalb eines Repos).

### Lauf-Ablauf (pro Lauf)

1. **Replikation:** für jeden neuen Snapshot, der noch kein Archiv hat,
   `borg create <repo>::<archiv> <.zfs/snapshot-Pfad>`.
2. **Zielabgleich:** `borg list` → Archivnamen mit aktuellem verwaltetem
   Snapshot-Bestand der Quelle vergleichen; Archive zu nicht mehr existierenden
   Snapshots `borg delete`.
3. **Platz freigeben:** periodisch (nicht jeden Lauf) `borg compact` — Dedup
   gibt Speicher erst beim Compact frei.
* Ein borg-Fehler blockiert das Quell-Pruning des betroffenen Datasets, analog
  zur bestehenden Replikations-Fehlerbehandlung
  (`mark_remote_replication_failed`).

### Binary-Bereitstellung auf Unraid

* borg wird als **self-contained PyInstaller-Binary** ausgeliefert (eine Datei,
  keine Python-/Dependency-Installation). `borg-linuxnewer64` (glibc ≥ 2.28,
  Unraid 6.12+ ist neu genug).
* `/usr/local/bin` liegt auf tmpfs → bei jedem Boot weg. Binary deshalb **ins
  Plugin-Paket (`.txz`) bündeln**, die `.plg` legt sie bei jedem Array-Start ab
  (offline-fest, kein Re-Download). Ablageort der Binary: `<RUNTIME_DIR>/borg/`.
* **Kein `TMPDIR`-Override nötig:** die PyInstaller-Selbstentpackung nach
  Default-`/tmp` (tmpfs, exec) funktioniert auf Standard-Unraid.
* **borgs Cache/Config umlenken:** `BORG_BASE_DIR=<RUNTIME_DIR>/borg` — hält
  Chunk-Index, Config und Security-Dir gebündelt auf dem Pool (schont den
  USB-Stick, übersteht Reboots, Index beschleunigt Folgeläufe). Default wäre
  `/root/.cache/borg` bzw. `/root/.config/borg`.

### Offene Design-Entscheidungen / zu klären

* **Gegenseite braucht borg** (`borg serve` über SSH). Provider wie rsync.net /
  BorgBase / Hetzner liefern das fertig; eigener SSH-Host braucht borg
  installiert.
* Repo-Layout: ein Repo pro Quelle vs. ein gemeinsames Repo (Dedup-Reichweite
  vs. Isolation).
* Repo-Verschlüsselung / Passphrase-Handling (`BORG_PASSPHRASE`,
  `repokey`/`keyfile`) — wo wird das Secret gehalten?
* Config-Schema: neue `config_schema`-Einträge (Repo-URL, SSH-Ziel, Passphrase,
  Compact-Intervall) + Pflege in `create_default_config` /
  `write_normalized_config`.
* CLI: borg-Ziel in `--add/edit/delete/test-target` integrieren.
  `--test-target` prüft: borg-Binary ausführbar, Repo erreichbar
  (`borg info`/`borg list`), `BORG_BASE_DIR` beschreibbar.
* Verify/Restore-Pfad für borg-Archive (`borg extract` bzw. `borg mount`).
* Performance: voller Datei-Walk pro Archiv (kein Block-Inkrement wie
  `zfs send`), Dedup überträgt nur geänderte Chunks. borg-Aufrufe pro Lauf
  bündeln statt pro Dataset/Snapshot neu starten (Onefile re-extrahiert je
  Aufruf).
