extends Node3D

## FIRE FLOW props: two flaming poi spinning round each fire-flow performer's
## hands while the bridge has them on the lane (NpcPopulationBridge
## .burn_roles). Works for either tier because it is placed from where the
## performer's body is DRAWN (NpcPopulationHost.drawn_position) and the way
## they are travelling (frame-to-frame motion; they go round the effigy), not
## from a hand bone: the poi swing in vertical circles either side of the
## body, a world-space particle trail behind each head, and a small warm light
## per performer that lights the crowd at night.
##
## Cosmetic: the spin runs on the NPC cosmetic clock (frozen when the sim is
## paused, time-lapsed with it). Pooled — at most MAX_PERFORMERS rigs; idle
## ones are hidden, not freed, until the burn ends.

const MAX_PERFORMERS := 24
const POLL_S := 0.25
const SPIN_HZ := 1.3
const POI_R := 0.45
const HAND_H := 1.2
const SIDE_M := 0.38
const FLAME := Color(1.0, 0.55, 0.15)

var _rigs: Dictionary = {}       # id -> {root, poi: [GPUParticles3D x2], light, prev: Vector3, fwd: Vector3}
var _ids: Array = []
var _accum := 0.0


func _process(delta: float) -> void:
	_accum += delta
	if _accum >= POLL_S:
		_accum = 0.0
		_refresh_ids()
	if _ids.is_empty():
		return
	var main := get_parent()
	var host := _host()
	var t := SimFxRate.now(main, SimFxRate.SYS_NPC)
	var night := clampf(_night(main), 0.0, 1.0)
	for id in _ids:
		var rig: Dictionary = _rigs.get(id, {})
		if rig.is_empty():
			continue
		var p: Variant = host.call("drawn_position", id) if host != null and host.has_method("drawn_position") else null
		if not (p is Vector3):
			(rig["root"] as Node3D).visible = false
			continue
		var pos: Vector3 = p
		var prev: Vector3 = rig["prev"]
		var mv := Vector3(pos.x - prev.x, 0.0, pos.z - prev.z)
		if mv.length() > 0.005:
			rig["fwd"] = mv.normalized()
		rig["prev"] = pos
		var fwd: Vector3 = rig["fwd"]
		var right := fwd.cross(Vector3.UP).normalized()
		(rig["root"] as Node3D).visible = true
		var ang := t * TAU * SPIN_HZ
		var pois: Array = rig["poi"]
		for k in 2:
			var side := -1.0 if k == 0 else 1.0
			var a := ang + (0.0 if k == 0 else PI)
			var hand := pos + Vector3.UP * HAND_H + right * side * SIDE_M
			var head := hand + (fwd * cos(a) + Vector3.UP * sin(a)) * POI_R
			(pois[k] as GPUParticles3D).global_position = head
		var light: OmniLight3D = rig["light"]
		light.global_position = pos + Vector3.UP * HAND_H
		light.light_energy = lerpf(0.3, 1.6, night) * (0.85 + 0.15 * sin(t * 23.0 + float(hash(id) % 7)))


func _refresh_ids() -> void:
	var b := _bridge()
	var want: Array = []
	if b != null and b.has_method("burn_roles"):
		var roles: Dictionary = b.call("burn_roles")
		for sid in roles:
			for id in ((roles[sid] as Dictionary).get("performers", []) as Array):
				if want.size() < MAX_PERFORMERS:
					want.append(str(id))
	for id in _rigs.keys():
		if not want.has(id):
			(_rigs[id]["root"] as Node).queue_free()
			_rigs.erase(id)
	for id in want:
		if not _rigs.has(id):
			_rigs[id] = _make_rig()
	_ids = want


func _make_rig() -> Dictionary:
	var root := Node3D.new()
	root.top_level = true
	add_child(root)
	var pois: Array = []
	for k in 2:
		var gp := GPUParticles3D.new()
		gp.amount = 28
		gp.lifetime = 0.35
		gp.local_coords = false
		gp.fixed_fps = 0
		gp.visibility_aabb = AABB(Vector3(-3, -3, -3), Vector3(6, 6, 6))
		var pm := ParticleProcessMaterial.new()
		pm.gravity = Vector3(0.0, 0.6, 0.0)
		pm.initial_velocity_min = 0.0
		pm.initial_velocity_max = 0.15
		pm.scale_min = 0.6
		pm.scale_max = 1.0
		var curve := CurveTexture.new()
		var c := Curve.new()
		c.add_point(Vector2(0.0, 1.0))
		c.add_point(Vector2(1.0, 0.0))
		curve.curve = c
		pm.scale_curve = curve
		var grad := Gradient.new()
		grad.set_color(0, Color(1.0, 0.85, 0.4, 1.0))
		grad.set_color(1, Color(1.0, 0.25, 0.05, 0.0))
		var gt := GradientTexture1D.new()
		gt.gradient = grad
		pm.color_ramp = gt
		gp.process_material = pm
		var q := QuadMesh.new()
		q.size = Vector2(0.16, 0.16)
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.vertex_color_use_as_albedo = true
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.disable_fog = true
		m.albedo_color = Color(1.6, 1.0, 0.5)
		q.material = m
		gp.draw_pass_1 = q
		gp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(gp)
		pois.append(gp)
	var light := OmniLight3D.new()
	light.light_color = FLAME
	light.omni_range = 5.0
	light.shadow_enabled = false
	light.distance_fade_enabled = true
	light.distance_fade_begin = 80.0
	light.distance_fade_length = 30.0
	root.add_child(light)
	return {"root": root, "poi": pois, "light": light, "prev": Vector3.INF, "fwd": Vector3(0, 0, 1)}


## Main's last `npc_night` push (reading the global back off the
## RenderingServer stalls on the render thread).
func _night(main: Node) -> float:
	var v: Variant = main.get("_npc_night_pushed") if main != null else null
	return float(v) if v != null and float(v) >= 0.0 else 1.0


func _sgv() -> Node:
	return ServiceLocator.graph()


func _bridge() -> Object:
	var s := _sgv()
	return s.call("npc_population_bridge") if s != null and s.has_method("npc_population_bridge") else null


func _host() -> Node:
	var s := _sgv()
	return s.call("npc_population_host") if s != null and s.has_method("npc_population_host") else null
