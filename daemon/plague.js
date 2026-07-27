(function () {
  'use strict';

  var wsCfg = window.__VDRX_WS__ || { host: '', port: 8082, tls: false };

  var root = document.getElementById('plague-root');
  var mapWrap = document.getElementById('plague-map-wrap');
  var mapImg = document.getElementById('plague-map-img');
  var svg = document.getElementById('plague-map-svg');
  var sidebar = document.getElementById('plague-sidebar');

  var SVG_NS = 'http://www.w3.org/2000/svg';

  // Identity is just a random id kept in localStorage - no login system,
  // matches "basic game" scope. Good enough to tell players apart across a
  // page refresh; anyone sharing a browser profile shares an identity too,
  // which is a fine tradeoff for a LAN/friends game and a flagged cut for
  // anything more public.
  var playerId = localStorage.getItem('vdrx_plague_player_id');
  if (!playerId) {
    playerId = 'p' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
    localStorage.setItem('vdrx_plague_player_id', playerId);
  }
  var playerName = localStorage.getItem('vdrx_plague_player_name') || '';

  var countries = {};   // id -> {name, population, neighbors, points?} - static, from /plague/countries
  var state = null;     // full game state - from /plague/state, then kept live via plague.delta
  var countryEls = {};  // id -> {shape: <polygon|circle>, label: <text>} - persistent across renders
  var selectedCountryId = null;
  var fallbackLayout = {}; // id -> {x,y} - only used if a country has no "points" (see layoutFallback)

  // -- data load --------------------------------------------------------

  fetch('/plague/countries').then(function (r) { return r.json(); }).then(function (data) {
    countries = data;
    layoutFallback();
    buildMapShapes();
    render();
  }).catch(function (e) { console.warn('[plague] failed to load /plague/countries', e); });

  fetch('/plague/state').then(function (r) { return r.json(); }).then(function (data) {
    state = data;
    render();
  }).catch(function (e) { console.warn('[plague] failed to load /plague/state', e); });

  // -- websocket ----------------------------------------------------------

  var wsUrl = (wsCfg.tls ? 'wss://' : 'ws://') + (wsCfg.host || location.hostname) + ':' + wsCfg.port + '/';
  var socket = new WebSocket(wsUrl);
  var subscribed = false;

  socket.onopen = function () { send({ method: 'sys.auth', token: 'plague' }); };
  socket.onmessage = function (evt) {
    var msg;
    try { msg = JSON.parse(evt.data); } catch (e) { return; }
    if (msg.event === 'auth.ok' && !subscribed) {
      subscribed = true;
      send({ method: 'subscribe', filter: 'plague.delta' });
      return;
    }
    if (msg.topic === 'plague.delta' && msg.payload) {
      state = msg.payload;
      render();
    }
  };
  socket.onclose = function () { console.warn('[plague] websocket closed - live updates stopped'); };

  function send(obj) {
    if (socket.readyState !== WebSocket.OPEN) return;
    socket.send(JSON.stringify(obj));
  }

  function doAction(type, args) {
    var payload = Object.assign({ type: type, player_id: playerId }, args || {});
    send({ method: 'publish', topic: 'plague.action', payload: JSON.stringify(payload) });
  }

  // -- layout / colors -----------------------------------------------------

  // Countries with no "points" (map not fully built out yet, or this
  // country deliberately left off the image) get a deterministic spot on a
  // simple ring layout instead - keeps the whole action/sim loop testable
  // before every country has real polygon data.
  function layoutFallback() {
    var ids = Object.keys(countries).filter(function (id) { return !countries[id].points; });
    var cx = 800, cy = 450, r = 380;
    ids.forEach(function (id, i) {
      var angle = (i / Math.max(1, ids.length)) * Math.PI * 2;
      fallbackLayout[id] = { x: cx + r * Math.cos(angle), y: cy + r * Math.sin(angle) };
    });
  }

  function hashHue(s) {
    var h = 0;
    for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
    return Math.abs(h) % 360;
  }
  function pathogenColor(pathogenId) {
    return 'hsl(' + hashHue(pathogenId) + ', 75%, 55%)';
  }

  // -- map shapes -----------------------------------------------------------

  function svgViewBoxDims() {
    if (mapImg.naturalWidth) return { w: mapImg.naturalWidth, h: mapImg.naturalHeight };
    return { w: 1600, h: 900 }; // fallback canvas size when no map image is configured yet
  }

  function applySvgSizing() {
    var d = svgViewBoxDims();
    svg.setAttribute('viewBox', '0 0 ' + d.w + ' ' + d.h);
    svg.setAttribute('width', d.w);
    svg.setAttribute('height', d.h);
  }
  mapImg.addEventListener('load', function () { applySvgSizing(); buildMapShapes(); render(); });
  mapImg.addEventListener('error', function () { applySvgSizing(); }); // no map configured yet - fallback canvas still works
  applySvgSizing();

  function pointsToSvgAttr(points) {
    return points.map(function (p) { return p[0] + ',' + p[1]; }).join(' ');
  }

  // Builds one persistent DOM element per country (polygon if it has real
  // "points", small circle at its fallback ring position otherwise) plus a
  // label. Called once on data load and again whenever the map image
  // finishes loading (its natural size may not be known yet on first call).
  function buildMapShapes() {
    Object.keys(countries).forEach(function (id) {
      if (countryEls[id]) return; // already built
      var c = countries[id];
      var shape;
      if (c.points && c.points.length >= 3) {
        shape = document.createElementNS(SVG_NS, 'polygon');
        shape.setAttribute('points', pointsToSvgAttr(c.points));
      } else {
        var pos = fallbackLayout[id] || { x: 0, y: 0 };
        shape = document.createElementNS(SVG_NS, 'circle');
        shape.setAttribute('cx', pos.x);
        shape.setAttribute('cy', pos.y);
        shape.setAttribute('r', 22);
      }
      shape.setAttribute('class', 'plague-country');
      shape.setAttribute('fill', '#182231');
      shape.setAttribute('fill-opacity', '0.85');
      shape.addEventListener('click', function () { onCountryClick(id); });

      var label = document.createElementNS(SVG_NS, 'text');
      label.setAttribute('class', 'plague-country-label');
      var labelPos = c.points ? centroid(c.points) : (fallbackLayout[id] || { x: 0, y: 0 });
      label.setAttribute('x', labelPos.x);
      label.setAttribute('y', labelPos.y);
      label.textContent = c.name || id;

      svg.appendChild(shape);
      svg.appendChild(label);
      countryEls[id] = { shape: shape, label: label };
    });
  }

  function centroid(points) {
    var x = 0, y = 0;
    points.forEach(function (p) { x += p[0]; y += p[1]; });
    return { x: x / points.length, y: y / points.length };
  }

  function onCountryClick(id) {
    var me = state && state.players ? state.players[playerId] : null;

    // Patient-zero placement: an infector who hasn't seeded yet, pre-game.
    if (me && me.role === 'infector' && state.status === 'lobby' && !(state.pathogens && state.pathogens[playerId])) {
      doAction('seed_pathogen', { country_id: id, name: playerName ? playerName + "'s strain" : 'Pathogen' });
      return;
    }

    selectedCountryId = id;
    render();
  }

  // -- rendering --------------------------------------------------------

  // Fill color per country: the pathogen with the most active cases there
  // wins the color (simplest legible option with several pathogens
  // possibly overlapping in one country); opacity scales with that
  // pathogen's infected fraction of local population so a just-seeded
  // country looks different from a saturated one. True multi-pathogen
  // blending (split fill, stacked bars, etc.) is a nice-to-have deferred
  // for later, not attempted here.
  function colorForCountry(id) {
    if (!state || !state.countries || !state.countries[id]) return { fill: '#182231', opacity: 0.85 };
    var pathogens = state.countries[id].pathogens || {};
    var bestId = null, bestInfected = -1, bestFraction = 0;
    var population = (countries[id] && countries[id].population) || 1;
    Object.keys(pathogens).forEach(function (pid) {
      var p = pathogens[pid];
      if (p.infected > bestInfected) {
        bestInfected = p.infected;
        bestId = pid;
        bestFraction = p.infected / population;
      }
    });
    if (!bestId || bestInfected <= 0) return { fill: '#182231', opacity: 0.85 };
    return { fill: pathogenColor(bestId), opacity: 0.25 + 0.65 * Math.min(1, bestFraction * 4) };
  }

  function render() {
    if (!countries || Object.keys(countryEls).length === 0) return;

    Object.keys(countryEls).forEach(function (id) {
      var c = colorForCountry(id);
      var el = countryEls[id];
      el.shape.setAttribute('fill', c.fill);
      el.shape.setAttribute('fill-opacity', c.opacity);
      el.shape.classList.toggle('selected', id === selectedCountryId);
    });

    renderSidebar();
  }

  // -- sidebar ------------------------------------------------------------

  function el(tag, attrs, children) {
    var e = document.createElement(tag);
    if (attrs) Object.keys(attrs).forEach(function (k) {
      if (k === 'text') e.textContent = attrs[k];
      else if (k.indexOf('on') === 0) e.addEventListener(k.slice(2), attrs[k]);
      else e.setAttribute(k, attrs[k]);
    });
    (children || []).forEach(function (c) { if (c) e.appendChild(c); });
    return e;
  }

  function renderSidebar() {
    sidebar.innerHTML = '';
    sidebar.appendChild(el('h2', { text: 'Plague' }));

    var me = state && state.players ? state.players[playerId] : null;
    var statusText = state ? state.status : 'loading...';
    var banner = el('div', { class: 'plague-status-banner' + (state && state.status === 'ended' ? ' ended' : '') });
    if (state && state.status === 'ended') {
      banner.textContent = state.winner && state.winner.indexOf('infector:') === 0
        ? 'GAME OVER - infector ' + state.winner.slice(9) + ' wins'
        : 'GAME OVER - defenders win, every pathogen was cured';
    } else {
      banner.textContent = 'Status: ' + statusText + (me ? ' - you are ' + me.role : ' - not joined yet');
    }
    sidebar.appendChild(banner);

    if (!me) sidebar.appendChild(renderJoinForm());
    else {
      if (me.role === 'infector') sidebar.appendChild(renderInfectorPanel());
      if (me.role === 'defender') sidebar.appendChild(renderDefenderPanel());
    }

    if (state && state.status === 'lobby' && state.pathogens && Object.keys(state.pathogens).length > 0) {
      sidebar.appendChild(el('button', {
        class: 'plague-btn primary', text: 'Start Game',
        onclick: function () { doAction('start_game', {}); }
      }));
    }

    sidebar.appendChild(el('h3', { text: 'Pathogens' }));
    if (state && state.pathogens) {
      Object.keys(state.pathogens).forEach(function (pid) {
        sidebar.appendChild(renderPathogenCard(pid, state.pathogens[pid]));
      });
    }

    if (selectedCountryId) sidebar.appendChild(renderCountryPanel(selectedCountryId, me));
  }

  function renderJoinForm() {
    var nameInput = el('input', { type: 'text', placeholder: 'Your name', value: playerName });
    var wrap = el('div', {}, [
      el('h3', { text: 'Join' }),
      el('div', { class: 'plague-field' }, [el('label', { text: 'Name' }), nameInput]),
    ]);
    function join(role) {
      playerName = nameInput.value.trim() || 'Player';
      localStorage.setItem('vdrx_plague_player_name', playerName);
      doAction('join', { role: role, name: playerName });
    }
    wrap.appendChild(el('button', { class: 'plague-btn primary', text: 'Join as Infector', onclick: function () { join('infector'); } }));
    wrap.appendChild(el('button', { class: 'plague-btn', text: 'Join as Defender', onclick: function () { join('defender'); } }));
    return wrap;
  }

  function renderInfectorPanel() {
    var wrap = el('div', {}, [el('h3', { text: 'Your Pathogen' })]);
    var mine = state.pathogens ? state.pathogens[playerId] : null;
    if (!mine) {
      wrap.appendChild(el('div', { class: 'plague-country-panel', text: 'Click a country on the map to place patient zero.' }));
      return wrap;
    }
    wrap.appendChild(renderPathogenCard(playerId, mine, true));
    return wrap;
  }

  function renderDefenderPanel() {
    var wrap = el('div', {}, [el('h3', { text: 'Defense' })]);
    wrap.appendChild(el('div', { class: 'plague-country-panel', text: 'Click a country to quarantine it, or use the border controls below.' }));

    var ids = Object.keys(countries);
    var fromSel = el('select', {});
    var toSel = el('select', {});
    ids.forEach(function (id) {
      fromSel.appendChild(el('option', { value: id, text: countries[id].name || id }));
      toSel.appendChild(el('option', { value: id, text: countries[id].name || id }));
    });
    wrap.appendChild(el('div', { class: 'plague-field' }, [el('label', { text: 'From' }), fromSel]));
    wrap.appendChild(el('div', { class: 'plague-field' }, [el('label', { text: 'To' }), toSel]));
    wrap.appendChild(el('button', {
      class: 'plague-btn danger', text: 'Close Border',
      onclick: function () { doAction('close_border', { from_id: fromSel.value, to_id: toSel.value }); }
    }));
    wrap.appendChild(el('button', {
      class: 'plague-btn', text: 'Open Border',
      onclick: function () { doAction('open_border', { from_id: fromSel.value, to_id: toSel.value }); }
    }));
    return wrap;
  }

  function renderPathogenCard(pid, p, ownerControls) {
    var card = el('div', { class: 'plague-pathogen-card' });
    card.appendChild(el('div', { class: 'name', text: p.name + (p.eradicated ? ' (eradicated)' : '') }));
    card.appendChild(el('div', { text: 'Infectivity ' + p.infectivity.toFixed(0) + ' / Lethality ' + p.lethality.toFixed(0) }));
    card.appendChild(el('div', { text: 'Cure progress' }));
    card.appendChild(el('div', { class: 'plague-bar-track' }, [
      el('div', { class: 'plague-bar-fill cure', style: 'width:' + Math.min(100, p.cure_progress) + '%' })
    ]));
    if (ownerControls && !p.eradicated) {
      card.appendChild(el('div', { text: 'Evolution points: ' + p.evolution_points.toFixed(1) }));
      card.appendChild(el('button', {
        class: 'plague-btn', text: '+ Infectivity',
        onclick: function () { doAction('evolve_trait', { trait: 'infectivity' }); }
      }));
      card.appendChild(el('button', {
        class: 'plague-btn', text: '+ Lethality',
        onclick: function () { doAction('evolve_trait', { trait: 'lethality' }); }
      }));
    }
    if (state && state.players && state.players[playerId] && state.players[playerId].role === 'defender' && !p.eradicated) {
      var amountInput = el('input', { type: 'number', value: '5', min: '1', style: 'width:60px;display:inline-block;margin-right:6px;' });
      card.appendChild(el('div', {}, [
        amountInput,
        el('button', {
          class: 'plague-btn primary', text: 'Invest in Cure',
          onclick: function () { doAction('invest_cure', { pathogen_id: pid, amount: parseFloat(amountInput.value) || 0 }); }
        })
      ]));
    }
    return card;
  }

  function renderCountryPanel(id, me) {
    var c = countries[id] || {};
    var s = state && state.countries ? state.countries[id] : null;
    var panel = el('div', { class: 'plague-country-panel' });
    panel.appendChild(el('div', { text: (c.name || id) + ' - pop ' + (c.population || 0).toLocaleString() }));
    if (s) panel.appendChild(el('div', { text: 'Quarantine: ' + (s.quarantine || 0) + '%' }));

    if (me && me.role === 'defender') {
      var slider = el('input', { type: 'range', min: '0', max: '100', value: String((s && s.quarantine) || 0) });
      slider.addEventListener('change', function () {
        doAction('quarantine', { country_id: id, level: parseFloat(slider.value) });
      });
      panel.appendChild(el('div', { class: 'plague-field' }, [el('label', { text: 'Set quarantine level' }), slider]));
    }
    return panel;
  }
}());
