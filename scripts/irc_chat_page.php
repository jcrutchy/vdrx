<?php
/**
 * irc_chat_page.php - serves the IRC web client's page shell via VDRX's
 * own template engine, routed through the "admin_templates" executive by
 * explicit template_topic (not this site's own implicit template_dir - see
 * BuildBusCLIResponse's comment in vdrx_network.pas for why that matters).
 *
 * All the REALTIME behaviour (receiving/sending chat messages) happens
 * entirely client-side after this loads, over the existing WebSocket
 * JSON-RPC bridge talking directly to irc_bot.chat.event/irc_bot.chat.send -
 * this script's only job is rendering the initial page once per visit.
 *
 * Config: the "irc-chat-page" cli_bridges entry, prefix "/irc".
 * Try:
 *   http://<host>:8081/irc
 *   http://<host>:8081/irc?channel=%23vdrx   (note: %23, not # - see the
 *     readme's URL-fragment gotcha; a bare "#" never reaches the server)
 */

declare(strict_types=1);

$raw = trim((string)fgets(STDIN));
$req = json_decode($raw, true);
if (!is_array($req)) {
    $req = [];
}

$qs = [];
parse_str((string)($req['query'] ?? ''), $qs);
$channel = !empty($qs['channel']) ? (string)$qs['channel'] : '#vdrx';

// The template engine's %%var%% substitution is plain text replacement with
// no context-aware escaping, and $channel lands in BOTH an HTML text
// context (the page title/header) AND a raw JS string literal in the same
// template (templates/irc_chat.tpl) - a single value can't safely carry
// different escaping for two different contexts, so it's sanitized here
// instead, to a strict whitelist IRC channel names genuinely fit within
// (letters, digits, #, -, _). Anything else in the query value is just
// dropped rather than escaped - simpler and more robust than trying to
// make one substitution safe for two embedding contexts at once.
$channel = preg_replace('/[^A-Za-z0-9#_\-]/', '', $channel);
if ($channel === '' || $channel === '#') {
    $channel = '#vdrx';
}

$response = [
    'status'         => 200,
    'template'       => 'irc_chat',
    'template_topic' => 'template.admin.render',
    'params'         => [
        'channel'          => $channel,
        'ws_port'          => '8082',
        'chat_out_topic'   => 'irc_bot.chat.event',
        'chat_in_topic'    => 'irc_bot.chat.send',
    ],
];

fwrite(STDOUT, json_encode($response) . "\n");
