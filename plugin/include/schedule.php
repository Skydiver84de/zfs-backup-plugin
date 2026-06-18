<?php
/*
 * zfs-backup – Endpoint für den Zeitplan (Cron) der GUI.
 *
 * Reiner Transport: die gesamte Logik (Validierung, Persistenz auf dem
 * Flash, Erzeugen der Unraid-Cron-Datei, update_cron) liegt in schedule.sh.
 * GET  -> schedule.sh get            (aktueller Zeitplan als JSON)
 * POST -> schedule.sh set <yes|no> <cron>
 *
 * CSRF wird NICHT hier geprüft: Unraid validiert den csrf_token global
 * (auto_prepend) und entfernt ihn aus $_POST; das Formular sendet ihn mit.
 *
 * Antwort (POST): {"ok":bool,"msg":"..."}
 */

header('Content-Type: application/json');

$sched = '/usr/local/emhttp/plugins/zfs-backup/schedule.sh';

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'GET') {
    $out = [];
    exec('bash ' . escapeshellarg($sched) . ' get 2>/dev/null', $out);
    $json = json_decode(implode("\n", $out), true);
    echo is_array($json)
        ? json_encode($json)
        : json_encode(['enabled' => false, 'cron' => '', 'active' => false]);
    exit;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    http_response_code(405);
    echo json_encode(['ok' => false, 'msg' => 'GET oder POST erforderlich']);
    exit;
}

$enabled = (($_POST['enabled'] ?? 'no') === 'yes') ? 'yes' : 'no';
$cron    = trim((string)($_POST['cron'] ?? ''));

$out = [];
$rc  = 0;
exec(
    'bash ' . escapeshellarg($sched) . ' set ' .
    escapeshellarg($enabled) . ' ' . escapeshellarg($cron) . ' 2>&1',
    $out, $rc
);

echo json_encode([
    'ok'  => ($rc === 0),
    'msg' => trim(implode("\n", $out)),
]);
