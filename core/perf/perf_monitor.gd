extends Node

## Lightweight frame-budget instrumentation + on-screen HUD (Tier 0 of the
## performance plan). Splits each frame into named cost buckets so we can tell
## which regime is actually hurting — graph simulation, world/env recompute, or
## per-prop 3D ticks — instead of guessing, and prove every later optimization
## with a number.
##
## Usage from any script (all no-ops when the HUD is disabled, so leaving the
## calls in costs ~nothing):
##     PerfMonitor.begin("graph_sim")
##     ... work ...
##     PerfMonitor.end("graph_sim")
## or the scoped form for a single expression block:
##     var t := PerfMonitor.scope("flow_engine"); ... ; PerfMonitor.close(t)
##
## Toggle with F3, or PerfMonitor.set_enabled(bool) from the settings panel.
## Autoload name: PerfMonitor (registered in project.godot).

## Sections drawn in this order; anything not listed is appended alphabetically.
const SECTION_ORDER: Array[String] = [
	"graph_sim", "flow_engine", "npc_population", "npc_dots", "npc_host", "crowd_sim",
	"crowd_render", "crowd_raster", "camp_power", "npc_persist", "npc_venues", "npc_peaks",
	# The graph-closed cascade that used to be invisible on the HUD: the DC
	# throttle pass, the (deferred) electrical fault check, the 3D placeholder
	# host's sync and the pond twin push. Read these when first person stutters.
	"gv_dc_throttle", "gv_faults", "gv_placeholder", "gv_pond_push",
	"conduits_3d", "world_env", "main_fx", "planets", "terrain_tick",
	"terrain_season", "stream_tracers", "drone",
	# First-person per-frame work that was invisible on the HUD before
	# 2026-10-18: every placed prop runtime (trackers, spins, rings, vehicles),
	# the placed lights, the crosshair ladder, SolarUI / TimelineUI / HudLayout.
	"prop_ticks", "placed_lights", "interact_focus", "solar_ui", "timeline_ui",
	"hud_layout", "gv_draw",
]

## Exponential smoothing factor for the displayed averages (per frame).
const SMOOTH := 0.10
## PEAKS: the worst single frame per section over this window. The smoothed
## average hides a 2 Hz sim tick entirely (a 50 ms spike every 30 frames reads
## as a few ms), and at high time scales that spike IS the stutter.
const PEAK_WINDOW_S := 2.0

var _enabled: bool = false

## section -> accumulated usec THIS frame (cleared each PerfMonitor._process).
var _accum: Dictionary = {}
## section -> start usec of an open begin() (supports one open span per name).
var _open: Dictionary = {}
## section -> smoothed MILLISECONDS for display (and snapshot()).
var _display: Dictionary = {}
## section -> live per-frame call count, and its smoothed display value.
var _calls: Dictionary = {}
var _calls_display: Dictionary = {}

var _frame_ms_display: float = 0.0
var _fps_display: float = 0.0
## section -> [current-window max ms, previous-window max ms]; frame likewise.
var _peak: Dictionary = {}
var _frame_peak := [0.0, 0.0]
var _peak_t := 0.0

var _hud: CanvasLayer = null
var _label: Control = null

## Last F4 node histogram, rendered as a second panel beside the main HUD.
var _hist_lines: Array = []


func _ready() -> void:
	# Always process (even when the game is paused) so the HUD keeps updating.
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	set_process_input(true)


func is_enabled() -> bool:
	return _enabled


## Machine-readable HUD state for playtest harness dumps (ms, not usec).
func snapshot() -> Dictionary:
	var sections := {}
	for k in _display.keys():
		# _display is already smoothed MILLISECONDS (see _process: _accum usec / 1000).
		# It was divided by 1000 again here, so every crowdbench section median
		# printed 1000x low (npc_host 0.22 ms while the F3 HUD read 220 ms).
		sections[str(k)] = float(_display[k])
	var calls := {}
	for k in _calls_display.keys():
		calls[str(k)] = float(_calls_display[k])
	return {
		"enabled": _enabled,
		"fps": _fps_display,
		"frame_ms": _frame_ms_display,
		"frame_ms_peak": maxf(float(_frame_peak[0]), float(_frame_peak[1])),
		"sections_ms": sections,
		"sections_peak_ms": _peak_snapshot(),
		"calls": calls,
		"render": render_snapshot(),
	}


func _peak_snapshot() -> Dictionary:
	var out := {}
	for k in _peak.keys():
		var p: Array = _peak[k]
		out[str(k)] = maxf(float(p[0]), float(p[1]))
	return out


## Godot Performance monitors — primitives / draw calls / nodes (for budgets).
func render_snapshot() -> Dictionary:
	var draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var proc_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var out := {
		"draw_calls": draw_calls,
		"primitives": prims,
		"scene_nodes": nodes,
		"process_ms": proc_ms,
	}
	var vp := get_viewport()
	if vp != null:
		var rid := vp.get_viewport_rid()
		out["render_cpu_ms"] = RenderingServer.viewport_get_measured_render_time_cpu(rid) \
				+ RenderingServer.get_frame_setup_time_cpu()
		out["render_gpu_ms"] = RenderingServer.viewport_get_measured_render_time_gpu(rid)
	return out


func set_enabled(on: bool) -> void:
	if on == _enabled:
		return
	_enabled = on
	if _enabled:
		_ensure_hud()
		if _hud != null:
			_hud.visible = true
		# Ask the renderer to measure per-frame CPU/GPU time on the main viewport
		# so the HUD can tell CPU-bound (cull/submit) from GPU-bound (fill/overdraw).
		var vp := get_viewport()
		if vp != null:
			RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
	elif _hud != null:
		_hud.visible = false
	# Clear stale timings so re-enabling starts fresh.
	_accum.clear()
	_open.clear()


func toggle() -> void:
	set_enabled(not _enabled)


## Begin timing a named section. Cheap no-op while disabled.
func begin(section: String) -> void:
	if not _enabled:
		return
	_open[section] = Time.get_ticks_usec()


## End timing a named section opened with begin(). Accumulates elapsed usec and
## increments this frame's call count for that section.
func end(section: String) -> void:
	if not _enabled:
		return
	var started: Variant = _open.get(section)
	if started == null:
		return
	var dt: int = Time.get_ticks_usec() - int(started)
	_open.erase(section)
	_accum[section] = float(_accum.get(section, 0.0)) + float(dt)
	_calls[section] = int(_calls.get(section, 0)) + 1


## Scoped variant for spans that don't map cleanly to a named begin/end pair.
## Returns an opaque token; pass it to close(). No-op token while disabled.
func scope(section: String) -> Array:
	if not _enabled:
		return []
	return [section, Time.get_ticks_usec()]


func close(token: Array) -> void:
	if not _enabled or token.size() != 2:
		return
	var section: String = token[0]
	var dt: int = Time.get_ticks_usec() - int(token[1])
	_accum[section] = float(_accum.get(section, 0.0)) + float(dt)
	_calls[section] = int(_calls.get(section, 0)) + 1


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var ke := event as InputEventKey
		if ke.pressed and not ke.echo and ke.keycode == KEY_F3:
			toggle()
			get_viewport().set_input_as_handled()
		elif ke.pressed and not ke.echo and ke.keycode == KEY_F4:
			dump_processing_histogram()
			get_viewport().set_input_as_handled()


## One-shot diagnostic: walk the whole scene tree and tally every node that is
## actively running _process / _physics_process, grouped by script (or class for
## scriptless nodes). Prints the heaviest groups to stdout so we know which
## per-instance callbacks dominate the frame. Press F4 in a heavy scene.
func dump_processing_histogram() -> void:
	var root := get_tree().root
	if root == null:
		return
	var proc: Dictionary = {}      # key -> count actively processing
	var phys: Dictionary = {}      # key -> count actively physics-processing
	var alln: Dictionary = {}      # key -> count of ALL nodes (composition)
	var total := [0, 0, 0]         # [nodes, processing, physics_processing]
	var special := {              # scene-cost drivers
		"mesh": 0, "mesh_shadow": 0, "multimesh": 0,
		"light": 0, "light_shadow": 0, "gi": 0, "particles": 0,
	}
	var mesh_owner: Dictionary = {}   # subsystem name -> MeshInstance3D count
	var scene := get_tree().current_scene
	_walk_histogram(root, proc, phys, alln, total, special, mesh_owner, scene)

	# Build the display/print lines once (shown on the HUD AND echoed to stdout).
	_hist_lines.clear()
	_hist_lines.append("nodes %d · proc %d · phys %d" % [total[0], total[1], total[2]])
	_hist_lines.append("mesh %d (shadow %d) · mm %d" % [special.mesh, special.mesh_shadow, special.multimesh])
	_hist_lines.append("lights %d (shadow %d) · gi %d · fx %d" % [special.light, special.light_shadow, special.gi, special.particles])
	_hist_lines.append("— meshes by subsystem —")
	for row in _top_groups(mesh_owner, 12):
		_hist_lines.append("%6d  %s" % [row[1], row[0]])
	# Which scripts are actually running per-frame callbacks — the direct lead on
	# an unexplained "_process total" (a script with many processing instances is
	# the usual culprit). Physics list only when something is physics-processing.
	_hist_lines.append("— top _process scripts —")
	for row in _top_groups(proc, 8):
		_hist_lines.append("%6d  %s" % [row[1], row[0]])
	if total[2] > 0:
		_hist_lines.append("— top _physics scripts —")
		for row in _top_groups(phys, 5):
			_hist_lines.append("%6d  %s" % [row[1], row[0]])
	_hist_lines.append("— top node types (all) —")
	for row in _top_groups(alln, 6):
		_hist_lines.append("%6d  %s" % [row[1], row[0]])

	print("\n===== PerfMonitor node histogram =====")
	for ln: String in _hist_lines:
		print("  " + ln)
	print("======================================\n")

	# Force the HUD on so the result is visible/screenshottable without stdout.
	set_enabled(true)
	if _label != null:
		_label.queue_redraw()


func _walk_histogram(n: Node, proc: Dictionary, phys: Dictionary,
		alln: Dictionary, total: Array, special: Dictionary,
		mesh_owner: Dictionary, scene: Node) -> void:
	total[0] += 1
	var k := _hist_key(n)
	alln[k] = int(alln.get(k, 0)) + 1
	if n.is_processing():
		proc[k] = int(proc.get(k, 0)) + 1
		total[1] += 1
	if n.is_physics_processing():
		phys[k] = int(phys.get(k, 0)) + 1
		total[2] += 1
	# Scene-cost drivers (culling + draw calls + shadow/GI passes).
	if n is MeshInstance3D:
		special.mesh += 1
		if (n as MeshInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			special.mesh_shadow += 1
		var owner := _subsystem_owner(n, scene)
		mesh_owner[owner] = int(mesh_owner.get(owner, 0)) + 1
	elif n is MultiMeshInstance3D:
		special.multimesh += 1
	elif n is Light3D and not (n is DirectionalLight3D):
		special.light += 1
		if (n as Light3D).shadow_enabled:
			special.light_shadow += 1
	elif n is GPUParticles3D or n is CPUParticles3D:
		special.particles += 1
	if n is VoxelGI or n is LightmapGI or n is ReflectionProbe:
		special.gi += 1
	for child in n.get_children():
		_walk_histogram(child, proc, phys, alln, total, special, mesh_owner, scene)


## Subsystem path (up to 2 container levels beneath the scene root) that a mesh
## belongs to, e.g. "Terrain/BuildingsCustom" or "Terrain/HeightField". Groups
## thousands of leaf meshes under the container that spawned them so we can see
## exactly which system to consolidate. Parent names ending in an id/hash suffix
## are collapsed (B_1234 -> B_*) so per-instance children fold together.
func _subsystem_owner(n: Node, scene: Node) -> String:
	if scene == null:
		return "?"
	# Collect the ancestor chain from just under the scene down toward the node.
	var chain: Array = []
	var cur := n
	while cur != null and cur != scene:
		chain.push_front(cur)
		cur = cur.get_parent()
	if chain.is_empty():
		return String(n.name)
	var lvl0 := String((chain[0] as Node).name)
	if chain.size() == 1:
		return lvl0
	var lvl1 := _collapse_id_suffix(String((chain[1] as Node).name))
	return lvl0 + "/" + lvl1


## "B_1234" / "Tile_3_-4" / "Prop_9f2a" -> a stable family label so per-instance
## container names don't each become their own histogram row.
func _collapse_id_suffix(s: String) -> String:
	var out := ""
	var digits_or_us := false
	for i in s.length():
		var ch := s[i]
		if ch >= "0" and ch <= "9":
			digits_or_us = true
			continue
		if digits_or_us and (ch == "_" or ch == "-"):
			continue
		digits_or_us = false
		out += ch
	if out.length() < s.length():
		return out + "*"
	return s


func _hist_key(n: Node) -> String:
	var scr: Variant = n.get_script()
	if scr != null and scr is Script:
		var p := (scr as Script).resource_path
		if not p.is_empty():
			return p.get_file()
	return n.get_class()


func _top_groups(d: Dictionary, limit: int) -> Array:
	var rows: Array = []
	for k: String in d.keys():
		rows.append([k, int(d[k])])
	rows.sort_custom(func(a, b): return int(a[1]) > int(b[1]))
	return rows.slice(0, limit)


var _measure_on := false


func _process(delta: float) -> void:
	if not _enabled:
		return
	# Idempotently ensure render-time measurement is active (covers the case where
	# the HUD was already enabled before this feature was added).
	if not _measure_on:
		var mvp := get_viewport()
		if mvp != null:
			RenderingServer.viewport_set_measure_render_time(mvp.get_viewport_rid(), true)
			_measure_on = true
	# Roll the just-finished frame's accumulators into the smoothed display set.
	_frame_ms_display = lerp(_frame_ms_display, delta * 1000.0, SMOOTH)
	_fps_display = lerp(_fps_display, float(Engine.get_frames_per_second()), SMOOTH)
	_peak_t += delta
	if _peak_t >= PEAK_WINDOW_S:
		_peak_t = 0.0
		_frame_peak = [0.0, float(_frame_peak[0])]
		for k in _peak.keys():
			_peak[k] = [0.0, float((_peak[k] as Array)[0])]
	_frame_peak[0] = maxf(float(_frame_peak[0]), delta * 1000.0)
	var seen: Dictionary = {}
	for section: String in _accum.keys():
		seen[section] = true
		var ms: float = float(_accum[section]) / 1000.0
		var pk: Array = _peak.get(section, [0.0, 0.0])
		pk[0] = maxf(float(pk[0]), ms)
		_peak[section] = pk
		_display[section] = lerp(float(_display.get(section, ms)), ms, SMOOTH)
		_calls_display[section] = lerp(float(_calls_display.get(section, 0.0)),
			float(_calls.get(section, 0)), SMOOTH)
	# Decay sections that did not report this frame toward zero so a stopped
	# subsystem visibly drops off instead of freezing at its last value.
	for section: String in _display.keys():
		if not seen.has(section):
			_display[section] = lerp(float(_display[section]), 0.0, SMOOTH)
			_calls_display[section] = lerp(float(_calls_display.get(section, 0.0)), 0.0, SMOOTH)
	_accum.clear()
	_calls.clear()
	if _label != null:
		_label.queue_redraw()


func _ensure_hud() -> void:
	if _hud != null and is_instance_valid(_hud):
		return
	_hud = CanvasLayer.new()
	_hud.layer = 128  # above everything
	_hud.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_hud)
	_label = Control.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_label.position = Vector2(10, 10)
	_label.custom_minimum_size = Vector2(320, 260)
	_label.draw.connect(_draw_hud)
	_hud.add_child(_label)


func _fmt_ms(v: float) -> String:
	return "%5.2f ms" % v


func _draw_hud() -> void:
	var c := _label
	if c == null:
		return
	var font := ThemeDB.fallback_font
	var fs := 13
	var line_h := 17.0
	var pad := 8.0
	var rows: Array = []

	# Header — overall frame budget (60 fps = 16.67 ms).
	rows.append(["F3 · Perf", "%d fps  %s" % [int(round(_fps_display)), _fmt_ms(_frame_ms_display)],
		_budget_color(_frame_ms_display)])
	var fpk := maxf(float(_frame_peak[0]), float(_frame_peak[1]))
	rows.append(["frame peak (2 s)", _fmt_ms(fpk), _budget_color(fpk)])

	# Godot's built-in global monitors (render + script totals, node count).
	var proc_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	rows.append(["_process total", _fmt_ms(proc_ms), Color(0.75, 0.85, 1.0)])
	rows.append(["_physics total", _fmt_ms(phys_ms), Color(0.75, 0.85, 1.0)])

	# CPU vs GPU render time — the CPU-bound vs GPU-bound tiebreaker.
	var vp := get_viewport()
	if vp != null:
		var rid := vp.get_viewport_rid()
		var rcpu := RenderingServer.viewport_get_measured_render_time_cpu(rid) \
			+ RenderingServer.get_frame_setup_time_cpu()
		var rgpu := RenderingServer.viewport_get_measured_render_time_gpu(rid)
		rows.append(["render CPU", _fmt_ms(rcpu), _budget_color(rcpu)])
		rows.append(["render GPU", _fmt_ms(rgpu), _budget_color(rgpu)])

	# Manually instrumented sections (the regime split).
	rows.append(["— sections —", "", Color(0.6, 0.6, 0.65)])
	for section: String in _ordered_sections():
		var ms: float = float(_display.get(section, 0.0))
		if ms < 0.005 and float(_calls_display.get(section, 0.0)) < 0.01:
			continue
		var calls: int = int(round(float(_calls_display.get(section, 0.0))))
		var suffix := "  ×%d" % calls if calls > 1 else ""
		var pka: Array = _peak.get(section, [0.0, 0.0])
		var pkv := maxf(float(pka[0]), float(pka[1]))
		var pk_txt := "  pk %.1f" % pkv if pkv > ms * 1.5 and pkv > 0.5 else ""
		rows.append([section, _fmt_ms(ms) + pk_txt + suffix, _budget_color(maxf(ms * 3.0, pkv))])

	rows.append(["— render —", "", Color(0.6, 0.6, 0.65)])
	rows.append(["draw calls", str(draw_calls), Color(0.85, 0.85, 0.9)])
	rows.append(["primitives", _fmt_count(prims), Color(0.85, 0.85, 0.9)])
	rows.append(["scene nodes", str(nodes), Color(0.85, 0.85, 0.9)])

	# Background panel sized to content.
	var h := line_h * rows.size() + pad * 2.0
	c.custom_minimum_size = Vector2(350, h)
	c.draw_rect(Rect2(Vector2.ZERO, Vector2(350, h)), Color(0.03, 0.04, 0.06, 0.82))
	c.draw_rect(Rect2(Vector2.ZERO, Vector2(350, h)), Color(0.4, 0.5, 0.7, 0.5), false, 1.0)

	var y := pad + line_h - 4.0
	for row: Array in rows:
		var name_col: Color = row[2] if row.size() > 2 else Color.WHITE
		c.draw_string(font, Vector2(pad, y), str(row[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, name_col)
		c.draw_string(font, Vector2(160, y), str(row[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, name_col)
		y += line_h

	# Second panel: F4 node histogram (counts of actively-processing scripts).
	if not _hist_lines.is_empty():
		var hx := 362.0
		var hw := 340.0
		var hh := line_h * (_hist_lines.size() + 1) + pad * 2.0
		c.draw_rect(Rect2(Vector2(hx, 0), Vector2(hw, hh)), Color(0.03, 0.04, 0.06, 0.85))
		c.draw_rect(Rect2(Vector2(hx, 0), Vector2(hw, hh)), Color(0.7, 0.5, 0.4, 0.5), false, 1.0)
		var hy := pad + line_h - 4.0
		c.draw_string(font, Vector2(hx + pad, hy), "F4 · processing nodes",
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.95, 0.8, 0.55))
		hy += line_h
		for ln: String in _hist_lines:
			var col := Color(0.85, 0.87, 0.92)
			if ln.begins_with("—") or ln.begins_with("nodes"):
				col = Color(0.6, 0.65, 0.72)
			c.draw_string(font, Vector2(hx + pad, hy), ln, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
			hy += line_h


func _ordered_sections() -> Array:
	var out: Array = []
	for s: String in SECTION_ORDER:
		if _display.has(s):
			out.append(s)
	var extra: Array = []
	for s: String in _display.keys():
		if not SECTION_ORDER.has(s):
			extra.append(s)
	extra.sort()
	out.append_array(extra)
	return out


func _fmt_count(n: int) -> String:
	if n >= 1_000_000:
		return "%.1fM" % (float(n) / 1_000_000.0)
	if n >= 1_000:
		return "%.1fk" % (float(n) / 1_000.0)
	return str(n)


func _budget_color(ms: float) -> Color:
	# Green < 5 ms, amber to ~12 ms, red beyond — coarse eyeball guide.
	if ms < 5.0:
		return Color(0.55, 0.9, 0.6)
	if ms < 12.0:
		return Color(0.95, 0.8, 0.45)
	return Color(0.95, 0.5, 0.5)
