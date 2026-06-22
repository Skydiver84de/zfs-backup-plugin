#!/bin/bash
# zfs-backup Unraid-Plugin – Borg-Binary bereitstellen.
#
# Stellt die borg-Standalone-Binary unter <RUNTIME_DIR>/borg/borg bereit. Diese
# liegt auf dem Pool (RUNTIME_DIR), ist also persistent: geladen wird genau
# EINMAL pro Pool, danach übersteht sie Reboots und Plugin-Neuinstallationen.
#
# Idempotent: passt die Datei (Checksumme), passiert nichts; fehlt sie oder weicht
# sie ab, wird sie neu geladen und verifiziert. Läuft im Plugin-Kontext bei jedem
# Boot (install.sh ruft es auf, sofern ein borg-Ziel konfiguriert ist) und lässt
# sich auch manuell aufrufen:  borg-setup.sh [<runtime-dir>]
#
# Quelle/Version sind hier gepinnt; ein Versionswechsel erfolgt bewusst über ein
# Plugin-Update (neue BORG_VERSION + BORG_SHA256).

set -o pipefail

# Borg 1.4.4, x86_64, glibc >= 2.31 (deckt Unraid 6.12+ ab). Nur diese eine
# Architektur – Unraid läuft auf x86_64.
BORG_VERSION="1.4.4"
BORG_ASSET="borg-linux-glibc231-x86_64"
BORG_SHA256="28d8053626bd375837ed4fdb4dda5ef29b2271dbe71a2c6a5749d8f8f0021c6d"
BORG_URL="https://github.com/borgbackup/borg/releases/download/${BORG_VERSION}/${BORG_ASSET}"

RUNTIME_DIR="${1:-${ZFS_BACKUP_RUNTIME_DIR:-}}"
if [ -z "$RUNTIME_DIR" ]; then
    echo "FEHLER: RUNTIME_DIR nicht gesetzt (Argument oder ZFS_BACKUP_RUNTIME_DIR)." >&2
    exit 1
fi

BORG_DIR="${RUNTIME_DIR}/borg"
BORG_BIN="${BORG_DIR}/borg"

sha_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    else
        echo ""
    fi
}

# Schon vorhanden und korrekt? Dann nichts tun (schneller Pfad bei jedem Boot).
if [ -x "$BORG_BIN" ]; then
    have="$(sha_of "$BORG_BIN")"
    if [ -z "$have" ] || [ "$have" = "$BORG_SHA256" ]; then
        # Leere Prüfsumme = kein sha-Tool vorhanden -> ausführbare Datei akzeptieren.
        echo "borg bereits vorhanden: $BORG_BIN"
        exit 0
    fi
    echo "borg-Checksumme weicht ab -> Neubezug."
fi

mkdir -p "$BORG_DIR" || { echo "FEHLER: Verzeichnis nicht anlegbar: $BORG_DIR" >&2; exit 1; }
tmp="${BORG_BIN}.download.$$"

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$tmp" "$BORG_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp" "$BORG_URL"
    else
        echo "FEHLER: weder curl noch wget vorhanden." >&2
        return 1
    fi
}

echo "Lade borg ${BORG_VERSION} (${BORG_ASSET}) ..."
if ! fetch; then
    rm -f "$tmp"
    echo "FEHLER: Download fehlgeschlagen: $BORG_URL" >&2
    exit 1
fi

got="$(sha_of "$tmp")"
if [ -n "$got" ] && [ "$got" != "$BORG_SHA256" ]; then
    rm -f "$tmp"
    echo "FEHLER: SHA256 stimmt nicht (erwartet $BORG_SHA256, erhalten $got)." >&2
    exit 1
fi
if [ -z "$got" ]; then
    echo "WARNUNG: kein sha256-Tool gefunden – Binary nicht verifiziert."
fi

chmod +x "$tmp" || { rm -f "$tmp"; echo "FEHLER: chmod fehlgeschlagen." >&2; exit 1; }
mv -f "$tmp" "$BORG_BIN" || { rm -f "$tmp"; echo "FEHLER: konnte borg nicht ablegen: $BORG_BIN" >&2; exit 1; }

echo "borg installiert: $BORG_BIN"
exit 0
