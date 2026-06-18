#!/bin/bash
# zfs-backup Unraid-Plugin – Zeitplan (Cron).
#
# Plugin-Schicht, NICHT der portable Kern: das Zeitplanen ist Unraid-spezifisch
# (Cron-Datei + update_cron). Der Kern (zfs-backup.sh) weiß davon nichts; er wird
# nur über den Wrapper `--run` aufgerufen.
#
# Die Zeitplan-Werte liegen in der normalen Config (SCHEDULE_ENABLED/SCHEDULE_CRON).
# LESEN: direkt aus der conf geparst (leichtgewichtig, ohne Skriptstart – wichtig
# fürs `apply` beim Boot und `get` beim Tab-Öffnen). SCHREIBEN: über die CLI
# (--set-config), damit der Kern der einzige Schreiber der conf bleibt (atomar
# normalisiert, gleiche Routine wie der Konfig-Tab; keine zwei Schreiber/Races).
# Daraus erzeugt dieses Skript die native Unraid-Cron-Datei + update_cron.
#
# Modi:
#   schedule.sh get                  – aktuellen Zeitplan als JSON ausgeben
#   schedule.sh set <yes|no> <cron>  – validieren, in die Config schreiben, anwenden
#   schedule.sh apply                – aus der Config neu erzeugen (Boot/Sync)

set -o pipefail

PLUGIN_NAME="zfs-backup"
DATA_DIR="/boot/config/plugins/${PLUGIN_NAME}"     # Config (Flash, persistent)
CONF="${DATA_DIR}/${PLUGIN_NAME}.conf"             # Haupt-Config (enthält SCHEDULE_*)
# Cron-Datei im Plugin-Ordner. update_cron liest sie ein, weil das Plugin in
# /var/log/plugins registriert ist (Symlink auf die .plg) – im Release von Unraid
# selbst angelegt, beim Sideload von install.sh (siehe dort).
CRON_FILE="${DATA_DIR}/${PLUGIN_NAME}.cron"
CLI="/usr/local/sbin/${PLUGIN_NAME}"               # Wrapper (setzt Daten-/Runtime-Pfade)
WRAPPER="$CLI"                                       # Lauf-Aufruf in der Cron-Zeile
UPDATE_CRON="/usr/local/sbin/update_cron"

# Zeitplan-Werte direkt aus der conf lesen (kein Code ausführen – nur die beiden
# Skalare via sed). Fehlt etwas, gelten sichere Defaults (aus/leer).
SCHEDULE_ENABLED="no"
SCHEDULE_CRON=""
read_schedule() {
    SCHEDULE_ENABLED="no"
    SCHEDULE_CRON=""
    [ -f "$CONF" ] || return 0
    [ "$(sed -n 's/^SCHEDULE_ENABLED="\(.*\)"$/\1/p' "$CONF" | tail -1)" = "yes" ] \
        && SCHEDULE_ENABLED="yes"
    SCHEDULE_CRON=$(sed -n 's/^SCHEDULE_CRON="\(.*\)"$/\1/p' "$CONF" | tail -1)
}

# Veraltet-Schwelle (Stunden) aus der conf lesen; 0/ungültig -> 0 (Wächter aus).
read_stale_hours() {
    local v
    [ -f "$CONF" ] || { echo 0; return; }
    v=$(sed -n 's/^STALE_AFTER_HOURS=\(.*\)$/\1/p' "$CONF" | tail -1)
    case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

# Gültiger 5-Feld-Cron-Ausdruck mit ausschließlich unkritischen Zeichen
# ([0-9*,/ -]). Das schließt Befehls-Injektion über das Ausdrucksfeld aus.
valid_cron() {
    local expr="$1"
    local fields
    [ -n "$expr" ] || return 1
    [[ "$expr" =~ ^[0-9*,/[:space:]-]+$ ]] || return 1
    fields=$(awk '{print NF}' <<<"$expr")
    [ "$fields" -eq 5 ] || return 1
    return 0
}

# Cron-Datei aus den übergebenen Werten schreiben (oder entfernen) + aktivieren.
write_cron_file() {
    local enabled="$1"
    local cron="$2"
    local stale
    stale=$(read_stale_hours)
    if [ "$enabled" = "yes" ] && valid_cron "$cron"; then
        # Unraid-Cron-Format: 5 Zeitfelder + Befehl, OHNE Benutzerfeld (die Zeile
        # wird per `crontab` als root-Crontab installiert; ein „root" davor würde
        # als Teil des Befehls gelesen und scheitern).
        {
            echo "# zfs-backup – automatisch generiert, nicht von Hand editieren."
            echo "${cron} ${WRAPPER} --run >/dev/null 2>&1"
            # „Backup veraltet"-Wächter (stündlich) – nur bei aktivem Zeitplan und
            # STALE_AFTER_HOURS > 0. --check-stale ist billig und meldet nur einmal.
            [ "$stale" -gt 0 ] 2>/dev/null \
                && echo "0 * * * * ${WRAPPER} --check-stale >/dev/null 2>&1"
        } > "$CRON_FILE"
    else
        rm -f "$CRON_FILE"
    fi
    [ -x "$UPDATE_CRON" ] && "$UPDATE_CRON" >/dev/null 2>&1
    return 0
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

case "$1" in
    get)
        read_schedule
        local_active=false
        [ -f "$CRON_FILE" ] && local_active=true
        printf '{"enabled":%s,"cron":"%s","active":%s}\n' \
            "$([ "$SCHEDULE_ENABLED" = "yes" ] && echo true || echo false)" \
            "$(json_escape "$SCHEDULE_CRON")" \
            "$local_active"
        ;;
    set)
        enabled="$2"
        cron="$3"
        case "$enabled" in
            yes|no) ;;
            *) echo "FEHLER: enabled muss yes oder no sein." >&2; exit 1 ;;
        esac
        if [ "$enabled" = "yes" ] && ! valid_cron "$cron"; then
            echo "FEHLER: Ungültiger Cron-Ausdruck (5 Felder, nur Ziffern * , / -)." >&2
            exit 1
        fi
        # In die normale Config schreiben (eine Quelle der Wahrheit).
        "$CLI" --set-config SCHEDULE_ENABLED "$enabled" >/dev/null || {
            echo "FEHLER: SCHEDULE_ENABLED konnte nicht gespeichert werden." >&2; exit 1; }
        "$CLI" --set-config SCHEDULE_CRON "$cron" >/dev/null || {
            echo "FEHLER: SCHEDULE_CRON konnte nicht gespeichert werden." >&2; exit 1; }
        write_cron_file "$enabled" "$cron"
        echo "OK"
        ;;
    apply)
        read_schedule
        write_cron_file "$SCHEDULE_ENABLED" "$SCHEDULE_CRON"
        ;;
    *)
        echo "Aufruf: $0 {get | set <yes|no> <cron> | apply}" >&2
        exit 1
        ;;
esac
