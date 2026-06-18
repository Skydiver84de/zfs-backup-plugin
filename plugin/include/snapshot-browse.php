<?php
/*
 * zfs-backup – Verzeichnisinhalt EINES Snapshots als JSON (Datei-Browser).
 *
 * Reiner Transport: das Listing macht der Kern (`--snapshot-ls <ds>
 * <snap> <scope> [pfad] --json`). ACHTUNG: liest tatsächlich ins Dataset
 * (.zfs/snapshot) und WECKT ggf. die Platte/den Remote – bewusste Nutzeraktion
 * (Klick auf einen Snapshot). GET, read-only (kein CSRF).
 *
 * scope = "source" (Quelle) oder eine Ziel-ID. Grundlage fürs spätere Restore.
 */

header('Content-Type: application/json');

$cli   = '/usr/local/sbin/zfs-backup';
$ds    = (string)($_GET['ds'] ?? '');
$snap  = (string)($_GET['snap'] ?? '');
$scope = (string)($_GET['scope'] ?? 'source');
$path  = (string)($_GET['path'] ?? '');

if ($scope === '' || !preg_match('/^[A-Za-z0-9_]+$/', $scope)) {
    $scope = 'source';
}
if ($ds === '' || $snap === '') {
    echo json_encode(['error' => 'Dataset/Snapshot fehlt', 'entries' => []]);
    exit;
}

$out = [];
$rc  = 0;
exec(escapeshellarg($cli) . ' --snapshot-ls '
   . escapeshellarg($ds) . ' ' . escapeshellarg($snap) . ' '
   . escapeshellarg($scope) . ' ' . escapeshellarg($path) . ' --json 2>/dev/null',
   $out, $rc);
$json = json_decode(implode("\n", $out), true);

echo is_array($json) ? json_encode($json)
    : json_encode(['error' => 'Snapshot nicht lesbar', 'entries' => []]);
