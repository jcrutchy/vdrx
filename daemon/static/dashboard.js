(function () {
  'use strict';

  var boardEl = document.getElementById('board');
  var boardName = boardEl.getAttribute('data-board');
  var state = window.__VDRX_BOARD__ || { widgets: [], links: [] };
  var wsCfg = window.__VDRX_WS__ || { host: '', port: 8082, tls: false };

  var wsUrl = (wsCfg.tls ? 'wss://' : 'ws://') +
    (wsCfg.host || location.hostname) + ':' + wsCfg.port + '/';
  var socket = new WebSocket(wsUrl);
  var subscribed = false;

  socket.onopen = function () {
    send({ method: 'sys.auth', token: 'dashboard' }); // stub auth - any nonempty token passes today, see vdrx_websocket.pas
  };

  socket.onmessage = function (evt) {
    var msg;
    try { msg = JSON.parse(evt.data); } catch (e) { return; }

    if (msg.event === 'auth.ok' && !subscribed) {
      subscribed = true;
      send({ method: 'subscribe', filter: 'wb.' + boardName + '.>' });
      return;
    }
    if (msg.topic === 'wb.' + boardName + '.synced') {
      var delta;
      try { delta = JSON.parse(msg.payload); } catch (e) { return; }
      applyDelta(delta);
      render();
    }
  };

  socket.onerror = function () { console.warn('vdrx: websocket error'); };
  socket.onclose = function () { console.warn('vdrx: websocket closed - live updates stopped'); };

  function send(obj) {
    if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(obj));
  }

  // Mirrors TVDRX_WhiteboardExecutive.ApplyDelta - kept in sync with the
  // server. This client doesn't special-case its own publishes: everything,
  // including edits made here, comes back over the same 'wb.<board>.synced'
  // broadcast and is applied the same way, which is what keeps every open
  // tab (this one included) showing the same state.
  function applyDelta(delta) {
    if (delta.op === 'add' && delta.widget) {
      state.widgets.push(delta.widget);
    } else if (delta.op === 'move') {
      for (var i = 0; i < state.widgets.length; i++) {
        if (state.widgets[i].id === delta.id) {
          state.widgets[i].x = delta.x;
          state.widgets[i].y = delta.y;
          break;
        }
      }
    } else if (delta.op === 'link' && delta.link) {
      state.links.push(delta.link);
    }
  }

  function publishDelta(delta) {
    send({ method: 'publish', topic: 'wb.' + boardName + '.delta', payload: JSON.stringify(delta) });
  }

  function render() {
    boardEl.innerHTML = '';
    state.widgets.forEach(function (w) {
      var div = document.createElement('div');
      div.className = 'vdrx-widget';
      div.style.left = (w.x || 0) + 'px';
      div.style.top = (w.y || 0) + 'px';
      div.textContent = w.text || w.id || '';
      makeDraggable(div, w);
      boardEl.appendChild(div);
    });
  }

  function makeDraggable(el, widget) {
    var dragging = false, startX, startY, origX, origY;
    el.addEventListener('mousedown', function (e) {
      dragging = true;
      startX = e.clientX; startY = e.clientY;
      origX = widget.x || 0; origY = widget.y || 0;
      e.preventDefault();
    });
    document.addEventListener('mousemove', function (e) {
      if (!dragging) return;
      widget.x = origX + (e.clientX - startX);
      widget.y = origY + (e.clientY - startY);
      el.style.left = widget.x + 'px';
      el.style.top = widget.y + 'px';
    });
    document.addEventListener('mouseup', function () {
      if (!dragging) return;
      dragging = false;
      publishDelta({ op: 'move', id: widget.id, x: widget.x, y: widget.y });
    });
  }

  // Double-click empty canvas to add a widget - just enough to exercise the
  // 'add' path end to end; swap for a real toolbar/UI whenever you're ready.
  boardEl.addEventListener('dblclick', function (e) {
    if (e.target !== boardEl) return;
    var text = window.prompt('New widget text:');
    if (!text) return;
    var rect = boardEl.getBoundingClientRect();
    publishDelta({
      op: 'add',
      widget: {
        id: 'w' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
        x: e.clientX - rect.left,
        y: e.clientY - rect.top,
        text: text
      }
    });
  });

  render();
}());
