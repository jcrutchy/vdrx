<?php
/**
 * irc_client.php
 *
 * A small IRC client protocol daemon meant to run as a VDRX-supervised
 * process (vdrx_bridge), subscribed to a TVDRX_SocketClientExecutive's
 * "<id>.out" topic and writing back to "<id>.in".
 *
 * VDRX owns the socket; this owns the protocol. It:
 *   - reads one JSON bus-message line at a time from STDIN (bridge's
 *     structured input format: {"topic":...,"payload":...,"source":...})
 *   - sends NICK/USER on startup
 *   - answers PING with PONG
 *   - optionally auto-joins a channel once registration completes (001)
 *   - writes JSON-wrapped {"topic":"<in-topic>","payload":"<irc line>"}
 *     lines to STDOUT for anything it wants sent to the server - this is
 *     the ONLY thing that should ever go to STDOUT (or STDERR - bridge
 *     merges the two), since both are read line-by-line as bus traffic.
 *     Anything this script wants to log for itself goes to a local file
 *     instead (see logLine()).
 *
 * Known limitation for this first pass: this script only knows to
 * register once, at its own startup. If VDRX's underlying TCP connection
 * drops and reconnects WITHOUT this process also restarting (e.g. a brief
 * blip that TVDRX_SocketClientExecutive's own reconnect logic recovers
 * from on its own), this script has no way to know a fresh NICK/USER is
 * needed - there's currently no "connected"/"disconnected" event on the
 * bus for it to react to. Fine for initial testing; worth fixing (an
 * event topic from the socket client) before relying on this for real.
 */

declare(strict_types=1);

// --- config, from CLI args (see vdrx.conf's "command" for this process) ---
$options = getopt('', ['nick:', 'user:', 'realname:', 'channel:', 'in-topic:', 'out-topic:', 'log:']);
$nick       = $options['nick']       ?? 'vdrxbot';
$user       = $options['user']       ?? 'vdrx';
$realname   = $options['realname']   ?? 'VDRX IRC Bridge';
$channel    = $options['channel']    ?? '#vdrx';           // optional, auto-joined after 001
$inTopic    = $options['in-topic']   ?? 'irc_bot.in';  // what the socket client writes to the socket
$outTopic   = $options['out-topic']  ?? 'freenode.out'; // what the socket client publishes reads as
$logFile    = $options['log']        ?? __DIR__ . '/irc_client.log';

$registered = false;

function logLine(string $line): void
{
    global $logFile;
    @file_put_contents($logFile, '[' . date('Y-m-d H:i:s') . '] ' . $line . "\n", FILE_APPEND);
}

// Sends a raw IRC line to the server by publishing it, JSON-wrapped, on
// $inTopic - TVDRX_SocketClientExecutive.HandlePacket writes the payload
// straight to the socket (plus its configured delimiter). Must be the
// ONLY thing written to STDOUT (see file header) and must be flushed
// immediately - PHP fully buffers STDOUT by default when it isn't a
// terminal (i.e. when piped, which is exactly bridge's setup), so without
// an explicit flush a line can sit unsent for a long time.
function sendLine(string $ircLine): void
{
    global $inTopic;
    $line = json_encode(['topic' => $inTopic, 'payload' => $ircLine]);
    fwrite(STDOUT, $line . "\n");
    fflush(STDOUT);
    logLine('-> ' . $ircLine);
}

function register(): void
{
    global $nick, $user, $realname;
    sendLine('NICK ' . $nick);
    sendLine('USER ' . $user . ' 0 * :' . $realname);
}

// One incoming line from the IRC server (already split by
// TVDRX_SocketClientExecutive's own delimiter framing - see its ReaderLoop
// - so this is always exactly one IRC line, no further splitting needed).
function handleIrcLine(string $line): void
{
    global $channel, $registered;

    logLine('<- ' . $line);

    // PING :<token> - must be answered promptly or the server times us out.
    if (str_starts_with($line, 'PING')) {
        $token = substr($line, strpos($line, ':') !== false ? strpos($line, ':') : 5);
        sendLine('PONG ' . $token);
        return;
    }

    // Numeric 001 = RPL_WELCOME - registration is complete. Auto-join once,
    // here, rather than blindly on startup (joining before registration
    // completes is rejected by the server).
    $parts = explode(' ', $line, 4);
    if (!$registered && isset($parts[1]) && $parts[1] === '376') {
        $registered = true;
        logLine('registration complete');
        if ($channel !== '') {
            sendLine('JOIN ' . $channel);
        }
    }
}

// --- main loop ---

logLine('starting - nick=' . $nick . ' user=' . $user . ' channel=' . $channel);
register();

while (($rawLine = fgets(STDIN)) !== false) {
    $rawLine = trim($rawLine);
    if ($rawLine === '') {
        continue;
    }

    // JSON_INVALID_UTF8_SUBSTITUTE: IRC has never mandated a text encoding
    // - a stray non-UTF-8 byte (a Windows-1252 smart quote from a services
    // bot is a common real example) is normal, expected traffic, not
    // malformed input. Without this flag, json_decode() fails the ENTIRE
    // line with a silent null on a single bad byte, even though the
    // surrounding JSON is syntactically well-formed - losing the whole
    // message over one character. This substitutes U+FFFD for the bad
    // byte(s) and decodes everything else normally instead.
    $msg = json_decode($rawLine, true, 512, JSON_INVALID_UTF8_SUBSTITUTE);
    if (!is_array($msg) || !isset($msg['topic'], $msg['payload'])) {
        // Not a structured bus message - shouldn't happen given bridge's
        // own input format, but don't crash the daemon over a malformed line.
        logLine('unparseable stdin line, ignoring: ' . $rawLine);
        continue;
    }

    if ($msg['topic'] === $outTopic) {
        handleIrcLine((string)$msg['payload']);
    }
    // Any other topic this process might one day be subscribed to would be
    // handled here too - none yet, so silently ignored.
}

// STDIN closed (bridge's CloseInput EOF hint, or the pipe just went away) -
// exit cleanly rather than looping on a permanently-false fgets.
logLine('stdin closed, exiting');
