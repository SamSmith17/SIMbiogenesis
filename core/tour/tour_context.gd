class_name TourContext
extends RefCounted

## Everything a tour stop needs, so stops stay short demos and never re-learn
## the game's plumbing:
##   handles   main, player, graph, loader, timeline (resolved per stop)
##   pacing    wait(s) × the run's pace; hold(actions, s) presses actions
##   words     caption(text) — lower-third; the title card is the director's
##   shots     hero() = the README image (captions hidden), shot(name) = extras
##   camera    a tour camera through Main's camera-claim stack: place / fly /
##             orbit, released by the director after every stop
##   clock     set_hour, scrub, run_clock
##   input     press(action) through the action's real key, click / drag
##   checks    require(ok, what) — a false marks the stop FAIL in the manifest
##
## Every helper returns early once `cancelled` is set (the stop ran over its
## budget — GDScript cannot kill a coroutine, so it is asked to stop instead).
## Game classes come through `klass("Name")` and autoloads through
## `autoload("Name")`, which keeps this file loadable under `--script`.

const CAM_CLAIM := "feature_tour"
const HERO_JPG_WIDTH := 1280
const HERO_JPG_QUALITY := 0.86
## 1 sim-second per real second (time_scale is sim-hours per real second).
const REALTIME_SCALE := 1.0 / 3600.0

var host: Node = null
var captions: TourCaptions = null
var stop: TourStop = null
var main: Node = null
var player: Node3D = null
var graph: Node = null
var loader: Node = null
var timeline: Node = null
var pace := 1.0
## Folder this stop's images go in (user://screenshots/<run>/stops/<id>).
var stop_dir := ""
var cancelled := false
var shots: Array = []
var hero_png := ""
var hero_jpg := ""
var failures: PackedStringArray = PackedStringArray()
var notes: PackedStringArray = PackedStringArray()
## UiAudit result for the hero shot (the screen as the player sees it,
## captions excluded): {} until hero() runs. "off" skips it.
var ui_audit: Dictionary = {}
var audit_mode := "report"

var _cam: Camera3D = null
var _hud_saved: Dictionary = {}
var _hud_depth := 0
var _held: PackedStringArray = PackedStringArray()
var _class_cache: Dictionary = {}


func tree() -> SceneTree:
	return host.get_tree() if host != null else Engine.get_main_loop() as SceneTree


func refresh_handles() -> void:
	var t := tree()
	main = null
	for child in t.root.get_children():
		if "day_time" in child and "sun" in child:
			main = child
			break
	player = main.get_node_or_null("Player") as Node3D if main != null else null
	if main != null and player == null:
		player = main.find_child("Player", true, false) as Node3D
	var sl := klass("ServiceLocator")
	graph = sl.call("graph") if sl != null else null
	if graph == null and main != null:
		graph = main.find_child("SystemGraphView", true, false)
	loader = main.get_node_or_null("TerrainLoader") if main != null else null
	if loader == null and main != null:
		loader = main.find_child("TerrainLoader", true, false)
	timeline = main.get_node_or_null("UILayer/TimelineUI") if main != null else null


func autoload(name: String) -> Node:
	return tree().root.get_node_or_null(name)


## A class_name script by name, loaded on demand (cached).
func klass(name: String) -> Script:
	if _class_cache.has(name):
		return _class_cache[name]
	var out: Script = null
	for c in ProjectSettings.get_global_class_list():
		if str(c.get("class", "")) == name:
			out = load(str(c.get("path", ""))) as Script
			break
	_class_cache[name] = out
	return out


# -- pacing -------------------------------------------------------------------

func wait(seconds: float) -> void:
	if cancelled or seconds <= 0.0:
		return
	await tree().create_timer(seconds * pace, true, false, true).timeout


func frames(n: int = 1) -> void:
	for _i in maxi(n, 1):
		await tree().process_frame


## Hold InputMap actions down for `seconds` (walk, drive, fly the drone).
func hold(actions: Array, seconds: float) -> void:
	if cancelled:
		return
	for a in actions:
		if InputMap.has_action(str(a)):
			Input.action_press(str(a))
			_held.append(str(a))
	await wait(seconds)
	release_held()


func release_held() -> void:
	for a in _held:
		Input.action_release(a)
	_held.clear()


# -- words --------------------------------------------------------------------

func caption(text: String, seconds: float = 3.0) -> void:
	if cancelled or captions == null:
		return
	captions.show_caption(text, seconds * pace)


## "Press G", "Click 📊 Site Report" … the chips on the title card and the
## "How to open" line in the docs.
static func open_hints(s: TourStop) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if not s.action.is_empty():
		var k := HarnessInput.action_label(s.action)
		if not k.is_empty():
			out.append("Press %s" % k)
	if not s.button.is_empty():
		out.append("Click %s" % s.button)
	return out


func key_label(action: String) -> String:
	return HarnessInput.action_label(action)


# -- checks -------------------------------------------------------------------

func require(ok: bool, what: String) -> bool:
	if not ok:
		failures.append(what)
		print("tour: %s — %s: not as expected" % [stop.id if stop != null else "?", what])
	return ok


func note(text: String) -> void:
	notes.append(text)
	print("tour: %s — %s" % [stop.id if stop != null else "?", text])


# -- screenshots --------------------------------------------------------------

## THE image for this stop in the docs. Captions are hidden for the grab;
## `hide_hud` also hides the game's own HUD (world shots read better bare).
func hero(hide_hud: bool = false) -> void:
	if cancelled:
		return
	if audit_mode != "off":
		# Audit what the PLAYER sees (HUD up), before any hide_hud for the image.
		await wait(0.35)
		ui_audit = UiAudit.run(tree().root.get_viewport())
		# What the HUD manager decided, beside what the audit found: a panel
		# reported visible under a claim that should hide it is a manager bug.
		var hl := HudLayout.get_hud()
		if hl != null:
			var snap := {}
			var raw: Dictionary = hl.snapshot()
			for id in raw:
				var r: Rect2 = raw[id]["rect"]
				snap[id] = {"state": raw[id]["state"], "rect": [r.position.x, r.position.y, r.size.x, r.size.y]}
			ui_audit["hud"] = {"panels": snap, "claims": hl.claims().keys(), "debug": hl.debug_state()}
	_check_privacy()
	var img := await _grab(hide_hud)
	if img == null:
		return
	hero_png = "%s/hero.png" % stop_dir
	img.save_png(hero_png)
	var small := img.duplicate() as Image
	if small.get_width() > HERO_JPG_WIDTH:
		var h := int(round(float(small.get_height()) * HERO_JPG_WIDTH / float(small.get_width())))
		small.resize(HERO_JPG_WIDTH, h, Image.INTERPOLATE_LANCZOS)
	small.convert(Image.FORMAT_RGB8)
	hero_jpg = "%s/hero.jpg" % stop_dir
	small.save_jpg(hero_jpg, HERO_JPG_QUALITY)
	shots.append({"file": "hero.png", "kind": "hero"})


## The hero shot goes into docs/ and the README: fail the stop if the site's
## real address or coordinates are on screen (SitePrivacy redacts the places
## that print them; this catches a new one).
func _check_privacy() -> void:
	if not SitePrivacy.redact or loader == null:
		return
	var label := str(loader.get("_map_label"))
	var lat := float(main.get("latitude")) if main != null and main.get("latitude") != null else NAN
	var lon := float(main.get("longitude")) if main != null and main.get("longitude") != null else NAN
	var found := SitePrivacy.leaks(tree().root, SitePrivacy.sensitive_tokens(label, lat, lon))
	require(found.is_empty(), "site address / coordinates on screen (%s)" % ", ".join(found))


## An extra still (not used by the README; kept with the run).
func shot(name: String, hide_hud: bool = false) -> void:
	if cancelled:
		return
	var img := await _grab(hide_hud)
	if img == null:
		return
	var file := "%s.png" % name
	img.save_png("%s/%s" % [stop_dir, file])
	shots.append({"file": file, "kind": "extra"})


func _grab(hide_hud: bool) -> Image:
	# A camera that just stopped moving is still smeared by TAA for a few
	# frames; let it converge before the README image is taken.
	await wait(0.35)
	var cap_was := captions != null and captions.visible
	if captions != null:
		captions.visible = false
	if hide_hud:
		hud(false)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := tree().root.get_viewport().get_texture().get_image()
	if hide_hud:
		hud(true)
	if captions != null:
		captions.visible = cap_was
	return img


## Show / hide Main's CanvasLayers (the HUD), remembering what was visible.
## Calls NEST: a shot(..., true) inside a stop's own hud(false) used to clear
## the saved list, so the stop's hud(true) restored nothing and every layer
## the baseline does not re-show (the designers' own layers) stayed hidden for
## the rest of the run. Only the outermost hide saves; only the matching
## outermost show restores.
func hud(show: bool) -> void:
	if main == null:
		return
	if not show:
		_hud_depth += 1
		if _hud_depth > 1:
			return
		_hud_saved.clear()
		# Nested CanvasLayers (UILayer/InteractionPromptUI, toasts…) are not
		# hidden by their parent layer, so take every one under Main.
		for c in main.find_children("*", "CanvasLayer", true, false):
			if (c as CanvasLayer).visible:
				_hud_saved[c.get_instance_id()] = true
				(c as CanvasLayer).visible = false
	else:
		if _hud_depth == 0:
			return
		_hud_depth -= 1
		if _hud_depth > 0:
			return
		hud_restore()


## Put back every layer a hud(false) hid, however deep the calls went (the
## director runs this after each stop's teardown).
func hud_restore() -> void:
	for iid in _hud_saved:
		var c := instance_from_id(int(iid)) as CanvasLayer
		if c != null and is_instance_valid(c):
			c.visible = true
	_hud_saved.clear()
	_hud_depth = 0


# -- clock --------------------------------------------------------------------

func set_hour(h: float) -> void:
	if main == null or is_nan(h):
		return
	main.set("day_time", fposmod(h, 24.0))


## Clock running at `multiple` × real time (0 = frozen).
func run_clock(multiple: float) -> void:
	if main != null:
		main.set("time_scale", REALTIME_SCALE * multiple)


## Sweep the clock from hour h0 to h1 (today; h1 < h0 wraps to tomorrow) over
## `seconds`, eased, through set_absolute_hours (sun, sky, weather and the
## battery all follow).
func scrub(h0: float, h1: float, seconds: float) -> void:
	if cancelled or main == null:
		return
	var day0 := float(main.call("get_absolute_hours")) - float(main.get("day_time"))
	var a := day0 + h0
	var b := day0 + (h1 if h1 >= h0 else h1 + 24.0)
	var saved_scale := float(main.get("time_scale"))
	main.set("time_scale", 0.0)
	var dur := maxf(seconds * pace, 0.05)
	var t := 0.0
	while t < dur and not cancelled:
		var u := smoothstep(0.0, 1.0, t / dur)
		main.call("set_absolute_hours", lerpf(a, b, u))
		await tree().process_frame
		t += host.get_process_delta_time()
	main.call("set_absolute_hours", b)
	main.set("time_scale", saved_scale)


## Sun altitude in degrees right now (the clock's own sun direction).
func sun_altitude() -> float:
	var clock: Variant = main.get("clock") if main != null else null
	if clock == null:
		return NAN
	return rad_to_deg(asin(clampf((clock.call("get_sun_direction") as Vector3).y, -1.0, 1.0)))


## The hour today at which the sun stands at `alt_deg` — in the evening
## (`evening`) or the morning. NAN if it never does (polar day / night).
## Leaves the clock where it found it.
func hour_for_sun(alt_deg: float, evening: bool = true) -> float:
	var clock: Variant = main.get("clock") if main != null else null
	if clock == null:
		return NAN
	var saved := float(main.get("day_time"))
	var lo := 12.5 if evening else 1.0
	var hi := 23.5 if evening else 12.5
	var target := sin(deg_to_rad(alt_deg))
	var f := func(h: float) -> float:
		main.set("day_time", h)
		return (clock.call("get_sun_direction") as Vector3).y - target
	var flo: float = f.call(lo)
	var fhi: float = f.call(hi)
	if signf(flo) == signf(fhi):
		main.set("day_time", saved)
		return NAN
	for _i in 40:
		var mid := 0.5 * (lo + hi)
		var fm: float = f.call(mid)
		if signf(fm) == signf(flo):
			lo = mid
			flo = fm
		else:
			hi = mid
	main.set("day_time", saved)
	return 0.5 * (lo + hi)


## Hold a cloudless sky for the rest of this stop (the weather sampler
## re-pushes cloud cover every frame, so the director re-applies this every
## frame until the next stop's baseline releases it).
func clear_sky(on: bool = true) -> void:
	if host != null:
		host.set("clear_sky_hold", on)


## A ground point near `around` (xz) whose height varies by the least over a
## disc of `radius` m — open, level ground for painting or sculpting — away
## from OSM buildings, and `clear_of_props_m` from every placed prop's centre
## (0 = props ignored). Searches rings out to `search_m`.
func find_flat(around: Vector2, radius: float = 18.0, search_m: float = 160.0,
		clear_of_props_m: float = 0.0) -> Vector3:
	var best := Vector2(around)
	var best_score := INF
	var step := maxf(radius * 0.8, 8.0)
	var props: Array = []
	if clear_of_props_m > 0.0:
		for r in prop_records():
			props.append(Vector2(float((r as Dictionary).get("x", 0.0)), float((r as Dictionary).get("z", 0.0))))
	var r := 0.0
	while r <= search_m:
		var n := 1 if r == 0.0 else int(ceil(TAU * r / step))
		for i in n:
			var a := TAU * float(i) / float(n)
			var c := around + Vector2(cos(a), sin(a)) * r
			var crowded := false
			for q0 in props:
				if (q0 as Vector2).distance_to(c) < clear_of_props_m + radius:
					crowded = true
					break
			if crowded:
				continue
			if loader != null and loader.has_method("pick_building_at_world"):
				var b: Variant = loader.call("pick_building_at_world", c.x, c.y)
				if b is Dictionary and bool((b as Dictionary).get("valid", false)):
					continue
			var lo := INF
			var hi := -INF
			for k in 9:
				var q := c
				if k > 0:
					var ak := TAU * float(k) / 8.0
					q = c + Vector2(cos(ak), sin(ak)) * radius
				var y := ground_y(q.x, q.y)
				lo = minf(lo, y)
				hi = maxf(hi, y)
			var score := (hi - lo) + r * 0.004
			if score < best_score:
				best_score = score
				best = c
		r += step
	return Vector3(best.x, ground_y(best.x, best.y), best.y)


# -- camera -------------------------------------------------------------------

func ground_y(x: float, z: float) -> float:
	if loader != null and loader.has_method("ground_height_at"):
		return float(loader.call("ground_height_at", x, z))
	return 0.0


func player_xz() -> Vector2:
	return Vector2(player.global_position.x, player.global_position.z) if player != null else Vector2.ZERO


## Horizontal unit vector the player faces.
func player_forward() -> Vector3:
	if player == null:
		return Vector3.FORWARD
	var f := -player.global_basis.z
	f.y = 0.0
	return f.normalized() if f.length() > 1e-4 else Vector3.FORWARD


## A ground point `dist` m ahead of the player (y = ground).
func ahead(dist: float, side: float = 0.0) -> Vector3:
	var f := player_forward()
	var r := f.cross(Vector3.UP)
	var p := (player.global_position if player != null else Vector3.ZERO) + f * dist + r * side
	p.y = ground_y(p.x, p.z)
	return p


func tour_camera() -> Camera3D:
	if _cam != null and is_instance_valid(_cam):
		return _cam
	_cam = Camera3D.new()
	_cam.name = "TourCamera"
	_cam.top_level = true
	_cam.fov = 60.0
	_cam.far = 20000.0
	main.add_child(_cam)
	main.call("push_camera_claim", CAM_CLAIM, {"camera_id": _cam.get_instance_id()})
	return _cam


func place_camera(pos: Vector3, look: Vector3) -> void:
	var cam := tour_camera()
	cam.global_position = pos
	if (look - pos).length() > 1e-3:
		cam.look_at(look, Vector3.UP if absf((look - pos).normalized().y) < 0.99 else Vector3.FORWARD)


## Fly the tour camera through [pos, look] pairs over `seconds`, eased.
func fly(points: Array, seconds: float) -> void:
	if cancelled or points.size() < 2:
		if points.size() == 1:
			place_camera(points[0][0], points[0][1])
		return
	var dur := maxf(seconds * pace, 0.05)
	var t := 0.0
	var segs := points.size() - 1
	while t < dur and not cancelled:
		var u := smoothstep(0.0, 1.0, t / dur) * segs
		var i := mini(int(u), segs - 1)
		var f := u - i
		var p: Vector3 = (points[i][0] as Vector3).lerp(points[i + 1][0], f)
		var l: Vector3 = (points[i][1] as Vector3).lerp(points[i + 1][1], f)
		place_camera(p, l)
		await tree().process_frame
		t += host.get_process_delta_time()
	place_camera(points[segs][0], points[segs][1])


## Orbit the tour camera round `center` (radius, height above it) from deg_a
## to deg_b (compass-ish, 0 = north / −Z) over `seconds`.
func orbit(center: Vector3, radius: float, height: float, deg_a: float, deg_b: float,
		seconds: float) -> void:
	if cancelled:
		return
	var dur := maxf(seconds * pace, 0.05)
	var t := 0.0
	while not cancelled:
		var u := clampf(t / dur, 0.0, 1.0)
		var a := deg_to_rad(lerpf(deg_a, deg_b, smoothstep(0.0, 1.0, u)))
		var p := center + Vector3(sin(a) * radius, height, -cos(a) * radius)
		var gy := ground_y(p.x, p.z) + 2.0
		if p.y < gy:
			p.y = gy
		place_camera(p, center)
		if u >= 1.0:
			break
		await tree().process_frame
		t += host.get_process_delta_time()


func release_camera() -> void:
	if main != null:
		main.call("pop_camera_claim", CAM_CLAIM)
	if _cam != null and is_instance_valid(_cam):
		_cam.queue_free()
	_cam = null


## Turn the first-person view by `deg` (positive = right) over `seconds`,
## optionally tilting the camera to `pitch_deg`.
func turn_player(deg: float, seconds: float, pitch_deg: float = NAN) -> void:
	if cancelled or player == null:
		return
	var cam := player.get_node_or_null("CameraArm/Camera3D") as Camera3D
	var y0 := player.rotation.y
	var p0 := cam.rotation.x if cam != null else 0.0
	var p1 := deg_to_rad(pitch_deg) if not is_nan(pitch_deg) else p0
	var dur := maxf(seconds * pace, 0.05)
	var t := 0.0
	while not cancelled:
		var u := smoothstep(0.0, 1.0, clampf(t / dur, 0.0, 1.0))
		player.rotation.y = y0 - deg_to_rad(deg) * u
		if cam != null:
			cam.rotation.x = lerpf(p0, p1, u)
		if t >= dur:
			break
		await tree().process_frame
		t += host.get_process_delta_time()


## Face the first-person camera at a world point.
func aim_player_at(target: Vector3) -> void:
	if player == null:
		return
	var cam := player.get_node_or_null("CameraArm/Camera3D") as Camera3D
	var eye := cam.global_position if cam != null else player.global_position + Vector3.UP * 1.6
	var d := target - eye
	player.rotation.y = atan2(-d.x, -d.z)
	if cam != null:
		cam.rotation.x = atan2(d.y, Vector2(d.x, d.z).length())


# -- input --------------------------------------------------------------------

## Press an action through its real bound key (the path the player uses).
func press(action: String) -> bool:
	if cancelled:
		return false
	return await HarnessInput.press_action(action)


func click_button(text: String, partial: bool = false) -> bool:
	if cancelled:
		return false
	var b := HarnessInput.find_button(tree().root, text, partial)
	if b == null:
		return false
	await HarnessInput.click(b.get_viewport(), HarnessInput.center_of(b))
	return true


func click_at(pos: Vector2) -> void:
	if cancelled:
		return
	await HarnessInput.click(tree().root.get_viewport(), pos)


func drag(a: Vector2, b: Vector2, steps: int = 16) -> void:
	if cancelled:
		return
	await HarnessInput.drag(tree().root.get_viewport(), a, b, steps)


# -- systems graph ------------------------------------------------------------

## Open the G view (the same side effects as the key) on a lens:
## "freeform" | "site" | "elevation" | "globe" ("" = whatever it opens on).
func open_graph(lens: String = "") -> bool:
	if graph == null or cancelled:
		return false
	graph.call("open_graph_view")
	await frames(3)
	if not lens.is_empty():
		graph.call("_on_mode_chip_pressed", lens)
	await frames(2)
	return bool(graph.get("visible"))


func close_graph() -> void:
	if graph != null and bool(graph.get("visible")):
		graph.call("close_graph_view")


## Orbit the live 3D lens camera (Site Plan / Globe) by `total` drag pixels,
## spread over `seconds`.
func graph_orbit(total: Vector2, seconds: float) -> void:
	if graph == null or cancelled:
		return
	var canvas: Variant = graph.get("_graph_canvas")
	var svc: Variant = canvas.get("soi_preview_service") if canvas != null else null
	if svc == null or not (svc as Object).has_method("apply_orbit_delta"):
		await wait(seconds)
		return
	var dur := maxf(seconds * pace, 0.05)
	var t := 0.0
	while t < dur and not cancelled:
		var dt := host.get_process_delta_time()
		svc.call("apply_orbit_delta", total * (dt / dur))
		await tree().process_frame
		t += dt


func reset_graph_orbit() -> void:
	var canvas: Variant = graph.get("_graph_canvas") if graph != null else null
	var svc: Variant = canvas.get("soi_preview_service") if canvas != null else null
	if svc != null and (svc as Object).has_method("reset_phys_orbit"):
		svc.call("reset_phys_orbit")


## Select a graph item through the canvas's own click handler (inspector opens).
func graph_select(item_id: String) -> void:
	if graph == null or item_id.is_empty():
		return
	var canvas: Variant = graph.get("_graph_canvas")
	if canvas != null:
		canvas.set("selected_item_id", item_id)
	graph.call("_on_canvas_item_selected", item_id)


# -- people -------------------------------------------------------------------

## Open festival mode (populates painted camps, seeds venues, opens the
## settlement view) and wait until it is up. Returns the settlement view or
## null. A second call on a populated site is quick: nothing is left to seed.
func open_festival(timeout_s: float = 25.0) -> Variant:
	if main == null or not main.has_method("open_festival_mode") or cancelled:
		return null
	main.call("open_festival_mode")
	var t := 0.0
	while t < timeout_s and not cancelled:
		var fm: Variant = main.get("festival_mode")
		if fm != null and is_instance_valid(fm) and bool(fm.call("is_active")):
			break
		await tree().process_frame
		t += host.get_process_delta_time()
	await wait(0.8)
	var sv: Variant = main.get("settlement_view")
	return sv if sv != null and is_instance_valid(sv) and bool(sv.call("is_open")) else null


## Frame the settlement camera on a ground point at a height (eased by the
## camera itself unless `snap`).
func settle_cam(at: Vector2, h: float, snap: bool = false) -> void:
	var sv: Variant = main.get("settlement_view") if main != null else null
	if sv == null or not is_instance_valid(sv) or not bool(sv.call("is_open")):
		return
	var cam: Variant = sv.call("camera")
	if cam == null:
		return
	cam.call("look_at_xz", at)
	cam.set("_h_target", h)
	if snap:
		cam.set("_h", h)
		cam.set("focus", at)


func population_bridge() -> Variant:
	return graph.get("_npc_population") if graph != null else null


func space_registry() -> Variant:
	var br: Variant = population_bridge()
	return br.call("registry_for", main) if br != null else null


## Ground position (xz) of the first tagged space of a type, or null.
func space_xz(space_type: String) -> Variant:
	var reg: Variant = space_registry()
	if reg == null:
		return null
	for rec in reg.call("spaces_of_type", space_type):
		var p: Variant = reg.call("cached_position", str((rec as Dictionary).get("id", "")))
		if p is Vector2:
			return p
		if p is Vector3:
			return Vector2(p.x, p.z)
	return null


# -- small finders ------------------------------------------------------------

## Root-scope graph items whose specs match `pred` (Callable(item) -> bool).
func graph_items(pred: Callable = Callable()) -> Array:
	var out: Array = []
	if graph == null:
		return out
	var model: Variant = graph.get("model")
	if model == null or not (model as Object).has_method("get_items_in_scope"):
		return out
	var gn := klass("GraphNesting")
	# Every scope, so an item inside a super-node (a camp's habitat) is found.
	var items: Array = gn.call("walk_items", model, "root") if gn != null \
		else model.call("get_items_in_scope", "root")
	for it in items:
		if not (it is Dictionary):
			continue
		if not pred.is_valid() or bool(pred.call(it)):
			out.append(it)
	return out


## Placed-prop records (generated maps) matching `pred` (Callable(rec) -> bool).
func prop_records(pred: Callable = Callable()) -> Array:
	var out: Array = []
	if loader == null or not loader.has_method("placed_prop_records"):
		return out
	for r in loader.call("placed_prop_records"):
		if r is Dictionary and (not pred.is_valid() or bool(pred.call(r))):
			out.append(r)
	return out


## A library preset (from a ComponentPresets array, matched by its
## specs.model_id) or {} — e.g. preset("CSP_CONCENTRATORS", "heliostat").
func preset(array_name: String, model_id: String) -> Dictionary:
	var cp := klass("ComponentPresets")
	if cp == null:
		return {}
	var arr: Variant = cp.get_script_constant_map().get(array_name, [])
	if not (arr is Array):
		return {}
	for p in arr:
		if p is Dictionary and str(((p as Dictionary).get("specs", {}) as Dictionary).get("model_id", "")) == model_id:
			return p
	return {}


## Place a library preset at a ground point the way the library's "Place it
## here" does — the prop and its bound graph node, in one go. Returns the new
## prop id ("" if nothing was placed). Remove it with remove_prop().
func place_preset(p: Dictionary, at: Vector3) -> String:
	if p.is_empty() or graph == null or not graph.has_method("_on_lib_place_model_requested"):
		return ""
	var before := {}
	for r in prop_records():
		before[str((r as Dictionary).get("id", ""))] = true
	graph.call("_on_lib_place_model_requested", p, "", at)
	await frames(3)
	for r in prop_records():
		var pid := str((r as Dictionary).get("id", ""))
		if not before.has(pid):
			return pid
	return ""


## Delete a placed prop and the graph node bound to it.
func remove_prop(prop_id: String) -> void:
	if loader != null and not prop_id.is_empty() and loader.has_method("delete_prop_by_id"):
		loader.call("delete_prop_by_id", prop_id)


## The prop's live record ({} if gone).
func prop_record(prop_id: String) -> Dictionary:
	if loader != null and loader.has_method("get_prop_record"):
		var r: Variant = loader.call("get_prop_record", prop_id)
		if r is Dictionary:
			return r
	return {}


## Save / restore the calendar and clock (stops that move the date).
func save_clock() -> Dictionary:
	if main == null:
		return {}
	return {"abs": float(main.call("get_absolute_hours")), "scale": float(main.get("time_scale"))}


func restore_clock(saved: Dictionary) -> void:
	if main == null or saved.is_empty():
		return
	main.call("set_absolute_hours", float(saved["abs"]))
	main.set("time_scale", float(saved["scale"]))


func prop_position(rec: Dictionary) -> Vector3:
	var x := float(rec.get("x", 0.0))
	var z := float(rec.get("z", 0.0))
	return Vector3(x, ground_y(x, z), z)


## The record of the prop nearest the player among `recs` ({} if none).
func nearest(recs: Array) -> Dictionary:
	var best := {}
	var bd := INF
	var p := player_xz()
	for r in recs:
		var d := Vector2(float(r.get("x", 0.0)), float(r.get("z", 0.0))).distance_to(p)
		if d < bd:
			bd = d
			best = r
	return best
