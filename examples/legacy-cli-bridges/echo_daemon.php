<?php
/**
 * echo_daemon.php - a "processes" entry (persistent, restart:"always"),
 * subscribed to an in_topic that a "bus-daemon" protocol cli_bridges route
 * publishes requests to. Proves the persistent-subscriber counterpart to
 * hello_bus.php's spawn-per-request model: this process starts once and
 * answers every request for as long as it's subscribed, instead of being
 * spawned fresh each time.
 *
 * Wire format is layered - this is a normal vdrx_bridge.pas subscriber, so
 * every line on STDIN is the Bridge envelope:
 *   {"topic":"echo.daemon.in","payload":"<the actual HTTP request envelope>","source":"..."}
 * "payload" is itself the same JSON RunBusDaemonRoute publishes for any bus
 * route - {"method","path","prefix","sub_path","query","headers","body",
 * "reply_to"} - so it's decoded a second time to get at "reply_to" and the
 * request fields.
 *
 * To answer, this writes a Bridge STRUCTURED publish line - {"topic":
 * "<reply_to>","payload":"<the HTTP reply envelope>"} - which only works
 * because this route's "publish" allow-list includes a pattern matching
 * reply_to (see vdrx.conf's "echo_daemon" processes entry, "publish":
 * ["http.reply.*"] - reply_to topics are always "http.reply.N").
 *
 * Config: "echo-daemon-route" cli_bridges entry (protocol "bus-daemon",
 * prefix "/echo-daemon", in_topic "echo.daemon.in") + "echo_daemon"
 * processes entry (subscribe ["echo.daemon.in"], publish ["http.reply.*"]).
 * Try: http://<host>:8081/echo-daemon?x=1
 */

declare(strict_types=1);

while (($line = fgets(STDIN)) !== false) {
    $line = trim($line);
    if ($line === '') {
        continue;
    }

    $envelope = json_decode($line, true);
    if (!is_array($envelope) || !isset($envelope['payload'])) {
        continue;
    }

    // NOTE: unlike a plain-text bus payload (an IRC line, say), vdrx_bridge.pas's
    // EnsureJSONPayload embeds an already-JSON payload as a genuine nested
    // object rather than double-encoding it as a string - so $envelope['payload']
    // is already the decoded request array here, not a string needing a second
    // json_decode(). (A raw-text payload would arrive as an actual string instead.)
    $request = $envelope['payload'];
    if (!is_array($request) || empty($request['reply_to'])) {
        continue;
    }

    $body = "hello from echo_daemon.php (persistent, pid " . getmypid() . ")\n\n" .
        'method:   ' . ($request['method'] ?? '') . "\n" .
        'path:     ' . ($request['path'] ?? '') . "\n" .
        'sub_path: ' . ($request['sub_path'] ?? '') . "\n" .
        'query:    ' . ($request['query'] ?? '') . "\n";

    $reply = [
        'topic'   => $request['reply_to'],
        'payload' => json_encode(['status' => 200, 'body' => $body]),
    ];

    fwrite(STDOUT, json_encode($reply) . "\n");
}
