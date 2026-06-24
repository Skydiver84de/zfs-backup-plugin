<?php
/*
 * zfs-backup – Endpoint zum Abbrechen eines laufenden Laufs aus der GUI.
 *
 * Ruft `zfs-backup --stop` auf (SIGTERM an die Prozessgruppe des Laufs, danach
 * SIGKILL; Lock + Bind-Mounts werden aufgeräumt). KEINE ZFS-/Backup-Logik im
 * PHP – nur der Aufruf. CSRF prüft Unraid global (auto_prepend); das Formular
 * sendet den Token mit.
 *
 * Antwort: {"ok":bool,"msg":"..."}
 */

header('Content-Type: application/json');

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    http_response_code(405);
    echo json_encode(['ok' => false, 'msg' => 'POST erforderlich']);
    exit;
}

$cli = '/usr/local/sbin/zfs-backup';

$out = [];
$rc  = 0;
exec(escapeshellarg($cli) . ' --stop 2>&1', $out, $rc);

echo json_encode([
    'ok'  => ($rc === 0),
    'msg' => $rc === 0 ? 'Lauf wird abgebrochen.' : 'Abbruch fehlgeschlagen.',
]);
