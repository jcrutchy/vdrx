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

**Hardened and paranoid builds.** `HARDEN=1 ./build.sh` links a position-independent
executable with full RELRO (ASLR for the main image). FreePascal's RTL still
contributes some text relocations, so check `readelf -d bin/vdrx` against your
distribution's or SELinux policy before relying on it. `PARANOID=1 ./build.sh tests`
adds range, overflow, stack and virtual-call checks (slower; run the unit tests,
`tests/run.sh` and the fuzzer with it to flush out memory bugs - the current suite
passes with no findings). The default build is neither.

**Running.** By default vdrx reads `vdrx.conf` from the *current directory* and
writes `vdrx_daemon.log` there. To use a different file, pass `-c <file>` /
`--config <file>` (or `--config=<file>`); it must exist or vdrx stops with
`configuration file not found`, and `-h` / `--help` prints the usage. Any other
argument is an error, so a typo cannot silently start vdrx on the wrong
configuration. Relative paths in the config (`static_dir`, `doc_root`,
`script_dir`, runner and process commands) resolve against the *current
directory*, not against the config file's folder - use `{MAIN_CONF_DIR}` in a
path when you want it anchored to the config file. So either run vdrx from the
folder that holds the config, or give it `--config` and start it from the folder
the relative paths are meant for:

```bash
cd examples/php-cgi
../../bin/vdrx
```

Every folder under `examples/` is a complete, runnable setup like that - see
[guides/](guides/README.md). Type `quit` in the console (or send SIGTERM / Ctrl-C)
to stop it; `reload` re-reads the config.

---
*Section numbers (§N) are shared across all vdrx docs - see the [section map](README.md#section-map).*
