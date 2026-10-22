# SIMbiogenesis

**Pick any place on Earth, then design, build and live in an off-grid site there.**

SIMbiogenesis is a first-person simulator for renewable energy and in-situ resources, made with [Godot 4.7](https://godotengine.org). Choose a spot on a world map and the game builds the land from real data: elevation, satellite imagery, OpenStreetMap buildings, roads, water and forest, plus that site's real historical weather. On that land you design how energy, water, food and waste move:

- solar arrays, wind turbines and micro-hydro;
- batteries, inverters and charge controllers;
- ponds, siphons, penstocks and tanks;
- processors, camps and whole festivals of simulated people.

You design those systems on a schematic **systems graph**. Every node on the graph is also a real object in the 3D world, so you can walk up to it, follow its pipe down the hill and watch the battery charge as the sun crosses the sky. The physics uses published models: solar position and irradiance, Betz-limited wind, pipe friction and Pelton/siphon hydraulics, and battery state of charge integrated over time. Your site's numbers mean something.

A **Home Assistant bridge** connects a real off-grid system to its digital twin. Live inverter and battery data drives the graph, and recorded history can be replayed and compared against the simulation.

<p align="center"><img src="docs/tour/arrival.jpg" width="820" alt="A generated site: real terrain, imagery and OSM buildings around the player"></p>

> **Status:** in active development, with no packaged releases yet. Run it from source with the Godot editor (below). Mostly tested on Windows 11 with an NVIDIA/AMD GPU.

## What you can do

- **Make a world anywhere.** Use the launch hub's world map or address search, then **New world here**. Terrain, imagery, buildings, roads, streams, ponds and auto-generated vegetation load for that location. Worlds save continuously, and several can share one map.
- **Design systems on the graph (G).** Wire panels, controllers, batteries, inverters, loads, tanks, ponds and processors. Strings over-volt, shorts trip and batteries overcharge, all following the real electrical rules. Three 3D lenses show the same design in context: **Site Plan**, **Elevation** cross-section, and a **Globe** of your sphere of influence.
- **Build the place.** Use the edit toolbar for terrain sculpting (**T**), vegetation (**V**), camps (**C**) and water and streams. There is also a Light Studio (**J**), a building builder (**B**), placed props and vehicles, and pallet-rack structures.
- **Engineer the water.** The **Hydro Lab** sizes siphon turbines and stream-fed Pelton penstocks against the real terrain profile and seasonal flow.
- **Watch people live there.** Simulated residents have needs, routines, morale and jobs. They work through chore boards and site projects, crowd into festivals with stages and effigy burns, and walk away if the water runs out.
- **Learn it.** The **Solar Bootcamp** is a 12-level tutorial. Pre-baked **challenges** replay a whole day or year in seconds, and a feature tour walks through every mode.
- **Labs:** **Linkage Lab** (deployable scissor structures), **Packing Lab** (will it fit in the truck?), a parametric OpenSCAD store, a mud printer, CSP heliostats.
- **Play together.** Co-presence multiplayer has Discord sign-in, discovery and chat relay.

Every mode is shown with screenshots in the [feature tour](#what-it-does) below and in **[docs/FEATURES.md](docs/FEATURES.md)**.

## Getting started

### Requirements

| | |
|---|---|
| **Engine** | [Godot **4.7.1**](https://godotengine.org/download/archive/), the **standard** build (not the .NET/C# one) |
| **OS / GPU** | Windows 10/11 is the main target; Linux and macOS export presets exist but get less testing. You need a GPU with Vulkan support (the Forward+ renderer). |
| **Network** | Needed the first time you visit a site, to download elevation, imagery, OSM and weather. After that the data is cached, and a cached site loads offline. |
| **Optional** | Python 3 for the `tools/` scripts; [ffmpeg](https://ffmpeg.org) on `PATH` for video export and tour recording; [OpenSCAD](https://openscad.org) for the parametric store |

### Download and first run

**Just want to play?** Download the zip for your computer from the
[Releases](https://github.com/SamSmith17/SIMbiogenesis/releases) page, unzip it
and run it. Put the optional `simbiogenesis-art-*.pck` files from the same page
next to the game for the built-in maps and detailed models. The release notes
have the macOS and Linux details, and [docs/RELEASES.md](docs/RELEASES.md) has
the whole picture.

**From the source:**

1. **Get the code:**
   ```bash
   git clone https://github.com/SamSmith17/SIMbiogenesis.git
   ```
   You can also use **Code → Download ZIP** on GitHub and unzip it.
2. **Open it in Godot.** Start Godot **4.7.1** (check the version: another one may not open the project), choose **Import** in the Project Manager, and select the `project.godot` file in the folder.
3. **Wait for the first import.** Imported-asset caches are not stored in git, so the first time Godot opens the project it imports every texture and model. That takes a few minutes. Later opens are fast.
4. **Press F5 (Run Project).** The launch hub opens: your worlds on the left and an energy map of the planet.
5. **Make a world.** Click a place on the map (or search an address), then press **New world here ⊕**. A new site takes about 15–60 s on the first visit while its data downloads; cached sites start in seconds.
6. **Look around.** Walk with **WASD** and **Shift**. Press **G** for the systems graph, **F1** for the in-game help and key list, **Tab** for a drone view, and **F5** for third person.
7. **Got a friend's worlds?** Drop their `.simpack.zip` onto the game window (or **Share… → Install a pack** in the hub) and press **Install**. If the pack carries game art, the Share window imports it and then asks you to **Restart now**; after that their worlds open exactly as they left them.

No accounts or API keys are needed: elevation (Open-Meteo / Copernicus), imagery (Esri World Imagery), OpenStreetMap and weather (Open-Meteo) all work without keys.

### What a fresh clone does not include

The repository is kept small. It holds the code, UI, shaders and small shared data. The large bespoke art lives in a separate local asset pack and is gitignored. That art includes the hand-built SOAK festival and Mars maps, the Mixamo NPC pack, some imported models and the detailed player character.

- **Everything built around a generated location works without it.** You get the terrain, systems graph, NPCs and labs, with simplified stand-ins wherever a model is missing.
- To add the art, install a shared pack: **Share… → Install a pack**, or drop the `.simpack.zip` file onto the game window. See **[docs/ASSETS.md](docs/ASSETS.md)** for what lives where.

### Optional integrations

These all stay off until you configure them. Credentials live in Godot's per-user data folder (`user://`), never in the repo.

- **Home Assistant** digital twin
- **OpenTopography** (sharper US elevation)
- **Gemini** imagery enhancement
- **Mapillary** street photos
- **Discord** multiplayer

Setup for each is in **[docs/LOCAL_CONFIG.md](docs/LOCAL_CONFIG.md)**, with placeholder templates in [docs/config-templates/](docs/config-templates/).

### Essential controls

| Key | Does | Key | Does |
|---|---|---|---|
| **WASD**, **Shift** | Move, sprint | **G** | Systems graph |
| **Space** | Pause / play the clock | **L** | Location picker |
| **Esc** | Free the mouse / close the top panel | **T** / **V** / **C** | Terrain / vegetation / camps toolbar |
| **F1** | Help + every key | **J** | Light Studio |
| **Tab** | Drone view | **K** | Site Report |
| **F5** | Third person | **E** | Solar / power panel |

Every binding can be changed in **Settings → Controls**. The full player reference is **[docs/FEATURE_CHEAT_SHEET.md](docs/FEATURE_CHEAT_SHEET.md)**.

<!-- TOUR:BEGIN -->
<!-- Generated by tools/tour_docs.py — edit the tour stops in core/tour/stops/, not this block. -->

## What it does

A quick look at every mode — full write-ups with how to open each are in **[docs/FEATURES.md](docs/FEATURES.md)**.

**World** — The real place: terrain, imagery, sky, time and weather.

<table>
<tr>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#arrival"><img src="docs/tour/arrival.jpg" width="260" alt="Any place on Earth"></a><br><b>Any place on Earth</b><br><sub>Play → pick a world</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#drone_view"><img src="docs/tour/drone_view.jpg" width="260" alt="Survey drone"></a><br><b>Survey drone</b><br><sub>Tab</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#third_person"><img src="docs/tour/third_person.jpg" width="260" alt="Third person"></a><br><b>Third person</b><br><sub>F5</sub></td>
</tr>
<tr>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#day_night"><img src="docs/tour/day_night.jpg" width="260" alt="Time, sun and sky"></a><br><b>Time, sun and sky</b><br><sub>the timeline</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#night_sky"><img src="docs/tour/night_sky.jpg" width="260" alt="The real night sky"></a><br><b>The real night sky</b><br><sub>Home</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#planets"><img src="docs/tour/planets.jpg" width="260" alt="Planets"></a><br><b>Planets</b><br><sub>Settings → Planets</sub></td>
</tr>
<tr>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#moon_phases"><img src="docs/tour/moon_phases.jpg" width="260" alt="Moon phases"></a><br><b>Moon phases</b><br><sub>the timeline</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#analemma"><img src="docs/tour/analemma.jpg" width="260" alt="Analemma mode"></a><br><b>Analemma mode</b><br><sub>∞ on the timeline speed control</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#weather"><img src="docs/tour/weather.jpg" width="260" alt="Weather and extreme events"></a><br><b>Weather and extreme events</b><br><sub>⚙ → Extreme Weather</sub></td>
</tr>
<tr>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#location_picker"><img src="docs/tour/location_picker.jpg" width="260" alt="Choose a location"></a><br><b>Choose a location</b><br><sub>L</sub></td>
</tr>
</table>

**Build** — Shape the site and put things on it.

<table>
<tr>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#terrain_sculpt"><img src="docs/tour/terrain_sculpt.jpg" width="260" alt="Terrain sculpting"></a><br><b>Terrain sculpting</b><br><sub>T</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#vegetation"><img src="docs/tour/vegetation.jpg" width="260" alt="Forests, seasons and growth"></a><br><b>Forests, seasons and growth</b><br><sub>V</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#camps"><img src="docs/tour/camps.jpg" width="260" alt="Painted camps"></a><br><b>Painted camps</b><br><sub>C</sub></td>
</tr>
<tr>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#water"><img src="docs/tour/water.jpg" width="260" alt="Streams and drainage"></a><br><b>Streams and drainage</b><br><sub>T</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#prop_editor"><img src="docs/tour/prop_editor.jpg" width="260" alt="Placed things and the prop editor"></a><br><b>Placed things and the prop editor</b><br><sub>U</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#building_builder"><img src="docs/tour/building_builder.jpg" width="260" alt="Building builder"></a><br><b>Building builder</b><br><sub>B</sub></td>
</tr>
<tr>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#light_studio"><img src="docs/tour/light_studio.jpg" width="260" alt="Light Studio"></a><br><b>Light Studio</b><br><sub>J</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#vehicles"><img src="docs/tour/vehicles.jpg" width="260" alt="Vehicles"></a><br><b>Vehicles</b><br><sub>O</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#scad_store"><img src="docs/tour/scad_store.jpg" width="260" alt="Parametric hardware store"></a><br><b>Parametric hardware store</b><br><sub>H</sub></td>
</tr>
<tr>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#mud_printer"><img src="docs/tour/mud_printer.jpg" width="260" alt="Mud printer"></a><br><b>Mud printer</b><br><sub>U</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#pallet_rack"><img src="docs/tour/pallet_rack.jpg" width="260" alt="Pallet rack builder"></a><br><b>Pallet rack builder</b><br><sub>P</sub></td>
</tr>
</table>

**Systems** — The resource-flow graph and the tools that design it.

<table>
<tr>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#graph_freeform"><img src="docs/tour/graph_freeform.jpg" width="260" alt="The systems graph"></a><br><b>The systems graph</b><br><sub>G</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#graph_tools"><img src="docs/tour/graph_tools.jpg" width="260" alt="Graph tools: Tidy and show-only views"></a><br><b>Graph tools: Tidy and show-only views</b><br><sub>G</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#site_plan"><img src="docs/tour/site_plan.jpg" width="260" alt="Site Plan lens"></a><br><b>Site Plan lens</b><br><sub>G</sub></td>
</tr>
<tr>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#elevation"><img src="docs/tour/elevation.jpg" width="260" alt="Elevation lens"></a><br><b>Elevation lens</b><br><sub>G</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#globe"><img src="docs/tour/globe.jpg" width="260" alt="Globe lens"></a><br><b>Globe lens</b><br><sub>G</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#snowglobe"><img src="docs/tour/snowglobe.jpg" width="260" alt="Full-screen globe"></a><br><b>Full-screen globe</b><br><sub>SoI marker / full globe</sub></td>
</tr>
<tr>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#hydro_lab"><img src="docs/tour/hydro_lab.jpg" width="260" alt="Hydro Lab"></a><br><b>Hydro Lab</b><br><sub>Inspector → Open Hydro Lab</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#site_report"><img src="docs/tour/site_report.jpg" width="260" alt="Site Report"></a><br><b>Site Report</b><br><sub>K</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#bootcamp"><img src="docs/tour/bootcamp.jpg" width="260" alt="Solar Bootcamp"></a><br><b>Solar Bootcamp</b><br><sub>🎓 Bootcamp</sub></td>
</tr>
<tr>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#challenges"><img src="docs/tour/challenges.jpg" width="260" alt="Challenges"></a><br><b>Challenges</b><br><sub>🎯</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#conduit_routing"><img src="docs/tour/conduit_routing.jpg" width="260" alt="3D wire and pipe routing"></a><br><b>3D wire and pipe routing</b><br><sub>a device's port (press and drag)</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#wind_turbines"><img src="docs/tour/wind_turbines.jpg" width="260" alt="Wind turbines"></a><br><b>Wind turbines</b><br><sub>U</sub></td>
</tr>
<tr>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#csp_heliostats"><img src="docs/tour/csp_heliostats.jpg" width="260" alt="Concentrated solar: troughs and heliostats"></a><br><b>Concentrated solar: troughs and heliostats</b><br><sub>U</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#home_assistant"><img src="docs/tour/home_assistant.jpg" width="260" alt="Home Assistant live links"></a><br><b>Home Assistant live links</b><br><sub>HA</sub></td>
</tr>
</table>

**People** — The community that lives there, and the crowd simulation.

<table>
<tr>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#festival_mode"><img src="docs/tour/festival_mode.jpg" width="260" alt="Festival mode"></a><br><b>Festival mode</b><br><sub>Festival</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#settlement_view"><img src="docs/tour/settlement_view.jpg" width="260" alt="Settlement view"></a><br><b>Settlement view</b><br><sub>Settlement</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#effigy_burn"><img src="docs/tour/effigy_burn.jpg" width="260" alt="The burn"></a><br><b>The burn</b><br><sub>Prop editor → Fire</sub></td>
</tr>
<tr>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#starshade_crew"><img src="docs/tour/starshade_crew.jpg" width="260" alt="StarShade: built by the crew"></a><br><b>StarShade: built by the crew</b><br><sub>Rehearse build (prop editor)</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#npc_anim_editor"><img src="docs/tour/npc_anim_editor.jpg" width="260" alt="NPC animation editor"></a><br><b>NPC animation editor</b><br><sub>⚙ → NPC → Animation editor…</sub></td>
</tr>
</table>

**Labs** — Design studios and multiplayer.

<table>
<tr>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#linkage_lab"><img src="docs/tour/linkage_lab.jpg" width="260" alt="Linkage Lab"></a><br><b>Linkage Lab</b><br><sub>N</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#packing_lab"><img src="docs/tour/packing_lab.jpg" width="260" alt="Packing Lab"></a><br><b>Packing Lab</b><br><sub>Q</sub></td>
<td align="center" valign="top" width="280"><a href="docs/FEATURES.md#multiplayer"><img src="docs/tour/multiplayer.jpg" width="260" alt="Play together"></a><br><b>Play together</b><br><sub>Multiplayer</sub></td>
</tr>
</table>

<!-- TOUR:END -->

## Saving, worlds and sharing

- A **world** is a map plus everything you built and simulated on it. It saves as you go, and also checkpoints every 3 minutes and when you exit. Use the timeline's **💾** button to rename, copy, start a new world on the same map, or exit to the launch hub.
- **Share…** (in the launch hub, on each world row, and in the 💾 panel) exports a `.simpack.zip` file. It can hold worlds, cached map data, libraries and, optionally, art and settings. Installing one never overwrites the recipient's own files.

## Building an export

`python tools/release/build_release.py` builds the Windows, macOS and Linux
zips and the optional art add-on into `release/<version>/`. Run
`python tools/release/install_export_templates.py` once first. Details,
including macOS signing and how the art add-on is found, are in
**[docs/RELEASES.md](docs/RELEASES.md)**. **Project → Export** in the editor
uses the same presets and writes into `build/`.

## For developers

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** covers the module layers and where a new file goes. It also lists the extension points and the live architectural-debt backlog. Read it before adding a feature.
- **[CLAUDE.md](CLAUDE.md)** is the project memory: the feature map, every subsystem's invariants and the full validation suite. It is authoritative when it disagrees with anything else.
- **Selftests** are offline and headless. Each one is a single command, for example:
  ```bash
  godot --headless --path . --script scenes/ui/ui_compile_selftest.gd
  ```
  `CLAUDE.md` lists them all. After adding a `class_name` script, run `godot --headless --path . --import` once.
- **Windowed captures** go through `tools\harness.ps1`, which runs the game in a sandboxed copy of your user data. One example: `tools\harness.ps1 -World mtvernon -Capture look`.
- **Feature tour:** `tools\tour.ps1 -Mode stills` regenerates the screenshots, and `python tools/tour_docs.py` rebuilds `docs/FEATURES.md` and the gallery above.
- **Moving files:** move the `.uid` or `.import` sidecar with each file and rewrite its `res://` references. Then run `python tools/checks/res_path_audit.py`, which lists every reference whose target is missing.
- **Plans and working notes** belong in `plans/`, which is gitignored. Shipping documentation goes in `docs/`.

## Repository layout

| Path | What's there |
|---|---|
| `scenes/maps/` | Map scenes: `generated_location.tscn` (every user world) and `main.gd`, the root script of every map |
| `scenes/ui/` | HUD, panels and modals, incl. the launch hub / `location_picker/`, `projection/`, `toolbar/`, `kit/` |
| `scenes/gameplay/`, `gameplay/` | Player, vehicles, interactables, tutorials and challenges, placed props and lights |
| `system_graph/` | The systems graph: model, canvas (`canvas_v2/`), inspector, flow engine, electrical rules |
| `core/` | Services and subsystems: terrain, weather, water, population, worlds, sharing, astronomy, packing, linkage, … |
| `power_system/` | Energy sources (solar, wind, hydro, CSP), devices, Home Assistant client, automation |
| `vegetation/` | Tree and plant builders, species catalog, growth model, scatter |
| `crisis_events/` | Fire and other crisis events |
| `assets/` | Small shipped art: fonts, icons, sky maps, materials, photocards |
| `addons/` | Godot plugins and GDExtensions (camera server, ffmpeg, SpaceMouse, import fix) |
| `tools/` | Harness, tour, benches, one-off checks and fixes, asset pipelines (Python / PowerShell / GDScript) |
| `maps/` | `MapDefinition` and the example definitions for the bespoke maps |
| `docs/` | Documentation, the feature tour, config templates |
| `credits/`, `CREDITS.md` | Third-party attribution ledger (human + machine-readable) |
| `scad_library/`, `parked/` | OpenSCAD part library; built-but-unwired code |

## Credits and license

SIMbiogenesis stands on open tools and open data: Godot, OpenStreetMap, Open-Meteo, Copernicus DEM, Esri imagery, Stellarium, NASA POWER, and many CC0 and open-licensed assets. Every third-party dependency and asset, with its license, is listed in **[CREDITS.md](CREDITS.md)**.

The project's own code is released under the **[MIT License](LICENSE)**. Third-party assets keep their own licenses, as recorded in the credits.
