#!/bin/sh
# Build the vdrx daemon (and optionally the test programs) with plain fpc.
#   ./build.sh            -> bin/vdrx
#   ./build.sh tests      -> also bin/test_jsonconf, test_redact, test_stall, test_socket_stall, vdrx_stress
# Needs: fp-compiler fp-units-fcl fp-units-net (and libssl-dev for TLS at run time)
set -e
cd "$(dirname "$0")"
mkdir -p bin build/units
FPC="fpc -B -Mobjfpc -Sh -O1 -vew -Fusrc -FUbuild/units -FEbin"
$FPC src/vdrx.lpr
if [ "$1" = "tests" ]; then
  $FPC tests/unit/test_jsonconf.lpr
  $FPC tests/unit/test_redact.lpr
  for t in test_stall test_socket_stall; do $FPC tests/manual/$t.lpr; done
  $FPC tests/stress/vdrx_stress.lpr
fi
echo "built: $(ls bin | tr '\n' ' ')"
