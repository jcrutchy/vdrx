<?php
header('Content-Type: text/plain; charset=utf-8');
echo "post id: " . (int)($_GET['id'] ?? 0) . "\n";
echo "REQUEST_URI (what the browser asked for): " . $_SERVER['REQUEST_URI'] . "\n";
