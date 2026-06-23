#!/bin/bash

set -o pipefail

########################################
# ZFS Backup Framework
########################################

# Reiner Platzhalter: die echte Version ist datumsbasiert (Unraid-Schema) und
# wird beim Paketbau in die installierte Kopie gestempelt (plugin/build.sh).
# Aus einem reinen Repo-Checkout (ungebaut) zeigt --version daher "0-dev".
SCRIPT_VERSION="0-dev"

readonly SCRIPT_PATH="$(realpath "$0")"
# Skriptverzeichnis und Datenverzeichnis sind getrennt: im Plugin-Kontext wird
# das Skriptverzeichnis bei Updates überschrieben, daher liegen Config (DATA_DIR)
# und Laufzeitdaten (Logs/State/Lock im RUNTIME_DIR) woanders. Steuerbar über die
# Umgebungsvariable ZFS_BACKUP_DATA_DIR; Standalone-Default = Skriptverzeichnis.
readonly SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
readonly DATA_DIR="${ZFS_BACKUP_DATA_DIR:-$SCRIPT_DIR}"
# Schreiblastige Laufzeitdaten (Logs/State/Lock) lassen sich optional auf einen
# Pool auslagern (ZFS_BACKUP_RUNTIME_DIR), um einen USB-Boot-Stick zu schonen.
# Default = DATA_DIR. INVARIANTE: weder DATA_DIR noch RUNTIME_DIR liegen je im
# Skriptverzeichnis – ein Plugin-Update (das nur das Skriptverzeichnis
# überschreibt) lässt sie damit unangetastet.
readonly RUNTIME_DIR="${ZFS_BACKUP_RUNTIME_DIR:-$DATA_DIR}"

# Datasets (inkl. aller Kinder), die grundsätzlich nie gesichert werden. Fest
# vorgegeben: das Plugin zielt immer auf cache/system – damit bleiben Docker/
# libvirt UND das darin liegende Runtime-Verzeichnis garantiert aus den
# Snapshots. Keine eigene Option nötig.
readonly FORCE_EXCLUDES=("cache/system")

readonly CONFIG_FILE="${DATA_DIR}/zfs-backup.conf"

# Schreiblastige Laufzeitdaten liegen alle im RUNTIME_DIR: Logs, State und das
# Lock (PID-Datei, wird bei jedem Lauf geschrieben; gehört zum Run-State wie
# run_progress, das release_lock ebenfalls aus dem STATE_DIR entfernt).
readonly LOCK_DIR="${RUNTIME_DIR}/lock"
readonly LOG_DIR="${RUNTIME_DIR}/logs"
readonly STATE_DIR="${RUNTIME_DIR}/state"

readonly DATASET_STATE_DIR="${STATE_DIR}/datasets"

LOCK_FILE="${LOCK_DIR}/zfs-backup.pid"

SIMULATE=0
RUN_ERRORS=0
CREATED_HOURLY=0
CREATED_DAILY=0
CREATED_WEEKLY=0
CREATED_MONTHLY=0
CREATED_YEARLY=0
DELETED_SNAPSHOTS=0
LOCAL_DELETED_SNAPSHOTS=0
REMOTE_DELETED_SNAPSHOTS=0
REPLICATION_FULL=0
REPLICATION_INCREMENTAL=0
REPLICATION_RESUMED=0
REPLICATION_SKIPPED=0
REPLICATION_ERRORS=0
REMOTE_REPLICATION_FULL=0
REMOTE_REPLICATION_INCREMENTAL=0
REMOTE_REPLICATION_RESUMED=0
REMOTE_REPLICATION_SKIPPED=0
REMOTE_REPLICATION_ERRORS=0
REMOTE_READY=0
REMOTE_READY_HOST=""
PROGRESS_PHASE=""
PROGRESS_DETAIL=""
CONFIG_CREATED=0
CONFIG_UPDATED=0
CONFIG_ADDED_OPTIONS=()
RUN_ACTIVE=0
SELF_DATASETS=()
SELF_DATASETS_COMPUTED=0
VERBOSE=0
CONSOLE_STATUS_ACTIVE=0
RUN_RUNTIME_SECONDS=0
REMOTE_SSH_ARGS=()
LOCAL_REPLICATION_FAILED_DATASETS="|"
REMOTE_REPLICATION_FAILED_DATASETS="|"
BORG_REPLICATION_FAILED_DATASETS="|"
BORG_REPLICATION_ERRORS=0
BORG_DELETED_ARCHIVES=0
BORG_CREATED_ARCHIVES=0
BORG_EXISTING_ARCHIVES="|"
# Repo dieses Laufs erreichbar? (analog REMOTE_READY) – erlaubt das Schreiben des
# Snapshot-(Archiv-)Caches fürs GUI ohne erneuten Erreichbarkeits-Zwang.
BORG_READY=0
BORG_READY_REPO=""
CURRENT_TARGET_ID=""
CURRENT_TARGET_LABEL=""
VERIFY_WARNINGS=0
VERIFY_REPAIRS=0
VERIFY_MISSING=0
VERIFY_EXTRA=0
EXISTING_HOURLY=0
EXISTING_DAILY=0
EXISTING_WEEKLY=0
EXISTING_MONTHLY=0
EXISTING_YEARLY=0

########################################
# Initialisierung
########################################

init_dirs() {

    mkdir -p "$DATA_DIR"
    mkdir -p "$RUNTIME_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$LOCK_DIR"
    mkdir -p "$STATE_DIR"
    mkdir -p "$DATASET_STATE_DIR"
}

init_logging() {

    LOG_FILE="${LOG_DIR}/zfs-backup-$(date +%Y-%m-%d).log"
}

console_supports_color() {
    [ -t 1 ] && [ -z "${NO_COLOR:-}" ]
}

console_color() {
    local code="$1"

    console_supports_color || return
    printf "\033[%sm" "$code"
}

console_reset() {
    console_supports_color || return
    printf "\033[0m"
}

console_clear_status() {
    [ "$CONSOLE_STATUS_ACTIVE" -eq 1 ] || return

    if [ -t 1 ]; then
        printf "\r\033[K"
    else
        printf "\n"
    fi

    CONSOLE_STATUS_ACTIVE=0
}

console_line() {
    local icon="$1"
    local color="$2"
    local msg="$3"

    console_clear_status
    console_color "$color"
    printf "[%s] %s " "$(date '+%d.%m.%Y %H:%M:%S')" "$icon"
    console_reset
    printf "%s\n" "$msg"
}

# Fortschritts-/Status-Modell (eine Quelle, mehrere Senken):
#   * Phasen:  log_phase -> write_progress (GUI-Progress-Datei) + console_phase.
#   * Detail:  console_status / console_stream_status -> write_progress_detail
#              (GUI) + eine live überschreibbare Konsolenzeile.
# Die beiden Detail-Funktionen unterscheiden sich NUR in Kanal/Frequenz:
#   * console_status: grobe Schritte (z. B. "Dataset 3/24") -> stdout. Am TTY per
#     \r überschrieben, ohne TTY (gestreamte GUI-Wartung) als ganze Zeile sichtbar.
#   * console_stream_status: hochfrequente Übertragungs-% -> nur /dev/tty, damit
#     der gestreamte stdout nicht mit hunderten %-Zeilen geflutet wird.
# Die eigentliche Zeilendarstellung teilen sich beide über _console_status_render.

# Gemeinsame Basis: rendert die transiente, per \r überschreibbare Statuszeile auf
# den eigenen stdout (vom Aufrufer ggf. nach /dev/tty umgeleitet). Farbe nur, wenn
# NO_COLOR nicht gesetzt ist – gerendert wird ohnehin nur auf ein Terminal.
_console_status_render() {
    local msg="$1"

    printf "\r"
    [ -z "${NO_COLOR:-}" ] && printf "\033[0;36m"
    printf "[%s] • " "$(date '+%d.%m.%Y %H:%M:%S')"
    [ -z "${NO_COLOR:-}" ] && printf "\033[0m"
    printf "%s\033[K" "$msg"
    CONSOLE_STATUS_ACTIVE=1
}

console_status() {
    local msg="$1"

    write_progress_detail "$msg"    # auch headless: Unterschritt für die GUI

    if [ -t 1 ]; then
        _console_status_render "$msg"
    else
        # Kein TTY (gestreamte GUI-Wartung wie Ausdünnen/Verify): als ganze Zeile,
        # damit der Fortschritt im Stream sichtbar ist – ähnlich dem Live-Status
        # eines normalen Laufs.
        printf "[%s] • %s\n" "$(date '+%d.%m.%Y %H:%M:%S')" "$msg"
    fi
}

console_phase() {
    local msg="$1"

    console_clear_status
    echo
    console_line "▶" "1;34" "$msg"
}

console_info() {
    console_line "•" "0;36" "$1"
}

console_success() {
    console_line "✓" "0;32" "$1"
}

console_warn() {
    console_line "!" "0;33" "$1"
}

console_error() {
    console_line "✗" "0;31" "$1"
}

log() {

    local msg="$1"

    echo "[$(date '+%d.%m.%Y %H:%M:%S')] $msg" >> "$LOG_FILE"

    case "$msg" in
        FEHLER:*) console_error "$msg" ;;
        WARNUNG:*) console_warn "$msg" ;;
        *) [ "$VERBOSE" -eq 1 ] && echo "[$(date '+%d.%m.%Y %H:%M:%S')] $msg" ;;
    esac
}

console_stream_status() {
    local msg="$1"

    write_progress_detail "$msg"    # auch headless: Übertragungs-% für die GUI

    # /dev/tty hat mode 0666, daher ist `[ -w /dev/tty ]` auch ohne Controlling-
    # Terminal wahr – das ÖFFNEN scheitert dann aber mit ENXIO ("No such device").
    # Darum einmalig real testen (öffnen) und das Ergebnis cachen.
    if [ -z "${TTY_USABLE:-}" ]; then
        if { true >/dev/tty; } 2>/dev/null; then TTY_USABLE=1; else TTY_USABLE=0; fi
    fi
    [ "$TTY_USABLE" = "1" ] || return

    # Gleiche Darstellung wie console_status, nur auf /dev/tty statt stdout (kein
    # Fluten des gestreamten stdout mit hochfrequenten %-Zeilen).
    _console_status_render "$msg" >/dev/tty
}

compact_transfer_label() {
    local label="$1"
    local rest
    local right
    local scope
    local mode
    local snapshot_ref
    local snapshot_name
    local snapshot_kind
    local dataset

    scope="${label%% *}"
    rest="${label#${scope} }"
    mode="${rest%% *}"
    rest="${rest#${mode} }"

    case "$label" in
        *" -> "*) right="${label##* -> }" ;;
        *) right="" ;;
    esac

    case "$mode" in
        Incremental)
            if [[ "$right" == *@* ]]; then
                snapshot_ref="$right"
            else
                snapshot_ref="${rest%% -> *}"
            fi
            ;;
        Full)
            snapshot_ref="${rest%% -> *}"
            ;;
        *)
            dataset="${rest%% -> *}"
            printf "%s %s %s\n" "$scope" "$mode" "$dataset"
            return
            ;;
    esac

    dataset="${snapshot_ref%@*}"
    snapshot_name="${snapshot_ref#*@}"
    snapshot_kind=$(snapshot_kind_from_name "$snapshot_name")

    printf "%s %s %s\n" "$scope" "$snapshot_kind" "$dataset"
}

snapshot_kind_from_name() {
    local snapshot_name="$1"

    case "$snapshot_name" in
        *_hourly_*) echo "Hourly" ;;
        *_daily_*) echo "Daily" ;;
        *_weekly_*) echo "Weekly" ;;
        *_monthly_*) echo "Monthly" ;;
        *_yearly_*) echo "Yearly" ;;
        *) echo "Snapshot" ;;
    esac
}

transfer_progress_from_pv() {
    local label="$1"
    local size="$2"
    local compact_label
    local percent
    local percent_int
    local last_percent=""
    local width=20
    local filled
    local empty
    local bar_done
    local bar_todo
    local milestone
    local last_milestone=0
    local stream_milestones=0

    # Ohne Terminal (gestreamte GUI-Wartung wie Ausdünnen) zeigt die /dev/tty-
    # Leiste von console_stream_status nichts. Dann alle 25 % EINE Zeile ausgeben,
    # damit der Fortschritt großer Übertragungen sichtbar ist (ohne zu fluten).
    # WICHTIG: Ausgabe auf stderr (fd 2), NIEMALS stdout – im Send-Pipeline-Kontext
    # ist stdout der zfs-recv-Datenstrom (Schreiben dorthin korrumpiert das Backup).
    # stderr bleibt der Skript-stderr; maintenance.php streamt ihn via 2>&1 mit.
    [ ! -t 2 ] && stream_milestones=1

    compact_label=$(compact_transfer_label "$label")

    while IFS= read -r percent; do
        percent_int="${percent%.*}"
        case "$percent_int" in
            ''|*[!0-9]*) continue ;;
        esac
        [ "$percent_int" -gt 100 ] && percent_int=100
        [ "$percent_int" = "$last_percent" ] && continue
        last_percent="$percent_int"

        filled=$((percent_int*width/100))
        empty=$((width-filled))
        printf -v bar_done "%*s" "$filled" ""
        printf -v bar_todo "%*s" "$empty" ""
        bar_done=${bar_done// /=}
        bar_todo=${bar_todo// / }

        if [ -n "$size" ]; then
            console_stream_status "Übertragung: ${compact_label} ${percent_int}% [${bar_done}${bar_todo}] $(format_bytes "$size")"
        else
            console_stream_status "Übertragung: ${compact_label} ${percent_int}% [${bar_done}${bar_todo}]"
        fi

        if [ "$stream_milestones" = 1 ]; then
            milestone=$((percent_int/25))
            if [ "$milestone" -gt "$last_milestone" ]; then
                last_milestone="$milestone"
                printf "[%s] • Übertragung: %s %d%%\n" \
                    "$(date '+%d.%m.%Y %H:%M:%S')" "$compact_label" "$percent_int" >&2
            fi
        fi
    done
}

log_stderr() {
    local prefix="$1"
    local line

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        echo "[$(date '+%d.%m.%Y %H:%M:%S')] ${prefix}: ${line}" >> "$LOG_FILE"
    done
}

log_phase() {
    local title="$1"

    log "===== ${title} ====="
    console_phase "$title"
    write_progress "$title"
}

# Formatiert Sekunden lesbar, z. B. "1d 4h 31m 47s". Führende Null-Einheiten
# werden weggelassen; Minimum "0s".
format_duration() {
    local total="$1"
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    local d=$((total/86400))
    local h=$(((total%86400)/3600))
    local m=$(((total%3600)/60))
    local s=$((total%60))
    local out=""
    [ "$d" -gt 0 ] && out="${out}${d}d "
    { [ "$d" -gt 0 ] || [ "$h" -gt 0 ]; } && out="${out}${h}h "
    { [ "$d" -gt 0 ] || [ "$h" -gt 0 ] || [ "$m" -gt 0 ]; } && out="${out}${m}m "
    out="${out}${s}s"
    printf '%s' "$out"
}

format_bytes() {
    local bytes="$1"

    awk -v bytes="$bytes" '
        BEGIN {
            split("B KiB MiB GiB TiB", unit, " ")
            value = bytes + 0
            unit_index = 1
            while (value >= 1024 && unit_index < 5) {
                value = value / 1024
                unit_index++
            }
            if (unit_index == 1) {
                printf "%d %s", value, unit[unit_index]
            } else {
                printf "%.1f %s", value, unit[unit_index]
            }
        }
    '
}

# Unix-Epoch -> deutsches Datum (TT.MM.JJJJ HH:MM:SS). Leer bei ungültigem Wert.
# GNU date (Unraid) via -d @epoch; BSD-Fallback (-r) der Robustheit halber.
format_epoch() {
    local e="$1"
    # 0/leer/ungültig -> leer (borg-Archive tragen keine ZFS-creation; sie geben 0
    # an, was sonst als „01.01.1970" erschiene).
    case "$e" in ''|0|*[!0-9]*) return ;; esac
    date -d "@${e}" '+%d.%m.%Y %H:%M:%S' 2>/dev/null \
        || date -r "$e" '+%d.%m.%Y %H:%M:%S' 2>/dev/null
}

mark_local_replication_failed() {
    local ds="$1"

    case "$LOCAL_REPLICATION_FAILED_DATASETS" in
        *"|${ds}|"*) ;;
        *) LOCAL_REPLICATION_FAILED_DATASETS="${LOCAL_REPLICATION_FAILED_DATASETS}${ds}|" ;;
    esac
}

mark_remote_replication_failed() {
    local ds="$1"

    case "$REMOTE_REPLICATION_FAILED_DATASETS" in
        *"|${ds}|"*) ;;
        *) REMOTE_REPLICATION_FAILED_DATASETS="${REMOTE_REPLICATION_FAILED_DATASETS}${ds}|" ;;
    esac
}

local_replication_failed_for_dataset() {
    [ "$LOCAL_REPLICATION_FAILED_DATASETS" = "|*|" ] && return 0
    case "$LOCAL_REPLICATION_FAILED_DATASETS" in
        *"|${1}|"*) return 0 ;;
    esac
    return 1
}

remote_replication_failed_for_dataset() {
    [ "$REMOTE_REPLICATION_FAILED_DATASETS" = "|*|" ] && return 0
    case "$REMOTE_REPLICATION_FAILED_DATASETS" in
        *"|${1}|"*) return 0 ;;
    esac
    return 1
}

mark_borg_replication_failed() {
    local ds="$1"

    case "$BORG_REPLICATION_FAILED_DATASETS" in
        *"|${ds}|"*) ;;
        *) BORG_REPLICATION_FAILED_DATASETS="${BORG_REPLICATION_FAILED_DATASETS}${ds}|" ;;
    esac
}

borg_replication_failed_for_dataset() {
    [ "$BORG_REPLICATION_FAILED_DATASETS" = "|*|" ] && return 0
    case "$BORG_REPLICATION_FAILED_DATASETS" in
        *"|${1}|"*) return 0 ;;
    esac
    return 1
}

zfs_name_is_safe() {
    local name="$1"

    [ -n "$name" ] || return 1
    case "$name" in
        *[!A-Za-z0-9_./:@-]*|/*|*@|@*) return 1 ;;
    esac

    return 0
}

# Borg-Repo-URL absichern: erlaubt sind ssh://-URLs und lokale/SSH-Kurzpfade
# (user@host:pfad bzw. /pfad). Keine Newlines/Tabs (zeilenbasierte Verarbeitung),
# keine Shell-Metazeichen, die in unquoteten Kontexten Ärger machen könnten.
# Aufrufe quoten die URL ohnehin (shell_quote); dies ist die zusätzliche Hürde.
borg_repo_is_safe() {
    local repo="$1"

    [ -n "$repo" ] || return 1
    case "$repo" in
        *[$'\n\t']*) return 1 ;;
        *[\;\&\|\<\>\`\$\(\)\'\"\*\?]*) return 1 ;;
    esac
    return 0
}

shell_quote() {
    local value="$1"

    printf "'%s'" "$(printf "%s" "$value" | sed "s/'/'\\\\''/g")"
}

assert_safe_local_target_dataset() {
    local source_ds="$1"
    local target="$2"

    zfs_name_is_safe "$source_ds" || return 1
    zfs_name_is_safe "$target" || return 1
    [ -n "$LOCAL_BACKUP_POOL" ] || return 1
    [ "$target" != "$LOCAL_BACKUP_POOL" ] || return 1
    [ "$target" != "$source_ds" ] || return 1

    case "$target" in
        "${LOCAL_BACKUP_POOL}/"*) return 0 ;;
    esac

    return 1
}

assert_safe_remote_target_dataset() {
    local source_ds="$1"
    local target="$2"

    zfs_name_is_safe "$source_ds" || return 1
    zfs_name_is_safe "$target" || return 1
    [ -n "$REMOTE_BASE_DATASET" ] || return 1
    [ "$target" != "$REMOTE_BASE_DATASET" ] || return 1
    [ "$target" != "$source_ds" ] || return 1

    case "$target" in
        "${REMOTE_BASE_DATASET}/"*) return 0 ;;
    esac

    return 1
}

########################################
# Config
########################################

create_default_config() {

cat > "$CONFIG_FILE" <<'EOF'
########################################
# ZFS Backup Config
########################################

########################################
# Datasets
########################################

# Zu sichernde Root-Datasets.
# Untergeordnete Datasets werden automatisch einbezogen.
INCLUDES=(
cache
)

# Ausgeschlossene Datasets.
# Ein ausgeschlossener Eintrag schließt auch dessen Unter-Datasets aus.
EXCLUDES=(
cache/system
)

# Pool-Root-Datasets wie "cache" oder "services" selbst snapshotten.
# Auf Unraid liegen dort meist nur Child-Datasets; sicherer Standard ist "no".
# Werte: "yes" oder "no"
SNAPSHOT_POOL_ROOTS="no"

########################################
# Snapshots
########################################

# Prefix für alle vom Skript verwalteten Snapshots.
SNAPSHOT_PREFIX="nas1_"

########################################
# Retention
########################################

# Aufzubewahrende Snapshots je Typ. Der Wert 0 deaktiviert den Typ vollständig:
# es werden keine Snapshots dieses Typs erstellt und vorhandene werden beim
# Pruning entfernt. > 0 erstellt und behält entsprechend viele.

# Anzahl aufzubewahrender stündlicher Snapshots (0 = aus).
KEEP_HOURLY=0

# Anzahl aufzubewahrender täglicher Snapshots (0 = aus).
KEEP_DAILY=14

# Anzahl aufzubewahrender wöchentlicher Snapshots (0 = aus).
KEEP_WEEKLY=8

# Anzahl aufzubewahrender monatlicher Snapshots (0 = aus).
KEEP_MONTHLY=12

# Anzahl aufzubewahrender jährlicher Snapshots (0 = aus).
KEEP_YEARLY=3

# Pruning auf den Quell-Datasets aktivieren.
# Werte: "yes" oder "no"
ENABLE_SOURCE_PRUNING="yes"

########################################
# Ziele
########################################

# Replikationsziele. Einträge müssen als Bash-Variablennamen nutzbar sein.
TARGETS=(
)

# Beispiel für ein lokales Ziel:
# TARGETS=(
# local
# )
# TARGET_local_TYPE="local"
# TARGET_local_ENABLED="yes"
# TARGET_local_BASE_DATASET="backups"

# Beispiel für ein Remote-Ziel:
# TARGETS=(
# remote
# )
# TARGET_remote_TYPE="remote"
# TARGET_remote_ENABLED="yes"
# TARGET_remote_HOST="root@192.168.1.50"
# TARGET_remote_BASE_DATASET="files/nas1"
# TARGET_remote_SSH_OPTIONS="-o BatchMode=yes -o ConnectTimeout=10 -o UpdateHostKeys=no"
# TARGET_remote_WAKE_ON_LAN="yes"
# TARGET_remote_WAKE_MAC="AA:BB:CC:DD:EE:FF"
# TARGET_remote_WAKE_TIMEOUT_SECONDS=60
# TARGET_remote_WAKE_CHECK_INTERVAL_SECONDS=2
# TARGET_remote_RETRY_ATTEMPTS=3
# TARGET_remote_RETRY_WAIT_SECONDS=10

# Beispiel für ein Borg-Ziel (entferntes Borg-Repository als Offsite-Ziel):
# TARGETS=(
# borg
# )
# TARGET_borg_TYPE="borg"
# TARGET_borg_ENABLED="yes"
# TARGET_borg_REPO="ssh://user@host:23/./backups/nas1"
# TARGET_borg_PASSPHRASE="geheime-repo-passphrase"
# TARGET_borg_SSH_OPTIONS="-o BatchMode=yes -o ConnectTimeout=10"
# TARGET_borg_COMPACT_EVERY=10

########################################
# Logs
########################################

# Aufbewahrung alter Logdateien in Tagen.
LOG_RETENTION_DAYS=365

########################################
# Benachrichtigungen
########################################

# Benachrichtigungen laufen über die native Unraid-Notification-Zentrale.
# Welcher Agent (Pushover, Discord, E-Mail, ...) sie zustellt und welche
# Stufen er erhält, wird in Unraid unter Einstellungen -> Benachrichtigungen
# eingestellt. Je Ereignis lässt sich hier die Stufe wählen bzw. abschalten.
# Werte: "aus", "normal", "warning" oder "alert"

# Benachrichtigung beim Start eines Laufs.
NOTIFY_START="aus"

# Benachrichtigung bei erfolgreichem Lauf.
NOTIFY_SUCCESS="normal"

# Benachrichtigung bei Fehlern.
NOTIFY_ERROR="alert"

# Benachrichtigung, wenn ein Lauf verwaiste Ziel-Datasets findet (Quelle gelöscht).
NOTIFY_ORPHANS="warning"

# Warnen, wenn das letzte erfolgreiche Backup älter als N Stunden ist (0 = aus).
# Der Wächter läuft nur bei aktivem Zeitplan (Unraid-Plugin) und meldet einmal.
STALE_AFTER_HOURS=26

########################################
# Zeitplan
########################################

# Geplante Läufe. Nur das Unraid-Plugin wertet dies aus (erzeugt daraus eine
# Cron-Datei). Im Standalone-Betrieb ohne Belang – dort per eigener cron planen.

# Geplanten Lauf aktivieren ("yes"/"no").
SCHEDULE_ENABLED="no"

# Cron-Ausdruck (5 Felder: Minute Stunde Tag Monat Wochentag), z. B. "0 2 * * *".
SCHEDULE_CRON=""
EOF
}

target_var() {
    local target_id="$1"
    local field="$2"

    printf "TARGET_%s_%s" "$target_id" "$field"
}

# Ziel-IDs sind numerisch (1..N, automatisch vergeben). Alte alphanumerische IDs
# (z. B. „local"/„remote") werden beim Laden noch akzeptiert und dann per
# target_resequence auf numerische IDs migriert.
target_id_is_valid() {
    local target_id="$1"

    [[ "$target_id" =~ ^([0-9]+|[A-Za-z_][A-Za-z0-9_]*)$ ]]
}

# Alle möglichen Felder eines Ziels – für das Verschieben beim Umnummerieren.
target_field_names() {
    printf '%s\n' TYPE ENABLED LABEL BASE_DATASET \
        HOST SSH_OPTIONS WAKE_ON_LAN WAKE_MAC WAKE_TIMEOUT_SECONDS \
        WAKE_CHECK_INTERVAL_SECONDS RETRY_ATTEMPTS RETRY_WAIT_SECONDS \
        REPO PASSPHRASE COMPACT_EVERY
}

# Nächste freie numerische ID (Ziele sind lückenlos 1..N nummeriert -> N+1).
target_next_id() {
    printf '%s' "$(( ${#TARGETS[@]} + 1 ))"
}

# Bildet die Ziele lückenlos auf numerische IDs 1..N ab (Reihenfolge bleibt) und
# verschiebt dabei die TARGET_<id>_*-Variablen über einen Zwischen-Namespace
# (kollisionsfrei, auch wenn alte und neue IDs überlappen). So wird beim Löschen
# aus „1,3" wieder „1,2" und alte alphanumerische IDs werden migriert.
target_resequence() {
    local -a ids=("${TARGETS[@]}")
    local n=${#ids[@]}
    local i field oldid srcvar tmpvar

    # Schon lückenlos 1..N in Reihenfolge? Dann nichts zu tun (kein Verschieben,
    # keine Cache-Invalidierung) – sonst würde jeder Lauf die Caches verwerfen.
    local already=1
    [ "$n" -eq 0 ] && return 0
    for ((i=0; i<n; i++)); do
        [ "${ids[$i]}" = "$((i+1))" ] || { already=0; break; }
    done
    [ "$already" -eq 1 ] && return 0

    # 1. Felder je Ziel nach TMPTARGET_<neuerIndex>_* sichern.
    for ((i=0; i<n; i++)); do
        oldid="${ids[$i]}"
        while read -r field; do
            srcvar="TARGET_${oldid}_${field}"
            [ "${!srcvar+x}" = "x" ] && printf -v "TMPTARGET_$((i+1))_${field}" "%s" "${!srcvar}"
        done < <(target_field_names)
    done
    # 2. Alte TARGET_<oldid>_* entfernen.
    for oldid in "${ids[@]}"; do
        while read -r field; do unset "TARGET_${oldid}_${field}"; done < <(target_field_names)
    done
    # 3. TMP -> TARGET mit neuen numerischen IDs; TARGETS neu aufbauen.
    TARGETS=()
    for ((i=1; i<=n; i++)); do
        while read -r field; do
            tmpvar="TMPTARGET_${i}_${field}"
            if [ "${!tmpvar+x}" = "x" ]; then
                printf -v "TARGET_${i}_${field}" "%s" "${!tmpvar}"
                unset "$tmpvar"
            fi
        done < <(target_field_names)
        TARGETS+=("$i")
    done

    # IDs haben sich geändert -> nach Ziel-ID benannte GUI-Caches verwerfen
    # (Snapshot-Baum/Listen), damit die GUI mit den neuen IDs neu aufbaut.
    invalidate_gui_cache 2>/dev/null
}

target_get() {
    local target_id="$1"
    local field="$2"
    local fallback="${3:-}"
    local var

    var=$(target_var "$target_id" "$field")
    if [ "${!var+x}" = "x" ]; then
        printf "%s\n" "${!var}"
    else
        printf "%s\n" "$fallback"
    fi
}

target_set() {
    local target_id="$1"
    local field="$2"
    local value="$3"
    local var

    var=$(target_var "$target_id" "$field")
    printf -v "$var" "%s" "$value"
}

target_array_contains() {
    local target_id="$1"
    local item

    for item in "${TARGETS[@]}"; do
        [ "$item" = "$target_id" ] && return 0
    done

    return 1
}

target_add_id() {
    local target_id="$1"

    target_array_contains "$target_id" || TARGETS+=("$target_id")
}

target_apply_defaults() {
    local target_id="$1"
    local type

    target_id_is_valid "$target_id" || return 1
    type=$(target_get "$target_id" TYPE local)

    target_set "$target_id" TYPE "$type"
    # Label = freier Anzeigename; fehlt es (Migration), als Default die ID.
    target_set "$target_id" LABEL "$(target_get "$target_id" LABEL "$target_id")"
    target_set "$target_id" ENABLED "$(target_get "$target_id" ENABLED yes)"

    case "$type" in
        local)
            target_set "$target_id" BASE_DATASET "$(target_get "$target_id" BASE_DATASET backups)"
            ;;
        remote)
            target_set "$target_id" HOST "$(target_get "$target_id" HOST root@192.168.1.50)"
            target_set "$target_id" BASE_DATASET "$(target_get "$target_id" BASE_DATASET files/nas1)"
            target_set "$target_id" SSH_OPTIONS "$(target_get "$target_id" SSH_OPTIONS "-o BatchMode=yes -o ConnectTimeout=10 -o UpdateHostKeys=no")"
            target_set "$target_id" WAKE_ON_LAN "$(target_get "$target_id" WAKE_ON_LAN yes)"
            target_set "$target_id" WAKE_MAC "$(target_get "$target_id" WAKE_MAC AA:BB:CC:DD:EE:FF)"
            target_set "$target_id" WAKE_TIMEOUT_SECONDS "$(target_get "$target_id" WAKE_TIMEOUT_SECONDS 60)"
            target_set "$target_id" WAKE_CHECK_INTERVAL_SECONDS "$(target_get "$target_id" WAKE_CHECK_INTERVAL_SECONDS 2)"
            target_set "$target_id" RETRY_ATTEMPTS "$(target_get "$target_id" RETRY_ATTEMPTS 3)"
            target_set "$target_id" RETRY_WAIT_SECONDS "$(target_get "$target_id" RETRY_WAIT_SECONDS 10)"
            ;;
        borg)
            target_set "$target_id" REPO "$(target_get "$target_id" REPO "")"
            target_set "$target_id" PASSPHRASE "$(target_get "$target_id" PASSPHRASE "")"
            target_set "$target_id" SSH_OPTIONS "$(target_get "$target_id" SSH_OPTIONS "-o BatchMode=yes -o ConnectTimeout=10")"
            target_set "$target_id" COMPACT_EVERY "$(target_get "$target_id" COMPACT_EVERY 10)"
            ;;
    esac
}

target_apply_all_defaults() {
    local target_id
    local valid_targets=()

    for target_id in "${TARGETS[@]}"; do
        target_id_is_valid "$target_id" || continue
        target_apply_defaults "$target_id" || continue
        valid_targets+=("$target_id")
    done

    TARGETS=("${valid_targets[@]}")
    # Lückenlos auf numerische IDs 1..N abbilden (migriert auch alte IDs).
    target_resequence
}

# Legt ein neues Replikationsziel an (prompt-frei). Kern für den CLI-Befehl
# --add-target. Die ID wird automatisch numerisch vergeben (nächste freie);
# der Nutzer gibt nur das Label (Anzeigename, frei wählbar). Validiert atomar
# VOR dem Anlegen, ergänzt Typ-Defaults und persistiert. Rückgabe 0/1.
# Bei borg trägt das dritte Argument die Repo-URL (statt eines Basis-Datasets),
# das vierte ist ungenutzt. local/remote nutzen es wie bisher als Ziel-Dataset.
target_create() {
    local label="$1"
    local type="$2"
    local base_dataset="$3"
    local host="$4"
    local target_id

    case "$label" in
        *[$'\n\r']*) console_error "Label darf keine Zeilenumbrüche enthalten"; return 1 ;;
    esac
    case "$type" in
        local|remote|borg) ;;
        *) console_error "Ungültiger Typ: $type (erlaubt: local, remote, borg)"; return 1 ;;
    esac
    if [ "$type" = "borg" ]; then
        if [ -z "$base_dataset" ] || ! borg_repo_is_safe "$base_dataset"; then
            console_error "Ungültige Borg-Repo-URL: $base_dataset"
            return 1
        fi
    else
        if [ -z "$base_dataset" ] || ! zfs_name_is_safe "$base_dataset"; then
            console_error "Ungültiges Basis/Ziel-Dataset: $base_dataset"
            return 1
        fi
    fi
    if [ "$type" = "remote" ] && [ -z "$host" ]; then
        console_error "SSH-Host darf bei Remote-Zielen nicht leer sein"
        return 1
    fi

    target_id=$(target_next_id)
    target_add_id "$target_id"
    target_set "$target_id" TYPE "$type"
    target_set "$target_id" ENABLED yes
    target_set "$target_id" LABEL "${label:-$target_id}"
    if [ "$type" = "borg" ]; then
        target_set "$target_id" REPO "$base_dataset"
    else
        target_set "$target_id" BASE_DATASET "$base_dataset"
    fi
    [ "$type" = "remote" ] && target_set "$target_id" HOST "$host"

    target_apply_defaults "$target_id"
    save_config_edits
    return 0
}

# Entfernt ein Ziel aus der Konfiguration (prompt-frei). Kern für
# --delete-target. Danach werden die verbleibenden Ziele lückenlos neu
# nummeriert (aus „1,3" wird „1,2"); die nach IDs benannten GUI-Caches werden
# verworfen (regenerieren beim nächsten Lauf). Rückgabe 0/1.
target_delete() {
    local target_id="$1"
    local item field
    local next=()

    if ! target_array_contains "$target_id"; then
        console_error "Ziel nicht gefunden: $target_id"
        return 1
    fi

    for item in "${TARGETS[@]}"; do
        [ "$item" = "$target_id" ] || next+=("$item")
    done
    TARGETS=("${next[@]}")
    # Variablen des gelöschten Ziels entfernen, dann lückenlos umnummerieren.
    while read -r field; do unset "TARGET_${target_id}_${field}"; done < <(target_field_names)
    target_resequence
    invalidate_gui_cache 2>/dev/null
    save_config_edits
    return 0
}

# Ordnet die Ziele in der angegebenen Reihenfolge neu an (prompt-frei). Kern für
# --reorder-targets. Erwartet ALLE aktuellen Ziel-IDs genau einmal als
# kommagetrennte Liste (eine Permutation des Bestands). Die Reihenfolge legt
# fest, in welcher Folge Backups laufen (erstes Ziel zuerst); siehe
# for_each_enabled_target. Danach werden die IDs lückenlos = Position neu
# vergeben (wie beim Löschen), die nach IDs benannten GUI-Caches verworfen.
# Rückgabe 0/1.
target_reorder() {
    local order="$1"
    local -a desired=()
    local id seen="|"
    local old_ifs="$IFS"

    IFS=','
    read -ra desired <<< "$order"
    IFS="$old_ifs"

    if [ "${#desired[@]}" -ne "${#TARGETS[@]}" ]; then
        console_error "Reihenfolge muss genau ${#TARGETS[@]} Ziel-ID(s) enthalten (eine je vorhandenes Ziel)"
        return 1
    fi
    for id in "${desired[@]}"; do
        if ! target_array_contains "$id"; then
            console_error "Unbekannte Ziel-ID in der Reihenfolge: $id"
            return 1
        fi
        case "$seen" in
            *"|${id}|"*) console_error "Ziel-ID doppelt in der Reihenfolge: $id"; return 1 ;;
        esac
        seen="${seen}${id}|"
    done

    TARGETS=("${desired[@]}")
    # Renummeriert auf 1..N nach der neuen Reihenfolge und verwirft die GUI-Caches
    # (Resequence ist ein No-Op + ohne Cache-Verwurf, falls die Reihenfolge schon
    # passte – also kostenlos bei unveränderter Anordnung).
    target_resequence
    save_config_edits
    return 0
}

# Verschiebt ein Ziel um eine Position nach oben/unten (prompt-frei). Komfort-
# Wrapper um target_reorder für Auf-/Ab-Buttons in der GUI. Rückgabe 0/1.
target_move() {
    local target_id="$1"
    local dir="$2"
    local -a ids=("${TARGETS[@]}")
    local n=${#ids[@]}
    local i pos=-1 swap=-1 tmp joined

    if ! target_array_contains "$target_id"; then
        console_error "Ziel nicht gefunden: $target_id"
        return 1
    fi
    for ((i=0; i<n; i++)); do
        [ "${ids[$i]}" = "$target_id" ] && { pos=$i; break; }
    done

    case "$dir" in
        up|hoch|oben) swap=$((pos-1)) ;;
        down|runter|unten) swap=$((pos+1)) ;;
        *) console_error "Richtung muss 'up' oder 'down' sein"; return 1 ;;
    esac

    if [ "$swap" -lt 0 ] || [ "$swap" -ge "$n" ]; then
        console_error "Ziel ist bereits am Rand der Reihenfolge"
        return 1
    fi

    tmp="${ids[$pos]}"; ids[$pos]="${ids[$swap]}"; ids[$swap]="$tmp"
    printf -v joined '%s,' "${ids[@]}"
    target_reorder "${joined%,}"
}

# Ziel-Labels in aktueller Reihenfolge als kommagetrennte Liste (für sprechende
# Reihenfolge-Meldungen statt nackter IDs, die nach dem Umsortieren ohnehin nur
# der Position entsprechen).
targets_label_order() {
    local target_id first=1 out=""

    for target_id in "${TARGETS[@]}"; do
        if [ "$first" -eq 1 ]; then first=0; else out+=", "; fi
        out+="$(target_get "$target_id" LABEL "$target_id")"
    done
    printf '%s' "$out"
}

# Setzt ein einzelnes Feld eines bestehenden Ziels (prompt-frei). Kern für
# --edit-target. Feld-Whitelist (schützt die CLI vor
# beliebigen Feldern) plus feldspezifische Validierung über
# target_edit_value_is_valid. Rückgabe 0 (ok) / 1 (Fehler).
target_edit_field() {
    local target_id="$1"
    local field="$2"
    local value="$3"

    if ! target_array_contains "$target_id"; then
        console_error "Ziel nicht gefunden: $target_id"
        return 1
    fi
    case "$field" in
        LABEL|ENABLED|BASE_DATASET|HOST|SSH_OPTIONS|WAKE_ON_LAN|WAKE_MAC|WAKE_TIMEOUT_SECONDS|WAKE_CHECK_INTERVAL_SECONDS|RETRY_ATTEMPTS|RETRY_WAIT_SECONDS|REPO|PASSPHRASE|COMPACT_EVERY) ;;
        *) console_error "Unbekanntes oder nicht editierbares Feld: $field"; return 1 ;;
    esac
    target_edit_value_is_valid "$field" "$value" || return 1
    target_set "$target_id" "$field" "$value"
    target_apply_defaults "$target_id"
    save_config_edits
    return 0
}

# Prüft die Erreichbarkeit eines Ziels (prompt-frei). Kern für
# --test-target. Lokal: zfs list des Ziel-Pools; Remote: Host
# bereitmachen (ggf. wecken) und remote zfs list. Rückgabe 0/1.
target_test() {
    local target_id="$1"
    local type

    if ! target_array_contains "$target_id"; then
        console_error "Ziel nicht gefunden: $target_id"
        return 1
    fi
    load_target_context "$target_id" || return 1
    type=$(target_type "$target_id")

    case "$type" in
        local)
            if zfs list "$LOCAL_BACKUP_POOL" >/dev/null 2>&1; then
                console_success "Lokales Ziel erreichbar: $LOCAL_BACKUP_POOL"
                return 0
            fi
            console_error "Lokales Ziel nicht gefunden: $LOCAL_BACKUP_POOL"
            return 1
            ;;
        remote)
            if ensure_remote_ready && remote_zfs_list "$REMOTE_BASE_DATASET"; then
                console_success "Remote-Ziel erreichbar: ${REMOTE_HOST}:${REMOTE_BASE_DATASET}"
                return 0
            fi
            console_error "Remote-Ziel nicht erreichbar: ${REMOTE_HOST}:${REMOTE_BASE_DATASET}"
            return 1
            ;;
        borg)
            borg_target_test && return 0
            return 1
            ;;
    esac
    return 1
}

target_enabled() {
    local target_id="$1"

    [ "$(target_get "$target_id" ENABLED yes)" = "yes" ]
}

target_type() {
    target_get "$1" TYPE local
}

target_enabled_count() {
    local wanted_type="${1:-all}"
    local target_id
    local count=0

    for target_id in "${TARGETS[@]}"; do
        target_enabled "$target_id" || continue
        [ "$wanted_type" = "all" ] || [ "$(target_type "$target_id")" = "$wanted_type" ] || continue
        count=$((count+1))
    done

    echo "$count"
}

# Anzeigename eines Ziels = sein Label (frei wählbar). Fallback: die ID.
target_label() {
    target_get "$1" LABEL "$1"
}

# Replikationsziele als JSON-Array fürs GUI (--targets --json).
# Remote-spezifische Felder liegen im "remote"-Objekt; bei lokalen Zielen null.
targets_json() {
    local target_id type first=1

    printf '['
    for target_id in "${TARGETS[@]}"; do
        if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
        type=$(target_type "$target_id")
        printf '{'
        printf '"id":"%s",' "$(json_escape "$target_id")"
        printf '"label":"%s",' "$(json_escape "$(target_label "$target_id")")"
        printf '"type":"%s",' "$(json_escape "$type")"
        printf '"enabled":%s,' "$(json_bool "$(target_get "$target_id" ENABLED yes)")"
        printf '"base_dataset":"%s",' "$(json_escape "$(target_get "$target_id" BASE_DATASET)")"
        if [ "$type" = "remote" ]; then
            printf '"remote":{'
            printf '"host":"%s",' "$(json_escape "$(target_get "$target_id" HOST)")"
            printf '"ssh_options":"%s",' "$(json_escape "$(target_get "$target_id" SSH_OPTIONS)")"
            printf '"wake_on_lan":%s,' "$(json_bool "$(target_get "$target_id" WAKE_ON_LAN no)")"
            printf '"wake_mac":"%s",' "$(json_escape "$(target_get "$target_id" WAKE_MAC)")"
            printf '"wake_timeout_seconds":%s,' "$(json_num "$(target_get "$target_id" WAKE_TIMEOUT_SECONDS 0)")"
            printf '"wake_check_interval_seconds":%s,' "$(json_num "$(target_get "$target_id" WAKE_CHECK_INTERVAL_SECONDS 0)")"
            printf '"retry_attempts":%s,' "$(json_num "$(target_get "$target_id" RETRY_ATTEMPTS 0)")"
            printf '"retry_wait_seconds":%s' "$(json_num "$(target_get "$target_id" RETRY_WAIT_SECONDS 0)")"
            printf '},"borg":null'
        elif [ "$type" = "borg" ]; then
            printf '"remote":null,"borg":{'
            printf '"repo":"%s",' "$(json_escape "$(target_get "$target_id" REPO)")"
            printf '"ssh_options":"%s",' "$(json_escape "$(target_get "$target_id" SSH_OPTIONS)")"
            printf '"compact_every":%s,' "$(json_num "$(target_get "$target_id" COMPACT_EVERY 0)")"
            # Passphrase nie ausgeben – nur, ob sie gesetzt ist.
            printf '"passphrase_set":%s' "$(json_bool "$([ -n "$(target_get "$target_id" PASSPHRASE)" ] && echo yes || echo no)")"
            printf '}'
        else
            printf '"remote":null,"borg":null'
        fi
        printf '}'
    done
    printf ']\n'
}

load_target_context() {
    local target_id="$1"
    local type

    target_id_is_valid "$target_id" || return 1
    type=$(target_type "$target_id")

    # Bereitschafts-Cache NICHT hier verwerfen: er ist host-basiert
    # (REMOTE_READY_HOST) und wird in ensure_remote_ready pro Host real per SSH
    # gegengeprüft. So bleibt er über die abwechselnden Ziel-Kontextwechsel im
    # Pruning/Orphan-Cleanup gültig, statt pro Dataset eine volle Ping/SSH-
    # Prüfung samt Log-Spam auszulösen.
    CURRENT_TARGET_ID="$target_id"
    CURRENT_TARGET_LABEL=$(target_label "$target_id")

    ENABLE_LOCAL_REPLICATION="no"
    ENABLE_REMOTE_REPLICATION="no"
    ENABLE_BORG_REPLICATION="no"

    case "$type" in
        local)
            ENABLE_LOCAL_REPLICATION="$(target_get "$target_id" ENABLED yes)"
            LOCAL_BACKUP_POOL="$(target_get "$target_id" BASE_DATASET backups)"
            ;;
        remote)
            ENABLE_REMOTE_REPLICATION="$(target_get "$target_id" ENABLED yes)"
            REMOTE_HOST="$(target_get "$target_id" HOST root@192.168.1.50)"
            REMOTE_BASE_DATASET="$(target_get "$target_id" BASE_DATASET files/nas1)"
            REMOTE_SSH_OPTIONS="$(target_get "$target_id" SSH_OPTIONS "-o BatchMode=yes -o ConnectTimeout=10 -o UpdateHostKeys=no")"
            ENABLE_REMOTE_WAKE_ON_LAN="$(target_get "$target_id" WAKE_ON_LAN yes)"
            REMOTE_WAKE_MAC="$(target_get "$target_id" WAKE_MAC AA:BB:CC:DD:EE:FF)"
            REMOTE_WAKE_TIMEOUT_SECONDS="$(target_get "$target_id" WAKE_TIMEOUT_SECONDS 60)"
            REMOTE_WAKE_CHECK_INTERVAL_SECONDS="$(target_get "$target_id" WAKE_CHECK_INTERVAL_SECONDS 2)"
            REMOTE_REPLICATION_RETRY_ATTEMPTS="$(target_get "$target_id" RETRY_ATTEMPTS 3)"
            REMOTE_REPLICATION_RETRY_WAIT_SECONDS="$(target_get "$target_id" RETRY_WAIT_SECONDS 10)"
            read -r -a REMOTE_SSH_ARGS <<< "$REMOTE_SSH_OPTIONS"
            ;;
        borg)
            ENABLE_BORG_REPLICATION="$(target_get "$target_id" ENABLED yes)"
            BORG_REPO="$(target_get "$target_id" REPO "")"
            BORG_PASSPHRASE_VALUE="$(target_get "$target_id" PASSPHRASE "")"
            BORG_SSH_OPTIONS="$(target_get "$target_id" SSH_OPTIONS "-o BatchMode=yes -o ConnectTimeout=10")"
            BORG_COMPACT_EVERY="$(target_get "$target_id" COMPACT_EVERY 10)"
            ;;
        *)
            return 1
            ;;
    esac
}

for_each_enabled_target() {
    local wanted_type="$1"
    local callback="$2"
    local target_id
    local type

    for target_id in "${TARGETS[@]}"; do
        target_enabled "$target_id" || continue
        type=$(target_type "$target_id")
        [ "$wanted_type" = "all" ] || [ "$type" = "$wanted_type" ] || continue
        load_target_context "$target_id" || continue
        "$callback" "$target_id"
    done
}

config_quote() {
    local value="$1"

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

write_config_scalar() {
    local name="$1"
    local value="$2"

    printf "%s=%s\n" "$name" "$(config_quote "$value")"
}

write_config_number() {
    local name="$1"
    local value="$2"

    printf "%s=%s\n" "$name" "$value"
}

write_config_array() {
    local name="$1"
    local item

    printf "%s=(\n" "$name"
    eval 'for item in "${'"$name"'[@]}"; do printf "%s\n" "$item"; done'
    printf ")\n"
}

sort_config_array() {
    local name="$1"
    local -n list="$name"

    [ "${#list[@]}" -gt 0 ] || return 0
    mapfile -t list < <(printf "%s\n" "${list[@]}" | LC_ALL=C sort)
}

sort_dataset_config_arrays() {
    sort_config_array INCLUDES
    sort_config_array EXCLUDES
}

write_target_config() {
    local target_id="$1"
    local type
    local field

    type=$(target_get "$target_id" TYPE local)

    echo
    printf "# Ziel %s: %s\n" "$target_id" "$(target_get "$target_id" LABEL "$target_id")"
    write_config_scalar "$(target_var "$target_id" TYPE)" "$type"
    write_config_scalar "$(target_var "$target_id" LABEL)" "$(target_get "$target_id" LABEL "$target_id")"
    write_config_scalar "$(target_var "$target_id" ENABLED)" "$(target_get "$target_id" ENABLED yes)"
    write_config_scalar "$(target_var "$target_id" BASE_DATASET)" "$(target_get "$target_id" BASE_DATASET)"

    if [ "$type" = "remote" ]; then
        for field in HOST SSH_OPTIONS WAKE_ON_LAN WAKE_MAC WAKE_TIMEOUT_SECONDS WAKE_CHECK_INTERVAL_SECONDS RETRY_ATTEMPTS RETRY_WAIT_SECONDS; do
            case "$field" in
                WAKE_TIMEOUT_SECONDS|WAKE_CHECK_INTERVAL_SECONDS|RETRY_ATTEMPTS|RETRY_WAIT_SECONDS)
                    write_config_number "$(target_var "$target_id" "$field")" "$(target_get "$target_id" "$field")"
                    ;;
                *)
                    write_config_scalar "$(target_var "$target_id" "$field")" "$(target_get "$target_id" "$field")"
                    ;;
            esac
        done
    elif [ "$type" = "borg" ]; then
        write_config_scalar "$(target_var "$target_id" REPO)" "$(target_get "$target_id" REPO)"
        write_config_scalar "$(target_var "$target_id" PASSPHRASE)" "$(target_get "$target_id" PASSPHRASE)"
        write_config_scalar "$(target_var "$target_id" SSH_OPTIONS)" "$(target_get "$target_id" SSH_OPTIONS)"
        write_config_number "$(target_var "$target_id" COMPACT_EVERY)" "$(target_get "$target_id" COMPACT_EVERY)"
    fi
}

extract_custom_config_entries() {
    local known
    local obsolete

    known=$(config_known_options_pattern)
    obsolete="ENABLE_LOCAL_REPLICATION|LOCAL_BACKUP_POOL|ENABLE_REMOTE_REPLICATION|REMOTE_HOST|REMOTE_BASE_DATASET|REMOTE_SSH_OPTIONS|ENABLE_REMOTE_WAKE_ON_LAN|REMOTE_WAKE_MAC|REMOTE_WAKE_TIMEOUT_SECONDS|REMOTE_WAKE_CHECK_INTERVAL_SECONDS|REMOTE_REPLICATION_RETRY_ATTEMPTS|REMOTE_REPLICATION_RETRY_WAIT_SECONDS|ENABLE_LOCAL_REPLICATION_PRUNING|ENABLE_REMOTE_REPLICATION_PRUNING|CHECK_FOR_UPDATES|UPDATE_BRANCH"

    awk -v known="$known" -v obsolete="$obsolete" '
        /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ {
            name=$0
            sub(/^[[:space:]]*/, "", name)
            sub(/[[:space:]]*=.*/, "", name)
            if (name == "TARGETS" || name ~ /^TARGET_([A-Za-z_][A-Za-z0-9_]*|[0-9]+)_[A-Z0-9_]+$/) {
                next
            }
            if (name ~ "^(" obsolete ")$") {
                next
            }
            if (name !~ "^(" known ")$") {
                print
            }
        }
    ' "$CONFIG_FILE"
}

write_normalized_config() {
    local tmp="$1"
    local custom_entries
    local target_id

    sort_dataset_config_arrays
    custom_entries=$(extract_custom_config_entries)

    {
        cat <<'EOF'
########################################
# ZFS Backup Config
########################################

########################################
# Datasets
########################################

# Zu sichernde Root-Datasets.
# Untergeordnete Datasets werden automatisch einbezogen.
EOF
        write_config_array INCLUDES
        cat <<'EOF'

# Ausgeschlossene Datasets.
# Ein ausgeschlossener Eintrag schließt auch dessen Unter-Datasets aus.
EOF
        write_config_array EXCLUDES
        cat <<'EOF'

# Pool-Root-Datasets wie "cache" oder "services" selbst snapshotten.
# Auf Unraid liegen dort meist nur Child-Datasets; sicherer Standard ist "no".
# Werte: "yes" oder "no"
EOF
        write_config_scalar SNAPSHOT_POOL_ROOTS "$SNAPSHOT_POOL_ROOTS"
        cat <<'EOF'

########################################
# Snapshots
########################################

# Prefix für alle vom Skript verwalteten Snapshots.
EOF
        write_config_scalar SNAPSHOT_PREFIX "$SNAPSHOT_PREFIX"
        cat <<'EOF'

########################################
# Retention
########################################

# Aufzubewahrende Snapshots je Typ. Der Wert 0 deaktiviert den Typ vollständig:
# es werden keine Snapshots dieses Typs erstellt und vorhandene werden beim
# Pruning entfernt. > 0 erstellt und behält entsprechend viele.

# Anzahl aufzubewahrender stündlicher Snapshots (0 = aus).
EOF
        write_config_number KEEP_HOURLY "$KEEP_HOURLY"
        cat <<'EOF'

# Anzahl aufzubewahrender täglicher Snapshots (0 = aus).
EOF
        write_config_number KEEP_DAILY "$KEEP_DAILY"
        cat <<'EOF'

# Anzahl aufzubewahrender wöchentlicher Snapshots (0 = aus).
EOF
        write_config_number KEEP_WEEKLY "$KEEP_WEEKLY"
        cat <<'EOF'

# Anzahl aufzubewahrender monatlicher Snapshots (0 = aus).
EOF
        write_config_number KEEP_MONTHLY "$KEEP_MONTHLY"
        cat <<'EOF'

# Anzahl aufzubewahrender jährlicher Snapshots (0 = aus).
EOF
        write_config_number KEEP_YEARLY "$KEEP_YEARLY"
        cat <<'EOF'

########################################
# Pruning
########################################

# Pruning auf den Quell-Datasets aktivieren.
# Werte: "yes" oder "no"
EOF
        write_config_scalar ENABLE_SOURCE_PRUNING "$ENABLE_SOURCE_PRUNING"
        cat <<'EOF'

########################################
# Ziele
########################################

# Replikationsziele.
EOF
        write_config_array TARGETS
        for target_id in "${TARGETS[@]}"; do
            write_target_config "$target_id"
        done

        cat <<'EOF'

########################################
# Logs
########################################

# Aufbewahrung alter Logdateien in Tagen.
EOF
        write_config_number LOG_RETENTION_DAYS "$LOG_RETENTION_DAYS"
        cat <<'EOF'

########################################
# Benachrichtigungen
########################################

# Benachrichtigungen laufen über die native Unraid-Notification-Zentrale.
# Welcher Agent (Pushover, Discord, E-Mail, ...) sie zustellt und welche
# Stufen er erhält, wird in Unraid unter Einstellungen -> Benachrichtigungen
# eingestellt. Je Ereignis lässt sich die Stufe wählen bzw. abschalten.
# Werte: "aus", "normal", "warning" oder "alert"

# Benachrichtigung beim Start eines Laufs.
EOF
        write_config_scalar NOTIFY_START "$NOTIFY_START"
        cat <<'EOF'

# Benachrichtigung bei erfolgreichem Lauf.
EOF
        write_config_scalar NOTIFY_SUCCESS "$NOTIFY_SUCCESS"
        cat <<'EOF'

# Benachrichtigung bei Fehlern.
EOF
        write_config_scalar NOTIFY_ERROR "$NOTIFY_ERROR"
        cat <<'EOF'

# Benachrichtigung bei verwaisten Ziel-Datasets (Quelle gelöscht/inaktiv).
EOF
        write_config_scalar NOTIFY_ORPHANS "$NOTIFY_ORPHANS"
        cat <<'EOF'

# Warnen, wenn das letzte erfolgreiche Backup älter als N Stunden ist (0 = aus).
# Der Wächter läuft nur bei aktivem Zeitplan (Unraid-Plugin) und meldet einmal.
EOF
        write_config_number STALE_AFTER_HOURS "$STALE_AFTER_HOURS"
        cat <<'EOF'

########################################
# Zeitplan
########################################

# Geplante Läufe. Nur das Unraid-Plugin wertet dies aus (erzeugt daraus eine
# Cron-Datei). Im Standalone-Betrieb ohne Belang – dort per eigener cron planen.

# Geplanten Lauf aktivieren ("yes"/"no").
EOF
        write_config_scalar SCHEDULE_ENABLED "$SCHEDULE_ENABLED"
        cat <<'EOF'

# Cron-Ausdruck (5 Felder: Minute Stunde Tag Monat Wochentag), z. B. "0 2 * * *".
EOF
        write_config_scalar SCHEDULE_CRON "$SCHEDULE_CRON"

        if [ -n "$custom_entries" ]; then
            cat <<'EOF'

########################################
# Benutzerdefiniert
########################################

# Unbekannte eigene einfache Variablen wurden beim Normalisieren erhalten.
EOF
            printf "%s\n" "$custom_entries"
        fi
    } > "$tmp"
}

normalize_config() {
    local make_backup="${1:-yes}"
    local tmp
    local backup

    tmp="${CONFIG_FILE}.tmp.$$"

    write_normalized_config "$tmp"

    if cmp -s "$CONFIG_FILE" "$tmp"; then
        rm -f "$tmp"
        return
    fi

    if [ "$make_backup" = "yes" ]; then
        backup="${CONFIG_FILE}.bak-$(date +%Y-%m-%d)"
        [ -f "$backup" ] || cp "$CONFIG_FILE" "$backup"
    fi

    mv "$tmp" "$CONFIG_FILE"
    CONFIG_UPDATED=1
}

config_option_is_recorded() {
    local name="$1"
    local item

    for item in "${CONFIG_ADDED_OPTIONS[@]}"; do
        [ "$item" = "$name" ] && return 0
    done

    return 1
}

config_file_has_option() {
    local name="$1"

    grep -Eq "^[[:space:]]*${name}[[:space:]]*=" "$CONFIG_FILE"
}

record_missing_config_options() {
    local option

    [ "$CONFIG_CREATED" -eq 1 ] && return 0

    while read -r option; do
        [ -n "$option" ] || continue
        [ "$option" = "TARGETS" ] && continue
        config_file_has_option "$option" && continue
        config_option_is_recorded "$option" && continue
        CONFIG_ADDED_OPTIONS+=("$option")
    done < <(config_schema | awk -F'|' '{ print $2 }')
}

load_config() {

    if [ ! -f "$CONFIG_FILE" ]; then

        create_default_config
        CONFIG_CREATED=1
        CONFIG_UPDATED=1
    fi

    source "$CONFIG_FILE"

    : "${LOG_RETENTION_DAYS:=365}"
    : "${KEEP_HOURLY:=0}"
    : "${KEEP_DAILY:=14}"
    : "${KEEP_WEEKLY:=8}"
    : "${KEEP_MONTHLY:=12}"
    : "${KEEP_YEARLY:=3}"
    : "${SNAPSHOT_POOL_ROOTS:=no}"
    : "${ENABLE_SOURCE_PRUNING:=yes}"
    : "${NOTIFY_START:=aus}"
    : "${NOTIFY_SUCCESS:=normal}"
    : "${NOTIFY_ERROR:=alert}"
    : "${NOTIFY_ORPHANS:=warning}"
    : "${STALE_AFTER_HOURS:=26}"
    : "${SCHEDULE_ENABLED:=no}"
    : "${SCHEDULE_CRON:=}"

    if ! declare -p TARGETS >/dev/null 2>&1; then
        TARGETS=()
    fi

    target_apply_all_defaults
}

# Hält die Config-Datei normalisiert und erkennt neu hinzugekommene Optionen.
# Bewusst NICHT in load_config: reine Lese-Befehle (Status/JSON für die GUI)
# brauchen das nicht und sparen so bei jedem Aufruf einen Tmp-Write + ~40 greps –
# die GUI ruft den Kern beim Seitenaufbau mehrfach auf. Pflege läuft nur bei
# Befehlen, die einen Lauf vorbereiten oder die Config schreiben (siehe MAIN).
config_maintain() {
    record_missing_config_options
    normalize_config
}

########################################
# Locking
########################################

acquire_lock() {

    if [ -f "$LOCK_FILE" ]; then

        OLD_PID=$(cat "$LOCK_FILE")

        if ps -p "$OLD_PID" >/dev/null 2>&1; then

            echo
            echo "Backup läuft bereits."
            echo "PID: $OLD_PID"
            echo

            exit 1

        else

            rm -f "$LOCK_FILE"
        fi
    fi

    echo $$ > "$LOCK_FILE"
}

release_lock() {

    rm -f "$LOCK_FILE"
    rm -f "${STATE_DIR}/run_progress"
}

# Schreibt den aktuellen Lauf-Fortschritt maschinenlesbar für die GUI. Nur
# während eines aktiven Laufs (RUN_ACTIVE=1); release_lock entfernt die Datei
# am Laufende wieder, sodass ein nicht laufender Stand keinen Fortschritt zeigt.
#
# PHASE = Grobphase (Snapshots/Replikation/…), DETAIL = aktueller Unterschritt
# (z. B. „Quelle-Pruning [13/24]: …" oder „Übertragung … 45%"). DETAIL wird über
# console_status/console_stream_status gefüllt, die headless sonst nichts
# ausgäben – so sieht die GUI auch in „stillen" Phasen, was gerade läuft.
write_progress() {
    [ "${RUN_ACTIVE:-0}" -eq 1 ] || return 0
    PROGRESS_PHASE="$1"
    PROGRESS_DETAIL=""          # neue Phase -> Detail zurücksetzen
    _write_progress_file
}

# Aktualisiert nur das DETAIL (aktueller Unterschritt) unter der laufenden Phase.
write_progress_detail() {
    [ "${RUN_ACTIVE:-0}" -eq 1 ] || return 0
    PROGRESS_DETAIL="$1"
    _write_progress_file
}

_write_progress_file() {
    local now_e now_h
    now_e=$(date +%s)
    now_h=$(date '+%d.%m.%Y %H:%M:%S')
    {
        printf 'PHASE=%s\n'   "${PROGRESS_PHASE}"
        printf 'DETAIL=%s\n'  "${PROGRESS_DETAIL}"
        printf 'STARTED=%s\n' "${RUN_STARTED_HUMAN}"
        printf 'UPDATED=%s\n' "$now_h"
        # Epoch der letzten echten Änderung – die GUI rechnet daraus „läuft seit"
        # (server-seitig, daher stabil über Tab-Wechsel/Reconnect).
        printf 'UPDATED_EPOCH=%s\n' "$now_e"
        printf 'PID=%s\n'     "$$"
    } > "${STATE_DIR}/run_progress"
}

# Liest einen einzelnen Wert aus state/run_progress (KEY=Wert).
progress_value() {
    local key="$1"
    local file="${STATE_DIR}/run_progress"
    local name value
    [ -f "$file" ] || return
    while IFS='=' read -r name value; do
        [ "$name" = "$key" ] && { printf '%s' "$value"; return; }
    done < "$file"
}

########################################
# State
########################################

write_state() {

    local file="$1"
    local value="$2"

    echo "$value" > "${STATE_DIR}/${file}"
}

read_state() {

    local file="$1"

    [ -f "${STATE_DIR}/${file}" ] || return

    cat "${STATE_DIR}/${file}"
}

state_value() {

    local file="$1"
    local fallback="${2:--}"
    local value

    value=$(read_state "$file")
    [ -n "$value" ] && echo "$value" || echo "$fallback"
}

read_run_stat() {

    local key="$1"
    local fallback="${2:--}"
    local file="${STATE_DIR}/last_run_stats"
    local name
    local value

    [ -f "$file" ] || {
        echo "$fallback"
        return
    }

    while IFS='=' read -r name value; do
        if [ "$name" = "$key" ]; then
            [ -n "$value" ] && echo "$value" || echo "$fallback"
            return
        fi
    done < "$file"

    echo "$fallback"
}

# Prompt-freier Kern: löscht die gespeicherten Laufstatistiken.
reset_statistics_apply() {
    rm -f "${STATE_DIR}/last_run_stats"
    rm -f "${STATE_DIR}/datasets_count"
    console_success "Statistiken zurückgesetzt"
}


# Prompt-freier Kern: löscht alle Logdateien.
delete_logs_apply() {
    local count
    count=$(find "$LOG_DIR" -type f -name "*.log" 2>/dev/null | wc -l | tr -d ' ')
    find "$LOG_DIR" -type f -name "*.log" -delete 2>/dev/null
    console_success "Logs gelöscht: ${count}"
}


# Prompt-freier Kern: löscht letzten Erfolg und letzten Fehler.
reset_run_status_apply() {
    rm -f "${STATE_DIR}/last_success"
    rm -f "${STATE_DIR}/last_error"
    console_success "Laufstatus zurückgesetzt"
}


########################################
# Unraid-Notification
########################################

# Standard-Unraid-Tool für System-Benachrichtigungen (webGui). Welcher Agent
# (Pushover, Discord, E-Mail, ...) eine Notification je Stufe zustellt, regelt
# Unraid selbst – das Skript meldet nur das Ereignis an die Zentrale.
UNRAID_NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"

# Benachrichtigung über die native Unraid-Notification-Zentrale senden.
# Fehlt das Tool (z. B. Nicht-Unraid-System), still überspringen.
send_unraid_notify() {
    local subject="$1"
    local message="$2"
    local importance="${3:-normal}"   # normal | warning | alert

    [ -x "$UNRAID_NOTIFY_BIN" ] || {
        log "Unraid-Notification übersprungen, ${UNRAID_NOTIFY_BIN} nicht verfügbar"
        return 0
    }

    if "$UNRAID_NOTIFY_BIN" \
          -e "ZFS Backup" \
          -s "$subject" \
          -d "$message" \
          -i "$importance" >/dev/null 2>&1; then
        log "Unraid-Notification gesendet: ${subject} (${importance})"
        return 0
    fi

    log "FEHLER: Unraid-Notification konnte nicht gesendet werden: $subject"
    return 1
}

build_notify_message() {
    local include_error="${1:-no}"
    local created_total
    local result
    local runtime
    local datasets
    local last_error

    result=$(read_run_stat RESULT "-")
    runtime=$(read_run_stat RUNTIME_SECONDS 0)
    datasets=$(read_run_stat DATASETS 0)
    created_total=$(read_run_stat CREATED_TOTAL 0)

    cat <<EOF
Ergebnis: ${result}
Laufzeit: $(format_duration "$runtime") | Datasets: ${datasets}

Snapshots: ${created_total} neu (H $(read_run_stat CREATED_HOURLY 0), D $(read_run_stat CREATED_DAILY 0), W $(read_run_stat CREATED_WEEKLY 0), M $(read_run_stat CREATED_MONTHLY 0), Y $(read_run_stat CREATED_YEARLY 0))
Bestand Quelle: $(read_run_stat SOURCE_INVENTORY_TOTAL 0) verwaltet (H $(read_run_stat SOURCE_INVENTORY_HOURLY 0), D $(read_run_stat SOURCE_INVENTORY_DAILY 0), W $(read_run_stat SOURCE_INVENTORY_WEEKLY 0), M $(read_run_stat SOURCE_INVENTORY_MONTHLY 0), Y $(read_run_stat SOURCE_INVENTORY_YEARLY 0))

Pruning: Quelle $(read_run_stat DELETED 0), Lokal $(read_run_stat LOCAL_DELETED 0), Remote $(read_run_stat REMOTE_DELETED 0) gelöscht
Verwaiste Datasets / Snapshots: $(read_run_stat ORPHAN_DATASETS 0) Ziel-Dataset(s), $(read_run_stat SOURCE_ORPHAN_SNAPSHOTS 0) Quell-Snapshot(s) in $(read_run_stat SOURCE_ORPHAN_DATASETS 0) Dataset(s) (nicht automatisch gelöscht; Aufräumen: --cleanup-orphans)
Lokal: $(read_run_stat REPLICATION_FULL 0) Full, $(read_run_stat REPLICATION_INCREMENTAL 0) Incr, $(read_run_stat REPLICATION_RESUMED 0) Resume, $(read_run_stat REPLICATION_SKIPPED 0) aktuell, $(read_run_stat REPLICATION_ERRORS 0) Fehler
Remote: $(read_run_stat REMOTE_REPLICATION_FULL 0) Full, $(read_run_stat REMOTE_REPLICATION_INCREMENTAL 0) Incr, $(read_run_stat REMOTE_REPLICATION_RESUMED 0) Resume, $(read_run_stat REMOTE_REPLICATION_SKIPPED 0) aktuell, $(read_run_stat REMOTE_REPLICATION_ERRORS 0) Fehler

Speicher: Quelle $(format_bytes "$(read_run_stat SOURCE_SNAPSHOT_USED 0)"), Lokal $(format_bytes "$(read_run_stat LOCAL_SNAPSHOT_USED 0)"), Remote $(format_bytes "$(read_run_stat REMOTE_SNAPSHOT_USED 0)")
EOF

    if [ "$include_error" = "yes" ]; then
        last_error=$(state_value last_error "-")
        if [ "${#last_error}" -gt 180 ]; then
            last_error="${last_error:0:177}..."
        fi
        cat <<EOF

Fehler gesamt: ${RUN_ERRORS}
Letzter Fehler: ${last_error}
EOF
    fi
}

notify_start() {
    [ "$NOTIFY_START" = "aus" ] && return 0

    send_unraid_notify \
        "ZFS Backup: Snapshotlauf gestartet" \
        "Snapshotlauf gestartet: ${RUN_STARTED_HUMAN}" \
        "$NOTIFY_START"
}

notify_success() {
    [ "$NOTIFY_SUCCESS" = "aus" ] && return 0

    send_unraid_notify \
        "ZFS Backup: Lauf erfolgreich" \
        "$(build_notify_message no)" \
        "$NOTIFY_SUCCESS"
}

notify_error() {
    [ "$NOTIFY_ERROR" = "aus" ] && return 0

    send_unraid_notify \
        "ZFS Backup: Lauf mit Fehlern" \
        "$(build_notify_message yes)" \
        "$NOTIFY_ERROR"
}

notify_orphans() {
    [ "$NOTIFY_ORPHANS" = "aus" ] && return 0
    local t="${ORPHAN_DATASETS_FOUND:-0}" s="${SOURCE_ORPHAN_SNAPSHOTS_FOUND:-0}" sd="${SOURCE_ORPHAN_DATASETS_FOUND:-0}"
    [ "$t" -gt 0 ] || [ "$s" -gt 0 ] || return 0

    send_unraid_notify \
        "ZFS Backup: verwaiste Datasets / Snapshots" \
        "${t} verwaiste Ziel-Dataset(s) (Quelle gelöscht/außer Betrieb) und ${s} verwaiste Quell-Snapshot(s) in ${sd} außer Betrieb genommenen Dataset(s) gefunden. Werden NICHT automatisch gelöscht – Aufräumen über die Wartung (Verwaiste Datasets / Snapshots)." \
        "$NOTIFY_ORPHANS"
}

########################################
# Backup-Aktualität („veraltet"-Wächter)
########################################

# Alter des letzten erfolgreichen Laufs in Sekunden (aus last_success_epoch).
# Rückgabe 1, wenn unbekannt (noch kein Erfolg / alter State ohne Epoch).
backup_age_seconds() {
    local epoch now
    epoch=$(state_value last_success_epoch "")
    case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
    now=$(date +%s)
    echo $(( now - epoch ))
}

# Ist das Backup veraltet? (STALE_AFTER_HOURS > 0 und Alter >= Schwelle.)
backup_is_stale() {
    [ "${STALE_AFTER_HOURS:-0}" -gt 0 ] 2>/dev/null || return 1
    local age
    age=$(backup_age_seconds) || return 1
    [ $(( age / 3600 )) -ge "$STALE_AFTER_HOURS" ]
}

# Wächter: prüft die Aktualität und meldet EINMAL (Merker stale_notified), wenn
# das Backup veraltet ist. Wird nicht mehr veraltet (frischer Erfolg), entfällt
# der Merker -> künftiges Veralten meldet wieder. Aufruf über --check-stale
# (eigener Wächter-Cron, nur bei aktivem Zeitplan angelegt).
check_stale() {
    local marker="${STATE_DIR}/stale_notified"
    local age

    if backup_is_stale; then
        if [ ! -f "$marker" ]; then
            age=$(backup_age_seconds)
            send_unraid_notify \
                "ZFS Backup: veraltet" \
                "Letztes erfolgreiches Backup vor $(format_duration "$age") (Schwelle ${STALE_AFTER_HOURS} h). Läuft der Zeitplan noch?" \
                warning
            : > "$marker"
            log "Warnung: Backup veraltet ($(format_duration "$age")), Notification gesendet"
        fi
    else
        rm -f "$marker"
    fi
}

########################################
# Config Check
########################################

config_check() {

    local errors=0
    local warnings=0
    local include_count=0
    local active_count=0
    local ds
    local keep_name
    local keep_value
    local target_id

    log_phase "Config Check"

    for ds in "${INCLUDES[@]}"; do
        ((include_count++))

        if zfs list "$ds" >/dev/null 2>&1; then
            :

        else

            console_error "Include nicht gefunden: $ds"
            ((errors++))
        fi
    done

    for ds in "${EXCLUDES[@]}"; do

        if zfs list "$ds" >/dev/null 2>&1; then
            :

        else

            console_warn "Exclude nicht gefunden: $ds"
            ((warnings++))
        fi
    done

    if [ -n "$SNAPSHOT_PREFIX" ] && zfs_name_is_safe "dataset@${SNAPSHOT_PREFIX}test"; then
        :
    else
        console_error "Snapshot-Prefix ist leer oder enthält unsichere Zeichen"
        ((errors++))
    fi

    case "$SNAPSHOT_POOL_ROOTS" in
        yes|no) ;;
        *)
            console_error "SNAPSHOT_POOL_ROOTS muss yes oder no sein"
            ((errors++))
            ;;
    esac

    if [ "${#TARGETS[@]}" -eq 0 ]; then
        console_warn "Keine Replikationsziele konfiguriert"
        ((warnings++))
    fi

    for target_id in "${TARGETS[@]}"; do
        if ! target_id_is_valid "$target_id"; then
            console_error "Ungültige Ziel-ID: $target_id"
            ((errors++))
            continue
        fi

        load_target_context "$target_id" || {
            console_error "Ziel konnte nicht geladen werden: $target_id"
            ((errors++))
            continue
        }

        case "$(target_type "$target_id")" in
            local)
                if ! zfs_name_is_safe "$LOCAL_BACKUP_POOL"; then
                    console_error "Lokales Ziel enthält unsichere Zeichen: ${target_id} -> $LOCAL_BACKUP_POOL"
                    ((errors++))
                elif ! zfs list "$LOCAL_BACKUP_POOL" >/dev/null 2>&1; then
                    console_error "Lokaler Ziel-Pool nicht gefunden: ${target_id} -> $LOCAL_BACKUP_POOL"
                    ((errors++))
                fi
                ;;
            remote)
                if ! zfs_name_is_safe "$REMOTE_BASE_DATASET"; then
                    console_error "Remote Basis-Dataset enthält unsichere Zeichen: ${target_id} -> $REMOTE_BASE_DATASET"
                    ((errors++))
                fi

                if [ -z "$REMOTE_HOST" ]; then
                    console_error "Remote Host nicht gesetzt: $target_id"
                    ((errors++))
                elif ensure_remote_ready && remote_zfs_list "$REMOTE_BASE_DATASET"; then
                    :
                else
                    console_warn "Remote Ziel-Dataset nicht gefunden oder SSH nicht erreichbar: ${target_id} -> ${REMOTE_HOST}:${REMOTE_BASE_DATASET}"
                    ((warnings++))
                fi

                if [ "$ENABLE_REMOTE_WAKE_ON_LAN" = "yes" ]; then
                    if [ -z "$REMOTE_WAKE_MAC" ]; then
                        console_error "Remote Wake-MAC nicht gesetzt: $target_id"
                        ((errors++))
                    elif ! command -v etherwake >/dev/null 2>&1; then
                        console_error "etherwake nicht gefunden"
                        ((errors++))
                    fi
                fi

                if ! [ "$REMOTE_REPLICATION_RETRY_ATTEMPTS" -ge 0 ] 2>/dev/null; then
                    console_error "Remote Retry-Versuche müssen eine Zahl >= 0 sein: $target_id"
                    ((errors++))
                fi

                if ! [ "$REMOTE_REPLICATION_RETRY_WAIT_SECONDS" -ge 0 ] 2>/dev/null; then
                    console_error "Remote Retry-Wartezeit muss eine Zahl >= 0 sein: $target_id"
                    ((errors++))
                fi
                ;;
            borg)
                if [ -z "$BORG_REPO" ] || ! borg_repo_is_safe "$BORG_REPO"; then
                    console_error "Borg-Repo-URL fehlt oder ist ungültig: ${target_id} -> $BORG_REPO"
                    ((errors++))
                fi
                if ! [ "$BORG_COMPACT_EVERY" -ge 0 ] 2>/dev/null; then
                    console_error "Borg COMPACT_EVERY muss eine Zahl >= 0 sein: $target_id"
                    ((errors++))
                fi
                if ! borg_bin >/dev/null 2>&1; then
                    console_warn "Borg-Binary nicht gefunden (weder gebündelt noch im PATH): $target_id"
                    ((warnings++))
                elif ! borg_run info >/dev/null 2>&1; then
                    console_warn "Borg-Repo nicht erreichbar (Passphrase/Netz/Repo prüfen): ${target_id} -> $BORG_REPO"
                    ((warnings++))
                fi
                ;;
            *)
                console_error "Unbekannter Zieltyp: ${target_id} -> $(target_type "$target_id")"
                ((errors++))
                ;;
        esac

    done

    for keep_name in KEEP_HOURLY KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY KEEP_YEARLY; do
        keep_value="${!keep_name}"
        # 0 ist gültig und bedeutet „Typ aus" (keine Erstellung, kein Bestand).
        if ! [ "$keep_value" -ge 0 ] 2>/dev/null; then
            console_error "${keep_name} muss eine Zahl >= 0 sein (0 = Typ aus)"
            ((errors++))
        fi
    done

    if [ "${KEEP_HOURLY:-0}" -eq 0 ] && [ "${KEEP_DAILY:-0}" -eq 0 ] \
       && [ "${KEEP_WEEKLY:-0}" -eq 0 ] && [ "${KEEP_MONTHLY:-0}" -eq 0 ] \
       && [ "${KEEP_YEARLY:-0}" -eq 0 ] 2>/dev/null; then
        console_warn "Alle Snapshot-Typen deaktiviert (alle KEEP_*=0) – es werden keine Snapshots erstellt"
        ((warnings++))
    fi

    if [ "$NOTIFY_START" != "aus" ] || [ "$NOTIFY_SUCCESS" != "aus" ] || [ "$NOTIFY_ERROR" != "aus" ] || [ "$NOTIFY_ORPHANS" != "aus" ]; then
        if [ ! -x "$UNRAID_NOTIFY_BIN" ]; then
            console_warn "Unraid-Notification-Tool nicht gefunden (${UNRAID_NOTIFY_BIN}) – Benachrichtigungen werden übersprungen"
            ((warnings++))
        fi
    fi

    # Informativer borg-Versions-Check (gedrosselt; aktualisiert den Cache bewusst).
    local borg_uhint
    borg_update_refresh
    borg_uhint=$(borg_update_cached_hint)
    [ -n "$borg_uhint" ] && console_info "$borg_uhint"

    active_count=$(get_datasets | wc -l | tr -d ' ')

    echo
    echo "Konfiguration"
    printf "  Datasets     %s aktiv aus %s Include(s), %s Exclude(s)\n" "$active_count" "$include_count" "${#EXCLUDES[@]}"
    printf "  Snapshots    Prefix %s\n" "$SNAPSHOT_PREFIX"
    printf "  Retention    %sh/%sd/%sw/%sm/%sy\n" "$KEEP_HOURLY" "$KEEP_DAILY" "$KEEP_WEEKLY" "$KEEP_MONTHLY" "$KEEP_YEARLY"
    printf "  Ziele        %s konfiguriert, %s aktiv\n" "${#TARGETS[@]}" "$(target_enabled_count all)"
    printf "  Wartung      Quell-Pruning %s  |  Zielabgleich automatisch\n" "$ENABLE_SOURCE_PRUNING"
    printf "  Notify       Start %s  |  Erfolg %s  |  Fehler %s  |  Verwaist %s\n" "$NOTIFY_START" "$NOTIFY_SUCCESS" "$NOTIFY_ERROR" "$NOTIFY_ORPHANS"
    if [ "${STALE_AFTER_HOURS:-0}" -gt 0 ] 2>/dev/null; then
        printf "  Veraltet-Warnung ab %s h\n" "$STALE_AFTER_HOURS"
    fi
    if [ "$SCHEDULE_ENABLED" = "yes" ] && [ -n "$SCHEDULE_CRON" ]; then
        printf "  Zeitplan     %s (nur Unraid-Plugin)\n" "$SCHEDULE_CRON"
    else
        printf "  Zeitplan     aus (nur Unraid-Plugin)\n"
    fi
    printf "  Pfade        Daten %s  |  Laufzeit %s\n" "$DATA_DIR" "$RUNTIME_DIR"
    local auto_ex
    auto_ex=$(auto_excluded_datasets | tr '\n' ' ')
    [ -n "$auto_ex" ] && printf "  Auto-Exclude %s\n" "$auto_ex"
    echo

    if [ $errors -eq 0 ]; then
        console_success "Config Check abgeschlossen: ${errors} Fehler, ${warnings} Warnung(en)"
    else
        console_error "Config Check abgeschlossen: ${errors} Fehler, ${warnings} Warnung(en)"
    fi
}

########################################
# Status
########################################

show_status() {

    local created_total
    local result
    local status_icon="•"
    local status_color="0;36"
    local target_id
    local target_type
    local target_state
    local has_run="no"
    local local_active
    local remote_active
    local version_line

    [ -f "${STATE_DIR}/last_run_stats" ] && has_run="yes"
    local_active=$(target_enabled_count local)
    remote_active=$(target_enabled_count remote)

    created_total=$(read_run_stat CREATED_TOTAL 0)
    result=$(read_run_stat RESULT "-")

    case "$result" in
        ERFOLG)
            status_icon="✓"
            status_color="0;32"
            ;;
        FEHLER)
            status_icon="✗"
            status_color="0;31"
            ;;
    esac

    version_line="v${SCRIPT_VERSION}"

    echo
    console_color "1;34"
    echo "ZFS Backup Status"
    console_reset
    echo

    if [ "$has_run" = "no" ]; then
        console_warn "Noch kein Snapshotlauf erfasst — die Lauf-Werte unten erscheinen erst nach dem ersten Lauf."
        echo
    fi

    console_color "$status_color"
    printf "%s " "$status_icon"
    console_reset
    printf "Letzter Lauf   %s  |  %s  |  %s\n" \
        "$result" \
        "$(format_duration "$(read_run_stat RUNTIME_SECONDS 0)")" \
        "$(read_run_stat LAST_RUN)"

    printf "Version        %s\n" "$version_line"
    printf "Letzter Erfolg %s\n" "$(state_value last_success)"
    printf "Letzter Fehler %s\n" "$(state_value last_error)"
    echo

    echo "Verwaltete Snapshots (Bestand, Stand letzter Lauf)"
    printf "  Neu erstellt  %s gesamt  (%s hourly, %s daily, %s weekly, %s monthly, %s yearly)\n" \
        "$created_total" \
        "$(read_run_stat CREATED_HOURLY 0)" \
        "$(read_run_stat CREATED_DAILY 0)" \
        "$(read_run_stat CREATED_WEEKLY 0)" \
        "$(read_run_stat CREATED_MONTHLY 0)" \
        "$(read_run_stat CREATED_YEARLY 0)"
    printf "  Quelle        %s Snapshots  (%s hourly, %s daily, %s weekly, %s monthly, %s yearly)\n" \
        "$(read_run_stat SOURCE_INVENTORY_TOTAL 0)" \
        "$(read_run_stat SOURCE_INVENTORY_HOURLY 0)" \
        "$(read_run_stat SOURCE_INVENTORY_DAILY 0)" \
        "$(read_run_stat SOURCE_INVENTORY_WEEKLY 0)" \
        "$(read_run_stat SOURCE_INVENTORY_MONTHLY 0)" \
        "$(read_run_stat SOURCE_INVENTORY_YEARLY 0)"
    if [ "$local_active" -eq 0 ]; then
        printf "  Lokal         kein aktives lokales Ziel\n"
    else
        printf "  Lokal         %s Snapshots  (%s hourly, %s daily, %s weekly, %s monthly, %s yearly)\n" \
            "$(read_run_stat LOCAL_INVENTORY_TOTAL 0)" \
            "$(read_run_stat LOCAL_INVENTORY_HOURLY 0)" \
            "$(read_run_stat LOCAL_INVENTORY_DAILY 0)" \
            "$(read_run_stat LOCAL_INVENTORY_WEEKLY 0)" \
            "$(read_run_stat LOCAL_INVENTORY_MONTHLY 0)" \
            "$(read_run_stat LOCAL_INVENTORY_YEARLY 0)"
    fi
    if [ "$remote_active" -eq 0 ]; then
        printf "  Remote        kein aktives Remote-Ziel\n"
    else
        printf "  Remote        %s Snapshots  (%s hourly, %s daily, %s weekly, %s monthly, %s yearly)\n" \
            "$(read_run_stat REMOTE_INVENTORY_TOTAL 0)" \
            "$(read_run_stat REMOTE_INVENTORY_HOURLY 0)" \
            "$(read_run_stat REMOTE_INVENTORY_DAILY 0)" \
            "$(read_run_stat REMOTE_INVENTORY_WEEKLY 0)" \
            "$(read_run_stat REMOTE_INVENTORY_MONTHLY 0)" \
            "$(read_run_stat REMOTE_INVENTORY_YEARLY 0)"
    fi
    printf "  Speicher      Anzahl / belegt: Quelle %s / %s  |  Lokal %s / %s  |  Remote %s / %s\n" \
        "$(read_run_stat SOURCE_SNAPSHOT_COUNT 0)" \
        "$(format_bytes "$(read_run_stat SOURCE_SNAPSHOT_USED 0)")" \
        "$(read_run_stat LOCAL_SNAPSHOT_COUNT 0)" \
        "$(format_bytes "$(read_run_stat LOCAL_SNAPSHOT_USED 0)")" \
        "$(read_run_stat REMOTE_SNAPSHOT_COUNT 0)" \
        "$(format_bytes "$(read_run_stat REMOTE_SNAPSHOT_USED 0)")"
    printf "  Gelöscht      Pruning: Quelle %s, lokal %s, remote %s\n" \
        "$(read_run_stat DELETED 0)" \
        "$(read_run_stat LOCAL_DELETED 0)" \
        "$(read_run_stat REMOTE_DELETED 0)"
    echo

    echo "Replikation letzter Lauf  (aktuell = war bereits auf Stand)"
    if [ "$local_active" -eq 0 ]; then
        printf "  Lokal         kein aktives lokales Ziel\n"
    else
        printf "  Lokal         %s Full, %s inkrementell, %s fortgesetzt, %s aktuell, %s Fehler\n" \
            "$(read_run_stat REPLICATION_FULL 0)" \
            "$(read_run_stat REPLICATION_INCREMENTAL 0)" \
            "$(read_run_stat REPLICATION_RESUMED 0)" \
            "$(read_run_stat REPLICATION_SKIPPED 0)" \
            "$(read_run_stat REPLICATION_ERRORS 0)"
    fi
    if [ "$remote_active" -eq 0 ]; then
        printf "  Remote        kein aktives Remote-Ziel\n"
    else
        printf "  Remote        %s Full, %s inkrementell, %s fortgesetzt, %s aktuell, %s Fehler\n" \
            "$(read_run_stat REMOTE_REPLICATION_FULL 0)" \
            "$(read_run_stat REMOTE_REPLICATION_INCREMENTAL 0)" \
            "$(read_run_stat REMOTE_REPLICATION_RESUMED 0)" \
            "$(read_run_stat REMOTE_REPLICATION_SKIPPED 0)" \
            "$(read_run_stat REMOTE_REPLICATION_ERRORS 0)"
    fi
    echo

    echo "Ziele"
    if [ "${#TARGETS[@]}" -eq 0 ]; then
        echo "  Keine Ziele konfiguriert"
    fi
    for target_id in "${TARGETS[@]}"; do
        target_type=$(target_type "$target_id")
        if target_enabled "$target_id"; then
            target_state="aktiv"
        else
            target_state="deaktiviert"
        fi
        if [ "$target_type" = "borg" ]; then
            printf "  %-12s %-11s | Typ: %s | Repo: %s" \
                "$target_id" "$target_state" "$target_type" \
                "$(target_get "$target_id" REPO)"
        else
            printf "  %-12s %-11s | Typ: %s | Ziel: %s" \
                "$target_id" "$target_state" "$target_type" \
                "$(target_get "$target_id" BASE_DATASET)"
        fi
        if [ "$target_type" = "remote" ]; then
            printf " | Host: %s" "$(target_get "$target_id" HOST)"
        fi
        printf "\n"
    done
    echo

    echo "Wartung"
    printf "  Quell-Pruning %s\n" "$ENABLE_SOURCE_PRUNING"
    echo

    echo "Pfade"
    printf "  Config        %s\n" "$CONFIG_FILE"
    printf "  Logs          %s\n" "$LOG_DIR"
    echo
}

# Maschinenlesbarer Status fürs GUI-Dashboard (--status --json).
# Spiegelt die Kernwerte von show_status; rein lesend, ohne ZFS-Aufrufe.
status_json() {

    local result runtime last_run
    local local_active remote_active borg_active
    local has_run=false
    local running=false
    local running_pid=""

    [ -f "${STATE_DIR}/last_run_stats" ] && has_run=true

    # Live-Status über das Lock-File (analog acquire_lock, aber ohne Seiteneffekt).
    if [ -f "$LOCK_FILE" ]; then
        running_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$running_pid" ] && ps -p "$running_pid" >/dev/null 2>&1; then
            running=true
        else
            running_pid=""
        fi
    fi

    result=$(read_run_stat RESULT "-")
    runtime=$(read_run_stat RUNTIME_SECONDS 0)
    last_run=$(read_run_stat LAST_RUN "")
    local_active=$(target_enabled_count local)
    remote_active=$(target_enabled_count remote)
    borg_active=$(target_enabled_count borg)

    printf '{'
    printf '"version":"%s",' "$(json_escape "$SCRIPT_VERSION")"
    printf '"running":%s,' "$running"
    if [ -n "$running_pid" ]; then
        printf '"running_pid":%s,' "$(json_num "$running_pid")"
    else
        printf '"running_pid":null,'
    fi
    if [ "$running" = "true" ] && [ -f "${STATE_DIR}/run_progress" ]; then
        printf '"progress":{"phase":"%s","detail":"%s","started":"%s","updated":"%s","updated_epoch":%s},' \
            "$(json_escape "$(progress_value PHASE)")" \
            "$(json_escape "$(progress_value DETAIL)")" \
            "$(json_escape "$(progress_value STARTED)")" \
            "$(json_escape "$(progress_value UPDATED)")" \
            "$(json_num "$(progress_value UPDATED_EPOCH)")"
    else
        printf '"progress":null,'
    fi
    printf '"has_run":%s,' "$has_run"
    printf '"last_run":{"timestamp":"%s","result":"%s","runtime_seconds":%s,"runtime_human":"%s"},' \
        "$(json_escape "$last_run")" \
        "$(json_escape "$result")" \
        "$(json_num "$runtime")" \
        "$(json_escape "$(format_duration "$runtime")")"
    printf '"last_success":"%s",' "$(json_escape "$(state_value last_success)")"
    printf '"last_error":"%s",' "$(json_escape "$(state_value last_error)")"
    # Backup-Aktualität: veraltet? + Alter (Stunden, null wenn unbekannt).
    local age_s age_h="null"
    if age_s=$(backup_age_seconds); then age_h=$(( age_s / 3600 )); fi
    printf '"stale":%s,"stale_after_hours":%s,"backup_age_hours":%s,' \
        "$(backup_is_stale && echo true || echo false)" \
        "$(json_num "${STALE_AFTER_HOURS:-0}")" \
        "$age_h"
    printf '"snapshots_created":{"total":%s,"hourly":%s,"daily":%s,"weekly":%s,"monthly":%s,"yearly":%s},' \
        "$(json_num "$(read_run_stat CREATED_TOTAL 0)")" \
        "$(json_num "$(read_run_stat CREATED_HOURLY 0)")" \
        "$(json_num "$(read_run_stat CREATED_DAILY 0)")" \
        "$(json_num "$(read_run_stat CREATED_WEEKLY 0)")" \
        "$(json_num "$(read_run_stat CREATED_MONTHLY 0)")" \
        "$(json_num "$(read_run_stat CREATED_YEARLY 0)")"
    printf '"targets":{"local_active":%s,"remote_active":%s,"borg_active":%s},' \
        "$(json_num "$local_active")" \
        "$(json_num "$remote_active")" \
        "$(json_num "$borg_active")"
    # borg-Versions-Hinweis (nur aus dem Cache; kein Netz beim Seitenaufbau).
    printf '"borg_update":"%s",' "$(json_escape "$(borg_update_cached_hint)")"
    # Gesicherte Datasets + verwalteter Snapshot-Bestand der Quelle (Stand letzter
    # Lauf, aus den run-stats – kein zfs/kein Wecken). Für die Dashboard-Übersicht.
    printf '"dataset_count":%s,' "$(json_num "$(read_run_stat DATASETS 0)")"
    printf '"source_inventory":{"total":%s,"hourly":%s,"daily":%s,"weekly":%s,"monthly":%s,"yearly":%s},' \
        "$(json_num "$(read_run_stat SOURCE_INVENTORY_TOTAL 0)")" \
        "$(json_num "$(read_run_stat SOURCE_INVENTORY_HOURLY 0)")" \
        "$(json_num "$(read_run_stat SOURCE_INVENTORY_DAILY 0)")" \
        "$(json_num "$(read_run_stat SOURCE_INVENTORY_WEEKLY 0)")" \
        "$(json_num "$(read_run_stat SOURCE_INVENTORY_MONTHLY 0)")" \
        "$(json_num "$(read_run_stat SOURCE_INVENTORY_YEARLY 0)")"
    # Verwaiste Datasets (Stand letzter Lauf; werden nie automatisch gelöscht).
    # orphan_datasets = Ziel-Datasets; source_orphan_datasets = außer Betrieb
    # genommene Quell-Datasets mit verbliebenen Snapshots.
    printf '"orphan_datasets":%s,' "$(json_num "$(read_run_stat ORPHAN_DATASETS 0)")"
    printf '"source_orphan_datasets":%s,' "$(json_num "$(read_run_stat SOURCE_ORPHAN_DATASETS 0)")"
    printf '"source_orphan_snapshots":%s,' "$(json_num "$(read_run_stat SOURCE_ORPHAN_SNAPSHOTS 0)")"
    # Pfade read-only fürs GUI (vom Plugin/Wrapper gesetzt, nicht editierbar).
    printf '"paths":{"data_dir":"%s","runtime_dir":"%s","config_file":"%s","log_dir":"%s","state_dir":"%s","lock_dir":"%s"}' \
        "$(json_escape "$DATA_DIR")" \
        "$(json_escape "$RUNTIME_DIR")" \
        "$(json_escape "$CONFIG_FILE")" \
        "$(json_escape "$LOG_DIR")" \
        "$(json_escape "$STATE_DIR")" \
        "$(json_escape "$LOCK_DIR")"
    printf '}\n'
}

########################################
# Simulate
########################################

simulate() {

    local ds
    local count=0

    console_phase "Simulation"

    echo
    echo "Konfiguration"
    printf "  Includes     %s\n" "${#INCLUDES[@]}"
    printf "  Excludes     %s\n" "${#EXCLUDES[@]}"
    printf "  Pool-Roots   %s\n" "$SNAPSHOT_POOL_ROOTS"
    printf "  Prefix       %s\n" "$SNAPSHOT_PREFIX"
    printf "  Retention    %sh/%sd/%sw/%sm/%sy\n" "$KEEP_HOURLY" "$KEEP_DAILY" "$KEEP_WEEKLY" "$KEEP_MONTHLY" "$KEEP_YEARLY"

    echo
    echo "Includes:"
    for ds in "${INCLUDES[@]}"; do
        echo "  $ds"
    done

    echo
    echo "Excludes:"
    for ds in "${EXCLUDES[@]}"; do
        echo "  $ds"
    done

    # Ziele einmal vorab bereitmachen, damit der pro-Dataset-Zielabgleich echte
    # Zahlen liefert: Remote-Ziele wecken (Wake-on-LAN), Borg-Repos prüfen. Nicht
    # erreichbare Ziele in SIM_UNREACHABLE_IDS merken und in der Vorschau nur als
    # „übersprungen" ausweisen, statt die Simulation zu blockieren.
    local sim_tid
    SIM_UNREACHABLE_IDS="|"
    BORG_SIM_LOADED_ID=""
    for sim_tid in "${TARGETS[@]}"; do
        target_enabled "$sim_tid" || continue
        load_target_context "$sim_tid" || continue
        case "$(target_type "$sim_tid")" in
            remote)
                ensure_remote_ready >/dev/null 2>&1 || SIM_UNREACHABLE_IDS="${SIM_UNREACHABLE_IDS}${sim_tid}|"
                ;;
            borg)
                { borg_ensure_binary && borg_run info >/dev/null 2>&1; } \
                    || SIM_UNREACHABLE_IDS="${SIM_UNREACHABLE_IDS}${sim_tid}|"
                ;;
        esac
    done

    echo

    echo "Datasets und geplante Aktionen:"
    while read -r ds; do
        [ -n "$ds" ] || continue
        ((count++))
        simulate_dataset "$ds"
    done < <(get_datasets)

    simulate_orphan_datasets

    echo
    console_success "Simulation abgeschlossen: ${count} Dataset(s) geprüft, keine Änderungen ausgeführt"
}

########################################
# Dataset / Snapshot Engine
########################################

# Gibt das ZFS-Dataset zurück, dessen Mountpoint EXAKT dem Pfad entspricht (der
# Pfad ist also ein Dataset-Wurzelverzeichnis), sonst nichts. So wird nur ein
# eigenes Dataset des Tools erkannt, kein Unterordner eines größeren Datasets.
zfs_dataset_at_path() {
    local path
    path=$(realpath "$1" 2>/dev/null) || return 1
    [ -n "$path" ] || return 1
    zfs list -H -o name,mountpoint 2>/dev/null | awk -v p="$path" '$2 == p { print $1; exit }'
}

# Ermittelt einmalig (gecacht) die Datasets, die die Tool-eigenen Daten tragen
# (DATA_DIR, RUNTIME_DIR). Diese werden nie gesichert: Logs/State ändern sich
# bei jedem Lauf, und das Skript selbst liegt im git-Repo.
compute_self_datasets() {
    [ "$SELF_DATASETS_COMPUTED" -eq 1 ] && return
    SELF_DATASETS_COMPUTED=1

    local dir ds existing found
    for dir in "$DATA_DIR" "$RUNTIME_DIR"; do
        ds=$(zfs_dataset_at_path "$dir") || continue
        [ -n "$ds" ] || continue
        found=0
        for existing in "${SELF_DATASETS[@]}"; do
            [ "$existing" = "$ds" ] && { found=1; break; }
        done
        [ "$found" -eq 0 ] && SELF_DATASETS+=("$ds")
    done
}

# True, wenn das Dataset selbst oder ein Elterndataset ein Tool-eigenes ist.
is_self_dataset() {
    local ds="$1"
    local self
    compute_self_datasets
    for self in "${SELF_DATASETS[@]}"; do
        [[ "$ds" == "$self" || "$ds" == "$self/"* ]] && return 0
    done
    return 1
}

# True, wenn das Dataset (oder ein Elterndataset) fest erzwungen ausgeschlossen
# ist (FORCE_EXCLUDES, z. B. cache/system).
is_force_excluded() {
    local ds="$1"
    local fx
    for fx in "${FORCE_EXCLUDES[@]}"; do
        [ -n "$fx" ] || continue
        [[ "$ds" == "$fx" || "$ds" == "$fx/"* ]] && return 0
    done
    return 1
}

# Alle automatisch ausgeschlossenen Datasets (für Anzeige/JSON): Tool-eigene
# (DATA_DIR/RUNTIME_DIR) plus erzwungene (FORCE_EXCLUDES).
auto_excluded_datasets() {
    compute_self_datasets
    local d
    for d in "${SELF_DATASETS[@]}" "${FORCE_EXCLUDES[@]}"; do
        [ -n "$d" ] && printf '%s\n' "$d"
    done
}

is_excluded() {
    local ds="$1"
    for ex in "${EXCLUDES[@]}"; do
        [[ "$ds" == "$ex" ]] && return 0
        [[ "$ds" == "$ex/"* ]] && return 0
    done
    return 1
}

is_include_override() {
    local ds="$1"
    local inc

    for inc in "${INCLUDES[@]}"; do
        [[ "$ds" == "$inc" || "$ds" == "$inc/"* ]] || continue

        if is_excluded "$inc"; then
            return 0
        fi
    done

    return 1
}

is_active_dataset() {
    local ds="$1"

    # Tool-eigene (DATA_DIR/RUNTIME_DIR) und erzwungene (FORCE_EXCLUDES, z. B.
    # cache/system) Datasets werden hart ausgeschlossen – auch gegen einen
    # expliziten Include; ihr Sichern ergibt keinen Sinn.
    is_self_dataset "$ds" && return 1
    is_force_excluded "$ds" && return 1
    ! is_excluded "$ds" && return 0
    is_include_override "$ds"
}

is_pool_root_dataset() {
    local ds="$1"

    [[ "$ds" != */* ]]
}

should_skip_pool_root_dataset() {
    local ds="$1"

    [ "$SNAPSHOT_POOL_ROOTS" = "yes" ] && return 1
    is_pool_root_dataset "$ds"
}

included_pool_roots() {
    local root
    local seen="|"

    for root in "${INCLUDES[@]}"; do
        is_pool_root_dataset "$root" || continue
        case "$seen" in
            *"|${root}|"*) continue ;;
        esac
        echo "$root"
        seen="${seen}${root}|"
    done
}

get_datasets() {
    local root
    local ds
    local seen="|"

    for root in "${INCLUDES[@]}"; do
        while read -r ds; do
            [ -n "$ds" ] || continue
            case "$seen" in
                *"|${ds}|"*) continue ;;
            esac

            should_skip_pool_root_dataset "$ds" && continue

            if is_active_dataset "$ds"; then
                echo "$ds"
                seen="${seen}${ds}|"
            fi
        done < <(zfs list -H -o name -r "$root" 2>/dev/null)
    done
}

show_datasets() {
    local count=0
    local ds

    console_phase "Datasets"

    echo
    echo "Aktive Datasets"

    while read -r ds; do
        [ -n "$ds" ] || continue
        ((count++))
        printf "  %2d  %s\n" "$count" "$ds"
    done < <(get_datasets)

    echo

    if [ "$count" -gt 0 ]; then
        console_success "Datasets abgeschlossen: ${count} aktiv, ${#INCLUDES[@]} Include(s), ${#EXCLUDES[@]} Exclude(s)"
    else
        console_warn "Datasets abgeschlossen: keine aktiven Datasets gefunden"
    fi
}

# Aktive Datasets als JSON fürs GUI (--datasets --json).
# Live über get_datasets (zfs); inkl. Include-/Exclude-Anzahl.
datasets_json() {
    local ds first=1 self sfirst=1

    printf '{"includes":%s,"excludes":%s,"auto_excluded":[' \
        "$(json_num "${#INCLUDES[@]}")" \
        "$(json_num "${#EXCLUDES[@]}")"
    while read -r self; do
        [ -n "$self" ] || continue
        if [ "$sfirst" -eq 1 ]; then sfirst=0; else printf ','; fi
        printf '"%s"' "$(json_escape "$self")"
    done < <(auto_excluded_datasets)
    printf '],"active":['
    while read -r ds; do
        [ -n "$ds" ] || continue
        if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
        printf '"%s"' "$(json_escape "$ds")"
    done < <(get_datasets)
    printf ']}\n'
}

snapshot_exists() {
    local ds="$1"
    local pattern="$2"

    while read -r snap; do
        case "$snap" in
            "${ds}@${pattern}"*) return 0 ;;
        esac
    done < <(zfs list -H -t snapshot -o name 2>/dev/null)

    return 1
}

create_snapshot() {
    local ds="$1"
    local snap="$2"
    local type="${3:-snapshot}"
    local label="$type"

    if zfs list -t snapshot "${ds}@${snap}" >/dev/null 2>&1; then
        return 1
    fi

    case "$type" in
        hourly) label="Hourly" ;;
        daily) label="Daily" ;;
        weekly) label="Weekly" ;;
        monthly) label="Monthly" ;;
        yearly) label="Yearly" ;;
        *) label="Snapshot" ;;
    esac

    log "Snapshot ${label}: ${ds}@${snap}"
    if zfs snapshot "${ds}@${snap}"; then
        return 0
    fi

    log "FEHLER: Snapshot konnte nicht erstellt werden: ${ds}@${snap}"
    write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Snapshot fehlgeschlagen: ${ds}@${snap}"
    ((RUN_ERRORS++))
    return 1
}

increment_created_counter() {
    local type="$1"

    case "$type" in
        hourly) ((CREATED_HOURLY++)) ;;
        daily) ((CREATED_DAILY++)) ;;
        weekly) ((CREATED_WEEKLY++)) ;;
        monthly) ((CREATED_MONTHLY++)) ;;
        yearly) ((CREATED_YEARLY++)) ;;
    esac
}

increment_existing_counter() {
    local type="$1"

    case "$type" in
        hourly) ((EXISTING_HOURLY++)) ;;
        daily) ((EXISTING_DAILY++)) ;;
        weekly) ((EXISTING_WEEKLY++)) ;;
        monthly) ((EXISTING_MONTHLY++)) ;;
        yearly) ((EXISTING_YEARLY++)) ;;
    esac
}

create_snapshot_by_type() {
    local ds="$1"
    local type="$2"
    local snap="$3"

    if create_snapshot "$ds" "$snap" "$type"; then
        increment_created_counter "$type"
        return 0
    fi

    return 1
}

create_snapshot_set() {
    local ds="$1"
    local created=0

    local DATE=$(date +%Y-%m-%d)
    local TIME=$(date +%H-%M)
    local WEEK=$(date +%G-W%V)
    local MONTH=$(date +%Y-%m)
    local YEAR=$(date +%Y)

    if type_enabled hourly; then
        if ! snapshot_exists "$ds" "${SNAPSHOT_PREFIX}hourly_${DATE}_$(date +%H)"; then
            create_snapshot_by_type "$ds" hourly "${SNAPSHOT_PREFIX}hourly_${DATE}_${TIME}" && ((created++))
        else
            increment_existing_counter hourly
            log "Snapshot Hourly vorhanden: $ds"
        fi
    fi

    if type_enabled daily; then
        if ! snapshot_exists "$ds" "${SNAPSHOT_PREFIX}daily_${DATE}_"; then
            create_snapshot_by_type "$ds" daily "${SNAPSHOT_PREFIX}daily_${DATE}_${TIME}" && ((created++))
        else
            increment_existing_counter daily
            log "Snapshot Daily vorhanden: $ds"
        fi
    fi

    # Seeding-Prinzip (weekly/monthly/yearly): NICHT auf den Kalenderstichtag
    # (So. / 1. des Monats / 1.1.) warten, sondern pro Periode genau einen
    # Snapshot sicherstellen. Der Periodenschlüssel im Namen (ISO-Woche, Monat,
    # Jahr) bestimmt die Eindeutigkeit; existiert er für die aktuelle Periode
    # noch nicht, wird er angelegt. Folgen:
    #   * Erstlauf seedet sofort alle Stufen -> tiefer Anker (z. B. yearly) ab
    #     Tag 1, statt bis zum nächsten Stichtag zu warten. Das verlängert u. a.
    #     das Fenster, in dem ein deaktiviertes Ziel per Incremental wieder
    #     aufholen kann (kein Neuaufbau).
    #   * Verpasste Stichtage heilen sich selbst (Box am 1.1. aus -> der nächste
    #     Lauf legt den Jahres-Snapshot trotzdem an).
    # Danach weiterhin genau einer pro Periode (Folgeläufe finden ihn vor).
    if type_enabled weekly; then
        if ! snapshot_exists "$ds" "${SNAPSHOT_PREFIX}weekly_${WEEK}_"; then
            create_snapshot_by_type "$ds" weekly "${SNAPSHOT_PREFIX}weekly_${WEEK}_${TIME}" && ((created++))
        else
            increment_existing_counter weekly
            log "Snapshot Weekly vorhanden: $ds"
        fi
    fi

    if type_enabled monthly; then
        if ! snapshot_exists "$ds" "${SNAPSHOT_PREFIX}monthly_${MONTH}_"; then
            create_snapshot_by_type "$ds" monthly "${SNAPSHOT_PREFIX}monthly_${MONTH}_${TIME}" && ((created++))
        else
            increment_existing_counter monthly
            log "Snapshot Monthly vorhanden: $ds"
        fi
    fi

    if type_enabled yearly; then
        if ! snapshot_exists "$ds" "${SNAPSHOT_PREFIX}yearly_${YEAR}_"; then
            create_snapshot_by_type "$ds" yearly "${SNAPSHOT_PREFIX}yearly_${YEAR}_${TIME}" && ((created++))
        else
            increment_existing_counter yearly
            log "Snapshot Yearly vorhanden: $ds"
        fi
    fi

    return 0
}

# Ausdünn-Variante: erzeugt für ein Dataset je AKTIVEM Typ EINEN frischen Snapshot
# (sekundengenauer Zeitstempel -> eindeutiger Name, auch wenn für die Periode schon
# einer existiert). Zusammen mit dem anschließenden Pruning auf je 1 bleibt damit
# pro Typ genau dieser frische Anker (aktueller Stand) -> direkt nach dem Ausdünnen
# ~0 belegt, maximaler Platz-Reclaim. type_enabled spiegelt die fürs Ausdünnen
# temporär auf 1/0 gesetzte Retention -> nur Typen mit Retention > 0.
create_fresh_anchor_set() {
    local ds="$1"
    local DATE=$(date +%Y-%m-%d)
    local STAMP=$(date +%H-%M-%S)
    local WEEK=$(date +%G-W%V)
    local MONTH=$(date +%Y-%m)
    local YEAR=$(date +%Y)

    type_enabled hourly  && create_snapshot_by_type "$ds" hourly  "${SNAPSHOT_PREFIX}hourly_${DATE}_${STAMP}"
    type_enabled daily   && create_snapshot_by_type "$ds" daily   "${SNAPSHOT_PREFIX}daily_${DATE}_${STAMP}"
    type_enabled weekly  && create_snapshot_by_type "$ds" weekly  "${SNAPSHOT_PREFIX}weekly_${WEEK}_${STAMP}"
    type_enabled monthly && create_snapshot_by_type "$ds" monthly "${SNAPSHOT_PREFIX}monthly_${MONTH}_${STAMP}"
    type_enabled yearly  && create_snapshot_by_type "$ds" yearly  "${SNAPSHOT_PREFIX}yearly_${YEAR}_${STAMP}"
    return 0
}

list_snapshots_by_type() {
    local ds="$1"
    local type="$2"

    zfs_name_is_safe "$ds" || return

    while read -r snap; do
        case "$snap" in
            "${ds}@${SNAPSHOT_PREFIX}${type}_"*) echo "$snap" ;;
        esac
    done < <(zfs list -H -t snapshot -o name -s creation -r "$ds" 2>/dev/null)
}

# Bildet die aktiven Datasets über den Mapper auf ihre Zieldatasets ab und gibt
# sie zeilenweise aus. Mapper "cat"/"" = Quelle (Dataset selbst), sonst eine
# Funktion ds->Zieldataset (z. B. local_target_dataset).
get_mapped_datasets() {
    local mapper="${1:-cat}"
    local ds

    while read -r ds; do
        [ -n "$ds" ] || continue
        case "$mapper" in
            ""|cat) printf '%s\n' "$ds" ;;
            *)      "$mapper" "$ds" ;;
        esac
    done < <(get_datasets)
}

# awk-Programm zum Zählen verwalteter Snapshots je Dataset. Datei 1 = aktive
# (Ziel-)Datasets (Menge + Reihenfolge), Datei 2 = Snapshotnamen "<ds>@<snap>".
# Erwartet -v prefix=<SNAPSHOT_PREFIX>. Ausgabe je Dataset "ds h d w m y".
# Geteilt von der lokalen und der Remote-Zählung.
SNAPSHOT_COUNT_AWK='
    NR == FNR { order[++n] = $0; active[$0] = 1; next }
    {
        at = index($0, "@"); if (at == 0) next
        ds = substr($0, 1, at - 1)
        if (!(ds in active)) next
        rest = substr($0, at + 1)
        pl = length(prefix)
        if (substr(rest, 1, pl) != prefix) next
        t = substr(rest, pl + 1)
        if      (t ~ /^hourly_/)  h[ds]++
        else if (t ~ /^daily_/)   d[ds]++
        else if (t ~ /^weekly_/)  w[ds]++
        else if (t ~ /^monthly_/) m[ds]++
        else if (t ~ /^yearly_/)  y[ds]++
    }
    END {
        for (i = 1; i <= n; i++) {
            ds = order[i]
            printf "%s %d %d %d %d %d\n", ds, h[ds]+0, d[ds]+0, w[ds]+0, m[ds]+0, y[ds]+0
        }
    }
'

# Zählt die verwalteten Snapshots je (gemapptem) Dataset in EINEM einzigen
# `zfs list -t snapshot` über ALLE Pools – statt eines Aufrufs pro Dataset.
# Ausgabe je aktivem Dataset eine Zeile "dataset h d w m y" (auch 0-Zeilen).
# Belegte Größe (used, Bytes) je aktivem Dataset – ein Bulk-`zfs list` (kein
# Aufruf je Dataset). Ausgabe: name<TAB>used. Für die Snapshots-Seite (Spalte
# „Belegt"); am warmen Lauf-Ende erfasst, GUI liest nur den State.
active_dataset_sizes() {
    local -a active
    mapfile -t active < <(get_datasets)
    [ "${#active[@]}" -gt 0 ] || return 0
    zfs list -H -p -o name,used "${active[@]}" 2>/dev/null
}

managed_snapshot_counts() {
    local mapper="${1:-cat}"
    local -a targets

    # Datasetliste materialisieren. Bei „leer" früh raus – sonst würde awks
    # NR==FNR-Muster die Snapshotliste fälschlich als Datasetliste lesen.
    mapfile -t targets < <(get_mapped_datasets "$mapper")
    [ "${#targets[@]}" -gt 0 ] || return 0

    awk -v prefix="$SNAPSHOT_PREFIX" "$SNAPSHOT_COUNT_AWK" \
        <(printf '%s\n' "${targets[@]}") \
        <(zfs list -H -t snapshot -o name 2>/dev/null)
}

# Wie managed_snapshot_counts, aber die Snapshotliste kommt vom Remote – EIN
# einziger SSH-Aufruf (`zfs list -t snapshot -r` unter REMOTE_BASE_DATASET)
# statt fünf je Dataset. Die Zieldatasets sind remote_target_dataset(ds).
remote_managed_snapshot_counts() {
    local -a targets
    local q_base

    zfs_name_is_safe "$REMOTE_BASE_DATASET" || return 0
    mapfile -t targets < <(get_mapped_datasets remote_target_dataset)
    [ "${#targets[@]}" -gt 0 ] || return 0
    q_base=$(shell_quote "$REMOTE_BASE_DATASET")

    awk -v prefix="$SNAPSHOT_PREFIX" "$SNAPSHOT_COUNT_AWK" \
        <(printf '%s\n' "${targets[@]}") \
        <(remote_ssh "zfs list -H -t snapshot -o name -r ${q_base} 2>/dev/null" 2>/dev/null)
}

source_snapshot_inventory() {
    snapshot_inventory_for_active_datasets cat
}

snapshot_inventory_for_active_datasets() {
    local mapper="${1:-cat}"
    local h=0 d=0 w=0 m=0 y=0
    local ds ch cd cw cm cy

    # Ein einziger Bulk-Aufruf (ein zfs list) statt eines pro Dataset.
    while read -r ds ch cd cw cm cy; do
        h=$((h+ch)); d=$((d+cd)); w=$((w+cw)); m=$((m+cm)); y=$((y+cy))
    done < <(managed_snapshot_counts "$mapper")

    printf "%s %s %s %s %s %s\n" "$h" "$d" "$w" "$m" "$y" "$((h+d+w+m+y))"
}

prune_snapshots() {
    local ds="$1"
    local type="$2"
    local keep="$3"
    local label="${4:-Retention}"

    mapfile -t snaps < <(list_snapshots_by_type "$ds" "$type")

    local count=${#snaps[@]}
    [ "$count" -le "$keep" ] && return

    local remove=$((count-keep))

    for ((i=0;i<remove;i++)); do
        log "${label}: ${snaps[$i]}"
        if zfs destroy "${snaps[$i]}"; then
            ((DELETED_SNAPSHOTS++))
            log "${label} gelöscht: ${snaps[$i]}"
        else
            log "FEHLER: Snapshot konnte nicht gelöscht werden: ${snaps[$i]}"
            write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Retention fehlgeschlagen: ${snaps[$i]}"
            ((RUN_ERRORS++))
        fi
    done
}

destroy_local_managed_snapshots() {
    local ds="$1"
    local label="$2"
    local counter="${3:-source}"
    local snap

    zfs_name_is_safe "$ds" || return
    while read -r snap; do
        [ -n "$snap" ] || continue
        log "${label}: ${snap}"
        if zfs destroy "$snap"; then
            case "$counter" in
                local) ((LOCAL_DELETED_SNAPSHOTS++)) ;;
                *) ((DELETED_SNAPSHOTS++)) ;;
            esac
            log "${label} gelöscht: ${snap}"
        else
            log "FEHLER: ${label} konnte nicht gelöscht werden: ${snap}"
            write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') ${label} fehlgeschlagen: ${snap}"
            ((RUN_ERRORS++))
        fi
    done < <(list_backup_snapshots "$ds")
}

prune_source_pool_root_snapshots() {
    local root

    [ "$SNAPSHOT_POOL_ROOTS" = "yes" ] && return
    while read -r root; do
        [ -n "$root" ] || continue
        zfs list "$root" >/dev/null 2>&1 || continue
        console_status "Quelle-Pruning Pool-Root: $root"
        destroy_local_managed_snapshots "$root" "Pool-Root Quelle" source
    done < <(included_pool_roots)
}

prune_local_pool_root_snapshots() {
    local root
    local target

    [ "$SNAPSHOT_POOL_ROOTS" = "yes" ] && return
    while read -r root; do
        [ -n "$root" ] || continue
        target=$(local_target_dataset "$root")
        zfs list "$target" >/dev/null 2>&1 || continue
        [ -n "$(local_receive_resume_token "$target")" ] && continue
        console_status "Lokal-Zielabgleich Pool-Root: $target"
        destroy_local_managed_snapshots "$target" "Pool-Root Lokal-Zielabgleich" local
    done < <(included_pool_roots)
}

retention_keep_for_type() {
    case "$1" in
        hourly) echo "$KEEP_HOURLY" ;;
        daily) echo "$KEEP_DAILY" ;;
        weekly) echo "$KEEP_WEEKLY" ;;
        monthly) echo "$KEEP_MONTHLY" ;;
        yearly) echo "$KEEP_YEARLY" ;;
        *) echo 0 ;;
    esac
}

# Ein Snapshot-Typ ist aktiv, wenn seine Retention > 0 ist. KEEP_*=0 schaltet den
# Typ ab: es werden keine erzeugt; vorhandene entfernt das Pruning (keep 0).
type_enabled() {
    local keep
    keep=$(retention_keep_for_type "$1")
    [ "${keep:-0}" -gt 0 ] 2>/dev/null
}

prune_source_snapshot_types() {
    local ds="$1"
    local type

    for type in hourly daily weekly monthly yearly; do
        prune_snapshots "$ds" "$type" "$(retention_keep_for_type "$type")" "Quelle-Pruning"
    done
}

receive_resume_token_present_on_active_targets() {
    local ds="$1"
    local local_target
    local remote_target
    local target_id
    local type

    for target_id in "${TARGETS[@]}"; do
        target_enabled "$target_id" || continue
        load_target_context "$target_id" || continue
        type=$(target_type "$target_id")

        case "$type" in
            local)
                local_target=$(local_target_dataset "$ds")
                [ -n "$(local_receive_resume_token "$local_target")" ] && return 0
                ;;
            remote)
                ensure_remote_ready >/dev/null 2>&1 || continue
                remote_target=$(remote_target_dataset "$ds")
                [ -n "$(remote_receive_resume_token "$remote_target")" ] && return 0
                ;;
        esac
    done

    return 1
}

prune_source_snapshots() {
    local ds
    local index=0
    local total=0
    local -a datasets

    mapfile -t datasets < <(get_datasets)
    total=${#datasets[@]}

    prune_source_pool_root_snapshots
    # Aus dem Backup-Umfang gefallene Datasets (via INCLUDES-Verengung ODER
    # EXCLUDES) werden hier NICHT mehr automatisch gelöscht. Sie gelten – wie
    # verwaiste Ziel-Datasets – als „außer Betrieb": ein Lauf meldet sie nur
    # (report_source_orphan_datasets), gelöscht wird ausschließlich manuell über
    # die Wartung (maintenance_cleanup_orphans). Schutz vor stillem Datenverlust.

    for ds in "${datasets[@]}"; do
        [ -n "$ds" ] || continue
        ((index++))
        console_status "Quelle-Pruning [${index}/${total}]: $ds"

        if receive_resume_token_present_on_active_targets "$ds"; then
            log "Quelle-Pruning übersprungen, Resume-Token vorhanden: $ds"
            continue
        fi

        if local_replication_failed_for_dataset "$ds" || remote_replication_failed_for_dataset "$ds" || borg_replication_failed_for_dataset "$ds"; then
            log "Quelle-Pruning übersprungen, Replikationsfehler: $ds"
            continue
        fi

        prune_source_snapshot_types "$ds"
    done
}

prune_local_extra_snapshots() {
    local source_ds="$1"
    local target_ds="$2"
    local snap
    local name

    while read -r snap; do
        name="${snap#*@}"
        source_snapshot_name_exists "$source_ds" "$name" && continue

        log "Lokal-Zielabgleich zusätzlicher Snapshot: ${snap}"
        if zfs destroy "$snap"; then
            ((LOCAL_DELETED_SNAPSHOTS++))
            log "Lokal-Zielabgleich gelöscht: ${snap}"
        else
            log "FEHLER: Zusätzlicher lokaler Snapshot konnte nicht gelöscht werden: $snap"
            write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Lokal-Zielabgleich fehlgeschlagen: $snap"
            ((RUN_ERRORS++))
        fi
    done < <(list_backup_snapshots "$target_ds")
}

run_pruning() {
    local before_source="$DELETED_SNAPSHOTS"
    local before_local="$LOCAL_DELETED_SNAPSHOTS"
    local before_remote="$REMOTE_DELETED_SNAPSHOTS"
    local before_borg="$BORG_DELETED_ARCHIVES"
    local phase_source
    local phase_local
    local phase_remote
    local phase_borg
    local summary

    if [ "$ENABLE_SOURCE_PRUNING" = "yes" ]; then
        prune_source_snapshots
        phase_source=$((DELETED_SNAPSHOTS-before_source))
        console_success "Quelle-Pruning abgeschlossen: ${phase_source} gelöscht"
    else
        console_info "Quelle-Pruning deaktiviert"
    fi

    sync_targets_to_source_snapshots

    if [ "$(target_enabled_count local)" -gt 0 ]; then
        phase_local=$((LOCAL_DELETED_SNAPSHOTS-before_local))
        if [ "$phase_local" -gt 0 ]; then
            console_success "Lokal-Zielabgleich abgeschlossen: ${phase_local} gelöscht"
        else
            console_info "Lokal-Zielabgleich abgeschlossen: ${phase_local} gelöscht"
        fi
    fi

    if [ "$(target_enabled_count remote)" -gt 0 ]; then
        phase_remote=$((REMOTE_DELETED_SNAPSHOTS-before_remote))
        if [ "$phase_remote" -gt 0 ]; then
            console_success "Remote-Zielabgleich abgeschlossen: ${phase_remote} gelöscht"
        else
            console_info "Remote-Zielabgleich abgeschlossen: ${phase_remote} gelöscht"
        fi
    fi

    if [ "$(target_enabled_count borg)" -gt 0 ]; then
        phase_borg=$((BORG_DELETED_ARCHIVES-before_borg))
        if [ "$phase_borg" -gt 0 ]; then
            console_success "Borg-Zielabgleich abgeschlossen: ${phase_borg} Archiv(e) gelöscht"
        else
            console_info "Borg-Zielabgleich abgeschlossen: ${phase_borg} Archiv(e) gelöscht"
        fi
    fi

    summary="Pruning/Zielabgleich abgeschlossen: Quelle $((DELETED_SNAPSHOTS-before_source)) gelöscht"
    [ "$(target_enabled_count local)" -gt 0 ] && summary="${summary}, Lokal $((LOCAL_DELETED_SNAPSHOTS-before_local)) entfernt"
    [ "$(target_enabled_count remote)" -gt 0 ] && summary="${summary}, Remote $((REMOTE_DELETED_SNAPSHOTS-before_remote)) entfernt"
    [ "$(target_enabled_count borg)" -gt 0 ] && summary="${summary}, Borg $((BORG_DELETED_ARCHIVES-before_borg)) entfernt"
    console_success "$summary"
}

rotate_logs() {
    find "$LOG_DIR" -type f -name "*.log" -mtime +"$LOG_RETENTION_DAYS" -delete
}

MAINTENANCE_SNAPSHOTS_DELETED=0
MAINTENANCE_SNAPSHOT_ERRORS=0

list_managed_snapshots_recursive() {
    local dataset="$1"

    zfs_name_is_safe "$dataset" || return
    while read -r snap; do
        case "$snap" in
            *"@${SNAPSHOT_PREFIX}"*) echo "$snap" ;;
        esac
    done < <(zfs list -H -t snapshot -o name -s creation -r "$dataset" 2>/dev/null)
}

remote_list_managed_snapshots_recursive() {
    local dataset="$1"
    local q_dataset
    local q_prefix

    zfs_name_is_safe "$dataset" || return
    q_dataset=$(shell_quote "$dataset")
    q_prefix=$(shell_quote "$SNAPSHOT_PREFIX")
    remote_ssh \
        "zfs list -H -t snapshot -o name -s creation -r ${q_dataset} 2>/dev/null | awk -v prefix=${q_prefix} 'index(\$1, \"@\" prefix) > 0 { print \$1 }'" \
        2>/dev/null
}

maintenance_delete_local_snapshots_recursive() {
    local dataset="$1"
    local label="$2"
    local snap

    while read -r snap; do
        [ -n "$snap" ] || continue
        log "${label}: Snapshot wird gelöscht: $snap"
        if zfs destroy "$snap"; then
            ((MAINTENANCE_SNAPSHOTS_DELETED++))
            log "${label}: Snapshot gelöscht: $snap"
        else
            ((MAINTENANCE_SNAPSHOT_ERRORS++))
            log "FEHLER: ${label}: Snapshot konnte nicht gelöscht werden: $snap"
        fi
    done < <(list_managed_snapshots_recursive "$dataset")
}

maintenance_delete_remote_snapshots_recursive() {
    local dataset="$1"
    local label="$2"
    local snap

    while read -r snap; do
        [ -n "$snap" ] || continue
        log "${label}: Snapshot wird gelöscht: ${REMOTE_HOST}:${snap}"
        if remote_destroy_snapshot "$snap"; then
            ((MAINTENANCE_SNAPSHOTS_DELETED++))
            log "${label}: Snapshot gelöscht: ${REMOTE_HOST}:${snap}"
        else
            ((MAINTENANCE_SNAPSHOT_ERRORS++))
            log "FEHLER: ${label}: Snapshot konnte nicht gelöscht werden: ${REMOTE_HOST}:${snap}"
        fi
    done < <(remote_list_managed_snapshots_recursive "$dataset")
}

maintenance_delete_source_snapshots() {
    local root
    local index=0
    local total=0
    local -a roots

    mapfile -t roots < <(printf "%s\n" "${INCLUDES[@]}")
    total=${#roots[@]}

    for root in "${roots[@]}"; do
        [ -n "$root" ] || continue
        zfs list "$root" >/dev/null 2>&1 || continue
        ((index++))
        console_status "Snapshots löschen Quelle [${index}/${total}]: $root"
        maintenance_delete_local_snapshots_recursive "$root" "Maintenance Quelle"
    done
}

maintenance_delete_local_target_snapshots() {
    local target_id="$1"

    zfs list "$LOCAL_BACKUP_POOL" >/dev/null 2>&1 || return
    console_status "Snapshots löschen $(target_label "$target_id"): $LOCAL_BACKUP_POOL"
    maintenance_delete_local_snapshots_recursive "$LOCAL_BACKUP_POOL" "Maintenance Lokal"
}

maintenance_delete_remote_target_snapshots() {
    local target_id="$1"

    if ! ensure_remote_ready; then
        console_error "Remote Host nicht erreichbar: $REMOTE_HOST"
        ((MAINTENANCE_SNAPSHOT_ERRORS++))
        return
    fi

    remote_zfs_list "$REMOTE_BASE_DATASET" || return
    console_status "Snapshots löschen $(target_label "$target_id"): $REMOTE_BASE_DATASET"
    maintenance_delete_remote_snapshots_recursive "$REMOTE_BASE_DATASET" "Maintenance Remote"
}

# Prompt-freier Kern: löscht alle verwalteten Snapshots (Prefix) auf Quelle und
# aktiven Zielen. Destruktiv, aber ausschließlich Snapshots – keine Datasets,
# Verzeichnisse oder Dateien. Rückgabe 0 (ok) / 1 (mind. ein Fehler).
delete_all_managed_snapshots_apply() {
    local target_id
    local type

    MAINTENANCE_SNAPSHOTS_DELETED=0
    MAINTENANCE_SNAPSHOT_ERRORS=0

    invalidate_gui_cache   # ändert den Snapshot-Bestand -> GUI-Cache verwerfen

    log_phase "Maintenance: Snapshots löschen"
    maintenance_delete_source_snapshots

    for target_id in "${TARGETS[@]}"; do
        target_enabled "$target_id" || continue
        load_target_context "$target_id" || continue
        type=$(target_type "$target_id")
        case "$type" in
            local) maintenance_delete_local_target_snapshots "$target_id" ;;
            remote) maintenance_delete_remote_target_snapshots "$target_id" ;;
            borg) maintenance_delete_borg_target_archives "$target_id" ;;
        esac
    done

    console_clear_status
    write_gui_cache   # GUI-State neu schreiben (Remote ist wach -> live gezählt)
    if [ "$MAINTENANCE_SNAPSHOT_ERRORS" -eq 0 ]; then
        console_success "Snapshots gelöscht: ${MAINTENANCE_SNAPSHOTS_DELETED} gelöscht, 0 Fehler"
        return 0
    fi
    console_error "Snapshots löschen abgeschlossen: ${MAINTENANCE_SNAPSHOTS_DELETED} gelöscht, ${MAINTENANCE_SNAPSHOT_ERRORS} Fehler"
    return 1
}


# Prompt-freier Kern: dünnt die Snapshot-Historie aus – erzeugt je aktivem Typ
# (Retention > 0) EINEN frischen Anker (hourly/daily/weekly/monthly/yearly) mit
# aktuellem Stand, behält nur diese und gleicht aktive Ziele an. Rückgabe 0 (ok) /
# 1 (abgebrochen wegen Fehler).
thin_snapshot_history_apply() {
    local old_keep_hourly="$KEEP_HOURLY"
    local old_keep_daily="$KEEP_DAILY"
    local old_keep_weekly="$KEEP_WEEKLY"
    local old_keep_monthly="$KEEP_MONTHLY"
    local old_keep_yearly="$KEEP_YEARLY"
    local before_errors
    local before_remote_errors
    local before_borg_errors
    local before_run_errors
    local before_source="$DELETED_SNAPSHOTS"
    local before_local="$LOCAL_DELETED_SNAPSHOTS"
    local before_remote="$REMOTE_DELETED_SNAPSHOTS"

    invalidate_gui_cache   # ändert den Snapshot-Bestand -> GUI-Cache verwerfen

    log_phase "Snapshot-Historie ausdünnen"

    # Ausdünnen = je aktivem Typ (Retention > 0) EINEN frischen Anker erzeugen und
    # nur diesen behalten. Dafür die Retention temporär auf 1 (bzw. 0 für
    # deaktivierte Typen) setzen, den Snapshot-Job im "thin"-Modus laufen lassen
    # (create_fresh_anchor_set: je aktivem Typ ein frischer, sekundengenauer
    # Snapshot mit aktuellem Stand) und anschließend auf je 1 prunen. Ergebnis:
    # ein frischer Anker je aktivem Typ (inkl. tiefem yearly fürs Reaktivierungs-
    # Fenster) – direkt danach ~0 belegt, maximaler Platz-Reclaim. Originalwerte
    # werden nach dem Pruning wiederhergestellt.
    KEEP_HOURLY=$((  old_keep_hourly  > 0 ? 1 : 0 ))
    KEEP_DAILY=$((   old_keep_daily   > 0 ? 1 : 0 ))
    KEEP_WEEKLY=$((  old_keep_weekly  > 0 ? 1 : 0 ))
    KEEP_MONTHLY=$(( old_keep_monthly > 0 ? 1 : 0 ))
    KEEP_YEARLY=$((  old_keep_yearly  > 0 ? 1 : 0 ))

    before_run_errors="$RUN_ERRORS"
    log_phase "Snapshots"
    run_snapshot_job thin

    if [ "$RUN_ERRORS" -gt "$before_run_errors" ]; then
        console_error "Snapshot-Historie nicht ausgedünnt: Snapshots konnten nicht überall erstellt werden"
        log "FEHLER: Snapshot-Historie ausdünnen abgebrochen, Snapshot-Erstellung fehlgeschlagen"
        return 1
    fi

    before_errors="$REPLICATION_ERRORS"
    before_remote_errors="$REMOTE_REPLICATION_ERRORS"
    before_borg_errors="$BORG_REPLICATION_ERRORS"

    log_phase "Ziel-Replikation"
    run_target_replications

    if [ "$REPLICATION_ERRORS" -gt "$before_errors" ] || [ "$REMOTE_REPLICATION_ERRORS" -gt "$before_remote_errors" ] || [ "$BORG_REPLICATION_ERRORS" -gt "$before_borg_errors" ]; then
        console_error "Snapshot-Historie nicht ausgedünnt: mindestens ein aktives Ziel konnte nicht synchronisiert werden"
        log "FEHLER: Snapshot-Historie ausdünnen abgebrochen, Ziel-Replikation fehlgeschlagen"
        ((RUN_ERRORS++))
        return 1
    fi

    log_phase "Quelle-Pruning"
    prune_source_snapshots

    KEEP_HOURLY="$old_keep_hourly"
    KEEP_DAILY="$old_keep_daily"
    KEEP_WEEKLY="$old_keep_weekly"
    KEEP_MONTHLY="$old_keep_monthly"
    KEEP_YEARLY="$old_keep_yearly"

    log_phase "Zielabgleich"
    sync_targets_to_source_snapshots

    console_clear_status
    write_gui_cache   # GUI-State neu schreiben (Remote ist wach -> live gezählt)
    console_success "Snapshot-Historie ausgedünnt"
    console_info "Gelöscht/entfernt: Quelle $((DELETED_SNAPSHOTS-before_source)), Lokal $((LOCAL_DELETED_SNAPSHOTS-before_local)), Remote $((REMOTE_DELETED_SNAPSHOTS-before_remote))"
    return 0
}


show_snapshots() {
    local ds
    local h
    local d
    local w
    local m
    local y
    local total
    local count=0
    local total_h=0
    local total_d=0
    local total_w=0
    local total_m=0
    local total_y=0
    local total_all=0
    local local_active
    local remote_active
    local lh ld lw lm ly ltot

    local_active=$(target_enabled_count local)
    remote_active=$(target_enabled_count remote)

    console_phase "Snapshots"

    echo
    echo "Quelle (verwaltete Snapshots je Dataset)"
    printf "%-42s %7s %7s %7s %7s %7s %7s\n" "Dataset" "Hourly" "Daily" "Weekly" "Monthly" "Yearly" "Gesamt"
    printf "%-42s %7s %7s %7s %7s %7s %7s\n" "-------" "------" "-----" "------" "-------" "------" "------"

    while read -r ds h d w m y; do
        [ -n "$ds" ] || continue

        total=$((h+d+w+m+y))

        ((count++))
        total_h=$((total_h+h))
        total_d=$((total_d+d))
        total_w=$((total_w+w))
        total_m=$((total_m+m))
        total_y=$((total_y+y))
        total_all=$((total_all+total))

        printf "%-42s %7s %7s %7s %7s %7s %7s\n" "$ds" "$h" "$d" "$w" "$m" "$y" "$total"
    done < <(managed_snapshot_counts cat)

    printf "%-42s %7s %7s %7s %7s %7s %7s\n" "-------" "------" "-----" "------" "-------" "------" "------"
    printf "%-42s %7s %7s %7s %7s %7s %7s\n" "Gesamt" "$total_h" "$total_d" "$total_w" "$total_m" "$total_y" "$total_all"
    echo

    echo "Aktive Ziele (Summe über alle aktiven Ziele)"
    printf "%-42s %7s %7s %7s %7s %7s %7s\n" "Ziel" "Hourly" "Daily" "Weekly" "Monthly" "Yearly" "Gesamt"
    printf "%-42s %7s %7s %7s %7s %7s %7s\n" "-------" "------" "-----" "------" "-------" "------" "------"

    if [ "$local_active" -gt 0 ]; then
        read -r lh ld lw lm ly ltot < <(target_snapshot_inventory_for_type local)
        printf "%-42s %7s %7s %7s %7s %7s %7s\n" "Lokal (live)" "$lh" "$ld" "$lw" "$lm" "$ly" "$ltot"
    else
        printf "%-42s %7s\n" "Lokal" "kein aktives Ziel"
    fi

    if [ "$remote_active" -gt 0 ]; then
        printf "%-42s %7s %7s %7s %7s %7s %7s   (Stand letzter Lauf, kein Wake)\n" \
            "Remote" \
            "$(read_run_stat REMOTE_INVENTORY_HOURLY 0)" \
            "$(read_run_stat REMOTE_INVENTORY_DAILY 0)" \
            "$(read_run_stat REMOTE_INVENTORY_WEEKLY 0)" \
            "$(read_run_stat REMOTE_INVENTORY_MONTHLY 0)" \
            "$(read_run_stat REMOTE_INVENTORY_YEARLY 0)" \
            "$(read_run_stat REMOTE_INVENTORY_TOTAL 0)"
    else
        printf "%-42s %7s\n" "Remote" "kein aktives Ziel"
    fi
    echo

    console_success "Snapshots abgeschlossen: Quelle ${count} Dataset(s), ${total_all} verwaltete Snapshot(s)"
}

# Verwaltete Snapshots als JSON fürs GUI (--snapshots --json).
# Quelle + lokales Ziel werden live je Dataset gezählt (zfs). Das Remote-Ziel
# wird live gezählt, wenn der Host ohnehin schon wach ist ($REMOTE_READY, z. B.
# direkt nach einem Lauf/Ausdünnen/Löschen, wenn write_gui_cache den Cache
# schreibt) ODER wenn $1="yes" (force, „Live aktualisieren" – darf wecken).
# Sonst der letzte bekannte Stand aus dem State (kein Wecken nur fürs Anzeigen).
snapshots_json() {
    local force_remote="${1:-no}"
    local ds h d w m y total first=1 used
    local total_h=0 total_d=0 total_w=0 total_m=0 total_y=0 total_all=0 total_used=0
    local local_active remote_active
    local lh ld lw lm ly ltot
    local rh rd rw rm ry rtot
    local -A ds_used=()
    local _ds _u

    local_active=$(target_enabled_count local)
    remote_active=$(target_enabled_count remote)

    # Belegte Größe je aktivem Dataset (ein Bulk-`zfs list`, kein Aufruf je Dataset).
    while IFS=$'\t' read -r _ds _u; do
        [ -n "$_ds" ] && ds_used["$_ds"]="$_u"
    done < <(active_dataset_sizes)

    printf '{"source":{"datasets":['
    # Ein einziger Bulk-Aufruf (ein zfs list) liefert je Dataset die Zählung.
    while read -r ds h d w m y; do
        [ -n "$ds" ] || continue
        total=$((h+d+w+m+y))
        used="${ds_used[$ds]:-0}"
        total_h=$((total_h+h)); total_d=$((total_d+d)); total_w=$((total_w+w))
        total_m=$((total_m+m)); total_y=$((total_y+y)); total_all=$((total_all+total))
        total_used=$((total_used+used))
        if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
        printf '{"dataset":"%s","hourly":%s,"daily":%s,"weekly":%s,"monthly":%s,"yearly":%s,"total":%s,"used":%s}' \
            "$(json_escape "$ds")" "$(json_num "$h")" "$(json_num "$d")" "$(json_num "$w")" \
            "$(json_num "$m")" "$(json_num "$y")" "$(json_num "$total")" "$(json_num "$used")"
    done < <(managed_snapshot_counts cat)
    printf '],"totals":{"hourly":%s,"daily":%s,"weekly":%s,"monthly":%s,"yearly":%s,"total":%s,"used":%s}}' \
        "$(json_num "$total_h")" "$(json_num "$total_d")" "$(json_num "$total_w")" \
        "$(json_num "$total_m")" "$(json_num "$total_y")" "$(json_num "$total_all")" "$(json_num "$total_used")"

    printf ',"targets":{"local_active":%s,"remote_active":%s,' \
        "$(json_num "$local_active")" "$(json_num "$remote_active")"

    if [ "$local_active" -gt 0 ]; then
        read -r lh ld lw lm ly ltot < <(target_snapshot_inventory_for_type local)
        printf '"local":{"hourly":%s,"daily":%s,"weekly":%s,"monthly":%s,"yearly":%s,"total":%s},' \
            "$(json_num "$lh")" "$(json_num "$ld")" "$(json_num "$lw")" \
            "$(json_num "$lm")" "$(json_num "$ly")" "$(json_num "$ltot")"
    else
        printf '"local":null,'
    fi

    if [ "$remote_active" -gt 0 ]; then
        if [ "$force_remote" = "yes" ] || [ "${REMOTE_READY:-0}" -eq 1 ]; then
            # Live zählen: Host wach (Cache-Schreiben nach Aktion -> kein Wecken)
            # oder erzwungen („Live aktualisieren" -> darf wecken).
            read -r rh rd rw rm ry rtot < <(target_snapshot_inventory_for_type remote)
        else
            # Letzter bekannter Stand aus dem State (kein Wecken beim Anzeigen).
            rh=$(read_run_stat REMOTE_INVENTORY_HOURLY 0)
            rd=$(read_run_stat REMOTE_INVENTORY_DAILY 0)
            rw=$(read_run_stat REMOTE_INVENTORY_WEEKLY 0)
            rm=$(read_run_stat REMOTE_INVENTORY_MONTHLY 0)
            ry=$(read_run_stat REMOTE_INVENTORY_YEARLY 0)
            rtot=$(read_run_stat REMOTE_INVENTORY_TOTAL 0)
        fi
        printf '"remote":{"hourly":%s,"daily":%s,"weekly":%s,"monthly":%s,"yearly":%s,"total":%s}' \
            "$(json_num "$rh")" "$(json_num "$rd")" "$(json_num "$rw")" \
            "$(json_num "$rm")" "$(json_num "$ry")" "$(json_num "$rtot")"
    else
        printf '"remote":null'
    fi
    printf '}}\n'
}

# Cache-Datei für die Einzel-Snapshots EINES Scopes (Quelle oder ein Ziel).
# Scope "source"/leer -> Quelle; sonst die Ziel-ID. Eine Datei je Ziel, damit
# das Ausklappen je Scope getrennt aus dem State liest (kein Live-zfs/SSH).
snapshots_list_cache_file() {
    local scope="${1:-source}"
    case "$scope" in
        ""|source) printf '%s/snapshots_list_cache' "$STATE_DIR" ;;
        *)         printf '%s/snapshots_list_cache.tgt.%s' "$STATE_DIR" "$scope" ;;
    esac
}

# Verwaltete Snapshots EINES Datasets, neueste zuerst. Ausgabe je Zeile
# TAB-getrennt: vollerName  Kurzname  Typ  used(Bytes)  refer(Bytes)  creation.
# Liest NUR den am Lauf-Ende erfassten Cache – KEIN Live-`zfs`/SSH: Quell- wie
# Ziel-Datasets können auf HDD liegen und sollen nicht geweckt werden.
# $2 = Cache-Datei (Default: Quell-Cache).
managed_dataset_snapshots() {
    local ds="$1" name used refer creation snap
    local cache="${2:-${STATE_DIR}/snapshots_list_cache}"
    [ -f "$cache" ] || return 0
    # Cache-TSV: name  used  referenced  creation  (creation = Feld 4 -> Sort).
    while IFS=$'\t' read -r name used refer creation; do
        case "$name" in "${ds}@"*) ;; *) continue ;; esac
        snap="${name#*@}"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$snap" "$(snapshot_kind_from_name "$snap")" "$used" "$refer" "$creation"
    done < <(grep -F -- "${ds}@" "$cache" 2>/dev/null | sort -t"$(printf '\t')" -k4,4 -nr)
}

# Verwaltete Snapshots eines Datasets als JSON (für die GUI – Grundlage fürs
# spätere gezielte Wiederherstellen). Voller Name, Kurzname, Typ, Größe, Zeit.
# $2 = Scope ("source"/leer = Quelle, sonst Ziel-ID) -> passender Cache.
dataset_snapshots_json() {
    local ds="$1" scope="${2:-source}" name snap kind used refer creation first=1
    local cache
    cache=$(snapshots_list_cache_file "$scope")
    printf '{"dataset":"%s","scope":"%s","snapshots":[' \
        "$(json_escape "$ds")" "$(json_escape "$scope")"
    while IFS=$'\t' read -r name snap kind used refer creation; do
        [ "$first" -eq 1 ] && first=0 || printf ','
        # size = referenced (Restore-Größe), used = exklusiv belegt (Pruning).
        printf '{"name":"%s","snapshot":"%s","type":"%s","size":%s,"used":%s,"creation":%s,"created":"%s"}' \
            "$(json_escape "$name")" "$(json_escape "$snap")" "$(json_escape "$kind")" \
            "$(json_num "$refer")" "$(json_num "$used")" "$(json_num "$creation")" \
            "$(json_escape "$(format_epoch "$creation")")"
    done < <(managed_dataset_snapshots "$ds" "$cache")
    printf ']}\n'
}

# Menschenlesbare Textausgabe (CLI). Größe = referenced, Belegt = used.
# $2 = Scope ("source"/leer = Quelle, sonst Ziel-ID).
show_dataset_snapshots() {
    local ds="$1" scope="${2:-source}" name snap kind used refer creation cache
    cache=$(snapshots_list_cache_file "$scope")
    echo "Verwaltete Snapshots: $ds  (Scope: $scope, Größe = referenziert / Belegt = exklusiv)"
    echo
    while IFS=$'\t' read -r name snap kind used refer creation; do
        printf "  %-40s %-8s %9s / %9s  %s\n" \
            "$snap" "$kind" "$(format_bytes "$refer")" "$(format_bytes "$used")" \
            "$(format_epoch "$creation")"
    done < <(managed_dataset_snapshots "$ds" "$cache")
}

# --- Snapshot-Inhalt durchsuchen (Datei-Browser, Grundlage fürs Restore) ------
# ZFS-Snapshots sind read-only unter <mountpoint>/.zfs/snapshot/<snap>/ einseh-
# bar. Das Browsen liest tatsächlich ins Dataset (kein Cache) und WECKT ggf. die
# Platte/den Remote – bewusst, da explizite Nutzeraktion (Klick auf Snapshot).

# Relativen Pfad innerhalb eines Snapshots absichern: leer = Wurzel; sonst nicht
# absolut, keine ".."/"."/leeren Komponenten, keine Newlines/Tabs (zeilen-/feld-
# basierte Verarbeitung). Schützt zusammen mit dem realpath-Präfixcheck gegen
# Ausbruch aus dem Snapshot-Root (auch über Symlinks).
snapshot_rel_path_is_safe() {
    local rel="$1" comp
    [ -z "$rel" ] && return 0
    case "$rel" in
        /*) return 1 ;;
        *[$'\n\t']*) return 1 ;;
    esac
    local IFS='/'
    for comp in $rel; do
        case "$comp" in
            ''|.|..) return 1 ;;
        esac
    done
    return 0
}

# Lokaler Snapshot-Wurzelpfad (<mountpoint>/.zfs/snapshot/<snap>) eines Datasets.
# Mountpoint none/legacy/leer -> nicht browsebar.
local_snapshot_root() {
    local ds="$1" snap="$2" mp
    mp=$(zfs get -H -o value mountpoint "$ds" 2>/dev/null)
    case "$mp" in /*) ;; *) return 1 ;; esac
    printf '%s/.zfs/snapshot/%s' "$mp" "$snap"
}

# Scope (source|Ziel-ID) auf Zugriffsart + Wurzelpfad abbilden. Ausgabe
# "local<TAB>root" (Wurzelpfad lokal ermittelt) oder "remote<TAB>" (Pfad +
# Mount holt das Remote-Script selbst). Remote setzt den Ziel-Kontext +
# ensure_remote_ready (darf wecken – bewusste Nutzeraktion).
# Setzt die Globals BROWSE_MODE (local|remote) und BROWSE_ROOT (lokaler Pfad bzw.
# leer bei remote). WICHTIG: muss im AKTUELLEN Shell laufen (NICHT in $()), denn
# load_target_context setzt REMOTE_HOST/REMOTE_SSH_ARGS als Shell-Variablen –
# in einer Kommando-Substitutions-Subshell gingen die verloren und die
# folgenden remote_ssh-Aufrufe hätten einen leeren Host. Rückgabe 0/1.
resolve_snapshot_browse() {
    local ds="$1" snap="$2" scope="${3:-source}" type
    BROWSE_MODE=""
    BROWSE_ROOT=""
    zfs_name_is_safe "$ds" || return 1
    zfs_name_is_safe "$snap" || return 1
    case "$scope" in
        source)
            BROWSE_ROOT=$(local_snapshot_root "$ds" "$snap") || return 1
            BROWSE_MODE="local" ;;
        *)
            target_id_is_valid "$scope" || return 1
            load_target_context "$scope" || return 1
            type=$(target_type "$scope")
            case "$type" in
                local)
                    BROWSE_ROOT=$(local_snapshot_root "$ds" "$snap") || return 1
                    BROWSE_MODE="local" ;;
                remote)
                    # Schläft der Remote, wird er geweckt (Wake-on-LAN) – Browsen
                    # eines Backup-Ziels muss auch funktionieren, wenn der Host
                    # gerade schläft. Der Aufruf kann entsprechend dauern.
                    ensure_remote_ready >/dev/null 2>&1 || return 1
                    BROWSE_MODE="remote" ;;
                *) return 1 ;;
            esac ;;
    esac
    return 0
}

# Gemeinsame sh-Scripts für Quelle UND Remote (Remote = Unraid/Linux mit GNU
# find/realpath). Lokal via `sh -s` ausgeführt, remote via remote_snapshot_exec.
# $1 = Zielpfad, $2 = Snapshot-Wurzel; realpath-Präfixcheck schützt vor Ausbruch
# (auch über Symlinks – realpath löst sie auf, der Check fängt Ziele außerhalb).
#
# Verzeichnisebene auflisten, NUL-getrennt: typ<TAB>größe<TAB>mtime<TAB>name.
SNAPSHOT_LS_SCRIPT='dir=$1; root=$2
rootreal=$(realpath "$root" 2>/dev/null) || exit 1
tgt=$(realpath "$dir" 2>/dev/null) || exit 1
case "$tgt" in "$rootreal"|"$rootreal"/*) ;; *) exit 1 ;; esac
[ -d "$tgt" ] || exit 1
find "$tgt" -mindepth 1 -maxdepth 1 -printf "%y\t%s\t%T@\t%f\0" 2>/dev/null'

# EINE Datei aus einem Snapshot auf stdout (Download/Vorschau). $1 = Datei.
SNAPSHOT_CAT_SCRIPT='f=$1; root=$2
rootreal=$(realpath "$root" 2>/dev/null) || exit 1
rp=$(realpath "$f" 2>/dev/null) || exit 1
case "$rp" in "$rootreal"/*) ;; *) exit 1 ;; esac
[ -f "$rp" ] || exit 1
cat -- "$rp"'

# EINEN Eintrag (Datei ODER Ordner) aus einem Snapshot als tar-Stream auf stdout
# – für den Remote-Restore (überträgt rekursiv inkl. Attributen über SSH). $1 =
# Zielpfad, $2 = Snapshot-Wurzel; realpath-Präfixcheck wie bei Cat/Ls. Tar gibt
# den Eintrag unter SEINEM Basisnamen aus (Wurzel = übergeordnetes Verzeichnis).
SNAPSHOT_TAR_SCRIPT='t=$1; root=$2
rootreal=$(realpath "$root" 2>/dev/null) || exit 1
rp=$(realpath "$t" 2>/dev/null) || exit 1
case "$rp" in "$rootreal"|"$rootreal"/*) ;; *) exit 1 ;; esac
[ -e "$rp" ] || exit 1
d=$(dirname "$rp"); b=$(basename "$rp")
tar -C "$d" -cf - -- "$b"'

# Lokales Listing: gemeinsames Script via `sh -s` (Zielpfad + Snapshot-Wurzel).
local_snapshot_ls_raw() {
    local root="$1" rel="$2" target
    if [ -n "$rel" ]; then target="$root/$rel"; else target="$root"; fi
    printf '%s' "$SNAPSHOT_LS_SCRIPT" | sh -s -- "$target" "$root" 2>/dev/null
}

# Remote-Browsen: mountet das Ziel-Dataset bei Bedarf (Replikate sind oft per
# `receive -u` ungemountet -> dann gibt es `.zfs/snapshot` nicht), ermittelt den
# Snapshot-Wurzelpfad und führt das per STDIN übergebene sh-Script mit (Zielpfad
# Wurzel) aus; macht das Dataset danach WIEDER LOS – nur wenn ES gemountet hat.
# zfs-Befehle direkt per remote_ssh (PATH); das Script per STDIN an `sh -s`
# (keine Quoting-Verschachtelung). $1 ds, $2 snap, $3 rel.
remote_snapshot_exec() {
    local ds="$1" snap="$2" rel="$3" q_ds m mp did=0 root q_root q_target
    q_ds=$(shell_quote "$ds")
    m=$(remote_ssh "zfs get -H -o value mounted ${q_ds} 2>/dev/null" 2>/dev/null)
    [ "$m" = "no" ] && remote_ssh "zfs mount ${q_ds}" >/dev/null 2>&1 && did=1
    mp=$(remote_ssh "zfs get -H -o value mountpoint ${q_ds} 2>/dev/null" 2>/dev/null)
    case "$mp" in
        /*)
            root="${mp}/.zfs/snapshot/${snap}"
            q_root=$(shell_quote "$root")
            if [ -n "$rel" ]; then q_target=$(shell_quote "$root/$rel"); else q_target="$q_root"; fi
            remote_ssh_stream "sh -s -- ${q_target} ${q_root}" 2>/dev/null
            ;;
    esac
    [ "$did" -eq 1 ] && remote_ssh "zfs unmount ${q_ds}" >/dev/null 2>&1
}

# Remote-Listing: gemeinsames Script über remote_snapshot_exec. $1 ds, $2 snap, $3 rel.
remote_snapshot_ls_raw() {
    printf '%s' "$SNAPSHOT_LS_SCRIPT" | remote_snapshot_exec "$1" "$2" "$3"
}

# Listing-Dispatcher (lokal oder remote) – eigene Funktion statt inline-case in
# der Process Substitution (bash 3.2 stolpert sonst beim Parsen).
# $1 mode, $2 root(lokal), $3 ds, $4 snap, $5 rel.
snapshot_ls_raw() {
    case "$1" in
        local)  local_snapshot_ls_raw  "$2" "$5" ;;
        remote) remote_snapshot_ls_raw "$3" "$4" "$5" ;;
    esac
}

# Verzeichnisinhalt eines Snapshots als JSON. $1 ds, $2 snap, $3 scope, $4 rel.
snapshot_ls_json() {
    local ds="$1" snap="$2" scope="${3:-source}" rel="${4:-}"
    local mode root first=1 type size mtime name kind

    if ! snapshot_rel_path_is_safe "$rel"; then
        printf '{"error":"ungültiger Pfad","entries":[]}\n'; return 1
    fi
    resolve_snapshot_browse "$ds" "$snap" "$scope" || {
        printf '{"error":"Snapshot nicht erreichbar","entries":[]}\n'; return 1
    }
    mode="$BROWSE_MODE"; root="$BROWSE_ROOT"

    printf '{"dataset":"%s","snapshot":"%s","scope":"%s","path":"%s","entries":[' \
        "$(json_escape "$ds")" "$(json_escape "$snap")" \
        "$(json_escape "$scope")" "$(json_escape "$rel")"
    while IFS=$'\t' read -r -d '' type size mtime name; do
        [ -n "$type" ] || continue
        mtime=${mtime%.*}
        case "$type" in d) kind="dir" ;; f) kind="file" ;; l) kind="link" ;; *) kind="other" ;; esac
        [ "$first" -eq 1 ] && first=0 || printf ','
        printf '{"name":"%s","type":"%s","size":%s,"mtime":%s,"modified":"%s"}' \
            "$(json_escape "$name")" "$kind" "$(json_num "$size")" \
            "$(json_num "$mtime")" "$(json_escape "$(format_epoch "$mtime")")"
    done < <(snapshot_ls_raw "$mode" "$root" "$ds" "$snap" "$rel")
    printf ']}\n'
}

# Inhalt EINER Datei aus einem Snapshot auf stdout (für Download/Vorschau).
# Strikter realpath-Präfixcheck; nur reguläre Dateien.
snapshot_cat() {
    local ds="$1" snap="$2" scope="${3:-source}" rel="${4:-}"

    snapshot_rel_path_is_safe "$rel" || return 1
    [ -n "$rel" ] || return 1
    # NICHT in $() (sonst ginge der Ziel-Kontext/REMOTE_HOST in der Subshell verloren).
    resolve_snapshot_browse "$ds" "$snap" "$scope" || return 1

    # Gemeinsames Cat-Script: lokal via `sh -s`, remote via remote_snapshot_exec.
    case "$BROWSE_MODE" in
        local)  printf '%s' "$SNAPSHOT_CAT_SCRIPT" | sh -s -- "${BROWSE_ROOT}/${rel}" "$BROWSE_ROOT" 2>/dev/null ;;
        remote) printf '%s' "$SNAPSHOT_CAT_SCRIPT" | remote_snapshot_exec "$ds" "$snap" "$rel" ;;
    esac
}

# Größe eines Pfades in Bytes (apparent size, GNU du -sb). 0 bei Fehler.
du_bytes() {
    local n
    n=$(du -sb "$1" 2>/dev/null | cut -f1)
    case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}

# Best-effort-Gesamtgröße eines Remote-Restore-Eintrags in Bytes (für den
# Fortschrittsbalken). Ganzer Snapshot: referenced des Snapshots (billig, kein
# Mount). Unterpfad: 0 = unbestimmt (der Balken läuft dann ohne Prozent).
# $1 = Ziel-Dataset, $2 = Snapshot, $3 = Unterpfad.
remote_entry_size() {
    local q_ds q_snap n
    [ -n "$3" ] && { echo 0; return; }
    q_ds=$(shell_quote "$1"); q_snap=$(shell_quote "$2")
    n=$(remote_ssh "zfs get -Hp -o value referenced ${q_ds}@${q_snap} 2>/dev/null" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}

# Holt einen Remote-Snapshot-Eintrag als tar-Stream und entpackt ihn lokal nach
# <tmpd>. $1 ds, $2 snap, $3 rel, $4 tmpd. (Eigene Funktion, damit sie als ganze
# Pipeline im Hintergrund laufen kann – siehe restore_copy_progress.)
restore_remote_extract() {
    # Hier ist der SSH-/Remote-stdout der DATENstrom (tar) – das Remote-Script
    # schreibt ausschließlich `tar -cf -` auf stdout. tar validiert beim Entpacken
    # den Header, eine verunreinigte Pipe bricht also ab (mit pipefail erkennbar);
    # der Aufrufer prüft zusätzlich die Existenz des entpackten Eintrags. tar-stderr
    # NICHT mehr verwerfen, sondern loggen, damit ein Fehlschlag diagnostizierbar
    # ist (statt still in /dev/null zu verschwinden). log_stderr schreibt nur ins
    # Logfile, verschmutzt also keinen stdout.
    printf '%s' "$SNAPSHOT_TAR_SCRIPT" | remote_snapshot_exec "$1" "$2" "$3" \
        | tar -C "$4" -xf - 2> >(log_stderr "Restore-Extract")
}

# Führt das Kopier-Kommando <cmd…> im Hintergrund aus und meldet währenddessen
# einmal pro Sekunde den Füllstand von <watch> gegen <total> Bytes als Zeile
# "FORTSCHRITT <pct>" (für die GUI). total<=0 => unbestimmt: "FORTSCHRITT -1
# <bytes>" (nur die bisher kopierten Bytes). Rückgabe = Exit-Code des Kommandos.
# $1 total, $2 watch, ab $3 das Kommando (auch eine Funktion = Pipeline).
restore_copy_progress() {
    local total="$1" watch="$2"; shift 2
    local pid sz pct last="" rc
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sz=$(du_bytes "$watch")
        if [ "$total" -gt 0 ]; then
            pct=$(( sz * 100 / total )); [ "$pct" -gt 100 ] && pct=100
            [ "$pct" != "$last" ] && { printf 'FORTSCHRITT %s\n' "$pct"; last="$pct"; }
        else
            printf 'FORTSCHRITT -1 %s\n' "$sz"
        fi
        sleep 1
    done
    wait "$pid"; rc=$?
    [ "$total" -gt 0 ] && printf 'FORTSCHRITT 100\n'
    return "$rc"
}

# Gibt den fertigen Restore-Zielpfad aus: im Progress-Modus als "ZIEL <pfad>"
# (von der GUI geparst), sonst als blanker Pfad (CLI-Vertrag bleibt erhalten).
restore_emit_done() {
    if [ "${RESTORE_PROGRESS:-0}" = "1" ]; then printf 'ZIEL %s\n' "$1"; else printf '%s\n' "$1"; fi
}

# Prüft das QUELL-Dataset und bestimmt den nicht-destruktiven Zielpfad im
# Restore-Ordner <quell-mountpoint>/_restore/<snap>/<rel>. Der Restore – egal ob
# aus der Quelle oder einem Replikat – landet IMMER im _restore-Ordner des
# Quell-Datasets; das Dataset muss dafür existieren und gemountet sein. Setzt die
# Globals RESTORE_SRC_MP und RESTORE_DEST (mit Zeitstempel-Suffix bei Konflikt).
# $1 = Quell-Dataset, $2 = Snapshot, $3 = Unterpfad.
restore_prepare_dest() {
    local src_ds="$1" snap="$2" rel="$3" mp dest
    RESTORE_SRC_MP=""; RESTORE_DEST=""

    if ! zfs list -H -o name "$src_ds" >/dev/null 2>&1; then
        echo "FEHLER: Quell-Dataset existiert nicht (mehr): $src_ds" >&2
        echo "Hinweis: Lege das Dataset auf der Quelle erst wieder an – erst dann" >&2
        echo "         kann ein Eintrag dorthin zurückgespielt werden." >&2
        return 1
    fi
    mp=$(zfs get -H -o value mountpoint "$src_ds" 2>/dev/null)
    case "$mp" in /*) ;; *) echo "FEHLER: Quell-Dataset nicht gemountet: $src_ds" >&2; return 1 ;; esac

    # Leerer Unterpfad = GANZER Snapshot: Zielordner ist <mp>/_restore/<snap>
    # selbst. Sonst ein einzelner Eintrag darunter (<mp>/_restore/<snap>/<rel>).
    if [ -n "$rel" ]; then
        dest="$mp/_restore/$snap/$rel"
    else
        dest="$mp/_restore/$snap"
    fi
    mkdir -p "$(dirname "$dest")" || { echo "FEHLER: Restore-Ordner nicht anlegbar" >&2; return 1; }
    [ -e "$dest" ] && dest="${dest}.restored-$(date +%Y%m%d-%H%M%S)"
    RESTORE_SRC_MP="$mp"; RESTORE_DEST="$dest"
    return 0
}

# Kopiert einen lokalen Snapshot-Eintrag <src> (realpath-geprüft gegen <root>)
# nicht destruktiv nach <dest> (cp -a, rekursiv mit Attributen). $1 src, $2 root,
# $3 dest. realpath-Präfixcheck wie beim Browsen (kein Ausbruch, auch über Symlinks).
restore_copy_local_entry() {
    local src="$1" root="$2" dest="$3" rootreal rp
    rootreal=$(realpath "$root" 2>/dev/null) || { echo "FEHLER: Snapshot nicht zugänglich" >&2; return 1; }
    rp=$(realpath "$src" 2>/dev/null) || { echo "FEHLER: Eintrag im Snapshot nicht gefunden" >&2; return 1; }
    case "$rp" in "$rootreal"|"$rootreal"/*) ;; *) echo "FEHLER: Pfad außerhalb des Snapshots" >&2; return 1 ;; esac
    [ -e "$rp" ] || { echo "FEHLER: Eintrag existiert nicht" >&2; return 1; }
    if [ "${RESTORE_PROGRESS:-0}" = "1" ]; then
        restore_copy_progress "$(du_bytes "$rp")" "$dest" cp -a -- "$rp" "$dest"
    else
        cp -a -- "$rp" "$dest"
    fi
}

# Restauriert <rel> (Datei ODER Ordner, rekursiv mit Attributen) aus dem Snapshot
# <snap> in den Restore-Ordner des QUELL-Datasets (<quell-mp>/_restore/<snap>/).
# NICHT destruktiv: überschreibt nie – bei Namenskonflikt Zeitstempel-Suffix.
# <scope> bestimmt die Quelle des Snapshots:
#   source   – Snapshot auf dem Quell-Dataset selbst (Quelle ist beschreibbar).
#   <ziel-id> – Replikat: <ds> ist das ZIEL-Dataset; das Quell-Dataset wird aus
#               dem Ziel-Base abgeleitet. Lokal per cp, remote per tar-über-SSH
#               (weckt den Host ggf. via WOL). Vorher wird IMMER geprüft, dass das
#               Quell-Dataset existiert (sonst gibt es keinen _restore-Ort).
# Gibt bei Erfolg den Zielpfad auf stdout aus.
snapshot_restore() {
    local ds="$1" snap="$2" scope="${3:-source}" rel="$4" progress="${5:-}"
    local type base src_ds snaproot srcpath tmpd leaf
    # Progress-Modus (GUI): meldet "FORTSCHRITT <pct>" und gibt den Zielpfad als
    # "ZIEL <pfad>" aus. RESTORE_PROGRESS ist global (von Kopier-Helfern gelesen).
    [ "$progress" = "progress" ] && RESTORE_PROGRESS=1 || RESTORE_PROGRESS=0

    zfs_name_is_safe "$ds"   || { echo "FEHLER: ungültiges Dataset: $ds" >&2; return 1; }
    zfs_name_is_safe "$snap" || { echo "FEHLER: ungültiger Snapshot: $snap" >&2; return 1; }
    # Leerer Pfad ist erlaubt und bedeutet: ganzer Snapshot.
    snapshot_rel_path_is_safe "$rel" || { echo "FEHLER: ungültiger Pfad: $rel" >&2; return 1; }

    if [ "$scope" = "source" ]; then
        # Quelle: Snapshot liegt auf dem Dataset selbst.
        if ! zfs list -t snapshot -H -o name "${ds}@${snap}" >/dev/null 2>&1; then
            echo "FEHLER: Snapshot nicht auf der Quelle vorhanden: ${ds}@${snap}" >&2; return 1
        fi
        restore_prepare_dest "$ds" "$snap" "$rel" || return 1
        snaproot="$RESTORE_SRC_MP/.zfs/snapshot/$snap"
        # rel leer = ganzer Snapshot: Quelle ist die Snapshot-Wurzel selbst.
        if [ -n "$rel" ]; then srcpath="$snaproot/$rel"; else srcpath="$snaproot"; fi
        if restore_copy_local_entry "$srcpath" "$snaproot" "$RESTORE_DEST"; then
            log "Restore: ${ds}@${snap}/${rel:-（ganzer Snapshot）} -> ${RESTORE_DEST}"
            restore_emit_done "$RESTORE_DEST"; return 0
        fi
        echo "FEHLER: Kopieren fehlgeschlagen" >&2; return 1
    fi

    # Restore aus einem Ziel (Replikat): <ds> ist das ZIEL-Dataset, der _restore-
    # Ordner liegt aber im QUELL-Dataset (aus dem Ziel-Base abgeleitet).
    target_id_is_valid "$scope" || { echo "FEHLER: ungültiges Ziel: $scope" >&2; return 1; }
    load_target_context "$scope" || { echo "FEHLER: Ziel-Kontext nicht ladbar: $scope" >&2; return 1; }
    type=$(target_type "$scope")
    case "$type" in
        local)  base="$LOCAL_BACKUP_POOL" ;;
        remote) base="$REMOTE_BASE_DATASET" ;;
        borg)   base="" ;;   # borg hat keine Ziel-Datasets: <ds> IST das Quell-Dataset
        *) echo "FEHLER: unbekannter Zieltyp: $scope" >&2; return 1 ;;
    esac
    if [ "$type" = "borg" ]; then
        src_ds="$ds"
    else
        case "$ds" in
            "${base}/"*) src_ds="${ds#"${base}"/}" ;;
            *) echo "FEHLER: Ziel-Dataset gehört nicht zu diesem Ziel: $ds" >&2; return 1 ;;
        esac
    fi

    restore_prepare_dest "$src_ds" "$snap" "$rel" || return 1

    case "$type" in
        local)
            snaproot=$(local_snapshot_root "$ds" "$snap") \
                || { echo "FEHLER: Ziel-Snapshot nicht zugänglich: ${ds}@${snap}" >&2; return 1; }
            # rel leer = ganzer Snapshot: Quelle ist die Snapshot-Wurzel selbst.
            if [ -n "$rel" ]; then srcpath="$snaproot/$rel"; else srcpath="$snaproot"; fi
            if restore_copy_local_entry "$srcpath" "$snaproot" "$RESTORE_DEST"; then
                log "Restore (lokales Ziel ${scope}): ${ds}@${snap}/${rel:-（ganzer Snapshot）} -> ${RESTORE_DEST}"
                restore_emit_done "$RESTORE_DEST"; return 0
            fi
            echo "FEHLER: Kopieren fehlgeschlagen" >&2; return 1
            ;;
        remote)
            ensure_remote_ready >/dev/null 2>&1 \
                || { echo "FEHLER: Remote-Host nicht erreichbar: $REMOTE_HOST" >&2; return 1; }
            tmpd=$(mktemp -d "$(dirname "$RESTORE_DEST")/.zfsrestore.XXXXXX") \
                || { echo "FEHLER: temporäres Verzeichnis nicht anlegbar" >&2; return 1; }
            # Eintrag (oder ganzer Snapshot, wenn rel leer) als tar-Stream vom
            # Remote-Snapshot holen und lokal entpacken (remote_snapshot_exec
            # mountet das Ziel-Dataset bei Bedarf selbst). Der ausgepackte Name
            # ist der Basisname des Eintrags bzw. der Snapshot-Name bei rel leer.
            # Im Progress-Modus läuft das Entpacken im Hintergrund und der lokale
            # tmpd-Füllstand wird gegen die Remote-Größe gemeldet.
            if [ "${RESTORE_PROGRESS:-0}" = "1" ]; then
                restore_copy_progress "$(remote_entry_size "$ds" "$snap" "$rel")" "$tmpd" \
                    restore_remote_extract "$ds" "$snap" "$rel" "$tmpd"
            else
                restore_remote_extract "$ds" "$snap" "$rel" "$tmpd"
            fi
            if [ -n "$rel" ]; then leaf=$(basename "$rel"); else leaf="$snap"; fi
            if [ -e "$tmpd/$leaf" ] && mv "$tmpd/$leaf" "$RESTORE_DEST"; then
                rm -rf "$tmpd" 2>/dev/null
                log "Restore (Remote-Ziel ${scope}): ${REMOTE_HOST}:${ds}@${snap}/${rel:-（ganzer Snapshot）} -> ${RESTORE_DEST}"
                restore_emit_done "$RESTORE_DEST"; return 0
            fi
            rm -rf "$tmpd" 2>/dev/null
            echo "FEHLER: Remote-Restore fehlgeschlagen (Eintrag nicht übertragen)" >&2
            return 1
            ;;
        borg)
            if ! borg_ensure_binary || ! borg_run info >/dev/null 2>&1; then
                echo "FEHLER: Borg-Repo nicht erreichbar: $BORG_REPO" >&2; return 1
            fi
            local archive
            archive=$(borg_archive_name "$src_ds" "$snap")
            if ! borg_run list --short 2>/dev/null | grep -qxF "$archive"; then
                echo "FEHLER: Borg-Archiv nicht vorhanden: $archive" >&2; return 1
            fi
            tmpd=$(mktemp -d "$(dirname "$RESTORE_DEST")/.zfsrestore.XXXXXX") \
                || { echo "FEHLER: temporäres Verzeichnis nicht anlegbar" >&2; return 1; }
            # Archive tragen relative Pfade (cd <root> && borg create … .). rel leer =
            # ganzes Archiv, sonst nur den Unterpfad. Extraktion ins tmpd (cd).
            if [ -n "$rel" ]; then
                ( cd "$tmpd" && borg_run extract "::${archive}" "$rel" 2> >(log_stderr "Borg extract ${archive}") )
                if [ -e "$tmpd/$rel" ] && mv "$tmpd/$rel" "$RESTORE_DEST"; then
                    rm -rf "$tmpd" 2>/dev/null
                    log "Restore (Borg-Ziel ${scope}): ${BORG_REPO}::${archive}/${rel} -> ${RESTORE_DEST}"
                    restore_emit_done "$RESTORE_DEST"; return 0
                fi
            else
                ( cd "$tmpd" && borg_run extract "::${archive}" 2> >(log_stderr "Borg extract ${archive}") )
                # tmpd liegt neben RESTORE_DEST -> direkt umbenennen.
                if mv "$tmpd" "$RESTORE_DEST" 2>/dev/null; then
                    log "Restore (Borg-Ziel ${scope}): ${BORG_REPO}::${archive} (ganzes Archiv) -> ${RESTORE_DEST}"
                    restore_emit_done "$RESTORE_DEST"; return 0
                fi
            fi
            rm -rf "$tmpd" 2>/dev/null
            echo "FEHLER: Borg-Restore fehlgeschlagen (Eintrag nicht extrahiert)" >&2
            return 1
            ;;
    esac
}

# Schreibt den GUI-State (Datasets + komplette Snapshot-Sicht als JSON) in den
# State – die EINZIGE Quelle der Snapshots-Seite. Wird nach jeder Aktion erzeugt,
# die den Bestand ändert (Lauf, Ausdünnen, Löschen). Dabei ist die Quelle/das
# lokale Ziel ohnehin warm und der Remote (sofern aktiv) noch wach, sodass
# snapshots_json das Remote LIVE mitzählt (REMOTE_READY -> kein Wecken). Die GUI
# liest danach nur noch diese Datei – kein zfs/SSH und kein Wecken beim Anschauen.
# Schlägt eine Aktion vorher fehl, bleibt der State per invalidate_gui_cache
# verworfen (nächste Anzeige fällt auf live zurück).
# --- Kapazität (Pool-Auslastung) -------------------------------------------

# Pool-Name aus einem Dataset/Pfad (erster Bestandteil vor "/").
pool_of() { printf '%s' "${1%%/*}"; }

# Pool-Kapazität (size/alloc/free/capacity) als JSON-Objekt aus einer
# zpool-list-Zeile (TAB-getrennt, -p) bauen. Leere/ungültige Zeile -> Rückgabe 1.
pool_capacity_json_from_line() {
    local pool="$1" line="$2" size alloc free cap
    [ -n "$line" ] || return 1
    IFS=$'\t' read -r size alloc free cap <<< "$line"
    cap="${cap%\%}"
    printf '{"pool":"%s","size":%s,"alloc":%s,"free":%s,"cap":%s}' \
        "$(json_escape "$pool")" "$(json_num "$size")" "$(json_num "$alloc")" \
        "$(json_num "$free")" "$(json_num "$cap")"
}

local_pool_capacity_json() {
    local pool="$1"
    [ -n "$pool" ] || return 1
    pool_capacity_json_from_line "$pool" \
        "$(zpool list -H -p -o size,alloc,free,capacity "$pool" 2>/dev/null)"
}

# Remote-Pool-Kapazität – setzt einen erreichbaren Remote voraus (am Lauf-Ende
# ohnehin wach). KEIN Wecken/WOL: schläft der Remote, wird er übersprungen.
remote_pool_capacity_json() {
    local pool="$1" q
    [ -n "$pool" ] || return 1
    q=$(shell_quote "$pool")
    pool_capacity_json_from_line "$pool" \
        "$(remote_ssh "zpool list -H -p -o size,alloc,free,capacity ${q} 2>/dev/null" 2>/dev/null)"
}

# Kapazität der beteiligten Pools/Datasets als JSON. Wird am (warmen) Lauf-Ende
# erfasst und gecacht; die GUI liest nur den Cache und weckt keine Platte.
capacity_json() {
    local first ds pool tid used cap_json q_ds seen=" "
    local -a active

    printf '{'

    # Quelle: eindeutige Pools der aktiven Datasets.
    printf '"source":['
    mapfile -t active < <(get_datasets)
    first=1
    for ds in "${active[@]}"; do
        pool=$(pool_of "$ds")
        [ -n "$pool" ] || continue
        case "$seen" in *" $pool "*) continue ;; esac
        seen="${seen}${pool} "
        cap_json=$(local_pool_capacity_json "$pool") || continue
        [ "$first" -eq 1 ] && first=0 || printf ','
        printf '%s' "$cap_json"
    done
    printf '],'

    # Lokale Ziele.
    printf '"local":['
    first=1
    for tid in "${TARGETS[@]}"; do
        target_enabled "$tid" || continue
        [ "$(target_type "$tid")" = "local" ] || continue
        load_target_context "$tid" || continue
        cap_json=$(local_pool_capacity_json "$(pool_of "$LOCAL_BACKUP_POOL")") || continue
        used=$(zfs list -H -p -o used "$LOCAL_BACKUP_POOL" 2>/dev/null)
        [ "$first" -eq 1 ] && first=0 || printf ','
        printf '{"id":"%s","label":"%s","dataset":"%s","used":%s,"pool":%s}' \
            "$(json_escape "$tid")" "$(json_escape "$(target_label "$tid")")" \
            "$(json_escape "$LOCAL_BACKUP_POOL")" "$(json_num "$used")" "$cap_json"
    done
    printf '],'

    # Remote-Ziele (nur wenn erreichbar; kein Wecken).
    printf '"remote":['
    first=1
    for tid in "${TARGETS[@]}"; do
        target_enabled "$tid" || continue
        [ "$(target_type "$tid")" = "remote" ] || continue
        load_target_context "$tid" || continue
        cap_json=$(remote_pool_capacity_json "$(pool_of "$REMOTE_BASE_DATASET")") || continue
        q_ds=$(shell_quote "$REMOTE_BASE_DATASET")
        used=$(remote_ssh "zfs list -H -p -o used ${q_ds} 2>/dev/null" 2>/dev/null)
        [ "$first" -eq 1 ] && first=0 || printf ','
        printf '{"id":"%s","label":"%s","dataset":"%s","used":%s,"pool":%s}' \
            "$(json_escape "$tid")" "$(json_escape "$(target_label "$tid")")" \
            "$(json_escape "$REMOTE_BASE_DATASET")" "$(json_num "$used")" "$cap_json"
    done
    printf ']'

    # Borg-Ziele: deduplizierte Repo-Größe (belegt) – nur wenn das Repo in diesem
    # Lauf erreichbar war (kein Extra-borg-info fürs bloße GUI-Anzeigen). Kein
    # frei/total (Repo hat kein festes Limit).
    printf ',"borg":['
    first=1
    for tid in "${TARGETS[@]}"; do
        target_enabled "$tid" || continue
        [ "$(target_type "$tid")" = "borg" ] || continue
        load_target_context "$tid" || continue
        { [ "$BORG_READY" -eq 1 ] && [ "$BORG_READY_REPO" = "$BORG_REPO" ]; } || continue
        used=$(borg_repo_used_bytes) || continue
        [ -n "$used" ] || continue
        [ "$first" -eq 1 ] && first=0 || printf ','
        printf '{"id":"%s","label":"%s","repo":"%s","used":%s}' \
            "$(json_escape "$tid")" "$(json_escape "$(target_label "$tid")")" \
            "$(json_escape "$BORG_REPO")" "$(json_num "$used")"
    done
    printf ']'

    printf '}\n'
}

# Kapazität menschenlesbar (Standardausgabe der CLI). Rechnet live; die GUI liest
# den Cache über --capacity --json --cached (weckt keine Platte).
show_capacity() {
    local ds pool tid line size alloc free cap seen=" " bused
    local -a active
    echo "Kapazität (Pool-Auslastung)"
    echo

    mapfile -t active < <(get_datasets)
    for ds in "${active[@]}"; do
        pool=$(pool_of "$ds"); [ -n "$pool" ] || continue
        case "$seen" in *" $pool "*) continue ;; esac
        seen="${seen}${pool} "
        line=$(zpool list -H -p -o size,alloc,free,capacity "$pool" 2>/dev/null) || continue
        [ -n "$line" ] || continue
        IFS=$'\t' read -r size alloc free cap <<< "$line"; cap="${cap%\%}"
        printf "  Quelle  %-18s %s belegt / %s frei  (%s%% von %s)\n" \
            "$pool" "$(format_bytes "$alloc")" "$(format_bytes "$free")" "$cap" "$(format_bytes "$size")"
    done

    for tid in "${TARGETS[@]}"; do
        target_enabled "$tid" || continue
        case "$(target_type "$tid")" in
            local)
                load_target_context "$tid" || continue
                line=$(zpool list -H -p -o size,alloc,free,capacity "$(pool_of "$LOCAL_BACKUP_POOL")" 2>/dev/null) || continue
                ;;
            remote)
                load_target_context "$tid" || continue
                line=$(remote_ssh "zpool list -H -p -o size,alloc,free,capacity $(shell_quote "$(pool_of "$REMOTE_BASE_DATASET")") 2>/dev/null" 2>/dev/null) || continue
                ;;
            borg)
                # borg: deduplizierte Repo-Größe (belegt); kein frei/total.
                load_target_context "$tid" || continue
                borg_ensure_binary >/dev/null 2>&1 || continue
                bused=$(borg_repo_used_bytes)
                [ -n "$bused" ] || continue
                printf "  %-7s %-18s %s belegt (dedupliziert; Repo ohne festes Limit)\n" \
                    "borg" "$(target_label "$tid")" "$(format_bytes "$bused")"
                continue
                ;;
            *) continue ;;
        esac
        [ -n "$line" ] || continue
        IFS=$'\t' read -r size alloc free cap <<< "$line"; cap="${cap%\%}"
        printf "  %-7s %-18s %s belegt / %s frei  (%s%% von %s)\n" \
            "$(target_type "$tid")" "$(target_label "$tid")" \
            "$(format_bytes "$alloc")" "$(format_bytes "$free")" "$cap" "$(format_bytes "$size")"
    done
}

# Ein Dataset über einen Mapper abbilden ("cat"/leer = unverändert, sonst die
# Mapper-Funktion, z. B. local_target_dataset / remote_target_dataset).
map_dataset() {
    case "$1" in
        ""|cat) printf '%s' "$2" ;;
        *)      "$1" "$2" ;;
    esac
}

# Roh-Snapshotzeilen (name<TAB>used<TAB>refer<TAB>creation) von stdin auf die
# VERWALTETEN Snapshots der aktiven (gemappten) Datasets filtern. $1 = Mapper.
# Schreibt die gefilterten Zeilen unverändert nach stdout.
filter_managed_snapshot_lines() {
    local mapper="${1:-cat}" name used refer creation ds snap a
    local -A active_set=()
    while read -r a; do
        [ -n "$a" ] && active_set["$(map_dataset "$mapper" "$a")"]=1
    done < <(get_datasets)
    while IFS=$'\t' read -r name used refer creation; do
        [ -n "$name" ] || continue
        ds="${name%@*}"; snap="${name#*@}"
        [ -n "${active_set[$ds]:-}" ] || continue
        case "$snap" in "${SNAPSHOT_PREFIX}"*) ;; *) continue ;; esac
        printf '%s\t%s\t%s\t%s\n' "$name" "$used" "$refer" "$creation"
    done
}

# Liste ALLER verwalteten Snapshots (name used refer creation, TAB-getrennt) der
# aktiven Datasets je Scope (Quelle + jedes aktive Ziel) in den State schreiben –
# je ein `zfs list -t snapshot` bzw. EIN SSH-Aufruf am warmen Lauf-Ende. Quelle
# für die aufklappbaren Einzel-Snapshots; die GUI liest danach nur diese Caches
# (kein Live-zfs/SSH -> weckt keine HDD/keinen schlafenden Remote).
# used = exklusiv belegt (oft 0, da geteilt); referenced = referenzierte
# Datenmenge (Restore-Größe, immer aussagekräftig). Beide erfassen.
write_snapshots_list_cache() {
    local force_remote="${1:-no}"
    local tid type

    # Quelle: ein zfs list über alle Pools.
    zfs list -H -p -o name,used,referenced,creation -t snapshot 2>/dev/null \
        | filter_managed_snapshot_lines cat > "${STATE_DIR}/snapshots_list_cache"

    # Je aktivem Ziel ein eigener Cache. Lokal: zfs list -r BASE. Remote: nur
    # wenn der Host ohnehin wach ist (REMOTE_READY) – sonst bleibt der alte Cache
    # unangetastet (kein Wecken nur fürs Anzeigen).
    for tid in "${TARGETS[@]}"; do
        target_enabled "$tid" || continue
        load_target_context "$tid" || continue
        type=$(target_type "$tid")
        case "$type" in
            local)
                zfs_name_is_safe "$LOCAL_BACKUP_POOL" || continue
                zfs list -H -p -o name,used,referenced,creation -t snapshot \
                    -r "$LOCAL_BACKUP_POOL" 2>/dev/null \
                    | filter_managed_snapshot_lines local_target_dataset \
                    > "$(snapshots_list_cache_file "$tid")"
                ;;
            remote)
                zfs_name_is_safe "$REMOTE_BASE_DATASET" || continue
                # force=yes („Live aktualisieren") darf wecken; sonst nur, wenn
                # der Host ohnehin wach ist (REMOTE_READY) – kein Wecken fürs
                # Anzeigen, der alte Cache bleibt dann unangetastet.
                if [ "$force_remote" = "yes" ]; then
                    ensure_remote_ready >/dev/null 2>&1 || continue
                else
                    [ "${REMOTE_READY:-0}" -eq 1 ] || continue
                    [ "$REMOTE_READY_HOST" = "$(remote_host_address)" ] || continue
                fi
                remote_ssh "zfs list -H -p -o name,used,referenced,creation -t snapshot -r $(shell_quote "$REMOTE_BASE_DATASET") 2>/dev/null" 2>/dev/null \
                    | filter_managed_snapshot_lines remote_target_dataset \
                    > "$(snapshots_list_cache_file "$tid")"
                ;;
            borg)
                # borg-Archive als „Snapshots" cachen – nur bei Live-Refresh (force)
                # oder wenn das Repo in diesem Lauf schon erreichbar war (BORG_READY);
                # sonst bleibt der alte Cache (kein Netzzugriff fürs Anzeigen, analog
                # remote). <ds%>__<snap> wird zu <ds>@<snap> demangled (% -> /);
                # Trenner ist „__<SNAPSHOT_PREFIX>" (eindeutig). used/refer/creation
                # sind bei borg unbekannt -> 0.
                if [ "$force_remote" = "yes" ]; then
                    borg_ensure_binary >/dev/null 2>&1 || continue
                    borg_run info >/dev/null 2>&1 || continue
                    # Live-„Aktualisieren": fehlende Größen nachziehen, bevor der
                    # Cache gebaut wird (begrenzt; füllt sich über Klicks/Läufe).
                    borg_load_existing_archives
                    borg_backfill_sizes 50
                else
                    { [ "$BORG_READY" -eq 1 ] && [ "$BORG_READY_REPO" = "$BORG_REPO" ]; } || continue
                fi
                # {time:%s} = Erstellzeit als Unix-Epoch (Python-strftime via borg
                # --format; numerisch geprüft, sonst 0). Eigene Archive <ds%>__<snap>
                # -> <ds>@<snap>; FREMDE Archive (anderes Schema, z. B. bestehende
                # Backups im selben Repo) -> Pseudo-Dataset „(andere)". Eine Größe je
                # Archiv liefert borg list nicht (nur borg info) -> used/refer = 0.
                # Größen aus dem persistenten Größen-Cache nachschlagen (used=dedup,
                # referenced=original). FILENAME-Vergleich statt NR==FNR (robust auch
                # bei leerem Größen-Cache). Größen-Cache nie leeren – nur anlegen.
                local _szc
                _szc=$(borg_size_cache_file "$tid")
                [ -f "$_szc" ] || { : > "$_szc" 2>/dev/null || _szc=/dev/null; }
                awk -F'\t' -v sep="__${SNAPSHOT_PREFIX}" -v szc="$_szc" '
                        FILENAME==szc { if(NF>=3){ o[$1]=$2; d[$1]=$3 } next }
                        {
                            arch=$1; ts=$2
                            if (ts !~ /^[0-9]+$/) ts=0
                            orig=(arch in o)?o[arch]:0; dedup=(arch in d)?d[arch]:0
                            i=index(arch,sep)
                            if (i==0) { printf "(andere)@%s\t%d\t%d\t%d\n", arch, dedup, orig, ts; next }
                            dsm=substr(arch,1,i-1); snap=substr(arch,i+2)
                            gsub(/%/,"/",dsm)
                            printf "%s@%s\t%d\t%d\t%d\n", dsm, snap, dedup, orig, ts
                        }
                    ' "$_szc" <(borg_run list --format '{archive}{TAB}{time:%s}{NL}' 2>/dev/null) \
                    > "$(snapshots_list_cache_file "$tid")"
                ;;
        esac
    done
}

# Je Dataset aus einem Snapshot-Cache zählen + Größen summieren. Ausgabe je
# Dataset TAB-getrennt: ds h d w m y total used_sum refer_sum (erste Sichtung).
snapshot_cache_summary() {
    local cache="$1"
    [ -f "$cache" ] || return 0
    awk -v prefix="$SNAPSHOT_PREFIX" -F'\t' '
        {
            name=$1; used=$2+0; refer=$3+0
            at=index(name,"@"); if(at==0) next
            ds=substr(name,1,at-1); rest=substr(name,at+1)
            pl=length(prefix); if(substr(rest,1,pl)!=prefix) next
            t=substr(rest,pl+1)
            if(!(ds in seen)){ order[++n]=ds; seen[ds]=1 }
            if      (t ~ /^hourly_/)  h[ds]++
            else if (t ~ /^daily_/)   d[ds]++
            else if (t ~ /^weekly_/)  w[ds]++
            else if (t ~ /^monthly_/) m[ds]++
            else if (t ~ /^yearly_/)  y[ds]++
            u[ds]+=used; r[ds]+=refer
        }
        END{
            for(i=1;i<=n;i++){ ds=order[i]
                printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", ds,
                    h[ds]+0,d[ds]+0,w[ds]+0,m[ds]+0,y[ds]+0,
                    h[ds]+d[ds]+w[ds]+m[ds]+y[ds]+0, u[ds]+0, r[ds]+0 }
        }
    ' "$cache" 2>/dev/null
}

# Einen Scope (Quelle oder Ziel) als JSON-Objekt ausgeben: Kopf + Dataset-Liste
# (je aktivem, gemapptem Dataset – auch 0-Zeilen) + Summen. Alles aus dem Cache;
# kein Live-zfs/SSH. $1 id, $2 label, $3 kind, $4 cache, $5 mapper.
scope_json() {
    local id="$1" label="$2" kind="$3" cache="$4" mapper="$5"
    local ds tds dh dd dw dm dy dt du _refer first=1
    local th=0 td=0 tw=0 tm=0 ty=0 tt=0 tu=0
    local -A H=() D=() W=() M=() Y=() T=() U=()

    # snapshot_cache_summary liefert je Dataset 9 Felder; refer_sum (Feld 9) wird
    # bewusst NICHT aggregiert (referenced-Summe überzählt geteilte Daten).
    while IFS=$'\t' read -r tds dh dd dw dm dy dt du _refer; do
        [ -n "$tds" ] || continue
        H[$tds]=$dh; D[$tds]=$dd; W[$tds]=$dw; M[$tds]=$dm; Y[$tds]=$dy
        T[$tds]=$dt; U[$tds]=$du
    done < <(snapshot_cache_summary "$cache")

    printf '{"id":"%s","label":"%s","kind":"%s","datasets":[' \
        "$(json_escape "$id")" "$(json_escape "$label")" "$(json_escape "$kind")"

    while read -r ds; do
        [ -n "$ds" ] || continue
        tds=$(map_dataset "$mapper" "$ds")
        dh=${H[$tds]:-0}; dd=${D[$tds]:-0}; dw=${W[$tds]:-0}
        dm=${M[$tds]:-0}; dy=${Y[$tds]:-0}; dt=${T[$tds]:-0}
        du=${U[$tds]:-0}
        th=$((th+dh)); td=$((td+dd)); tw=$((tw+dw)); tm=$((tm+dm)); ty=$((ty+dy))
        tt=$((tt+dt)); tu=$((tu+du))
        [ "$first" -eq 1 ] && first=0 || printf ','
        # "used" = Summe des exklusiv belegten Platzes der Snapshots (aussage-
        # kräftig). KEIN referenced-Summe – das überzählt (Snapshots teilen Daten).
        printf '{"dataset":"%s","source":"%s","hourly":%s,"daily":%s,"weekly":%s,"monthly":%s,"yearly":%s,"total":%s,"used":%s}' \
            "$(json_escape "$tds")" "$(json_escape "$ds")" \
            "$(json_num "$dh")" "$(json_num "$dd")" "$(json_num "$dw")" \
            "$(json_num "$dm")" "$(json_num "$dy")" "$(json_num "$dt")" \
            "$(json_num "$du")"
    done < <(get_datasets)

    # borg: fremde Archive (nicht von uns erstellt) als Pseudo-Dataset „(andere)"
    # anhängen – damit sichtbar, später im Browser durchsuchbar/löschbar. Zählung
    # separat (kein Typ-Split); Größe unbekannt.
    if [ "$kind" = "borg" ]; then
        local other_n
        other_n=$(grep -c -F -- "(andere)@" "$cache" 2>/dev/null) || other_n=0
        if [ "${other_n:-0}" -gt 0 ]; then
            tt=$((tt+other_n))
            [ "$first" -eq 1 ] && first=0 || printf ','
            printf '{"dataset":"%s","source":"%s","hourly":0,"daily":0,"weekly":0,"monthly":0,"yearly":0,"total":%s,"used":0}' \
                "$(json_escape "(andere)")" "$(json_escape "(andere)")" "$(json_num "$other_n")"
        fi
    fi

    printf '],"totals":{"hourly":%s,"daily":%s,"weekly":%s,"monthly":%s,"yearly":%s,"total":%s,"used":%s}}' \
        "$(json_num "$th")" "$(json_num "$td")" "$(json_num "$tw")" \
        "$(json_num "$tm")" "$(json_num "$ty")" "$(json_num "$tt")" \
        "$(json_num "$tu")"
}

# Komplette Scope-Übersicht (Quelle + jedes aktive Ziel) als JSON fürs GUI
# (--snapshot-tree). Vollständig aus den Caches; die GUI rendert daraus die
# aufklappbaren Scopes und lädt Einzel-Snapshots erst beim Klick nach.
snapshot_tree_json() {
    local tid type mapper first=1
    printf '{"scopes":['
    scope_json "source" "Quelle" "source" \
        "$(snapshots_list_cache_file source)" cat
    for tid in "${TARGETS[@]}"; do
        target_enabled "$tid" || continue
        type=$(target_type "$tid")
        case "$type" in
            local)  mapper=local_target_dataset ;;
            remote) mapper=remote_target_dataset ;;
            borg)   mapper="cat" ;;   # Archive sind nach Quell-Dataset benannt (1:1)
            *)      continue ;;
        esac
        # Kontext setzen (LOCAL_BACKUP_POOL/REMOTE_BASE_DATASET) – der Mapper
        # braucht ihn, um Quell- auf Ziel-Datasets abzubilden. Kein SSH/Wecken.
        load_target_context "$tid" || continue
        printf ','
        scope_json "$tid" "$(target_label "$tid")" "$type" \
            "$(snapshots_list_cache_file "$tid")" "$mapper"
    done
    printf ']}\n'
}

write_gui_cache() {
    datasets_json  > "${STATE_DIR}/datasets_cache.json"  2>/dev/null
    snapshots_json > "${STATE_DIR}/snapshots_cache.json" 2>/dev/null
    capacity_json  > "${STATE_DIR}/capacity_cache.json"  2>/dev/null
    write_snapshots_list_cache 2>/dev/null
    # Scope-Baum NACH den Snapshot-Caches (er liest sie aus).
    snapshot_tree_json > "${STATE_DIR}/snapshot_tree_cache.json" 2>/dev/null
}

invalidate_gui_cache() {
    rm -f "${STATE_DIR}/datasets_cache.json" "${STATE_DIR}/snapshots_cache.json" \
          "${STATE_DIR}/capacity_cache.json" "${STATE_DIR}/snapshots_list_cache" \
          "${STATE_DIR}/snapshot_tree_cache.json" \
          "${STATE_DIR}"/snapshots_list_cache.tgt.* 2>/dev/null
}

simulate_snapshot_action() {
    local ds="$1"
    local type="$2"
    local due="$3"
    local pattern="$4"
    local snap="$5"

    printf "  %-7s: " "$type"

    if [ "$due" != "yes" ]; then
        echo "nicht fällig"
        return
    fi

    if snapshot_exists "$ds" "$pattern"; then
        echo "bereits vorhanden (${pattern}*)"
    else
        echo "würde erstellt: ${ds}@${snap}"
    fi
}

simulate_retention() {
    local ds="$1"
    local type="$2"
    local keep="$3"
    local count
    local remove
    local i

    mapfile -t snaps < <(list_snapshots_by_type "$ds" "$type")

    count=${#snaps[@]}
    [ "$count" -le "$keep" ] && {
        printf "  %-7s: keine Löschung (%s/%s)\n" "$type" "$count" "$keep"
        return
    }

    remove=$((count-keep))
    printf "  %-7s: %s Löschung(en)\n" "$type" "$remove"

    for ((i=0;i<remove;i++)); do
        echo "           würde löschen: ${snaps[$i]}"
    done
}

# Set (|name|name|) der verwalteten Quell-Snapshotnamen, die NACH dem (simulierten)
# Quell-Pruning übrig blieben. Grundlage für den pruning-bewussten Zielabgleich:
# der echte Lauf prunt erst die Quelle und gleicht DANN die Ziele daran an, also
# bezieht sich „würde entfernt" auf diesen Stand. Ist das Quell-Pruning aus, bleibt
# der komplette aktuelle Bestand. Pro Typ die ältesten (count-keep) weglassen
# (keep=0 => Typ ganz weg), exakt wie prune_source_snapshot_types/simulate_retention.
sim_source_kept_set() {
    local ds="$1" spec type keep count remove i name
    local -a snaps
    local set="|"
    for spec in "hourly:${KEEP_HOURLY:-0}" "daily:${KEEP_DAILY:-0}" "weekly:${KEEP_WEEKLY:-0}" "monthly:${KEEP_MONTHLY:-0}" "yearly:${KEEP_YEARLY:-0}"; do
        type="${spec%%:*}"; keep="${spec##*:}"
        mapfile -t snaps < <(list_snapshots_by_type "$ds" "$type")
        count=${#snaps[@]}
        if [ "$ENABLE_SOURCE_PRUNING" = "yes" ] && [ "$count" -gt "$keep" ]; then
            remove=$((count-keep))
        else
            remove=0
        fi
        for ((i=0;i<count;i++)); do
            [ "$i" -lt "$remove" ] && continue   # die ältesten 'remove' würden geprunt
            name="${snaps[$i]#*@}"
            set="${set}${name}|"
        done
    done
    printf '%s' "$set"
}

# Zählt, wie viele verwaltete Quell-Snapshots NACH dem gemeinsamen Snapshot kommen
# (= würden inkrementell übertragen). Liest "ds@name"-Zeilen (nach creation
# sortiert) von stdin; $1 = gemeinsamer Snapshotname.
sim_count_after_common() {
    local common="$1" line name seen=0 n=0
    while read -r line; do
        [ -n "$line" ] || continue
        name="${line#*@}"
        [ "$seen" -eq 1 ] && n=$((n+1))
        [ "$name" = "$common" ] && seen=1
    done
    printf '%s' "$n"
}

# Kompakte Dry-Run-Zeilen für ein lokales Ziel (Kontext geladen). Replikations-
# Aktion + Anzahl zusätzlicher Ziel-Snapshots, die der Zielabgleich entfernen
# würde – ohne Snapshot-Namen (übersichtlich).
sim_target_local() {
    local ds="$1" kept="$2" target latest common extra=0 snap name repl
    target=$(local_target_dataset "$ds")
    latest=$(latest_backup_snapshot_name "$ds")
    if [ -z "$latest" ]; then
        repl="kein Quell-Snapshot"
    elif [ -n "$(local_receive_resume_token "$target")" ]; then
        repl="Resume offen (wird fortgesetzt)"
    elif ! zfs list "$target" >/dev/null 2>&1; then
        repl="Full-Aufbau (Ziel fehlt)"
    elif zfs list -t snapshot "${target}@${latest}" >/dev/null 2>&1; then
        repl="aktuell"
    else
        common=$(latest_common_snapshot_name "$ds" "$target")
        if [ -z "$common" ]; then
            repl="Full-Aufbau (kein gemeinsamer Snapshot)"
        else
            repl="inkrementell: $(list_backup_snapshots "$ds" | sim_count_after_common "$common") Snapshot(s)"
        fi
    fi
    if zfs list "$target" >/dev/null 2>&1; then
        while read -r snap; do
            [ -n "$snap" ] || continue
            name="${snap#*@}"
            case "$kept" in *"|${name}|"*) ;; *) extra=$((extra+1)) ;; esac
        done < <(list_backup_snapshots "$target")
    fi
    printf '  Replikation:  %s\n' "$repl"
    printf '  Zielabgleich: %s Ziel-Snapshot(s) würden entfernt (inkl. Pruning-Folge)\n' "$extra"
}

# Kompakte Dry-Run-Zeilen für ein Remote-Ziel (Kontext geladen, Host bereit).
sim_target_remote() {
    local ds="$1" kept="$2" target latest common extra=0 snap name repl
    target=$(remote_target_dataset "$ds")
    latest=$(latest_backup_snapshot_name "$ds")
    if [ -z "$latest" ]; then
        repl="kein Quell-Snapshot"
    elif [ -n "$(remote_receive_resume_token "$target")" ]; then
        repl="Resume offen (wird fortgesetzt)"
    elif ! remote_zfs_list "$target" >/dev/null 2>&1; then
        repl="Full-Aufbau (Ziel fehlt)"
    elif remote_snapshot_exists "${target}@${latest}"; then
        repl="aktuell"
    else
        common=$(latest_common_remote_snapshot_name "$ds" "$target")
        if [ -z "$common" ]; then
            repl="Full-Aufbau (kein gemeinsamer Snapshot)"
        else
            repl="inkrementell: $(list_backup_snapshots "$ds" | sim_count_after_common "$common") Snapshot(s)"
        fi
    fi
    while read -r snap; do
        [ -n "$snap" ] || continue
        name="${snap#*@}"
        case "$kept" in *"|${name}|"*) ;; *) extra=$((extra+1)) ;; esac
    done < <(remote_list_backup_snapshots "$target")
    printf '  Replikation:  %s\n' "$repl"
    printf '  Zielabgleich: %s Remote-Snapshot(s) würden entfernt (inkl. Pruning-Folge)\n' "$extra"
}

# Kompakte Dry-Run-Zeilen für ein Borg-Ziel (Kontext geladen, Repo erreichbar).
# Archivliste je Ziel einmal cachen (BORG_SIM_LOADED_ID), nicht je Dataset neu.
sim_target_borg() {
    local ds="$1" kept="$2" prefix archive name snap create=0 extra=0
    if [ "${BORG_SIM_LOADED_ID:-}" != "$CURRENT_TARGET_ID" ]; then
        borg_load_existing_archives
        BORG_SIM_LOADED_ID="$CURRENT_TARGET_ID"
    fi
    prefix=$(borg_dataset_prefix "$ds")
    # Erstellung: aktuelle verwaltete Quell-Snapshots ohne Archiv (vor Pruning).
    while read -r snap; do
        name="${snap#*@}"
        [ -n "$name" ] || continue
        borg_archive_exists "$(borg_archive_name "$ds" "$name")" || create=$((create+1))
    done < <(list_backup_snapshots "$ds")
    # Entfernen: Archive im Namespace, deren Snapshot nach dem Pruning fehlt.
    while IFS= read -r archive; do
        [ -n "$archive" ] || continue
        case "$archive" in "${prefix}"*) ;; *) continue ;; esac
        name="${archive#"${prefix}"}"
        case "$kept" in *"|${name}|"*) ;; *) extra=$((extra+1)) ;; esac
    done < <(printf '%s\n' "$BORG_EXISTING_ARCHIVES" | tr '|' '\n')
    if [ "$create" -gt 0 ]; then
        printf '  Replikation:  %s Archiv(e) würden erstellt\n' "$create"
    else
        printf '  Replikation:  aktuell\n'
    fi
    printf '  Zielabgleich: %s Archiv(e) würden entfernt (inkl. Pruning-Folge)\n' "$extra"
}

simulate_dataset() {
    local ds="$1"
    local DATE=$(date +%Y-%m-%d)
    local TIME=$(date +%H-%M)
    local HOUR=$(date +%H)
    local WEEK=$(date +%G-W%V)
    local MONTH=$(date +%Y-%m)
    local YEAR=$(date +%Y)
    local target_id
    # Seeding-Prinzip (vgl. create_snapshot_set): weekly/monthly/yearly sind
    # immer "fällig" — erstellt wird, sobald für die aktuelle Periode
    # (ISO-Woche/Monat/Jahr) noch kein Snapshot existiert, nicht erst am
    # Kalenderstichtag (So./1./1.1.).
    local weekly_due="yes"
    local monthly_due="yes"
    local yearly_due="yes"

    echo
    echo "$ds"
    echo "Snapshots:"

    if type_enabled hourly; then
        simulate_snapshot_action \
            "$ds" hourly yes \
            "${SNAPSHOT_PREFIX}hourly_${DATE}_${HOUR}" \
            "${SNAPSHOT_PREFIX}hourly_${DATE}_${TIME}"
    else
        printf "  %-7s: deaktiviert\n" "hourly"
    fi

    if type_enabled daily; then
        simulate_snapshot_action \
            "$ds" daily yes \
            "${SNAPSHOT_PREFIX}daily_${DATE}_" \
            "${SNAPSHOT_PREFIX}daily_${DATE}_${TIME}"
    else
        printf "  %-7s: deaktiviert\n" "daily"
    fi

    if type_enabled weekly; then
        simulate_snapshot_action \
            "$ds" weekly "$weekly_due" \
            "${SNAPSHOT_PREFIX}weekly_${WEEK}_" \
            "${SNAPSHOT_PREFIX}weekly_${WEEK}_${TIME}"
    else
        printf "  %-7s: deaktiviert\n" "weekly"
    fi

    if type_enabled monthly; then
        simulate_snapshot_action \
            "$ds" monthly "$monthly_due" \
            "${SNAPSHOT_PREFIX}monthly_${MONTH}_" \
            "${SNAPSHOT_PREFIX}monthly_${MONTH}_${TIME}"
    else
        printf "  %-7s: deaktiviert\n" "monthly"
    fi

    if type_enabled yearly; then
        simulate_snapshot_action \
            "$ds" yearly "$yearly_due" \
            "${SNAPSHOT_PREFIX}yearly_${YEAR}_" \
            "${SNAPSHOT_PREFIX}yearly_${YEAR}_${TIME}"
    else
        printf "  %-7s: deaktiviert\n" "yearly"
    fi

    if [ "$ENABLE_SOURCE_PRUNING" = "yes" ]; then
        echo "Quelle-Pruning:"
        simulate_retention "$ds" hourly "$KEEP_HOURLY"
        simulate_retention "$ds" daily "$KEEP_DAILY"
        simulate_retention "$ds" weekly "$KEEP_WEEKLY"
        simulate_retention "$ds" monthly "$KEEP_MONTHLY"
        simulate_retention "$ds" yearly "$KEEP_YEARLY"
    else
        echo "Quelle-Pruning:"
        echo "  deaktiviert"
    fi

    # Quell-Snapshots, die nach dem (simulierten) Pruning übrig blieben – Basis für
    # den pruning-bewussten Zielabgleich (einmal je Dataset, von allen Zielen genutzt).
    local type kept
    kept=$(sim_source_kept_set "$ds")
    for target_id in "${TARGETS[@]}"; do
        target_enabled "$target_id" || continue
        load_target_context "$target_id" || continue
        type=$(target_type "$target_id")
        echo "Zielabgleich $(target_label "$target_id") [${type}]:"
        # Vorab in simulate() als nicht erreichbar markiert? Dann nur Hinweis.
        case "$SIM_UNREACHABLE_IDS" in
            *"|${target_id}|"*)
                echo "  Ziel nicht erreichbar – übersprungen"
                continue ;;
        esac
        case "$type" in
            local)  sim_target_local  "$ds" "$kept" ;;
            remote) sim_target_remote "$ds" "$kept" ;;
            borg)   sim_target_borg   "$ds" "$kept" ;;
        esac
    done
}

# Eine Verwaisten-Sektion kompakt ausgeben: Kopfzeile mit Anzahl, darunter die
# Namen NUR bei wenigen Einträgen (bis 8), sonst Verweis auf --cleanup-orphans.
# $1 = Label (z. B. "Quelle" oder "<label> [remote]"), $2 = Beschreibung der
# Einträge; Liste der Namen von stdin. Setzt SIM_ORPHAN_FOUND/-TRUNCATED.
sim_orphan_section() {
    local label="$1" desc="$2"
    local -a items=()
    local line
    while read -r line; do [ -n "$line" ] && items+=("$line"); done
    local n=${#items[@]}
    [ "$n" -eq 0 ] && return 0
    SIM_ORPHAN_FOUND=1
    printf "  %s: %s %s\n" "$label" "$n" "$desc"
    if [ "$n" -le 8 ]; then
        for line in "${items[@]}"; do printf "      %s\n" "$line"; done
    else
        SIM_ORPHAN_TRUNCATED=1
    fi
}

# Vorschau der außer Betrieb genommenen / verwaisten Datasets, die ein Lauf nur
# MELDEN (nicht löschen) würde – Quelle und ALLE aktiven Ziele. Erreichbarkeit der
# Remote-/Borg-Ziele wurde in simulate() vorab ermittelt (Remote ggf. geweckt).
# Übersichtlich gehalten: je Sektion nur eine Anzahl-Zeile, Namen nur bei wenigen
# Einträgen; die vollständige Liste liefert --cleanup-orphans. Aus dem Umfang
# gefallene Datasets werden NIE automatisch bereinigt; Aufräumen nur über Wartung.
simulate_orphan_datasets() {
    local target_id
    local type
    local sds line sc sn_total=0 ds_n=0
    local -a sitems=()
    SIM_ORPHAN_FOUND=0
    SIM_ORPHAN_TRUNCATED=0

    echo
    echo "Außer Betrieb / verwaist (würde gemeldet, NICHT gelöscht):"

    # Quelle: bei außer Betrieb genommenen Datasets bleibt das Dataset (Live-Daten),
    # betroffen sind nur seine verbliebenen verwalteten Snapshots -> diese zählen.
    while read -r sds; do
        [ -n "$sds" ] || continue
        sc=0
        while read -r line; do [ -n "$line" ] && sc=$((sc+1)); done < <(list_backup_snapshots "$sds")
        sn_total=$((sn_total+sc)); ds_n=$((ds_n+1))
        sitems+=("$sds (${sc} Snapshot(s))")
    done < <(list_source_orphan_datasets)
    if [ "$ds_n" -gt 0 ]; then
        SIM_ORPHAN_FOUND=1
        printf "  Quelle: %s verwaiste Snapshot(s) in %s außer Betrieb genommenen Dataset(s)\n" "$sn_total" "$ds_n"
        if [ "$ds_n" -le 8 ]; then
            for line in "${sitems[@]}"; do printf "      %s\n" "$line"; done
        else
            SIM_ORPHAN_TRUNCATED=1
        fi
    fi

    # Ziele (lokal + remote; borg hat keine Ziel-Datasets).
    for target_id in "${TARGETS[@]}"; do
        target_enabled "$target_id" || continue
        type=$(target_type "$target_id")
        case "$type" in local|remote) ;; *) continue ;; esac
        load_target_context "$target_id" || continue

        case "$SIM_UNREACHABLE_IDS" in
            *"|${target_id}|"*)
                printf "  %s [%s]: Ziel nicht erreichbar – Verwaisten-Prüfung übersprungen\n" "$(target_label "$target_id")" "$type"
                continue ;;
        esac
        [ "$type" = "local" ] && { zfs list "$LOCAL_BACKUP_POOL" >/dev/null 2>&1 || continue; }

        sim_orphan_section "$(target_label "$target_id") [$type]" "verwaiste Ziel-Dataset(s)" \
            < <(list_target_orphan_datasets "$target_id")
    done

    [ "$SIM_ORPHAN_FOUND" -eq 0 ] && echo "  Keine außer Betrieb genommenen / verwaisten Datasets"
    [ "$SIM_ORPHAN_TRUNCATED" -eq 1 ] && echo "  Vollständige Liste / Aufräumen: zfs-backup --cleanup-orphans"
}

run_snapshot_job() {
    local mode="${1:-normal}"   # normal = Seeding; thin = frische Anker je aktivem Typ
    local count=0
    local total=0
    local index=0
    local ds
    local created_total
    local inv_h
    local inv_d
    local inv_w
    local inv_m
    local inv_y
    local inv_total
    local -a datasets

    mapfile -t datasets < <(get_datasets)
    total=${#datasets[@]}

    for ds in "${datasets[@]}"; do
        [ -n "$ds" ] || continue
        ((index++))
        console_status "Snapshot-Prüfung [${index}/${total}]: $ds"
        log "Snapshot-Prüfung [${index}/${total}]: $ds"
        if [ "$mode" = "thin" ]; then
            create_fresh_anchor_set "$ds"
        else
            create_snapshot_set "$ds"
        fi
        ((count++))
    done

    created_total=$((CREATED_HOURLY+CREATED_DAILY+CREATED_WEEKLY+CREATED_MONTHLY+CREATED_YEARLY))
    read -r inv_h inv_d inv_w inv_m inv_y inv_total < <(source_snapshot_inventory)

    console_success "Snapshots geprüft: ${count} Datasets, ${created_total} Snapshots neu"
    console_info "Snapshot-Bestand Quelle: ${inv_total} verwaltete Snapshots (Hourly ${inv_h}, Daily ${inv_d}, Weekly ${inv_w}, Monthly ${inv_m}, Yearly ${inv_y})"

    write_state last_snapshot_run "$(date '+%d.%m.%Y %H:%M:%S')"
    write_state datasets_count "$count"
    write_state snapshots_created "$created_total"
}

########################################
# Lokale Replikation
########################################

local_target_dataset() {
    local ds="$1"

    echo "${LOCAL_BACKUP_POOL}/${ds}"
}

list_backup_snapshots() {
    local ds="$1"

    zfs_name_is_safe "$ds" || return

    while read -r snap; do
        case "$snap" in
            "${ds}@${SNAPSHOT_PREFIX}"*) echo "$snap" ;;
        esac
    done < <(zfs list -H -t snapshot -o name -s creation -r "$ds" 2>/dev/null)
}

latest_backup_snapshot_name() {
    local ds="$1"
    local snap
    local latest=""

    while read -r snap; do
        latest="${snap#*@}"
    done < <(list_backup_snapshots "$ds")

    [ -n "$latest" ] && echo "$latest"
}

source_snapshot_name_exists() {
    local ds="$1"
    local name="$2"

    zfs list -t snapshot "${ds}@${name}" >/dev/null 2>&1
}

snapshot_stats_for_dataset() {
    local ds="$1"

    zfs_name_is_safe "$ds" || {
        printf "0 0\n"
        return
    }

    zfs list -H -p -t snapshot -o name,used -r "$ds" 2>/dev/null \
        | awk -v ds="$ds" -v prefix="$SNAPSHOT_PREFIX" '
            index($1, ds "@" prefix) == 1 {
                count++
                used += $2
            }
            END {
                printf "%d %d\n", count + 0, used + 0
            }
        '
}

snapshot_stats_for_active_datasets() {
    local mapper="${1:-}"
    local ds
    local target
    local count
    local used
    local total_count=0
    local total_used=0

    while read -r ds; do
        [ -n "$ds" ] || continue
        case "$mapper" in
            ""|cat) target="$ds" ;;
            *) target=$($mapper "$ds") ;;
        esac
        read -r count used < <(snapshot_stats_for_dataset "$target")
        total_count=$((total_count+count))
        total_used=$((total_used+used))
    done < <(get_datasets)

    printf "%d %d\n" "$total_count" "$total_used"
}

target_snapshot_stats_for_type() {
    local wanted_type="$1"
    local target_id
    local count
    local used
    local total_count=0
    local total_used=0

    for target_id in "${TARGETS[@]}"; do
        target_enabled "$target_id" || continue
        [ "$(target_type "$target_id")" = "$wanted_type" ] || continue
        load_target_context "$target_id" || continue

        case "$wanted_type" in
            local)
                read -r count used < <(snapshot_stats_for_active_datasets local_target_dataset)
                ;;
            remote)
                read -r count used < <(remote_snapshot_stats_for_active_datasets)
                ;;
        esac

        total_count=$((total_count+${count:-0}))
        total_used=$((total_used+${used:-0}))
    done

    printf "%d %d\n" "$total_count" "$total_used"
}

target_snapshot_inventory_for_type() {
    local wanted_type="$1"
    local target_id
    local h
    local d
    local w
    local m
    local y
    local total
    local total_h=0
    local total_d=0
    local total_w=0
    local total_m=0
    local total_y=0
    local total_all=0

    for target_id in "${TARGETS[@]}"; do
        target_enabled "$target_id" || continue
        [ "$(target_type "$target_id")" = "$wanted_type" ] || continue
        load_target_context "$target_id" || continue

        case "$wanted_type" in
            local)
                read -r h d w m y total < <(snapshot_inventory_for_active_datasets local_target_dataset)
                ;;
            remote)
                read -r h d w m y total < <(remote_snapshot_inventory_for_active_datasets)
                ;;
        esac

        total_h=$((total_h+${h:-0}))
        total_d=$((total_d+${d:-0}))
        total_w=$((total_w+${w:-0}))
        total_m=$((total_m+${m:-0}))
        total_y=$((total_y+${y:-0}))
        total_all=$((total_all+${total:-0}))
    done

    printf "%s %s %s %s %s %s\n" "$total_h" "$total_d" "$total_w" "$total_m" "$total_y" "$total_all"
}

latest_common_snapshot_name() {
    local source_ds="$1"
    local target_ds="$2"
    local snap
    local name
    local latest=""

    while read -r snap; do
        name="${snap#*@}"
        if zfs list -t snapshot "${target_ds}@${name}" >/dev/null 2>&1; then
            latest="$name"
        fi
    done < <(list_backup_snapshots "$source_ds")

    [ -n "$latest" ] && echo "$latest"
}

local_receive_options() {
    echo "-F -s -u"
}

local_receive_resume_token() {
    local dataset="$1"
    local token

    zfs_name_is_safe "$dataset" || return

    token=$(zfs get -H -o value receive_resume_token "$dataset" 2>/dev/null)

    [ -n "$token" ] || return
    [ "$token" = "-" ] && return

    echo "$token"
}

resume_local_replication() {
    local ds="$1"
    local target="$2"
    local token="$3"
    local mark_failure="${4:-yes}"

    log "Lokale Replikation Resume Send: ${ds} -> ${target}"

    if ! assert_safe_local_target_dataset "$ds" "$target"; then
        log "FEHLER: Unsicheres lokales Ziel-Dataset für Resume: $target"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Unsicheres lokales Resume-Ziel: $target"
        if [ "$mark_failure" = "yes" ]; then
            ((REPLICATION_ERRORS++))
            ((RUN_ERRORS++))
            mark_local_replication_failed "$ds"
        fi
        return 1
    fi

    if send_resume_stream "Lokal Resume ${ds} -> ${target}" "$token" \
        | zfs receive $(local_receive_options) "$target" 2> >(log_stderr "ZFS Receive lokal"); then
        ((REPLICATION_RESUMED++))
        return 0
    fi

    if [ "$mark_failure" = "yes" ]; then
        log "FEHLER: Lokaler Resume fehlgeschlagen: $ds -> $target"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Lokaler Resume fehlgeschlagen: $ds"
        ((REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        mark_local_replication_failed "$ds"
    else
        log "Lokaler Resume Versuch fehlgeschlagen: $ds -> $target"
    fi

    return 1
}

local_full_send() {
    local ds="$1"
    local target="$2"
    local latest="$3"
    local parent

    parent="${target%/*}"
    log "Lokale Replikation Full Send: ${ds}@${latest} -> ${target}"

    if ! assert_safe_local_target_dataset "$ds" "$target"; then
        log "FEHLER: Unsicheres lokales Ziel-Dataset: $target"
        return 1
    fi

    if [ "$parent" != "$target" ]; then
        zfs create -p "$parent" >/dev/null 2>&1 || {
            log "FEHLER: Ziel-Dataset konnte nicht vorbereitet werden: $parent"
            return 1
        }
    fi

    send_stream "Lokal Full ${ds}@${latest} -> ${target}" "${ds}@${latest}" \
        | zfs receive $(local_receive_options) "$target" 2> >(log_stderr "ZFS Receive lokal")
}

local_incremental_send() {
    local ds="$1"
    local target="$2"
    local from="$3"
    local to="$4"

    log "Lokale Replikation Incremental Send: ${ds}@${from} -> ${ds}@${to} | Ziel: ${target}"

    send_stream "Lokal Incremental ${ds}@${from} -> ${ds}@${to}" \
        -i "${ds}@${from}" "${ds}@${to}" \
        | zfs receive $(local_receive_options) "$target" 2> >(log_stderr "ZFS Receive lokal")
}

local_full_send_all_snapshots() {
    local ds="$1"
    local target="$2"
    local snap
    local previous=""
    local name
    local first="yes"
    local -a snaps

    mapfile -t snaps < <(list_backup_snapshots "$ds")

    [ "${#snaps[@]}" -gt 0 ] || {
        log "FEHLER: Keine verwalteten Snapshots für Full Send vorhanden: $ds"
        return 1
    }

    for snap in "${snaps[@]}"; do
        name="${snap#*@}"

        if [ "$first" = "yes" ]; then
            first="no"
            if ! local_full_send "$ds" "$target" "$name"; then
                if [ -n "$(local_receive_resume_token "$target")" ]; then
                    log "Lokale Replikation Full Send unterbrochen, Resume-Token bleibt erhalten: $target"
                    return 1
                fi
                if assert_safe_local_target_dataset "$ds" "$target"; then
                    zfs destroy -r "$target" >/dev/null 2>&1
                else
                    log "FEHLER: Unsicheres lokales Ziel-Dataset, Aufräumen nach Full-Send-Abbruch übersprungen: $target"
                fi
                return 1
            fi
        else
            if ! local_incremental_send "$ds" "$target" "$previous" "$name"; then
                return 1
            fi
        fi

        previous="$name"
    done
}

rebuild_local_target_from_all_snapshots() {
    local ds="$1"
    local target="$2"

    console_warn "Lokal-Replikation wird neu aufgebaut: $target"
    log "Lokale Replikation Neuaufbau mit Snapshot-Historie: $ds -> $target"

    if ! assert_safe_local_target_dataset "$ds" "$target"; then
        log "FEHLER: Unsicheres lokales Ziel-Dataset für Neuaufbau: $target"
        return 1
    fi

    zfs destroy -r "$target" >/dev/null 2>&1 || return 1
    local_full_send_all_snapshots "$ds" "$target"
}

estimate_send_size() {
    zfs send -nP "$@" 2>/dev/null | awk '$1 == "size" { size = $2 } END { if (size != "") print size }'
}

estimate_resume_send_size() {
    local token="$1"

    zfs send -nP -t "$token" 2>/dev/null | awk '$1 == "size" { size = $2 } END { if (size != "") print size }'
}

send_stream() {
    local label="$1"
    local size
    local status
    local display_status

    shift
    size=$(estimate_send_size "$@")

    if [ -n "$size" ]; then
        status="Übertragung: ${label} (geschätzt: $(format_bytes "$size"))"
        display_status="Übertragung: $(compact_transfer_label "$label") (geschätzt: $(format_bytes "$size"))"
    else
        status="Übertragung: ${label}"
        display_status="Übertragung: $(compact_transfer_label "$label")"
    fi
    echo "[$(date '+%d.%m.%Y %H:%M:%S')] $status" >> "$LOG_FILE"
    console_stream_status "$display_status"

    if [ -n "$size" ] && command -v pv >/dev/null 2>&1; then
        zfs send "$@" 2> >(log_stderr "ZFS Send") \
            | pv -f -n -s "$size" 2> >(transfer_progress_from_pv "$label" "$size")
        return
    fi

    if command -v pv >/dev/null 2>&1; then
        zfs send "$@" 2> >(log_stderr "ZFS Send") | pv -f -q
        return
    fi

    [ -n "$size" ] || echo "[$(date '+%d.%m.%Y %H:%M:%S')] Fortschritt nicht verfügbar, ZFS konnte keine Send-Größe ermitteln" >> "$LOG_FILE"
    echo "[$(date '+%d.%m.%Y %H:%M:%S')] Fortschritt nicht verfügbar, pv ist nicht installiert" >> "$LOG_FILE"

    zfs send "$@" 2> >(log_stderr "ZFS Send")
}

send_resume_stream() {
    local label="$1"
    local token="$2"
    local size
    local status
    local display_status

    size=$(estimate_resume_send_size "$token")

    if [ -n "$size" ]; then
        status="Übertragung: ${label} (geschätzt: $(format_bytes "$size"))"
        display_status="Übertragung: $(compact_transfer_label "$label") (geschätzt: $(format_bytes "$size"))"
    else
        status="Übertragung: ${label}"
        display_status="Übertragung: $(compact_transfer_label "$label")"
    fi
    echo "[$(date '+%d.%m.%Y %H:%M:%S')] $status" >> "$LOG_FILE"
    console_stream_status "$display_status"

    if [ -n "$size" ] && command -v pv >/dev/null 2>&1; then
        zfs send -t "$token" 2> >(log_stderr "ZFS Send Resume") \
            | pv -f -n -s "$size" 2> >(transfer_progress_from_pv "$label" "$size")
        return
    fi

    if command -v pv >/dev/null 2>&1; then
        zfs send -t "$token" 2> >(log_stderr "ZFS Send Resume") | pv -f -q
        return
    fi

    [ -n "$size" ] || echo "[$(date '+%d.%m.%Y %H:%M:%S')] Fortschritt nicht verfügbar, ZFS konnte keine Resume-Größe ermitteln" >> "$LOG_FILE"
    echo "[$(date '+%d.%m.%Y %H:%M:%S')] Fortschritt nicht verfügbar, pv ist nicht installiert" >> "$LOG_FILE"

    zfs send -t "$token" 2> >(log_stderr "ZFS Send Resume")
}

dataset_is_active_by_name() {
    local source_ds="$1"
    local ds
    local -a active

    # Erst vollständig einlesen, dann prüfen: ein early-return aus
    # `while read < <(get_datasets)` würde die Pipe schließen, während
    # get_datasets noch schreibt -> „echo: write error: Broken pipe".
    mapfile -t active < <(get_datasets)
    for ds in "${active[@]}"; do
        [ "$ds" = "$source_ds" ] && return 0
    done

    return 1
}

dataset_has_active_descendant() {
    local source_ds="$1"
    local ds
    local -a active

    # Erst vollständig einlesen, dann prüfen – sonst schließt das early-return
    # die Pipe, während get_datasets noch schreibt („echo: write error: Broken
    # pipe", vgl. dataset_is_active_by_name).
    mapfile -t active < <(get_datasets)
    for ds in "${active[@]}"; do
        case "$ds" in
            "${source_ds}/"*) return 0 ;;
        esac
    done

    return 1
}

replicate_dataset_local() {
    local ds="$1"
    local target
    local latest
    local common
    local token

    target=$(local_target_dataset "$ds")
    latest=$(latest_backup_snapshot_name "$ds")

    if ! assert_safe_local_target_dataset "$ds" "$target"; then
        log "FEHLER: Unsicheres lokales Ziel-Dataset: $target"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Unsicheres lokales Ziel-Dataset: $target"
        ((REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        mark_local_replication_failed "$ds"
        return
    fi

    if [ -z "$latest" ]; then
        log "Lokale Replikation übersprungen, kein Snapshot vorhanden: $ds"
        ((REPLICATION_SKIPPED++))
        return
    fi

    token=$(local_receive_resume_token "$target")
    if [ -n "$token" ]; then
        if resume_local_replication "$ds" "$target" "$token"; then
            return
        fi

        return
    fi

    if ! zfs list "$target" >/dev/null 2>&1; then
        if local_full_send_all_snapshots "$ds" "$target"; then
            ((REPLICATION_FULL++))
            return
        fi

        log "FEHLER: Full Send fehlgeschlagen: ${ds}@${latest} -> ${target}"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Lokale Full-Replikation fehlgeschlagen: $ds"
        ((REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        mark_local_replication_failed "$ds"
        return
    fi

    if zfs list -t snapshot "${target}@${latest}" >/dev/null 2>&1; then
        log "Lokale Replikation übersprungen, Ziel ist aktuell: ${target}@${latest}"
        ((REPLICATION_SKIPPED++))
        return
    fi

    common=$(latest_common_snapshot_name "$ds" "$target")

    if [ -z "$common" ]; then
        if rebuild_local_target_from_all_snapshots "$ds" "$target"; then
            ((REPLICATION_FULL++))
            return
        fi

        log "FEHLER: Kein gemeinsamer Snapshot für inkrementelle Replikation: $ds -> $target"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Kein gemeinsamer Snapshot: $ds"
        ((REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        mark_local_replication_failed "$ds"
        return
    fi

    log "Lokale Replikation Incremental Send: ${ds}@${common} -> ${ds}@${latest} | Ziel: ${target}"

    if send_stream "Lokal Incremental ${ds}@${common} -> ${ds}@${latest}" \
        -I "${ds}@${common}" "${ds}@${latest}" \
        | zfs receive $(local_receive_options) "$target" 2> >(log_stderr "ZFS Receive lokal"); then
        ((REPLICATION_INCREMENTAL++))
        return
    fi

    log "FEHLER: Incremental Send fehlgeschlagen: ${ds}@${common} -> ${ds}@${latest}"
    write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Lokale Incremental-Replikation fehlgeschlagen: $ds"
    ((REPLICATION_ERRORS++))
    ((RUN_ERRORS++))
    mark_local_replication_failed "$ds"
}

run_local_replication() {
    local ds
    local index=0
    local total=0
    local inv_h=0
    local inv_d=0
    local inv_w=0
    local inv_m=0
    local inv_y=0
    local inv_total=0
    local -a datasets

    [ "$ENABLE_LOCAL_REPLICATION" = "yes" ] || return

    if ! zfs list "$LOCAL_BACKUP_POOL" >/dev/null 2>&1; then
        log "FEHLER: Lokaler Backup-Pool nicht gefunden: $LOCAL_BACKUP_POOL"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Backup-Pool nicht gefunden: $LOCAL_BACKUP_POOL"
        ((REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        LOCAL_REPLICATION_FAILED_DATASETS="|*|"
        return
    fi

    mapfile -t datasets < <(get_datasets)
    total=${#datasets[@]}

    for ds in "${datasets[@]}"; do
        [ -n "$ds" ] || continue
        ((index++))
        console_status "Lokale Replikation [${index}/${total}]: $ds"
        replicate_dataset_local "$ds"
    done

    read -r inv_h inv_d inv_w inv_m inv_y inv_total < <(snapshot_inventory_for_active_datasets local_target_dataset)

    if [ "$REPLICATION_ERRORS" -eq 0 ]; then
        console_success "Lokale Replikation abgeschlossen"
        console_info "Datasets: ${REPLICATION_FULL} Full, ${REPLICATION_INCREMENTAL} inkrementell, ${REPLICATION_RESUMED} fortgesetzt, ${REPLICATION_SKIPPED} aktuell"
    else
        console_error "Lokale Replikation abgeschlossen"
        console_info "Datasets: ${REPLICATION_FULL} Full, ${REPLICATION_INCREMENTAL} inkrementell, ${REPLICATION_RESUMED} fortgesetzt, ${REPLICATION_SKIPPED} aktuell, ${REPLICATION_ERRORS} Fehler"
    fi
    console_info "Snapshot-Bestand Lokal: ${inv_total} verwaltete Snapshots (Hourly ${inv_h}, Daily ${inv_d}, Weekly ${inv_w}, Monthly ${inv_m}, Yearly ${inv_y})"
}

run_target_replication() {
    local target_id="$1"
    local type

    type=$(target_type "$target_id")
    log_phase "Replikation: $(target_label "$target_id")"

    case "$type" in
        local) run_local_replication ;;
        remote) run_remote_replication ;;
        borg) run_borg_replication ;;
    esac
}

run_target_replications() {
    for_each_enabled_target all run_target_replication
}

# Verwaiste Ziel-Datasets EINES Ziels auflisten – Ziel-Datasets unterhalb des
# BASE_DATASET, deren Quell-Dataset nicht mehr aktiv ist (gelöscht/aus dem Backup
# genommen) und die kein aktives Child mehr haben. NUR Auflisten, KEINE Löschung.
# Setzt einen geladenen Ziel-Kontext voraus (load_target_context). Ausgabe je
# Zeile der volle Ziel-Dataset-Name. Sicherheit: niemals automatisch löschen –
# ein versehentlich gelöschtes Quell-Dataset darf die Backups nicht mitreißen.
list_target_orphan_datasets() {
    local target_id="$1" type base target source_ds

    type=$(target_type "$target_id")
    case "$type" in
        local)
            base="$LOCAL_BACKUP_POOL"
            [ -n "$base" ] && zfs list "$base" >/dev/null 2>&1 || return 0
            while read -r target; do
                [ -n "$target" ] || continue
                [ "$target" = "$base" ] && continue
                case "$target" in "${base}/"*) ;; *) continue ;; esac
                source_ds="${target#${base}/}"
                dataset_is_active_by_name "$source_ds" && continue
                dataset_has_active_descendant "$source_ds" && continue
                printf '%s\n' "$target"
            done < <(zfs list -H -o name -r "$base" 2>/dev/null | sort -r)
            ;;
        remote)
            base="$REMOTE_BASE_DATASET"
            [ -n "$base" ] || return 0
            ensure_remote_ready >/dev/null 2>&1 || return 1
            remote_zfs_list "$base" || return 0
            while read -r target; do
                [ -n "$target" ] || continue
                [ "$target" = "$base" ] && continue
                case "$target" in "${base}/"*) ;; *) continue ;; esac
                source_ds="${target#${base}/}"
                dataset_is_active_by_name "$source_ds" && continue
                dataset_has_active_descendant "$source_ds" && continue
                printf '%s\n' "$target"
            done < <(remote_list_datasets_recursive "$base" | sort -r)
            ;;
    esac
}

########################################
# Remote-Replikation
########################################

remote_target_dataset() {
    local ds="$1"

    echo "${REMOTE_BASE_DATASET}/${ds}"
}

remote_ping_host() {
    local host="$1"

    ping -c 1 -W 1 "$host" >/dev/null 2>&1
}

remote_host_address() {
    local host="$REMOTE_HOST"

    host="${host#*@}"
    host="${host%%:*}"

    echo "$host"
}

ensure_remote_ready() {
    local host
    local waited=0
    local timeout="${REMOTE_WAKE_TIMEOUT_SECONDS:-60}"
    local interval="${REMOTE_WAKE_CHECK_INTERVAL_SECONDS:-2}"
    local ping_ready=0

    host=$(remote_host_address)

    if [ -z "$host" ]; then
        log "FEHLER: Remote Host nicht gesetzt"
        return 1
    fi

    if [ "$REMOTE_READY" -eq 1 ] && [ "$REMOTE_READY_HOST" = "$host" ]; then
        if remote_ssh "command -v zfs >/dev/null 2>&1" 2>/dev/null; then
            return 0
        fi

        REMOTE_READY=0
        log "Remote Bereitschaftscache verworfen: SSH/ZFS nicht mehr erreichbar"
    fi

    [ "$interval" -gt 0 ] 2>/dev/null || interval=2
    [ "$timeout" -gt 0 ] 2>/dev/null || timeout=60

    if remote_ping_host "$host"; then
        ping_ready=1
        log "Remote Host antwortet auf Ping: $host"
        console_info "Remote Host antwortet auf Ping: $host"
    else
        if [ "$ENABLE_REMOTE_WAKE_ON_LAN" != "yes" ]; then
            log "FEHLER: Remote Host nicht erreichbar: $host"
            return 1
        fi

        if [ -z "$REMOTE_WAKE_MAC" ]; then
            log "FEHLER: Remote Wake-on-LAN aktiv, aber REMOTE_WAKE_MAC ist nicht gesetzt"
            return 1
        fi

        if ! command -v etherwake >/dev/null 2>&1; then
            log "FEHLER: etherwake nicht gefunden, Remote Host kann nicht geweckt werden"
            return 1
        fi

        log "Remote Host nicht erreichbar: $host"
        log "Wake-on-LAN wird gesendet: $REMOTE_WAKE_MAC"
        console_warn "Remote Host nicht erreichbar: $host"
        console_info "Wake-on-LAN wird gesendet: $REMOTE_WAKE_MAC"

        if ! etherwake "$REMOTE_WAKE_MAC" >/dev/null 2>&1; then
            log "FEHLER: Wake-on-LAN fehlgeschlagen: $REMOTE_WAKE_MAC"
            return 1
        fi
    fi

    while [ "$waited" -lt "$timeout" ]; do
        if [ "$ping_ready" -eq 0 ] && remote_ping_host "$host"; then
            ping_ready=1
            log "Remote Host antwortet auf Ping nach ${waited} Sekunden: $host"
            console_info "Remote Host antwortet auf Ping nach ${waited} Sekunden: $host"
        fi

        if [ "$ping_ready" -eq 1 ] && remote_ssh "command -v zfs >/dev/null 2>&1" 2>/dev/null; then
            log "Remote Host bereit nach ${waited} Sekunden: $host"
            console_success "Remote Host bereit nach ${waited} Sekunden: $host"
            REMOTE_READY=1
            REMOTE_READY_HOST="$host"
            return 0
        fi

        log "Warte auf Remote Host: ${waited}/${timeout} Sekunden"
        if [ "$ping_ready" -eq 1 ]; then
            console_status "Warte auf Remote SSH/ZFS: ${waited}/${timeout} Sekunden"
        else
            console_status "Warte auf Remote Host: ${waited}/${timeout} Sekunden"
        fi

        sleep "$interval"
        waited=$((waited+interval))
    done

    log "FEHLER: Remote Host nicht bereit: $host"
    return 1
}

remote_ssh() {
    ssh -n -o UpdateHostKeys=no "${REMOTE_SSH_ARGS[@]}" "$REMOTE_HOST" "$@"
}

remote_ssh_stream() {
    ssh -o UpdateHostKeys=no "${REMOTE_SSH_ARGS[@]}" "$REMOTE_HOST" "$@"
}

remote_receive_options() {
    echo "-F -s -u"
}

remote_zfs_list() {
    local dataset="$1"
    local q_dataset

    zfs_name_is_safe "$dataset" || return 1
    q_dataset=$(shell_quote "$dataset")
    remote_ssh "zfs list ${q_dataset} >/dev/null 2>&1" 2>/dev/null
}

remote_snapshot_exists() {
    local snapshot="$1"
    local q_snapshot

    zfs_name_is_safe "$snapshot" || return 1
    q_snapshot=$(shell_quote "$snapshot")
    remote_ssh "zfs list -t snapshot ${q_snapshot} >/dev/null 2>&1" 2>/dev/null
}

remote_create_dataset() {
    local dataset="$1"
    local q_dataset

    zfs_name_is_safe "$dataset" || return 1
    q_dataset=$(shell_quote "$dataset")
    remote_ssh "zfs create -p ${q_dataset} >/dev/null 2>&1"
}

remote_list_backup_snapshots() {
    local ds="$1"
    local q_ds
    local q_prefix

    zfs_name_is_safe "$ds" || return
    q_ds=$(shell_quote "$ds")
    q_prefix=$(shell_quote "$SNAPSHOT_PREFIX")
    remote_ssh \
        "zfs list -H -t snapshot -o name -s creation -r ${q_ds} 2>/dev/null | awk -v ds=${q_ds} -v prefix=${q_prefix} 'index(\$1, ds \"@\" prefix) == 1 { print \$1 }'" \
        2>/dev/null
}

remote_destroy_snapshot() {
    local snapshot="$1"
    local q_snapshot

    zfs_name_is_safe "$snapshot" || return 1
    q_snapshot=$(shell_quote "$snapshot")
    remote_ssh "zfs destroy ${q_snapshot}"
}

remote_destroy_dataset_recursive() {
    local dataset="$1"
    local q_dataset

    zfs_name_is_safe "$dataset" || return 1
    q_dataset=$(shell_quote "$dataset")
    remote_ssh "zfs destroy -r ${q_dataset}"
}

remote_list_datasets_recursive() {
    local dataset="$1"
    local q_dataset

    zfs_name_is_safe "$dataset" || return
    q_dataset=$(shell_quote "$dataset")
    remote_ssh "zfs list -H -o name -r ${q_dataset} 2>/dev/null" 2>/dev/null
}

remote_snapshot_stats_for_dataset() {
    local dataset="$1"
    local q_dataset
    local q_prefix

    zfs_name_is_safe "$dataset" || {
        printf "0 0\n"
        return
    }
    q_dataset=$(shell_quote "$dataset")
    q_prefix=$(shell_quote "$SNAPSHOT_PREFIX")
    remote_ssh \
        "zfs list -H -p -t snapshot -o name,used -r ${q_dataset} 2>/dev/null | awk -v ds=${q_dataset} -v prefix=${q_prefix} 'index(\$1, ds \"@\" prefix) == 1 { count++; used += \$2 } END { printf \"%d %d\\n\", count + 0, used + 0 }'" \
        2>/dev/null
}

remote_snapshot_stats_for_active_datasets() {
    local ds
    local target
    local count
    local used
    local total_count=0
    local total_used=0

    [ "$ENABLE_REMOTE_REPLICATION" = "yes" ] || {
        printf "0 0\n"
        return
    }

    ensure_remote_ready >/dev/null 2>&1 || {
        printf "0 0\n"
        return
    }

    while read -r ds; do
        [ -n "$ds" ] || continue
        target=$(remote_target_dataset "$ds")
        read -r count used < <(remote_snapshot_stats_for_dataset "$target")
        total_count=$((total_count+${count:-0}))
        total_used=$((total_used+${used:-0}))
    done < <(get_datasets)

    printf "%d %d\n" "$total_count" "$total_used"
}

remote_snapshot_inventory_for_active_datasets() {
    local h=0 d=0 w=0 m=0 y=0
    local ds ch cd cw cm cy

    [ "$ENABLE_REMOTE_REPLICATION" = "yes" ] || {
        printf "0 0 0 0 0 0\n"
        return
    }

    ensure_remote_ready >/dev/null 2>&1 || {
        printf "0 0 0 0 0 0\n"
        return
    }

    # Ein einziger SSH-Aufruf (Bulk) statt fünf je Dataset.
    while read -r ds ch cd cw cm cy; do
        h=$((h+ch)); d=$((d+cd)); w=$((w+cw)); m=$((m+cm)); y=$((y+cy))
    done < <(remote_managed_snapshot_counts)

    printf "%s %s %s %s %s %s\n" "$h" "$d" "$w" "$m" "$y" "$((h+d+w+m+y))"
}

remote_receive_resume_token() {
    local dataset="$1"
    local token
    local q_dataset

    zfs_name_is_safe "$dataset" || return
    q_dataset=$(shell_quote "$dataset")
    token=$(remote_ssh \
        "zfs get -H -o value receive_resume_token ${q_dataset} 2>/dev/null" \
        2>/dev/null)

    [ -n "$token" ] || return
    [ "$token" = "-" ] && return

    echo "$token"
}

latest_common_remote_snapshot_name() {
    local source_ds="$1"
    local target_ds="$2"
    local snap
    local name
    local latest=""

    while read -r snap; do
        name="${snap#*@}"
        if remote_snapshot_exists "${target_ds}@${name}"; then
            latest="$name"
        fi
    done < <(list_backup_snapshots "$source_ds")

    [ -n "$latest" ] && echo "$latest"
}

resume_remote_replication() {
    local ds="$1"
    local target="$2"
    local token="$3"
    local mark_failure="${4:-yes}"
    local q_target

    log "Remote-Replikation Resume Send: ${ds} -> ${REMOTE_HOST}:${target}"

    assert_safe_remote_target_dataset "$ds" "$target" || {
        log "FEHLER: Unsicheres Remote Ziel-Dataset für Resume: ${REMOTE_HOST}:${target}"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Unsicheres Remote Resume-Ziel: $target"
        if [ "$mark_failure" = "yes" ]; then
            ((REMOTE_REPLICATION_ERRORS++))
            ((RUN_ERRORS++))
            mark_remote_replication_failed "$ds"
        fi
        return 1
    }
    q_target=$(shell_quote "$target")
    if send_resume_stream "Remote Resume ${ds} -> ${target}" "$token" \
        | remote_ssh_stream "zfs receive $(remote_receive_options) ${q_target}" 2> >(log_stderr "SSH/Remote Receive"); then
        ((REMOTE_REPLICATION_RESUMED++))
        return 0
    fi

    if [ "$mark_failure" = "yes" ]; then
        log "FEHLER: Remote Resume fehlgeschlagen: $ds -> $target"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Remote Resume fehlgeschlagen: $ds"
        ((REMOTE_REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        mark_remote_replication_failed "$ds"
    else
        log "Remote Resume Versuch fehlgeschlagen: $ds -> $target"
    fi
    return 1
}

remote_retry_attempts() {
    [ "$REMOTE_REPLICATION_RETRY_ATTEMPTS" -ge 0 ] 2>/dev/null || {
        echo 0
        return
    }

    echo "$REMOTE_REPLICATION_RETRY_ATTEMPTS"
}

remote_retry_wait_seconds() {
    [ "$REMOTE_REPLICATION_RETRY_WAIT_SECONDS" -ge 0 ] 2>/dev/null || {
        echo 10
        return
    }

    echo "$REMOTE_REPLICATION_RETRY_WAIT_SECONDS"
}

remote_resume_with_retries() {
    local ds="$1"
    local target="$2"
    local attempts
    local wait_seconds
    local attempt
    local token

    attempts=$(remote_retry_attempts)
    wait_seconds=$(remote_retry_wait_seconds)

    [ "$attempts" -gt 0 ] || return 1

    for ((attempt=1; attempt<=attempts; attempt++)); do
        log "Remote-Replikation Retry ${attempt}/${attempts}: $ds -> ${REMOTE_HOST}:${target}"
        console_warn "Remote-Replikation Retry ${attempt}/${attempts}: $ds"

        [ "$wait_seconds" -gt 0 ] && sleep "$wait_seconds"

        REMOTE_READY=0
        if ! ensure_remote_ready; then
            log "Remote-Replikation Retry ${attempt}/${attempts}: Remote nicht bereit"
            continue
        fi

        token=$(remote_receive_resume_token "$target")
        if [ -z "$token" ]; then
            log "Remote-Replikation Retry ${attempt}/${attempts}: kein Resume-Token vorhanden: ${REMOTE_HOST}:${target}"
            continue
        fi

        log "Remote-Replikation Retry ${attempt}/${attempts}: Resume-Token gefunden"
        if resume_remote_replication "$ds" "$target" "$token" no; then
            log "Remote-Replikation Retry erfolgreich: $ds -> ${REMOTE_HOST}:${target}"
            return 0
        fi
    done

    return 1
}

remote_full_send() {
    local ds="$1"
    local target="$2"
    local latest="$3"
    local count_stats="${4:-yes}"
    local parent
    local q_target

    parent="${target%/*}"
    log "Remote-Replikation Full Send: ${ds}@${latest} -> ${REMOTE_HOST}:${target}"

    if ! assert_safe_remote_target_dataset "$ds" "$target"; then
        log "FEHLER: Unsicheres Remote Ziel-Dataset: ${REMOTE_HOST}:${target}"
        [ "$count_stats" = "yes" ] && {
            ((REMOTE_REPLICATION_ERRORS++))
            ((RUN_ERRORS++))
            mark_remote_replication_failed "$ds"
        }
        return 1
    fi

    remote_create_dataset "$parent" || {
        log "FEHLER: Remote Ziel-Dataset konnte nicht vorbereitet werden: ${REMOTE_HOST}:${parent}"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Remote Ziel-Dataset konnte nicht vorbereitet werden: $parent"
        [ "$count_stats" = "yes" ] && {
            ((REMOTE_REPLICATION_ERRORS++))
            ((RUN_ERRORS++))
            mark_remote_replication_failed "$ds"
        }
        return 1
    }

    q_target=$(shell_quote "$target")
    if send_stream "Remote Full ${ds}@${latest} -> ${REMOTE_HOST}:${target}" "${ds}@${latest}" \
        | remote_ssh_stream "zfs receive $(remote_receive_options) ${q_target}" 2> >(log_stderr "SSH/Remote Receive"); then
        [ "$count_stats" = "yes" ] && ((REMOTE_REPLICATION_FULL++))
        return 0
    fi

    if remote_resume_with_retries "$ds" "$target"; then
        [ "$count_stats" = "yes" ] && ((REMOTE_REPLICATION_FULL++))
        return 0
    fi

    log "FEHLER: Remote Full Send fehlgeschlagen: ${ds}@${latest} -> ${target}"
    write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Remote Full-Replikation fehlgeschlagen: $ds"
    [ "$count_stats" = "yes" ] && {
        ((REMOTE_REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        mark_remote_replication_failed "$ds"
    }
    return 1
}

remote_incremental_send() {
    local ds="$1"
    local target="$2"
    local from="$3"
    local to="$4"
    local q_target

    log "Remote-Replikation Incremental Send: ${ds}@${from} -> ${ds}@${to} | Ziel: ${REMOTE_HOST}:${target}"

    q_target=$(shell_quote "$target")
    # -I (großes I) statt -i: überträgt ALLE dazwischenliegenden Snapshots, nicht
    # nur die Endpunkte. Sonst entstehen historische Lücken, wenn das Remote-Ziel
    # einen Lauf verpasst hat (z. B. WOL) und der nächste Lauf common->latest in
    # einem Rutsch aufholt. Der lokale Pfad nutzt ebenfalls -I (Konsistenz). Bei
    # zusammenhängenden Snapshots (from direkt vor to) verhält sich -I wie -i.
    if send_stream "Remote Incremental ${ds}@${from} -> ${ds}@${to}" \
        -I "${ds}@${from}" "${ds}@${to}" \
        | remote_ssh_stream "zfs receive $(remote_receive_options) ${q_target}" 2> >(log_stderr "SSH/Remote Receive"); then
        return 0
    fi

    remote_resume_with_retries "$ds" "$target"
}

remote_full_send_all_snapshots() {
    local ds="$1"
    local target="$2"
    local snap
    local previous=""
    local name
    local first="yes"
    local -a snaps

    mapfile -t snaps < <(list_backup_snapshots "$ds")

    [ "${#snaps[@]}" -gt 0 ] || {
        log "FEHLER: Keine verwalteten Snapshots für Remote Full Send vorhanden: $ds"
        return 1
    }

    for snap in "${snaps[@]}"; do
        name="${snap#*@}"

        if [ "$first" = "yes" ]; then
            first="no"
            if ! remote_full_send "$ds" "$target" "$name" no; then
                if assert_safe_remote_target_dataset "$ds" "$target"; then
                    remote_destroy_dataset_recursive "$target" >/dev/null 2>&1
                else
                    log "FEHLER: Unsicheres Remote Ziel-Dataset, Aufräumen nach Full-Send-Abbruch übersprungen: ${REMOTE_HOST}:${target}"
                fi
                return 1
            fi
        else
            if ! remote_incremental_send "$ds" "$target" "$previous" "$name"; then
                return 1
            fi
        fi

        previous="$name"
    done
}

rebuild_remote_target_from_all_snapshots() {
    local ds="$1"
    local target="$2"
    local reason="${3:-Neuaufbau}"

    console_warn "Remote-Replikation wird neu aufgebaut: ${REMOTE_HOST}:${target}"
    log "Remote-Replikation ${reason} mit Snapshot-Historie: $ds -> ${REMOTE_HOST}:${target}"

    if ! assert_safe_remote_target_dataset "$ds" "$target"; then
        log "FEHLER: Unsicheres Remote Ziel-Dataset für Neuaufbau: ${REMOTE_HOST}:${target}"
        return 1
    fi

    remote_destroy_dataset_recursive "$target" && remote_full_send_all_snapshots "$ds" "$target"
}

replicate_dataset_remote() {
    local ds="$1"
    local target
    local latest
    local common
    local token

    target=$(remote_target_dataset "$ds")
    latest=$(latest_backup_snapshot_name "$ds")

    if ! assert_safe_remote_target_dataset "$ds" "$target"; then
        log "FEHLER: Unsicheres Remote Ziel-Dataset: ${REMOTE_HOST}:${target}"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Unsicheres Remote Ziel-Dataset: $target"
        ((REMOTE_REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        mark_remote_replication_failed "$ds"
        return
    fi

    if [ -z "$latest" ]; then
        log "Remote-Replikation übersprungen, kein Snapshot vorhanden: $ds"
        ((REMOTE_REPLICATION_SKIPPED++))
        return
    fi

    token=$(remote_receive_resume_token "$target")
    if [ -n "$token" ]; then
        if resume_remote_replication "$ds" "$target" "$token" no; then
            return
        fi

        if remote_resume_with_retries "$ds" "$target"; then
            return
        fi

        log "FEHLER: Remote Resume fehlgeschlagen: $ds -> $target"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Remote Resume fehlgeschlagen: $ds"
        ((REMOTE_REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        mark_remote_replication_failed "$ds"
        return
    fi

    if ! remote_zfs_list "$target"; then
        if remote_full_send_all_snapshots "$ds" "$target"; then
            ((REMOTE_REPLICATION_FULL++))
            return
        fi

        log "FEHLER: Remote Full Send fehlgeschlagen: ${ds}@${latest} -> ${target}"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Remote Full-Replikation fehlgeschlagen: $ds"
        ((REMOTE_REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        mark_remote_replication_failed "$ds"
        return
    fi

    if remote_snapshot_exists "${target}@${latest}"; then
        log "Remote-Replikation übersprungen, Ziel ist aktuell: ${REMOTE_HOST}:${target}@${latest}"
        ((REMOTE_REPLICATION_SKIPPED++))
        return
    fi

    common=$(latest_common_remote_snapshot_name "$ds" "$target")

    if [ -z "$common" ]; then
        if rebuild_remote_target_from_all_snapshots "$ds" "$target" "Neuaufbau ohne gemeinsamen Snapshot"; then
            ((REMOTE_REPLICATION_FULL++))
            return
        fi

        log "FEHLER: Remote-Ziel konnte nicht neu aufgebaut werden: ${REMOTE_HOST}:${target}"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Remote-Ziel konnte nicht neu aufgebaut werden: $target"
        ((REMOTE_REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        mark_remote_replication_failed "$ds"
        return
    fi

    if remote_incremental_send "$ds" "$target" "$common" "$latest"; then
        ((REMOTE_REPLICATION_INCREMENTAL++))
        return
    fi

    log "FEHLER: Remote Incremental Send fehlgeschlagen: ${ds}@${common} -> ${ds}@${latest}"
    write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Remote Incremental-Replikation fehlgeschlagen: $ds"
    ((REMOTE_REPLICATION_ERRORS++))
    ((RUN_ERRORS++))
    mark_remote_replication_failed "$ds"
}

run_remote_replication() {
    local ds
    local index=0
    local total=0
    local inv_h=0
    local inv_d=0
    local inv_w=0
    local inv_m=0
    local inv_y=0
    local inv_total=0
    local -a datasets

    [ "$ENABLE_REMOTE_REPLICATION" = "yes" ] || return

    if [ -z "$REMOTE_HOST" ]; then
        log "FEHLER: Remote Host nicht gesetzt"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Remote Host nicht gesetzt"
        ((REMOTE_REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        return
    fi

    if ! ensure_remote_ready; then
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Remote Host nicht erreichbar: $REMOTE_HOST"
        ((REMOTE_REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        REMOTE_REPLICATION_FAILED_DATASETS="|*|"
        return
    fi

    if ! remote_ssh "command -v zfs >/dev/null 2>&1"; then
        log "FEHLER: Remote Host nicht erreichbar oder ZFS fehlt: $REMOTE_HOST"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Remote Host nicht erreichbar oder ZFS fehlt: $REMOTE_HOST"
        ((REMOTE_REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        REMOTE_REPLICATION_FAILED_DATASETS="|*|"
        return
    fi

    mapfile -t datasets < <(get_datasets)
    total=${#datasets[@]}

    for ds in "${datasets[@]}"; do
        [ -n "$ds" ] || continue
        ((index++))
        console_status "Remote-Replikation [${index}/${total}]: $ds"
        replicate_dataset_remote "$ds"
    done

    read -r inv_h inv_d inv_w inv_m inv_y inv_total < <(remote_snapshot_inventory_for_active_datasets)

    if [ "$REMOTE_REPLICATION_ERRORS" -eq 0 ]; then
        console_success "Remote-Replikation abgeschlossen"
        console_info "Datasets: ${REMOTE_REPLICATION_FULL} Full, ${REMOTE_REPLICATION_INCREMENTAL} inkrementell, ${REMOTE_REPLICATION_RESUMED} fortgesetzt, ${REMOTE_REPLICATION_SKIPPED} aktuell"
    else
        console_error "Remote-Replikation abgeschlossen"
        console_info "Datasets: ${REMOTE_REPLICATION_FULL} Full, ${REMOTE_REPLICATION_INCREMENTAL} inkrementell, ${REMOTE_REPLICATION_RESUMED} fortgesetzt, ${REMOTE_REPLICATION_SKIPPED} aktuell, ${REMOTE_REPLICATION_ERRORS} Fehler"
    fi
    console_info "Snapshot-Bestand Remote: ${inv_total} verwaltete Snapshots (Hourly ${inv_h}, Daily ${inv_d}, Weekly ${inv_w}, Monthly ${inv_m}, Yearly ${inv_y})"
}

# Run-Phase: verwaiste Ziel-Datasets nur ERKENNEN und LOGGEN, NIEMALS automatisch
# löschen (Schutz: ein versehentlich gelöschtes Quell-Dataset darf die Backups
# nicht mitlöschen). Das eigentliche Aufräumen läuft nur manuell über die Wartung
# (Dry-Run + Bestätigung, siehe maintenance_cleanup_orphans).
report_target_orphan_datasets() {
    local target_id="$1" target n=0

    while read -r target; do
        [ -n "$target" ] || continue
        n=$((n+1))
        log "Verwaistes Ziel-Dataset (Quelle gelöscht/inaktiv): $(target_label "$target_id") -> ${target}"
    done < <(list_target_orphan_datasets "$target_id")

    if [ "$n" -gt 0 ]; then
        ORPHAN_DATASETS_FOUND=$((ORPHAN_DATASETS_FOUND + n))
        console_warn "$(target_label "$target_id"): ${n} verwaiste Ziel-Dataset(s) – werden NICHT automatisch gelöscht (Aufräumen über Wartung)."
    fi
}

report_all_target_orphan_datasets() {
    ORPHAN_DATASETS_FOUND=0
    for_each_enabled_target all report_target_orphan_datasets
    [ "$ORPHAN_DATASETS_FOUND" -gt 0 ] && \
        log "Hinweis: ${ORPHAN_DATASETS_FOUND} verwaiste Ziel-Dataset(s) gefunden. Aufräumen nur manuell: zfs-backup.sh --cleanup-orphans (Dry-Run) bzw. --cleanup-orphans --yes."
    return 0
}

# Quell-Datasets, die aus dem Backup-Umfang gefallen sind (nicht mehr aktiv – ob
# durch INCLUDES-Verengung oder EXCLUDES), aber noch verwaltete Snapshots tragen.
# Quell-Pendant zu list_target_orphan_datasets. Rein lesend; NIE löschen (nur die
# Wartung räumt auf). Quelle = Live-Daten: hier geht es ausschließlich um die
# verbliebenen verwalteten Snapshots, niemals um das Dataset selbst.
list_source_orphan_datasets() {
    local pool ds inc seen_pools="|" seen_ds="|"

    for inc in "${INCLUDES[@]}"; do
        pool="${inc%%/*}"
        case "$seen_pools" in *"|${pool}|"*) continue ;; esac
        seen_pools="${seen_pools}${pool}|"

        while read -r ds; do
            [ -n "$ds" ] || continue
            case "$seen_ds" in *"|${ds}|"*) continue ;; esac
            is_pool_root_dataset "$ds" && continue
            is_self_dataset "$ds" && continue
            is_force_excluded "$ds" && continue
            dataset_is_active_by_name "$ds" && continue
            dataset_has_active_descendant "$ds" && continue
            # Nur melden, wenn überhaupt verwaltete Snapshots übrig sind.
            [ -n "$(list_backup_snapshots "$ds")" ] || continue
            seen_ds="${seen_ds}${ds}|"
            printf '%s\n' "$ds"
        done < <(zfs list -H -o name -r "$pool" 2>/dev/null)
    done
}

# Run-Phase: außer Betrieb genommene Quell-Datasets nur MELDEN, niemals automatisch
# löschen (analog report_target_orphan_datasets). Betroffen sind ihre verbliebenen
# verwalteten Snapshots (das Dataset bleibt) – daher zählt die Meldung Snapshots
# (Hauptgröße) und Datasets (Kontext). Setzt SOURCE_ORPHAN_SNAPSHOTS_FOUND und
# SOURCE_ORPHAN_DATASETS_FOUND.
report_source_orphan_datasets() {
    local ds line n=0 sn=0 sc

    SOURCE_ORPHAN_DATASETS_FOUND=0
    SOURCE_ORPHAN_SNAPSHOTS_FOUND=0
    while read -r ds; do
        [ -n "$ds" ] || continue
        n=$((n+1))
        sc=0
        while read -r line; do [ -n "$line" ] && sc=$((sc+1)); done < <(list_backup_snapshots "$ds")
        sn=$((sn+sc))
        log "Quell-Dataset außer Betrieb (nicht mehr im Backup-Umfang; ${sc} Snapshot(s) bleiben): $ds"
    done < <(list_source_orphan_datasets)

    if [ "$n" -gt 0 ]; then
        SOURCE_ORPHAN_DATASETS_FOUND=$n
        SOURCE_ORPHAN_SNAPSHOTS_FOUND=$sn
        console_warn "${sn} verwaiste Quell-Snapshot(s) in ${n} außer Betrieb genommenen Dataset(s) – werden NICHT automatisch gelöscht (Aufräumen über Wartung)."
        log "Hinweis: ${sn} verwaiste Quell-Snapshot(s) in ${n} Dataset(s). Aufräumen nur manuell: zfs-backup.sh --cleanup-orphans [--yes]."
    fi
    return 0
}

# Maintenance: verwaiste Datasets aufräumen. $1="yes" -> wirklich löschen, sonst
# Dry-Run (nur anzeigen, was gelöscht würde). $2 = Ziel-ID (leer = alle Ziele +
# Quelle). Destruktiv nur mit --yes; jede Ziel-Löschung über assert_safe_*. Deckt
# ab: (a) verwaiste ZIEL-Datasets (Quelle gelöscht/außer Betrieb) -> ganzes
# Ziel-Dataset löschen; (b) außer Betrieb genommene QUELL-Datasets -> nur deren
# verbliebene verwaltete Snapshots löschen, NIEMALS das Quell-Dataset.
maintenance_cleanup_orphans() {
    local do_delete="${1:-no}"
    local only_target="${2:-}"
    local target_id type base target source_ds total=0 deleted=0
    local source_orphan snap snapn sdeleted

    if [ -n "$only_target" ] && ! target_array_contains "$only_target"; then
        echo "FEHLER: Ziel nicht gefunden: $only_target" >&2
        return 1
    fi

    # (b) Quelle: außer Betrieb genommene Datasets – nur die verbliebenen
    # verwalteten Snapshots löschen. Nur im Gesamtlauf (kein einzelnes Ziel gewählt).
    if [ -z "$only_target" ]; then
        while read -r source_orphan; do
            [ -n "$source_orphan" ] || continue
            snapn=0
            while read -r snap; do [ -n "$snap" ] && snapn=$((snapn+1)); done < <(list_backup_snapshots "$source_orphan")
            total=$((total+1))

            if [ "$do_delete" != "yes" ]; then
                printf 'WÜRDE BEREINIGEN  [Quelle] %s (%s Snapshot(s))\n' "$source_orphan" "$snapn"
                continue
            fi

            sdeleted=0
            while read -r snap; do
                [ -n "$snap" ] || continue
                if zfs destroy "$snap"; then
                    sdeleted=$((sdeleted+1)); log "Quell-Orphan-Snapshot gelöscht: $snap"
                else
                    echo "FEHLER: konnte nicht löschen: $snap" >&2
                fi
            done < <(list_backup_snapshots "$source_orphan")
            [ "$sdeleted" -gt 0 ] && deleted=$((deleted+1))
            printf 'BEREINIGT  [Quelle] %s (%s Snapshot(s) gelöscht)\n' "$source_orphan" "$sdeleted"
        done < <(list_source_orphan_datasets)
    fi

    for target_id in "${TARGETS[@]}"; do
        target_enabled "$target_id" || continue
        [ -n "$only_target" ] && [ "$target_id" != "$only_target" ] && continue
        load_target_context "$target_id" || continue
        type=$(target_type "$target_id")
        case "$type" in
            local)  base="$LOCAL_BACKUP_POOL" ;;
            remote) base="$REMOTE_BASE_DATASET" ;;
            *) continue ;;
        esac

        while read -r target; do
            [ -n "$target" ] || continue
            total=$((total+1))
            source_ds="${target#${base}/}"

            if [ "$do_delete" != "yes" ]; then
                printf 'WÜRDE LÖSCHEN  [%s] %s\n' "$(target_label "$target_id")" "$target"
                continue
            fi

            case "$type" in
                local)
                    if ! assert_safe_local_target_dataset "$source_ds" "$target"; then
                        echo "FEHLER: unsicheres Ziel übersprungen: $target" >&2; continue
                    fi
                    if zfs destroy -r "$target"; then
                        deleted=$((deleted+1)); log "Orphan gelöscht: $target"
                        printf 'GELÖSCHT  %s\n' "$target"
                    else
                        echo "FEHLER: konnte nicht löschen: $target" >&2
                    fi
                    ;;
                remote)
                    if ! assert_safe_remote_target_dataset "$source_ds" "$target"; then
                        echo "FEHLER: unsicheres Ziel übersprungen: ${REMOTE_HOST}:${target}" >&2; continue
                    fi
                    if remote_destroy_dataset_recursive "$target"; then
                        deleted=$((deleted+1)); log "Orphan gelöscht: ${REMOTE_HOST}:${target}"
                        printf 'GELÖSCHT  %s:%s\n' "$REMOTE_HOST" "$target"
                    else
                        echo "FEHLER: konnte nicht löschen: ${REMOTE_HOST}:${target}" >&2
                    fi
                    ;;
            esac
        done < <(list_target_orphan_datasets "$target_id")
    done

    echo
    if [ "$do_delete" != "yes" ]; then
        if [ "$total" -eq 0 ]; then
            echo "Keine verwaisten Datasets gefunden (Quelle und Ziele)."
        else
            echo "Dry-Run: ${total} Eintrag/Einträge würden bereinigt (Ziel-Datasets gelöscht, Quell-Snapshots entfernt). Zum Ausführen die Aktion mit Bestätigung erneut starten (--yes)."
        fi
    else
        echo "Aufräumen abgeschlossen: ${deleted} von ${total} verwaisten Eintrag/Einträgen bereinigt."
        if [ "$deleted" -gt 0 ]; then
            # GUI-Caches verwerfen (Snapshot-Baum/Listen referenzieren Ziel-Datasets)
            # und den im Status angezeigten Orphan-Zähler nachziehen.
            invalidate_gui_cache 2>/dev/null
            update_run_stat_orphans
        fi
    fi
    return 0
}

# Den im Status angezeigten Zähler ORPHAN_DATASETS im Run-State auf den aktuellen
# Stand setzen (nach einem Cleanup). Zählt die verbleibenden Orphans über alle
# aktiven Ziele (kein Wecken nötig: lokal sofort, remote nur wenn erreichbar).
update_run_stat_orphans() {
    local file="${STATE_DIR}/last_run_stats" target_id ds line n=0 sds=0 ssn=0
    [ -f "$file" ] || return 0
    for target_id in "${TARGETS[@]}"; do
        target_enabled "$target_id" || continue
        load_target_context "$target_id" || continue
        while read -r _; do n=$((n+1)); done < <(list_target_orphan_datasets "$target_id")
    done
    # Quelle: außer Betrieb genommene Datasets (sds) und ihre Restsnapshots (ssn).
    while read -r ds; do
        [ -n "$ds" ] || continue
        sds=$((sds+1))
        while read -r line; do [ -n "$line" ] && ssn=$((ssn+1)); done < <(list_backup_snapshots "$ds")
    done < <(list_source_orphan_datasets)
    tmp="${file}.tmp.$$"
    update_run_stat_set "$file" ORPHAN_DATASETS "$n"
    update_run_stat_set "$file" SOURCE_ORPHAN_DATASETS "$sds"
    update_run_stat_set "$file" SOURCE_ORPHAN_SNAPSHOTS "$ssn"
}

# Einen Schlüssel im Run-State setzen/ergänzen (idempotent).
update_run_stat_set() {
    local file="$1" key="$2" value="$3" tmp="${1}.tmp.$$"
    if grep -q "^${key}=" "$file"; then
        sed "s/^${key}=.*/${key}=${value}/" "$file" > "$tmp" && mv "$tmp" "$file"
    else
        { cat "$file"; printf '%s=%s\n' "$key" "$value"; } > "$tmp" && mv "$tmp" "$file"
    fi
}

prune_remote_extra_snapshots() {
    local source_ds="$1"
    local target_ds="$2"
    local snap
    local name

    while read -r snap; do
        name="${snap#*@}"
        source_snapshot_name_exists "$source_ds" "$name" && continue

        log "Remote-Zielabgleich zusätzlicher Snapshot: ${REMOTE_HOST}:${snap}"
        if remote_destroy_snapshot "$snap"; then
            ((REMOTE_DELETED_SNAPSHOTS++))
            log "Remote-Zielabgleich gelöscht: ${REMOTE_HOST}:${snap}"
        else
            log "FEHLER: Zusätzlicher Remote-Snapshot konnte nicht gelöscht werden: ${REMOTE_HOST}:${snap}"
            write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Remote-Zielabgleich fehlgeschlagen: $snap"
            ((RUN_ERRORS++))
        fi
    done < <(remote_list_backup_snapshots "$target_ds")
}

prune_remote_pool_root_snapshots() {
    local root
    local target
    local snap

    [ "$SNAPSHOT_POOL_ROOTS" = "yes" ] && return
    while read -r root; do
        [ -n "$root" ] || continue
        target=$(remote_target_dataset "$root")
        remote_zfs_list "$target" || continue
        [ -n "$(remote_receive_resume_token "$target")" ] && continue
        console_status "Remote-Zielabgleich Pool-Root: $target"
        while read -r snap; do
            [ -n "$snap" ] || continue
            log "Pool-Root Remote-Zielabgleich: ${REMOTE_HOST}:${snap}"
            if remote_destroy_snapshot "$snap"; then
                ((REMOTE_DELETED_SNAPSHOTS++))
                log "Pool-Root Remote-Zielabgleich gelöscht: ${REMOTE_HOST}:${snap}"
            else
                log "FEHLER: Pool-Root Remote-Zielabgleich konnte nicht gelöscht werden: ${REMOTE_HOST}:${snap}"
                write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Pool-Root Remote-Zielabgleich fehlgeschlagen: $snap"
                ((RUN_ERRORS++))
            fi
        done < <(remote_list_backup_snapshots "$target")
    done < <(included_pool_roots)
}

sync_local_target_to_source_snapshots() {
    local target_id="$1"
    local ds
    local target
    local index=0
    local total=0
    local before="$LOCAL_DELETED_SNAPSHOTS"
    local deleted
    local -a datasets

    if ! zfs list "$LOCAL_BACKUP_POOL" >/dev/null 2>&1; then
        log "FEHLER: Lokaler Zielabgleich nicht möglich, Backup-Pool fehlt: $LOCAL_BACKUP_POOL"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Lokaler Zielabgleich nicht möglich: $LOCAL_BACKUP_POOL"
        ((REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        return
    fi

    mapfile -t datasets < <(get_datasets)
    total=${#datasets[@]}

    prune_local_pool_root_snapshots

    for ds in "${datasets[@]}"; do
        [ -n "$ds" ] || continue
        ((index++))
        target=$(local_target_dataset "$ds")
        zfs list "$target" >/dev/null 2>&1 || continue

        if [ -n "$(local_receive_resume_token "$target")" ]; then
            log "Lokaler Zielabgleich übersprungen, Resume-Token vorhanden: $target"
            continue
        fi

        console_status "Lokal-Zielabgleich $(target_label "$target_id") [${index}/${total}]: $ds"
        prune_local_extra_snapshots "$ds" "$target"
    done

    # Aus dem Umfang gefallene Datasets werden NICHT mehr automatisch bereinigt –
    # sie erscheinen als verwaiste Ziel-Datasets (report_*_orphan_datasets) und
    # werden nur über die Wartung gelöscht (maintenance_cleanup_orphans).

    deleted=$((LOCAL_DELETED_SNAPSHOTS-before))
    console_info "Lokal-Zielabgleich $(target_label "$target_id") abgeschlossen: ${deleted} Snapshot(s) entfernt"
}

sync_remote_target_to_source_snapshots() {
    local target_id="$1"
    local ds
    local target
    local index=0
    local total=0
    local before="$REMOTE_DELETED_SNAPSHOTS"
    local deleted
    local -a datasets

    if ! ensure_remote_ready; then
        log "FEHLER: Remote-Zielabgleich nicht möglich, Host nicht erreichbar: $REMOTE_HOST"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Remote-Zielabgleich nicht möglich: $REMOTE_HOST"
        ((REMOTE_REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        return
    fi

    if ! remote_ssh "command -v zfs >/dev/null 2>&1"; then
        log "FEHLER: Remote-Zielabgleich nicht möglich, Host nicht erreichbar oder ZFS fehlt: $REMOTE_HOST"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Remote-Zielabgleich nicht möglich: $REMOTE_HOST"
        ((REMOTE_REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        return
    fi

    remote_zfs_list "$REMOTE_BASE_DATASET" || return

    mapfile -t datasets < <(get_datasets)
    total=${#datasets[@]}

    prune_remote_pool_root_snapshots

    for ds in "${datasets[@]}"; do
        [ -n "$ds" ] || continue
        ((index++))
        target=$(remote_target_dataset "$ds")
        remote_zfs_list "$target" || continue

        if [ -n "$(remote_receive_resume_token "$target")" ]; then
            log "Remote-Zielabgleich übersprungen, Resume-Token vorhanden: ${REMOTE_HOST}:${target}"
            continue
        fi

        console_status "Remote-Zielabgleich $(target_label "$target_id") [${index}/${total}]: $ds"
        prune_remote_extra_snapshots "$ds" "$target"
    done

    # Siehe sync_local_target_to_source_snapshots: kein Auto-Löschen aus dem Umfang
    # gefallener Datasets mehr – Meldung als verwaist, Löschen nur über die Wartung.

    deleted=$((REMOTE_DELETED_SNAPSHOTS-before))
    console_info "Remote-Zielabgleich $(target_label "$target_id") abgeschlossen: ${deleted} Snapshot(s) entfernt"
}

sync_target_to_source_snapshots() {
    local target_id="$1"
    local type

    type=$(target_type "$target_id")

    case "$type" in
        local) sync_local_target_to_source_snapshots "$target_id" ;;
        remote) sync_remote_target_to_source_snapshots "$target_id" ;;
        borg) sync_borg_target_to_source_snapshots "$target_id" ;;
    esac
}

sync_targets_to_source_snapshots() {
    for_each_enabled_target all sync_target_to_source_snapshots
}

########################################
# Borg-Replikation (Offsite-Ziel)
########################################
# Optionaler Zieltyp: spiegelt den verwalteten Snapshot-Bestand der Quelle als
# Borg-Archive in ein entferntes Repository (rsync.net, BorgBase, Hetzner Storage
# Box oder ein eigener SSH-Host mit borg). Pro verwaltetem Snapshot EIN Archiv,
# benannt nach Dataset + Snapshot. „Quelle ist maßgeblich" bleibt erhalten: KEIN
# `borg prune`; der Zielabgleich löscht ausschließlich Archive zu nicht mehr
# existierenden Snapshots (Pendant zu prune_remote_extra_snapshots).
#
# WICHTIG: Borg überträgt über seine EIGENE SSH-Verbindung zum Repo (kein
# `zfs send | recv`-Pipe). Es gibt hier also keinen Datenstrom, in den fremder
# stdout-Inhalt geraten könnte – die Stream-Korruptionsgefahr der ZFS-Pfade
# besteht bei borg nicht. borgs stdout/stderr werden frei geloggt.

# Ablageort für Borg-Binary, Cache, Config und Security-Dir – gebündelt auf dem
# Pool (RUNTIME_DIR), schont den USB-Stick, übersteht Reboots und beschleunigt
# über den Chunk-Index die Folgeläufe.
borg_base_dir() {
    printf '%s/borg' "$RUNTIME_DIR"
}

# Pfad zur Borg-Binary. Bevorzugt die ins Plugin gebündelte Standalone-Binary
# (<RUNTIME_DIR>/borg/borg), sonst ein borg im PATH. Gibt bei Erfolg den Pfad aus
# und liefert 0; sonst 1 (nichts ausgegeben).
borg_bin() {
    local bundled
    bundled="$(borg_base_dir)/borg"
    if [ -x "$bundled" ]; then
        printf '%s' "$bundled"
        return 0
    fi
    if command -v borg >/dev/null 2>&1; then
        command -v borg
        return 0
    fi
    return 1
}

# Stellt eine fehlende borg-Binary über das mitgelieferte borg-setup.sh bereit
# (liegt neben dem Skript im Plugin-Verzeichnis). So genügt nach dem Anlegen
# eines borg-Ziels ein --test-target/Lauf, ohne auf den nächsten Array-Start zu
# warten. Liefert 0, wenn danach eine ausführbare Binary vorliegt.
borg_ensure_binary() {
    borg_bin >/dev/null 2>&1 && return 0
    local setup="${SCRIPT_DIR}/borg-setup.sh"
    if [ -f "$setup" ]; then
        log "Borg-Binary fehlt – borg-setup.sh wird ausgeführt"
        ZFS_BACKUP_RUNTIME_DIR="$RUNTIME_DIR" bash "$setup" "$RUNTIME_DIR" \
            2> >(log_stderr "borg-setup") >/dev/null
    fi
    borg_bin >/dev/null 2>&1
}

# Führt borg im aktuellen Ziel-Kontext aus (BORG_REPO/Passphrase/SSH/Cache aus
# load_target_context). Nicht-interaktiv: Passphrase kommt aus der Config, borg
# fragt nie nach. Gibt borgs Exit-Code unverändert durch (0 ok, 1 Warnung,
# >=2 Fehler).
borg_run() {
    local bin base
    bin="$(borg_bin)" || { log "FEHLER: Borg-Binary nicht gefunden"; return 127; }
    base="$(borg_base_dir)"
    mkdir -p "$base" 2>/dev/null

    BORG_REPO="$BORG_REPO" \
    BORG_PASSPHRASE="$BORG_PASSPHRASE_VALUE" \
    BORG_BASE_DIR="$base" \
    BORG_RSH="ssh ${BORG_SSH_OPTIONS}" \
    "$bin" "$@"
}

# Archivname je verwaltetem Snapshot: <dataset>__<snap>, wobei „/" im Dataset
# durch „%" ersetzt wird (in ZFS-Namen nie vorhanden -> umkehrbar, kollisionsfrei).
# So liegen mehrere Datasets namespaced im selben Repo, ohne fremde Archive (z. B.
# bestehende Backups des Nutzers) zu berühren.
borg_dataset_prefix() {
    local ds="$1"
    printf '%s__' "${ds//\//%}"
}

borg_archive_name() {
    local ds="$1" snap="$2"
    printf '%s__%s' "${ds//\//%}" "$snap"
}

# Liest die Archivnamen des Repos einmal pro Lauf in BORG_EXISTING_ARCHIVES
# (|name|name|-Set), damit die per-Dataset-Replikation nicht je Snapshot ein
# eigenes `borg list` startet (Onefile-Re-Extraktion + SSH je Aufruf vermeiden).
borg_load_existing_archives() {
    local name
    BORG_EXISTING_ARCHIVES="|"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        BORG_EXISTING_ARCHIVES="${BORG_EXISTING_ARCHIVES}${name}|"
    done < <(borg_run list --short 2>/dev/null)
}

borg_archive_exists() {
    case "$BORG_EXISTING_ARCHIVES" in
        *"|${1}|"*) return 0 ;;
    esac
    return 1
}

# Liest borgs --log-json-Fortschritt (stderr) von stdin und meldet ihn als
# Lauf-Fortschritt: bei bekannter Gesamtgröße ($1, referenced) in %, sonst die
# verarbeitete Menge. $2 = Label (Archivname). Sonstige Meldungen (Warnungen) ins
# Log. Pendant zu transfer_progress_from_pv, nur für borg create.
borg_create_progress() {
    local total="$1" label="$2" line orig pct last="-1" step msg compact
    compact=$(compact_transfer_label "$label")
    while IFS= read -r line; do
        case "$line" in
            *'"archive_progress"'*)
                case "$line" in *'"finished"'*) continue ;; esac
                orig=$(printf '%s' "$line" | sed -n 's/.*"original_size"[^0-9]*\([0-9][0-9]*\).*/\1/p')
                case "$orig" in ''|*[!0-9]*) continue ;; esac
                if [ "$total" -gt 0 ] 2>/dev/null; then
                    pct=$(( orig * 100 / total )); [ "$pct" -gt 100 ] && pct=100
                    [ "$pct" = "$last" ] && continue
                    last="$pct"
                    console_stream_status "Borg-Übertragung: ${compact} ${pct}%"
                else
                    step=$(( orig / 52428800 ))   # je ~50 MiB eine Meldung
                    [ "$step" = "$last" ] && continue
                    last="$step"
                    console_stream_status "Borg-Übertragung: ${compact} $(format_bytes "$orig")"
                fi
                ;;
            *'"log_message"'*)
                msg=$(printf '%s' "$line" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
                [ -n "$msg" ] && log "Borg create ${label}: ${msg}"
                ;;
            *'"type"'*) : ;;   # andere strukturierte Events ignorieren
            *) [ -n "$line" ] && log "Borg create ${label}: ${line}" ;;
        esac
    done
}

# Legt für jeden verwalteten Quell-Snapshot ohne Archiv ein borg-Archiv an. Liest
# read-only aus <mountpoint>/.zfs/snapshot/<snap> – exakt der Pfad, den auch
# Datei-Browser und Restore nutzen. Ein Fehler markiert das Dataset
# (mark_borg_replication_failed) und blockiert dadurch sein Quell-Pruning.
replicate_dataset_borg() {
    local ds="$1"
    local snap name archive root rc _bsz _bo _bd _btotal
    local did_fail=0

    while IFS= read -r snap; do
        name="${snap#*@}"
        [ -n "$name" ] || continue
        archive="$(borg_archive_name "$ds" "$name")"
        borg_archive_exists "$archive" && continue

        root="$(local_snapshot_root "$ds" "$name")" || {
            log "FEHLER: Borg-Quelle nicht browsebar (Mountpoint none/legacy): ${ds}@${name}"
            write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Borg-Quelle nicht browsebar: ${ds}@${name}"
            did_fail=1
            continue
        }
        if [ ! -d "$root" ]; then
            log "FEHLER: Borg-Snapshot-Pfad fehlt: $root"
            write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Borg-Snapshot-Pfad fehlt: $root"
            did_fail=1
            continue
        fi

        log "Borg create: ${ds}@${name} -> ${BORG_REPO}::${archive}"
        # Fortschritt: referenzierte Snapshot-Größe als Gesamtwert (schnell, aus
        # ZFS-Metadaten – kein Datei-Walk). --log-json --progress lässt borg den
        # Fortschritt strukturiert auf stderr melden -> borg_create_progress.
        _btotal=$(zfs get -Hp -o value referenced "${ds}@${name}" 2>/dev/null)
        case "$_btotal" in ''|*[!0-9]*) _btotal=0 ;; esac
        # cd in den Snapshot-Root, „." sichern -> Archiv enthält relative Pfade.
        ( cd "$root" && borg_run create --one-file-system --log-json --progress "::${archive}" . \
            2> >(borg_create_progress "$_btotal" "$archive") )
        rc=$?
        if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
            [ "$rc" -eq 1 ] && log "Borg create Warnung (rc=1, fortgesetzt): ${archive}"
            BORG_EXISTING_ARCHIVES="${BORG_EXISTING_ARCHIVES}${archive}|"
            ((BORG_CREATED_ARCHIVES++))
            # Größe des frisch erstellten Archivs persistent cachen (ändert sich nie).
            if _bsz=$(borg_fetch_archive_size "$archive"); then
                IFS=$'\t' read -r _bo _bd <<< "$_bsz"
                borg_size_store "$CURRENT_TARGET_ID" "$archive" "$_bo" "$_bd"
            fi
        else
            log "FEHLER: Borg create fehlgeschlagen (rc=${rc}): ${archive}"
            write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Borg create fehlgeschlagen: ${archive}"
            did_fail=1
        fi
    done < <(list_backup_snapshots "$ds")

    if [ "$did_fail" -eq 1 ]; then
        ((BORG_REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        mark_borg_replication_failed "$ds"
    fi
}

run_borg_replication() {
    local ds index=0 total
    local -a datasets

    [ "$ENABLE_BORG_REPLICATION" = "yes" ] || return

    if ! borg_ensure_binary; then
        log "FEHLER: Borg-Replikation nicht möglich, Binary fehlt"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Borg-Binary fehlt"
        ((BORG_REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        BORG_REPLICATION_FAILED_DATASETS="|*|"
        return
    fi

    if ! borg_run info >/dev/null 2>&1; then
        log "FEHLER: Borg-Repo nicht erreichbar: $BORG_REPO"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Borg-Repo nicht erreichbar: $BORG_REPO"
        ((BORG_REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        BORG_REPLICATION_FAILED_DATASETS="|*|"
        return
    fi

    # Repo erreichbar -> der GUI-Cache darf danach die Archivliste abrufen.
    BORG_READY=1
    BORG_READY_REPO="$BORG_REPO"

    borg_load_existing_archives

    mapfile -t datasets < <(get_datasets)
    total=${#datasets[@]}

    for ds in "${datasets[@]}"; do
        [ -n "$ds" ] || continue
        ((index++))
        console_status "Borg-Replikation [${index}/${total}]: $ds"
        replicate_dataset_borg "$ds"
    done

    if [ "$BORG_REPLICATION_ERRORS" -eq 0 ]; then
        console_success "Borg-Replikation abgeschlossen"
    else
        console_error "Borg-Replikation abgeschlossen"
    fi
    console_info "Archive: ${BORG_CREATED_ARCHIVES} neu erstellt"
}

# Borg-Zielabgleich: löscht je Dataset die Archive im eigenen Namespace
# (<dataset>__…), deren Quell-Snapshot nicht mehr existiert. Fremde Archive
# (bestehende Backups des Nutzers ohne unseren Präfix) werden NIE angefasst.
borg_prune_extra_archives() {
    local ds="$1"
    local prefix archive name snap

    prefix="$(borg_dataset_prefix "$ds")"

    # Aktuell verwaltete Quell-Snapshotnamen als Set sammeln.
    local present="|"
    while IFS= read -r snap; do
        name="${snap#*@}"
        [ -n "$name" ] || continue
        present="${present}${name}|"
    done < <(list_backup_snapshots "$ds")

    while IFS= read -r archive; do
        [ -n "$archive" ] || continue
        case "$archive" in
            "${prefix}"*) ;;
            *) continue ;;
        esac
        snap="${archive#"${prefix}"}"
        case "$present" in
            *"|${snap}|"*) continue ;;
        esac

        log "Borg-Zielabgleich zusätzliches Archiv: ${archive}"
        if borg_run delete "::${archive}" 2> >(log_stderr "Borg delete ${archive}"); then
            ((BORG_DELETED_ARCHIVES++))
            log "Borg-Zielabgleich gelöscht: ${archive}"
        else
            log "FEHLER: Borg-Archiv konnte nicht gelöscht werden: ${archive}"
            write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Borg-Zielabgleich fehlgeschlagen: ${archive}"
            ((RUN_ERRORS++))
        fi
    done < <(printf '%s\n' "${BORG_EXISTING_ARCHIVES}" | tr '|' '\n')
}

# Gibt Speicher frei (Dedup gibt erst beim Compact frei). Läuft NICHT jeden Lauf,
# sondern alle COMPACT_EVERY Läufe (Zähler je Ziel im State). 0 = nie.
borg_compact_if_due() {
    local key count every
    every="${BORG_COMPACT_EVERY:-10}"
    [ "$every" -gt 0 ] 2>/dev/null || return 0

    key="borg_compact_${CURRENT_TARGET_ID}"
    count="$(state_value "$key" 0)"
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    count=$((count+1))

    if [ "$count" -ge "$every" ]; then
        console_status "Borg compact $(target_label "$CURRENT_TARGET_ID"): Speicher freigeben"
        log "Borg compact: ${BORG_REPO}"
        if borg_run compact 2> >(log_stderr "Borg compact"); then
            log "Borg compact abgeschlossen"
        else
            log "FEHLER: Borg compact fehlgeschlagen: ${BORG_REPO}"
            write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Borg compact fehlgeschlagen: ${BORG_REPO}"
            ((RUN_ERRORS++))
        fi
        count=0
    fi
    write_state "$key" "$count"
}

sync_borg_target_to_source_snapshots() {
    local target_id="$1"
    local ds index=0 total
    local before="$BORG_DELETED_ARCHIVES"
    local deleted
    local -a datasets

    if ! borg_ensure_binary || ! borg_run info >/dev/null 2>&1; then
        log "FEHLER: Borg-Zielabgleich nicht möglich, Repo nicht erreichbar: $BORG_REPO"
        write_state last_error "$(date '+%d.%m.%Y %H:%M:%S') Borg-Zielabgleich nicht möglich: $BORG_REPO"
        ((BORG_REPLICATION_ERRORS++))
        ((RUN_ERRORS++))
        return
    fi

    borg_load_existing_archives

    mapfile -t datasets < <(get_datasets)
    total=${#datasets[@]}

    for ds in "${datasets[@]}"; do
        [ -n "$ds" ] || continue
        ((index++))
        console_status "Borg-Zielabgleich $(target_label "$target_id") [${index}/${total}]: $ds"
        borg_prune_extra_archives "$ds"
    done

    # Fehlende Archivgrößen nachziehen (begrenzt; füllt den Größen-Cache über Läufe).
    borg_backfill_sizes 50

    # Speicher erst nach dem Löschen freigeben (sinnvollster Zeitpunkt).
    borg_compact_if_due

    deleted=$((BORG_DELETED_ARCHIVES-before))
    console_info "Borg-Zielabgleich $(target_label "$target_id") abgeschlossen: ${deleted} Archiv(e) entfernt"
}

# Prüft ein Borg-Ziel (Kern für --test-target): Binary ausführbar,
# BORG_BASE_DIR beschreibbar, Repo per `borg info` erreichbar. Setzt einen
# geladenen Ziel-Kontext voraus (load_target_context).
borg_target_test() {
    local base
    if ! borg_ensure_binary; then
        console_error "Borg-Binary nicht gefunden (weder gebündelt unter $(borg_base_dir) noch im PATH) und konnte nicht bezogen werden"
        return 1
    fi
    base="$(borg_base_dir)"
    if ! mkdir -p "$base" 2>/dev/null || [ ! -w "$base" ]; then
        console_error "Borg-Cache-Verzeichnis nicht beschreibbar: $base"
        return 1
    fi
    if [ -z "$BORG_REPO" ]; then
        console_error "Borg-Repo-URL nicht gesetzt"
        return 1
    fi
    if borg_run info >/dev/null 2>&1; then
        console_success "Borg-Repo erreichbar: $BORG_REPO"
        return 0
    fi
    console_error "Borg-Repo nicht erreichbar (Passphrase/Netz/Repo prüfen): $BORG_REPO"
    return 1
}

# Maintenance „Snapshots löschen": entfernt alle Archive im verwalteten Namespace
# aller aktiven Datasets aus dem Repo (nie fremde Archive). Setzt geladenen
# Ziel-Kontext voraus.
maintenance_delete_borg_target_archives() {
    local target_id="$1"
    local ds archive prefix
    local -a datasets

    if ! borg_bin >/dev/null 2>&1 || ! borg_run info >/dev/null 2>&1; then
        console_error "Borg-Repo nicht erreichbar: $BORG_REPO"
        ((MAINTENANCE_SNAPSHOT_ERRORS++))
        return
    fi

    borg_load_existing_archives
    mapfile -t datasets < <(get_datasets)

    for ds in "${datasets[@]}"; do
        [ -n "$ds" ] || continue
        prefix="$(borg_dataset_prefix "$ds")"
        console_status "Archive löschen $(target_label "$target_id"): $ds"
        while IFS= read -r archive; do
            [ -n "$archive" ] || continue
            case "$archive" in "${prefix}"*) ;; *) continue ;; esac
            log "Maintenance Borg: Archiv wird gelöscht: ${archive}"
            if borg_run delete "::${archive}" 2> >(log_stderr "Borg delete ${archive}"); then
                ((MAINTENANCE_SNAPSHOTS_DELETED++))
                log "Maintenance Borg: Archiv gelöscht: ${archive}"
            else
                ((MAINTENANCE_SNAPSHOT_ERRORS++))
                log "FEHLER: Maintenance Borg: Archiv konnte nicht gelöscht werden: ${archive}"
            fi
        done < <(printf '%s\n' "${BORG_EXISTING_ARCHIVES}" | tr '|' '\n')
    done
}

# Anbieter-Vorlagen für borg-Ziele (Datenquelle der GUI; --borg-providers --json).
# Je Anbieter: id, label, Repo-URL-Platzhalter, Default-SSH-Optionen, Setup-Schritte
# (anzeigbare Anleitung) und ein Hinweis. Statisch – ein neuer Anbieter kommt als
# weiterer Block dazu. Reines JSON, kein jq nötig.
borg_providers_json() {
    cat <<'JSON'
[
  {
    "id":"hetzner",
    "label":"Hetzner Storage Box",
    "repo_placeholder":"ssh://uXXXXX@uXXXXX.your-storagebox.de:23/home/<verzeichnis>",
    "ssh_options":"-i /root/.ssh/zfs_backup_ed25519 -o BatchMode=yes -o ConnectTimeout=10",
    "steps":[
      "An der Storage Box „SSH support“ aktivieren (Hetzner-Konsole/Robot).",
      "SSH-Key erzeugen (oder bestehenden nutzen): ssh-keygen -t ed25519 -f /root/.ssh/zfs_backup_ed25519 -N \"\"",
      "Pubkey hochladen (einmalig, fragt nach dem Box-Passwort): cat /root/.ssh/zfs_backup_ed25519.pub | ssh -p 23 uXXXXX@uXXXXX.your-storagebox.de install-ssh-key",
      "Falls das Repo neu ist, einmalig anlegen: borg init --encryption=repokey (mit denselben Zugangsdaten).",
      "Repo-URL und Passphrase oben eintragen, dann „Testen“."
    ],
    "note":"Der Port (23) steckt in der Repo-URL. /root/.ssh ist auf Unraid reboot-persistent (Symlink auf den USB-Stick)."
  },
  {
    "id":"generic",
    "label":"Generischer SSH-Host / anderer Anbieter",
    "repo_placeholder":"ssh://user@host:22/pfad/zum/repo",
    "ssh_options":"-o BatchMode=yes -o ConnectTimeout=10",
    "steps":[
      "Auf dem Zielhost muss borg installiert sein (Zugriff über „borg serve“ per SSH).",
      "Passwortlosen SSH-Key einrichten (z. B. ssh-copy-id) – headless, ohne Key-Passphrase.",
      "Falls das Repo neu ist, einmalig anlegen: borg init --encryption=repokey.",
      "Repo-URL und Passphrase oben eintragen, dann „Testen“."
    ],
    "note":"Bei abweichendem SSH-Port diesen in der Repo-URL angeben (ssh://…:PORT/…)."
  }
]
JSON
}

# Deduplizierte Gesamtgröße des Repos in Bytes (was es real belegt), aus
# `borg info --json` (cache.stats.unique_csize). Reines tr/sed, kein jq. Setzt
# geladenen borg-Kontext voraus. Leer bei Fehler. borg kennt kein „frei/total"
# (Repo hat kein festes Limit) – daher nur die belegte Größe.
borg_repo_used_bytes() {
    borg_run info --json 2>/dev/null \
        | tr ',{}' '\n\n\n' \
        | sed -n 's/.*"unique_csize"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        | head -n1
}

# --- Informativer borg-Versions-Update-Check --------------------------------
# Vergleicht die installierte borg-Version mit der neuesten GitHub-Release. KEIN
# Auto-Update: die Binary ist gepinnt + SHA256-geprüft, ein borg-Update läuft
# bewusst über ein Plugin-Release (neue BORG_VERSION in borg-setup.sh). Ein Sprung
# auf eine neue Hauptversion (z. B. 2.x) ist breaking (Repo-Format) und wird extra
# markiert. Ergebnis wird gecacht (1x/Tag) – kein Netzzugriff fürs bloße Anzeigen.

borg_update_cache_file() { printf '%s/borg_update_check' "$STATE_DIR"; }

# Installierte borg-Version (z. B. „1.4.4"). Leer, wenn nicht ermittelbar.
borg_installed_version() {
    local bin
    bin=$(borg_bin) || return 1
    "$bin" --version 2>/dev/null | awk '{print $2}'
}

# Neueste Release-Version von GitHub (tag_name). Leer bei Fehler/kein Netz.
borg_github_latest_version() {
    local url="https://api.github.com/repos/borgbackup/borg/releases/latest" body
    if command -v curl >/dev/null 2>&1; then
        body=$(curl -fsSL --max-time 8 "$url" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        body=$(wget -qO- --timeout=8 "$url" 2>/dev/null)
    else
        return 1
    fi
    printf '%s' "$body" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

# Version a < b (Punkt-getrennt, via sort -V). Rückgabe 0 wenn a<b.
borg_version_lt() {
    [ "$1" = "$2" ] && return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# GitHub höchstens 1x/Tag fragen und das Ergebnis cachen (CHECKED/INSTALLED/LATEST).
# $1=force umgeht die Drosselung. Nur wenn ein borg-Ziel aktiv ist. Rückgabe immer 0.
borg_update_refresh() {
    local force="${1:-no}" cache cur latest now checked=0
    [ "$(target_enabled_count borg)" -gt 0 ] || return 0
    cur=$(borg_installed_version) || return 0
    [ -n "$cur" ] || return 0
    cache=$(borg_update_cache_file)
    now=$(date +%s)
    [ -f "$cache" ] && while IFS='=' read -r k v; do [ "$k" = "CHECKED" ] && checked=$v; done < "$cache"
    if [ "$force" != "force" ] && [ "$((now - checked))" -lt 86400 ]; then
        return 0
    fi
    latest=$(borg_github_latest_version) || return 0
    [ -n "$latest" ] || return 0
    mkdir -p "$STATE_DIR" 2>/dev/null
    { printf 'CHECKED=%s\n' "$now"; printf 'INSTALLED=%s\n' "$cur"; printf 'LATEST=%s\n' "$latest"; } > "$cache"
    return 0
}

# Hinweistext aus dem Cache (kein Netz). Leer, wenn aktuell/unbekannt. Major-Sprung
# wird markiert (Repo-Format-Wechsel).
borg_update_cached_hint() {
    local cache cur latest cmaj lmaj
    cache=$(borg_update_cache_file)
    [ -f "$cache" ] || return 0
    cur=""; latest=""
    while IFS='=' read -r k v; do
        case "$k" in INSTALLED) cur=$v ;; LATEST) latest=$v ;; esac
    done < "$cache"
    [ -n "$cur" ] && [ -n "$latest" ] || return 0
    borg_version_lt "$cur" "$latest" || return 0
    cmaj=${cur%%.*}; lmaj=${latest%%.*}
    if [ "$cmaj" != "$lmaj" ]; then
        printf 'borg %s verfügbar (installiert: %s) – ACHTUNG: neue Hauptversion mit Repo-Format-Wechsel, nicht ungeprüft übernehmen. Update über ein Plugin-Release.' "$latest" "$cur"
    else
        printf 'borg %s verfügbar (installiert: %s). Update über ein Plugin-Release einplanen.' "$latest" "$cur"
    fi
}

# --- Persistenter Cache der Archivgrößen ------------------------------------
# Die Größe eines borg-Archivs ändert sich nach der Erstellung nie -> einmal
# ermittelt, dauerhaft gültig. Je Ziel eine Datei mit Zeilen
# <archive>\t<original_size>\t<deduplicated_size>. Genutzt für die Größenspalten
# auf der Snapshots-Seite (statt 0).
borg_size_cache_file() { printf '%s/borg_sizes_%s' "$STATE_DIR" "$1"; }

# Gecachte Größe: gibt "<orig>\t<dedup>" aus (rc 0) oder rc 1 (nicht gecacht).
borg_size_cached() {
    local f
    f=$(borg_size_cache_file "$1")
    [ -f "$f" ] || return 1
    awk -F'\t' -v a="$2" '$1==a { print $2 "\t" $3; f=1; exit } END { exit !f }' "$f"
}

# Größe persistent ablegen (nur, wenn noch nicht vorhanden – Archive sind unveränderlich).
borg_size_store() {
    local f
    borg_size_cached "$1" "$2" >/dev/null 2>&1 && return 0
    mkdir -p "$STATE_DIR" 2>/dev/null
    f=$(borg_size_cache_file "$1")
    printf '%s\t%s\t%s\n' "$2" "${3:-0}" "${4:-0}" >> "$f"
}

# Archivgröße per `borg info ::archive --json` holen -> "<orig>\t<dedup>" (rc 0) /
# rc 1. Nur den archives-Abschnitt parsen (nicht die Repo-Gesamtstats). Setzt
# geladenen borg-Kontext voraus.
borg_fetch_archive_size() {
    local js seg orig dedup
    js=$(borg_run info "::$1" --json 2>/dev/null) || return 1
    seg=${js#*\"archives\"}; seg=${seg%%\"cache\"*}
    orig=$(printf '%s' "$seg"  | tr ',{}' '\n\n\n' | sed -n 's/.*"original_size"[^0-9]*\([0-9][0-9]*\).*/\1/p'      | head -n1)
    dedup=$(printf '%s' "$seg" | tr ',{}' '\n\n\n' | sed -n 's/.*"deduplicated_size"[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -n1)
    [ -n "$orig" ] || return 1
    printf '%s\t%s' "$orig" "${dedup:-0}"
}

# Fehlende Archivgrößen für die vorhandenen Archive (BORG_EXISTING_ARCHIVES)
# nachziehen – für Archive, die vor diesem Feature erstellt wurden. Pro Lauf
# begrenzt ($1, Default 50), damit eine langsame Leitung den Lauf nicht blockiert;
# über mehrere Läufe füllt sich der Cache. Setzt geladenen borg-Kontext voraus.
borg_backfill_sizes() {
    local limit="${1:-50}" done_n=0 archive bsz bo bd
    while IFS= read -r archive; do
        [ -n "$archive" ] || continue
        [ "$done_n" -ge "$limit" ] && break
        borg_size_cached "$CURRENT_TARGET_ID" "$archive" >/dev/null 2>&1 && continue
        if bsz=$(borg_fetch_archive_size "$archive"); then
            IFS=$'\t' read -r bo bd <<< "$bsz"
            borg_size_store "$CURRENT_TARGET_ID" "$archive" "$bo" "$bd"
            done_n=$((done_n+1))
        fi
    done < <(printf '%s\n' "$BORG_EXISTING_ARCHIVES" | tr '|' '\n')
    [ "$done_n" -gt 0 ] && log "Borg: ${done_n} Archivgröße(n) nachgezogen ($(target_label "$CURRENT_TARGET_ID"))"
}

# CLI: Archive eines/aller borg-Ziele anzeigen (--borg-archives [<ziel-id>]).
# Reicht `borg list` durch (Archivname + Datum), je Ziel ein Abschnitt. Ersetzt die
# manuelle BORG_*-Env-Hantiererei. Rückgabe 0/1.
cli_borg_archives() {
    local only_target="${1:-}"
    local target_id found=0

    for target_id in "${TARGETS[@]}"; do
        [ "$(target_type "$target_id")" = "borg" ] || continue
        [ -n "$only_target" ] && [ "$target_id" != "$only_target" ] && continue
        found=1
        load_target_context "$target_id" || continue
        printf '== %s (%s) ==\n' "$(target_label "$target_id")" "$BORG_REPO"
        if ! borg_ensure_binary; then
            echo "  Borg-Binary nicht verfügbar."
            echo
            continue
        fi
        if ! borg_run list 2> >(log_stderr "borg list"); then
            echo "  (Repo nicht erreichbar – Passphrase/Netz/Repo prüfen)"
        fi
        echo
    done

    if [ "$found" -eq 0 ]; then
        if [ -n "$only_target" ]; then
            echo "Kein borg-Ziel mit ID $only_target." >&2
        else
            echo "Keine borg-Ziele konfiguriert." >&2
        fi
        return 1
    fi
    return 0
}

########################################
# Verify
########################################

verify_local_dataset() {
    local source_ds="$1"
    local repair="${2:-no}"
    local target
    local snap
    local name
    local latest
    local errors=0
    local historical_missing=0

    [ "$ENABLE_LOCAL_REPLICATION" = "yes" ] || return 0

    target=$(local_target_dataset "$source_ds")
    latest=$(latest_backup_snapshot_name "$source_ds")

    if ! zfs list "$target" >/dev/null 2>&1; then
        log "Verify Lokal: Ziel fehlt: $target"
        ((VERIFY_MISSING++))
        if [ "$repair" = "yes" ]; then
            log "Verify Lokal: Replikation wird gestartet: $source_ds"
            ((VERIFY_REPAIRS++))
            replicate_dataset_local "$source_ds"
            zfs list "$target" >/dev/null 2>&1 || return 1
        else
            return 1
        fi
    fi

    while read -r snap; do
        name="${snap#*@}"
        if ! zfs list -t snapshot "${target}@${name}" >/dev/null 2>&1; then
            ((VERIFY_MISSING++))
            if [ "$name" = "$latest" ]; then
                log "Verify Lokal: neuester Snapshot fehlt: ${target}@${name}"
                if [ "$repair" = "yes" ]; then
                    log "Verify Lokal: Snapshot wird nachrepliziert: ${target}@${name}"
                    ((VERIFY_REPAIRS++))
                    replicate_dataset_local "$source_ds"
                    if ! zfs list -t snapshot "${target}@${name}" >/dev/null 2>&1; then
                        ((errors++))
                    fi
                else
                    ((errors++))
                fi
            else
                log "Verify Lokal: historischer Snapshot fehlt: ${target}@${name}"
                ((VERIFY_WARNINGS++))
                historical_missing=1
            fi
        fi
    done < <(list_backup_snapshots "$source_ds")

    if [ "$repair" = "yes" ] && [ "$historical_missing" -eq 1 ]; then
        log "Verify Lokal: historische Lücke erfordert Neuaufbau: $target"
        ((VERIFY_REPAIRS++))
        if ! rebuild_local_target_from_all_snapshots "$source_ds" "$target"; then
            ((errors++))
        fi
    fi

    while read -r snap; do
        name="${snap#*@}"
        if ! source_snapshot_name_exists "$source_ds" "$name"; then
            log "Verify Lokal: zusätzlicher Snapshot: ${target}@${name}"
            ((VERIFY_EXTRA++))
            if [ "$repair" = "yes" ]; then
                log "Verify Lokal: zusätzlicher Snapshot wird gelöscht: ${target}@${name}"
                ((VERIFY_REPAIRS++))
                if zfs destroy "${target}@${name}"; then
                    ((LOCAL_DELETED_SNAPSHOTS++))
                else
                    ((errors++))
                fi
            else
                ((errors++))
            fi
        fi
    done < <(list_backup_snapshots "$target")

    [ "$errors" -eq 0 ]
}

verify_remote_dataset() {
    local source_ds="$1"
    local repair="${2:-no}"
    local target
    local snap
    local name
    local latest
    local errors=0
    local historical_missing=0

    [ "$ENABLE_REMOTE_REPLICATION" = "yes" ] || return 0

    target=$(remote_target_dataset "$source_ds")
    latest=$(latest_backup_snapshot_name "$source_ds")

    if ! remote_zfs_list "$target"; then
        log "Verify Remote: Ziel fehlt: ${REMOTE_HOST}:${target}"
        ((VERIFY_MISSING++))
        if [ "$repair" = "yes" ]; then
            log "Verify Remote: Replikation wird gestartet: $source_ds"
            ((VERIFY_REPAIRS++))
            replicate_dataset_remote "$source_ds"
            remote_zfs_list "$target" || return 1
        else
            return 1
        fi
    fi

    while read -r snap; do
        name="${snap#*@}"
        if ! remote_snapshot_exists "${target}@${name}"; then
            ((VERIFY_MISSING++))
            if [ "$name" = "$latest" ]; then
                log "Verify Remote: neuester Snapshot fehlt: ${REMOTE_HOST}:${target}@${name}"
                if [ "$repair" = "yes" ]; then
                    log "Verify Remote: Snapshot wird nachrepliziert: ${REMOTE_HOST}:${target}@${name}"
                    ((VERIFY_REPAIRS++))
                    replicate_dataset_remote "$source_ds"
                    if ! remote_snapshot_exists "${target}@${name}"; then
                        ((errors++))
                    fi
                else
                    ((errors++))
                fi
            else
                log "Verify Remote: historischer Snapshot fehlt: ${REMOTE_HOST}:${target}@${name}"
                ((VERIFY_WARNINGS++))
                historical_missing=1
            fi
        fi
    done < <(list_backup_snapshots "$source_ds")

    if [ "$repair" = "yes" ] && [ "$historical_missing" -eq 1 ]; then
        log "Verify Remote: historische Lücke erfordert Neuaufbau: ${REMOTE_HOST}:${target}"
        ((VERIFY_REPAIRS++))
        if ! rebuild_remote_target_from_all_snapshots "$source_ds" "$target" "Verify-Reparatur"; then
            ((errors++))
        fi
    fi

    while read -r snap; do
        name="${snap#*@}"
        if ! source_snapshot_name_exists "$source_ds" "$name"; then
            log "Verify Remote: zusätzlicher Snapshot: ${REMOTE_HOST}:${target}@${name}"
            ((VERIFY_EXTRA++))
            if [ "$repair" = "yes" ]; then
                log "Verify Remote: zusätzlicher Snapshot wird gelöscht: ${REMOTE_HOST}:${target}@${name}"
                ((VERIFY_REPAIRS++))
                if remote_destroy_snapshot "${target}@${name}"; then
                    ((REMOTE_DELETED_SNAPSHOTS++))
                else
                    ((errors++))
                fi
            else
                ((errors++))
            fi
        fi
    done < <(remote_list_backup_snapshots "$target")

    [ "$errors" -eq 0 ]
}

verify_source_dataset() {
    local ds="$1"
    local repair="${2:-no}"
    local count_stats="${3:-yes}"
    local snapshot_count

    snapshot_count=$(list_backup_snapshots "$ds" | wc -l)

    if [ "$snapshot_count" -eq 0 ]; then
        log "Verify Quelle: keine verwalteten Snapshots: $ds"
        if [ "$count_stats" = "yes" ]; then
            ((VERIFY_WARNINGS++))
            ((VERIFY_MISSING++))
        fi

        if [ "$repair" = "yes" ]; then
            log "Verify Quelle: aktueller Snapshot wird erstellt: $ds"
            [ "$count_stats" = "yes" ] && ((VERIFY_REPAIRS++))
            create_snapshot_set "$ds"
            snapshot_count=$(list_backup_snapshots "$ds" | wc -l)
        fi

        [ "$snapshot_count" -gt 0 ] || return 1
    fi

    return 0
}

verify_source_phase() {
    local repair="$1"
    local ds
    local index=0
    local total=0
    local checked=0
    local errors=0
    local warnings
    local repairs
    local missing
    local extra
    local -a datasets_list

    mapfile -t datasets_list < <(get_datasets)
    total=${#datasets_list[@]}

    VERIFY_WARNINGS=0
    VERIFY_REPAIRS=0
    VERIFY_MISSING=0
    VERIFY_EXTRA=0

    if [ "$repair" = "yes" ]; then
        log_phase "Verify Quelle + Reparatur"
    else
        log_phase "Verify Quelle"
    fi

    for ds in "${datasets_list[@]}"; do
        [ -n "$ds" ] || continue
        ((index++))
        ((checked++))
        console_status "Verify Quelle [${index}/${total}]: $ds"
        verify_source_dataset "$ds" "$repair" || ((errors++))
    done

    console_clear_status
    warnings="$VERIFY_WARNINGS"
    repairs="$VERIFY_REPAIRS"
    missing="$VERIFY_MISSING"
    extra="$VERIFY_EXTRA"

    if [ "$errors" -eq 0 ]; then
        console_success "Verify Quelle abgeschlossen: ${checked} geprüft, ${missing} fehlend, ${extra} extra, ${repairs} repariert, ${warnings} Warnung(en), keine Fehler"
    else
        console_error "Verify Quelle abgeschlossen: ${checked} geprüft, ${missing} fehlend, ${extra} extra, ${repairs} repariert, ${warnings} Warnung(en), ${errors} Fehler"
    fi

    return "$errors"
}

verify_local_phase() {
    local repair="${1:-no}"
    local only_target="${2:-}"
    local ds
    local target_id
    local index=0
    local total=0
    local checked=0
    local errors=0
    local warnings
    local repairs
    local missing
    local extra
    local -a datasets_list

    mapfile -t datasets_list < <(get_datasets)
    total=${#datasets_list[@]}

    if [ "$(target_enabled_count local)" -eq 0 ]; then
        console_warn "Verify Lokal übersprungen: kein aktives lokales Ziel"
        return 0
    fi

    if [ "$repair" = "yes" ]; then
        log_phase "Verify Lokal + Reparatur"
    else
        log_phase "Verify Lokal"
    fi

    VERIFY_WARNINGS=0
    VERIFY_REPAIRS=0
    VERIFY_MISSING=0
    VERIFY_EXTRA=0

    for target_id in "${TARGETS[@]}"; do
        target_enabled "$target_id" || continue
        [ "$(target_type "$target_id")" = "local" ] || continue
        [ -n "$only_target" ] && [ "$target_id" != "$only_target" ] && continue
        load_target_context "$target_id" || continue
        index=0
        for ds in "${datasets_list[@]}"; do
            [ -n "$ds" ] || continue
            ((index++))
            console_status "Verify Lokal $(target_label "$target_id") [${index}/${total}]: $ds"
            verify_source_dataset "$ds" no no || continue
            ((checked++))
            verify_local_dataset "$ds" "$repair" || {
                ((errors++))
            }
        done
    done

    console_clear_status
    warnings="$VERIFY_WARNINGS"
    repairs="$VERIFY_REPAIRS"
    missing="$VERIFY_MISSING"
    extra="$VERIFY_EXTRA"
    if [ "$errors" -eq 0 ]; then
        console_success "Verify Lokal abgeschlossen: ${checked} geprüft, ${missing} fehlend, ${extra} extra, ${repairs} repariert, ${warnings} Warnung(en), keine Fehler"
    else
        console_error "Verify Lokal abgeschlossen: ${checked} geprüft, ${missing} fehlend, ${extra} extra, ${repairs} repariert, ${warnings} Warnung(en), ${errors} Fehler"
    fi

    return "$errors"
}

verify_remote_phase() {
    local repair="${1:-no}"
    local only_target="${2:-}"
    local ds
    local target_id
    local index=0
    local total=0
    local checked=0
    local errors=0
    local warnings=0
    local repairs=0
    local missing=0
    local extra=0
    local -a datasets_list

    mapfile -t datasets_list < <(get_datasets)
    total=${#datasets_list[@]}

    if [ "$(target_enabled_count remote)" -eq 0 ]; then
        console_warn "Verify Remote übersprungen: kein aktives Remote-Ziel"
        return 0
    fi

    if [ "$repair" = "yes" ]; then
        log_phase "Verify Remote + Reparatur"
    else
        log_phase "Verify Remote"
    fi

    VERIFY_WARNINGS=0
    VERIFY_REPAIRS=0
    VERIFY_MISSING=0
    VERIFY_EXTRA=0

    for target_id in "${TARGETS[@]}"; do
        target_enabled "$target_id" || continue
        [ "$(target_type "$target_id")" = "remote" ] || continue
        [ -n "$only_target" ] && [ "$target_id" != "$only_target" ] && continue
        load_target_context "$target_id" || continue

        if ! ensure_remote_ready; then
            console_error "Remote Host nicht erreichbar: $REMOTE_HOST"
            ((errors++))
            continue
        fi

        if ! remote_ssh "command -v zfs >/dev/null 2>&1"; then
            console_error "Remote Host nicht erreichbar oder ZFS fehlt: $REMOTE_HOST"
            ((errors++))
            continue
        fi

        index=0
        for ds in "${datasets_list[@]}"; do
            [ -n "$ds" ] || continue
            ((index++))
            console_status "Verify Remote $(target_label "$target_id") [${index}/${total}]: $ds"
            verify_source_dataset "$ds" no no || continue
            ((checked++))
            verify_remote_dataset "$ds" "$repair" || {
                ((errors++))
            }
        done
    done

    console_clear_status
    warnings="$VERIFY_WARNINGS"
    repairs="$VERIFY_REPAIRS"
    missing="$VERIFY_MISSING"
    extra="$VERIFY_EXTRA"
    if [ "$errors" -eq 0 ]; then
        console_success "Verify Remote abgeschlossen: ${checked} geprüft, ${missing} fehlend, ${extra} extra, ${repairs} repariert, ${warnings} Warnung(en), keine Fehler"
    else
        console_error "Verify Remote abgeschlossen: ${checked} geprüft, ${missing} fehlend, ${extra} extra, ${repairs} repariert, ${warnings} Warnung(en), ${errors} Fehler"
    fi

    return "$errors"
}

# Verify eines borg-Ziels für ein Dataset (rein meldend, ändert nichts). Pendant zu
# verify_remote_dataset: fehlende Archive (je verwaltetem Quell-Snapshot) und
# zusätzliche Archive (im Namespace ohne Quell-Snapshot). Neuestes fehlendes Archiv
# = Fehler, historisches = Warnung. Setzt einen geladenen borg-Kontext + geladene
# Archivliste (borg_load_existing_archives) voraus.
verify_borg_dataset() {
    local source_ds="$1"
    local snap name latest archive prefix errors=0
    local present="|"

    [ "$ENABLE_BORG_REPLICATION" = "yes" ] || return 0
    latest=$(latest_backup_snapshot_name "$source_ds")
    prefix=$(borg_dataset_prefix "$source_ds")

    # Fehlende Archive je verwaltetem Quell-Snapshot.
    while read -r snap; do
        name="${snap#*@}"
        [ -n "$name" ] || continue
        present="${present}${name}|"
        archive=$(borg_archive_name "$source_ds" "$name")
        if ! borg_archive_exists "$archive"; then
            ((VERIFY_MISSING++))
            if [ "$name" = "$latest" ]; then
                log "Verify Borg: neuestes Archiv fehlt: ${archive}"
                ((errors++))
            else
                log "Verify Borg: historisches Archiv fehlt: ${archive}"
                ((VERIFY_WARNINGS++))
            fi
        fi
    done < <(list_backup_snapshots "$source_ds")

    # Zusätzliche Archive im Namespace ohne (aktuellen) Quell-Snapshot.
    while IFS= read -r archive; do
        [ -n "$archive" ] || continue
        case "$archive" in "${prefix}"*) ;; *) continue ;; esac
        name="${archive#"${prefix}"}"
        case "$present" in *"|${name}|"*) continue ;; esac
        log "Verify Borg: zusätzliches Archiv (kein Quell-Snapshot): ${archive}"
        ((VERIFY_EXTRA++))
        ((errors++))
    done < <(printf '%s\n' "$BORG_EXISTING_ARCHIVES" | tr '|' '\n')

    [ "$errors" -eq 0 ]
}

# Verify-Phase über alle (oder ein) borg-Ziel(e). $1 = repair (ignoriert – Verify
# meldet nur, das Angleichen macht der normale Lauf), $2 = nur diese Ziel-ID.
verify_borg_phase() {
    local _repair="${1:-no}"
    local only_target="${2:-}"
    local ds target_id index=0 total=0 checked=0 errors=0
    local warnings missing extra
    local -a datasets_list

    mapfile -t datasets_list < <(get_datasets)
    total=${#datasets_list[@]}

    if [ "$(target_enabled_count borg)" -eq 0 ]; then
        console_warn "Verify Borg übersprungen: kein aktives borg-Ziel"
        return 0
    fi

    log_phase "Verify Borg"
    VERIFY_WARNINGS=0
    VERIFY_REPAIRS=0
    VERIFY_MISSING=0
    VERIFY_EXTRA=0

    for target_id in "${TARGETS[@]}"; do
        target_enabled "$target_id" || continue
        [ "$(target_type "$target_id")" = "borg" ] || continue
        [ -n "$only_target" ] && [ "$target_id" != "$only_target" ] && continue
        load_target_context "$target_id" || continue

        if ! borg_ensure_binary || ! borg_run info >/dev/null 2>&1; then
            console_error "Borg-Repo nicht erreichbar: $BORG_REPO"
            ((errors++))
            continue
        fi
        borg_load_existing_archives

        index=0
        for ds in "${datasets_list[@]}"; do
            [ -n "$ds" ] || continue
            ((index++))
            console_status "Verify Borg $(target_label "$target_id") [${index}/${total}]: $ds"
            verify_source_dataset "$ds" no no || continue
            ((checked++))
            verify_borg_dataset "$ds" || ((errors++))
        done
    done

    console_clear_status
    warnings="$VERIFY_WARNINGS"
    missing="$VERIFY_MISSING"
    extra="$VERIFY_EXTRA"
    if [ "$errors" -eq 0 ]; then
        console_success "Verify Borg abgeschlossen: ${checked} geprüft, ${missing} fehlend, ${extra} extra, ${warnings} Warnung(en), keine Fehler"
    else
        console_error "Verify Borg abgeschlossen: ${checked} geprüft, ${missing} fehlend, ${extra} extra, ${warnings} Warnung(en), ${errors} Fehler"
    fi

    return "$errors"
}

verify() {
    local scope="${1:-all}"
    local repair="${2:-no}"
    local ask_repair="${3:-no}"
    local errors=0
    local datasets
    local answer

    case "$scope" in
        yes|no)
            repair="$scope"
            ask_repair="${2:-no}"
            scope="all"
            ;;
    esac

    if [ "$repair" = "yes" ]; then
        console_info "Verify repariert nicht mehr direkt. Der normale Snapshotlauf gleicht aktive Ziele automatisch an."
        repair="no"
    fi
    ask_repair="no"

    datasets=$(get_datasets | wc -l | tr -d ' ')

    case "$scope" in
        all)
            verify_source_phase "$repair" || errors=$((errors+$?))
            verify_local_phase "$repair" || errors=$((errors+$?))
            verify_remote_phase "$repair" || errors=$((errors+$?))
            verify_borg_phase "$repair" || errors=$((errors+$?))
            ;;
        source)
            verify_source_phase "$repair" || errors=$((errors+$?))
            ;;
        local)
            verify_local_phase "$repair" || errors=$((errors+$?))
            ;;
        remote)
            verify_remote_phase "$repair" || errors=$((errors+$?))
            ;;
        borg)
            verify_borg_phase "$repair" || errors=$((errors+$?))
            ;;
        *)
            # Einzelnes Ziel (Ziel-ID als Bereich): passende Phase mit Filter.
            if target_array_contains "$scope"; then
                case "$(target_type "$scope")" in
                    local)  verify_local_phase  "$repair" "$scope" || errors=$((errors+$?)) ;;
                    remote) verify_remote_phase "$repair" "$scope" || errors=$((errors+$?)) ;;
                    borg)   verify_borg_phase   "$repair" "$scope" || errors=$((errors+$?)) ;;
                    *) console_error "Unbekannter Zieltyp: $scope"; return 1 ;;
                esac
            else
                console_error "Unbekannter Verify-Bereich: $scope"
                return 1
            fi
            ;;
    esac

    console_clear_status
    if [ "$errors" -eq 0 ]; then
        console_success "Verify abgeschlossen: ${scope}, ${datasets} Dataset(s), keine Fehler"
    else
        console_error "Verify abgeschlossen: ${scope}, ${datasets} Dataset(s), ${errors} Fehler"
    fi

    if [ "$repair" != "yes" ] && [ "$ask_repair" = "yes" ] && [ "$errors" -gt 0 ]; then
        echo
        read -rp "Es wurden reparierbare Unstimmigkeiten gefunden. Jetzt reparieren? [y/N]: " answer

        case "$answer" in
            y|Y|yes|YES|ja|JA)
                verify "$scope" yes no
                return $?
                ;;
        esac
    fi

    [ "$errors" -eq 0 ]
}

show_help() {

cat <<EOF

ZFS Backup Framework
Version : ${SCRIPT_VERSION}

Verwendung:

  zfs-backup.sh
      Snapshotlauf starten

  zfs-backup.sh --help
      Diese Hilfe anzeigen

  zfs-backup.sh --version
      Versionsnummer anzeigen

  zfs-backup.sh --status [--json]
      Status anzeigen. Mit --json maschinenlesbar fürs GUI-Dashboard.
      Bei laufendem Backup enthält das JSON ein progress-Objekt (Phase).

  zfs-backup.sh --gui-init --json
      GUI-intern: Status, Kapazität (cached), Schema, Konfigwerte und Ziele in
      EINEM JSON-Objekt (ein Aufruf statt fünf beim Seitenaufbau).

  zfs-backup.sh --check-stale
      Prüft, ob das letzte erfolgreiche Backup älter als STALE_AFTER_HOURS ist,
      und meldet das einmal per Unraid-Notification (Wächter; 0 = aus).

  zfs-backup.sh --log-tail [N]
      Die letzten N Zeilen (Standard 50) des heutigen Logs ausgeben
      (für die Live-Log-Ansicht der GUI).

  zfs-backup.sh --log-follow [N]
      Dem heutigen Log live folgen (jede neue Zeile sofort ausgeben);
      optionales N = Startzeilen (Standard 1, 0 = nur neue). Blockiert bis
      zum Verbindungsabbruch. Quelle für die Live-Ansicht der GUI
      (Server-Sent-Events).

  zfs-backup.sh --progress-follow
      Dem Lauf-Fortschritt live folgen: bei jeder Phasen-/Detail-Änderung
      eine Zeile (Phase, Detail, Start, Aktualisiert, PID; TAB-getrennt).
      Endet, wenn kein Lauf mehr aktiv ist. Quelle für die Live-Detail-
      anzeige der GUI (Push).

  zfs-backup.sh --config-check
      Konfiguration prüfen

  zfs-backup.sh --config-schema [--json]
      Konfigurations-Schema (Gruppe, Name, Typ, Beschreibung) ausgeben.
      Mit --json maschinenlesbar als Datenquelle für die GUI.

  zfs-backup.sh --get-config [OPTION] [--json]
      Aktuelle Konfigurationswerte lesen. Mit OPTION den Einzelwert (Text,
      mit --json typisiert); ohne OPTION alle Werte als JSON-Objekt fürs
      GUI-Formular. Etwaige Secrets würden maskiert ausgegeben.

  zfs-backup.sh --set-config <OPTION> <WERT>
      Eine Konfigurationsoption über die normale Validierung setzen und
      speichern. Mehrwertige Arrays als ein Argument in Anführungszeichen.

  zfs-backup.sh --simulate
      Snapshotlauf simulieren

  zfs-backup.sh --datasets [--json]
      Datasets nach Include/Exclude anzeigen. Mit --json maschinenlesbar.

  zfs-backup.sh --snapshots [--json]
      Snapshotübersicht anzeigen. Mit --json maschinenlesbar.

  zfs-backup.sh --capacity [--json] [--cached]
      Pool-Auslastung (belegt/frei/%) je Quelle und Ziel. Mit --cached den am
      letzten Lauf erfassten Stand aus dem State (weckt keine Platte); sonst live.

  zfs-backup.sh --dataset-snapshots <dataset> [<scope>] [--json]
      Verwaltete Snapshots eines Datasets mit vollem Namen, Größe und Erstellzeit
      aus dem am Lauf-Ende erfassten State (kein Live-zfs, weckt keine Platte).
      <scope> = "source" (Default) oder eine Ziel-ID.

  zfs-backup.sh --snapshot-tree [--json] [--cached]
      Scope-Übersicht: Quelle und jedes aktive Ziel mit Dataset-Zählungen und
      Größen (Grundlage der aufklappbaren Snapshots-Seite). Mit --cached den am
      letzten Lauf erfassten Stand aus dem State (weckt keine Platte).

  zfs-backup.sh --snapshot-ls <dataset> <snapshot> <scope> [unterpfad]
      Verzeichnisinhalt eines Snapshots als JSON (Datei-Browser). <scope> =
      "source" oder eine Ziel-ID. Liest ins Dataset (.zfs/snapshot) und WECKT
      ggf. die Platte/den Remote – bewusste Nutzeraktion.

  zfs-backup.sh --snapshot-cat <dataset> <snapshot> <scope> <unterpfad>
      Inhalt EINER Datei aus einem Snapshot auf stdout (Download/Vorschau).

  zfs-backup.sh --snapshot-restore <dataset> <snapshot> <scope> <unterpfad> [progress]
      Datei/Ordner aus einem Snapshot in den Restore-Ordner des QUELL-Datasets
      (<quell-mountpoint>/_restore/<snapshot>/) zurückholen (nicht destruktiv,
      überschreibt nie). <scope> = source (Quell-Snapshot) ODER eine Ziel-ID
      (Replikat); bei einem lokalen/Remote-Ziel ist <dataset> das Ziel-Dataset,
      bei einem borg-Ziel das QUELL-Dataset (borg hat keine Ziel-Datasets; aus dem
      Archiv <dataset>__<snapshot> wird per `borg extract` geholt). Vorher wird
      geprüft, dass das Quell-Dataset existiert. Leerer <unterpfad> = ganzer
      Snapshot. Remote-Ziele werden dafür ggf. per WOL geweckt. Mit dem optionalen
      5. Argument "progress" meldet der Lauf den Fortschritt (FORTSCHRITT <pct> …
      ZIEL <pfad>) – für die GUI; sonst nur der Zielpfad.

  zfs-backup.sh --targets [--json]
      Replikationsziele anzeigen. Mit --json maschinenlesbar für die GUI.

  zfs-backup.sh --add-target <label> <local|remote|borg> <ziel> [ssh-host]
      Neues Replikationsziel anlegen. Die ID wird automatisch numerisch
      vergeben; <label> ist der frei wählbare Anzeigename. Typ-Defaults werden
      automatisch ergänzt. <ziel> ist bei local/remote das Basis/Ziel-Dataset,
      bei borg die Repo-URL (z. B. ssh://user@host:23/./backups/nas1). Die
      Borg-Passphrase danach per --edit-target <id> PASSPHRASE setzen.

  zfs-backup.sh --delete-target <id>
      Replikationsziel entfernen. Die verbleibenden Ziele werden danach
      lückenlos neu nummeriert (aus „1,3" wird „1,2").

  zfs-backup.sh --edit-target <id> <feld> <wert>
      Ein Feld eines Ziels ändern (LABEL, ENABLED, BASE_DATASET; remote
      zusätzlich HOST, SSH_OPTIONS, WAKE_ON_LAN, WAKE_MAC,
      WAKE_TIMEOUT_SECONDS, WAKE_CHECK_INTERVAL_SECONDS, RETRY_ATTEMPTS,
      RETRY_WAIT_SECONDS; borg zusätzlich REPO, PASSPHRASE, SSH_OPTIONS,
      COMPACT_EVERY).

  zfs-backup.sh --cleanup-orphans [<ziel-id>] [--yes]
      Verwaiste Datasets aufräumen: verwaiste ZIEL-Datasets (Quelle gelöscht oder
      außer Betrieb) werden ganz gelöscht (zfs destroy -r); außer Betrieb genommene
      QUELL-Datasets (aus INCLUDES gefallen oder via EXCLUDES) behalten ihr Dataset,
      nur ihre verbliebenen verwalteten Snapshots werden entfernt. Optionale
      <ziel-id> beschränkt auf ein Ziel (ohne = alle Ziele + Quelle). OHNE --yes nur
      Dry-Run (zeigt, was passieren würde); MIT --yes wird ausgeführt. Ein normaler
      Lauf löscht NIE automatisch – er meldet nur.

  zfs-backup.sh --test-target <id>
      Erreichbarkeit eines Ziels prüfen (lokal: zfs list; remote: ggf. wecken
      und remote zfs list; borg: Binary, Cache-Verzeichnis und `borg info`).

  zfs-backup.sh --borg-archives [<ziel-id>]
      Archive der borg-Ziele anzeigen (borg list). Ohne ID alle borg-Ziele,
      sonst nur das angegebene. Ersetzt die manuelle BORG_*-Env-Eingabe.

  zfs-backup.sh --borg-check-update
      Informativ prüfen, ob eine neuere borg-Version verfügbar ist (GitHub).
      Kein Auto-Update – borg wird über ein Plugin-Release aktualisiert. Der
      normale Lauf aktualisiert den Hinweis ohnehin (gedrosselt, 1×/Tag).

  zfs-backup.sh --reorder-targets <id,id,...>
      Backup-Reihenfolge der Ziele neu festlegen. Erwartet ALLE vorhandenen
      Ziel-IDs genau einmal in der gewünschten Reihenfolge (erstes Ziel zuerst).
      Die IDs werden danach lückenlos = Position neu vergeben.

  zfs-backup.sh --move-target <id> <up|down>
      Ein Ziel um eine Position nach oben/unten verschieben (Auf-/Ab-Buttons).

  zfs-backup.sh --reset-statistics --yes
      Gespeicherte Laufstatistiken löschen.

  zfs-backup.sh --reset-run-status --yes
      Letzten Erfolg und letzten Fehler zurücksetzen.

  zfs-backup.sh --delete-logs --yes
      Alle Logdateien löschen.

  zfs-backup.sh --thin-history --yes
      Snapshot-Historie ausdünnen: je aktivem Typ (Retention > 0) einen frischen
      Anker erzeugen (hourly/daily/weekly/monthly/yearly), nur diese behalten,
      aktive Ziele angleichen.

  zfs-backup.sh --delete-managed-snapshots --yes
      Alle verwalteten Snapshots (Prefix) auf Quelle und aktiven Zielen
      löschen. Keine Datasets, Verzeichnisse oder Dateien.

  zfs-backup.sh --verify
      Quelle, lokale Replikation und Remote-Replikation prüfen

  zfs-backup.sh --verify-repair
      Kompatibilitätsalias für --verify. Reparatur läuft über den normalen Snapshotlauf.

  zfs-backup.sh --verify-source
      Quelle prüfen

  zfs-backup.sh --verify-source-repair
      Kompatibilitätsalias für --verify-source

  zfs-backup.sh --verify-local
      Lokale Replikation prüfen

  zfs-backup.sh --verify-local-repair
      Kompatibilitätsalias für --verify-local

  zfs-backup.sh --verify-remote
      Remote-Replikation prüfen

  zfs-backup.sh --verify-remote-repair
      Kompatibilitätsalias für --verify-remote

  zfs-backup.sh --verify-borg
      Borg-Ziele prüfen: je verwaltetem Snapshot das Archiv und zusätzliche
      Archive (meldend, ändert nichts).

  zfs-backup.sh --verify-target <ziel-id>
      Nur die Snapshots eines einzelnen Ziels prüfen (lokal/remote/borg)

  zfs-backup.sh --verbose --run
      Detailausgabe zusätzlich zum Logfile anzeigen

Maintenance:

  Alle verwalteten Snapshots löschen
      Löscht ausschließlich Snapshots mit SNAPSHOT_PREFIX auf Quelle und aktiven
      Zielen. Datasets, Verzeichnisse und Dateien werden nicht gelöscht.

  Snapshot-Historie ausdünnen
      Erzeugt je aktivem Snapshot-Typ (Retention > 0) einen frischen Anker mit
      aktuellem Stand (hourly/daily/weekly/monthly/yearly), behält nur diese auf
      der Quelle und gleicht aktive Ziele danach an.

Config:

  ENABLE_SOURCE_PRUNING="yes"
      Pruning auf den Quell-Datasets aktivieren oder deaktivieren

  TARGETS=(...)
      Replikationsziele. Pflege über die --*-target-Befehle.

  TARGET_<id>_TYPE="local|remote"
      Zieltyp.

  TARGET_<id>_BASE_DATASET="backups"
      Lokales oder Remote-Basis-Dataset.

  Remote-Ziele nutzen zusätzlich HOST, SSH_OPTIONS, WAKE_* und RETRY_*.

EOF

}

########################################
# CLI
########################################

# Verlangt für destruktive CLI-Aktionen ein explizites --yes (bestätigt die
# Aktion). Die zentralen assert_safe_*-Prüfungen bleiben davon unberührt
# (--yes umgeht KEINE Sicherheitsprüfung).
require_yes() {
    if [ "${CLI_YES:-0}" -ne 1 ]; then
        echo "Destruktive Aktion: zur Ausführung bitte --yes anhängen." >&2
        return 1
    fi
    return 0
}

handle_cli() {

    local arg
    CLI_FORMAT="text"
    CLI_YES=0
    CLI_CACHED=0
    CLI_ARGS=()
    for arg in "$@"; do
        case "$arg" in
            --json) CLI_FORMAT="json" ;;
            --yes) CLI_YES=1 ;;
            --cached) CLI_CACHED=1 ;;
            *) CLI_ARGS+=("$arg") ;;
        esac
    done
    CLI_CMD="${CLI_ARGS[0]:-}"

    case "$CLI_CMD" in

        --help)

            show_help
            exit 0
            ;;

        --run)

            return 0
            ;;

        --version)

            echo "$SCRIPT_VERSION"
            exit 0
            ;;

        --status)

            if [ "$CLI_FORMAT" = "json" ]; then
                status_json
            else
                show_status
            fi
            exit 0
            ;;

        --gui-init)

            # Aggregat für den GUI-Seitenaufbau (ein Aufruf statt fünf).
            gui_init_json
            exit 0
            ;;

        --check-stale)

            # Wächter: meldet einmal, wenn das letzte erfolgreiche Backup älter
            # als STALE_AFTER_HOURS ist. Vom Plugin-Wächter-Cron aufgerufen.
            check_stale
            exit 0
            ;;

        --log-tail)

            local tail_n="${CLI_ARGS[1]:-50}"
            case "$tail_n" in ''|*[!0-9]*) tail_n=50 ;; esac
            [ -f "$LOG_FILE" ] && tail -n "$tail_n" "$LOG_FILE"
            exit 0
            ;;

        --log-follow)

            # Folgt dem heutigen Logfile live und gibt jede neue Zeile sofort aus
            # (für die Live-Ansicht der GUI per Server-Sent-Events). Optionales N
            # = Anzahl Startzeilen (Standard 1; 0 = nur neue Zeilen). Blockiert,
            # bis der Aufrufer die Verbindung schließt; -F wartet auch, falls die
            # Datei erst noch entsteht. Reine Log-Ausgabe, keine ZFS-/Backup-Logik.
            local fol_n="${CLI_ARGS[1]:-1}"
            case "$fol_n" in ''|*[!0-9]*) fol_n=1 ;; esac
            exec tail -n "$fol_n" -F "$LOG_FILE" 2>/dev/null
            ;;

        --progress-follow)

            # Folgt dem Fortschritts-State live: gibt bei jeder Änderung von
            # Phase/Detail SOFORT eine Zeile aus (Felder TAB-getrennt:
            # PHASE \t DETAIL \t STARTED \t UPDATED \t PID). Beendet sich, wenn
            # kein Lauf mehr aktiv ist (run_progress weg oder PID tot) – der
            # Aufrufer (GUI-SSE) erkennt das Ende am Verbindungsschluss. Quelle
            # für die Live-Detailanzeige (Push), ohne das Logfile zu fluten.
            # Hinweis: `sleep` ist ein Fork-Punkt, bash flusht stdout davor →
            # jede Zeile geht ohne Pufferverzögerung an die Pipe.
            {
                local pf="${STATE_DIR}/run_progress"
                local last="" key phase detail started updated pid waited=0 k v
                local wait_forever=0
                [ "${CLI_ARGS[1]:-}" = "wait" ] && wait_forever=1
                # Auf die run_progress-Datei warten. Standard: kurze Grace (~5 s,
                # Race zwischen Lock und 1. write_progress). Mit "wait": unbegrenzt,
                # bis ein Lauf beginnt – für die offene Statusseite, die auch extern
                # (Cron/CLI) gestartete Läufe live zeigen soll. Der aufrufende
                # SSE-Worker beendet diesen Prozess bei Client-Disconnect.
                while [ ! -f "$pf" ]; do
                    if [ "$wait_forever" = "1" ]; then
                        sleep 1
                    else
                        [ "$waited" -ge 50 ] && break
                        sleep 0.1
                        waited=$((waited + 1))
                    fi
                done
                while [ -f "$pf" ]; do
                    phase=""; detail=""; started=""; updated=""; updated_epoch=""; pid=""
                    while IFS='=' read -r k v; do
                        case "$k" in
                            PHASE)   phase=$v ;;
                            DETAIL)  detail=$v ;;
                            STARTED) started=$v ;;
                            UPDATED) updated=$v ;;
                            UPDATED_EPOCH) updated_epoch=$v ;;
                            PID)     pid=$v ;;
                        esac
                    done < "$pf"
                    [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && break
                    key="${phase}"$'\t'"${detail}"
                    if [ "$key" != "$last" ]; then
                        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                            "$phase" "$detail" "$started" "$updated" "$updated_epoch" "$pid"
                        last="$key"
                    fi
                    sleep 0.3
                done
            } 2>/dev/null
            exit 0
            ;;

        --targets)

            if [ "$CLI_FORMAT" = "json" ]; then
                targets_json
            else
                show_targets_overview
            fi
            exit 0
            ;;

        --config-check)

            config_check
            exit 0
            ;;

        --config-schema)

            if [ "$CLI_FORMAT" = "json" ]; then
                config_schema_json
            else
                config_schema_text
            fi
            exit 0
            ;;

        --borg-providers)

            # Anbieter-Vorlagen für borg-Ziele (Datenquelle der GUI). Reines JSON.
            borg_providers_json
            exit 0
            ;;

        --set-config)

            if [ "${#CLI_ARGS[@]}" -lt 3 ]; then
                echo "Verwendung: zfs-backup.sh --set-config <OPTION> <WERT>" >&2
                exit 1
            fi
            if [ "${CLI_ARGS[1]}" = "TARGETS" ]; then
                echo "TARGETS wird über die Ziel-Befehle gepflegt (--add-target u. a.)." >&2
                exit 1
            fi
            if ! config_option_exists "${CLI_ARGS[1]}"; then
                echo "Unbekannte Option: ${CLI_ARGS[1]}" >&2
                exit 1
            fi
            set_config_option_value "${CLI_ARGS[1]}" "${CLI_ARGS[2]}"
            exit $?
            ;;

        --get-config)

            if [ "${#CLI_ARGS[@]}" -ge 2 ]; then
                if ! config_option_exists "${CLI_ARGS[1]}"; then
                    echo "Unbekannte Option: ${CLI_ARGS[1]}" >&2
                    exit 1
                fi
                if [ "$CLI_FORMAT" = "json" ]; then
                    config_value_json "${CLI_ARGS[1]}"
                    echo
                elif config_option_is_secret "${CLI_ARGS[1]}"; then
                    local secret_var="${CLI_ARGS[1]}"
                    [ -n "${!secret_var}" ] && echo "***" || echo ""
                else
                    config_option_value "${CLI_ARGS[1]}"
                fi
                exit 0
            fi
            config_values_json
            exit 0
            ;;

        --add-target)

            if [ "${#CLI_ARGS[@]}" -lt 4 ]; then
                echo "Verwendung: zfs-backup.sh --add-target <label> <local|remote|borg> <ziel> [ssh-host]" >&2
                echo "  (Die ID wird automatisch vergeben; <label> ist der Anzeigename. <ziel> = Dataset bzw. bei borg die Repo-URL.)" >&2
                exit 1
            fi
            if target_create "${CLI_ARGS[1]}" "${CLI_ARGS[2]}" "${CLI_ARGS[3]}" "${CLI_ARGS[4]:-}"; then
                console_success "Ziel hinzugefügt: ${CLI_ARGS[1]} (ID ${TARGETS[${#TARGETS[@]}-1]})"
                exit 0
            fi
            exit 1
            ;;

        --delete-target)

            if [ "${#CLI_ARGS[@]}" -lt 2 ]; then
                echo "Verwendung: zfs-backup.sh --delete-target <id>" >&2
                exit 1
            fi
            if target_delete "${CLI_ARGS[1]}"; then
                console_success "Ziel gelöscht: ${CLI_ARGS[1]}"
                exit 0
            fi
            exit 1
            ;;

        --edit-target)

            if [ "${#CLI_ARGS[@]}" -lt 4 ]; then
                echo "Verwendung: zfs-backup.sh --edit-target <id> <FELD> <WERT>" >&2
                exit 1
            fi
            if target_edit_field "${CLI_ARGS[1]}" "${CLI_ARGS[2]}" "${CLI_ARGS[3]}"; then
                console_success "Gespeichert: ${CLI_ARGS[1]} ${CLI_ARGS[2]}"
                exit 0
            fi
            exit 1
            ;;

        --test-target)

            if [ "${#CLI_ARGS[@]}" -lt 2 ]; then
                echo "Verwendung: zfs-backup.sh --test-target <id>" >&2
                exit 1
            fi
            target_test "${CLI_ARGS[1]}"
            exit $?
            ;;

        --borg-archives)

            # Archive eines/aller borg-Ziele anzeigen (optional auf eine ID beschränkt).
            cli_borg_archives "${CLI_ARGS[1]:-}"
            exit $?
            ;;

        --borg-check-update)

            # borg-Versions-Check erzwingen (fragt GitHub) und das Ergebnis zeigen.
            if [ "$(target_enabled_count borg)" -eq 0 ]; then
                echo "Kein aktives borg-Ziel – Versions-Check übersprungen." >&2
                exit 0
            fi
            borg_update_refresh force
            uhint=$(borg_update_cached_hint)
            if [ -n "$uhint" ]; then
                console_warn "$uhint"
            else
                console_success "borg ist aktuell ($(borg_installed_version))."
            fi
            exit 0
            ;;

        --reorder-targets)

            if [ "${#CLI_ARGS[@]}" -lt 2 ]; then
                echo "Verwendung: zfs-backup.sh --reorder-targets <id,id,...>" >&2
                echo "  (Alle vorhandenen Ziel-IDs in der gewünschten Backup-Reihenfolge; erstes zuerst.)" >&2
                exit 1
            fi
            if target_reorder "${CLI_ARGS[1]}"; then
                console_success "Reihenfolge gespeichert: $(targets_label_order)"
                exit 0
            fi
            exit 1
            ;;

        --move-target)

            if [ "${#CLI_ARGS[@]}" -lt 3 ]; then
                echo "Verwendung: zfs-backup.sh --move-target <id> <up|down>" >&2
                exit 1
            fi
            if target_move "${CLI_ARGS[1]}" "${CLI_ARGS[2]}"; then
                console_success "Ziel verschoben. Neue Reihenfolge: $(targets_label_order)"
                exit 0
            fi
            exit 1
            ;;

        --reset-statistics)

            require_yes || exit 1
            reset_statistics_apply
            exit 0
            ;;

        --reset-run-status)

            require_yes || exit 1
            reset_run_status_apply
            exit 0
            ;;

        --delete-logs)

            require_yes || exit 1
            delete_logs_apply
            exit 0
            ;;

        --thin-history)

            require_yes || exit 1
            thin_snapshot_history_apply
            exit $?
            ;;

        --delete-managed-snapshots)

            require_yes || exit 1
            delete_all_managed_snapshots_apply
            exit $?
            ;;

        --cleanup-orphans)

            # Verwaiste Ziel-Datasets aufräumen. Optionale Ziel-ID als 1. Argument
            # (leer = alle Ziele). OHNE --yes nur Dry-Run (zeigt, was gelöscht
            # würde); MIT --yes tatsächlich löschen. Ein normaler Lauf löscht NIE.
            local co_target="${CLI_ARGS[1]:-}"
            if [ -n "$co_target" ] && ! target_id_is_valid "$co_target"; then
                echo "FEHLER: ungültige Ziel-ID: $co_target" >&2
                exit 1
            fi
            if [ "${CLI_YES:-0}" -eq 1 ]; then
                maintenance_cleanup_orphans yes "$co_target"
            else
                maintenance_cleanup_orphans no "$co_target"
            fi
            exit $?
            ;;

        --simulate)

            simulate
            exit 0
            ;;

        --datasets)

            if [ "$CLI_FORMAT" = "json" ]; then
                # --cached: Stand vom letzten Lauf aus dem State (kein zfs).
                if [ "$CLI_CACHED" -eq 1 ] && [ -s "${STATE_DIR}/datasets_cache.json" ]; then
                    cat "${STATE_DIR}/datasets_cache.json"
                else
                    datasets_json
                fi
            else
                show_datasets
            fi
            exit 0
            ;;

        --snapshots)

            if [ "$CLI_FORMAT" = "json" ]; then
                # --cached: Stand vom letzten Lauf aus dem State (kein zfs, weckt
                # keine Platte). Ohne Cache (z. B. vor dem ersten Lauf) live.
                if [ "$CLI_CACHED" -eq 1 ] && [ -s "${STATE_DIR}/snapshots_cache.json" ]; then
                    cat "${STATE_DIR}/snapshots_cache.json"
                else
                    # Live-Pfad (GUI „Live aktualisieren"): alles aktuell holen –
                    # Remote aktiv prüfen (darf wecken) UND den Snapshot-Listen-
                    # Cache für die aufklappbaren Einzel-Snapshots live neu schreiben
                    # (ein zfs list -t snapshot; weckt ggf. Quell-HDDs – bewusst, da
                    # explizit „Live").
                    write_snapshots_list_cache yes 2>/dev/null
                    snapshots_json yes
                fi
            else
                show_snapshots
            fi
            exit 0
            ;;

        --capacity)

            if [ "$CLI_FORMAT" = "json" ]; then
                if [ "$CLI_CACHED" -eq 1 ]; then
                    # Strikt aus dem State (kein zpool/SSH, weckt keine Platte).
                    # Fehlt der Cache (vor dem ersten Lauf), leere Struktur – die
                    # GUI fragt NIE live ab.
                    if [ -s "${STATE_DIR}/capacity_cache.json" ]; then
                        cat "${STATE_DIR}/capacity_cache.json"
                    else
                        echo '{"source":[],"local":[],"remote":[]}'
                    fi
                else
                    capacity_json   # live (manueller Aufruf; darf wecken)
                fi
            else
                show_capacity
            fi
            exit 0
            ;;

        --dataset-snapshots)

            # Verwaltete Snapshots EINES Datasets (Name/Größe/Zeit) aus dem am
            # Lauf-Ende erfassten Cache – KEIN Live-zfs (Quelle/Ziel kann HDD
            # sein) und nur unsere verwalteten Snapshots (kein Zugriff auf fremde
            # Datasets). Optionaler Scope: "source" (Default) oder eine Ziel-ID.
            local dss_ds="${CLI_ARGS[1]:-}"
            local dss_scope="${CLI_ARGS[2]:-source}"
            if [ -z "$dss_ds" ] || ! zfs_name_is_safe "$dss_ds"; then
                if [ "$CLI_FORMAT" = "json" ]; then
                    echo '{"error":"ungültiges Dataset","snapshots":[]}'
                else
                    echo "FEHLER: ungültiges Dataset: ${dss_ds}" >&2
                fi
                exit 1
            fi
            if [ "$dss_scope" != "source" ] && ! target_id_is_valid "$dss_scope"; then
                if [ "$CLI_FORMAT" = "json" ]; then
                    echo '{"error":"ungültiger Scope","snapshots":[]}'
                else
                    echo "FEHLER: ungültiger Scope: ${dss_scope}" >&2
                fi
                exit 1
            fi
            if [ "$CLI_FORMAT" = "json" ]; then
                dataset_snapshots_json "$dss_ds" "$dss_scope"
            else
                show_dataset_snapshots "$dss_ds" "$dss_scope"
            fi
            exit 0
            ;;

        --snapshot-tree)

            # Scope-Übersicht (Quelle + jedes aktive Ziel) mit Dataset-Zählungen
            # und Größen – Grundlage der aufklappbaren Snapshots-Seite. Aus dem
            # State-Cache (--cached, GUI-Standard) oder live neu erzeugt.
            if [ "$CLI_FORMAT" = "json" ]; then
                if [ "$CLI_CACHED" -eq 1 ] && [ -s "${STATE_DIR}/snapshot_tree_cache.json" ]; then
                    cat "${STATE_DIR}/snapshot_tree_cache.json"
                else
                    # Live („Aktualisieren"): neu erzeugen UND den Cache persistent
                    # mitschreiben, damit Folgeansichten (und die Browse-Scopes)
                    # den aktuellen Stand inkl. aktueller Ziel-IDs nutzen.
                    write_snapshots_list_cache yes 2>/dev/null
                    snapshot_tree_json | tee "${STATE_DIR}/snapshot_tree_cache.json"
                fi
            else
                snapshot_tree_json
            fi
            exit 0
            ;;

        --snapshot-ls)

            # Verzeichnisebene innerhalb eines Snapshots auflisten (Datei-Browser,
            # Grundlage fürs Restore). Liest tatsächlich ins Dataset – WECKT ggf.
            # die Platte/den Remote (bewusste Nutzeraktion). Positional, feste
            # Reihenfolge: <dataset> <snapshot> <scope> [unterpfad].
            local sls_ds="${CLI_ARGS[1]:-}"
            local sls_snap="${CLI_ARGS[2]:-}"
            local sls_scope="${CLI_ARGS[3]:-source}"
            local sls_path="${CLI_ARGS[4]:-}"
            if [ -z "$sls_ds" ] || ! zfs_name_is_safe "$sls_ds" \
               || [ -z "$sls_snap" ] || ! zfs_name_is_safe "$sls_snap"; then
                echo '{"error":"ungültiges Dataset/Snapshot","entries":[]}'
                exit 1
            fi
            if [ "$sls_scope" != "source" ] && ! target_id_is_valid "$sls_scope"; then
                echo '{"error":"ungültiger Scope","entries":[]}'
                exit 1
            fi
            snapshot_ls_json "$sls_ds" "$sls_snap" "$sls_scope" "$sls_path"
            exit $?
            ;;

        --snapshot-cat)

            # Inhalt EINER Datei aus einem Snapshot auf stdout (Download/Vorschau).
            # Positional: <dataset> <snapshot> <scope> <unterpfad>. Bei Fehler
            # leere Ausgabe + Exit 1 (PHP wertet den Code aus).
            local sct_ds="${CLI_ARGS[1]:-}"
            local sct_snap="${CLI_ARGS[2]:-}"
            local sct_scope="${CLI_ARGS[3]:-source}"
            local sct_path="${CLI_ARGS[4]:-}"
            if [ -z "$sct_ds" ] || ! zfs_name_is_safe "$sct_ds" \
               || [ -z "$sct_snap" ] || ! zfs_name_is_safe "$sct_snap"; then
                echo "FEHLER: ungültiges Dataset/Snapshot" >&2
                exit 1
            fi
            if [ "$sct_scope" != "source" ] && ! target_id_is_valid "$sct_scope"; then
                echo "FEHLER: ungültiger Scope" >&2
                exit 1
            fi
            snapshot_cat "$sct_ds" "$sct_snap" "$sct_scope" "$sct_path"
            exit $?
            ;;

        --snapshot-restore)

            # Datei/Ordner aus einem Snapshot in den Restore-Ordner des Quell-
            # Datasets zurückholen (nicht destruktiv). Positional: <dataset>
            # <snapshot> <scope> <unterpfad>. scope = source ODER Ziel-ID
            # (Replikat); bei Replikaten ist <dataset> das Ziel-Dataset.
            local sr_ds="${CLI_ARGS[1]:-}"
            local sr_snap="${CLI_ARGS[2]:-}"
            local sr_scope="${CLI_ARGS[3]:-source}"
            local sr_path="${CLI_ARGS[4]:-}"
            # Optionales 5. Argument "progress": Fortschrittsausgabe für die GUI.
            local sr_prog="${CLI_ARGS[5]:-}"
            snapshot_restore "$sr_ds" "$sr_snap" "$sr_scope" "$sr_path" "$sr_prog"
            exit $?
            ;;

        --verify)

            verify all no yes
            exit $?
            ;;

        --verify-repair)

            verify all no no
            exit $?
            ;;

        --verify-source)

            verify source no no
            exit $?
            ;;

        --verify-source-repair)

            verify source no no
            exit $?
            ;;

        --verify-local)

            verify local no no
            exit $?
            ;;

        --verify-local-repair)

            verify local no no
            exit $?
            ;;

        --verify-remote)

            verify remote no no
            exit $?
            ;;

        --verify-remote-repair)

            verify remote no no
            exit $?
            ;;

        --verify-borg)

            verify borg no no
            exit $?
            ;;

        --verify-target)

            # Snapshots nur eines einzelnen Ziels prüfen (Ziel-ID als Argument).
            local vt_target="${CLI_ARGS[1]:-}"
            if [ -z "$vt_target" ] || ! target_id_is_valid "$vt_target"; then
                echo "FEHLER: ungültige Ziel-ID: ${vt_target:-（leer）}" >&2
                exit 1
            fi
            verify "$vt_target" no no
            exit $?
            ;;

        *)

            if [ -n "$CLI_CMD" ]; then
                echo "Unbekannte Option: $CLI_CMD"
                echo
                echo "Verwende:"
                echo "  zfs-backup.sh --help"
                exit 1
            fi
            ;;

    esac
}

config_schema() {
    cat <<'EOF'
Datasets|INCLUDES|array|Root-Datasets, die gesichert werden. Unter-Datasets werden automatisch einbezogen.
Datasets|EXCLUDES|array|Datasets, die ausgenommen werden. Ein Eintrag schließt auch seine Unter-Datasets aus, außer sie stehen explizit in INCLUDES.
Datasets|SNAPSHOT_POOL_ROOTS|bool|Pool-Root-Datasets wie cache oder services selbst snapshotten. Standard: no, damit nur Child-Datasets verarbeitet werden.
Snapshots / Retention|SNAPSHOT_PREFIX|string|Prefix für alle vom Skript verwalteten Snapshots. Damit werden eigene Snapshots von fremden Snapshots getrennt.
Snapshots / Retention|KEEP_HOURLY|number|Aufzubewahrende stündliche Snapshots. 0 deaktiviert den Typ (keine Erstellung, kein Bestand).
Snapshots / Retention|KEEP_DAILY|number|Aufzubewahrende tägliche Snapshots. 0 deaktiviert den Typ (keine Erstellung, kein Bestand).
Snapshots / Retention|KEEP_WEEKLY|number|Aufzubewahrende wöchentliche Snapshots. 0 deaktiviert den Typ (keine Erstellung, kein Bestand).
Snapshots / Retention|KEEP_MONTHLY|number|Aufzubewahrende monatliche Snapshots. 0 deaktiviert den Typ (keine Erstellung, kein Bestand).
Snapshots / Retention|KEEP_YEARLY|number|Aufzubewahrende jährliche Snapshots. 0 deaktiviert den Typ (keine Erstellung, kein Bestand).
Pruning / Cleanup|ENABLE_SOURCE_PRUNING|bool|Löscht ältere verwaltete Snapshots auf der Quelle gemäß Retention.
Ziele|TARGETS|array|Liste der Replikationsziele in Backup-Reihenfolge (erstes Ziel zuerst). Typen: local, remote, borg (entferntes Borg-Repository als Offsite-Ziel). Pflege über die Ziel-Befehle (--add-target, --edit-target, --delete-target, --test-target, --reorder-targets, --move-target).
Logs / Benachrichtigung|LOG_RETENTION_DAYS|number|Anzahl Tage, die tägliche Logdateien behalten werden.
Logs / Benachrichtigung|NOTIFY_START|enum:aus,normal,warning,alert|Unraid-Notification beim Start eines Laufs. Stufe wählen oder "aus".
Logs / Benachrichtigung|NOTIFY_SUCCESS|enum:aus,normal,warning,alert|Unraid-Notification bei erfolgreichem Lauf. Stufe wählen oder "aus".
Logs / Benachrichtigung|NOTIFY_ERROR|enum:aus,normal,warning,alert|Unraid-Notification bei Fehlern. Stufe wählen oder "aus".
Logs / Benachrichtigung|NOTIFY_ORPHANS|enum:aus,normal,warning,alert|Unraid-Notification, wenn ein Lauf verwaiste Datasets findet – verwaiste Ziel-Datasets (Quelle gelöscht/außer Betrieb) oder außer Betrieb genommene Quell-Datasets mit Restsnapshots. Stufe wählen oder "aus".
Logs / Benachrichtigung|STALE_AFTER_HOURS|number|Warnen, wenn das letzte erfolgreiche Backup älter als N Stunden ist (0 = aus). Wächter läuft nur bei aktivem Zeitplan.
Zeitplan|SCHEDULE_ENABLED|bool|Geplanten Lauf aktivieren. Nur das Unraid-Plugin wertet dies aus (Cron).
Zeitplan|SCHEDULE_CRON|string|Cron-Ausdruck (Minute Stunde Tag Monat Wochentag). Vom Zeitplan-Tab gepflegt.
EOF
}

# --- Maschinenlesbare CLI-Ausgabe ------------------------------------
# Gemeinsamer JSON-Helfer: escapt einen String als JSON-String-Wert.
# Reines bash (keine jq-Abhängigkeit). config_schema liefert einzeilige Felder,
# daher genügt das Escapen von Backslash, Anführungszeichen, Tab und CR.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/}"
    printf '%s' "$s"
}

# Gibt einen nicht-negativen Ganzzahlwert als JSON-Zahl aus, sonst 0.
# Schützt die Ausgabe vor nicht-numerischen Fallbacks (z. B. "-").
json_num() {
    case "$1" in
        ''|*[!0-9]*) printf '0' ;;
        *) printf '%s' "$1" ;;
    esac
}

# Gibt einen yes/no-Wert als JSON-Boolean aus (yes/true/1 -> true, sonst false).
json_bool() {
    case "$1" in
        yes|true|1) printf 'true' ;;
        *) printf 'false' ;;
    esac
}

# config_schema als JSON-Array ausgeben:
# [{"group":..,"name":..,"type":..,"description":..}, ...]
# Datenquelle für schema-getriebene Formulare in der GUI.
config_schema_json() {
    local group name type desc
    local first=1

    printf '['
    while IFS='|' read -r group name type desc; do
        [ -z "$group" ] && continue
        if [ "$first" -eq 1 ]; then
            first=0
        else
            printf ','
        fi
        printf '{"group":"%s","name":"%s","type":"%s","description":"%s"}' \
            "$(json_escape "$group")" \
            "$(json_escape "$name")" \
            "$(json_escape "$type")" \
            "$(json_escape "$desc")"
    done < <(config_schema)
    printf ']\n'
}

# config_schema menschenlesbar ausgeben (Standardformat für die CLI).
config_schema_text() {
    local group name type desc
    while IFS='|' read -r group name type desc; do
        [ -z "$group" ] && continue
        printf '%-22s %-8s %s\n' "$name" "$type" "$group"
        printf '    %s\n' "$desc"
    done < <(config_schema)
}

config_schema_field() {
    local name="$1"
    local field="$2"

    config_schema | awk -F'|' -v name="$name" -v field="$field" '$2 == name { print $field; found = 1; exit } END { exit found ? 0 : 1 }'
}

config_known_options_pattern() {
    config_schema | awk -F'|' '
        {
            if (output != "") output = output "|"
            output = output $2
        }
        END {
            print output
        }
    '
}

config_option_type() {
    config_schema_field "$1" 3 || echo "string"
}

config_option_value() {
    local name="$1"
    local item

    case "$(config_option_type "$name")" in
        array)
            eval 'for item in "${'"$name"'[@]}"; do printf "%s " "$item"; done'
            echo
            ;;
        *)
            printf "%s\n" "${!name}"
            ;;
    esac
}

# Secrets werden nie im Klartext ausgegeben, sondern maskiert. Aktuell gibt es
# keine geheimen Optionen mehr (Benachrichtigung läuft über Unraid, kein Token);
# die Maskierungs-Mechanik bleibt für künftige Secrets erhalten.
config_option_is_secret() {
    case "$1" in
        *) return 1 ;;
    esac
}

# Aktueller Wert einer Option als typisierter JSON-Wert (für --get-config):
# number -> Zahl, array -> Array, bool/string -> String (round-trip-fähig zu
# --set-config). Secrets maskiert ("***" wenn gesetzt, sonst "").
config_value_json() {
    local name="$1"
    local type
    local item
    local first=1

    if config_option_is_secret "$name"; then
        if [ -n "${!name}" ]; then printf '"***"'; else printf '""'; fi
        return
    fi

    type=$(config_option_type "$name")
    case "$type" in
        number)
            printf '%s' "$(json_num "${!name}")"
            ;;
        array)
            printf '['
            eval 'for item in "${'"$name"'[@]}"; do
                if [ "$first" -eq 1 ]; then first=0; else printf ","; fi
                printf "\"%s\"" "$(json_escape "$item")"
            done'
            printf ']'
            ;;
        *)
            printf '"%s"' "$(json_escape "${!name}")"
            ;;
    esac
}

# Alle Konfigurationswerte als JSON-Objekt (für das GUI-Formular). TARGETS
# bleibt außen vor (eigener Endpunkt --targets --json).
config_values_json() {
    local group name type desc
    local first=1

    printf '{'
    while IFS='|' read -r group name type desc; do
        [ -z "$name" ] && continue
        [ "$name" = "TARGETS" ] && continue
        if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
        printf '"%s":' "$(json_escape "$name")"
        config_value_json "$name"
    done < <(config_schema)
    printf '}\n'
}


save_config_edits() {
    normalize_config no
    source "$CONFIG_FILE"
    target_apply_all_defaults
}

# Aggregat für den GUI-Seitenaufbau: liefert Status, Kapazität (cached), Schema,
# Konfigwerte und Ziele in EINEM JSON-Objekt. Die GUI ruft so den Kern beim Laden
# nur EINMAL statt fünfmal (ein Interpreter-Start statt fünf). Rein lesend,
# komponiert nur die vorhandenen Emitter.
gui_init_json() {
    printf '{"status":'
    status_json
    printf ',"capacity":'
    if [ -s "${STATE_DIR}/capacity_cache.json" ]; then
        cat "${STATE_DIR}/capacity_cache.json"
    else
        printf '{"source":[],"local":[],"remote":[]}'
    fi
    printf ',"schema":'
    config_schema_json
    printf ',"values":'
    config_values_json
    printf ',"targets":'
    targets_json
    printf '}\n'
}

dataset_config_value_is_valid() {
    local value="$1"

    [ -n "$value" ] || return 1
    case "$value" in
        *@*) return 1 ;;
    esac
    zfs_name_is_safe "$value" || return 1

    return 0
}

# Prüft, ob eine Option im config_schema bekannt ist (für --set-config/--get-config).
config_option_exists() {
    config_schema | awk -F'|' -v n="$1" '$2 == n { found = 1 } END { exit found ? 0 : 1 }'
}

set_config_option_value() {
    local name="$1"
    local value="$2"
    local type
    local items

    type=$(config_option_type "$name")

    case "$type" in
        bool)
            case "$value" in
                yes|no) ;;
                *) console_error "Ungültiger Wert. Erlaubt ist yes oder no."; return 1 ;;
            esac
            printf -v "$name" "%s" "$value"
            ;;
        enum:*)
            local allowed="${type#enum:}"
            case ",$allowed," in
                *",$value,"*) ;;
                *) console_error "Ungültiger Wert. Erlaubt: ${allowed//,/, }."; return 1 ;;
            esac
            printf -v "$name" "%s" "$value"
            ;;
        number)
            case "$value" in
                ''|*[!0-9]*) console_error "Ungültiger Wert. Bitte eine ganze Zahl eingeben."; return 1 ;;
            esac
            printf -v "$name" "%s" "$value"
            ;;
        array)
            local -n target_array="$name"
            local item
            if [ "$value" = "-" ]; then
                if [ "$name" = "EXCLUDES" ]; then
                    target_array=()
                else
                    console_error "${name} darf nicht leer sein."
                    return 1
                fi
            else
                read -r -a items <<< "$value"
                if [ "${#items[@]}" -eq 0 ]; then
                    console_error "Bitte mindestens einen Eintrag angeben."
                    return 1
                fi
                for item in "${items[@]}"; do
                    if ! dataset_config_value_is_valid "$item"; then
                        console_error "Ungültiger Dataset-Name: $item"
                        return 1
                    fi
                done
                target_array=("${items[@]}")
            fi
            ;;
        *)
            printf -v "$name" "%s" "$value"
            ;;
    esac

    save_config_edits
    console_success "Gespeichert: $name"
}

show_targets_overview() {
    local target_id
    local type

    echo
    echo "Ziele"
    echo
    if [ "${#TARGETS[@]}" -eq 0 ]; then
        echo "  Keine Ziele konfiguriert"
        return 0
    fi

    for target_id in "${TARGETS[@]}"; do
        type=$(target_type "$target_id")
        printf "  %s\n" "$target_id"
        printf "    Name      %s\n" "$(target_label "$target_id")"
        printf "    Typ       %s\n" "$type"
        printf "    Aktiv     %s\n" "$(target_get "$target_id" ENABLED yes)"
        printf "    Ziel      %s\n" "$(target_get "$target_id" BASE_DATASET)"
        if [ "$type" = "remote" ]; then
            printf "    Host      %s\n" "$(target_get "$target_id" HOST)"
            printf "    WOL       %s -> %s\n" "$(target_get "$target_id" WAKE_ON_LAN yes)" "$(target_get "$target_id" WAKE_MAC)"
            printf "    Retry     %s Versuch(e), %s Sekunden\n" "$(target_get "$target_id" RETRY_ATTEMPTS 3)" "$(target_get "$target_id" RETRY_WAIT_SECONDS 10)"
        fi
        echo
    done
}

target_edit_value_is_valid() {
    local field="$1"
    local value="$2"

    case "$field" in
        LABEL)
            case "$value" in
                *[$'\n\r']*) console_error "Label darf keine Zeilenumbrüche enthalten."; return 1 ;;
            esac
            ;;
        ENABLED|WAKE_ON_LAN)
            case "$value" in
                yes|no) return 0 ;;
                *) console_error "Ungültiger Wert. Erlaubt ist yes oder no."; return 1 ;;
            esac
            ;;
        BASE_DATASET)
            if [ -z "$value" ] || ! zfs_name_is_safe "$value"; then
                console_error "Ungültiges Ziel-Dataset: $value"
                return 1
            fi
            ;;
        HOST)
            if [ -z "$value" ]; then
                console_error "SSH-Host darf nicht leer sein."
                return 1
            fi
            ;;
        WAKE_TIMEOUT_SECONDS|WAKE_CHECK_INTERVAL_SECONDS|RETRY_ATTEMPTS|RETRY_WAIT_SECONDS|COMPACT_EVERY)
            if ! [ "$value" -ge 0 ] 2>/dev/null; then
                console_error "Bitte eine ganze Zahl >= 0 eingeben."
                return 1
            fi
            ;;
        REPO)
            if [ -z "$value" ] || ! borg_repo_is_safe "$value"; then
                console_error "Ungültige Borg-Repo-URL: $value"
                return 1
            fi
            ;;
        PASSPHRASE)
            case "$value" in
                *[$'\n\r']*) console_error "Passphrase darf keine Zeilenumbrüche enthalten."; return 1 ;;
            esac
            ;;
    esac

    return 0
}

show_run_summary() {

    local end_time=$(date +%s)
    local runtime=$((end_time-START_TIME))
    local result="ERFOLG"
    local datasets
    local created_total
    local source_snapshot_count
    local source_snapshot_used
    local local_snapshot_count
    local local_snapshot_used
    local remote_snapshot_count
    local remote_snapshot_used
    local inv_h
    local inv_d
    local inv_w
    local inv_m
    local inv_y
    local inv_total
    local local_inv_h=0
    local local_inv_d=0
    local local_inv_w=0
    local local_inv_m=0
    local local_inv_y=0
    local local_inv_total=0
    local remote_inv_h=0
    local remote_inv_d=0
    local remote_inv_w=0
    local remote_inv_m=0
    local remote_inv_y=0
    local remote_inv_total=0

    RUN_RUNTIME_SECONDS="$runtime"

    [ "$RUN_ERRORS" -gt 0 ] && result="FEHLER"
    datasets=$(read_state datasets_count)
    created_total=$((CREATED_HOURLY+CREATED_DAILY+CREATED_WEEKLY+CREATED_MONTHLY+CREATED_YEARLY))
    read -r inv_h inv_d inv_w inv_m inv_y inv_total < <(source_snapshot_inventory)

    read -r source_snapshot_count source_snapshot_used < <(snapshot_stats_for_active_datasets cat)

    read -r local_snapshot_count local_snapshot_used < <(target_snapshot_stats_for_type local)
    read -r local_inv_h local_inv_d local_inv_w local_inv_m local_inv_y local_inv_total < <(target_snapshot_inventory_for_type local)
    read -r remote_snapshot_count remote_snapshot_used < <(target_snapshot_stats_for_type remote)
    read -r remote_inv_h remote_inv_d remote_inv_w remote_inv_m remote_inv_y remote_inv_total < <(target_snapshot_inventory_for_type remote)

    console_clear_status

    cat <<EOF

========================================
Backup-Statistik
========================================

Status        ${result}
Laufzeit      ${runtime} Sekunden
Datasets      ${datasets}

Snapshots     ${created_total} neu (${CREATED_HOURLY} hourly, ${CREATED_DAILY} daily, ${CREATED_WEEKLY} weekly, ${CREATED_MONTHLY} monthly, ${CREATED_YEARLY} yearly)
Quelle        ${inv_total} verwaltete Snapshots (${inv_h} hourly, ${inv_d} daily, ${inv_w} weekly, ${inv_m} monthly, ${inv_y} yearly)
Pruning       ${DELETED_SNAPSHOTS} Quelle, ${LOCAL_DELETED_SNAPSHOTS} lokal, ${REMOTE_DELETED_SNAPSHOTS} remote gelöscht

Lokal         ${REPLICATION_FULL} Full, ${REPLICATION_INCREMENTAL} inkrementell, ${REPLICATION_RESUMED} fortgesetzt, ${REPLICATION_SKIPPED} aktuell, ${REPLICATION_ERRORS} Fehler
Remote        ${REMOTE_REPLICATION_FULL} Full, ${REMOTE_REPLICATION_INCREMENTAL} inkrementell, ${REMOTE_REPLICATION_RESUMED} fortgesetzt, ${REMOTE_REPLICATION_SKIPPED} aktuell, ${REMOTE_REPLICATION_ERRORS} Fehler

Snapshot-Speicher
  Quelle       ${source_snapshot_count} Snapshots, $(format_bytes "$source_snapshot_used") used
  Lokal        ${local_snapshot_count} Snapshots, $(format_bytes "$local_snapshot_used") used
  Remote       ${remote_snapshot_count} Snapshots, $(format_bytes "$remote_snapshot_used") used

EOF

    cat > "${STATE_DIR}/last_run_stats" <<EOF
LAST_RUN=$(date '+%d.%m.%Y %H:%M:%S')
RESULT=${result}
DATASETS=$(read_state datasets_count)
CREATED_HOURLY=${CREATED_HOURLY}
CREATED_DAILY=${CREATED_DAILY}
CREATED_WEEKLY=${CREATED_WEEKLY}
CREATED_MONTHLY=${CREATED_MONTHLY}
CREATED_YEARLY=${CREATED_YEARLY}
CREATED_TOTAL=${created_total}
SOURCE_INVENTORY_HOURLY=${inv_h}
SOURCE_INVENTORY_DAILY=${inv_d}
SOURCE_INVENTORY_WEEKLY=${inv_w}
SOURCE_INVENTORY_MONTHLY=${inv_m}
SOURCE_INVENTORY_YEARLY=${inv_y}
SOURCE_INVENTORY_TOTAL=${inv_total}
LOCAL_INVENTORY_HOURLY=${local_inv_h}
LOCAL_INVENTORY_DAILY=${local_inv_d}
LOCAL_INVENTORY_WEEKLY=${local_inv_w}
LOCAL_INVENTORY_MONTHLY=${local_inv_m}
LOCAL_INVENTORY_YEARLY=${local_inv_y}
LOCAL_INVENTORY_TOTAL=${local_inv_total}
REMOTE_INVENTORY_HOURLY=${remote_inv_h}
REMOTE_INVENTORY_DAILY=${remote_inv_d}
REMOTE_INVENTORY_WEEKLY=${remote_inv_w}
REMOTE_INVENTORY_MONTHLY=${remote_inv_m}
REMOTE_INVENTORY_YEARLY=${remote_inv_y}
REMOTE_INVENTORY_TOTAL=${remote_inv_total}
DELETED=${DELETED_SNAPSHOTS}
LOCAL_DELETED=${LOCAL_DELETED_SNAPSHOTS}
REMOTE_DELETED=${REMOTE_DELETED_SNAPSHOTS}
ORPHAN_DATASETS=${ORPHAN_DATASETS_FOUND:-0}
SOURCE_ORPHAN_DATASETS=${SOURCE_ORPHAN_DATASETS_FOUND:-0}
SOURCE_ORPHAN_SNAPSHOTS=${SOURCE_ORPHAN_SNAPSHOTS_FOUND:-0}
SOURCE_SNAPSHOT_COUNT=${source_snapshot_count}
SOURCE_SNAPSHOT_USED=${source_snapshot_used}
LOCAL_SNAPSHOT_COUNT=${local_snapshot_count}
LOCAL_SNAPSHOT_USED=${local_snapshot_used}
REMOTE_SNAPSHOT_COUNT=${remote_snapshot_count}
REMOTE_SNAPSHOT_USED=${remote_snapshot_used}
RUNTIME_SECONDS=${runtime}
REPLICATION_FULL=${REPLICATION_FULL}
REPLICATION_INCREMENTAL=${REPLICATION_INCREMENTAL}
REPLICATION_RESUMED=${REPLICATION_RESUMED}
REPLICATION_SKIPPED=${REPLICATION_SKIPPED}
REPLICATION_ERRORS=${REPLICATION_ERRORS}
REMOTE_REPLICATION_FULL=${REMOTE_REPLICATION_FULL}
REMOTE_REPLICATION_INCREMENTAL=${REMOTE_REPLICATION_INCREMENTAL}
REMOTE_REPLICATION_RESUMED=${REMOTE_REPLICATION_RESUMED}
REMOTE_REPLICATION_SKIPPED=${REMOTE_REPLICATION_SKIPPED}
REMOTE_REPLICATION_ERRORS=${REMOTE_REPLICATION_ERRORS}
EOF

    # GUI-Cache (Datasets/Snapshots) für die Snapshots-Seite mitschreiben –
    # Platten sind jetzt ohnehin warm, das Anschauen weckt später keine mehr.
    write_gui_cache
}

########################################
# MAIN
########################################

init_dirs
init_logging
load_config

if [ "$1" = "--verbose" ]; then
    VERBOSE=1
    shift
fi

# Ohne Argumente: Hilfe anzeigen. Es gibt kein interaktives Menü mehr; ein
# Snapshotlauf wird ausschließlich über --run gestartet.
if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

# Config-Datei normalisieren / fehlende Optionen erkennen – aber NUR bei
# Befehlen, die das brauchen (Lauf/Pflege/Schreiben). Reine Lese-Befehle, die die
# GUI beim Seitenaufbau mehrfach aufruft, überspringen das (Performance).
case "$1" in
    --version|--help|--status|--gui-init|--capacity|--datasets|--snapshots|--snapshot-tree|--dataset-snapshots|--snapshot-ls|--snapshot-cat|--targets|--config-schema|--borg-providers|--get-config|--log-tail|--log-follow|--progress-follow|--check-stale)
        ;;
    *)
        config_maintain
        ;;
esac

# Nach einer Config-Aktualisierung nur unkritische Befehle zulassen; ein Lauf
# wird blockiert, bis die Config geprüft wurde.
if [ "$CONFIG_UPDATED" -eq 1 ]; then
    case "$1" in
        --help|--version|--status|--gui-init|--check-stale|--capacity|--datasets|--snapshots|--targets|--dataset-snapshots|--snapshot-tree|--snapshot-ls|--snapshot-cat|--snapshot-restore|--log-tail|--log-follow|--progress-follow|--config-check|--config-schema|--borg-providers|--borg-archives|--borg-check-update|--get-config|--set-config|--add-target|--delete-target|--edit-target|--test-target|--reorder-targets|--move-target|--reset-statistics|--reset-run-status|--delete-logs|--thin-history|--delete-managed-snapshots|--cleanup-orphans)
            ;;
        *)
            echo
            if [ "$CONFIG_CREATED" -eq 1 ]; then
                echo "Die Config-Datei wurde erstellt:"
            else
                echo "Die Config-Datei wurde aktualisiert:"
            fi
            echo "$CONFIG_FILE"
            echo
            echo "Bitte prüfe die Config mit:"
            echo "  zfs-backup.sh --config-check"
            echo
            echo "Der angeforderte Lauf wurde aus Sicherheitsgründen nicht gestartet."
            echo
            exit 1
            ;;
    esac
fi

handle_cli "$@"

acquire_lock
trap release_lock EXIT
RUN_ACTIVE=1
START_TIME=$(date +%s)
RUN_STARTED_HUMAN="$(date '+%d.%m.%Y %H:%M:%S')"
write_progress "Start"

log "Snapshotlauf gestartet"
notify_start
log_phase "Snapshots"
run_snapshot_job
log_phase "Ziel-Replikation"
run_target_replications
log_phase "Verwaiste Datasets"
report_all_target_orphan_datasets
report_source_orphan_datasets
log_phase "Pruning"
run_pruning
rotate_logs

# borg-Versions-Check (gedrosselt 1x/Tag, nur bei aktivem borg-Ziel) – aktualisiert
# den Cache, den Status/GUI/config-check ohne Netz lesen.
borg_update_refresh

show_run_summary

# Verwaiste Ziel-Datasets gefunden? Unraid-Warnung (unabhängig von Erfolg/Fehler).
notify_orphans

if [ "$RUN_ERRORS" -eq 0 ]; then
    write_state \
        last_success \
        "$(date '+%d.%m.%Y %H:%M:%S')"
    # Maschinenlesbarer Zeitstempel für die „Backup veraltet"-Prüfung + Merker
    # zurücksetzen (frischer Erfolg -> nicht mehr veraltet).
    write_state last_success_epoch "$(date +%s)"
    rm -f "${STATE_DIR}/stale_notified"
    notify_success
    log "Snapshotlauf beendet"
    console_success "Snapshotlauf erfolgreich beendet"
    exit 0
fi

write_state \
    last_error \
    "$(date '+%d.%m.%Y %H:%M:%S') Snapshotlauf mit ${RUN_ERRORS} Fehler(n)"

notify_error
log "Snapshotlauf mit Fehlern beendet"
console_error "Snapshotlauf mit Fehlern beendet"

exit 1
