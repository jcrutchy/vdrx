<?php
header('Content-Type: text/plain');
$keys = ['GATEWAY_INTERFACE','SERVER_SOFTWARE','SERVER_PROTOCOL','SERVER_NAME','SERVER_PORT','REQUEST_METHOD','REQUEST_URI','SCRIPT_NAME','SCRIPT_FILENAME','DOCUMENT_ROOT','PATH_INFO','PATH_TRANSLATED','QUERY_STRING','REMOTE_ADDR','REMOTE_PORT','CONTENT_TYPE','CONTENT_LENGTH','HTTP_HOST','HTTP_USER_AGENT','HTTP_X_CUSTOM','HTTP_COOKIE','HTTP_PROXY','HTTPS','PHP_SELF'];
foreach ($keys as $k) echo "$k=" . ($_SERVER[$k] ?? '<unset>') . "\n";
echo "GET=" . json_encode($_GET) . "\nPOST=" . json_encode($_POST) . "\nCOOKIE=" . json_encode($_COOKIE) . "\n";
echo "RAW=" . strlen(file_get_contents('php://input')) . "\n";
echo "CWD=" . getcwd() . "\n";
