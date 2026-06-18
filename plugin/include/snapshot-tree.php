<?php
/*
 * zfs-backup – Scope-Übersicht (Quelle + jedes aktive Ziel) als JSON.
 *
 * Reiner Transport: die Zählung/Größen liefert der Kern
 * (`--snapshot-tree --json`) aus dem am Lauf-Ende erfassten State. Standard
 * (--cached) weckt KEINE Platte/keinen schlafenden Remote; nur ?live=1 (Knopf
 * „Live aktualisieren") fragt alle Ziele aktiv ab. GET, read-only (kein CSRF).
 */

header('Content-Type: application/json');

$cli  = '/usr/local/sbin/zfs-backup';
$live = isset($_GET['live']);
$mod  = $live ? '' : ' --cached';

$out = [];
exec(escapeshellarg($cli) . ' --snapshot-tree --json' . $mod . ' 2>/dev/null', $out);
$json = json_decode(implode("\n", $out), true);

echo is_array($json) ? json_encode($json) : json_encode(['scopes' => []]);
