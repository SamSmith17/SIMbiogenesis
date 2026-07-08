# Systems Graph Vision — 2D Schematic Map of the Digital Twin

*Authoritative design context for the graph overhaul. Last updated: July 2026.*

---

## Role in the Product

The **2D graph view** (G toggle, `system_graph/`) is not a secondary HUD panel — it is the **core gameplay surface** of SIMbiogenesis. The 3D first-person world is the **embodied digital twin**: walk the site, place real infrastructure, wire sensors. The 2D graph is the **conceptual systems map**: every connection, storage, process, and resource flux within the player's stewardship area, animated over time.

Together they form a closed design loop:

```
Location (origin) → Sphere of Influence (conceptual boundary)
    → 3D world (terrain, weather, placed nodes, HA sensors)
    ↔ 2D graph (schematic, flows, automations, efficiency)
    → Real-world build (buy catalog modules, install, link HA)
    → Live data calibrates simulation → simulation improves real system
```

The game succeeds when a player can **design a self-sustaining pathway in simulation**, **build it in reality**, and **converge sim and live performance** until their sphere genuinely closes its material and energy loops.

---

## North-Star Concept: Sphere of Influence

### Definition

A **Sphere of Influence (SoI)** is a user-defined conceptual volume centered on a **location origin** (lat/lon from the map picker) with a **user-defined radius**.

It is **not** a physical enclosure. It is an **open-system terrarium / biosphere** — sunlight, rain, air, and groundwater cross the boundary freely. What the SoI defines is **stewardship and accounting**: everything inside the volume is tracked, simulated, and the player's responsibility.

### Vertical extent (conceptual)

| Zone | What is tracked |
|------|-----------------|
| Atmosphere above | Solar flux, wind, humidity, cloud moisture, precipitation |
| Habitable surface | Buildings, panels, tanks, processors, vegetation, soil |
| Subsurface below | Topsoil, root zone, subsoil, bedrock, aquifers |

The center plane is the razor-thin habitable shell of Earth; the SoI extends above and below it for complete mass/energy bookkeeping.

### Expansion model

- Start at 100% open — resources flow in and out without penalty.
- As the player expands radius (or achieves closure metrics), spheres may **overlap** with other players' spheres — cooperative self-sufficiency at regional scale is the long-term multiplayer/community vision.
- On Earth, **100% ISRU is not required on day one**; partial closure is valid. On Moon/Mars, 100% ISRU is mandatory — Earth is the training ground.

---

## Planetary Basic Income (PBI)

Every location on Earth receives a continuous, unstoppable flux of energy and matter — **Planetary Basic Income**. All primary inputs are solar energy directly or indirectly:

| Primary input | Mechanism | Graph representation |
|---------------|-----------|----------------------|
| **Sun** | Direct irradiance → PV, thermal, photosynthesis | Catchment / source nodes, GHI-driven rates |
| **Wind** | Solar-driven atmospheric motion | Wind turbine sources, WeatherService wind |
| **Rain** | Solar-driven water cycle → precipitation on SoI surface | Catchment nodes (mm → m³ on footprint) |
| **Biomass** | Solar-driven photosynthesis in vegetation within SoI | OSM/NDVI-scaled synthesis rates → biomass resource |

PBI is **free, forever, and location-specific**. The game teaches that scarcity of water, energy, or material on Earth is rarely absolute — the challenge is **efficiency, integration, and operator skill**.

---

## ISRU — In Situ Resource Utilization

Space-agency term adapted for Earth: **utilize, store, transform, and recycle** energy and material flows within the immediate environment **without depending on outside supply**.

### Human-needs closure targets

From PBI inputs, the graph must eventually route flows to satisfy:

- Food · Oxygen · Water · Infrastructure · Fuel · Energy · Waste recycling

Each need maps to **processor nodes** (filters, pumps, shredders, biochar reactors, digesters, greenhouses, etc.) with **known real-world efficiency metrics**.

### Efficiency is the game mechanic

Challenges are expressed as **performance ratios**, not binary unlocks:

| System type | Example efficiency question |
|-------------|----------------------------|
| Water recovery | kWh per liter recovered (rain → tank → filter → tap) |
| Plastic recycling | kg plastic recycled per kWh sunshine |
| Biomass → fuel | kWh stored per kg dry biomass input |
| Waste → soil | kg compost per kg input waste |

Every library module represents a **real product or open-source technology** with documented:

- Capital cost · Operating power · Throughput · Input/output resource kinds · Failure modes · HA entity mapping template

Players optimize **pathways** — sequences of connections — not individual nodes in isolation.

---

## 2D Graph — Interaction Model

### UX reference targets

The canvas should feel like professional node-based tools:

- **Grasshopper** — parametric wiring, typed ports, live parameter feedback
- **TouchDesigner** — nested networks, zoom-into-container, breadcrumb navigation

### Nested canvases (TouchDesigner model)

Complex modules decompose into sub-graphs. **Compound nodes** already exist (`type: compound`, scope stack in `system_graph_view.gd`); the overhaul completes this model:

- Double-click or **Enter** on a compound → navigate into its **child scope canvas**
- Breadcrumb trail shows scope hierarchy (`Root › Water Plant › RO Stage`)
- Parent compound exposes **promoted ports** (external interface) wired to internal boundary nodes
- Save/load preserves full scope tree in graph autosave JSON

### Build vs Test modes (existing, extend)

| Mode | Purpose |
|------|---------|
| **Build** | Pause time, edit topology, inspect specs, link HA entities |
| **Test / Run** | Time advances, flows animate on wires, tanks integrate, divergence vs live data visible |

### Resource flow visualization

- Wires carry **typed resources** (`ResourceKinds`: water, electric, biomass, plastic_waste, …)
- Wire animation speed ∝ instantaneous flow rate
- Storage nodes show **level, inflow, outflow** scrubbed on the EnergyTimeline / ResourceTimeline axis
- Catchment nodes (rain, sun, wind, biomass) inject PBI at rates derived from **location + weather + SoI area**

---

## 3D ↔ 2D Linkage

| 3D world | 2D graph |
|----------|----------|
| GPS origin + radius | SoI boundary metadata on graph root scope |
| Placed prop (shiftpod, tank, panel) | Corresponding library node or imported subgraph |
| OSM solar array added to graph | Panel compound auto-created (partial today) |
| Conduit routing in world | Optional spatial hint; graph owns logical connection |
| HA sensor entity | Node/port `ha_entity_id` binding |
| Weather at location | Catchment rate multipliers |

Selecting a node in 2D should optionally **highlight** its 3D counterpart (and vice versa). The graph is the **authoritative connection diagram**; 3D is **georeferenced embodiment**.

---

## Simulation ↔ Reality Feedback Loop

This closes Pillar 5 (Digital Twin) with the graph as the integration surface:

1. **Design in graph** — pick real catalog modules, wire flows, set automations
2. **Export** — ESPHome YAML, HA automation YAML, Lovelace layout (existing direction)
3. **Build in world** — purchase/install modules, connect sensors to HA
4. **Link entities** — `HAEntityLinker` maps live readings to graph node ports
5. **Compare** — observed vs simulated resource timelines (extend NLE compare pattern from SolarUI)
6. **Calibrate** — auto-tune efficiency coefficients (`energy_wh_per_unit`, loss factors) to minimize RMSE
7. **Improve** — simulation suggests better pathways; player iterates real system

Success metric: **closure fraction** — what percentage of each human-need resource flow is sourced from within the SoI vs imported across the boundary.

---

## Library & Module Catalog Requirements

Every spawnable graph item should eventually carry:

```json
{
  "catalog_id": "aquatec_ro_pump_550",
  "manufacturer": "Aquatec",
  "product_url": "...",
  "capital_cost_usd": 89,
  "ports": [
    {"id": "water_in", "kind": "water", "direction": "in"},
    {"id": "water_out", "kind": "water", "direction": "out"},
    {"id": "power", "kind": "electric", "direction": "in"}
  ],
  "performance": {
    "energy_wh_per_liter": 0.8,
    "max_flow_lph": 550
  },
  "ha_template": {"power": "sensor.aquatec_power", "flow": "sensor.aquatec_flow"}
}
```

Presets today live in `component_presets.gd` (mostly electrical). The overhaul **extends** this file or splits into category resources (water, waste, biomass, …) without breaking existing saves.

---

## Relationship to Existing Code

| Existing | Vision alignment | Gap |
|----------|------------------|-----|
| `system_graph_view.gd` + V2 canvas | Shell, library, inspector, Build/Test | SoI metadata, flow UX polish |
| `GraphModel` + scope/compound | Nested canvases | Promoted ports, full TD navigation |
| `ResourceFlowEngine` + `ResourceTimeline` | Multi-resource sim, scrub-safe tanks | Catchment/PBI injectors, closure metrics |
| `ResourceKinds` | Typed water/biomass/plastic/… | Air moisture, O₂, soil, fuel kinds |
| `component_presets.gd` | Real product names (partial) | Full ISRU catalog with efficiency specs |
| `solar_bridge.gd` | Live PV mirror | Generalize to all HA-linked processors |
| `ha_entity_linker.gd` | Entity binding | Per-port binding, calibration loop |
| `AutomationEngine` | Rule export | Graph-native automation authoring |
| Observed vs sim compare (SolarUI/NLE) | Calibration pattern | Extend to all resource channels |
| 3D terrain + weather | PBI data source | SoI area → catchment math |

---

## Non-Goals (for this overhaul phase)

- Multiplayer sphere overlap (design for it; implement later)
- Full chemistry/process simulation (use catalog efficiency curves first)
- Replacing HA bridge with HACS migration (ROADMAP Pillar 5 decision stands)
- Removing 3D exploration — it remains essential for spatial grounding

---

## Success Criteria

A player at any real-world location can:

1. Define an SoI radius around their origin
2. See PBI catchments populate the graph from live weather
3. Wire real catalog modules into a coherent water/energy/waste pathway
4. Run scenarios (drought week, cloudy month, freeze event) and read closure metrics
5. Export HA config, install hardware, link sensors
6. View live vs sim divergence on the same timeline scrubber
7. Iterate until simulated and observed flows converge

*See ROADMAP.md Pillar 9 and Phase 8 for phased delivery.*
