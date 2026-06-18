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
 *   action=add     label, type(local|remote), base, [host]   (ID wird automatisch vergeben)
 *   action=delete  id (numerisch)
 *   action=test    id (numerisch)
 *   action=edit    id (numerisch), fields[FELD]=WERT … (mehrere erlaubt)
 *
 * Antwort:
 *   {"ok":bool,"msg":"..."}                       (add/delete/test)
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
if (in_array($action, ['delete', 'test', 'edit'], true)
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
