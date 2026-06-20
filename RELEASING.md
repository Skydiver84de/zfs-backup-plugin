# Release-Prozess

Öffentliches Unraid-Plugin-Repo: **`Skydiver84de/zfs-backup-plugin`** (Branch
`main`). Unraid installiert/aktualisiert über die `.plg`-Datei im Repo; diese lädt
das `.txz`-Paket per raw-URL aus `plugin/packages/` und prüft es per MD5.

**Versionsschema** `JJJJ.MM.TT.rNN`, z. B. `2026.06.20.r01` (erstes Release des
Tages), `2026.06.20.r02` (gleichtägiger Hotfix), `2026.06.21.r01` usw. Dev-Builds
heißen `JJJJ.MM.TT.<HHMM>dev`. Das ist bewusst auf **Unraids Versionsvergleich
abgestimmt: Unraid nutzt für Plugins `strcmp` (byteweise), NICHT `version_compare`**
(das gilt nur fürs OS). Weil `'r'` byteweise größer ist als jede Ziffer und eine
Dev-HHMM mit `0`–`2` beginnt, wird ein gleichtägiges `…​.r01` einem `…​.HHMMdev`
korrekt als Update angeboten; Hotfixes zählen via Nullpolsterung sauber hoch
(`r01 < r02 < … < r09 < r10`), das Datum dominiert über Tage.

Quelle ist allein das **Build-Datum**: `build.sh` stempelt die Version beim
Paketbau in die installierte Kopie (`SCRIPT_VERSION`), in den `.txz`-Dateinamen und
ins `.plg`. Im Repo bleibt `SCRIPT_VERSION` der Platzhalter `"0-dev"` — **nicht**
manuell pflegen. Nur der CHANGELOG-Kopf wird von Hand ergänzt.

## Wichtig: das `.txz` wird auf Unraid gebaut

`plugin/build.sh` nutzt `makepkg` und läuft **nur auf Unraid** (nicht auf macOS).
Ohne Argument baut es ein Release `<heutiges-datum>.r01`; für einen gleichtägigen
Hotfix `build.sh r02` (Kurzform → `<datum>.r02`, nullgepolstert).

**Test- vs. Release-Build:** `build.sh --install` (lokaler Sideload zum Testen)
erzeugt eine Dev-Version `<datum>.<HHMM>dev` und lässt die committeten
Release-Artefakte (`plugin/packages/`, `plugin/zfs-backup.plg`) **unberührt** – ein
Teststand kann so nie versehentlich als Release committet werden. Nur der
Release-Build (`build.sh` **ohne** `--install`) schreibt in diese Dateien. Eine
explizit übergebene Vollversion (`build.sh 2026.06.20.r01`) wird unverändert
übernommen.

## Schritte

Annahme: Version `JJJJ.MM.TT.rNN` (z. B. `2026.06.21.r01`).

1. **CHANGELOG-Kopf** `## JJJJ.MM.TT.rNN – <Stichwort>` ergänzen; `bash -n zfs-backup.sh`
   prüfen, committen, pushen. (Die Version selbst wird **nicht** im Skript gesetzt —
   `build.sh` stempelt sie beim Bauen.)

2. **Auf Unraid** bauen:
   ```bash
   git clone https://github.com/Skydiver84de/zfs-backup-plugin.git   # oder: git pull
   cd zfs-backup-plugin
   bash plugin/build.sh            # -> <datum>.r01  (gleichtägiger Hotfix: build.sh r02)
   ```
   Ergebnis: `plugin/packages/zfs-backup-<datum>.r01.txz` + `plugin/zfs-backup.plg`.

3. **`.txz` + `.plg` committen** (von Unraid mit git-Push-Zugang, sonst die beiden
   Dateien auf den Rechner mit `gh`-Login kopieren und dort committen). Das alte
   Paket aus `plugin/packages/` entfernen (build.sh räumt es beim Bauen selbst auf):
   ```bash
   git add -A plugin/packages plugin/zfs-backup.plg
   git commit -m "release: <version>"
   git push origin main
   ```

4. **Tag + GitHub-Release** (optional, als Marker; Installation läuft über raw-URL):
   ```bash
   git tag -a <version> -m "<version>" && git push origin <version>
   awk '/^## <version>/{f=1; next} /^## /&&f{exit} f' CHANGELOG.md \
     | gh release create <version> --verify-tag --title "<version>" --notes-file -
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
