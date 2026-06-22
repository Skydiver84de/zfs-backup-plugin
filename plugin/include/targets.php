<?php
/*
 * zfs-backup – Aktions-Endpoint für die Ziele-Verwaltung der GUI.
 *
 * Reicht Ziel-Aktionen über die bestehende headless-Schnittstelle an den Kern
 * weiter. KEINE eigene ZFS-/Validierungslogik: id/Feld/Wert gehen durch
 * die bestehende Validierung in target_create/target_edit_field/target_test.
 * CSRF prüft Unraid global (auto_prepend); das Formular sendet den Token mit.
 *
 * POST-Parameter:
 *   action=add      label, type(local|remote), base, [host]  (ID wird automatisch vergeben)
 *   action=delete   id (numerisch)
 *   action=test     id (numerisch)
 *   action=edit     id (numerisch), fields[FELD]=WERT … (mehrere erlaubt)
 *   action=move     id (numerisch), dir(up|down)            (eine Position verschieben)
 *   action=reorder  order=ID,ID,…                           (komplette Backup-Reihenfolge)
 *
 * Antwort:
 *   {"ok":bool,"msg":"..."}                       (add/delete/test/move/reorder)
 *   {"results":{"<FELD>":{"ok":bool,"msg":".."}}} (edit)
 */

header('Content-Type: application/json');

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    http_response_code(405);
    echo json_encode(['error' => 'POST erforderlich']);
    exit;
}

$cli    = '/usr/local/sbin/zfs-backup';
$action = (string)($_POST['action'] ?? '');
$id     = (string)($_POST['id'] ?? '');

/* IDs sind numerisch (automatisch vergeben). delete/test/edit brauchen eine
 * gültige ID; add nicht (dort kommt das Label, die ID vergibt der Kern).
 * Erst-Härtung vor dem Kern; die eigentliche Prüfung macht target_*. */
if (in_array($action, ['delete', 'test', 'edit', 'move'], true)
    && ($id === '' || !preg_match('/^[0-9]+$/', $id))) {
    http_response_code(400);
    echo json_encode(['error' => 'Ungültige Ziel-ID']);
    exit;
}

/* Führt zfs-backup mit den Argumenten aus und liefert [ok, msg]. */
function zb_run(string $cli, array $args): array {
    $cmd = escapeshellarg($cli);
    foreach ($args as $a) {
        $cmd .= ' ' . escapeshellarg((string)$a);
    }
    $out = [];
    $rc  = 0;
    exec($cmd . ' 2>&1', $out, $rc);
    return [$rc === 0, trim(implode("\n", $out))];
}

/* Höchste vorhandene (numerische) Ziel-ID = die zuletzt angelegte, da IDs
 * lückenlos 1..N vergeben werden. Liefert '' wenn keine/Fehler. */
function zb_last_target_id(string $cli): string {
    $out = [];
    exec(escapeshellarg($cli) . ' --targets --json 2>/dev/null', $out);
    $arr = json_decode(implode("\n", $out), true);
    $max = 0;
    if (is_array($arr)) {
        foreach ($arr as $t) {
            $iid = (int)($t['id'] ?? 0);
            if ($iid > $max) $max = $iid;
        }
    }
    return $max > 0 ? (string)$max : '';
}

switch ($action) {

    case 'add':
        $label = (string)($_POST['label'] ?? '');
        $type  = (string)($_POST['type'] ?? '');
        $base  = (string)($_POST['base'] ?? '');
        $host  = (string)($_POST['host'] ?? '');
        if ($label === '') {
            http_response_code(400);
            echo json_encode(['ok' => false, 'msg' => 'Bezeichnung erforderlich']);
            break;
        }
        $args = ['--add-target', $label, $type, $base];
        if ($type === 'remote' && $host !== '') $args[] = $host;
        list($ok, $msg) = zb_run($cli, $args);
        echo json_encode(['ok' => $ok, 'msg' => $msg]);
        break;

    case 'add-borg':
        /* Borg-Ziel atomar anlegen: --add-target <label> borg <repo>, danach die
         * borg-Felder per --edit-target. Repo geht als „base"-Slot in --add-target.
         * Validierung bleibt im Kern (target_create/target_edit_field). */
        $label = (string)($_POST['label'] ?? '');
        $repo  = (string)($_POST['repo'] ?? '');
        $pass  = (string)($_POST['pass'] ?? '');
        $ssh   = (string)($_POST['ssh'] ?? '');
        $compact = (string)($_POST['compact'] ?? '');
        if ($label === '' || $repo === '') {
            http_response_code(400);
            echo json_encode(['ok' => false, 'msg' => 'Bezeichnung und Repo-URL sind erforderlich.']);
            break;
        }
        list($ok, $msg) = zb_run($cli, ['--add-target', $label, 'borg', $repo]);
        if (!$ok) { echo json_encode(['ok' => false, 'msg' => $msg]); break; }
        $newId = zb_last_target_id($cli);
        if ($newId === '') { echo json_encode(['ok' => false, 'msg' => 'Ziel angelegt, aber ID nicht ermittelbar.']); break; }
        $errs = [];
        foreach ([['SSH_OPTIONS', $ssh], ['COMPACT_EVERY', $compact], ['PASSPHRASE', $pass]] as $f) {
            if ($f[1] === '') continue;   // leer = Default/ungesetzt lassen
            list($eok, $emsg) = zb_run($cli, ['--edit-target', $newId, $f[0], $f[1]]);
            if (!$eok) $errs[] = $f[0] . ': ' . $emsg;
        }
        if ($errs) {
            echo json_encode(['ok' => false, 'msg' => "Ziel angelegt (ID $newId), aber: " . implode('; ', $errs)]);
        } else {
            echo json_encode(['ok' => true, 'msg' => "Borg-Ziel angelegt (ID $newId).", 'id' => $newId]);
        }
        break;

    case 'delete':
        list($ok, $msg) = zb_run($cli, ['--delete-target', $id]);
        echo json_encode(['ok' => $ok, 'msg' => $msg]);
        break;

    case 'test':
        /* Live-Ausgabe streamen (wie Unraids Plugin-Aktionen): Zeile für Zeile,
         * nginx-Pufferung aus, kein Zeitlimit (Remote-Test kann per WOL dauern).
         * Antwort ist text/plain; die letzte Zeile trägt den Exit-Code. */
        header('Content-Type: text/plain; charset=utf-8');
        header('X-Accel-Buffering: no');
        @set_time_limit(0);
        while (ob_get_level() > 0) { ob_end_flush(); }
        $cmd = escapeshellarg($cli) . ' --test-target ' . escapeshellarg($id) . ' 2>&1';
        $ph  = popen($cmd, 'r');
        if ($ph === false) {
            echo "Fehler: Test konnte nicht gestartet werden.\n[Exit-Code: 1]\n";
            exit;
        }
        while (!feof($ph)) {
            $line = fgets($ph);
            if ($line !== false) { echo $line; flush(); }
        }
        $rc = pclose($ph);
        echo "\n[Exit-Code: " . (int)$rc . "]\n";
        exit;

    case 'move':
        $dir = (string)($_POST['dir'] ?? '');
        if (!in_array($dir, ['up', 'down'], true)) {
            http_response_code(400);
            echo json_encode(['ok' => false, 'msg' => 'Ungültige Richtung']);
            break;
        }
        list($ok, $msg) = zb_run($cli, ['--move-target', $id, $dir]);
        echo json_encode(['ok' => $ok, 'msg' => $msg]);
        break;

    case 'reorder':
        $order = (string)($_POST['order'] ?? '');
        if ($order === '' || !preg_match('/^[0-9]+(,[0-9]+)*$/', $order)) {
            http_response_code(400);
            echo json_encode(['ok' => false, 'msg' => 'Ungültige Reihenfolge']);
            break;
        }
        list($ok, $msg) = zb_run($cli, ['--reorder-targets', $order]);
        echo json_encode(['ok' => $ok, 'msg' => $msg]);
        break;

    case 'edit':
        $fields  = $_POST['fields'] ?? [];
        $results = [];
        if (is_array($fields)) {
            foreach ($fields as $field => $value) {
                if (!preg_match('/^[A-Z][A-Z0-9_]*$/', (string)$field)) {
                    $results[$field] = ['ok' => false, 'msg' => 'Ungültiger Feldname'];
                    continue;
                }
                list($ok, $msg) = zb_run($cli, ['--edit-target', $id, (string)$field, (string)$value]);
                $results[$field] = ['ok' => $ok, 'msg' => $msg];
            }
        }
        echo json_encode(['results' => $results]);
        break;

    default:
        http_response_code(400);
        echo json_encode(['error' => 'Unbekannte Aktion']);
}
