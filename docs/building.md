# 8. Building and running

```bash
apt-get install fp-compiler fp-units-fcl fp-units-net
./build.sh              # -> bin/vdrx          (Windows: build.bat, or open src/vdrx.lpi in Lazarus)
./build.sh tests        # also the test programs (see tests/README.md)
```

`build.sh` is just `fpc -Mobjfpc -Sh -O1 -Fusrc -FUbuild/units -FEbin src/vdrx.lpr`;
the Lazarus project `src/vdrx.lpi` writes the same `bin/vdrx`. `bin/`, `build/` and
`src/lib/` are build output and git-ignored.

(TLS needs the OpenSSL *runtime* library - `libssl3` on current Debian/Ubuntu,
`openssl-libs` on RHEL - which is almost always there already. The `-dev`
package is **not** needed: FPC's `openssl` unit only looks for the unversioned
`libssl.so`, so vdrx finds `libssl.so.3` (or `.1.1`) itself, through a private
temporary link that it removes again, and logs one line saying so. If TLS
still does not start, the log says why: `TLS port ... NOT started`.)

**Running.** vdrx reads `vdrx.conf` from the *current directory* (there is no
command-line option for a different path) and writes `vdrx_daemon.log` there.
Relative paths in the config (`static_dir`, `doc_root`, `script_dir`, runner and
process commands) resolve against that same directory. So you run it from the
folder that holds the config:

```bash
cd examples/php-cgi
../../bin/vdrx
```

Every folder under `examples/` is a complete, runnable setup like that - see
[guides/](guides/README.md). Type `quit` in the console (or send SIGTERM / Ctrl-C)
to stop it; `reload` re-reads the config.

---
*Section numbers (§N) are shared across all vdrx docs - see the [section map](README.md#section-map).*
