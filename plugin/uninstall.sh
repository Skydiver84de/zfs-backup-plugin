#!/bin/bash
# zfs-backup Unraid-Plugin – Entfernen.
#
# Standardmäßig werden nur Programm-Teile entfernt (Wrapper + Plugin-Dir).
# Config (DATA_DIR) und der Runtime-Ordner bleiben erhalten, damit eine
# Neuinstallation nahtlos weiterläuft. Mit --purge wird auch das entfernt.

PLUGIN_NAME="zfs-backup"
PLUGIN_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}"
DATA_DIR="/boot/config/plugins/${PLUGIN_NAME}"
WRAPPER="/usr/local/sbin/${PLUGIN_NAME}"

SYS_MNT=$(zfs get -H -o value mountpoint cache/system 2>/dev/null)
RUNTIME_DIR="${SYS_MNT:-/mnt/cache/system}/zfs-backup"

rm -f "$WRAPPER"
rm -f /etc/bash_completion.d/zfs-backup
rm -rf "$PLUGIN_DIR"
echo "Wrapper, Bash-Completion und Plugin-Verzeichnis entfernt."

# Plugin-Registrierung (Symlink in /var/log/plugins) entfernen. Bei einem regulären
# Remove über die Plugins-Seite macht Unraid das selbst; fürs Sideload hier mit.
rm -f "/var/log/plugins/${PLUGIN_NAME}.plg"

# Cron deaktivieren: die generierte .cron-Datei entfernen und Unraids Cron neu
# laden (sonst feuerte der Zeitplan einen nicht mehr vorhandenen Wrapper). Die
# Zeitplan-Wahl steht in der Config (SCHEDULE_*) und bleibt ohne --purge erhalten;
# eine Neuinstallation erzeugt die .cron daraus wieder (install.sh -> schedule.sh apply).
CRON_FILE="${DATA_DIR}/${PLUGIN_NAME}.cron"
if [ -f "$CRON_FILE" ]; then
    rm -f "$CRON_FILE"
    [ -x /usr/local/sbin/update_cron ] && /usr/local/sbin/update_cron >/dev/null 2>&1
    echo "Cron-Zeitplan deaktiviert."
fi

if [ "$1" = "--purge" ]; then
    rm -rf "$DATA_DIR"
    rm -rf "$RUNTIME_DIR"
    echo "Config ($DATA_DIR) und Runtime-Ordner ($RUNTIME_DIR) ebenfalls entfernt (--purge)."
else
    echo "Config ($DATA_DIR) und Runtime-Ordner ($RUNTIME_DIR) bleiben erhalten."
    echo "Zum vollständigen Entfernen (dieses Script ist nach dem Plugin-Remove weg)"
    echo "diese Ordner manuell löschen:"
    echo "  rm -rf \"$DATA_DIR\" \"$RUNTIME_DIR\""
fi
