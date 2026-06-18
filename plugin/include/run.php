<?php
/*
 * zfs-backup – Endpoint zum Starten eines normalen Laufs aus der GUI.
 *
 * Startet `zfs-backup --run` losgelöst (setsid, im Hintergrund) und kehrt
 * SOFORT zurück (kein Warten auf den Hochlauf). Den Fortschritt zeigt danach
 * der Status-Stream der GUI (log-stream.php?mode=status&expect=starting).
 * KEINE ZFS-/Backup-Logik im PHP – nur Start und Vorab-Prüfung „läuft
 * schon?" über die headless-Schnittstelle. CSRF prüft Unraid global
 * (auto_prepend); das Formular sendet den Token mit.
 *
 * Antwort: {"ok":bool,"msg":"...",["running":true]}
 */

header('Content-Type: application/json');

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    http_response_code(405);
    echo json_encode(['ok' => false, 'msg' => 'POST erforderlich']);
    exit;
}

$cli = '/usr/local/sbin/zfs-backup';

/* Liest `--status --json` und gibt true zurück, wenn gerade ein Lauf aktiv ist. */
function zb_is_running(string $cli): bool {
    $out = [];
    exec(escapeshellarg($cli) . ' --status --json 2>/dev/null', $out);
    $st = json_decode(implode("\n", $out), true);
    return is_array($st) && !empty($st['running']);
}

if (zb_is_running($cli)) {
    echo json_encode(['ok' => false, 'running' => true,
        'msg' => 'Es läuft bereits ein Lauf.']);
    exit;
}

/* Losgelöst starten und SOFORT zurückkehren – der Request blockiert nicht. Den
 * Hochlauf (Config-Normalisierung, Lock) zeigt anschließend der Status-Stream
 * der GUI (log-stream.php?mode=status&expect=starting), der darauf wartet.
 * Eigene Session (setsid), Streams umgeleitet, Hintergrund – so überlebt der
 * Lauf das Request-Ende. Das Skript protokolliert selbst ins Logfile. */
$cmd = 'setsid ' . escapeshellarg($cli) . ' --run >/dev/null 2>&1 </dev/null &';
exec($cmd);

echo json_encode(['ok' => true, 'msg' => 'Lauf angestoßen.']);
