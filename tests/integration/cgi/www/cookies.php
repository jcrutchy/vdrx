<?php setcookie('a','1'); setcookie('b','2'); header('Location: /env.php'); http_response_code(302); echo 'moved';
