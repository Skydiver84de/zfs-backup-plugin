# Release-Prozess

Öffentliches Unraid-Plugin-Repo: **`Skydiver84de/zfs-backup-plugin`** (Branch
`main`). Unraid installiert/aktualisiert über die `.plg`-Datei im Repo; diese lädt
das `.txz`-Paket per raw-URL aus `plugin/packages/` und prüft es per MD5.

**Eine** Versionsnummer, **datumsbasiert** (Unraid-Konvention), z. B. `2026.06.18`
(bei mehreren Releases am selben Tag ein Suffix: `2026.06.18a`). Quelle ist allein
das **Build-Datum**: `build.sh` stempelt es beim Paketbau in die installierte
Kopie (`SCRIPT_VERSION`), in den `.txz`-Dateinamen und ins `.plg`. Im Repo bleibt
`SCRIPT_VERSION` der Platzhalter `"0-dev"` — **nicht** manuell pflegen. Nur der
CHANGELOG-Kopf wird von Hand mit der Datums-Version ergänzt.

## Wichtig: das `.txz` wird auf Unraid gebaut

`plugin/build.sh` nutzt `makepkg` und läuft **nur auf Unraid** (nicht auf macOS).
Ohne Argument nimmt es automatisch das heutige Datum als Version.

**Test- vs. Release-Build:** `build.sh --install` (lokaler Sideload zum Testen)
erzeugt eine Version mit Suffix `dev` (z. B. `2026.06.20dev`) und lässt die
committeten Release-Artefakte (`plugin/packages/`, `plugin/zfs-backup.plg`)
**unberührt** – ein Teststand kann so nie versehentlich als Release committet
werden. Nur der Release-Build (`build.sh` **ohne** `--install`) schreibt eine
saubere Datums-Version in diese Dateien. Eine explizit übergebene Version
(`build.sh 2026.06.20`) wird immer unverändert übernommen.

## Schritte

Annahme: Version `JJJJ.MM.TT`.

1. **CHANGELOG-Kopf** `## JJJJ.MM.TT – <Stichwort>` ergänzen; `bash -n zfs-backup.sh`
   prüfen, committen, pushen. (Die Version selbst wird **nicht** im Skript gesetzt —
   `build.sh` stempelt sie aus dem Datum.)

2. **Auf Unraid** bauen:
   ```bash
   git clone https://github.com/Skydiver84de/zfs-backup-plugin.git   # oder: git pull
   cd zfs-backup-plugin
   bash plugin/build.sh            # nimmt das heutige Datum (oder: build.sh JJJJ.MM.TT)
   ```
   Ergebnis: `plugin/packages/zfs-backup-<datum>.txz` + `plugin/zfs-backup.plg`.

3. **`.txz` + `.plg` committen** (von Unraid mit git-Push-Zugang, sonst die beiden
   Dateien auf den Rechner mit `gh`-Login kopieren und dort committen). Das alte
   Paket aus `plugin/packages/` entfernen (build.sh räumt es beim Bauen selbst auf):
   ```bash
   git add -A plugin/packages plugin/zfs-backup.plg
   git commit -m "release: <datum>"
   git push origin main
   ```

4. **Tag + GitHub-Release** (optional, als Marker; Installation läuft über raw-URL):
   ```bash
   git tag -a <datum> -m "<datum>" && git push origin <datum>
   awk '/^## <datum>/{f=1} f' CHANGELOG.md | gh release create <datum> --verify-tag --title "<datum>" --notes-file -
   ```

## Installation in Unraid

Plugins-Seite → **Install Plugin** → URL:
```
https://raw.githubusercontent.com/Skydiver84de/zfs-backup-plugin/main/plugin/zfs-backup.plg
```
Updates erscheinen automatisch, sobald eine neuere (= spätere) Datums-Version im
Repo liegt.

## Git-Identität

Commits laufen unter der global konfigurierten git-Identität (`git config user.*`).
