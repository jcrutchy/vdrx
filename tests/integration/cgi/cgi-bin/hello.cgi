#!/bin/sh
printf "Content-Type: text/plain\r\n\r\n"
echo "classic cgi-bin: method=$REQUEST_METHOD query=$QUERY_STRING"
