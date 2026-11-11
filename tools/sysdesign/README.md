# Whole-system design harness

Design a site as data, build it from the library's own presets, run it for a
year or more on the game's simulation, and read what happened.

## The loop

1. Write a design: `core/simkit/designs/<name>.json` (the engine, builder,
   stepper and report live in `core/simkit/` so the headless kernel and the
   MCP server use them too; see `docs/SIMKIT_MCP.md`).
2. Dry-run it in the harness sandbox (the world is not changed):

   ```
   $env:SYSDESIGN = "bombay_ten"; $env:SYSDESIGN_DAYS = "366"
   tools\harness.ps1 -World <world id> -RunScript res://tools/sysdesign/run_design.gd -Label sysdesign -Timeout 3400
   ```

3. Read `user://screenshots/<label>/report.md` (also `report.json`, `daily.csv`).
4. Change the design, run again.
5. Build it into a world for real: `tools/fixes/closed_loop_world.gd` (below).

A year with ten simulated people at 6-minute steps takes about 27 minutes.
`SYSDESIGN_PEOPLE=0` drops the people (the habitat bills its headcount at the
preset rates) and runs several times faster for a first look.
`SYSDESIGN_DUMP=autos,board,<node id>` prints the automation log, the chore
board or a node's state at the end.

## What a run is

`core/simkit/simkit_year.gd` steps the LIVE graph of the loaded world with the game's
own pieces, in the order the pre-render uses:

| Part | Source |
|---|---|
| Solar | `SolarUI.evaluate_solar_pair_at` (Meeus sun position, the site's weather archive, the array as wired) |
| Battery, AC shed / resume | `EnergyTimeline.step_soc`, SolarUI's floor and hysteresis |
| Load | `GraphAcLoad.compute_watts_offline` (a machine draws only while it runs) |
| People, chores | `NpcPopulationBridge.tick_at` (needs, routines, morale, departures, the chore board) |
| Automations | `AutomationSim` over each node's `graph_automations`, switched through the node's `GraphSimLoad` proxy |
| Tanks, machines, plants, rain | `ResourceFlowEngine.render_step` |
| HomeBiogas, tools | the graph view's own machine ticks |

The player's testing switches (ideal supply, no departures, ignore capacity)
are reset in memory for the run. Labour is finite and the abstract pool of
hours is zero, so a recipe step that needs hands waits for a person.

## What "sustained" means

`core/simkit/simkit_report.gd` passes a run only if all of these hold:

- nobody went without water or food (an empty meal counter does not count:
  people fall back to the pantry);
- the inverter never shed the loads;
- everyone stayed, and mean morale was at least 0.6;
- no import node ran and no ideal-supply top-up happened;
- no waste store overflowed;
- water and food stores ended no lower than 90 % of where they began (for a
  run of 300 days or more);
- no store handed out more than it held (the flow engine lets a nearly empty
  store serve a whole step's draw).

## The design format

```
{
  "name": "...", "people": 10,
  "start": {"year": 2024, "month": 1, "day": 1, "hour": 6}, "days": 366,
  "nodes":  [{"id": "gh", "preset": "<library label>", "count": 9,
              "set": {<inspector fields>}, "state": "on" | "off",
              "recipe": "<catalog recipe id>" | "recipe_file": "<recipes/x.json>" | "recipe_def": {...},
              "automations": [<WHEN / IF / THEN cards>]}],
  "solar":  [{"id", "panel": "<panel label>", "series", "parallel", "controller": "<node id>"}],
  "dc":     [["<controller>", "<battery>"]],
  "ac":     {"<controller>": ["<node id>", ...]},
  "wires":  [["<from>", "<to>", "<kind>"]],
  "spaces": [{"type", "at": [east, south], "size": [w, d], "capacity", "label"}],
  "world":  {...}        // only the world builder reads this
}
```

- A node is a library preset by LABEL, so a design can only use modules a
  player can drop from the library. `set` holds fields the inspector edits.
- `count` makes `gh_1 … gh_9`; a wire naming `gh` reaches all of them.
- A wire's ports are found by kind. `"blackwater>water"` carries blackwater
  onto a port that takes water (the canvas allows any two kinds of one unit).
  `"dc"` wires a generator's DC pair to a battery.
- Processors are OFF unless switched on; a node with automations starts off
  and its rules switch it (the game's own rule).
- `core/simkit/recipes/*.json` are fitted from the TC Process Lab's model by
  `fit_tc_recipes.gd` (headless), with a crew step to load and one to empty.

## Building a world from a design

```
Godot --headless --path . --script tools/sysdesign/create_world.gd -- --from=<world on the map> "--name=<name>"
tools\harness.ps1 -World <new id> -RunScript res://tools/checks/closed_loop_world_check.gd -Label closed_loop_world -Timeout 2400   # watch it in the sandbox
tools\harness.ps1 -World <new id> -RunScript res://tools/fixes/closed_loop_world.gd -Persist                                        # keep it
```

The builder puts the graph on the world, places a 3D twin for each node the
`world` block lists (as packed kits, some stowed in a cargo container), the
living vehicles the people arrive in, a gate, the spaces, the standing
chores, and an ARRIVE then DEPLOY schedule.

To change a world that is already built (and maybe already played) without
starting it over, edit the design and sync it:

```
$env:SYSDESIGN = "bombay_ten"
tools\harness.ps1 -World <id> -RunScript res://tools/fixes/closed_loop_sync.gd            # dry run
tools\harness.ps1 -World <id> -RunScript res://tools/fixes/closed_loop_sync.gd -Persist   # keep it
```

It keeps the clock, the people, the props, node positions and every store's
stock (unless the node says `"sync_reset_level": true`), adds the nodes the
design gained next to what they are wired to, removes the ones it lost,
applies `set` and recipes, and rebuilds the design's wires. A `"@start"` value
(a greenhouse's planting hour) becomes the schedule's DEPLOY hour there.

Run year checks on the base map world (`w6ad922917357` for Bombay Beach), not
on the built world: its own deploy schedule makes the people sim several
times slower.

## What bombay_ten models (2026-11-09 revision)

- Water: raw rain cistern -> sand filter + UV -> drinking day tank (people,
  kitchen). Greywater -> filters -> reclaimed water (irrigation only: four
  greenhouse beds, the plots, the digester's water), never the drinking tank.
- Sanitation: urine-diverting flush toilets. Urine -> storage -> nutrient
  recovery (nitrify, distil, desalt) -> nutrients + reclaimed water + brine to
  a salt pan. Brownwater -> digester (biogas) -> digestate filter -> nutrients
  + reclaimed water. Kitchen scraps -> HomeBiogas -> the same digestate filter.
  Plot biomass and plate scraps -> hot compost -> nutrients.
- Nutrients are kg of N + P + K; a bed takes about 1 % of its food's weight.
  A starter 15 kg covers the gap while the loop comes up.
- Food: 1500 kg of packaged supplies, opened when the pantry runs low, each
  kilo leaving plastic and card / tin. Twelve 20 m polycarbonate domes, each
  with 192.5 m² of keyhole ring beds (2,310 m² in all: by the plant model a
  m² under polycarbonate here makes 2.9 kg of food a year, so ten people
  need about 1,900 m²). Beds are sown when the crew builds them and come up
  over two months; the summer surplus fills the pantry for the winter dip.
  What is not eaten goes to the biomass store and on to compost. A plastic
  collection run fetches waste plastic once the bin is empty and the site
  feeds itself.
- Chores: one per dome and per plot (`"each": true`), hours from the area.
- Pyrolysis condensers run on a closed radiator loop (no cooling water out).

## Engine rules a design has to respect

- A proportional processor moves `min(port rates) × efficiency` in total;
  only `io_absolute` presets move each authored rate.
- A batch pushes its outputs even into a full store, so a batch machine needs
  a rule that stops it (the kitchen stops when the counter is stocked).
- An unwired port falls back to any other store wired to that node. Wire
  every port.
- A store counts as "has supply" above 0.1 % full and then serves a whole
  step's draw. Keep `capacity × 0.001` above the largest draw per step, or
  gate the consumer with a rule.
- A rain catchment needs the Rain source wired into it.
