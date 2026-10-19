<?php
header('Content-Type: text/plain; charset=utf-8');
foreach (['REQUEST_METHOD','REQUEST_URI','SCRIPT_NAME','SCRIPT_FILENAME','PATH_INFO','QUERY_STRING',
          'SERVER_NAME','SERVER_PORT','REMOTE_ADDR','HTTP_HOST','HTTP_USER_AGENT','GATEWAY_INTERFACE'] as $k) {
  printf("%-18s %s\n", $k, $_SERVER[$k] ?? '(unset)');
}
echo "\nPHP " . PHP_VERSION . " via " . php_sapi_name() . "\n";
