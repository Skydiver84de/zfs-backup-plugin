<?php
/*
 * zfs-backup – HTML/Text-Fragment für den Logs-Tab der GUI (lazy geladen).
 *
 * Gibt die letzten N Zeilen des heutigen Logs über `--log-tail N` aus. KEINE
 * ZFS-/Backup-Logik – reine Anzeige. GET, read-only (kein CSRF nötig).
 */

$cli = '/usr/local/sbin/zfs-backup';

$n = isset($_GET['n']) ? (int)$_GET['n'] : 200;
if ($n < 1)    $n = 200;
if ($n > 5000) $n = 5000;

$out = [];
$rc  = 0;
exec(escapeshellarg($cli) . ' --log-tail ' . (int)$n . ' 2>/dev/null', $out, $rc);

header('Content-Type: text/plain; charset=utf-8');

if ($rc !== 0) {
    echo "Log konnte nicht gelesen werden (Exit-Code " . (int)$rc . ").";
    exit;
}
if (count($out) === 0) {
    echo "(Heute noch keine Logzeilen.)";
    exit;
}
echo implode("\n", $out);
