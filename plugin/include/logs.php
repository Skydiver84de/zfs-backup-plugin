<?php
/*
 * zfs-backup – HTML/Text-Fragment für den Logs-Tab der GUI (lazy geladen).
 *
 * ?list=1   -> verfügbare Tageslogs als Datum (YYYY-MM-DD), neueste zuerst
 *              (für die Datumsauswahl). Eine Zeile je Datum.
 * sonst     -> die letzten N Zeilen über `--log-tail N [DATE]`. Optionales
 *              ?date=YYYY-MM-DD wählt ein älteres Tageslog statt heute.
 * KEINE ZFS-/Backup-Logik – reine Anzeige. GET, read-only (kein CSRF nötig).
 */

$cli = '/usr/local/sbin/zfs-backup';

header('Content-Type: text/plain; charset=utf-8');

// Liste der verfügbaren Tageslogs (für das Datums-Dropdown).
if (isset($_GET['list'])) {
    $out = [];
    exec(escapeshellarg($cli) . ' --log-list 2>/dev/null', $out);
    echo implode("\n", $out);
    exit;
}

$n = isset($_GET['n']) ? (int)$_GET['n'] : 200;
if ($n < 1)    $n = 200;
if ($n > 5000) $n = 5000;

// Optionales Datum strikt validieren (der Kern prüft erneut).
$date = isset($_GET['date']) ? (string)$_GET['date'] : '';
if ($date !== '' && !preg_match('/^\d{4}-\d{2}-\d{2}$/', $date)) {
    $date = '';
}

$cmd = escapeshellarg($cli) . ' --log-tail ' . (int)$n;
if ($date !== '') {
    $cmd .= ' ' . escapeshellarg($date);
}
$cmd .= ' 2>/dev/null';

$out = [];
$rc  = 0;
exec($cmd, $out, $rc);

if ($rc !== 0) {
    echo "Log konnte nicht gelesen werden (Exit-Code " . (int)$rc . ").";
    exit;
}
if (count($out) === 0) {
    echo $date !== '' ? "(Keine Logzeilen für $date.)" : "(Heute noch keine Logzeilen.)";
    exit;
}
echo implode("\n", $out);
