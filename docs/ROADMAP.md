# SIMbiogenesis — Product Roadmap
*Built with Fable 5 · Open Source Stack · Community-Driven · Digital Twin Ready*

**Detailed 2D graph / ISRU vision:** [`SYSTEMS_GRAPH_VISION.md`](SYSTEMS_GRAPH_VISION.md)

---

## What This Game Actually Is

An **in situ resource utilization (ISRU) simulator** disguised as a first-person exploration game. The player picks a real location on Earth — an **origin point** — and defines a **Sphere of Influence**: a conceptual open-system volume (surface, atmosphere, subsurface) for which they accept stewardship. Within that sphere, the game tracks the flux of **sun, wind, rain, and biomass** — Earth's **Planetary Basic Income**, the unstoppable solar-driven energy and material flows that sustain all life for free.

The **2D systems graph** (G toggle) is the **core gameplay surface**: a schematic, node-based map of every connection, storage, process, and resource flow within the sphere — like Grasshopper or TouchDesigner for real infrastructure. The **3D world** is the **embodied digital twin**: walk the site, place modules, see weather and terrain. Together they let players design closed-loop pathways (water recovery, waste recycling, energy storage, food production), simulate efficiency in their exact location, **export configs to Home Assistant**, link live sensor data, and **calibrate simulation against reality** until simulated and real performance converge.

The problem the game teaches is not scarcity — Earth has enough sunlight, water, and material for everyone — but **integration efficiency**: kWh per liter of recovered water, kg of plastic recycled per kWh, reliability of off-the-shelf open-source hardware. Every graph module represents a **real product or technology** with known costs and performance. Players start partially open (Earth never requires 100% closure on day one) and work toward self-sustaining spheres that can overlap with others — training for the 100% ISRU required on Moon and Mars.

Think: *Factorio* meets *Google Earth* meets *PVsyst* meets *TouchDesigner* — open source, community-owned, Home Assistant-native, ISRU-first.

---

## Stack Decisions — All Open Source

| Layer | Tool | License | Notes |
|---|---|---|---|
| Game engine | Godot 4.x | MIT | First-class GDScript + shader support |
| Geocoding | Nominatim (OSM) | ODbL | No key, no rate limit for reasonable use |
| Elevation | OpenTopography SRTM REST | CC BY 4.0 | 30m resolution, global, no key |
| Weather historical + forecast | Open-Meteo | CC BY 4.0 | No key, hourly, 80yr archive, global |
| Solar resource baseline | NASA POWER API | Public domain | No key, monthly/daily global irradiance |
| Climate projections | Copernicus CDS (CMIP6) | Varies / free | 2050/2075 scenarios, free registration |
| Satellite imagery | Copernicus Sentinel-2 | Free / open | 10m resolution, NDVI vegetation mapping |
| Building footprints | Overpass API (OSM) | ODbL | Free global building footprints + heights |
| Sun position algorithm | NREL SPA | Public domain | Port to GDScript, sub-0.01° accuracy |
| Community protocol | Nostr | Public domain | Decentralized, no server dependency |
| HA bridge | Custom HACS integration | Apache 2.0 | Python, installable by any HA user |
| Serialization | JSON + TOML | — | Installations as portable text files |
| Physics | Implemented from literature | — | No lib dependency, formulas in comments |

**No proprietary APIs. No vendor lock-in. No ongoing per-user API cost for core features.**

---

## Core Pillars

> **Status legend.** ✅ shipped · ⚠️ partial · 🔀 diverged (goal met a different way)
> · ❌ not started or dead. Marked **2026-08-01** against `CLAUDE.md` and
> `FEATURE_CHEAT_SHEET.md`, which are the living record — this file is the
> *vision*, and where they disagree they win. The Pillar/Phase prose below was
> written as a forward-looking spec and is deliberately left in the future tense;
> read the Status line, not the tense.


---

### Pillar 1: Location → Playable World in Under 10 Seconds

> **Status: ✅ SHIPPED** — DEM + OSM + imagery pipeline, launch hub, `generated_location.tscn`, terrain sculpting, vegetation.

The first experience: user enters an address or drops a pin, and within 10 seconds they are standing in a 3D reconstruction of that real place, ready to start designing.

**Pipeline (all parallel fetches after geocoding):**

```
Address / coordinates
    ↓ Nominatim geocoding (< 100ms)
    ↓ lat/lon established
    ├── OpenTopography SRTM → elevation grid (2km × 2km, ~500ms)
    ├── Open-Meteo Archive API → 1 year historical hourly weather (~800ms)
    ├── Open-Meteo Forecast API → 7-day forecast (~300ms)
    ├── Overpass API → building footprints + tagged heights (~400ms)
    ├── NASA POWER → annual solar resource summary (~400ms)
    └── Sentinel-2 NDVI tile (optional, ~2s, can load async after world appears)
    ↓ All data received (~1.5s total with parallelism)
    ├── Terrain mesh generation from elevation (GPU, ~150ms)
    ├── Building extrusion from OSM footprints (~100ms)
    ├── Vegetation scatter from NDVI density map (~100ms)
    └── WorldEnvironment sun angle from NREL SPA (~instant)
World ready: ~3–5 seconds
```

**Vegetation without satellite data (fallback):**
Use the NASA POWER climate classification (Koppen-Geiger) for the location to select a biome preset: Pacific Northwest = dense conifer + fern understory, Southwest desert = sparse scrub + rock, Great Plains = grassland + scattered deciduous. Scatter procedural vegetation from the biome preset at densities encoded in the preset. Looks inhabited and contextually correct without any satellite fetch. Upgrade to NDVI-driven density when the Sentinel-2 tile loads.

**NREL SPA in GDScript:**
The Solar Position Algorithm is a set of polynomial corrections to ecliptic longitude. The GDScript port is ~300 lines, takes lat/lon/datetime, returns azimuth and elevation to sub-0.01° accuracy. This drives: sun position in WorldEnvironment, shadow casting direction, panel irradiance angle of incidence. No external call — runs locally, every frame if needed.

**Fable session:** `"Implement the full location-to-world pipeline as described in the architecture docs. Parallel HTTPRequest nodes for all data fetches. NREL SPA ported to GDScript from the published algorithm (cite NREL/TP-560-34302 in comments). Terrain from elevation grid as a 256×256 subdivided PlaneMesh with vertex displacement. Biome-preset vegetation scatter as fallback before NDVI loads. Target: world visible within 5 seconds of coordinate input."`

---

### Pillar 2: Physics Engine — Real Numbers, Real Behavior

> **Status: ✅ SHIPPED** — Solar (Meeus SPA + NOCT + Erbs), wind, hydro, CSP trough, reversible battery. `source_physics_selftest.gd` = 301 checks.

Every formula cited in code comments. No faked curves. Scientists and engineers in the audience will check the math.

#### Solar
- **Irradiance model:** Perez all-sky (beam + diffuse + ground-reflected), fed by Open-Meteo's `shortwave_radiation` and `diffuse_radiation` components
- **Panel model:** Single-diode 5-parameter (I_sc, V_oc, I_mp, V_mp, temperature coefficients). Performance degrades at rate `P(T) = P_stc × [1 + γ(T_cell - 25)]` where γ ≈ -0.004/°C for monocrystalline
- **Cell temperature:** NOCT model: `T_cell = T_amb + (NOCT - 20°C)/800 × G`
- **String mismatch:** Bypass diode model — one shaded cell in a string limits the string output to the shaded cell's current. Visualized as a per-panel color gradient.

#### Wind
- **Power curve:** `P = ½ × ρ × A × C_p(λ,β) × v³` where ρ = 1.225 kg/m³ at STP with altitude correction `ρ = ρ_0 × exp(-alt/8500)`
- **Betz limit:** C_p_max = 0.593, realistic turbines 0.35–0.45
- **Wind shear:** Logarithmic profile `v(z) = v_ref × ln(z/z_0) / ln(z_ref/z_0)` with terrain roughness class z_0 selected by land use type
- **Cut-in/rated/cut-out:** Configurable per turbine spec

#### Hydro
- **Power:** `P = ρ_water × g × Q × h_net × η_turbine × η_generator`
- **Pipe losses:** Darcy-Weisbach: `h_f = f × (L/D) × (v²/2g)` with Moody chart friction factor
- **Turbine selection:** Pelton (head > 30m, η ≈ 0.85–0.90), Turgo (10–30m, η ≈ 0.80–0.85), crossflow (< 10m, η ≈ 0.75–0.82)
- **Seasonal flow:** Monthly multipliers sourced from Open-Meteo precipitation history

#### Battery
- **Equivalent circuit:** Thevenin model — V_terminal = V_oc(SoC) - I×R_0 - V_RC. V_oc is a lookup curve, not linear.
- **Aging:** Rainflow cycle counting against manufacturer's cycle-life curve. Capacity = C_rated × (1 - k × cumulative_cycles^0.5). After N cycles, the battery degrades visibly in the simulation.
- **Thermal:** Arrhenius temperature dependence on capacity: `C(T) = C_25 × exp(-E_a/R × (1/T - 1/298))`
- **LiFePO4 vs NMC vs lead-acid:** Distinct V_oc curves, R_0 values, cycle life curves, and temperature coefficients as selectable presets

#### Thermal
- **Lumped capacitance:** `m × c_p × dT/dt = Q_in - Q_convection - Q_radiation`
- **Inverter throttle:** Throttle curve from manufacturer data (typically linear derating above 40°C ambient)
- **Wire heating:** `P_heat = I² × R(T)` where `R(T) = R_20 × [1 + α(T - 20)]`, α_copper = 0.00393/°C
- **False-color heatmap:** Fragment shader on each component mesh — maps temperature to ROYGBIV palette, updated each physics tick

#### Financial
- **LCOE:** `(TCC + Σ(O&M_t / (1+r)^t)) / Σ(E_t / (1+r)^t)` over 25-year project life
- **Degradation:** Panel 0.5%/yr, battery capacity per aging model, inverter replacement at year 12–15
- **NPV/IRR:** Full discounted cash flow with configurable real discount rate and utility rate escalation
- **Avoided CO₂:** Annual generation × regional grid carbon intensity (EPA eGRID data by state, hardcoded lookup)

**Fable session strategy:** Split into three sessions — solar + wind + hydro in one, battery + thermal in a second, financial model in a third. Each session receives the existing EnergySource base class and must implement it fully.

---

### Pillar 3: First-Person Gameplay Layer

> **Status: ✅ SHIPPED** — First-person + vehicles + crisis events. "Tutorial as missions" landed as **Solar Bootcamp** (12 levels) + pre-baked challenges.

The simulation must feel like a game, not a dashboard. The depth is invisible until the player wants it.

**Core game loop:**
1. Load a location → stand in it
2. Survey the site (sun path visible in sky, wind direction particles, water flow animation)
3. Place components (snap to terrain, rotate, configure in Inspector-like panel)
4. Run time forward — watch the system respond to weather
5. See real-time graphs, heatmaps, financial readouts update
6. Compare against historical events or community designs
7. Export or publish

**Placement system:**
- Raycast from camera determines placement surface
- Ghost mesh shows component before placement with green/orange/red tint for good/marginal/bad placement (based on shade analysis, slope, proximity to obstructions)
- Components have `ConnectionPort` marker nodes — cable endpoint snapping
- Inspector panel slides in from right when component is selected, showing all configurable parameters and live telemetry

**Time controls (HUD bottom bar):**
- Slider from 1× real-time to 8760× (one simulated year per real second)
- Date/time display — shows what real historical date the simulation is currently replaying
- "Jump to event" button — shortlist of notable historical weather events for the location
- Fast-forward past low-interest periods (night, no-wind) with smart skip

**Tutorial as missions:**
- Not a manual — guided missions that teach by doing
- Mission 1: "It's January in Portland. Your neighbor's power is out. Can you keep your lights on for 72 hours?" → player sizes a battery system under crisis pressure
- Mission 2: "Your summer bill is $180. Design a system that brings it to $20 or less by next June." → introduces economics
- Mission 3: "A week of cloud cover is coming. Optimize." → introduces weather forecasting integration
- Missions unlock concepts progressively. Knowledge graph tracks what the player has encountered.

**Accessibility:**
- Colorblind modes (all heatmaps use colorblind-safe palettes with a toggle)
- Scalable UI (all elements use Theme constants, no hardcoded pixel sizes)
- Optional data sonification — energy flow audible as tonal synthesis
- Subtitle mode for all in-game audio cues

---

### Pillar 4: Community Layer — Nostr-Native, Git-Spirited

> **Status: 🔀 DIVERGED** — Went LAN/join-code multiplayer + portable `.esim` packages instead of Nostr. The *goal* (share a site, remix someone's build) is met; the transport is not.

**Installation as a portable file:**
Every installation is a structured JSON document — call it an `.esim` file (energy simulation):
```json
{
  "schema_version": "1.0",
  "location": { "lat": 45.52, "lon": -122.68, "label": "Portland, OR" },
  "components": [ ... ],
  "wiring": [ ... ],
  "simulation_results": {
    "annual_kwh": 8420,
    "resilience_score": 0.94,
    "lcoe_per_kwh": 0.087,
    "co2_avoided_kg": 2890
  },
  "fork_of": "nostr:nevent1...",
  "author_pubkey": "npub1..."
}
```

**Nostr publishing (NIP-78 arbitrary app data):**
- Publishing an installation creates a Nostr event (kind 30078) with the `.esim` JSON as content
- Tags: `l` (location geohash), `t` (component types used), `performance` metrics
- Any Nostr relay stores it. No central server dependency.
- Discovery: query relays by geohash to find installations near a location, or by performance metrics
- The game ships with a curated list of default relays and lets users add their own

**Fork:**
- Pull any published installation by Nostr event ID
- Game loads it as your starting point, runs it against your location's weather
- Publish your modified version with an `e` tag referencing the original → lineage chain is preserved

**Compare:**
- Load two installations into split-screen comparison mode
- Run both through the same weather dataset (same location, same date range)
- Output: side-by-side metrics, graph overlay, diff view showing what changed

**Leaderboard (local computation, Nostr-aggregated):**
The game client queries a Nostr relay for published installations matching a filter (location, date range, component type) and ranks them locally. No central leaderboard server — the relay is just a message store. Rankings: annual kWh/$ invested, P90 resilience (Monte Carlo), LCOE, carbon avoided per m² site footprint.

**Fable session:** `"Design and implement the .esim file format (versioned JSON schema with migration support), Nostr event publishing/fetching using HTTPRequest (NIP-01 filter query to a relay's /req endpoint), fork/compare loading system, and local leaderboard computation. The installation must round-trip perfectly: save → publish → pull → load → identical simulation results."`

---

### Pillar 5: Digital Twin — Closed Loop with Home Assistant

> **Status: ⚠️ PARTIAL** — HA WebSocket client + entity linker + CSV replay + automation push all work. The **HACS-integration migration is still an open decision** — do not rebuild the bridge without an explicit call.

This is the feature that makes the game uniquely yours and your audience's.

**Architecture overview:**
```
Real World                          Simulation
─────────────────────────────────────────────────────
Sensors (PZEM, inverter, weather)
    ↓ ESPHome → MQTT
    ↓
Home Assistant
    ↓ Custom HACS Integration
    ↓ WebSocket stream
    ↓
Godot Game ←→ Real-time sync panel
    ↓
Deviation alert: "Real battery 12% below simulation"
Predictive alert: "Forecast shows battery hits 20% by 11pm"
    ↓
Dispatch schedule → HA input helpers → Automation trigger
    ↓
Real inverter adjusts behavior
```

**HA → Game (inbound telemetry):**
The HACS integration exposes a WebSocket endpoint on HA. The game subscribes and receives:
- All `sensor` entities matching energy patterns: `*_power`, `*_energy`, `*_voltage`, `*_soc`, `*_temperature`
- Weather station data if a local station is integrated
- Grid import/export from the HA Energy Dashboard
- Entity state changes streamed in real-time

The game uses this stream to:
1. Seed the simulation's initial state from real values
2. Drive a "real vs. simulated" overlay panel — two lines on every graph
3. Trigger divergence alerts when real and simulated SoC drift beyond a configurable threshold
4. Override weather inputs with real local weather station data when available

**Game → HA (outbound configuration):**

*ESPHome YAML export:*
Game state → deterministic YAML generation. For your SRNE inverter setup:
```yaml
# Generated by Energy Simulator v1.0
# Installation: Portland Home System
# Generated: 2026-06-12

uart:
  id: modbus_uart
  tx_pin: GPIO17
  rx_pin: GPIO16
  baud_rate: 9600

modbus:
  id: modbus_bus
  uart_id: modbus_uart

sensor:
  - platform: modbus_controller
    name: "Battery Voltage"
    register_type: holding
    address: 0x0101
    unit_of_measurement: "V"
    value_type: U_WORD
    filters:
      - multiply: 0.1
  # ... all registers derived from game component configuration
```

*HA Automation export:*
Battery dispatch schedule → HA automation YAML. Time-of-use optimization computed in-game → exported as time-triggered automations that call inverter charge/discharge scripts.

*Lovelace dashboard export:*
Generate a complete HA dashboard config JSON matching the game's graph layout, so the player's real HA dashboard mirrors what they designed in-game.

**Closed-loop validation:**
After a real-world day, the game pulls the day's actual sensor data from HA and runs a post-hoc comparison: how well did the simulation predict actual performance? Reports RMSE on generation, consumption, and SoC. Over time this builds a calibration history — the game can auto-adjust its model parameters (e.g., actual panel efficiency vs. rated, actual battery capacity vs. nominal) to match real observed behavior.

**Predictive mode:**
Using tomorrow's Open-Meteo forecast + the calibrated model + current real SoC, the game predicts tomorrow's battery curve and flags: "Based on tonight's forecast, you will hit your minimum SoC (20%) at 2:14am. Consider pre-charging from grid before 11pm if ToU rates allow." Push this prediction to HA as a notification.

**Fable session:** `"Design and implement the full HA digital twin bridge. Three components: (1) A Python HACS integration (separate repo) that subscribes to HA WebSocket API and re-exposes energy sensor data on a simple WebSocket endpoint the game connects to. (2) GDScript WebSocket client that receives the stream and maps entity IDs to game component IDs via a configurable mapping file. (3) Export functions for ESPHome YAML, HA automation YAML, and Lovelace dashboard JSON, generated deterministically from game state. Include a real-vs-simulated divergence panel in the game's UI."`

---

### Pillar 6: Historical and Future Scenario Modes

> **Status: ⚠️ PARTIAL** — Open-Meteo archive + forecast + `ClimateProjectionService` + stochastic weather generator exist. The five curated historical events do not.

**Historical mode — what actually happened:**
Open-Meteo's archive API provides hourly data back to 1940 for most global locations. Variables available: `shortwave_radiation`, `windspeed_10m`, `winddirection_10m`, `precipitation`, `temperature_2m`, `cloud_cover`, `et0_fao_evapotranspiration`, and more.

Preloaded scenario events (curated, shipped with the game):
- *Pacific Northwest Heat Dome, June 27–30, 2021* — 4 days of 38–47°C. Panel derating and cooling loads spike.
- *Texas Winter Storm Uri, Feb 10–20, 2021* — 10 days, some areas below -18°C, wind turbines iced. Cold-weather battery capacity reduction is dramatic.
- *Puerto Rico after Hurricane Maria, Sept–Dec 2017* — 3 months of grid outage. What does your system sustain?
- *California rolling blackouts, Aug 14–19, 2020* — Extreme heat, grid export blocked, peak demand shaving challenge.
- *Portland Columbia Gorge wind event, Oct 1–3, 2024* — 130+ km/h gusts, wind turbine cut-out stress test.

Each scenario: fetches the real historical weather data for the event period at the user's location (same event period, their specific weather), frames it as a mission with a brief narrative, tracks performance against the scenario goal, posts the result to the Nostr leaderboard for that scenario.

**Future climate mode — CMIP6 projections:**
The Copernicus Climate Data Store provides CMIP6 ensemble projections as bias-corrected monthly statistics (free, requires registration). Variables: temperature anomaly, precipitation change, solar radiation change by month.

Implementation: download the CMIP6 delta for the player's location at 2050 (SSP2-4.5) and 2075 (SSP5-8.5). Apply deltas to the Open-Meteo historical baseline to generate a synthetic future-year weather file. Run the full year simulation. Output: how does your installation perform in 2050? In the worst-case 2075 projection?

Key effects that matter for energy simulation:
- Hotter summers → panel derating, more cooling loads, battery thermal stress
- Wetter/drier winters → hydro flow rate changes
- Changed wind patterns → turbine performance shift
- Earlier spring snowmelt → seasonal hydro timing change

These are real, quantified changes from published climate science — not invented difficulty modifiers.

---

### Pillar 7: NEC Compliance Checker

> **Status: ❌ NOT STARTED** — No implementation. Nothing in the graph checks conductor sizing, OCPD, or the 120% rule.

A rules engine encoded once by Fable, then running deterministically forever. Not gameplay — an optional "Design Review" mode that checks the installation against relevant NEC 2023 articles before export.

Key rules to implement (representative, not exhaustive):

| Rule | NEC Article | Check |
|---|---|---|
| Wire ampacity | 310 | Wire gauge ≥ 125% of circuit current for continuous loads |
| Overcurrent protection | 240, 690 | Breaker or fuse within 18" of battery terminal |
| PV string voltage | 690.7 | String Voc_STC × 1.25 < 600V (residential) or 1500V (commercial) |
| Rapid shutdown | 690.12 | If roof-mounted, rapid shutdown initiator required |
| GFPD | 690.5 | Ground fault protection on grounded systems |
| Battery disconnect | 706.15 | Manual disconnect accessible within 6ft of battery |
| Inverter AC disconnect | 690.15 | Utility-side disconnect within sight of inverter |
| Voltage drop | 647 | < 3% for branch circuits (informational, not mandatory, but flagged) |
| Conduit fill | 358, 362 | Wire count vs. conduit diameter |

Output: a punch list of violations with NEC article citations and suggested fixes. Not a lawyer, not a substitute for a real inspection — but it teaches real code compliance and catches obvious errors before export.

**Fable session:** `"Implement the NEC compliance checker as a separate CheckEngine autoload. It takes an InstallationSnapshot (generated from current game state) and returns an array of ComplianceResult objects, each with: severity (error/warning/info), affected_component_id, nec_article, violation_description, suggested_fix. Implement all rules in the table from the architecture docs. Rules are pure functions with no side effects — given the same installation, they always return the same results. Display results in a scrollable panel sorted by severity. Include a 'Learn more' link for each rule that opens an in-game explanation of why the rule exists."`

---

### Pillar 8: Satellite Terrain Auto-Population

> **Status: ❌ DEAD** — Deferred permanently — Godot has no JP2 decoder, so raw Sentinel-2 NDVI is off the table. Vegetation comes from OSM landcover instead.

**Without AI at runtime — pure GIS pipeline:**

Sentinel-2 provides 13 spectral bands at 10m resolution globally, freely via Copernicus. For vegetation:

```
NDVI = (Band_8 - Band_4) / (Band_8 + Band_4)
     = (NIR - Red) / (NIR + Red)

NDVI < 0.1  → bare soil / rock / water
NDVI 0.1–0.3 → sparse scrub / grassland
NDVI 0.3–0.6 → mixed vegetation / agriculture  
NDVI > 0.6  → dense forest / wetland
```

NDWI (water index) from bands 3 and 8 identifies water bodies. NDBI (built-up index) from bands 6 and 4 identifies developed areas.

These three indices + the SRTM terrain → complete site characterization without any vision model:
- Water body → place water plane mesh with ripple shader
- High NDVI + steep slope → place conifer clusters (PNW), palm clusters (tropical), etc. by biome
- High NDBI + flat → place building meshes from OSM footprints
- Low NDVI + flat → sparse vegetation, exposed soil texture

The Sentinel-2 tile for a 2km × 2km area is approximately 15MB compressed — cacheable locally after first fetch.

**Fable session:** `"Implement the satellite terrain autopop pipeline. Fetch Sentinel-2 L2A product for the current location bounding box via the Copernicus STAC API (no registration required for L2A products). Compute NDVI, NDWI, NDBI from the appropriate band files. Downsample to 256×256 to match terrain resolution. Use NDVI as the density map for vegetation scatter, NDWI to place water planes, NDBI to mask areas where OSM buildings should place instead of vegetation. Cache all raw band files by bounding box hash. Show a loading progress indicator while satellite data fetches in the background after the initial world loads."`

---

### Pillar 9: Sphere of Influence & Systems Graph *(core gameplay — see SYSTEMS_GRAPH_VISION.md)*

> **Status: ⚠️ PARTIAL** — the graph IS the core surface and is heavily built (nested super-nodes, SketchUp-style components, DC electrical faults, resource flow, PBI catchments, Site Plan / Elevation views, NPC population). The **full ISRU catalog and the PBI vision are not complete** — see the gap table in `SYSTEMS_GRAPH_VISION.md`.

The 2D graph is the game's **conceptual map** of the 3D digital twin. Everything else (terrain, first-person placement, HA bridge) exists to ground this schematic in reality.

#### Sphere of Influence (SoI)

- **Origin:** map location (lat/lon) from LocationPicker / user map `.tres`
- **Radius:** user-defined; defines conceptual stewardship volume (atmosphere + habitable surface + subsurface)
- **Open system:** not physically enclosed; tracks boundary-crossing flows for closure accounting
- **Expansion:** increase radius as closure improves; future overlap with other players' spheres

#### Planetary Basic Income — primary catchments

All catchment nodes derive rates from location + weather + SoI footprint area:

| Input | Source data | Satisfies |
|-------|-------------|-----------|
| Sun | GHI / Open-Meteo radiation | Electric, thermal, biomass (via photosynthesis) |
| Wind | Open-Meteo 10 m wind | Electric |
| Rain | Precipitation × SoI area | Water tanks, aquifer recharge |
| Biomass | OSM vegetation + NDVI + season | Food, biochar, fuel feedstock |

#### ISRU module library

Every library item = real product or open-source design with:

- Typed input/output ports (`ResourceKinds` + extensions)
- Efficiency metrics (`energy_wh_per_unit`, throughput, loss factors)
- Capital/operating cost · HA entity template · datasheet link

Categories beyond today's electrical focus: water recovery, waste sorting/shredding, biochar, digesters, greenhouses, atmospheric moisture, soil amendment.

#### Graph UX — TouchDesigner-style nested canvases

- **Compound nodes** expose a child scope canvas (partially implemented: scope stack, breadcrumbs, Enter/Back)
- Double-click compound → drill in; breadcrumb → navigate up
- **Promoted ports** on compound boundary = external API of a subsystem
- Wire animation ∝ flow rate; tank levels scrub on timeline (ResourceTimeline, like battery SOC)
- **Build** mode (paused) vs **Test** mode (time running) — extend with closure dashboards

#### 3D ↔ 2D linkage

- Placed 3D props ↔ graph nodes (prop_id / catalog_id)
- OSM solar arrays → panel compounds (working today)
- Conduit routes ↔ optional spatial overlay; graph owns logical topology
- Select in either view → highlight counterpart

#### Sim ↔ real calibration loop

1. Design pathway in graph → export HA/ESPHome (Pillar 5)
2. Build hardware → link sensors via `HAEntityLinker`
3. Compare observed vs simulated resource timelines (extend SolarUI NLE compare pattern)
4. Auto-calibrate efficiency coefficients → suggest graph improvements
5. Track **closure fraction** per human-need resource (% sourced inside SoI)

**Fable session:** `"Read SYSTEMS_GRAPH_VISION.md. Implement SoI metadata on graph root scope (radius, area, closure metrics panel). Add catchment source nodes for rain and biomass driven by WeatherService + SoI area. Extend ResourceFlowEngine to inject PBI at catchment nodes. Complete compound promoted-port wiring and TouchDesigner-style drill-in UX. Add three water-processor catalog entries with energy_wh_per_liter specs."`

---

## Roadmap Phases

### Phase 0 — Architecture Sprint ✅ **DONE**
- Scene tree, autoloads, signal bus, data bus
- Save/load system with versioned schema
- Basic first-person controller
- `CLAUDE.md` project memory file established

### Phase 1 — Location → World ✅ **DONE**
- Nominatim geocoding
- SRTM elevation + terrain mesh
- Open-Meteo integration (historical + forecast)
- Overpass building footprints + extrusion
- NREL SPA sun position (GDScript port)
- Biome-preset vegetation fallback
- NASA POWER solar baseline

**Milestone:** Enter any address, stand in a recognizable 3D place in under 10 seconds.

### Phase 2 — Physics Engine ✅ **DONE**
- Solar: Perez irradiance + single-diode panel model
- Wind: full power curve + wind shear
- Hydro: Pelton/run-of-river + pipe losses
- Battery: Thevenin model + aging
- Thermal: lumped capacitance + false-color heatmap shader
- Financial: LCOE + NPV/IRR + CO₂ accounting

**Milestone:** Place a solar + battery system and watch it respond accurately to real historical weather.

### Phase 3 — Data Layer ✅ **DONE**
- TimeController (game-time ↔ real timestamps)
- Historical weather playback (Open-Meteo archive)
- 3D↔2D graph linkage (DataBus + GraphPanel scenes)
- Historical scenario events (curated, hardcoded trigger dates)

**Milestone:** Replay the 2021 Pacific Northwest heat dome on your installation.

### Phase 4 — Game Layer ✅ **DONE**
- Component placement + wiring (catenary cable + flow shader)
- UI theme system (dark theme, consistent type, animations)
- Tutorial mission framework (5 launch missions)
- Time-lapse visualization
- Sound design (generative component audio)

**Milestone:** A non-technical player can sit down, complete Mission 1, and understand why batteries matter.

### Phase 5 — Community 🔀 **DIVERGED** (LAN/join-code + .esim, not Nostr)
- `.esim` installation file format (versioned JSON schema)
- Nostr publish/fetch/fork/compare
- Leaderboard (local computation, relay-aggregated)
- Performance metrics standardization

**Milestone:** Publish an installation to Nostr. Pull someone else's design and run it at your location.

### Phase 6 — Digital Twin ⚠️ **PARTIAL** (bridge works; HACS migration undecided)
- HACS HA integration (Python, separate repo)
- Game WebSocket client for real sensor data
- Real vs. simulated divergence panel
- ESPHome YAML export
- HA automation YAML export
- Predictive battery forecast with HA notification push
- Post-hoc calibration (real data vs. predicted, RMSE tracking)

**Milestone:** Real HA system feeds live data into the game. Game exports valid ESPHome config for an SRNE hybrid inverter.

### Phase 7 — Advanced ⏳ **ONGOING**
- Satellite imagery NDVI autopop (Copernicus Sentinel-2)
- Future climate scenarios (CMIP6 delta method)
- NEC compliance checker (rules engine)
- String mismatch visualization (per-panel color gradient)
- Monte Carlo resilience analyzer (P50/P90 from historical ensemble)
- Battery dispatch optimizer (dynamic programming on TOU schedule)
- Shared installation API alternative (self-hostable REST backend for orgs)

### Phase 8 — Systems Graph Overhaul ⚠️ **IN PROGRESS**

Priority order (each milestone independently shippable):

1. **SoI model** — radius UI, area math, metadata on graph root, closure fraction readout
2. **PBI catchments** — sun/wind/rain/biomass source nodes tied to WeatherService + SoI area
3. **Nested canvas completion** — promoted ports, TD-style drill-in/out, scope save round-trip
4. **ISRU catalog expansion** — water, waste, biomass processors with real efficiency specs
5. **Flow UX** — wire animation, tank level overlays, multi-resource timeline lanes on TimelineUI
6. **3D ↔ 2D binding** — placed prop ↔ graph node, cross-highlight, import from world
7. **Calibration loop** — observed vs sim per resource channel, auto-tune `energy_wh_per_unit`
8. **HA pathway export** — graph-native automation authoring → AutomationEngine YAML push

**Milestone:** Player designs a rain → tank → filter → tap pathway at their real address, runs a dry-week scenario, exports HA config, links one live flow sensor, and sees sim vs observed divergence on the timeline.

---

## Fable Session Strategy

**The CLAUDE.md file is the critical artifact.**
Before every session: Fable reads it and knows exactly what exists. After every session: Fable updates it. This file is the project's institutional memory.

CLAUDE.md must always contain:
- Full scene tree map with node types
- All autoloads and their public API (signals, methods)
- DataBus source ID naming convention
- Save data schema (version + all fields)
- External API endpoints + expected response shapes
- Physics constants and formula source citations
- Component registry (all EnergyComponent subclasses)
- Open work items from the last session

**Session template:**
1. Start in **Plan mode** — "Read CLAUDE.md and all files in the affected system. Map out exactly what you will change before touching anything."
2. Review plan. Ask questions if anything is unclear.
3. Switch to **Auto accept edits** to execute.
4. End of session: "Update CLAUDE.md to reflect everything you changed. Write a one-paragraph summary of what was built and what the next session should tackle."

**One system per session.** Never combine e.g. "implement wind physics and also build the community layer." Complexity compounds; keep scope tight.

**Test-first for physics.** Every physics implementation session should begin with: "Write unit tests for each formula before implementing anything. The tests should use published example values from the source literature as expected outputs."

---

## Key Technical Decisions

**Why Nostr instead of a central server?**
No infrastructure cost, no single point of failure, no vendor dependency, aligns with the open-source / HA community's values, and Nostr clients already exist for the desktop — players can interact with the community outside the game. The tradeoff (no guaranteed message persistence) is acceptable for an installation registry where data is non-critical.

**Why JSON for `.esim` instead of a binary format?**
Human-readable, git-diffable, Nostr-embeddable, forward-compatible with schema migration. Performance is not a concern for a single installation file.

**Why GDScript physics implementation instead of a sidecar (Python + pvlib)?**
A GDScript physics engine runs everywhere Godot runs (Windows, Mac, Linux, Web, mobile) with no external runtime dependency. A Python sidecar requires Python installed and a local server process — too fragile for a game. The tradeoff is that GDScript formulas need to be verified against pvlib values during development. Fable handles this validation.

**Why not WebGPU compute shaders for Monte Carlo?**
Godot 4's RenderingServer supports compute shaders on desktop, but the cross-platform support story is incomplete for WebGL deployments. Implement Monte Carlo in GDScript first with a 100-scenario sample (fast enough for interactive use), then optionally port the inner loop to a compute shader as a performance optimization in Phase 7.

**Why HACS integration instead of a Godot plugin directly calling HA's API?**
The HACS integration is always-running, handles HA's authentication and SSL, and can push data to the game rather than requiring the game to poll. More importantly, it makes the bridge installable by any HA user in three clicks — which is the right distribution model for this audience.

---

*Last updated: July 2026. Update this document after each Fable session.*
