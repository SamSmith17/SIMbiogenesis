class_name FirepitBuilder
extends RefCounted

## Procedural FIREPIT — a short black steel ring with an ash bed and a few
## logs, and (FirepitFire, attached at placement) a small fire that burns
## through the night when it is cold.
##
## It is also the crowd's WARMTH: placing one tags it as a fire circle
## (PlacedPropService._auto_tag_space), so the evening gathers round it, and
## while it is lit it is a warm spot NpcComfort sends people to on a cold
## night (NpcPopulationBridge._comfort_spots). The visual and the crowd agree
## on whether it is burning because both ask `lit_for` the same question.
##
## Built from Godot primitive meshes (CylinderMesh) — no hand-wound triangles,
## so none of the clockwise-front-face traps of the box builders.

const MODEL_ID := "firepit"

## Ring geometry (metres).
const OUTER_R_M := 0.55
const HEIGHT_M := 0.36
const ASH_Y_M := 0.12
const LOG_LEN_M := 0.62
const LOG_R_M := 0.055
## Where the crowd stands round it (NpcComfort.seat_around ring radius).
const RING_R_M := 1.7

## Record keys: `firepit_mode` "auto" | "on" | "off", and `firepit_below_c`
## (auto lights it at night below this air temperature).
const MODE_AUTO := "auto"
const MODE_ON := "on"
const MODE_OFF := "off"
const MODES: Array = [MODE_AUTO, MODE_ON, MODE_OFF]
## "When it gets cold": a night under 15 °C is jacket weather (the same
## line NpcComfort draws for the cold pull).
const DEFAULT_BELOW_C := 15.0

const STEEL_COLOR := Color(0.035, 0.035, 0.038)
const ASH_COLOR := Color(0.17, 0.16, 0.15)
const LOG_COLOR := Color(0.16, 0.10, 0.06)


static func build_node(_spec: Dictionary = {}, node_name: String = "Firepit") -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	# The pit: an open-topped steel cylinder, both faces drawn so the inside
	# wall reads as the bowl it is.
	var ring := MeshInstance3D.new()
	ring.name = "Ring"
	var cyl := CylinderMesh.new()
	cyl.top_radius = OUTER_R_M
	cyl.bottom_radius = OUTER_R_M * 0.92
	cyl.height = HEIGHT_M
	cyl.cap_top = false
	cyl.radial_segments = 28
	cyl.rings = 1
	ring.mesh = cyl
	ring.position = Vector3(0.0, HEIGHT_M * 0.5, 0.0)
	ring.material_override = _mat(STEEL_COLOR, 0.55, 0.65, true)
	root.add_child(ring)
	# A rolled lip so the rim reads at a distance.
	var lip := MeshInstance3D.new()
	lip.name = "Lip"
	var torus := TorusMesh.new()
	torus.inner_radius = OUTER_R_M - 0.025
	torus.outer_radius = OUTER_R_M + 0.025
	torus.rings = 28
	torus.ring_segments = 6
	lip.mesh = torus
	lip.position = Vector3(0.0, HEIGHT_M, 0.0)
	lip.material_override = _mat(STEEL_COLOR, 0.45, 0.7, false)
	root.add_child(lip)
	# Ash bed (its emission is lifted by FirepitFire while the fire burns).
	var ash := MeshInstance3D.new()
	ash.name = "Ash"
	var disc := CylinderMesh.new()
	disc.top_radius = OUTER_R_M * 0.86
	disc.bottom_radius = OUTER_R_M * 0.86
	disc.height = 0.03
	disc.radial_segments = 24
	disc.rings = 1
	ash.mesh = disc
	ash.position = Vector3(0.0, ASH_Y_M, 0.0)
	var ash_mat := _mat(ASH_COLOR, 0.95, 0.0, false)
	ash_mat.emission_enabled = true
	ash_mat.emission = Color(1.0, 0.38, 0.08)
	ash_mat.emission_energy_multiplier = 0.0
	ash.material_override = ash_mat
	root.add_child(ash)
	# Three logs leaning into a teepee over the bed.
	var log_mat := _mat(LOG_COLOR, 0.9, 0.0, false)
	for k in 3:
		var lg := MeshInstance3D.new()
		lg.name = "Log%d" % k
		var lm := CylinderMesh.new()
		lm.top_radius = LOG_R_M * 0.8
		lm.bottom_radius = LOG_R_M
		lm.height = LOG_LEN_M
		lm.radial_segments = 8
		lm.rings = 1
		lg.mesh = lm
		lg.material_override = log_mat
		var a := TAU * float(k) / 3.0
		var lean := deg_to_rad(52.0)
		var b := Basis(Vector3.UP, a) * Basis(Vector3.RIGHT, -lean)   # tops lean IN
		lg.transform = Transform3D(b, Vector3(sin(a), 0.0, cos(a)) * 0.13 + Vector3(0.0, ASH_Y_M + 0.17, 0.0))
		root.add_child(lg)
	return root


static func _mat(c: Color, rough: float, metal: float, two_sided: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	if two_sided:
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## Is a firepit with this record burning, given {night: bool, temp_c: float}?
## Auto: at night, when the air is below its `firepit_below_c` (an unknown
## temperature counts as cold — a firepit is for nights).
static func lit_for(rec: Dictionary, env: Dictionary) -> bool:
	match str(rec.get("firepit_mode", MODE_AUTO)):
		MODE_ON:
			return true
		MODE_OFF:
			return false
	if not bool(env.get("night", false)):
		return false
	var t := float(env.get("temp_c", NAN))
	if is_nan(t):
		return true
	return t < float(rec.get("firepit_below_c", DEFAULT_BELOW_C))


## {night, temp_c} right now: night = the sun below the horizon (the world
## clock's own sun), temperature from WeatherService (NAN when unknown).
static func env_now(main: Node) -> Dictionary:
	var out := {"night": false, "temp_c": NAN}
	if main == null:
		return out
	var clock: Variant = main.get("clock")
	if clock != null and clock.has_method("get_sun_direction"):
		out["night"] = (clock.call("get_sun_direction") as Vector3).y < 0.0
	else:
		var h := fposmod(float(main.get("day_time")) if main.get("day_time") != null else 12.0, 24.0)
		out["night"] = h < 6.5 or h >= 19.5
	var ws := main.get_node_or_null("/root/WeatherService")
	if ws != null and ws.has_method("temperature_c") and clock != null:
		var hour := float(main.get("day_time")) if main.get("day_time") != null else 12.0
		out["temp_c"] = float(ws.call("temperature_c", int(clock.get("month")), int(clock.get("day")), hour))
	return out
