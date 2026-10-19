<?php
/**
 * hello_bus.php - "bus" protocol example for a cli_bridges route
 * (see the "hello-bus-php" entry in vdrx.conf, prefix "/hello").
 *
 * Unlike the "cgi" protocol (see phpcli/index.php), a bus-mode script
 * doesn't get CGI env vars or a per-path script file lookup - it gets
 * spawned fresh, reads exactly ONE JSON line off STDIN describing the
 * whole request, and must write exactly ONE JSON line back to STDOUT
 * before exiting. See RunBusCLIScript's comment in vdrx_network.pas for
 * the full contract; the short version:
 *
 *   stdin  (one line): {"method":"GET","path":"/hello/channel/%23blah",
 *                        "prefix":"/hello","sub_path":"/channel/%23blah",
 *                        "query":"name=World","headers":{...},"body":""}
 *   stdout (one line): {"status":200,"body":"..."} - or see
 *                        template_demo.php for the "template" form.
 *
 * "prefix" is this route's base_uri (vdrx.conf's "prefix": "/hello") -
 * VDRX doesn't parse anything past it as a file path or otherwise; the
 * whole remainder of the URL is just handed to you as data in "sub_path"
 * and "query", to interpret however you like. Try both of these and
 * compare what arrives:
 *
 *   http://<host>:8081/hello?name=World
 *   http://<host>:8081/hello/name/World
 *
 * One real gotcha worth knowing up front: a literal '#' in a URL (e.g. an
 * IRC channel name like "#test") is a browser-side FRAGMENT delimiter -
 * the browser strips it and everything after it before the request ever
 * reaches the server, unless it's percent-encoded as %23. So a link built
 * as href="/hello/channel/#test" will NOT deliver "#test" to this script;
 * href="/hello/channel/%23test" will. Same applies to a query string value
 * like ?channel=#test - encode it as ?channel=%23test.
 */

declare(strict_types=1);

$raw = trim((string)fgets(STDIN));
$req = json_decode($raw, true);
if (!is_array($req)) {
    $req = [];
}

$body  = "hello from hello_bus.php\n\n";
$body .= 'method:   ' . ($req['method'] ?? '') . "\n";
$body .= 'path:     ' . ($req['path'] ?? '') . "\n";
$body .= 'prefix:   ' . ($req['prefix'] ?? '') . "\n";
$body .= 'sub_path: ' . ($req['sub_path'] ?? '') . "\n";
$body .= 'query:    ' . ($req['query'] ?? '') . "\n";

$qs = [];
parse_str((string)($req['query'] ?? ''), $qs);
if (!empty($qs)) {
    $body .= "\nparsed query params:\n";
    foreach ($qs as $k => $v) {
        $body .= "  {$k} = {$v}\n";
    }
}

if (!empty($req['sub_path']) && $req['sub_path'] !== '/') {
    $parts = array_values(array_filter(explode('/', (string)$req['sub_path'])));
    $body .= "\nparsed sub_path segments:\n";
    foreach ($parts as $i => $seg) {
        $body .= "  [{$i}] " . urldecode($seg) . "\n";
    }
}

$response = [
    'status' => 200,
    'body'   => $body,
];

// The ONE line this script is allowed to write to stdout - see the
// contract note above. Anything else (debug output, errors) should go to
// a local log file instead, exactly like scripts/irc_soylent.php already
// does for its own persistent-process stdin/stdout protocol.
fwrite(STDOUT, json_encode($response) . "\n");
