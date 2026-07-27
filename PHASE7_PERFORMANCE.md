# Phase 7 — Profiler-led performance and stability

**Status:** first code pass + maintainer guide. Treat hotspot changes as **measure → change → re-measure** in your build.

---

## Editor workflow (Godot 4.6)

1. **Debugger → Profiler** — run a capture on each map for ~30–60s at **1×** time, then ~30s at **fast-forward** (e.g. 60×–Max). Note scripts with high **Time** or **Calls** relative to others.
2. **Debugger → Monitors** — watch **FPS**, **Process**, **Physics Process**, **Object Counts** while switching **Map select → Mars → menu → Soak** repeatedly; object count should plateau, not climb without bound.
3. **VS Profiler** (optional export) — platform-specific; use if a native binary misbehaves only outside the editor.

---

## Already-favorable patterns (no change needed for Phase 7)

- **`system_graph_view.gd`** — `_process` returns when `not visible`.
- **`solar_ui.gd`** — sim steps at **10 Hz**, UI/graph at **4 Hz**; per-frame work is mainly lighting lerp + overload guard.
- **`scenes/ui/timeline_ui.gd`** — display refresh throttled (`UPDATE_INTERVAL`).
- **`device_registry.gd`** — safety scan every **8 s** and only when signal-idle.
- **Scene-shell stability** — `SimMode` / `AutomationEngine` clear stale `Main` / `SolarUI` refs off-map; see Phase 5–6 notes.

---

## Changes in this pass (low risk)

| Area | Change |
|------|--------|
| **`core/sim_mode.gd`** | Poll `_compute_mode()` at **~20 Hz** (`_MODE_POLL_SEC = 0.05`) instead of every frame. `set_historical_active()` forces an immediate recompute so history mode toggles stay snappy. |
| **`scenes/ui/health_ui.gd`** | Poll `GameplayRules.should_show_survival_ui()` every **0.2 s**; fog / pulse / indicators still run every frame when the HUD is shown. |
| **`crisis_event_manager.gd`** | Poll `GameplayRules.is_crisis_events_enabled()` every **0.25 s**. When crises are **off** (typical), avoids an autoload resolve every frame; full per-frame logic unchanged when enabled. |

---

## Soak / regression matrix

| Test | Pass criterion |
|------|----------------|
| HA live ↔ sim | `SimMode.is_live()` still matches UI within ~one poll interval after toggling live mode or time speed. |
| History playback | Enter/exit historical mode; mode signal still updates immediately on exit (forced poll). |
| Survival HUD | Toggle scenario / rules that hide survival UI; bars hide/show within ~200 ms. |
| Toggle crisis rules mid-session | Within ~250 ms, manager resumes or stops full processing. |

---

## Graph high-speed pass (follow-up)

See graph performance work: `GraphSimLoadHost` bulk sync, canvas high-speed LOD,
`ResourceTimeline` strided fill, RFE ambient cache + 0.5 s poll at ≥450×,
SolarBridge/PBI change-gates, recipe catalog index, SolarUI lighting at UI Hz
when `time_scale ≥ 0.125`.

## Candidates for a future pass (measure only)

- **`ha_websocket_client.gd`** / **`uisp_api_client.gd`** — network pacing; avoid extra polls without network traces.

---

## Completion / follow-up code

- **`core/sim_mode.gd`**, **`scenes/ui/health_ui.gd`**, **`crisis_event_manager.gd`** — see table above.
- Docs: README roadmap, **`PHASE1_INVENTORY.md`**.
