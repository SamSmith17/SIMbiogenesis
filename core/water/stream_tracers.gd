class_name StreamTracers
extends MultiMeshInstance3D

## Flow view: little bright beads riding every stream at its Manning velocity,
## so the speed of water — set by gravity through the bed slope — is visible
## at a glance: a riffle races, a lowland reach creeps, a dry ditch is empty.
##
## Positions are a pure function of the COSMETIC clock (SimFxRate, the lights
## track): bead k of a stream sits at s = (s0_k + v·t) mod L, so the view
## freezes when the sim pauses and time-lapses (sub-linearly) at speed, the
## same contract as fire, crowds and LED chases. Nothing integrates.
##
## Beads are re-placed every frame from per-stream arrays baked once per
## network rebuild; only beads within CULL_M of the camera are drawn.

const MAX_BEADS := 6000
const MAX_PER_STREAM := 120
const BEAD_SPACING_M := 9.0
const CULL_M := 900.0
const BEAD_R_M := 0.16

## [{pts3, s, v, n, s0, len, scale, first (instance index), aabb (Rect2 xz),
##   hidden (bool — the whole range is currently parked)}]
var _streams: Array = []
var _main: Node = null


func _ready() -> void:
	name = "WaterTracers"
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var sphere := SphereMesh.new()
	sphere.radius = BEAD_R_M
	sphere.height = BEAD_R_M * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	mm.mesh = sphere
	mm.instance_count = 0
	multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.75, 0.95, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.4, 0.8, 1.0)
	mat.emission_energy_multiplier = 1.6
	material_override = mat


## Bake the streams. `items` = Array of {points (PackedVector2Array stations),
## s, level (PackedFloat32Array water surface Y per station), velocity_ms,
## q_lps}. Dry streams get no beads.
func set_streams(items: Array, main: Node) -> void:
	_main = main
	_streams = []
	var total := 0
	for it_v in items:
		var it: Dictionary = it_v
		var pts: PackedVector2Array = it["points"]
		var s: PackedFloat32Array = it["s"]
		var lev: PackedFloat32Array = it["level"]
		var v := float(it.get("velocity_ms", 0.0))
		if pts.size() < 2 or v <= 0.005 or float(it.get("q_lps", 0.0)) <= 0.05:
			continue
		var length := s[s.size() - 1]
		var n := clampi(int(length / BEAD_SPACING_M), 2, MAX_PER_STREAM)
		if total + n > MAX_BEADS:
			n = MAX_BEADS - total
		if n <= 0:
			break
		var p3 := PackedVector3Array()
		p3.resize(pts.size())
		var box := Rect2(pts[0], Vector2.ZERO)
		for i in pts.size():
			p3[i] = Vector3(pts[i].x, lev[i] + 0.04, pts[i].y)
			box = box.expand(pts[i])
		var s0 := PackedFloat32Array()
		s0.resize(n)
		for k in n:
			# Even spacing plus a hashed jitter so beads never march in lockstep.
			s0[k] = (float(k) + 0.5 * NpcHash.unit01(str(it.get("id", "")), "bead%d" % k)) * length / float(n)
		var sc := clampf(0.6 + 0.25 * log(maxf(float(it.get("q_lps", 1.0)), 1.0)) / log(10.0), 0.6, 2.2)
		_streams.append({"pts3": p3, "s": s, "v": v, "n": n, "s0": s0, "len": length,
			"scale": sc, "first": total, "aabb": box, "hidden": false})
		total += n
	multimesh.instance_count = total
	var hidden := Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)
	for i in total:
		multimesh.set_instance_transform(i, hidden)
	for st in _streams:
		(st as Dictionary)["hidden"] = true


func _process(delta: float) -> void:
	PerfSpan.begin("stream_tracers")
	_perf_tick(delta)
	PerfSpan.end("stream_tracers")


## The per-frame body; `_process` above only times it.
func _perf_tick(_delta: float) -> void:
	if multimesh == null or multimesh.instance_count == 0 or not visible:
		return
	var t := SimFxRate.now(_main, SimFxRate.SYS_LIGHTS) if _main != null else 0.0
	var cam := get_viewport().get_camera_3d()
	var cp := cam.global_position if cam != null else Vector3.ZERO
	var hidden := Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)
	var cxz := Vector2(cp.x, cp.z)
	for st_v in _streams:
		var st: Dictionary = st_v
		var first := int(st["first"])
		var n := int(st["n"])
		# Whole streams out of range cost nothing per frame: park once.
		var box: Rect2 = st["aabb"]
		if box.grow(CULL_M).has_point(cxz) == false:
			if not bool(st["hidden"]):
				for k in n:
					multimesh.set_instance_transform(first + k, hidden)
				st["hidden"] = true
			continue
		st["hidden"] = false
		var length := float(st["len"])
		var v := float(st["v"])
		var s0: PackedFloat32Array = st["s0"]
		var sc := float(st["scale"])
		for k in n:
			var p := _at(st, fposmod(s0[k] + v * t, length))
			var dist := p.distance_to(cp)
			if dist > CULL_M:
				multimesh.set_instance_transform(first + k, hidden)
			else:
				# Grow with distance so a bead stays a few pixels wide from the
				# drone; true size up close.
				var g := sc * maxf(1.0, dist / 45.0)
				multimesh.set_instance_transform(first + k, Transform3D(Basis().scaled(Vector3.ONE * g), p))


static func _at(st: Dictionary, s_at: float) -> Vector3:
	var s: PackedFloat32Array = st["s"]
	var p3: PackedVector3Array = st["pts3"]
	var lo := 0
	var hi := s.size() - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if s[mid] <= s_at:
			lo = mid
		else:
			hi = mid
	var t := (s_at - s[lo]) / maxf(s[hi] - s[lo], 1e-6)
	return p3[lo].lerp(p3[hi], clampf(t, 0.0, 1.0))
