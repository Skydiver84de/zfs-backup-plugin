<?php
/*
 * zfs-backup – Aktions-Endpoint für Prüfen (Verify) und Wartung der GUI.
 *
 * Reicht ausschließlich fest verdrahtete Wartungs-/Prüf-Flags an den Kern
 * weiter. KEINE eigene ZFS-/Backup-Logik: die Action ist nur ein
 * Schlüssel in eine Whitelist, es werden keine freien Argumente übernommen.
 * Destruktive Aktionen hängt der Endpoint selbst `--yes` an; die Sicherheits-
 * prüfungen macht der Kern. CSRF prüft Unraid global (auto_prepend); das
 * Formular sendet den Token mit.
 *
 * POST-Parameter:
 *   action=<schlüssel aus $ACTIONS>
 *
 * Antwort: text/plain, live gestreamt (wie Unraids Plugin-Aktionen); die
 * letzte Zeile trägt den Exit-Code („[Exit-Code: N]“).
 */

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    http_response_code(405);
    header('Content-Type: text/plain; charset=utf-8');
    echo "POST erforderlich\n[Exit-Code: 1]\n";
    exit;
}

$cli = '/usr/local/sbin/zfs-backup';

/* Whitelist: Action -> feste Argumentliste. Destruktive Aktionen tragen
 * `--yes` bereits hier, damit der Kern sie ohne Rückfrage ausführt (die
 * Rückfrage macht die GUI per confirm()). */
$ACTIONS = [
    'simulate'                 => ['--simulate'],
    'refresh-snapshots'        => ['--refresh-snapshots'],   // Snapshots-Seite live aktualisieren (read-only)
    'verify'                   => ['--verify'],
    'verify-source'            => ['--verify-source'],
    'verify-local'             => ['--verify-local'],
    'verify-remote'            => ['--verify-remote'],
    'verify-target'            => ['--verify-target'],            // + Ziel-ID
    'reset-statistics'         => ['--reset-statistics', '--yes'],
    'reset-run-status'         => ['--reset-run-status', '--yes'],
    'delete-logs'              => ['--delete-logs', '--yes'],
    'thin-history'             => ['--thin-history', '--yes'],
    'delete-managed-snapshots' => ['--delete-managed-snapshots', '--yes'],
    'cleanup-orphans-dry'      => ['--cleanup-orphans'],            // Dry-Run, löscht nichts
    'cleanup-orphans'          => ['--cleanup-orphans', '--yes'],   // destruktiv
];

$action = (string)($_POST['action'] ?? '');

header('Content-Type: text/plain; charset=utf-8');
header('X-Accel-Buffering: no');       // nginx-Pufferung aus, damit live ankommt

if (!isset($ACTIONS[$action])) {
    http_response_code(400);
    echo "Unbekannte Aktion\n[Exit-Code: 1]\n";
    exit;
}

@set_time_limit(0);                    // Verify/Thin können dauern (WOL, große Pools)
while (ob_get_level() > 0) { ob_end_flush(); }

$args = $ACTIONS[$action];

/* Orphan-Cleanup: optionale Ziel-ID (numerisch) als Positionsargument direkt
 * nach --cleanup-orphans einfügen (leer = alle Ziele). */
if ($action === 'cleanup-orphans-dry' || $action === 'cleanup-orphans') {
    $target = (string)($_POST['target'] ?? '');
    if ($target !== '' && preg_match('/^[0-9]+$/', $target)) {
        array_splice($args, 1, 0, [$target]);
    }
}

/* Verify einzelnes Ziel: Ziel-ID (numerisch) als Argument an --verify-target. */
if ($action === 'verify-target') {
    $target = (string)($_POST['target'] ?? '');
    if ($target === '' || !preg_match('/^[0-9]+$/', $target)) {
        echo "Fehler: ungültige Ziel-ID.\n[Exit-Code: 1]\n";
        exit;
    }
    $args[] = $target;
}

$cmd = escapeshellarg($cli);
foreach ($args as $a) {
    $cmd .= ' ' . escapeshellarg($a);
}
$cmd .= ' 2>&1';

$ph = popen($cmd, 'r');
if ($ph === false) {
    echo "Fehler: Aktion konnte nicht gestartet werden.\n[Exit-Code: 1]\n";
    exit;
}
while (!feof($ph)) {
    $line = fgets($ph);
    if ($line !== false) { echo $line; flush(); }
}
$rc = pclose($ph);
echo "\n[Exit-Code: " . (int)$rc . "]\n";
exit;
