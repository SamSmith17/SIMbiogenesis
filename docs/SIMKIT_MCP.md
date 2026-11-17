# Simulating sites with your own AI (the simulation MCP server)

SIMbiogenesis can run a site for a year (or ten) on its own simulation without
opening the game window, and report what happened in a few hundred tokens. An
AI model you choose, including a local one running on the site's own solar,
can use that to try designs, compare them and send the best one to the game.
The game has no AI built in; you connect yours.

```
your AI  ──MCP (stdio)──▶  tools/simkit_mcp/simbio_sim_mcp.py  ──launches──▶  headless kernel
  (Claude, LM Studio,          sandboxed workspace, validated ids,         core/simkit/sim_kernel.tscn
   a local Ollama model)       design checks, run queue, reports           (the game's own sim, no rendering)
                                        │
                                        └── submit ──▶ the game's inbox ──▶ you review it as an experiment fork
```

## What a run is

The kernel is the game's own `Main`, `SolarUI` and graph view in a scene with
nothing else: no terrain, vegetation, buildings, player or HUD, so nothing is
drawn. The year is stepped by the same code the harness used
(`core/simkit/simkit_year.gd`):

| Part | Source |
|---|---|
| Solar | SolarUI's evaluator: Meeus sun position, the site's Open-Meteo archive, the array as wired |
| Battery, AC shed / resume | `EnergyTimeline.step_soc` with SolarUI's floor and hysteresis |
| Loads | `GraphAcLoad` (a machine draws only while it runs) |
| People | `NpcPopulationBridge` (needs, routines, chores, morale, departures), or `people: "rates"` |
| Automations | the graph's own rules in sim time (`AutomationSim`) |
| Tanks, machines, plants, rain | `ResourceFlowEngine.render_step` |

Extreme weather (dust, smoke, damaging wind) follows the world: a world with it
switched on runs with it, from the weather and air-quality data the game has
already cached for that site (`hazards: "on"` / `"off"` to override).

With `people: "agents"` every person is simulated and a recipe step that needs
hands waits for one. With `people: "rates"` the camp consumes at the preset
rates and labour is free, since nobody is simulated to do the work; it is
several times faster and good for a first look, and the report says which it
was under `fidelity`.

Not simulated in the kernel yet: ponds and streams carved in the terrain, shade
on panels from trees and buildings, festival camp power. The report lists them
under `fidelity.not_simulated`.

Checked against the in-game harness on the same design (60 days, people as
rates): loads agree to the watt-hour, every store and machine within 2 %, and
the array's output within 0.5 %.

Cost on the Bombay Beach ten-person design (117 nodes, 6-minute steps):

| | 60 days | 366 days |
|---|---|---|
| people as rates | ~2.3 min | ~12 min |
| people as agents | ~25 min | ~1.5 h (people doing every crew step) |

## Setting it up

Requirements: Python 3.9+ (standard library only) and the Godot 4.7 binary the
project uses (from a source checkout), or the game's exported executable.

```bash
python tools/simkit_mcp/simbio_sim_mcp.py --godot "C:/path/Godot_v4.7.1-stable_win64_console.exe" check
```

`check` prints what the server found: the binary, the project, your worlds
(each world is a site) and the built-in designs. A site's weather is copied
from the game's own cache, so open a world in the game once before simulating
it, or start the server with `--allow-download`.

### Claude Code

```bash
claude mcp add simbiogenesis-sim -- python C:/path/SIMbiogenesis/tools/simkit_mcp/simbio_sim_mcp.py --godot C:/path/Godot_console.exe
```

### Claude Desktop, LM Studio and other MCP hosts

Add to the host's MCP config (`claude_desktop_config.json`, LM Studio's
`mcp.json`, …):

```json
{
  "mcpServers": {
    "simbiogenesis-sim": {
      "command": "python",
      "args": ["C:/path/SIMbiogenesis/tools/simkit_mcp/simbio_sim_mcp.py",
               "--godot", "C:/path/Godot_v4.7.1-stable_win64_console.exe"]
    }
  }
}
```

### A local model with no MCP host (Ollama, llama.cpp, vLLM)

`tools/simkit_mcp/local_llm_loop.py` drives the server for any
OpenAI-compatible endpoint with tool calling:

```bash
python tools/simkit_mcp/local_llm_loop.py --model qwen3:14b --godot C:/path/Godot_console.exe --site <world id> --base bombay_ten --goal "Keep it SUSTAINED with the smallest battery."
```

Defaults to Ollama on `http://localhost:11434/v1`; `--base-url` for LM Studio
(`http://localhost:1234/v1`) or llama.cpp. Models with good tool calling at
7–14 B parameters do the loop fine; the reports are built to fit a small
context.

### Open WebUI

Through [mcpo](https://github.com/open-webui/mcpo), bound to this machine only:

```bash
uvx mcpo --host 127.0.0.1 --port 8000 -- python tools/simkit_mcp/simbio_sim_mcp.py --godot C:/path/Godot_console.exe
```

## The tools

| Tool | What it does |
|---|---|
| `list` | sites (your worlds), designs, recent runs |
| `catalog` | library modules a design may name; `q` / `category` filter, `label` for one module's ports and settable fields |
| `design_get` | a design: an outline (nodes, counts, settings, solar; ~4 kB) or `view: full` (~18 kB) |
| `design_put` | save a design whole, or as `base` + `patch` (below) under a new id |
| `run` | simulate a design at a site; `days` (366), `people` agents / rates, `hazards` site / on / off, `step_min` (6), `start`, `validate_only`, `wait_s` |
| `status` | progress, day, ETA |
| `report` | `part`: summary (default) / checks / kpi / stores / machines / monthly / bottlenecks / daily / all; `ids` filters rows to node ids |
| `compare` | 2–6 runs: verdicts, failed checks, only the KPIs and stores that differ |
| `cancel` | stop a run |
| `submit` | send a design and a finished run of it to the game's inbox |

### The patch language

So a model never has to resend a 20 kB design to change one number:

```json
{"id": "bt_small_battery", "base": "bombay_ten", "patch": {
  "top":   {"people": 12},
  "set":   {"bat_c": {"kwh": 10.0}, "cistern": {"capacity_qty": 300000}},
  "nodes": {"ghb": {"count": 10}},
  "add":   [{"id": "tank2", "preset": "Water Tank (250 gal)"}],
  "remove": ["awg"],
  "wires_add": [["sandfilter", "tank2", "water"]],
  "wires_remove": [["gfilter", "reclaim"]],
  "solar": {"pv_a": {"series": 9, "parallel": 3}},
  "ac_add": {"ctl_a": ["tank2"]}
}}
```

`null` as a value removes a field. Node ids in every report are the design's
own ids (`ghb_3` for the third of a `count: 12` node), so what a report names, a
patch can change.

### The design format

A design is data: library presets by label, inspector fields under `set`, wires
by kind, automations as WHEN / IF / THEN cards that switch nodes, and
`logic`: a list of control blocks (on / off band, PID, interlock, timer,
counter, sequence, duty pair) whose tags name design nodes
(`tank.<node id>.level`, `node.<node id>`, `valve.<node id>.open`); the
report's `logic` rows say what each ended on, how often it switched and, for a
band or a PID, `in_band_pct` (the share of the run its reading spent between
its marks, or within 5 % of its setpoint). `alarms`: a list of limit rules
(`{id, name, tag, op ">=" | "<=" | "on" | "off" | "lost", limit, deadband,
delay_s}`) on the same tags; the report's `alarms` rows say how many times each
went off and for how many hours. Valves and pumps are library presets like any
other node ("Ball Valve", "Control Valve", "Transfer Pump"). See the
built-in `core/simkit/designs/bombay_ten.json`. The engine rules a design must
respect (proportional processors, batches need a stop rule, wire every port, a
rain catchment needs the Rain source) are in `tools/sysdesign/README.md`.

### The report

`report` with no `part` returns, for example:

```json
{"run":"r20261111_…","design":"Bombay Beach closed loop, ten people","days":366,
 "verdict":"SUSTAINED","fails":[],
 "kpi":{"pv_kwp":15.2,"battery_kwh":62.4,"solar_possible_kwh":…,"curtailed_pct":…,
        "load_kwh_day":…,"ac_off_h":0,"min_soc_pct":…,"people_end":10,"morale_mean":…},
 "bottlenecks":["fwaste (food_waste) was empty 674 h, first on day 0", "…"],
 "fidelity":{"kernel":"headless","people":"agents","step_min":6,"not_simulated":[…]}}
```

Rules that keep it short and diffable: three significant figures everywhere,
tables as `{cols, rows}`, rows keyed by design node id, the bottlenecks ranked.
It never contains the site's coordinates or name.

The summary also has a `flows` block: the biggest wires by total and how much
of each resource cycled back (Finn's cycling index). For people, each run
folder (`runs/<run id>/`) holds `flows.svg`, the year's loop Sankey: the main
stream runs down, what cycles back returns up the sides. Hovering a ribbon in a
browser shows its value.

With people as agents, `time_use` says how they spent the run: hours per
person per day by category (sleep, toilet, washing, eating, drinking, work,
walking, queueing, hanging out, venues, idle), beside the American Time Use
Survey 2025 averages (`vs_atus`), and `work_per_person_h_week` is the work
each person did per week, so a design can trade machines against human
hours. Both are empty with people as rates.

## In the game: reviewing a submitted design

A submitted design lands in the game's `user://simkit/inbox/`. When a world
loads the game says how many are waiting. Open **Compare** (⧉ on the timeline)
→ **A vs B** → **From AI tools**: each entry shows its verdict, what failed and
its first bottleneck. Importing one makes an experiment **fork** of the world
and selects it as B. From there, the tools you already have: run A vs B on this
world's own weather and battery, **Edit B** to open it in the graph editor,
rename or delete it. Nothing in your world changes unless you build it.

## Security

The server is built so that connecting an AI cannot reach past the simulation.

- **No network port.** It speaks MCP over stdio to the host that started it.
- **One folder.** Everything it reads or writes is inside its workspace
  (`%LOCALAPPDATA%/SIMbiogenesis_simkit` by default), named by ids checked
  against `[A-Za-z0-9_-]{1,64}`; a client never passes a path. From the
  game's data it reads only each world's `world.json` (coordinates) and
  `snapshot.json` (whether extreme weather is on), the site's weather and
  air-quality caches, and three settings files the simulation uses
  (`solar_panel_config.cfg`, `sim_settings.cfg`, `extreme_weather.cfg`, none of
  which holds a secret), copying them into the kernel's folder. It writes only
  to `simkit/inbox/` (off with `--no-submit`).
- **The kernel is sandboxed.** It runs with a whitelisted environment (no API
  keys pass through) and its own empty user folder: no worlds, no Home
  Assistant profile, no tokens. Inside it `SimkitMode` blocks every network
  request the game can make (Home Assistant, multiplayer, Discord, map and AI
  imagery, alerts, air quality); the weather archive downloads only with
  `--allow-download`.
- **Designs are data.** Size, depth, node count, ids and keys are checked by
  the server and again in the kernel (`core/simkit/simkit_guard.gd`). Fields
  that could point outside the sim (scene or device paths, Home Assistant
  links, URLs, files) are stripped; automations keep only switch and delay
  actions, never service calls.
- **The game decides.** A submitted design is a file in an inbox; the game
  checks its graph again on import and only ever makes it a fork. Nothing is
  applied to a world without the player.
- **Privacy.** Reports and site listings carry no coordinates and, unless you
  start the server with `--share-place-names`, no world names (a world is
  often named after its street address). An external model sees the climate
  through the results, not where you live.
- **Limits.** One run at a time by default (`--max-parallel`), a wall-time cap
  per run (`--max-wall-s`, 2 h), the newest 200 runs kept.

## Checks

```bash
Godot --headless --path . --script core/simkit/simkit_selftest.gd
python tools/simkit_mcp/mcp_selftest.py
python tools/simkit_mcp/mcp_selftest.py --godot <Godot console exe>
```
