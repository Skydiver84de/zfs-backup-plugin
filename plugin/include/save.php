<?php
/*
 * zfs-backup – Speicher-Endpoint für das GUI-Konfigurationsformular.
 *
 * Nimmt geänderte Felder per POST entgegen und reicht jedes über die
 * bestehende headless-Schnittstelle (--set-config) an den Kern weiter.
 * KEINE eigene Validierung/ZFS-Logik hier: die Validierung passiert
 * in set_config_option_value; dieser Endpoint ist nur Transport.
 *
 * Antwort: {"results":{"<OPTION>":{"ok":bool,"msg":"..."}, ...}}
 */

header('Content-Type: application/json');

/* Nur POST. CSRF wird NICHT hier geprüft: Unraid validiert den mitgesendeten
 * csrf_token bereits global (auto_prepend) und entfernt ihn danach aus $_POST.
 * Eine zusätzliche Prüfung hier würde immer fehlschlagen (Token ist konsumiert).
 * Das Formular sendet den Token weiterhin mit, damit Unraids Prüfung greift. */
if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    http_response_code(405);
    echo json_encode(['error' => 'POST erforderlich']);
    exit;
}

$cli    = '/usr/local/sbin/zfs-backup';
$fields = $_POST['fields'] ?? [];
$results = [];

if (is_array($fields)) {
    foreach ($fields as $name => $value) {
        /* Optionsnamen sind streng begrenzt (Schema-Konvention: A-Z, 0-9, _).
         * Schützt vor missbräuchlichen Argumenten, bevor überhaupt der Kern läuft. */
        if (!preg_match('/^[A-Z][A-Z0-9_]*$/', (string)$name)) {
            $results[$name] = ['ok' => false, 'msg' => 'Ungültiger Optionsname'];
            continue;
        }
        $out = [];
        $rc  = 0;
        exec(
            escapeshellarg($cli) . ' --set-config ' .
            escapeshellarg((string)$name) . ' ' .
            escapeshellarg((string)$value) . ' 2>&1',
            $out, $rc
        );
        $results[$name] = [
            'ok'  => ($rc === 0),
            'msg' => trim(implode("\n", $out)),
        ];
    }
}

echo json_encode(['results' => $results]);
