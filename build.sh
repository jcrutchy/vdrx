#!/bin/sh
# Build the vdrx daemon (and optionally the test programs) with plain fpc.
#   ./build.sh            -> bin/vdrx
#   ./build.sh tests      -> also bin/test_jsonconf, test_redact, test_stall, test_socket_stall, vdrx_stress
# Needs: fp-compiler fp-units-fcl fp-units-net (and libssl-dev for TLS at run time)
set -e
cd "$(dirname "$0")"
mkdir -p bin build/units
FPC="fpc -B -Mobjfpc -Sh -O1 -vew -Fusrc -FUbuild/units -FEbin"
# HARDEN=1   position-independent executable + full RELRO (ASLR for the main image; FPC links some RTL
#            code with text relocations, so check `readelf -d bin/vdrx` on your distribution/SELinux policy).
# PARANOID=1 range, overflow, stack and virtual-method-call checks: slower, for running the test suites and
#            fuzzers to flush out memory bugs - not for production.
[ "$HARDEN" = "1" ] && FPC="$FPC -Cg -fPIC -k-pie -k-z -know -k-z -krelro"
[ "$PARANOID" = "1" ] && FPC="$FPC -Cr -Co -Ct -CR"
$FPC src/vdrx.lpr
if [ "$1" = "tests" ]; then
  $FPC tests/unit/test_jsonconf.lpr
  $FPC tests/unit/test_redact.lpr
  $FPC tests/unit/test_spawn.lpr
  $FPC tests/unit/test_registry.lpr
  $FPC tests/unit/test_linebuf.lpr
  $FPC tests/unit/test_iplimit.lpr
  $FPC tests/unit/test_httphdr.lpr
  $FPC tests/unit/test_peer.lpr
  $FPC tests/unit/test_sha256.lpr
  $FPC tests/unit/test_topiccover.lpr
  for t in test_stall test_socket_stall; do $FPC tests/manual/$t.lpr; done
  $FPC tests/stress/vdrx_stress.lpr
fi
echo "built: $(ls bin | tr '\n' ' ')"
