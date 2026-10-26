<?php
header('X-Test: front');
echo "FRONT uri=" . $_SERVER['REQUEST_URI'] . " script=" . $_SERVER['SCRIPT_NAME'] . " pathinfo=" . ($_SERVER['PATH_INFO'] ?? '-');
