<?php
// confserver.php - lets tools/conf_viewer.html read vdrx config files over the bus.
// Run by the "confserver" runner (see example.vdrx.conf): php confserver.php <path>
// Prints {"path": <resolved path>, "text": <file contents>} and exits 0.
// Exit 1 = not found, 2 = refused (the runner maps these to status 404 / 403).
//
// Only files under $roots with an extension in $exts can be read. A relative
// path is tried under each root in turn; an absolute one must still land inside
// a root. Add your own project folders to $roots (e.g. 'C:/dev').
$roots = [dirname(__DIR__)];
$exts  = ['conf', 'json'];

$req = str_replace('\\', '/', $argv[1] ?? '');
if ($req === '' || strpos($req, "\0") !== false) { fwrite(STDERR, "no path\n"); exit(1); }

$win = PHP_OS_FAMILY === 'Windows';
$under = function ($p, $r) use ($win) {
  $r = rtrim(str_replace('\\', '/', $r), '/') . '/';
  return $win ? stripos($p, $r) === 0 : strpos($p, $r) === 0;
};
$cands = preg_match('~^([a-zA-Z]:)?/~', $req) ? [$req] : array_map(fn($r) => rtrim($r, '/\\') . '/' . $req, $roots);
foreach ($cands as $c) {
  $p = realpath($c);
  if ($p === false || !is_file($p)) continue;
  $p = str_replace('\\', '/', $p);
  $ok = in_array(strtolower(pathinfo($p, PATHINFO_EXTENSION)), $exts, true);
  $in = false;
  foreach ($roots as $r) { $rr = realpath($r); if ($rr !== false && $under($p, $rr)) $in = true; }
  if (!$ok || !$in) { fwrite(STDERR, "refused: $p\n"); exit(2); }
  echo json_encode(['path' => $p, 'text' => file_get_contents($p)], JSON_INVALID_UTF8_SUBSTITUTE | JSON_UNESCAPED_SLASHES);
  exit(0);
}
fwrite(STDERR, "not found: $req\n");
exit(1);
