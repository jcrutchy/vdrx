<?php
// Front controller: every URL that matches no real file lands here.
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
header('Content-Type: text/html; charset=utf-8');
if ($path === '/' || $path === '/index.php') { ?>
<!doctype html><meta charset="utf-8"><title>vdrx + php-cgi</title>
<h1>vdrx + php-cgi</h1>
<ul>
  <li><a href="/info.php">/info.php</a> - the CGI environment PHP received</li>
  <li><a href="/form.php">/form.php</a> - GET, POST and cookies</li>
  <li><a href="/blog/42">/blog/42</a> - rewritten to /post.php?id=42</li>
  <li><a href="/anything/else?x=1">/anything/else?x=1</a> - no such file: handled by this front controller</li>
  <li><a href="/info.php/extra/path">/info.php/extra/path</a> - the extra part arrives as PATH_INFO</li>
</ul>
<?php } else {
  echo '<!doctype html><meta charset="utf-8"><h1>Front controller</h1><p>No file for <code>' .
       htmlspecialchars($path) . '</code>, so index.php handled it.</p><p><a href="/">home</a></p>';
}
