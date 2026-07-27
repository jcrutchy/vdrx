<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>$$site_title$$ - Plague</title>
  <link rel="stylesheet" href="/plague.css">
</head>
<body>
  <div id="plague-root">
    <div id="plague-map-wrap">
      <img id="plague-map-img" src="/$$plague_map_image$$" alt="">
      <svg id="plague-map-svg" preserveAspectRatio="none"></svg>
    </div>
    <div id="plague-sidebar"></div>
  </div>
  <script>
    window.__VDRX_WS__ = {"host": %%ws_host_json%%, "port": %%ws_port%%, "tls": %%ws_tls_json%%};
  </script>
  <script src="/plague.js"></script>
</body>
</html>
