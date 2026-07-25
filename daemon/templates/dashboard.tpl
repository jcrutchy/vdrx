<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>$$site_title$$ - %%board_name%%</title>
  <link rel="stylesheet" href="/dashboard.css">
</head>
<body>
@@nav@@
  <div id="board" data-board="%%board_name%%"></div>
  <script>
    window.__VDRX_BOARD__ = %%board_json%%;
    window.__VDRX_WS__ = {"host": %%ws_host_json%%, "port": %%ws_port%%, "tls": %%ws_tls_json%%};
  </script>
  <script src="/dashboard.js"></script>
</body>
</html>
