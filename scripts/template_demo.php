<?php
/**
 * template_demo.php - "bus" protocol example showing the OTHER reply shape
 * RunBusCLIScript accepts: instead of a raw "body", give it a "template"
 * name plus "params" (-> %%var%% substitution) and "rows"
 * (-> ##loop:name##...##endloop:name## blocks), and VDRX's own
 * TVDRX_TemplateStore.Fill (vdrx_templates.pas) renders the actual HTML
 * server-side - this script never touches markup at all, see
 * templates/greeting.tpl.
 *
 * Config: the "template-demo-php" cli_bridges entry, prefix
 * "/template-demo". Since cli_bridges is shared across every http_sites
 * entry but each SITE has its own TVDRX_TemplateStore, "greeting.tpl" is
 * looked up under whichever site's "template_dir" actually received the
 * request - here that's the "vdrx_admin" site (port 8081, template_dir
 * "templates").
 *
 * Try:
 *   http://<host>:8081/template-demo
 *   http://<host>:8081/template-demo?name=Jared
 */

declare(strict_types=1);

$raw = trim((string)fgets(STDIN));
$req = json_decode($raw, true);
if (!is_array($req)) {
    $req = [];
}

$qs = [];
parse_str((string)($req['query'] ?? ''), $qs);
$name = !empty($qs['name']) ? (string)$qs['name'] : 'World';

$response = [
    'status'   => 200,
    'template' => 'greeting',
    'params'   => [
        'name'     => $name,
        'sub_path' => (string)($req['sub_path'] ?? ''),
    ],
    // Each entry becomes one pass through greeting.tpl's
    // ##loop:messages##...##endloop:messages## block, with that row's
    // fields available as %%from%% / %%text%% inside the loop body only.
    'rows' => [
        'messages' => [
            ['from' => 'vdrx',   'text' => 'this list came from a "rows" array in the reply JSON'],
            ['from' => 'script', 'text' => 'add or remove entries here and reload to see the loop react'],
        ],
    ],
];

fwrite(STDOUT, json_encode($response) . "\n");
