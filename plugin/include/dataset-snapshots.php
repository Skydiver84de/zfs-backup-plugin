<?php
/*
 * zfs-backup – verwaltete Snapshots EINES Datasets (Name, Größe, Zeit) als JSON.
 *
 * Reiner Transport: das Listing macht der Kern (`--dataset-snapshots <ds>
 * <scope> --json`) aus dem am Lauf-Ende erfassten State – KEIN Live-zfs, weckt
 * KEINE Platte (Quell-/Ziel-Datasets können auf HDD liegen). GET, read-only.
 *
 * scope = "source" (Quelle, Default) oder eine Ziel-ID. Grundlage fürs spätere
 * gezielte Wiederherstellen eines Snapshots.
 */

header('Content-Type: application/json');

$cli   = '/usr/local/sbin/zfs-backup';
$ds    = (string)($_GET['ds'] ?? '');
$scope = (string)($_GET['scope'] ?? 'source');

// Scope absichern (Kern prüft erneut): "source" oder numerische Ziel-ID.
if ($scope === '' || !preg_match('/^[A-Za-z0-9_]+$/', $scope)) {
    $scope = 'source';
}

if ($ds === '') {
    echo json_encode(['dataset' => '', 'scope' => $scope, 'snapshots' => []]);
    exit;
}

$out = [];
exec(escapeshellarg($cli) . ' --dataset-snapshots ' . escapeshellarg($ds)
   . ' ' . escapeshellarg($scope) . ' --json 2>/dev/null', $out);
$json = json_decode(implode("\n", $out), true);

echo is_array($json) ? json_encode($json) : json_encode(['dataset' => $ds, 'scope' => $scope, 'snapshots' => []]);
