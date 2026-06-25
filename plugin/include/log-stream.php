<?php
/*
 * zfs-backup – Server-Sent-Events-Stream für die Live-Status-Box der GUI.
 *
 * Schiebt jede neue Logzeile sofort an den Browser (Push statt Polling), indem
 * es dem Log des Kerns folgt (`--log-follow` => `tail -F`). KEINE ZFS-/Backup-
 * Logik: Logpfad und Status kommen aus dem Kern, hier wird nur
 * weitergereicht. GET, read-only (kein CSRF).
 *
 * Modi (?mode=):
 *   status (Standard) – für die Status-Box: erst der aktuelle Status, dann je
 *                       neue Logzeile (Start: letzte 1), alle 3 s ein Status-
 *                       Heartbeat (Phase) und bei Lauf-Ende ein „done"-Event.
 *   lines             – für den Logs-Tab: nur neue Logzeilen (Start: 0), ohne
 *                       Status/Ende-Logik, läuft auch ohne aktiven Lauf.
 *
 * Events:
 *   line   data: <Logzeile>
 *   status data: {"phase","pid","started","updated"}
 *   done   data: 1
 */

$cli  = '/usr/local/sbin/zfs-backup';
$mode = (($_GET['mode'] ?? '') === 'lines') ? 'lines' : 'status';
// Direkt nach „Lauf starten": auf den Hochlauf warten (run.php blockiert nicht).
$expect_starting = (($_GET['expect'] ?? '') === 'starting');

header('Content-Type: text/event-stream; charset=utf-8');
header('Cache-Control: no-cache');
header('X-Accel-Buffering: no');           // nginx-Pufferung aus
@set_time_limit(0);
// Skript NICHT bei Client-Disconnect sofort abbrechen, sondern selbst sauber
// beenden (Schleife verlassen, tail per proc_terminate stoppen). Ohne das würde
// im lines-Modus (kein Status-Heartbeat) bei stillem Log weder ein Schreib-
// versuch noch connection_aborted() erfolgen -> Worker/tail liefen ewig weiter.
ignore_user_abort(true);
while (ob_get_level() > 0) { ob_end_flush(); }

$last_out = time();   // Zeitpunkt der letzten Ausgabe (für Keepalive)

function sse(string $event, string $data): void {
    global $last_out;
    echo 'event: ' . $event . "\n";
    // Mehrzeiliges sicher abdecken (Logzeile ist i. d. R. einzeilig).
    foreach (explode("\n", $data) as $chunk) {
        echo 'data: ' . $chunk . "\n";
    }
    echo "\n";
    @ob_flush();
    @flush();
    $last_out = time();
}

/* SSE-Kommentar als Keepalive: hält die Verbindung offen UND erzeugt einen
 * Schreibversuch, damit connection_aborted() einen Disconnect erkennt. */
function sse_ping(): void {
    global $last_out;
    echo ": ping\n\n";
    @ob_flush();
    @flush();
    $last_out = time();
}

/* Liefert [running, status-json-array]. */
function read_status(string $cli): array {
    $out = [];
    exec(escapeshellarg($cli) . ' --status --json 2>/dev/null', $out);
    $st = json_decode(implode("\n", $out), true);
    return [is_array($st) && !empty($st['running']), $st];
}

function emit_status(array $st): void {
    $pg = $st['progress'] ?? [];
    sse('status', json_encode([
        'phase'   => $pg['phase']   ?? null,
        'detail'  => $pg['detail']  ?? null,
        'pid'     => $st['running_pid'] ?? null,
        'started' => $pg['started'] ?? null,
        'updated' => $pg['updated'] ?? null,
        'updated_epoch' => isset($pg['updated_epoch']) ? (int)$pg['updated_epoch'] : null,
    ]));
}

/* Eine --progress-follow-Zeile (TAB-getrennt) als status-Event senden.
 * Felder: phase, detail, started, updated, updated_epoch, pid. */
function emit_progress_line(string $line): void {
    $f = explode("\t", $line);
    sse('status', json_encode([
        'phase'   => $f[0] ?? null,
        'detail'  => $f[1] ?? null,
        'started' => $f[2] ?? null,
        'updated' => $f[3] ?? null,
        'updated_epoch' => (isset($f[4]) && $f[4] !== '') ? (int)$f[4] : null,
        'pid'     => (isset($f[5]) && $f[5] !== '') ? (int)$f[5] : null,
    ]));
}

// Status-Modus (Watch): läuft gerade etwas, sofort den aktuellen Status senden.
// Läuft nichts, wird NICHT beendet – stattdessen blockiert unten der
// `--progress-follow wait`-Kanal, bis ein Lauf beginnt (auch extern via Cron/CLI
// gestartet), und pusht dann. So zeigt eine offen liegende Statusseite jeden Lauf
// live, ohne dass der Browser pollen muss. (expect=starting ist damit obsolet,
// wird aber weiter akzeptiert.)
if ($mode === 'status') {
    list($running, $st) = read_status($cli);
    if ($running) {
        // Bisherige Aktivitäts-Historie des Laufs zuerst senden, damit die GUI-
        // Aktivitätsanzeige nach Tab-Wechsel/Reload den kompletten Verlauf zeigt
        // (nicht nur ab jetzt). Eine Zeile je Eintrag, im activity-Event vereint.
        $act = [];
        exec(escapeshellarg($cli) . ' --progress-activity 2>/dev/null', $act);
        if (!empty($act)) { sse('activity', implode("\n", $act)); }
        emit_status($st);
    } elseif (!$expect_starting) {
        // Kein Lauf aktiv und wir warten nicht auf einen Start (Reconnect z. B.
        // nach Tab-Rückkehr): dem Client mitteilen, dass nichts (mehr) läuft –
        // zeigte er noch „läuft", lädt er neu und sieht das Ergebnis. (Bei einer
        // leerlaufenden Statusseite ignoriert der Client das und wartet weiter.)
        sse('notrunning', '1');
    }
}

// proc_open (Array-Form, ohne Shell), damit die Prozesse beim Aufräumen gezielt
// per proc_terminate beendet werden können. Der Wrapper nutzt `exec`, die PID
// bleibt also bis zum eigentlichen Prozess erhalten. (popen+pclose würde an
// einem blockierten Handle hängen, wenn gerade nichts kommt.)
$descr = [1 => ['pipe', 'w'], 2 => ['file', '/dev/null', 'w']];

// Log-Follow immer: Status-Box braucht die aktuelle Zeile (Start 1), der
// Logs-Tab nur neue (Start 0).
$follow_n = ($mode === 'lines') ? 0 : 1;
$logProc = proc_open([$cli, '--log-follow', (string)$follow_n], $descr, $logPipes);
if (!is_resource($logProc)) {
    if ($mode === 'status') { sse('done', '1'); }
    exit;
}
$logFp = $logPipes[1];
stream_set_blocking($logFp, false);

// Status-Modus zusätzlich: Progress-Follow als zweiter Push-Kanal (Phase/Detail
// live). Endet der Lauf, beendet sich --progress-follow -> EOF -> „done".
$progProc = null;
$progFp   = null;
if ($mode === 'status') {
    // "wait": blockiert, bis ein Lauf beginnt, statt nach ~5 s aufzugeben – so
    // erkennt die offene Statusseite auch extern gestartete Läufe.
    $progProc = proc_open([$cli, '--progress-follow', 'wait'], $descr, $progPipes);
    if (is_resource($progProc)) {
        $progFp = $progPipes[1];
        stream_set_blocking($progFp, false);
    }
}

while (true) {
    if (connection_aborted()) break;

    $r = [$logFp];
    if ($progFp) { $r[] = $progFp; }
    $w = []; $e = [];
    $n = @stream_select($r, $w, $e, 1);
    if ($n === false) break;

    if ($n > 0) {
        // Neue Logzeile(n) -> sofort pushen.
        if (in_array($logFp, $r, true)) {
            while (($line = fgets($logFp)) !== false) {
                $line = rtrim($line, "\r\n");
                if ($line !== '') { sse('line', $line); }
            }
            if (feof($logFp)) break;   // tail beendet (z. B. Logrotation)
        }
        // Fortschritts-Änderung(en) -> als status-Event pushen.
        if ($progFp && in_array($progFp, $r, true)) {
            while (($line = fgets($progFp)) !== false) {
                $line = rtrim($line, "\r\n");
                if ($line !== '') { emit_progress_line($line); }
            }
            if (feof($progFp)) { sse('done', '1'); break; }   // Lauf beendet
        }
    }

    // Keepalive, falls länger nichts gesendet wurde (Disconnect erkennbar machen).
    if (time() - $last_out >= 15) {
        sse_ping();
    }
}

// Prozesse beenden und aufräumen.
proc_terminate($logProc);
fclose($logFp);
proc_close($logProc);
if (is_resource($progProc)) {
    proc_terminate($progProc);
    if ($progFp) { fclose($progFp); }
    proc_close($progProc);
}
