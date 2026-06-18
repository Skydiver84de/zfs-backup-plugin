<?php
/*
 * zfs-backup – EINE Datei aus einem Snapshot ausliefern (Download/Vorschau).
 *
 * Reiner Transport: den Inhalt liefert der Kern (`--snapshot-cat <ds>
 * <snap> <scope> <pfad>`), der strikt im Snapshot-Root bleibt (realpath-Check).
 * Liest ins Dataset und WECKT ggf. die Platte/den Remote – bewusste Nutzer-
 * aktion. GET, read-only (kein CSRF).
 *
 * mode=download (Default): roher Datei-Stream als Anhang.
 * mode=preview:           JSON {binary,truncated,text} bis 256 KB (Textvorschau).
 */

$cli   = '/usr/local/sbin/zfs-backup';
$ds    = (string)($_GET['ds'] ?? '');
$snap  = (string)($_GET['snap'] ?? '');
$scope = (string)($_GET['scope'] ?? 'source');
$path  = (string)($_GET['path'] ?? '');
$mode  = (($_GET['mode'] ?? '') === 'preview') ? 'preview' : 'download';

if ($scope === '' || !preg_match('/^[A-Za-z0-9_]+$/', $scope)) {
    $scope = 'source';
}
if ($ds === '' || $snap === '' || $path === '') {
    http_response_code(400);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'Parameter fehlt']);
    exit;
}

$cmd = escapeshellarg($cli) . ' --snapshot-cat '
     . escapeshellarg($ds) . ' ' . escapeshellarg($snap) . ' '
     . escapeshellarg($scope) . ' ' . escapeshellarg($path) . ' 2>/dev/null';

if ($mode === 'preview') {
    header('Content-Type: application/json');
    $limit = 256 * 1024;
    $data  = '';
    $fp = popen($cmd, 'r');
    if ($fp) {
        $data = stream_get_contents($fp, $limit + 1);
        pclose($fp);
    }
    if ($data === false) { $data = ''; }
    $truncated = strlen($data) > $limit;
    if ($truncated) { $data = substr($data, 0, $limit); }
    $binary = (strpos($data, "\0") !== false);
    $flags  = defined('JSON_INVALID_UTF8_SUBSTITUTE') ? JSON_INVALID_UTF8_SUBSTITUTE : 0;
    echo json_encode([
        'binary'    => $binary,
        'truncated' => $truncated,
        'text'      => $binary ? '' : $data,
    ], $flags);
    exit;
}

// Download: roher Stream als Anhang. Dateiname = letzte Pfadkomponente.
$base = basename(str_replace('\\', '/', $path));
$base = preg_replace('/[\x00-\x1f"\\\\]/', '_', $base);
if ($base === '' || $base === false) { $base = 'datei'; }

header('Content-Type: application/octet-stream');
header('Content-Disposition: attachment; filename="' . $base . '"; '
     . "filename*=UTF-8''" . rawurlencode($base));
header('X-Content-Type-Options: nosniff');

passthru($cmd, $rc);
