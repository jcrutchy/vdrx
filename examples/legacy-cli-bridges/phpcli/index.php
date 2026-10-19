<?php
/**
 * index.php - CGI-mode example for the "phpcli" cli_bridges route in
 * vdrx.conf (protocol defaults to "cgi", so this is unrelated to the new
 * "bus" protocol - see scripts/hello_bus.php for that).
 *
 * VDRX resolves the URL path beyond the route's "prefix" ("/cli/") to a
 * file under its "script_dir" ("phpcli"), spawns the configured "command"
 * (plain "php", not "php-cgi") with this file's path as its one argument,
 * and sets a handful of CGI env vars before reading its raw stdout back
 * verbatim as the response body - see RunCLIScript in vdrx_network.pas.
 *
 * Because the command is plain "php" rather than "php-cgi", the CGI SAPI's
 * automatic $_GET/$_POST/$_SERVER population never kicks in - read the env
 * vars directly with getenv() instead, as below. header() calls are also a
 * silent no-op under the CLI SAPI - Content-Type here comes entirely from
 * this route's "content_type" in vdrx.conf, not from anything this script
 * does.
 *
 * Try it: http://<host>:8081/cli/index.php?anything=here
 */

declare(strict_types=1);

$method = (string)getenv('REQUEST_METHOD');
$uri    = (string)getenv('REQUEST_URI');
$query  = (string)getenv('QUERY_STRING');
$ctype  = (string)getenv('CONTENT_TYPE');
$clen   = (string)getenv('CONTENT_LENGTH');

// A CGI-mode script's stdout IS the response body - no envelope, no JSON,
// just print whatever the response should look like.
echo "<!DOCTYPE html>\n<html><body>\n";
echo "<h1>phpcli/index.php (cgi mode)</h1>\n";
echo "<p>This process was spawned fresh for this one request and will exit ";
echo "as soon as it finishes printing.</p>\n";
echo "<table border=\"1\" cellpadding=\"4\">\n";
echo "<tr><td>REQUEST_METHOD</td><td>" . htmlspecialchars($method) . "</td></tr>\n";
echo "<tr><td>REQUEST_URI</td><td>" . htmlspecialchars($uri) . "</td></tr>\n";
echo "<tr><td>QUERY_STRING</td><td>" . htmlspecialchars($query) . "</td></tr>\n";
echo "<tr><td>CONTENT_TYPE</td><td>" . htmlspecialchars($ctype) . "</td></tr>\n";
echo "<tr><td>CONTENT_LENGTH</td><td>" . htmlspecialchars($clen) . "</td></tr>\n";
echo "</table>\n";
echo "</body></html>\n";
