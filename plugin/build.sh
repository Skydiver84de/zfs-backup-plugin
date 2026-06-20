#!/bin/bash
# Baut das .txz-Paket des zfs-backup-Plugins aus den Repo-Dateien.
#
# AUF UNRAID ausführen (nutzt makepkg aus Slackware). Ergebnis liegt neben
# diesem Skript: zfs-backup-<version>.txz plus ausgegebene MD5-Summe.
#
#   bash plugin/build.sh                 # Release bauen (Version = heutiges Datum)
#   bash plugin/build.sh 2026.06.11      # Release bauen, Version explizit
#   bash plugin/build.sh --install       # Test-Build bauen UND installieren
#                                        #   -> Version "<datum>dev"; lässt die
#                                        #      committeten Release-Artefakte
#                                        #      (plugin/packages, plugin/*.plg)
#                                        #      bewusst unberührt
#
# Mit --install entfällt das manuelle Kopieren/Installieren. Ablauf:
#   1. vorhandene Installation entfernen (removepkg) – Config/Runtime bleiben,
#      da sie NICHT Teil des Pakets sind (liegen auf /boot bzw. cache/system),
#   2. frisch installieren (installpkg + install.sh),
#   3. .txz + .plg nach /boot/config/plugins kopieren (Boot-Persistenz/Plugins-Seite).
# So wird immer sauber neu installiert – ohne den `plugin install`-Befehl, der
# eine gleiche Version ablehnen würde. Eine Datumsversion genügt daher.
#
# Die Plugin-/Paket-Version ist datumsbasiert (Unraid-Konvention für den
# Update-Vergleich); die interne SCRIPT_VERSION im Skript ist davon getrennt.

set -euo pipefail

PLUGIN_NAME="zfs-backup"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

DO_INSTALL=0
VERSION=""
for arg in "$@"; do
    case "$arg" in
        --install) DO_INSTALL=1 ;;
        -*) echo "FEHLER: unbekannte Option: $arg" >&2; exit 1 ;;
        *)  VERSION="$arg" ;;
    esac
done
# Version: Release-Builds (ohne --install) sind datumsbasiert (Unraid-Konvention).
# Test-/Sideload-Builds (--install ohne explizite Version) bekommen das Suffix
# "dev" – sie sind bewusst KEIN offizieller Release und geben sich auch in der
# Plugins-Übersicht als Teststand zu erkennen. Eine explizit übergebene Version
# bleibt immer unverändert.
if [ -n "$VERSION" ]; then
    :
elif [ "$DO_INSTALL" -eq 1 ]; then
    VERSION="$(date +%Y.%m.%d)dev"
else
    VERSION="$(date +%Y.%m.%d)"
fi

command -v makepkg >/dev/null 2>&1 || {
    echo "FEHLER: makepkg nicht gefunden – dieses Skript auf Unraid ausführen." >&2
    exit 1
}
[ -f "$REPO_DIR/zfs-backup.sh" ] || {
    echo "FEHLER: zfs-backup.sh nicht gefunden unter $REPO_DIR" >&2
    exit 1
}

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Paket-Layout = Zielpfade auf dem System.
DEST="$STAGE/usr/local/emhttp/plugins/$PLUGIN_NAME"
mkdir -p "$DEST"
install -m 0755 "$REPO_DIR/zfs-backup.sh" "$DEST/zfs-backup.sh"
# Einzige Versionsquelle ist das Build-Datum (Unraid-Schema). Es wird hier in die
# gepackte/installierte Kopie gestempelt, damit `zfs-backup --version` exakt den
# gebauten Stand zeigt (Release = <datum>, Test = <datum>dev). Die Repo-Datei
# bleibt der Platzhalter "0-dev" – kein manuelles Versions-Pflegen mehr.
sed -i 's/^SCRIPT_VERSION=.*/SCRIPT_VERSION="'"$VERSION"'"/' "$DEST/zfs-backup.sh"
install -m 0755 "$SELF_DIR/install.sh"    "$DEST/install.sh"
install -m 0755 "$SELF_DIR/uninstall.sh"  "$DEST/uninstall.sh"
install -m 0755 "$SELF_DIR/schedule.sh"   "$DEST/schedule.sh"
install -m 0644 "$SELF_DIR/zfs-backup.completion" "$DEST/zfs-backup.completion"
install -m 0644 "$SELF_DIR/zfs-backup.svg"        "$DEST/zfs-backup.svg"
install -m 0644 "$SELF_DIR/zfs-backup.png"        "$DEST/zfs-backup.png"
install -m 0644 "$SELF_DIR/zfs-backup.page"       "$DEST/zfs-backup.page"
install -m 0644 "$SELF_DIR/zfs-backup-dashboard.page" "$DEST/zfs-backup-dashboard.page"
# Plugins-Seite zeigt diese README.md (als Markdown) als Beschreibung.
install -m 0644 "$SELF_DIR/package.README.md"     "$DEST/README.md"
# GUI-Endpoints (vom Formular per AJAX aufgerufen).
mkdir -p "$DEST/include"
install -m 0644 "$SELF_DIR/include/save.php"      "$DEST/include/save.php"
install -m 0644 "$SELF_DIR/include/targets.php"   "$DEST/include/targets.php"
install -m 0644 "$SELF_DIR/include/snapshots.php" "$DEST/include/snapshots.php"
install -m 0644 "$SELF_DIR/include/dataset-snapshots.php" "$DEST/include/dataset-snapshots.php"
install -m 0644 "$SELF_DIR/include/snapshot-tree.php" "$DEST/include/snapshot-tree.php"
install -m 0644 "$SELF_DIR/include/snapshot-browse.php" "$DEST/include/snapshot-browse.php"
install -m 0644 "$SELF_DIR/include/snapshot-file.php" "$DEST/include/snapshot-file.php"
install -m 0644 "$SELF_DIR/include/snapshot-restore.php" "$DEST/include/snapshot-restore.php"
install -m 0644 "$SELF_DIR/include/maintenance.php" "$DEST/include/maintenance.php"
install -m 0644 "$SELF_DIR/include/run.php"       "$DEST/include/run.php"
install -m 0644 "$SELF_DIR/include/logs.php"      "$DEST/include/logs.php"
install -m 0644 "$SELF_DIR/include/log-stream.php" "$DEST/include/log-stream.php"
install -m 0644 "$SELF_DIR/include/schedule.php"  "$DEST/include/schedule.php"
install -m 0644 "$SELF_DIR/include/dashboard-tile.php" "$DEST/include/dashboard-tile.php"

# Slackware-Paketbeschreibung (slack-desc): jede Zeile mit "name:" prefixen.
mkdir -p "$STAGE/install"
cat > "$STAGE/install/slack-desc" <<'DESC'
zfs-backup: zfs-backup (ZFS-Backup-Framework für Unraid)
zfs-backup:
zfs-backup: Snapshots, lokale und Remote-ZFS-Replikation, Pruning, Verify
zfs-backup: und Unraid-Benachrichtigungen als ein headless Bash-Skript.
zfs-backup: Konfiguration und Bedienung über die Plugin-GUI bzw. CLI.
zfs-backup:
zfs-backup:
zfs-backup:
zfs-backup:
zfs-backup:
zfs-backup:
DESC

OUT="$SELF_DIR/${PLUGIN_NAME}-${VERSION}.txz"
( cd "$STAGE" && makepkg -l y -c y "$OUT" >/dev/null )

MD5="$(md5sum "$OUT" | awk '{print $1}')"

# Fertiges .plg aus der Vorlage (.plg.in) erzeugen – mit Version + MD5. Die
# Vorlage bleibt unverändert (kein git-Konflikt); das erzeugte .plg ist
# gitignored.
PLG_IN="$SELF_DIR/${PLUGIN_NAME}.plg.in"
# Release-Build -> committete plugin/zfs-backup.plg erzeugen. Test-/Sideload-Build
# -> ephemere .plg im Stage-Verzeichnis, damit die versionierte .plg unberührt
# bleibt (ein Dev-Stand darf nie versehentlich als Release committet werden).
if [ "$DO_INSTALL" -eq 1 ]; then
    PLG="$STAGE/${PLUGIN_NAME}.plg"
else
    PLG="$SELF_DIR/${PLUGIN_NAME}.plg"
fi
if [ -f "$PLG_IN" ]; then
    sed \
        -e "s|<!ENTITY version[[:space:]]*\"[^\"]*\">|<!ENTITY version   \"${VERSION}\">|" \
        -e "s|<!ENTITY md5[[:space:]]*\"[^\"]*\">|<!ENTITY md5       \"${MD5}\">|" \
        "$PLG_IN" > "$PLG"
fi

# Für den öffentlichen Release: das gebaute Paket nach plugin/packages/ legen
# (von dort lädt es das .plg per raw-URL; dieser Ordner wird committet). Alte
# Pakete dort entfernen, damit immer nur die aktuelle Version im Repo liegt.
# Test-/Sideload-Builds (--install) lassen plugin/packages/ unberührt – sie
# sollen die committeten Release-Artefakte nicht überschreiben.
PKG_DIR="$SELF_DIR/packages"
if [ "$DO_INSTALL" -eq 0 ]; then
    mkdir -p "$PKG_DIR"
    rm -f "$PKG_DIR"/${PLUGIN_NAME}-*.txz
    cp -f "$OUT" "$PKG_DIR/"
fi

echo "Paket : $OUT"
[ "$DO_INSTALL" -eq 0 ] && echo "        -> $PKG_DIR/$(basename "$OUT") (fürs Repo/Release)"
if [ "$DO_INSTALL" -eq 1 ]; then
    echo "Version: $VERSION  (Test-/Sideload-Build, kein offizieller Release)"
else
    echo "Version: $VERSION"
fi
echo "MD5   : $MD5"
echo "Größe : $(du -h "$OUT" | awk '{print $1}')"
[ -f "$PLG" ] && echo "PLG   : $PLG (Version + MD5 eingetragen)"
echo

BOOT_PLUGIN_DIR="/boot/config/plugins/${PLUGIN_NAME}"
BOOT_PLG="/boot/config/plugins/${PLUGIN_NAME}.plg"

if [ "$DO_INSTALL" -eq 1 ]; then
    [ -f "$PLG" ] || { echo "FEHLER: $PLG nicht erzeugt – Installation abgebrochen." >&2; exit 1; }
    command -v plugin >/dev/null 2>&1 || { echo "FEHLER: 'plugin'-Befehl nicht gefunden (kein Unraid?)." >&2; exit 1; }

    PLUGIN_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}"

    echo "== Installation =="
    # 1. Vorhandene Installation entfernen. removepkg entfernt nur die Paket-
    #    dateien (Programm unter $PLUGIN_DIR). Config (/boot/config/plugins) und
    #    Runtime (cache/system) sind NICHT Teil des Pakets und bleiben erhalten.
    if ls /var/log/packages/${PLUGIN_NAME}-[0-9]* >/dev/null 2>&1; then
        echo "Entferne vorhandene Installation ..."
        for p in /var/log/packages/${PLUGIN_NAME}-[0-9]*; do
            [ -e "$p" ] && removepkg "$(basename "$p")" >/dev/null 2>&1 || true
        done
    fi

    # 2. Frisch installieren (installpkg kennt keine Versionssperre) + Setup.
    echo "Installiere ${PLUGIN_NAME} ${VERSION} ..."
    installpkg "$OUT"
    bash "$PLUGIN_DIR/install.sh"

    # 3. .txz + .plg nach /boot für Boot-Persistenz und die Plugins-Seite.
    mkdir -p "$BOOT_PLUGIN_DIR"
    rm -f "$BOOT_PLUGIN_DIR"/${PLUGIN_NAME}-*.txz   # alte Versionen im Boot-Ordner aufräumen
    cp -f "$OUT" "$BOOT_PLUGIN_DIR/"
    cp -f "$PLG" "$BOOT_PLG"

    echo
    echo "Fertig. GUI: Settings -> ZFS Backup   ·   CLI: zfs-backup --help"
else
    echo "A) Lokal bauen UND installieren (Sideload, zum Testen):"
    echo "   bash plugin/build.sh --install"
    echo
    echo "B) Öffentlichen Release veröffentlichen (Datums-Version, hier ${VERSION}):"
    echo "   1. bash plugin/build.sh            # nimmt das heutige Datum"
    echo "   2. git add -A plugin/packages plugin/${PLUGIN_NAME}.plg"
    echo "   3. git commit -m \"release: ${VERSION}\" && git push"
    echo "   Danach in Unraid installierbar über die .plg-URL:"
    echo "   https://raw.githubusercontent.com/Skydiver84de/zfs-backup-plugin/main/plugin/${PLUGIN_NAME}.plg"
fi
