extends Node3D

## PEAK BEACONS — where the person the FUCK YES!!! toast names actually IS.
## When the toast announces a peak (PeakToast calls ping()), a column of
## green light stands up over that person for LIFE_S seconds, topped with
## their name and how far away they are, so the eye goes straight to them:
##   * the beam's width and height grow with the camera's distance, so it
##     reads as a beacon from the settlement view at 1 km and as a slim glow
##     up close (never a wall in your face);
##   * a ground ring pulses at its foot;
##   * when the spot is OFF-SCREEN (or behind you) an arrow on the screen's
##     edge points to it, with the name and distance.
## Real time (it is UI): it does not freeze with the sim. At most MAX at once;
## a new ping replaces the oldest. NpcDisplayPrefs.peak_beacons turns it off.
##
## It LOCKS ON to one person: every frame it stands where their body is DRAWN
## (NpcPopulationHost.drawn_position — their avatar, or the crowd shader's own
## sum replayed on the CPU), never the sim's position at the onset, so it
## stays on them as they dance or walk; and the host keeps them a full figure
## for the beacon's life (spotlight) so a real, unique body is always under
## it. If they cannot be found (left the site) it fades out.

const MAX := 3
const LIFE_S := 9.0
const IN_S := 0.35
const OUT_S := 2.5
const GREEN := Color(0.45, 1.0, 0.55)
## Pings closer together than this (toasts off: every burst pings) fold.
const MIN_GAP_S := 2.0

var _beacons: Array = []      # {root, beam, mat, ring, label, pos, born, name}
var _clock := 0.0
var _last_ping := -999.0
var _overlay: CanvasLayer = null
var _arrows: Control = null


func _ready() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = UITheme.LAYER_TOAST - 1
	add_child(_overlay)
	_arrows = Control.new()
	_arrows.set_anchors_preset(Control.PRESET_FULL_RECT)
	_arrows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arrows.draw.connect(_draw_arrows)
	_overlay.add_child(_arrows)


## Stand a beacon over the first event's person. `events` are PeakField
## onset events ({id, name, pos: Vector2, ...}).
func ping(events: Array) -> void:
	if not NpcDisplayPrefs.peak_beacons() or events.is_empty():
		return
	if _clock - _last_ping < MIN_GAP_S:
		return
	# The first peaker whose body is DRAWN: with the light crowd switched off
	# a light-tier peaker is simulated but not on screen, and a beacon over
	# nobody points at nothing. None drawn -> no beacon (the toast still shows).
	var host := _host()
	var e: Dictionary = {}
	var drawn: Variant = null
	for ev in events:
		var ed: Dictionary = ev
		if not (ed.get("pos") is Vector2):
			continue
		var dp: Variant = host.call("drawn_position", str(ed.get("id", ""))) \
			if host != null and host.has_method("drawn_position") else ed["pos"]
		if dp != null:
			e = ed
			drawn = dp
			break
	if e.is_empty():
		return
	_last_ping = _clock
	var p: Vector2 = e["pos"]
	var main := get_parent()
	var id := str(e.get("id", ""))
	if host != null and host.has_method("spotlight"):
		host.call("spotlight", id, LIFE_S + 0.5)
	var at := Vector3(p.x, TerrainSurfaceQuery.ground_height_at(main, p.x, p.y), p.y)
	if drawn is Vector3:
		at = drawn
	if _beacons.size() >= MAX:
		_free_beacon(_beacons.pop_front())
	_beacons.append(_make(at, str(e.get("name", "")), id))


## The newest live beacon {pos: Vector3, name, id}, or {} (the toast's
## click-to-look uses it).
func latest() -> Dictionary:
	if _beacons.is_empty():
		return {}
	var b: Dictionary = _beacons.back()
	return {"pos": b["pos"], "name": b["name"], "id": b["id"]}


func _make(at: Vector3, who: String, id: String) -> Dictionary:
	var root := Node3D.new()
	root.name = "Beacon"
	add_child(root)
	root.global_position = at
	var beam := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.5
	cyl.bottom_radius = 0.5
	cyl.height = 1.0
	cyl.radial_segments = 16
	cyl.rings = 1
	cyl.cap_top = false
	cyl.cap_bottom = false
	beam.mesh = cyl
	var mat := ShaderMaterial.new()
	mat.shader = load("res://core/population/peak_beacon.gdshader")
	beam.material_override = mat
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.extra_cull_margin = 500.0
	root.add_child(beam)
	var ring := MeshInstance3D.new()
	var tor := TorusMesh.new()
	tor.inner_radius = 0.9
	tor.outer_radius = 1.0
	tor.rings = 48
	tor.ring_segments = 4
	ring.mesh = tor
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	rm.albedo_color = GREEN
	rm.disable_fog = true
	ring.material_override = rm
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(ring)
	var lbl := Label3D.new()
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.fixed_size = true
	lbl.pixel_size = 0.0012
	lbl.font_size = 26
	lbl.outline_size = 10
	lbl.no_depth_test = true
	lbl.modulate = GREEN
	lbl.outline_modulate = Color(0.02, 0.15, 0.05, 0.95)
	lbl.text = "✦ %s" % (who if not who.is_empty() else NpcPeak.LABEL)
	root.add_child(lbl)
	return {"root": root, "beam": beam, "mat": mat, "ring": ring, "ring_mat": rm, "label": lbl,
		"pos": at, "born": _clock, "name": who, "id": id}


func _free_beacon(b: Dictionary) -> void:
	var r: Node = b.get("root")
	if r != null and is_instance_valid(r):
		r.queue_free()


func _process(delta: float) -> void:
	_clock += delta
	if _beacons.is_empty():
		if _arrows != null:
			_arrows.queue_redraw()
		return
	var cam := get_viewport().get_camera_3d()
	var host := _host()
	var keep: Array = []
	for b_v in _beacons:
		var b: Dictionary = b_v
		var age := _clock - float(b["born"])
		# Follow the body as it is drawn this frame; a person who cannot be
		# found any more ends the beacon early (a short fade).
		var drawn: Variant = host.call("drawn_position", str(b["id"])) \
			if host != null and host.has_method("drawn_position") and not str(b["id"]).is_empty() else null
		if drawn is Vector3:
			b["pos"] = drawn
			b["lost"] = 0.0
			(b["root"] as Node3D).global_position = drawn
		else:
			b["lost"] = float(b.get("lost", 0.0)) + delta
			if float(b["lost"]) > 1.0 and age < LIFE_S - OUT_S:
				b["born"] = _clock - (LIFE_S - OUT_S)
				age = LIFE_S - OUT_S
		if age >= LIFE_S:
			_free_beacon(b)
			continue
		keep.append(b)
		var f := clampf(age / IN_S, 0.0, 1.0) * clampf((LIFE_S - age) / OUT_S, 0.0, 1.0)
		var at: Vector3 = b["pos"]
		var d := cam.global_position.distance_to(at) if cam != null else 50.0
		# Readable from any zoom: slim and short up close, a tall wide column
		# from the settlement view's site height.
		var w := clampf(d * 0.022, 0.8, 32.0)
		var h := clampf(18.0 + d * 0.18, 18.0, 420.0)
		var beam: MeshInstance3D = b["beam"]
		beam.scale = Vector3(w, h, w)
		beam.position = Vector3(0.0, h * 0.5, 0.0)
		(b["mat"] as ShaderMaterial).set_shader_parameter("fade", f)
		(b["mat"] as ShaderMaterial).set_shader_parameter("t", _clock)
		# The ring at its foot breathes out and back.
		var rr := maxf(w * 3.5, 3.0) * (1.0 + 0.25 * sin(_clock * 4.0))
		var ring: MeshInstance3D = b["ring"]
		ring.scale = Vector3(rr, maxf(rr * 0.05, 0.2), rr)
		ring.position = Vector3(0.0, 0.08, 0.0)
		var rc := GREEN
		rc.a = 0.8 * f
		(b["ring_mat"] as StandardMaterial3D).albedo_color = rc
		var lbl: Label3D = b["label"]
		lbl.position = Vector3(0.0, h + 1.0, 0.0) if d > 40.0 else Vector3(0.0, 2.6, 0.0)
		var lc := GREEN
		lc.a = f
		lbl.modulate = lc
		var oc := lbl.outline_modulate
		oc.a = 0.95 * f
		lbl.outline_modulate = oc
		var who := str(b["name"])
		lbl.text = "✦ %s · %s  %d m" % [who if not who.is_empty() else "Someone", NpcPeak.LABEL, int(d)]
	_beacons = keep
	_arrows.queue_redraw()


func _host() -> Node:
	var scene := get_tree().current_scene if get_tree() != null else null
	var sgv := scene.get_node_or_null("UILayer/SystemGraphView") if scene != null else null
	if sgv == null or not sgv.has_method("npc_population_host"):
		return null
	return sgv.call("npc_population_host")


## Off-screen beacons: an arrow on the screen edge, toward them, with the
## name and distance.
func _draw_arrows() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var vp := _arrows.get_viewport_rect().size
	var font := _arrows.get_theme_default_font()
	var margin := 46.0
	for b_v in _beacons:
		var b: Dictionary = b_v
		var age := _clock - float(b["born"])
		var f := clampf(age / IN_S, 0.0, 1.0) * clampf((LIFE_S - age) / OUT_S, 0.0, 1.0)
		var at: Vector3 = b["pos"] + Vector3(0.0, 1.5, 0.0)
		var behind := cam.is_position_behind(at)
		var sp := cam.unproject_position(at)
		var inside := not behind and sp.x >= 0.0 and sp.y >= 0.0 and sp.x <= vp.x and sp.y <= vp.y
		if inside:
			continue
		var centre := vp * 0.5
		var dir := sp - centre
		if behind:
			dir = -dir
		if dir.length() < 1.0:
			dir = Vector2(0.0, 1.0)
		dir = dir.normalized()
		# Clamp to the screen rect minus the margin.
		var half := centre - Vector2(margin, margin)
		var k := minf(half.x / maxf(absf(dir.x), 1e-4), half.y / maxf(absf(dir.y), 1e-4))
		var p := centre + dir * k
		var pulse := 0.75 + 0.25 * sin(_clock * 6.0)
		var col := GREEN
		col.a = f * pulse
		var tip := p + dir * 24.0
		var side := Vector2(-dir.y, dir.x)
		_arrows.draw_colored_polygon(PackedVector2Array([tip, p - dir * 8.0 + side * 16.0,
			p - dir * 8.0 - side * 16.0]), col)
		var d := int(cam.global_position.distance_to(b["pos"]))
		var txt := "%s  %d m" % [str(b["name"]), d]
		var tw := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		var lp := p - dir * 30.0 - Vector2(tw * 0.5, -4.0) + Vector2(0.0, 26.0 if absf(dir.x) > absf(dir.y) else 0.0)
		if absf(dir.x) > absf(dir.y):
			lp.x = p.x - tw - 12.0 if dir.x > 0.0 else p.x + 12.0
		lp.x = clampf(lp.x, 6.0, vp.x - tw - 6.0)
		lp.y = clampf(lp.y, 16.0, vp.y - 6.0)
		_arrows.draw_string_outline(font, lp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 4, Color(0, 0, 0, 0.85 * f))
		_arrows.draw_string(font, lp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)
