@echo off
setlocal

rem hello_bus.bat - proves the "bus" cli_bridges protocol doesn't care what
rem language answers it. VDRX doesn't know or care that this is a batch
rem script instead of PHP - it just spawned "cmd /c scripts\hello_bus.bat"
rem (this route's "command" in vdrx.conf), wrote one JSON request line to
rem its stdin, and is now reading one JSON reply line back off stdout,
rem exactly the same contract hello_bus.php gets.
rem
rem Batch has no real JSON parsing, so this deliberately doesn't try to
rem parse the request line - it just reads and discards it (set /p) to
rem demonstrate the round trip, then prints a canned reply. Also
rem deliberately does NOT echo the raw request line back inside its own
rem JSON string - batch has no JSON-escaping tools, and the request line
rem can itself contain quotes/braces that would produce broken JSON.
rem
rem Config: the "hello-bus-bat" cli_bridges entry, prefix "/hello-bat".
rem Try: http://<host>:8081/hello-bat

set /p REQLINE=

echo {"status":200,"content_type":"text/plain","body":"hello from hello_bus.bat (Windows Batch)! VDRX spawned cmd.exe, wrote one JSON request line to its stdin, and read this one JSON reply line back off stdout - same contract PHP or Python would get. Timestamp: %DATE% %TIME%."}

endlocal
