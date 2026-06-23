<?php
/*
 * zfs-backup – HTML-Fragment für den Snapshots-Tab der GUI (lazy geladen).
 *
 * Rendert eine read-only Übersicht: Summen-Karten (--snapshots) sowie je Scope
 * (Quelle + jedes aktive Ziel) eine aufklappbare Dataset-Tabelle (--snapshot-
 * tree). Die Einzel-Snapshots eines Datasets werden erst beim Klick nachgeladen
 * (dataset-snapshots.php). KEINE ZFS-/Backup-Logik – nur Darstellung.
 *
 * Standard: Stand vom letzten Lauf aus dem State (`--cached`) – das fragt KEIN
 * zfs/SSH ab und weckt keine Backup-Platte/keinen schlafenden Remote. Nur mit
 * ?live=1 (Knopf „Aktualisieren") werden alle Ziele aktiv abgefragt (teuer).
 */

$cli  = '/usr/local/sbin/zfs-backup';
$live = isset($_GET['live']);
$mod  = $live ? '' : ' --cached';

function zb_h($v, string $fb = '–'): string {
    if ($v === null || $v === '' || $v === '-') return $fb;
    return htmlspecialchars((string)$v, ENT_QUOTES, 'UTF-8');
}
function zb_bytes($n): string {
    $n = (float)$n;
    $u = ['B','KiB','MiB','GiB','TiB','PiB'];
    $i = 0;
    while ($n >= 1024 && $i < count($u) - 1) { $n /= 1024; $i++; }
    $d = ($i === 0) ? 0 : ($n < 10 ? 2 : ($n < 100 ? 1 : 0));
    return number_format($n, $d) . ' ' . $u[$i];
}
function zb_cli_json(string $cli, string $args) {
    $out = [];
    $rc  = 0;
    exec(escapeshellarg($cli) . ' ' . $args . ' 2>/dev/null', $out, $rc);
    return json_decode(implode("\n", $out), true);
}

$ds   = zb_cli_json($cli, '--datasets --json' . $mod);
$sn   = zb_cli_json($cli, '--snapshots --json' . $mod);
$tree = zb_cli_json($cli, '--snapshot-tree --json' . $mod);

if (!is_array($ds) || !is_array($sn) || !is_array($tree)) {
    echo '<div class="zb-error"><strong>Snapshots konnten nicht gelesen werden.</strong><br>'
       . 'Die Aufrufe <code>--datasets</code> / <code>--snapshots</code> / <code>--snapshot-tree</code> '
       . 'lieferten kein gültiges JSON.</div>';
    exit;
}

$active   = $ds['active'] ?? [];
$excluded = $ds['auto_excluded'] ?? [];
$tot      = $sn['source']['totals'] ?? [];
$tg       = $sn['targets'] ?? [];
$scopes   = $tree['scopes'] ?? [];
?>

<p class="muted" style="margin:0 0 10px">
<?php if ($live): ?>
  Live abgefragt – alle aktiven Ziele wurden direkt per <code>zfs</code> geprüft.
<?php else: ?>
  Stand: <strong>letzter Lauf</strong> (aus dem Cache, ohne eine Platte zu wecken).
  Der Bestand ändert sich nur während eines Laufs; „Aktualisieren" prüft alle Ziele live.
<?php endif; ?>
</p>

<div class="zb-cards">
  <div class="zb-card">
    <h3>Gesicherte Datasets</h3>
    <table>
      <tr><td class="k">Aktiv</td><td class="v"><?= count($active) ?></td></tr>
      <tr><td class="k">Includes</td><td class="v"><?= (int)($ds['includes'] ?? 0) ?></td></tr>
      <tr><td class="k">Excludes</td><td class="v"><?= (int)($ds['excludes'] ?? 0) ?></td></tr>
    </table>
  </div>
  <div class="zb-card">
    <h3>Snapshots Quelle</h3>
    <table>
      <tr><td class="k">Stündlich</td><td class="v"><?= (int)($tot['hourly'] ?? 0) ?></td></tr>
      <tr><td class="k">Täglich</td><td class="v"><?= (int)($tot['daily'] ?? 0) ?></td></tr>
      <tr><td class="k">Wöchentlich</td><td class="v"><?= (int)($tot['weekly'] ?? 0) ?></td></tr>
      <tr><td class="k">Monatlich</td><td class="v"><?= (int)($tot['monthly'] ?? 0) ?></td></tr>
      <tr><td class="k">Jährlich</td><td class="v"><?= (int)($tot['yearly'] ?? 0) ?></td></tr>
      <tr><td class="k"><strong>Gesamt</strong></td><td class="v"><strong><?= (int)($tot['total'] ?? 0) ?></strong></td></tr>
    </table>
  </div>
  <?php if (!empty($tg['local']) || !empty($tg['remote'])): ?>
  <div class="zb-card">
    <h3>Snapshots Ziele</h3>
    <table>
      <tr><td class="k">Lokal</td><td class="v"><?= !empty($tg['local']) ? (int)$tg['local']['total'] : '–' ?></td></tr>
      <tr><td class="k">Remote</td><td class="v"><?= !empty($tg['remote']) ? (int)$tg['remote']['total'] : '–' ?></td></tr>
    </table>
  </div>
  <?php endif; ?>
</div>

<?php
  // Scope-Akkordeon: Quelle + jedes aktive Ziel. Köpfe + Dataset-Tabellen werden
  // serverseitig aus dem Cache gerendert (billig); die Einzel-Snapshots eines
  // Datasets lädt JS erst beim Klick nach (dataset-snapshots.php).
  $kindLabel = ['source' => 'Quelle', 'local' => 'Lokales Ziel', 'remote' => 'Remote-Ziel', 'borg' => 'Borg-Ziel'];
?>
<h3 class="zb-sub">Snapshots je Quelle &amp; Ziel</h3>
<div id="zb-scopes">
<?php if (count($scopes) === 0): ?>
  <p class="muted">Noch kein Bestand erfasst – nach dem ersten Lauf erscheinen hier Quelle und Ziele.</p>
<?php else: foreach ($scopes as $sc):
    $sid   = (string)($sc['id'] ?? '');
    $kind  = (string)($sc['kind'] ?? 'source');
    $label = (string)($sc['label'] ?? $sid);
    $rows  = $sc['datasets'] ?? [];
    $st    = $sc['totals'] ?? [];
    $open  = false;   // alle Scopes standardmäßig zugeklappt
?>
  <div class="zb-scope<?= $open ? ' open' : '' ?>">
    <div class="zb-scope-head" data-scope-toggle>
      <span class="zb-caret">▸</span>
      <span class="zb-scope-kind"><?= zb_h($kindLabel[$kind] ?? $kind) ?></span>
      <span class="zb-scope-label"><?= zb_h($label) ?></span>
      <span class="zb-scope-sum"><?= (int)($st['total'] ?? 0) ?> Snapshots ·
        <?= zb_bytes($st['used'] ?? 0) ?> belegt</span>
    </div>
    <div class="zb-scope-body"<?= $open ? '' : ' style="display:none"' ?>>
      <table class="zb-tg">
        <thead>
          <tr>
            <th>Dataset</th>
            <th class="num">Stündl.</th><th class="num">Tägl.</th><th class="num">Wöch.</th>
            <th class="num">Monatl.</th><th class="num">Jährl.</th><th class="num">Gesamt</th>
            <th class="num" title="Summe des exklusiv belegten Platzes aller Snapshots dieses Datasets – wird beim Löschen frei">Belegt</th>
          </tr>
        </thead>
        <tbody>
          <?php if (count($rows) === 0): ?>
            <tr><td colspan="8" class="empty">Keine Datasets.</td></tr>
          <?php else: foreach ($rows as $row): $rds = (string)($row['dataset'] ?? ''); ?>
            <tr class="zb-ds-row" data-ds="<?= zb_h($rds, '') ?>" data-scope="<?= zb_h($sid, '') ?>"
                title="Snapshots anzeigen">
              <td><span class="zb-caret">▸</span> <?= zb_h($rds) ?></td>
              <td class="num"><?= (int)($row['hourly'] ?? 0) ?></td>
              <td class="num"><?= (int)($row['daily'] ?? 0) ?></td>
              <td class="num"><?= (int)($row['weekly'] ?? 0) ?></td>
              <td class="num"><?= (int)($row['monthly'] ?? 0) ?></td>
              <td class="num"><?= (int)($row['yearly'] ?? 0) ?></td>
              <td class="num"><strong><?= (int)($row['total'] ?? 0) ?></strong></td>
              <td class="num"><?= zb_bytes($row['used'] ?? 0) ?></td>
            </tr>
            <tr class="zb-ds-detail" style="display:none"><td colspan="8"></td></tr>
          <?php endforeach; ?>
            <tr class="zb-tot">
              <td><strong>Gesamt</strong></td>
              <td class="num"><?= (int)($st['hourly'] ?? 0) ?></td>
              <td class="num"><?= (int)($st['daily'] ?? 0) ?></td>
              <td class="num"><?= (int)($st['weekly'] ?? 0) ?></td>
              <td class="num"><?= (int)($st['monthly'] ?? 0) ?></td>
              <td class="num"><?= (int)($st['yearly'] ?? 0) ?></td>
              <td class="num"><strong><?= (int)($st['total'] ?? 0) ?></strong></td>
              <td class="num"><strong><?= zb_bytes($st['used'] ?? 0) ?></strong></td>
            </tr>
          <?php endif; ?>
        </tbody>
      </table>
    </div>
  </div>
<?php endforeach; endif; ?>
</div>

<?php if (count($excluded) > 0): ?>
  <p class="muted" style="margin-top:14px">Automatisch ausgeschlossen (Laufzeit/Programm):
    <?= zb_h(implode(', ', $excluded)) ?>.</p>
<?php endif; ?>
