<?php
/*
 * zfs-backup – baut die HTML-Kachel (<tbody>) für das Unraid-Dashboard.
 *
 * Wird von zfs-backup-dashboard.page in einem try/catch eingebunden (Vorbild:
 * Tailscale-Plugin), damit ein Fehler hier NIE das Dashboard zerschießt. Holt den
 * Status rein über die headless-CLI (`zfs-backup --status --json`, liest nur
 * State, weckt keine Platte) – keine ZFS-/Backup-Logik.
 *
 * Aufbau wie die nativen Tiles: das <tbody> wird per customTiles() direkt in die
 * Dashboard-Tabelle eingefügt; deshalb NUR einfache <tr>/<td>-Zeilen, KEINE
 * verschachtelte Tabelle (die würde das Dashboard-Layout/JS stören). Erste Zeile
 * = Titel, dann je eine Zeile Label/Wert.
 */
if (!function_exists('zfs_backup_dashboard_tile')) {
    function zfs_backup_dashboard_tile(): string {
        $out = [];
        exec("/usr/local/sbin/zfs-backup --status --json 2>/dev/null", $out);
        $st = json_decode(implode("\n", $out), true);

        $h = function ($v, $f = '–') {
            if ($v === null || $v === '' || $v === '-') return $f;
            return htmlspecialchars((string)$v, ENT_QUOTES, 'UTF-8');
        };
        $age = function ($hours) {
            if ($hours === null) return '';
            if ($hours < 1)  return 'vor ' . max(1, (int)round($hours * 60)) . ' min';
            if ($hours < 48) return 'vor ' . (int)round($hours) . ' h';
            return 'vor ' . (int)round($hours / 24) . ' Tagen';
        };
        // EINE Zelle pro Zeile (wie native Tiles): Label links, Wert per float
        // rechts. Zwei <td>-Spalten würden die Tabelle breiter als die Kachel
        // machen (Werte brachen über den rechten Kartenrand hinaus). Kompaktes
        // Padding, damit die Kachel nicht höher wird als die anderen Tiles.
        // Anordnung wie beim Tailscale-Tile: Label in fester Spaltenbreite, Wert
        // direkt dahinter LINKSbündig (nicht rechts am Rand). Alles in EINER Zelle
        // -> bleibt garantiert in der Kartenbreite. Nur vertikales Padding drosseln,
        // links/rechts auf dem nativen td-Default lassen (bündig zum Kopf).
        $row = function ($label, $value) {
            return '<tr><td style="padding-top:1px;padding-bottom:1px;border:0">'
                 . '<span class="grey-text" style="display:inline-block;box-sizing:border-box;min-width:160px;padding-right:8px;white-space:nowrap;vertical-align:top">' . $label . '</span>'
                 . '<span style="display:inline-block;vertical-align:top">' . $value . '</span>'
                 . '</td></tr>';
        };

        if (!is_array($st)) {
            $orb = 'red-orb'; $txt = 'nicht erreichbar'; $sub = '';
        } elseif (!empty($st['running'])) {
            $prog = is_array($st['progress'] ?? null) ? $st['progress'] : [];
            $orb = 'blue-orb';   $txt = 'läuft';    $sub = $h($prog['phase'] ?? null, '');
        } elseif (!empty($st['stale'])) {
            $orb = 'yellow-orb'; $txt = 'veraltet'; $sub = $age(isset($st['backup_age_hours']) ? (float)$st['backup_age_hours'] : null);
        } elseif (empty($st['has_run'])) {
            $orb = 'grey-orb';   $txt = 'bereit';   $sub = 'noch kein Lauf';
        } else {
            $orb = 'green-orb';  $txt = 'aktuell';  $sub = '';
        }
        $zustand = '<i class="fa fa-circle ' . $orb . '"></i> ' . $h($txt)
                 . ($sub !== '' ? ' <span class="grey-text">– ' . $h($sub) . '</span>' : '');

        $rows = '';
        if (is_array($st)) {
            $lr      = is_array($st['last_run'] ?? null) ? $st['last_run'] : [];
            $result  = $lr['result'] ?? '-';
            $orphans = (int)($st['orphan_datasets'] ?? 0);
            $srcOrphans = (int)($st['source_orphan_snapshots'] ?? 0);
            $tg      = is_array($st['targets'] ?? null) ? $st['targets'] : [];
            $dsc     = (int)($st['dataset_count'] ?? 0);
            $inv     = is_array($st['source_inventory'] ?? null) ? $st['source_inventory'] : [];

            if ($result === 'ERFOLG')      $res = '<span class="green-text">ERFOLG</span>';
            elseif ($result === 'FEHLER')  $res = '<span class="red-text">FEHLER</span>';
            else                           $res = '–';
            $rt = (!empty($lr['runtime_human']) && $lr['runtime_human'] !== '0s')
                ? ' <span class="grey-text">· ' . $h($lr['runtime_human']) . '</span>' : '';

            // Snapshot-Bestand der Quelle: Gesamt + Aufschlüsselung (H nur falls > 0).
            $total = (int)($inv['total'] ?? 0);
            $parts = [];
            if ((int)($inv['hourly'] ?? 0) > 0) $parts[] = 'H ' . (int)$inv['hourly'];
            $parts[] = 'D ' . (int)($inv['daily']   ?? 0);
            $parts[] = 'W ' . (int)($inv['weekly']  ?? 0);
            $parts[] = 'M ' . (int)($inv['monthly'] ?? 0);
            $parts[] = 'Y ' . (int)($inv['yearly']  ?? 0);
            $invHtml = $total . ($total > 0 ? ' <span class="grey-text">(' . implode(' · ', $parts) . ')</span>' : '');

            $rows .= $row('Letzter Lauf', $h($lr['timestamp'] ?? null) . ' &nbsp;' . $res . $rt);
            // "Letzter Erfolg" nur zeigen, wenn der letzte Lauf KEIN Erfolg war –
            // sonst wäre es mit dem Zeitpunkt oben redundant.
            if ($result !== 'ERFOLG') $rows .= $row('Letzter Erfolg', $h($st['last_success'] ?? null));
            $rows .= $row('Datasets', $dsc . ' gesichert');
            $rows .= $row('Snapshots (Quelle)', $invHtml);
            $rows .= $row('Aktive Ziele', (int)($tg['local_active'] ?? 0) . ' lokal &middot; ' . (int)($tg['remote_active'] ?? 0) . ' remote &middot; ' . (int)($tg['borg_active'] ?? 0) . ' borg');
            if ($orphans > 0 || $srcOrphans > 0) {
                $ow = [];
                if ($orphans > 0)    $ow[] = $orphans . ' Ziel-Dataset(s)';
                if ($srcOrphans > 0) $ow[] = $srcOrphans . ' Quell-Snapshot(s)';
                $rows .= $row('Verwaiste Datasets / Snapshots', '<span class="orange-text" style="font-weight:bold">' . implode(' &middot; ', $ow) . '</span>');
            }
        } else {
            $rows .= '<tr><td colspan="2" class="grey-text">zfs-backup nicht erreichbar – Plugin installiert?</td></tr>';
        }

        // Native Tile-Kopfzeile: Icon + Titel + Untertitel (Zustand) + Zahnrad.
        // Diese Struktur löst Unraids Standard-Controls aus (Zahnrad + Einklapp-
        // Pfeil oben rechts) und die native Titel-Optik (Großbuchstaben via CSS).
        $header = '<span class="tile-header">'
                . '<span class="tile-header-left">'
                . '<img src="/plugins/zfs-backup/zfs-backup.png" class="f32" style="width:32px;height:32px" alt="">'
                . '<div class="section">'
                . '<h3 class="tile-header-main">ZFS Backup</h3>'
                . '<span>' . $zustand . '</span>'
                . '</div>'
                . '</span>'
                . '<span class="tile-header-right">'
                . '<span class="tile-header-right-controls">'
                . '<a href="/Settings/zfs-backup"><i class="fa fa-fw fa-cog control" title="Einstellungen"></i></a>'
                . '</span>'
                . '</span>'
                . '</span>';

        return '<tbody title="ZFS Backup – Snapshots &amp; Replikation">'
             . '<tr><td>' . $header . '</td></tr>'
             . $rows
             // Abstandszeile unten, damit die letzte Zeile nicht am Kartenrand klebt.
             . '<tr><td style="padding:0 0 6px;border:0"></td></tr>'
             . '</tbody>';
    }
}
