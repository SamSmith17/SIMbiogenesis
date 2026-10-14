extends Node3D

## PEAK RIPPLES — what a FUCK YES!!! does to the people round it, made
## visible. Every onset sends a green ring out across the ground from the new
## peaker to the edge of their contagion's reach (the 3x3 block of NpcPeak
## cells PeakField counts), so a spreading wave reads as rings rippling out
## and overlapping through the crowd, and the player can SEE whose
## neighbourhood just got easier to tip. The ring's strength follows the
## contagion setting: off, a peak is a small flash and nothing more.
##
## Reads the bridge's NON-consuming onset log (peak_events_since) on its own
## cursor — the toast drains a different list. One MultiMesh, MAX rings
## pooled round-robin; timing on the NPC cosmetic clock (fx_time_npc), so the
## rings freeze when the sim is paused, like the glow.

const MAX := 64
const POLL_S := 0.1
## The contagion reach from a peaker: 1.5 cells — the middle of the 3x3 block.
const REACH_M := NpcPeak.CELL_M * 1.5
const FLASH_M := 2.0
## More onsets than this in one poll (a catch-up, a big wave at speed) are
## thinned evenly: a few dozen rings read as a wave, two hundred as noise.
const MAX_PER_POLL := 16
const LIFT_M := 0.12

var _mm: MultiMesh = null
var _mmi: MultiMeshInstance3D = null
var _next := 0
var _serial := -1
var _accum := 0.0


func _ready() -> void:
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	var q := QuadMesh.new()
	q.size = Vector2(2.0, 2.0)
	q.orientation = PlaneMesh.FACE_Y
	_mm.mesh = q
	_mm.instance_count = MAX
	for i in MAX:
		_mm.set_instance_transform(i, Transform3D(Basis(), Vector3(0.0, -10000.0, 0.0)))
		_mm.set_instance_custom_data(i, Color(-1000.0, 0.0, 0.0, 0.0))
	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "PeakRipples"
	_mmi.multimesh = _mm
	var mat := ShaderMaterial.new()
	mat.shader = load("res://core/population/peak_ripple.gdshader")
	_mmi.material_override = mat
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Rings land anywhere a peak can: the instance AABB means nothing here.
	_mmi.custom_aabb = AABB(Vector3(-1e5, -1e4, -1e5), Vector3(2e5, 2e4, 2e5))
	add_child(_mmi)


func _process(delta: float) -> void:
	_accum += delta
	if _accum < POLL_S:
		return
	_accum = 0.0
	var b := _bridge()
	if b == null or not b.has_method("peak_events_since"):
		return
	var d: Dictionary = b.call("peak_events_since", _serial)
	var latest := int(d.get("serial", 0))
	if _serial < 0 or latest < _serial:
		# First look (or the field was rebuilt): start from now — never
		# replay a whole evening of old rings on load.
		_serial = latest
		return
	_serial = latest
	var ev: Array = d.get("events", [])
	if ev.is_empty():
		return
	var main := get_parent()
	var now := SimFxRate.now(main, SimFxRate.SYS_NPC)
	var c := PopTestPrefs.peak_contagion()
	var reach := lerpf(FLASH_M, REACH_M, clampf(c, 0.0, 1.0)) * (1.0 + 0.15 * maxf(c - 1.0, 0.0))
	var strength := 0.35 + 0.65 * clampf(c, 0.0, 1.0)
	var stride := maxf(float(ev.size()) / float(MAX_PER_POLL), 1.0)
	var k := 0.0
	while int(k) < ev.size():
		var e: Dictionary = ev[int(k)]
		var p: Vector2 = e.get("pos", Vector2.ZERO)
		var y := TerrainSurfaceQuery.ground_height_at(main, p.x, p.y) + LIFT_M
		var i := _next
		_next = (_next + 1) % MAX
		# Each ring staggered a hair, so a burst arrives as a ripple, not a
		# single flash.
		var start := now + 0.06 * (k / stride)
		_mm.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(reach, 1.0, reach)), Vector3(p.x, y, p.y)))
		_mm.set_instance_custom_data(i, Color(start, strength, 0.0, 0.0))
		k += stride


func _bridge() -> Object:
	var scene := get_tree().current_scene if get_tree() != null else null
	var sgv := scene.get_node_or_null("UILayer/SystemGraphView") if scene != null else null
	if sgv == null or not sgv.has_method("npc_population_bridge"):
		return null
	return sgv.call("npc_population_bridge")
