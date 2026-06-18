<?php
/*
 * zfs-backup – Datei/Ordner aus einem Snapshot wiederherstellen (Restore).
 *
 * Reiner Transport: die eigentliche Arbeit macht der Kern
 * (`--snapshot-restore <ds> <snap> <scope> <pfad> progress`). Kopiert NICHT
 * destruktiv in den _restore-Ordner des QUELL-Datasets (<quell-mp>/_restore/<snap>/,
 * überschreibt nie). scope = source (Quell-Snapshot) ODER Ziel-ID (Replikat
 * lokal/remote; <ds> ist dann das Ziel-Dataset, der Kern leitet das Quell-Dataset
 * ab und prüft, dass es existiert). Leerer <pfad> = GANZER Snapshot (sonst
 * Datei/Ordner darunter). Schreibt ins Dataset -> POST. CSRF prüft Unraid global
 * (auto_prepend); das Formular sendet den Token mit.
 *
 * Antwort: text/plain, live gestreamt. Der Kern meldet während des Kopierens
 * Zeilen "FORTSCHRITT <pct>" (bzw. "FORTSCHRITT -1 <bytes>" wenn die Gesamtgröße
 * unbekannt ist) und am Ende "ZIEL <zielpfad>"; die letzte Zeile trägt den
 * Exit-Code ("[Exit-Code: N]"). Die GUI rendert daraus einen Fortschrittsbalken.
 */

header('Content-Type: text/plain; charset=utf-8');
header('X-Accel-Buffering: no');       // nginx-Pufferung aus, damit live ankommt

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    http_response_code(405);
    echo "POST erforderlich\n[Exit-Code: 1]\n";
    exit;
}

$cli   = '/usr/local/sbin/zfs-backup';
$ds    = (string)($_POST['ds'] ?? '');
$snap  = (string)($_POST['snap'] ?? '');
$scope = (string)($_POST['scope'] ?? 'source');
$path  = (string)($_POST['path'] ?? '');

if ($scope === '' || !preg_match('/^[A-Za-z0-9_]+$/', $scope)) {
    $scope = 'source';
}
// Leerer Pfad ist erlaubt und bedeutet: GANZER Snapshot (Sicherheit prüft der
// Kern). Dataset und Snapshot müssen aber gesetzt sein.
if ($ds === '' || $snap === '') {
    http_response_code(400);
    echo "Dataset/Snapshot fehlt\n[Exit-Code: 1]\n";
    exit;
}

@set_time_limit(0);                    // große Restores (WOL, viele GB) können dauern
while (ob_get_level() > 0) { ob_end_flush(); }

$cmd = escapeshellarg($cli) . ' --snapshot-restore '
     . escapeshellarg($ds) . ' ' . escapeshellarg($snap) . ' '
     . escapeshellarg($scope) . ' ' . escapeshellarg($path) . ' '
     . escapeshellarg('progress') . ' 2>&1';

$ph = popen($cmd, 'r');
if ($ph === false) {
    echo "Fehler: Restore konnte nicht gestartet werden.\n[Exit-Code: 1]\n";
    exit;
}
while (!feof($ph)) {
    $line = fgets($ph);
    if ($line !== false) { echo $line; flush(); }
}
$rc = pclose($ph);
echo "\n[Exit-Code: " . (int)$rc . "]\n";
exit;
