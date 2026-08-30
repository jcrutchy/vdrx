<!DOCTYPE html>
<html>
<head>
  <title>$$site_title$$ - Greeting</title>
</head>
<body>
  <h1>Hello, %%name%%!</h1>
  <p>This page was rendered by VDRX's own template engine
     (vdrx_templates.pas) - scripts/template_demo.php only supplied the
     data (%%name%% and the rows below), never any markup.</p>
  <p>You asked for sub_path: <code>%%sub_path%%</code></p>

  <h2>Messages</h2>
  <ul>
##loop:messages##
    <li><strong>%%from%%:</strong> %%text%%</li>
##endloop:messages##
  </ul>

  <p><small>Try <code>/template-demo?name=Jared</code> to change the
     greeting via the %%name%% param.</small></p>
</body>
</html>
