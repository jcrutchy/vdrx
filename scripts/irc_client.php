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
 *   - parses incoming PRIVMSG/NOTICE lines into a structured chat event,
 *     published on its own topic (--chat-out-topic) for a browser (or
 *     anything else) subscribed there to pick up - see scripts/irc_chat_page.php
 *     and templates/irc_chat.tpl for the web client that actually uses this.
 *   - accepts a structured "send a message" request on --chat-in-topic and
 *     turns it into a real PRIVMSG on the wire
 *   - writes JSON-wrapped {"topic":"<some-topic>","payload":"<...>"}
 *     lines to STDOUT for anything it wants to say - this is the ONLY thing
 *     that should ever go to STDOUT (or STDERR - bridge merges the two),
 *     since both are read line-by-line as bus traffic. Anything this script
 *     wants to log for itself goes to a local file instead (see logLine()).
 *
 * One asymmetry worth understanding before touching either direction below,
 * since it's easy to get backwards (a mistake this file's own author nearly
 * made writing the chat-event side): a Bridge-managed process's INCOMING
 * envelope (what this script reads off STDIN) embeds an already-JSON
 * "payload" as a genuine nested value if the published payload was valid
 * JSON (vdrx_bridge.pas's EnsureJSONPayload) - so $msg['payload'] below may
 * already be a decoded PHP array, not a string needing another
 * json_decode(). Going the OTHER way, this script's own OUTGOING structured-
 * publish lines are parsed by vdrx_bridge.pas's TryParseStructuredLine,
 * which only accepts "payload" as a JSON STRING (not a nested object) - so
 * publishChatEvent() below deliberately json_encode()s the payload data
 * into a string before wrapping it, or Bridge would silently drop it as
 * empty. The two directions are NOT symmetric.
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
$options = getopt('', ['nick:', 'user:', 'realname:', 'channel:', 'in-topic:', 'out-topic:',
    'chat-in-topic:', 'chat-out-topic:', 'log:']);
$nick         = $options['nick']            ?? 'vdrxbot';
$user         = $options['user']            ?? 'vdrx';
$realname     = $options['realname']        ?? 'VDRX IRC Bridge';
$channel      = $options['channel']         ?? '#vdrx';           // optional, auto-joined after 001
$inTopic      = $options['in-topic']        ?? 'irc_bot.in';      // what the socket client writes to the socket
$outTopic     = $options['out-topic']       ?? 'freenode.out';    // what the socket client publishes reads as
$chatInTopic  = $options['chat-in-topic']   ?? 'irc_bot.chat.send';  // a browser -> "send this message"
$chatOutTopic = $options['chat-out-topic']  ?? 'irc_bot.chat.event'; // -> a browser: "this message arrived"
$logFile      = $options['log']             ?? __DIR__ . '/irc_client.log';

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

// See the file header's asymmetry note - "payload" here is deliberately a
// json_encode()d STRING, not the raw $data array, because
// vdrx_bridge.pas's TryParseStructuredLine only recognises "payload" as a
// JSON string value; a nested object there is silently dropped as empty.
function publishChatEvent(array $data): void
{
    global $chatOutTopic;
    $line = json_encode(['topic' => $chatOutTopic, 'payload' => json_encode($data)]);
    fwrite(STDOUT, $line . "\n");
    fflush(STDOUT);
}

// A browser (or anything else) asked to send a message - $payload arrives
// already decoded (see the file header's asymmetry note) when it was
// published as a JSON object, which is the expected case from
// templates/irc_chat.tpl's JS; guarded to also accept a bare JSON string or
// plain text, so this doesn't hard-fail on a differently-shaped caller.
function handleChatSend($payload): void
{
    global $channel, $nick;
    if (is_string($payload)) {
        $decoded = json_decode($payload, true);
        $payload = is_array($decoded) ? $decoded : ['text' => $payload];
    }
    if (!is_array($payload)) {
        return;
    }
    $target = (string)($payload['target'] ?? $channel);
    $text = (string)($payload['text'] ?? '');
    if ($target === '' || $text === '') {
        return;
    }
    // NOT validated against $channel or any allow-list - matches this
    // project's documented "lax security for now" stance (see the readme's
    // known gaps), but worth being explicit about: any WS client that's
    // passed sys.auth's stub check (any non-empty token) can direct a
    // PRIVMSG at an arbitrary target, not just the channel the page shell
    // shows - not something templates/irc_chat.tpl's own UI does, but
    // nothing here stops a client that publishes to CHAT_IN_TOPIC directly.
    // A raw CR/LF in a user-supplied message would otherwise let it inject
    // a second, attacker-controlled IRC line onto the wire - IRC lines are
    // themselves delimited on LF (TVDRX_SocketClientExecutive's own framing),
    // so this isn't optional hardening, it's the actual protocol boundary.
    $text = str_replace(["\r", "\n"], ' ', $text);
    sendLine('PRIVMSG ' . $target . ' :' . $text);
    // IRC servers don't echo your own PRIVMSG back to you by default -
    // without this, the sender would never see their own message appear in
    // their own chat log.
    publishChatEvent(['type' => 'privmsg', 'from' => $nick, 'target' => $target, 'text' => $text, 'ts' => time(), 'self' => true]);
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

    // Numeric 376 = RPL_ENDOFMOTD (422 = ERR_NOMOTD is the other common
    // "no more messages coming before you can act" signal, not currently
    // handled - some servers use it instead of 376 if MOTD is disabled).
    // Deliberately not 001/RPL_WELCOME - waiting for end-of-MOTD instead is
    // the safer, more common real-world choice: several messages (CAP
    // negotiation, server numerics) can still be in flight between 001 and
    // the point a server actually considers a client ready to JOIN.
    $parts = explode(' ', $line, 4);
    if (!$registered && isset($parts[1]) && $parts[1] === '376') {
        $registered = true;
        logLine('registration complete');
        if ($channel !== '') {
            sendLine('JOIN ' . $channel);
        }
    }

    // :nick!user@host PRIVMSG target :the message text  (NOTICE is identical
    // in shape). Anything else - server notices with no prefix, other
    // numerics, MODE, JOIN/PART echoes, ... - is simply not chat content and
    // is left alone; this only ever forwards the two message-carrying
    // commands a chat UI actually needs to render.
    if ($line !== '' && $line[0] === ':') {
        $spacePos = strpos($line, ' ');
        if ($spacePos !== false) {
            $prefix = substr($line, 1, $spacePos - 1);
            $restParts = explode(' ', substr($line, $spacePos + 1), 3);
            $cmd = $restParts[0] ?? '';
            if (($cmd === 'PRIVMSG' || $cmd === 'NOTICE') && isset($restParts[1], $restParts[2])) {
                $msgTarget = $restParts[1];
                $text = $restParts[2];
                if ($text !== '' && $text[0] === ':') {
                    $text = substr($text, 1);
                }
                $fromNick = explode('!', $prefix, 2)[0];
                publishChatEvent([
                    'type'   => strtolower($cmd),
                    'from'   => $fromNick,
                    'target' => $msgTarget,
                    'text'   => $text,
                    'ts'     => time(),
                ]);
            }
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
    } elseif ($msg['topic'] === $chatInTopic) {
        handleChatSend($msg['payload']);
    }
    // Any other topic this process might one day be subscribed to would be
    // handled here too - none yet, so silently ignored.
}

// STDIN closed (bridge's CloseInput EOF hint, or the pipe just went away) -
// exit cleanly rather than looping on a permanently-false fgets.
logLine('stdin closed, exiting');
