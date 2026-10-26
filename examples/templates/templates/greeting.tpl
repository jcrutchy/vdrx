<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>$$site_title$$ - greeting</title>
</head>
<body>
  <h1>Hello, %%name%%!</h1>
  <p>Requested path: <code>%%path%%</code></p>
  <h2>Messages</h2>
  <ul>
##loop:messages##
    <li><strong>%%from%%:</strong> %%text%%</li>
##endloop:messages##
  </ul>
  <p><small>Try <a href="/greeting?name=Jared">?name=Jared</a>.</small></p>
@@footer@@
</body>
</html>
