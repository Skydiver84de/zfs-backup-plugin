#!/bin/bash
# zfs-backup Unraid-Plugin – Install-/Setup-Logik.
#
# Prüft Voraussetzungen, legt das Runtime-Dataset an und verdrahtet die Pfade.
# Idempotent: läuft im Plugin-Kontext bei jedem Boot erneut (Unraid-Konvention)
# und darf das gefahrlos. Lässt sich auch manuell aus dem git-Clone testen.

set -o pipefail

PLUGIN_NAME="zfs-backup"
PLUGIN_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}"   # Programm (Update überschreibt das)
DATA_DIR="/boot/config/plugins/${PLUGIN_NAME}"          # Config (Flash, persistent)
SYSTEM_DS="cache/system"                                # muss ein Dataset sein
RUNTIME_SUBDIR="zfs-backup"                             # Ordner unter cache/system
WRAPPER="/usr/local/sbin/${PLUGIN_NAME}"               # CLI-Aufruf mit gesetzten Pfaden

fail() { echo "FEHLER: $*" >&2; exit 1; }

echo "== zfs-backup Plugin-Setup =="

# 1. ZFS vorhanden?
command -v zfs >/dev/null 2>&1 || fail "ZFS (zfs-Befehl) nicht gefunden."

# 2. cache/system MUSS ein Dataset sein (siehe README). Sonst lägen Logs/State
#    – und Docker/libvirt – im selben Dataset wie sicherungswürdige Daten.
if ! zfs list -H -o name "$SYSTEM_DS" >/dev/null 2>&1; then
    echo
    echo "ABBRUCH: '$SYSTEM_DS' ist kein ZFS-Dataset."
    echo
    echo "Das Plugin legt sein Runtime-Verzeichnis unter '$SYSTEM_DS' ab, das"
    echo "(zusammen mit Docker/libvirt) von der Sicherung ausgeschlossen wird."
    echo "Dafür muss '$SYSTEM_DS' ein eigenes Dataset sein."
    echo
    echo "Bitte zuerst '$SYSTEM_DS' als Dataset anlegen – Details in der README."
    echo
    exit 1
fi

# 3. Runtime-Verzeichnis als ORDNER unter cache/system. Kein eigenes Dataset
#    nötig: cache/system wird als Ganzes ausgeschlossen, der Ordner damit auch.
SYS_MNT=$(zfs get -H -o value mountpoint "$SYSTEM_DS")
[ -n "$SYS_MNT" ] && [ "$SYS_MNT" != "-" ] || fail "Mountpoint von $SYSTEM_DS nicht ermittelbar."
RUNTIME_DIR="${SYS_MNT}/${RUNTIME_SUBDIR}"
mkdir -p "$RUNTIME_DIR" || fail "Konnte Runtime-Verzeichnis nicht anlegen: $RUNTIME_DIR"
echo "Runtime-Verzeichnis: $RUNTIME_DIR"

# 4. Verzeichnisse sicherstellen
mkdir -p "$DATA_DIR" "$PLUGIN_DIR" || fail "Konnte Verzeichnisse nicht anlegen."

# 5. Skript bereitstellen. Im echten Plugin liegt zfs-backup.sh bereits via .txz
#    im PLUGIN_DIR; beim manuellen Test aus dem Clone kopieren wir es dorthin.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC=""
for cand in "$SELF_DIR/zfs-backup.sh" "$SELF_DIR/../zfs-backup.sh"; do
    [ -f "$cand" ] && { SRC="$cand"; break; }
done
[ -n "$SRC" ] || fail "zfs-backup.sh nicht gefunden (neben install.sh oder eine Ebene höher)."
if [ "$SRC" != "$PLUGIN_DIR/zfs-backup.sh" ]; then
    cp -f "$SRC" "$PLUGIN_DIR/zfs-backup.sh" || fail "Konnte zfs-backup.sh nicht installieren."
fi
chmod +x "$PLUGIN_DIR/zfs-backup.sh"

# 5b. Borg-Binary bereitstellen – aber NUR, wenn ein borg-Ziel konfiguriert ist
#     (sonst lädt niemand ~30 MB ohne Grund). Idempotent: borg-setup.sh prüft die
#     Checksumme und lädt nur bei fehlender/abweichender Datei. Liegt auf dem Pool
#     (RUNTIME_DIR) -> persistent, also real nur einmal pro Pool. Schlägt der
#     Bezug fehl (kein Netz beim Boot), bricht das Setup NICHT ab; borg-Ziele
#     melden dann „Binary nicht gefunden", alles andere läuft normal weiter.
CONF="$DATA_DIR/zfs-backup.conf"
BORG_SETUP=""
for cand in "$SELF_DIR/borg-setup.sh" "$PLUGIN_DIR/borg-setup.sh"; do
    [ -f "$cand" ] && { BORG_SETUP="$cand"; break; }
done
if [ -n "$BORG_SETUP" ] && [ -f "$CONF" ] && grep -q 'TYPE="borg"' "$CONF" 2>/dev/null; then
    echo "Borg-Ziel konfiguriert -> borg-Binary sicherstellen ..."
    ZFS_BACKUP_RUNTIME_DIR="$RUNTIME_DIR" bash "$BORG_SETUP" "$RUNTIME_DIR" \
        || echo "WARNUNG: borg-Binary konnte nicht bereitgestellt werden (siehe oben)."
fi

# 6. Wrapper anlegen: setzt Daten-/Runtime-Pfade und ruft das Skript.
cat > "$WRAPPER" <<EOF
#!/bin/bash
# Auto-generiert vom zfs-backup Plugin-Setup. Setzt die Pfade und ruft das
# eigentliche Skript. Nicht von Hand editieren.
export ZFS_BACKUP_DATA_DIR="$DATA_DIR"
export ZFS_BACKUP_RUNTIME_DIR="$RUNTIME_DIR"
exec "$PLUGIN_DIR/zfs-backup.sh" "\$@"
EOF
chmod +x "$WRAPPER"

# 7. Plugin in /var/log/plugins registrieren (Symlink auf die .plg). Unraids
#    update_cron liest die Cron-Datei eines Plugins NUR, wenn dort ein <name>.plg
#    eintrag existiert. Beim regulären Install und bei jedem Boot legt Unraid
#    diesen Symlink selbst an (rc.local -> `plugin install` je .plg in
#    /boot/config/plugins). Hier nur fürs Sideload via build.sh (am Plugin-Manager
#    vorbei, kein Reboot) – damit der Zeitplan sofort greift. Idempotent, exakt das
#    von Unraid genutzte Konstrukt; der Symlink genügt update_cron (Name-basiert).
PLG_LINK="/var/log/plugins/${PLUGIN_NAME}.plg"
mkdir -p /var/log/plugins
ln -sf "/boot/config/plugins/${PLUGIN_NAME}.plg" "$PLG_LINK"

# 8. Zeitplan (Cron) aus der persistierten Konfiguration anwenden. Idempotent;
#    läuft nach der Registrierung oben, damit update_cron die Cron-Datei sieht.
SCHEDULE_SH="$PLUGIN_DIR/schedule.sh"
if [ -f "$SCHEDULE_SH" ]; then
    bash "$SCHEDULE_SH" apply && echo "Zeitplan angewendet (falls konfiguriert)."
fi

# 8. Bash-Completion installieren (falls mitgeliefert).
COMPLETION_SRC=""
for cand in "$SELF_DIR/zfs-backup.completion" "$PLUGIN_DIR/zfs-backup.completion"; do
    [ -f "$cand" ] && { COMPLETION_SRC="$cand"; break; }
done
if [ -n "$COMPLETION_SRC" ]; then
    mkdir -p /etc/bash_completion.d
    cp -f "$COMPLETION_SRC" /etc/bash_completion.d/zfs-backup
    echo "Bash-Completion installiert: /etc/bash_completion.d/zfs-backup"
fi

echo
echo "Fertig. Aufruf künftig über:  $PLUGIN_NAME --status   (Wrapper: $WRAPPER)"
echo "  Config (gesichert):    $DATA_DIR"
echo "  Runtime (ausgeschl.):  $RUNTIME_DIR   [Ordner unter $SYSTEM_DS]"
echo
