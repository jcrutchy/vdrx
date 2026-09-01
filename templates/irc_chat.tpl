<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>$$site_title$$ - IRC - %%channel%%</title>
  <style>
    :root { color-scheme: dark; }
    body {
      margin: 0;
      font-family: -apple-system, Segoe UI, Roboto, sans-serif;
      background: #1b1d23;
      color: #d8dae0;
      display: flex;
      flex-direction: column;
      height: 100vh;
    }
    header {
      padding: 10px 16px;
      background: #22242c;
      border-bottom: 1px solid #33353f;
      display: flex;
      align-items: baseline;
      gap: 10px;
    }
    header h1 { font-size: 15px; margin: 0; font-weight: 600; }
    header .channel { color: #7aa2f7; }
    #status {
      font-size: 12px;
      padding: 2px 8px;
      border-radius: 10px;
      background: #3a3d4a;
      color: #9aa0b0;
    }
    #status.ok { background: #1f4d2f; color: #7ee2a0; }
    #status.err { background: #4d1f1f; color: #e27e7e; }
    #log {
      flex: 1;
      overflow-y: auto;
      padding: 10px 16px;
      font-size: 14px;
      line-height: 1.5;
    }
    .msg { margin-bottom: 2px; word-wrap: break-word; }
    .msg .ts { color: #5a5d6a; margin-right: 6px; }
    .msg .from { color: #7aa2f7; font-weight: 600; margin-right: 4px; }
    .msg.self .from { color: #9ece6a; }
    .msg.notice .from { color: #e0af68; }
    .msg.system { color: #6a6d7a; font-style: italic; }
    form#composer {
      display: flex;
      gap: 8px;
      padding: 10px 16px;
      background: #22242c;
      border-top: 1px solid #33353f;
    }
    #text {
      flex: 1;
      background: #1b1d23;
      border: 1px solid #33353f;
      border-radius: 6px;
      color: #d8dae0;
      padding: 8px 10px;
      font-size: 14px;
    }
    #text:focus { outline: none; border-color: #7aa2f7; }
    button {
      background: #7aa2f7;
      color: #1b1d23;
      border: none;
      border-radius: 6px;
      padding: 8px 16px;
      font-weight: 600;
      cursor: pointer;
    }
    button:disabled { opacity: 0.5; cursor: not-allowed; }
  </style>
</head>
<body>
  <header>
    <h1>$$site_title$$ IRC</h1>
    <span class="channel">%%channel%%</span>
    <span id="status">connecting&hellip;</span>
  </header>
  <div id="log"></div>
  <form id="composer">
    <input id="text" type="text" autocomplete="off" placeholder="Message %%channel%%&hellip;" disabled>
    <button id="send" type="submit" disabled>Send</button>
  </form>

  <script>
  (function () {
    'use strict';

    // Rendered server-side once, via VDRX's own template engine
    // (%%params%% substitution) - everything below this point runs
    // entirely client-side, talking to VDRX purely over the WebSocket
    // JSON-RPC bridge described in the readme's §5.
    var CHANNEL = "%%channel%%";
    var WS_PORT = "%%ws_port%%";
    var CHAT_OUT_TOPIC = "%%chat_out_topic%%";
    var CHAT_IN_TOPIC = "%%chat_in_topic%%";

    var logEl = document.getElementById('log');
    var statusEl = document.getElementById('status');
    var textEl = document.getElementById('text');
    var sendBtn = document.getElementById('send');
    var formEl = document.getElementById('composer');

    var ws = null;
    var authed = false;
    var reconnectDelay = 1000;
    var MAX_RECONNECT_DELAY = 15000;

    function setStatus(text, cls) {
      statusEl.textContent = text;
      statusEl.className = cls || '';
    }

    function systemLine(text) {
      var div = document.createElement('div');
      div.className = 'msg system';
      div.textContent = text;
      logEl.appendChild(div);
      logEl.scrollTop = logEl.scrollHeight;
    }

    // textContent (never innerHTML) for anything derived from message
    // content below - "from"/"text" both originate from other IRC users,
    // not this page, and must never be interpreted as markup.
    function appendMessage(payload) {
      var div = document.createElement('div');
      div.className = 'msg' + (payload.self ? ' self' : '') + (payload.type === 'notice' ? ' notice' : '');

      var ts = document.createElement('span');
      ts.className = 'ts';
      var d = payload.ts ? new Date(payload.ts * 1000) : new Date();
      ts.textContent = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
      div.appendChild(ts);

      var from = document.createElement('span');
      from.className = 'from';
      from.textContent = (payload.from || '?') + ':';
      div.appendChild(from);

      div.appendChild(document.createTextNode(' ' + (payload.text || '')));

      logEl.appendChild(div);
      logEl.scrollTop = logEl.scrollHeight;
    }

    function connect() {
      setStatus('connecting\u2026');
      ws = new WebSocket('ws://' + location.hostname + ':' + WS_PORT);

      ws.onopen = function () {
        reconnectDelay = 1000;
        ws.send(JSON.stringify({ method: 'sys.auth', token: 'irc-chat-page', source: 'irc_chat_page' }));
      };

      ws.onmessage = function (ev) {
        var msg;
        try {
          msg = JSON.parse(ev.data);
        } catch (e) {
          return;
        }

        if (msg.event === 'auth.ok') {
          authed = true;
          setStatus('connected', 'ok');
          textEl.disabled = false;
          sendBtn.disabled = false;
          systemLine('Connected. Subscribing to ' + CHAT_OUT_TOPIC + '\u2026');
          ws.send(JSON.stringify({ method: 'subscribe', filter: CHAT_OUT_TOPIC }));
          return;
        }

        if (msg.topic === CHAT_OUT_TOPIC) {
          // Already a genuine JS object here, not a string needing another
          // JSON.parse - see BuildBusCLIResponse/TVDRX_WSConnection's own
          // notes on why a bus message's "payload" arrives this way.
          var payload = msg.payload;
          if (typeof payload === 'string') {
            try { payload = JSON.parse(payload); } catch (e) { return; }
          }
          appendMessage(payload);
        }
      };

      ws.onclose = function () {
        authed = false;
        textEl.disabled = true;
        sendBtn.disabled = true;
        setStatus('disconnected - retrying\u2026', 'err');
        setTimeout(connect, reconnectDelay);
        reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY);
      };

      ws.onerror = function () {
        ws.close();
      };
    }

    formEl.addEventListener('submit', function (ev) {
      ev.preventDefault();
      var text = textEl.value.trim();
      if (!text || !authed) return;
      ws.send(JSON.stringify({
        method: 'publish',
        topic: CHAT_IN_TOPIC,
        payload: { target: CHANNEL, text: text }
      }));
      textEl.value = '';
    });

    connect();
  })();
  </script>
</body>
</html>
