#!/bin/sh
# Run every automated test:  tests/run.sh
#   1. build the daemon and the test programs   (./build.sh tests)
#   2. unit tests                               (bin/test_jsonconf, test_redact, test_spawn, test_registry, test_linebuf)
#   3. integration tests                        (tests/integration/run.sh)
# The stress suite (tests/stress) and the stall demos (tests/manual) are run by hand - see tests/README.md.
cd "$(dirname "$0")/.." || exit 1
fail=0
echo "== build"; ./build.sh tests >/dev/null 2>&1 || { ./build.sh tests; exit 1; }; echo "  built bin/"
echo; echo "== unit: jsonconf"
out=$(bin/test_jsonconf 2>/dev/null); rc=$?; echo "  $(echo "$out" | tail -1)"; [ $rc -eq 0 ] || fail=1
echo; echo "== unit: log redaction"
out=$(bin/test_redact 2>/dev/null); rc=$?; echo "  $(echo "$out" | tail -1)"; [ $rc -eq 0 ] || { echo "$out" | grep -E "FAIL|leaked|changed|output" | sed "s/^/  /"; fail=1; }
echo; echo "== unit: spawning, static policy"
out=$(bin/test_spawn 2>/dev/null); rc=$?; echo "  $(echo "$out" | tail -1)"; [ $rc -eq 0 ] || { echo "$out" | grep -E "FAIL" | sed "s/^/  /"; fail=1; }
echo; echo "== unit: subscription registry"
out=$(bin/test_registry 2>/dev/null); rc=$?; echo "  $(echo "$out" | tail -1)"; [ $rc -eq 0 ] || { echo "$out" | grep -E "FAIL" | sed "s/^/  /"; fail=1; }
echo; echo "== unit: line buffer (max_line_bytes)"
out=$(bin/test_linebuf 2>/dev/null); rc=$?; echo "  $(echo "$out" | tail -1)"; [ $rc -eq 0 ] || { echo "$out" | grep -E "FAIL" | sed "s/^/  /"; fail=1; }
echo; echo "== unit: per-address connection limits"
out=$(bin/test_iplimit 2>/dev/null); rc=$?; echo "  $(echo "$out" | tail -1)"; [ $rc -eq 0 ] || { echo "$out" | grep -E "FAIL" | sed "s/^/  /"; fail=1; }
echo; echo "== unit: forwarded headers"
out=$(bin/test_httphdr 2>/dev/null); rc=$?; echo "  $(echo "$out" | tail -1)"; [ $rc -eq 0 ] || { echo "$out" | grep -E "FAIL" | sed "s/^/  /"; fail=1; }
echo; echo "== unit: accepted-peer decoding (IPv4 / IPv6 socket layouts)"
out=$(bin/test_peer 2>/dev/null); rc=$?; echo "  $(echo "$out" | tail -1)"; [ $rc -eq 0 ] || { echo "$out" | grep -E "FAIL" | sed "s/^/  /"; fail=1; }
echo; echo "== unit: topic coverage (ws_profiles allow rules are sound)"
out=$(bin/test_topiccover 2>/dev/null); rc=$?; echo "  $(echo "$out" | tail -1)"; [ $rc -eq 0 ] || { echo "$out" | grep -E "FAIL|UNSOUND" | sed "s/^/  /"; fail=1; }
echo; tests/integration/run.sh || fail=1
echo; [ $fail -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $fail
