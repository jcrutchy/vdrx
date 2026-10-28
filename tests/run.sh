#!/bin/sh
# Run every automated test:  tests/run.sh
#   1. build the daemon and the test programs   (./build.sh tests)
#   2. unit tests                               (bin/test_jsonconf, bin/test_redact)
#   3. integration tests                        (tests/integration/run.sh)
# The stress suite (tests/stress) and the stall demos (tests/manual) are run by hand - see tests/README.md.
cd "$(dirname "$0")/.." || exit 1
fail=0
echo "== build"; ./build.sh tests >/dev/null 2>&1 || { ./build.sh tests; exit 1; }; echo "  built bin/"
echo; echo "== unit: jsonconf"
out=$(bin/test_jsonconf 2>/dev/null); rc=$?; echo "  $(echo "$out" | tail -1)"; [ $rc -eq 0 ] || fail=1
echo; echo "== unit: log redaction"
out=$(bin/test_redact 2>/dev/null); rc=$?; echo "  $(echo "$out" | tail -1)"; [ $rc -eq 0 ] || { echo "$out" | grep -E "FAIL|leaked|changed|output" | sed "s/^/  /"; fail=1; }
echo; tests/integration/run.sh || fail=1
echo; [ $fail -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $fail
