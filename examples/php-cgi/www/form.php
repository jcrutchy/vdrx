<?php
if (isset($_POST['name'])) setcookie('last_name', $_POST['name']);
header('Content-Type: text/html; charset=utf-8');
?><!doctype html><meta charset="utf-8"><title>form</title>
<h1>Form</h1>
<form method="post"><input name="name" placeholder="your name"> <button>Send</button></form>
<p>POST: <code><?= htmlspecialchars(json_encode($_POST)) ?></code></p>
<p>GET: <code><?= htmlspecialchars(json_encode($_GET)) ?></code> (try <a href="?a=1&b=2">?a=1&amp;b=2</a>)</p>
<p>Cookies: <code><?= htmlspecialchars(json_encode($_COOKIE)) ?></code></p>
<p><a href="/">home</a></p>
