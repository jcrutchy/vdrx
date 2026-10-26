# 10. Config viewer - `tools/conf_viewer.html`

A single HTML file (no dependencies; open it in a browser) that draws a
conf as a bus diagram: topics are coloured lanes, publishers sit left,
subscribers right, and a list of wiring checks (a route nobody serves, a
process that can't reply, duplicate ids/prefixes ...) sits beside it. Load a
conf with *Open…*, *Paste…*, drag-and-drop, or *Add file…* for each file of an
`includes` chain.

**Live mode.** Fill in the WebSocket URL, a `ws_profiles` id and token and
press *Go live*: the viewer subscribes to exactly the lanes it draws and
animates messages along them (publisher -> lane -> subscribers), with a
colour-coded terminal underneath (click a line to highlight its lane).
Give it a read-mostly profile, e.g. the `viewer` entry in [`reference.vdrx.conf`](reference.vdrx.conf).

**Files over the bus.** *Open via bus…* and *Load includes* read config
files from the machine running vdrx: the viewer publishes to `confserver.in`
and the `confserver` runner (`tools/confserver.php`) answers on the
viewer's own `viewer.reply.*` topic. The script only serves `.conf`/`.json`
files below the `$roots` listed at its top - edit that list for projects
outside the vdrx folder. Open the root conf via the bus first so relative
include paths resolve against its real folder.

---
*Section numbers (§N) are shared across all vdrx docs - see the [section map](README.md#section-map).*
