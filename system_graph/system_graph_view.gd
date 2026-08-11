extends Control
## Solar Circuit Designer — Godot port of the LinkageLab webapp.
## Phases: 1=layout shell, 4=node renderer, 7=library, 11=solar bridge.
## Toggle: input action `system_graph_toggle` (default G).

## Fired when an electrical fault trips (short circuit, battery/controller
## over-voltage). `reason` is a GraphNodeState.REASON_* code. The tutorial
## director listens; nothing else needs to.
signal electrical_fault_observed(reason: String, item_id: String)

## Fired when an external graph load (game load, .esim import) lands while the
## tutorial sandbox is active — the incoming state wins, the sandbox is dropped
## WITHOUT restore, and the tutorial director must reset its UI.
signal sandbox_interrupted

# ---------------------------------------------------------------------------
# Mission-control color palette — redirected to UITheme (single source of
# truth); local const names kept so existing call sites are unchanged.
# ---------------------------------------------------------------------------
const C_BG       := UITheme.C_BG
const C_SIDEBAR  := UITheme.C_PANEL
const C_PANEL    := UITheme.C_PANEL_RAISED
const C_BORDER   := UITheme.C_BORDER
const C_PRIMARY  := UITheme.C_PRIMARY
const C_AMBER    := UITheme.C_AMBER
const C_GREEN    := UITheme.C_GREEN
const C_TEXT     := UITheme.C_TEXT
const C_TEXT_S   := UITheme.C_TEXT_S
const C_TEXT_M   := UITheme.C_TEXT_M

const TOPBAR_H    := 60.0
## Left dashboard + telemetry column width.
const SIDEBAR_L_W := 340.0
const SIDEBAR_R_W := 340.0
## Siphon Lab params dock — Elevation CT remains the shared viewport.
const SIPHON_LAB_W := 380.0
## Cap for the Hydro Lab's fallback auto-bind (a turbine placed before any nearby
## pond existed). Generous enough for a normal site, small enough that opening the
## Lab never latches onto a pond across a large map.
const LAB_AUTOBIND_MAX_M := 300.0
const TOGGLE_W    := 20.0   # width of the sidebar collapse tabs

const _CANVAS_SCRIPT    := preload("res://system_graph_v2/graph_canvas_v2.gd")
const _LIB_PANEL_SCRIPT := preload("res://system_graph/library_panel.gd")
const _INSP_PANEL_SCRIPT := preload("res://system_graph/inspector_panel.gd")
const _SIPHON_LAB_SCRIPT := preload("res://scenes/ui/siphon_hydro_modal.gd")
const _BRIDGE_SCRIPT         := preload("res://system_graph/solar_bridge.gd")
const _HISTORY_PLAYER_SCRIPT := preload("res://system_graph/history_player.gd")
const _HISTORY_SCRIPT   := preload("res://system_graph/history_manager.gd")
const _LINKER_SCRIPT    := preload("res://system_graph/ha_entity_linker.gd")
const _SIM_LOAD_HOST_SCRIPT := preload("res://system_graph/graph_sim_load_host.gd")
const _RESOURCE_FLOW_SCRIPT := preload("res://system_graph/resource_flow_engine.gd")
const _CLOSURE_METRICS_SCRIPT := preload("res://system_graph/closure_metrics.gd")
const _HIGH_SCORE_STORE_SCRIPT := preload("res://core/high_score_store.gd")
const _CONDUIT_MGR_SCRIPT := preload("res://core/conduits/conduit_manager.gd")
const _PLACEHOLDER_HOST_SCRIPT := preload("res://system_graph/graph_placeholder_host.gd")
const _UI_SFX := preload("res://core/ui_sfx.gd")
## Global `class_name` is not always resolved here during parse; preload gives a stable entry point.
const _GAMEPLAY_RULES_SCRIPT := preload("res://gameplay/gameplay_rules.gd")
const _PV_ELECTRICAL_SCRIPT := preload("res://system_graph/pv_electrical.gd")
const _GRAPH_LAYOUT_SCRIPT := preload("res://system_graph/graph_layout.gd")
const _GRAPH_PV_WIRING_SCRIPT := preload("res://system_graph/graph_pv_wiring.gd")
const _GRAPH_EMBODIMENT_SCRIPT := preload("res://system_graph/graph_embodiment.gd")
const _PLACED_PROP_RUNTIME_SCRIPT := preload("res://core/placed_models/placed_prop_runtime.gd")
const _DASHBOARD_SCRIPT := preload("res://system_graph/graph_dashboard_panel.gd")
const _PREVIEW_SERVICE_SCRIPT := preload("res://system_graph/graph_model_preview_service.gd")
const _DC_POWER_WIRING_SCRIPT := preload("res://system_graph/dc_power_wiring.gd")
const _ESIM_PACKAGE_SCRIPT := preload("res://core/esim/esim_package.gd")
const _ESIM_IMPORTER_SCRIPT := preload("res://core/esim/esim_importer.gd")
const _MudBuildingStructureBuilder := preload(
	"res://core/machines/mud_building/mud_building_structure_builder.gd")
const _GeodesicDomeBuilder := preload("res://core/machines/geodesic_dome_builder.gd")
const _DomeParts := preload("res://core/machines/dome_parts.gd")
const _CncCutPresets := preload("res://core/machines/cnc_cut_presets.gd")
const _UI_PREFS_CFG := "user://ui_prefs.cfg"
const GRAPH_AUTOSAVE_DIR := "user://saves/graph_autosave"
## Named graph snapshots the player can copy between maps.
const GRAPH_LIBRARY_DIR := "user://saves/graphs"
const GRAPH_AUTOSAVE_DEBOUNCE_SEC := 0.75
const GRAPH_AUTOSAVE_REASONS := {
	"add_item": true,
	"remove_item": true,
	"update_item": true,
	"add_connection": true,
	"remove_connection": true,
	"update_connection": true,
	"reset": true,
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var _sidebar_l_open := true
var _sidebar_r_open := true
var _mode := "build"   # "build" | "test"

var _solar_ui: Control = null
var _graph_dashboard: GraphDashboardPanel = null
var _view_menu: MenuButton = null
const VIEW_LEGEND := 100
const VIEW_HISTORY := 101
const VIEW_HINTS := 102
const VIEW_PBI_BAR := 103

## Wire-style control popup ids.
const WIRE_STYLE_BEZIER := 300
const WIRE_STYLE_ROUNDED := 301
const WIRE_STYLE_METRO := 302
const WIRE_STYLE_APPLY_ALL := 303
var _wire_style_menu: MenuButton = null

## When true, PBI (Planetary Basic Income) nodes are pinned to a fixed
## screen-space bar along the top of the canvas instead of floating in graph
## space. Persisted in the graph save state.
var _pbi_bar_pinned: bool = true
var _pan_right_mouse := true
## Populated on first deferred init from the map lat/lon (generated) or scene tag.
var _cached_map_graph_key: String = ""
var _graph_file_dialog: FileDialog = null
var _esim_file_dialog: FileDialog = null
var _esim_paste_dialog: ConfirmationDialog = null
var _esim_paste_edit: TextEdit = null
var _esim_ghost_active: bool = false
var _esim_ghost_package: Dictionary = {}
var _osm_solar_btn: Button = null
var _location_wired: bool = false

## Survival state before graph was opened — restored when the graph closes.
var _gameplay_paused_before_graph: bool = true

## SolarBridge instance — polls solar_ui and keeps virtual graph nodes in sync.
var _bridge: RefCounted = null

## HistoryPlayer Node — fetches and replays HA history when the user enters
## HISTORICAL mode.  Lazily instantiated when the History button is pressed.
var _history_player: Node = null
## Bottom-edge UI strip shown only while a historical playback session is
## active.  Holds time display, scrubber, play/pause, speed.
var _history_panel: PanelContainer = null
var _history_play_btn:   Button = null
var _history_stop_btn:   Button = null
var _history_speed_opt:  OptionButton = null
var _history_slider:     HSlider = null
var _history_status_lbl: Label = null
var _history_time_lbl:   Label = null
var _history_user_seeking: bool = false   # suppress slider→playback feedback
const HISTORY_PANEL_H := 68.0

## IDs of virtual nodes / connections the user has manually deleted from the
## canvas.  Forwarded to SolarBridge.suppressed_ids so they are not re-created
## on the next tick.  Also persisted through save / load.
var _suppressed_virtuals: Dictionary = {}

## GraphSimLoadHost — owns lightweight Node proxies for every non-virtual
## load item so SceneNodeAction automations (dump load, battery-SOC gates,
## etc.) can actually toggle library-spawned appliances / chargers.
var _sim_load_host: Node = null

## ResourceFlowEngine — reversible multi-resource tank simulation.
var _resource_flow: RefCounted = null
## NPC population host (one engine per pop-driven habitat; ambient-ticked).
var _npc_population: NpcPopulationBridge = null
## Site Plan provider callables are installed once; see _wire_npc_providers.
var _npc_providers_wired := false
## 3D silhouette avatars for the population (spawned while any engine runs).
var _npc_host: Node3D = null
## Active multi-machine workflow (Phase 2) — empty dict when idle.
var _active_workflow: Dictionary = {}
var _workflow_panel: Control = null
var _closure_refresh_acc: float = 0.0
const _CLOSURE_REFRESH_INTERVAL := 1.0
var _conduit_manager: Node3D = null
var _placeholder_host: Node3D = null
var _conduit_route_wired: bool = false

## Home Assistant entity linker (Node — keeps a signal connection to HAClient).
var _ha_linker: Node = null

## Undo/redo history (snapshot-based).
var _history: RefCounted = null
## True while bridge.tick() or a bulk operation runs — skips history recording.
var _history_suppress:     bool = false
## True during the per-frame polling-tick block in _process(). While set,
## _on_model_changed defers its redraw/telemetry work (queue_redraw,
## _refresh_telemetry, _sync_solar_ui_from_graph, _sync_graph_controller_ac_fault)
## instead of running it once per model.update_item — a single sim tick can
## touch dozens of items (per-tank/per-virtual-node writes), and each write
## used to force its own full redraw + telemetry rescan. _flush_sim_bulk_update
## runs the deferred work exactly once after the tick block.
var _sim_bulk_update:        bool = false
var _pending_canvas_redraw:  bool = false
var _pending_telemetry_refresh: bool = false
## Throttle dashboard/library rescans during sim bulk (~1 Hz is enough for
## cost totals; physics already runs on its own pollers).
var _telemetry_flush_acc: float = 0.0
const _TELEMETRY_FLUSH_INTERVAL := 1.0
var _pending_library_populate: bool = false
## Becomes true after the first _process() tick so we capture the initial state.
var _history_initialized:  bool = false
## Set once main.gd applies a save snapshot to the graph. Blocks the deferred
## graph-autosave restore from clobbering the loaded game with last session's
## autosave (the two persistence paths race; the explicit save must win).
var _external_save_applied: bool = false
## Topbar undo/redo buttons — stored so we can update their disabled state.
var _undo_btn: Button = null
var _redo_btn: Button = null
# Combine ▾ — grouping / arrays / banks / wiring. Layout ▾ — arrange ops.
var _combine_menu: MenuButton = null
var _layout_menu: MenuButton = null
const COMBINE_GROUP := 0
const COMBINE_UNGROUP := 1
const COMBINE_ARRAY := 2
const COMBINE_BANK := 3
const COMBINE_SERIES := 4
const COMBINE_PARALLEL := 5
const COMBINE_CTRL_PICKER := 8
const COMBINE_EXPLODE := 7
const LAYOUT_ARRANGE := 6
const LAYOUT_PLACEHOLDER := 9
var _ctrl_picker_dialog: AcceptDialog = null
var _ctrl_picker_list: ItemList = null
var _ctrl_picker_array_id: String = ""
var _ctrl_picker_ranked: Array = []
var _enter_btn: Button = null
var _back_btn: Button = null
var _scope_breadcrumb: HBoxContainer = null
var _soi_chip: Label = null
var _explode_confirm: ConfirmationDialog = null
var _explode_pending_id: String = ""

## Full-screen background rect (opaque when SoI live preview is off).
var _bg_rect: ColorRect = null
var _soi_preview: Node = null
var _view_mode_menu: MenuButton = null
## The View options submenus (Site Plan / Elevation / People & paths) — kept so
## the _vm_set_* helpers can find which popup holds a given VIEW_MODE_* id.
var _view_mode_subpopups: Array = []


func _add_view_mode_submenu(root: PopupMenu, label: String, sub: PopupMenu) -> void:
	sub.id_pressed.connect(_on_view_mode_menu_id)
	root.add_child(sub)
	root.add_submenu_node_item(label, sub)
	_view_mode_subpopups.append(sub)


## The popup (root or submenu) holding a VIEW_MODE_* item, or null.
func _vm_popup_holding(id: int) -> PopupMenu:
	if _view_mode_menu == null:
		return null
	var root := _view_mode_menu.get_popup()
	if root.get_item_index(id) >= 0:
		return root
	for sub_v in _view_mode_subpopups:
		var sub := sub_v as PopupMenu
		if sub != null and is_instance_valid(sub) and sub.get_item_index(id) >= 0:
			return sub
	return null


func _vm_set_checked(id: int, checked: bool) -> void:
	var p := _vm_popup_holding(id)
	if p != null:
		p.set_item_checked(p.get_item_index(id), checked)


func _vm_set_disabled(id: int, disabled: bool) -> void:
	var p := _vm_popup_holding(id)
	if p != null:
		p.set_item_disabled(p.get_item_index(id), disabled)


func _vm_set_text(id: int, text: String) -> void:
	var p := _vm_popup_holding(id)
	if p != null:
		p.set_item_text(p.get_item_index(id), text)
var _mode_chip_row: HBoxContainer = null
var _mode_chip_btns: Dictionary = {}  # mode_id -> Button
var _designate_menu: MenuButton = null
var _site_designate_mode: String = ""  # "" | "catchment" | "crop"
var _graph_view_mode: String = GraphSiteLayout.VIEW_FREEFORM
## Freeform-only: show orbitable SoI snowglobe behind the abstract graph.
var _freeform_soi_bubble: bool = false
## Elevation-only: full 3D snowglobe cross-section behind the 2D profile.
## Default ON — Elevation is the CT section surface.
var _elevation_3d_section: bool = true
var _elev_slice_row: HBoxContainer = null
var _elev_slice_slider: HSlider = null
var _elev_slice_lbl: Label = null
var _hydro_section_lbl: Label = null
const _SOI_PREVIEW_SCRIPT := preload("res://system_graph/graph_soi_preview_service.gd")
const _SPATIAL_EDIT_SCRIPT := preload("res://system_graph/graph_spatial_edit.gd")
const VIEW_MODE_FREEFORM := 100
const VIEW_MODE_SITE := 101
const VIEW_MODE_ELEVATION := 102
const VIEW_MODE_SEED_SITE := 103
## 157, NOT 151: this shared the "View options ▾" popup with
## VIEW_MODE_SITE_PORTS (also 151), whose match arm won — "Embody missing Site
## twins…" silently toggled Site ports instead. Menu ids are session-only, so
## renumbering is safe; ui_compile_selftest now asserts VIEW_MODE_* uniqueness.
const VIEW_MODE_EMBODY_TWINS := 157
const VIEW_MODE_EXAG_1X := 104
const VIEW_MODE_EXAG_5X := 105
const VIEW_MODE_HEADING_ROTATE := 106
const VIEW_MODE_SOI_BUBBLE := 107
const VIEW_MODE_ELEV_3D := 108
const VIEW_MODE_SNOWGLOBE := 109
const VIEW_MODE_RESET_SECTION := 110
const VIEW_MODE_NODE_CARDS := 130
const VIEW_MODE_PREVIEW_LABELS := 131
const VIEW_MODE_RADIAL := 132
const VIEW_MODE_ELEV_DEM := 140
const VIEW_MODE_ELEV_CHIPS := 141
const VIEW_MODE_ELEV_PORTS := 142
const VIEW_MODE_ELEV_SCHEM_WIRES := 143
const VIEW_MODE_ELEV_PROJ_PIPES := 144
const VIEW_MODE_SITE_CHIPS := 145
const VIEW_MODE_SITE_LIVE_LIGHT := 146
const VIEW_MODE_ELEV_LIVE_LIGHT := 147
const VIEW_MODE_SITE_WIRE_NONE := 148
const VIEW_MODE_SITE_WIRE_METRO := 149
const VIEW_MODE_SITE_WIRE_3D := 150
const VIEW_MODE_SITE_PORTS := 151
## Desire lines (Tier 3e).
const VIEW_MODE_DESIRE_LINES := 152
const VIEW_MODE_DESIRE_TRAILS := 153
const VIEW_MODE_DESIRE_CHANNEL := 154
const VIEW_MODE_DESIRE_WINDOW := 155
const VIEW_MODE_DESIRE_3D := 156
const VIEW_MODE_DESIRE_RESET := 158
const DESIGNATE_OFF := 200
const DESIGNATE_CATCHMENT := 201
const DESIGNATE_CROP := 202
## One-shot toast when Elev 3D auto-enables world wires + flow glow.
var _elev_3d_wires_toast_shown: bool = false
## Site/Elev: freeze clock at mean solar noon so CT/plan aren't night-black.
var _elev_noon_active: bool = false
var _elev_saved_day_time: float = NAN
const ELEV_CLOCK_OWNER := "graph_elevation_noon"
## When true, Site/Elev keep the live clock (skip noon bake).
var _site_elev_live_lighting: bool = false
## Site Plan lighting-drift throttle: the live clock moves the sun, so the
## dirty-driven SoI SubViewport is re-captured at this wall-clock cadence
## while the plan is open (cheap UPDATE_ONCE, never the _preview_live path).
const SITE_LIGHT_REFRESH_MS := 5000
var _site_light_refresh_ms: int = 0
## Saved conduits_3d_visible when Site Plan forces a wire mode session.
var _site_saved_conduits_3d: Variant = null
var _spatial_edit = null
var _site_tool_row: HBoxContainer = null
var _site_radial_btn: Button = null
var _site_array_menu: MenuButton = null
var _site_radius_slider: HSlider = null
var _site_radius_lbl: Label = null
var _elev_hydro_lab_btn: Button = null
const SITE_ARRAY_LINE := 400
const SITE_ARRAY_ARC := 401
const SITE_ARRAY_CIRCLE := 402
const SITE_ARRAY_CONFIRM := 403
const SITE_ARRAY_CANCEL := 404
const SITE_ARRAY_SET_CENTER := 405
const SITE_ARRAY_CLEAR_CENTER := 406
const SITE_RADIUS_RESET := 407
var _awaiting_array_center: bool = false

## Reasons that should be recorded in the undo history.
const HISTORY_REASONS: Array[String] = [
	"add_item", "remove_item",
	"add_connection", "remove_connection",
	"reset",
]

## The central data model.  All graph edits go through here.
var model: GraphModel = null

# Node references (all built in _build_layout)
var _graph_canvas      = null
var _model_preview:    Node = null
var _left_sidebar:     Control = null
var _right_sidebar:    Control = null
var _left_toggle:      Button  = null
var _right_toggle:     Button  = null
var _lib_tab_btn:      Button  = null
var _insp_tab_btn:     Button  = null
var _inspector_panel   = null
var _siphon_lab_modal: Control = null
## Snapshot of 3D conduit prefs before Lab force-on (restored on exit).
var _lab_saved_conduits_visible: bool = false
var _lab_saved_flow_glow: bool = false
var _lab_conduit_prefs_saved: bool = false
var _selected_item_ids: Array[String] = []
var _embodiment_prop_id: String = ""
var _embodiment_solar_tag: String = ""
var _active_scope_id: String = "root"
var _scope_trail: Array[String] = ["root"]

# Toast notification
var _toast_panel: PanelContainer = null
var _toast_label: Label          = null
var _toast_timer: float          = 0.0
var _fault_card_modal: GraphFaultCardModal = null
# Tutorial sandbox (Solar Bootcamp): while active, the player's REAL graph
# state lives in _sandbox_pre_state and everything on the canvas is throwaway
# level content. collect_save_state() returns the pre-state so neither the
# per-map autosave nor a game save can ever capture sandbox content.
var _sandbox_active: bool = false
var _sandbox_pre_state: Dictionary = {}
var _autosave_suspended: bool = false
var _tutorial_director: Node = null
## Set by ChallengeBakeEngine while it owns the flow engine (bake/playback).
var _ambient_flow_suspended: bool = false
var _first_load_layout_done: bool = false
var _fit_deferred_pending: bool = false
var _checking_voltage: bool = false
# DC-side topology cache (banks/shorts) refreshed by _check_electrical_faults;
# _tick_dc_throttle reads it at 0.25 s cadence without re-flattening the graph.
var _dc_analysis: Dictionary = {}
var _dc_flat_conns: Array = []
var _dc_throttle_acc: float = 0.0
## Latches so the non-destructive advisories fire once per occurrence rather
## than on every fault pass / throttle tick.
var _pv_reverse_notified: bool = false
var _bank_advice_notified: bool = false
var _autosave_timer: Timer = null
var _autosave_pending: bool = false
## Debounced persistence for the tutorial sandbox graph — separate from
## _autosave_timer, which is deliberately suppressed while sandboxed (see
## _schedule_graph_autosave).
var _tutorial_sandbox_timer: Timer = null
var _timeline_inset_hooked := false

# Component (super-node) live-propagation. Editing inside an instance debounces a
# capture->restamp-siblings cycle; the guard stops the restamp's own `changed`
# emissions from re-triggering propagation (see _on_model_changed).
var _component_sync_timer: Timer = null
var _component_sync_pending: Dictionary = {}   # instance_id -> true
var _component_sync_active: bool = false

# Hints overlay
var _hints_panel:   Control = null
var _hints_visible: bool    = false

# System Review modal (rebuilt on each open)
var _review_modal: Control = null

## Phase 10 will populate these from graph items.  Phase 1 leaves them at 0.
var _score_labels: Dictionary = {}

# ---------------------------------------------------------------------------
# Library panel & drag-to-spawn
# ---------------------------------------------------------------------------
var _lib_panel = null            # LibraryPanel script instance (right sidebar)
var _lib_ghost: PanelContainer = null
var _lib_ghost_label: Label    = null
var _lib_drag_active: bool     = false   # dragging past threshold
var _lib_drag_preset: Dictionary = {}    # preset being dragged / clicked
var _lib_drag_start:  Vector2  = Vector2.ZERO
const LIB_DRAG_THRESHOLD := 6.0


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	ServiceLocator.provide(ServiceLocator.GRAPH, self)
	focus_mode = Control.FOCUS_ALL
	model = GraphModel.new()
	model.changed.connect(_on_model_changed)
	_history = _HISTORY_SCRIPT.new()
	_ha_linker = _LINKER_SCRIPT.new()
	_ha_linker.name = "HAEntityLinker"
	add_child(_ha_linker)
	_ha_linker.call("setup", model)
	_init_sim_load_host()
	_init_resource_flow()
	_init_model_preview()
	_refresh_solar_ui_ref()
	_build_layout()
	_wire_model_preview()
	_load_graph_ui_prefs()
	if is_instance_valid(_graph_dashboard):
		_graph_dashboard.bind_graph_view(self)
		_graph_dashboard.set_mode(_mode)
	_init_bridge()
	_init_graph_autosave()
	call_deferred("_deferred_restore_graph_autosave")
	call_deferred("_init_conduit_manager")
	call_deferred("_init_placeholder_host")
	_connect_automation_feedback()
	# Solar Bootcamp first-load offer (new players only; no-op headless/harness).
	get_tree().create_timer(3.0).timeout.connect(
		_maybe_show_tutorial_prompt, CONNECT_ONE_SHOT)
	# _process stays ENABLED always (ambient resource-flow tick needs to run
	# even while the graph is closed — see _tick_resource_flow_ambient). The
	# `if not visible: return` inside _process still gates the heavy UI-only
	# work, so this costs nothing extra while hidden.


## Flash the bound graph node when one of its automation rules fires.
func _connect_automation_feedback() -> void:
	var eng := get_node_or_null("/root/AutomationEngine")
	if eng == null or not eng.has_signal("automation_triggered"):
		return
	if not eng.is_connected("automation_triggered", _on_automation_triggered):
		eng.connect("automation_triggered", _on_automation_triggered)


func _on_automation_triggered(automation_id: String) -> void:
	if model == null or _graph_canvas == null or automation_id.is_empty():
		return
	if not visible:
		return
	for it: Dictionary in model.items:
		var specs: Dictionary = it.get("specs", {}) as Dictionary
		var autos: Array = specs.get("graph_automations", []) as Array
		for a: Variant in autos:
			if a is Dictionary and str((a as Dictionary).get("id", "")) == automation_id:
				if _graph_canvas.has_method("flash_item"):
					_graph_canvas.call("flash_item", str(it.get("id", "")))
				return


func _exit_tree() -> void:
	_flush_graph_autosave()
	_shutdown_soi_preview_world_effects()
	if _sim_load_host != null and _sim_load_host.has_method("teardown"):
		_sim_load_host.call("teardown")
	# Make sure a hot historical session does not leave the global SimMode
	# latched on after the graph view is dismissed.
	if _history_player != null and is_instance_valid(_history_player):
		_history_player.call("stop")


func _init_resource_flow() -> void:
	if _resource_flow == null:
		_resource_flow = _RESOURCE_FLOW_SCRIPT.new()
	if _resource_flow != null and _resource_flow.has_method("setup"):
		_resource_flow.call("setup", model, self)
	if _resource_flow != null and _resource_flow.has_signal("tank_overflow_changed") \
			and not _resource_flow.is_connected("tank_overflow_changed", _on_tank_overflow_changed):
		_resource_flow.connect("tank_overflow_changed", _on_tank_overflow_changed)
	if _resource_flow != null and _resource_flow.has_signal("processor_blocked") \
			and not _resource_flow.is_connected("processor_blocked", _on_processor_blocked):
		_resource_flow.connect("processor_blocked", _on_processor_blocked)
	if _resource_flow != null and _resource_flow.has_signal("recipe_parts_ready") \
			and not _resource_flow.is_connected("recipe_parts_ready", _on_recipe_parts_ready):
		_resource_flow.connect("recipe_parts_ready", _on_recipe_parts_ready)
	if _resource_flow != null and _resource_flow.has_signal("recipe_chore_waiting") \
			and not _resource_flow.is_connected("recipe_chore_waiting", _on_recipe_chore_waiting):
		_resource_flow.connect("recipe_chore_waiting", _on_recipe_chore_waiting)
	_sync_chore_ledger_to_flow()
	if _graph_canvas != null:
		_graph_canvas.set("resource_flow_engine", _resource_flow)


## Toast on false→true transitions only (the signal already guarantees edges).
func _on_tank_overflow_changed(item_id: String, overflowing: bool) -> void:
	if not overflowing:
		return
	# Siphon Lab drives pond levels for CT — don't spam Overflow overlays.
	if _graph_view_mode == GraphSiteLayout.VIEW_SIPHON:
		return
	var item := model.get_item(item_id) if model != null else {}
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var tank_name := str(specs.get("name", "Tank"))
	_show_toast("⚠ %s overflowing — capacity exceeded, input is being lost" % tank_name)


func _on_processor_blocked(item_id: String, missing_kinds: Array) -> void:
	var item := model.get_item(item_id) if model != null else {}
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var p_name := str(specs.get("name", "Processor"))
	var k_names: PackedStringArray = []
	for k: Variant in missing_kinds:
		k_names.append(ResourceKinds.display_name(str(k)))
	var k_str := ", ".join(k_names)
	_show_toast("⚠ %s blocked — waiting for %s" % [p_name, k_str])


func _sync_chore_ledger_to_flow() -> void:
	if _resource_flow == null:
		return
	var main := _get_scene_main_node()
	var loader := _find_terrain_loader(main) if main != null else null
	if loader != null and loader.has_method("get_chore_ledger"):
		_resource_flow.chore_ledger = loader.call("get_chore_ledger") as ChoreLedger


func _on_recipe_parts_ready(item_id: String, parts: Array) -> void:
	for p: Variant in parts:
		if not (p is Dictionary):
			continue
		var d: Dictionary = p as Dictionary
		var pid := str(d.get("part_id", ""))
		if pid.is_empty():
			continue
		var count := maxi(int(d.get("qty", 1)), 1)
		var src := "recipe"
		if model != null:
			var it := model.get_item(item_id)
			if not it.is_empty():
				src = str((it.get("specs", {}) as Dictionary).get("name", "recipe"))
		var meta := {
			"label": str(d.get("label", pid)),
			"material_kind": str(d.get("material_kind", "")),
			"source": src,
		}
		var main := _get_scene_main_node()
		var loader := _find_terrain_loader(main) if main != null else null
		if loader != null and loader.has_method("credit_part"):
			loader.call("credit_part", pid, count, meta)
			_show_part_up_toast(str(meta["label"]), count)


func _on_recipe_chore_waiting(item_id: String, request: Dictionary) -> void:
	var label := str(request.get("label", "Needs attention"))
	var hours := float(request.get("chore_hours", 0.0))
	var main := _get_scene_main_node()
	if main != null and main.has_method("show_chore_confirm"):
		main.call("show_chore_confirm", item_id, label, hours)
		return
	var toast: Variant = main.get("toast_ui") if main != null else null
	if toast != null and is_instance_valid(toast) and toast.has_method("show_chore_confirm"):
		toast.call("show_chore_confirm", item_id, label, hours,
			func(): confirm_recipe_chore(item_id))


## Apply a catalog process recipe to a processor (stamps I/O + timing).
func apply_process_recipe(item_id: String, recipe_id: String) -> bool:
	if model == null or item_id.is_empty() or recipe_id.is_empty():
		return false
	var item := model.get_item(item_id)
	if item.is_empty():
		return false
	var recipe := ProcessRecipeCatalog.find(recipe_id)
	if recipe.is_empty():
		return false
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	RecipeRunner.select_recipe(specs, recipe)
	# Sheet-press bridge: keep dedicated job kinematics, just configure thickness/part.
	if str(specs.get("role", "")) == "pp_sheet_press":
		if recipe.has("sheet_thickness_mm"):
			specs["sheet_thickness_mm"] = float(recipe["sheet_thickness_mm"])
		if str(recipe.get("job_part_id", "")) != "":
			specs["job_part_id"] = str(recipe["job_part_id"])
		if str(recipe.get("job_part_label", "")) != "":
			specs["job_part_label"] = str(recipe["job_part_label"])
	model.update_item(item_id, {"specs": specs})
	return true


## Start the selected/active process recipe on a generic batch processor.
func start_process_recipe(item_id: String) -> bool:
	if model == null or item_id.is_empty():
		return false
	var item := model.get_item(item_id)
	if item.is_empty():
		return false
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var role := str(specs.get("role", ""))
	if role == "pp_sheet_press":
		return start_pp_sheet_press_job(item_id)
	var abs_h := 0.0
	var main := _get_scene_main_node()
	if main != null and main.has_method("get_absolute_hours"):
		abs_h = float(main.call("get_absolute_hours"))
	var recipe := RecipeRunner.resolve_recipe(specs)
	if recipe.is_empty():
		return false
	# Ensure switched on so RFE will run the batch.
	specs["switched_on"] = true
	specs["on"] = true
	var begin := RecipeRunner.begin_run(specs, abs_h, recipe)
	model.update_item(item_id, {"specs": specs})
	if bool(begin.get("waiting_chore", false)):
		_on_recipe_chore_waiting(item_id, {
			"step_id": str(specs.get("recipe_waiting_step_id", "")),
			"label": str(specs.get("recipe_waiting_label", "Needs attention")),
			"chore_hours": float(specs.get("recipe_waiting_chore_hrs", 0.0)),
		})
	return bool(begin.get("ok", false))


func cancel_process_recipe(item_id: String) -> void:
	if model == null or item_id.is_empty():
		return
	var item := model.get_item(item_id)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	if str(specs.get("role", "")) == "pp_sheet_press":
		cancel_pp_sheet_press_job(item_id)
		return
	RecipeRunner.cancel_run(specs)
	model.update_item(item_id, {"specs": specs})


## A crew member finished the chore a labour-gated recipe step was waiting on.
##
## Called BY STRING from SiteProjectEffects (the bridge's post-tick sweep), and
## deliberately routed through the same `confirm_recipe_chore` the player's
## button uses: one resume path, one debit, no second accounting. The step_id
## guard means a stale effect — a chore completing after the player cancelled
## the run, or after the machine moved on — resolves to a harmless no-op
## rather than skipping whatever step happens to be waiting now.
func resume_recipe_step(item_id: String, step_id: String) -> bool:
	if model == null or item_id.is_empty():
		return false
	var item := model.get_item(item_id)
	if item.is_empty():
		return true   # the machine is gone; consume the effect
	var specs: Dictionary = item.get("specs", {})
	if not bool(specs.get("recipe_waiting_chore", false)):
		return true
	if not step_id.is_empty() and str(specs.get("recipe_waiting_step_id", "")) != step_id:
		return true   # it has moved on to a different step
	return confirm_recipe_chore(item_id)


func confirm_recipe_chore(item_id: String) -> bool:
	if model == null or item_id.is_empty():
		return false
	_sync_chore_ledger_to_flow()
	var item := model.get_item(item_id)
	if item.is_empty():
		return false
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var abs_h := 0.0
	var main := _get_scene_main_node()
	if main != null and main.has_method("get_absolute_hours"):
		abs_h = float(main.call("get_absolute_hours"))
	var ledger: ChoreLedger = null
	if _resource_flow != null:
		ledger = _resource_flow.chore_ledger
	# Sheet-press unload chore: debit labor, credit pending part, resume auto-cycle.
	if str(specs.get("role", "")) == "pp_sheet_press" \
			and bool(specs.get("sheet_credit_pending", false)):
		var hours := maxf(float(specs.get("recipe_waiting_chore_hrs", 0.0)), 0.0)
		if ledger != null and hours > 0.0 and not ledger.try_debit(hours):
			return false
		specs["sheet_unload_confirmed"] = true
		specs["sheet_credit_pending"] = false
		specs.erase("recipe_waiting_chore")
		specs.erase("recipe_waiting_step_id")
		specs.erase("recipe_waiting_label")
		specs.erase("recipe_waiting_chore_hrs")
		model.update_item(item_id, {"specs": specs})
		_credit_fabricated_part(specs)
		if bool(specs.get("auto_cycle", true)):
			specs["job_completed"] = false
			specs.erase("sheet_unload_confirmed")
			model.update_item(item_id, {"specs": specs})
		var loader_s := _find_terrain_loader(main) if main != null else null
		if loader_s != null and loader_s.has_method("save_chore_ledger"):
			loader_s.call("save_chore_ledger")
		return true
	var result := RecipeRunner.confirm_chore(specs, abs_h, ledger)
	model.update_item(item_id, {"specs": specs})
	var loader := _find_terrain_loader(main) if main != null else null
	if loader != null and loader.has_method("save_chore_ledger"):
		loader.call("save_chore_ledger")
	return bool(result.get("ok", false))


## Open the process-recipe editor modal (create/edit user recipes).
func open_process_recipe_editor(recipe_id: String = "", role_hint: String = "") -> void:
	var main := _get_scene_main_node()
	var ui := main.get_node_or_null("UILayer") if main != null else null
	var existing: Node = null
	if ui != null:
		existing = ui.get_node_or_null("ProcessRecipeEditor")
	if existing == null:
		var editor_script: GDScript = load("res://scenes/ui/process_recipe_editor.gd") as GDScript
		if editor_script == null:
			return
		existing = editor_script.new()
		existing.name = "ProcessRecipeEditor"
		if ui != null:
			ui.add_child(existing)
		else:
			add_child(existing)
	if existing.has_method("open"):
		existing.call("open", recipe_id, role_hint)


func open_workflow_panel() -> void:
	if _workflow_panel == null or not is_instance_valid(_workflow_panel):
		var script: GDScript = load("res://scenes/ui/workflow_panel.gd") as GDScript
		if script == null:
			return
		_workflow_panel = script.new()
		_workflow_panel.name = "WorkflowPanel"
		var main := _get_scene_main_node()
		var ui := main.get_node_or_null("UILayer") if main != null else null
		if ui != null:
			ui.add_child(_workflow_panel)
		else:
			add_child(_workflow_panel)
	_workflow_panel.call("open")


func get_active_workflow() -> Dictionary:
	return _active_workflow.duplicate(true)


func start_workflow(workflow_id: String) -> bool:
	var wf := WorkflowRecipeCatalog.find(workflow_id)
	if wf.is_empty():
		return false
	_active_workflow = WorkflowRunner.create_state(workflow_id, {})
	var begin := WorkflowRunner.begin(_active_workflow, wf)
	if not bool(begin.get("ok", false)):
		_active_workflow = {}
		return false
	_tick_active_workflow()
	return true


func cancel_workflow() -> void:
	if not _active_workflow.is_empty():
		WorkflowRunner.cancel(_active_workflow)
	_active_workflow = {}


func confirm_workflow_chore() -> bool:
	if _active_workflow.is_empty():
		return false
	var result := WorkflowRunner.confirm_chore(_active_workflow, _workflow_ctx())
	if bool(result.get("ok", false)):
		_tick_active_workflow()
	return bool(result.get("ok", false))


func _tick_active_workflow() -> void:
	if _active_workflow.is_empty():
		return
	var status := str(_active_workflow.get("status", ""))
	if status in ["idle", "done", "failed"]:
		return
	var prev_status := status
	var result := WorkflowRunner.tick(_active_workflow, _workflow_ctx())
	var new_status := str(result.get("status", status))
	if new_status == WorkflowRunner.STATE_WAITING_CHORE \
			and prev_status != WorkflowRunner.STATE_WAITING_CHORE:
		var waiting: Dictionary = result.get("waiting",
			_active_workflow.get("waiting", {})) as Dictionary
		var main := _get_scene_main_node()
		var toast: Variant = main.get("toast_ui") if main != null else null
		if toast != null and is_instance_valid(toast) and toast.has_method("show_chore_confirm"):
			toast.call("show_chore_confirm", "",
				str(waiting.get("label", "Workflow chore")),
				float(waiting.get("chore_hours", 0.0)),
				func(): confirm_workflow_chore())
	if new_status == WorkflowRunner.STATE_DONE:
		_show_toast("Workflow complete: %s" % str(_active_workflow.get("workflow_id", "")))


func _workflow_ctx() -> Dictionary:
	return {
		"find_machine": func(role: String) -> String:
			if model == null:
				return ""
			for item: Dictionary in model.items:
				if str(item.get("type", "")) != "processor":
					continue
				var specs: Dictionary = item.get("specs", {}) as Dictionary
				if str(specs.get("role", "")) == role:
					return str(item.get("id", ""))
			return "",
		"apply_recipe": func(item_id: String, recipe_id: String) -> bool:
			return apply_process_recipe(item_id, recipe_id),
		"start_recipe": func(item_id: String) -> bool:
			return start_process_recipe(item_id),
		"machine_busy": func(item_id: String) -> bool:
			var item := model.get_item(item_id) if model != null else {}
			var specs: Dictionary = item.get("specs", {}) as Dictionary
			return bool(specs.get("job_active", false)) or bool(specs.get("recipe_running", false)) \
					or bool(specs.get("recipe_waiting_chore", false)) \
					or bool(specs.get("sheet_credit_pending", false)),
		"machine_done": func(item_id: String) -> bool:
			var item := model.get_item(item_id) if model != null else {}
			var specs: Dictionary = item.get("specs", {}) as Dictionary
			if bool(specs.get("sheet_credit_pending", false)):
				return false
			if bool(specs.get("job_completed", false)) and not bool(specs.get("job_active", false)):
				return true
			if not bool(specs.get("recipe_running", false)) \
					and float(specs.get("recipe_progress", 0.0)) >= 1.0:
				return true
			return false,
		"debit_chore": func(hours: float) -> bool:
			_sync_chore_ledger_to_flow()
			var ledger: ChoreLedger = _resource_flow.chore_ledger if _resource_flow != null else null
			if ledger == null:
				return true
			var ok := ledger.try_debit(hours)
			var main := _get_scene_main_node()
			var loader := _find_terrain_loader(main) if main != null else null
			if ok and loader != null and loader.has_method("save_chore_ledger"):
				loader.call("save_chore_ledger")
			return ok,
	}


## Live resource/processor state snapshot for the automation context + HUD.
## Tank levels are addressable by id and by lower_snake_case name; each resource
## kind also gets its lowest tank level under "resource.<kind>.level".
## Switchable nodes expose device_states["node.<id>"] = on|off|starved|blocked.
func get_automation_resource_context() -> Dictionary:
	var numeric: Dictionary = {}
	var states: Dictionary = {}
	# Always publish on/off from the live model so automations can key off
	# graph neighbors even when DeviceRegistry has no entry for a sim-load.
	if model != null:
		for item: Dictionary in model.items:
			var ity := str(item.get("type", ""))
			if ity not in ["processor", "appliance", "acload"]:
				continue
			var iid := str(item.get("id", ""))
			if iid.is_empty():
				continue
			var specs: Dictionary = item.get("specs", {}) as Dictionary
			var st := str(specs.get("node_state", ""))
			var on_off := str(specs.get("requested_state",
					specs.get("current_state", "off"))).to_lower()
			if on_off != "on":
				on_off = "off"
			# Prefer run switch; escalate to starvation/block when active.
			if st == GraphNodeState.STARVED:
				states["node.%s" % iid] = "starved"
			elif st == GraphNodeState.BLOCKED:
				states["node.%s" % iid] = "blocked"
			else:
				states["node.%s" % iid] = on_off
			var nm := str(specs.get("name", "")).strip_edges().to_lower().replace(" ", "_")
			if not nm.is_empty():
				states["node.%s" % nm] = states["node.%s" % iid]
	if _resource_flow == null or not _resource_flow.has_method("state_snapshot"):
		return {"numeric_values": numeric, "device_states": states}
	var snap: Dictionary = _resource_flow.call("state_snapshot")
	var tanks: Dictionary = snap.get("tanks", {}) as Dictionary
	for tid: String in tanks:
		var t: Dictionary = tanks[tid] as Dictionary
		var lvl := float(t.get("level_pct", 0.0))
		numeric["tank.%s.level" % tid] = lvl
		var nm := str(t.get("name", "")).strip_edges().to_lower().replace(" ", "_")
		if not nm.is_empty():
			numeric["tank.%s.level" % nm] = lvl
		var kind := str(t.get("kind", ""))
		if not kind.is_empty():
			var key := "resource.%s.level" % kind
			numeric[key] = minf(float(numeric.get(key, 100.0)), lvl)
		states["tank.%s" % tid] = "overflow" if bool(t.get("overflow", false)) else "ok"
		if not nm.is_empty():
			states["tank.%s" % nm] = states["tank.%s" % tid]
	for hid: String in (snap.get("starved", {}) as Dictionary):
		states["node.%s" % hid] = "starved"
	for bid: String in (snap.get("blocked", {}) as Dictionary):
		states["node.%s" % bid] = "blocked"
	return {"numeric_values": numeric, "device_states": states}


func _init_sim_load_host() -> void:
	if _sim_load_host != null:
		return
	_sim_load_host = _SIM_LOAD_HOST_SCRIPT.new()
	_sim_load_host.name = "GraphSimLoadHost"
	add_child(_sim_load_host)
	_sim_load_host.call("setup", model)


func _init_model_preview() -> void:
	if _model_preview != null and is_instance_valid(_model_preview):
		return
	_model_preview = _PREVIEW_SERVICE_SCRIPT.new()
	_model_preview.name = "GraphModelPreviewService"
	add_child(_model_preview)
	if _model_preview.has_signal("preview_ready"):
		_model_preview.connect("preview_ready", _on_model_preview_ready)


func _wire_model_preview() -> void:
	if _graph_canvas != null:
		_graph_canvas.set("model_preview_service", _model_preview)
	if _inspector_panel != null and _inspector_panel.has_method("set_preview_refresh_callback"):
		_inspector_panel.call("set_preview_refresh_callback",
			Callable(self, "_refresh_item_card_preview"))


func _on_model_preview_ready(_cache_key: String, _texture: ImageTexture) -> void:
	if _graph_canvas != null:
		_graph_canvas.call("queue_redraw")


## Public redraw hook (terrain watershed preview, external overlays).
func queue_canvas_redraw() -> void:
	if _graph_canvas != null:
		_graph_canvas.call("queue_redraw")


## Invalidate + re-queue the card snapshot for one graph item (inspector camera / GLB).
func _refresh_item_card_preview(item_id: String) -> void:
	if _model_preview == null or model == null or item_id.is_empty():
		return
	var item := model.get_item(item_id)
	if item.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if str(specs.get("model_id", "")).is_empty():
		return
	if _model_preview.has_method("request_refresh"):
		_model_preview.call("request_refresh", specs)
	if _graph_canvas != null:
		_graph_canvas.call("queue_redraw")


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		var vp := get_viewport()
		if vp != null:
			vp.disable_3d = visible
		
		# NOTE: processing is intentionally NOT gated by visibility (see the
		# comment at the end of _ready) — the ambient resource-flow tick must
		# keep running while the graph is closed.
		mouse_filter = (
			Control.MOUSE_FILTER_STOP if visible
			else Control.MOUSE_FILTER_IGNORE
		)
		if visible:
			_refresh_solar_ui_ref()
			_init_bridge()
			if _graph_canvas != null:
				_graph_canvas.set("pan_right_mouse", _pan_right_mouse)
			_ensure_timeline_inset_hook()
			# Re-measure after TimelineUI finishes its deferred bar layout.
			call_deferred("_apply_layout")
			call_deferred("grab_focus")
			call_deferred("_init_placeholder_host")
			# Re-enable SoI backdrop only once the graph is actually shown —
			# view prefs may already be restored from autosave while hidden.
			# Re-read mode at execution time (not queue time) so a same-frame
			# open_siphon_lab / mode chip isn't clobbered by a stale arg.
			call_deferred("_reapply_current_graph_view_mode")
			call_deferred("_refresh_osm_solar_btn")
			# Late MapContext / terrain load may have landed since _ready.
			call_deferred("_bind_map_graph", false)
		else:
			_flush_graph_autosave()
			_clear_embodiment_highlight()
			# Hydro Lab suspends the player + may leave a watershed ghost mesh —
			# always tear that down when G closes the graph, not only when
			# switching view modes inside an open graph.
			_force_teardown_siphon_lab_on_graph_close()
			_shutdown_soi_preview_world_effects()
			_elev_end_noon_lock()
		_apply_mouse_for_graph(visible)
	elif what == NOTIFICATION_RESIZED:
		if visible:
			_apply_layout()
			if _soi_preview != null and _soi_preview.has_method("mark_layout_dirty"):
				_soi_preview.call("mark_layout_dirty")


func _init_graph_autosave() -> void:
	if Engine.is_editor_hint():
		return
	if _autosave_timer != null:
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GRAPH_AUTOSAVE_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GRAPH_LIBRARY_DIR))
	_autosave_timer = Timer.new()
	_autosave_timer.one_shot = true
	_autosave_timer.wait_time = GRAPH_AUTOSAVE_DEBOUNCE_SEC
	_autosave_timer.timeout.connect(_flush_graph_autosave)
	add_child(_autosave_timer)
	_component_sync_timer = Timer.new()
	_component_sync_timer.one_shot = true
	_component_sync_timer.wait_time = 0.15
	_component_sync_timer.timeout.connect(_flush_component_sync)
	add_child(_component_sync_timer)
	_tutorial_sandbox_timer = Timer.new()
	_tutorial_sandbox_timer.one_shot = true
	_tutorial_sandbox_timer.wait_time = GRAPH_AUTOSAVE_DEBOUNCE_SEC
	_tutorial_sandbox_timer.timeout.connect(_flush_tutorial_sandbox_save)
	add_child(_tutorial_sandbox_timer)


## Stable key for this map's graph autosave.
## Generated location maps → `map_{lat}_{lon}` (CoordToken). Hand-built scenes →
## `scene_{basename}` so Mars / Soak stay independent of prefs.
func _compute_map_graph_key() -> String:
	var main_node := _get_scene_main_node()
	var scene_tag := _scene_basename(main_node)
	if scene_tag.is_empty() or scene_tag == "generated_location":
		var lat := 0.0
		var lon := 0.0
		if main_node != null:
			if main_node.get("latitude") != null:
				lat = float(main_node.get("latitude"))
			if main_node.get("longitude") != null:
				lon = float(main_node.get("longitude"))
		# MapContext may still be pending if TerrainLoader hasn't consumed it yet.
		var ctx := get_node_or_null("/root/MapContext")
		if ctx != null and bool(ctx.get("has_pending")):
			lat = float(ctx.get("latitude"))
			lon = float(ctx.get("longitude"))
		return "map_%s_%s" % [CoordToken.token(lat), CoordToken.token(lon)]
	return "scene_%s" % scene_tag


func _scene_basename(main_node: Node) -> String:
	if main_node != null:
		var path := String(main_node.scene_file_path)
		if not path.is_empty():
			return path.get_file().trim_suffix(".tscn").replace(" ", "_")
	var tree := get_tree()
	if tree != null and tree.current_scene != null:
		var path2 := String(tree.current_scene.scene_file_path)
		if not path2.is_empty():
			return path2.get_file().trim_suffix(".tscn").replace(" ", "_")
	return ""


func _graph_autosave_path() -> String:
	return "%s/%s.graph.json" % [GRAPH_AUTOSAVE_DIR, _resolve_map_graph_key()]


func _resolve_map_graph_key() -> String:
	if not _cached_map_graph_key.is_empty():
		return _cached_map_graph_key
	return _compute_map_graph_key()


func _cache_map_graph_key() -> void:
	_cached_map_graph_key = _compute_map_graph_key()


func _deferred_restore_graph_autosave() -> void:
	_wire_main_location_changed()
	# If main.gd already applied a save snapshot, that loaded graph wins — do NOT
	# overwrite it with the (older) per-map autosave. Still run the bridge/PBI
	# setup below either way.
	if not _external_save_applied:
		_bind_map_graph(true)
	else:
		_cache_map_graph_key()
		_ensure_pbi_nodes()
	if _bridge != null and _bridge.has_method("setup") and is_instance_valid(_solar_ui):
		_bridge.call("setup", model, _solar_ui)
	call_deferred("_sync_solar_ui_from_graph")
	call_deferred("_refresh_osm_solar_btn")
	call_deferred("_try_seed_starshade_if_empty")


func _wire_main_location_changed() -> void:
	if _location_wired:
		return
	var main_node := _get_scene_main_node()
	if main_node == null or not main_node.has_signal("location_changed"):
		return
	if not main_node.is_connected("location_changed", _on_main_location_changed_for_graph):
		main_node.connect("location_changed", _on_main_location_changed_for_graph)
	_location_wired = true


## Mid-session location change (or late MapContext apply) → switch per-map graph.
func _on_main_location_changed_for_graph(_lat: float, _lon: float) -> void:
	if _external_save_applied:
		# Game save owns this frame; just retarget the key for future autosaves.
		_cached_map_graph_key = ""
		_cache_map_graph_key()
		return
	_bind_map_graph(false)


## Load this map's autosave, or start empty (PBIs only). Flushes the previous
## map key first when switching.
func _bind_map_graph(force: bool) -> void:
	# Full game save owns the graph for this session until the next map boot.
	if _external_save_applied:
		_cache_map_graph_key()
		_refresh_osm_solar_btn()
		return
	var new_key := _compute_map_graph_key()
	if not force and new_key == _cached_map_graph_key and not _cached_map_graph_key.is_empty():
		return
	# Persist outgoing map before switching keys.
	if not _cached_map_graph_key.is_empty() and new_key != _cached_map_graph_key:
		_autosave_pending = true
		_flush_graph_autosave()
	_cached_map_graph_key = new_key
	if FileAccess.file_exists(_graph_autosave_path()):
		_try_restore_graph_autosave()
	else:
		_clear_graph_contents_for_new_map()
	_ensure_pbi_nodes()
	_refresh_osm_solar_btn()
	call_deferred("_try_seed_starshade_if_empty")


func _clear_graph_contents_for_new_map() -> void:
	if model == null:
		return
	_history_suppress = true
	# Clear everything — new maps start empty (PBIs re-added afterward).
	for i in range(model.items.size() - 1, -1, -1):
		var it: Dictionary = model.items[i]
		model.remove_item(str(it.get("id", "")))
	for i in range(model.connections.size() - 1, -1, -1):
		model.connections.remove_at(i)
	_suppressed_virtuals.clear()
	if _bridge != null:
		_bridge.suppressed_ids = _suppressed_virtuals
	_active_scope_id = "root"
	_scope_trail = ["root"]
	_selected_item_ids.clear()
	_history_suppress = false
	if _graph_canvas != null:
		_graph_canvas.set("active_scope_id", _active_scope_id)
		_graph_canvas.call("queue_redraw")


func _try_seed_starshade_if_empty() -> void:
	if model == null or StarShadeGraphSeeder.has_graph_content(model):
		return
	var main_node := _get_scene_main_node()
	if main_node == null:
		return
	var loader := _find_terrain_loader(main_node)
	StarShadeGraphSeeder.try_seed_from_main(main_node, loader)


## Called by TerrainLoader after world/OSM/SoI are ready for this site.
func _on_map_world_ready() -> void:
	if not _external_save_applied:
		_bind_map_graph(false)
	_refresh_osm_solar_btn()
	_try_seed_starshade_if_empty()


func has_user_graph_layout() -> bool:
	if Engine.is_editor_hint():
		return false
	return FileAccess.file_exists(_graph_autosave_path())


func _schedule_graph_autosave() -> void:
	if Engine.is_editor_hint():
		return
	if _autosave_suspended:
		# The sandbox graph itself is never part of the player's autosave (see
		# begin_tutorial_sandbox), but the carry_graph curriculum (levels 10-12)
		# needs the graph to survive a session close, or resuming one lands on
		# a blank, unbuildable canvas. Persist it on its own debounced timer —
		# every one of this function's ~60 call sites doubles as the hook.
		if _sandbox_active and _tutorial_sandbox_timer != null:
			_tutorial_sandbox_timer.start()
		return
	if _autosave_timer == null:
		return
	_autosave_pending = true
	_autosave_timer.start()


func _flush_graph_autosave() -> void:
	if Engine.is_editor_hint() or not _autosave_pending or _autosave_suspended:
		return
	if _cached_map_graph_key.is_empty():
		_cache_map_graph_key()
	_autosave_pending = false
	var payload := collect_save_state()
	payload["map_graph_key"] = _cached_map_graph_key
	var f := FileAccess.open(_graph_autosave_path(), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(payload))
	f.close()


func _try_restore_graph_autosave() -> void:
	if Engine.is_editor_hint():
		return
	var path := _graph_autosave_path()
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if parsed is Dictionary and not (parsed as Dictionary).is_empty():
		apply_save_state(parsed as Dictionary)


# ---------------------------------------------------------------------------
# Tutorial sandbox (Solar Bootcamp) — see gameplay/tutorial_director.gd
# ---------------------------------------------------------------------------

## Snapshot the player's real graph, suspend autosave, silence the solar
## bridge's virtual nodes, and clear the canvas for level content. Returns
## false when already active.
func begin_tutorial_sandbox() -> bool:
	if _sandbox_active:
		return false
	_sandbox_pre_state = collect_save_state()
	_sandbox_active = true
	_autosave_suspended = true
	if _bridge != null and _bridge.has_method("set_enabled"):
		_bridge.call("set_enabled", false)
	tutorial_clear_graph()
	return true


## Debounced write of the live sandbox graph to ProgressStore — the only thing
## that lets a carry_graph level (10-12) resume with content after a session
## close instead of the blank canvas begin_tutorial_sandbox always starts from.
func _flush_tutorial_sandbox_save() -> void:
	if not _sandbox_active or model == null:
		return
	var level_id := ""
	if _tutorial_director != null and is_instance_valid(_tutorial_director):
		var lvl: TutorialLevelDef = _tutorial_director.get("_level")
		if lvl != null:
			level_id = lvl.id
	ProgressStore.save_sandbox_snapshot(level_id, model.serialize())


## Apply the last-persisted sandbox graph on top of the (currently empty)
## sandbox. Called by TutorialDirector.start() when entering a carry_graph
## level. Returns false when nothing was persisted (first-ever visit).
func restore_tutorial_sandbox_snapshot() -> bool:
	var blob: Dictionary = ProgressStore.load_sandbox_snapshot().get("graph", {}) as Dictionary
	if blob.is_empty():
		return false
	apply_save_state({"graph": blob}, {"sandbox": true})
	return true


func clear_tutorial_sandbox_snapshot() -> void:
	ProgressStore.clear_sandbox_snapshot()


## Restore the pre-tutorial graph exactly as it was. `_schedule` refreshes the
## autosave from the restored (identical) state, which is harmless.
func end_tutorial_sandbox() -> void:
	if not _sandbox_active:
		return
	_sandbox_active = false
	var pre := _sandbox_pre_state
	_sandbox_pre_state = {}
	if _bridge != null and _bridge.has_method("set_enabled"):
		_bridge.call("set_enabled", true)
	if not pre.is_empty():
		apply_save_state(pre)
	_autosave_suspended = false
	_schedule_graph_autosave()


func is_sandbox_active() -> bool:
	return _sandbox_active


## Reset the canvas to an empty graph (sandbox only — levels re-seed on top).
func tutorial_clear_graph() -> void:
	apply_save_state({"graph": {"items": [], "connections": [], "scopes": {},
		"definitions": {}}}, {"sandbox": true})
	_dc_analysis = {}


## Spawn one level's seed items (+ optional pre-wires) into the sandbox graph.
## Returns the spawned item ids in seed order.
func tutorial_seed_level(seed: Array, seed_wires: Array = []) -> Array:
	var ids: Array = []
	if model == null:
		return ids
	for entry in seed:
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		var preset := TutorialCatalog.find_preset(str(e.get("preset_label", "")))
		if preset.is_empty():
			push_warning("tutorial_seed_level: unknown preset '%s'" % str(e.get("preset_label", "")))
			ids.append("")
			continue
		var specs: Dictionary = (preset.get("specs", {}) as Dictionary).duplicate(true)
		var dims := ComponentPresets.spawn_dimensions(preset)
		var item_id: String = model.generate_item_id()
		model.add_item({
			"id": item_id,
			"type": str(preset.get("type", "appliance")),
			"x": float(e.get("x", 0.0)), "y": float(e.get("y", 0.0)),
			"width": dims.x, "height": dims.y,
			"scope_id": "root",
			"specs": specs,
			"is_virtual": false,
		})
		ids.append(item_id)
	for w in seed_wires:
		if not (w is Dictionary):
			continue
		var wd: Dictionary = w
		var a := int(wd.get("from", -1))
		var b := int(wd.get("to", -1))
		if a < 0 or b < 0 or a >= ids.size() or b >= ids.size() \
				or str(ids[a]).is_empty() or str(ids[b]).is_empty():
			continue
		var from_handle := str(wd.get("from_handle", "positive"))
		var pol := "negative" if from_handle.to_lower().contains("neg") else "positive"
		model.add_connection({"scope_id": "root", "polarity": pol,
			"source_item_id": str(ids[a]), "source_handle_id": from_handle,
			"target_item_id": str(ids[b]), "target_handle_id": str(wd.get("to_handle", "negative"))})
	if _graph_canvas != null:
		_graph_canvas.call("queue_redraw")
	call_deferred("_check_electrical_faults")
	return ids


## Restrict the Library to the level's allowed presets (labels). Empty array =
## empty library for this level; call clear_tutorial_palette to lift.
func set_tutorial_palette(labels: Array) -> void:
	if _lib_panel == null:
		return
	var allowed: Dictionary = {}
	for l in labels:
		allowed[str(l)] = true
	_lib_panel.set("tutorial_preset_filter",
		func(preset: Dictionary) -> bool:
			return allowed.has(str(preset.get("label", ""))))
	if _lib_panel.has_method("refresh_gating"):
		_lib_panel.call("refresh_gating")


func clear_tutorial_palette() -> void:
	if _lib_panel == null:
		return
	_lib_panel.set("tutorial_preset_filter", Callable())
	if _lib_panel.has_method("refresh_gating"):
		_lib_panel.call("refresh_gating")


## Refresh library gating after a ProgressStore grant (unlocks).
func refresh_library_gating() -> void:
	if _lib_panel != null and _lib_panel.has_method("refresh_gating"):
		_lib_panel.call("refresh_gating")


## Present a tutorial brief/debrief through the shared fault-card modal.
func show_tutorial_card(card: Dictionary) -> void:
	if card.is_empty():
		return
	_ensure_fault_card_modal()
	_fault_card_modal.show_card(card)


func _ensure_tutorial_director() -> Node:
	if _tutorial_director != null and is_instance_valid(_tutorial_director):
		return _tutorial_director
	var script := load("res://gameplay/tutorial_director.gd") as GDScript
	if script == null:
		return null
	_tutorial_director = script.new()
	_tutorial_director.name = "TutorialDirector"
	add_child(_tutorial_director)
	if _tutorial_director.has_method("bind_graph_view"):
		_tutorial_director.call("bind_graph_view", self)
	return _tutorial_director


func _on_bootcamp_pressed() -> void:
	var director := _ensure_tutorial_director()
	if director != null and director.has_method("toggle"):
		director.call("toggle")


## First-load query: offer the bootcamp to brand-new players. Runs from the
## view's _ready (deferred poll) so no scene-shell (main.gd) wiring is needed;
## hard no-op headless, under CLI harness runs, and once answered.
func _maybe_show_tutorial_prompt(attempts_left: int = 120) -> void:
	if Engine.is_editor_hint() or DisplayServer.get_name() == "headless":
		return
	if not OS.get_cmdline_user_args().is_empty():
		return  # playtest-harness / capture run — never pop UI
	if not ProgressStore.is_new_player():
		return
	# Wait out the terrain-load overlay and the F1 first-run help.
	var ui_layer := get_parent()
	var loading := ui_layer != null and ui_layer.get_node_or_null("TerrainLoadOverlay") != null
	var help := ui_layer.get_node_or_null("HelpOverlayUI") if ui_layer != null else null
	var help_open := help != null and help is CanvasItem and (help as CanvasItem).visible
	if (loading or help_open) and attempts_left > 0:
		get_tree().create_timer(1.0).timeout.connect(
			_maybe_show_tutorial_prompt.bind(attempts_left - 1), CONNECT_ONE_SHOT)
		return
	var modal := TutorialIntroModal.new()
	modal.name = "TutorialIntroModal"
	if ui_layer != null:
		ui_layer.add_child(modal)
	else:
		add_child(modal)
	modal.start_requested.connect(func() -> void:
		refresh_library_gating()
		var director := _ensure_tutorial_director()
		if director != null and director.has_method("start"):
			director.call("start")
	)
	modal.skip_requested.connect(func() -> void:
		refresh_library_gating()
	)
	modal.open()



# ---------------------------------------------------------------------------
# Layout construction
# ---------------------------------------------------------------------------

func _build_layout() -> void:
	# Fullscreen dark background (rendered first = bottom of stack)
	var bg := ColorRect.new()
	bg.color        = C_BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor_full(bg)
	add_child(bg)
	_bg_rect = bg

	# Graph canvas (central area — drawn next so sidebars overlay it)
	var gc := Control.new()
	gc.name = "GraphCanvas"
	gc.set_script(_CANVAS_SCRIPT)
	add_child(gc)
	_graph_canvas = gc
	gc.set("resource_flow_engine", _resource_flow)
	_init_spatial_edit()
	# Connect canvas selection signals
	_connect_canvas_signals(gc)

	# Left sidebar
	_left_sidebar = _build_left_sidebar()
	add_child(_left_sidebar)

	# Left collapse tab (separate node, always visible)
	_left_toggle = _make_collapse_tab("◀", _on_left_toggle,
		CORNER_TOP_RIGHT, CORNER_BOTTOM_RIGHT)
	add_child(_left_toggle)

	# Right sidebar
	_right_sidebar = _build_right_sidebar()
	add_child(_right_sidebar)
	# Connect library / inspector panel signals after they're in the tree
	if _lib_panel != null and _lib_panel.has_signal("item_picked"):
		_lib_panel.connect("item_picked", _on_lib_item_picked)
	if _lib_panel != null and _lib_panel.has_signal("place_model_requested"):
		_lib_panel.connect("place_model_requested", _on_lib_place_model_requested)
	if _lib_panel != null and _lib_panel.has_signal("custom_component_created"):
		_lib_panel.connect("custom_component_created", _on_lib_custom_component_created)

	# Right collapse tab
	_right_toggle = _make_collapse_tab("▶", _on_right_toggle,
		CORNER_TOP_LEFT, CORNER_BOTTOM_LEFT)
	add_child(_right_toggle)

	# Topbar — added last so it renders on top of everything
	var topbar := _build_topbar()
	add_child(topbar)

	# Drag ghost — added absolutely last so it renders above everything
	_lib_ghost = _make_lib_ghost()
	add_child(_lib_ghost)

	_build_make_array_quick_button()

	_apply_layout()


func _connect_canvas_signals(gc: Node) -> void:
	if gc.has_signal("item_selected"):
		if not gc.is_connected("item_selected", _on_canvas_item_selected):
			gc.connect("item_selected", _on_canvas_item_selected)
	if gc.has_signal("item_double_tapped"):
		if not gc.is_connected("item_double_tapped", _on_canvas_item_double_tapped):
			gc.connect("item_double_tapped", _on_canvas_item_double_tapped)
	if gc.has_signal("items_multi_selected"):
		if not gc.is_connected("items_multi_selected", _on_canvas_items_multi_selected):
			gc.connect("items_multi_selected", _on_canvas_items_multi_selected)
	if gc.has_signal("connection_selected"):
		if not gc.is_connected("connection_selected", _on_canvas_connection_selected):
			gc.connect("connection_selected", _on_canvas_connection_selected)
	if gc.has_signal("compound_open_requested"):
		if not gc.is_connected("compound_open_requested", _on_open_compound_requested):
			gc.connect("compound_open_requested", _on_open_compound_requested)
	if gc.has_signal("scope_pop_requested"):
		if not gc.is_connected("scope_pop_requested", _on_scope_pop_requested):
			gc.connect("scope_pop_requested", _on_scope_pop_requested)
	if gc.has_signal("layout_changed"):
		if not gc.is_connected("layout_changed", _on_canvas_layout_changed):
			gc.connect("layout_changed", _on_canvas_layout_changed)
	if gc.has_signal("resource_containers_merged"):
		if not gc.is_connected("resource_containers_merged", _on_resource_containers_merged):
			gc.connect("resource_containers_merged", _on_resource_containers_merged)
	if gc.has_signal("controller_reset_pressed"):
		if not gc.is_connected("controller_reset_pressed", _on_controller_reset_pressed):
			gc.connect("controller_reset_pressed", _on_controller_reset_pressed)
	if gc.has_signal("site_background_clicked"):
		if not gc.is_connected("site_background_clicked", _on_site_background_clicked):
			gc.connect("site_background_clicked", _on_site_background_clicked)
	if gc.has_signal("elevation_heading_changed"):
		if not gc.is_connected("elevation_heading_changed", _on_elevation_heading_changed):
			gc.connect("elevation_heading_changed", _on_elevation_heading_changed)
	if gc.has_signal("elevation_section_offset_changed"):
		if not gc.is_connected("elevation_section_offset_changed",
				_on_elevation_section_offset_changed):
			gc.connect("elevation_section_offset_changed",
					_on_elevation_section_offset_changed)


func _on_canvas_layout_changed() -> void:
	_autosave_pending = true
	_flush_graph_autosave()
	if _graph_view_mode == GraphSiteLayout.VIEW_SITE \
			or _graph_view_mode == GraphSiteLayout.VIEW_ELEVATION:
		_sync_bound_props_from_site()
		# Site Plan: restamp ground Y after XZ moves. Elevation view lets the
		# user drag vertically into elevation_m — do not clobber that here.
		if _graph_view_mode == GraphSiteLayout.VIEW_SITE:
			_refresh_item_elevations()
			_refresh_site_autoroutes()


## After a site-plan drag, move any bound 3D props to match site_x_m/site_z_m.
## Skips props already within tolerance (move_prop_xz respawns the whole prop
## layer, so an unconditional per-node move made every drag-end O(props²) and
## re-grounded props that never moved). A binding whose prop record no longer
## exists (deleted before twin-delete linking existed, or a different save) is
## cleared and surfaced instead of failing silently forever.
const _SITE_SYNC_EPS_M := 0.05

func _sync_bound_props_from_site() -> void:
	if model == null:
		return
	var main := _get_scene_main_node()
	var soi := get_node_or_null("/root/SoiService")
	if main == null or soi == null or not soi.has_method("world_center"):
		return
	var center: Vector3 = soi.call("world_center")
	var stale: Array[String] = []
	for item: Dictionary in model.items:
		if not GraphSiteLayout.has_site_coords(item):
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		var prop_id := str(specs.get("bound_prop_id", ""))
		if prop_id.is_empty():
			continue
		var wxz := GraphSiteLayout.site_to_world_xz(GraphSiteLayout.site_xz(item), center)
		var rec := PlacedPropService.get_prop_record(main, prop_id)
		if rec.is_empty():
			stale.append(str(item.get("id", "")))
			continue
		if Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0))) \
				.distance_to(wxz) <= _SITE_SYNC_EPS_M:
			continue
		# Radial layout: auto-yaw the twin tangential to the circle around the
		# SoI center (model faces outward, width along the tangent) so radially
		# planned sites don't need per-model yaw fiddling. Yaw is patched into
		# the record BEFORE move_prop_xz — its rebuild applies both at once.
		if _graph_canvas != null and bool(_graph_canvas.get("radial_layout_mode")):
			var site := GraphSiteLayout.site_xz(item)
			var c_site := Vector2.ZERO
			if _spatial_edit != null:
				c_site = _spatial_edit.radial_center_site()
			var yaw := _spatial_radial_yaw_deg(site, c_site)
			PlacedPropService.update_prop_record(main, prop_id, {"yaw": yaw}, false)
		PlacedPropService.move_prop_xz(main, prop_id, wxz.x, wxz.y)
	for iid in stale:
		var it := model.get_item(iid)
		if it.is_empty():
			continue
		var sp: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
		sp.erase("bound_prop_id")
		model.update_item(iid, {"specs": sp})
	if not stale.is_empty():
		_show_toast("Unlinked %d node%s whose 3D twin no longer exists" % [
			stale.size(), "" if stale.size() == 1 else "s"])


## True when this item should auto-get a visible 3D twin at site coords.
func _item_wants_site_twin(item: Dictionary) -> bool:
	if item.is_empty() or not GraphSiteLayout.has_site_coords(item):
		return false
	if bool(item.get("is_ghost", false)):
		return false
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	# Already embodied via scene path — leave alone.
	if not str(specs.get("scene_device_path", specs.get("device_path", ""))).is_empty():
		return false
	# Explicit model_id always wants a twin at site coords.
	if not str(specs.get("model_id", "")).is_empty():
		return true
	var itype := str(item.get("type", ""))
	# Containers + physical plant that commonly need embodiment on Site Plan.
	# Nested children (panels inside StarShade, etc.) are filtered by callers
	# to root scope so we don't stamp a twin per leaf.
	if itype in [
		"resource", "catchment", "compound",
		"habitat", "processor", "wind", "hydro", "heliostat",
		"biodigester", "cartesian_machine", "pp_beam_extruder",
	]:
		return true
	return false


## Ensure a site-placed container/compound has a grounded PlacedProp twin.
## Uses generic_tank / generic_box when model_id is empty. Returns true on
## create/move success.
func ensure_site_twin(item_id: String, quiet: bool = true) -> bool:
	if model == null or item_id.is_empty():
		return false
	var item := model.get_item(item_id)
	if not _item_wants_site_twin(item):
		return false
	var main := _get_scene_main_node()
	var soi := get_node_or_null("/root/SoiService")
	if main == null or soi == null or not soi.has_method("world_center"):
		if not quiet:
			_show_toast("No map / SoI center available")
		return false
	var center: Vector3 = soi.call("world_center")
	var wxz := GraphSiteLayout.site_to_world_xz(GraphSiteLayout.site_xz(item), center)
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var model_id := ModelCatalog.default_twin_model_id(item)
	var box_spec := ModelCatalog.twin_box_spec_for_item(item)
	var existing := str(specs.get("bound_prop_id", ""))
	if not existing.is_empty():
		var rec := PlacedPropService.get_prop_record(main, existing)
		if not rec.is_empty():
			if Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0))) \
					.distance_to(wxz) > _SITE_SYNC_EPS_M:
				PlacedPropService.move_prop_xz(main, existing, wxz.x, wxz.y)
			if str(specs.get("model_id", "")).is_empty():
				specs["model_id"] = model_id
				model.update_item(item_id, {"specs": specs})
			return true
		specs.erase("bound_prop_id")
	var extra := {
		"graph_item_id": item_id,
		"box_spec": box_spec,
	}
	if model_id == ModelCatalog.GENERIC_TANK_ID:
		extra["tank_spec"] = box_spec
	var ports := ConnectionPortDefs.default_ports_for_model(model_id, box_spec)
	if not ports.is_empty():
		extra["connection_ports"] = ports
	var result := PlacedPropService.place_model_at_xz(main, model_id, wxz.x, wxz.y, extra)
	if not bool(result.get("ok", false)):
		if not quiet:
			_show_toast("Place failed: %s" % str(result.get("error", "?")))
		return false
	specs["model_id"] = model_id
	specs["bound_prop_id"] = str(result.get("prop_id", ""))
	if float(specs.get("footprint_w_m", 0.0)) <= 0.0 \
			or float(specs.get("footprint_d_m", 0.0)) <= 0.0:
		specs["footprint_w_m"] = float(box_spec.get("w_m", 1.0))
		specs["footprint_d_m"] = float(box_spec.get("d_m", 1.0))
	model.update_item(item_id, {"specs": specs})
	return true


## Auto-embody every root-scope site-placed item that lacks a twin.
func ensure_all_site_twins() -> int:
	if model == null:
		return 0
	# Refuse until TerrainLoader owns a prop layer — placing into the
	# PlacedPropService fallback layer can overwrite the map props file.
	var main0 := _get_scene_main_node()
	var loader0 := TerrainSurfaceQuery.find_terrain_loader(main0) if main0 != null else null
	if loader0 == null or loader0.get("_placed_prop_layer") == null:
		return 0
	var n := 0
	var root_items: Array = model.get_items_in_scope("root") \
			if model.has_method("get_items_in_scope") else model.items
	for item_v in root_items:
		if not (item_v is Dictionary):
			continue
		var item: Dictionary = item_v
		var iid := str(item.get("id", ""))
		if iid.is_empty():
			continue
		if not _item_wants_site_twin(item):
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		var prop_id := str(specs.get("bound_prop_id", ""))
		var needs := prop_id.is_empty()
		if not needs:
			var main := _get_scene_main_node()
			if main != null and PlacedPropService.get_prop_record(main, prop_id).is_empty():
				needs = true
		if needs and ensure_site_twin(iid, true):
			n += 1
	return n


## Place (or re-place) a graph node's GLB / procedural twin at its site coords.
## Hide / show a node's bound 3D twin from the world (and Site Plan). Persists on
## the prop record; a hidden twin also drops out of Site Plan (see graph_canvas
## _item_has_visible_twin). Reachable from the graph even when the prop is hidden
## (you can't click an invisible prop in first-person to un-hide it).
func set_node_3d_hidden(item_id: String, hidden: bool) -> void:
	var pid := _bound_prop_id_for_item(item_id)
	if pid.is_empty():
		return
	var loader := _find_terrain_loader(_get_scene_main_node())
	if loader != null and loader.has_method("update_prop_record"):
		loader.call("update_prop_record", pid, {"hidden_3d": hidden})
		_graph_canvas.queue_redraw() if _graph_canvas != null else null


func is_node_3d_hidden(item_id: String) -> bool:
	var pid := _bound_prop_id_for_item(item_id)
	if pid.is_empty():
		return false
	var loader := _find_terrain_loader(_get_scene_main_node())
	if loader != null and loader.has_method("get_prop_record"):
		return bool((loader.call("get_prop_record", pid) as Dictionary).get("hidden_3d", false))
	return false


## Bulk hide/show all generic placeholder twins (generic_box/tank) from 3D + Site Plan.
func hide_all_placeholder_twins(hidden: bool) -> void:
	var loader := _find_terrain_loader(_get_scene_main_node())
	if loader == null or not loader.has_method("set_placeholder_twins_hidden"):
		return
	var n := int(loader.call("set_placeholder_twins_hidden", hidden))
	_show_toast(("Hid %d placeholder twin(s)" if hidden else "Showed %d placeholder twin(s)") % n)
	if _graph_canvas != null:
		_graph_canvas.queue_redraw()


func _bound_prop_id_for_item(item_id: String) -> String:
	if model == null or item_id.is_empty():
		return ""
	var item := model.get_item(item_id)
	if item.is_empty():
		return ""
	return str((item.get("specs", {}) as Dictionary).get("bound_prop_id", ""))


func place_site_twin(item_id: String) -> void:
	if model == null or item_id.is_empty():
		return
	var item := model.get_item(item_id)
	if item.is_empty():
		return
	if not GraphSiteLayout.has_site_coords(item):
		_show_toast("Assign a Site Plan position first (drag onto the SoI disc)")
		return
	var had_prop := not str((item.get("specs", {}) as Dictionary) \
			.get("bound_prop_id", "")).is_empty()
	# Containers / catchments / compounds: auto procedural twin.
	if _item_wants_site_twin(item):
		if not ensure_site_twin(item_id, false):
			return
		_refresh_item_elevations()
		_refresh_site_autoroutes()
		_schedule_graph_autosave()
		_show_toast("Moved 3D twin to site position" if had_prop \
				else "Placed 3D twin at ground level")
		return
	# Other types still require an explicit model_id.
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var model_id := str(specs.get("model_id", ""))
	if model_id.is_empty():
		_show_toast("Attach a GLB model_id in Place in 3D first")
		return
	var main := _get_scene_main_node()
	var soi := get_node_or_null("/root/SoiService")
	if main == null or soi == null or not soi.has_method("world_center"):
		_show_toast("No map / SoI center available")
		return
	var center: Vector3 = soi.call("world_center")
	var wxz := GraphSiteLayout.site_to_world_xz(GraphSiteLayout.site_xz(item), center)
	var existing := str(specs.get("bound_prop_id", ""))
	if not existing.is_empty():
		if PlacedPropService.move_prop_xz(main, existing, wxz.x, wxz.y):
			_show_toast("Moved 3D twin to site position")
			_refresh_item_elevations()
			_refresh_site_autoroutes()
			return
	var result := PlacedPropService.place_model_at_xz(main, model_id, wxz.x, wxz.y, {
		"graph_item_id": item_id,
	})
	if not bool(result.get("ok", false)):
		_show_toast("Place failed: %s" % str(result.get("error", "?")))
		return
	specs["bound_prop_id"] = str(result.get("prop_id", ""))
	if float(specs.get("footprint_w_m", 0.0)) <= 0.0 \
			or float(specs.get("footprint_d_m", 0.0)) <= 0.0:
		var fp := PlacedPropService.footprint_from_model(model_id, 1.0)
		if fp.x > 0.0 and fp.y > 0.0:
			specs["footprint_w_m"] = fp.x
			specs["footprint_d_m"] = fp.y
	model.update_item(item_id, {"specs": specs})
	_show_toast("Placed 3D twin at ground level")
	_refresh_item_elevations()
	_refresh_site_autoroutes()
	_schedule_graph_autosave()


func _on_resource_containers_merged(target_id: String, _absorbed_id: String, kind: String) -> void:
	var label := ResourceKinds.display_name(kind)
	_show_toast("Merged %s containers" % label)
	# Keep existing placed twin if any; do not auto-embody a gray-box tank.
	if not target_id.is_empty():
		var item := model.get_item(target_id) if model != null else {}
		var prop_id := str((item.get("specs", {}) as Dictionary).get("bound_prop_id", ""))
		if not prop_id.is_empty():
			ensure_site_twin(target_id, true)
	if _resource_flow != null and _resource_flow.has_method("clear_timelines"):
		_resource_flow.call("clear_timelines")
	if _graph_canvas != null:
		_graph_canvas.call("queue_redraw")


func _apply_layout() -> void:
	var left_w  := SIDEBAR_L_W if _sidebar_l_open else 0.0
	var right_w := SIDEBAR_R_W if _sidebar_r_open else 0.0
	var siphon_dock := _graph_view_mode == GraphSiteLayout.VIEW_SIPHON
	# Phase 2 Hydro Lab is a full-bleed overlay — don't reserve SIPHON_LAB_W or
	# leave the left telemetry dock stealing CT width.
	if siphon_dock:
		left_w = 0.0
		right_w = 0.0
	var timeline_inset := _timeline_bottom_inset()

	# Left sidebar — stop above the timeline bar so its items are never hidden
	if _left_sidebar:
		_left_sidebar.visible = _sidebar_l_open and not siphon_dock
		_anchor(_left_sidebar,
			0.0, 0.0, 0.0, 1.0,
			0.0, TOPBAR_H, SIDEBAR_L_W, -timeline_inset)

	# Left collapse tab: immediately right of sidebar's right edge
	if _left_toggle:
		_left_toggle.visible = not siphon_dock
		_anchor(_left_toggle,
			0.0, 0.5, 0.0, 0.5,
			left_w, -20.0, left_w + TOGGLE_W, 20.0)
		_left_toggle.text = "◀" if _sidebar_l_open else "▶"

	# Right sidebar — stop above the timeline bar
	if _right_sidebar:
		_right_sidebar.visible = _sidebar_r_open and not siphon_dock
		_anchor(_right_sidebar,
			1.0, 0.0, 1.0, 1.0,
			-SIDEBAR_R_W, TOPBAR_H, 0.0, -timeline_inset)

	# Right collapse tab: immediately left of sidebar's left edge
	if _right_toggle:
		_right_toggle.visible = not siphon_dock
		_anchor(_right_toggle,
			1.0, 0.5, 1.0, 0.5,
			-(right_w + TOGGLE_W), -20.0, -right_w, 20.0)
		_right_toggle.text = "▶" if _sidebar_r_open else "◀"

	# Graph canvas fills the remaining space between sidebars, below topbar,
	# above the timeline bar (and history panel, when visible).
	var bottom_offset: float = timeline_inset
	if _history_panel != null and is_instance_valid(_history_panel) \
			and _history_panel.visible:
		bottom_offset += HISTORY_PANEL_H
	if _graph_canvas:
		_anchor(_graph_canvas,
			0.0, 0.0, 1.0, 1.0,
			left_w, TOPBAR_H, -right_w, -bottom_offset)
		# Keep model reference in sync whenever layout is re-applied
		_graph_canvas.set("model", model)
		_graph_canvas.set("active_scope_id", _active_scope_id)
	if _siphon_lab_modal != null and is_instance_valid(_siphon_lab_modal):
		_apply_siphon_lab_layout()
	if _soi_preview != null and _soi_preview.has_method("mark_layout_dirty"):
		_soi_preview.call("mark_layout_dirty")
	_layout_history_panel()
	_update_scope_breadcrumb()


# ---------------------------------------------------------------------------
# Top bar
# ---------------------------------------------------------------------------

func _build_topbar() -> Control:
	var bar := Control.new()
	bar.name         = "TopBar"
	bar.mouse_filter = Control.MOUSE_FILTER_STOP
	_anchor(bar, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, TOPBAR_H)

	# Dark gradient background
	var bg := ColorRect.new()
	bg.color        = Color(0.055, 0.075, 0.140, 1.0)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor_full(bg)
	bar.add_child(bg)

	# Glow bottom border line (2 px)
	var glow_line := ColorRect.new()
	glow_line.color        = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.38)
	glow_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor(glow_line, 0.0, 1.0, 1.0, 1.0, 0.0, -2.0, 0.0, 0.0)
	bar.add_child(glow_line)

	var margin := MarginContainer.new()
	_anchor_full(margin)
	margin.add_theme_constant_override("margin_left",   8)
	margin.add_theme_constant_override("margin_right",  8)
	margin.add_theme_constant_override("margin_top",    7)
	margin.add_theme_constant_override("margin_bottom", 7)
	bar.add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 5)
	margin.add_child(hbox)

	# ── LEFT: edit controls ────────────────────────────────────────────────
	var left_grp := HBoxContainer.new()
	left_grp.add_theme_constant_override("separation", 4)
	left_grp.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	hbox.add_child(left_grp)

	_undo_btn = _make_topbar_btn("↶")
	_redo_btn = _make_topbar_btn("↷")
	var reset_btn  := _make_topbar_btn("Reset")
	var sysrev_btn := _make_topbar_btn("⚡ Review")
	var challenge_btn := _make_topbar_btn("🎯")
	_undo_btn.tooltip_text = "Undo  (Ctrl+Z)"
	_redo_btn.tooltip_text = "Redo  (Ctrl+Y)"
	_undo_btn.pressed.connect(_do_undo)
	_redo_btn.pressed.connect(_do_redo)
	reset_btn.pressed.connect(_confirm_reset_graph)
	reset_btn.tooltip_text = "Reset this map's graph (asks first — not undoable)"
	sysrev_btn.pressed.connect(_on_system_review)
	challenge_btn.tooltip_text = "Challenges — structured survival missions"
	challenge_btn.pressed.connect(_on_challenge_pressed)
	var bootcamp_btn := _make_topbar_btn("🎓")
	bootcamp_btn.tooltip_text = "Solar Bootcamp — learn the graph from the battery up"
	bootcamp_btn.pressed.connect(_on_bootcamp_pressed)
	for b: Button in [_undo_btn, _redo_btn, reset_btn, sysrev_btn, challenge_btn, bootcamp_btn]:
		left_grp.add_child(b)
	_update_undo_redo_btns()

	var sep1 := VSeparator.new()
	sep1.add_theme_color_override("color", Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.38))
	sep1.add_theme_constant_override("separation", 8)
	left_grp.add_child(sep1)

	# Combine ▾ — grouping / compound / wiring (layout lives in Layout ▾).
	_combine_menu = _make_topbar_menu_btn("Combine ▾")
	_combine_menu.tooltip_text = "Group, arrays, banks, series/parallel wiring"
	var cp := _combine_menu.get_popup()
	cp.add_item("Group into super-node", COMBINE_GROUP)
	cp.add_item("Ungroup generic group", COMBINE_UNGROUP)
	cp.add_item("Explode compound…", COMBINE_EXPLODE)
	cp.add_separator()
	cp.add_item("Make Solar Array", COMBINE_ARRAY)
	cp.add_item("Make Battery Bank", COMBINE_BANK)
	cp.add_separator()
	cp.add_item("Wire panels in Series", COMBINE_SERIES)
	cp.add_item("Wire panels in Parallel", COMBINE_PARALLEL)
	cp.add_item("Pick controller for array…", COMBINE_CTRL_PICKER)
	cp.id_pressed.connect(_on_combine_menu_id)
	left_grp.add_child(_combine_menu)

	_layout_menu = _make_topbar_menu_btn("Layout ▾")
	_layout_menu.tooltip_text = (
			"Auto-arrange the active scope (and nested super-nodes) · "
			+ "spawn a gray-box 3D placeholder for the selection")
	var lp := _layout_menu.get_popup()
	lp.add_item("Arrange layout", LAYOUT_ARRANGE)
	lp.add_item("Spawn 3D placeholder", LAYOUT_PLACEHOLDER)
	lp.id_pressed.connect(_on_layout_menu_id)
	left_grp.add_child(_layout_menu)

	_enter_btn = _make_topbar_btn("▸ Expand")
	_back_btn  = _make_topbar_btn("◂ Collapse")
	_enter_btn.tooltip_text = "Open the selected super-node (keeps StarShade / component identity + 3D binding)"
	_back_btn.tooltip_text = "Collapse back to the parent super-node (Esc)"
	_enter_btn.pressed.connect(_on_enter_selected_compound)
	_back_btn.pressed.connect(_on_back_scope_pressed)
	var sep_nav := VSeparator.new()
	sep_nav.add_theme_color_override("color", Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.38))
	left_grp.add_child(sep_nav)
	left_grp.add_child(_enter_btn)
	left_grp.add_child(_back_btn)
	_update_special_group_buttons()

	# ── CENTER: flexible fill ──────────────────────────────────────────────
	hbox.add_child(_hspacer())

	# ── RIGHT: utility controls + breadcrumb ───────────────────────────────
	var right_grp := HBoxContainer.new()
	right_grp.add_theme_constant_override("separation", 4)
	right_grp.size_flags_horizontal = Control.SIZE_SHRINK_END
	right_grp.alignment = BoxContainer.ALIGNMENT_END
	hbox.add_child(right_grp)

	_scope_breadcrumb = HBoxContainer.new()
	_scope_breadcrumb.add_theme_constant_override("separation", 1)
	_scope_breadcrumb.alignment = BoxContainer.ALIGNMENT_END
	right_grp.add_child(_scope_breadcrumb)
	_update_scope_breadcrumb()

	_soi_chip = Label.new()
	_soi_chip.add_theme_color_override("font_color", C_PRIMARY)
	_soi_chip.add_theme_font_size_override("font_size", 12)
	_soi_chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_soi_chip.text = "SoI · —"
	_soi_chip.tooltip_text = "Sphere of Influence — Interact with the map pin (O) to open Snowglobe and resize"
	right_grp.add_child(_soi_chip)

	var sep2 := VSeparator.new()
	sep2.add_theme_color_override("color", Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.38))
	sep2.add_theme_constant_override("separation", 8)
	right_grp.add_child(sep2)

	# ── Graph view mode: Freeform / Site Plan / Elevation / Snowglobe ──
	# The Hydro Lab is deliberately NOT a chip: it is item-bound (opened from a
	# hydro turbine's inspector / double-click / 3D prop menu), and a chip entry
	# carried no item id — with no turbine on the graph it opened a useless
	# empty full-screen view.
	_mode_chip_row = HBoxContainer.new()
	_mode_chip_row.add_theme_constant_override("separation", 4)
	_mode_chip_row.tooltip_text = "Graph / SoI view mode"
	for pair in [
		["freeform", "Freeform"],
		["site", "Site Plan"],
		["elevation", "Elevation"],
		["snowglobe", "Snowglobe"],
	]:
		var b := _make_mode_chip(str(pair[0]), str(pair[1]))
		_mode_chip_row.add_child(b)
		_mode_chip_btns[str(pair[0])] = b
	right_grp.add_child(_mode_chip_row)

	_designate_menu = _make_topbar_menu_btn("Designate ▾")
	_designate_menu.tooltip_text = (
			"Site Plan: click an empty roof or field on the SoI disc to import "
			+ "it as a catchment or crop bed (mirrors OSM solar add).")
	var dp := _designate_menu.get_popup()
	dp.add_radio_check_item("Off", DESIGNATE_OFF)
	dp.add_radio_check_item("Catchment (roof)", DESIGNATE_CATCHMENT)
	dp.add_radio_check_item("Crop (field)", DESIGNATE_CROP)
	dp.id_pressed.connect(_on_designate_menu_id)
	dp.set_item_checked(dp.get_item_index(DESIGNATE_OFF), true)
	right_grp.add_child(_designate_menu)

	# Mode SWITCHING lives only in the chip strip above — this menu holds the
	# per-view extras (duplicating the modes here made three different ways to
	# say the same thing across the topbar).
	_view_mode_menu = _make_topbar_menu_btn("View options ▾")
	_view_mode_menu.tooltip_text = (
		"Extras for the active view.\n"
		+ "SoI bubble (freeform): snowglobe behind nodes — Shift+drag orbit, Shift+scroll zoom.\n"
		+ "Site Plan: starts top-down; Shift+drag orbits (yaw/tilt); scroll zooms 2D+3D.\n"
		+ "Elevation CT: side-on half-cutaway; Shift+drag rotate/depth; "
		+ "Shift+wheel zoom cut; Slice depth slider; Reset section.\n"
		+ "Hydro Lab: hydro detail panel (module height, start/break, RPM) — SoI preview off.")
	# The flat ~30-item popup accreted per feature; it is now grouped into
	# per-view submenus. Every VIEW_MODE_* id is UNCHANGED (ui_compile_selftest
	# pins uniqueness, autosaved prefs key off the ids) and every submenu's
	# id_pressed routes to the same _on_view_mode_menu_id handler — only the
	# geometry of the menu changed. Sync code goes through _vm_set_* helpers,
	# which search the root + submenus for the popup holding an id.
	var vmp := _view_mode_menu.get_popup()
	_view_mode_subpopups.clear()
	vmp.add_check_item("SoI bubble (freeform)", VIEW_MODE_SOI_BUBBLE)
	vmp.add_check_item("Node cards (no 3D previews)", VIEW_MODE_NODE_CARDS)
	vmp.add_check_item("Preview node labels", VIEW_MODE_PREVIEW_LABELS)

	var site_sub := PopupMenu.new()
	site_sub.add_check_item("Radial layout (auto-yaw)", VIEW_MODE_RADIAL)
	site_sub.add_check_item("Magnifier labels", VIEW_MODE_SITE_CHIPS)
	site_sub.add_check_item("Ports", VIEW_MODE_SITE_PORTS)
	site_sub.add_separator("Wires")
	site_sub.add_radio_check_item("3D conduits", VIEW_MODE_SITE_WIRE_3D)
	site_sub.add_radio_check_item("Metro 2D overlay", VIEW_MODE_SITE_WIRE_METRO)
	site_sub.add_radio_check_item("None (overlay)", VIEW_MODE_SITE_WIRE_NONE)
	site_sub.add_separator()
	site_sub.add_item("Seed site from freeform…", VIEW_MODE_SEED_SITE)
	site_sub.add_item("Embody missing Site twins…", VIEW_MODE_EMBODY_TWINS)
	_add_view_mode_submenu(vmp, "Site Plan", site_sub)

	var elev_sub := PopupMenu.new()
	elev_sub.add_check_item("3D snowglobe section", VIEW_MODE_ELEV_3D)
	elev_sub.add_separator("Overlays")
	elev_sub.add_check_item("DEM / pond 2D overlay", VIEW_MODE_ELEV_DEM)
	elev_sub.add_check_item("Chips (labels/bodies)", VIEW_MODE_ELEV_CHIPS)
	elev_sub.add_check_item("Ports", VIEW_MODE_ELEV_PORTS)
	elev_sub.add_check_item("Schematic 2D wires", VIEW_MODE_ELEV_SCHEM_WIRES)
	elev_sub.add_check_item("Projected 2D pipe overlay", VIEW_MODE_ELEV_PROJ_PIPES)
	elev_sub.add_separator()
	elev_sub.add_check_item("Live lighting (follow sim clock)", VIEW_MODE_SITE_LIVE_LIGHT)
	elev_sub.add_separator()
	elev_sub.add_radio_check_item("Scale 1× (3D section locks to 1×)", VIEW_MODE_EXAG_1X)
	elev_sub.add_radio_check_item("Scale 5× (2D-only Elev)", VIEW_MODE_EXAG_5X)
	elev_sub.add_item("Rotate section heading +15°", VIEW_MODE_HEADING_ROTATE)
	elev_sub.add_item("Reset section (N/S · slice 0 · zoom fit)", VIEW_MODE_RESET_SECTION)
	_add_view_mode_submenu(vmp, "Elevation", elev_sub)

	var people_sub := PopupMenu.new()
	people_sub.add_check_item("Show worn paths", VIEW_MODE_DESIRE_LINES)
	people_sub.add_check_item("Show live trails", VIEW_MODE_DESIRE_TRAILS)
	people_sub.add_item("Filter: all traffic", VIEW_MODE_DESIRE_CHANNEL)
	people_sub.add_item("Remember: past week", VIEW_MODE_DESIRE_WINDOW)
	people_sub.add_check_item("Drape worn paths in the 3D world", VIEW_MODE_DESIRE_3D)
	people_sub.add_item("Reset desire lines", VIEW_MODE_DESIRE_RESET)
	_add_view_mode_submenu(vmp, "People & paths", people_sub)

	vmp.id_pressed.connect(_on_view_mode_menu_id)
	_vm_set_checked(VIEW_MODE_EXAG_5X, true)
	_vm_set_checked(VIEW_MODE_ELEV_3D, _elevation_3d_section)
	_vm_set_checked(VIEW_MODE_ELEV_DEM, true)
	_vm_set_checked(VIEW_MODE_ELEV_CHIPS, false)
	_vm_set_checked(VIEW_MODE_ELEV_PORTS, true)
	_vm_set_checked(VIEW_MODE_ELEV_SCHEM_WIRES, false)
	_vm_set_checked(VIEW_MODE_ELEV_PROJ_PIPES, false)
	_vm_set_checked(VIEW_MODE_SITE_PORTS, true)
	right_grp.add_child(_view_mode_menu)

	_elev_slice_row = HBoxContainer.new()
	_elev_slice_row.add_theme_constant_override("separation", 6)
	_elev_slice_row.visible = false
	var slice_cap := Label.new()
	slice_cap.text = "Slice"
	slice_cap.add_theme_font_size_override("font_size", 11)
	slice_cap.add_theme_color_override("font_color", Color(C_TEXT.r, C_TEXT.g, C_TEXT.b, 0.85))
	_elev_slice_row.add_child(slice_cap)
	_elev_slice_slider = HSlider.new()
	_elev_slice_slider.custom_minimum_size = Vector2(120, 22)
	_elev_slice_slider.min_value = -150.0
	_elev_slice_slider.max_value = 150.0
	_elev_slice_slider.step = 1.0
	_elev_slice_slider.value = 0.0
	_elev_slice_slider.tooltip_text = "CT slice depth (−R…+R metres along the cut normal)"
	_elev_slice_slider.value_changed.connect(_on_elev_slice_slider_changed)
	_elev_slice_row.add_child(_elev_slice_slider)
	_elev_slice_lbl = Label.new()
	_elev_slice_lbl.text = "0 m"
	_elev_slice_lbl.custom_minimum_size = Vector2(44, 0)
	_elev_slice_lbl.add_theme_font_size_override("font_size", 11)
	_elev_slice_row.add_child(_elev_slice_lbl)
	right_grp.add_child(_elev_slice_row)

	_hydro_section_lbl = Label.new()
	_hydro_section_lbl.visible = false
	_hydro_section_lbl.add_theme_font_size_override("font_size", 11)
	_hydro_section_lbl.add_theme_color_override("font_color",
			Color(0.75, 0.9, 1.0, 0.95))
	_hydro_section_lbl.tooltip_text = (
			"Hydro Section: live stage-discharge ΣQ and PE/generation from "
			+ "pond level + culvert inverts (Elevation view)")
	right_grp.add_child(_hydro_section_lbl)

	_elev_hydro_lab_btn = Button.new()
	_elev_hydro_lab_btn.text = "Hydro Lab…"
	_elev_hydro_lab_btn.visible = false
	_elev_hydro_lab_btn.focus_mode = Control.FOCUS_NONE
	_elev_hydro_lab_btn.tooltip_text = (
			"Open Hydro Lab deep-dive for the nearest siphon / penstock "
			+ "(Elevation stays the primary hydro CT).")
	_apply_topbar_btn_style(_elev_hydro_lab_btn)
	_elev_hydro_lab_btn.pressed.connect(_on_elev_open_hydro_lab_pressed)
	right_grp.add_child(_elev_hydro_lab_btn)

	# Site Plan camp tools — Radial / Array / working radius (visible dock).
	_site_tool_row = HBoxContainer.new()
	_site_tool_row.add_theme_constant_override("separation", 6)
	_site_tool_row.visible = false
	_site_radial_btn = Button.new()
	_site_radial_btn.text = "Radial"
	_site_radial_btn.toggle_mode = true
	_site_radial_btn.focus_mode = Control.FOCUS_NONE
	_site_radial_btn.tooltip_text = (
			"Radial camp layout: auto-yaw on move + bold working-radius guide. "
			+ "Shift+drag a prop to face the tangent (SoI size unchanged).")
	_apply_topbar_btn_style(_site_radial_btn)
	_site_radial_btn.toggled.connect(_on_site_radial_toggled)
	_site_tool_row.add_child(_site_radial_btn)
	_site_array_menu = _make_topbar_menu_btn("Array ▾")
	_site_array_menu.tooltip_text = (
			"Duplicate the selected 3D prop in a Line, Arc, or Circle using "
			+ "the working radius (default = SoI R).")
	var ap := _site_array_menu.get_popup()
	ap.add_item("Array: Line…", SITE_ARRAY_LINE)
	ap.add_item("Array: Arc…", SITE_ARRAY_ARC)
	ap.add_item("Array: Circle…", SITE_ARRAY_CIRCLE)
	ap.add_separator()
	ap.add_item("Confirm array", SITE_ARRAY_CONFIRM)
	ap.add_item("Cancel array", SITE_ARRAY_CANCEL)
	ap.add_separator()
	ap.add_item("Set array center…", SITE_ARRAY_SET_CENTER)
	ap.add_item("Clear custom center", SITE_ARRAY_CLEAR_CENTER)
	ap.add_item("Reset R to SoI", SITE_RADIUS_RESET)
	ap.id_pressed.connect(_on_site_array_menu_id)
	_site_tool_row.add_child(_site_array_menu)
	var r_cap := Label.new()
	r_cap.text = "R"
	r_cap.add_theme_font_size_override("font_size", 11)
	_site_tool_row.add_child(r_cap)
	_site_radius_slider = HSlider.new()
	_site_radius_slider.custom_minimum_size = Vector2(100, 22)
	_site_radius_slider.min_value = 5.0
	_site_radius_slider.max_value = 200.0
	_site_radius_slider.step = 1.0
	_site_radius_slider.value = 50.0
	_site_radius_slider.tooltip_text = "Working radius (m) — brush-style; does not resize SoI"
	_site_radius_slider.value_changed.connect(_on_site_working_radius_changed)
	_site_tool_row.add_child(_site_radius_slider)
	_site_radius_lbl = Label.new()
	_site_radius_lbl.text = "50 m"
	_site_radius_lbl.custom_minimum_size = Vector2(40, 0)
	_site_radius_lbl.add_theme_font_size_override("font_size", 11)
	_site_tool_row.add_child(_site_radius_lbl)
	right_grp.add_child(_site_tool_row)

	var sep3 := VSeparator.new()
	sep3.add_theme_color_override("color", Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.38))
	sep3.add_theme_constant_override("separation", 8)
	right_grp.add_child(sep3)

	# ── Wire style ▾ — global override (Bezier / Rounded / Metro) + Apply to all ─
	_wire_style_menu = _make_topbar_menu_btn("Wire ▾")
	_wire_style_menu.tooltip_text = (
			"Global wire style override for every connection (view-only, "
			+ "reversible).\n\"Apply to all\" bakes the current style into the "
			+ "model and clears the override.")
	var wsp := _wire_style_menu.get_popup()
	wsp.add_radio_check_item("Bezier (curved)", WIRE_STYLE_BEZIER)
	wsp.add_radio_check_item("Rounded (orthogonal)", WIRE_STYLE_ROUNDED)
	wsp.add_radio_check_item("Metro (45°)", WIRE_STYLE_METRO)
	wsp.add_separator()
	wsp.add_item("Apply to all connections", WIRE_STYLE_APPLY_ALL)
	wsp.id_pressed.connect(_on_wire_style_menu_id)
	right_grp.add_child(_wire_style_menu)
	_sync_wire_style_menu_checks()

	# View ▾ — Legend / History / Hints consolidated (was three buttons).
	_view_menu = _make_topbar_menu_btn("View ▾")
	_view_menu.tooltip_text = "Legend, history playback, pinned PBI bar, hints"
	var vp := _view_menu.get_popup()
	vp.add_check_item("Wire-color legend", VIEW_LEGEND)
	vp.add_check_item("🕒 History playback", VIEW_HISTORY)
	vp.add_separator()
	vp.add_check_item("Show PBI bar (pinned)", VIEW_PBI_BAR)
	vp.set_item_checked(vp.get_item_index(VIEW_PBI_BAR), _pbi_bar_pinned)
	vp.add_separator()
	vp.add_item("Hints & shortcuts", VIEW_HINTS)
	vp.id_pressed.connect(_on_view_menu_id)
	right_grp.add_child(_view_menu)

	_osm_solar_btn = _make_topbar_btn("☀ Add OSM Solar")
	_osm_solar_btn.tooltip_text = (
			"Import OSM solar arrays whose footprints sit inside the current "
			+ "Sphere of Influence. Aim-Interact still works one array at a time.")
	_osm_solar_btn.visible = false
	_osm_solar_btn.pressed.connect(_on_add_soi_osm_solar_pressed)
	right_grp.add_child(_osm_solar_btn)

	var graph_menu := _make_topbar_menu_btn("Graph ▾")
	graph_menu.tooltip_text = (
			"Per-map autosave · Export / import graph JSON to share layouts "
			+ "between sites. Game saves (full world) stay in SaveLoadUI.")
	var gp := graph_menu.get_popup()
	gp.add_item("Export graph…", 1)
	gp.add_item("Import graph…", 2)
	gp.add_separator()
	gp.add_item("Reset this map’s graph", 3)
	gp.id_pressed.connect(_on_graph_menu_id)
	right_grp.add_child(graph_menu)

	var site_menu := _make_topbar_menu_btn("Site ▾")
	site_menu.tooltip_text = (
			"Share a portable .esim site package (graph + SoI + props + styles). "
			+ "Preview a friend’s design as a ghost overlay, then apply or discard.")
	var sp := site_menu.get_popup()
	sp.add_item("Export site (.esim)…", 10)
	sp.add_item("Import site (.esim)…", 11)
	sp.add_separator()
	sp.add_item("Preview site as ghost…", 12)
	sp.add_item("Clear ghost preview", 13)
	sp.add_item("Apply ghost graph (replace mine)", 14)
	sp.add_separator()
	sp.add_item("Copy share code (graph + SoI)", 15)
	sp.add_item("Paste share code…", 16)
	sp.id_pressed.connect(_on_site_menu_id)
	right_grp.add_child(site_menu)

	return bar


func _on_view_menu_id(id: int) -> void:
	match id:
		VIEW_LEGEND:  _on_legend_toggle()
		VIEW_HISTORY: _on_history_btn_pressed()
		VIEW_PBI_BAR: _on_toggle_pbi_bar()
		VIEW_HINTS:   _on_show_hints()


## Toggle the pinned PBI bar; propagate the choice to the canvas and persist it.
func _on_toggle_pbi_bar() -> void:
	_pbi_bar_pinned = not _pbi_bar_pinned
	_apply_pbi_bar_pinned()
	if _view_menu != null:
		var vp := _view_menu.get_popup()
		vp.set_item_checked(vp.get_item_index(VIEW_PBI_BAR), _pbi_bar_pinned)
	_schedule_graph_autosave()


func _apply_pbi_bar_pinned() -> void:
	if _graph_canvas != null:
		_graph_canvas.set("pbi_bar_pinned", _pbi_bar_pinned)
		_graph_canvas.call("queue_redraw")


# ── Wire-style global override ────────────────────────────────────────────────
func _on_wire_style_menu_id(id: int) -> void:
	match id:
		WIRE_STYLE_BEZIER:    _set_wire_style_override("bezier")
		WIRE_STYLE_ROUNDED:   _set_wire_style_override("orthogonal")
		WIRE_STYLE_METRO:     _set_wire_style_override("metro")
		WIRE_STYLE_APPLY_ALL: _apply_wire_style_to_all()


func _set_wire_style_override(style: String) -> void:
	if _graph_canvas == null:
		return
	# Toggle off if re-selecting the active override.
	if str(_graph_canvas.get("wire_style_override")) == style:
		_graph_canvas.set("wire_style_override", "")
	else:
		_graph_canvas.set("wire_style_override", style)
	_graph_canvas.call("queue_redraw")
	_sync_wire_style_menu_checks()
	_schedule_graph_autosave()


## Bake the current effective style into every connection + the model default,
## then clear the override so per-connection styles are authoritative again.
func _apply_wire_style_to_all() -> void:
	if _graph_canvas == null or model == null:
		return
	var style: String = str(_graph_canvas.get("wire_style_override"))
	if style.is_empty():
		return
	for conn in model.connections:
		if conn is Dictionary:
			conn["line_style"] = style
	model.last_line_style = style
	_graph_canvas.set("wire_style_override", "")
	_graph_canvas.call("queue_redraw")
	_sync_wire_style_menu_checks()
	_schedule_graph_autosave()


func _sync_wire_style_menu_checks() -> void:
	if _wire_style_menu == null:
		return
	var wsp := _wire_style_menu.get_popup()
	var ov := ""
	if _graph_canvas != null:
		ov = str(_graph_canvas.wire_style_override)
	wsp.set_item_checked(wsp.get_item_index(WIRE_STYLE_BEZIER), ov == "bezier")
	wsp.set_item_checked(wsp.get_item_index(WIRE_STYLE_ROUNDED), ov == "orthogonal")
	wsp.set_item_checked(wsp.get_item_index(WIRE_STYLE_METRO), ov == "metro")
	if ov.is_empty():
		_wire_style_menu.text = "Wire ▾"
	else:
		var lbl := "Bezier"
		if ov == "orthogonal":
			lbl = "Rounded"
		elif ov == "metro":
			lbl = "Metro"
		_wire_style_menu.text = "Wire: %s ▾" % lbl


# ── Physical-view (Site/Elevation) orbit camera persistence ──────────────────
## Snapshot the SoI preview camera's orbit params (yaw/pitch) for Site +
## Elevation so an orbited view is restored on reload.
func _collect_phys_cam_state() -> Dictionary:
	if _soi_preview != null and _soi_preview.has_method("get_phys_cam_state"):
		var st: Variant = _soi_preview.call("get_phys_cam_state")
		if st is Dictionary:
			return st as Dictionary
	return {}


func _apply_phys_cam_state(st: Dictionary) -> void:
	if st.is_empty():
		return
	# Ensure the service exists so the saved orbit is retained even when the
	# preview isn't active yet (it applies to the camera on next activation).
	_ensure_soi_preview()
	if _soi_preview != null and _soi_preview.has_method("apply_phys_cam_state"):
		_soi_preview.call("apply_phys_cam_state", st)


func _make_topbar_btn(label: String) -> Button:
	var b := Button.new()
	b.text       = label
	b.focus_mode = Control.FOCUS_NONE
	_apply_topbar_btn_style(b)
	return b


## Topbar dropdown (MenuButton shares Button's stylebox slots).
func _make_topbar_menu_btn(label: String) -> MenuButton:
	var b := MenuButton.new()
	b.text       = label
	b.focus_mode = Control.FOCUS_NONE
	b.flat       = false
	b.switch_on_hover = false
	_apply_topbar_btn_style(b)
	return b


func _apply_topbar_btn_style(b: Button) -> void:
	var sb_n := StyleBoxFlat.new()
	sb_n.bg_color     = Color(0.10, 0.14, 0.24, 1.0)
	sb_n.border_color = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.55)
	sb_n.set_border_width_all(1)
	sb_n.set_corner_radius_all(6)
	sb_n.content_margin_left   = 13.0
	sb_n.content_margin_right  = 13.0
	sb_n.content_margin_top    = 6.0
	sb_n.content_margin_bottom = 6.0

	var sb_h := sb_n.duplicate() as StyleBoxFlat
	sb_h.bg_color     = Color(0.13, 0.20, 0.36, 1.0)
	sb_h.border_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.85)
	sb_h.set_border_width_all(1)

	var sb_p := sb_h.duplicate() as StyleBoxFlat
	sb_p.bg_color = Color(C_PRIMARY.r * 0.22, C_PRIMARY.g * 0.22, C_PRIMARY.b * 0.22, 1.0)

	b.add_theme_stylebox_override("normal",  sb_n)
	b.add_theme_stylebox_override("hover",   sb_h)
	b.add_theme_stylebox_override("pressed", sb_p)
	b.add_theme_color_override("font_color", C_TEXT)
	b.add_theme_font_size_override("font_size", 13)


func _restyle_btn_amber(b: Button) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_AMBER
	sb.set_corner_radius_all(6)
	sb.content_margin_left   = 13.0
	sb.content_margin_right  = 13.0
	sb.content_margin_top    = 6.0
	sb.content_margin_bottom = 6.0
	var sb_h := sb.duplicate() as StyleBoxFlat
	sb_h.bg_color = Color(C_AMBER.r * 1.12, C_AMBER.g * 1.12, C_AMBER.b * 1.12).clamp()
	b.add_theme_stylebox_override("normal",  sb)
	b.add_theme_stylebox_override("hover",   sb_h)
	b.add_theme_stylebox_override("pressed", sb_h)
	b.add_theme_color_override("font_color", C_BG)
	b.add_theme_font_size_override("font_size", 13)


## Desire-line view state (Site Plan only).
var _desire_lines_on := false
var _desire_channel := ""          # "" = all traffic
var _desire_window: int = 1        # NpcDesireMap.Retention.WEEK
var _desire_3d_on := false
var _desire_overlay: Node3D = null


func _cycle_desire_channel() -> void:
	var opts: Array = [""]
	opts.append_array(NpcDesireMap.CHANNELS)
	var i := opts.find(_desire_channel)
	_desire_channel = str(opts[(i + 1) % opts.size()])


func _desire_channel_label() -> String:
	if _desire_channel.is_empty():
		return "all traffic"
	if _desire_channel == "chore":
		return "work trips"
	return SpaceTypes.label(str(SpaceTypes.NEED_TO_SPACE.get(_desire_channel, _desire_channel)))


func _on_view_mode_menu_id(id: int) -> void:
	match id:
		VIEW_MODE_FREEFORM:
			_apply_graph_view_mode(GraphSiteLayout.VIEW_FREEFORM)
		VIEW_MODE_SITE:
			_apply_graph_view_mode(GraphSiteLayout.VIEW_SITE)
		VIEW_MODE_ELEVATION:
			_apply_graph_view_mode(GraphSiteLayout.VIEW_ELEVATION)
		VIEW_MODE_SOI_BUBBLE:
			_freeform_soi_bubble = not _freeform_soi_bubble
			_sync_view_mode_menu_checks()
			_sync_soi_preview_for_mode()
			_schedule_graph_autosave()
		VIEW_MODE_ELEV_3D:
			_elevation_3d_section = not _elevation_3d_section
			if _elevation_3d_section:
				_maybe_toast_elev_3d_wires_hint()
			_sync_view_mode_menu_checks()
			_sync_soi_preview_for_mode()
			_schedule_graph_autosave()
		VIEW_MODE_ELEV_DEM, VIEW_MODE_ELEV_CHIPS, VIEW_MODE_ELEV_PORTS, \
		VIEW_MODE_ELEV_SCHEM_WIRES, VIEW_MODE_ELEV_PROJ_PIPES:
			_toggle_elev_overlay(id)
		VIEW_MODE_SNOWGLOBE:
			_open_full_snowglobe()
		VIEW_MODE_NODE_CARDS:
			if _graph_canvas != null:
				var cur := str(_graph_canvas.get("node_display_mode"))
				_graph_canvas.set("node_display_mode",
					"preview" if cur == "card" else "card")
				_graph_canvas.call("queue_redraw")
			_sync_view_mode_menu_checks()
			_schedule_graph_autosave()
		VIEW_MODE_PREVIEW_LABELS:
			if _graph_canvas != null:
				_graph_canvas.set("show_preview_labels",
					not bool(_graph_canvas.get("show_preview_labels")))
				_graph_canvas.call("queue_redraw")
			_sync_view_mode_menu_checks()
			_schedule_graph_autosave()
		VIEW_MODE_RADIAL:
			if _graph_canvas != null:
				var on := not bool(_graph_canvas.get("radial_layout_mode"))
				_graph_canvas.set("radial_layout_mode", on)
				_graph_canvas.call("queue_redraw")
				if on and _graph_view_mode != GraphSiteLayout.VIEW_SITE:
					_apply_graph_view_mode(GraphSiteLayout.VIEW_SITE)
				if _site_radial_btn != null:
					_site_radial_btn.set_pressed_no_signal(on)
				_show_toast("Radial layout %s — Shift+drag prop = tangent yaw"
					% ("ON" if on else "OFF"))
			_sync_view_mode_menu_checks()
			_schedule_graph_autosave()
		VIEW_MODE_SITE_CHIPS:
			if _graph_canvas != null:
				_graph_canvas.set("site_show_chips",
						not bool(_graph_canvas.get("site_show_chips")))
				_graph_canvas.call("queue_redraw")
			_sync_view_mode_menu_checks()
			_schedule_graph_autosave()
		VIEW_MODE_SITE_PORTS:
			if _graph_canvas != null:
				_graph_canvas.set("site_show_ports",
						not bool(_graph_canvas.get("site_show_ports")))
				_graph_canvas.call("queue_redraw")
			_sync_view_mode_menu_checks()
			_schedule_graph_autosave()
		VIEW_MODE_SITE_LIVE_LIGHT, VIEW_MODE_ELEV_LIVE_LIGHT:
			_site_elev_live_lighting = not _site_elev_live_lighting
			# Elevation-only: Site Plan never claims the clock (live by design).
			if _site_elev_live_lighting:
				_elev_end_noon_lock()
				_show_toast("Live lighting ON — Elevation follows the sim clock")
			elif _graph_view_mode == GraphSiteLayout.VIEW_ELEVATION and visible:
				_elev_begin_noon_lock()
				_show_toast("Daytime bake ON — mean solar noon")
			_sync_view_mode_menu_checks()
			_schedule_graph_autosave()
		VIEW_MODE_SITE_WIRE_3D:
			set_site_wire_mode("prefer_3d")
		VIEW_MODE_SITE_WIRE_METRO:
			set_site_wire_mode("metro")
		VIEW_MODE_SITE_WIRE_NONE:
			set_site_wire_mode("none")
		VIEW_MODE_SEED_SITE:
			_seed_site_from_freeform()
		VIEW_MODE_EMBODY_TWINS:
			_embody_site_twins_manual()
		# Desire lines (Tier 3e). These items live in THIS menu ("View options ▾"),
		# so their arms must live in THIS handler — they sat in _on_view_menu_id
		# (the "View ▾" handler) for a while, where every click was a dead no-op.
		VIEW_MODE_DESIRE_LINES:
			_desire_lines_on = not _desire_lines_on
			if _graph_canvas != null:
				_graph_canvas.call("queue_redraw")
			_sync_view_mode_menu_checks()
		VIEW_MODE_DESIRE_TRAILS:
			if _graph_canvas != null:
				_graph_canvas.set("npc_trails_enabled",
						not bool(_graph_canvas.get("npc_trails_enabled")))
				_graph_canvas.call("queue_redraw")
			_sync_view_mode_menu_checks()
		VIEW_MODE_DESIRE_CHANNEL:
			_cycle_desire_channel()
			if _npc_population != null:
				_npc_population.set_desire_channel(_desire_channel)
			if _graph_canvas != null:
				_graph_canvas.call("queue_redraw")
			_sync_view_mode_menu_checks()
		VIEW_MODE_DESIRE_3D:
			_desire_3d_on = not _desire_3d_on
			_ensure_desire_overlay()
			_sync_view_mode_menu_checks()
		VIEW_MODE_DESIRE_WINDOW:
			_desire_window = (_desire_window + 1) % 3
			if _npc_population != null:
				_npc_population.set_desire_window(_desire_window)
			_sync_view_mode_menu_checks()
		VIEW_MODE_DESIRE_RESET:
			if _npc_population != null and _npc_population.has_method("reset_desire_map"):
				_npc_population.call("reset_desire_map")
			if _graph_canvas != null:
				_graph_canvas.call("queue_redraw")
			_show_toast("Desire lines cleared")
		VIEW_MODE_EXAG_1X:
			_set_elevation_exaggeration(1.0)
		VIEW_MODE_EXAG_5X:
			_set_elevation_exaggeration(5.0)
		VIEW_MODE_HEADING_ROTATE:
			_rotate_elevation_heading(deg_to_rad(15.0))
		VIEW_MODE_RESET_SECTION:
			_reset_elevation_section()


func _make_mode_chip(mode_id: String, label: String) -> Button:
	var b := Button.new()
	b.text = label
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.flat = false
	_apply_topbar_btn_style(b)
	b.pressed.connect(func() -> void: _on_mode_chip_pressed(mode_id))
	return b


func _on_mode_chip_pressed(mode_id: String) -> void:
	match mode_id:
		"freeform":
			_apply_graph_view_mode(GraphSiteLayout.VIEW_FREEFORM)
		"site":
			_apply_graph_view_mode(GraphSiteLayout.VIEW_SITE)
		"elevation":
			_apply_graph_view_mode(GraphSiteLayout.VIEW_ELEVATION)
		"snowglobe":
			_open_full_snowglobe()


func _open_full_snowglobe() -> void:
	var soi := get_node_or_null("/root/SoiService")
	if soi != null and soi.has_method("enter_snowglobe"):
		soi.call("enter_snowglobe")


func _on_designate_menu_id(id: int) -> void:
	match id:
		DESIGNATE_OFF:
			_set_site_designate_mode("")
		DESIGNATE_CATCHMENT:
			_set_site_designate_mode("catchment")
			if _graph_view_mode != GraphSiteLayout.VIEW_SITE:
				_apply_graph_view_mode(GraphSiteLayout.VIEW_SITE)
		DESIGNATE_CROP:
			_set_site_designate_mode("crop")
			if _graph_view_mode != GraphSiteLayout.VIEW_SITE:
				_apply_graph_view_mode(GraphSiteLayout.VIEW_SITE)


func _set_site_designate_mode(mode: String) -> void:
	_site_designate_mode = mode
	if _graph_canvas != null:
		_graph_canvas.set("site_designate_mode", mode)
	if _designate_menu != null:
		var dp := _designate_menu.get_popup()
		dp.set_item_checked(dp.get_item_index(DESIGNATE_OFF), mode.is_empty())
		dp.set_item_checked(dp.get_item_index(DESIGNATE_CATCHMENT), mode == "catchment")
		dp.set_item_checked(dp.get_item_index(DESIGNATE_CROP), mode == "crop")
		match mode:
			"catchment":
				_designate_menu.text = "Designate · Roof ▾"
			"crop":
				_designate_menu.text = "Designate · Crop ▾"
			_:
				_designate_menu.text = "Designate ▾"


func _on_site_background_clicked(screen_pos: Vector2) -> void:
	if _awaiting_array_center:
		_awaiting_array_center = false
		_on_site_array_center_click(screen_pos)
		return
	if _site_designate_mode.is_empty() or _graph_canvas == null:
		return
	var disc: Dictionary = {}
	if _graph_canvas.has_method("get_soi_disc_layout"):
		disc = _graph_canvas.call("get_soi_disc_layout") as Dictionary
	var origin: Vector2 = disc.get("origin", Vector2.ZERO)
	var zoom := float(_graph_canvas.get("_zoom"))
	var site_m := GraphSiteLayout.screen_to_site_m(screen_pos, origin, zoom)
	var soi := get_node_or_null("/root/SoiService")
	if soi == null or not soi.has_method("world_center"):
		return
	var world := GraphSiteLayout.site_to_world_xz(site_m, soi.call("world_center") as Vector3)
	var loader := _find_terrain_loader(_get_scene_main_node())
	if loader == null:
		return
	if _site_designate_mode == "catchment":
		var bpick: Dictionary = loader.call("pick_building_at_world", world.x, world.y) \
				if loader.has_method("pick_building_at_world") else {"valid": false}
		if bool(bpick.get("valid", false)):
			var bidx := int(bpick.get("building_idx", -1))
			if loader.has_method("add_building_catchment_to_graph"):
				loader.call("add_building_catchment_to_graph", bidx)
		else:
			print("SystemGraphView: Designate catchment — no building under click")
	elif _site_designate_mode == "crop":
		var vpick: Dictionary = loader.call("pick_veg_area_at_world", world.x, world.y) \
				if loader.has_method("pick_veg_area_at_world") else {"valid": false}
		if bool(vpick.get("valid", false)):
			var kind := str(vpick.get("kind", ""))
			if kind in ["grass_field", "orchard", "vineyard", "park", "grass_lawn"] \
					or kind.begins_with("grass"):
				var vidx := int(vpick.get("area_idx", -1))
				if loader.has_method("add_veg_area_plant_to_graph"):
					loader.call("add_veg_area_plant_to_graph", vidx)
			else:
				print("SystemGraphView: Designate crop — kind '%s' not a crop field" % kind)
		else:
			print("SystemGraphView: Designate crop — no veg area under click")


## Deferred visibility hook — always applies the live `_graph_view_mode`.
func _reapply_current_graph_view_mode() -> void:
	_apply_graph_view_mode(_graph_view_mode)


func _apply_graph_view_mode(mode: String, opts: Dictionary = {}) -> void:
	var was_elev := _graph_view_mode == GraphSiteLayout.VIEW_ELEVATION
	var was_site := _graph_view_mode == GraphSiteLayout.VIEW_SITE
	var entering_elev := mode == GraphSiteLayout.VIEW_ELEVATION and not was_elev
	_graph_view_mode = mode
	# Fresh entry into Elevation turns CT 3D on (restore / explicit opt skip this).
	if entering_elev and not bool(opts.get("preserve_elev_3d", false)):
		_elevation_3d_section = true
		# Do NOT auto-enable world 3D wires here — remeshing every conduit on
		# the same frame as the SoI CT SubViewport boots was TDR'ing AMD GPUs.
		# Soft-focus remeshes only the siphon culvert (below).
		_maybe_toast_elev_3d_wires_hint()
	# Elevation only: bake at mean solar noon unless live lighting is on.
	# Site Plan deliberately NEVER claims the clock — the noon freeze was why
	# the plan read as a frozen snapshot (people stop ticking, nothing moves;
	# PACKING_PLAN.md names this exact player report). Site lighting is live.
	var is_phys := mode in [GraphSiteLayout.VIEW_SITE, GraphSiteLayout.VIEW_ELEVATION]
	if mode == GraphSiteLayout.VIEW_ELEVATION and visible and not _site_elev_live_lighting:
		_elev_begin_noon_lock()
	else:
		_elev_end_noon_lock()
	if was_site and not is_phys:
		_restore_site_conduit_visibility()
	if _graph_canvas != null:
		_graph_canvas.visible = true
		# ALWAYS through set_view_mode — it is what saves the outgoing view's
		# zoom/pan into its own slot and restores the incoming one. VIEW_SIPHON is
		# a real mode now (the canvas draws only its background under the Lab); it
		# used to be faked by parking in VIEW_FREEFORM, which handed the Lab the
		# freeform camera to overwrite. Do NOT zero _pan on Elevation entry either
		# — frame_elevation_window already does, and the elevation slot owns it.
		_graph_canvas.call("set_view_mode", mode)
		_graph_canvas.call("queue_redraw")
	_sync_view_mode_menu_checks()
	_sync_elev_slice_row()
	_sync_site_tool_row()
	_sync_soi_preview_for_mode()
	_sync_siphon_lab_view(str(opts.get("siphon_item_id", "")))
	_apply_layout()
	if mode == GraphSiteLayout.VIEW_SITE or mode == GraphSiteLayout.VIEW_ELEVATION \
			or mode == GraphSiteLayout.VIEW_SIPHON:
		_backfill_site_from_world()
		_refresh_item_elevations()
		if mode == GraphSiteLayout.VIEW_SITE:
			# Seat graph nodes that still lack site_* only. Do NOT auto-call
			# ensure_all_site_twins() here — that place+save path raced map load
			# when view_mode=site was restored from autosave and overwrote
			# user://maps/placed_props_*.json with only the new twins (wiping
			# unbound buildings / pallet racks). Embody is opt-in via View menu.
			_auto_seed_site_unplaced()
			_refresh_site_autoroutes()
			_ensure_site_working_radius()
			_apply_site_wire_mode_session()
	# Elev: heal orphan pond twins + soft-focus siphon culvert / frame CT.
	if entering_elev:
		heal_duplicate_null_bathymetry_ponds()
		heal_pond_capacity_sanity()
	if entering_elev and not bool(opts.get("skip_elev_siphon_focus", false)):
		call_deferred("_ensure_elev_siphon_ct_ready")
	# Extreme zoom: crop SoI SubViewport on the next frame before a giant Control
	# can allocate (GPU cliff). Applies to fresh Site entry too — restoring the
	# plan at deep zoom used to wait for the service's next idle _process, one
	# frame of oversized Control. Siphon Lab uses no SoI preview now.
	if entering_elev or (mode == GraphSiteLayout.VIEW_SITE and not was_site):
		call_deferred("_force_soi_preview_layout_sync")
	_schedule_graph_autosave()


## Snap Elev CT lighting to mean solar noon; freeze time_scale until leave/hide.
func _elev_begin_noon_lock() -> void:
	var main := _get_scene_main_node()
	if main == null:
		return
	if not _elev_noon_active:
		_elev_saved_day_time = float(main.get("day_time"))
		_elev_noon_active = true
	# Claim rather than save/restore: the elevation view can be opened over CSV
	# playback or the snowglobe, and the old _elev_saved_time_scale snapshotted
	# THEIR temporary 0.0 and restored that. See core/clock_claims.gd.
	if main.has_method("push_clock_claim"):
		main.call("push_clock_claim", ELEV_CLOCK_OWNER, {"time_scale": 0.0})
	_elev_snap_solar_noon(main)
	call_deferred("_elev_refresh_ct_after_noon")


func _elev_snap_solar_noon(main: Node = null) -> void:
	if main == null:
		main = _get_scene_main_node()
	if main == null:
		return
	var clock: Variant = main.get("clock")
	if clock != null and clock.has_method("mean_solar_time_to_clock_time"):
		main.set("day_time", clock.call("mean_solar_time_to_clock_time", 12.0))
	elif main.has_method("solar_time_to_clock_time"):
		main.set("day_time", main.call("solar_time_to_clock_time", 12.0))
	else:
		main.set("day_time", 12.0)


func _elev_refresh_ct_after_noon() -> void:
	if not _elev_noon_active or not visible:
		return
	if _soi_preview != null and _soi_preview.has_method("force_layout_sync"):
		_soi_preview.call("force_layout_sync")
	elif _soi_preview != null and _soi_preview.has_method("mark_layout_dirty"):
		_soi_preview.call("mark_layout_dirty")


func _elev_end_noon_lock() -> void:
	if not _elev_noon_active:
		return
	_elev_noon_active = false
	var main := _get_scene_main_node()
	if main != null:
		if not is_nan(_elev_saved_day_time):
			main.set("day_time", _elev_saved_day_time)
		if main.has_method("pop_clock_claim"):
			main.call("pop_clock_claim", ELEV_CLOCK_OWNER)
	_elev_saved_day_time = NAN


func _spatial_radial_yaw_deg(site_xz: Vector2, center_site: Vector2 = Vector2.ZERO) -> float:
	var rel := site_xz - center_site
	if rel.length() < 0.5:
		return 0.0
	var theta := atan2(rel.y, rel.x)
	return rad_to_deg(-(theta + PI * 0.5))


func _init_spatial_edit() -> void:
	_spatial_edit = _SPATIAL_EDIT_SCRIPT.new()
	_spatial_edit.get_main = func() -> Node: return _get_scene_main_node()
	_spatial_edit.get_preview = func() -> Node: return _soi_preview
	_spatial_edit.get_view_mode = func() -> String: return _graph_view_mode
	_spatial_edit.get_elev_heading = func() -> float:
		return float(_graph_canvas.get("elevation_heading_rad")) if _graph_canvas != null else 0.0
	_spatial_edit.get_conduit_manager = func() -> Node: return _get_conduit_manager()
	_spatial_edit.sync_graph_from_prop = _spatial_sync_graph_from_prop
	_spatial_edit.on_highlight = _spatial_highlight_prop
	_spatial_edit.array_preview_changed.connect(_on_spatial_array_preview_changed)
	_spatial_edit.working_radius_changed.connect(_on_spatial_working_radius_changed)
	if _graph_canvas != null:
		_graph_canvas.set("spatial_edit", _spatial_edit)
		_graph_canvas.set("site_drag_sync_prop", _site_drag_sync_bound_prop)


## Live Site Plan magnifier drag → move the bound 3D twin under the ring.
## Release path (`_sync_bound_props_from_site`) still heals yaw / elevation.
func _site_drag_sync_bound_prop(item_id: String, site_xz: Vector2) -> void:
	if model == null or item_id.is_empty():
		return
	var item := model.get_item(item_id)
	if item.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var prop_id := str(specs.get("bound_prop_id", ""))
	if prop_id.is_empty():
		return
	var main := _get_scene_main_node()
	var soi := get_node_or_null("/root/SoiService")
	if main == null or soi == null or not soi.has_method("world_center"):
		return
	var center: Vector3 = soi.call("world_center")
	var wxz := GraphSiteLayout.site_to_world_xz(site_xz, center)
	var rec := PlacedPropService.get_prop_record(main, prop_id)
	if rec.is_empty():
		return
	if Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0))) \
			.distance_to(wxz) <= _SITE_SYNC_EPS_M:
		return
	if _graph_canvas != null and bool(_graph_canvas.get("radial_layout_mode")):
		var c_site := Vector2.ZERO
		if _spatial_edit != null:
			c_site = _spatial_edit.radial_center_site()
		var yaw := _spatial_radial_yaw_deg(site_xz, c_site)
		PlacedPropService.update_prop_record(main, prop_id, {"yaw": yaw}, false)
	PlacedPropService.move_prop_xz(main, prop_id, wxz.x, wxz.y)


func _spatial_sync_graph_from_prop(prop_id: String, extras: Dictionary = {}) -> void:
	if model == null or prop_id.is_empty():
		return
	var main := _get_scene_main_node()
	if main == null:
		return
	# Prefer existing sync path (finds bound items by prop id).
	if has_method("sync_site_from_prop"):
		call("sync_site_from_prop", prop_id)
	if extras.has("elevation_m"):
		var elev := float(extras["elevation_m"])
		for it in model.items:
			if not (it is Dictionary):
				continue
			var specs: Dictionary = ((it as Dictionary).get("specs", {}) as Dictionary) \
					.duplicate(true)
			if str(specs.get("bound_prop_id", "")) != prop_id:
				continue
			var patch := {"elevation_m": elev}
			if str(specs.get("role", "")) == "siphon_hydro":
				specs["module_elev_m"] = elev
				SiphonHydraulics.apply_resolved_levels(specs, elev)
				patch["specs"] = specs
			model.update_item(str((it as Dictionary).get("id", "")), patch)
			break


func _spatial_highlight_prop(prop_id: String) -> void:
	# Outline the live PlacedProp (Elev / Hydro Lab) + flash the graph chip.
	var main := _get_scene_main_node()
	if main != null:
		var parent := main.get_node_or_null("PlacedProps")
		if parent == null:
			parent = main.find_child("PlacedProps", true, false)
		if parent != null:
			for child in parent.get_children():
				if not (child is PlacedProp):
					continue
				var pp := child as PlacedProp
				pp.set_graph_highlight(str(pp.prop_id) == prop_id and not prop_id.is_empty())
	# Re-capture the disc so the hover/selection outline shows live (fires only when
	# the highlighted prop actually changes, so idle mouse-move doesn't re-render).
	if _soi_preview != null and _soi_preview.has_method("request_refresh"):
		_soi_preview.request_refresh()
	if prop_id.is_empty() or _graph_canvas == null or model == null:
		return
	for it in model.items:
		if not (it is Dictionary):
			continue
		var specs: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
		if str(specs.get("bound_prop_id", "")) == prop_id:
			if _graph_canvas.has_method("flash_item"):
				_graph_canvas.call("flash_item", str((it as Dictionary).get("id", "")))
			return


func _on_spatial_array_preview_changed() -> void:
	if _graph_canvas == null or _spatial_edit == null:
		return
	_graph_canvas.set("site_array_ghosts", _spatial_edit.array_ghosts.duplicate(true))
	_graph_canvas.call("queue_redraw")


func _on_spatial_working_radius_changed(r_m: float) -> void:
	if _graph_canvas != null:
		_graph_canvas.set("site_working_radius_m", r_m)
		_graph_canvas.call("queue_redraw")
	if _site_radius_slider != null:
		_site_radius_slider.set_value_no_signal(r_m)
	if _site_radius_lbl != null:
		_site_radius_lbl.text = "%.0f m" % r_m


func _ensure_site_working_radius() -> void:
	var r_m := 150.0
	var soi := get_node_or_null("/root/SoiService")
	if soi != null and soi.has_method("radius_m"):
		r_m = float(soi.call("radius_m"))
	if _spatial_edit != null:
		var wr := float(_spatial_edit.ensure_working_radius(r_m))
		_on_spatial_working_radius_changed(wr)
	if _site_radius_slider != null:
		_site_radius_slider.max_value = maxf(r_m * 1.5, 50.0)


func _sync_site_tool_row() -> void:
	var on := _graph_view_mode == GraphSiteLayout.VIEW_SITE
	if _site_tool_row != null:
		_site_tool_row.visible = on
	if on:
		_ensure_site_working_radius()
		if _site_radial_btn != null and _graph_canvas != null:
			_site_radial_btn.set_pressed_no_signal(
					bool(_graph_canvas.get("radial_layout_mode")))
	if _elev_hydro_lab_btn != null:
		_elev_hydro_lab_btn.visible = _graph_view_mode == GraphSiteLayout.VIEW_ELEVATION


func _on_site_radial_toggled(pressed: bool) -> void:
	if _graph_canvas == null:
		return
	_graph_canvas.set("radial_layout_mode", pressed)
	_graph_canvas.call("queue_redraw")
	_sync_view_mode_menu_checks()
	_schedule_graph_autosave()
	_show_toast("Radial %s — Shift+drag prop = face tangent" % ("ON" if pressed else "OFF"))


func _on_site_working_radius_changed(v: float) -> void:
	var soi_r := 150.0
	var soi := get_node_or_null("/root/SoiService")
	if soi != null and soi.has_method("radius_m"):
		soi_r = float(soi.call("radius_m"))
	if _spatial_edit != null:
		_spatial_edit.set_working_radius(v, soi_r)


func _on_site_array_menu_id(id: int) -> void:
	if _spatial_edit == null:
		return
	match id:
		SITE_ARRAY_LINE:
			_spatial_edit.array_pattern = 0  # LINE
			if not _spatial_edit.begin_array_from_selection():
				_show_toast("Select a placed 3D prop first (LMB in Site Plan)")
			else:
				_show_toast("Array Line preview — Array ▾ → Confirm")
		SITE_ARRAY_ARC:
			_spatial_edit.array_pattern = 1  # ARC
			if not _spatial_edit.begin_array_from_selection():
				_show_toast("Select a placed 3D prop first")
			else:
				_show_toast("Array Arc preview — Array ▾ → Confirm")
		SITE_ARRAY_CIRCLE:
			_spatial_edit.array_pattern = 2  # CIRCLE
			if not _spatial_edit.begin_array_from_selection():
				_show_toast("Select a placed 3D prop first")
			else:
				_show_toast("Array Circle preview — Array ▾ → Confirm")
		SITE_ARRAY_CONFIRM:
			var n := int(_spatial_edit.confirm_array())
			_show_toast("Placed %d duplicate%s" % [n, "" if n == 1 else "s"])
			_schedule_graph_autosave()
		SITE_ARRAY_CANCEL:
			_spatial_edit.cancel_array()
			_show_toast("Array cancelled")
		SITE_ARRAY_SET_CENTER:
			_awaiting_array_center = true
			_show_toast("Click the SoI disc to set array center (next click)")
		SITE_ARRAY_CLEAR_CENTER:
			_spatial_edit.clear_custom_center()
			_spatial_edit.rebuild_array_ghosts()
			_show_toast("Array center = SoI origin")
		SITE_RADIUS_RESET:
			var soi_r2 := 150.0
			var soi2 := get_node_or_null("/root/SoiService")
			if soi2 != null and soi2.has_method("radius_m"):
				soi_r2 = float(soi2.call("radius_m"))
			_spatial_edit.reset_working_radius_to_soi(soi_r2)
			_show_toast("Working R reset to SoI (%.0f m)" % soi_r2)


func _on_site_array_center_click(screen_pos: Vector2) -> void:
	if _spatial_edit == null or _soi_preview == null:
		return
	if _soi_preview.has_method("canvas_to_site_ground"):
		var s: Variant = _soi_preview.call("canvas_to_site_ground", screen_pos)
		if s is Vector2:
			_spatial_edit.custom_center_site = s as Vector2
			_spatial_edit.rebuild_array_ghosts()
			_show_toast("Array center set")


func _on_elev_open_hydro_lab_pressed() -> void:
	var sid := ""
	if model != null:
		for it in model.items:
			if not (it is Dictionary):
				continue
			var specs: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
			if str(specs.get("role", "")) == "siphon_hydro" \
					or ModelCatalog.is_hydro_turbine(str(specs.get("model_id", ""))):
				sid = str((it as Dictionary).get("id", ""))
				break
	if sid.is_empty():
		_show_toast("No siphon / penstock on the graph — add one first")
		return
	open_siphon_lab(sid)


## Public: Site Plan wire overlay mode — none | metro | prefer_3d
func set_site_wire_mode(mode: String) -> void:
	var m := mode.strip_edges().to_lower()
	if m not in ["none", "metro", "prefer_3d"]:
		m = "prefer_3d"
	if _graph_canvas != null:
		_graph_canvas.set("site_wire_mode", m)
		_graph_canvas.call("queue_redraw")
	_apply_site_wire_mode_session()
	_sync_view_mode_menu_checks()
	_schedule_graph_autosave()
	_show_toast("Site wires: %s" % m.replace("_", " "))


func _apply_site_wire_mode_session() -> void:
	if _graph_view_mode != GraphSiteLayout.VIEW_SITE or _graph_canvas == null:
		return
	var mode := str(_graph_canvas.get("site_wire_mode"))
	var sc := get_node_or_null("/root/SimSettingsController")
	if sc == null:
		return
	if _site_saved_conduits_3d == null and "conduits_3d_visible" in sc:
		_site_saved_conduits_3d = bool(sc.get("conduits_3d_visible"))
	if mode == "prefer_3d":
		if sc.has_method("set_conduits_3d_visible"):
			sc.call("set_conduits_3d_visible", true)
		elif "conduits_3d_visible" in sc:
			sc.set("conduits_3d_visible", true)
	elif mode in ["metro", "none"]:
		if sc.has_method("set_conduits_3d_visible"):
			sc.call("set_conduits_3d_visible", false)
		elif "conduits_3d_visible" in sc:
			sc.set("conduits_3d_visible", false)


func _restore_site_conduit_visibility() -> void:
	if _site_saved_conduits_3d == null:
		return
	var sc := get_node_or_null("/root/SimSettingsController")
	if sc != null:
		if sc.has_method("set_conduits_3d_visible"):
			sc.call("set_conduits_3d_visible", bool(_site_saved_conduits_3d))
		elif "conduits_3d_visible" in sc:
			sc.set("conduits_3d_visible", bool(_site_saved_conduits_3d))
	_site_saved_conduits_3d = null


func _force_soi_preview_layout_sync() -> void:
	if _soi_preview != null and _soi_preview.has_method("force_layout_sync"):
		_soi_preview.call("force_layout_sync")
	elif _soi_preview != null and _soi_preview.has_method("mark_layout_dirty"):
		_soi_preview.call("mark_layout_dirty")


## Elev enter: show siphon culvert (focus-only) and frame the CT on the pond
## when the elev window still looks like a fresh/datum view.
func _ensure_elev_siphon_ct_ready() -> void:
	if _graph_view_mode != GraphSiteLayout.VIEW_ELEVATION:
		return
	var siphon_id := _find_elev_siphon_id()
	if siphon_id.is_empty():
		return
	focus_siphon_conduit_glow(siphon_id, false)
	var need_frame := true
	var pond := resolve_siphon_pond(siphon_id)
	if _graph_canvas != null and not pond.is_empty() \
			and GraphSiteLayout.has_site_coords(pond):
		var heading := float(_graph_canvas.get("elevation_heading_rad"))
		var cross_dir := Vector2(-sin(heading), cos(heading))
		var pond_slice := GraphSiteLayout.site_xz(pond).dot(cross_dir)
		var cur_slice := float(_graph_canvas.get("elevation_section_offset_m"))
		var elev_m := float(_graph_canvas.call("get_elev_anchor_elev_m")) \
				if _graph_canvas.has_method("get_elev_anchor_elev_m") else NAN
		var ps: Dictionary = pond.get("specs", {}) as Dictionary
		var floor_m := float(ps.get("floor_m", NAN))
		var rim_m := float(ps.get("rim_m", NAN))
		var level_m := float(ps.get("level_m", NAN))
		var target := level_m
		if is_nan(target):
			target = rim_m if not is_nan(rim_m) else floor_m
		var elev_ok := not is_nan(target) and not is_nan(elev_m) \
				and absf(elev_m - target) < 25.0
		var slice_ok := absf(cur_slice - pond_slice) < 8.0
		# Already framed near the pond — keep user's pan/zoom.
		if elev_ok and slice_ok and _graph_canvas.has_method("has_elev_anchor") \
				and bool(_graph_canvas.call("has_elev_anchor")):
			need_frame = false
	if need_frame:
		frame_elevation_for_siphon(siphon_id)


## Site Plan → top-down. Freeform bubble → orbit. Elevation / Hydro Lab → section.
## Never latches world clip / SubViewport while the graph is hidden — otherwise
## map load + autosave restore drops the player into a clipped snowglobe world.
func _sync_soi_preview_for_mode() -> void:
	_ensure_soi_preview()
	var want_site := _graph_view_mode == GraphSiteLayout.VIEW_SITE
	var want_freeform_bubble := (
			_graph_view_mode == GraphSiteLayout.VIEW_FREEFORM and _freeform_soi_bubble)
	var want_siphon_lab := _graph_view_mode == GraphSiteLayout.VIEW_SIPHON
	var want_elev_3d := (
			(_graph_view_mode == GraphSiteLayout.VIEW_ELEVATION and _elevation_3d_section)
			or want_siphon_lab)
	var want_preview := visible and (want_site or want_freeform_bubble or want_elev_3d)
	if _soi_preview != null and _soi_preview.has_method("set_embed_host"):
		var host: Control = null
		if want_siphon_lab and _siphon_lab_modal != null \
				and _siphon_lab_modal.has_method("get_preview_embed_host"):
			host = _siphon_lab_modal.call("get_preview_embed_host") as Control
		_soi_preview.call("set_embed_host", host)
	if _soi_preview != null and _soi_preview.has_method("clear_lab_section_frame") \
			and not want_siphon_lab:
		_soi_preview.call("clear_lab_section_frame")
	if _soi_preview != null and _soi_preview.has_method("set_active"):
		_soi_preview.call("set_active", want_preview)
	if want_preview:
		if _soi_preview != null and _soi_preview.has_method("set_top_down"):
			_soi_preview.call("set_top_down", want_site)
		if _soi_preview != null and _soi_preview.has_method("set_section_mode"):
			_soi_preview.call("set_section_mode", want_elev_3d)
		if want_elev_3d and _graph_canvas != null \
				and _soi_preview != null and _soi_preview.has_method("set_section_heading"):
			_soi_preview.call("set_section_heading",
					float(_graph_canvas.get("elevation_heading_rad")))
		if want_elev_3d and _graph_canvas != null \
				and _soi_preview != null and _soi_preview.has_method("set_section_offset"):
			_soi_preview.call("set_section_offset",
					float(_graph_canvas.get("elevation_section_offset_m")))
		if want_siphon_lab and _siphon_lab_modal != null \
				and _siphon_lab_modal.has_method("get_lab_section_frame"):
			sync_siphon_lab_section_frame(
					_siphon_lab_modal.call("get_lab_section_frame") as Dictionary)
	if _bg_rect != null and is_instance_valid(_bg_rect):
		_bg_rect.color = Color(C_BG.r, C_BG.g, C_BG.b, 1.0)


## Push Hydro Lab metre window into the embedded Elevation CT camera.
func sync_siphon_lab_section_frame(frame: Dictionary) -> void:
	if _soi_preview == null or frame.is_empty():
		return
	if frame.has("heading") and _graph_canvas != null:
		_graph_canvas.set("elevation_heading_rad", float(frame.get("heading", 0.0)))
		if _soi_preview.has_method("set_section_heading"):
			_soi_preview.call("set_section_heading", float(frame.get("heading", 0.0)))
	if _soi_preview.has_method("set_lab_section_frame"):
		_soi_preview.call("set_lab_section_frame",
				float(frame.get("along_m", 0.0)),
				float(frame.get("elev_m", 0.0)),
				float(frame.get("ortho_h_m", 8.0)))


## Soft-focus siphon outlet/intake conduits so 3D flow glow reads in Elev CT
## without remeshing every wire on the map (AMD TDR-safe).
## `force_global_wires`: Lab turns Timeline 3D wires on (restored on teardown).
## Elev uses false — focus-only remesh shows the culvert without a full-map storm.
func focus_siphon_conduit_glow(siphon_id: String, force_global_wires: bool = true) -> void:
	if model == null or siphon_id.is_empty():
		return
	ensure_siphon_outlet_sink(siphon_id)
	var mgr := _get_conduit_manager()
	var focus_id := ""
	var penstock_id := ""
	for conn in model.connections:
		if not (conn is Dictionary):
			continue
		var c: Dictionary = conn
		var src := str(c.get("source_item_id", ""))
		var tgt := str(c.get("target_item_id", ""))
		if src != siphon_id and tgt != siphon_id:
			continue
		# Force culvert/outlet AND any routed penstock visible + glowing (a bare
		# intake wire stays schematic). A penstock is the player's own routed
		# pipe — it must render, not sit behind the direct-intake hide rule.
		var type_id := ConduitKinds.derive_type_for_connection(c)
		var is_penstock := ConduitKinds.normalize_route_mode(
				str((c.get("conduit_style", {}) as Dictionary).get("route_mode",
					ConduitKinds.type_meta(type_id).get("route_mode", "")))) == "contour"
		var patch := {}
		if is_penstock or ConduitKinds.uses_culvert_kit(type_id) \
				or str(c.get("conduit_type", "")) == "culvert_pipe":
			if c.get("visible_3d") != true:
				patch["visible_3d"] = true
			if c.get("flow_glow") != true:
				patch["flow_glow"] = true
		if not patch.is_empty():
			var cid0 := str(c.get("id", ""))
			if not cid0.is_empty():
				model.update_connection(cid0, patch)
				c = model.get_connection(cid0)
				if c.is_empty():
					c = conn
		focus_id = str(c.get("id", focus_id))
		if is_penstock:
			penstock_id = str(c.get("id", ""))
		if mgr != null and mgr.has_method("ensure_preview_samples"):
			mgr.call("ensure_preview_samples", c)
	# The loop keeps the LAST match; prefer the penstock when one is routed —
	# that is the run the player is designing, and only the focused connection
	# renders while global 3D wires are off.
	if not penstock_id.is_empty():
		focus_id = penstock_id
	if focus_id.is_empty() or mgr == null:
		if _graph_canvas != null:
			_graph_canvas.call("queue_redraw")
		return
	if force_global_wires:
		# Lab needs the 3D culvert on the CT cut — turn wires on so remesh isn't skipped.
		if not _lab_conduit_prefs_saved:
			_lab_conduit_prefs_saved = true
			var ssc0 := get_node_or_null("/root/SimSettingsController")
			_lab_saved_conduits_visible = bool(ssc0.get("conduits_3d_visible")) \
					if ssc0 != null else false
			_lab_saved_flow_glow = bool(ssc0.get("conduit_flow_glow_enabled")) \
					if ssc0 != null else false
		if mgr.has_method("set_global_visibility"):
			mgr.call("set_global_visibility", true)
		if mgr.has_method("set_global_flow_glow"):
			mgr.call("set_global_flow_glow", true)
	if mgr.has_method("set_focus_highlight"):
		mgr.call("set_focus_highlight", focus_id)
	if mgr.has_method("force_remesh"):
		mgr.call("force_remesh", focus_id)
	# Second remesh after CT camera settles (first can race empty anchors).
	if mgr.has_method("force_remesh"):
		get_tree().create_timer(0.12).timeout.connect(
				func() -> void:
					if mgr != null and is_instance_valid(mgr) and mgr.has_method("force_remesh"):
						mgr.call("force_remesh", focus_id),
				CONNECT_ONE_SHOT)
	if _graph_canvas != null:
		_graph_canvas.call("queue_redraw")


## Leave the Lab and stand next to the turbine in first person, with its
## penstock focused/glowing — the "go look at the thing I just built" move, and
## the way into the 3D wire tools for finer bends.
func go_to_turbine_in_world(item_id: String) -> bool:
	if model == null or item_id.is_empty():
		return false
	var item := model.get_item(item_id)
	if item.is_empty():
		return false
	var prop_id := str((item.get("specs", {}) as Dictionary).get("bound_prop_id", ""))
	var main := _get_scene_main_node()
	if main == null:
		return false
	if prop_id.is_empty():
		prop_id = _find_hydroturbine_prop_id_for_item(item_id, main)
	if prop_id.is_empty():
		_show_toast("This turbine has no 3D twin yet — place it in the world first")
		return false
	var rec := PlacedPropService.get_prop_record(main, prop_id)
	if rec.is_empty():
		return false
	var px := float(rec.get("x", 0.0))
	var pz := float(rec.get("z", 0.0))
	# Stand a few metres back so the machine AND the pipe leaving it are in
	# frame, on the ground (never inside the prop or under the terrain).
	var stand := Vector2(px + 4.0, pz + 4.0)
	var gy := TerrainSurfaceQuery.ground_height_at(main, stand.x, stand.y)
	var player: Variant = main.get("player")
	if not (player is Node3D):
		return false
	var p3 := player as Node3D
	p3.global_position = Vector3(stand.x, gy + 1.2, stand.y)
	if p3 is CharacterBody3D:
		(p3 as CharacterBody3D).velocity = Vector3.ZERO
	if "player_spawn_position" in main:
		main.player_spawn_position = p3.global_position
	# Keep the penstock lit so it is obvious what to grab.
	focus_siphon_conduit_glow(item_id)
	if visible:
		_apply_graph_close_side_effects()
	return true


## Keep a bound turbine's 3D model in step with its turbine_kind — a PowerSpout
## must not wear the siphon hydroturbine's body. The prop record's own model_id
## is authoritative (changing the graph spec alone does nothing), so this swaps
## it in place: update_prop_record with rebuild frees just that prop, respawns
## it, and re-runs the whole behaviour-attach dispatch.
## ⚠ `turbine_node` / `spin_axis` were stamped on the record at PLACEMENT time
## and must be patched too, or the spin runtime binds a node name from the old
## GLB and the new runner never turns.
func sync_turbine_model_to_kind(item_id: String) -> bool:
	if model == null or item_id.is_empty():
		return false
	var item := model.get_item(item_id)
	if item.is_empty():
		return false
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if str(specs.get("role", "")) != "siphon_hydro":
		return false
	var prop_id := str(specs.get("bound_prop_id", ""))
	if prop_id.is_empty():
		return false
	var want := str(HydroSource.kind_meta(
			str(specs.get("turbine_kind", "siphon"))).get("model_id", ""))
	if want.is_empty() or ModelCatalog.find(want).is_empty():
		return false
	var main := _get_scene_main_node()
	if main == null:
		return false
	var rec := PlacedPropService.get_prop_record(main, prop_id)
	if rec.is_empty() or str(rec.get("model_id", "")) == want:
		return false
	PlacedPropService.update_prop_record(main, prop_id, {
		"model_id": want,
		"turbine_node": ModelCatalog.turbine_node_for(want),
		"spin_axis": ModelCatalog.spin_axis_for(want),
	}, true)
	# Keep the graph spec's model_id honest too (library/packing read it).
	var s2: Dictionary = specs.duplicate(true)
	s2["model_id"] = want
	model.update_item(item_id, {"specs": s2})
	# Mid-Lab / mid-Elevation swap: the CT midplane clip and the section yaw
	# were applied to the node that was just FREED — re-apply to the respawn or
	# the new model renders unsliced (or not at all) on the cut.
	if _graph_view_mode == GraphSiteLayout.VIEW_SIPHON \
			or (_graph_view_mode == GraphSiteLayout.VIEW_ELEVATION and _elevation_3d_section):
		if _soi_preview != null \
				and _soi_preview.has_method("_apply_hydroturbine_section_clip"):
			_soi_preview.call("_apply_hydroturbine_section_clip", true)
		_ensure_hydroturbine_section_yaw(item_id)
	_show_toast("Swapped the 3D model to %s" % ModelCatalog.find(want).get("label", want))
	return true


## Mint a Stream Intake at a world point and wire a penstock from it to
## `turbine_id`'s inlet handle. This is what "drop the pipe here and that's the
## source" means mechanically: a conduit has NO free endpoints (both ends must
## resolve to an item with a 3D anchor, and a `resource` item only gets one via
## bound_prop_id), so the drop has to create a real prop + graph node. Head then
## follows from the intake's terrain elevation through the normal invert path.
## Returns the new connection id, or "" on failure.
## Specs for a freshly minted stream intake. `stream_source` is the marker the
## flow engine and the inspector key off (model_id is the fallback, so intakes
## made before this key existed still resolve).
func _stream_intake_specs(prop_id: String) -> Dictionary:
	var specs := {
		"name": "Stream Intake",
		"resource_kind": "water",
		# NOT pond_storage: this is a running source, not a reservoir with a
		# level to draw down — the turbine reads its ELEVATION for head.
		"pond_storage": false,
		"stream_source": true,
		"unlimited_capacity": true,
		"capacity_qty": 1000.0, "capacity_unit": "L", "level": 1.0,
		"bound_prop_id": prop_id,
		"model_id": StreamIntakeBuilder.MODEL_ID,
		"daily_note": "Tapped by a penstock. Its ground elevation sets the gross head, its base flow + rain response set how much water it runs.",
	}
	specs.merge(HydroSupply.default_intake_specs())
	return specs


func create_penstock_intake_at(world_pos: Vector3, turbine_id: String,
		turbine_handle: String, style_ov: Dictionary = {}) -> String:
	if model == null or turbine_id.is_empty():
		return ""
	var turbine := model.get_item(turbine_id)
	if turbine.is_empty():
		_show_toast("Penstock needs a turbine at the other end")
		return ""
	var main := _get_scene_main_node()
	if main == null:
		return ""
	var placed: Dictionary = PlacedPropService.place_model_at_xz(
			main, StreamIntakeBuilder.MODEL_ID, world_pos.x, world_pos.z)
	if not bool(placed.get("ok", false)):
		_show_toast("Couldn't place the intake here")
		return ""
	var prop_id := str(placed.get("prop_id", ""))
	var ground_y := float(placed.get("ground_y", world_pos.y))
	var item_id: String = model.generate_item_id()
	var site := Vector2.ZERO
	var soi := get_node_or_null("/root/SoiService")
	if soi != null and soi.has_method("world_center"):
		site = GraphSiteLayout.world_xz_to_site(
				Vector2(world_pos.x, world_pos.z), soi.call("world_center") as Vector3)
	var graph_pos := Vector2(randf_range(-90.0, 90.0), randf_range(-70.0, 70.0))
	model.add_item({
		"id": item_id,
		"type": "resource",
		"x": graph_pos.x, "y": graph_pos.y,
		"width": 90.0, "height": 100.0,
		"scope_id": _active_scope_id,
		"site_x_m": site.x, "site_z_m": site.y,
		"elevation_m": ground_y,
		"is_virtual": false,
		# A new intake ships with a real dry-weather flow and a rain response
		# (HydroSupply.default_intake_specs), so the turbine produces the moment
		# the penstock is routed. Zeros here would leave the whole
		# place-intake-then-route flow ending at 0 W with nothing saying why.
		"specs": _stream_intake_specs(prop_id),
	})
	PlacedPropService.update_prop_record(main, prop_id,
			{"graph_item_id": item_id}, false)
	var style: Dictionary = style_ov.duplicate(true)
	style.erase("route_mode")
	# add_connection() returns void and stamps a generated id when absent, so
	# mint the id here to hand it straight to the reveal/remesh path.
	var conn_id: String = model.generate_connection_id()
	model.add_connection({
		"id": conn_id,
		"source_item_id": item_id, "source_handle_id": "output",
		"target_item_id": turbine_id,
		"target_handle_id": turbine_handle if not turbine_handle.is_empty() else "res_in_0",
		"polarity": "resource", "resource_type": "water",
		"conduit_type": "poly_penstock",
		"conduit_style": style,
		"visible_3d": true, "flow_glow": true,
	})
	reveal_penstock_conduit(conn_id)
	_schedule_graph_autosave()
	_autosave_pending = true
	_flush_graph_autosave()
	_show_toast("Stream Intake placed — penstock routed to the turbine")
	return conn_id


## A penstock the player just routed must RENDER, or nothing downstream works:
## ConduitManager skips `_on_model_changed` entirely while global 3D wires are
## off, and only the focused connection is built otherwise — so the mesh never
## exists, and because `route_length_m` / the endpoint inverts are stamped
## INSIDE the rebuild, the flow engine never adopts the measured run either.
## Turning wires on + focusing + forcing one remesh is what closes that loop.
func reveal_penstock_conduit(conn_id: String) -> void:
	if conn_id.is_empty():
		return
	var mgr := _get_conduit_manager()
	if mgr == null:
		return
	# The conn carries visible_3d: true, and the manager now renders explicit
	# conns whatever the global 3D-wires toggle says — no need to flip the
	# player's global preference anymore. Focus + a forced remesh (twice: the
	# first can race empty port anchors) is all it takes.
	if mgr.has_method("set_focus_highlight"):
		mgr.call("set_focus_highlight", conn_id)
	if mgr.has_method("force_remesh"):
		mgr.call("force_remesh", conn_id)
		get_tree().create_timer(0.15).timeout.connect(
				func() -> void:
					if mgr != null and is_instance_valid(mgr) \
							and mgr.has_method("force_remesh"):
						mgr.call("force_remesh", conn_id),
				CONNECT_ONE_SHOT)
	if _graph_canvas != null:
		_graph_canvas.call("queue_redraw")


## Remove the auto-minted ∞ culvert outlet from a PENSTOCK-kind turbine: the
## sink item plus its wire, but ONLY when the sink is wired to nothing else —
## a tank the player wired for their own reasons is not ours to delete.
func _remove_auto_outlet_sink(siphon_id: String) -> void:
	if model == null or siphon_id.is_empty():
		return
	var removed := false
	for it: Dictionary in model.get_items_in_scope(
			str(model.get_item(siphon_id).get("scope_id", "root"))):
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		if not bool(sp.get("outlet_sink", false)):
			continue
		var sink_id := str(it.get("id", ""))
		var conns: Array = model.connections_for_item(sink_id)
		var only_this := not conns.is_empty()
		for cn: Dictionary in conns:
			if str(cn.get("source_item_id", "")) != siphon_id \
					and str(cn.get("target_item_id", "")) != siphon_id:
				only_this = false
				break
		if not only_this:
			continue
		for cn2: Dictionary in conns.duplicate():
			model.remove_connection(str(cn2.get("id", "")))
		model.remove_item(sink_id)
		removed = true
	if removed:
		_show_toast("Removed the culvert outlet — this turbine discharges tailwater at the machine")
		_schedule_graph_autosave()


## First siphon on the graph (selection preferred) — Elev soft-focus / frame helper.
func _find_elev_siphon_id() -> String:
	if model == null:
		return ""
	for sid in _selected_item_ids:
		var it := model.get_item(sid)
		if it.is_empty():
			continue
		if str((it.get("specs", {}) as Dictionary).get("role", "")) == "siphon_hydro":
			return sid
	if _graph_canvas != null:
		var sel := str(_graph_canvas.get("selected_item_id"))
		if not sel.is_empty():
			var it2 := model.get_item(sel)
			if not it2.is_empty() and str((it2.get("specs", {}) as Dictionary) \
					.get("role", "")) == "siphon_hydro":
				return sel
	for it3 in model.items:
		if not (it3 is Dictionary):
			continue
		if str(((it3 as Dictionary).get("specs", {}) as Dictionary).get("role", "")) \
				== "siphon_hydro":
			return str((it3 as Dictionary).get("id", ""))
	return ""


## Restore conduit visibility/glow + clear Lab drive flags when leaving Siphon.
func teardown_siphon_lab_session(siphon_id: String = "") -> void:
	# One-shot twin sync after Lab (mesh pushes were skipped while suspended).
	push_pond_levels_to_mesh(true)
	var main_unsuspend := _get_scene_main_node()
	if main_unsuspend != null and main_unsuspend.has_method("set_world_suspended_for_lab"):
		main_unsuspend.call("set_world_suspended_for_lab", false)
	var mgr := _get_conduit_manager()
	if mgr != null:
		if mgr.has_method("set_focus_highlight"):
			mgr.call("set_focus_highlight", "")
		# Restoring the pre-Lab prefs is safe now: explicitly-visible conns
		# (routed penstocks, forced tailraces) render regardless of the global
		# toggle, so nothing the player built vanishes on Lab close.
		if _lab_conduit_prefs_saved:
			if mgr.has_method("set_global_flow_glow"):
				mgr.call("set_global_flow_glow", _lab_saved_flow_glow)
			if mgr.has_method("set_global_visibility"):
				mgr.call("set_global_visibility", _lab_saved_conduits_visible)
		_lab_conduit_prefs_saved = false
	if model != null and not siphon_id.is_empty():
		var item := model.get_item(siphon_id)
		if not item.is_empty():
			var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
			if bool(specs.get("lab_sim_inflow_enabled", false)):
				specs["lab_sim_inflow_enabled"] = false
				model.update_item(siphon_id, {"specs": specs})
			# The override flag lives on the INTAKE (it is what the freeform
			# inspector reads), so clearing the turbine's toggle is not enough —
			# the intake would keep claiming a Lab override after the Lab closed.
			if _resource_flow != null \
					and _resource_flow.has_method("_stream_intake_for"):
				var intake: Dictionary = _resource_flow.call("_stream_intake_for", item)
				if not intake.is_empty():
					var isp: Dictionary = (intake.get("specs", {}) as Dictionary).duplicate(true)
					if bool(isp.get("supply_override", false)):
						isp["supply_override"] = false
						model.update_item(str(intake.get("id", "")), {"specs": isp})
		var tank := resolve_siphon_pond(siphon_id)
		if not tank.is_empty():
			var tid := str(tank.get("id", ""))
			var ts: Dictionary = (tank.get("specs", {}) as Dictionary).duplicate(true)
			if bool(ts.get("overflowing", false)):
				# Overflow is now honest (recomputed each engine tick); clear the
				# stale chip on teardown so leaving the Lab doesn't freeze it.
				ts["overflowing"] = false
				if str(ts.get("node_state", "")) == "overflow":
					ts["node_state"] = ""
				model.update_item(tid, {"specs": ts})
	if _soi_preview != null and _soi_preview.has_method("clear_lab_section_frame"):
		_soi_preview.call("clear_lab_section_frame")
	# Lab auto-Preview leaves a teal 3D hillside mesh — clear on exit so Elev
	# SoI doesn't keep the wedge after leaving Hydro Lab.
	var loader := _find_terrain_loader(_get_scene_main_node())
	if loader != null and loader.has_method("clear_watershed_preview"):
		loader.call("clear_watershed_preview")


## Show/hide the embedded Elevation cross-section 3D view. The Hydro Lab's
## turbine close-up owns the same slot when it is the active tab, and two 3D views
## rendering into one rect is both wrong and wasteful.
func set_lab_section_ct_visible(on: bool) -> void:
	if _soi_preview == null or not is_instance_valid(_soi_preview):
		return
	if _soi_preview.has_method("set_embed_visible"):
		_soi_preview.call("set_embed_visible", on)


## Frame Elevation CT on the siphon's pond + module (shared with Elev).
## Locks heading to pond → siphon/outlet side cut and a tight zoom window.
##
## Two jobs, separable on purpose. The HEADING + slice offset are what the Hydro
## Lab genuinely needs (its cross-section reads them back via _elev_section_params).
## The CAMERA framing belongs to Elevation alone — the Lab drives its own CT
## through sync_siphon_lab_section_frame, and letting it frame the canvas here is
## what used to overwrite another view's zoom. Lab callers pass set_camera=false.
func frame_elevation_for_siphon(siphon_id: String, set_camera: bool = true) -> void:
	if _graph_canvas == null or siphon_id.is_empty() or model == null:
		return
	var item := model.get_item(siphon_id)
	if item.is_empty():
		return
	var pond := resolve_siphon_pond(siphon_id)
	var pond_site := Vector2.ZERO
	if not pond.is_empty() and GraphSiteLayout.has_site_coords(pond):
		pond_site = GraphSiteLayout.site_xz(pond)
	elif GraphSiteLayout.has_site_coords(item):
		pond_site = GraphSiteLayout.site_xz(item)
	# Aim cut along pond → siphon (fallback siphon → outlet sink).
	var aim := GraphSiteLayout.site_xz(item) if GraphSiteLayout.has_site_coords(item) \
			else pond_site + Vector2(8.0, 0.0)
	var outlet := {}
	if _resource_flow != null and _resource_flow.has_method("_resolve_siphon_outlet_tank"):
		outlet = _resource_flow.call("_resolve_siphon_outlet_tank", item)
	if not outlet.is_empty() and GraphSiteLayout.has_site_coords(outlet):
		aim = GraphSiteLayout.site_xz(outlet)
	var delta := aim - pond_site
	if delta.length_squared() < 0.25:
		delta = Vector2(1.0, 0.0)
	var heading := atan2(delta.y, delta.x)
	_graph_canvas.set("elevation_heading_rad", heading)
	var along_dir := Vector2(cos(heading), sin(heading))
	var cross_dir := Vector2(-sin(heading), cos(heading))
	# CT slice = pond's cross-axis offset (not SoI centre 0 — ponds often sit
	# tens of metres off-axis, e.g. +47 m). Keeps DEM + 3D cut through the basin.
	var pond_slice := pond_site.dot(cross_dir)
	_graph_canvas.set("elevation_section_offset_m", pond_slice)
	_sync_elev_slice_slider_from_canvas(pond_slice)
	if _graph_canvas.has_signal("elevation_heading_changed"):
		_graph_canvas.emit_signal("elevation_heading_changed", heading)
	if _graph_canvas.has_signal("elevation_section_offset_changed"):
		_graph_canvas.emit_signal("elevation_section_offset_changed", pond_slice)
	var pond_along := pond_site.dot(along_dir)
	# Push heading/slice into the SoI section camera (anchors drive look/ortho).
	# Ahead of the framing below because both halves want it and only the framing
	# half is optional — these are pure heading/offset writes, order-independent.
	if _soi_preview != null:
		if _soi_preview.has_method("set_section_heading"):
			_soi_preview.call("set_section_heading", heading)
		if _soi_preview.has_method("set_section_offset"):
			_soi_preview.call("set_section_offset", pond_slice)
		# Elev owns pan/zoom; while Hydro Lab is open, Lab CT frame stays in charge.
		if _graph_view_mode != GraphSiteLayout.VIEW_SIPHON \
				and _soi_preview.has_method("clear_lab_section_frame"):
			_soi_preview.call("clear_lab_section_frame")
	call_deferred("_force_soi_preview_layout_sync")
	if not set_camera:
		# Hydro Lab: heading + slice are all it wanted. Framing the canvas from
		# here would write whichever view's camera is live.
		return
	# Cap footprint so large OSM ponds don't zoom the CT out to a void.
	var half_w := 4.0
	if not pond.is_empty():
		var ps: Dictionary = pond.get("specs", {}) as Dictionary
		half_w = maxf(float(ps.get("footprint_w_m", 8.0)) * 0.5, 2.0)
		half_w = maxf(half_w, maxf(float(ps.get("footprint_d_m", 0.0)), 2.0) * 0.5)
		if _graph_canvas.has_method("_elevation_pond_half_width_m"):
			half_w = maxf(half_w, float(_graph_canvas.call(
					"_elevation_pond_half_width_m", pond, ps, along_dir)))
	half_w = clampf(half_w, 2.0, 10.0)
	var module_along := 3.5
	if GraphSiteLayout.has_site_coords(item):
		module_along = GraphSiteLayout.site_xz(item).dot(along_dir) - pond_along
		if absf(module_along) < 0.5:
			module_along = 3.5
	module_along = clampf(module_along, -12.0, 12.0)
	var a0 := pond_along - half_w - 1.0
	var a1 := pond_along + maxf(module_along + 3.0, half_w + 1.5)
	if module_along < 0.0:
		a0 = pond_along + minf(module_along - 3.0, -half_w - 1.0)
		a1 = pond_along + half_w + 1.0
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var module_m := float(specs.get("module_elev_m", NAN))
	var start_m := float(specs.get("siphon_start_m", module_m))
	var break_m := float(specs.get("siphon_break_m", module_m))
	var floor_m := float((pond.get("specs", {}) as Dictionary).get("floor_m", NAN)) \
			if not pond.is_empty() else NAN
	var rim_m := float((pond.get("specs", {}) as Dictionary).get("rim_m", NAN)) \
			if not pond.is_empty() else NAN
	if is_nan(module_m):
		module_m = 0.0
	if is_nan(start_m):
		start_m = module_m
	if is_nan(break_m):
		break_m = module_m
	if is_nan(floor_m):
		floor_m = minf(module_m, break_m) - 1.5
	if is_nan(rim_m):
		rim_m = maxf(module_m, start_m) + 0.8
	# Frame pond + prime/break only — outlet invert (~−9 m) blew the CT into void.
	var y0 := minf(floor_m, minf(break_m, module_m)) - 0.35
	var y1 := maxf(rim_m, maxf(start_m, module_m)) + 0.45
	var vp: Vector2 = _graph_canvas.size as Vector2
	if vp.x < 64.0 or vp.y < 64.0:
		vp = Vector2(720.0, 480.0)
	if _graph_canvas.has_method("frame_elevation_window"):
		_graph_canvas.call("frame_elevation_window", a0, a1, y0, y1, vp, 0.05)
	# Look-at = turbine (along + elev), not pond midpoint — zoom still fits pond.
	var turbine_along := pond_along + module_along
	if _graph_canvas.has_method("set_elev_view_state") \
			and _graph_canvas.has_method("get_elev_view_state"):
		var st: Dictionary = _graph_canvas.call("get_elev_view_state") as Dictionary
		st["along_m"] = turbine_along
		st["elev_m"] = module_m
		_graph_canvas.call("set_elev_view_state", st)


func _sync_desire_menu_labels() -> void:
	var site_only := _graph_view_mode == GraphSiteLayout.VIEW_SITE
	for id in [VIEW_MODE_DESIRE_LINES, VIEW_MODE_DESIRE_TRAILS]:
		_vm_set_disabled(int(id), not site_only)
	# The channel/retention filters and the 3D drape apply in the world too,
	# so they stay live outside Site Plan.
	_vm_set_checked(VIEW_MODE_DESIRE_3D, _desire_3d_on)
	_vm_set_checked(VIEW_MODE_DESIRE_LINES, _desire_lines_on)
	if _graph_canvas != null:
		_vm_set_checked(VIEW_MODE_DESIRE_TRAILS,
				bool(_graph_canvas.get("npc_trails_enabled")))
	_vm_set_text(VIEW_MODE_DESIRE_CHANNEL, "Filter: %s" % _desire_channel_label())
	_vm_set_text(VIEW_MODE_DESIRE_WINDOW, "Remember: %s" %
			NpcDesireMap.retention_label(_desire_window).to_lower())


func _sync_view_mode_menu_checks() -> void:
	if _view_mode_menu == null:
		return
	_sync_desire_menu_labels()
	# Mode radios no longer live in this menu (the chip strip is the single
	# mode switcher); only the per-view extras need syncing. All lookups go
	# through _vm_set_* since the items are spread across submenus now.
	_vm_set_checked(VIEW_MODE_SOI_BUBBLE, _freeform_soi_bubble)
	_vm_set_disabled(VIEW_MODE_SOI_BUBBLE,
			_graph_view_mode != GraphSiteLayout.VIEW_FREEFORM)
	_vm_set_checked(VIEW_MODE_ELEV_3D, _elevation_3d_section)
	_vm_set_disabled(VIEW_MODE_ELEV_3D,
			_graph_view_mode != GraphSiteLayout.VIEW_ELEVATION)
	var elev_in := _graph_view_mode == GraphSiteLayout.VIEW_ELEVATION
	for elev_id in [VIEW_MODE_ELEV_DEM, VIEW_MODE_ELEV_CHIPS, VIEW_MODE_ELEV_PORTS,
			VIEW_MODE_ELEV_SCHEM_WIRES, VIEW_MODE_ELEV_PROJ_PIPES]:
		_vm_set_disabled(int(elev_id), not elev_in)
	if _graph_canvas != null:
		_vm_set_checked(VIEW_MODE_NODE_CARDS,
				str(_graph_canvas.get("node_display_mode")) == "card")
		_vm_set_checked(VIEW_MODE_PREVIEW_LABELS,
				bool(_graph_canvas.get("show_preview_labels")))
		_vm_set_checked(VIEW_MODE_RADIAL,
				bool(_graph_canvas.get("radial_layout_mode")))
		var site_in := _graph_view_mode == GraphSiteLayout.VIEW_SITE
		_vm_set_checked(VIEW_MODE_SITE_CHIPS, bool(_graph_canvas.get("site_show_chips")))
		_vm_set_disabled(VIEW_MODE_SITE_CHIPS, not site_in)
		_vm_set_checked(VIEW_MODE_SITE_PORTS, bool(_graph_canvas.get("site_show_ports")))
		_vm_set_disabled(VIEW_MODE_SITE_PORTS, not site_in)
		_vm_set_checked(VIEW_MODE_SITE_LIVE_LIGHT, _site_elev_live_lighting)
		var sw := str(_graph_canvas.get("site_wire_mode"))
		for pair in [
			[VIEW_MODE_SITE_WIRE_3D, "prefer_3d"],
			[VIEW_MODE_SITE_WIRE_METRO, "metro"],
			[VIEW_MODE_SITE_WIRE_NONE, "none"],
		]:
			_vm_set_checked(int(pair[0]), sw == str(pair[1]))
			_vm_set_disabled(int(pair[0]), not site_in)
		_sync_elev_overlay_menu_checks()
	# Mode chip strip mirrors the active view (Snowglobe is modal, not sticky).
	for mid in _mode_chip_btns:
		var btn: Button = _mode_chip_btns[mid] as Button
		if btn == null:
			continue
		var on := false
		match str(mid):
			"freeform":
				on = _graph_view_mode == GraphSiteLayout.VIEW_FREEFORM
			"site":
				on = _graph_view_mode == GraphSiteLayout.VIEW_SITE
			"elevation":
				on = _graph_view_mode == GraphSiteLayout.VIEW_ELEVATION
			"snowglobe":
				on = false
		btn.set_pressed_no_signal(on)


func _set_elevation_exaggeration(ex: float) -> void:
	if _graph_canvas != null:
		_graph_canvas.set("elevation_exaggeration", ex)
		_graph_canvas.call("queue_redraw")
	if _view_mode_menu != null:
		_vm_set_checked(VIEW_MODE_EXAG_1X, is_equal_approx(ex, 1.0))
		_vm_set_checked(VIEW_MODE_EXAG_5X, is_equal_approx(ex, 5.0))


func _toggle_elev_overlay(id: int) -> void:
	if _graph_canvas == null:
		return
	var key := ""
	match id:
		VIEW_MODE_ELEV_DEM:
			key = "elev_show_dem_overlay"
		VIEW_MODE_ELEV_CHIPS:
			key = "elev_show_chips"
		VIEW_MODE_ELEV_PORTS:
			key = "elev_show_ports"
		VIEW_MODE_ELEV_SCHEM_WIRES:
			key = "elev_show_schematic_wires"
		VIEW_MODE_ELEV_PROJ_PIPES:
			key = "elev_show_projected_pipes"
	if key.is_empty():
		return
	_graph_canvas.set(key, not bool(_graph_canvas.get(key)))
	_graph_canvas.call("queue_redraw")
	_sync_view_mode_menu_checks()
	_schedule_graph_autosave()


func _sync_elev_overlay_menu_checks() -> void:
	if _graph_canvas == null:
		return
	var pairs := {
		VIEW_MODE_ELEV_DEM: "elev_show_dem_overlay",
		VIEW_MODE_ELEV_CHIPS: "elev_show_chips",
		VIEW_MODE_ELEV_PORTS: "elev_show_ports",
		VIEW_MODE_ELEV_SCHEM_WIRES: "elev_show_schematic_wires",
		VIEW_MODE_ELEV_PROJ_PIPES: "elev_show_projected_pipes",
	}
	for mid in pairs:
		_vm_set_checked(int(mid), bool(_graph_canvas.get(pairs[mid])))


## Hint only — never force-enable 3D wires (GPU remesh storm + CT = TDR risk).
func _maybe_toast_elev_3d_wires_hint() -> void:
	if _elev_3d_wires_toast_shown:
		return
	var ssc := get_node_or_null("/root/SimSettingsController")
	if ssc != null and bool(ssc.get("conduits_3d_visible")):
		return
	_elev_3d_wires_toast_shown = true
	_show_toast("Elevation CT: enable Timeline “3D wires” for physical pipes (off by default)")


## True when the graph's Elevation/Siphon SoI section SubViewport is live.
## Used by main.gd to skip god-ray fog while CT owns the shared World3D.
func is_soi_section_preview_active() -> bool:
	if not visible or _soi_preview == null or not is_instance_valid(_soi_preview):
		return false
	if not bool(_soi_preview.get("active")):
		return false
	if _soi_preview.has_method("is_section_mode"):
		return bool(_soi_preview.call("is_section_mode"))
	return false


func _rotate_elevation_heading(delta_rad: float) -> void:
	if _graph_canvas == null:
		return
	var h := fposmod(float(_graph_canvas.get("elevation_heading_rad")) + delta_rad, TAU)
	_graph_canvas.set("elevation_heading_rad", h)
	_graph_canvas.call("queue_redraw")
	_on_elevation_heading_changed(h)


func _elev_section_preview_active() -> bool:
	return _elevation_3d_section and (
			_graph_view_mode == GraphSiteLayout.VIEW_ELEVATION \
			or _graph_view_mode == GraphSiteLayout.VIEW_SIPHON)


func _on_elevation_heading_changed(heading_rad: float) -> void:
	if _soi_preview != null and _soi_preview.has_method("set_section_heading") \
			and _elev_section_preview_active():
		_soi_preview.call("set_section_heading", heading_rad)
	_schedule_graph_autosave()


func _on_elevation_section_offset_changed(offset_m: float) -> void:
	_sync_elev_slice_slider_from_canvas(offset_m)
	if _soi_preview != null and _soi_preview.has_method("set_section_offset") \
			and _elev_section_preview_active():
		_soi_preview.call("set_section_offset", offset_m)
	_schedule_graph_autosave()


func _on_elev_slice_slider_changed(v: float) -> void:
	if _graph_canvas == null:
		return
	_graph_canvas.set("elevation_section_offset_m", v)
	if _elev_slice_lbl != null:
		_elev_slice_lbl.text = "%+.0f m" % v
	_graph_canvas.call("queue_redraw")
	_on_elevation_section_offset_changed(v)


func _sync_elev_slice_slider_from_canvas(offset_m: float) -> void:
	if _elev_slice_slider != null:
		_elev_slice_slider.set_value_no_signal(offset_m)
	if _elev_slice_lbl != null:
		_elev_slice_lbl.text = "%+.0f m" % offset_m


func _sync_elev_slice_row() -> void:
	if _elev_slice_row == null:
		return
	var on := _graph_view_mode == GraphSiteLayout.VIEW_ELEVATION
	_elev_slice_row.visible = on
	if _hydro_section_lbl != null:
		_hydro_section_lbl.visible = on
	if _elev_hydro_lab_btn != null:
		_elev_hydro_lab_btn.visible = on
	if not on:
		return
	var r_m := 150.0
	var soi := get_node_or_null("/root/SoiService")
	if soi != null and soi.has_method("radius_m"):
		r_m = float(soi.call("radius_m"))
	if _elev_slice_slider != null:
		_elev_slice_slider.min_value = -r_m
		_elev_slice_slider.max_value = r_m
		var cur := 0.0
		if _graph_canvas != null:
			cur = float(_graph_canvas.get("elevation_section_offset_m"))
		_elev_slice_slider.set_value_no_signal(clampf(cur, -r_m, r_m))
		if _elev_slice_lbl != null:
			_elev_slice_lbl.text = "%+.0f m" % cur
	refresh_hydro_section_panel()


## Reset CT section: heading ≈ N/S of site (0° = east section → looking north),
## offset 0, zoom fit SoI.
func _reset_elevation_section() -> void:
	if _graph_canvas != null:
		_graph_canvas.set("elevation_heading_rad", 0.0)
		_graph_canvas.set("elevation_section_offset_m", 0.0)
		_graph_canvas.call("queue_redraw")
	_sync_elev_slice_slider_from_canvas(0.0)
	if _soi_preview != null and _soi_preview.has_method("reset_section"):
		_soi_preview.call("reset_section", 0.0)
	_on_elevation_heading_changed(0.0)
	_on_elevation_section_offset_changed(0.0)
	_show_toast("Section reset · heading east · slice 0 · zoom fit")


func _seed_site_from_freeform() -> void:
	var n := _auto_seed_site_unplaced()
	_show_toast("Seeded site coords for %d nodes" % n)
	if _graph_canvas != null:
		_graph_canvas.call("queue_redraw")
	_schedule_graph_autosave()


## Opt-in Site Plan embodiment (View options ▾). Refuses until TerrainLoader
## has a loaded prop layer so we never save twins over an empty in-memory set.
func _embody_site_twins_manual() -> void:
	var main := _get_scene_main_node()
	var loader := TerrainSurfaceQuery.find_terrain_loader(main) if main != null else null
	if loader == null or loader.get("_placed_prop_layer") == null:
		_show_toast("Wait for the map to finish loading before embodying twins")
		return
	if loader.get("load_completed") == false:
		_show_toast("Wait for the map to finish loading before embodying twins")
		return
	var twins := ensure_all_site_twins()
	if twins > 0:
		_show_toast("Embodied %d Site Plan twin%s" % [
			twins, "" if twins == 1 else "s"])
	else:
		_show_toast("All site-placed nodes already have 3D twins")
	_schedule_graph_autosave()


## Quiet seed for root-scope items still missing site_* (Site Plan enter + menu).
func _auto_seed_site_unplaced() -> int:
	if model == null:
		return 0
	var r_m := 150.0
	var soi := get_node_or_null("/root/SoiService")
	if soi != null and soi.has_method("radius_m"):
		r_m = float(soi.call("radius_m"))
	# Only root-scope — nested compound children stay schematic-only.
	var root_items: Array = model.get_items_in_scope("root") \
			if model.has_method("get_items_in_scope") else model.items
	var n := GraphSiteLayout.seed_site_from_freeform(root_items, r_m)
	# Persist via model.changed — seed mutated dicts in-place; poke once.
	if n > 0 and model != null:
		model.changed.emit("update_item")
		if _graph_canvas != null:
			_graph_canvas.call("queue_redraw")
	return n


func _backfill_site_from_world() -> void:
	## Reverse-sync site coords from bound props / OSM solar centroids.
	if model == null:
		return
	var soi := get_node_or_null("/root/SoiService")
	if soi == null or not soi.has_method("world_center"):
		return
	var center: Vector3 = soi.call("world_center")
	var main := _get_scene_main_node()
	var changed_any := false
	for item: Dictionary in model.items:
		if GraphSiteLayout.has_site_coords(item):
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		var prop_id := str(specs.get("bound_prop_id", ""))
		if not prop_id.is_empty() and main != null:
			var xz: Variant = _world_xz_for_bound_prop(main, prop_id)
			if xz is Vector2:
				var site := GraphSiteLayout.world_xz_to_site(xz as Vector2, center)
				model.update_item(str(item.get("id", "")), {
					"site_x_m": site.x, "site_z_m": site.y})
				changed_any = true
				continue
		var osm_tag := str(specs.get("osm_tag", ""))
		if not osm_tag.is_empty() and main != null:
			var sxz: Variant = _world_xz_for_osm_tag(main, osm_tag)
			if sxz is Vector2:
				var site2 := GraphSiteLayout.world_xz_to_site(sxz as Vector2, center)
				model.update_item(str(item.get("id", "")), {
					"site_x_m": site2.x, "site_z_m": site2.y})
				changed_any = true
	if changed_any and _graph_canvas != null:
		_graph_canvas.call("queue_redraw")


func _world_xz_for_bound_prop(main: Node, prop_id: String) -> Variant:
	var loader := _find_terrain_loader(main)
	if loader == null:
		return null
	# Prefer PlacedPropService scene layer lookup via runtime nodes.
	var props_parent := main.find_child("PlacedProps", true, false)
	if props_parent == null and loader != null:
		props_parent = loader.find_child("PlacedProps", true, false)
	if props_parent != null:
		for c in props_parent.get_children():
			if str(c.get("prop_id")) == prop_id or str(c.name) == prop_id:
				var p: Vector3 = (c as Node3D).global_position
				return Vector2(p.x, p.z)
	var layer: Variant = loader.get("_placed_prop_layer")
	if layer != null and layer.has_method("find_by_id"):
		var rec: Dictionary = layer.call("find_by_id", prop_id)
		if not rec.is_empty():
			return Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
	return null


## Full world position (x,y,z) of a placed prop by id, or null. Prefers the live
## scene node (authoritative during a move) and falls back to the saved record.
func _world_pos_for_bound_prop(main: Node, prop_id: String) -> Variant:
	var loader := _find_terrain_loader(main)
	if loader == null:
		return null
	var props_parent := main.find_child("PlacedProps", true, false)
	if props_parent == null:
		props_parent = loader.find_child("PlacedProps", true, false)
	if props_parent != null:
		for c in props_parent.get_children():
			if str(c.get("prop_id")) == prop_id or str(c.name) == prop_id:
				return (c as Node3D).global_position
	var layer: Variant = loader.get("_placed_prop_layer")
	if layer != null and layer.has_method("find_by_id"):
		var rec: Dictionary = layer.call("find_by_id", prop_id)
		if not rec.is_empty():
			return Vector3(float(rec.get("x", 0.0)), float(rec.get("y", 0.0)),
				float(rec.get("z", 0.0)))
	return null


## Write the site_x_m / site_z_m / elevation_m of every graph node bound to
## `prop_id` from the prop's live 3D world position. Called whenever a placed
## prop is created or moved (placed_prop_service.confirm_placement / move_prop_xz
## and terrain_loader._confirm_prop_reposition) so Site/Elevation views track the
## 3D twin. Safe no-op if the SoI, prop, or node is missing.
func sync_site_from_prop(prop_id: String) -> void:
	if model == null or prop_id.is_empty():
		return
	var soi := get_node_or_null("/root/SoiService")
	if soi == null or not soi.has_method("world_center"):
		return
	var center: Vector3 = soi.call("world_center")
	var main := _get_scene_main_node()
	if main == null:
		return
	var pos_v: Variant = _world_pos_for_bound_prop(main, prop_id)
	if not (pos_v is Vector3):
		return
	var world: Vector3 = pos_v as Vector3
	var site := GraphSiteLayout.world_xz_to_site(Vector2(world.x, world.z), center)
	var changed_any := false
	for item: Dictionary in model.items:
		var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		if str(specs.get("bound_prop_id", "")) != prop_id:
			continue
		var patch := {
			"site_x_m": site.x, "site_z_m": site.y, "elevation_m": world.y}
		# Siphon start/break track the 3D turbine via offsets → absolutes.
		if str(specs.get("role", "")) == "siphon_hydro":
			specs["module_elev_m"] = world.y
			SiphonHydraulics.apply_resolved_levels(specs, world.y)
			patch["specs"] = specs
		model.update_item(str(item.get("id", "")), patch)
		changed_any = true
	if changed_any:
		if _graph_canvas != null:
			_graph_canvas.call("queue_redraw")
		_schedule_graph_autosave()
		# Bound prop moved — rebuild 3D conduits that terminate on it.
		var mgr := _get_conduit_manager()
		if mgr != null and mgr.has_method("invalidate_obstacle_cache"):
			mgr.call("invalidate_obstacle_cache")
		if mgr != null and mgr.has_method("sync_all"):
			mgr.call("sync_all")


func _world_xz_for_osm_tag(main: Node, tag: String) -> Variant:
	var loader := _find_terrain_loader(main)
	if loader == null or not loader.has_method("get_solar_array_centroid"):
		# Parse tag "osm_solar_%d_%d" as rounded metres if helper missing.
		if tag.begins_with("osm_solar_"):
			var parts := tag.trim_prefix("osm_solar_").split("_")
			if parts.size() >= 2:
				return Vector2(float(parts[0]), float(parts[1]))
		return null
	var cent: Variant = loader.call("get_solar_array_centroid", tag)
	return cent


## Resolve `elevation_m` for every placed graph item, in this precedence:
##
##   1. the bound prop's own connection-port / anchor height, via the SAME
##      resolver the 3D conduit builder uses (ConduitManager.anchor_global_for_item)
##   2. an elevation the engine owns (a siphon module's level, edited in the Lab)
##   3. terrain ground Y — the original behaviour, still right for unbound items
##
## Rung 1 is the fix for "the penstock ends in a different place in elevation than
## it does in 3D". This function used to stamp EVERY item to ground Y, so an
## elevation-view chip sat on the DEM line while the 3D pipe terminated at a port
## on the prop — a turbine inlet flange or a culvert invert, metres away.
## Called once by TerrainLoader when a map has finished loading.
##
## Before this, elevations were resolved ONLY on entry to Site / Elevation / the
## Hydro Lab. A map that booted straight into first person therefore ran every
## conduit off whatever the save carried — and an unbound outlet sink saved at
## elevation 0 anchored its culvert at world Y ≈ 0 while the turbine sat 80 m
## below it, so the pipe launched into the sky until the player opened the graph.
## Re-syncs the conduits afterwards so anything already built at the wrong height
## is re-routed rather than left pointing at the horizon.
func resolve_site_elevations_after_load() -> void:
	if model == null:
		return
	_backfill_site_from_world()
	_refresh_item_elevations()
	var mgr := _get_conduit_manager()
	if mgr != null:
		if mgr.has_method("invalidate_obstacle_cache"):
			mgr.call("invalidate_obstacle_cache")
		if mgr.has_method("sync_all"):
			mgr.call("sync_all")


func _refresh_item_elevations() -> void:
	if model == null:
		return
	var soi := get_node_or_null("/root/SoiService")
	if soi == null or not soi.has_method("world_center"):
		return
	var center: Vector3 = soi.call("world_center")
	var main := _get_scene_main_node()
	var tree := get_tree()
	for item: Dictionary in model.items:
		if not GraphSiteLayout.has_site_coords(item):
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		# The flow engine and the Lab's level drag both own a siphon module's
		# elevation; re-stamping it here would fight them every frame.
		if str(specs.get("role", "")) == "siphon_hydro" \
				and not is_nan(float(specs.get("module_elev_m", NAN))):
			continue
		var elev := NAN
		if not str(specs.get("bound_prop_id", "")).is_empty() and tree != null:
			var anchor := ConduitManager.anchor_global_for_item(item, tree, "", main)
			if is_finite(anchor.x) and is_finite(anchor.y):
				elev = anchor.y
		if is_nan(elev):
			var site := GraphSiteLayout.site_xz(item)
			var wxz := GraphSiteLayout.site_to_world_xz(site, center)
			elev = float(center.y)
			if soi.has_method("ground_y_at"):
				elev = float(soi.call("ground_y_at", wxz.x, wxz.y))
		if is_nan(elev):
			continue
		if absf(float(item.get("elevation_m", NAN)) - elev) > 0.005 \
				or is_nan(float(item.get("elevation_m", NAN))):
			model.update_item(str(item.get("id", "")), {"elevation_m": elev})


func _refresh_site_autoroutes() -> void:
	if model == null:
		return
	var main := _get_scene_main_node()
	var soi := get_node_or_null("/root/SoiService")
	if main == null or soi == null or not soi.has_method("world_center"):
		return
	# Do NOT auto-spawn generic tank/box twins — player places a real model first.
	var center: Vector3 = soi.call("world_center")
	var n := GraphSiteAutoroute.refresh_all(model, main, center)
	if _conduit_manager != null:
		if _conduit_manager.has_method("invalidate_obstacle_cache"):
			_conduit_manager.call("invalidate_obstacle_cache")
		if _conduit_manager.has_method("invalidate_astar"):
			_conduit_manager.call("invalidate_astar")
	if n > 0 or _conduit_manager != null:
		call_deferred("_init_conduit_manager")


func _on_soi_preview_toggled(on: bool) -> void:
	# Legacy entry: maps to freeform SoI bubble (does not switch view mode).
	_freeform_soi_bubble = on
	if _graph_view_mode != GraphSiteLayout.VIEW_FREEFORM:
		_apply_graph_view_mode(GraphSiteLayout.VIEW_FREEFORM)
		return
	_sync_view_mode_menu_checks()
	_sync_soi_preview_for_mode()


## True while the live SoI SubViewport backdrop is rendering (main.gd uses this
## to keep sun/sky updates running for the preview).
func is_soi_preview_active() -> bool:
	return _soi_preview != null and bool(_soi_preview.get("active"))


func _ensure_soi_preview() -> void:
	if _soi_preview != null and is_instance_valid(_soi_preview):
		return
	_soi_preview = _SOI_PREVIEW_SCRIPT.new()
	_soi_preview.name = "GraphSoiPreviewService"
	add_child(_soi_preview)
	if _soi_preview.has_method("setup"):
		_soi_preview.call("setup", self, _graph_canvas)
	# Hand the canvas a reference so it can use the preview camera as the
	# projection authority for orbited Site/Elevation views (workstream E).
	if _graph_canvas != null and is_instance_valid(_graph_canvas):
		_graph_canvas.set("soi_preview_service", _soi_preview)


## Called when the graph Control is hidden (G toggle). Ensures Lab session
## flags/world suspend/watershed preview cannot stick after leaving the UI.
func _force_teardown_siphon_lab_on_graph_close() -> void:
	var leave_id := ""
	if _siphon_lab_modal != null and is_instance_valid(_siphon_lab_modal):
		leave_id = str(_siphon_lab_modal.get("_item_id"))
		if _siphon_lab_modal.has_method("exit_view"):
			_siphon_lab_modal.call("exit_view")
	teardown_siphon_lab_session(leave_id)
	# Park the mode the player opened the Lab from (else Elevation) so the next
	# G open isn't the Lab.
	if _graph_view_mode == GraphSiteLayout.VIEW_SIPHON:
		var back := _lab_return_mode
		_lab_return_mode = ""
		if back.is_empty() or back == GraphSiteLayout.VIEW_SIPHON:
			back = GraphSiteLayout.VIEW_ELEVATION
		_graph_view_mode = back
		if _graph_canvas != null:
			# set_view_mode, not a raw set: leaving the Lab must restore the
			# framing `back` was left at, not inherit the Lab's.
			_graph_canvas.call("set_view_mode", back)
		_sync_view_mode_menu_checks()


## Tear down graph SoI SubViewport and clear autoload clip so FPS world stays open.
func _shutdown_soi_preview_world_effects() -> void:
	if _soi_preview != null and is_instance_valid(_soi_preview):
		if _soi_preview.has_method("set_active"):
			_soi_preview.call("set_active", false)
		if _soi_preview.has_method("teardown"):
			_soi_preview.call("teardown")
	var soi := get_node_or_null("/root/SoiService")
	if soi == null:
		return
	if soi.has_method("clear_graph_preview_world_effects"):
		soi.call("clear_graph_preview_world_effects")
	elif soi.has_method("set_graph_preview_active"):
		soi.call("set_graph_preview_active", false)


func _on_bg_alpha_changed(value: float) -> void:
	# Legacy hook kept for any external callers; BG slider was replaced by SoI view.
	if _bg_rect != null and is_instance_valid(_bg_rect):
		_bg_rect.color = Color(C_BG.r, C_BG.g, C_BG.b, value)
	if _graph_canvas != null and is_instance_valid(_graph_canvas):
		_graph_canvas.set("canvas_bg_alpha", value)


func _restyle_btn_primary(b: Button) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C_PRIMARY.r * 0.28, C_PRIMARY.g * 0.28, C_PRIMARY.b * 0.28, 1.0)
	sb.border_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left   = 13.0
	sb.content_margin_right  = 13.0
	sb.content_margin_top    = 6.0
	sb.content_margin_bottom = 6.0
	var sb_h := sb.duplicate() as StyleBoxFlat
	sb_h.bg_color = Color(C_PRIMARY.r * 0.40, C_PRIMARY.g * 0.40, C_PRIMARY.b * 0.40, 1.0)
	b.add_theme_stylebox_override("normal",  sb)
	b.add_theme_stylebox_override("hover",   sb_h)
	b.add_theme_stylebox_override("pressed", sb_h)
	b.add_theme_color_override("font_color", Color(C_PRIMARY.r * 1.4, C_PRIMARY.g * 1.4, C_PRIMARY.b * 1.4, 1.0).clamp())
	b.add_theme_font_size_override("font_size", 14)


func _set_mode_btn_style(b: Button, active: bool) -> void:
	if b == null:
		return
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(4)
	sb.content_margin_left   = 16.0
	sb.content_margin_right  = 16.0
	sb.content_margin_top    = 6.0
	sb.content_margin_bottom = 6.0
	if active:
		sb.bg_color = C_PRIMARY
		b.add_theme_color_override("font_color", C_BG)
	else:
		sb.bg_color = C_PANEL
		b.add_theme_color_override("font_color", C_TEXT_S)
	b.add_theme_stylebox_override("normal",  sb)
	b.add_theme_stylebox_override("hover",   sb)
	b.add_theme_stylebox_override("pressed", sb)
	b.add_theme_font_size_override("font_size", 13)


# ---------------------------------------------------------------------------
# Left sidebar
# ---------------------------------------------------------------------------

func _build_left_sidebar() -> Control:
	var bar := Control.new()
	bar.name         = "LeftSidebar"
	bar.mouse_filter = Control.MOUSE_FILTER_STOP
	bar.clip_contents = true

	# Background
	var bg := ColorRect.new()
	bg.color        = C_SIDEBAR
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor_full(bg)
	bar.add_child(bg)

	# Right border
	var bdr := ColorRect.new()
	bdr.color        = C_BORDER
	bdr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor(bdr, 1.0, 0.0, 1.0, 1.0, -1.0, 0.0, 0.0, 0.0)
	bar.add_child(bdr)

	# Scrollable content — fills sidebar height so content meets the
	# timeline inset instead of leaving a dead band at the bottom.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_anchor_full(scroll)
	bar.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 0)
	scroll.add_child(vbox)

	_graph_dashboard = _DASHBOARD_SCRIPT.new() as GraphDashboardPanel
	_graph_dashboard.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_graph_dashboard)

	var design_content := VBoxContainer.new()
	design_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	design_content.add_theme_constant_override("separation", 0)
	vbox.add_child(design_content)

	design_content.add_child(_build_score_section(
		"⚡ SYSTEM TELEMETRY", [
			["Array Wmp",       "0 W",   "scoreArrayWmp"],
			["Array Voc",       "0 V",   "scoreArrayVoc"],
			["Array Imp",       "0 A",   "scoreArrayImp"],
			["Array Config",    "—",     "scoreArrayConfig"],
			["Battery",         "0 kWh", "scoreBattery"],
			["Battery Config",  "—",     "scoreBatteryConfig"],
			["Battery Voltage", "—",     "scoreBatteryVoltage"],
			["Optimization",    "0%",    "scoreOptimization"],
			["Total Cost",      "$0",    "scoreTotalCost"],
		]
	))

	design_content.add_child(_build_score_section(
		"💰 COST BREAKDOWN", [
			["Solar Panels",        "$0.00", "costPanels"],
			["Inverter/Controller", "$0.00", "costInverter"],
			["Batteries",           "$0.00", "costBatteries"],
			["Components",          "$0.00", "costComponents"],
			["Wires",               "$0.00", "costWires"],
			["Total",               "$0.00", "costTotal"],
		],
		"costTotal"
	))

	return bar


func _build_score_section(title: String, rows: Array,
		bold_id: String = "") -> VBoxContainer:
	var section := VBoxContainer.new()
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.add_theme_constant_override("separation", 0)

	# Section header
	var hdr_bg := PanelContainer.new()
	var hdr_sb := StyleBoxFlat.new()
	hdr_sb.bg_color     = C_PANEL
	hdr_sb.border_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.25)
	hdr_sb.set_border_width(SIDE_BOTTOM, 1)
	hdr_sb.content_margin_left   = 12.0
	hdr_sb.content_margin_right  = 12.0
	hdr_sb.content_margin_top    = 8.0
	hdr_sb.content_margin_bottom = 8.0
	hdr_bg.add_theme_stylebox_override("panel", hdr_sb)
	var hdr_lbl := Label.new()
	hdr_lbl.text = title
	hdr_lbl.add_theme_color_override("font_color", C_PRIMARY)
	hdr_lbl.add_theme_font_size_override("font_size", 11)
	hdr_bg.add_child(hdr_lbl)
	section.add_child(hdr_bg)

	# Rows
	var rows_vbox := VBoxContainer.new()
	rows_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows_vbox.add_theme_constant_override("separation", 0)
	section.add_child(rows_vbox)

	for row in rows:
		var row_id: String  = row[2]
		var is_bold := (row_id == bold_id)

		# Divider line above the total row
		if is_bold:
			var div := ColorRect.new()
			div.color                = C_BORDER
			div.custom_minimum_size  = Vector2(0.0, 1.0)
			div.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			rows_vbox.add_child(div)

		var row_pc := PanelContainer.new()
		row_pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var row_sb := StyleBoxFlat.new()
		row_sb.bg_color     = C_BG if is_bold else Color(0.0, 0.0, 0.0, 0.0)
		row_sb.border_color = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.35)
		row_sb.set_border_width(SIDE_BOTTOM, 1)
		row_sb.content_margin_left   = 12.0
		row_sb.content_margin_right  = 12.0
		row_sb.content_margin_top    = 6.0
		row_sb.content_margin_bottom = 6.0
		row_pc.add_theme_stylebox_override("panel", row_sb)

		var row_hbox := HBoxContainer.new()
		row_pc.add_child(row_hbox)

		var key_lbl := Label.new()
		key_lbl.text                  = row[0]
		key_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		key_lbl.add_theme_color_override("font_color",
			C_TEXT if is_bold else C_TEXT_S)
		key_lbl.add_theme_font_size_override("font_size", 11)
		row_hbox.add_child(key_lbl)

		var val_lbl := Label.new()
		val_lbl.name                    = row_id
		val_lbl.text                    = row[1]
		val_lbl.horizontal_alignment    = HORIZONTAL_ALIGNMENT_RIGHT
		val_lbl.add_theme_color_override("font_color",
			C_TEXT if is_bold else C_PRIMARY)
		val_lbl.add_theme_font_size_override("font_size", 11)
		row_hbox.add_child(val_lbl)

		rows_vbox.add_child(row_pc)
		_score_labels[row_id] = val_lbl

	return section


# ---------------------------------------------------------------------------
# Right sidebar
# ---------------------------------------------------------------------------

func _build_right_sidebar() -> Control:
	var bar := Control.new()
	bar.name          = "RightSidebar"
	bar.mouse_filter  = Control.MOUSE_FILTER_STOP
	bar.clip_contents = true

	# Background
	var bg := ColorRect.new()
	bg.color        = C_SIDEBAR
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor_full(bg)
	bar.add_child(bg)

	# Left border
	var bdr := ColorRect.new()
	bdr.color        = C_BORDER
	bdr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor(bdr, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0)
	bar.add_child(bdr)

	# Tab header
	var tab_hbox := HBoxContainer.new()
	tab_hbox.add_theme_constant_override("separation", 0)
	_anchor(tab_hbox, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0, 44.0)
	bar.add_child(tab_hbox)

	_lib_tab_btn  = _make_tab_btn("📦 Library",   true)
	_insp_tab_btn = _make_tab_btn("🔧 Inspector", false)
	_lib_tab_btn.pressed.connect(func(): _show_right_tab("library"))
	_insp_tab_btn.pressed.connect(func(): _show_right_tab("inspector"))
	tab_hbox.add_child(_lib_tab_btn)
	tab_hbox.add_child(_insp_tab_btn)

	# Tab bottom-border accent
	var tab_bdr := ColorRect.new()
	tab_bdr.color        = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.3)
	tab_bdr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor(tab_bdr, 0.0, 0.0, 1.0, 0.0, 0.0, 43.0, 0.0, 44.0)
	bar.add_child(tab_bdr)

	# Library panel (Phase 7)
	var lp := Control.new()
	lp.name = "LibraryPanel"
	lp.set_script(_LIB_PANEL_SCRIPT)
	_anchor(lp, 0.0, 0.0, 1.0, 1.0, 1.0, 44.0, 0.0, 0.0)
	bar.add_child(lp)
	_lib_panel = lp

	# Inspector panel (Phase 8) — same anchor, hidden by default
	var ip := Control.new()
	ip.name    = "InspectorPanel"
	ip.visible = false
	ip.set_script(_INSP_PANEL_SCRIPT)
	_anchor(ip, 0.0, 0.0, 1.0, 1.0, 1.0, 44.0, 0.0, 0.0)
	bar.add_child(ip)
	_inspector_panel = ip
	if _inspector_panel != null and _inspector_panel.has_method("set_toast_callback"):
		_inspector_panel.call("set_toast_callback", Callable(self, "_show_toast"))
	if _inspector_panel != null and _inspector_panel.has_method("set_ha_linker"):
		_inspector_panel.call("set_ha_linker", _ha_linker)
	if _inspector_panel != null and _inspector_panel.has_method("set_compound_callbacks"):
		_inspector_panel.call("set_compound_callbacks",
			Callable(self, "_enter_compound_animated"),
			Callable(self, "_on_ungroup_selected_pressed"),
			Callable(self, "_on_back_scope_pressed"),
			Callable(self, "_on_explode_selected_pressed"))
	if _inspector_panel != null and _inspector_panel.has_method("set_component_callbacks"):
		_inspector_panel.call("set_component_callbacks",
			Callable(self, "save_compound_as_component"),
			Callable(self, "make_compound_unique"))
	if _inspector_panel != null and _inspector_panel.has_method("set_component_sync_callback"):
		_inspector_panel.call("set_component_sync_callback",
			Callable(self, "request_component_sync"))
	if _inspector_panel != null and _inspector_panel.has_method("set_conduit_callbacks"):
		_inspector_panel.call("set_conduit_callbacks",
			Callable(self, "_start_conduit_route"),
			Callable(self, "_clear_conduit_route"),
			Callable(self, "open_conduit_style_modal"))
	if _inspector_panel != null and _inspector_panel.has_method("set_placeholder_callback"):
		_inspector_panel.call("set_placeholder_callback",
			Callable(self, "_spawn_3d_placeholder_for_item"))
	if _inspector_panel != null and _inspector_panel.has_method("set_place_model_callback"):
		_inspector_panel.call("set_place_model_callback",
			Callable(self, "_place_model_for_item"))
	if _inspector_panel != null and _inspector_panel.has_method("set_siphon_lab_callback"):
		_inspector_panel.call("set_siphon_lab_callback",
			Callable(self, "open_siphon_lab"))
	if _inspector_panel != null and _inspector_panel.has_method("set_place_site_twin_callback"):
		_inspector_panel.call("set_place_site_twin_callback",
			Callable(self, "place_site_twin"))
	if _inspector_panel != null and _inspector_panel.has_method("set_hide_3d_callbacks"):
		_inspector_panel.call("set_hide_3d_callbacks",
			Callable(self, "set_node_3d_hidden"),
			Callable(self, "is_node_3d_hidden"),
			Callable(self, "hide_all_placeholder_twins"))
	_ensure_siphon_lab_modal()
	if _inspector_panel != null and _inspector_panel.has_method("set_edit_ports_callback"):
		_inspector_panel.call("set_edit_ports_callback",
			Callable(self, "open_connection_ports"))
	if _inspector_panel != null and _inspector_panel.has_method("set_preview_refresh_callback"):
		_inspector_panel.call("set_preview_refresh_callback",
			Callable(self, "_refresh_item_card_preview"))
	if _inspector_panel != null and _inspector_panel.has_method("set_controller_reset_callback"):
		_inspector_panel.call("set_controller_reset_callback",
			Callable(self, "reset_controller_from_inspector"))
	if _inspector_panel != null and _inspector_panel.has_method("set_library_sync_callback"):
		_inspector_panel.call("set_library_sync_callback",
			Callable(self, "sync_library_instances_from_preset"))
	if _inspector_panel != null and _inspector_panel.has_method("set_ghost_sync_callback"):
		_inspector_panel.call("set_ghost_sync_callback",
			Callable(self, "sync_processor_ghost_containers_for_item"))
	if _inspector_panel != null and _inspector_panel.has_method("set_save_to_library_callback"):
		_inspector_panel.call("set_save_to_library_callback",
			Callable(self, "save_item_to_library"))

	return bar


## Switch the right sidebar between Library and Inspector tabs.
func _show_right_tab(tab: String) -> void:
	var to_lib := (tab == "library")
	if _lib_panel        != null: _lib_panel.visible        = to_lib
	if _inspector_panel  != null: _inspector_panel.visible  = not to_lib
	if _lib_tab_btn      != null: _apply_tab_style(_lib_tab_btn,  to_lib)
	if _insp_tab_btn     != null: _apply_tab_style(_insp_tab_btn, not to_lib)


func _apply_tab_style(btn: Button, active: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.content_margin_left   = 8.0
	sb.content_margin_right  = 8.0
	sb.content_margin_top    = 10.0
	sb.content_margin_bottom = 10.0
	if active:
		sb.bg_color = C_PANEL
		sb.border_color = C_PRIMARY
		sb.set_border_width(SIDE_BOTTOM, 2)
		btn.add_theme_color_override("font_color", C_TEXT)
	else:
		sb.bg_color = C_SIDEBAR
		btn.add_theme_color_override("font_color", C_TEXT_M)
	btn.add_theme_stylebox_override("normal",  sb)
	btn.add_theme_stylebox_override("hover",   sb)
	btn.add_theme_stylebox_override("pressed", sb)


func _make_tab_btn(label: String, active: bool) -> Button:
	var b := Button.new()
	b.text                  = label
	b.focus_mode            = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.size_flags_vertical   = Control.SIZE_EXPAND_FILL

	var sb := StyleBoxFlat.new()
	sb.content_margin_left   = 8.0
	sb.content_margin_right  = 8.0
	sb.content_margin_top    = 10.0
	sb.content_margin_bottom = 10.0
	if active:
		sb.bg_color = C_PANEL
		sb.border_color = C_PRIMARY
		sb.set_border_width(SIDE_BOTTOM, 2)
		b.add_theme_color_override("font_color", C_TEXT)
	else:
		sb.bg_color = C_SIDEBAR
		b.add_theme_color_override("font_color", C_TEXT_M)
	b.add_theme_stylebox_override("normal",  sb)
	b.add_theme_stylebox_override("hover",   sb)
	b.add_theme_stylebox_override("pressed", sb)
	b.add_theme_font_size_override("font_size", 12)
	return b


# ---------------------------------------------------------------------------
# Collapse tab buttons
# ---------------------------------------------------------------------------

func _make_collapse_tab(label: String, cb: Callable,
		corner_a: int, corner_b: int) -> Button:
	var b := Button.new()
	b.text       = label
	b.focus_mode = Control.FOCUS_NONE

	var sb := StyleBoxFlat.new()
	sb.bg_color     = C_PANEL
	sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius(corner_a, 4)
	sb.set_corner_radius(corner_b, 4)
	sb.content_margin_left   = 3.0
	sb.content_margin_right  = 3.0
	sb.content_margin_top    = 8.0
	sb.content_margin_bottom = 8.0

	var sb_h := sb.duplicate() as StyleBoxFlat
	sb_h.border_color = C_PRIMARY
	sb_h.bg_color     = Color(0.145, 0.192, 0.322, 1.0)  # space-500

	b.add_theme_stylebox_override("normal",  sb)
	b.add_theme_stylebox_override("hover",   sb_h)
	b.add_theme_stylebox_override("pressed", sb_h)
	b.add_theme_color_override("font_color", C_TEXT_M)
	b.add_theme_font_size_override("font_size", 11)
	b.pressed.connect(cb)
	return b


# ---------------------------------------------------------------------------
# Sidebar + mode callbacks
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Library drag-to-spawn  (Phase 7)
# ---------------------------------------------------------------------------

func _make_lib_ghost() -> PanelContainer:
	var pc := PanelContainer.new()
	pc.name         = "LibDragGhost"
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.visible      = false

	var sb := StyleBoxFlat.new()
	sb.bg_color              = Color(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.92)
	sb.border_color          = C_PRIMARY
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(5)
	sb.content_margin_left   = 10.0
	sb.content_margin_right  = 10.0
	sb.content_margin_top    =  5.0
	sb.content_margin_bottom =  5.0
	pc.add_theme_stylebox_override("panel", sb)

	var lbl := Label.new()
	lbl.name = "GhostLabel"
	lbl.add_theme_color_override("font_color", C_TEXT)
	lbl.add_theme_font_size_override("font_size", 11)
	pc.add_child(lbl)
	_lib_ghost_label = lbl
	return pc


## Called by LibraryPanel when the user presses an item button.
func _on_lib_item_picked(preset: Dictionary, screen_pos: Vector2) -> void:
	_lib_drag_preset = preset
	_lib_drag_start  = screen_pos
	_lib_drag_active = false
	if _lib_ghost_label != null:
		_lib_ghost_label.text = "%s  %s" % [
			preset.get("icon", ""),
			preset.get("label", "?"),
		]


## Called by LibraryPanel right after a "Create Custom Component" preset is
## saved — spawns it onto the canvas immediately (no drag gesture to arm).
func _on_lib_custom_component_created(preset: Dictionary) -> void:
	_spawn_at_canvas_center(preset)


## "Place Model" pressed on a 3D-linked library preset (e.g. the VAWT). Closes
## the graph and starts a ghost placement of the linked GLB. When the player
## confirms the spot, PlacedPropService calls create_bound_generator_node() to
## spawn this preset's 2D node, bound to the placed prop (see wind_turbine_spin.gd).
##
## `existing_item_id` (inspector "Place in 3D"): bind the already-on-canvas node
## instead of minting a duplicate unconnected twin.
func _on_lib_place_model_requested(preset: Dictionary, existing_item_id: String = "") -> void:
	var specs: Dictionary = (preset.get("specs", {}) as Dictionary).duplicate(true)
	var ptype_early := str(preset.get("type", "wind"))
	var model_id_early := str(specs.get("model_id", ""))
	# Component (super-node) presets spawn subgraphs, not a single 3D prop —
	# never place a gray box for those. Exception: binding an *existing*
	# component instance that already carries a model_id (StarShade → Place in 3D).
	var is_component_preset := ptype_early == "compound" or preset.has("component_tree") \
			or preset.has("definition_id")
	var allow_component_bind := not existing_item_id.is_empty() and not model_id_early.is_empty()
	if is_component_preset and not allow_component_bind:
		_show_toast("Components can't be placed as a single 3D prop")
		return
	var model_id := model_id_early
	# F: any preset without a bespoke GLB places a procedural gray-box
	# placeholder sized from its footprint (fallback 1 m cube).
	var is_placeholder := model_id.is_empty()
	var box_footprint := Vector2(1.0, 1.0)
	if is_placeholder:
		box_footprint = GraphSiteLayout.physical_footprint_m(
			{"type": ptype_early, "specs": specs})
		model_id = ModelCatalog.GENERIC_BOX_ID
		specs["model_id"] = model_id
	var main := _get_scene_main_node()
	if main == null:
		return
	# Carry everything PlacedPropService needs to (a) tag the placed prop for the
	# spin animation and (b) create + bind the 2D node once the player confirms.
	var dims := ComponentPresets.spawn_dimensions(preset)
	var ptype := str(preset.get("type", "wind"))
	var kind := str(specs.get("kind", ""))
	if kind.is_empty():
		if ptype == "plant" or model_id == GrowBed.MODEL_ID:
			kind = "grow_bed"
		elif ptype == "wind":
			kind = "vawt"
		elif str(specs.get("role", "")) == "habitat":
			kind = "habitat"
		elif ModelCatalog.is_hydro_turbine(model_id) \
				or str(specs.get("role", "")) == "siphon_hydro":
			kind = "siphon_hydro"
	elif ModelCatalog.is_hydro_turbine(model_id) \
			or str(specs.get("role", "")) == "siphon_hydro":
		kind = "siphon_hydro"
	var plant_abs_h := -1.0
	if kind == "grow_bed" and main.has_method("get_absolute_hours"):
		plant_abs_h = float(main.call("get_absolute_hours"))
	var record_extra := {
		"kind": kind,
		"turbine_node": str(specs.get("turbine_node",
			ModelCatalog.turbine_node_for(model_id))),
		# Runner axis travels with the record so a model swap can repoint it.
		"spin_axis": str(specs.get("spin_axis", ModelCatalog.spin_axis_for(model_id))),
		"wind_specs": specs if ptype == "wind" else {},
	}
	if kind == "grow_bed":
		record_extra["plant_abs_h"] = plant_abs_h
		record_extra["grow_bed_spec"] = {"plant_abs_h": plant_abs_h}
	if kind == "csp_trough":
		record_extra["csp_specs"] = specs
		record_extra["csp_base_node"] = str(specs.get("csp_base_node", "Component#452"))
		record_extra["csp_concentrator_node"] = str(specs.get("csp_concentrator_node", "Component#453"))
	if kind == "heliostat":
		record_extra["helio_specs"] = specs
		record_extra["helio_base_node"] = str(specs.get("helio_base_node", "fixed base"))
		record_extra["helio_azimuth_node"] = str(specs.get("helio_azimuth_node", "horizontal rotating assembly"))
		record_extra["helio_altitude_node"] = str(specs.get("helio_altitude_node", "Vertical Rotating Assembly"))
		record_extra["helio_mirror_node"] = str(specs.get("helio_mirror_node", "Mirror array"))
		record_extra["helio_focal_node"] = str(specs.get("helio_focal_node", "solar collector area"))
	if kind == "hawt":
		record_extra["hawt_yaw_node"] = str(specs.get("hawt_yaw_node",
			ModelCatalog.find(model_id).get("hawt_yaw_node", "turbine vane assembly")))
		record_extra["hawt_blade_node"] = str(specs.get("hawt_blade_node",
			ModelCatalog.find(model_id).get("hawt_blade_node", "Nosecone and Blades")))
	if kind == "cartesian_machine":
		# Pass the current axis-tag profile so the 3D runtime binds even before a
		# save; the runtime also refreshes from the store on bind.
		record_extra["machine_profile"] = CartesianMachineProfile.get_profile(model_id).to_dict()
	if kind == "pp_beam_extruder" or model_id == "pp_beam_extruder":
		record_extra["kind"] = "pp_beam_extruder"
		record_extra["beam_mesh_name"] = str(specs.get("beam_mesh_name",
			ModelCatalog.find("pp_beam_extruder").get("beam_mesh_name", "Recycled Plastic Beam")))
	if kind == "pp_sheet_press" or model_id == "pp_sheet_press":
		record_extra["kind"] = "pp_sheet_press"
		record_extra["z_stroke_m"] = float(specs.get("z_stroke_m", 0.12))
	if is_placeholder:
		var bw := maxf(box_footprint.x, 0.3)
		var bd := maxf(box_footprint.y, 0.3)
		record_extra["box_spec"] = {
			"w_m": bw, "d_m": bd, "h_m": maxf(1.0, minf(bw, bd))}
	var graph_link := {
		"node_type": ptype,
		"label": str(preset.get("label", "Wind Turbine")),
		"icon": str(preset.get("icon", "🌀")),
		"width": dims.x,
		"height": dims.y,
		"specs": specs,
	}
	if not existing_item_id.is_empty():
		graph_link["existing_item_id"] = existing_item_id
		# Stamp early so runtimes that bind at spawn see the real node id even
		# before create_bound_generator_node returns.
		record_extra["graph_item_id"] = existing_item_id
	var prep := {
		"ok": true,
		"model_id": model_id,
		"graph_link": graph_link,
		"record_extra": record_extra,
	}
	var r: Dictionary = PlacedPropService.begin_placement(main, model_id, prep)
	if not bool(r.get("ok", false)):
		_show_toast("Could not start placement")
		return
	# Close the graph so the player can aim + click in the 3D world, restoring the
	# gameplay/survival state the graph paused on open.
	visible = false
	_apply_mouse_for_graph(false)
	if main.get("gameplay_mechanics_paused") != null:
		main.gameplay_mechanics_paused = _gameplay_paused_before_graph
	var gr: Variant = _GAMEPLAY_RULES_SCRIPT.from_node(self)
	if gr != null:
		gr.set_survival_paused(_gameplay_paused_before_graph)
	# Hand the per-frame aim/confirm loop to the placed-props UI (same path the
	# building-builder library uses).
	var loader := _find_terrain_loader(main)
	if loader != null and loader.has_method("notify_external_placement_started"):
		loader.call("notify_external_placement_started", r)
	else:
		var ppui := main.get_node_or_null("UILayer/PlacedPropsUI")
		if ppui != null and ppui.has_method("notify_bundle_imported"):
			ppui.call("notify_bundle_imported", r)


func _find_terrain_loader(main: Node) -> Node:
	if main == null:
		return null
	return main.find_child("TerrainLoader", true, false)


## Open the Inventory & Crafting panel (fabricated parts + recipe assembly).
func open_inventory_panel() -> void:
	if _inventory_panel == null or not is_instance_valid(_inventory_panel):
		_inventory_panel = _INVENTORY_PANEL.new()
		var main := _get_scene_main_node()
		var ui := main.get_node_or_null("UILayer") if main != null else null
		if ui != null:
			ui.add_child(_inventory_panel)
		else:
			add_child(_inventory_panel)
	_inventory_panel.call("open")


## Ghost-place a mud building design (from Mud Building Designer) without printing.
func place_mud_building(mud_spec: Dictionary) -> void:
	if mud_spec.is_empty():
		return
	var main := _get_scene_main_node()
	if main == null:
		return
	var stored := mud_spec.duplicate(true)
	stored["ghost_highlight"] = false
	var prep := {
		"ok": true,
		"model_id": _MudBuildingStructureBuilder.MODEL_ID,
		"mud_spec": {
			"mud_spec": mud_spec.duplicate(true),
			"ghost_highlight": true,
		},
		"record_extra": {
			"mud_spec": stored,
		},
	}
	var r: Dictionary = PlacedPropService.begin_placement(
		main, _MudBuildingStructureBuilder.MODEL_ID, prep)
	if not bool(r.get("ok", false)):
		_show_toast("Could not start mud building placement")
		return
	visible = false
	_apply_mouse_for_graph(false)
	if main.get("gameplay_mechanics_paused") != null:
		main.gameplay_mechanics_paused = _gameplay_paused_before_graph
	var gr: Variant = _GAMEPLAY_RULES_SCRIPT.from_node(self)
	if gr != null:
		gr.set_survival_paused(_gameplay_paused_before_graph)
	var loader := _find_terrain_loader(main)
	if loader != null and loader.has_method("notify_external_placement_started"):
		loader.call("notify_external_placement_started", r)
	else:
		var ppui := main.get_node_or_null("UILayer/PlacedPropsUI")
		if ppui != null and ppui.has_method("notify_bundle_imported"):
			ppui.call("notify_bundle_imported", r)
	_show_toast("Place your mud building")


## Begin ghost placement of a crafted output model (no bound graph node) — the
## crafting "assemble" action hands off to the same in-world placement loop the
## library "Place Model" uses.
## `crew_recipe_id` (RecipeCatalog id with a `labour` block): the structure
## commits as an under-construction GHOST, parts are debited AT COMMIT
## (cancelling the placement costs nothing), and an "assembly" site project
## puts the crew on it — see _queue_assembly_project.
func place_crafted_model(model_id: String, label: String,
		crew_recipe_id: String = "") -> void:
	if model_id.is_empty():
		return
	var main := _get_scene_main_node()
	if main == null:
		return
	var prep := {"ok": true, "model_id": model_id}
	if model_id == _GeodesicDomeBuilder.MODEL_ID:
		prep["dome_spec"] = {
			"radius_m": _DomeParts.TARGET_RADIUS_M,
			"ghost_highlight": true,
		}
		prep["record_extra"] = {
			"dome_spec": {
				"radius_m": _DomeParts.TARGET_RADIUS_M,
				"ghost_highlight": false,
			},
		}
	if not crew_recipe_id.is_empty():
		var extra: Dictionary = prep.get("record_extra", {})
		extra["build_state"] = {"phase": "", "ghost": 0.15}
		prep["record_extra"] = extra
		prep["on_committed"] = func(prop_id: String) -> void:
			_queue_assembly_project(crew_recipe_id, prop_id)
	var r: Dictionary = PlacedPropService.begin_placement(main, model_id, prep)
	if not bool(r.get("ok", false)):
		_show_toast("Could not start placement")
		return
	visible = false
	_apply_mouse_for_graph(false)
	if main.get("gameplay_mechanics_paused") != null:
		main.gameplay_mechanics_paused = _gameplay_paused_before_graph
	var gr: Variant = _GAMEPLAY_RULES_SCRIPT.from_node(self)
	if gr != null:
		gr.set_survival_paused(_gameplay_paused_before_graph)
	var loader := _find_terrain_loader(main)
	if loader != null and loader.has_method("notify_external_placement_started"):
		loader.call("notify_external_placement_started", r)
	else:
		var ppui := main.get_node_or_null("UILayer/PlacedPropsUI")
		if ppui != null and ppui.has_method("notify_bundle_imported"):
			ppui.call("notify_bundle_imported", r)
	_show_toast("Place your %s" % label)


## The crew-assembly queue half of place_crafted_model: runs once the player
## commits the ghost's spot. Parts are debited HERE (the CNC reserve/refund
## discipline: any downstream refusal credits them straight back and removes
## the ghost), the recipe's labour phases become chained board chores, and
## the last phase carries the finalize_assembly effect that firms the ghost
## and binds a graph node.
func _queue_assembly_project(recipe_id: String, prop_id: String) -> void:
	var main := _get_scene_main_node()
	var loader := _find_terrain_loader(main) if main != null else null
	var recipe := RecipeCatalog.find(recipe_id)
	var requires: Dictionary = recipe.get("requires", {})
	var abort := func(msg: String, refund: bool) -> void:
		if refund:
			var inv2: PartInventory = loader.call("get_part_inventory")
			for pid2 in requires:
				inv2.add_part(str(pid2), int(requires[pid2]))
			loader.call("save_part_inventory")
		if loader != null and loader.has_method("delete_prop_by_id"):
			loader.call("delete_prop_by_id", prop_id)
		_show_toast(msg)
	if loader == null or not loader.has_method("get_part_inventory") \
			or recipe.is_empty():
		abort.call("Crew assembly needs a generated map with an inventory", false)
		return
	var inv: PartInventory = loader.call("get_part_inventory")
	if _npc_population == null or _npc_population.pop_driven_item_ids().is_empty():
		abort.call("Nobody to do the work — turn on Population Simulation for a habitat first", false)
		return
	if not RecipeCatalog.spend(inv, recipe_id):
		abort.call("Parts were used up before assembly could start", false)
		return
	loader.call("save_part_inventory")
	var phases: Array = (recipe.get("labour", {}) as Dictionary).get("phases", [])
	var n := phases.size()
	var rows: Array = []
	var prev_id := ""
	for i in n:
		var ph := phases[i] as Dictionary
		var pid := str(ph.get("id", "p%d" % i))
		var row := {
			"task_id": pid,
			"label": str(ph.get("label", "Assembly work")),
			"work_s": maxf(float(ph.get("work_s", 3600.0)), 60.0),
			"min_workers": int(ph.get("min_workers", 1)),
			"max_workers": int(ph.get("max_workers", 2)),
			"exposure": NpcWeatherGate.EXPOSURE_OUTDOOR,
			"priority": i + 1,
		}
		if not prev_id.is_empty():
			row["depends_on"] = [prev_id]
		if i < n - 1:
			# Each finished phase firms the ghost a step.
			row["effect"] = {"op": "set_build_phase", "prop_id": prop_id,
				"phase": pid, "ghost": lerpf(0.15, 0.85, float(i + 1) / float(n))}
		else:
			row["effect"] = {"op": "finalize_assembly", "prop_id": prop_id,
				"graph_preset": str(recipe.get("graph_preset", ""))}
		rows.append(row)
		prev_id = pid
	var rec := PlacedPropService.get_prop_record(main, prop_id)
	var site := Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
	var iid := str(_npc_population.pop_driven_item_ids()[0])
	var made := _npc_population.create_site_project(iid, "assembly",
		str(recipe.get("label", "Assembly")), prop_id, site, rows,
		{"start_h": 7.0, "end_h": 19.0}, {"kind": "prop", "id": prop_id},
		{"refund_parts": requires.duplicate(true)})
	if made.is_empty():
		abort.call("The chore board is full — finish or cancel something first", true)
		return
	_show_toast("👷 %s queued — the crew will assemble it" % str(recipe.get("label", "Assembly")))


## Bind a crew-ASSEMBLED structure into the 2D graph once its project
## completes (the finalize_assembly effect). The preset label names the
## ComponentPresets entry whose specs the node takes; the prop record gains
## the kind/turbine_node/wind_specs extras so the 3D spin runtime attaches
## on the rebuild that firmed the ghost.
func bind_assembled_structure(prop_id: String, preset_label: String) -> bool:
	var main := _get_scene_main_node()
	if main == null or model == null:
		return false
	var preset := ComponentPresets.find_preset_by_label(preset_label)
	if preset.is_empty():
		push_warning("bind_assembled_structure: no preset labelled '%s'" % preset_label)
		return true   # consumed — an unknown label must not retry forever
	var rec := PlacedPropService.get_prop_record(main, prop_id)
	if rec.is_empty():
		return true   # prop deleted meanwhile — nothing to bind
	var specs: Dictionary = (preset.get("specs", {}) as Dictionary).duplicate(true)
	var model_id := str(rec.get("model_id", ""))
	specs["model_id"] = model_id
	var ptype := str(preset.get("type", "wind"))
	var record_extra := {
		"kind": str(specs.get("kind", "vawt" if ptype == "wind" else "")),
		"turbine_node": str(specs.get("turbine_node",
			ModelCatalog.find(model_id).get("turbine_node", ""))),
		"wind_specs": specs if ptype == "wind" else {},
	}
	PlacedPropService.update_prop_record(main, prop_id, record_extra, true)
	var dims := ComponentPresets.spawn_dimensions(preset)
	var node_id := create_bound_generator_node(prop_id, {
		"node_type": ptype,
		"label": str(preset.get("label", preset_label)),
		"icon": str(preset.get("icon", "🌀")),
		"width": dims.x, "height": dims.y,
		"specs": specs,
	})
	if node_id.is_empty():
		return false   # graph not ready — retry next sweep
	PlacedPropService.update_prop_record(main, prop_id, {"graph_item_id": node_id}, false)
	_show_toast("⚡ %s commissioned — it is live on the graph" % preset_label)
	return true


## Create OR bind a graph node for a placed 3D prop. Called by
## PlacedPropService.confirm_placement() once the player commits a spot.
## When `graph_link.existing_item_id` is set (inspector Place in 3D), updates
## that node in place — never mints a duplicate. Returns the bound item id.
func create_bound_generator_node(prop_id: String, graph_link: Dictionary) -> String:
	if model == null or graph_link.is_empty():
		return ""
	var specs: Dictionary = (graph_link.get("specs", {}) as Dictionary).duplicate(true)
	var model_id := str(specs.get("model_id", ""))
	if not model_id.is_empty() and (
			float(specs.get("footprint_w_m", 0.0)) <= 0.0
			or float(specs.get("footprint_d_m", 0.0)) <= 0.0):
		var fp := PlacedPropService.footprint_from_model(model_id, 1.0)
		if fp.x > 0.0 and fp.y > 0.0:
			specs["footprint_w_m"] = fp.x
			specs["footprint_d_m"] = fp.y

	var existing_id := str(graph_link.get("existing_item_id", ""))
	if not existing_id.is_empty():
		var existing := model.get_item(existing_id)
		if not existing.is_empty():
			return _bind_existing_item_to_prop(existing_id, prop_id, specs, graph_link)

	specs["bound_prop_id"] = prop_id
	var item_id: String = model.generate_item_id()
	# Spawn near the canvas centre in graph space so it's visible when reopened.
	var gc := _graph_canvas as Control
	var graph_pos := Vector2(randf_range(-80.0, 80.0), randf_range(-60.0, 60.0))
	if gc != null and model != null:
		var items: Array = model.get_items_in_scope(_active_scope_id)
		graph_pos = _GRAPH_LAYOUT_SCRIPT.nudge_spawn_position(
			graph_pos, Vector2(float(graph_link.get("width", 124.0)),
				float(graph_link.get("height", 112.0))), items)
	var new_item := {
		"id": item_id,
		"type": str(graph_link.get("node_type", "wind")),
		"x": graph_pos.x,
		"y": graph_pos.y,
		"width": float(graph_link.get("width", 124.0)),
		"height": float(graph_link.get("height", 112.0)),
		"scope_id": _active_scope_id,
		"specs": specs,
		"is_virtual": false,
	}
	_apply_site_coords_from_prop(new_item, prop_id)
	model.add_item(new_item)
	# Placing a siphon next to a pond should just work — auto-bind to the
	# nearest pond within footprint range (silent: no toast if none is close;
	# the player can Rebind manually) and auto-route its downhill culvert
	# outlet, instead of requiring the Bind/Ensure-outlet dev buttons.
	if str(specs.get("role", "")) == "siphon_hydro":
		if bind_siphon_to_nearest_pond(item_id, true, 40.0):
			ensure_siphon_outlet_sink(item_id)
	_schedule_graph_autosave()
	_autosave_pending = true
	_flush_graph_autosave()
	_toast_bound_prop_link(str(graph_link.get("label", "Node")), specs, graph_link)
	return item_id


## Bind an already-on-canvas graph node to a just-placed 3D prop (Place in 3D).
## Preserves graph position + wiring + live specs; only stamps the prop link /
## footprint. Re-place: swaps bound_prop_id then deletes the previous 3D twin
## (order matters so delete_prop_by_id → remove_items_bound_to_prop does not
## nuke this node).
func _bind_existing_item_to_prop(item_id: String, prop_id: String,
		specs: Dictionary, graph_link: Dictionary) -> String:
	var existing := model.get_item(item_id)
	if existing.is_empty():
		return ""
	var prev_specs: Dictionary = (existing.get("specs", {}) as Dictionary).duplicate(true)
	var old_prop_id := str(prev_specs.get("bound_prop_id", ""))
	prev_specs["bound_prop_id"] = prop_id
	var mid := str(specs.get("model_id", ""))
	if not mid.is_empty():
		prev_specs["model_id"] = mid
	var fw := float(specs.get("footprint_w_m", 0.0))
	var fd := float(specs.get("footprint_d_m", 0.0))
	if fw > 0.0:
		prev_specs["footprint_w_m"] = fw
	if fd > 0.0:
		prev_specs["footprint_d_m"] = fd
	var patch: Dictionary = {"specs": prev_specs}
	_apply_site_coords_from_prop(patch, prop_id)
	model.update_item(item_id, patch)
	# Drop the previous twin only after the node points at the new prop.
	if not old_prop_id.is_empty() and old_prop_id != prop_id:
		var main := _get_scene_main_node()
		var loader := _find_terrain_loader(main) if main != null else null
		if loader != null and loader.has_method("delete_prop_by_id"):
			loader.call("delete_prop_by_id", old_prop_id)
	_schedule_graph_autosave()
	_autosave_pending = true
	_flush_graph_autosave()
	_toast_bound_prop_link(str(graph_link.get("label",
		str(prev_specs.get("name", "Node")))), prev_specs, graph_link)
	return item_id


func _apply_site_coords_from_prop(item_or_patch: Dictionary, prop_id: String) -> void:
	var soi := get_node_or_null("/root/SoiService")
	var main2 := _get_scene_main_node()
	if soi == null or not soi.has_method("world_center") or main2 == null:
		return
	var center: Vector3 = soi.call("world_center")
	var pos_v: Variant = _world_pos_for_bound_prop(main2, prop_id)
	if pos_v is Vector3:
		var world: Vector3 = pos_v as Vector3
		var site := GraphSiteLayout.world_xz_to_site(Vector2(world.x, world.z), center)
		item_or_patch["site_x_m"] = site.x
		item_or_patch["site_z_m"] = site.y
		item_or_patch["elevation_m"] = world.y


func _toast_bound_prop_link(link_label: String, specs: Dictionary, graph_link: Dictionary) -> void:
	var role := str(specs.get("role", ""))
	if role == "habitat":
		_show_toast("%s linked to placed shelter" % link_label)
	elif str(graph_link.get("node_type", "")) == "wind":
		_show_toast("%s linked to placed turbine" % link_label)
	elif str(graph_link.get("node_type", "")) == "plant":
		_show_toast("%s linked to placed grow bed" % link_label)
	else:
		_show_toast("%s linked in 3D" % link_label)


## Called when the current world time changes for a placed generator's bound
## node — used by WindTurbineSpin/HawtTracker to keep the 2D node's output in
## sync even while the graph is closed. Safe no-op if the node is gone.
func refresh_bound_generator_output(item_id: String, kw: float) -> void:
	if model == null or item_id.is_empty():
		return
	var it := model.get_item(item_id)
	if it.is_empty():
		return
	var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	if absf(float(specs.get("current_output_kw", 0.0)) - kw) >= 0.0005:
		specs["current_output_kw"] = kw
		model.update_item(item_id, {"specs": specs})
	# Also keep the battery/aux balance current while the graph panel is
	# closed. _process (which normally drives _sync_graph_dc_generation_to_
	# solar on a timer) early-returns when `not visible`, so without this a
	# turbine wired to a battery would animate live in 3D (this function's
	# caller polls regardless of visibility) while SolarUI's "AUX" reading
	# silently froze at whatever it was the instant the panel was closed.
	_sync_graph_dc_generation_to_solar()


## Called when the in-progress library drag ends (LMB released).
func _end_lib_drag(screen_pos: Vector2) -> void:
	if _lib_drag_active and _graph_canvas != null:
		var canvas_global: Vector2 = (_graph_canvas as Control).global_position
		var canvas_rect: Rect2     = Rect2(canvas_global, (_graph_canvas as Control).size)
		if canvas_rect.has_point(screen_pos):
			var local_pos: Vector2 = screen_pos - canvas_global
			_spawn_from_preset(_lib_drag_preset, local_pos)
	elif not _lib_drag_active:
		# Short press / click → spawn near canvas center
		_spawn_at_canvas_center(_lib_drag_preset)

	_lib_drag_active  = false
	_lib_drag_preset  = {}
	if _lib_ghost != null:
		_lib_ghost.visible = false


func _spawn_at_canvas_center(preset: Dictionary) -> void:
	if _graph_canvas == null:
		return
	var gc := _graph_canvas as Control
	var offset := Vector2(randf_range(-60.0, 60.0), randf_range(-40.0, 40.0))
	var local_pos: Vector2 = gc.size * 0.5 + offset
	if model != null:
		var dims := ComponentPresets.spawn_dimensions(preset)
		var pw := dims.x
		var ph := dims.y
		var center: Vector2 = gc.size * 0.5
		var pan := gc.get("_pan") as Vector2
		var zoom := float(gc.get("_zoom"))
		var graph_pos: Vector2 = (local_pos - center - pan) / maxf(zoom, 0.001)
		graph_pos -= Vector2(pw, ph) * 0.5
		var items: Array = model.get_items_in_scope(_active_scope_id)
		graph_pos = _GRAPH_LAYOUT_SCRIPT.nudge_spawn_position(
			graph_pos, Vector2(pw, ph), items)
		local_pos = center + pan + graph_pos * zoom
	_spawn_from_preset(preset, local_pos)


func _spawn_from_preset(preset: Dictionary, canvas_local_pos: Vector2) -> void:
	if model == null or _graph_canvas == null:
		return
	var pan:    Vector2 = _graph_canvas.get("_pan")  as Vector2
	var zoom:   float   = float(_graph_canvas.get("_zoom"))
	var center: Vector2 = _graph_canvas.size * 0.5
	var graph_pos := (canvas_local_pos - center - pan) / zoom

	# Linked component (SketchUp-style): register its definition tree into the
	# document, then realize an INSTANCE bound to the definition.
	if str(preset.get("type", "")) == "component":
		_spawn_component_preset(preset, graph_pos)
		return

	# Subgraph template (legacy one-off) → instantiate a pre-wired nested
	# super-node with fresh ids instead of a single leaf node.
	if preset.has("subgraph"):
		_spawn_subgraph_preset(preset, graph_pos)
		return

	var ptype: String = str(preset.get("type", "appliance"))
	var specs: Dictionary = (preset.get("specs", {}) as Dictionary).duplicate(true)
	var item_id: String = model.generate_item_id()
	var dims := ComponentPresets.spawn_dimensions(preset)
	var proc_w: float = dims.x
	var proc_h: float = dims.y
	var dev_path: String = str(specs.get("scene_device_path", ""))
	# Preset-declared default automations (e.g. "Woodgas DC Generator"'s
	# SOC-based on/off) ship with no "id" — mint one per rule now so the engine can
	# register them below (AutomationEngine ignores id-less rules).
	var preset_autos: Array = specs.get("graph_automations", []) as Array
	if not preset_autos.is_empty():
		for i in preset_autos.size():
			var a: Dictionary = preset_autos[i] as Dictionary
			if str(a.get("id", "")).is_empty():
				a["id"] = "graph_autom_%s_%d" % [item_id, i]
				preset_autos[i] = a
		specs["graph_automations"] = preset_autos
	var item_data: Dictionary = {
		"id":         item_id,
		"type":       ptype,
		"x":          graph_pos.x,
		"y":          graph_pos.y,
		"width":      proc_w,
		"height":     proc_h,
		"scope_id":   _active_scope_id,
		"specs":      specs,
		"is_virtual": false,
	}
	if not dev_path.is_empty():
		item_data["device_path"] = dev_path
	# Site Plan: leave site coords unset so the node lands in the unplaced tray.
	if _graph_view_mode == GraphSiteLayout.VIEW_SITE \
			or _graph_view_mode == GraphSiteLayout.VIEW_ELEVATION:
		item_data.erase("site_x_m")
		item_data.erase("site_z_m")
	model.add_item(item_data)

	if ptype == "processor":
		ResourceKinds.new().migrate_processor_specs(specs)
		_spawn_processor_ghost_containers(item_id, specs, graph_pos, proc_w, proc_h)

	if not preset_autos.is_empty() and _inspector_panel != null \
			and _inspector_panel.has_method("sync_all_load_automations"):
		_inspector_panel.call("sync_all_load_automations", model)

	_schedule_graph_autosave()
	_autosave_pending = true
	_flush_graph_autosave()
	call_deferred("_populate_library_scene_devices")
	if (_graph_view_mode == GraphSiteLayout.VIEW_SITE \
			or _graph_view_mode == GraphSiteLayout.VIEW_ELEVATION) \
			and _graph_canvas != null:
		_graph_canvas.call("queue_redraw")
		print("SystemGraphView: spawned '%s' — drop onto SoI disc from Unplaced tray"
				% str(specs.get("name", ptype)))


## Instantiate a subgraph-template preset as a generic super-node: creates the
## compound shell + child scope, spawns the template's children (fresh ids),
## wires the internal connections, and builds live exposed_ports/handles. The
## result is identical to the player having grouped an equivalent selection.
func _spawn_subgraph_preset(preset: Dictionary, graph_pos: Vector2) -> void:
	var sub: Dictionary = preset.get("subgraph", {}) as Dictionary
	var tpl_items: Array = sub.get("items", []) as Array
	if tpl_items.is_empty():
		return
	_history_suppress = true
	var comp_specs: Dictionary = (preset.get("specs", {}) as Dictionary).duplicate(true)
	comp_specs["compound_kind"] = ""
	comp_specs["child_count"] = tpl_items.size()
	var compound_id: String = model.generate_item_id()
	var comp_item: Dictionary = {
		"id": compound_id,
		"type": "compound",
		"x": graph_pos.x, "y": graph_pos.y,
		"width": float(preset.get("width", 200.0)),
		"height": float(preset.get("height", 130.0)),
		"scope_id": _active_scope_id,
		"specs": comp_specs,
		"handles": [],
		"is_virtual": false,
	}
	model.add_item(comp_item)
	var child_scope := "scope_%s" % compound_id
	model.ensure_scope(child_scope, _active_scope_id, compound_id, str(comp_specs.get("name", "Super Node")))
	model.update_item(compound_id, {"child_scope_id": child_scope})
	# Spawn children with fresh ids (local_id -> real id).
	var id_map: Dictionary = {}
	for it_v in tpl_items:
		var t := it_v as Dictionary
		var itype := str(t.get("type", "appliance"))
		var new_id := model.generate_item_id()
		id_map[str(t.get("local_id", ""))] = new_id
		var specs: Dictionary = (t.get("specs", {}) as Dictionary).duplicate(true)
		var dims := ComponentPresets.spawn_dimensions({"type": itype})
		var idata: Dictionary = {
			"id": new_id, "type": itype,
			"x": graph_pos.x + float(t.get("dx", 0.0)),
			"y": graph_pos.y + float(t.get("dy", 0.0)),
			"width": dims.x, "height": dims.y,
			"scope_id": child_scope,
			"parent_compound_id": compound_id,
			"specs": specs, "is_virtual": false,
		}
		model.add_item(idata)
		if itype == "processor":
			ResourceKinds.new().migrate_processor_specs(specs)
	# Internal wires.
	for c_v in (sub.get("connections", []) as Array):
		var c := c_v as Dictionary
		var s_id := str(id_map.get(str(c.get("source", "")), ""))
		var t_id := str(id_map.get(str(c.get("target", "")), ""))
		if s_id.is_empty() or t_id.is_empty():
			continue
		model.add_connection({
			"scope_id": child_scope,
			"polarity": c.get("polarity", "ac"),
			"resource_type": c.get("resource_type", ""),
			"source_item_id": s_id, "source_handle_id": str(c.get("source_handle", "")),
			"target_item_id": t_id, "target_handle_id": str(c.get("target_handle", "")),
			"line_style": "bezier", "curve_tension": 1.0, "corner_radius": 28.0,
		})
	# Promoted ports + matching handles on the compound shell.
	var exposed_ports: Array = []
	var handles: Array = []
	var in_n := 0
	var out_n := 0
	for ep_v in (sub.get("exposed_ports", []) as Array):
		var ep := ep_v as Dictionary
		var child_id := str(id_map.get(str(ep.get("child", "")), ""))
		if child_id.is_empty():
			continue
		var hid := str(ep.get("handle_id", ""))
		var direction := str(ep.get("direction", "in"))
		var pol := str(ep.get("polarity", "ac"))
		exposed_ports.append({
			"handle_id": hid, "child_item_id": child_id,
			"child_handle_id": str(ep.get("child_handle", "")),
			"polarity": pol, "kind": str(ep.get("kind", "")),
			"label": str(ep.get("label", "")), "direction": direction,
		})
		# Top-to-bottom flow: inputs across the TOP edge, outputs across the BOTTOM.
		var t := float(in_n + 1) / 6.0 if direction == "in" else float(out_n + 1) / 6.0
		handles.append({"id": hid, "polarity": pol, "direction": direction,
			"ry": 0.0 if direction == "in" else 1.0, "rx": clampf(t, 0.1, 0.9)})
		if direction == "in":
			in_n += 1
		else:
			out_n += 1
	var final_specs: Dictionary = (model.get_item(compound_id).get("specs", {}) as Dictionary).duplicate(true)
	final_specs["exposed_ports"] = exposed_ports
	final_specs["port_in_count"] = in_n
	final_specs["port_out_count"] = out_n
	model.update_item(compound_id, {"specs": final_specs, "handles": handles})
	_history_suppress = false
	model.changed.emit("reset")
	_schedule_graph_autosave()
	_autosave_pending = true
	_flush_graph_autosave()
	_show_toast("Placed %s" % str(preset.get("label", "super-node")))


## Spawn a LINKED component instance from a library entry: register the entry's
## definition tree (built-in or user) into the document's registry, then realize
## an instance bound to it. All instances of the definition live-update together.
func _spawn_component_preset(preset: Dictionary, graph_pos: Vector2) -> void:
	if model == null:
		return
	var def_id := str(preset.get("def_id", ""))
	if def_id.is_empty():
		return
	var defs: Dictionary = preset.get("defs", {}) as Dictionary
	if defs.is_empty():
		defs = ComponentPresets.builtin_component_tree(def_id)
	if defs.is_empty():
		_show_toast("Unknown component")
		return
	_history_suppress = true
	# Register every definition in the tree (don't clobber a locally-edited one).
	for did in defs.keys():
		if model.get_definition(str(did)).is_empty():
			model.put_definition(defs[did] as Dictionary)
	var compound_id := GraphComponentDefs.realize(model, def_id, _active_scope_id, graph_pos)
	_history_suppress = false
	if compound_id.is_empty():
		_show_toast("Could not place component")
		return
	model.changed.emit("reset")
	_schedule_graph_autosave()
	_autosave_pending = true
	_flush_graph_autosave()
	_show_toast("Placed %s" % str(preset.get("label", "component")))


## Inspector "Save as Component": promote a generic super-node into a reusable,
## live-linked component definition (minting one on first save), name it, persist
## it (with any nested defs) to the user library, and push it to all instances.
func save_compound_as_component(compound_id: String) -> void:
	if model == null:
		return
	var item := model.get_item(compound_id)
	if item.is_empty() or str(item.get("type", "")) != "compound":
		return
	if str((item.get("specs", {}) as Dictionary).get("compound_kind", "")) != "":
		_show_toast("Only generic super-nodes can be components")
		return
	var cur_name := str((item.get("specs", {}) as Dictionary).get("name", "Component"))
	_prompt_text("Save as Component", "Component name", cur_name,
		func(entered: String):
			var nm := entered.strip_edges()
			if nm.is_empty():
				nm = cur_name
			_finish_save_component(compound_id, nm))


func _finish_save_component(compound_id: String, comp_name: String) -> void:
	_history_suppress = true
	var item := model.get_item(compound_id)
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var def_id := str(specs.get("definition_id", ""))
	if def_id.is_empty():
		# First save — mint a definition and bind this compound as its first instance.
		var def := GraphComponentDefs.make_definition(comp_name)
		def_id = str(def["id"])
		model.put_definition(def)
		specs["definition_id"] = def_id
		specs["name"] = comp_name
		model.update_item(compound_id, {"specs": specs})
	else:
		specs["name"] = comp_name
		model.update_item(compound_id, {"specs": specs})
	# Capture current interior into the definition, then rename the definition.
	GraphComponentDefs.capture(model, compound_id)
	var def2 := model.get_definition(def_id)
	def2["name"] = comp_name
	model.put_definition(def2)
	_history_suppress = false
	# Persist to the user library (with nested defs) and refresh other instances.
	_persist_component_to_library(def_id, comp_name)
	for other in model.instances_of_definition(def_id):
		var oid := str((other as Dictionary).get("id", ""))
		if oid != compound_id:
			_history_suppress = true
			GraphComponentDefs.restamp(model, oid)
			_history_suppress = false
	model.changed.emit("reset")
	_schedule_graph_autosave()
	_show_toast("Saved component '%s'" % comp_name)


## Write a definition (and every definition it references) into the user library
## so it appears under "My Components" and survives restarts.
func _persist_component_to_library(def_id: String, comp_name: String) -> void:
	var tree: Dictionary = {}
	_gather_model_def_tree(def_id, tree)
	if tree.is_empty():
		return
	var entry := {
		"type": "component", "label": comp_name, "icon": "🧩",
		"def_id": def_id, "defs": tree,
	}
	ComponentPresets.save_user_preset("my_components", entry)


## Recursively collect a model definition plus its nested references.
func _gather_model_def_tree(def_id: String, out: Dictionary) -> void:
	if def_id.is_empty() or out.has(def_id):
		return
	var def := model.get_definition(def_id)
	if def.is_empty():
		return
	out[def_id] = def.duplicate(true)
	for it_v in ((def.get("subgraph", {}) as Dictionary).get("items", []) as Array):
		var nested := str((it_v as Dictionary).get("definition_id", ""))
		if not nested.is_empty():
			_gather_model_def_tree(nested, out)


## Inspector "Make Unique": detach this instance from its definition (edits no
## longer sync). Other instances are unaffected.
func make_compound_unique(compound_id: String) -> void:
	if model == null:
		return
	GraphComponentDefs.make_unique(model, compound_id)
	model.changed.emit("reset")
	_schedule_graph_autosave()
	_show_toast("Detached — now a unique super-node")


## Minimal single-line text prompt modal. Runs `on_confirm.call(text)` on OK.
func _prompt_text(title: String, placeholder: String, default_text: String,
		on_confirm: Callable) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = title
	dlg.dialog_hide_on_ok = true
	var le := LineEdit.new()
	le.placeholder_text = placeholder
	le.text = default_text
	le.custom_minimum_size = Vector2(280, 0)
	le.select_all()
	dlg.add_child(le)
	dlg.register_text_enter(le)
	add_child(dlg)
	dlg.confirmed.connect(func():
		if on_confirm.is_valid():
			on_confirm.call(le.text)
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()
	le.grab_focus()


## Import an OSM (or other real-world) solar footprint as ONE compound array node
## (`compound_kind:"array"`), not a scatter of flat panel nodes. Idempotent per
## `array_tag`: re-importing the same tag replaces only that array. Optional `opts`:
##   panel_w_m / panel_h_m / row_gap_m / gap_x_m / voc / vmp / isc / imp
##   footprint_xz (PackedVector2Array or Array of Vector2) — stored for re-tile
##   tilt_deg, auto_wire (default true), show_picker (default true),
##   controller_id (skip picker and wire to this id).
## Returns the new array item id (or "" on failure).
func add_imported_solar_panels(count: int, watts: float, label: String = "OSM Solar",
		array_tag: String = "", opts: Dictionary = {}) -> String:
	if model == null or count <= 0:
		return ""
	var panel_spec := SolarArrayBuilder.resolve_panel_spec({
		"panel_watts": watts if watts > 0.0 else SolarArrayBuilder.PANEL_WATTS,
		"panel_w_m": float(opts.get("panel_w_m", SolarArrayBuilder.PANEL_W)),
		"panel_h_m": float(opts.get("panel_h_m", SolarArrayBuilder.PANEL_H)),
		"gap_x_m": float(opts.get("gap_x_m", SolarArrayBuilder.GAP_X)),
		"row_gap_m": float(opts.get("row_gap_m", SolarArrayBuilder.ROW_GAP)),
		"voc": float(opts.get("voc", SolarArrayBuilder.PANEL_VOC)),
		"vmp": float(opts.get("vmp", SolarArrayBuilder.PANEL_VMP)),
		"isc": float(opts.get("isc", SolarArrayBuilder.PANEL_ISC)),
		"imp": float(opts.get("imp", SolarArrayBuilder.PANEL_IMP)),
	})
	var panel_watts := float(panel_spec["panel_watts"])
	var panel_voc := float(panel_spec["voc"])
	var panel_vmp := float(panel_spec["vmp"])
	var panel_imp := float(panel_spec["imp"])
	var panel_isc := float(panel_spec["isc"])
	# Remove only the nodes this call supersedes; count survivors for Y offset.
	var stale: Array = []
	var kept_osm := 0
	for it in model.items:
		if not (it is Dictionary):
			continue
		var specs0: Dictionary = (it as Dictionary).get("specs", {})
		if not bool(specs0.get("osm_import", false)):
			continue
		var same := array_tag.is_empty() or str(specs0.get("osm_tag", "")) == array_tag
		if same:
			stale.append(str((it as Dictionary).get("id", "")))
		else:
			kept_osm += 1
	for sid in stale:
		model.remove_item(sid)

	# Topology using nearest / chosen controller Voc (fallback: recommended preset).
	var max_voc_guess := 150.0
	var prefer_ctrl := str(opts.get("controller_id", ""))
	if not prefer_ctrl.is_empty():
		var cit := model.get_item(prefer_ctrl)
		if not cit.is_empty():
			max_voc_guess = float((cit.get("specs", {}) as Dictionary).get("max_voc", 150.0))
	else:
		var found_ctrl := false
		for item in model.get_items_in_scope(_active_scope_id):
			if not (item is Dictionary):
				continue
			if str((item as Dictionary).get("type", "")) != "controller":
				continue
			if bool((item as Dictionary).get("is_virtual", false)):
				continue
			var spc: Dictionary = (item as Dictionary).get("specs", {})
			if bool(spc.get("destroyed", false)):
				continue
			max_voc_guess = float(spc.get("max_voc", 150.0))
			found_ctrl = true
			break
		if not found_ctrl:
			var rec := SolarArrayIntelligence.recommend_controller_preset(
					count, panel_voc, panel_watts)
			var rsp: Dictionary = rec.get("specs", {}) as Dictionary
			max_voc_guess = float(rsp.get("max_voc", 450.0))

	var topo := SolarArrayIntelligence.best_series_parallel(count, panel_voc, max_voc_guess)
	var equiv := SolarArrayIntelligence.build_array_equiv_specs(
			count, panel_watts, panel_voc, panel_vmp, panel_imp, panel_isc, topo)

	var origin := Vector2(-80.0, float(kept_osm) * 160.0)
	var arr_specs: Dictionary = {
		"name": "%s (%d×%.0fW)" % [label, count, panel_watts],
		"summary": "%s  •  %.0fW  %.1fV  %.1fA" % [
			str(equiv.get("array_topology", "Array")),
			float(equiv.get("array_equiv_wmp", 0.0)),
			float(equiv.get("array_equiv_vmp", 0.0)),
			float(equiv.get("array_equiv_imp", 0.0)),
		],
		"compound_kind": "array",
		"child_count": 0,
		"port_in_count": 0,
		"port_out_count": 2,
		"boundary_links": [],
		"osm_import": true,
		"osm_tag": array_tag,
		"array_tag": array_tag,
		"panel_count": count,
		"wmp": panel_watts,
		"voc": panel_voc,
		"vmp": panel_vmp,
		"isc": panel_isc,
		"imp": panel_imp,
		"cost": 300.0 * float(count),
		"panel_w_m": float(panel_spec["panel_w_m"]),
		"panel_h_m": float(panel_spec["panel_h_m"]),
		"gap_x_m": float(panel_spec["gap_x_m"]),
		"row_gap_m": float(panel_spec["row_gap_m"]),
		"tilt_deg": float(opts.get("tilt_deg", 0.0)),
		"mount_style": SolarArrayBuilder.resolve_mount_style(
			str(opts.get("mount_style", SolarArrayBuilder.MOUNT_ROOF))),
	}
	for k in equiv.keys():
		arr_specs[k] = equiv[k]
	# Persist footprint so inspector dim edits can re-tile panel count.
	if opts.has("footprint_xz"):
		arr_specs["footprint_xz"] = _serialize_footprint(opts.get("footprint_xz"))

	var arr_sz := GraphArrayLayout.compound_size(arr_specs)
	# Cap oversized visual grid for huge arrays (electrical counts stay true).
	if arr_sz.x > 1400.0 or arr_sz.y > 900.0:
		var vis := arr_specs.duplicate(true)
		vis["array_series"] = mini(int(vis.get("array_series", 1)), 6)
		vis["array_parallel"] = mini(int(vis.get("array_parallel", 1)), 4)
		arr_sz = GraphArrayLayout.compound_size(vis)

	var array_id := model.generate_item_id()
	_history_suppress = true
	model.add_item({
		"id": array_id,
		"type": "compound",
		"x": origin.x,
		"y": origin.y,
		"width": arr_sz.x,
		"height": arr_sz.y,
		"scope_id": _active_scope_id,
		"specs": arr_specs,
		"handles": GraphArrayLayout.default_handles(),
		"is_virtual": false,
	})
	var child_scope_id := "scope_%s" % array_id
	model.ensure_scope(child_scope_id, _active_scope_id, array_id, label)
	model.update_item(array_id, {"child_scope_id": child_scope_id})
	_history_suppress = false

	var auto_wire := bool(opts.get("auto_wire", true))
	var show_picker := bool(opts.get("show_picker", true))
	if auto_wire:
		if not prefer_ctrl.is_empty() and not model.get_item(prefer_ctrl).is_empty():
			_apply_array_controller_choice(array_id, prefer_ctrl, -1)
		elif show_picker:
			call_deferred("_show_controller_picker_for_array", array_id)
		else:
			_auto_wire_imported_array(array_id)

	_schedule_graph_autosave()
	_autosave_pending = true
	_flush_graph_autosave()
	print("SystemGraphView: imported solar array node '%s' — %d panels @ %.0f W (%s, tag '%s')" % [
		array_id, count, panel_watts, str(equiv.get("array_topology", "")), array_tag])
	_sync_solar_ui_from_graph()
	return array_id


const _STOWED_PREFIX := "STOWED • "


## Deploy gate for a live-foldable structure's imported array (Linkage Lab).
## A stowed array keeps its node + wiring (the hardware still exists, folded
## away) but stops contributing capacity to SolarUI until redeployed.
## Packed 3D twin flag (PACKING_PLAN.md Phase 5): called by
## TerrainLoader.set_prop_packed for a prop bound to a graph item. Every
## producer gate reads specs.packed_3d — renewables/CSP/heliostat ticks
## zero their output, ResourceFlowEngine._processor_switched_on refuses to
## run — so a crated machine is honest across the whole sim.
func set_item_packed_3d(item_id: String, packed: bool) -> bool:
	if model == null or item_id.is_empty():
		return false
	var item: Dictionary = model.get_item(item_id)
	if item.is_empty():
		return false
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	if bool(specs.get("packed_3d", false)) == packed:
		return true
	if packed:
		specs["packed_3d"] = true
	else:
		specs.erase("packed_3d")
	model.update_item(item_id, {"specs": specs})
	_schedule_graph_autosave()
	if _graph_canvas != null:
		_graph_canvas.queue_redraw()
	return true


func set_imported_array_stowed(tag: String, stowed: bool) -> bool:
	if model == null or tag.is_empty():
		return false
	var changed := false
	for it in model.items:
		if not (it is Dictionary):
			continue
		var specs0: Dictionary = (it as Dictionary).get("specs", {})
		if not bool(specs0.get("osm_import", false)):
			continue
		if str(specs0.get("osm_tag", "")) != tag:
			continue
		if bool(specs0.get("array_stowed", false)) == stowed:
			continue
		specs0 = specs0.duplicate(true)
		specs0["array_stowed"] = stowed
		var summary := str(specs0.get("summary", "")).trim_prefix(_STOWED_PREFIX)
		specs0["summary"] = (_STOWED_PREFIX + summary) if stowed else summary
		model.update_item(str((it as Dictionary).get("id", "")), {"specs": specs0})
		changed = true
	if changed:
		_sync_solar_ui_from_graph()
		_schedule_graph_autosave()
		if _graph_canvas != null:
			_graph_canvas.queue_redraw()
	return changed


## True if an imported solar array with this tag is on the graph.
func has_array_with_tag(tag: String) -> bool:
	if model == null or tag.is_empty():
		return false
	for it in model.items:
		if not (it is Dictionary):
			continue
		var specs0: Dictionary = (it as Dictionary).get("specs", {})
		if bool(specs0.get("osm_import", false)) and str(specs0.get("osm_tag", "")) == tag:
			return true
	return false


## Remove an imported solar array by tag (e.g. its placed structure was
## deleted). Returns true if anything was removed.
func remove_imported_solar_array(tag: String) -> bool:
	if model == null or tag.is_empty():
		return false
	var remove_ids: Array[String] = []
	for it in model.items:
		if not (it is Dictionary):
			continue
		var specs0: Dictionary = (it as Dictionary).get("specs", {})
		if bool(specs0.get("osm_import", false)) and str(specs0.get("osm_tag", "")) == tag:
			remove_ids.append(str((it as Dictionary).get("id", "")))
	for rid in remove_ids:
		if not rid.is_empty():
			model.remove_item(rid)
	if remove_ids.is_empty():
		return false
	_schedule_graph_autosave()
	_autosave_pending = true
	_flush_graph_autosave()
	_sync_solar_ui_from_graph()
	print("SystemGraphView: removed imported solar array tag '%s' (%d items)" % [
		tag, remove_ids.size()])
	return true


func _serialize_footprint(raw: Variant) -> Array:
	var out: Array = []
	if raw is PackedVector2Array:
		for p in raw as PackedVector2Array:
			out.append([p.x, p.y])
	elif raw is Array:
		for p in raw as Array:
			if p is Vector2:
				out.append([(p as Vector2).x, (p as Vector2).y])
			elif p is Array and (p as Array).size() >= 2:
				out.append([float((p as Array)[0]), float((p as Array)[1])])
	return out


func _deserialize_footprint(raw: Variant) -> PackedVector2Array:
	var out := PackedVector2Array()
	if raw is PackedVector2Array:
		return raw as PackedVector2Array
	if not (raw is Array):
		return out
	for p in raw as Array:
		if p is Vector2:
			out.append(p as Vector2)
		elif p is Array and (p as Array).size() >= 2:
			out.append(Vector2(float((p as Array)[0]), float((p as Array)[1])))
	return out


func _selected_array_id_for_picker() -> String:
	if model == null or _selected_item_ids.is_empty():
		return ""
	for sid in _selected_item_ids:
		var it := model.get_item(str(sid))
		if it.is_empty():
			continue
		if str(it.get("type", "")) != "compound":
			continue
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		if str(sp.get("compound_kind", "")) == "array":
			return str(sid)
	return ""


func _on_pick_controller_for_array_pressed() -> void:
	var aid := _selected_array_id_for_picker()
	if aid.is_empty():
		_show_toast("Select a solar array compound")
		return
	_show_controller_picker_for_array(aid)


func _array_anchor_center(array_id: String) -> Vector2:
	var it := model.get_item(array_id) if model != null else {}
	if it.is_empty():
		return Vector2.ZERO
	return Vector2(
		float(it.get("x", 0.0)) + float(it.get("width", 180.0)) * 0.5,
		float(it.get("y", 0.0)) + float(it.get("height", 120.0)) * 0.5)


func _array_panel_params(array_id: String) -> Dictionary:
	var it := model.get_item(array_id) if model != null else {}
	var sp: Dictionary = it.get("specs", {}) as Dictionary
	return {
		"count": int(sp.get("array_panel_units", sp.get("panel_count", 0))),
		"voc": float(sp.get("voc", SolarArrayBuilder.PANEL_VOC)),
		"watts": float(sp.get("wmp", SolarArrayBuilder.PANEL_WATTS)),
	}


func _show_controller_picker_for_array(array_id: String) -> void:
	if model == null or array_id.is_empty():
		return
	var params := _array_panel_params(array_id)
	var count := int(params["count"])
	if count <= 0:
		_show_toast("Array has no panels")
		return
	var ranked := SolarArrayIntelligence.rank_controllers(
			model, _array_anchor_center(array_id),
			count, float(params["voc"]), float(params["watts"]), _active_scope_id)
	_ctrl_picker_array_id = array_id
	_ctrl_picker_ranked = ranked
	if _ctrl_picker_dialog == null:
		_ctrl_picker_dialog = AcceptDialog.new()
		_ctrl_picker_dialog.title = "Solar controller"
		_ctrl_picker_dialog.ok_button_text = "Wire to selected"
		_ctrl_picker_dialog.min_size = Vector2i(440, 360)
		var vbox := VBoxContainer.new()
		vbox.add_theme_constant_override("separation", 8)
		var hint := Label.new()
		hint.text = "Ranked by Voc fit + canvas distance. Prefer an existing controller, or place a library preset."
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override("font_size", 12)
		vbox.add_child(hint)
		_ctrl_picker_list = ItemList.new()
		_ctrl_picker_list.custom_minimum_size = Vector2(400, 220)
		_ctrl_picker_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_ctrl_picker_list.allow_reselect = true
		vbox.add_child(_ctrl_picker_list)
		_ctrl_picker_dialog.add_child(vbox)
		_ctrl_picker_dialog.confirmed.connect(_on_controller_picker_confirmed)
		add_child(_ctrl_picker_dialog)
	_ctrl_picker_list.clear()
	for i in ranked.size():
		var r: Dictionary = ranked[i]
		var topo: Dictionary = r.get("topo", {}) as Dictionary
		var where := "on canvas" if bool(r.get("on_canvas", false)) else "place new"
		var fit := "fits" if bool(r.get("fits", false)) else "over Voc"
		var line := "%s  ·  %s  ·  max Voc %.0f V  ·  %s  ·  %s" % [
			str(r.get("label", "Controller")),
			str(topo.get("array_topology", "?")),
			float(r.get("max_voc", 0.0)),
			fit,
			where,
		]
		_ctrl_picker_list.add_item(line)
		if i == 0:
			_ctrl_picker_list.select(0)
	_ctrl_picker_dialog.popup_centered()


func _on_controller_picker_confirmed() -> void:
	if model == null or _ctrl_picker_array_id.is_empty():
		return
	var idx := 0
	if _ctrl_picker_list != null and _ctrl_picker_list.get_selected_items().size() > 0:
		idx = int(_ctrl_picker_list.get_selected_items()[0])
	if idx < 0 or idx >= _ctrl_picker_ranked.size():
		return
	var choice: Dictionary = _ctrl_picker_ranked[idx]
	var ctrl_id := str(choice.get("id", ""))
	var preset_idx := int(choice.get("preset_idx", -1))
	_apply_array_controller_choice(_ctrl_picker_array_id, ctrl_id, preset_idx)
	_ctrl_picker_array_id = ""
	_ctrl_picker_ranked.clear()


func _apply_array_controller_choice(array_id: String, controller_id: String,
		preset_idx: int) -> void:
	if model == null or array_id.is_empty():
		return
	var params := _array_panel_params(array_id)
	var count := int(params["count"])
	var panel_voc := float(params["voc"])
	var panel_watts := float(params["watts"])
	var ctrl_id := controller_id
	if ctrl_id.is_empty():
		var preset: Dictionary = {}
		if preset_idx >= 0 and preset_idx < ComponentPresets.CONTROLLERS.size():
			preset = ComponentPresets.CONTROLLERS[preset_idx]
		else:
			preset = SolarArrayIntelligence.recommend_controller_preset(
					count, panel_voc, panel_watts)
		ctrl_id = SolarArrayIntelligence.place_controller_preset(
				model, preset, _array_anchor_center(array_id), _active_scope_id)
		if ctrl_id.is_empty():
			_show_toast("Could not place controller")
			return
		_show_toast("Placed %s" % str((preset.get("specs", {}) as Dictionary).get("name", "controller")))
	var cit := model.get_item(ctrl_id)
	if cit.is_empty():
		return
	var max_voc := float((cit.get("specs", {}) as Dictionary).get("max_voc", 150.0))
	var it := model.get_item(array_id)
	var sp: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	var topo := SolarArrayIntelligence.best_series_parallel(count, panel_voc, max_voc)
	var equiv := SolarArrayIntelligence.build_array_equiv_specs(
			count, panel_watts, panel_voc,
			float(sp.get("vmp", SolarArrayBuilder.PANEL_VMP)),
			float(sp.get("imp", SolarArrayBuilder.PANEL_IMP)),
			float(sp.get("isc", SolarArrayBuilder.PANEL_ISC)), topo)
	for k in equiv.keys():
		sp[k] = equiv[k]
	sp["summary"] = "%s  •  %.0fW  %.1fV  %.1fA" % [
		str(equiv.get("array_topology", "Array")),
		float(equiv.get("array_equiv_wmp", 0.0)),
		float(equiv.get("array_equiv_vmp", 0.0)),
		float(equiv.get("array_equiv_imp", 0.0)),
	]
	_history_suppress = true
	model.update_item(array_id, {"specs": sp})
	SolarArrayIntelligence.wire_array_to_controller(model, array_id, ctrl_id, _active_scope_id)
	_history_suppress = false
	_push_history()
	call_deferred("_check_electrical_faults")
	_schedule_graph_autosave()
	_show_toast("Wired array → %s (%s)" % [
		str((cit.get("specs", {}) as Dictionary).get("name", ctrl_id)),
		str(topo.get("array_topology", "")),
	])


func _auto_wire_imported_array(array_id: String) -> void:
	if model == null or array_id.is_empty():
		return
	var params := _array_panel_params(array_id)
	var ranked := SolarArrayIntelligence.rank_controllers(
			model, _array_anchor_center(array_id),
			int(params["count"]), float(params["voc"]), float(params["watts"]),
			_active_scope_id)
	# Prefer best on-canvas controller that fits; else place best preset.
	var choice: Dictionary = {}
	for r in ranked:
		if bool((r as Dictionary).get("on_canvas", false)) \
				and bool((r as Dictionary).get("fits", false)):
			choice = r
			break
	if choice.is_empty():
		for r in ranked:
			if bool((r as Dictionary).get("fits", false)):
				choice = r
				break
	if choice.is_empty() and not ranked.is_empty():
		choice = ranked[0]
	if choice.is_empty():
		return
	_apply_array_controller_choice(array_id, str(choice.get("id", "")),
			int(choice.get("preset_idx", -1)))

## Import an OSM roof as a rain catchment. Idempotent per `osm_tag`.
func add_imported_catchment(payload: Dictionary) -> bool:
	if model == null:
		return false
	var tag := str(payload.get("osm_tag", ""))
	if tag.is_empty():
		return false
	# Replace prior import with the same tag.
	for it in model.items:
		if not (it is Dictionary):
			continue
		var specs0: Dictionary = (it as Dictionary).get("specs", {})
		if str((it as Dictionary).get("type", "")) != "catchment":
			continue
		if str(specs0.get("osm_tag", "")) == tag:
			model.remove_item(str((it as Dictionary).get("id", "")))
			break
	var centroid: Vector2 = payload.get("centroid", Vector2.ZERO) as Vector2
	var soi := get_node_or_null("/root/SoiService")
	var site := Vector2.ZERO
	if soi != null and soi.has_method("world_center"):
		site = GraphSiteLayout.world_xz_to_site(centroid, soi.call("world_center") as Vector3)
	var poly: PackedVector2Array = payload.get("points", PackedVector2Array())
	var poly_site: Array = []
	for p in poly:
		poly_site.append([p.x - centroid.x, p.y - centroid.y])
	var area := maxf(float(payload.get("area_m2", 10.0)), 1.0)
	var fw := maxf(float(payload.get("width_m", sqrt(area))), 1.0)
	var fd := maxf(float(payload.get("depth_m", sqrt(area))), 1.0)
	var label := str(payload.get("label", "Roof Catchment"))
	model.add_item({
		"id": model.generate_item_id(),
		"type": "catchment",
		"x": 0.0, "y": 0.0,
		"width": 110.0, "height": 90.0,
		"scope_id": "root",
		"site_x_m": site.x,
		"site_z_m": site.y,
		"specs": {
			"name": label,
			"catchment_kind": "rain",
			"use_soi_area": false,
			"area_m2": area,
			"runoff_coeff": float(payload.get("runoff_coeff", 0.85)),
			"cost": 0.0,
			"osm_import": true,
			"osm_tag": tag,
			"footprint_w_m": fw,
			"footprint_d_m": fd,
			"map_display_scale": 1.0,
			"osm_poly_site": poly_site,
		},
		"is_virtual": false,
	})
	_schedule_graph_autosave()
	_autosave_pending = true
	_flush_graph_autosave()
	print("SystemGraphView: imported catchment tag '%s' (%.0f m²)" % [tag, area])
	return true


## Pond / still-water import: catchment + linked water tank. Idempotent per
## `osm_water_tag` (also accepted as `osm_tag`).
func add_imported_pond(payload: Dictionary) -> bool:
	if model == null:
		return false
	var tag := str(payload.get("osm_water_tag", payload.get("osm_tag", "")))
	if tag.is_empty():
		return false
	var pond_id := str(payload.get("pond_id", ""))
	# Remove prior catchment + tank sharing this tag OR this stable pond_id
	# (idempotent re-import even if the tag drifted since the last import).
	_remove_pond_items_by_tag(tag)
	if not pond_id.is_empty():
		_remove_pond_items_by_pond_id(pond_id)
	var centroid: Vector2 = payload.get("centroid", Vector2.ZERO) as Vector2
	var soi := get_node_or_null("/root/SoiService")
	var site := Vector2.ZERO
	var elev := NAN
	if soi != null and soi.has_method("world_center"):
		var center: Vector3 = soi.call("world_center") as Vector3
		site = GraphSiteLayout.world_xz_to_site(centroid, center)
		if soi.has_method("ground_y_at"):
			elev = float(soi.call("ground_y_at", centroid.x, centroid.y))
	var poly: PackedVector2Array = payload.get("points", PackedVector2Array())
	var poly_site: Array = []
	for p in poly:
		poly_site.append([p.x - centroid.x, p.y - centroid.y])
	var area := maxf(float(payload.get("area_m2", 10.0)), 1.0)
	var mean_depth := maxf(float(payload.get("mean_depth_m", 1.5)), 0.3)
	var capacity_l := maxf(float(payload.get("capacity_l", area * mean_depth * 1000.0)), 100.0)
	var rim_m := float(payload.get("rim_m", elev if not is_nan(elev) else 0.0))
	var floor_m := float(payload.get("floor_m", rim_m - mean_depth))
	var level_m := float(payload.get("level_m", NAN))
	if is_nan(level_m):
		level_m = rim_m - clampf((rim_m - floor_m) * 0.15, 0.05, 0.5)
	var span := maxf(rim_m - floor_m, 0.05)
	var stock_l := float(payload.get("stock_l", NAN))
	var level_frac := clampf((level_m - floor_m) / span, 0.0, 1.0)
	if payload.has("level"):
		level_frac = clampf(float(payload["level"]), 0.0, 1.0)
	elif not is_nan(stock_l) and capacity_l > 1e-3:
		level_frac = clampf(stock_l / capacity_l, 0.0, 1.0)
	var capacity_mode := str(payload.get("capacity_mode", "auto"))
	var fill_mode := str(payload.get("fill_mode", "auto"))
	if is_nan(stock_l):
		stock_l = level_frac * capacity_l
	var fw := maxf(float(payload.get("width_m", sqrt(area))), 1.0)
	var fd := maxf(float(payload.get("depth_m", sqrt(area))), 1.0)
	var label := str(payload.get("label", "Pond"))
	var catch_id := model.generate_item_id()
	var tank_id := model.generate_item_id()
	var catch_item := {
		"id": catch_id,
		"type": "catchment",
		"x": 80.0, "y": 80.0,
		"width": 110.0, "height": 90.0,
		"scope_id": "root",
		"site_x_m": site.x,
		"site_z_m": site.y,
		"specs": {
			"name": label,
			"catchment_kind": "pond",
			"use_soi_area": false,
			"area_m2": area,
			"runoff_coeff": float(payload.get("runoff_coeff", 1.0)),
			"cost": 0.0,
			"osm_import": true,
			"osm_tag": tag,
			"osm_water_tag": tag,
			"pond_id": pond_id,
			"mean_depth_m": mean_depth,
			"rim_m": rim_m,
			"floor_m": floor_m,
			"level_m": level_m,
			"footprint_w_m": fw,
			"footprint_d_m": fd,
			"map_display_scale": 1.0,
			"osm_poly_site": poly_site,
		},
		"is_virtual": false,
	}
	if not is_nan(elev):
		catch_item["elevation_m"] = elev
	elif not is_nan(level_m):
		catch_item["elevation_m"] = level_m
	model.add_item(catch_item)
	var tank_item := {
		"id": tank_id,
		"type": "resource",
		"x": 230.0, "y": 80.0,
		"width": 90.0, "height": 100.0,
		"scope_id": "root",
		"site_x_m": site.x + 2.0,
		"site_z_m": site.y,
		"specs": {
			"name": "%s Storage" % label,
			"resource_kind": "water",
			"capacity": "%.0f L" % capacity_l,
			"capacity_qty": capacity_l,
			"capacity_unit": "L",
			"level": level_frac,
			"level_m": level_m,
			"rim_m": rim_m,
			"floor_m": floor_m,
			"stock_l": stock_l,
			"capacity_mode": capacity_mode,
			"fill_mode": fill_mode,
			"cost": 0.0,
			"osm_import": true,
			"osm_water_tag": tag,
			"pond_id": pond_id,
			"pond_storage": true,
		},
		"is_virtual": false,
	}
	if not is_nan(elev):
		tank_item["elevation_m"] = elev
	else:
		tank_item["elevation_m"] = level_m
	model.add_item(tank_item)
	model.add_connection({
		"scope_id": "root",
		"polarity": "resource",
		"resource_type": "water",
		"source_item_id": catch_id,
		"source_handle_id": "output",
		"target_item_id": tank_id,
		"target_handle_id": "input",
		"waypoints": [],
		"line_style": "bezier",
		"curve_tension": 1.0,
		"corner_radius": 28.0,
	})
	_schedule_graph_autosave()
	_autosave_pending = true
	_flush_graph_autosave()
	print("SystemGraphView: imported pond tag '%s' (%.0f m², %.0f L)" % [tag, area, capacity_l])
	return true


## Hillside DEM catchment wired into an existing pond storage tank.
## Idempotent per `watershed_<pond_tag>` osm_tag. Payload from
## `TerrainLoader.analyze_pond_watershed`.
func add_imported_watershed_catchment(payload: Dictionary) -> bool:
	if model == null:
		return false
	var pond_tag := str(payload.get("pond_tag", payload.get("osm_water_tag", "")))
	if pond_tag.is_empty():
		return false
	if not has_pond_with_tag(pond_tag):
		# Need a tank to credit — import pond surface first if caller has payload bits.
		return false
	var tank_id := _pond_tank_id_for_tag(pond_tag)
	if tank_id.is_empty():
		return false
	var ws_tag := "watershed_%s" % pond_tag
	_remove_watershed_catchment_by_tag(ws_tag)
	var centroid: Vector2 = payload.get("centroid", Vector2.ZERO) as Vector2
	var soi := get_node_or_null("/root/SoiService")
	var site := Vector2.ZERO
	var elev := NAN
	if soi != null and soi.has_method("world_center"):
		var center: Vector3 = soi.call("world_center") as Vector3
		site = GraphSiteLayout.world_xz_to_site(centroid, center)
		if soi.has_method("ground_y_at"):
			elev = float(soi.call("ground_y_at", centroid.x, centroid.y))
	var poly_site: Array = payload.get("poly_site", []) as Array
	if poly_site.is_empty():
		var poly_world: PackedVector2Array = payload.get("poly_world", PackedVector2Array()) \
				as PackedVector2Array
		for p in poly_world:
			poly_site.append([p.x - centroid.x, p.y - centroid.y])
	var area := maxf(float(payload.get("area_m2", 1.0)), 1.0)
	var runoff := clampf(float(payload.get("runoff_default",
			payload.get("runoff_coeff", 0.35))), 0.0, 1.0)
	var label := str(payload.get("label", "Hillside Catchment"))
	var catch_id := model.generate_item_id()
	var tank_item := model.get_item(tank_id)
	var place_x := float(tank_item.get("x", 80.0)) + 150.0
	var place_y := float(tank_item.get("y", 200.0)) - 20.0
	var catch_item := {
		"id": catch_id,
		"type": "catchment",
		"x": place_x, "y": place_y,
		"width": 120.0, "height": 90.0,
		"scope_id": "root",
		"site_x_m": site.x,
		"site_z_m": site.y,
		"specs": {
			"name": label,
			"catchment_kind": "watershed",
			"use_soi_area": false,
			"area_m2": area,
			"runoff_coeff": runoff,
			"cost": 0.0,
			"osm_import": true,
			"osm_tag": ws_tag,
			"pond_tag": pond_tag,
			"osm_water_tag": pond_tag,
			"footprint_w_m": maxf(sqrt(area), 1.0),
			"footprint_d_m": maxf(sqrt(area), 1.0),
			"map_display_scale": 1.0,
			"osm_poly_site": poly_site,
			"cell_count": int(payload.get("cell_count", 0)),
		},
		"is_virtual": false,
	}
	if not is_nan(elev):
		catch_item["elevation_m"] = elev
	model.add_item(catch_item)
	if _graph_canvas != null:
		_graph_canvas.set("selected_item_id", catch_id)

	# Wire catchment → pond tank (water).
	model.add_connection({
		"scope_id": "root",
		"polarity": "resource",
		"resource_type": "water",
		"source_item_id": catch_id,
		"source_handle_id": "output",
		"target_item_id": tank_id,
		"target_handle_id": "input",
		"waypoints": [],
		"line_style": "bezier",
		"curve_tension": 1.0,
		"corner_radius": 28.0,
	})
	_schedule_graph_autosave()
	_autosave_pending = true
	_flush_graph_autosave()
	if _graph_canvas != null:
		_graph_canvas.call("queue_redraw")
	print("SystemGraphView: watershed catchment for pond '%s' (%.0f m²)" % [pond_tag, area])
	return true


func remove_imported_watershed_catchment(pond_tag: String) -> bool:
	if pond_tag.is_empty():
		return false
	var n := _remove_watershed_catchment_by_tag("watershed_%s" % pond_tag)
	if n > 0:
		_schedule_graph_autosave()
		_autosave_pending = true
		_flush_graph_autosave()
		if _graph_canvas != null:
			_graph_canvas.call("queue_redraw")
	return n > 0


func has_watershed_catchment_for_pond(pond_tag: String) -> bool:
	if model == null or pond_tag.is_empty():
		return false
	var ws_tag := "watershed_%s" % pond_tag
	for it in model.items:
		if not (it is Dictionary):
			continue
		var specs: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
		if str((it as Dictionary).get("type", "")) != "catchment":
			continue
		if str(specs.get("catchment_kind", "")) == "watershed" \
				and (str(specs.get("osm_tag", "")) == ws_tag \
				or str(specs.get("pond_tag", "")) == pond_tag):
			return true
	return false


func _remove_watershed_catchment_by_tag(ws_tag: String) -> int:
	if model == null or ws_tag.is_empty():
		return 0
	var remove_ids: Array[String] = []
	for it in model.items:
		if not (it is Dictionary):
			continue
		var specs0: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
		if str((it as Dictionary).get("type", "")) != "catchment":
			continue
		if str(specs0.get("catchment_kind", "")) != "watershed":
			continue
		if str(specs0.get("osm_tag", "")) == ws_tag \
				or str(specs0.get("pond_tag", "")) == ws_tag.trim_prefix("watershed_"):
			remove_ids.append(str((it as Dictionary).get("id", "")))
	for rid in remove_ids:
		if not rid.is_empty():
			model.remove_item(rid)
	return remove_ids.size()


func _pond_tank_id_for_tag(pond_tag: String) -> String:
	if model == null or pond_tag.is_empty():
		return ""
	for it in model.items:
		if not (it is Dictionary):
			continue
		var item: Dictionary = it
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(item.get("type", "")) != "resource":
			continue
		if not bool(specs.get("pond_storage", false)):
			continue
		if str(specs.get("osm_water_tag", "")) == pond_tag:
			return str(item.get("id", ""))
	return ""


# ---------------------------------------------------------------------------
# Siphon Lab (detail modal) + pond bind / ∞ outlet sink
# ---------------------------------------------------------------------------

func _ensure_siphon_lab_modal() -> void:
	if _siphon_lab_modal != null and is_instance_valid(_siphon_lab_modal):
		return
	# Host inside SystemGraphView so Siphon Lab fills the canvas area as a view.
	var modal := Control.new()
	modal.name = "SiphonHydroModal"
	modal.set_script(_SIPHON_LAB_SCRIPT)
	modal.visible = false
	modal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(modal)
	# Above canvas, below topbar/sidebars — move just after GraphCanvas.
	if _graph_canvas != null:
		move_child(modal, _graph_canvas.get_index() + 1)
	if modal.has_method("bind_graph_view"):
		modal.call("bind_graph_view", self)
	_siphon_lab_modal = modal
	_apply_siphon_lab_layout()


func _apply_siphon_lab_layout() -> void:
	if _siphon_lab_modal == null or not is_instance_valid(_siphon_lab_modal):
		return
	var bottom_offset := _timeline_bottom_inset()
	if _history_panel != null and is_instance_valid(_history_panel) \
			and _history_panel.visible:
		bottom_offset += HISTORY_PANEL_H
	# Phase 2: own 2D cross-section + params — fill the whole canvas area
	# (below topbar, above timeline). No longer a right-strip dock over the CT.
	_anchor(_siphon_lab_modal,
		0.0, 0.0, 1.0, 1.0,
		0.0, TOPBAR_H, 0.0, -bottom_offset)


func _sync_siphon_lab_view(preferred_item_id: String = "") -> void:
	_ensure_siphon_lab_modal()
	if _siphon_lab_modal == null:
		return
	_apply_siphon_lab_layout()
	if _graph_view_mode == GraphSiteLayout.VIEW_SIPHON:
		if _siphon_lab_modal.has_method("enter_as_view"):
			_siphon_lab_modal.call("enter_as_view", preferred_item_id)
		# Modal shell must exist before SoI SubViewport can embed into it.
		_sync_soi_preview_for_mode()
	else:
		var leave_id := ""
		if _siphon_lab_modal != null and _siphon_lab_modal.get("_item_id") != null:
			leave_id = str(_siphon_lab_modal.get("_item_id"))
		teardown_siphon_lab_session(leave_id)
		if _siphon_lab_modal.has_method("exit_view"):
			_siphon_lab_modal.call("exit_view")


func open_siphon_lab(item_id: String) -> void:
	if model == null:
		return
	# The Lab is item-bound: an empty id used to bypass validation entirely and
	# open a useless empty full-screen view (the old mode-chip path).
	if item_id.is_empty():
		_show_toast("Select a hydro turbine first — the Hydro Lab opens from its node")
		return
	var item := model.get_item(item_id)
	if item.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if str(specs.get("role", "")) != "siphon_hydro":
		return
	# Remember where the player came from so closing the Lab returns there
	# instead of always dumping them in Elevation.
	if _graph_view_mode != GraphSiteLayout.VIEW_SIPHON:
		_lab_return_mode = _graph_view_mode
	_apply_graph_view_mode(GraphSiteLayout.VIEW_SIPHON, {"siphon_item_id": item_id})


## Graph view mode to restore when the Hydro Lab closes (recorded on open).
var _lab_return_mode: String = ""


## Close the Hydro Lab and return to the mode the player opened it from.
func close_hydro_lab() -> void:
	var back := _lab_return_mode
	_lab_return_mode = ""
	if back.is_empty() or back == GraphSiteLayout.VIEW_SIPHON:
		back = GraphSiteLayout.VIEW_ELEVATION
	_apply_graph_view_mode(back)


## Throttle Elev redraws while the Siphon Lab is open (~15 Hz).
var _lab_redraw_acc: float = 0.0


## Siphon Lab per-frame sync: push pond twin mesh into the embedded Elev CT.
## Water stock itself is advanced by ResourceFlowEngine (world clock, or wall
## time while paused via lab Test Inflow).
##
## Returns TRUE only when the throttle actually fired and tank state was written.
## The Lab uses that to decide whether to drop its pond-context cache — it used to
## drop it unconditionally every frame, which turned a 0.25 s cache into a
## per-frame `resolve_siphon_pond()` and was a large part of the Lab's sluggishness.
func lab_siphon_tick(siphon_id: String, real_delta: float, _opts: Dictionary = {}) -> bool:
	if model == null or siphon_id.is_empty() or real_delta <= 0.0:
		return false
	_lab_redraw_acc += real_delta
	if _lab_redraw_acc < 0.12:
		return false
	_lab_redraw_acc = 0.0
	# Force mesh rebuild so the Lab CT pond surface tracks stock while the
	# ambient throttle skips Elev/Siphon (and world-suspend) remeshes.
	push_pond_levels_to_mesh(true)
	queue_canvas_redraw()
	return true


## Siphon Lab: directly set the bound pond's water level (dragging the water line
## on the cross-section). Re-anchors the tank timeline so the flow engine then
## continues fill/drain from here on the world clock instead of clobbering it.
func lab_set_pond_level(siphon_id: String, level_m: float) -> bool:
	if model == null or siphon_id.is_empty():
		return false
	var tank := resolve_siphon_pond(siphon_id)
	if tank.is_empty():
		return false
	var tid := str(tank.get("id", ""))
	var specs: Dictionary = (tank.get("specs", {}) as Dictionary).duplicate(true)
	var floor_y := float(specs.get("floor_m", NAN))
	var rim := float(specs.get("rim_m", NAN))
	if is_nan(floor_y) or is_nan(rim) or rim <= floor_y + 0.02:
		return false
	level_m = clampf(level_m, floor_y + 0.02, rim - 0.02)
	var span := maxf(rim - floor_y, 0.05)
	var frac := clampf((level_m - floor_y) / span, 0.0, 1.0)
	var cap := maxf(float(specs.get("capacity_qty", 1.0)), 1.0)
	specs["level_m"] = level_m
	specs["level"] = frac
	specs["stock_l"] = frac * cap
	specs["fill_mode"] = "auto"
	model.update_item(tid, {"specs": specs, "elevation_m": level_m})
	if _resource_flow != null and _resource_flow.has_method("reanchor_tank"):
		_resource_flow.call("reanchor_tank", tid, frac)
	push_pond_levels_to_mesh(true)
	return true


## True when a pond tank has usable floor/rim bathymetry for Lab/Elev framing.
static func pond_has_usable_bathymetry(specs: Dictionary) -> bool:
	var floor_m := float(specs.get("floor_m", NAN))
	var rim_m := float(specs.get("rim_m", NAN))
	return not is_nan(floor_m) and not is_nan(rim_m) and rim_m > floor_m + 0.05


## Heal tags, prune orphans, ensure outlet, select bound pond (Lab enter).
## True when this turbine is wired to a tapped stream/spring intake. Such a
## turbine already HAS a water source — the penstock — and must never be
## auto-rebound to a pond, because binding replaces the water-in wiring.
## The explicit "Rebind to nearest pond" button is deliberately not gated by this:
## that one is the player asking.
func _turbine_has_stream_source(siphon_id: String) -> bool:
	if model == null or siphon_id.is_empty():
		return false
	for conn: Dictionary in model.connections:
		var src := str(conn.get("source_item_id", ""))
		var tgt := str(conn.get("target_item_id", ""))
		if src != siphon_id and tgt != siphon_id:
			continue
		var other_id := tgt if src == siphon_id else src
		if ResourceFlowEngine.is_stream_intake(model.get_item(other_id)):
			return true
	return false


func prepare_siphon_lab_session(siphon_id: String) -> void:
	var loader := _find_terrain_loader(_get_scene_main_node())
	if loader != null:
		heal_pond_tags_from_map(loader)
		if loader.has_method("prune_orphan_ponds_from_graph"):
			loader.call("prune_orphan_ponds_from_graph", false)
	heal_duplicate_null_bathymetry_ponds()
	heal_pond_capacity_sanity()
	if not siphon_id.is_empty():
		# Unbound OR bound to a null-bathymetry orphan — prefer a live pond.
		var bound := resolve_siphon_pond(siphon_id)
		var need_rebind := bound.is_empty()
		if not need_rebind:
			var bs: Dictionary = bound.get("specs", {}) as Dictionary
			need_rebind = not pond_has_usable_bathymetry(bs)
		# ...but NEVER for a turbine already fed by a tapped stream/spring. A
		# stream intake is not a pond, so resolve_siphon_pond returns empty and
		# this path used to fire every time — and bind_siphon_to_nearest_pond
		# REPLACES the water-in wiring, so merely opening the Hydro Lab deleted
		# the penstock the player had just routed and silently latched the
		# turbine onto a pond somewhere else on the map.
		if need_rebind and _turbine_has_stream_source(siphon_id):
			need_rebind = false
		if need_rebind:
			# Generous but bounded — the placement path already binds within 40 m,
			# so this fallback only fires when the turbine was placed before a
			# nearby pond existed. Cap it so opening the Lab can't silently latch
			# onto a pond on the far side of the map; beyond the cap it stays
			# unbound (Lab shows "wire a pond") instead of binding nonsense.
			bind_siphon_to_nearest_pond(siphon_id, true, LAB_AUTOBIND_MAX_M)
		# Migrate absolute start/break → offsets vs live module elev; heal tank cap.
		var siphon := model.get_item(siphon_id)
		if not siphon.is_empty():
			var ss: Dictionary = (siphon.get("specs", {}) as Dictionary).duplicate(true)
			var elev := float(siphon.get("elevation_m", NAN))
			if is_nan(elev):
				elev = float(ss.get("module_elev_m", NAN))
			SiphonHydraulics.apply_resolved_levels(ss, elev)
			var siphon_patch := {"specs": ss}
			if not is_nan(elev):
				siphon_patch["elevation_m"] = elev
			model.update_item(siphon_id, siphon_patch)
		ensure_siphon_outlet_sink(siphon_id)
		# Soft-focus culvert glow; Elevation CT (embedded) shows the 3D run.
		focus_siphon_conduit_glow(siphon_id, false)
		_relax_legacy_siphon_nameplate(siphon_id)
		_ensure_hydroturbine_section_yaw(siphon_id)
		# Heading + slice only: the Lab frames its OWN CT via
		# sync_siphon_lab_section_frame, and framing the canvas from here wrote
		# whichever view's camera happened to be live (the freeform-zoom bug).
		frame_elevation_for_siphon(siphon_id, false)
		var tank := resolve_siphon_pond(siphon_id)
		if not tank.is_empty():
			heal_pond_terrain_capacity_for_tank(str(tank.get("id", "")))
			if _graph_canvas != null:
				var tid := str(tank.get("id", ""))
				_graph_canvas.set("selected_item_id", tid)
				if _graph_canvas.has_method("flash_item"):
					_graph_canvas.call("flash_item", tid)
	# Lite suspend (veg/player) — keep World3D live for the embedded Elev CT.
	var main_suspend := _get_scene_main_node()
	if main_suspend != null and main_suspend.has_method("set_world_suspended_for_lab"):
		main_suspend.call("set_world_suspended_for_lab", true)


## Face the hydroturbine prop into the CT cut: spin axis (model +Z) aligns with
## the camera look (−cross). At heading 0 look=(0,0,−1); yaw 0 → local +Z =
## world +Z so the disk is face-on. General: yaw = −heading + catalog bias.
func _ensure_hydroturbine_section_yaw(siphon_id: String) -> void:
	if model == null or siphon_id.is_empty():
		return
	var item := model.get_item(siphon_id)
	if item.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var prop_id := str(specs.get("bound_prop_id", ""))
	var main := _get_scene_main_node()
	if main == null:
		return
	if prop_id.is_empty():
		prop_id = _find_hydroturbine_prop_id_for_item(siphon_id, main)
	if prop_id.is_empty():
		return
	var heading := 0.0
	if _graph_canvas != null:
		heading = float(_graph_canvas.get("elevation_heading_rad"))
	# Mesh authoring bias (usually 0 — see the ModelCatalog hydro notes). Read
	# it from the prop's OWN model, not the siphon turbine's.
	var rec_for_yaw := PlacedPropService.get_prop_record(main, prop_id)
	var yaw_model := str(rec_for_yaw.get("model_id", "hydroturbine"))
	var forced := ModelCatalog.forced_yaw_deg(yaw_model)
	var want := -rad_to_deg(heading) + forced
	want = fposmod(want + 180.0, 360.0) - 180.0
	var cur := PlacedPropService.get_prop_record(main, prop_id)
	var pitch := float(cur.get("pitch", 0.0)) if not cur.is_empty() else 0.0
	var roll := float(cur.get("roll", 0.0)) if not cur.is_empty() else 0.0
	var scl := float(cur.get("scale", 1.0)) if not cur.is_empty() else 1.0
	if cur.is_empty() or absf(float(cur.get("yaw", 0.0)) - want) >= 0.35:
		# Persist without free()/respawn (avoids section-clip meta races).
		PlacedPropService.update_prop_record(main, prop_id, {"yaw": want}, false)
	# Always live-apply — record may already match while ModelRoot is stale.
	var parent := main.find_child("PlacedProps", true, false)
	if parent == null:
		return
	for child in parent.get_children():
		if child is PlacedProp and str((child as PlacedProp).prop_id) == prop_id:
			(child as PlacedProp).apply_live_transform(
					(child as PlacedProp).global_position, want, pitch, roll, scl)
			break


## Resolve a placed hydro turbine (any hydro model) for a turbine graph item.
func _find_hydroturbine_prop_id_for_item(siphon_id: String, main: Node) -> String:
	if main == null or siphon_id.is_empty():
		return ""
	var parent := main.find_child("PlacedProps", true, false)
	if parent == null:
		return ""
	var fallback := ""
	for child in parent.get_children():
		if not (child is PlacedProp):
			continue
		var pp := child as PlacedProp
		if not ModelCatalog.is_hydro_turbine(str(pp.model_id)):
			continue
		var rec := PlacedPropService.get_prop_record(main, str(pp.prop_id))
		var gid := str(rec.get("graph_item_id", ""))
		if gid == siphon_id:
			return str(pp.prop_id)
		if fallback.is_empty():
			fallback = str(pp.prop_id)
	return fallback


## Old Siphon presets pinned max_power_w=250 (hoverboard nameplate), which froze
## DC at 250 W while PE was multi‑kW. Treat that exact legacy value as uncapped.
func _relax_legacy_siphon_nameplate(siphon_id: String) -> void:
	if model == null or siphon_id.is_empty():
		return
	var item := model.get_item(siphon_id)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	if absf(float(specs.get("max_power_w", 0.0)) - 250.0) > 0.51:
		return
	specs["max_power_w"] = 0.0
	model.update_item(siphon_id, {"specs": specs})


## Pond tank currently feeding this siphon (forward or reverse wire).
func resolve_siphon_pond(siphon_id: String) -> Dictionary:
	if model == null or siphon_id.is_empty():
		return {}
	var item := model.get_item(siphon_id)
	if item.is_empty():
		return {}
	if _resource_flow != null and _resource_flow.has_method("_resolve_siphon_inlet_tank"):
		return _resource_flow.call("_resolve_siphon_inlet_tank", item)
	# Fallback without engine: scan connections.
	for conn: Dictionary in model.connections:
		var src_id := str(conn.get("source_item_id", ""))
		var tgt_id := str(conn.get("target_item_id", ""))
		var other_id := ""
		if tgt_id == siphon_id:
			other_id = src_id
		elif src_id == siphon_id:
			other_id = tgt_id
		else:
			continue
		var other := model.get_item(other_id)
		if other.is_empty():
			continue
		var os: Dictionary = other.get("specs", {}) as Dictionary
		if bool(os.get("pond_storage", false)):
			return other
	return {}


func siphon_outlet_cumulative_l(siphon_id: String) -> float:
	if model == null or siphon_id.is_empty():
		return 0.0
	var item := model.get_item(siphon_id)
	if item.is_empty():
		return 0.0
	var down := {}
	if _resource_flow != null and _resource_flow.has_method("_resolve_siphon_outlet_tank"):
		down = _resource_flow.call("_resolve_siphon_outlet_tank", item)
	if down.is_empty():
		return 0.0
	return float((down.get("specs", {}) as Dictionary).get("cumulative_l", 0.0))


## Wire siphon to nearest pond_storage, seat at pond site, seed start/break.
## Prefers tanks whose osm_water_tag still exists on the map (live twin).
## `silent`: suppress toasts (auto-bind-on-placement/Lab-open — a miss there
## isn't actionable feedback; the player can still Rebind manually).
## `max_dist_m`: skip binding to a pond farther than this (auto-bind only wants
## a pond you obviously placed the turbine next to, not the nearest one on the
## whole map); NAN/<=0 means no distance cap (manual Rebind stays unrestricted).
func bind_siphon_to_nearest_pond(siphon_id: String, silent: bool = false,
		max_dist_m: float = NAN) -> bool:
	if model == null or siphon_id.is_empty():
		return false
	var siphon := model.get_item(siphon_id)
	if siphon.is_empty():
		return false
	var live_tags: Dictionary = {}
	var loader := _find_terrain_loader(_get_scene_main_node())
	if loader != null and loader.has_method("live_pond_tags"):
		for t in loader.call("live_pond_tags") as PackedStringArray:
			live_tags[str(t)] = true
	# Drop stale pond nodes first so Bind can't latch onto prototype leftovers.
	if loader != null and loader.has_method("prune_orphan_ponds_from_graph"):
		loader.call("prune_orphan_ponds_from_graph", false)
	var best: Dictionary = {}
	var best_score := INF
	var best_dist := INF
	var siphon_site := Vector2.ZERO
	if GraphSiteLayout.has_site_coords(siphon):
		siphon_site = GraphSiteLayout.site_xz(siphon)
	for it in model.items:
		if not (it is Dictionary):
			continue
		var tank: Dictionary = it
		var ts: Dictionary = tank.get("specs", {}) as Dictionary
		if not bool(ts.get("pond_storage", false)):
			continue
		var tag := str(ts.get("osm_water_tag", ""))
		var live := live_tags.is_empty() or (not tag.is_empty() and live_tags.has(tag))
		var bath := pond_has_usable_bathymetry(ts)
		var d := 0.0
		if GraphSiteLayout.has_site_coords(tank) and GraphSiteLayout.has_site_coords(siphon):
			d = GraphSiteLayout.site_xz(tank).distance_to(siphon_site)
		elif GraphSiteLayout.has_site_coords(tank):
			d = 0.0
		else:
			d = 1.0e6
		# Prefer live + bathymetry. Null floor/rim twins sort after good ponds.
		var score := d \
				+ (0.0 if live else 1.0e7) \
				+ (0.0 if bath else 1.0e6)
		if score < best_score:
			best_score = score
			best_dist = d
			best = tank
	if best.is_empty():
		if not silent:
			_show_toast("No pond on graph — Add to graph from Pond settings first")
		return false
	if not is_nan(max_dist_m) and max_dist_m > 0.0 and best_dist > max_dist_m:
		return false
	var tank_id := str(best.get("id", ""))
	var best_tag := str((best.get("specs", {}) as Dictionary).get("osm_water_tag", ""))
	var best_live := live_tags.is_empty() or live_tags.has(best_tag)
	if not best_live and not silent:
		_show_toast("Bound pond has no map body — orphan ponds are healed automatically")
	# Remove existing water wires to this siphon's water in (avoid duplicates).
	var to_remove: Array[String] = []
	for conn: Dictionary in model.connections:
		var cid := str(conn.get("id", ""))
		var src := str(conn.get("source_item_id", ""))
		var tgt := str(conn.get("target_item_id", ""))
		var sh := str(conn.get("source_handle_id", ""))
		var th := str(conn.get("target_handle_id", ""))
		if tgt == siphon_id and (th == "res_in_0" or th == "input"):
			to_remove.append(cid)
		elif src == siphon_id and (sh.begins_with("res_in_") or sh == "input") \
				and tgt == tank_id:
			to_remove.append(cid)
	for cid in to_remove:
		model.remove_connection(cid)
	# Direct pond→intake: no physical tube (module pierces the bank). Keep the
	# 2D schematic stub; never spawn a 3D hose even if "Make physical" is used.
	model.add_connection({
		"scope_id": str(siphon.get("scope_id", "root")),
		"polarity": "resource",
		"resource_type": "water",
		"source_item_id": tank_id,
		"source_handle_id": "output",
		"target_item_id": siphon_id,
		"target_handle_id": "res_in_0",
		"waypoints": [],
		"line_style": model.last_line_style,
		"curve_tension": 1.0,
		"corner_radius": 8.0,
		"visible_3d": false,
		"direct_intake": true,
	})
	# Seat siphon at pond site; seed module + start/break from pond bathymetry.
	var patch := {}
	if GraphSiteLayout.has_site_coords(best):
		var site := GraphSiteLayout.site_xz(best)
		patch["site_x_m"] = site.x + 1.5
		patch["site_z_m"] = site.y
	var ts2: Dictionary = best.get("specs", {}) as Dictionary
	var rim := float(ts2.get("rim_m", NAN))
	var floor_y := float(ts2.get("floor_m", NAN))
	var level_m := float(ts2.get("level_m", NAN))
	var specs: Dictionary = (siphon.get("specs", {}) as Dictionary).duplicate(true)
	var mod_e := rim - 0.35 if not is_nan(rim) else float(best.get("elevation_m", 0.0))
	specs["module_elev_m"] = mod_e
	var d_in := maxf(float(specs.get("intake_diameter_mm", 150.0)) / 1000.0, 0.05)
	var break_m := mod_e
	if not is_nan(floor_y):
		break_m = maxf(floor_y + 0.15, mod_e - 0.4)
	var start_m := SiphonHydraulics.crown_from_invert(break_m, d_in)
	if not is_nan(level_m):
		start_m = maxf(start_m, level_m - 0.05)
	if not is_nan(rim):
		start_m = minf(start_m, rim - 0.02)
	# Absolutes for save compat + offsets so 3D module moves retarget levels.
	specs["siphon_start_m"] = start_m
	specs["siphon_break_m"] = break_m
	specs["siphon_start_offset_m"] = start_m - mod_e
	specs["siphon_break_offset_m"] = break_m - mod_e
	specs["intake_crown_m"] = start_m
	specs["intake_invert_m"] = break_m
	SiphonHydraulics.apply_resolved_levels(specs, mod_e)
	patch["elevation_m"] = mod_e
	patch["specs"] = specs
	model.update_item(siphon_id, patch)
	heal_pond_terrain_capacity_for_tank(tank_id)
	ensure_siphon_outlet_sink(siphon_id)
	# Select the bound tank in freeform so it's obvious which of N ponds is live.
	if _graph_canvas != null:
		_graph_canvas.set("selected_item_id", tank_id)
		_graph_canvas.call("queue_redraw")
	var live_note := "" if best_live else " (no map twin)"
	_show_toast("Bound to %s%s" % [str(ts2.get("name", "pond")), live_note])
	_schedule_graph_autosave()
	return true


## Re-link graph pond tanks to live map tags when site still overlaps a water body.
func heal_pond_tags_from_map(loader: Node) -> int:
	if model == null or loader == null \
			or not loader.has_method("resolve_pond_idx_for_graph_tank"):
		return 0
	var n := 0
	var n_retagged := 0
	for it in model.items:
		if not (it is Dictionary):
			continue
		var tank: Dictionary = it
		var specs: Dictionary = (tank.get("specs", {}) as Dictionary).duplicate(true)
		if not bool(specs.get("pond_storage", false)):
			continue
		var old_tag := str(specs.get("osm_water_tag", ""))
		var old_pond_id := str(specs.get("pond_id", ""))
		var resolved: Dictionary = loader.call("resolve_pond_idx_for_graph_tank", tank)
		if int(resolved.get("idx", -1)) < 0:
			continue
		var live_tag := str(resolved.get("tag", ""))
		var live_pond_id := str(resolved.get("pond_id", ""))
		# Backfill pond_id even when the tag itself hasn't drifted yet (legacy
		# tank predating the stable-id feature) — nothing to retarget in that
		# case, just stamp the id so future resolves take the fast exact path.
		var tag_stale := not live_tag.is_empty() and live_tag != old_tag
		var id_missing := not live_pond_id.is_empty() and live_pond_id != old_pond_id
		if not tag_stale and not id_missing:
			continue
		if tag_stale:
			specs["osm_water_tag"] = live_tag
		if not live_pond_id.is_empty():
			specs["pond_id"] = live_pond_id
		var live_label := str(resolved.get("label", ""))
		if tag_stale and not live_label.is_empty():
			if live_label.ends_with("Storage"):
				specs["name"] = live_label
			else:
				specs["name"] = "%s Storage" % live_label
		model.update_item(str(tank.get("id", "")), {"specs": specs})
		# Retarget surface catchment / watershed that still used the old tag.
		if tag_stale and not old_tag.is_empty():
			for it2 in model.items:
				if not (it2 is Dictionary):
					continue
				var other: Dictionary = it2
				var os: Dictionary = (other.get("specs", {}) as Dictionary).duplicate(true)
				var touched := false
				if str(os.get("osm_water_tag", "")) == old_tag:
					os["osm_water_tag"] = live_tag
					touched = true
				if str(other.get("type", "")) == "catchment" \
						and str(os.get("osm_tag", "")) == old_tag:
					os["osm_tag"] = live_tag
					touched = true
				if str(os.get("pond_tag", "")) == old_tag:
					os["pond_tag"] = live_tag
					touched = true
				if str(os.get("catchment_kind", "")) == "watershed" \
						and str(os.get("osm_tag", "")) == "watershed_%s" % old_tag:
					os["osm_tag"] = "watershed_%s" % live_tag
					os["pond_tag"] = live_tag
					touched = true
				if touched:
					model.update_item(str(other.get("id", "")), {"specs": os})
			n_retagged += 1
		n += 1
	if n > 0:
		_schedule_graph_autosave()
	if n_retagged > 0:
		_show_toast("Re-linked %d pond tag%s to map water" % [
				n_retagged, "" if n_retagged == 1 else "s"])
	return n


## Drop null-bathymetry pond twins when another tank shares the same tag with
## usable floor/rim (keeps the siphon-bound id if it is the good one).
func heal_duplicate_null_bathymetry_ponds() -> int:
	if model == null:
		return 0
	var by_tag: Dictionary = {}  # tag -> Array[Dictionary]
	for it in model.items:
		if not (it is Dictionary):
			continue
		var tank: Dictionary = it
		var specs: Dictionary = tank.get("specs", {}) as Dictionary
		if not bool(specs.get("pond_storage", false)):
			continue
		if bool(specs.get("outlet_sink", false)):
			continue
		var tag := str(specs.get("osm_water_tag", ""))
		if tag.is_empty():
			continue
		if not by_tag.has(tag):
			by_tag[tag] = []
		(by_tag[tag] as Array).append(tank)
	var n := 0
	var protected: Dictionary = {}
	for it2 in model.items:
		if not (it2 is Dictionary):
			continue
		if str(((it2 as Dictionary).get("specs", {}) as Dictionary).get("role", "")) \
				!= "siphon_hydro":
			continue
		var bound := resolve_siphon_pond(str((it2 as Dictionary).get("id", "")))
		if not bound.is_empty() and pond_has_usable_bathymetry(
				bound.get("specs", {}) as Dictionary):
			protected[str(bound.get("id", ""))] = true
	for tag in by_tag.keys():
		var group: Array = by_tag[tag]
		if group.size() < 2:
			continue
		var has_good := false
		for g in group:
			if pond_has_usable_bathymetry((g as Dictionary).get("specs", {}) as Dictionary):
				has_good = true
				break
		if not has_good:
			continue
		for g2 in group:
			var gd: Dictionary = g2
			var gid := str(gd.get("id", ""))
			if protected.has(gid):
				continue
			if pond_has_usable_bathymetry(gd.get("specs", {}) as Dictionary):
				continue
			model.remove_item(gid)
			n += 1
	if n > 0:
		_schedule_graph_autosave()
		_autosave_pending = true
		_flush_graph_autosave()
		if _graph_canvas != null:
			_graph_canvas.call("queue_redraw")
		_show_toast("Removed %d null-bathymetry pond duplicate(s)" % n)
	return n


## Prefer DEM terrain_capacity_l for an Auto pond tank (Lab enter / bind).
func heal_pond_terrain_capacity_for_tank(tank_id: String) -> bool:
	if model == null or tank_id.is_empty():
		return false
	var tank := model.get_item(tank_id)
	if tank.is_empty():
		return false
	var specs: Dictionary = (tank.get("specs", {}) as Dictionary).duplicate(true)
	if not bool(specs.get("pond_storage", false)):
		return false
	if str(specs.get("capacity_mode", "auto")) == "manual":
		return false
	if bool(specs.get("outlet_sink", false)) or bool(specs.get("unlimited_capacity", false)):
		return false
	var tag := str(specs.get("osm_water_tag", ""))
	if tag.is_empty():
		return false
	var loader := _find_terrain_loader(_get_scene_main_node())
	if loader == null or not loader.has_method("find_pond_idx_by_tag") \
			or not loader.has_method("get_pond_info"):
		return false
	var idx := int(loader.call("find_pond_idx_by_tag", tag))
	if idx < 0:
		return false
	var info: Dictionary = loader.call("get_pond_info", idx) as Dictionary
	if not bool(info.get("valid", false)):
		return false
	var terrain_cap := maxf(float(info.get("terrain_capacity_l",
			info.get("capacity_l", 0.0))), 0.0)
	if terrain_cap < 1.0:
		return false
	var cur := maxf(float(specs.get("capacity_qty", 0.0)), 0.0)
	if terrain_cap <= cur + 1.0:
		return false
	var level := clampf(float(specs.get("level", 0.0)), 0.0, 1.0)
	specs["capacity_qty"] = terrain_cap
	specs["capacity"] = "%.0f L" % terrain_cap
	specs["stock_l"] = level * terrain_cap
	model.update_item(tank_id, {"specs": specs})
	return true


## Full-basin along half-width from live pond poly (metres), else footprint.
func pond_poly_half_width_m(tank: Dictionary, along_dir: Vector2) -> float:
	if tank.is_empty():
		return 4.0
	var specs: Dictionary = tank.get("specs", {}) as Dictionary
	if _graph_canvas != null and _graph_canvas.has_method("_elevation_pond_half_width_m"):
		return float(_graph_canvas.call("_elevation_pond_half_width_m",
				tank, specs, along_dir))
	return maxf(float(specs.get("footprint_w_m", 8.0)) * 0.5, 2.0)


## Cap runaway pond capacity_qty (e.g. 1e12 mistaken for unlimited sink).
func heal_pond_capacity_sanity() -> int:
	if model == null:
		return 0
	const ABSURD := 1.0e10
	var n := 0
	for it in model.items:
		if not (it is Dictionary):
			continue
		var tank: Dictionary = it
		var specs: Dictionary = (tank.get("specs", {}) as Dictionary).duplicate(true)
		if not bool(specs.get("pond_storage", false)):
			continue
		if bool(specs.get("outlet_sink", false)) or bool(specs.get("unlimited_capacity", false)):
			continue
		var cap := float(specs.get("capacity_qty", 0.0))
		if is_nan(cap) or cap < ABSURD:
			continue
		# Prefer bathymetric volume estimate from footprint × depth.
		var floor_m := float(specs.get("floor_m", NAN))
		var rim_m := float(specs.get("rim_m", NAN))
		var fw := maxf(float(specs.get("footprint_w_m", 8.0)), 2.0)
		var fd := maxf(float(specs.get("footprint_d_m", fw)), 2.0)
		var depth := 1.5
		if not is_nan(floor_m) and not is_nan(rim_m) and rim_m > floor_m:
			depth = rim_m - floor_m
		var healed := maxf(fw * fd * depth * 1000.0, 1000.0)  # m³→L approx
		var level := clampf(float(specs.get("level", 0.5)), 0.0, 1.0)
		specs["capacity_qty"] = healed
		specs["stock_l"] = level * healed
		if not is_nan(floor_m) and not is_nan(rim_m):
			var level_m := float(specs.get("level_m", NAN))
			if is_nan(level_m):
				specs["level_m"] = lerpf(floor_m, rim_m, level)
		model.update_item(str(tank.get("id", "")), {"specs": specs})
		n += 1
	if n > 0:
		_schedule_graph_autosave()
		_autosave_pending = true
		_flush_graph_autosave()
		if _graph_canvas != null:
			_graph_canvas.call("queue_redraw")
	return n


## Remove pond tanks + surface catchments whose tags are not in `live_tags`.
## Skips tanks currently feeding a siphon unless `force`.
func prune_orphan_pond_items(live_tags: Dictionary, force: bool = false) -> int:
	if model == null:
		return 0
	var protected: Dictionary = {}
	if not force:
		for it in model.items:
			if not (it is Dictionary):
				continue
			var item: Dictionary = it
			if str((item.get("specs", {}) as Dictionary).get("role", "")) != "siphon_hydro":
				continue
			var tank := resolve_siphon_pond(str(item.get("id", "")))
			if tank.is_empty():
				continue
			var pt := str((tank.get("specs", {}) as Dictionary).get("osm_water_tag", ""))
			if not pt.is_empty():
				protected[pt] = true
			protected[str(tank.get("id", ""))] = true
	var remove_tags: Array[String] = []
	for it in model.items:
		if not (it is Dictionary):
			continue
		var specs: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
		if not bool(specs.get("pond_storage", false)):
			continue
		var tag := str(specs.get("osm_water_tag", ""))
		if tag.is_empty():
			# Untagged storage — treat as orphan unless protected by id.
			if not protected.has(str((it as Dictionary).get("id", ""))):
				remove_tags.append("__id__:%s" % str((it as Dictionary).get("id", "")))
			continue
		if live_tags.has(tag):
			continue
		if protected.has(tag) or protected.has(str((it as Dictionary).get("id", ""))):
			continue
		remove_tags.append(tag)
	var n := 0
	for key in remove_tags:
		if key.begins_with("__id__:"):
			var rid := key.substr("__id__:".length())
			if not rid.is_empty():
				model.remove_item(rid)
				n += 1
			continue
		n += _remove_pond_items_by_tag(key)
		# Also drop hillside watershed catchments tied to this pond.
		n += _remove_watershed_catchment_by_tag("watershed_%s" % key)
	if n > 0:
		_schedule_graph_autosave()
		_autosave_pending = true
		_flush_graph_autosave()
		if _graph_canvas != null:
			_graph_canvas.call("queue_redraw")
		_show_toast("Removed %d stale pond graph item(s)" % n)
	return n


## Create downhill ∞ outlet sink + culvert_pipe from siphon water out (idempotent).
func ensure_siphon_outlet_sink(siphon_id: String) -> String:
	if model == null or siphon_id.is_empty():
		return ""
	var siphon := model.get_item(siphon_id)
	if siphon.is_empty():
		return ""
	# Penstock kinds (PowerSpout / Pelton / Turgo / run-of-river) discharge AT
	# THE MACHINE — the tailwater jet is their outlet. The auto ∞ culvert
	# tailrace is a siphon-only affordance: minting one here drew a phantom
	# culvert barrel off every placed PowerSpout. Also HEAL an already-minted
	# one (existing saves / a kind change) so the phantom disappears on the
	# next Lab open rather than living forever.
	var kind0 := str((siphon.get("specs", {}) as Dictionary).get("turbine_kind", "siphon"))
	if bool(HydroSource.kind_meta(kind0).get("has_penstock", false)):
		_remove_auto_outlet_sink(siphon_id)
		return ""
	# Existing water outlet?
	if _resource_flow != null and _resource_flow.has_method("_resolve_siphon_outlet_tank"):
		var existing: Dictionary = _resource_flow.call("_resolve_siphon_outlet_tank", siphon)
		if not existing.is_empty():
			var es: Dictionary = existing.get("specs", {}) as Dictionary
			if bool(es.get("outlet_sink", false)) or bool(es.get("unlimited_capacity", false)):
				return str(existing.get("id", ""))
	# Fallback scan (true idempotency): _resolve_siphon_outlet_tank only finds a
	# sink still WIRED to a res_out port — if the player wired their own tank
	# first, or the connection was ever dropped, every caller (placement, Lab
	# entry, siphon modal) minted ANOTHER ∞ outlet, which is how a map ends up
	# with "Culvert Outlet" ×N. Reuse an existing sink in this scope instead:
	# one already wired to this siphon wins (extras wired to the same siphon are
	# merged away), else an unwired orphan is re-wired rather than duplicated.
	var scope_id := str(siphon.get("scope_id", "root"))
	var wired_sink_ids: Array[String] = []
	var orphan_sink_id := ""
	for it: Dictionary in model.get_items_in_scope(scope_id):
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		if not bool(sp.get("outlet_sink", false)):
			continue
		var cand_id := str(it.get("id", ""))
		var conns: Array = model.connections_for_item(cand_id)
		var wired_to_this := false
		for cn: Dictionary in conns:
			if str(cn.get("source_item_id", "")) == siphon_id:
				wired_to_this = true
				break
		if wired_to_this:
			wired_sink_ids.append(cand_id)
		elif orphan_sink_id.is_empty() and conns.is_empty():
			orphan_sink_id = cand_id
	if not wired_sink_ids.is_empty():
		for i in range(1, wired_sink_ids.size()):
			model.remove_item(wired_sink_ids[i])
		if wired_sink_ids.size() > 1:
			_show_toast("Merged %d duplicate culvert outlets" % (wired_sink_ids.size() - 1))
			_schedule_graph_autosave()
		return wired_sink_ids[0]
	if not orphan_sink_id.is_empty():
		var siphon_elev0 := float(siphon.get("elevation_m",
				(siphon.get("specs", {}) as Dictionary).get("module_elev_m", 0.0)))
		var orphan_item := model.get_item(orphan_sink_id)
		var orphan_elev := float(orphan_item.get("elevation_m", siphon_elev0 - 9.0))
		model.add_connection({
			"scope_id": scope_id,
			"polarity": "resource",
			"resource_type": "water",
			"source_item_id": siphon_id,
			"source_handle_id": "res_out_0",
			"target_item_id": orphan_sink_id,
			"target_handle_id": "input",
			"waypoints": [],
			"conduit_type": "culvert_pipe",
			"invert_in_m": siphon_elev0 - 0.2,
			"invert_out_m": orphan_elev,
			"visible_3d": true,
			"flow_glow": true,
			"line_style": model.last_line_style,
			"curve_tension": 1.0,
			"corner_radius": 28.0,
		})
		_schedule_graph_autosave()
		return orphan_sink_id
	var sink_id := model.generate_item_id()
	var sx := float(siphon.get("x", 200.0)) + 180.0
	var sy := float(siphon.get("y", 200.0)) + 40.0
	var site_x := float(siphon.get("site_x_m", 0.0))
	var site_z := float(siphon.get("site_z_m", 0.0))
	var siphon_elev := float(siphon.get("elevation_m",
			(siphon.get("specs", {}) as Dictionary).get("module_elev_m", 0.0)))
	var sink_elev := siphon_elev - 9.0
	var route_3d: Array = []
	var daylighted := false

	# Trace a REAL downhill path from the siphon (steepest-descent walk over the
	# actual terrain, Watershed.trace_downhill) so the culvert runs to genuine
	# low ground instead of an arbitrary +12 m / −9 m straight chord that could
	# just as easily tunnel straight into a hillside.
	if GraphSiteLayout.has_site_coords(siphon):
		# Arbitrary-but-separated fallback (matches the old fixed convention) —
		# applied unless the downhill trace below finds a real direction to
		# route in. Guarantees the outlet never lands exactly on top of the
		# siphon even on flat/no-elevation-data terrain.
		site_x = float(siphon.get("site_x_m", 0.0)) + 12.0
		var soi := get_node_or_null("/root/SoiService")
		var loader := _find_terrain_loader(_get_scene_main_node())
		if soi != null and soi.has_method("world_center") and loader != null \
				and loader.has_method("ground_height_at"):
			var center: Vector3 = soi.call("world_center") as Vector3
			var start_world_xz := GraphSiteLayout.site_to_world_xz(
					GraphSiteLayout.site_xz(siphon), center)
			var height_at := Callable(loader, "ground_height_at")
			var trace: Dictionary = Watershed.trace_downhill(
					start_world_xz, height_at, 9.0, 4.0, 60)
			var pts: PackedVector2Array = trace.get("points", PackedVector2Array())
			if pts.size() > 1:
				var end_xz: Vector2 = pts[pts.size() - 1]
				var end_site := GraphSiteLayout.world_xz_to_site(end_xz, center)
				site_x = end_site.x
				site_z = end_site.y
				sink_elev = float(trace.get("final_elev", sink_elev))
				daylighted = true
				# Intermediate points (skip the start — that's the siphon's own
				# port) become mid-route waypoints, buried just under the real
				# ground surface, so the 3D culvert visibly follows the terrain
				# contour downhill instead of a straight tunnel.
				const BURY_M := 0.35
				for i in range(1, pts.size() - 1):
					var p: Vector2 = pts[i]
					var gy := float(height_at.call(p.x, p.y))
					route_3d.append(Vector3(p.x, gy - BURY_M, p.y))

	var specs_s := (siphon.get("specs", {}) as Dictionary).duplicate(true)
	specs_s["outlet_invert_m"] = sink_elev
	model.update_item(siphon_id, {"specs": specs_s})
	model.add_item({
		"id": sink_id,
		"type": "resource",
		"x": sx, "y": sy,
		"width": 72.0, "height": 72.0,
		"scope_id": str(siphon.get("scope_id", "root")),
		"site_x_m": site_x,
		"site_z_m": site_z,
		"elevation_m": sink_elev,
		"specs": {
			"name": "Culvert Outlet",
			"resource_kind": "water",
			"capacity": "∞",
			"capacity_qty": 1.0e12,
			"capacity_unit": "L",
			"level": 0.0,
			"unlimited_capacity": true,
			"outlet_sink": true,
			"cumulative_l": 0.0,
			"live_in_lps": 0.0,
			"cost": 0.0,
		},
		"is_virtual": false,
	})
	# Prefer water output handle (res_out_0); fall back to first water out.
	var out_handle := "res_out_0"
	model.add_connection({
		"scope_id": str(siphon.get("scope_id", "root")),
		"polarity": "resource",
		"resource_type": "water",
		"source_item_id": siphon_id,
		"source_handle_id": out_handle,
		"target_item_id": sink_id,
		"target_handle_id": "input",
		"waypoints": [],
		"route_3d": route_3d,
		"conduit_type": "culvert_pipe",
		"invert_in_m": siphon_elev - 0.2,
		"invert_out_m": sink_elev,
		"visible_3d": true,
		"flow_glow": true,
		"line_style": model.last_line_style,
		"curve_tension": 1.0,
		"corner_radius": 28.0,
	})
	_show_toast("Culvert outlet routed downhill" if daylighted else "∞ culvert outlet ready")
	_schedule_graph_autosave()
	return sink_id


## Remove the catchment + storage tank (and their connection) for a pond tag.
## Returns the number of items removed.
func _remove_pond_items_by_tag(tag: String) -> int:
	if model == null or tag.is_empty():
		return 0
	var remove_ids: Array[String] = []
	for it in model.items:
		if not (it is Dictionary):
			continue
		var specs0: Dictionary = (it as Dictionary).get("specs", {})
		var ty := str((it as Dictionary).get("type", ""))
		if str(specs0.get("osm_water_tag", "")) == tag \
				or (ty == "catchment" and str(specs0.get("osm_tag", "")) == tag):
			remove_ids.append(str((it as Dictionary).get("id", "")))
	for rid in remove_ids:
		if not rid.is_empty():
			model.remove_item(rid)
	return remove_ids.size()


## Same idempotent-reimport cleanup as _remove_pond_items_by_tag, keyed by the
## stable pond_id instead — catches a phantom twin left under a stale tag.
func _remove_pond_items_by_pond_id(pond_id: String) -> int:
	if model == null or pond_id.is_empty():
		return 0
	var remove_ids2: Array[String] = []
	for it2 in model.items:
		if not (it2 is Dictionary):
			continue
		var specs2: Dictionary = (it2 as Dictionary).get("specs", {})
		if str(specs2.get("pond_id", "")) == pond_id:
			remove_ids2.append(str((it2 as Dictionary).get("id", "")))
	for rid2 in remove_ids2:
		if not rid2.is_empty():
			model.remove_item(rid2)
	return remove_ids2.size()


## True if a pond (catchment or storage tank) with this tag — or, preferably,
## this stable pond_id (robust to the tag drifting from a re-carve) — is on
## the graph.
func has_pond_with_tag(tag: String, pond_id: String = "") -> bool:
	if model == null or (tag.is_empty() and pond_id.is_empty()):
		return false
	for it in model.items:
		if not (it is Dictionary):
			continue
		var specs0: Dictionary = (it as Dictionary).get("specs", {})
		if not pond_id.is_empty() and str(specs0.get("pond_id", "")) == pond_id:
			return true
		if str(specs0.get("osm_water_tag", "")) == tag:
			return true
		if str((it as Dictionary).get("type", "")) == "catchment" \
				and str(specs0.get("osm_tag", "")) == tag:
			return true
	return false


## Public pond removal (used when a player deletes / clears a sculpted pond).
func remove_imported_pond(tag: String) -> bool:
	var n := _remove_pond_items_by_tag(tag)
	if n > 0:
		_schedule_graph_autosave()
		_autosave_pending = true
		_flush_graph_autosave()
		print("SystemGraphView: removed pond tag '%s' (%d items)" % [tag, n])
	return n > 0


## Mesh → graph twin: update pond tank (+ catchment) absolute/fractional level.
## Re-entrancy guarded so graph→mesh push doesn't ping-pong.
var _pond_twin_sync_active: bool = false
var _pond_twin_push_timer: Timer = null
## Throttled 3D water rebuild (ambient drain/fill at high time_scale).
var _pond_mesh_last_real_s: float = -1.0e9
var _pond_mesh_last_abs_h: float = NAN
var _pond_mesh_last_levels: Dictionary = {}  # tag → level_m last pushed to mesh
## Ambient water remesh is expensive (full Water rebuild + ReflectionProbes).
## At ~0.5 s this caused a rhythmic 1–2 s FPS surge under high time_scale.
const _POND_MESH_MIN_REAL_S := 3.0
const _POND_MESH_MIN_SIM_H := 2.0
const _POND_MESH_LEVEL_EPS_M := 0.10

func sync_pond_level_from_mesh(tag: String, level_m: float, rim_m: float,
		floor_m: float, capacity_l: float = 0.0, extras: Dictionary = {}) -> void:
	if model == null or tag.is_empty() or _pond_twin_sync_active:
		return
	_pond_twin_sync_active = true
	var pond_id := str(extras.get("pond_id", ""))
	var span := maxf(rim_m - floor_m, 0.05)
	var frac := clampf((level_m - floor_m) / span, 0.0, 1.0)
	if extras.has("level"):
		frac = clampf(float(extras["level"]), 0.0, 1.0)
	elif extras.has("stock_l") and capacity_l > 1e-3:
		frac = clampf(float(extras["stock_l"]) / capacity_l, 0.0, 1.0)
	for it in model.items:
		if not (it is Dictionary):
			continue
		var item: Dictionary = it
		var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		# pond_id match (robust to tag drift) takes priority over the tag match.
		var by_id := not pond_id.is_empty() and str(specs.get("pond_id", "")) == pond_id
		if not by_id and str(specs.get("osm_water_tag", "")) != tag \
				and not (str(item.get("type", "")) == "catchment" \
				and str(specs.get("osm_tag", "")) == tag):
			continue
		# Self-heal a stale tag inline — no separate healing pass needed once a
		# tank carries a pond_id.
		if by_id and str(specs.get("osm_water_tag", "")) != tag:
			specs["osm_water_tag"] = tag
		if by_id and str(item.get("type", "")) == "catchment" \
				and str(specs.get("osm_tag", "")) != tag:
			specs["osm_tag"] = tag
		if not specs.has("pond_id") and not pond_id.is_empty():
			specs["pond_id"] = pond_id
		specs["level_m"] = level_m
		specs["rim_m"] = rim_m
		specs["floor_m"] = floor_m
		if bool(specs.get("pond_storage", false)) \
				or str(item.get("type", "")) == "resource":
			if bool(specs.get("pond_storage", false)):
				# Respect Manual capacity/fill on the tank when mesh syncs.
				var cap_mode := str(extras.get("capacity_mode",
						specs.get("capacity_mode", "auto")))
				var fill_mode := str(extras.get("fill_mode",
						specs.get("fill_mode", "auto")))
				specs["capacity_mode"] = cap_mode
				specs["fill_mode"] = fill_mode
				if extras.has("stock_l"):
					specs["stock_l"] = float(extras["stock_l"])
				if fill_mode != "manual":
					specs["level"] = frac
				if capacity_l > 0.0 and cap_mode != "manual":
					specs["capacity_qty"] = capacity_l
					specs["capacity"] = "%.0f L" % capacity_l
		model.update_item(str(item.get("id", "")), {
			"specs": specs,
			"elevation_m": level_m,
		})
	_pond_twin_sync_active = false


## Graph → mesh: push pond_storage tank stock/level to 3D (bathymetric when possible).
## Ambient sim updates records cheaply; a throttle may rebuild Water when level
## moved enough. Pass `update_mesh=true` for Lab drag / teardown (immediate).
## After a stock push, bathymetric `level_m` is written back onto the tank (and
## surface-catchment twin) so Elev 2D / Lab overlays match the 3D water surface
## instead of a linear floor→rim fallback that can sit above/below the mesh.
func push_pond_levels_to_mesh(update_mesh: bool = false) -> void:
	if model == null or _pond_twin_sync_active:
		return
	var loader := _find_terrain_loader(_get_scene_main_node())
	if loader == null:
		return
	_pond_twin_sync_active = true
	var any := false
	var levels: Dictionary = {}
	var writebacks: Array = []  # [{tag, info}] after mesh stock update
	for it in model.items:
		if not (it is Dictionary):
			continue
		var item: Dictionary = it
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if not bool(specs.get("pond_storage", false)):
			continue
		# Auto fill: sim owns stock → mesh. Manual stays until Apply/push.
		if str(specs.get("fill_mode", "auto")) == "manual" \
				and not bool(specs.get("_pond_manual_push", false)):
			continue
		var tag := str(specs.get("osm_water_tag", ""))
		if tag.is_empty():
			continue
		var stock_l := float(specs.get("stock_l", NAN))
		if is_nan(stock_l):
			var cap := maxf(float(specs.get("capacity_qty", 0.0)), 0.0)
			if cap > 1e-3:
				stock_l = clampf(float(specs.get("level", 0.0)), 0.0, 1.0) * cap
		if not is_nan(stock_l) and loader.has_method("set_pond_stock_l_by_tag"):
			if bool(loader.call("set_pond_stock_l_by_tag", tag, stock_l)):
				any = true
			var lm := NAN
			if loader.has_method("find_pond_idx_by_tag") and loader.has_method("get_pond_info"):
				var pidx := int(loader.call("find_pond_idx_by_tag", tag))
				if pidx >= 0:
					var info: Dictionary = loader.call("get_pond_info", pidx) as Dictionary
					lm = float(info.get("level_m", NAN))
					if bool(info.get("valid", false)):
						writebacks.append({"tag": tag, "info": info})
			if is_nan(lm):
				lm = float(specs.get("level_m", NAN))
			if is_nan(lm):
				var rim0 := float(specs.get("rim_m", NAN))
				var floor0 := float(specs.get("floor_m", NAN))
				if not is_nan(rim0) and not is_nan(floor0):
					var span0 := maxf(rim0 - floor0, 0.05)
					lm = floor0 + clampf(float(specs.get("level", 0.0)), 0.0, 1.0) * span0
			if not is_nan(lm):
				levels[tag] = lm
			continue
		var rim := float(specs.get("rim_m", NAN))
		var floor_y := float(specs.get("floor_m", NAN))
		var level_m := float(specs.get("level_m", NAN))
		if is_nan(level_m) and not is_nan(rim) and not is_nan(floor_y):
			var span := maxf(rim - floor_y, 0.05)
			level_m = floor_y + clampf(float(specs.get("level", 0.0)), 0.0, 1.0) * span
		if is_nan(level_m):
			continue
		levels[tag] = level_m
		if loader.has_method("set_pond_fill_level_by_tag"):
			if bool(loader.call("set_pond_fill_level_by_tag", tag, level_m)):
				any = true
	for wb in writebacks:
		if wb is Dictionary:
			_writeback_pond_twins_from_mesh(
					str((wb as Dictionary).get("tag", "")),
					(wb as Dictionary).get("info", {}) as Dictionary)
	var did_mesh := false
	if update_mesh and any and loader.has_method("refresh_pond_water_mesh"):
		loader.call("refresh_pond_water_mesh")
		did_mesh = true
	elif any and not update_mesh:
		did_mesh = _try_throttled_pond_mesh_rebuild(loader, levels)
	if did_mesh:
		_pond_mesh_remember(levels)
	_pond_twin_sync_active = false
	if update_mesh and any:
		queue_canvas_redraw()


## Inside `_pond_twin_sync_active`: stamp mesh bathymetry onto pond_storage + the
## surface catchment twin so Elev/Lab 2D don't float above/below the 3D bowl.
func _writeback_pond_twins_from_mesh(tag: String, info: Dictionary) -> void:
	if model == null or tag.is_empty() or info.is_empty():
		return
	var lm := float(info.get("level_m", NAN))
	if is_nan(lm):
		return
	var rim := float(info.get("rim_m", NAN))
	var floor_y := float(info.get("floor_m", NAN))
	var stock_l := float(info.get("stock_l", NAN))
	var capacity_l := float(info.get("capacity_l", NAN))
	var frac := float(info.get("fill_frac", NAN))
	if is_nan(frac) and not is_nan(stock_l) and capacity_l > 1e-3:
		frac = clampf(stock_l / capacity_l, 0.0, 1.0)
	elif is_nan(frac) and not is_nan(rim) and not is_nan(floor_y):
		frac = clampf((lm - floor_y) / maxf(rim - floor_y, 0.05), 0.0, 1.0)
	var pond_id := str(info.get("pond_id", ""))
	for it in model.items:
		if not (it is Dictionary):
			continue
		var item: Dictionary = it
		var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		var is_tank := bool(specs.get("pond_storage", false))
		var is_surface := str(item.get("type", "")) == "catchment" \
				and str(specs.get("catchment_kind", "")) == "pond"
		if not is_tank and not is_surface:
			continue
		var by_id := not pond_id.is_empty() and str(specs.get("pond_id", "")) == pond_id
		var by_tag := str(specs.get("osm_water_tag", specs.get("osm_tag", ""))) == tag
		if not by_id and not by_tag:
			continue
		specs["level_m"] = lm
		if not is_nan(rim):
			specs["rim_m"] = rim
		if not is_nan(floor_y):
			specs["floor_m"] = floor_y
		if is_tank:
			if not is_nan(stock_l):
				specs["stock_l"] = stock_l
			if not is_nan(frac) and str(specs.get("fill_mode", "auto")) != "manual":
				specs["level"] = frac
			var terrain_cap := float(info.get("terrain_capacity_l", capacity_l))
			if terrain_cap > 1e-3 and str(specs.get("capacity_mode", "auto")) != "manual":
				# Always prefer DEM bathymetry so Lab fill can reach the basin lip.
				specs["capacity_qty"] = maxf(terrain_cap, capacity_l)
				specs["capacity"] = "%.0f L" % float(specs["capacity_qty"])
			elif capacity_l > 1e-3 and str(specs.get("capacity_mode", "auto")) != "manual":
				specs["capacity_qty"] = capacity_l
				specs["capacity"] = "%.0f L" % capacity_l
		model.update_item(str(item.get("id", "")), {
			"specs": specs,
			"elevation_m": lm,
		})


func _try_throttled_pond_mesh_rebuild(loader: Node, levels: Dictionary) -> bool:
	if loader == null or levels.is_empty() or not loader.has_method("refresh_pond_water_mesh"):
		return false
	var main := _get_scene_main_node()
	if main != null and main.has_method("is_world_suspended_for_lab") \
			and bool(main.call("is_world_suspended_for_lab")):
		return false
	# Siphon Lab forces remesh via lab_siphon_tick — skip ambient here.
	# Elevation CT used to skip entirely (probe hitch); allow throttled remesh
	# so Test-Inflow / rain still raise the 3D pond while watching the section.
	if _graph_view_mode == GraphSiteLayout.VIEW_SIPHON:
		return false
	var now_s := Time.get_ticks_msec() * 0.001
	# Hard cap ~1 rebuild / 3 s.
	if now_s - _pond_mesh_last_real_s < _POND_MESH_MIN_REAL_S:
		return false
	var abs_h := NAN
	if main != null and main.has_method("get_absolute_hours"):
		abs_h = float(main.call("get_absolute_hours"))
	var time_ok := (now_s - _pond_mesh_last_real_s) >= _POND_MESH_MIN_REAL_S
	if not is_nan(abs_h) and not is_nan(_pond_mesh_last_abs_h):
		time_ok = time_ok or absf(abs_h - _pond_mesh_last_abs_h) >= _POND_MESH_MIN_SIM_H
	elif is_nan(_pond_mesh_last_abs_h):
		time_ok = true
	if not time_ok:
		return false
	var max_delta := 0.0
	for tag in levels.keys():
		var lm := float(levels[tag])
		if not _pond_mesh_last_levels.has(tag):
			max_delta = maxf(max_delta, _POND_MESH_LEVEL_EPS_M + 0.01)
			continue
		max_delta = maxf(max_delta, absf(lm - float(_pond_mesh_last_levels[tag])))
	if max_delta < _POND_MESH_LEVEL_EPS_M:
		return false
	loader.call("refresh_pond_water_mesh")
	return true


func _pond_mesh_remember(levels: Dictionary) -> void:
	_pond_mesh_last_real_s = Time.get_ticks_msec() * 0.001
	var main := _get_scene_main_node()
	if main != null and main.has_method("get_absolute_hours"):
		_pond_mesh_last_abs_h = float(main.call("get_absolute_hours"))
	_pond_mesh_last_levels = levels.duplicate()


func _schedule_pond_twin_push() -> void:
	if _pond_twin_sync_active:
		return
	if _pond_twin_push_timer == null:
		_pond_twin_push_timer = Timer.new()
		_pond_twin_push_timer.one_shot = true
		_pond_twin_push_timer.wait_time = 0.12
		add_child(_pond_twin_push_timer)
		_pond_twin_push_timer.timeout.connect(push_pond_levels_to_mesh)
	_pond_twin_push_timer.start()


## Import an OSM field / orchard / vineyard as a plant bed. Idempotent per tag.
func add_imported_plant(payload: Dictionary) -> bool:
	if model == null:
		return false
	var tag := str(payload.get("osm_tag", ""))
	if tag.is_empty():
		return false
	for it in model.items:
		if not (it is Dictionary):
			continue
		var specs0: Dictionary = (it as Dictionary).get("specs", {})
		if str((it as Dictionary).get("type", "")) != "plant":
			continue
		if str(specs0.get("osm_tag", "")) == tag:
			model.remove_item(str((it as Dictionary).get("id", "")))
			break
	var centroid: Vector2 = payload.get("centroid", Vector2.ZERO) as Vector2
	var soi := get_node_or_null("/root/SoiService")
	var site := Vector2.ZERO
	if soi != null and soi.has_method("world_center"):
		site = GraphSiteLayout.world_xz_to_site(centroid, soi.call("world_center") as Vector3)
	var poly: PackedVector2Array = payload.get("points", PackedVector2Array())
	var poly_site: Array = []
	for p in poly:
		poly_site.append([p.x - centroid.x, p.y - centroid.y])
	var area := maxf(float(payload.get("area_m2", 10.0)), 1.0)
	var fw := maxf(float(payload.get("width_m", sqrt(area))), 1.0)
	var fd := maxf(float(payload.get("depth_m", sqrt(area))), 1.0)
	var label := str(payload.get("label", "OSM Field"))
	var specs := {
		"name": label,
		"area_m2": area,
		"use_soi_area": false,
		"lue_g_per_mj": 2.0,
		"water_l_per_kg": 50.0,
		"nutrient_kg_per_kg": 0.02,
		"sunlight_factor": 1.0,
		"cost": 0.0,
		"osm_import": true,
		"osm_tag": tag,
		"veg_kind": str(payload.get("veg_kind", "")),
		"footprint_w_m": fw,
		"footprint_d_m": fd,
		"map_display_scale": 1.0,
		"osm_poly_site": poly_site,
	}
	# Phase 10 food forest: perennials that yield inside a harvest window rather
	# than photosynthesising a crop hour by hour. ResourceFlowEngine._process_plant
	# takes a different branch when food_forest is set.
	var food: Variant = payload.get("food", {})
	if food is Dictionary and float((food as Dictionary).get("kg_per_year", 0.0)) > 0.0:
		var fsum: Dictionary = food
		specs["food_forest"] = true
		specs["food_trees"] = int(fsum.get("trees", 0))
		specs["food_kg_per_year"] = float(fsum.get("kg_per_year", 0.0))
		specs["food_kcal_per_kg"] = float(fsum.get("kcal_per_kg", 0.0))
		specs["food_kcal_per_year"] = float(fsum.get("kcal_per_year", 0.0))
		specs["harvest_start_doy"] = int(fsum.get("harvest_start_doy", 1))
		specs["harvest_end_doy"] = int(fsum.get("harvest_end_doy", 365))
		specs["food_dominant"] = str(fsum.get("dominant", ""))
		specs["food_species"] = (fsum.get("species_counts", {}) as Dictionary).duplicate()
	model.add_item({
		"id": model.generate_item_id(),
		"type": "plant",
		"x": 0.0, "y": 0.0,
		"width": 160.0, "height": 130.0,
		"scope_id": "root",
		"site_x_m": site.x,
		"site_z_m": site.y,
		"specs": specs,
		"is_virtual": false,
	})
	_schedule_graph_autosave()
	_autosave_pending = true
	_flush_graph_autosave()
	print("SystemGraphView: imported plant tag '%s' (%.0f m²)" % [tag, area])
	return true


func has_starshade_graph_content() -> bool:
	return StarShadeGraphSeeder.has_graph_content(model)


## Idempotent: adds real (non-virtual) panels + EcoWorthy controller + 2×48V 50Ah bank.
func seed_starshade_system(panel_count: int, panel_watts: float, tag: String = "starshade_site") -> bool:
	if model == null:
		return false
	if not StarShadeGraphSeeder.seed_graph(model, panel_count, panel_watts, tag):
		return false
	_normalize_battery_bank_display_nodes()
	_schedule_graph_autosave()
	_sync_solar_ui_from_graph()
	return true


func _spawn_processor_ghost_containers(proc_id: String, proc_specs: Dictionary,
		proc_pos: Vector2, proc_w: float, proc_h: float) -> void:
	var inputs: Array = proc_specs.get("inputs", []) as Array
	var outputs: Array = proc_specs.get("outputs", []) as Array
	
	var in_w: float = 90.0
	var in_h: float = 100.0
	var out_w: float = 90.0
	var out_h: float = 100.0
	
	var offset_y := 120.0
	
	# Position inputs at the top
	var total_in_w := float(inputs.size()) * in_w + float(inputs.size() - 1) * 24.0
	var start_in_x := proc_pos.x + (proc_w - total_in_w) * 0.5
	
	for i: int in inputs.size():
		var inp: Dictionary = inputs[i] as Dictionary
		var kind: String = str(inp.get("kind", "water"))
		var ghost_id: String = model.generate_item_id()
		var gx := start_in_x + float(i) * (in_w + 24.0)
		var gy := proc_pos.y - in_h - offset_y
		
		model.add_item({
			"id": ghost_id,
			"type": "resource",
			"x": gx,
			"y": gy,
			"width": in_w,
			"height": in_h,
			"scope_id": _active_scope_id,
			"is_ghost": true,
			"specs": {
				"name": ResourceKinds.display_name(kind),
				"resource_kind": kind,
				"capacity_qty": 100.0,
				"capacity_unit": ResourceKinds.default_unit(kind),
				"level": 0.5,
				"is_ghost": true,
				"cost": 0.0,
			},
		})
		model.add_connection({
			"scope_id": _active_scope_id,
			"polarity": "resource",
			"resource_type": kind,
			"source_item_id": ghost_id,
			"source_handle_id": "output",
			"target_item_id": proc_id,
			"target_handle_id": "res_in_%d" % i,
			"waypoints": [],
			"line_style": "bezier",
			"curve_tension": 1.0,
			"corner_radius": 28.0,
		})

	# Position outputs at the bottom
	var total_out_w := float(outputs.size()) * out_w + float(outputs.size() - 1) * 24.0
	var start_out_x := proc_pos.x + (proc_w - total_out_w) * 0.5
	
	for i: int in outputs.size():
		var outp: Dictionary = outputs[i] as Dictionary
		var kind: String = str(outp.get("kind", "water"))
		var ghost_id: String = model.generate_item_id()
		var gx := start_out_x + float(i) * (out_w + 24.0)
		var gy := proc_pos.y + proc_h + offset_y
		
		model.add_item({
			"id": ghost_id,
			"type": "resource",
			"x": gx,
			"y": gy,
			"width": out_w,
			"height": out_h,
			"scope_id": _active_scope_id,
			"is_ghost": true,
			"specs": {
				"name": ResourceKinds.display_name(kind),
				"resource_kind": kind,
				"capacity_qty": 100.0,
				"capacity_unit": ResourceKinds.default_unit(kind),
				"level": 0.0,
				"is_ghost": true,
				"cost": 0.0,
			},
		})
		model.add_connection({
			"scope_id": _active_scope_id,
			"polarity": "resource",
			"resource_type": kind,
			"source_item_id": proc_id,
			"source_handle_id": "res_out_%d" % i,
			"target_item_id": ghost_id,
			"target_handle_id": "input",
			"waypoints": [],
			"line_style": "bezier",
			"curve_tension": 1.0,
			"corner_radius": 28.0,
		})


# ---------------------------------------------------------------------------
# Library preset -> placed instance sync ("prefab"-style propagation)
# ---------------------------------------------------------------------------

## Spec fields that are inherently per-instance — identity, live simulation
## state, and HA/3D-scene bindings — and must never be overwritten when a
## library preset's config is pushed to sibling instances of the same node.
const _INSTANCE_ONLY_SPEC_KEYS := [
	"name", "graph_automations",
	"scene_device_path", "device_path", "ha_live",
	"model_id", "bound_prop_id",
	"card_preview_yaw_deg", "card_preview_pitch_deg", "card_preview_dist_mult",
	"graph_placeholder", "ibc_tank_link",
	"level", "soc", "current_output_kw", "inflow_rate", "outflow_rate",
	"destroyed", "node_state", "node_state_reason", "node_state_kinds", "deficit_qty",
	"unlimited_capacity", "allow_negative", "scale_with_fill", "jit_outflow",
	"live_capture_lph", "live_capture_rate",
	"pop_state", "pop_present", "pop_morale", "pop_collapse_risk",
	"site_projects",
]

## Called by the inspector after "Save/Add to Library" writes `preset`. Pushes
## the preset's configuration to every OTHER placed graph item of the same
## type + name (the same identity ComponentPresets uses to match a preset) —
## editing "the template" updates all its copies on the canvas, mirroring a
## prefab workflow. Runtime state, HA links, and 3D bindings stay per-instance
## (see _INSTANCE_ONLY_SPEC_KEYS). Processor instances also get their
## auto-spawned resource-tank ports ("connected containers") resynced to
## match any input/output changes in the preset.
func sync_library_instances_from_preset(preset: Dictionary, source_item_id: String) -> void:
	if model == null:
		return
	var itype := str(preset.get("type", ""))
	var name_val := str(preset.get("label", ""))
	if itype.is_empty() or name_val.is_empty():
		return
	var preset_specs: Dictionary = preset.get("specs", {}) as Dictionary
	var updated := 0
	for it: Dictionary in model.items.duplicate():
		var iid := str(it.get("id", ""))
		if iid == source_item_id or iid.is_empty():
			continue
		if str(it.get("type", "")) != itype:
			continue
		var cur_specs: Dictionary = it.get("specs", {}) as Dictionary
		if str(cur_specs.get("name", "")) != name_val:
			continue
		var new_specs: Dictionary = preset_specs.duplicate(true)
		for key: String in _INSTANCE_ONLY_SPEC_KEYS:
			if cur_specs.has(key):
				new_specs[key] = cur_specs[key]
			else:
				new_specs.erase(key)
		model.update_item(iid, {"specs": new_specs})
		if itype == "processor":
			_sync_processor_ghost_containers(iid, new_specs)
		updated += 1
	if updated > 0:
		_show_toast("Updated %d placed instance%s to match" % [updated, "" if updated == 1 else "s"])


## Category id ("processors" vs "habitats") ComponentPresets uses to store/
## look up a processor-type item's preset, keyed off specs.role.
func _library_category_for_specs(specs: Dictionary) -> String:
	var role := str(specs.get("role", ""))
	if role == "habitat":
		return "habitats"
	if role == "cartesian_machine":
		return "tools"
	return "processors"


## Called by the inspector's "Save to Library" button. Builds a preset from
## the item's current specs (stripping instance-only state — see
## _INSTANCE_ONLY_SPEC_KEYS — except the identity "name"), saves/updates it in
## the user preset store, then reuses sync_library_instances_from_preset to
## push the change to every other placed instance of the same template.
func save_item_to_library(item_id: String) -> void:
	if model == null:
		return
	var item := model.get_item(item_id)
	if item.is_empty() or str(item.get("type", "")) != "processor":
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var label := str(specs.get("name", "")).strip_edges()
	if label.is_empty():
		label = "Custom Component"
		specs["name"] = label
	var cat_id := _library_category_for_specs(specs)
	var preset_specs: Dictionary = specs.duplicate(true)
	for key: String in _INSTANCE_ONLY_SPEC_KEYS:
		if key != "name":
			preset_specs.erase(key)
	var icon := "⚙"
	for p: Dictionary in ComponentPresets.presets_for_category(cat_id):
		if str(p.get("label", "")) == label:
			icon = str(p.get("icon", icon))
			break
	var preset := {
		"type": "processor", "label": label, "icon": icon,
		"width": float(item.get("width", 130.0)),
		"height": float(item.get("height", 120.0)),
		"specs": preset_specs,
	}
	ComponentPresets.save_user_preset(cat_id, preset)
	sync_library_instances_from_preset(preset, item_id)
	_show_toast("Saved '%s' to library" % label)


## Called by the inspector directly after an in-place I/O edit (add/remove
## port, change a port's kind) on a single processor instance — resyncs that
## instance's own auto-spawned resource-tank ports to match, independent of
## any library-preset push. No-op for non-processor items.
func sync_processor_ghost_containers_for_item(item_id: String) -> void:
	if model == null:
		return
	var item := model.get_item(item_id)
	if item.is_empty() or str(item.get("type", "")) != "processor":
		return
	_sync_processor_ghost_containers(item_id, item.get("specs", {}) as Dictionary)


## Resyncs a processor instance's auto-spawned resource-tank ports ("connected
## containers") after `proc_specs` was refreshed from a library preset. Ports
## whose kind changed get their tank refreshed in place (renamed only if the
## label still matches the auto-generated pattern, so a user-renamed tank is
## left alone); new ports (the preset grew inputs/outputs) get a freshly
## spawned tank + wire. Ports removed from the preset are left as-is on the
## canvas rather than silently deleted (same as manually removing an I/O row).
func _sync_processor_ghost_containers(proc_id: String, proc_specs: Dictionary) -> void:
	if model == null:
		return
	var proc_item := model.get_item(proc_id)
	if proc_item.is_empty():
		return
	var proc_pos := Vector2(float(proc_item.get("x", 0.0)), float(proc_item.get("y", 0.0)))
	var proc_w := float(proc_item.get("width", 130.0))
	var proc_h := float(proc_item.get("height", 120.0))
	var scope_id := str(proc_item.get("scope_id", _active_scope_id))

	_sync_processor_ghost_side(proc_id, proc_specs.get("inputs", []) as Array, true,
		proc_pos, proc_w, proc_h, scope_id)
	_sync_processor_ghost_side(proc_id, proc_specs.get("outputs", []) as Array, false,
		proc_pos, proc_w, proc_h, scope_id)


func _sync_processor_ghost_side(proc_id: String, ports: Array, is_input: bool,
		proc_pos: Vector2, proc_w: float, proc_h: float, scope_id: String) -> void:
	var g_w: float = 90.0
	var g_h: float = 100.0
	var offset_y := 120.0
	var count := ports.size()
	var total_w := float(count) * g_w + float(maxi(count - 1, 0)) * 24.0
	var start_x := proc_pos.x + (proc_w - total_w) * 0.5
	var gy := (proc_pos.y - g_h - offset_y) if is_input else (proc_pos.y + proc_h + offset_y)

	for i in count:
		var port: Dictionary = ports[i] as Dictionary
		var kind := str(port.get("kind", "water"))
		var handle_id := ("res_in_%d" % i) if is_input else ("res_out_%d" % i)
		var ghost_id := _ghost_tank_at_port(proc_id, handle_id, is_input)
		var gx := start_x + float(i) * (g_w + 24.0)

		if ghost_id.is_empty():
			# New port on the resynced processor — spawn a tank + wire, matching
			# the original spawn-time layout (_spawn_processor_ghost_containers).
			var new_id := model.generate_item_id()
			model.add_item({
				"id": new_id, "type": "resource",
				"x": gx, "y": gy, "width": g_w, "height": g_h,
				"scope_id": scope_id, "is_ghost": true,
				"specs": {
					"name": ResourceKinds.display_name(kind),
					"resource_kind": kind,
					"capacity_qty": 100.0,
					"capacity_unit": ResourceKinds.default_unit(kind),
					"level": 0.5 if is_input else 0.0,
					"is_ghost": true,
					"cost": 0.0,
				},
			})
			var conn := {
				"scope_id": scope_id, "polarity": "resource", "resource_type": kind,
				"waypoints": [], "line_style": "bezier",
				"curve_tension": 1.0, "corner_radius": 28.0,
			}
			if is_input:
				conn["source_item_id"] = new_id
				conn["source_handle_id"] = "output"
				conn["target_item_id"] = proc_id
				conn["target_handle_id"] = handle_id
			else:
				conn["source_item_id"] = proc_id
				conn["source_handle_id"] = handle_id
				conn["target_item_id"] = new_id
				conn["target_handle_id"] = "input"
			model.add_connection(conn)
			continue

		var g_item := model.get_item(ghost_id)
		if g_item.is_empty():
			continue
		var g_specs: Dictionary = (g_item.get("specs", {}) as Dictionary).duplicate(true)
		var old_kind := str(g_specs.get("resource_kind", ""))
		if old_kind == kind:
			continue
		var auto_name := ResourceKinds.display_name(old_kind)
		if str(g_specs.get("name", "")) == auto_name:
			g_specs["name"] = ResourceKinds.display_name(kind)
		g_specs["resource_kind"] = kind
		g_specs["capacity_unit"] = ResourceKinds.default_unit(kind)
		model.update_item(ghost_id, {"specs": g_specs})


## Finds the ghost resource-tank item wired to a processor's res_in_N/res_out_N
## port, if any (mirrors ResourceFlowEngine._tank_at_port's lookup pattern).
func _ghost_tank_at_port(proc_id: String, handle_id: String, is_input: bool) -> String:
	if model == null:
		return ""
	for conn: Dictionary in model.connections:
		if is_input:
			if str(conn.get("target_item_id", "")) != proc_id:
				continue
			if str(conn.get("target_handle_id", "")) != handle_id:
				continue
			var src := model.get_item(str(conn.get("source_item_id", "")))
			if not src.is_empty() and bool(src.get("is_ghost", false)):
				return str(src.get("id", ""))
		else:
			if str(conn.get("source_item_id", "")) != proc_id:
				continue
			if str(conn.get("source_handle_id", "")) != handle_id:
				continue
			var tgt := model.get_item(str(conn.get("target_item_id", "")))
			if not tgt.is_empty() and bool(tgt.get("is_ghost", false)):
				return str(tgt.get("id", ""))
	return ""


# ---------------------------------------------------------------------------
# Selection callbacks
# ---------------------------------------------------------------------------

func select_item_by_id(item_id: String) -> void:
	if _graph_canvas == null:
		return
	_selected_item_ids.clear()
	if not item_id.is_empty():
		_selected_item_ids.append(item_id)
	if _graph_canvas.has_method("_select_item"):
		_graph_canvas.call("_select_item", item_id)
	else:
		_graph_canvas.set("selected_item_id", item_id)
		_graph_canvas.set("selected_item_ids", _selected_item_ids.duplicate())
		_graph_canvas.call("queue_redraw")
	if item_id.is_empty():
		_on_canvas_item_selected("")
	else:
		_on_canvas_item_selected(item_id)


func find_item_by_bound_prop_id(prop_id: String) -> String:
	if model == null or prop_id.is_empty():
		return ""
	return _GRAPH_EMBODIMENT_SCRIPT.find_item_by_bound_prop_id(model, prop_id)


func find_items_by_osm_tag(tag: String) -> Array[String]:
	if model == null or tag.is_empty():
		return []
	return _GRAPH_EMBODIMENT_SCRIPT.find_items_by_osm_tag(model, tag)


func select_item_by_world_binding(prop_id: String = "", osm_tag: String = "",
		scene_path: String = "") -> void:
	if model == null:
		return
	var item_id := ""
	if not prop_id.is_empty():
		item_id = find_item_by_bound_prop_id(prop_id)
	if item_id.is_empty() and not osm_tag.is_empty():
		var ids := find_items_by_osm_tag(osm_tag)
		if not ids.is_empty():
			item_id = ids[0]
	if item_id.is_empty() and not scene_path.is_empty():
		item_id = _GRAPH_EMBODIMENT_SCRIPT.find_item_by_scene_path(model, scene_path)
	if item_id.is_empty():
		return
	select_item_by_id(item_id)


func _clear_embodiment_highlight() -> void:
	var main := _get_scene_main_node()
	if not _embodiment_prop_id.is_empty() and main != null:
		var prop := _PLACED_PROP_RUNTIME_SCRIPT.find_by_prop_id(main, _embodiment_prop_id)
		if prop != null:
			prop.set_graph_highlight(false)
	_embodiment_prop_id = ""
	_embodiment_solar_tag = ""
	var loader := _find_terrain_loader(main)
	if loader != null:
		if loader.has_method("clear_graph_solar_highlight"):
			loader.call("clear_graph_solar_highlight")
		if loader.has_method("clear_graph_scene_highlight"):
			loader.call("clear_graph_scene_highlight")
		if loader.has_method("clear_graph_osm_area_highlight"):
			loader.call("clear_graph_osm_area_highlight")


func _apply_embodiment_highlight(item: Dictionary) -> void:
	_clear_embodiment_highlight()
	if item.is_empty():
		return
	var main := _get_scene_main_node()
	var loader := _find_terrain_loader(main)
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var prop_id := str(specs.get("bound_prop_id", ""))
	if not prop_id.is_empty() and main != null:
		_embodiment_prop_id = prop_id
		var prop := _PLACED_PROP_RUNTIME_SCRIPT.find_by_prop_id(main, prop_id)
		if prop != null:
			prop.set_graph_highlight(true)
		return
	var osm_tag := str(specs.get("osm_tag", ""))
	var itype := str(item.get("type", ""))
	if not osm_tag.is_empty() and loader != null:
		if itype == "catchment" and loader.has_method("highlight_building_by_tag"):
			if bool(loader.call("highlight_building_by_tag", osm_tag)):
				return
		if itype == "plant" and loader.has_method("highlight_veg_by_tag"):
			if bool(loader.call("highlight_veg_by_tag", osm_tag)):
				return
		if loader.has_method("highlight_solar_by_tag"):
			_embodiment_solar_tag = osm_tag
			loader.call("highlight_solar_by_tag", osm_tag)
			return
	var scene_path := str(specs.get("scene_device_path", item.get("device_path", "")))
	if not scene_path.is_empty() and main != null:
		var node: Node = main.get_node_or_null(NodePath(scene_path))
		if node == null:
			node = get_tree().root.get_node_or_null(NodePath(scene_path))
		if node != null and loader != null and loader.has_method("highlight_scene_node_for_graph"):
			loader.call("highlight_scene_node_for_graph", node)


func _on_canvas_item_selected(item_id: String) -> void:
	_selected_item_ids.clear()
	if not item_id.is_empty():
		_selected_item_ids.append(item_id)
	_update_special_group_buttons()
	if item_id.is_empty():
		# Deselected — return to library tab, clear inspector
		_clear_embodiment_highlight()
		if _inspector_panel != null and _inspector_panel.has_method("clear_selection"):
			_inspector_panel.call("clear_selection")
		_show_right_tab("library")
		return
	if model == null:
		return
	var item := model.get_item(item_id)
	if item.is_empty():
		return
	_apply_embodiment_highlight(item)
	if _inspector_panel != null and _inspector_panel.has_method("inspect_item"):
		_inspector_panel.call("inspect_item", item, model)
	_show_right_tab("inspector")
	_update_make_array_quick_button()


func _on_canvas_item_double_tapped(item_id: String) -> void:
	if item_id.is_empty() or model == null:
		return
	var item := model.get_item(item_id)
	if item.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if str(specs.get("role", "")) == "siphon_hydro":
		open_siphon_lab(item_id)
		return
	if _mode == "test" and item.has("device_path"):
		_try_toggle_device(item)


func _on_canvas_items_multi_selected(item_ids: Array) -> void:
	_clear_embodiment_highlight()
	_selected_item_ids.clear()
	for v in item_ids:
		var sid: String = str(v)
		if not sid.is_empty():
			_selected_item_ids.append(sid)
	_update_special_group_buttons()
	if _inspector_panel != null and _inspector_panel.has_method("clear_selection"):
		_inspector_panel.call("clear_selection")
	_show_right_tab("library")
	_update_make_array_quick_button()


func _on_open_compound_requested(item_id: String) -> void:
	_enter_compound_animated(item_id)


## Seamless drill-in: capture the collapsed body rect, swap scope, then let the
## canvas grow the child content out of that rect (continuous zoom-through).
func _enter_compound_animated(item_id: String) -> void:
	if _graph_canvas != null and _graph_canvas.has_method("begin_enter_transition"):
		_graph_canvas.call("begin_enter_transition", item_id)
	_enter_compound(item_id)
	if _graph_canvas != null and _graph_canvas.has_method("finish_enter_transition"):
		_graph_canvas.call("finish_enter_transition")
	elif _graph_canvas != null and _graph_canvas.has_method("fit_scope_to_view"):
		_graph_canvas.call("fit_scope_to_view")


## Zoom-out-past-floor while inside a sub-canvas — pop up to the parent scope and
## re-center on the super-node we just left (mirror of the drill-in transition).
func _on_scope_pop_requested() -> void:
	_collapse_active_scope(true)


func _on_canvas_connection_selected(conn_id: String) -> void:
	_selected_item_ids.clear()
	_update_special_group_buttons()
	if conn_id.is_empty():
		if _inspector_panel != null and _inspector_panel.has_method("clear_selection"):
			_inspector_panel.call("clear_selection")
		_show_right_tab("library")
		return
	if model == null:
		return
	var conn := model.get_connection(conn_id)
	if conn.is_empty():
		return
	if _inspector_panel != null and _inspector_panel.has_method("inspect_connection"):
		_inspector_panel.call("inspect_connection", conn, model)
	_show_right_tab("inspector")
	_update_make_array_quick_button()


## Select a graph connection from world conduit focus (crosshair).
func select_connection_by_id(conn_id: String) -> void:
	if conn_id.is_empty() or model == null:
		return
	if _graph_canvas != null:
		_graph_canvas.set("selected_connection_id", conn_id)
		_graph_canvas.set("selected_item_id", "")
		if _graph_canvas.has_method("queue_redraw"):
			_graph_canvas.call("queue_redraw")
	_on_canvas_connection_selected(conn_id)


func _on_left_toggle() -> void:
	_sidebar_l_open = not _sidebar_l_open
	_apply_layout()


func _on_right_toggle() -> void:
	_sidebar_r_open = not _sidebar_r_open
	_apply_layout()


# ---------------------------------------------------------------------------
# Topbar callbacks  (Phase 9)
# ---------------------------------------------------------------------------

func _on_graph_menu_id(id: int) -> void:
	match id:
		1:
			_open_graph_file_dialog(true)
		2:
			_open_graph_file_dialog(false)
		3:
			_confirm_reset_graph()


## Reset wipes every node/wire with history SUPPRESSED (not undoable) — it
## must never fire from a single misclick. One shared confirm guards both the
## topbar Reset button and Graph ▾ → Reset.
var _reset_confirm: ConfirmationDialog = null

func _confirm_reset_graph() -> void:
	if _reset_confirm == null:
		_reset_confirm = ConfirmationDialog.new()
		_reset_confirm.title = "Reset graph"
		_reset_confirm.dialog_text = (
			"Remove every node and wire from this map's graph?\n"
			+ "Placed 3D objects stay in the world. This cannot be undone.")
		_reset_confirm.ok_button_text = "Reset graph"
		_reset_confirm.confirmed.connect(func() -> void:
			_on_reset_graph()
			_autosave_pending = true
			_flush_graph_autosave()
			_try_seed_starshade_if_empty()
			_refresh_osm_solar_btn()
		)
		add_child(_reset_confirm)
	_reset_confirm.popup_centered()


func _on_site_menu_id(id: int) -> void:
	match id:
		10:
			_open_esim_file_dialog("export")
		11:
			_open_esim_file_dialog("import")
		12:
			_open_esim_file_dialog("ghost")
		13:
			clear_esim_ghost()
			_show_toast("Ghost preview cleared")
		14:
			_apply_esim_ghost_graph()
		15:
			_copy_esim_share_code()
		16:
			_open_esim_paste_dialog()


func _ensure_esim_file_dialog() -> void:
	if _esim_file_dialog != null and is_instance_valid(_esim_file_dialog):
		return
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(_ESIM_PACKAGE_SCRIPT.LIBRARY_DIR))
	var dlg := FileDialog.new()
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dlg.filters = PackedStringArray([
		"*.esim ; SIMbiogenesis site package",
		"*.esim.json ; SIMbiogenesis site package (JSON)",
		"*.json ; JSON",
	])
	dlg.use_native_dialog = true
	dlg.size = Vector2i(780, 520)
	dlg.file_selected.connect(_on_esim_file_selected)
	dlg.canceled.connect(func() -> void:
		CursorController.release_modal("esim_file_dialog"))
	add_child(dlg)
	_esim_file_dialog = dlg


func _open_esim_file_dialog(mode: String) -> void:
	_ensure_esim_file_dialog()
	_esim_file_dialog.set_meta("esim_mode", mode)
	match mode:
		"export":
			_esim_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
			_esim_file_dialog.title = "Export site (.esim)"
			var stamp := Time.get_datetime_string_from_system().replace(":", "-")
			_esim_file_dialog.current_file = "site_%s.esim" % stamp
		"import":
			_esim_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
			_esim_file_dialog.title = "Import site (.esim) — replace mine"
			_esim_file_dialog.current_file = ""
		_:
			_esim_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
			_esim_file_dialog.title = "Preview site as ghost (.esim)"
			_esim_file_dialog.current_file = ""
	_esim_file_dialog.popup_centered()
	CursorController.request_modal("esim_file_dialog", Callable())


func _on_esim_file_selected(path: String) -> void:
	CursorController.release_modal("esim_file_dialog")
	if _esim_file_dialog == null:
		return
	var mode := str(_esim_file_dialog.get_meta("esim_mode", "export"))
	var full := path
	if mode == "export":
		if not full.ends_with(".esim") and not full.ends_with(".esim.json") \
				and not full.ends_with(".json"):
			full += ".esim"
		_export_esim_to_path(full)
	elif mode == "import":
		_import_esim_from_path(full, "replace")
	else:
		_import_esim_from_path(full, "ghost")


func _export_esim_to_path(path: String) -> void:
	var main_node := _get_scene_main_node()
	var collected: Dictionary = _ESIM_PACKAGE_SCRIPT.collect_from_main(main_node)
	if not bool(collected.get("ok", false)):
		_show_toast("⚠  %s" % str(collected.get("error", "Export failed")))
		return
	var pkg: Dictionary = collected.get("package", {}) as Dictionary
	var saved: Dictionary = _ESIM_PACKAGE_SCRIPT.save_to_path(pkg, path)
	if not bool(saved.get("ok", false)):
		_show_toast("⚠  %s" % str(saved.get("error", "Could not write .esim")))
		return
	# Also keep a copy under user:// for easy re-share.
	var lib_name := path.get_file()
	if lib_name.is_empty():
		lib_name = "site.esim"
	_ESIM_PACKAGE_SCRIPT.save_to_path(
		pkg, "%s/%s" % [_ESIM_PACKAGE_SCRIPT.LIBRARY_DIR, lib_name])
	var summary: Dictionary = pkg.get("summary", {}) as Dictionary
	_show_toast("💾  Site exported · %d nodes · %d props" % [
		int(summary.get("item_count", 0)),
		int(summary.get("prop_count", 0)),
	])


func _import_esim_from_path(path: String, mode: String) -> void:
	var result: Dictionary = _ESIM_IMPORTER_SCRIPT.apply_file(get_tree(), path, {"mode": mode})
	_report_esim_result(result, mode)


func _report_esim_result(result: Dictionary, mode: String) -> void:
	if not bool(result.get("ok", false)):
		_show_toast("⚠  %s" % str(result.get("error", "Import failed")))
		return
	for w in result.get("warnings", []) as Array:
		_show_toast("⚠  %s" % str(w), 3.5)
	var summary: Dictionary = result.get("summary", {}) as Dictionary
	if mode == "ghost":
		_show_toast("👻  Ghost preview · %d foreign nodes" % int(result.get(
			"item_count", summary.get("item_count", 0))))
	else:
		_show_toast("📂  Site imported · %d nodes · %d props" % [
			int(summary.get("item_count", 0)),
			int(summary.get("prop_count", 0)),
		])
	_refresh_osm_solar_btn()
	if _graph_canvas != null:
		_graph_canvas.queue_redraw()


func _copy_esim_share_code() -> void:
	var main_node := _get_scene_main_node()
	var collected: Dictionary = _ESIM_PACKAGE_SCRIPT.collect_from_main(main_node)
	if not bool(collected.get("ok", false)):
		_show_toast("⚠  %s" % str(collected.get("error", "Collect failed")))
		return
	var encoded: Dictionary = _ESIM_PACKAGE_SCRIPT.encode_share_code(
		collected.get("package", {}) as Dictionary)
	if not bool(encoded.get("ok", false)):
		_show_toast("⚠  %s" % str(encoded.get("error", "Encode failed")))
		return
	DisplayServer.clipboard_set(str(encoded.get("code", "")))
	_show_toast("📋  Share code copied (%d chars)" % int(encoded.get("code_chars", 0)))


func _open_esim_paste_dialog() -> void:
	if _esim_paste_dialog == null or not is_instance_valid(_esim_paste_dialog):
		var dlg := ConfirmationDialog.new()
		dlg.title = "Paste .esim share code"
		dlg.ok_button_text = "Preview as ghost"
		dlg.cancel_button_text = "Cancel"
		dlg.dialog_hide_on_ok = false
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 8)
		var hint := Label.new()
		hint.text = "Paste an ESIM1:… code from a friend. Opens as a ghost overlay first."
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		col.add_child(hint)
		var edit := TextEdit.new()
		edit.custom_minimum_size = Vector2(520, 160)
		edit.placeholder_text = "ESIM1:…"
		edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		col.add_child(edit)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var apply_btn := Button.new()
		apply_btn.text = "Import (replace mine)"
		apply_btn.pressed.connect(func() -> void:
			_finish_esim_paste("replace"))
		row.add_child(apply_btn)
		col.add_child(row)
		dlg.add_child(col)
		dlg.confirmed.connect(func() -> void:
			_finish_esim_paste("ghost"))
		dlg.canceled.connect(func() -> void:
			CursorController.release_modal("esim_paste_dialog"))
		add_child(dlg)
		_esim_paste_dialog = dlg
		_esim_paste_edit = edit
	_esim_paste_edit.text = ""
	var clip := DisplayServer.clipboard_get().strip_edges()
	if clip.begins_with(_ESIM_PACKAGE_SCRIPT.PASTE_PREFIX):
		_esim_paste_edit.text = clip
	_esim_paste_dialog.popup_centered()
	CursorController.request_modal("esim_paste_dialog", Callable())


func _finish_esim_paste(mode: String) -> void:
	CursorController.release_modal("esim_paste_dialog")
	if _esim_paste_dialog != null:
		_esim_paste_dialog.hide()
	var code := ""
	if _esim_paste_edit != null:
		code = _esim_paste_edit.text
	var result: Dictionary = _ESIM_IMPORTER_SCRIPT.apply_share_code(
		get_tree(), code, {"mode": mode})
	_report_esim_result(result, mode)


func load_esim_as_ghost(package: Dictionary) -> Dictionary:
	var v: Dictionary = _ESIM_PACKAGE_SCRIPT.validate(package)
	if not bool(v.get("ok", false)):
		return v
	if model == null:
		return {"ok": false, "error": "Graph model missing"}
	clear_esim_ghost()
	var overlay: Dictionary = _ESIM_PACKAGE_SCRIPT.make_ghost_overlay(
		package.get("system_graph", {}) as Dictionary)
	var items: Array = overlay.get("items", []) as Array
	if items.is_empty():
		return {"ok": false, "error": "Package graph has no nodes to preview"}

	_history_suppress = true
	var defs: Dictionary = overlay.get("definitions", {}) as Dictionary
	for did in defs.keys():
		var def: Variant = defs[did]
		if def is Dictionary and model.get_definition(str(did)).is_empty():
			model.put_definition(def as Dictionary)

	var scopes: Dictionary = overlay.get("scopes", {}) as Dictionary
	for sid in scopes.keys():
		var sd: Dictionary = scopes[sid] as Dictionary if scopes[sid] is Dictionary else {}
		model.ensure_scope(
			str(sid),
			str(sd.get("parent_scope_id", "root")),
			str(sd.get("owner_compound_id", "")),
			str(sd.get("title", "")))

	for it in items:
		if it is Dictionary:
			model.add_item((it as Dictionary).duplicate(true))
	for c in overlay.get("connections", []) as Array:
		if c is Dictionary:
			model.add_connection((c as Dictionary).duplicate(true))
	_history_suppress = false

	_esim_ghost_active = true
	_esim_ghost_package = package.duplicate(true)
	if _graph_canvas != null:
		_graph_canvas.queue_redraw()
	return {
		"ok": true,
		"item_count": int(overlay.get("item_count", items.size())),
		"connection_count": int(overlay.get("connection_count", 0)),
		"summary": _ESIM_PACKAGE_SCRIPT.summary_of(package),
		"warnings": [],
	}


func clear_esim_ghost() -> void:
	if model == null:
		_esim_ghost_active = false
		_esim_ghost_package = {}
		return
	_history_suppress = true
	var to_remove: Array = []
	for it in model.items:
		if it is Dictionary and bool((it as Dictionary).get("esim_ghost", false)):
			to_remove.append(str((it as Dictionary).get("id", "")))
	for iid in to_remove:
		if not str(iid).is_empty():
			model.remove_item(str(iid))
	# Drop leftover ghost scopes (compounds may already cascade these).
	var scope_keys: Array = model.scopes.keys()
	for sk in scope_keys:
		var key := str(sk)
		if key.begins_with(_ESIM_PACKAGE_SCRIPT.ESIM_GHOST_SCOPE_PREFIX):
			model.remove_scope(key)
	_history_suppress = false
	_esim_ghost_active = false
	_esim_ghost_package = {}
	if _graph_canvas != null:
		_graph_canvas.queue_redraw()


func _apply_esim_ghost_graph() -> void:
	if not _esim_ghost_active or _esim_ghost_package.is_empty():
		_show_toast("⚠  No ghost preview loaded")
		return
	var pkg := _esim_ghost_package.duplicate(true)
	clear_esim_ghost()
	var result: Dictionary = _ESIM_IMPORTER_SCRIPT.apply_to_scene(
		get_tree(), pkg, {"mode": "replace", "graph_only": false})
	_report_esim_result(result, "replace")


func _ensure_graph_file_dialog() -> void:
	if _graph_file_dialog != null and is_instance_valid(_graph_file_dialog):
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GRAPH_LIBRARY_DIR))
	var dlg := FileDialog.new()
	dlg.access = FileDialog.ACCESS_USERDATA
	dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dlg.filters = PackedStringArray(["*.graph.json ; Graph snapshot", "*.json ; JSON"])
	dlg.current_dir = "saves/graphs"
	dlg.use_native_dialog = false
	dlg.size = Vector2i(720, 480)
	dlg.file_selected.connect(_on_graph_file_selected)
	dlg.canceled.connect(func() -> void:
		CursorController.release_modal("graph_file_dialog"))
	add_child(dlg)
	_graph_file_dialog = dlg


func _open_graph_file_dialog(save_mode: bool) -> void:
	_ensure_graph_file_dialog()
	_graph_file_dialog.set_meta("graph_save_mode", save_mode)
	if save_mode:
		_graph_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		_graph_file_dialog.title = "Export graph"
		var stamp := Time.get_datetime_string_from_system().replace(":", "-")
		_graph_file_dialog.current_file = "graph_%s.graph.json" % stamp
	else:
		_graph_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_graph_file_dialog.title = "Import graph"
		_graph_file_dialog.current_file = ""
	_graph_file_dialog.popup_centered()
	CursorController.request_modal("graph_file_dialog", Callable())


func _on_graph_file_selected(path: String) -> void:
	CursorController.release_modal("graph_file_dialog")
	if _graph_file_dialog == null:
		return
	var save_mode := bool(_graph_file_dialog.get_meta("graph_save_mode", true))
	# ACCESS_USERDATA paths are relative to user://.
	var full := path
	if not path.begins_with("user://") and not path.begins_with("res://") \
			and not path.is_absolute_path():
		full = "user://" + path.trim_prefix("/")
	if not full.ends_with(".graph.json") and not full.ends_with(".json"):
		full += ".graph.json"
	if save_mode:
		_export_graph_to_path(full)
	else:
		_import_graph_from_path(full)


func _export_graph_to_path(path: String) -> void:
	_autosave_pending = true
	_flush_graph_autosave()
	var payload := collect_save_state()
	payload["map_graph_key"] = _resolve_map_graph_key()
	payload["exported_at"] = Time.get_datetime_string_from_system()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_show_toast("⚠  Could not export graph")
		return
	f.store_string(JSON.stringify(payload))
	f.close()
	_show_toast("💾  Graph exported")


func _import_graph_from_path(path: String) -> void:
	if not FileAccess.file_exists(path):
		_show_toast("⚠  Graph file not found")
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_show_toast("⚠  Could not read graph")
		return
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary) or (parsed as Dictionary).is_empty():
		_show_toast("⚠  Invalid graph file")
		return
	apply_save_state(parsed as Dictionary)
	_ensure_pbi_nodes()
	_autosave_pending = true
	_flush_graph_autosave()
	_sync_solar_ui_from_graph()
	_refresh_osm_solar_btn()
	_show_toast("📂  Graph imported onto this map")


func _on_add_soi_osm_solar_pressed() -> void:
	var main_node := _get_scene_main_node()
	var loader := _find_terrain_loader(main_node)
	if loader == null or not loader.has_method("add_all_soi_solar_arrays_to_graph"):
		_show_toast("⚠  No terrain solar data yet")
		return
	var n: int = int(loader.call("add_all_soi_solar_arrays_to_graph"))
	_refresh_osm_solar_btn()
	if n <= 0:
		_show_toast("No pending OSM solar arrays inside SoI")
	else:
		_show_toast("☀  Added %d OSM solar array(s)" % n)


func _refresh_osm_solar_btn() -> void:
	if _osm_solar_btn == null:
		return
	var main_node := _get_scene_main_node()
	var loader := _find_terrain_loader(main_node)
	var pending := 0
	var panels := 0
	if loader != null and loader.has_method("list_soi_solar_arrays_pending"):
		var list: Array = loader.call("list_soi_solar_arrays_pending") as Array
		pending = list.size()
		for e in list:
			panels += int((e as Dictionary).get("panel_count", 0))
	_osm_solar_btn.visible = pending > 0
	if pending > 0:
		_osm_solar_btn.text = "☀ Add OSM Solar (%d · %d pv)" % [pending, panels]


## Legacy hooks — game save/load live in SaveLoadUI; graph export/import above.
func _on_save_pressed() -> void:
	_open_graph_file_dialog(true)


func _on_load_pressed() -> void:
	_open_graph_file_dialog(false)


func _on_reset_graph() -> void:
	if model == null:
		return
	_history_suppress = true
	for item: Dictionary in model.items:
		var iid := str(item.get("id", ""))
		if _inspector_panel != null and _inspector_panel.has_method("unregister_item_automations"):
			_inspector_panel.call("unregister_item_automations", item)
		if bool(item.get("is_virtual", false)):
			_suppress_virtual(iid)
		model.remove_item(iid)
	for i in range(model.connections.size() - 1, -1, -1):
		model.connections.remove_at(i)
	_suppressed_virtuals = GraphVirtualIds.merge_suppression(_suppressed_virtuals)
	if _bridge != null:
		_bridge.suppressed_ids = _suppressed_virtuals
	_active_scope_id = "root"
	_scope_trail = ["root"]
	_selected_item_ids.clear()
	# Re-seed the fundamental PBI nodes so the pinned bar isn't left empty.
	_ensure_pbi_nodes()
	_history_suppress = false
	model.changed.emit("reset")
	_apply_scope_to_canvas()
	_show_toast("Graph reset")


func _on_show_hints() -> void:
	if _hints_panel == null:
		_hints_panel = _build_hints_panel()
		add_child(_hints_panel)   # added on top
	_hints_visible = not _hints_visible
	_hints_panel.visible = _hints_visible


func _on_group_selected_pressed() -> void:
	var load_ids := _get_load_group_candidates()
	if load_ids.size() >= 2:
		_group_load_items(load_ids)
		return
	_group_selected_items()


func _group_load_items(candidate_ids: Array[String]) -> void:
	if model == null or candidate_ids.size() < 2:
		_show_toast("Select 2+ loads to group")
		return
	var total_max := 0.0
	var total_avg := 0.0
	for sid: String in candidate_ids:
		var it := model.get_item(sid)
		if it.is_empty():
			continue
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		total_max += float(sp.get("max_watts", sp.get("watts", 0.0)))
		total_avg += float(sp.get("avg_watts", sp.get("watts", sp.get("max_watts", 0.0))))
	_selected_item_ids = candidate_ids.duplicate()
	_group_selected_items(false, "load_group", "Load Group (%d)" % candidate_ids.size(), {
		"max_watts": total_max,
		"avg_watts": total_avg,
		"summary":   "%.0f W combined · %d loads" % [total_avg, candidate_ids.size()],
	})


func _on_make_array_pressed() -> void:
	_make_special_compound("array", "Solar Array", [])


func _on_make_battery_bank_pressed() -> void:
	_make_special_compound("battery_bank", "Battery Bank", [])


func _make_special_compound(kind: String, title: String, _allowed_types: Array[String]) -> void:
	var selected := _get_group_candidates(true)
	if selected.size() < 2:
		_show_toast("Select 2+ nodes to %s" % title)
		return
	var extra_specs: Dictionary = {}
	for sid: String in selected:
		var it := model.get_item(sid)
		if kind == "array":
			if not _is_array_candidate(it):
				_show_toast("Selection must only include panel/array nodes")
				return
		elif kind == "battery_bank":
			if not _is_battery_candidate(it):
				_show_toast("Selection must only include battery/bank nodes")
				return
	if kind != "array" and not _ids_form_connected_component(selected):
		_show_toast("%s requires connected nodes" % title)
		return
	if kind == "array":
		extra_specs = _compute_array_equivalent_from_selection(selected)
	var new_compound_id := _group_selected_items(true, kind, title, extra_specs)
	if kind == "array" and not new_compound_id.is_empty():
		var comp := model.get_item(new_compound_id)
		if not comp.is_empty():
			var sp := (comp.get("specs", {}) as Dictionary).duplicate(true)
			sp["summary"] = "%s  •  %.0fW  %.1fV  %.1fA" % [
				str(sp.get("array_topology", "Array")),
				float(sp.get("array_equiv_wmp", 0.0)),
				float(sp.get("array_equiv_vmp", 0.0)),
				float(sp.get("array_equiv_imp", 0.0)),
			]
			model.update_item(new_compound_id, {"specs": sp})


func _get_load_group_candidates() -> Array[String]:
	var out: Array[String] = []
	if model == null:
		return out
	for sid: String in _selected_item_ids:
		var it := model.get_item(sid)
		if it.is_empty():
			continue
		if str(it.get("scope_id", "root")) != _active_scope_id:
			continue
		if bool(it.get("is_ghost", false)):
			continue
		if _is_load_group_candidate(it):
			out.append(sid)
	return out


func _is_load_group_candidate(item: Dictionary) -> bool:
	var ty := str(item.get("type", ""))
	if ty in ["appliance", "acload", "processor"]:
		return true
	if ty == "compound":
		var sp: Dictionary = item.get("specs", {}) as Dictionary
		return str(sp.get("compound_kind", "")) == "load_group"
	return false


func _get_group_candidates(allow_virtual: bool = false) -> Array[String]:
	var out: Array[String] = []
	if model == null:
		return out
	for sid: String in _selected_item_ids:
		var it := model.get_item(sid)
		if it.is_empty():
			continue
		if str(it.get("scope_id", "root")) != _active_scope_id:
			continue
		if not allow_virtual and bool(it.get("is_virtual", false)):
			continue
		out.append(sid)
	return out


func _ids_form_connected_component(ids: Array[String]) -> bool:
	if ids.size() <= 1 or model == null:
		return true
	var allowed: Dictionary = {}
	for sid: String in ids:
		allowed[sid] = true
	var adj: Dictionary = {}
	for sid: String in ids:
		adj[sid] = []
	for conn: Dictionary in model.get_connections_in_scope(_active_scope_id):
		var a := str(conn.get("source_item_id", ""))
		var b := str(conn.get("target_item_id", ""))
		if allowed.has(a) and allowed.has(b):
			(adj[a] as Array).append(b)
			(adj[b] as Array).append(a)
	var start: String = ids[0]
	var queue: Array[String] = [start]
	var seen: Dictionary = {start: true}
	while not queue.is_empty():
		var cur: String = queue.pop_front()
		for nxt_v in (adj.get(cur, []) as Array):
			var nxt := str(nxt_v)
			if seen.has(nxt):
				continue
			seen[nxt] = true
			queue.append(nxt)
	return seen.size() == ids.size()


func _on_combine_menu_id(id: int) -> void:
	match id:
		COMBINE_GROUP:       _on_group_selected_pressed()
		COMBINE_UNGROUP:     _on_ungroup_selected_pressed()
		COMBINE_EXPLODE:     _on_explode_selected_pressed()
		COMBINE_ARRAY:       _on_make_array_pressed()
		COMBINE_BANK:        _on_make_battery_bank_pressed()
		COMBINE_SERIES:      _on_series_wiring_pressed()
		COMBINE_PARALLEL:    _on_parallel_wiring_pressed()
		COMBINE_CTRL_PICKER: _on_pick_controller_for_array_pressed()


func _on_layout_menu_id(id: int) -> void:
	match id:
		LAYOUT_ARRANGE:     _on_arrange_graph_pressed()
		LAYOUT_PLACEHOLDER: _on_spawn_3d_placeholder_pressed()


## Enable/disable Combine ▾ / Layout ▾ items from the current selection.
func _update_special_group_buttons() -> void:
	var selected := _get_group_candidates(true)
	var can_array := selected.size() >= 2
	var can_bank := selected.size() >= 2 and _ids_form_connected_component(selected)
	# Generic super-node grouping is universal: any 2+ selected nodes in the
	# active scope can be grouped (load selections still auto-form a load_group).
	var can_group := selected.size() >= 2
	if can_array:
		for sid: String in selected:
			var it := model.get_item(sid)
			if not _is_array_candidate(it):
				can_array = false
				break
	if can_bank:
		for sid: String in selected:
			if not _is_battery_candidate(model.get_item(sid)):
				can_bank = false
				break
	var can_ungroup := false
	var can_explode := false
	var can_expand := false
	if _selected_item_ids.size() == 1 and model != null:
		var comp := model.get_item(_selected_item_ids[0])
		if not comp.is_empty() and str(comp.get("type", "")) == "compound":
			can_explode = true
			can_expand = not str(comp.get("child_scope_id", "")).is_empty()
			# Generic groups may ungroup; identity-backed components expand instead.
			can_ungroup = not _compound_has_persistent_identity(comp)
	var can_collapse := _scope_trail.size() > 1
	var can_wire := _count_panel_selection() >= 2
	var can_ctrl_pick := _selected_array_id_for_picker() != ""
	if _combine_menu != null:
		var popup := _combine_menu.get_popup()
		var states := {
			COMBINE_GROUP: can_group,
			COMBINE_UNGROUP: can_ungroup,
			COMBINE_EXPLODE: can_explode,
			COMBINE_ARRAY: can_array,
			COMBINE_BANK: can_bank,
			COMBINE_SERIES: can_wire,
			COMBINE_PARALLEL: can_wire,
			COMBINE_CTRL_PICKER: can_ctrl_pick,
		}
		for id: int in states:
			var idx := popup.get_item_index(id)
			if idx >= 0:
				popup.set_item_disabled(idx, not bool(states[id]))
	if _enter_btn != null:
		_enter_btn.disabled = not can_expand
	if _back_btn != null:
		_back_btn.disabled = not can_collapse
	if _layout_menu != null:
		var lp := _layout_menu.get_popup()
		for id2: int in [LAYOUT_ARRANGE, LAYOUT_PLACEHOLDER]:
			var idx2 := lp.get_item_index(id2)
			if idx2 >= 0:
				lp.set_item_disabled(idx2, false)


func _is_array_candidate(item: Dictionary) -> bool:
	var ty := str(item.get("type", ""))
	if ty == "panel":
		return true
	if ty == "compound":
		var sp: Dictionary = item.get("specs", {}) as Dictionary
		return str(sp.get("compound_kind", "")) == "array"
	return false


func _is_battery_candidate(item: Dictionary) -> bool:
	var ty := str(item.get("type", ""))
	if ty == "battery" or ty == "smartbattery":
		return true
	if ty == "compound":
		var sp: Dictionary = item.get("specs", {}) as Dictionary
		return str(sp.get("compound_kind", "")) == "battery_bank"
	return false


func _array_unit_equivalent(item: Dictionary) -> Dictionary:
	var ty := str(item.get("type", ""))
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	if ty == "panel":
		var wmp := float(sp.get("wmp", 220.0))
		var vmp := float(sp.get("vmp", 30.0))
		var voc := float(sp.get("voc", 37.5))
		var imp := float(sp.get("imp", wmp / maxf(vmp, 0.001)))
		var isc := float(sp.get("isc", imp))
		return {"valid": true, "series": 1, "parallel": 1, "panel_units": 1, "wmp": wmp, "vmp": vmp, "voc": voc, "imp": imp, "isc": isc}
	if ty == "compound" and str(sp.get("compound_kind", "")) == "array":
		return {
			"valid": true,
			"series": int(sp.get("array_series", 1)),
			"parallel": int(sp.get("array_parallel", 1)),
			"panel_units": int(sp.get("array_panel_units", sp.get("child_count", 0))),
			"wmp": float(sp.get("array_equiv_wmp", 0.0)),
			"vmp": float(sp.get("array_equiv_vmp", 0.0)),
			"voc": float(sp.get("array_equiv_voc", 0.0)),
			"imp": float(sp.get("array_equiv_imp", 0.0)),
			"isc": float(sp.get("array_equiv_isc", 0.0)),
		}
	return {"valid": false}


func _selection_components(ids: Array[String]) -> Array[Array]:
	var out: Array[Array] = []
	if model == null or ids.is_empty():
		return out
	var allowed: Dictionary = {}
	var adj: Dictionary = {}
	for sid: String in ids:
		allowed[sid] = true
		adj[sid] = []
	for conn: Dictionary in model.get_connections_in_scope(_active_scope_id):
		var a := str(conn.get("source_item_id", ""))
		var b := str(conn.get("target_item_id", ""))
		if allowed.has(a) and allowed.has(b):
			(adj[a] as Array).append(b)
			(adj[b] as Array).append(a)
	var seen: Dictionary = {}
	for sid: String in ids:
		if seen.has(sid):
			continue
		var comp: Array = []
		var q: Array[String] = [sid]
		seen[sid] = true
		while not q.is_empty():
			var cur: String = q.pop_front()
			comp.append(cur)
			for nv in (adj.get(cur, []) as Array):
				var nxt := str(nv)
				if seen.has(nxt):
					continue
				seen[nxt] = true
				q.append(nxt)
		out.append(comp)
	return out


func _compute_array_equivalent_from_selection(ids: Array[String]) -> Dictionary:
	var comps := _selection_components(ids)
	if comps.is_empty():
		comps = [ids]
	var branch_series: Array = []
	var total_parallel := 0
	var total_wmp := 0.0
	var total_imp := 0.0
	var total_isc := 0.0
	var branch_voc_max := 0.0
	var mixed_voltage := false
	var panel_units := 0
	var first_series_vmp := -1.0
	var first_series_voc := -1.0
	var uniform_series := true
	for comp in comps:
		var comp_series := 0
		var comp_parallel := 1
		var comp_vmp := 0.0
		var comp_voc := 0.0
		var comp_imp := 1e20
		var comp_isc := 1e20
		var comp_has_unit := false
		var comp_panel_units := 0
		for sid_v in comp:
			var sid := str(sid_v)
			var it := model.get_item(sid)
			var u := _array_unit_equivalent(it)
			if not bool(u.get("valid", false)):
				continue
			comp_has_unit = true
			comp_series += int(u.get("series", 1))
			comp_parallel = mini(comp_parallel, maxi(1, int(u.get("parallel", 1))))
			comp_vmp += float(u.get("vmp", 0.0))
			comp_voc += float(u.get("voc", 0.0))
			comp_imp = minf(comp_imp, float(u.get("imp", 0.0)))
			comp_isc = minf(comp_isc, float(u.get("isc", 0.0)))
			comp_panel_units += int(u.get("panel_units", 0))
		if not comp_has_unit:
			continue
		panel_units += comp_panel_units
		if comp_imp == 1e20:
			comp_imp = 0.0
		if comp_isc == 1e20:
			comp_isc = 0.0
		var comp_series_i := maxi(1, comp_series)
		branch_series.append(comp_series_i)
		total_parallel += maxi(1, comp_parallel)
		var comp_wmp := comp_vmp * comp_imp
		total_wmp += comp_wmp
		total_imp += comp_imp
		total_isc += comp_isc
		branch_voc_max = maxf(branch_voc_max, comp_voc)
		if first_series_vmp < 0.0:
			first_series_vmp = comp_vmp
			first_series_voc = comp_voc
		elif absf(comp_vmp - first_series_vmp) > 0.25 or absf(comp_voc - first_series_voc) > 0.25:
			mixed_voltage = true
		if int(comp_series_i) != int(branch_series[0]):
			uniform_series = false
	var s_ref: int = int(branch_series[0]) if not branch_series.is_empty() else 1
	var topo := ("%dS x %dP" % [s_ref, maxi(total_parallel, 1)]) if uniform_series else ("Mixed Series x %dP" % maxi(total_parallel, 1))
	var equiv_vmp := 0.0
	if total_imp > 0.0:
		equiv_vmp = total_wmp / total_imp
	elif first_series_vmp > 0.0:
		equiv_vmp = first_series_vmp
	var equiv_voc := branch_voc_max if branch_voc_max > 0.0 else maxf(first_series_voc, 0.0)
	return {
		"array_topology": topo,
		"array_series": int(s_ref),
		"array_parallel": maxi(total_parallel, 1),
		"array_branches": comps.size(),
		"array_mixed_voltage": mixed_voltage,
		"array_panel_units": panel_units,
		"array_equiv_wmp": total_wmp,
		"array_equiv_vmp": equiv_vmp,
		"array_equiv_voc": equiv_voc,
		"array_equiv_imp": total_imp,
		"array_equiv_isc": total_isc,
	}


## True when dissolving this compound would lose SketchUp-style / StarShade
## identity (definition, 3D twin, banner). Those nodes use Expand/Collapse
## instead of Ungroup; Explode is the explicit destructive path.
func _compound_has_persistent_identity(item: Dictionary) -> bool:
	if item.is_empty() or str(item.get("type", "")) != "compound":
		return false
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if not str(specs.get("definition_id", "")).is_empty():
		return true
	if not str(specs.get("bound_prop_id", "")).is_empty():
		return true
	if not str(specs.get("starshade_tag", "")).is_empty():
		return true
	if bool(specs.get("node_banner", false)) and not str(specs.get("model_id", "")).is_empty():
		return true
	return false


func _compound_identity_label(item: Dictionary) -> String:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var name := str(specs.get("name", "")).strip_edges()
	if not name.is_empty():
		return name
	var def_id := str(specs.get("definition_id", ""))
	if not def_id.is_empty():
		return def_id
	return "super-node"


## Ungroup / Ctrl+Shift+G: generic groups dissolve; identity-backed compounds
## (StarShade, library components, 3D-bound shells) Expand instead so context
## and world position survive. Use Combine ▾ → Explode for the destructive path.
func _on_ungroup_selected_pressed(item_id: String = "") -> void:
	if not item_id.is_empty():
		_selected_item_ids.clear()
		_selected_item_ids.append(item_id)
		if _graph_canvas != null:
			_graph_canvas.set("selected_item_ids", _selected_item_ids)
			_graph_canvas.set("selected_item_id", item_id)
	if _selected_item_ids.size() != 1 or model == null:
		_show_toast("Select one compound to ungroup")
		return
	var comp := model.get_item(_selected_item_ids[0])
	if comp.is_empty() or str(comp.get("type", "")) != "compound":
		_show_toast("Select a compound node")
		return
	if _compound_has_persistent_identity(comp):
		var label := _compound_identity_label(comp)
		_enter_compound_animated(str(comp.get("id", "")))
		_show_toast("Expanded %s — Collapse (Esc / ◂ Collapse) keeps identity + 3D binding" % label)
		return
	_ungroup_selected_compound()


func _on_explode_selected_pressed(item_id: String = "") -> void:
	if not item_id.is_empty():
		_selected_item_ids.clear()
		_selected_item_ids.append(item_id)
		if _graph_canvas != null:
			_graph_canvas.set("selected_item_ids", _selected_item_ids)
			_graph_canvas.set("selected_item_id", item_id)
	if _selected_item_ids.size() != 1 or model == null:
		_show_toast("Select one compound to explode")
		return
	var comp := model.get_item(_selected_item_ids[0])
	if comp.is_empty() or str(comp.get("type", "")) != "compound":
		_show_toast("Select a compound node")
		return
	_explode_pending_id = str(comp.get("id", ""))
	if _explode_confirm == null:
		_explode_confirm = ConfirmationDialog.new()
		_explode_confirm.title = "Explode compound"
		_explode_confirm.ok_button_text = "Explode"
		_explode_confirm.confirmed.connect(func() -> void:
			if _explode_pending_id.is_empty():
				return
			_selected_item_ids.clear()
			_selected_item_ids.append(_explode_pending_id)
			if _graph_canvas != null:
				_graph_canvas.set("selected_item_ids", _selected_item_ids)
				_graph_canvas.set("selected_item_id", _explode_pending_id)
			_explode_pending_id = ""
			_ungroup_selected_compound()
		)
		add_child(_explode_confirm)
	var label := _compound_identity_label(comp)
	var identity := _compound_has_persistent_identity(comp)
	if identity:
		_explode_confirm.dialog_text = (
			"Explode \"%s\"?\n\n"
			+ "This dissolves the super-node shell. Children stay, but StarShade / "
			+ "component identity, banner, and 3D world binding on the shell are lost.\n\n"
			+ "Prefer Expand / Collapse to peek inside without breaking the link.") % label
	else:
		_explode_confirm.dialog_text = (
			"Explode \"%s\"?\n\nChildren move into the current scope and the shell is removed.") % label
	_explode_confirm.popup_centered()


func _on_enter_selected_compound() -> void:
	if _selected_item_ids.size() != 1:
		_show_toast("Select one super-node to expand")
		return
	_enter_compound_animated(_selected_item_ids[0])


func _on_back_scope_pressed() -> void:
	_collapse_active_scope(true)


## Zoom-out / Collapse / Esc — pop one scope and re-select the owner super-node
## so StarShade (etc.) stays the selected identity with its 3D binding intact.
func _collapse_active_scope(animated: bool = true) -> void:
	if _scope_trail.size() <= 1:
		return
	var leaving := _active_scope_id
	var owner := ""
	if model != null:
		owner = str(model.get_scope(leaving).get("owner_compound_id", ""))
	if animated and _graph_canvas != null and _graph_canvas.has_method("begin_pop_transition"):
		_graph_canvas.call("begin_pop_transition")
	_scope_trail.pop_back()
	_active_scope_id = _scope_trail[_scope_trail.size() - 1]
	_selected_item_ids.clear()
	if not owner.is_empty():
		_selected_item_ids.append(owner)
	_update_special_group_buttons()
	_apply_scope_to_canvas()
	if animated and _graph_canvas != null and not owner.is_empty() \
			and _graph_canvas.has_method("finish_pop_transition"):
		_graph_canvas.call("finish_pop_transition", owner)
	elif _graph_canvas != null and not owner.is_empty() and _graph_canvas.has_method("focus_on_item"):
		_graph_canvas.call("focus_on_item", owner)
	if not owner.is_empty():
		if _graph_canvas != null:
			_graph_canvas.set("selected_item_ids", _selected_item_ids)
			_graph_canvas.set("selected_item_id", owner)
		_on_canvas_item_selected(owner)


func _update_scope_breadcrumb() -> void:
	if _scope_breadcrumb == null:
		return
	for c in _scope_breadcrumb.get_children():
		c.queue_free()
	for i in _scope_trail.size():
		var sid: String = _scope_trail[i]
		var title := "Root"
		if sid != "root" and model != null and model.has_method("get_scope"):
			title = str(model.get_scope(sid).get("title", sid))
		if i > 0:
			var sep := Label.new()
			sep.text = " › "
			sep.add_theme_color_override("font_color", C_TEXT_M)
			sep.add_theme_font_size_override("font_size", 13)
			sep.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			_scope_breadcrumb.add_child(sep)
		var is_last := i == _scope_trail.size() - 1
		var seg := Button.new()
		seg.text = title
		seg.flat = true
		seg.focus_mode = Control.FOCUS_NONE
		seg.add_theme_font_size_override("font_size", 13)
		seg.add_theme_color_override("font_color", C_TEXT if is_last else C_TEXT_S)
		seg.disabled = is_last
		var idx := i
		seg.pressed.connect(func(): _jump_to_scope_index(idx))
		_scope_breadcrumb.add_child(seg)


## Breadcrumb click — jump straight to an ancestor scope in the trail.
func _jump_to_scope_index(index: int) -> void:
	if index < 0 or index >= _scope_trail.size():
		return
	if index == _scope_trail.size() - 1:
		return
	_scope_trail.resize(index + 1)
	_active_scope_id = _scope_trail[index]
	_selected_item_ids.clear()
	_update_special_group_buttons()
	_apply_scope_to_canvas()
	if _graph_canvas != null and _graph_canvas.has_method("fit_scope_to_view"):
		_graph_canvas.call("fit_scope_to_view")


func _apply_scope_to_canvas() -> void:
	if _graph_canvas != null:
		_graph_canvas.set("active_scope_id", _active_scope_id)
		_graph_canvas.call("queue_redraw")
	_update_scope_breadcrumb()


func _enter_compound(item_id: String) -> void:
	if model == null:
		return
	var item := model.get_item(item_id)
	if item.is_empty() or str(item.get("type", "")) != "compound":
		return
	var child_scope_id: String = item.get("child_scope_id", "") as String
	if child_scope_id.is_empty():
		return
	_active_scope_id = child_scope_id
	_scope_trail.append(child_scope_id)
	_selected_item_ids.clear()
	_apply_scope_to_canvas()


func _compound_handle_for_boundary(conn: Dictionary, selected_ids: Dictionary, counters: Dictionary) -> Dictionary:
	var src_sel: bool = selected_ids.has(conn.get("source_item_id", "") as String)
	var polarity: String = conn.get("polarity", "ac") as String
	var direction: String = "in"
	if src_sel:
		direction = "out"
	var key := "%s_%s" % [direction, polarity]
	var idx: int = int(counters.get(key, 0)) + 1
	counters[key] = idx
	var hid := "%s_%s_%d" % [direction, polarity, idx]
	return {
		"id": hid,
		"polarity": polarity,
		"direction": direction,
		"index": idx,
	}


## Evenly redistribute a compound's promoted handles: inputs across the TOP edge,
## outputs across the BOTTOM edge (top-to-bottom flow, matching base-graph nodes;
## array compounds keep their bottom-bus layout).
## Called after all boundary ports are known so spacing is uniform.
func _distribute_compound_handle_positions(handle_defs: Array) -> void:
	var ins: Array = []
	var outs: Array = []
	for h_v in handle_defs:
		var h := h_v as Dictionary
		if str(h.get("direction", "in")) == "out":
			outs.append(h)
		else:
			ins.append(h)
	for arr_v in [ins, outs]:
		var arr := arr_v as Array
		var n := arr.size()
		for i in n:
			var h := arr[i] as Dictionary
			var is_out := str(h.get("direction", "in")) == "out"
			h["ry"] = 1.0 if is_out else 0.0
			h["rx"] = clampf(float(i + 1) / float(n + 1), 0.08, 0.92)


func _compound_handle_pos(direction: String, idx: int, side_count: int, compound_kind: String = "") -> Vector2:
	var n := maxi(1, side_count)
	var t := float(idx) / float(n + 1)
	# Top-to-bottom flow: inputs on the TOP edge, outputs on the BOTTOM edge.
	# Array compounds keep bottom-facing ports (condensed panel cluster).
	if compound_kind == "array":
		return Vector2(t, 1.0)
	if direction == "in":
		return Vector2(t, 0.0)
	return Vector2(t, 1.0)


func _group_selected_items(allow_virtual: bool = false, compound_kind: String = "", group_title: String = "Group", extra_specs: Dictionary = {}) -> String:
	if model == null:
		return ""
	var candidates := _get_group_candidates(allow_virtual)
	var selected_ids_set: Dictionary = {}
	for sid: String in candidates:
		selected_ids_set[sid] = true
	if candidates.size() < 2:
		_show_toast("Select 2+ nodes to group")
		return ""
	var min_x := 1e20
	var min_y := 1e20
	var max_x := -1e20
	var max_y := -1e20
	for sid: String in candidates:
		var it := model.get_item(sid)
		var x := float(it.get("x", 0.0))
		var y := float(it.get("y", 0.0))
		var w := float(it.get("width", 120.0))
		var h := float(it.get("height", 90.0))
		min_x = minf(min_x, x)
		min_y = minf(min_y, y)
		max_x = maxf(max_x, x + w)
		max_y = maxf(max_y, y + h)
	var center_x := (min_x + max_x) * 0.5 - 90.0
	var center_y := (min_y + max_y) * 0.5 - 60.0
	var comp_w := 180.0
	var comp_h := 120.0
	if compound_kind == "load_group":
		comp_w = 168.0
		comp_h = 104.0
		center_x = (min_x + max_x) * 0.5 - comp_w * 0.5
		center_y = (min_y + max_y) * 0.5 - comp_h * 0.5
	elif compound_kind == "array":
		var layout_specs: Dictionary = extra_specs.duplicate(true)
		if not layout_specs.has("array_panel_units"):
			layout_specs["array_panel_units"] = candidates.size()
		var arr_sz := GraphArrayLayout.compound_size(layout_specs)
		comp_w = arr_sz.x
		comp_h = arr_sz.y
		center_x = (min_x + max_x) * 0.5 - comp_w * 0.5
		center_y = (min_y + max_y) * 0.5 - comp_h * 0.5
	elif compound_kind == "battery_bank":
		# Same tall cell as a leaf battery — collapsed bank draws as one SOC fill.
		comp_w = 128.0
		comp_h = 172.0
		center_x = (min_x + max_x) * 0.5 - comp_w * 0.5
		center_y = (min_y + max_y) * 0.5 - comp_h * 0.5
	var group_specs: Dictionary = {
		"name": group_title,
		"summary": "Nested graph",
		"child_count": candidates.size(),
		"port_in_count": 0,
		"port_out_count": 0,
		"exposed_ports": [],
		"compound_kind": compound_kind,
	}
	if compound_kind == "battery_bank":
		group_specs["display_as_battery"] = true
		var bank_kwh := 0.0
		for sid_b: String in candidates:
			var bit := model.get_item(sid_b)
			var bsp: Dictionary = bit.get("specs", {}) as Dictionary
			bank_kwh += float(bsp.get("kwh", 0.0))
		group_specs["bank_total_kwh"] = bank_kwh
		group_specs["kwh"] = bank_kwh
	for k: Variant in extra_specs.keys():
		group_specs[k] = extra_specs[k]
	var comp_item: Dictionary = {
		"type": "compound",
		"x": center_x,
		"y": center_y,
		"width": comp_w,
		"height": comp_h,
		"scope_id": _active_scope_id,
		"specs": group_specs,
		"handles": [],
		"is_virtual": false,
	}
	_history_suppress = true
	model.add_item(comp_item)
	var compound_id: String = ""
	if model.items.size() > 0:
		compound_id = model.items[model.items.size() - 1].get("id", "") as String
	var child_scope_id := "scope_%s" % compound_id
	model.ensure_scope(child_scope_id, _active_scope_id, compound_id, group_title)
	model.update_item(compound_id, {"child_scope_id": child_scope_id})

	for sid: String in candidates:
		var it := model.get_item(sid)
		if it.is_empty():
			continue
		model.update_item(sid, {"scope_id": child_scope_id, "parent_compound_id": compound_id})

	var exposed_ports: Array = []
	var handle_defs: Array = []
	var handle_counters: Dictionary = {}
	var conns := model.get_connections_in_scope(_active_scope_id)
	# duplicate because we'll remove and add while iterating
	var conns_copy: Array = conns.duplicate()
	var side_in_count: int = 0
	var side_out_count: int = 0
	for conn: Dictionary in conns_copy:
		var sid: String = conn.get("source_item_id", "") as String
		var tid: String = conn.get("target_item_id", "") as String
		var src_sel: bool = selected_ids_set.has(sid)
		var tgt_sel: bool = selected_ids_set.has(tid)
		if src_sel and tgt_sel:
			model.update_connection(conn.get("id", "") as String, {"scope_id": child_scope_id})
			continue
		if src_sel == tgt_sel:
			continue
		var hd: Dictionary
		if compound_kind == "array":
			var pol := str(conn.get("polarity", "positive"))
			var hid := GraphArrayLayout.consolidated_handle_id(pol)
			hd = {"id": hid, "polarity": pol, "direction": "out" if src_sel else "in", "index": 1}
		else:
			hd = _compound_handle_for_boundary(conn, selected_ids_set, handle_counters)
		var direction: String = hd.get("direction", "in") as String
		var idx: int = int(hd.get("index", 1))
		if direction == "in":
			side_in_count = maxi(side_in_count, idx)
		else:
			side_out_count = maxi(side_out_count, idx)
		var pos := _compound_handle_pos(direction, idx, maxi(side_in_count, side_out_count), compound_kind)
		if compound_kind != "array":
			handle_defs.append({
				"id": hd.get("id", "") as String,
				"polarity": hd.get("polarity", "ac") as String,
				"direction": direction,
				"rx": pos.x,
				"ry": pos.y,
			})
		# Live promoted port: maps this compound handle to the interior node it
		# fronts. flat_connections() tunnels through this so sim stays correct.
		exposed_ports.append({
			"handle_id": hd.get("id", "") as String,
			"child_item_id": sid if src_sel else tid,
			"child_handle_id": conn.get("source_handle_id", "") if src_sel else conn.get("target_handle_id", ""),
			"polarity": conn.get("polarity", "ac"),
			"kind": conn.get("resource_type", ""),
			"label": "",
			"direction": direction,
		})
		model.remove_connection(conn.get("id", "") as String)
		var nconn := conn.duplicate(true)
		nconn["scope_id"] = _active_scope_id
		if src_sel:
			nconn["source_item_id"] = compound_id
			nconn["source_handle_id"] = hd.get("id", "") as String
		else:
			nconn["target_item_id"] = compound_id
			nconn["target_handle_id"] = hd.get("id", "") as String
		model.add_connection(nconn)

	if compound_kind == "array":
		handle_defs.clear()
		for h: Dictionary in GraphArrayLayout.default_handles():
			handle_defs.append(h.duplicate(true))
		side_in_count = 0
		side_out_count = 2
	else:
		_distribute_compound_handle_positions(handle_defs)

	var comp := model.get_item(compound_id)
	if not comp.is_empty():
		var specs: Dictionary = (comp.get("specs", {}) as Dictionary).duplicate(true)
		specs["child_count"] = candidates.size()
		specs["exposed_ports"] = exposed_ports
		specs["port_in_count"] = side_in_count
		specs["port_out_count"] = side_out_count
		if compound_kind == "array":
			specs["port_in_count"] = 0
			specs["port_out_count"] = 2
		for k in extra_specs.keys():
			specs[k] = extra_specs[k]
		if compound_kind == "load_group":
			var has_ac_in := false
			for hd: Dictionary in handle_defs:
				if str(hd.get("polarity", "")) in ["ac", "load"]:
					has_ac_in = true
					break
			if not has_ac_in:
				handle_defs.append({"id": "input", "polarity": "load", "direction": "in", "rx": 0.5, "ry": 0.0})
				side_in_count = maxi(side_in_count, 1)
			specs["summary"] = str(specs.get("summary", "%d loads" % candidates.size()))
		model.update_item(compound_id, {
			"handles": handle_defs,
			"specs": specs,
		})
	_history_suppress = false
	model.changed.emit("reset")
	_selected_item_ids.clear()
	_selected_item_ids.append(compound_id)
	if _graph_canvas != null:
		_graph_canvas.set("selected_item_ids", _selected_item_ids)
		_graph_canvas.set("selected_item_id", compound_id)
		_graph_canvas.call("queue_redraw")
	_on_canvas_item_selected(compound_id)
	_update_special_group_buttons()
	if compound_kind == "array":
		_show_toast("Solar array: %d panels tiled · single +/- bus" % candidates.size())
	else:
		_show_toast("Grouped %d nodes" % candidates.size())
	return compound_id


func _sync_array_compound_layouts() -> void:
	if model == null:
		return
	for item: Dictionary in model.items:
		if str(item.get("type", "")) != "compound":
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(specs.get("compound_kind", "")) != "array":
			continue
		var item_id := str(item.get("id", ""))
		if item_id.is_empty():
			continue
		var want_sz := GraphArrayLayout.compound_size(specs)
		var updates: Dictionary = {}
		if absf(float(item.get("width", 0.0)) - want_sz.x) > 1.0 \
				or absf(float(item.get("height", 0.0)) - want_sz.y) > 1.0:
			updates["width"] = want_sz.x
			updates["height"] = want_sz.y
		var handles: Array = item.get("handles", []) as Array
		var needs_handles := handles.is_empty()
		if not needs_handles:
			for h: Dictionary in handles:
				var hid := str(h.get("id", ""))
				if hid != "positive" and hid != "negative":
					needs_handles = true
					break
		if needs_handles:
			updates["handles"] = GraphArrayLayout.default_handles()
		if updates.is_empty():
			continue
		model.update_item(item_id, updates)


## Battery-bank supernodes draw as one tall SOC cell. Legacy StarShade banks
## were 190×120 (wider than tall); snap those (and any other wide bank) to the
## leaf-battery size and stamp `display_as_battery` so the V2 chrome kicks in.
func _normalize_battery_bank_display_nodes() -> void:
	if model == null:
		return
	for item: Dictionary in model.items:
		if str(item.get("type", "")) != "compound":
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		var is_bank := bool(specs.get("display_as_battery", false)) \
			or str(specs.get("compound_kind", "")) == "battery_bank" \
			or str(specs.get("definition_id", "")).to_lower().contains("battery_bank")
		if not is_bank:
			continue
		var iid := str(item.get("id", ""))
		if iid.is_empty():
			continue
		var w := float(item.get("width", 0.0))
		var h := float(item.get("height", 0.0))
		var updates: Dictionary = {}
		if w > h + 1.0:
			updates["width"] = 128.0
			updates["height"] = 172.0
		if not bool(specs.get("display_as_battery", false)):
			var sp := specs.duplicate(true)
			sp["display_as_battery"] = true
			updates["specs"] = sp
		if updates.is_empty():
			continue
		model.update_item(iid, updates)


func _ungroup_selected_compound() -> void:
	if model == null:
		return
	if _selected_item_ids.size() != 1:
		_show_toast("Select one compound to ungroup")
		return
	var compound_id: String = _selected_item_ids[0]
	var comp := model.get_item(compound_id)
	if comp.is_empty() or str(comp.get("type", "")) != "compound":
		_show_toast("Select a compound node")
		return
	if str(comp.get("scope_id", "root")) != _active_scope_id:
		return
	var child_scope_id: String = comp.get("child_scope_id", "") as String
	if child_scope_id.is_empty():
		return
	var specs: Dictionary = comp.get("specs", {}) as Dictionary
	# exposed_ports is the LIVE promoted-port map; boundary_links is only present
	# on unmigrated legacy saves (migrate_boundary_links normally converts it).
	var exposed_ports: Array = specs.get("exposed_ports", []) as Array
	if exposed_ports.is_empty() and specs.has("boundary_links"):
		var legacy := specs.duplicate(true)
		GraphNesting.migrate_boundary_links(legacy)
		exposed_ports = legacy.get("exposed_ports", []) as Array
	# Snapshot the interior BEFORE moving anything (remove_item cascade-deletes a
	# child scope, so we relocate children out first, then delete only the shell).
	_history_suppress = true
	# Restore each promoted port's boundary wire as a direct child↔external edge.
	# The external endpoint is read from whatever is CURRENTLY wired to the
	# compound handle, so ports rewired live after grouping still ungroup right.
	for ep_v: Variant in exposed_ports:
		var ep := ep_v as Dictionary
		var ch: String = str(ep.get("handle_id", ""))
		var child_item: String = str(ep.get("child_item_id", ""))
		var child_handle: String = str(ep.get("child_handle_id", ""))
		var src_is_child: bool = str(ep.get("direction", "in")) == "out"
		var to_remove: Array[String] = []
		var restores: Array = []
		for conn: Dictionary in model.get_connections_in_scope(_active_scope_id):
			var ext_item := ""
			var ext_handle := ""
			if conn.get("source_item_id", "") == compound_id and conn.get("source_handle_id", "") == ch:
				ext_item = str(conn.get("target_item_id", ""))
				ext_handle = str(conn.get("target_handle_id", ""))
			elif conn.get("target_item_id", "") == compound_id and conn.get("target_handle_id", "") == ch:
				ext_item = str(conn.get("source_item_id", ""))
				ext_handle = str(conn.get("source_handle_id", ""))
			else:
				continue
			to_remove.append(str(conn.get("id", "")))
			restores.append({
				"polarity": conn.get("polarity", ep.get("polarity", "ac")),
				"resource_type": conn.get("resource_type", ep.get("kind", "")),
				"ext_item": ext_item, "ext_handle": ext_handle,
			})
		for cid: String in to_remove:
			model.remove_connection(cid)
		for r_v: Variant in restores:
			var r := r_v as Dictionary
			model.add_connection({
				"scope_id": _active_scope_id,
				"polarity": r.get("polarity", "ac"),
				"resource_type": r.get("resource_type", ""),
				"source_item_id": child_item if src_is_child else r.get("ext_item", ""),
				"source_handle_id": child_handle if src_is_child else r.get("ext_handle", ""),
				"target_item_id": r.get("ext_item", "") if src_is_child else child_item,
				"target_handle_id": r.get("ext_handle", "") if src_is_child else child_handle,
				"waypoints": [],
				"line_style": "bezier",
				"curve_tension": 1.0,
				"corner_radius": 28.0,
				"voltage_mismatch": false,
			})
	# Move children and internal connections back to the current scope.
	for item: Dictionary in model.get_items_in_scope(child_scope_id):
		model.update_item(item.get("id", "") as String, {
			"scope_id": _active_scope_id,
			"parent_compound_id": "",
		})
	for conn: Dictionary in model.get_connections_in_scope(child_scope_id):
		model.update_connection(conn.get("id", "") as String, {"scope_id": _active_scope_id})
	# Child scope is now empty — remove_item's cascade has nothing to orphan.
	model.remove_item(compound_id)
	model.remove_scope(child_scope_id)
	_history_suppress = false
	model.changed.emit("reset")
	_selected_item_ids.clear()
	if _graph_canvas != null:
		_graph_canvas.set("selected_item_ids", [])
		_graph_canvas.set("selected_item_id", "")
		_graph_canvas.call("queue_redraw")
	_update_special_group_buttons()
	_show_toast("Exploded compound — shell removed")

func _on_challenge_pressed() -> void:
	var main_node := get_tree().root.get_node_or_null("Main")
	if main_node != null and main_node.has_method("open_challenge_picker"):
		main_node.call("open_challenge_picker")


func _on_system_review() -> void:
	# Toggle: close if already open
	if _review_modal != null and is_instance_valid(_review_modal):
		_review_modal.queue_free()
		_review_modal = null
		return
	_review_modal = _build_review_modal()
	add_child(_review_modal)


# ---------------------------------------------------------------------------
# System Review modal  (Phase 13)
# ---------------------------------------------------------------------------

func _build_review_modal() -> Control:
	# ── Overlay ──────────────────────────────────────────────────────────────
	var overlay := Control.new()
	overlay.name         = "ReviewModal"
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_anchor_full(overlay)

	var dim := ColorRect.new()
	dim.color        = Color(0.0, 0.0, 0.0, 0.6)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor_full(dim)
	overlay.add_child(dim)

	# ── Center container ──────────────────────────────────────────────────────
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor_full(center)
	overlay.add_child(center)

	# ── Panel ─────────────────────────────────────────────────────────────────
	var panel_sb := StyleBoxFlat.new()
	panel_sb.bg_color            = C_SIDEBAR
	panel_sb.border_color        = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.55)
	panel_sb.set_border_width_all(1)
	panel_sb.set_corner_radius_all(10)
	panel_sb.content_margin_left   = 0.0
	panel_sb.content_margin_right  = 0.0
	panel_sb.content_margin_top    = 0.0
	panel_sb.content_margin_bottom = 0.0

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(620.0, 0.0)
	panel.mouse_filter        = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", panel_sb)
	center.add_child(panel)

	var outer_vbox := VBoxContainer.new()
	outer_vbox.add_theme_constant_override("separation", 0)
	panel.add_child(outer_vbox)

	# ── Title bar ─────────────────────────────────────────────────────────────
	var title_bar := _rv_title_bar(overlay)
	outer_vbox.add_child(title_bar)

	# ── Gather data ───────────────────────────────────────────────────────────
	var solar_kw:  float = 0.0
	var load_kw:   float = 0.0
	var bat_soc:   float = 0.0
	var net_kw:    float = 0.0
	var day_solar: float = 0.0
	var day_load:  float = 0.0
	var powered:   bool  = true
	var has_live:  bool  = is_instance_valid(_solar_ui)
	if has_live:
		solar_kw  = float(_solar_ui.get("current_solar_kw") if _solar_ui.get("current_solar_kw") != null else 0.0)
		load_kw   = float(_solar_ui.get("current_load_kw")  if _solar_ui.get("current_load_kw")  != null else 0.0)
		var bk: float = float(_solar_ui.get("battery_kwh_stored")   if _solar_ui.get("battery_kwh_stored")   != null else 0.0)
		var bc: float = float(_solar_ui.get("BATTERY_CAPACITY_KWH") if _solar_ui.get("BATTERY_CAPACITY_KWH") != null else 16.0)
		bat_soc   = bk / bc * 100.0 if bc > 0.0 else 0.0
		net_kw    = solar_kw - load_kw
		day_solar = float(_solar_ui.get("daily_solar_generated_kwh") if _solar_ui.get("daily_solar_generated_kwh") != null else 0.0)
		day_load  = float(_solar_ui.get("daily_load_consumed_kwh")   if _solar_ui.get("daily_load_consumed_kwh")   != null else 0.0)
		powered   = _solar_ui.is_power_available() if _solar_ui.has_method("is_power_available") else true

	# Design totals from model (root scope only; skip virtual internals)
	var agg := _collect_root_array_aggregate()
	var panel_wmp:      float = float(agg.get("panel_wmp", 0.0))
	var panel_count:    int   = int(agg.get("panel_count", 0))
	var bat_kwh_total:  float = 0.0
	var bat_v_set:      float = 48.0
	var ctrl_max_watts: float = 0.0
	var total_cost:     float = 0.0
	var user_items:     int   = 0
	if model != null:
		for item: Dictionary in GraphNesting.walk_items(model, "root"):
			if bool(item.get("is_virtual", false)):
				continue
			var sp := item.get("specs", {}) as Dictionary
			# Crated gear contributes no CAPACITY (same rule as the panel
			# aggregate + GraphDcElectrical.is_packed) but its cost still
			# counts — you own it either way.
			if not bool(sp.get("packed_3d", false)):
				match item.get("type", ""):
					"battery":
						bat_kwh_total += float(sp.get("kwh", 0.0))
						bat_v_set      = float(sp.get("voltage", 48.0))
					"controller":
						ctrl_max_watts += float(sp.get("max_pv_watts", 0.0))
			total_cost += float(sp.get("cost", 0.0))
			if not bool(item.get("is_virtual", false)):
				user_items += 1

	# ── Sections ──────────────────────────────────────────────────────────────
	if has_live:
		outer_vbox.add_child(_rv_section("⚡  LIVE SYSTEM STATUS", [
			["Solar Output",    "%.0f W"  % (solar_kw * 1000.0),    Color(0.27, 0.9, 0.42) if solar_kw > 0.05 else C_TEXT_S],
			["Load Demand",     "%.0f W"  % (load_kw  * 1000.0),    C_TEXT_S],
			["Battery SOC",     "%.0f %%"  % bat_soc,
				Color(0.27, 0.9, 0.42) if bat_soc > 60.0 else C_AMBER if bat_soc > 25.0 else Color(0.9, 0.35, 0.3)],
			["Net Power Flow",  "%+.0f W" % (net_kw   * 1000.0),
				Color(0.27, 0.9, 0.42) if net_kw > 0.05 else C_AMBER if net_kw < -0.05 else C_TEXT_S],
			["Power State",     "✔ Available" if powered else "✘ Depleted",
				Color(0.27, 0.9, 0.42) if powered else Color(0.9, 0.35, 0.3)],
		]))
		var day_balance := day_solar - day_load
		outer_vbox.add_child(_rv_section("📅  TODAY'S ENERGY", [
			["Solar Generated",  "%.3f kWh" % day_solar,
				Color(0.27, 0.9, 0.42) if day_solar > 0.0 else C_TEXT_S],
			["Load Consumed",    "%.3f kWh" % day_load,   C_TEXT_S],
			["Net Balance",      "%+.3f kWh" % day_balance,
				Color(0.27, 0.9, 0.42) if day_balance > 0.01 else C_AMBER if day_balance < -0.01 else C_TEXT_S],
		]))

	# Solar PBI energy budget (educational — SoI flux vs captured)
	if model != null:
		var budget: Dictionary = SolarEnergyBudget.compute(model)
		if bool(budget.get("has_pbi", false)):
			var gold := Color(1.0, 0.85, 0.3)
			var eff_pct: float = float(budget.get("efficiency_pct", 0.0))
			var budget_rows: Array = [
				["SoI incoming flux", SolarEnergyBudget.format_kw(float(budget.get("flux_kw", 0.0))), gold],
				["Irradiance", "%.0f W/m²" % float(budget.get("irradiance_wm2", 0.0)), C_TEXT_S],
				["Cloud cover", "%.0f%%" % (float(budget.get("cloud_frac", 0.0)) * 100.0), C_TEXT_S],
				["Panels capturing", "%s (%d)" % [
						SolarEnergyBudget.format_kw(float(budget.get("panel_kw", 0.0))),
						int(budget.get("panel_count", 0))], Color(0.27, 0.9, 0.42)],
				["Grow-bed chemical", "%s (%d beds)" % [
						SolarEnergyBudget.format_kw(float(budget.get("plant_chem_kw", 0.0))),
						int(budget.get("plant_count", 0))], C_GREEN if int(budget.get("plant_count", 0)) > 0 else C_TEXT_S],
				["Site capture efficiency", "%.2f%%" % eff_pct,
					Color(0.27, 0.9, 0.42) if eff_pct > 1.0 else C_AMBER if eff_pct > 0.01 else C_TEXT_S],
			]
			outer_vbox.add_child(_rv_section("☀  SOLAR ENERGY BUDGET", budget_rows))

	var array_label := "%d panel%s = %.0f W" % [panel_count, "s" if panel_count != 1 else "", panel_wmp] if panel_count > 0 else "—"
	var bat_label   := "%.1f kWh @ %.0fV"    % [bat_kwh_total, bat_v_set]                                  if bat_kwh_total > 0.0 else "—"
	var ctrl_label  := "%.0f W max"           % ctrl_max_watts                                              if ctrl_max_watts > 0.0 else "—"
	var cm: Dictionary = compute_closure_metrics()
	var chs: Dictionary = cm.get("channels", {}) as Dictionary
	var closure_rows: Array = [
		["Puzzle Score", "%.0f" % float(cm.get("score", 0.0)), C_PRIMARY],
		["Mean Closure", "%.0f%%" % (float(cm.get("mean_closure_pct", 0.0)) * 100.0), C_TEXT_S],
		["Autonomy", "%.1f person-days" % float(cm.get("autonomy_person_days", 0.0)), C_TEXT_S],
	]
	for nk: String in ["energy", "water", "food", "waste"]:
		var ch: Dictionary = chs.get(nk, {}) as Dictionary
		var st: String = str(ch.get("status", "idle"))
		if st == "idle":
			closure_rows.append([nk.capitalize(), "— (inactive)", C_TEXT_M])
		else:
			closure_rows.append([
				nk.capitalize(),
				"%.0f%% closed · %.1f d autonomy" % [
						float(ch.get("closure_pct", 0.0)) * 100.0,
						float(ch.get("autonomy_days", 0.0)),
				],
				_CLOSURE_METRICS_SCRIPT.status_color(st),
			])
	outer_vbox.add_child(_rv_section("🔁  CLOSURE METRICS", closure_rows))

	outer_vbox.add_child(_rv_section("🏗  SYSTEM DESIGN", [
		["Solar Array",       array_label,                                 C_TEXT_S],
		["Battery Bank",      bat_label,                                   C_TEXT_S],
		["Controller",        ctrl_label,                                  C_TEXT_S],
		["User Components",   "%d item%s" % [user_items, "s" if user_items != 1 else ""],  C_TEXT_S],
		["Estimated Cost",    "$%.0f" % total_cost,                        C_PRIMARY],
	]))

	outer_vbox.add_child(_rv_hints_section(
		panel_wmp, ctrl_max_watts, bat_kwh_total, load_kw,
		day_solar, day_load, user_items, has_live, cm))

	return overlay


## Generates the title bar row with "📊 System Review" label and × close button.
func _rv_title_bar(overlay: Control) -> Control:
	var tb_sb := StyleBoxFlat.new()
	tb_sb.bg_color = C_PANEL
	tb_sb.set_border_width(SIDE_BOTTOM, 1)
	tb_sb.border_color        = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.3)
	tb_sb.content_margin_left   = 16.0
	tb_sb.content_margin_right  = 16.0
	tb_sb.content_margin_top    = 10.0
	tb_sb.content_margin_bottom = 10.0
	var tb := PanelContainer.new()
	tb.add_theme_stylebox_override("panel", tb_sb)

	var hbox := HBoxContainer.new()
	tb.add_child(hbox)

	var title := Label.new()
	title.text = "📊  System Review"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", C_PRIMARY)
	title.add_theme_font_size_override("font_size", 14)
	hbox.add_child(title)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.add_theme_color_override("font_color",       C_TEXT_S)
	close_btn.add_theme_color_override("font_hover_color", C_TEXT)
	close_btn.add_theme_font_size_override("font_size", 14)
	close_btn.pressed.connect(func():
		if is_instance_valid(overlay):
			overlay.queue_free()
		_review_modal = null
	)
	hbox.add_child(close_btn)

	return tb


## Builds one data section for the review modal.
## rows: Array of [label_str, value_str, Color]
func _rv_section(title: String, rows: Array) -> Control:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Section header
	var hdr_sb := StyleBoxFlat.new()
	hdr_sb.bg_color             = C_PANEL
	hdr_sb.border_color         = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.2)
	hdr_sb.set_border_width(SIDE_BOTTOM, 1)
	hdr_sb.content_margin_left   = 16.0
	hdr_sb.content_margin_right  = 16.0
	hdr_sb.content_margin_top    = 7.0
	hdr_sb.content_margin_bottom = 7.0
	var hdr := PanelContainer.new()
	hdr.add_theme_stylebox_override("panel", hdr_sb)
	var hdr_lbl := Label.new()
	hdr_lbl.text = title
	hdr_lbl.add_theme_color_override("font_color", C_PRIMARY)
	hdr_lbl.add_theme_font_size_override("font_size", 11)
	hdr.add_child(hdr_lbl)
	vbox.add_child(hdr)

	for row: Array in rows:
		var row_sb := StyleBoxFlat.new()
		row_sb.bg_color             = Color(0.0, 0.0, 0.0, 0.0)
		row_sb.border_color         = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.3)
		row_sb.set_border_width(SIDE_BOTTOM, 1)
		row_sb.content_margin_left   = 16.0
		row_sb.content_margin_right  = 16.0
		row_sb.content_margin_top    = 6.0
		row_sb.content_margin_bottom = 6.0
		var row_pc := PanelContainer.new()
		row_pc.add_theme_stylebox_override("panel", row_sb)
		row_pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var row_hbox := HBoxContainer.new()
		row_pc.add_child(row_hbox)

		var k := Label.new()
		k.text                  = row[0]
		k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		k.add_theme_color_override("font_color", C_TEXT_S)
		k.add_theme_font_size_override("font_size", 11)
		row_hbox.add_child(k)

		var v := Label.new()
		v.text                  = row[1]
		v.horizontal_alignment  = HORIZONTAL_ALIGNMENT_RIGHT
		v.add_theme_color_override("font_color", row[2] as Color)
		v.add_theme_font_size_override("font_size", 11)
		row_hbox.add_child(v)

		vbox.add_child(row_pc)

	return vbox


## Generates the hints section with smart tips based on system data.
func _rv_hints_section(panel_wmp: float, ctrl_max_watts: float,
		bat_kwh: float, load_kw: float,
		day_solar: float, day_load: float,
		user_items: int, has_live: bool,
		closure_metrics: Dictionary = {}) -> Control:
	var hints: Array = []

	if user_items == 0:
		hints.append(["💡", "Press G, add a Habitat from the library, then start a Challenge (🎯).", C_TEXT_S])
	else:
		# Panel ↔ controller matching
		if ctrl_max_watts > 0.0:
			var ratio := panel_wmp / ctrl_max_watts
			if ratio > 1.15:
				hints.append(["⚠", "Panels (%.0f W) exceed controller max (%.0f W) by %.0f%% — energy is wasted." % [panel_wmp, ctrl_max_watts, (ratio - 1.0) * 100.0], C_AMBER])
			elif ratio < 0.65:
				hints.append(["⚡", "Panels (%.0f W) are undersized for the controller (%.0f W) — add more panels." % [panel_wmp, ctrl_max_watts], C_AMBER])
			else:
				hints.append(["✔", "Panel-to-controller ratio is well-matched (%.0f%%)." % (ratio * 100.0), Color(0.27, 0.9, 0.42)])

		# Battery autonomy
		if bat_kwh > 0.0 and load_kw > 0.001:
			var days := bat_kwh / (load_kw * 24.0)
			if days < 0.5:
				hints.append(["⚠", "Battery (%.1f kWh) covers only %.1fh of load — consider expanding." % [bat_kwh, days * 24.0], C_AMBER])
			elif days < 1.5:
				hints.append(["💡", "Battery covers %.1f day(s) of load — adequate for short outages." % days, C_TEXT_S])
			else:
				hints.append(["✔", "Battery autonomy is %.1f days — good resilience." % days, Color(0.27, 0.9, 0.42)])

		# Daily energy balance
		if has_live:
			var balance := day_solar - day_load
			if balance > 0.01:
				hints.append(["✔", "Today's surplus: +%.3f kWh — system generating more than consumed." % balance, Color(0.27, 0.9, 0.42)])
			elif balance < -0.01:
				hints.append(["⚠", "Today's deficit: %.3f kWh — grid or battery drawdown." % absf(balance), C_AMBER])

	# Closure / import coaching
	var chs: Dictionary = closure_metrics.get("channels", {}) as Dictionary
	for nk: String in ["water", "food", "energy"]:
		var ch: Dictionary = chs.get(nk, {}) as Dictionary
		if ch.is_empty() or str(ch.get("status", "idle")) == "idle":
			continue
		var demand := float(ch.get("demand", 0.0))
		var import_v := float(ch.get("supply_import", ch.get("import", 0.0)))
		var local_v := float(ch.get("supply_local", 0.0))
		if demand > 0.01 and import_v > 0.01:
			var pct := clampf(import_v / demand, 0.0, 1.0) * 100.0
			if pct >= 25.0:
				var tip := ""
				match nk:
					"water":
						tip = "You're importing %.0f%% of water — expand SoI rain catchment or cut occupants." % pct
					"food":
						tip = "You're importing %.0f%% of food — grow local biomass loops or reduce occupants." % pct
					"energy":
						tip = "You're importing %.0f%% of energy — add PV / battery or shed loads." % pct
				hints.append(["📦", tip, C_AMBER])
		elif demand > 0.01 and local_v / demand >= 0.85:
			hints.append(["✔", "%s is mostly local (%.0f%% closed)." % [
					nk.capitalize(), float(ch.get("closure_pct", 0.0)) * 100.0], Color(0.27, 0.9, 0.42)])
		if str(ch.get("status", "")) == "critical":
			hints.append(["■", "%s is critical — refill tanks or start an import bridge." % nk.capitalize(), Color(0.90, 0.35, 0.30)])

	var waste_ch: Dictionary = chs.get("waste", {}) as Dictionary
	if not waste_ch.is_empty() and str(waste_ch.get("status", "idle")) != "idle":
		var w_close := float(waste_ch.get("closure_pct", 0.0))
		if w_close < 0.4:
			hints.append(["♻", "Waste loop is only %.0f%% closed — add greywater filter / digester." % (w_close * 100.0), C_AMBER])

	if hints.is_empty():
		hints.append(["✔", "System looks good!", Color(0.27, 0.9, 0.42)])

	# Build the UI
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var hdr_sb := StyleBoxFlat.new()
	hdr_sb.bg_color             = C_PANEL
	hdr_sb.border_color         = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.2)
	hdr_sb.set_border_width(SIDE_BOTTOM, 1)
	hdr_sb.content_margin_left   = 16.0
	hdr_sb.content_margin_right  = 16.0
	hdr_sb.content_margin_top    = 7.0
	hdr_sb.content_margin_bottom = 7.0
	var hdr := PanelContainer.new()
	hdr.add_theme_stylebox_override("panel", hdr_sb)
	var hdr_lbl := Label.new()
	hdr_lbl.text = "💡  OPTIMIZATION HINTS"
	hdr_lbl.add_theme_color_override("font_color", C_PRIMARY)
	hdr_lbl.add_theme_font_size_override("font_size", 11)
	hdr.add_child(hdr_lbl)
	vbox.add_child(hdr)

	for hint: Array in hints:
		var row_sb := StyleBoxFlat.new()
		row_sb.bg_color             = Color(0.0, 0.0, 0.0, 0.0)
		row_sb.border_color         = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.3)
		row_sb.set_border_width(SIDE_BOTTOM, 1)
		row_sb.content_margin_left   = 16.0
		row_sb.content_margin_right  = 16.0
		row_sb.content_margin_top    = 8.0
		row_sb.content_margin_bottom = 8.0
		var row_pc := PanelContainer.new()
		row_pc.add_theme_stylebox_override("panel", row_sb)
		row_pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var row_hbox := HBoxContainer.new()
		row_hbox.add_theme_constant_override("separation", 10)
		row_pc.add_child(row_hbox)

		var icon := Label.new()
		icon.text = hint[0]
		icon.add_theme_font_size_override("font_size", 13)
		row_hbox.add_child(icon)

		var txt := Label.new()
		txt.text                  = hint[1]
		txt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		txt.autowrap_mode         = TextServer.AUTOWRAP_WORD_SMART
		txt.add_theme_color_override("font_color", hint[2] as Color)
		txt.add_theme_font_size_override("font_size", 11)
		row_hbox.add_child(txt)

		vbox.add_child(row_pc)

	# Bottom padding
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(0.0, 8.0)
	vbox.add_child(pad)

	return vbox


func _delete_selected() -> void:
	if model == null or _graph_canvas == null:
		return
	var sel_item: String = _graph_canvas.get("selected_item_id") as String
	var sel_items: Array = _graph_canvas.get("selected_item_ids") as Array
	var sel_conn: String = _graph_canvas.get("selected_connection_id") as String
	if sel_items.size() > 1:
		var removed_any := false
		var doomed_props: Array[String] = []
		for sid_v in sel_items:
			var sid: String = str(sid_v)
			var it := model.get_item(sid)
			if it.is_empty():
				continue
			if str(it.get("scope_id", "root")) != _active_scope_id:
				continue
			if _item_is_locked(it):
				continue
			if _inspector_panel != null and _inspector_panel.has_method("unregister_item_automations"):
				_inspector_panel.call("unregister_item_automations", it)
			if bool(it.get("is_virtual", false)):
				_suppress_virtual(sid)
			_collect_bound_prop_ids(it, doomed_props)
			model.remove_item(sid)
			removed_any = true
		_selected_item_ids.clear()
		if not removed_any:
			_show_toast("Fundamental PBI nodes can't be removed")
		else:
			_reconcile_active_scope_owner()
			_delete_bound_props(doomed_props)
		return
	if not sel_item.is_empty():
		var it := model.get_item(sel_item)
		if _item_is_locked(it):
			_show_toast("Fundamental PBI nodes can't be removed")
			return
		if _inspector_panel != null and _inspector_panel.has_method("unregister_item_automations"):
			_inspector_panel.call("unregister_item_automations", it)
		if bool(it.get("is_virtual", false)):
			_suppress_virtual(sel_item)
		var doomed_props: Array[String] = []
		_collect_bound_prop_ids(it, doomed_props)
		model.remove_item(sel_item)
		_reconcile_active_scope_owner()
		_delete_bound_props(doomed_props)
	elif not sel_conn.is_empty():
		if sel_conn.begins_with("vconn_"):
			_suppress_virtual(sel_conn)
		model.remove_connection(sel_conn)


## bound_prop_id of `item` plus every descendant inside a compound's child
## scope tree — remove_item cascade-deletes those items, so their 3D twins
## must be collected BEFORE the removal.
func _collect_bound_prop_ids(item: Dictionary, out: Array[String]) -> void:
	if item.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var pid := str(specs.get("bound_prop_id", ""))
	if not pid.is_empty() and not out.has(pid):
		out.append(pid)
	if str(item.get("type", "")) != "compound":
		return
	var child_scope := str(item.get("child_scope_id", ""))
	if child_scope.is_empty() or model == null:
		return
	for child in model.get_items_in_scope(child_scope):
		_collect_bound_prop_ids(child as Dictionary, out)


## Delete the 3D placed-prop twins of just-removed graph nodes. A 2D node and
## its bound prop are ONE object in two views — deleting either side removes
## both (the reverse direction lives in terrain_loader.delete_prop_by_id).
func _delete_bound_props(prop_ids: Array[String]) -> void:
	if prop_ids.is_empty():
		return
	var main := _get_scene_main_node()
	if main == null:
		return
	var loader := _find_terrain_loader(main)
	if loader == null or not loader.has_method("delete_prop_by_id"):
		return
	var n := 0
	for pid in prop_ids:
		if bool(loader.call("delete_prop_by_id", pid)):
			n += 1
	if n > 0:
		_show_toast("Removed %d 3D twin%s from the world" % [n, "" if n == 1 else "s"])


## Remove every graph node (any scope) bound to a deleted 3D prop. Called by
## terrain_loader.delete_prop_by_id so a prop deleted in the world never
## leaves a dead node behind on the graph. No-op when the graph side already
## removed the items (graph-initiated deletes run first).
func remove_items_bound_to_prop(prop_id: String) -> void:
	if model == null or prop_id.is_empty():
		return
	var doomed: Array[String] = []
	for item: Dictionary in model.items:
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(specs.get("bound_prop_id", "")) == prop_id:
			doomed.append(str(item.get("id", "")))
	if doomed.is_empty():
		return
	for iid in doomed:
		var it := model.get_item(iid)
		if it.is_empty():
			continue
		if _inspector_panel != null and _inspector_panel.has_method("unregister_item_automations"):
			_inspector_panel.call("unregister_item_automations", it)
		model.remove_item(iid)
	if _graph_canvas != null:
		_graph_canvas.call("queue_redraw")
	_schedule_graph_autosave()


## After deleting interior nodes, prune any now-dangling promoted ports on the
## super-node that owns the scope we're editing (live-promotion maintenance).
func _reconcile_active_scope_owner() -> void:
	if model == null or _active_scope_id == "root":
		return
	var sc: Dictionary = model.get_scope(_active_scope_id)
	var owner := str(sc.get("owner_compound_id", ""))
	if owner.is_empty():
		return
	if GraphNesting.reconcile_exposed_ports(model, owner):
		model.changed.emit("reset")


## PBI / fundamental catchment nodes are locked and cannot be user-deleted.
func _item_is_locked(item: Dictionary) -> bool:
	if item.is_empty():
		return false
	if bool(item.get("locked", false)):
		return true
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if bool(specs.get("locked", false)) or bool(specs.get("fundamental", false)):
		return true
	return str(item.get("type", "")) == "pbi"


func _suppress_virtual(id: String) -> void:
	_suppressed_virtuals[id] = true
	if id.begins_with("virtual_panel_"):
		_suppressed_virtuals[GraphVirtualIds.V_PANEL_ID] = true
	if id.begins_with("virtual_device_") or id.begins_with("virtual_load_") \
			or id == "virtual_baseline":
		_suppressed_virtuals["vconn_ac_%s" % id] = true
	if id.begins_with("vconn_"):
		_suppressed_virtuals[id] = true
	if _bridge != null:
		_bridge.suppressed_ids = _suppressed_virtuals


# ---------------------------------------------------------------------------
# Toast notification  (Phase 9)
# ---------------------------------------------------------------------------

## `level` is a ToastUI.Level. It defaults to INFO (silent) so the ~120 existing
## call sites keep working untouched; pass OK/WARN/ERROR to add the matching
## feedback tier. Messages already prefixed "⚠" are auto-classified WARN, which
## covers the existing "allowed, but wrong" cases without editing each one.
func _show_toast(msg: String, duration: float = 2.5,
		level: int = ToastUI.Level.INFO) -> void:
	if _toast_panel == null:
		_toast_panel = _build_toast_panel()
		add_child(_toast_panel)   # on top

	var lvl := level
	if lvl == ToastUI.Level.INFO and msg.begins_with("⚠"):
		lvl = ToastUI.Level.WARN
	_play_toast_sfx(lvl)

	_toast_label.text    = msg
	_toast_panel.visible = true
	_toast_timer         = duration

	# Center horizontally near the BOTTOM of the canvas (above the timeline
	# inset) — the top-center slot sits right on the PBI chip row (Sunlight/
	# Rain/Wind) and a toast there occludes live nodes.
	var left_w  := SIDEBAR_L_W if _sidebar_l_open else 0.0
	var right_w := SIDEBAR_R_W if _sidebar_r_open else 0.0
	var canvas_w := size.x - left_w - right_w
	_toast_panel.reset_size()
	_toast_panel.position = Vector2(
		left_w + (canvas_w - _toast_panel.size.x) * 0.5,
		maxf(TOPBAR_H + 12.0,
			size.y - _timeline_bottom_inset() - _toast_panel.size.y - 72.0)
	)


func _play_toast_sfx(level: int) -> void:
	var sfx := get_node_or_null("/root/UiSound")
	if sfx == null:
		return
	match level:
		ToastUI.Level.OK:
			sfx.call("play_ui", _UI_SFX.SUCCESS, 120)
		ToastUI.Level.WARN:
			sfx.call("play_ui", _UI_SFX.WARN, 250)
		ToastUI.Level.ERROR:
			sfx.call("play_ui", _UI_SFX.DANGER, 250)


func _build_toast_panel() -> PanelContainer:
	var pc := PanelContainer.new()
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.visible      = false

	var sb := StyleBoxFlat.new()
	sb.bg_color              = Color(C_BG.r, C_BG.g, C_BG.b, 0.92)
	sb.border_color          = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.6)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left   = 16.0
	sb.content_margin_right  = 16.0
	sb.content_margin_top    =  8.0
	sb.content_margin_bottom =  8.0
	pc.add_theme_stylebox_override("panel", sb)

	_toast_label = Label.new()
	_toast_label.add_theme_color_override("font_color", C_TEXT)
	_toast_label.add_theme_font_size_override("font_size", 12)
	pc.add_child(_toast_label)
	return pc


# ---------------------------------------------------------------------------
# Hints overlay  (Phase 9)
# ---------------------------------------------------------------------------

func _build_hints_panel() -> Control:
	var pc := PanelContainer.new()
	pc.mouse_filter = Control.MOUSE_FILTER_STOP

	var sb := StyleBoxFlat.new()
	sb.bg_color              = Color(C_BG.r, C_BG.g, C_BG.b, 0.95)
	sb.border_color          = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.5)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left   = 20.0
	sb.content_margin_right  = 20.0
	sb.content_margin_top    = 16.0
	sb.content_margin_bottom = 16.0
	pc.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	pc.add_child(vbox)

	var title := Label.new()
	title.text = "⌨  Keyboard & Mouse Shortcuts"
	title.add_theme_color_override("font_color", C_PRIMARY)
	title.add_theme_font_size_override("font_size", 13)
	vbox.add_child(title)

	var div := ColorRect.new()
	div.color               = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
	div.custom_minimum_size = Vector2(0.0, 1.0)
	div.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(div)

	var shortcuts: Array = [
		["G",                      "Toggle graph view"],
		["Del",                    "Delete selected node / wire"],
		["Scroll wheel",           "Zoom canvas"],
		["Middle / Right drag",    "Pan canvas"],
		["Left-click node",        "Select & open Inspector"],
		["Drag from port dot",     "Create wire connection"],
		["Left-click wire",        "Select wire"],
		["Click library item",     "Spawn at canvas center"],
		["Drag library item",      "Drag-drop onto canvas"],
	]

	for pair: Array in shortcuts:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		vbox.add_child(row)

		var key_lbl := Label.new()
		key_lbl.text               = pair[0]
		key_lbl.custom_minimum_size = Vector2(160.0, 0.0)
		key_lbl.add_theme_color_override("font_color", C_AMBER)
		key_lbl.add_theme_font_size_override("font_size", 11)
		row.add_child(key_lbl)

		var desc_lbl := Label.new()
		desc_lbl.text = pair[1]
		desc_lbl.add_theme_color_override("font_color", C_TEXT_S)
		desc_lbl.add_theme_font_size_override("font_size", 11)
		row.add_child(desc_lbl)

	var close_btn := Button.new()
	close_btn.text       = "Close"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(func():
		_hints_visible = false
		pc.visible = false
	)
	_restyle_btn_amber(close_btn)
	vbox.add_child(close_btn)

	# Position: centered in canvas area
	pc.set_anchors_and_offsets_preset(Control.PRESET_CENTER)

	return pc


func _on_build_mode() -> void:
	_mode = "build"
	if _graph_canvas != null:
		_graph_canvas.set("current_mode", "build")
	if is_instance_valid(_graph_dashboard):
		_graph_dashboard.set_mode("build")


func _on_test_mode() -> void:
	_mode = "test"
	if _graph_canvas != null:
		_graph_canvas.set("current_mode", "test")
	if is_instance_valid(_graph_dashboard):
		_graph_dashboard.set_mode("test")


# ---------------------------------------------------------------------------
# Process — drives GraphCanvas.tick()
# ---------------------------------------------------------------------------

## Ambient resource-flow tick — runs every frame regardless of graph visibility
## (see the call site in _process for why). History-suppressed + bulk-coalesced
## exactly like the old visible-gated call was, so engine-driven writes never
## spam the undo stack while the player is out in the 3D world.
## Live roster telemetry for a pop-driven habitat (inspector Population
## section); {} until the ambient tick has spun the engine up.
## Navigation state for the inspector, so "why is everyone walking through
## that tree" has a visible answer while the grid is still baking.
func npc_nav_status() -> Dictionary:
	return _npc_population.nav_status() if _npc_population != null else {}


func npc_population_summary(item_id: String) -> Dictionary:
	if _npc_population == null:
		return {}
	return _npc_population.summary_for(item_id)


## The habitat's daily schedule, and replacing it (Routines panel editor).
func npc_routine_for(item_id: String) -> NpcRoutine:
	return _npc_population.routine_for(item_id) if _npc_population != null else null


func npc_set_routine(item_id: String, blocks: Array) -> bool:
	return _npc_population.set_routine(item_id, blocks) if _npc_population != null else false


## Which clip plays in each activity/space slot, and rebinding them.
func npc_anim_overrides(item_id: String) -> Dictionary:
	return _npc_population.anim_overrides_for(item_id) if _npc_population != null else {}


func npc_set_anim_overrides(item_id: String, overrides: Dictionary) -> bool:
	return _npc_population.set_anim_overrides(item_id, overrides) \
		if _npc_population != null else false


## Start a habitat's community over (inspector button). An emptied roster has
## no way back on its own — see NpcPopulationBridge.reset_population.
func npc_reset_population(item_id: String) -> bool:
	if _npc_population == null:
		return false
	if not _npc_population.reset_population(item_id, model, _get_scene_main_node()):
		return false
	_show_toast("New people have arrived — %d moving in" % int(
		float((model.get_item(item_id).get("specs", {}) as Dictionary).get("occupants", 0))))
	return true


const _NPC_ROUTINES_SCRIPT := preload("res://scenes/ui/npc_routines_panel.gd")
var _npc_routines_panel: Control = null
const _SITE_PROJECTS_SCRIPT := preload("res://scenes/ui/site_project_panel.gd")
var _site_project_panel: Control = null
const _WORK_PLANNER_SCRIPT := preload("res://scenes/ui/work_planner_panel.gd")
var _work_planner_panel: Control = null
const _FEED_STRIP_SCRIPT := preload("res://scenes/ui/settlement_feed_strip.gd")
var _feed_strip: Control = null


## The settlement log's first-person strip — a few quiet fading lines while
## neither the graph (toasts) nor the settlement view (feed panel) is up.
## Spawned once a population is actually running; it polls the log itself.
func _ensure_feed_strip() -> void:
	if _feed_strip != null and is_instance_valid(_feed_strip):
		return
	if _npc_population == null or not _npc_population.has_pop_driven():
		return
	var parent := get_parent()
	if parent == null:
		return
	_feed_strip = _FEED_STRIP_SCRIPT.new()
	_feed_strip.name = "SettlementFeedStrip"
	parent.add_child(_feed_strip)
	_feed_strip.call("bind", _npc_population, self)


## The Work Planner (Chores / Tasks / Schedule / Person). Same lazy pattern as
## the Routines panel; reachable from the work dock and the Routines panel.
## A non-empty `agent_id` lands straight on that person's tab — the jump the
## fairness line, the roster strip and the settlement card all share.
func open_work_planner(item_id: String = "", agent_id: String = "") -> void:
	if _npc_population == null:
		_show_toast("No population running — planning needs a crew")
		return
	if _work_planner_panel == null or not is_instance_valid(_work_planner_panel):
		_work_planner_panel = _WORK_PLANNER_SCRIPT.new()
		_work_planner_panel.name = "WorkPlannerPanel"
		var parent := get_parent()
		if parent == null:
			return
		parent.add_child(_work_planner_panel)
	if agent_id.is_empty():
		_work_planner_panel.call("open", _npc_population, item_id)
	else:
		_work_planner_panel.call("open_person", _npc_population, item_id, agent_id)


## Site Projects panel (the camp-lifecycle mechanic's management surface).
## Lazily instantiated the same way the Routines panel is; reachable from the
## Routines panel's "Projects…" button and anywhere with a view reference.
func open_site_projects() -> void:
	if _npc_population == null:
		_show_toast("No population running — projects need a crew")
		return
	if _site_project_panel == null or not is_instance_valid(_site_project_panel):
		_site_project_panel = _SITE_PROJECTS_SCRIPT.new()
		_site_project_panel.name = "SiteProjectPanel"
		var parent := get_parent()
		if parent == null:
			return
		parent.add_child(_site_project_panel)
	_site_project_panel.call("open", _npc_population)


## Routines & chores for one habitat (inspector button). Lazily instantiated
## the same way the Record Book / Site Report modals are.
func open_npc_routines(item_id: String) -> void:
	if _npc_population == null or not _npc_population.has_engine(item_id):
		_show_toast("Turn on Simulated individuals first — the roster starts on the next tick")
		return
	if _npc_routines_panel == null or not is_instance_valid(_npc_routines_panel):
		_npc_routines_panel = _NPC_ROUTINES_SCRIPT.new()
		_npc_routines_panel.name = "NpcRoutinesPanel"
		var parent := get_parent()
		if parent == null:
			return
		parent.add_child(_npc_routines_panel)
	_npc_routines_panel.call("open", _npc_population, item_id)


## Light up the in-graph 3D site preview so the world renders LIVE behind the
## canvas — used while a tutorial run plays back, so the player watches the sun
## cross the site while the battery fills. The preview SubViewport shares the
## root World3D and is exempt from the `disable_3d` the graph sets on the root
## viewport, which is why the run doesn't have to hide the graph to show a sky.
##
## MUST be turned back off on every run-exit path: the service documents the
## live re-render as the view's dominant cost.
func set_live_world_preview(on: bool) -> void:
	if _soi_preview == null:
		return
	if on and _soi_preview.has_method("set_active"):
		_soi_preview.call("set_active", true)
	if _soi_preview.has_method("set_preview_live"):
		_soi_preview.call("set_preview_live", on)


## ChallengeBakeEngine handshake: while suspended, the engine steps the flow
## sim + population itself (render_step / seek_all_tanks) and the ambient
## tick stands down entirely.
func set_ambient_flow_suspended(on: bool) -> void:
	_ambient_flow_suspended = on


func resource_flow_engine() -> RefCounted:
	return _resource_flow


func npc_population_bridge() -> NpcPopulationBridge:
	return _npc_population


## Aggregate roster snapshot for the dashboard's Settlement card. Routed
## through _npc_dot_source() so an MP guest reads the host's replicated dots
## exactly like the 3D avatar layer does. {} = no population running.
func npc_dot_summary() -> Dictionary:
	var src = _npc_dot_source()
	if src == null or not bool(src.call("active")):
		return {}
	var dots: Variant = src.call("agent_dots")
	if not (dots is Array) or (dots as Array).is_empty():
		return {}
	var n := 0
	var morale_sum := 0.0
	var bands: Dictionary = {}       # morale_label -> count
	var acts: Dictionary = {}        # activity -> count (raw sim names)
	var traveling := 0
	for dot_v in dots as Array:
		if not (dot_v is Dictionary):
			continue
		var dot: Dictionary = dot_v
		n += 1
		morale_sum += float(dot.get("morale", 0.0))
		var band := str(dot.get("morale_label", ""))
		if not band.is_empty():
			bands[band] = int(bands.get(band, 0)) + 1
		if int(dot.get("state", NpcAgent.State.IDLE)) == NpcAgent.State.TRAVELING:
			traveling += 1
		else:
			var act := str(dot.get("activity", ""))
			if act.is_empty():
				act = "idle"
			acts[act] = int(acts.get(act, 0)) + 1
	if n == 0:
		return {}
	return {"count": n, "morale_avg": morale_sum / float(n),
			"bands": bands, "activities": acts, "traveling": traveling}


## The "watch the crew" handoff, v2: queueing work no longer yanks the camera
## anywhere (the old watch_site_at jumped to the Site Plan and hard-set its
## zoom, which was jarring and — while the plan froze the clock — showed a
## frozen crew anyway). Instead: nudge a paused clock so the work actually
## starts, and offer a clickable Watch chip that opens the settlement view —
## the surface built for watching people work — centred on the site.
func notify_crew_queued(world_xz: Vector2, title: String, detail := "") -> void:
	var m := _get_scene_main_node()
	var resumed := false
	if m != null and m.get("time_scale") != null and float(m.time_scale) <= 0.0:
		m.time_scale = 1.0
		resumed = true
	var det := detail
	if resumed:
		det = "clock resumed" if det.is_empty() else "%s · clock resumed" % det
	det = "tap to watch" if det.is_empty() else "%s · tap to watch" % det
	var toaster: ToastUI = m.get("toast_ui") if m != null else null
	if toaster == null:
		_show_toast(title, 3.0, ToastUI.Level.OK)
		return
	toaster.show_community("crew_queued", title, det, ToastUI.Level.OK, 5.0,
		func() -> void:
			if visible:
				_apply_graph_close_side_effects()
			if m != null and m.has_method("open_settlement_view"):
				m.call("open_settlement_view", world_xz))


## The live 3D host (null until at least one pop-driven habitat has spawned
## it) — for settings-driven live refreshes like re-tinting on a display-pref
## change, which need to reach already-built NpcAvatars directly.
func npc_population_host() -> Node3D:
	return _npc_host


## Which settlement-log kinds are story beats worth a toast, and how loudly.
const _NPC_TOAST_LEVELS: Dictionary = {
	"departed": ToastUI.Level.WARN,
	"lost": ToastUI.Level.ERROR,
	"collapse_warning": ToastUI.Level.WARN,
	"collapsed": ToastUI.Level.ERROR,
	"deserted": ToastUI.Level.ERROR,
	"skill_earned": ToastUI.Level.OK,
}


## Departures and collapse are story beats — surface them in EVERY mode.
## Reads the settlement log through a NAMED CURSOR (log_since), so this toast
## and the challenge bake's collapse watcher can no longer race each other.
## Chips render through the global ToastUI stack (icon + headline + dim
## detail, severity-tinted) rather than the graph's private single-slot label,
## which was only visible while the graph itself was open. While the
## settlement view is open its own feed already shows these lines, so the
## toast stays quiet there; the cursor still advances, so closing the view
## never replays a backlog of stale toasts.
func _drain_npc_events() -> void:
	if _npc_population == null:
		return
	var quiet := false
	var main := _get_scene_main_node()
	if main != null and main.has_method("settlement_view_open"):
		quiet = bool(main.call("settlement_view_open"))
	var toaster: ToastUI = main.get("toast_ui") if main != null else null
	for e in _npc_population.log_since("graph_toast"):
		var ev: Dictionary = e
		var kind := str(ev.get("kind", ""))
		if not _NPC_TOAST_LEVELS.has(kind) or quiet:
			continue
		var level: int = _NPC_TOAST_LEVELS[kind]
		var meta: Dictionary = ev.get("meta", {})
		if toaster != null:
			toaster.show_community(kind,
				str(meta.get("title", ev.get("text", ""))),
				str(meta.get("detail", "")), level, 4.0,
				_community_chip_action(kind, str(ev.get("subject", "")),
					str(meta.get("agent_id", ""))))
		else:
			_show_toast(str(ev.get("text", "")), 2.5, level)


## What clicking a community chip opens: a qualification opens that person's
## ledger (the planner's Person tab); everything else — departures, collapse —
## opens the settlement view, because "go look at the community" is the honest
## response to community news. Closing the graph first uses the same side-
## effect path the G toggle does, so survival pausing stays balanced.
func _community_chip_action(kind: String, iid: String, agent_id: String) -> Callable:
	if kind == "skill_earned" and not agent_id.is_empty():
		return func() -> void:
			open_work_planner(iid, agent_id)
	return func() -> void:
		if visible:
			_apply_graph_close_side_effects()
		var main := _get_scene_main_node()
		if main != null and main.has_method("open_settlement_view"):
			main.call("open_settlement_view")


## Spawn/despawn the 3D avatar host to match whether any population engine
## is running (pop-driven habitat present).
## Site Plan providers. Resolved through `_npc_dot_source()` on every call so a
## client (which never builds an NpcPopulationBridge) still draws the host's
## people, and so switching between hosting and joining needs no re-wiring.
## The space/crew/desire layers stay bridge-only: none of them are replicated,
## and a provider that quietly returned [] would read as "this camp has no
## tagged spaces" rather than "you are a guest".
func _wire_npc_providers() -> void:
	if _graph_canvas == null or _npc_providers_wired:
		return
	_npc_providers_wired = true
	_graph_canvas.set("npc_agents_provider", func() -> Array:
		var src = _npc_dot_source()
		return src.call("agent_dots") if src != null else [])
	var main_for_spaces := _get_scene_main_node()
	_graph_canvas.set("npc_spaces_provider", func() -> Array:
		return _npc_population.space_markers(main_for_spaces) if _npc_population != null else [])
	_graph_canvas.set("npc_crew_provider", func() -> Array:
		return _npc_population.crew_site_markers(main_for_spaces) if _npc_population != null else [])
	_graph_canvas.set("npc_desire_provider", func() -> Dictionary:
		if not _desire_lines_on or _npc_population == null:
			return {}
		var p: Dictionary = _npc_population.desire_payload(_desire_channel)
		if not p.is_empty():
			p["channel_label"] = _desire_channel_label()
		return p)


## True when a multiplayer client should render the host's population rather
## than run its own. Soft lookup: the harness and headless selftests have no
## session, and single-player must be byte-identical to before.
func _mp_is_replica() -> bool:
	var mp := get_node_or_null("/root/MultiplayerSession")
	if mp == null:
		return false
	var pop = mp.get("population")
	return pop != null and bool(pop.call("is_replica"))


## The dot source for the 3D figures. On a client this is the replication
## mirror, which duck-types the two methods NpcPopulationHost needs — that one
## substitution is what makes the whole avatar/LOD/pose path work unchanged.
func _npc_dot_source():
	if _mp_is_replica():
		var mp := get_node_or_null("/root/MultiplayerSession")
		if mp != null:
			var pop = mp.get("population")
			if pop != null:
				return pop.get("mirror")
	return _npc_population


func _ensure_npc_host() -> void:
	var source = _npc_dot_source()
	var wants := source != null and bool(source.call("active"))
	var alive := _npc_host != null and is_instance_valid(_npc_host)
	if wants and not alive:
		var main_node := _get_scene_main_node()
		if main_node == null:
			return
		_npc_host = NpcPopulationHost.new()
		_npc_host.setup(source, main_node)
		main_node.add_child(_npc_host)
	elif alive and _npc_host.get("_bridge") != source:
		# Role changed mid-session (hosted, then joined someone else). Re-point
		# rather than rebuild so avatars do not pop.
		_npc_host.setup(source, _get_scene_main_node())
	elif not wants and alive:
		_npc_host.queue_free()
		_npc_host = null


## Build or tear down the 3D desire drape. Lazily created on first enable, so
## a player who never turns it on pays nothing.
func _ensure_desire_overlay() -> void:
	var main_node := _get_scene_main_node()
	if not _desire_3d_on or _npc_population == null or main_node == null:
		if _desire_overlay != null and is_instance_valid(_desire_overlay):
			_desire_overlay.queue_free()
		_desire_overlay = null
		return
	var payload: Dictionary = _npc_population.desire_payload(_desire_channel)
	if payload.is_empty():
		return
	if _desire_overlay == null or not is_instance_valid(_desire_overlay):
		_desire_overlay = NpcDesireOverlay.new()
		var parent: Node = main_node.get_node_or_null("Terrain")
		(parent if parent != null else main_node).add_child(_desire_overlay)
	_desire_overlay.call("rebuild", main_node, payload.get("rect", Rect2()))
	_desire_overlay.call("set_heat", payload.get("texture"))


func _tick_resource_flow_ambient(delta: float) -> void:
	# Multiplayer: the HOST owns the simulation. Before this guard every client
	# independently ran its own flow engine and population sim off its synced
	# copy of the graph, drifted, and got stomped by the host's snapshot every
	# 12 s — so tank levels crept and the people on screen were a local
	# hallucination that snapped twice a minute. A client RENDERS replicated
	# state (MpPopulationController) instead of computing its own.
	#
	# Checked before the `_resource_flow == null` guard on purpose: the client
	# path must not depend on a flow engine it is never going to step.
	if _mp_is_replica():
		_wire_npc_providers()
		_ensure_npc_host()
		return
	if _resource_flow == null:
		return
	# Challenge bake/playback: the ChallengeBakeEngine owns the flow engine —
	# the ambient tick would either rewind tank specs mid-bake (frozen clock →
	# scrub-read) or double-step them during playback.
	if _ambient_flow_suspended:
		return
	# The engine coalesces on its own 0.25 s / 0.5 s accumulator, so on most frames
	# tick() just accumulates and early-returns. Only pay the bulk-sync + history-
	# suppress + PerfMonitor overhead on frames where a step will actually run.
	if _resource_flow.has_method("would_tick") and not _resource_flow.call("would_tick", delta):
		_resource_flow.call("tick", delta)  # cheap: accumulate + early-out
		return
	var was_suppress := _history_suppress
	var was_bulk := _sim_bulk_update
	_history_suppress = true
	_sim_bulk_update = true
	if _sim_load_host != null and _sim_load_host.has_method("begin_bulk_sync"):
		_sim_load_host.call("begin_bulk_sync")
	# NPC population: step agents + install this tick's habitat demand rates
	# BEFORE the flow step consumes them (runs ambient, graph open or closed).
	if _npc_population == null:
		_npc_population = NpcPopulationBridge.new()
		_wire_npc_providers()
	PerfMonitor.begin("npc_population")
	_npc_population.tick(model, _resource_flow, _get_scene_main_node())
	PerfMonitor.end("npc_population")
	_ensure_npc_host()
	_ensure_feed_strip()
	if _desire_3d_on:
		_ensure_desire_overlay()
	_drain_npc_events()
	# Dots move only on population ticks — redraw the Site Plan then (and only
	# then; with the graph closed or in other views this costs nothing).
	if visible and _npc_population.active() and _graph_canvas != null \
			and _graph_view_mode == GraphSiteLayout.VIEW_SITE:
		_graph_canvas.queue_redraw()
	# Site Plan runs on the LIVE clock (no noon lock), so the top-down disc's
	# lighting drifts with sim time. Re-capture the (dirty-driven) SubViewport
	# at a low wall-clock throttle — never the expensive _preview_live path.
	if visible and _graph_view_mode == GraphSiteLayout.VIEW_SITE \
			and _soi_preview != null and _soi_preview.has_method("request_refresh"):
		var now_ms := Time.get_ticks_msec()
		if now_ms - _site_light_refresh_ms >= SITE_LIGHT_REFRESH_MS:
			_site_light_refresh_ms = now_ms
			_soi_preview.call("request_refresh")
	PerfMonitor.begin("flow_engine")
	_resource_flow.call("tick", delta)
	PerfMonitor.end("flow_engine")
	if _sim_load_host != null and _sim_load_host.has_method("end_bulk_sync"):
		_sim_load_host.call("end_bulk_sync")
	_history_suppress = was_suppress
	_sim_bulk_update = was_bulk


func _process(delta: float) -> void:
	# Water/catchment/siphon/culvert physics must progress even while the 2D
	# graph screen is closed — rain fills ponds and the siphon drains them
	# ambiently, the same way weather/solar keep running with no UI open.
	# Previously `_resource_flow.tick()` only ran below the `if not visible`
	# gate, so the whole water system silently froze the instant the player
	# left the graph (reported as "rain doesn't fill the pond" / "the siphon
	# never flows" — its specs were a stale snapshot from the last time the
	# graph happened to be open, not a live simulation).
	_tick_resource_flow_ambient(delta)
	# DC current-limit throttle must stay live with the graph closed — it caps
	# the battery charge rate SolarUI integrates every frame.
	_tick_dc_throttle(delta)
	if not visible:
		return
	# Hydro Lab owns its CT/UI — skip canvas/bridge/renewables storms. Ambient
	# ResourceFlowEngine (above) still runs so test inflow + siphon drain work.
	if _graph_view_mode == GraphSiteLayout.VIEW_SIPHON:
		if _toast_timer > 0.0:
			_toast_timer -= delta
			if _toast_timer <= 0.0 and _toast_panel != null:
				_toast_panel.visible = false
		return
	var sim_ts := -1.0
	var main_node := _get_scene_main_node()
	if main_node != null and main_node.get("time_scale") != null:
		sim_ts = float(main_node.time_scale)
	# Auto-switch between Test (running) and Build (paused) based on simulation state
	if sim_ts >= 0.0:
		var want_mode := "test" if sim_ts > 0.0 else "build"
		if _mode != want_mode:
			if want_mode == "test":
				_on_test_mode()
			else:
				_on_build_mode()
	PerfMonitor.begin("graph_sim")
	PerfMonitor.begin("gv_canvas")
	if _graph_canvas != null and _graph_canvas.has_method("tick"):
		_graph_canvas.call("tick", delta, sim_ts)
	PerfMonitor.end("gv_canvas")
	# Bridge tick — suppress history so its model updates are not recorded, and
	# batch the redraw/telemetry cascade so a tick touching many items (tanks,
	# virtual nodes) triggers one redraw instead of one per update_item.
	_history_suppress = true
	_sim_bulk_update = true
	if _sim_load_host != null and _sim_load_host.has_method("begin_bulk_sync"):
		_sim_load_host.call("begin_bulk_sync")
	PerfMonitor.begin("gv_bridge")
	if _bridge != null:
		_bridge.call("tick", delta)
	PerfMonitor.end("gv_bridge")
	PerfMonitor.begin("gv_ticks")
	_tick_graph_renewables(delta)
	_tick_graph_csp(delta)
	_tick_graph_heliostat(delta)
	_tick_graph_biodigester(delta)
	_tick_graph_tools(delta)
	_tick_graph_pp_extruder(delta)
	_tick_graph_pp_sheet_press(delta)
	_tick_connector_burnout(delta)
	_tick_graph_pbis(delta)
	_tick_graph_solar_shading(delta)
	PerfMonitor.end("gv_ticks")
	_energy_sync_acc += delta
	var _do_energy_sync := false
	if _energy_sync_acc >= _ENERGY_SYNC_INTERVAL:
		_energy_sync_acc = 0.0
		_do_energy_sync = true
		PerfMonitor.begin("gv_energy")
		_sync_graph_energy_from_solar()
		PerfMonitor.end("gv_energy")
	PerfMonitor.begin("gv_workflow")
	_tick_active_workflow()
	PerfMonitor.end("gv_workflow")
	# Runs after the resource-flow tick (not alongside the sync above) so it
	# sees this frame's freshly recomputed DC-generator current_output_kw
	# telemetry, not last frame's.
	if _do_energy_sync:
		PerfMonitor.begin("gv_dcsync")
		_sync_graph_dc_generation_to_solar()
		PerfMonitor.end("gv_dcsync")
	_closure_refresh_acc += delta
	if _closure_refresh_acc >= _CLOSURE_REFRESH_INTERVAL:
		_closure_refresh_acc = 0.0
		PerfMonitor.begin("gv_closure")
		_refresh_closure_telemetry()
		PerfMonitor.end("gv_closure")
	# end_bulk_sync flushes the coalesced load-state sync, which may itself write
	# update_item. Run it BEFORE clearing the bulk/history flags so those writes
	# stay history-suppressed and coalesced into the single flush below — clearing
	# first made each load-sync write fire the full uncoalesced redraw/telemetry
	# cascade (the graph-view stall).
	if _sim_load_host != null and _sim_load_host.has_method("end_bulk_sync"):
		PerfMonitor.begin("gv_bulk")
		_sim_load_host.call("end_bulk_sync")
		PerfMonitor.end("gv_bulk")
	_history_suppress = false
	_sim_bulk_update = false
	_telemetry_flush_acc += delta
	PerfMonitor.begin("gv_flush")
	_flush_sim_bulk_update(_telemetry_flush_acc >= _TELEMETRY_FLUSH_INTERVAL)
	PerfMonitor.end("gv_flush")
	if _telemetry_flush_acc >= _TELEMETRY_FLUSH_INTERVAL:
		_telemetry_flush_acc = 0.0
	PerfMonitor.end("graph_sim")
	# Push the initial snapshot once, after the bridge has seeded virtual nodes
	if not _history_initialized:
		_history_initialized = true
		_push_history()
		call_deferred("_maybe_apply_first_load_layout")
	if _lib_ghost != null and _lib_ghost.visible:
		_lib_ghost.position = get_viewport().get_mouse_position() + Vector2(10.0, 8.0)
	# Toast countdown
	if _toast_timer > 0.0:
		_toast_timer -= delta
		if _toast_timer <= 0.0 and _toast_panel != null:
			_toast_panel.visible = false


# ---------------------------------------------------------------------------
# Input — G toggle
# ---------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	# ---- Library drag tracking ----
	if not _lib_drag_preset.is_empty():
		if event is InputEventMouseMotion:
			var mm := event as InputEventMouseMotion
			if not _lib_drag_active:
				if mm.global_position.distance_to(_lib_drag_start) > LIB_DRAG_THRESHOLD:
					_lib_drag_active     = true
					if _lib_ghost != null:
						_lib_ghost.visible = true
			# Ghost position is updated in _process via get_mouse_position()
		elif event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
				_end_lib_drag(mb.global_position)
				get_viewport().set_input_as_handled()
				return
		# Native touch path (mirrors the mouse path; idempotent if mouse events are
		# also emulated from touch, since _end_lib_drag clears the armed preset).
		elif event is InputEventScreenDrag:
			var sd := event as InputEventScreenDrag
			if not _lib_drag_active:
				if sd.position.distance_to(_lib_drag_start) > LIB_DRAG_THRESHOLD:
					_lib_drag_active = true
					if _lib_ghost != null:
						_lib_ghost.visible = true
			if _lib_ghost != null and _lib_ghost.visible:
				_lib_ghost.position = sd.position + Vector2(10.0, 8.0)
		elif event is InputEventScreenTouch:
			var stc := event as InputEventScreenTouch
			if not stc.pressed:
				_end_lib_drag(stc.position)
				get_viewport().set_input_as_handled()
				return

	# ---- Keyboard shortcuts (Delete / Ctrl+Z / Ctrl+Y) ----
	if event is InputEventKey:
		var ke := event as InputEventKey
		if ke.pressed and not ke.echo:
			var key_focus := get_viewport().gui_get_focus_owner()
			var in_text := key_focus is LineEdit or key_focus is TextEdit or key_focus is CodeEdit
			if not in_text:
				if ke.keycode == KEY_DELETE:
					_delete_selected()
					get_viewport().set_input_as_handled()
					return
				if ke.ctrl_pressed and ke.keycode == KEY_Z:
					_do_undo()
					get_viewport().set_input_as_handled()
					return
				if ke.ctrl_pressed and ke.keycode == KEY_Y:
					_do_redo()
					get_viewport().set_input_as_handled()
					return
				# Esc collapses one nesting level (keeps StarShade / component identity).
				if visible and ke.keycode == KEY_ESCAPE and _scope_trail.size() > 1:
					_collapse_active_scope(true)
					get_viewport().set_input_as_handled()
					return
				# Ctrl+G group / Ctrl+Shift+G ungroup-or-expand (only while the graph is open).
				# Identity-backed super-nodes Expand instead of dissolving — see
				# Combine ▾ → Explode for the destructive shell removal.
				if visible and ke.ctrl_pressed and ke.keycode == KEY_G:
					if ke.shift_pressed:
						_on_ungroup_selected_pressed()
					else:
						_on_group_selected_pressed()
					get_viewport().set_input_as_handled()
					return

	# ---- G toggle ----
	if not InputMap.has_action("system_graph_toggle"):
		return
	if not event.is_action_pressed("system_graph_toggle"):
		return

	# Don't steal input from text fields
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is CodeEdit:
		return

	# Don't open while save/load panel is up
	var ui_layer := get_parent()
	if ui_layer:
		var sl := ui_layer.get_node_or_null("SaveLoadUI")
		if sl != null and sl.has_method("is_panel_visible") and sl.is_panel_visible():
			return

	if visible:
		_apply_graph_close_side_effects()
	else:
		_apply_graph_open_side_effects()
	_update_make_array_quick_button()
	get_viewport().set_input_as_handled()


## Programmatic open (tutorial director) — same side effects as the G toggle.
func open_graph_view() -> void:
	if visible:
		return
	_apply_graph_open_side_effects()
	_update_make_array_quick_button()


func _apply_graph_open_side_effects() -> void:
	visible = true
	_apply_graph_open_mode_from_sim_state()
	# Pause survival mechanics while graph is open
	var m := _get_scene_main_node()
	if m != null and m.get("gameplay_mechanics_paused") != null:
		_gameplay_paused_before_graph = bool(m.gameplay_mechanics_paused)
		m.gameplay_mechanics_paused = true
	var gr: Variant = _GAMEPLAY_RULES_SCRIPT.from_node(self)
	if gr != null:
		gr.set_survival_paused(true)
	# Re-sync load automations so rules fire even if the graph was
	# closed and the engine was cleared since last inspect
	if _inspector_panel != null and _inspector_panel.has_method("sync_all_load_automations"):
		_inspector_panel.call("sync_all_load_automations", model)


func _apply_graph_close_side_effects() -> void:
	visible = false
	# Restore survival state from before the graph was opened
	var m := _get_scene_main_node()
	if m != null and m.get("gameplay_mechanics_paused") != null:
		m.gameplay_mechanics_paused = _gameplay_paused_before_graph
	var gr: Variant = _GAMEPLAY_RULES_SCRIPT.from_node(self)
	if gr != null:
		gr.set_survival_paused(_gameplay_paused_before_graph)


# ---------------------------------------------------------------------------
# Scene main (Main node under UILayer parent)
# ---------------------------------------------------------------------------

func _get_scene_main_node() -> Node:
	var ul := get_parent()
	if ul == null:
		return null
	return ul.get_parent()


func _init_conduit_manager() -> void:
	var main_node := _get_scene_main_node()
	if main_node == null or model == null:
		return
	# Twins are explicit (Place in 3D / Place 3D twin) — never auto on boot.
	_conduit_manager = main_node.get_node_or_null("ConduitManager") as Node3D
	if _conduit_manager == null:
		_conduit_manager = _CONDUIT_MGR_SCRIPT.new()
		_conduit_manager.name = "ConduitManager"
		main_node.add_child(_conduit_manager)
	if _conduit_manager.has_method("setup"):
		_conduit_manager.call("setup", model, main_node)
	_ensure_conduit_route_ui(main_node)
	_wire_player_conduit_controller(main_node)


func _ensure_conduit_route_ui(main_node: Node) -> void:
	var ul := main_node.get_node_or_null("UILayer")
	if ul == null:
		return
	if ul.get_node_or_null("ConduitRouteUI") != null:
		return
	var ui := CanvasLayer.new()
	ui.name = "ConduitRouteUI"
	ui.set_script(load("res://scenes/ui/conduit_route_ui.gd") as Script)
	ul.add_child(ui)


func _wire_player_conduit_controller(main_node: Node) -> void:
	var player := main_node.get_node_or_null("Player")
	if player == null:
		return
	var ctrl := player.get_node_or_null("ConduitRouteController")
	if ctrl == null:
		return
	var ui := main_node.get_node_or_null("UILayer/ConduitRouteUI")
	# Always (re)bind manager — early wire with a null manager used to latch
	# `_conduit_route_wired` and leave LMB click/drag dead forever.
	if ctrl.has_method("setup") and _conduit_manager != null:
		var cam: Camera3D = player.get("camera") as Camera3D
		if cam == null:
			cam = player.get_node_or_null("Camera3D") as Camera3D
		ctrl.call("setup", player, cam, _conduit_manager, ui)
	if not _conduit_route_wired:
		if ctrl.has_signal("route_committed") \
				and not ctrl.is_connected("route_committed", _on_conduit_route_finished):
			ctrl.connect("route_committed", _on_conduit_route_finished)
		if ctrl.has_signal("route_cancelled") \
				and not ctrl.is_connected("route_cancelled", _on_conduit_route_finished):
			ctrl.connect("route_cancelled", _on_conduit_route_finished)
		_conduit_route_wired = true


func _get_conduit_manager() -> Node3D:
	if _conduit_manager == null or not is_instance_valid(_conduit_manager):
		_init_conduit_manager()
	return _conduit_manager


func _init_placeholder_host() -> void:
	var main_node := _get_scene_main_node()
	if main_node == null or model == null:
		return
	_placeholder_host = main_node.get_node_or_null("GraphPlaceholderHost") as Node3D
	if _placeholder_host == null:
		_placeholder_host = _PLACEHOLDER_HOST_SCRIPT.new()
		_placeholder_host.name = "GraphPlaceholderHost"
		main_node.add_child(_placeholder_host)
	if _placeholder_host.has_method("setup"):
		_placeholder_host.call("setup", model, main_node)
	if _placeholder_host.has_method("auto_link_battery_to_ibc"):
		if bool(_placeholder_host.call("auto_link_battery_to_ibc")):
			_schedule_graph_autosave()
	var mgr := _get_conduit_manager()
	if mgr != null and mgr.has_method("sync_all"):
		mgr.call("sync_all")


func _get_placeholder_host() -> Node3D:
	if _placeholder_host == null or not is_instance_valid(_placeholder_host):
		_init_placeholder_host()
	return _placeholder_host


func _spawn_3d_placeholder_for_item(item_id: String) -> void:
	if item_id.is_empty():
		_show_toast("Select a graph node first")
		return
	var host := _get_placeholder_host()
	if host == null or not host.has_method("spawn_placeholder_for_item"):
		_show_toast("3D placeholder host unavailable")
		return
	var path: String = str(host.call("spawn_placeholder_for_item", item_id))
	if path.is_empty():
		_show_toast("Could not spawn 3D placeholder")
		return
	_schedule_graph_autosave()
	var mgr := _get_conduit_manager()
	if mgr != null and mgr.has_method("sync_all"):
		mgr.call("sync_all")
	_show_toast("Linked 3D placeholder")
	if _inspector_panel != null and _inspector_panel.has_method("inspect_item"):
		var item := model.get_item(item_id) if model != null else {}
		if not item.is_empty():
			_inspector_panel.call("inspect_item", item, model)


func _on_spawn_3d_placeholder_pressed() -> void:
	var item_id := ""
	if _graph_canvas != null:
		item_id = str(_graph_canvas.get("selected_item_id"))
	_spawn_3d_placeholder_for_item(item_id)


## "Place in 3D" pressed in the inspector for a model-linked node (e.g. VAWT).
## Reconstructs the preset dict from the item's own specs and delegates to the
## same ghost-placement path used by the library-panel Place button — but passes
## `item_id` so confirm binds THIS node instead of spawning a duplicate.
func _place_model_for_item(item_id: String) -> void:
	if model == null or item_id.is_empty():
		_show_toast("Select a graph node first")
		return
	var item := model.get_item(item_id)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var model_id := str(specs.get("model_id", ""))
	if model_id.is_empty():
		_show_toast("This node has no linked 3D model")
		return
	# Build a minimal preset dict identical to what the library emits, then reuse
	# the same placement handler so both paths stay consistent.
	var preset := {
		"type": str(item.get("type", "wind")),
		"label": str(specs.get("name", item.get("type", "Turbine"))),
		"icon": "🌀",
		"width": float(item.get("width", 124.0)),
		"height": float(item.get("height", 112.0)),
		"specs": specs,
	}
	_on_lib_place_model_requested(preset, item_id)


func _start_conduit_route(conn_id: String) -> void:
	if model == null:
		return
	var conn := model.get_connection(conn_id)
	if conn.is_empty():
		return
	if not model.connection_is_3d_routable(conn):
		_show_toast("Link both nodes to 3D scene objects before routing.")
		return
	var mgr := _get_conduit_manager()
	if mgr == null:
		_show_toast("Conduit manager unavailable.")
		return
	var src := model.get_item(str(conn.get("source_item_id", "")))
	var tgt := model.get_item(str(conn.get("target_item_id", "")))
	var tree := get_tree()
	var main_for_anchor := _get_scene_main_node()
	var anchor_a: Vector3 = ConduitManager.anchor_global_for_item(
		src, tree, str(conn.get("source_handle_id", "")), main_for_anchor)
	var anchor_b: Vector3 = ConduitManager.anchor_global_for_item(
		tgt, tree, str(conn.get("target_handle_id", "")), main_for_anchor)
	if not is_finite(anchor_a.x) or not is_finite(anchor_b.x):
		_show_toast("Could not resolve 3D anchor positions.")
		return
	var type_id: String = ConduitKinds.derive_type_for_connection(conn)
	var main_node := _get_scene_main_node()
	if main_node == null:
		return
	_wire_player_conduit_controller(main_node)
	var player := main_node.get_node_or_null("Player")
	if player == null:
		return
	var ctrl := player.get_node_or_null("ConduitRouteController")
	if ctrl == null or not ctrl.has_method("begin_route"):
		_show_toast("Conduit route controller not ready.")
		return
	visible = false
	_apply_mouse_for_graph(false)
	var route: Array = conn.get("route_3d", []) as Array
	ctrl.call("begin_route", conn_id, anchor_a, anchor_b, type_id, route)
	_show_toast("Routing 3D conduit — LMB pin, Enter commit, Esc cancel")


func _clear_conduit_route(conn_id: String) -> void:
	var mgr := _get_conduit_manager()
	# Prefer autoroute reset (clears locked bends) so conceptual runs re-metro.
	if mgr != null and mgr.has_method("reset_autoroute"):
		mgr.call("reset_autoroute", conn_id)
	elif mgr != null and mgr.has_method("clear_route"):
		mgr.call("clear_route", conn_id)
	if model != null:
		var conn := model.get_connection(conn_id)
		if not conn.is_empty() and _inspector_panel != null \
				and _inspector_panel.has_method("inspect_connection"):
			_inspector_panel.call("inspect_connection", conn, model)
	_schedule_graph_autosave()


func _on_conduit_route_finished(_conn_id: String) -> void:
	_schedule_graph_autosave()
	if model != null and _inspector_panel != null \
			and _inspector_panel.has_method("inspect_connection"):
		var conn := model.get_connection(_conn_id)
		if not conn.is_empty():
			_inspector_panel.call("inspect_connection", conn, model)


## When opening the graph, use Test mode if the simulation clock is running, Build mode if paused.
func _apply_graph_open_mode_from_sim_state() -> void:
	var m := _get_scene_main_node()
	if m == null or m.get("time_scale") == null:
		_on_build_mode()
		return
	if float(m.time_scale) > 0.0:
		_on_test_mode()
	else:
		_on_build_mode()


# ---------------------------------------------------------------------------
# SolarUI discovery
# ---------------------------------------------------------------------------

func _refresh_solar_ui_ref() -> void:
	var root := get_tree().root
	if root:
		_solar_ui = root.get_node_or_null("Main/UILayer/SolarUI") as Control
	if not is_instance_valid(_solar_ui):
		var scene := get_tree().current_scene
		if scene:
			_solar_ui = scene.get_node_or_null("UILayer/SolarUI") as Control
	_populate_library_scene_devices()
	_populate_library_graph_linkables()


func _scene_device_path_on_graph(path_str: String) -> bool:
	if model == null or path_str.is_empty():
		return false
	for item: Dictionary in model.items:
		if bool(item.get("is_ghost", false)):
			continue
		var dev := str(item.get("device_path", ""))
		if dev == path_str:
			return true
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(specs.get("scene_device_path", "")) == path_str:
			return true
	return false


func _is_graph_proxy_consumer(consumer: Node) -> bool:
	if consumer == null:
		return true
	if consumer.get_script() != null:
		var scr := str(consumer.get_script().resource_path)
		if scr.ends_with("graph_sim_load.gd"):
			return true
	var p := consumer.get_parent()
	while p != null:
		if str(p.name) == "GraphSimLoadHost" or str(p.name) == "SystemGraphView":
			return true
		p = p.get_parent()
	return str(consumer.name).begins_with("SimLoad_")


## Build the "In Model" library shelf: scene power_consumers not yet on the graph.
func _populate_library_scene_devices() -> void:
	if _lib_panel == null:
		return
	if not _lib_panel.has_method("populate_in_model") and not _lib_panel.has_method("populate_scene_devices"):
		return
	if not is_instance_valid(_solar_ui):
		return
	var tree := _solar_ui.get_tree()
	if tree == null:
		return
	var consumers: Array[Node] = tree.get_nodes_in_group("power_consumers")
	consumers.sort_custom(func(a: Node, b: Node) -> bool:
		return str(a.get_path()) < str(b.get_path())
	)
	var presets: Array = []
	for consumer: Node in consumers:
		if consumer == null or not is_instance_valid(consumer):
			continue
		if _is_graph_proxy_consumer(consumer):
			continue
		if consumer.has_meta("graph_sim_load") and bool(consumer.get_meta("graph_sim_load")):
			continue
		var path_str := str(consumer.get_path())
		if _scene_device_path_on_graph(path_str):
			continue
		var nm: String = str(consumer.name)
		var max_w := 25.0
		var avg_w := 0.0
		if consumer is PowerDevice:
			var pd := consumer as PowerDevice
			nm    = pd.device_name
			max_w = pd.rated_power_watts
			avg_w = pd.get_current_power()
		else:
			if consumer.get("display_name") != null:
				nm = str(consumer.get("display_name"))
			if consumer.get("wattage") != null:
				max_w = float(consumer.get("wattage"))
			if consumer.has_method("get_current_power"):
				avg_w = float(consumer.call("get_current_power"))
		if nm.strip_edges().is_empty():
			nm = path_str.get_file()
		if nm.begins_with("SimLoad_") or nm.begins_with("@"):
			continue
		presets.append({
			"type":   "appliance",
			"label":  nm,
			"icon":   "🔌",
			"width":  160.0,
			"height": 104.0,
			"specs": {
				"name":              nm,
				"max_watts":         max_w,
				"avg_watts":         avg_w,
				"scene_device_path": path_str,
				"in_model":          true,
			},
		})
	if _lib_panel.has_method("populate_in_model"):
		_lib_panel.call("populate_in_model", presets)
	else:
		_lib_panel.call("populate_scene_devices", presets)


func _populate_library_graph_linkables() -> void:
	if _lib_panel == null or not _lib_panel.has_method("populate_graph_linkables"):
		return
	if not is_instance_valid(_solar_ui):
		return
	var tree := _solar_ui.get_tree()
	if tree == null:
		return
	var seen: Dictionary = {}
	var presets: Array = []
	for group_name: String in ["graph_linkable", "energy_sources"]:
		for node: Node in tree.get_nodes_in_group(group_name):
			if node == null or not is_instance_valid(node):
				continue
			var path_str: String = str(node.get_path())
			if seen.has(path_str):
				continue
			seen[path_str] = true
			var nm: String = str(node.name)
			if node.get("source_name") != null:
				nm = str(node.get("source_name"))
			elif node.get("display_name") != null:
				nm = str(node.get("display_name"))
			var gtype := "appliance"
			var icon := "🔌"
			if node is WindTurbineSource or str(node.get_script()).find("wind_turbine") >= 0:
				gtype = "wind"
				icon = "🌬"
			elif node is HydroSource or str(node.get_script()).find("hydro_source") >= 0:
				gtype = "hydro"
				icon = "💧"
			elif node is SolarPanelSource or str(node.get_script()).find("solar_calculator") >= 0:
				gtype = "panel"
				icon = "☀"
			presets.append({
				"type": gtype,
				"label": nm,
				"icon": icon,
				"width": 140.0,
				"height": 104.0,
				"specs": {
					"name": nm,
					"scene_device_path": path_str,
				},
			})
	if not presets.is_empty():
		_lib_panel.call("populate_graph_linkables", presets)


func _load_graph_ui_prefs() -> void:
	var cfg := ConfigFile.new()
	var legend_visible := false
	if cfg.load(_UI_PREFS_CFG) == OK:
		legend_visible = bool(cfg.get_value("graph", "legend_visible", false))
	if _graph_canvas != null and _graph_canvas.has_method("set_legend_visible"):
		_graph_canvas.call("set_legend_visible", legend_visible)
	_update_legend_btn()


func _save_graph_ui_prefs() -> void:
	var cfg := ConfigFile.new()
	cfg.load(_UI_PREFS_CFG)
	var on := false
	if _graph_canvas != null and _graph_canvas.has_method("is_legend_visible"):
		on = bool(_graph_canvas.call("is_legend_visible"))
	cfg.set_value("graph", "legend_visible", on)
	cfg.save(_UI_PREFS_CFG)


func _on_legend_toggle() -> void:
	if _graph_canvas == null or not _graph_canvas.has_method("set_legend_visible"):
		return
	var on := not bool(_graph_canvas.call("is_legend_visible"))
	_graph_canvas.call("set_legend_visible", on)
	_update_legend_btn()
	_save_graph_ui_prefs()


func _update_legend_btn() -> void:
	var on := false
	if _graph_canvas != null and _graph_canvas.has_method("is_legend_visible"):
		on = bool(_graph_canvas.call("is_legend_visible"))
	if _view_menu != null:
		var popup := _view_menu.get_popup()
		var idx := popup.get_item_index(VIEW_LEGEND)
		if idx >= 0:
			popup.set_item_checked(idx, on)


## Toggle the world PowerDevice bound to a virtual graph item.
## Called from _on_canvas_item_double_tapped when mode == "test".
func _try_toggle_device(item: Dictionary) -> void:
	var path_str: String = item.get("device_path", "") as String
	if path_str.is_empty():
		return
	# Absolute NodePath stored as string (e.g. "/root/Main/World/...")
	var node: Node = get_tree().root.get_node_or_null(NodePath(path_str))
	if node == null:
		_show_toast("Device not found in scene")
		return
	if not node.has_method("toggle"):
		_show_toast("Node has no toggle()")
		return
	node.call("toggle")
	var name_: String = item.get("specs", {}).get("name", "Device") as String
	# Report the SWITCH we just set (requested), not the momentary effective flag —
	# the resolved run state comes from the engine's node_state (below), so the
	# toast and the status chip can never contradict.
	var switch_on := false
	if node.get("_requested_on") != null:
		switch_on = bool(node.get("_requested_on"))
	elif node.get("current_state") != null:
		switch_on = int(node.get("current_state")) != 0
	elif node.get("is_on") != null:
		switch_on = bool(node.get("is_on"))
	var switch_lbl := "ON" if switch_on else "OFF"
	# Resolved run state (may lag up to one resource tick).
	var suffix := ""
	var iid: String = str(item.get("id", ""))
	if not iid.is_empty() and model != null:
		var ns := str((model.get_item(iid).get("specs", {}) as Dictionary).get("node_state", ""))
		match ns:
			GraphNodeState.RUNNING: suffix = " — running"
			GraphNodeState.BLOCKED: suffix = " — no power / blocked"
			GraphNodeState.READY: suffix = " — ready"
	_show_toast("%s: switched %s%s" % [name_, switch_lbl, suffix])
	# Force bridge to refresh device state immediately
	if _bridge != null:
		_bridge.call("tick", 1.0)


## Create (or reconnect) the SolarBridge when solar_ui becomes available.
func _init_bridge() -> void:
	if not is_instance_valid(_solar_ui):
		return
	if _bridge == null:
		_bridge = _BRIDGE_SCRIPT.new()
	_bridge.call("setup", model, _solar_ui)
	# Restore any user-deleted virtual IDs so the bridge does not re-create them.
	_bridge.suppressed_ids = _suppressed_virtuals


# ---------------------------------------------------------------------------
# Historical playback (HA history → graph scrubber)
# ---------------------------------------------------------------------------

const _HISTORY_HOURS_BACK := 72       # 3 days
const _HISTORY_SPEEDS: Array = [
	{"label": "60×",   "x": 60.0},
	{"label": "300×",  "x": 300.0},
	{"label": "1500×", "x": 1500.0},
	{"label": "3600×", "x": 3600.0},
]


func _ensure_history_player() -> void:
	if _history_player != null and is_instance_valid(_history_player):
		return
	var ha_client := _resolve_ha_client_node()
	_history_player = _HISTORY_PLAYER_SCRIPT.new()
	_history_player.name = "HistoryPlayer"
	add_child(_history_player)
	_history_player.call("setup", model, _ha_linker, ha_client)
	_history_player.state_changed.connect(_on_history_state_changed)
	_history_player.loading_progress.connect(_on_history_loading_progress)
	_history_player.data_ready.connect(_on_history_data_ready)
	_history_player.playback_progress.connect(_on_history_playback_progress)


func _resolve_ha_client_node() -> Node:
	var scene_tree := get_tree()
	if scene_tree == null:
		return null
	var direct := scene_tree.root.get_node_or_null("HAClient")
	if direct != null:
		return direct
	for c in scene_tree.root.get_children():
		var nested := c.get_node_or_null("HAClient")
		if nested != null:
			return nested
	return null


func _on_history_btn_pressed() -> void:
	_ensure_history_player()
	# Toggle: if a session is active, stop & hide.  Otherwise start a fresh
	# 3-day playback at 60× speed.
	var st: int = int(_history_player.call("get_state"))
	if st in [_history_player.State.PLAYING, _history_player.State.PAUSED,
			_history_player.State.LOADING, _history_player.State.READY]:
		_history_player.stop()
		_hide_history_panel()
		_set_view_menu_checked(VIEW_HISTORY, false)
		return
	_ensure_history_panel()
	_history_panel.visible = true
	_apply_layout()
	_history_player.start({
		"hours_back": _HISTORY_HOURS_BACK,
		"speed_x":    60.0,
	})
	if _history_status_lbl != null:
		_history_status_lbl.text = "Loading last %d h…" % _HISTORY_HOURS_BACK
	_set_view_menu_checked(VIEW_HISTORY, true)


func _set_view_menu_checked(id: int, on: bool) -> void:
	if _view_menu == null:
		return
	var popup := _view_menu.get_popup()
	var idx := popup.get_item_index(id)
	if idx >= 0:
		popup.set_item_checked(idx, on)


func _ensure_history_panel() -> void:
	if _history_panel != null and is_instance_valid(_history_panel):
		return
	_history_panel = PanelContainer.new()
	_history_panel.visible = false
	_history_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color              = Color(0.05, 0.07, 0.13, 0.98)
	sb.set_border_width(SIDE_TOP, 2)
	sb.border_color          = Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, 0.70)
	sb.content_margin_left   = 12.0
	sb.content_margin_right  = 12.0
	sb.content_margin_top    =  8.0
	sb.content_margin_bottom =  8.0
	_history_panel.add_theme_stylebox_override("panel", sb)
	add_child(_history_panel)

	# Three-zone layout: [left status | center controls | right speed+stop]
	var outer_hbox := HBoxContainer.new()
	outer_hbox.add_theme_constant_override("separation", 0)
	_history_panel.add_child(outer_hbox)

	# ── LEFT: icon + status label ──────────────────────────────────────────
	var left_zone := HBoxContainer.new()
	left_zone.add_theme_constant_override("separation", 8)
	left_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_zone.alignment = BoxContainer.ALIGNMENT_BEGIN
	outer_hbox.add_child(left_zone)

	var icon_lbl := Label.new()
	icon_lbl.text = "🕒"
	icon_lbl.add_theme_color_override("font_color", C_AMBER)
	icon_lbl.add_theme_font_size_override("font_size", 20)
	icon_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	left_zone.add_child(icon_lbl)

	var status_vbox := VBoxContainer.new()
	status_vbox.add_theme_constant_override("separation", 0)
	status_vbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	left_zone.add_child(status_vbox)

	var hist_title := Label.new()
	hist_title.text = "HA HISTORY PLAYBACK"
	hist_title.add_theme_color_override("font_color", Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, 0.95))
	hist_title.add_theme_font_size_override("font_size", 11)
	status_vbox.add_child(hist_title)

	_history_status_lbl = Label.new()
	_history_status_lbl.text = "Ready"
	_history_status_lbl.add_theme_color_override("font_color", C_TEXT_S)
	_history_status_lbl.add_theme_font_size_override("font_size", 13)
	_history_status_lbl.custom_minimum_size = Vector2(130.0, 0.0)
	status_vbox.add_child(_history_status_lbl)

	# ── CENTER: play + slider + time ───────────────────────────────────────
	var center_zone := HBoxContainer.new()
	center_zone.add_theme_constant_override("separation", 8)
	center_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_zone.alignment = BoxContainer.ALIGNMENT_CENTER
	outer_hbox.add_child(center_zone)

	_history_play_btn = _make_topbar_btn("⏸ Pause")
	_history_play_btn.custom_minimum_size = Vector2(96.0, 0.0)
	_restyle_btn_primary(_history_play_btn)
	_history_play_btn.pressed.connect(_on_history_play_pressed)
	center_zone.add_child(_history_play_btn)

	_history_slider = HSlider.new()
	_history_slider.min_value = 0.0
	_history_slider.max_value = 1.0
	_history_slider.step      = 0.0001
	_history_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_history_slider.custom_minimum_size   = Vector2(260.0, 28.0)
	_history_slider.drag_started.connect(_on_history_slider_drag_started)
	_history_slider.drag_ended.connect(_on_history_slider_drag_ended)
	_history_slider.value_changed.connect(_on_history_slider_value_changed)
	center_zone.add_child(_history_slider)

	_history_time_lbl = Label.new()
	_history_time_lbl.text = "——"
	_history_time_lbl.add_theme_color_override("font_color", C_TEXT)
	_history_time_lbl.add_theme_font_size_override("font_size", 13)
	_history_time_lbl.custom_minimum_size     = Vector2(184.0, 0.0)
	_history_time_lbl.horizontal_alignment    = HORIZONTAL_ALIGNMENT_CENTER
	_history_time_lbl.vertical_alignment      = VERTICAL_ALIGNMENT_CENTER
	center_zone.add_child(_history_time_lbl)

	# ── RIGHT: speed + stop ────────────────────────────────────────────────
	var right_zone := HBoxContainer.new()
	right_zone.add_theme_constant_override("separation", 6)
	right_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_zone.alignment = BoxContainer.ALIGNMENT_END
	outer_hbox.add_child(right_zone)

	var speed_lbl := Label.new()
	speed_lbl.text = "Speed"
	speed_lbl.add_theme_color_override("font_color", C_TEXT_S)
	speed_lbl.add_theme_font_size_override("font_size", 11)
	speed_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	right_zone.add_child(speed_lbl)

	_history_speed_opt = OptionButton.new()
	_history_speed_opt.focus_mode = Control.FOCUS_NONE
	_history_speed_opt.add_theme_font_size_override("font_size", 13)
	_history_speed_opt.custom_minimum_size = Vector2(90.0, 0.0)
	for i: int in _HISTORY_SPEEDS.size():
		_history_speed_opt.add_item(str(_HISTORY_SPEEDS[i].get("label", "")), i)
	_history_speed_opt.select(0)
	_history_speed_opt.item_selected.connect(_on_history_speed_changed)
	right_zone.add_child(_history_speed_opt)

	_history_stop_btn = _make_topbar_btn("■ Stop")
	_restyle_btn_amber(_history_stop_btn)
	_history_stop_btn.pressed.connect(_on_history_stop_pressed)
	right_zone.add_child(_history_stop_btn)


func _hide_history_panel() -> void:
	if _history_panel != null and is_instance_valid(_history_panel):
		_history_panel.visible = false
	_apply_layout()


func _layout_history_panel() -> void:
	if _history_panel == null or not is_instance_valid(_history_panel) \
			or not _history_panel.visible:
		return
	var left_w  := SIDEBAR_L_W if _sidebar_l_open else 0.0
	var right_w := SIDEBAR_R_W if _sidebar_r_open else 0.0
	var timeline_inset := _timeline_bottom_inset()
	_anchor(_history_panel, 0.0, 1.0, 1.0, 1.0,
		left_w, -(timeline_inset + HISTORY_PANEL_H), -right_w, -timeline_inset)


func _timeline_bottom_inset() -> float:
	_ensure_timeline_inset_hook()
	var ul := get_parent()
	if ul != null:
		var tl := ul.get_node_or_null("TimelineUI")
		if tl != null and tl.has_method("get_stack_height"):
			var h := float(tl.call("get_stack_height"))
			# Prefer live height; never undershoot the shared fallback.
			return maxf(h, UiScreenLayout.timeline_stack_height())
	return UiScreenLayout.timeline_stack_height()


func _ensure_timeline_inset_hook() -> void:
	if _timeline_inset_hooked:
		return
	var ul := get_parent()
	if ul == null:
		return
	var tl := ul.get_node_or_null("TimelineUI")
	if tl == null:
		return
	if tl.has_signal("stack_height_changed") \
			and not tl.is_connected("stack_height_changed", _on_timeline_stack_height_changed):
		tl.connect("stack_height_changed", _on_timeline_stack_height_changed)
	_timeline_inset_hooked = true


func _on_timeline_stack_height_changed(_height: float) -> void:
	if visible:
		_apply_layout()


func _set_graph_companion_ui_visible(graph_open: bool) -> void:
	var ul := get_parent()
	if ul == null:
		return
	var terrain_opts := ul.get_node_or_null("TerrainOptionsUI")
	if terrain_opts is CanvasItem:
		(terrain_opts as CanvasItem).visible = not graph_open


func _on_history_state_changed(s: int) -> void:
	if _history_player == null:
		return
	if _history_play_btn != null:
		match s:
			_history_player.State.PLAYING:
				_history_play_btn.text = "⏸ Pause"
			_history_player.State.PAUSED, _history_player.State.READY:
				_history_play_btn.text = "▶ Play"
			_history_player.State.LOADING:
				_history_play_btn.text = "…"
			_history_player.State.STOPPED, _history_player.State.IDLE:
				_history_play_btn.text = "▶ Play"
	if _history_status_lbl != null:
		match s:
			_history_player.State.LOADING:
				pass   # progress label handled by _on_history_loading_progress
			_history_player.State.READY:
				_history_status_lbl.text = "Ready"
			_history_player.State.PLAYING:
				_history_status_lbl.text = "Playing %.0f×" % _history_player.get_speed()
			_history_player.State.PAUSED:
				_history_status_lbl.text = "Paused"
			_history_player.State.STOPPED:
				_history_status_lbl.text = "Stopped"


func _on_history_loading_progress(loaded: int, total: int) -> void:
	if _history_status_lbl != null:
		_history_status_lbl.text = "Loading %d / %d" % [loaded, total]


func _on_history_data_ready(start_t: int, end_t: int) -> void:
	if _history_time_lbl != null:
		_history_time_lbl.text = "%s … %s" % [
			Time.get_datetime_string_from_unix_time(start_t),
			Time.get_datetime_string_from_unix_time(end_t),
		]


func _on_history_playback_progress(cursor_t: int, fraction: float) -> void:
	if _history_user_seeking:
		return   # user is dragging — don't fight them
	if _history_slider != null:
		# value_changed is connected; suppress feedback by checking the flag
		# in the handler.  Use set_value_no_signal? HSlider supports it.
		_history_slider.set_value_no_signal(fraction)
	if _history_time_lbl != null:
		_history_time_lbl.text = Time.get_datetime_string_from_unix_time(cursor_t)


func _on_history_play_pressed() -> void:
	if _history_player == null:
		return
	_history_player.toggle_play()


func _on_history_stop_pressed() -> void:
	if _history_player != null:
		_history_player.stop()
	_hide_history_panel()


func _on_history_speed_changed(idx: int) -> void:
	if _history_player == null:
		return
	if idx < 0 or idx >= _HISTORY_SPEEDS.size():
		return
	var x: float = float(_HISTORY_SPEEDS[idx].get("x", 60.0))
	_history_player.set_speed(x)
	# Refresh status text
	_on_history_state_changed(int(_history_player.call("get_state")))


func _on_history_slider_drag_started() -> void:
	_history_user_seeking = true


func _on_history_slider_drag_ended(_value_changed: bool) -> void:
	_history_user_seeking = false
	if _history_player != null:
		_history_player.seek(_history_slider.value)


func _on_history_slider_value_changed(_v: float) -> void:
	# Scrub instantly while dragging so the user gets feedback.
	if _history_user_seeking and _history_player != null:
		_history_player.seek(_history_slider.value)


# ---------------------------------------------------------------------------
# Mouse-capture management  (preserves existing 3D camera behaviour)
# ---------------------------------------------------------------------------

func _apply_mouse_for_graph(graph_open: bool) -> void:
	_set_graph_companion_ui_visible(graph_open)
	if graph_open:
		CursorController.request_modal("system_graph")
	else:
		CursorController.release_modal("system_graph")


func _other_ui_needs_free_mouse() -> bool:
	var ul := get_parent()
	if ul == null:
		return false
	var time_ui := ul.get_node_or_null("TimeUI")
	if time_ui != null and time_ui.get("ui_visible") == true:
		return true
	var sl := ul.get_node_or_null("SaveLoadUI")
	if sl != null and sl.has_method("is_panel_visible") and sl.is_panel_visible():
		return true
	var go_ui := ul.get_node_or_null("GameOverUI")
	if go_ui is CanvasItem and (go_ui as CanvasItem).visible:
		return true
	var ha_conn := ul.get_node_or_null("HAConnectionUI")
	if ha_conn is Control and (ha_conn as Control).visible:
		return true
	return false


# ---------------------------------------------------------------------------
# Model events
# ---------------------------------------------------------------------------

func _on_model_changed(reason: String) -> void:
	if _sim_bulk_update:
		# Defer — a sim tick can call update_item dozens of times; coalesce into
		# one redraw + one telemetry refresh via _flush_sim_bulk_update().
		_pending_canvas_redraw = true
		_pending_telemetry_refresh = true
		# Pond twin: coalesce mesh push while sim integrates tank levels.
		_schedule_pond_twin_push()
	else:
		if _graph_canvas != null:
			_graph_canvas.call("queue_redraw")
		_refresh_telemetry()
		if reason == "update_item" or reason == "reset":
			_schedule_pond_twin_push()
		# The Site Plan's unplaced tray is gone — a node added while the plan
		# is open is seated on the disc immediately instead of landing
		# invisible (entry already seeds; this covers live adds). Recurses one
		# level as "update_item", which takes the branch above.
		if reason == "add_item" and visible \
				and _graph_view_mode == GraphSiteLayout.VIEW_SITE:
			_auto_seed_site_unplaced()
		_sync_solar_ui_from_graph()
		_sync_graph_controller_ac_fault()
		call_deferred("_populate_library_scene_devices")
	if reason in ["add_connection", "remove_connection", "update_connection"]:
		call_deferred("_check_electrical_faults")
	elif not _sim_bulk_update and reason in ["add_item", "remove_item", "update_item", "reset"]:
		# Item-level edits (battery voltage in the inspector, deletions, loads)
		# can change bank topology without touching a connection — drop the DC
		# cache so the next throttle tick rebuilds it. Sim-tick telemetry writes
		# run under _sim_bulk_update and never invalidate.
		_dc_analysis = {}
	# SketchUp-style live component propagation: a structural edit made INSIDE a
	# component instance (the active scope sits within one) recaptures that
	# instance's definition and re-stamps its siblings. Skipped while a restamp is
	# already running, during load/undo, and during sim bulk ticks.
	if not _component_sync_active and not _history_suppress and not _sim_bulk_update \
			and reason in _COMPONENT_SYNC_REASONS:
		var inst := _innermost_instance_for_scope(_active_scope_id)
		if not inst.is_empty():
			request_component_sync(inst)
	# Record structural user changes in the undo history
	if _history != null and _history_initialized and not _history_suppress:
		if reason in HISTORY_REASONS:
			_push_history()
			_update_undo_redo_btns()
		if GRAPH_AUTOSAVE_REASONS.has(reason):
			_schedule_graph_autosave()
	# Phase 4 live multiplayer design sync (debounced on MultiplayerSession).
	if not Engine.is_editor_hint() and not _history_suppress and not _sim_bulk_update \
			and MultiplayerSession != null and MultiplayerSession.has_method("notify_graph_edited") \
			and MultiplayerSession.has_method("is_active") and MultiplayerSession.is_active():
		MultiplayerSession.notify_graph_edited(reason)


## Runs the redraw/telemetry work _on_model_changed deferred while
## _sim_bulk_update was set, exactly once, covering every model.update_item
## call made during the tick block. No-op if nothing changed this tick.
## `force_telemetry` (≈1 Hz) runs the expensive dashboard/library rescans;
## canvas redraw still flushes every tick when pending (animation owns most
## redraws via graph_canvas.tick anyway).
func _flush_sim_bulk_update(force_telemetry: bool = true) -> void:
	if not _pending_canvas_redraw and not _pending_telemetry_refresh \
			and not _pending_library_populate:
		return
	if _pending_canvas_redraw and _graph_canvas != null:
		_graph_canvas.call("queue_redraw")
	_pending_canvas_redraw = false
	if _pending_telemetry_refresh:
		_pending_library_populate = true
		if force_telemetry:
			_refresh_telemetry()
			_sync_solar_ui_from_graph()
			_sync_graph_controller_ac_fault()
			_pending_telemetry_refresh = false
	if force_telemetry and _pending_library_populate:
		call_deferred("_populate_library_scene_devices")
		_pending_library_populate = false


# ---------------------------------------------------------------------------
# Component (super-node) live propagation
# ---------------------------------------------------------------------------

## Model-change reasons that count as a structural interior edit worth
## propagating across instances of a component definition.
const _COMPONENT_SYNC_REASONS := [
	"add_item", "remove_item", "update_item",
	"add_connection", "remove_connection", "update_connection",
]


## Walk up from `scope_id` and return the innermost compound INSTANCE (one bound
## to a definition) that owns an ancestor scope, or "" if the edit is not inside
## any component instance.
func _innermost_instance_for_scope(scope_id: String) -> String:
	if model == null or scope_id.is_empty() or scope_id == "root":
		return ""
	var s := scope_id
	var guard := 0
	while not s.is_empty() and s != "root" and guard < 64:
		guard += 1
		var sc := model.get_scope(s)
		var owner := str(sc.get("owner_compound_id", ""))
		if not owner.is_empty():
			var it := model.get_item(owner)
			if GraphComponentDefs.is_instance(it):
				return owner
		s = str(sc.get("parent_scope_id", ""))
	return ""


## Queue a debounced capture+restamp for `instance_id` (public so authoring/
## inspector port edits can trigger propagation explicitly).
func request_component_sync(instance_id: String) -> void:
	if instance_id.is_empty():
		return
	_component_sync_pending[instance_id] = true
	if _component_sync_timer != null:
		_component_sync_timer.start()


## Run every queued component sync: capture each instance's definition, then
## re-stamp all OTHER instances of that definition. Loop-safe via the guard.
func _flush_component_sync() -> void:
	if model == null or _component_sync_pending.is_empty():
		return
	var pending := _component_sync_pending.keys()
	_component_sync_pending.clear()
	_component_sync_active = true
	_history_suppress = true
	var synced_defs: Dictionary = {}
	for inst_v in pending:
		var inst_id := str(inst_v)
		var it := model.get_item(inst_id)
		if not GraphComponentDefs.is_instance(it):
			continue
		var def_id := GraphComponentDefs.capture(model, inst_id)
		if def_id.is_empty() or synced_defs.has(def_id):
			continue
		synced_defs[def_id] = true
		for other in model.instances_of_definition(def_id):
			var oid := str((other as Dictionary).get("id", ""))
			if oid != inst_id:
				GraphComponentDefs.restamp(model, oid)
	_history_suppress = false
	_component_sync_active = false
	if not synced_defs.is_empty():
		if _graph_canvas != null:
			_graph_canvas.call("queue_redraw")
		_schedule_graph_autosave()


# ---------------------------------------------------------------------------
# Undo / Redo  (Phase 14)
# ---------------------------------------------------------------------------

## Save the current model state onto the undo stack.
func _push_history() -> void:
	if _history == null or model == null:
		return
	_history.call("push", model.serialize())


## Restore the previous model state.
func _do_undo() -> void:
	if _history == null:
		return
	var snap: Dictionary = _history.call("undo") as Dictionary
	if snap.is_empty():
		_show_toast("Nothing to undo", 1.5)
		return
	_history_suppress = true
	model.deserialize(snap)
	_history_suppress = false
	if _graph_canvas != null:
		_graph_canvas.call("queue_redraw")
	_refresh_telemetry()
	_update_undo_redo_btns()
	_show_toast("Undo", 1.2)


## Restore the next model state (after an undo).
func _do_redo() -> void:
	if _history == null:
		return
	var snap: Dictionary = _history.call("redo") as Dictionary
	if snap.is_empty():
		_show_toast("Nothing to redo", 1.5)
		return
	_history_suppress = true
	model.deserialize(snap)
	_history_suppress = false
	if _graph_canvas != null:
		_graph_canvas.call("queue_redraw")
	_refresh_telemetry()
	_update_undo_redo_btns()
	_show_toast("Redo", 1.2)


## Refresh the disabled / enabled visual state of the Undo and Redo buttons.
func _update_undo_redo_btns() -> void:
	if _history == null:
		return
	if _undo_btn != null:
		_undo_btn.disabled = not bool(_history.call("can_undo"))
		_undo_btn.modulate = Color(1, 1, 1, 0.45 if _undo_btn.disabled else 1.0)
	if _redo_btn != null:
		_redo_btn.disabled = not bool(_history.call("can_redo"))
		_redo_btn.modulate = Color(1, 1, 1, 0.45 if _redo_btn.disabled else 1.0)


# ---------------------------------------------------------------------------
# Build-mode telemetry & cost  (Phase 10)
# ---------------------------------------------------------------------------

func _refresh_telemetry() -> void:
	if model == null:
		return

	# ── Aggregate panels ────────────────────────────────────────────────────
	var agg := _collect_root_array_aggregate()
	var panel_wmp:     float = float(agg.get("panel_wmp", 0.0))
	var panel_voc_max: float = float(agg.get("panel_voc_max", 0.0))
	var panel_imp:     float = float(agg.get("panel_imp", 0.0))
	var panel_count:   int   = int(agg.get("panel_count", 0))

	# ── Aggregate batteries ─────────────────────────────────────────────────
	var bat_kwh:   float = 0.0
	var bat_v_set: Array = []     # unique voltages seen

	# ── Aggregate controllers ────────────────────────────────────────────────
	var ctrl_max_watts: float = 0.0

	# ── Cost buckets ─────────────────────────────────────────────────────────
	var cost_panels:      float = 0.0
	var cost_controllers: float = 0.0
	var cost_batteries:   float = 0.0
	var cost_components:  float = 0.0

	for item: Dictionary in GraphNesting.walk_items(model, "root"):
		if bool(item.get("is_virtual", false)):
			continue
		var itype: String    = item.get("type",  "") as String
		var specs: Dictionary = item.get("specs", {})
		var cost: float      = float(specs.get("cost", 0.0))
		# Crated gear: cost counts (you own it), capacity does not.
		var packed: bool     = bool(specs.get("packed_3d", false))

		match itype:
			"panel":
				cost_panels += cost
			"compound":
				if str(specs.get("compound_kind", "")) == "array":
					cost_panels += cost

			"battery", "smartbattery":
				if not packed:
					bat_kwh     += float(specs.get("kwh",     0.0))
					var bv: float = float(specs.get("voltage", 0.0))
					if bv > 0.0 and not bat_v_set.has(bv):
						bat_v_set.append(bv)
				cost_batteries += cost

			"controller":
				if not packed:
					ctrl_max_watts += float(specs.get("max_pv_watts", 0.0))
				cost_controllers += cost

			_:
				cost_components += cost

	# Wire costs
	var cost_wires: float = 0.0
	for conn: Dictionary in model.connections:
		cost_wires += float(conn.get("total_wire_cost", 0.0))

	var cost_total: float = cost_panels + cost_controllers + cost_batteries + cost_components + cost_wires

	# ── Derived metrics ──────────────────────────────────────────────────────

	# Optimization: how much of controller capacity is filled by panels
	var optimization: float = 0.0
	if ctrl_max_watts > 0.0:
		optimization = minf(100.0, (panel_wmp / ctrl_max_watts) * 100.0)

	# Battery voltage string
	var bat_v_str: String
	match bat_v_set.size():
		0: bat_v_str = "—"
		1: bat_v_str = "%.0fV" % float(bat_v_set[0])
		_: bat_v_str = "Mixed"

	# Battery config: count × voltage (or kWh if voltages differ)
	var bat_count: int = 0
	for item: Dictionary in GraphNesting.walk_items(model, "root"):
		if bool(item.get("is_virtual", false)):
			continue
		if item.get("type", "") in ["battery", "smartbattery"]:
			bat_count += 1
	var bat_config: String
	if bat_count == 0:
		bat_config = "—"
	elif bat_v_set.size() == 1:
		bat_config = "%d × %.0fV" % [bat_count, float(bat_v_set[0])]
	else:
		bat_config = "%d batteries" % bat_count

	# Array config: panel count
	var array_config: String = str(agg.get("array_config", "—"))

	# ── Update telemetry labels ──────────────────────────────────────────────
	_set_score("scoreArrayWmp",      "%.0f W"  % panel_wmp if panel_count > 0 else "—")
	_set_score("scoreArrayVoc",      "%.1f V"  % panel_voc_max if panel_count > 0 else "—")
	_set_score("scoreArrayImp",      "%.2f A"  % panel_imp if panel_count > 0 else "—")
	_set_score("scoreArrayConfig",   array_config)
	_set_score("scoreBattery",       "%.2f kWh" % bat_kwh if bat_count > 0 else "—")
	_set_score("scoreBatteryConfig", bat_config)
	_set_score("scoreBatteryVoltage",bat_v_str)

	var opt_str: String = "%.0f %%" % optimization if ctrl_max_watts > 0.0 else "—"
	_set_score("scoreOptimization",  opt_str)
	_set_score_color("scoreOptimization",
		C_AMBER if optimization >= 100.0
		else (C_PRIMARY if optimization >= 70.0 else C_TEXT_M))

	_set_score("scoreTotalCost", "$%.0f" % cost_total)

	# ── Update cost labels ───────────────────────────────────────────────────
	_set_score("costPanels",      "$%.2f" % cost_panels)
	_set_score("costInverter",    "$%.2f" % cost_controllers)
	_set_score("costBatteries",   "$%.2f" % cost_batteries)
	_set_score("costComponents",  "$%.2f" % cost_components)
	_set_score("costWires",       "$%.2f" % cost_wires)
	_set_score("costTotal",       "$%.2f" % cost_total)

	var soi_svc := get_node_or_null("/root/SoiService")
	if _soi_chip != null:
		if soi_svc != null and soi_svc.has_method("radius_m"):
			var r: float = soi_svc.radius_m()
			var km2: float = soi_svc.area_m2() / 1_000_000.0
			_soi_chip.text = "🌐 SoI %d m · %.2f km²" % [int(round(r)), km2]
			_soi_chip.add_theme_color_override("font_color", C_PRIMARY)
		else:
			_soi_chip.text = "🌐 SoI · —"
			_soi_chip.add_theme_color_override("font_color", C_TEXT_S)

	_refresh_closure_telemetry()


## Public API for TimelineUI Needs strip / challenges.
func compute_closure_metrics() -> Dictionary:
	var abs_h := _closure_abs_hours()
	var etl: RefCounted = null
	if is_instance_valid(_solar_ui):
		var et: Variant = _solar_ui.get("energy_timeline")
		if et is RefCounted:
			etl = et as RefCounted
	return _CLOSURE_METRICS_SCRIPT.compute(model, _resource_flow, etl, abs_h)


## Idempotent puzzle starter (habitat + tanks + SoI catchments). Called on challenge start.
## `power_only` seeds AC + grid import only (Mission 1).
func try_seed_puzzle_starter(occupants: int = 1, power_only: bool = false) -> bool:
	if model == null:
		return false
	if not PuzzleStarterGraphSeeder.seed_graph(model, occupants, power_only):
		return false
	if _resource_flow != null:
		_resource_flow.setup(model, self)
	_schedule_graph_autosave()
	if _graph_canvas != null:
		_graph_canvas.call("queue_redraw")
	_refresh_closure_telemetry()
	_show_toast("Starter habitat graph seeded — wire imports to close the loop")
	return true


func _closure_abs_hours() -> float:
	var main_node := _get_scene_main_node()
	if main_node != null and main_node.has_method("get_absolute_hours"):
		return float(main_node.call("get_absolute_hours"))
	return 0.0


func _refresh_closure_telemetry() -> void:
	var m: Dictionary = compute_closure_metrics()
	var main_node := _get_scene_main_node()
	var lat := 0.0
	var lon := 0.0
	if main_node != null:
		lat = float(main_node.get("latitude")) if main_node.get("latitude") != null else 0.0
		lon = float(main_node.get("longitude")) if main_node.get("longitude") != null else 0.0
	_HIGH_SCORE_STORE_SCRIPT.record_if_best(lat, lon, "", float(m.get("score", 0.0)), {
		"mean_closure_pct": float(m.get("mean_closure_pct", 0.0)),
		"autonomy_person_days": float(m.get("autonomy_person_days", 0.0)),
	})
	if is_instance_valid(_graph_dashboard):
		_graph_dashboard.refresh(true)


func _set_score(key: String, value: String) -> void:
	if _score_labels.has(key):
		(_score_labels[key] as Label).text = value


func _set_score_color(key: String, color: Color) -> void:
	if _score_labels.has(key):
		(_score_labels[key] as Label).add_theme_color_override("font_color", color)


func _collect_root_array_aggregate() -> Dictionary:
	var panel_wmp: float = 0.0
	var panel_imp: float = 0.0
	var panel_count: int = 0
	if model == null:
		return {"panel_wmp": 0.0, "panel_voc_max": 0.0, "panel_imp": 0.0, "panel_count": 0, "array_config": "—"}
	for item: Dictionary in GraphNesting.walk_items(model, "root"):
		if bool(item.get("is_virtual", false)):
			continue
		var itype := str(item.get("type", ""))
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		# Packed (crated) items contribute no capacity until unpacked — same
		# rule as stowed linkage arrays below.
		if bool(specs.get("packed_3d", false)):
			continue
		if itype == "panel":
			panel_wmp += float(specs.get("wmp", 0.0))
			panel_imp += float(specs.get("imp", 0.0))
			panel_count += int(specs.get("panel_count", 1.0))
		elif itype == "compound" and str(specs.get("compound_kind", "")) == "array":
			# Stowed (folded) linkage structures keep their node/wiring but
			# contribute no capacity until redeployed.
			if bool(specs.get("array_stowed", false)):
				continue
			panel_wmp += float(specs.get("array_equiv_wmp", 0.0))
			panel_imp += float(specs.get("array_equiv_imp", 0.0))
			panel_count += int(specs.get("array_panel_units", specs.get("child_count", 0)))
	# Voc is NOT additive across the whole design the way Wmp/Imp/count are —
	# it's a per-STRING figure that depends entirely on series vs. parallel
	# wiring. Reporting each panel's own rated Voc here (as this used to) reads
	# a fixed 40 V for four identical panels regardless of how they're wired —
	# exactly the confusion a series-vs-parallel curriculum exists to resolve.
	# So this walks the same wired-topology math the controller fault check
	# uses (PvElectrical.branch_vocs_for_controller_flat): the worst branch Voc
	# actually feeding any controller right now — i.e. the number that would
	# blow one up.
	var panel_voc_max: float = 0.0
	var flat_conns := GraphNesting.flat_connections(model)
	for ctrl_item: Dictionary in GraphNesting.walk_items(model, "root"):
		if str(ctrl_item.get("type", "")) != "controller":
			continue
		var cid := str(ctrl_item.get("id", ""))
		for bv in PvElectrical.branch_vocs_for_controller_flat(model, cid, flat_conns, 25.0):
			panel_voc_max = maxf(panel_voc_max, float(bv))
	var cfg := "%d panel%s" % [panel_count, "s" if panel_count != 1 else ""] if panel_count > 0 else "—"
	return {
		"panel_wmp": panel_wmp,
		"panel_voc_max": panel_voc_max,
		"panel_imp": panel_imp,
		"panel_count": panel_count,
		"array_config": cfg,
	}


func _collect_battery_aggregate() -> Dictionary:
	var bat_kwh: float = 0.0
	var bat_count: int = 0
	if model == null:
		return {"total_kwh": 0.0, "count": 0}
	for item: Dictionary in GraphNesting.walk_items(model, "root"):
		if bool(item.get("is_virtual", false)):
			continue
		var itype := str(item.get("type", ""))
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		match itype:
			"battery", "smartbattery":
				bat_kwh += float(specs.get("kwh", 0.0))
				bat_count += 1
			"compound":
				if str(specs.get("compound_kind", "")) == "battery_bank":
					bat_kwh += float(specs.get("bank_total_kwh", specs.get("kwh", 0.0)))
					bat_count += int(specs.get("child_count", 1))
	return {"total_kwh": bat_kwh, "count": bat_count}


func _average_graph_battery_soc() -> float:
	if model == null:
		return -1.0
	var weighted := 0.0
	var total_kwh := 0.0
	for item: Dictionary in GraphNesting.walk_items(model, "root"):
		if bool(item.get("is_virtual", false)):
			continue
		var itype := str(item.get("type", ""))
		if itype not in ["battery", "smartbattery"]:
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		# A crated battery is not part of the bank — its SOC must not drag
		# the displayed average.
		if bool(specs.get("packed_3d", false)):
			continue
		var kwh := float(specs.get("kwh", 0.0))
		if kwh <= 0.0:
			continue
		weighted += kwh * clampf(float(specs.get("soc", 0.5)), 0.0, 1.0)
		total_kwh += kwh
	if total_kwh <= 0.0:
		return -1.0
	return weighted / total_kwh


## Keep graph panel output + battery SOC aligned with the canonical SolarUI bank.
func _sync_graph_energy_from_solar() -> void:
	if model == null or _solar_ui == null or not is_instance_valid(_solar_ui):
		return
	var solar_kw := maxf(0.0, float(_solar_ui.get("current_solar_kw") if _solar_ui.get("current_solar_kw") != null else 0.0))
	var cap := maxf(0.0, float(_solar_ui.get("BATTERY_CAPACITY_KWH") if _solar_ui.get("BATTERY_CAPACITY_KWH") != null else 0.0))
	var stored := maxf(0.0, float(_solar_ui.get("battery_kwh_stored") if _solar_ui.get("battery_kwh_stored") != null else 0.0))
	var bank_soc := clampf(stored / cap, 0.0, 1.0) if cap > 0.0 else 0.0

	# Publish the real battery flow to the canvas so wire animation uses
	# SolarUI's balance instead of the |net|*0.95 heuristic.
	if _graph_canvas != null:
		var load_kw := maxf(0.0, float(_solar_ui.get("current_load_kw") if _solar_ui.get("current_load_kw") != null else 0.0))
		var aux_kw := maxf(0.0, float(_solar_ui.get("current_aux_generation_kw") if _solar_ui.get("current_aux_generation_kw") != null else 0.0))
		var graph_dc_kw := maxf(0.0, float(_solar_ui.get("current_graph_dc_kw") if _solar_ui.get("current_graph_dc_kw") != null else 0.0))
		_graph_canvas.set("live_power_hint", {
			"battery_w": (solar_kw + aux_kw + graph_dc_kw - load_kw) * 1000.0,
			"valid": true,
		})

	var panel_items: Array[Dictionary] = []
	var total_wmp := 0.0
	for item: Dictionary in GraphNesting.walk_items(model, "root"):
		if bool(item.get("is_virtual", false)):
			continue
		if str(item.get("type", "")) != "panel":
			continue
		panel_items.append(item)
		total_wmp += float((item.get("specs", {}) as Dictionary).get("wmp", 0.0))

	if not panel_items.is_empty():
		var per_kw := solar_kw / float(panel_items.size()) if total_wmp <= 0.0 else 0.0
		for item: Dictionary in panel_items:
			var iid: String = str(item.get("id", ""))
			var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
			var share := per_kw
			if total_wmp > 0.0:
				share = solar_kw * float(specs.get("wmp", 0.0)) / total_wmp
			# Per-node shade / availability (default 1.0 ambient). Phase 5 writes
			# 3D site shade into specs.sunlight_factor; SolarUI's own battery math
			# stays unmodulated (panel authority = modulate graph share only).
			var had_sun_f: bool = specs.has("sunlight_factor")
			var sun_f: float = 1.0
			if had_sun_f:
				sun_f = clampf(float(specs.get("sunlight_factor", 1.0)), 0.0, 1.2)
			share *= sun_f
			if had_sun_f \
					and absf(float(specs.get("current_output_kw", 0.0)) - share) < 0.0005:
				continue
			specs["current_output_kw"] = share
			specs["sunlight_factor"] = sun_f
			model.update_item(iid, {"specs": specs})

	for item: Dictionary in GraphNesting.walk_items(model, "root"):
		if bool(item.get("is_virtual", false)):
			continue
		var itype := str(item.get("type", ""))
		if itype not in ["battery", "smartbattery"]:
			continue
		var iid: String = str(item.get("id", ""))
		var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		if absf(float(specs.get("soc", -1.0)) - bank_soc) < 0.0005:
			continue
		specs["soc"] = bank_soc
		model.update_item(iid, {"specs": specs})


## Sums live DC-electricity generation (fuel generators, graph-only wind/
## hydro) that's actually wired into a root-scope battery, and pushes it into
## SolarUI so it rides the same reversible EnergyTimeline SOC integrator as
## real solar/aux generation instead of writing battery SOC directly. See
## system_graph/dc_power_wiring.gd for the wiring trace.
func _sync_graph_dc_generation_to_solar() -> void:
	if model == null or _solar_ui == null or not is_instance_valid(_solar_ui):
		return
	var kw: float = _DC_POWER_WIRING_SCRIPT.sum_graph_dc_generation_kw(model)
	if _solar_ui.has_method("set_graph_dc_generation_kw"):
		_solar_ui.call("set_graph_dc_generation_kw", kw)


func _sync_solar_ui_from_graph() -> void:
	if _solar_ui == null or not is_instance_valid(_solar_ui):
		return
	var agg := _collect_root_array_aggregate()
	var bat := _collect_battery_aggregate()
	var panel_count := int(agg.get("panel_count", 0))
	var panel_wmp := float(agg.get("panel_wmp", 0.0))
	var avg_watts := panel_wmp / float(panel_count) if panel_count > 0 else 220.0
	var bank_soc := _average_graph_battery_soc()
	if _solar_ui.has_method("apply_from_graph"):
		_solar_ui.call("apply_from_graph", {
			"panel_count": panel_count,
			"panel_watts": avg_watts,
			"peak_kw": panel_wmp / 1000.0,
			"battery_kwh": float(bat.get("total_kwh", 0.0)),
			"battery_count": int(bat.get("count", 0)),
			"battery_soc": bank_soc,
		})
	if _solar_ui.has_method("set_graph_has_solar"):
		_solar_ui.call("set_graph_has_solar", panel_count > 0)
	_sync_graph_energy_from_solar()




# ---------------------------------------------------------------------------
# Save / Load  (matches solar_ui pattern used in main.gd)
# ---------------------------------------------------------------------------

## Seed the canvas's per-view camera slots from a save blob and adopt the restored
## view's framing. Three layers, weakest first, so an old save still lands right:
##   1. legacy canvas_pan_*/canvas_zoom  → the FREEFORM slot (and, for saves that
##      predate elev_view entirely, the ELEVATION slot with anchor_inited false so
##      _ensure_elev_anchor still runs its pixel-pan → metre-anchor migration)
##   2. legacy elev_view {zoom, along_m, elev_m} → the ELEVATION slot
##   3. canvas_view_cams → every slot, authoritative
func _restore_view_cams(data: Dictionary, restored_view: String) -> void:
	if _graph_canvas == null or not _graph_canvas.has_method("set_view_cam_state"):
		return
	var legacy_zoom := clampf(float(data.get("canvas_zoom", 1.0)),
			GraphLayout.ZOOM_MIN, GraphLayout.ZOOM_MAX)
	var legacy_pan_x := float(data.get("canvas_pan_x", 0.0))
	var legacy_pan_y := float(data.get("canvas_pan_y", 0.0))
	var cams := {
		GraphSiteLayout.VIEW_FREEFORM: {
			"zoom": legacy_zoom, "pan_x": legacy_pan_x, "pan_y": legacy_pan_y,
			"along_m": 0.0, "elev_m": NAN, "anchor_inited": false,
		},
		GraphSiteLayout.VIEW_ELEVATION: {
			"zoom": legacy_zoom, "pan_x": legacy_pan_x, "pan_y": legacy_pan_y,
			"along_m": 0.0, "elev_m": NAN, "anchor_inited": false,
		},
	}
	var elev_view: Variant = data.get("elev_view", {})
	if elev_view is Dictionary and not (elev_view as Dictionary).is_empty():
		var ev: Dictionary = elev_view as Dictionary
		cams[GraphSiteLayout.VIEW_ELEVATION] = {
			"zoom": clampf(float(ev.get("zoom", legacy_zoom)),
					GraphLayout.ZOOM_MIN, GraphLayout.ZOOM_MAX),
			"pan_x": 0.0, "pan_y": 0.0,
			"along_m": float(ev.get("along_m", 0.0)),
			"elev_m": float(ev.get("elev_m", NAN)),
			"anchor_inited": true,
		}
	var saved: Variant = data.get("canvas_view_cams", {})
	if saved is Dictionary:
		for mode_v: Variant in (saved as Dictionary).keys():
			cams[str(mode_v)] = (saved as Dictionary)[mode_v]
	# Adopt FIRST so set_view_cam_state's own restore targets the right slot, and
	# so the deferred _apply_graph_view_mode(restored_view) is a no-op switch that
	# cannot capture pre-restore leftovers into a neighbouring view.
	if _graph_canvas.has_method("adopt_view_mode_no_capture"):
		_graph_canvas.call("adopt_view_mode_no_capture", restored_view)
	_graph_canvas.call("set_view_cam_state", cams)


func collect_save_state() -> Dictionary:
	# Sandbox safety: while the tutorial owns the canvas, the authoritative
	# player state is the snapshot taken on entry — game saves and autosaves
	# must capture THAT, never the throwaway level content.
	if _sandbox_active and not _sandbox_pre_state.is_empty():
		return _sandbox_pre_state.duplicate(true)
	var pan  := Vector2.ZERO
	var zoom := 1.0
	if _graph_canvas != null:
		pan  = _graph_canvas.get("_pan") if _graph_canvas.get("_pan") != null else Vector2.ZERO
		zoom = float(_graph_canvas.get("_zoom")) if _graph_canvas.get("_zoom") != null else 1.0

	var graph_blob: Dictionary = model.serialize() if model != null else {}
	# Never persist foreign .esim ghost overlay into autosave / game saves.
	var state := {
		"graph":               graph_blob,
		"sidebar_l_open":      _sidebar_l_open,
		"sidebar_r_open":      _sidebar_r_open,
		"mode":                _mode,
		"active_scope_id":     _active_scope_id,
		"scope_trail":         _scope_trail.duplicate(),
		"canvas_pan_x":        pan.x,
		"canvas_pan_y":        pan.y,
		"canvas_zoom":         zoom,
		"view_mode":           _graph_view_mode,
		"freeform_soi_bubble": _freeform_soi_bubble,
		"elevation_3d_section": _elevation_3d_section,
		"elevation_heading_rad": float(_graph_canvas.get("elevation_heading_rad")) if _graph_canvas != null else 0.0,
		"elevation_section_offset_m": float(_graph_canvas.get("elevation_section_offset_m")) if _graph_canvas != null else 0.0,
		"elev_view": (_graph_canvas.call("get_elev_view_state") as Dictionary) \
				if _graph_canvas != null and _graph_canvas.has_method("get_elev_view_state") \
				else {},
		# Per-view camera slots. canvas_zoom/canvas_pan_* and elev_view above still
		# describe the freeform and elevation slots respectively, so an OLD build
		# reading this save still restores something sane.
		"canvas_view_cams": (_graph_canvas.call("get_view_cam_state") as Dictionary) \
				if _graph_canvas != null and _graph_canvas.has_method("get_view_cam_state") \
				else {},
		"elevation_exaggeration": float(_graph_canvas.get("elevation_exaggeration")) if _graph_canvas != null else 5.0,
		"elev_show_dem_overlay": bool(_graph_canvas.get("elev_show_dem_overlay")) if _graph_canvas != null else true,
		"elev_show_chips": bool(_graph_canvas.get("elev_show_chips")) if _graph_canvas != null else false,
		"elev_show_ports": bool(_graph_canvas.get("elev_show_ports")) if _graph_canvas != null else false,
		"elev_show_schematic_wires": bool(_graph_canvas.get("elev_show_schematic_wires")) if _graph_canvas != null else false,
		"elev_show_projected_pipes": bool(_graph_canvas.get("elev_show_projected_pipes")) if _graph_canvas != null else false,
		"suppressed_virtuals": _suppressed_virtuals.duplicate(),
		"pbi_bar_pinned":      _pbi_bar_pinned,
		"wire_style_override": str(_graph_canvas.get("wire_style_override")) if _graph_canvas != null else "",
		"node_display_mode":   str(_graph_canvas.get("node_display_mode")) if _graph_canvas != null else "preview",
		"show_preview_labels": bool(_graph_canvas.get("show_preview_labels")) if _graph_canvas != null else true,
		"soi_ring_scale":      float(_graph_canvas.get("soi_ring_scale")) if _graph_canvas != null else 1.0,
		"radial_layout_mode":  bool(_graph_canvas.get("radial_layout_mode")) if _graph_canvas != null else false,
		"site_show_chips":     bool(_graph_canvas.get("site_show_chips")) if _graph_canvas != null else true,
		"site_show_ports":     bool(_graph_canvas.get("site_show_ports")) if _graph_canvas != null else true,
		"site_wire_mode":      str(_graph_canvas.get("site_wire_mode")) if _graph_canvas != null else "metro",
		"site_elev_live_lighting": _site_elev_live_lighting,
		"site_spatial":        _spatial_edit.to_prefs() if _spatial_edit != null else {},
		"phys_cam":            _collect_phys_cam_state(),
	}
	return _ESIM_PACKAGE_SCRIPT.strip_esim_ghosts_from_graph_state(state)


func apply_save_state(data: Dictionary, options: Dictionary = {}) -> void:
	if data.is_empty():
		return
	# An external load (game load, import) while the tutorial sandbox is up:
	# the incoming state wins. Drop the sandbox WITHOUT restoring the pre-state
	# and tell the director to stand down.
	if _sandbox_active and not bool(options.get("sandbox", false)):
		_sandbox_active = false
		_sandbox_pre_state = {}
		_autosave_suspended = false
		if _bridge != null and _bridge.has_method("set_enabled"):
			_bridge.call("set_enabled", true)
		sandbox_interrupted.emit()
	# Game snapshot must latch so deferred per-map autosave restore cannot
	# clobber it. Graph import / autosave restore leave the flag alone.
	if bool(options.get("from_game_save", false)):
		_external_save_applied = true

	var preserve_positions := bool(options.get("preserve_positions", false))
	var position_backup: Dictionary = {}
	if preserve_positions and model != null:
		for item: Dictionary in model.items:
			var iid: String = str(item.get("id", ""))
			if iid.is_empty():
				continue
			position_backup[iid] = Vector2(float(item.get("x", 0.0)), float(item.get("y", 0.0)))

	# Restore graph model (suppress history — a fresh baseline is pushed below)
	_history_suppress = true
	var legacy_stripped := false
	var graph_d: Variant = data.get("graph", {})
	if graph_d is Dictionary and not (graph_d as Dictionary).is_empty():
		if model != null:
			model.deserialize(graph_d as Dictionary)
			legacy_stripped = GraphVirtualIds.strip_legacy_virtual_solar(model)
			# Built-in definitions evolve (starshade rev 2 grew battery DC
			# terminals); saved graphs carry their own older copy. Additively
			# merge any missing shipped exposed ports into the stored defs +
			# live instances (idempotent, never a full restamp).
			var healed := GraphComponentDefs.heal_builtin_exposed_ports(model)
			if healed > 0:
				print("SystemGraphView: healed exposed ports on %d component instance(s)" % healed)
	_sync_array_compound_layouts()
	_normalize_battery_bank_display_nodes()
	if preserve_positions and not position_backup.is_empty():
		for iid: String in position_backup.keys():
			if model.get_item(iid).is_empty():
				continue
			var pos: Vector2 = position_backup[iid] as Vector2
			model.update_item(iid, {"x": pos.x, "y": pos.y})
	_history_suppress = false
	# Reset undo/redo so the loaded state becomes the new baseline
	if _history != null:
		_history.call("clear")
		_history_initialized = false   # re-push initial on next _process() tick
	_update_undo_redo_btns()

	# Recreate sim-load proxies for every non-virtual load item and refresh
	# their device_paths BEFORE we re-register automations — otherwise any
	# SceneNodeActions wired up below would still point at stale paths.
	if _sim_load_host != null and _sim_load_host.has_method("refresh"):
		_sim_load_host.call("refresh")

	if _resource_flow != null and _resource_flow.has_method("clear_timelines"):
		_resource_flow.call("clear_timelines")

	call_deferred("_init_conduit_manager")
	call_deferred("_init_placeholder_host")

	# Re-register any saved per-load automations with the engine so they fire
	# immediately on load (the engine state itself isn't persisted; we rebuild
	# it from the graph's specs).
	if _inspector_panel != null and _inspector_panel.has_method("sync_all_load_automations"):
		_inspector_panel.call("sync_all_load_automations", model)

	# Restore user-deleted virtual IDs so bridge does not re-create them.
	var sv: Variant = data.get("suppressed_virtuals", {})
	_suppressed_virtuals = sv as Dictionary if sv is Dictionary else {}
	if legacy_stripped:
		_suppressed_virtuals = GraphVirtualIds.merge_suppression(_suppressed_virtuals)
	if _bridge != null:
		_bridge.suppressed_ids = _suppressed_virtuals

	# Restore sidebar / mode state
	_sidebar_l_open = bool(data.get("sidebar_l_open", true))
	_sidebar_r_open = bool(data.get("sidebar_r_open", true))
	_mode           = str(data.get("mode", "build"))
	_active_scope_id = str(data.get("active_scope_id", "root"))
	var trail_data: Variant = data.get("scope_trail", ["root"])
	_scope_trail.clear()
	if trail_data is Array:
		for sid_v: Variant in (trail_data as Array):
			var sid: String = str(sid_v)
			if sid.is_empty():
				continue
			_scope_trail.append(sid)
	if _scope_trail.is_empty():
		_scope_trail.append("root")

	_apply_layout()

	# Restore canvas viewport
	if _graph_canvas != null:
		_graph_canvas.set("_pan",  Vector2(
			float(data.get("canvas_pan_x", 0.0)),
			float(data.get("canvas_pan_y", 0.0))
		))
		_graph_canvas.set("_zoom", clampf(float(data.get("canvas_zoom", 1.0)),
				GraphLayout.ZOOM_MIN, GraphLayout.ZOOM_MAX))
		_graph_canvas.set("active_scope_id", _active_scope_id)
		_graph_canvas.set("elevation_heading_rad", float(data.get("elevation_heading_rad", 0.0)))
		_graph_canvas.set("elevation_section_offset_m",
				float(data.get("elevation_section_offset_m", 0.0)))
		_graph_canvas.set("elevation_exaggeration", float(data.get("elevation_exaggeration", 5.0)))
		_graph_canvas.set("elev_show_dem_overlay", bool(data.get("elev_show_dem_overlay", true)))
		_graph_canvas.set("elev_show_chips", bool(data.get("elev_show_chips", false)))
		_graph_canvas.set("elev_show_ports", bool(data.get("elev_show_ports", false)))
		_graph_canvas.set("elev_show_schematic_wires",
				bool(data.get("elev_show_schematic_wires", false)))
		_graph_canvas.set("elev_show_projected_pipes",
				bool(data.get("elev_show_projected_pipes", false)))
		_graph_canvas.set("wire_style_override", str(data.get("wire_style_override", "")))
		var ndm := str(data.get("node_display_mode", "preview"))
		_graph_canvas.set("node_display_mode",
				ndm if ndm in ["preview", "card"] else "preview")
		_graph_canvas.set("show_preview_labels", bool(data.get("show_preview_labels", true)))
		_graph_canvas.set("soi_ring_scale",
				clampf(float(data.get("soi_ring_scale", 1.0)), 0.25, 4.0))
		_graph_canvas.set("radial_layout_mode", bool(data.get("radial_layout_mode", false)))
		_graph_canvas.set("site_show_chips", bool(data.get("site_show_chips", true)))
		_graph_canvas.set("site_show_ports", bool(data.get("site_show_ports", true)))
		var swm := str(data.get("site_wire_mode", "metro"))
		_graph_canvas.set("site_wire_mode",
				swm if swm in ["none", "metro", "prefer_3d"] else "metro")
		var elev_view: Variant = data.get("elev_view", {})
		if elev_view is Dictionary and not (elev_view as Dictionary).is_empty() \
				and _graph_canvas.has_method("set_elev_view_state"):
			_graph_canvas.call("set_elev_view_state", elev_view)
		_graph_canvas.call("queue_redraw")
	_site_elev_live_lighting = bool(data.get("site_elev_live_lighting", false))
	if _spatial_edit != null:
		var spat: Variant = data.get("site_spatial", {})
		if spat is Dictionary:
			_spatial_edit.apply_prefs(spat as Dictionary)
			_on_spatial_working_radius_changed(
					float(_spatial_edit.working_radius_m) if not is_nan(_spatial_edit.working_radius_m) else 50.0)
	_pbi_bar_pinned = bool(data.get("pbi_bar_pinned", true))
	_apply_pbi_bar_pinned()
	_sync_wire_style_menu_checks()
	var pcam: Variant = data.get("phys_cam", {})
	if pcam is Dictionary:
		_apply_phys_cam_state(pcam as Dictionary)
	_freeform_soi_bubble = bool(data.get("freeform_soi_bubble", false))
	_elevation_3d_section = bool(data.get("elevation_3d_section", true))
	_sync_elev_slice_row()
	_sync_site_tool_row()
	var restored_view := str(data.get("view_mode", GraphSiteLayout.VIEW_FREEFORM))
	# The Hydro Lab is item-bound and never restored as a sticky mode — a saved
	# "siphon" view (quit with the Lab open) reopens as Elevation instead, so the
	# graph can't boot into a Lab that carries no item id.
	if restored_view == GraphSiteLayout.VIEW_SIPHON:
		restored_view = GraphSiteLayout.VIEW_ELEVATION
	_restore_view_cams(data, restored_view)
	if restored_view in [GraphSiteLayout.VIEW_FREEFORM, GraphSiteLayout.VIEW_SITE,
			GraphSiteLayout.VIEW_ELEVATION]:
		# Restore prefs only; `_sync_soi_preview_for_mode` no-ops world clip
		# while the graph is hidden (first-person map load). Keep saved elev 3D.
		call_deferred("_apply_graph_view_mode", restored_view,
				{"preserve_elev_3d": true})

	_refresh_telemetry()
	_sync_solar_ui_from_graph()
	_update_scope_breadcrumb()
	call_deferred("_post_restore_layout_fixup")

	# Subscribe to any ha_links already saved in the graph (e.g. Shelly 4PM
	# nodes created from the preset that carry pre-filled entity IDs).
	if _ha_linker != null and _ha_linker.has_method("refresh_subscriptions"):
		_ha_linker.call_deferred("refresh_subscriptions")


# ---------------------------------------------------------------------------
# Layout helpers
# ---------------------------------------------------------------------------

func _anchor(ctrl: Control,
		al: float, at: float, ar: float, ab: float,
		ol: float, ot: float, or_: float, ob: float) -> void:
	ctrl.anchor_left   = al;  ctrl.anchor_top    = at
	ctrl.anchor_right  = ar;  ctrl.anchor_bottom = ab
	ctrl.offset_left   = ol;  ctrl.offset_top    = ot
	ctrl.offset_right  = or_; ctrl.offset_bottom = ob


func _anchor_full(ctrl: Control) -> void:
	_anchor(ctrl, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0)


func _hspacer() -> Control:
	var s := Control.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.mouse_filter          = Control.MOUSE_FILTER_IGNORE
	return s


# ---------------------------------------------------------------------------
# Wind / hydro graph items — live output refresh
# ---------------------------------------------------------------------------

const _RENEWABLES_POLL_INTERVAL := 0.25  # matches SolarBridge cadence
var _renewables_acc: float = _RENEWABLES_POLL_INTERVAL
const _ENERGY_SYNC_INTERVAL := 0.25
var _energy_sync_acc: float = 0.0
const _PBIS_POLL_INTERVAL := 0.25
var _pbis_acc: float = _PBIS_POLL_INTERVAL
## Per-node 3D shade → specs.sunlight_factor (Phase 5). Same cadence as
## renewables; round-robins receivers so large graphs stay cheap.
const _SHADE_POLL_INTERVAL := 0.25
const _SHADE_RAYS_PER_TICK := 12
var _shade_acc: float = _SHADE_POLL_INTERVAL
var _shade_cursor: int = 0


## Recompute current_output_kw for user-placed "wind" and "hydro" items from
## their inspector-edited specs and the world clock, using the same physics
## as the 3D EnergySource nodes (power_kw_from_graph_specs adapters).
func _tick_graph_renewables(delta: float) -> void:
	if model == null:
		return
	_renewables_acc += delta
	if _renewables_acc < _RENEWABLES_POLL_INTERVAL:
		return
	_renewables_acc = 0.0

	var hour := 12.0
	var month := 6
	var day := 15
	var m := _get_scene_main_node()
	if m != null:
		var dt: Variant = m.get("day_time")
		if dt != null:
			hour = float(dt)
		var mo: Variant = m.get("month")
		if mo != null:
			month = clampi(int(mo), 1, 12)
		var dd: Variant = m.get("day")
		if dd != null:
			day = clampi(int(dd), 1, 31)

	# Real weather input (shared by every item this tick): measured 10 m wind
	# when WeatherService covers the sim location. NAN keeps the synthetic model.
	var real_wind_10m := NAN
	var ws := get_node_or_null("/root/WeatherService")
	if ws != null and m != null and ws.has_method("covers"):
		var lat: Variant = m.get("latitude")
		var lon: Variant = m.get("longitude")
		if lat != null and lon != null and bool(ws.call("covers", float(lat), float(lon))):
			real_wind_10m = float(ws.call("wind_speed_ms", month, day, hour))

	# Only the generating types — via the model's shared type index instead of a
	# full-list scan. Shallow spec copies: we only read/write scalar telemetry
	# and rebuild nested arrays wholesale, so a deep copy per item per tick is
	# waste. Hydro left this tick in Phase B of the Hydro Lab overhaul: every
	# turbine is now a role=="siphon_hydro" processor computed by
	# ResourceFlowEngine (_process_siphon_hydro / _process_spec_driven_hydro).
	var _renewables: Array = []
	_renewables.append_array(model.items_of_type("wind"))
	_renewables.append_array(model.items_of_type("panel"))
	for item: Dictionary in _renewables:
		var ty: String = item.get("type", "") as String
		var iid: String = item.get("id", "") as String
		var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(false)
		var scene_path: String = str(specs.get("scene_device_path", item.get("device_path", "")))
		if not scene_path.is_empty():
			var scene_node: Node = get_tree().root.get_node_or_null(NodePath(scene_path))
			if scene_node != null and scene_node.has_method("get_current_power_kw"):
				var live_kw: float = maxf(0.0, float(scene_node.call("get_current_power_kw")))
				if absf(float(specs.get("current_output_kw", 0.0)) - live_kw) >= 0.0005:
					specs["current_output_kw"] = live_kw
					model.update_item(iid, {"specs": specs, "device_path": scene_path})
				continue
		if ty == "panel":
			continue
		var kw := 0.0
		# Packed 3D twin (PACKING_PLAN.md Phase 5): a crated turbine generates
		# nothing — kw stays 0 and converges via the change gate below.
		if bool(specs.get("packed_3d", false)):
			pass
		elif ty == "wind":
			kw = WindTurbineSource.power_kw_from_graph_specs(specs, hour, real_wind_10m)
		if absf(float(specs.get("current_output_kw", 0.0)) - kw) < 0.0005:
			continue
		specs["current_output_kw"] = kw
		model.update_item(iid, {"specs": specs})
	refresh_hydro_section_panel()


const _DC_THROTTLE_INTERVAL := 0.25


## Live controller current-limit throttle (GraphDcElectrical): each real
## (player-built) controller charging a battery bank delivers at most
## bus_V × max_charge_amps watts of the PV share wired to it. The summed cap is
## pushed into SolarUI (set_graph_dc_limit_w) so the battery charge rate the
## whole sim integrates reflects the wiring — the levers behind tutorial
## levels 3–7 (120 W / 360 W / 720 W / 1200 W all emerge from this math).
## Runs ambient (graph open or closed); telemetry writes are change-gated and
## wrapped in history/bulk suppression so they never pollute undo or autosave.
func _tick_dc_throttle(delta: float) -> void:
	if model == null:
		return
	_dc_throttle_acc += delta
	if _dc_throttle_acc < _DC_THROTTLE_INTERVAL:
		return
	_dc_throttle_acc = 0.0
	if _dc_analysis.is_empty():
		# Fresh load — _check_electrical_faults hasn't run yet (it refreshes the
		# cache on wiring changes). Build the topology once here.
		_dc_flat_conns = GraphNesting.flat_connections(model)
		_dc_analysis = GraphDcElectrical.analyze(model, _dc_flat_conns)
	var raw_kw := 0.0
	if is_instance_valid(_solar_ui):
		var raw_v: Variant = _solar_ui.get("_raw_solar_kw")
		if raw_v != null:
			raw_kw = maxf(float(raw_v), 0.0)
	# Eligible = real controllers wired to both a PV source and a battery bank.
	var entries: Array = []
	var total_wmp := 0.0
	var routed_wmp := 0.0
	for item in GraphNesting.walk_items(model, "root"):
		if not (item is Dictionary):
			continue
		var it: Dictionary = item
		if bool(it.get("is_virtual", false)):
			continue
		if PvElectrical.is_pv_source_item(it):
			total_wmp += _pv_item_wmp(it)
			continue
		if str(it.get("type", "")) != "controller":
			continue
		# A crated controller delivers no charge current (Phase 5 packed gate).
		if GraphDcElectrical.is_packed(it):
			continue
		var bank := GraphDcElectrical.bank_for_controller(
			model, str(it.get("id", "")), _dc_flat_conns, _dc_analysis)
		if bank.is_empty():
			continue
		var sources := PvElectrical.pv_sources_for_controller_flat(
			model, str(it.get("id", "")), _dc_flat_conns)
		if sources.is_empty():
			continue
		# A backwards PV pair presents no usable voltage — the array delivers
		# nothing until the leads are swapped.
		if GraphDcElectrical.controller_pv_reversed(
				model, str(it.get("id", "")), _dc_flat_conns):
			continue
		var wmp := 0.0
		for sid in sources:
			wmp += _pv_item_wmp(model.get_item(str(sid)))
		routed_wmp += wmp
		entries.append({"item": it, "bank": bank, "wmp": wmp,
			"sources": sources.duplicate()})
	if entries.is_empty() or total_wmp <= 0.0:
		_publish_live_circuits([])
		if is_instance_valid(_solar_ui) and _solar_ui.has_method("set_graph_dc_limit_w"):
			_solar_ui.call("set_graph_dc_limit_w", -1.0)
		return
	var was_suppress := _history_suppress
	var was_bulk := _sim_bulk_update
	_history_suppress = true
	_sim_bulk_update = true
	var delivered_total_w := 0.0
	for e in entries:
		var it2: Dictionary = (e as Dictionary).get("item", {}) as Dictionary
		var share_w := raw_kw * 1000.0 * float((e as Dictionary).get("wmp", 0.0)) / total_wmp
		var sp: Dictionary = (it2.get("specs", {}) as Dictionary).duplicate(false)
		var th := {"delivered_w": 0.0, "bus_voltage": 0.0, "limit_w": 0.0, "clipped": false}
		if not bool(sp.get("destroyed", false)):
			th = GraphDcElectrical.controller_throttle(
				it2, (e as Dictionary).get("bank", {}) as Dictionary, share_w)
			delivered_total_w += float(th.get("delivered_w", 0.0))
		var limit_w: float = float(th.get("limit_w", 0.0))
		if not is_finite(limit_w):
			limit_w = 0.0  # no current limit modeled → no cap to display
		if absf(float(sp.get("dc_delivered_w", -1.0)) - float(th.get("delivered_w", 0.0))) >= 1.0 \
				or bool(sp.get("dc_clipped", false)) != bool(th.get("clipped", false)) \
				or absf(float(sp.get("dc_bus_v", -1.0)) - float(th.get("bus_voltage", 0.0))) >= 0.5:
			sp["dc_delivered_w"] = float(th.get("delivered_w", 0.0))
			sp["dc_bus_v"] = float(th.get("bus_voltage", 0.0))
			sp["dc_limit_w"] = limit_w
			sp["dc_clipped"] = bool(th.get("clipped", false))
			model.update_item(str(it2.get("id", "")), {"specs": sp})
	_history_suppress = was_suppress
	_sim_bulk_update = was_bulk
	_publish_live_circuits(entries)
	_check_bank_advice(entries)
	# PV wattage not routed through any eligible controller passes uncapped —
	# freeplay arrays mirrored via the virtual chain keep working untouched.
	var unrouted_w: float = raw_kw * 1000.0 * maxf(1.0 - routed_wmp / total_wmp, 0.0)
	if is_instance_valid(_solar_ui) and _solar_ui.has_method("set_graph_dc_limit_w"):
		_solar_ui.call("set_graph_dc_limit_w", delivered_total_w + unrouted_w)


## Non-destructive coaching: a bank paralleled where series would move twice
## the power still WORKS, so it never faults — but nothing in the sim told the
## player they were leaving half their array unused. Fires once per occurrence
## and only when series would genuinely help (the controller is clipping, and
## there is more array than the current bus can take).
func _check_bank_advice(entries: Array) -> void:
	var advise: Dictionary = {}
	for e in entries:
		var ed: Dictionary = e
		var bank: Dictionary = ed.get("bank", {}) as Dictionary
		var it: Dictionary = ed.get("item", {}) as Dictionary
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		if int(bank.get("parallel_count", 1)) < 2 or int(bank.get("series_count", 1)) > 1:
			continue
		if not bool(sp.get("dc_clipped", false)):
			continue  # not the bottleneck — nothing to gain
		var bus_v := float(bank.get("bus_voltage", 12.0))
		var amps := float(sp.get("max_charge_amps", 0.0))
		var n := int(bank.get("parallel_count", 2))
		advise = {
			"parallel_count": n,
			"bus_v": bus_v,
			"delivered_w": bus_v * amps,
			"series_v": bus_v * float(n),
			"series_w": bus_v * float(n) * amps,
		}
		break
	if advise.is_empty():
		_bank_advice_notified = false
		return
	if _bank_advice_notified:
		return
	_bank_advice_notified = true
	_show_toast("⚠ Batteries in parallel — series would nearly double your charging", 4.5)
	_show_fault_card(GraphNodeState.REASON_SUBOPTIMAL_BANK, advise)


## Tell the canvas which controllers sit on a COMPLETE circuit (both PV legs
## wired and a battery bank attached) and at what bus voltage, so wire drawing
## can stop animating dead wires and can label them with a real voltage. The
## set is exactly `entries`, already computed here for the throttle — the
## canvas would otherwise have to re-traverse the graph every redraw.
func _publish_live_circuits(entries: Array) -> void:
	if _graph_canvas == null:
		return
	var live: Dictionary = {}
	var members: Dictionary = {}   # item_id → controller_id (panels + batteries)
	for e in entries:
		var ed: Dictionary = e
		var it: Dictionary = ed.get("item", {}) as Dictionary
		var cid := str(it.get("id", ""))
		if cid.is_empty():
			continue
		var bank: Dictionary = ed.get("bank", {}) as Dictionary
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		live[cid] = {
			"bus_v": float(bank.get("bus_voltage", 0.0)),
			"delivered_w": float(sp.get("dc_delivered_w", 0.0)),
			"array_voc": PvElectrical.max_string_voc_for_controller_flat(
				model, cid, _dc_flat_conns, _ambient_temp_c_for_voc()),
		}
		for sid in (ed.get("sources", []) as Array):
			members[str(sid)] = cid
		for bid in (bank.get("battery_ids", []) as Array):
			members[str(bid)] = cid
	var hint: Dictionary = (_graph_canvas.get("live_power_hint") as Dictionary).duplicate()
	hint["circuits"] = live
	hint["circuit_of"] = members
	_graph_canvas.set("live_power_hint", hint)


static func _pv_item_wmp(item: Dictionary) -> float:
	if item.is_empty():
		return 0.0
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	# Crated panels deliver nothing (Phase 5 packed gate).
	if bool(sp.get("packed_3d", false)):
		return 0.0
	if str(item.get("type", "")) == "compound":
		var units := float(sp.get("array_panel_units", 0.0))
		var per := float(sp.get("array_panel_wmp", sp.get("wmp", 0.0)))
		if units > 0.0 and per > 0.0:
			return units * per
	return float(sp.get("wmp", 0.0))


const _CspTroughSource := preload("res://power_system/sources/csp_trough_source.gd")
const _CSP_POLL_INTERVAL := 0.25
var _csp_acc: float = _CSP_POLL_INTERVAL


## Recompute live tracking angle + thermal/steam output for "processor" items
## with specs.role == "csp_concentrator" (Parabolic Trough CSP). Physics in
## power_system/sources/csp_trough_source.gd (single-axis N-S tracking, real
## sun position + weather-attenuated DNI). Drives specs.inputs[0].rate (water
## L/h) / specs.outputs[0].rate (steam kg/h) so ResourceFlowEngine's generic
## tank-throughput logic moves the right mass through the water→steam ports.
func _tick_graph_csp(delta: float) -> void:
	if model == null:
		return
	_csp_acc += delta
	if _csp_acc < _CSP_POLL_INTERVAL:
		return
	_csp_acc = 0.0

	var m := _get_scene_main_node()
	if m == null:
		return
	var clock_obj: Variant = m.get("clock")
	if clock_obj == null or not (clock_obj as Object).has_method("get_julian_day_utc"):
		return
	var lat_v: Variant = m.get("latitude")
	var lon_v: Variant = m.get("longitude")
	var lat: float = float(lat_v) if lat_v != null else 33.36
	var lon: float = float(lon_v) if lon_v != null else -115.74
	var jd_utc: float = float((clock_obj as Object).call("get_julian_day_utc"))
	var sp := SolarPosition.get_position(lat, lon, jd_utc)
	var sun_el: float = float(sp.get("elevation_deg", 0.0))
	var sun_az: float = float(sp.get("azimuth_deg", 180.0))

	var hour := 12.0
	var month := 6
	var day := 15
	var dt_v: Variant = m.get("day_time")
	if dt_v != null:
		hour = float(dt_v)
	var mo_v: Variant = m.get("month")
	if mo_v != null:
		month = clampi(int(mo_v), 1, 12)
	var dd_v: Variant = m.get("day")
	if dd_v != null:
		day = clampi(int(dd_v), 1, 31)
	var ws := get_node_or_null("/root/WeatherService")
	var weather := SolarIrradiance.sample_weather(lat, lon, month, day, hour, ws)

	for item: Dictionary in model.items_of_type("processor"):
		var specs_ref: Dictionary = item.get("specs", {})
		if str(specs_ref.get("role", "")) != "csp_concentrator":
			continue
		var specs: Dictionary = specs_ref.duplicate(false)
		var iid: String = item.get("id", "") as String
		# Packed 3D twin (PACKING_PLAN.md Phase 5): a crated trough tracks and
		# boils nothing — {} zeroes every telemetry key via the .get defaults.
		var result: Dictionary = {} if bool(specs_ref.get("packed_3d", false)) \
			else _CspTroughSource.simulate(specs, sun_az, sun_el, weather)

		var dirty := absf(float(specs.get("thermal_output_kw", 0.0)) - float(result.get("thermal_output_kw", 0.0))) > 0.001 \
			or absf(float(specs.get("tracking_angle_deg", 0.0)) - float(result.get("tracking_angle_deg", 0.0))) > 0.05
		if not dirty:
			continue

		specs["tracking_angle_deg"] = result.get("tracking_angle_deg", 0.0)
		specs["cos_incidence"] = result.get("cos_incidence", 0.0)
		specs["dni_wm2"] = result.get("dni_wm2", 0.0)
		specs["end_loss_frac"] = result.get("end_loss_frac", 0.0)
		specs["thermal_output_kw"] = result.get("thermal_output_kw", 0.0)
		specs["steam_kg_h"] = result.get("steam_kg_h", 0.0)

		var inputs: Array = (specs.get("inputs", []) as Array).duplicate(true)
		if not inputs.is_empty():
			var inp0: Dictionary = (inputs[0] as Dictionary).duplicate(true)
			inp0["rate"] = result.get("water_lph", 0.0)
			inputs[0] = inp0
			specs["inputs"] = inputs
		var outputs: Array = (specs.get("outputs", []) as Array).duplicate(true)
		if not outputs.is_empty():
			var out0: Dictionary = (outputs[0] as Dictionary).duplicate(true)
			out0["rate"] = result.get("steam_kg_h", 0.0)
			outputs[0] = out0
			specs["outputs"] = outputs

		model.update_item(iid, {"specs": specs})


const _HomeBiogasSource := preload("res://power_system/sources/home_biogas_source.gd")
const _BIODIGESTER_POLL_INTERVAL := 0.25
var _biodigester_acc: float = _BIODIGESTER_POLL_INTERVAL


## Recompute live biogas + fertilizer output for "processor" items with
## specs.role == "biodigester" (HomeBiogas 2.0). Physics in
## power_system/sources/home_biogas_source.gd (feed setpoint × temp derate).
## Drives input/output rates so ResourceFlowEngine (`io_absolute`) moves the
## right mass through food-waste/manure + water → biogas + liquid fertilizer.
func _tick_graph_biodigester(delta: float) -> void:
	if model == null:
		return
	_biodigester_acc += delta
	if _biodigester_acc < _BIODIGESTER_POLL_INTERVAL:
		return
	_biodigester_acc = 0.0

	var ambient_c := _ambient_temp_c_for_voc()

	for item: Dictionary in model.items_of_type("processor"):
		var specs_ref: Dictionary = item.get("specs", {})
		if str(specs_ref.get("role", "")) != "biodigester":
			continue
		var specs: Dictionary = specs_ref.duplicate(false)
		var iid: String = item.get("id", "") as String
		var result := _HomeBiogasSource.simulate(specs, ambient_c)

		var prev_feed_kind := ""
		var prev_inputs: Array = specs.get("inputs", []) as Array
		if not prev_inputs.is_empty() and prev_inputs[0] is Dictionary:
			prev_feed_kind = str((prev_inputs[0] as Dictionary).get("kind", ""))
		var dirty := absf(float(specs.get("biogas_m3_h", 0.0)) - float(result.get("biogas_m3_h", 0.0))) > 0.00005 \
			or absf(float(specs.get("temp_factor", 1.0)) - float(result.get("temp_factor", 1.0))) > 0.005 \
			or absf(float(specs.get("feed_fraction", 0.0)) - float(result.get("feed_fraction", 0.0))) > 0.005 \
			or absf(float(specs.get("ambient_temp_c", 20.0)) - float(result.get("ambient_temp_c", 20.0))) > 0.25 \
			or prev_feed_kind != str(result.get("feed_kind", "food_waste"))
		if not dirty:
			continue

		specs["ambient_temp_c"] = result.get("ambient_temp_c", ambient_c)
		specs["temp_factor"] = result.get("temp_factor", 1.0)
		specs["feed_fraction"] = result.get("feed_fraction", 0.0)
		specs["biogas_m3_h"] = result.get("biogas_m3_h", 0.0)
		specs["fertilizer_lph"] = result.get("fertilizer_lph", 0.0)
		specs["cooking_hours_day"] = result.get("cooking_hours_day", 0.0)
		specs["biogas_m3_day"] = result.get("biogas_m3_day", 0.0)
		specs["methane_m3_day"] = result.get("methane_m3_day", 0.0)

		var feed_kind := str(result.get("feed_kind", "food_waste"))
		var inputs: Array = (specs.get("inputs", []) as Array).duplicate(true)
		while inputs.size() < 2:
			inputs.append({"kind": "water", "rate": 0.0, "unit": "L/h"})
		var inp0: Dictionary = (inputs[0] as Dictionary).duplicate(true)
		inp0["kind"] = feed_kind
		inp0["rate"] = result.get("feed_lph", 0.0)
		inp0["unit"] = "L/h"
		inputs[0] = inp0
		var inp1: Dictionary = (inputs[1] as Dictionary).duplicate(true)
		inp1["kind"] = "water"
		inp1["rate"] = result.get("water_lph", 0.0)
		inp1["unit"] = "L/h"
		inputs[1] = inp1
		specs["inputs"] = inputs

		var outputs: Array = (specs.get("outputs", []) as Array).duplicate(true)
		while outputs.size() < 2:
			outputs.append({"kind": "biogas", "rate": 0.0, "unit": "m³/h"})
		var out0: Dictionary = (outputs[0] as Dictionary).duplicate(true)
		out0["kind"] = "biogas"
		out0["rate"] = result.get("biogas_m3_h", 0.0)
		out0["unit"] = "m³/h"
		outputs[0] = out0
		var out1: Dictionary = (outputs[1] as Dictionary).duplicate(true)
		out1["kind"] = "liquid_fertilizer"
		out1["rate"] = result.get("fertilizer_lph", 0.0)
		out1["unit"] = "L/h"
		outputs[1] = out1
		specs["outputs"] = outputs

		model.update_item(iid, {"specs": specs})


const _HeliostatSource := preload("res://power_system/sources/heliostat_source.gd")
const _HELIO_POLL_INTERVAL := 0.25
var _helio_acc: float = _HELIO_POLL_INTERVAL


## Recompute live focal temperature + concentration + thermal/steam output for
## "processor" items with specs.role == "heliostat" (Dual-Axis Heliostat).
## Physics in power_system/sources/heliostat_source.gd (perfect two-axis sun
## tracking, real sun position + weather-attenuated DNI, cavity-receiver energy
## balance). Drives specs.inputs[0].rate (water L/h) / specs.outputs[0].rate
## (steam kg/h) like the trough, so ResourceFlowEngine moves the right mass.
func _tick_graph_heliostat(delta: float) -> void:
	if model == null:
		return
	_helio_acc += delta
	if _helio_acc < _HELIO_POLL_INTERVAL:
		return
	_helio_acc = 0.0

	var m := _get_scene_main_node()
	if m == null:
		return
	var clock_obj: Variant = m.get("clock")
	if clock_obj == null or not (clock_obj as Object).has_method("get_julian_day_utc"):
		return
	var lat_v: Variant = m.get("latitude")
	var lon_v: Variant = m.get("longitude")
	var lat: float = float(lat_v) if lat_v != null else 33.36
	var lon: float = float(lon_v) if lon_v != null else -115.74
	var jd_utc: float = float((clock_obj as Object).call("get_julian_day_utc"))
	var sp := SolarPosition.get_position(lat, lon, jd_utc)
	var sun_el: float = float(sp.get("elevation_deg", 0.0))
	var sun_az: float = float(sp.get("azimuth_deg", 180.0))

	var hour := 12.0
	var month := 6
	var day := 15
	var dt_v: Variant = m.get("day_time")
	if dt_v != null:
		hour = float(dt_v)
	var mo_v: Variant = m.get("month")
	if mo_v != null:
		month = clampi(int(mo_v), 1, 12)
	var dd_v: Variant = m.get("day")
	if dd_v != null:
		day = clampi(int(dd_v), 1, 31)
	var ws := get_node_or_null("/root/WeatherService")
	var weather := SolarIrradiance.sample_weather(lat, lon, month, day, hour, ws)

	for item: Dictionary in model.items_of_type("processor"):
		var specs_ref: Dictionary = item.get("specs", {})
		if str(specs_ref.get("role", "")) != "heliostat":
			continue
		var specs: Dictionary = specs_ref.duplicate(false)
		var iid: String = item.get("id", "") as String
		# Packed 3D twin: a crated dish concentrates nothing (see CSP tick).
		var result: Dictionary = {} if bool(specs_ref.get("packed_3d", false)) \
			else _HeliostatSource.simulate(specs, sun_az, sun_el, weather)

		var dirty := absf(float(specs.get("thermal_output_kw", 0.0)) - float(result.get("thermal_output_kw", 0.0))) > 0.001 \
			or absf(float(specs.get("focal_temp_c", 0.0)) - float(result.get("focal_temp_c", 0.0))) > 0.5
		if not dirty:
			continue

		specs["cos_incidence"] = result.get("cos_incidence", 0.0)
		specs["dni_wm2"] = result.get("dni_wm2", 0.0)
		specs["incident_kw"] = result.get("incident_kw", 0.0)
		specs["absorbed_kw"] = result.get("absorbed_kw", 0.0)
		specs["concentration_ratio"] = result.get("concentration_ratio", 0.0)
		specs["focal_flux_kw_m2"] = result.get("focal_flux_kw_m2", 0.0)
		specs["focal_temp_c"] = result.get("focal_temp_c", 0.0)
		specs["thermal_output_kw"] = result.get("thermal_output_kw", 0.0)
		specs["steam_kg_h"] = result.get("steam_kg_h", 0.0)

		var inputs: Array = (specs.get("inputs", []) as Array).duplicate(true)
		if not inputs.is_empty():
			var inp0: Dictionary = (inputs[0] as Dictionary).duplicate(true)
			inp0["rate"] = result.get("water_lph", 0.0)
			inputs[0] = inp0
			specs["inputs"] = inputs
		var outputs: Array = (specs.get("outputs", []) as Array).duplicate(true)
		if not outputs.is_empty():
			var out0: Dictionary = (outputs[0] as Dictionary).duplicate(true)
			out0["rate"] = result.get("steam_kg_h", 0.0)
			outputs[0] = out0
			specs["outputs"] = outputs

		model.update_item(iid, {"specs": specs})


const _CartesianMachineSource := preload("res://power_system/sources/cartesian_machine_source.gd")
const _PpBeamExtruderSource := preload("res://power_system/sources/pp_beam_extruder_source.gd")
const _PpSheetPressSource := preload("res://power_system/sources/pp_sheet_press_source.gd")
const _MACHINE_SETUP_MODAL := preload("res://scenes/ui/machine_setup_modal.gd")
const _CONNECTION_PORT_MODAL := preload("res://scenes/ui/connection_port_modal.gd")
const _CONDUIT_STYLE_MODAL := preload("res://scenes/ui/conduit_style_modal.gd")
const _INVENTORY_PANEL := preload("res://scenes/ui/inventory_panel.gd")
const _PRINT_SETUP_MODAL := preload("res://scenes/ui/print_setup_modal.gd")
const _MUD_BUILDING_DESIGNER := preload("res://scenes/ui/mud_building_designer_modal.gd")
const _TOOLS_POLL_INTERVAL := 0.2
var _tools_acc: float = _TOOLS_POLL_INTERVAL
const _PP_EXTRUDER_POLL_INTERVAL := 0.2
var _pp_extruder_acc: float = _PP_EXTRUDER_POLL_INTERVAL
const _PP_SHEET_POLL_INTERVAL := 0.2
var _pp_sheet_acc: float = _PP_SHEET_POLL_INTERVAL
var _machine_setup_modal: Control = null
var _connection_port_modal: Control = null
var _conduit_style_modal: Control = null
var _inventory_panel: Control = null
var _print_setup_modal: Control = null
var _mud_building_designer: Control = null


## Live job scheduler for "processor" items with specs.role == "cartesian_machine"
## (CNC router / flake 3D printer). The authority for machine job state: it
## advances a SCRUB-SAFE progress (pure function of the absolute-hours clock, via
## CartesianMachineSource.progress_at — like the sun trackers), drives the
## material feed rate (specs.inputs[0].rate so ResourceFlowEngine debits the
## wired feedstock tank), holds the running power draw (item.batch_active_watts,
## read by graph_ac_load), and on completion credits the fabricated part to the
## per-map PartInventory. The 3D CncMachineRuntime reads progress back (via
## get_cnc_job_state) to trace the toolpath.
func _tick_graph_tools(delta: float) -> void:
	if model == null:
		return
	_tools_acc += delta
	if _tools_acc < _TOOLS_POLL_INTERVAL:
		return
	_tools_acc = 0.0

	var m := _get_scene_main_node()
	var abs_hours := 0.0
	if m != null and m.has_method("get_absolute_hours"):
		abs_hours = float(m.call("get_absolute_hours"))

	for item: Dictionary in model.items_of_type("processor"):
		var specs: Dictionary = (item.get("specs", {}) as Dictionary)
		if str(specs.get("role", "")) != "cartesian_machine":
			continue
		var iid: String = item.get("id", "") as String
		var active := bool(specs.get("job_active", false))
		var progress := _CartesianMachineSource.progress_at(specs, abs_hours)
		var running := active and progress < 1.0

		var new_specs: Dictionary = specs.duplicate(true)
		var mat_rate := _CartesianMachineSource.material_rate_per_hr(specs) if running else 0.0
		var inputs: Array = (new_specs.get("inputs", []) as Array).duplicate(true)
		if not inputs.is_empty() and inputs[0] is Dictionary:
			var inp0: Dictionary = (inputs[0] as Dictionary).duplicate(true)
			inp0["rate"] = mat_rate
			inputs[0] = inp0
			new_specs["inputs"] = inputs
		new_specs["requested_state"] = "on" if running else "off"
		new_specs["job_progress"] = progress
		var watts := float(new_specs.get("watts", 0.0)) if running else 0.0

		var completed_now := false
		if active and progress >= 1.0 and not bool(specs.get("job_completed", false)):
			new_specs["job_active"] = false
			new_specs["job_completed"] = true
			new_specs["requested_state"] = "off"
			completed_now = true

		var prev_progress := float(specs.get("job_progress", -1.0))
		var prev_watts := float(item.get("batch_active_watts", -1.0))
		var dirty := completed_now or absf(prev_progress - progress) > 0.005 \
			or absf(prev_watts - watts) > 0.5
		if not dirty:
			continue
		model.update_item(iid, {"specs": new_specs, "batch_active_watts": watts})
		if completed_now:
			# Cut-preset feedstock was already spent; don't restore on later Cancel.
			new_specs.erase("job_consume_part_id")
			new_specs.erase("job_consume_qty")
			new_specs.erase("job_consume_label")
			model.update_item(iid, {"specs": new_specs, "batch_active_watts": watts})
			if bool(new_specs.get("print_persist", false)):
				# Mud/clay/concrete print: the object dries in place on the map
				# (persistence handled by the 3D runtime -> terrain loader), so it
				# is NOT credited to the crafting inventory.
				_show_toast("%s finished: print dried in place" % str(new_specs.get("name", "Printer")))
			else:
				_credit_fabricated_part(new_specs)


## Read model for the 3D runtime: current job progress (clock-derived, smooth)
## and the job path id so CncMachineRuntime can load + trace the toolpath.
func get_cnc_job_state(item_id: String) -> Dictionary:
	if model == null or item_id.is_empty():
		return {}
	var item := model.get_item(item_id)
	if item.is_empty():
		return {}
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if str(specs.get("role", "")) != "cartesian_machine":
		return {}
	var m := _get_scene_main_node()
	var abs_hours := 0.0
	if m != null and m.has_method("get_absolute_hours"):
		abs_hours = float(m.call("get_absolute_hours"))
	var mid := str(specs.get("model_id", ""))
	var kind := str(specs.get("machine_kind", ""))
	var bed_lowering := bool(specs.get("bed_lowering",
		kind == "trash" or mid == "trash_printer"))
	return {
		"active": bool(specs.get("job_active", false)),
		"completed": bool(specs.get("job_completed", false)),
		"job_id": str(specs.get("job_id", "")),
		"progress": _CartesianMachineSource.progress_at(specs, abs_hours),
		"additive": str(specs.get("machine_role", "")) == "fdm_printer",
		"machine_kind": kind,
		"print_persist": bool(specs.get("print_persist", false)),
		"bed_lowering": bed_lowering,
		"print_mesh_path": str(specs.get("print_mesh_path", "")),
		"print_offset_x": float(specs.get("print_offset_x", 0.0)),
		"print_offset_z": float(specs.get("print_offset_z", 0.0)),
		"print_scale": float(specs.get("print_scale", 1.0)),
		"wet_color": specs.get("wet_color", [0.36, 0.26, 0.17]),
		"dry_color": specs.get("dry_color", [0.68, 0.56, 0.42]),
		"layer_height_mm": float(specs.get("layer_height_mm", 50.0)),
		"line_width_mm": float(specs.get("line_width_mm",
			specs.get("nozzle_diameter_mm", 76.2))),
	}


## Schedule a parsed G-code/STL job on a cartesian_machine node. `parse` is the
## dict from Toolpath/StlLoader. Returns true on success.
## Optional extra_specs keys: job_consume_part_id / job_consume_qty — inventory
## already debited by the caller (e.g. CNC cut presets); cancel restores them.
func start_machine_job(item_id: String, parse: Dictionary, part_id: String,
		part_label: String, part_count: int, extra_specs: Dictionary = {}) -> bool:
	if model == null or parse.is_empty() or not bool(parse.get("ok", true)):
		return false
	var item := model.get_item(item_id)
	if item.is_empty():
		return false
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	if str(specs.get("role", "")) != "cartesian_machine":
		return false
	for k: String in extra_specs.keys():
		specs[k] = extra_specs[k]
	var job := _CartesianMachineSource.derive_job(parse, specs)
	var job_id := MachineJobStore.save(parse)
	var m := _get_scene_main_node()
	var abs_hours := 0.0
	if m != null and m.has_method("get_absolute_hours"):
		abs_hours = float(m.call("get_absolute_hours"))
	specs["job_active"] = true
	specs["job_completed"] = false
	specs["job_id"] = job_id
	specs["job_name"] = str(part_label) if not part_label.is_empty() else "Job"
	specs["job_start_abs_hours"] = abs_hours
	specs["job_duration_hr"] = float(job.get("duration_hr", 0.0))
	specs["job_material_kind"] = str(job.get("material_kind", ""))
	specs["job_material_qty"] = float(job.get("material_qty", 0.0))
	specs["job_energy_kwh"] = float(job.get("energy_kwh", 0.0))
	specs["job_progress"] = 0.0
	specs["job_part_id"] = part_id if not part_id.is_empty() else part_label.to_snake_case()
	specs["job_part_label"] = part_label if not part_label.is_empty() else part_id
	specs["job_part_count"] = maxi(part_count, 1)
	specs["requested_state"] = "on"
	model.update_item(item_id, {"specs": specs})
	_schedule_graph_autosave()
	return true


## Start a built-in CNC cut preset: debit one beam from inventory, run the strut
## STL toolpath, credit the finished A/B strut on completion.
func start_cnc_cut_preset(item_id: String, preset_id: String) -> Dictionary:
	var preset: Dictionary = _CncCutPresets.find(preset_id)
	if preset.is_empty():
		return {"ok": false, "error": "unknown preset"}
	if model == null:
		return {"ok": false, "error": "no graph"}
	var item := model.get_item(item_id)
	if item.is_empty():
		return {"ok": false, "error": "missing node"}
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if str(specs.get("machine_role", "")) != "cnc_router" \
			and str(specs.get("model_id", "")) != "cnc_router":
		return {"ok": false, "error": "not a CNC router"}
	if bool(specs.get("job_active", false)):
		return {"ok": false, "error": "job already running"}
	var main := _get_scene_main_node()
	var loader := _find_terrain_loader(main) if main != null else null
	if loader == null or not loader.has_method("get_part_inventory"):
		return {"ok": false, "error": "no inventory"}
	var inv: PartInventory = loader.call("get_part_inventory") as PartInventory
	if inv == null:
		return {"ok": false, "error": "no inventory"}
	var need := maxi(int(preset.get("consume_qty", 1)), 1)
	if inv.count_beam_feedstock() < need:
		return {"ok": false, "error": "need %d recycled plastic beam(s) in inventory" % need}
	var consumed_id := inv.consume_beam_feedstock(need)
	if consumed_id.is_empty():
		return {"ok": false, "error": "could not debit beam feedstock"}
	if loader.has_method("save_part_inventory"):
		loader.call("save_part_inventory")
	var stl_path := str(preset.get("stl_path", ""))
	var parse := StlLoader.parse_file(stl_path, {
		"mode": "solid",
		"layer_height_mm": 2.0,
		"line_width_mm": 6.0,
		"print_speed_mm_s": 40.0,
		"scale": 1.0,
	})
	if not bool(parse.get("ok", false)):
		# Restore feedstock if the toolpath failed to load.
		inv.add_part(consumed_id, need, {
			"label": _DomeParts.label_for(_DomeParts.PART_BEAM),
			"material_kind": "plastic_flake",
			"source": "cnc_cut_restore",
		})
		if loader.has_method("save_part_inventory"):
			loader.call("save_part_inventory")
		return {"ok": false, "error": "could not load strut toolpath"}
	var produce_id := str(preset.get("produce_part_id", ""))
	var produce_label := str(preset.get("produce_label", produce_id))
	var ok := start_machine_job(item_id, parse, produce_id, produce_label, 1, {
		"job_consume_part_id": consumed_id,
		"job_consume_qty": need,
		"job_consume_label": _DomeParts.label_for(_DomeParts.PART_BEAM),
		"job_material_kind": "plastic_flake",
	})
	if not ok:
		inv.add_part(consumed_id, need, {
			"label": _DomeParts.label_for(_DomeParts.PART_BEAM),
			"material_kind": "plastic_flake",
			"source": "cnc_cut_restore",
		})
		if loader.has_method("save_part_inventory"):
			loader.call("save_part_inventory")
		return {"ok": false, "error": "could not start cut job"}
	return {"ok": true, "produce": produce_label, "consumed": consumed_id}


func cancel_machine_job(item_id: String) -> void:
	if model == null:
		return
	var item := model.get_item(item_id)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	# Restore beam feedstock debited for a cut preset that never finished.
	var consume_id := str(specs.get("job_consume_part_id", ""))
	var consume_qty := maxi(int(specs.get("job_consume_qty", 0)), 0)
	if not consume_id.is_empty() and consume_qty > 0 and bool(specs.get("job_active", false)):
		var main := _get_scene_main_node()
		var loader := _find_terrain_loader(main) if main != null else null
		if loader != null and loader.has_method("get_part_inventory"):
			var inv: PartInventory = loader.call("get_part_inventory") as PartInventory
			if inv != null:
				inv.add_part(consume_id, consume_qty, {
					"label": str(specs.get("job_consume_label", _DomeParts.label_for(_DomeParts.PART_BEAM))),
					"material_kind": "plastic_flake",
					"source": "cnc_cut_cancel",
				})
				if loader.has_method("save_part_inventory"):
					loader.call("save_part_inventory")
	specs.erase("job_consume_part_id")
	specs.erase("job_consume_qty")
	specs.erase("job_consume_label")
	specs["job_active"] = false
	specs["requested_state"] = "off"
	var inputs: Array = (specs.get("inputs", []) as Array).duplicate(true)
	if not inputs.is_empty() and inputs[0] is Dictionary:
		var inp0: Dictionary = (inputs[0] as Dictionary).duplicate(true)
		inp0["rate"] = 0.0
		inputs[0] = inp0
		specs["inputs"] = inputs
	model.update_item(item_id, {"specs": specs, "batch_active_watts": 0.0})


## Credit a completed machine job's output part to the per-map inventory (owned
## by the terrain loader). Groundwork for the crafting mechanic.
func _credit_fabricated_part(specs: Dictionary) -> void:
	var part_id := str(specs.get("job_part_id", ""))
	if part_id.is_empty():
		return
	var count := maxi(int(specs.get("job_part_count", 1)), 1)
	var label := str(specs.get("job_part_label", part_id))
	var meta := {
		"label": label,
		"material_kind": str(specs.get("job_material_kind", "")),
		"mass_kg": float(specs.get("job_material_qty", 0.0)),
		"source": str(specs.get("name", "machine")),
	}
	var main := _get_scene_main_node()
	var loader := _find_terrain_loader(main) if main != null else null
	if loader != null and loader.has_method("credit_part"):
		loader.call("credit_part", part_id, count, meta)
		_show_part_up_toast(label, count)


## Green "+N UP!" achievement toast (global ToastUI) with Inventory shortcut.
func _show_part_up_toast(label: String, count: int) -> void:
	var main := _get_scene_main_node()
	if main != null and main.has_method("show_part_up"):
		main.call("show_part_up", label, count)
		return
	var toast: Variant = main.get("toast_ui") if main != null else null
	if toast != null and is_instance_valid(toast) and toast.has_method("show_part_up"):
		toast.call("show_part_up", label, count)


## Precious Plastic beam extruder: while RUNNING, advance extruded length from
## flake throughput × sim-hours; cut at cut_length_m and credit inventory parts
## (same PartInventory path as CNC). 3D PpBeamExtruderRuntime reads state via
## get_pp_extruder_state.
func _tick_graph_pp_extruder(delta: float) -> void:
	if model == null:
		return
	_pp_extruder_acc += delta
	if _pp_extruder_acc < _PP_EXTRUDER_POLL_INTERVAL:
		return
	_pp_extruder_acc = 0.0

	var m := _get_scene_main_node()
	var abs_hours := 0.0
	if m != null and m.has_method("get_absolute_hours"):
		abs_hours = float(m.call("get_absolute_hours"))

	for item: Dictionary in model.items_of_type("processor"):
		var specs_ref: Dictionary = item.get("specs", {})
		if str(specs_ref.get("role", "")) != "pp_beam_extruder":
			continue
		var specs: Dictionary = specs_ref.duplicate(false)
		var iid: String = item.get("id", "") as String
		var running := str(specs.get("node_state", "")).to_lower() == GraphNodeState.RUNNING
		var last_h := float(specs.get("extrude_last_abs_hours", -1.0))
		var dt_h := 0.0
		if last_h >= 0.0:
			dt_h = abs_hours - last_h
		# Large jumps (load / scrub): don't invent hours of extrusion; just re-anchor.
		if dt_h < 0.0 or dt_h > 2.0:
			dt_h = 0.0

		var result := _PpBeamExtruderSource.advance(specs, dt_h, running)
		var beams := int(result.get("beams_cut", 0))

		specs["extruded_length_m"] = result.get("extruded_length_m", 0.0)
		specs["meters_per_hour"] = result.get("meters_per_hour", 0.0)
		specs["extrude_fill_fraction"] = result.get("fill_fraction", 0.0)
		# Always persist the clock anchor. A dirty-threshold gate previously
		# skipped tiny 1×-speed steps so last_h never advanced and length
		# looked frozen in the inspector until a large jump landed.
		specs["extrude_last_abs_hours"] = abs_hours

		# Demand rate stays at the rated flake_kg_h so ResourceFlowEngine can
		# transition READY→RUNNING; length only advances while RUNNING.
		var flake_rate := float(specs.get("flake_kg_h", 5.0))
		var inputs: Array = (specs.get("inputs", []) as Array).duplicate(true)
		if not inputs.is_empty() and inputs[0] is Dictionary:
			var inp0: Dictionary = (inputs[0] as Dictionary).duplicate(true)
			inp0["kind"] = "plastic_flake"
			inp0["rate"] = flake_rate
			inp0["unit"] = "kg/h"
			inputs[0] = inp0
			specs["inputs"] = inputs

		if beams > 0:
			var cut_len := float(result.get("cut_length_m", specs.get("cut_length_m", 2.0)))
			var cut_mass := float(result.get("cut_mass_kg", 0.0)) / float(beams)
			specs["beams_cut_total"] = int(specs.get("beams_cut_total", 0)) + beams
			specs["job_part_count"] = beams
			specs["job_material_kind"] = "plastic_flake"
			specs["job_material_qty"] = cut_mass
			# Beams are feedstock — CNC cut presets finish them into A/B struts.
			specs["job_part_id"] = _DomeParts.PART_BEAM
			specs["job_part_label"] = "%s (%.2f m)" % [
				_DomeParts.label_for(_DomeParts.PART_BEAM), cut_len]
			_credit_fabricated_part(specs)

		model.update_item(iid, {"specs": specs})
		_refresh_pp_extruder_inspector_if_selected(iid)


func _refresh_pp_extruder_inspector_if_selected(item_id: String) -> void:
	if _inspector_panel == null or not is_instance_valid(_inspector_panel):
		return
	if not _inspector_panel.has_method("refresh_pp_extruder_live"):
		return
	var sel := ""
	if _inspector_panel.has_method("current_item_id"):
		sel = str(_inspector_panel.call("current_item_id"))
	if sel == item_id:
		_inspector_panel.call("refresh_pp_extruder_live")


## Read model for PpBeamExtruderRuntime (3D grow/cut animation).
func get_pp_extruder_state(item_id: String) -> Dictionary:
	if model == null or item_id.is_empty():
		return {}
	var item := model.get_item(item_id)
	if item.is_empty():
		return {}
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if str(specs.get("role", "")) != "pp_beam_extruder":
		return {}
	return {
		"extruded_length_m": float(specs.get("extruded_length_m", 0.0)),
		"cut_length_m": float(specs.get("cut_length_m", 2.0)),
		"meters_per_hour": float(specs.get("meters_per_hour", 0.0)),
		"fill_fraction": float(specs.get("extrude_fill_fraction", 0.0)),
		"running": str(specs.get("node_state", "")).to_lower() == GraphNodeState.RUNNING,
		"beams_cut_total": int(specs.get("beams_cut_total", 0)),
	}


## Precious Plastic sheet press: batch cycle (melt → cool under pressure).
## Auto-starts when switched on + auto_cycle; pauses the clock while starved /
## unpowered; credits a 1 m² sheet to PartInventory on complete. Instantaneous
## heater draw is written to specs.watts so ResourceFlowEngine / AC wires see the
## warm-up peak + thermostat cycling.
func _tick_graph_pp_sheet_press(_delta: float) -> void:
	if model == null:
		return
	_pp_sheet_acc += _delta
	if _pp_sheet_acc < _PP_SHEET_POLL_INTERVAL:
		return
	_pp_sheet_acc = 0.0

	var m := _get_scene_main_node()
	var abs_hours := 0.0
	if m != null and m.has_method("get_absolute_hours"):
		abs_hours = float(m.call("get_absolute_hours"))

	for item: Dictionary in model.items_of_type("processor"):
		var specs_ref: Dictionary = item.get("specs", {})
		if str(specs_ref.get("role", "")) != "pp_sheet_press":
			continue
		var specs: Dictionary = specs_ref.duplicate(false)
		var iid: String = item.get("id", "") as String
		var ns := str(specs.get("node_state", "")).to_lower()
		var running := ns == GraphNodeState.RUNNING
		var switched_on := str(specs.get("requested_state", "on")).to_lower() != "off"
		var active := bool(specs.get("job_active", false))

		# Auto-queue the next sheet when idle.
		if not active and switched_on and bool(specs.get("auto_cycle", true)):
			if start_pp_sheet_press_job(iid):
				# Re-read after start.
				item = model.get_item(iid)
				specs = (item.get("specs", {}) as Dictionary).duplicate(true)
				active = bool(specs.get("job_active", false))

		if not active:
			# Standby: advertise peak so the inspector shows nameplate draw.
			var peak := float(specs.get("peak_watts", _PpSheetPressSource.PEAK_WATTS))
			var prev_w := float(specs.get("watts", -1.0))
			var inputs_idle: Array = (specs.get("inputs", []) as Array).duplicate(true)
			if not inputs_idle.is_empty() and inputs_idle[0] is Dictionary:
				var inp_i: Dictionary = (inputs_idle[0] as Dictionary).duplicate(true)
				if absf(float(inp_i.get("rate", 0.0))) > 1e-6:
					inp_i["rate"] = 0.0
					inputs_idle[0] = inp_i
					specs["inputs"] = inputs_idle
					model.update_item(iid, {"specs": specs, "batch_active_watts": 0.0})
				elif absf(prev_w - peak) > 1.0:
					specs["watts"] = peak
					model.update_item(iid, {"specs": specs, "batch_active_watts": 0.0})
			continue

		# Freeze absolute-hour progress while not RUNNING (starved / no power),
		# but keep flake demand so ResourceFlowEngine can still enter RUNNING.
		var progress := _PpSheetPressSource.progress_at(specs, abs_hours)
		if not running:
			var dur := maxf(float(specs.get("job_duration_hr", 0.0)), _PpSheetPressSource.MIN_JOB_HOURS)
			specs["job_start_abs_hours"] = abs_hours - progress * dur
			specs["job_phase"] = _PpSheetPressSource.phase_at(specs, abs_hours)
			specs["job_progress"] = progress
			specs["watts"] = float(specs.get("peak_watts", _PpSheetPressSource.PEAK_WATTS))
			var mat_qty_wait := float(specs.get("job_material_qty", 0.0))
			var mat_rate_wait := mat_qty_wait / dur if mat_qty_wait > 0.0 else 0.0
			var inputs_p: Array = (specs.get("inputs", []) as Array).duplicate(true)
			if not inputs_p.is_empty() and inputs_p[0] is Dictionary:
				var inp_p: Dictionary = (inputs_p[0] as Dictionary).duplicate(true)
				inp_p["kind"] = "plastic_flake"
				inp_p["rate"] = mat_rate_wait
				inp_p["unit"] = "kg/h"
				inputs_p[0] = inp_p
				specs["inputs"] = inputs_p
			model.update_item(iid, {"specs": specs, "batch_active_watts": 0.0})
			continue

		progress = _PpSheetPressSource.progress_at(specs, abs_hours)
		var phase := _PpSheetPressSource.phase_at(specs, abs_hours)
		var watts := _PpSheetPressSource.power_watts_at(specs, abs_hours)
		# Spread flake demand over the full cycle so ResourceFlowEngine keeps a
		# positive I/O rate (cool phase would otherwise look idle).
		var mat_rate := 0.0
		var mat_qty := float(specs.get("job_material_qty", 0.0))
		var dur_h := maxf(float(specs.get("job_duration_hr", 0.0)), _PpSheetPressSource.MIN_JOB_HOURS)
		if mat_qty > 0.0 and progress < 1.0:
			mat_rate = mat_qty / dur_h

		var new_specs: Dictionary = specs.duplicate(true)
		new_specs["job_progress"] = progress
		new_specs["job_phase"] = phase
		new_specs["watts"] = watts
		var inputs: Array = (new_specs.get("inputs", []) as Array).duplicate(true)
		if not inputs.is_empty() and inputs[0] is Dictionary:
			var inp0: Dictionary = (inputs[0] as Dictionary).duplicate(true)
			inp0["kind"] = "plastic_flake"
			inp0["rate"] = mat_rate
			inp0["unit"] = "kg/h"
			inputs[0] = inp0
			new_specs["inputs"] = inputs
		new_specs["requested_state"] = "on"

		var completed_now := false
		if progress >= 1.0 and not bool(specs.get("job_completed", false)):
			new_specs["job_active"] = false
			new_specs["job_completed"] = true
			new_specs["job_phase"] = "done"
			new_specs["watts"] = 0.0
			if not inputs.is_empty() and inputs[0] is Dictionary:
				var inp_done: Dictionary = (inputs[0] as Dictionary).duplicate(true)
				inp_done["rate"] = 0.0
				inputs[0] = inp_done
				new_specs["inputs"] = inputs
			completed_now = true

		var prev_progress := float(specs.get("job_progress", -1.0))
		var prev_watts := float(item.get("batch_active_watts", -1.0))
		var dirty := completed_now or absf(prev_progress - progress) > 0.002 \
			or absf(prev_watts - watts) > 25.0 \
			or str(specs.get("job_phase", "")) != phase
		if not dirty:
			continue
		model.update_item(iid, {"specs": new_specs, "batch_active_watts": watts})
		if completed_now:
			new_specs["sheets_pressed_total"] = int(specs.get("sheets_pressed_total", 0)) + 1
			new_specs["job_material_kind"] = "plastic_flake"
			# Hybrid chore: unload step may require confirm before inventory credit.
			var recipe := ProcessRecipeCatalog.find(str(new_specs.get("selected_recipe_id", "")))
			var needs_unload_confirm := false
			var unload_label := "Unload sheet"
			var unload_hrs := 0.0
			for s: Variant in ProcessRecipe.end_steps(recipe):
				if s is Dictionary and bool((s as Dictionary).get("require_confirm", false)):
					needs_unload_confirm = true
					unload_label = str((s as Dictionary).get("label", unload_label))
					unload_hrs = float((s as Dictionary).get("chore_hours", 0.0))
					break
			if needs_unload_confirm and not bool(new_specs.get("sheet_unload_confirmed", false)):
				new_specs["recipe_waiting_chore"] = true
				new_specs["recipe_waiting_step_id"] = "unload"
				new_specs["recipe_waiting_label"] = unload_label
				new_specs["recipe_waiting_chore_hrs"] = unload_hrs
				new_specs["sheet_credit_pending"] = true
				model.update_item(iid, {"specs": new_specs})
				_on_recipe_chore_waiting(iid, {
					"step_id": "unload",
					"label": unload_label,
					"chore_hours": unload_hrs,
				})
			else:
				model.update_item(iid, {"specs": new_specs})
				_credit_fabricated_part(new_specs)
				# Allow auto_cycle to queue the next sheet on a later tick.
				if bool(new_specs.get("auto_cycle", true)):
					new_specs["job_completed"] = false
					new_specs.erase("sheet_unload_confirmed")
					model.update_item(iid, {"specs": new_specs})


## Schedule one sheet-press cycle from the current thickness setpoint.
func start_pp_sheet_press_job(item_id: String) -> bool:
	if model == null or item_id.is_empty():
		return false
	var item := model.get_item(item_id)
	if item.is_empty():
		return false
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	if str(specs.get("role", "")) != "pp_sheet_press":
		return false
	if bool(specs.get("job_active", false)):
		return false
	var job := _PpSheetPressSource.derive_job(specs)
	var m := _get_scene_main_node()
	var abs_hours := 0.0
	if m != null and m.has_method("get_absolute_hours"):
		abs_hours = float(m.call("get_absolute_hours"))
	specs["job_active"] = true
	specs["job_completed"] = false
	specs["job_start_abs_hours"] = abs_hours
	specs["job_duration_hr"] = float(job.get("duration_hr", 0.0))
	specs["job_melt_hr"] = float(job.get("melt_hr", 0.0))
	specs["job_cool_hr"] = float(job.get("cool_hr", 0.0))
	specs["job_material_qty"] = float(job.get("material_kg", 0.0))
	specs["job_material_kind"] = "plastic_flake"
	specs["job_avg_kwh_per_h"] = float(job.get("avg_kwh_per_h", 4.0))
	specs["job_energy_kwh"] = float(job.get("energy_kwh", 0.0))
	specs["job_progress"] = 0.0
	specs["job_phase"] = "melt"
	specs["sheet_thickness_mm"] = float(job.get("thickness_mm", 8.0))
	specs["job_part_id"] = str(job.get("part_id", "pp_sheet"))
	specs["job_part_label"] = str(job.get("part_label", "Recycled Plastic Sheet"))
	specs["job_part_count"] = 1
	specs["requested_state"] = "on"
	# Seed a positive flake rate so ResourceFlowEngine can enter RUNNING.
	var mat_rate := float(job.get("material_kg", 0.0)) / maxf(float(job.get("duration_hr", 1.0)), 0.01)
	var inputs: Array = (specs.get("inputs", []) as Array).duplicate(true)
	if inputs.is_empty():
		inputs = [{"kind": "plastic_flake", "rate": mat_rate, "unit": "kg/h"}]
	elif inputs[0] is Dictionary:
		var inp0: Dictionary = (inputs[0] as Dictionary).duplicate(true)
		inp0["kind"] = "plastic_flake"
		inp0["rate"] = mat_rate
		inp0["unit"] = "kg/h"
		inputs[0] = inp0
	specs["inputs"] = inputs
	specs["watts"] = float(specs.get("peak_watts", _PpSheetPressSource.PEAK_WATTS))
	model.update_item(item_id, {"specs": specs})
	_schedule_graph_autosave()
	return true


func cancel_pp_sheet_press_job(item_id: String) -> void:
	if model == null:
		return
	var item := model.get_item(item_id)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs["job_active"] = false
	specs["job_completed"] = false
	specs["job_phase"] = "idle"
	specs["job_progress"] = 0.0
	specs["watts"] = float(specs.get("peak_watts", _PpSheetPressSource.PEAK_WATTS))
	var inputs: Array = (specs.get("inputs", []) as Array).duplicate(true)
	if not inputs.is_empty() and inputs[0] is Dictionary:
		var inp0: Dictionary = (inputs[0] as Dictionary).duplicate(true)
		inp0["rate"] = 0.0
		inputs[0] = inp0
		specs["inputs"] = inputs
	model.update_item(item_id, {"specs": specs, "batch_active_watts": 0.0})


## Read model for PpSheetPressRuntime (Z-axis + sheet reveal).
func get_pp_sheet_press_state(item_id: String) -> Dictionary:
	if model == null or item_id.is_empty():
		return {}
	var item := model.get_item(item_id)
	if item.is_empty():
		return {}
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if str(specs.get("role", "")) != "pp_sheet_press":
		return {}
	var m := _get_scene_main_node()
	var abs_hours := 0.0
	if m != null and m.has_method("get_absolute_hours"):
		abs_hours = float(m.call("get_absolute_hours"))
	return {
		"active": bool(specs.get("job_active", false)),
		"completed": bool(specs.get("job_completed", false)),
		"phase": _PpSheetPressSource.phase_at(specs, abs_hours),
		"progress": _PpSheetPressSource.progress_at(specs, abs_hours),
		"compression": _PpSheetPressSource.compression_at(specs, abs_hours),
		"thickness_mm": float(specs.get("sheet_thickness_mm", 8.0)),
		"z_stroke_m": float(specs.get("z_stroke_m", 0.12)),
		"watts": float(specs.get("watts", 0.0)),
		"sheets_pressed_total": int(specs.get("sheets_pressed_total", 0)),
	}


## Open the Machine Setup modal (X/Y/Z axis tagging + jog calibration) for a
## machine model. Lazily instantiated under the main UILayer.
func open_machine_setup(model_id: String, item_id: String) -> void:
	if model_id.is_empty():
		return
	if _machine_setup_modal == null or not is_instance_valid(_machine_setup_modal):
		_machine_setup_modal = _MACHINE_SETUP_MODAL.new()
		var main := _get_scene_main_node()
		var ui := main.get_node_or_null("UILayer") if main != null else null
		if ui != null:
			ui.add_child(_machine_setup_modal)
		else:
			add_child(_machine_setup_modal)
	_machine_setup_modal.call("open", model_id, item_id)


## Open the Connection Port modal — tag plugs/inlets on a GLB for 3D conduits.
## Live 3D conduit style preview for a focused/selected connection.
func open_conduit_style_modal(conn_id: String) -> void:
	if model == null or conn_id.is_empty():
		return
	var conn := model.get_connection(conn_id)
	if conn.is_empty():
		return
	# Cancel in-world routing first — its HUD CanvasLayer sat above UILayer and
	# RouteController._input was eating modal clicks via center-ray wire picks.
	_cancel_conduit_routing_for_modal()
	if _conduit_style_modal == null or not is_instance_valid(_conduit_style_modal):
		_conduit_style_modal = _CONDUIT_STYLE_MODAL.new()
		_conduit_style_modal.name = "ConduitStyleModal"
		var main := _get_scene_main_node()
		var ui := main.get_node_or_null("UILayer") if main != null else null
		if ui != null:
			var layer := ui.get_node_or_null("ConduitStyleLayer") as CanvasLayer
			if layer == null:
				layer = CanvasLayer.new()
				layer.name = "ConduitStyleLayer"
				layer.layer = UITheme.LAYER_MODAL
				ui.add_child(layer)
			layer.add_child(_conduit_style_modal)
		else:
			add_child(_conduit_style_modal)
		if _conduit_style_modal.has_signal("style_applied") \
				and not _conduit_style_modal.is_connected("style_applied", _on_conduit_style_applied):
			_conduit_style_modal.connect("style_applied", _on_conduit_style_applied)
	_conduit_style_modal.call("open", conn_id, model, _get_scene_main_node())


func _cancel_conduit_routing_for_modal() -> void:
	var main := _get_scene_main_node()
	if main == null:
		return
	var player := main.get_node_or_null("Player")
	if player != null:
		var ctrl := player.get_node_or_null("ConduitRouteController")
		if ctrl != null and ctrl.has_method("is_routing") and bool(ctrl.call("is_routing")) \
				and ctrl.has_method("cancel_route"):
			ctrl.call("cancel_route")
	var route_ui := main.get_node_or_null("UILayer/ConduitRouteUI")
	if route_ui != null and route_ui.has_method("hide_route"):
		route_ui.call("hide_route")


func _on_conduit_style_applied(_conn_id: String) -> void:
	var mgr := _get_conduit_manager()
	if mgr != null and mgr.has_method("sync_all"):
		mgr.call("sync_all")
	_schedule_graph_autosave()


func open_connection_ports(item_id: String) -> void:
	if model == null or item_id.is_empty():
		return
	var item := model.get_item(item_id)
	if item.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var model_id := str(specs.get("model_id", ""))
	if model_id.is_empty():
		_show_toast("This node has no linked 3D model")
		return
	if _connection_port_modal == null or not is_instance_valid(_connection_port_modal):
		_connection_port_modal = _CONNECTION_PORT_MODAL.new()
		var main := _get_scene_main_node()
		var ui := main.get_node_or_null("UILayer") if main != null else null
		if ui != null:
			ui.add_child(_connection_port_modal)
		else:
			add_child(_connection_port_modal)
		if _connection_port_modal.has_signal("ports_saved") \
				and not _connection_port_modal.is_connected("ports_saved", _on_connection_ports_saved):
			_connection_port_modal.connect("ports_saved", _on_connection_ports_saved)
	# Pass full 2D handle dicts (id / polarity / direction / label) so the
	# modal can list IN/OUT · type · name instead of free-form naming.
	var handle_dicts: Array = []
	var src_handles: Array = item.get("handles", []) as Array
	if _graph_canvas != null and _graph_canvas.has_method("_resolved_handles"):
		src_handles = _graph_canvas.call("_resolved_handles", item) as Array
	for h2: Variant in src_handles:
		if h2 is Dictionary:
			handle_dicts.append((h2 as Dictionary).duplicate(true))
	_connection_port_modal.call("open", model_id, item_id,
		str(specs.get("bound_prop_id", "")), handle_dicts, model)


func open_connection_ports_for_prop(prop_id: String) -> void:
	if model == null or prop_id.is_empty():
		return
	var item_id := find_item_by_bound_prop_id(prop_id)
	if item_id.is_empty():
		# Open against the prop's model with no graph item.
		var main := _get_scene_main_node()
		var rec := PlacedPropService.get_prop_record(main, prop_id)
		var mid := str(rec.get("model_id", ""))
		if mid.is_empty():
			return
		if _connection_port_modal == null or not is_instance_valid(_connection_port_modal):
			_connection_port_modal = _CONNECTION_PORT_MODAL.new()
			var ui := main.get_node_or_null("UILayer") if main != null else null
			if ui != null:
				ui.add_child(_connection_port_modal)
			else:
				add_child(_connection_port_modal)
			if _connection_port_modal.has_signal("ports_saved") \
					and not _connection_port_modal.is_connected("ports_saved", _on_connection_ports_saved):
				_connection_port_modal.connect("ports_saved", _on_connection_ports_saved)
		_connection_port_modal.call("open", mid, "", prop_id, PackedStringArray())
		return
	open_connection_ports(item_id)


func _on_connection_ports_saved(_model_id: String, prop_id: String) -> void:
	if not prop_id.is_empty():
		var main := _get_scene_main_node()
		var prop := PlacedPropRuntime.find_by_prop_id(main, prop_id)
		if prop != null:
			var ports := ConnectionPortDefs.resolve_ports_for_prop(main, prop_id)
			ConnectionPortDefs.sync_port_markers(prop, ports)
	var mgr := _get_conduit_manager()
	if mgr != null and mgr.has_method("sync_all"):
		mgr.call("sync_all")
	_schedule_graph_autosave()


## Open the shared FDM Print Setup modal for a placed additive printer (aimed
## via the crosshair). Returns true if handled — any machine_role=fdm_printer
## (mud, trash, or future). The modal drives CncMachineRuntime's STL ghost live
## and starts the job with placement/scale/color/slicer params.
func open_print_setup_for_prop(prop_id: String) -> bool:
	if model == null or prop_id.is_empty():
		return false
	var main := _get_scene_main_node()
	if main == null:
		return false
	var prop := PlacedPropRuntime.find_by_prop_id(main, prop_id)
	if prop == null:
		return false
	var runtime := prop.get_node_or_null("CncMachineRuntime")
	if runtime == null:
		return false
	var item_id := str(runtime.get("graph_item_id"))
	var item := model.get_item(item_id) if not item_id.is_empty() else {}
	var mid := str(prop.model_id)
	# Self-heal missing graph bind for known FDM printers.
	if item.is_empty() and (mid == "mud_printer" or mid == "trash_printer"):
		item_id = _rebind_printer_graph_node(prop_id, mid)
		if item_id.is_empty():
			return false
		item = model.get_item(item_id)
		runtime.set("graph_item_id", item_id)
	if item.is_empty():
		return false
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	if str(specs.get("machine_role", "")) != "fdm_printer":
		return false
	if str(specs.get("model_id", "")).is_empty():
		specs["model_id"] = mid
	var kind := str(specs.get("machine_kind", ""))
	if kind.is_empty():
		if mid == "trash_printer":
			specs["machine_kind"] = "trash"
		elif mid == "mud_printer":
			specs["machine_kind"] = "mud"
	if _print_setup_modal == null or not is_instance_valid(_print_setup_modal):
		_print_setup_modal = _PRINT_SETUP_MODAL.new()
		var ui := main.get_node_or_null("UILayer")
		if ui != null:
			ui.add_child(_print_setup_modal)
		else:
			add_child(_print_setup_modal)
	_print_setup_modal.call("open", runtime, item_id, self, specs)
	return true


## Open the Mud Building Designer. If item_id is empty, binds the first mud
## printer graph node + its placed CncMachineRuntime (when available).
func open_mud_building_designer(item_id: String = "") -> bool:
	var iid := item_id
	var specs: Dictionary = {}
	var runtime: CncMachineRuntime = null
	if iid.is_empty() and model != null:
		for item: Dictionary in model.items:
			if str(item.get("type", "")) != "processor":
				continue
			var sp: Dictionary = item.get("specs", {}) as Dictionary
			if str(sp.get("model_id", "")) == "mud_printer" \
					or str(sp.get("machine_kind", "")) == "mud":
				iid = str(item.get("id", ""))
				specs = sp
				break
	elif model != null and not iid.is_empty():
		var item := model.get_item(iid)
		specs = item.get("specs", {}) as Dictionary if not item.is_empty() else {}
	if specs.is_empty():
		specs = {
			"machine_kind": "mud", "model_id": "mud_printer",
			"filament_diameter_mm": 76.2,
			"work_x_mm": 3048.0, "work_y_mm": 3048.0, "work_z_mm": 3048.0,
			"print_speed_mm_s": 120.0,
			"wet_color": [0.36, 0.26, 0.17], "dry_color": [0.68, 0.56, 0.42],
		}
	var main := _get_scene_main_node()
	if main != null and not iid.is_empty():
		# Prefer the runtime bound to this graph node.
		for n in main.find_children("*", "CncMachineRuntime", true, false):
			var rt := n as CncMachineRuntime
			if rt != null and str(rt.get("graph_item_id")) == iid:
				runtime = rt
				break
	if _mud_building_designer == null or not is_instance_valid(_mud_building_designer):
		_mud_building_designer = _MUD_BUILDING_DESIGNER.new()
		var ui := main.get_node_or_null("UILayer") if main != null else null
		if ui != null:
			ui.add_child(_mud_building_designer)
		else:
			add_child(_mud_building_designer)
	_mud_building_designer.call("open", self, iid, runtime, specs)
	return true


## Recreate a bound processor graph node for a mud/trash printer prop.
func _rebind_printer_graph_node(prop_id: String, model_id: String) -> String:
	var preset: Dictionary = {}
	for p: Dictionary in ComponentPresets.TOOLS:
		if str((p.get("specs", {}) as Dictionary).get("model_id", "")) == model_id:
			preset = p
			break
	if preset.is_empty():
		return ""
	var graph_link := {
		"node_type": "processor",
		"label": str(preset.get("label", model_id)),
		"icon": str(preset.get("icon", "🖨")),
		"width": float(preset.get("width", 150.0)),
		"height": float(preset.get("height", 130.0)),
		"specs": (preset.get("specs", {}) as Dictionary).duplicate(true),
	}
	var node_id := create_bound_generator_node(prop_id, graph_link)
	if node_id.is_empty():
		return ""
	var main := _get_scene_main_node()
	if main != null:
		PlacedPropService.update_prop_record(main, prop_id, {"graph_item_id": node_id}, false)
	return node_id


func _rebind_mud_printer_graph_node(prop_id: String) -> String:
	return _rebind_printer_graph_node(prop_id, "mud_printer")


## Phase 5: throttled per-node 3D shade → specs.sunlight_factor.
## Site-placed panels/plants get a ray toward the sun; nodes without site
## coords keep ambient 1.0. Round-robins so large graphs stay cheap.
func _tick_graph_solar_shading(delta: float) -> void:
	if model == null:
		return
	_shade_acc += delta
	if _shade_acc < _SHADE_POLL_INTERVAL:
		return
	_shade_acc = 0.0

	var main := _get_scene_main_node()
	if main == null or not main.is_inside_tree():
		return
	var world: World3D = main.get_world_3d()
	if world == null:
		return
	var space := world.direct_space_state
	if space == null:
		return

	var sun_dir := Vector3.UP
	var clock = main.get("clock")
	if clock != null and clock.has_method("get_sun_direction"):
		sun_dir = clock.call("get_sun_direction") as Vector3
	elif main.get("sun") is Node3D:
		var sun_n: Node3D = main.get("sun") as Node3D
		# Match SolarUI: DirectionalLight basis.z points toward the sun.
		sun_dir = sun_n.global_transform.basis.z

	var soi := get_node_or_null("/root/SoiService")
	var center := Vector3.ZERO
	if soi != null and soi.has_method("world_center"):
		center = soi.call("world_center") as Vector3

	var receivers: Array = []
	for item: Dictionary in model.items:
		if bool(item.get("is_virtual", false)):
			continue
		if not GraphSolarShading.is_receiver_type(str(item.get("type", ""))):
			continue
		if not GraphSiteLayout.has_site_coords(item):
			continue
		receivers.append(item)
	if receivers.is_empty():
		return

	var n := receivers.size()
	_shade_cursor = _shade_cursor % n
	var budget := mini(_SHADE_RAYS_PER_TICK, n)
	for i in budget:
		var item: Dictionary = receivers[(_shade_cursor + i) % n] as Dictionary
		var iid := str(item.get("id", ""))
		if iid.is_empty():
			continue
		var factor := GraphSolarShading.shade_factor_for_item(
				item, main, center, sun_dir, space)
		var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		if specs.has("sunlight_factor") \
				and absf(float(specs.get("sunlight_factor", 1.0)) - factor) < 0.001:
			continue
		specs["sunlight_factor"] = factor
		specs["shade_factor"] = factor  # geometric alias for inspector/debug
		model.update_item(iid, {"specs": specs})
	_shade_cursor = (_shade_cursor + budget) % n


## Pond + culvert Hydro Section snapshot for an intake item (or {}).
## Live Hydro Section readout (Elevation toolbar chip). Refreshed on renewables tick.
func refresh_hydro_section_panel() -> void:
	if _hydro_section_lbl == null:
		return
	if _graph_view_mode != GraphSiteLayout.VIEW_ELEVATION:
		_hydro_section_lbl.visible = false
		return
	_hydro_section_lbl.visible = true
	var tank := HydroSectionCalculator.find_pond_tank(model)
	if tank.is_empty():
		_hydro_section_lbl.text = "Hydro Section · no pond tank on graph"
		return
	var tag := str((tank.get("specs", {}) as Dictionary).get("osm_water_tag", ""))
	var level_m := HydroSectionCalculator.pond_level_m_from_tank(tank)
	var culverts := HydroSectionCalculator.culverts_from_model(model, tag)
	var hydro_specs := {}
	for h in model.items_of_type("processor") if model != null else []:
		if h is Dictionary \
				and str(((h as Dictionary).get("specs", {}) as Dictionary).get("role", "")) == "siphon_hydro":
			hydro_specs = (h as Dictionary).get("specs", {}) as Dictionary
			break
	var cur_month := 6
	var main_for_month := _get_scene_main_node()
	if main_for_month != null and main_for_month.get("clock") != null:
		cur_month = int(main_for_month.get("clock").get("month"))
	var snap := HydroSectionCalculator.evaluate(level_m, culverts, hydro_specs, NAN, cur_month)
	if is_nan(level_m):
		_hydro_section_lbl.text = "Hydro · pond level unavailable (bind a live pond)"
		return
	var q := float(snap.get("live_q_lps", 0.0))
	var h := float(snap.get("gross_head_m", 0.0))
	var pe := float(snap.get("pe_kw", 0.0))
	var gen := float(snap.get("gen_kw", 0.0))
	if is_nan(q):
		q = 0.0
	if is_nan(h):
		h = 0.0
	if is_nan(pe):
		pe = 0.0
	if is_nan(gen):
		gen = 0.0
	var mode := str(snap.get("mode", "potential"))
	if mode == "generation":
		_hydro_section_lbl.text = (
			"Hydro · Q %.1f L/s · H %.1f m · gen %.2f kW · %d/%d open" % [
				q, h, gen,
				int(snap.get("open_count", 0)),
				int(snap.get("culvert_count", 0)),
			])
	else:
		_hydro_section_lbl.text = (
			"Hydro · Q %.1f L/s · H %.1f m · PE %.2f kW · %d/%d open" % [
				q, h, pe,
				int(snap.get("open_count", 0)),
				int(snap.get("culvert_count", 0)),
			])


# ---------------------------------------------------------------------------
# Make Array quick button (floats over a multi-selection of array candidates)
# ---------------------------------------------------------------------------

var _make_array_quick_btn: Button = null


func _build_make_array_quick_button() -> void:
	_make_array_quick_btn = Button.new()
	_make_array_quick_btn.text = "Make Array"
	_make_array_quick_btn.custom_minimum_size = Vector2(108.0, 28.0)
	_make_array_quick_btn.visible = false
	_make_array_quick_btn.focus_mode = Control.FOCUS_NONE
	_make_array_quick_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	_make_array_quick_btn.add_theme_font_size_override("font_size", 11)
	_make_array_quick_btn.pressed.connect(func() -> void:
		_on_make_array_pressed()
		_update_make_array_quick_button()
	)
	add_child(_make_array_quick_btn)


func _selection_screen_bounds(ids: Array[String]) -> Rect2:
	var c := _graph_canvas as Control
	if c == null:
		return Rect2()
	var pan := c.get("_pan") as Vector2
	var zoom := float(c.get("_zoom"))
	var canvas_center := c.size * 0.5
	var min_x := 1e20
	var min_y := 1e20
	var max_x := -1e20
	var max_y := -1e20
	for sid: String in ids:
		var it := model.get_item(sid)
		if it.is_empty():
			continue
		var tl := canvas_center + pan + Vector2(float(it.get("x", 0.0)), float(it.get("y", 0.0))) * zoom
		var sz := Vector2(float(it.get("width", 120.0)), float(it.get("height", 90.0))) * zoom
		min_x = minf(min_x, tl.x)
		min_y = minf(min_y, tl.y)
		max_x = maxf(max_x, tl.x + sz.x)
		max_y = maxf(max_y, tl.y + sz.y)
	if min_x > max_x or min_y > max_y:
		return Rect2()
	return Rect2(Vector2(min_x, min_y), Vector2(max_x - min_x, max_y - min_y))


func _update_make_array_quick_button() -> void:
	if _make_array_quick_btn == null:
		return
	_make_array_quick_btn.visible = false
	if not visible or model == null or _graph_canvas == null:
		return
	var selected := _get_group_candidates(true)
	if selected.size() < 2:
		return
	for sid: String in selected:
		if not _is_array_candidate(model.get_item(sid)):
			return
	var rect := _selection_screen_bounds(selected)
	if rect.size.length() <= 0.0:
		return
	var gc := _graph_canvas as Control
	var center := rect.position + rect.size * 0.5
	var btn_size := _make_array_quick_btn.size
	if btn_size.x <= 0.0:
		btn_size = _make_array_quick_btn.get_combined_minimum_size()
	_make_array_quick_btn.position = gc.position + center - Vector2(btn_size.x * 0.5, 34.0)
	_make_array_quick_btn.visible = true


# ---------------------------------------------------------------------------
# PV voltage faults, controller destroy/reset, layout, series/parallel wiring
# ---------------------------------------------------------------------------

func _ambient_temp_c_for_voc() -> float:
	if is_instance_valid(_solar_ui):
		if _solar_ui.has_method("_estimate_ambient_temp"):
			return float(_solar_ui.call("_estimate_ambient_temp"))
	return 15.0


func _count_panel_selection() -> int:
	var n := 0
	for sid: String in _selected_item_ids:
		if _is_array_candidate(model.get_item(sid)):
			n += 1
	return n


func _panel_selection_ids() -> Array[String]:
	var out: Array[String] = []
	for sid: String in _selected_item_ids:
		if _is_array_candidate(model.get_item(sid)):
			out.append(sid)
	return out


## Flag reversed wires and punish them by kind. Flags ride on the connection
## itself (precedent: `voltage_mismatch`) so drawing and hit-testing need no
## extra traversal, and are cleared when the player fixes the wiring.
func _apply_reverse_polarity() -> void:
	var reversed := GraphDcElectrical.find_reverse_polarity(model, _dc_flat_conns)
	var flagged: Dictionary = {}
	var pv_case: Dictionary = {}
	for r in reversed:
		var rd: Dictionary = r
		flagged[str(rd.get("conn_id", ""))] = true
		if str(rd.get("kind", "")) == "battery":
			_destroy_battery(str(rd.get("other_id", "")),
				GraphNodeState.REASON_REVERSE_POLARITY,
				"Reversed polarity — + wired to −",
				{"kind": "battery"})
		elif pv_case.is_empty():
			pv_case = rd
	# Sync the flag on every DC wire (set AND clear) so fixing the wiring
	# clears the red without needing a reset.
	for conn: Dictionary in model.connections:
		var cid := str(conn.get("id", ""))
		var want := flagged.has(cid)
		if bool(conn.get("reverse_polarity", false)) != want:
			model.update_connection(cid, {"reverse_polarity": want})
	# One advisory per fresh PV reversal — non-destructive, so a toast + card
	# rather than a blast. Latched so it doesn't re-fire every fault pass.
	if pv_case.is_empty():
		_pv_reverse_notified = false
	elif not _pv_reverse_notified:
		_pv_reverse_notified = true
		_show_toast("⚠ Panels are wired backwards — the array is delivering nothing", 4.0)
		_show_fault_card(GraphNodeState.REASON_REVERSE_POLARITY, {"kind": "pv"})
		electrical_fault_observed.emit(GraphNodeState.REASON_REVERSE_POLARITY,
			str(pv_case.get("controller_id", "")))


func _any_controller_destroyed() -> bool:
	if model == null:
		return false
	for item in GraphNesting.walk_items(model, "root"):
		if not (item is Dictionary):
			continue
		if str((item as Dictionary).get("type", "")) != "controller":
			continue
		var sp: Dictionary = (item as Dictionary).get("specs", {}) as Dictionary
		if bool(sp.get("destroyed", false)):
			return true
	return false


func _sync_graph_controller_ac_fault() -> void:
	if not is_instance_valid(_solar_ui):
		return
	if _solar_ui.has_method("set_graph_controller_destroyed"):
		_solar_ui.call("set_graph_controller_destroyed", _any_controller_destroyed())


func _check_electrical_faults() -> void:
	if model == null or _checking_voltage:
		return
	_checking_voltage = true
	var temp_c := _ambient_temp_c_for_voc()
	# Nesting-aware: flatten super-node portals and scan EVERY scope at once, so a
	# PV string split across a compound boundary or buried in a collapsed
	# sub-canvas still faults correctly.
	PvElectrical.update_connection_voltage_flags_flat(model, temp_c)
	# DC-side topology (battery banks, shorts) — cached for _tick_dc_throttle.
	_dc_flat_conns = GraphNesting.flat_connections(model)
	_dc_analysis = GraphDcElectrical.analyze(model, _dc_flat_conns)
	# 0) Reverse polarity. Checked BEFORE the destructive families so a crossed
	# battery lead is reported as what it is rather than as a downstream
	# symptom. PV reversal is non-destructive (a panel is a current source and
	# simply delivers nothing); a reversed battery lead kills the pack.
	_apply_reverse_polarity()
	# 1) Battery short circuits: burn the loop's wires, destroy the battery.
	for s in _dc_analysis.get("shorts", []) as Array:
		if not (s is Dictionary):
			continue
		var sd: Dictionary = s
		_burn_short_wires(sd.get("conn_ids", []) as Array)
		_destroy_battery(str(sd.get("battery_id", "")),
			GraphNodeState.REASON_SHORT_CIRCUIT,
			"Short circuit — %.0f V across bare wire" % float(sd.get("loop_emf_v", 12.0)),
			{"loop_emf_v": float(sd.get("loop_emf_v", 12.0))})
	# 2) Unregulated PV overcharging a bank (no controller in the path).
	for f_ov in GraphDcElectrical.find_battery_overvoltage(
			model, _dc_flat_conns, _dc_analysis, temp_c) as Array:
		if not (f_ov is Dictionary):
			continue
		var fd: Dictionary = f_ov
		var params := {"string_voc": float(fd.get("string_voc", 0.0)),
			"safe_v": float(fd.get("safe_v", 14.6))}
		for bid in fd.get("battery_ids", []) as Array:
			_destroy_battery(str(bid), GraphNodeState.REASON_BATTERY_OVERVOLTAGE,
				"PV Voc %.0f V > charge limit %.0f V" % [
					float(fd.get("string_voc", 0.0)), float(fd.get("safe_v", 14.6))],
				params)
	# 3) PV string Voc over a controller's input rating (existing fault).
	var faults: Array = PvElectrical.find_overvoltage_faults_flat(model, temp_c)
	for f in faults:
		if not (f is Dictionary):
			continue
		var cid := str((f as Dictionary).get("controller_id", ""))
		var it := model.get_item(cid)
		if it.is_empty():
			continue
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		if bool(sp.get("destroyed", false)):
			continue
		_destroy_controller(cid, float((f as Dictionary).get("string_voc", 0.0)),
			float((f as Dictionary).get("max_voc", 0.0)))
	_sync_graph_controller_ac_fault()
	if _graph_canvas != null:
		_graph_canvas.call("queue_redraw")
	_checking_voltage = false


## Wave 8: integrate per-connection overload heat and sever burned-out
## connectors. Telemetry (overload_ratio) is refreshed by GraphAcLoad /
## ResourceFlowEngine only while loss simulation is on, so this is a no-op
## with losses off (ratios stay 0 and heat decays).
func _tick_connector_burnout(delta: float) -> void:
	if model == null:
		return
	for conn: Dictionary in model.connections:
		if bool(conn.get("severed", false)):
			continue
		var ratio: float = float(conn.get("overload_ratio", 0.0))
		var heat: float = float(conn.get("overload_s", 0.0))
		var new_heat: float = ConduitLoss.step_overload_heat(heat, ratio, delta)
		if absf(new_heat - heat) > 0.0001:
			conn["overload_s"] = new_heat  # direct write — no signal churn
		if ConduitLoss.is_burned_out(new_heat):
			_sever_connection(conn)


func _sever_connection(conn: Dictionary) -> void:
	var cid := str(conn.get("id", ""))
	if cid.is_empty():
		return
	var type_id: String = ConduitKinds.derive_type_for_connection(conn)
	var electrical: bool = ConduitKinds.is_electrical_type(type_id)
	model.update_connection(cid, {"severed": true, "overload_s": 0.0})
	var verb := "burned out" if electrical else "burst"
	_show_toast("⚠ %s %s — overloaded past its rating. Reset it in the wire inspector." % [
		ConduitKinds.display_name(type_id), verb], 5.0)
	print("SystemGraphView: connection '%s' (%s) %s from sustained overload" % [
		cid, type_id, verb])
	if _graph_canvas != null:
		_graph_canvas.call("queue_redraw")
	if electrical:
		_ignite_conduit_fire(cid)


## Electrical burnout can ignite the conduit itself in the 3D world (scoped to
## the conduit mesh only — reuses the fire crisis system's structure lock).
func _ignite_conduit_fire(conn_id: String) -> void:
	var mgr := _get_conduit_manager()
	if mgr == null or not mgr.has_method("get_instance"):
		return
	var inst: MeshInstance3D = mgr.call("get_instance", conn_id)
	if inst == null or not is_instance_valid(inst):
		return
	var tree := get_tree()
	if tree == null:
		return
	var manager := tree.get_first_node_in_group("crisis_event_manager")
	if manager == null or not manager.has_method("trigger_event_manual"):
		return
	var fire_script := load("res://crisis_events/fire/fire_event.gd") as GDScript
	if fire_script == null:
		return
	var fire_event: Variant = fire_script.new()
	var context := {
		"scene_tree": tree,
		"structure": inst,
		"restrict_to_structure": true,
		"prefer_bottom": false,
	}
	if bool(fire_event.can_trigger(context)):
		manager.call("trigger_event_manual", fire_event, context)


func _destroy_controller(controller_id: String, string_voc: float, max_voc: float) -> void:
	if model == null:
		return
	var it := model.get_item(controller_id)
	if it.is_empty():
		return
	var sp: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	sp["destroyed"] = true
	sp["fault_voc"] = string_voc
	sp["destroyed_reason"] = "Voc %.0f V > max %.0f V" % [string_voc, max_voc]
	sp["node_state_reason"] = GraphNodeState.REASON_OVERVOLTAGE
	model.update_item(controller_id, {"specs": sp})
	_play_destroy_fx(controller_id)
	_show_fault_card(GraphNodeState.REASON_OVERVOLTAGE,
		{"string_voc": string_voc, "max_voc": max_voc})
	_sync_graph_controller_ac_fault()
	electrical_fault_observed.emit(GraphNodeState.REASON_OVERVOLTAGE, controller_id)
	print("SystemGraphView: controller '%s' destroyed (Voc %.1f V > max %.1f V)" % [
		controller_id, string_voc, max_voc])


## Battery destroyed by a short circuit or unregulated PV overcharge. Same
## specs contract as controllers (destroyed / destroyed_reason / node_state_
## reason), so the canvas FAULT halo + DESTROYED banner + RESET come for free.
func _destroy_battery(battery_id: String, reason: String, detail: String,
		card_params: Dictionary = {}) -> void:
	if model == null or battery_id.is_empty():
		return
	var it := model.get_item(battery_id)
	if it.is_empty():
		return
	var sp: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	if bool(sp.get("destroyed", false)):
		return
	sp["destroyed"] = true
	sp["destroyed_reason"] = detail
	sp["node_state_reason"] = reason
	model.update_item(battery_id, {"specs": sp})
	_play_destroy_fx(battery_id)
	_show_fault_card(reason, card_params)
	electrical_fault_observed.emit(reason, battery_id)
	print("SystemGraphView: battery '%s' destroyed (%s)" % [battery_id, detail])


## Sever every conductor on a shorted loop — they carried the fault current.
## Reuses the burnout severing (scorched wire, reset in the wire inspector);
## skipped wires that are already severed stay severed.
func _burn_short_wires(conn_ids: Array) -> void:
	if model == null:
		return
	for cid in conn_ids:
		var conn := model.get_connection(str(cid))
		if conn.is_empty() or bool(conn.get("severed", false)):
			continue
		_sever_connection(conn)


func _reset_controller(controller_id: String) -> void:
	if model == null:
		return
	var it := model.get_item(controller_id)
	if it.is_empty():
		return
	var ty := str(it.get("type", ""))
	var sp: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	sp["destroyed"] = false
	sp.erase("destroyed_reason")
	sp.erase("fault_voc")
	sp.erase("node_state_reason")
	model.update_item(controller_id, {"specs": sp})
	# A reset while the blast is still playing must not pop a stale card.
	_cancel_pending_fault_card()
	_sync_graph_controller_ac_fault()
	call_deferred("_check_electrical_faults")
	if ty == "battery" or ty == "smartbattery":
		_show_toast("Battery reset — fix the wiring before it burns again", 3.0)
	else:
		_show_toast("Controller reset — check wiring before re-energizing", 3.0)
	if _graph_canvas != null:
		_graph_canvas.call("queue_redraw")


func _on_controller_reset_pressed(controller_id: String) -> void:
	_reset_controller(controller_id)


func _play_destroy_fx(item_id: String) -> void:
	if _graph_canvas == null or not _graph_canvas.has_method("play_controller_destroy_fx"):
		return
	var it := model.get_item(item_id)
	if it.is_empty():
		return
	var c := _graph_canvas as Control
	var pan := c.get("_pan") as Vector2
	var zoom := float(c.get("_zoom"))
	var center := c.size * 0.5
	var tl := center + pan + Vector2(float(it.get("x", 0.0)), float(it.get("y", 0.0))) * zoom
	var sz := Vector2(float(it.get("width", 120.0)), float(it.get("height", 90.0))) * zoom
	var screen_center := tl + sz * 0.5
	_graph_canvas.call("play_controller_destroy_fx", item_id, screen_center)


func _ensure_fault_card_modal() -> void:
	if _fault_card_modal != null and is_instance_valid(_fault_card_modal):
		return
	_fault_card_modal = GraphFaultCardModal.new()
	_fault_card_modal.name = "FaultCardModal"
	add_child(_fault_card_modal)


## Seconds the blast plays before the education card appears. Showing the card
## in the same frame as the FX buried the very explosion it explains — and per
## playtest feedback, the card was still arriving too soon to actually watch
## the (much bigger, two-hit) blast and sit with the mistake before the lesson
## interrupts. Comfortably outlasts graph_canvas.gd's FX_LIFETIME (4.2 s).
const FAULT_CARD_DELAY := 3.2

var _pending_fault_card: Dictionary = {}
var _fault_card_token: int = 0


## Present the education card for a tripped fault (GraphEducationCards registry
## keyed by GraphNodeState reason), after the destroy FX has had its moment.
## Queued by the modal if one is already up.
func _show_fault_card(reason: String, params: Dictionary = {}) -> void:
	var card := GraphEducationCards.card_for_fault(reason, params)
	if card.is_empty():
		return
	card["placement"] = "corner"
	_pending_fault_card = card
	_fault_card_token += 1
	var token := _fault_card_token
	var tree := get_tree()
	if tree == null:
		_flush_fault_card(token)
		return
	tree.create_timer(FAULT_CARD_DELAY).timeout.connect(
		func() -> void: _flush_fault_card(token))


## Show the queued card unless it was superseded by a later fault or cancelled
## (reset / left the view) while the blast was still playing.
func _flush_fault_card(token: int) -> void:
	if token != _fault_card_token or _pending_fault_card.is_empty():
		return
	if not is_inside_tree() or not visible:
		_pending_fault_card = {}
		return
	var card := _pending_fault_card
	_pending_fault_card = {}
	_ensure_fault_card_modal()
	_fault_card_modal.show_card(card)


func _cancel_pending_fault_card() -> void:
	_fault_card_token += 1
	_pending_fault_card = {}


func reset_controller_from_inspector(controller_id: String) -> void:
	_reset_controller(controller_id)


func _apply_graph_auto_layout(fit_view: bool = true, recurse_children: bool = true) -> void:
	if model == null:
		return
	var items: Array = GraphLayout.filter_layout_items(model.get_items_in_scope(_active_scope_id))
	if items.size() < 2 and not recurse_children:
		return
	_history_suppress = true
	if items.size() >= 2:
		var patches: Dictionary = GraphLayout.resolve_overlaps(items)
		for iid in patches:
			model.update_item(str(iid), {"x": (patches[iid] as Vector2).x, "y": (patches[iid] as Vector2).y})
	# B: tidy the interior of any compound in this scope too, so Arrange fixes a
	# messy super-node (e.g. a StarShade array) without having to drill in.
	if recurse_children:
		for it: Dictionary in model.get_items_in_scope(_active_scope_id):
			if str(it.get("type", "")) == "compound":
				_layout_compound_scopes(str(it.get("child_scope_id", "")))
	_history_suppress = false
	_push_history()
	if fit_view and _graph_canvas != null:
		_fit_canvas_to_content()
	if _graph_canvas != null:
		_graph_canvas.call("queue_redraw")
	_schedule_graph_autosave()


## Recursively lay out a compound's child scope and any nested compounds. Panel-
## heavy scopes get a clean grid (cols≈√count); everything else gets a light
## force-directed relaxation, both followed by overlap resolution.
func _layout_compound_scopes(scope_id: String) -> void:
	if model == null or scope_id.is_empty():
		return
	for sid in GraphNesting.descendant_scopes(model, scope_id):
		var items: Array = GraphLayout.filter_layout_items(
			model.get_items_in_scope(str(sid)))
		if items.size() < 2:
			continue
		var panels := 0
		for it: Dictionary in items:
			if str(it.get("type", "")) == "panel":
				panels += 1
		var patches: Dictionary
		if panels >= items.size() * 0.6:
			var cols := maxi(1, int(round(sqrt(float(items.size())))))
			patches = GraphLayout.layout_grid(items, cols, Vector2(24.0, 24.0))
		else:
			var conns: Array = model.get_connections_in_scope(str(sid)) \
				if model.has_method("get_connections_in_scope") else []
			patches = GraphLayout.relax_forces(items, conns)
		for iid_v in patches.keys():
			var pos: Vector2 = patches[iid_v] as Vector2
			model.update_item(str(iid_v), {"x": pos.x, "y": pos.y})


func _fit_canvas_to_content() -> void:
	if _graph_canvas == null or model == null:
		return
	var items: Array = GraphLayout.filter_layout_items(model.get_items_in_scope(_active_scope_id))
	if items.is_empty():
		return
	var c := _graph_canvas as Control
	if c.size.x < 32.0 or c.size.y < 32.0:
		if not _fit_deferred_pending:
			_fit_deferred_pending = true
			call_deferred("_fit_canvas_to_content")
		return
	_fit_deferred_pending = false
	var bounds := GraphLayout.content_bounds(items)
	var fit: Dictionary = GraphLayout.compute_fit_view(bounds, c.size)
	c.set("_pan", Vector2(float(fit.get("pan_x", 0.0)), float(fit.get("pan_y", 0.0))))
	c.set("_zoom", clampf(float(fit.get("zoom", 1.0)),
			GraphLayout.ZOOM_MIN, GraphLayout.ZOOM_MAX))


func _post_restore_layout_fixup() -> void:
	if model == null or not visible:
		return
	var items: Array = GraphLayout.filter_layout_items(model.get_items_in_scope(_active_scope_id))
	if items.size() < 2:
		return
	if GraphLayout.has_overlaps(items):
		_apply_graph_auto_layout(true)
		_show_toast("Overlapping nodes auto-arranged", 2.5)
		return
	# Recover from autosaves written when off-canvas nodes crushed zoom to minimum.
	if _graph_canvas != null \
			and float(_graph_canvas.get("_zoom")) <= GraphLayout.ZOOM_MIN * 1.05:
		_fit_canvas_to_content()


func _maybe_apply_first_load_layout() -> void:
	if _first_load_layout_done or model == null:
		return
	_first_load_layout_done = true
	if has_user_graph_layout():
		call_deferred("_post_restore_layout_fixup")
		return
	_apply_graph_auto_layout(true)
	_show_toast("Graph auto-arranged — drag nodes anytime", 2.5)


func _on_arrange_graph_pressed() -> void:
	_apply_graph_auto_layout(true)
	_show_toast("Nodes arranged")


func _on_series_wiring_pressed() -> void:
	_wire_selected_panels(true)


func _on_parallel_wiring_pressed() -> void:
	_wire_selected_panels(false)


func _wire_selected_panels(series: bool) -> void:
	if model == null:
		return
	var ids := _panel_selection_ids()
	if ids.size() < 2:
		_show_toast("Select 2+ panel nodes")
		return
	var ctrl_id := GraphPvWiring.nearest_controller_id(model, ids, _active_scope_id)
	if ctrl_id.is_empty():
		_show_toast("Add a controller to connect panels")
		return
	_history_suppress = true
	GraphPvWiring.layout_panels_row(model, ids)
	if series:
		GraphPvWiring.wire_series(model, ids, ctrl_id, _active_scope_id)
	else:
		GraphPvWiring.wire_parallel(model, ids, ctrl_id, _active_scope_id)
	_history_suppress = false
	_push_history()
	call_deferred("_check_electrical_faults")
	_show_toast("Wired %d panel(s) %s → controller" % [
		ids.size(), "in series" if series else "in parallel"])
	_update_special_group_buttons()
func _ensure_pbi_nodes() -> void:
	if model == null:
		return
	# Biomass is a downstream consequence of sunlight (grow beds), not a
	# fundamental PBI — strip legacy biomass-as-PBI nodes from older saves.
	var legacy_bio: Array = []
	for item: Dictionary in model.items_of_type("pbi"):
		var bk: String = str((item.get("specs", {}) as Dictionary).get("resource_kind", ""))
		if bk == "biomass":
			legacy_bio.append(str(item.get("id", "")))
	for bid: String in legacy_bio:
		if not bid.is_empty():
			model.remove_item(bid)

	var has_sun := false
	var has_rain := false
	var has_wind := false
	for item: Dictionary in model.items_of_type("pbi"):
		# Stamp locked/fundamental on every PBI already present.
		item["locked"] = true
		# PBIs are pinned to the fixed top bar, so exclude them from auto-layout
		# and overlap resolution (they have no meaningful graph-space position).
		item["layout_exclude"] = true
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		specs["fundamental"] = true
		specs["locked"] = true
		item["specs"] = specs
		var kind: String = str(specs.get("resource_kind", ""))
		if kind == "sunlight" or kind == "solar":
			has_sun = true
		elif kind == "water" or kind == "rain":
			has_rain = true
		elif kind == "wind" or kind == "mechanical" or kind == "atmosphere" or kind == "air":
			has_wind = true

	var to_add := []
	if not has_sun:
		to_add.append({"id": "pbi_sun", "kind": "sunlight", "name": "Sunlight"})
	if not has_rain:
		to_add.append({"id": "pbi_rain", "kind": "water", "name": "Rain"})
	if not has_wind:
		to_add.append({"id": "pbi_wind", "kind": "wind", "name": "Wind"})

	if to_add.is_empty():
		return

	var start_x = -400.0
	var spacing = 220.0
	for i in to_add.size():
		var p = to_add[i]
		model.add_item({
			"id": p["id"],
			"type": "pbi",
			"x": start_x + i * spacing,
			"y": -400.0,
			"width": 128.0,
			"height": 128.0,
			"locked": true,
			"layout_exclude": true,
			"specs": {
				"name": p["name"],
				"resource_kind": p["kind"],
				"fundamental": true,
				"locked": true,
			},
		})


func _tick_graph_pbis(delta: float) -> void:
	if model == null:
		return
	# Was unthrottled (ran every frame with live WeatherService/SoiService
	# queries + a full item scan + a per-frame randf()) — throttle to match the
	# other 0.25s polling ticks.
	_pbis_acc += delta
	if _pbis_acc < _PBIS_POLL_INTERVAL:
		return
	_pbis_acc = 0.0

	var area_m2 := 0.0
	var soi_svc := get_node_or_null("/root/SoiService")
	if soi_svc != null and soi_svc.has_method("area_m2"):
		area_m2 = float(soi_svc.call("area_m2"))

	var year := 2026
	var month := 6
	var day := 15
	var hour := 12.0
	var lat := 0.0
	var lon := 0.0
	var m := _get_scene_main_node()
	if m != null:
		var dt: Variant = m.get("day_time")
		if dt != null: hour = float(dt)
		var mo: Variant = m.get("month")
		if mo != null: month = clampi(int(mo), 1, 12)
		var dd: Variant = m.get("day")
		if dd != null: day = clampi(int(dd), 1, 31)
		var yr: Variant = m.get("year")
		if yr != null: year = int(yr)
		var lat_v: Variant = m.get("latitude")
		if lat_v != null: lat = float(lat_v)
		var lon_v: Variant = m.get("longitude")
		if lon_v != null: lon = float(lon_v)

	var rain_mm_h := 0.0
	var ws := get_node_or_null("/root/WeatherService")
	if ws != null and ws.has_method("covers") and bool(ws.call("covers", lat, lon)):
		if ws.has_method("rain_rate_mmh"):
			rain_mm_h = float(ws.call("rain_rate_mmh", month, day, hour))

	# Real GHI (measured when WeatherService covers the site, else clear-sky
	# geometry) — shared with resource_flow_engine._process_sun_pbi so the
	# PBI's live sim tick and this always-on (works-while-paused) tick agree.
	var weather := SolarIrradiance.sample_weather(lat, lon, month, day, hour, ws)
	var ghi_wm2 := SolarIrradiance.ghi_wm2_at_calendar(lat, lon, month, day, hour, weather, year)
	var sun_flux_kw := SolarIrradiance.flux_kw_from_ghi(ghi_wm2, area_m2)

	var atmo: Dictionary = AtmospherePbi.sample(lat, lon, month, day, hour, ws)
	var rain_active := rain_mm_h > 0.0

	const PBI_EPS := 0.05
	for item: Dictionary in model.items_of_type("pbi"):
		var iid: String = item.get("id", "") as String
		var prev: Dictionary = item.get("specs", {}) as Dictionary
		var specs: Dictionary = prev.duplicate(false)
		var kind: String = str(specs.get("resource_kind", ""))

		if kind == "sunlight" or kind == "solar":
			var disp := SolarIrradiance.pbi_display_string(ghi_wm2, sun_flux_kw)
			var active := ghi_wm2 > 1.0
			var avail := SolarIrradiance.sun_availability(ghi_wm2)
			var cloud_f := float(weather.get("cloud", 0.0))
			if str(prev.get("display_value", "")) == disp \
					and bool(prev.get("is_active", false)) == active \
					and absf(float(prev.get("irradiance_wm2", 0.0)) - ghi_wm2) <= PBI_EPS \
					and absf(float(prev.get("flux_kw", 0.0)) - sun_flux_kw) <= PBI_EPS \
					and absf(float(prev.get("sun_availability", 0.0)) - avail) <= 0.01 \
					and absf(float(prev.get("cloud_frac", 0.0)) - cloud_f) <= 0.01:
				continue
			specs["display_value"] = disp
			specs["is_active"] = active
			specs["irradiance_wm2"] = ghi_wm2
			specs["flux_kw"] = sun_flux_kw
			specs["sun_availability"] = avail
			specs["cloud_frac"] = cloud_f
			model.update_item(iid, {"specs": specs})
			continue

		elif kind == "water" or kind == "rain":
			var liters_per_hour = area_m2 * rain_mm_h
			var disp_w := "%.0f L/h" % liters_per_hour if liters_per_hour > 0.0 else "0 L/h"
			if str(prev.get("display_value", "")) == disp_w \
					and bool(prev.get("is_active", false)) == rain_active:
				continue
			specs["display_value"] = disp_w
			specs["is_active"] = rain_active
			model.update_item(iid, {"specs": specs})
			continue

		elif kind == "wind" or kind == "mechanical" or kind == "atmosphere" or kind == "air":
			var wind_ms: float = float(atmo.get("wind_ms", 0.0))
			var temp_c: float = float(atmo.get("temp_c", 20.0))
			var humidity: float = float(atmo.get("humidity_pct", 50.0))
			var cloud: float = float(atmo.get("cloud_frac", 0.0))
			var rain: float = float(atmo.get("rain_mmh", rain_mm_h))
			var kinetic_kw: float = AtmospherePbi.kinetic_flux_kw(wind_ms, area_m2)
			var wclass := AtmospherePbi.weather_visual_class(cloud, rain)
			var disp_a := AtmospherePbi.pbi_display_string(wind_ms, temp_c, humidity)
			var active_a := wind_ms > 0.5 or rain > 0.05 or cloud > 0.05
			if absf(float(prev.get("wind_ms", 0.0)) - wind_ms) <= 0.05 \
					and absf(float(prev.get("temp_c", 0.0)) - temp_c) <= 0.2 \
					and absf(float(prev.get("humidity_pct", 0.0)) - humidity) <= 1.0 \
					and absf(float(prev.get("cloud_frac", 0.0)) - cloud) <= 0.02 \
					and absf(float(prev.get("rain_mmh", 0.0)) - rain) <= 0.05 \
					and absf(float(prev.get("kinetic_kw", 0.0)) - kinetic_kw) <= PBI_EPS \
					and int(prev.get("weather_class", -1)) == wclass \
					and str(prev.get("display_value", "")) == disp_a \
					and bool(prev.get("is_active", false)) == active_a:
				continue
			specs["wind_ms"] = wind_ms
			specs["temp_c"] = temp_c
			specs["humidity_pct"] = humidity
			specs["cloud_frac"] = cloud
			specs["rain_mmh"] = rain
			specs["kinetic_kw"] = kinetic_kw
			specs["weather_class"] = wclass
			specs["display_value"] = disp_a
			specs["is_active"] = active_a
			model.update_item(iid, {"specs": specs})
			continue
