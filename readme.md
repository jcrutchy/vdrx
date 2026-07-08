# VDRX: Visual Data Relay Executive

**VDRX** is a lightweight, template-driven orchestration engine designed to turn your command-line environment into a spatial, visual workspace. It acts as the "Executive" layer between your background system processes and your local browser, transforming raw `stdout` streams into real-time, interactive UI widgets.

---

## The Philosophy

VDRX follows the principle that **everything is a data stream.** Instead of building heavy, monolithic web applications, VDRX uses a recursive template engine to project your command-line state onto an infinite virtual canvas.

* **IRC-Native**: Control your workspace using standard IRC commands.
* **Template-Driven**: UI widgets are defined by simple, modular template files.
* **Persistent State**: Your UI layout is saved instantly via message-based "buckets."
* **Process-Agnostic**: Pipe output from any CLI tool directly into a live dashboard.

---

## How It Works

1. **The Engine**: The VDRX core binary acts as a broker, managing the lifecycle of your scripts (`TProcess`) and the routing of data streams.
2. **The Relay**: It consumes output from your scripts (via `stdin/stdout` IPC) and broadcasts them as events.
3. **The Canvas**: The browser acts as a "Graphical TTY." It listens for VDRX events, resolves local templates, and renders the UI in real-time.

---

## Quick Start

### 1. Build

```bash
fpc vdrx.pas

```

### 2. Configure

Create a `config.json` to define your script directory, template paths, and bucket file location.

### 3. Launch

```bash
./vdrx --config config.json

```

---

## Commands

VDRX is designed to be controlled via IRC or any terminal-based client:

* `~canvas-add <template_name> <id>` — Injects a new widget into the canvas.
* `~bucket-set <key> <json_value>` — Persists state to your workspace memory.
* `~script-cmd <alias> <args>` — Sends signals directly to running background agents.

---

## Project Structure

* `/templates` — Modular `.tpl` files (recursive HTML/JS).
* `/scripts` — Your collection of data-gathering binaries.
* `/buckets` — Persistent state and coordinate storage.

---

## Why VDRX?

You aren't "designing a dashboard"—you are **weaving a system.** Whether it's monitoring your Tesla's energy usage, tracking RAAF compliance checklists, or just piping `cowsay` to a floating bubble, VDRX provides the plumbing to turn your CLI output into a living, visual environment.

---

*Built for the data-junkie who prefers the terminal but appreciates a view.*
