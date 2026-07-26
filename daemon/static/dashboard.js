(function () {
  'use strict';

  var STICKY_COLORS = ['#fff59d', '#ffccbc', '#c8e6c9', '#bbdefb', '#e1bee7'];
  var NOTE_W = 160, NOTE_H = 120;

  var boardEl = document.getElementById('board');
  var boardName = boardEl.getAttribute('data-board');
  var state = window.__VDRX_BOARD__ || { widgets: [], links: [] };
  var wsCfg = window.__VDRX_WS__ || { host: '', port: 8082, tls: false };

  console.log('[vdrx] board:', boardName, 'initial widgets:', state.widgets.length);

  var elementsById = {};  // widget id -> DOM element, kept across renders so an
                           // in-progress edit/drag is never wiped by an unrelated update
  var pendingFocusId = null; // id of a note we just created locally - focus its textarea once it appears
  var draggingIds = {};   // widget id -> true while a local drag is in progress -
                           // render() skips repositioning that note while it's set
  var editingIds = {};    // widget id -> true while a LOCAL edit hasn't been flushed
                           // to the server yet. Deliberately NOT based on
                           // document.activeElement - switching browser tabs
                           // leaves the old tab's textarea as document.activeElement
                           // even though it's in the background, so a focus-based
                           // guard was silently dropping remote updates for a note
                           // you'd typed in and then tabbed away from without ever
                           // technically blurring it. This tracks "do I have an
                           // unpublished local change" instead, which is what
                           // actually needs protecting from being overwritten.

  var wsUrl = (wsCfg.tls ? 'wss://' : 'ws://') +
    (wsCfg.host || location.hostname) + ':' + wsCfg.port + '/';
  console.log('[vdrx] connecting to', wsUrl);
  var socket = new WebSocket(wsUrl);
  var subscribed = false;

  socket.onopen = function () {
    console.log('[vdrx] socket open, sending sys.auth');
    send({ method: 'sys.auth', token: 'dashboard' });
  };

  socket.onmessage = function (evt) {
    console.log('[vdrx] <- raw', evt.data);
    var msg;
    try { msg = JSON.parse(evt.data); } catch (e) {
      console.warn('[vdrx] could not parse incoming message as JSON', e);
      return;
    }

    if (msg.event === 'auth.ok' && !subscribed) {
      subscribed = true;
      console.log('[vdrx] authenticated, subscribing to wb.' + boardName + '.>');
      send({ method: 'subscribe', filter: 'wb.' + boardName + '.>' });
      return;
    }
    if (msg.topic === 'wb.' + boardName + '.synced') {
      // msg.payload arrives as a genuine JS object here, not a JSON string -
      // the server embeds it as a raw JSON value in the outer frame, so the
      // outer JSON.parse(evt.data) above already parsed it.
      if (!msg.payload || typeof msg.payload !== 'object') {
        console.warn('[vdrx] .synced message had no usable payload object', msg);
        return;
      }
      console.log('[vdrx] applying delta', msg.payload);
      applyDelta(msg.payload);
      render();
    }
  };

  socket.onerror = function (evt) {
    console.warn('[vdrx] websocket error', evt);
  };
  socket.onclose = function (evt) {
    console.warn('[vdrx] websocket closed - live updates stopped. code=' + evt.code + ' reason=' + evt.reason);
  };

  function send(obj) {
    if (socket.readyState !== WebSocket.OPEN) {
      console.warn('[vdrx] tried to send while socket not open (readyState=' + socket.readyState + '), dropped:', obj);
      return;
    }
    console.log('[vdrx] -> send', obj);
    socket.send(JSON.stringify(obj));
  }

  // Mirrors TVDRX_WhiteboardExecutive.ApplyDelta. Mutates widget objects IN
  // PLACE rather than replacing them - render() keeps one DOM element per
  // widget across its lifetime, and that element's handlers close over the
  // widget object itself, so identity has to stay stable for a remote update
  // to show up correctly on an element someone's actively looking at.
  function applyDelta(delta) {
    if (delta.op === 'add' && delta.widget) {
      state.widgets.push(delta.widget);
    } else if (delta.op === 'move') {
      var w = findWidget(delta.id);
      if (w) { w.x = delta.x; w.y = delta.y; }
      else console.warn('[vdrx] move for unknown widget id', delta.id);
    } else if (delta.op === 'edit') {
      var w2 = findWidget(delta.id);
      if (w2) w2.text = delta.text;
      else console.warn('[vdrx] edit for unknown widget id', delta.id);
    } else if (delta.op === 'delete') {
      state.widgets = state.widgets.filter(function (w) { return w.id !== delta.id; });
    } else if (delta.op === 'link' && delta.link) {
      state.links.push(delta.link);
    } else {
      console.warn('[vdrx] unrecognised delta op', delta);
    }
  }

  function findWidget(id) {
    for (var i = 0; i < state.widgets.length; i++)
      if (state.widgets[i].id === id) return state.widgets[i];
    return null;
  }

  function publishDelta(delta) {
    send({ method: 'publish', topic: 'wb.' + boardName + '.delta', payload: JSON.stringify(delta) });
  }

  function hashCode(s) {
    var h = 0;
    for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
    return h;
  }

  function boardBounds() {
    var rect = boardEl.getBoundingClientRect();
    return { w: rect.width, h: rect.height };
  }

  function clamp(v, min, max) {
    if (max < min) return min; // board smaller than the note - pin to the corner rather than produce a bogus range
    return Math.max(min, Math.min(v, max));
  }

  function createWidgetEl(w) {
    var el = document.createElement('div');
    el.className = 'vdrx-sticky';
    el.dataset.id = w.id;
    el.style.background = w.color || STICKY_COLORS[0];
    el.style.transform = 'rotate(' + ((Math.abs(hashCode(w.id)) % 7) - 3) + 'deg)';

    var handle = document.createElement('div');
    handle.className = 'vdrx-sticky-handle';

    var del = document.createElement('button');
    del.type = 'button';
    del.className = 'vdrx-sticky-delete';
    del.title = 'Delete note';
    del.textContent = '\u00d7';
    del.addEventListener('click', function (e) {
      e.stopPropagation();
      publishDelta({ op: 'delete', id: w.id });
    });
    handle.appendChild(del);

    var ta = document.createElement('textarea');
    ta.className = 'vdrx-sticky-text';
    ta.placeholder = 'Type something...';
    ta.value = w.text || '';

    var editTimer = null;
    function flushEdit() {
      if (editTimer) { clearTimeout(editTimer); editTimer = null; }
      delete editingIds[w.id]; // our change is now on its way to the server - safe for remote updates to land again
      publishDelta({ op: 'edit', id: w.id, text: ta.value });
    }
    ta.addEventListener('input', function () {
      editingIds[w.id] = true; // unflushed local change - protect this box from remote overwrites until flushEdit runs
      if (editTimer) clearTimeout(editTimer);
      editTimer = setTimeout(flushEdit, 600);
    });
    ta.addEventListener('blur', flushEdit);

    makeDraggable(handle, el, w);

    el.appendChild(handle);
    el.appendChild(ta);
    return el;
  }

  function makeDraggable(handleEl, noteEl, widget) {
    var dragging = false, lastX, lastY;
    handleEl.addEventListener('mousedown', function (e) {
      dragging = true;
      draggingIds[widget.id] = true;
      lastX = e.clientX; lastY = e.clientY;
      e.preventDefault();
    });
    document.addEventListener('mousemove', function (e) {
      if (!dragging) return;
      var b = boardBounds();
      // Incremental delta from the LAST mousemove tick, not a total offset
      // from mousedown - so a concurrent remote move on this same note
      // during your drag doesn't cause a jump/stale-base publish.
      widget.x = clamp(widget.x + (e.clientX - lastX), 0, b.w - NOTE_W);
      widget.y = clamp(widget.y + (e.clientY - lastY), 0, b.h - NOTE_H);
      lastX = e.clientX; lastY = e.clientY;
      noteEl.style.left = widget.x + 'px';
      noteEl.style.top = widget.y + 'px';
    });
    document.addEventListener('mouseup', function () {
      if (!dragging) return;
      dragging = false;
      delete draggingIds[widget.id];
      publishDelta({ op: 'move', id: widget.id, x: widget.x, y: widget.y });
    });
  }

  // In-place diff, not a full rebuild: creates a DOM element once per widget
  // id and updates it thereafter, so a note someone is actively dragging or
  // has an unflushed edit pending in (see draggingIds/editingIds) is never
  // clobbered by an unrelated remote update arriving mid-interaction.
  function render() {
    var seen = {};
    state.widgets.forEach(function (w) {
      seen[w.id] = true;
      var el = elementsById[w.id];
      if (!el) {
        el = createWidgetEl(w);
        elementsById[w.id] = el;
        boardEl.appendChild(el);
        if (w.id === pendingFocusId) {
          pendingFocusId = null;
          el.querySelector('textarea').focus();
        }
      }
      if (!draggingIds[w.id]) {
        el.style.left = (w.x || 0) + 'px';
        el.style.top = (w.y || 0) + 'px';
      }
      var ta = el.querySelector('textarea');
      if (!editingIds[w.id] && ta.value !== (w.text || ''))
        ta.value = w.text || '';
    });
    Object.keys(elementsById).forEach(function (id) {
      if (!seen[id]) {
        elementsById[id].remove();
        delete elementsById[id];
      }
    });
  }

  function createNoteAt(x, y) {
    var b = boardBounds();
    var widget = {
      id: 'w' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
      type: 'sticky',
      x: clamp(x - NOTE_W / 2, 0, b.w - NOTE_W),
      y: clamp(y - NOTE_H / 2, 0, b.h - NOTE_H),
      text: '',
      color: STICKY_COLORS[Math.floor(Math.random() * STICKY_COLORS.length)]
    };
    console.log('[vdrx] creating note', widget, 'board bounds', b);
    pendingFocusId = widget.id;
    publishDelta({ op: 'add', widget: widget });
  }

  boardEl.addEventListener('dblclick', function (e) {
    if (e.target !== boardEl) return;
    var rect = boardEl.getBoundingClientRect();
    createNoteAt(e.clientX - rect.left, e.clientY - rect.top);
  });

  var addBtn = document.createElement('button');
  addBtn.type = 'button';
  addBtn.className = 'vdrx-add-note';
  addBtn.title = 'New sticky note';
  addBtn.textContent = '+ note';
  addBtn.addEventListener('click', function () {
    var b = boardBounds();
    createNoteAt(b.w / 2 + (Math.random() * 120 - 60), b.h / 2 + (Math.random() * 120 - 60));
  });
  document.body.appendChild(addBtn);

  render();
}());
