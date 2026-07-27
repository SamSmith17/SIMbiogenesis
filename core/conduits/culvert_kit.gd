class_name CulvertKit
extends RefCounted

## Corrugated PE culvert ring kit. One baked ring mesh (8″ reference) is
## uniformly scaled per nominal ID; runtime stamps rings along a large-radius
## PE sweep (see CulvertRouter / CulvertAssembler).

const DATA_DIR := "res://core/conduits/data/"
const FAMILY := "pe_culvert"
const SRC_GLB := "res://Imported Models/PipeFittings/culvert_pe_8in.glb"
## Common dual-wall HDPE culvert IDs (in). Reference bake is 8″.
const SIZES_IN := [4.0, 6.0, 8.0, 10.0, 12.0, 15.0, 18.0, 21.0, 24.0]
const REF_SIZE_IN := 8.0
## Manufacturer guidance for dual-wall PE: ~3–5× OD. We use 4× OD default.
const DEFAULT_BEND_RADIUS_OD_MULT := 4.0

var kit_id: String = ""
var revision: int = 1
var size_in: float = 8.0
var family: String = FAMILY
var nominal_od_m: float = 0.24
var pitch_m: float = 0.057
var ring_mesh: Mesh = null
var source_glb: String = SRC_GLB


static func nearest_size_in(size_in: float) -> float:
	var best := SIZES_IN[0]
	var best_d := INF
	for s: float in SIZES_IN:
		var d := absf(s - size_in)
		if d < best_d:
			best_d = d
			best = s
	return best


static func size_token(size_in: float) -> String:
	var nearest := nearest_size_in(size_in)
	var whole := int(floor(nearest + 1e-6))
	var frac := nearest - float(whole)
	if frac < 0.01:
		return str(whole)
	return str(nearest).replace(".", "_")


static func kit_id_for_size(size_in: float) -> String:
	return "%s_%s" % [FAMILY, size_token(size_in)]


static func size_label(size_in: float) -> String:
	var s := nearest_size_in(size_in)
	var whole := int(floor(s + 1e-6))
	if absf(s - float(whole)) < 0.01:
		return "%d″" % whole
	return "%.0f″" % s


# Process-lifetime cache, mirrors PipeKit.load_kit — avoids the JSON+mesh reload
# on the drag-preview hot path (conduit_style_modal). Kit data is immutable.
static var _kit_cache: Dictionary = {}

static func load_kit(kit_id: String) -> CulvertKit:
	if _kit_cache.has(kit_id):
		var hit: Variant = _kit_cache[kit_id]
		return hit as CulvertKit if hit is CulvertKit else null
	var kit_loaded := _load_kit_uncached(kit_id)
	_kit_cache[kit_id] = kit_loaded if kit_loaded != null else false
	return kit_loaded


static func _load_kit_uncached(kit_id: String) -> CulvertKit:
	var path := DATA_DIR + "pipe_kit_%s.json" % kit_id
	if not FileAccess.file_exists(path):
		# Allow bare size token ids.
		if not kit_id.begins_with(FAMILY):
			path = DATA_DIR + "pipe_kit_%s.json" % kit_id_for_size(
				float(kit_id.replace("_", ".")))
		if not FileAccess.file_exists(path):
			push_warning("CulvertKit: missing %s" % path)
			return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	var d: Dictionary = parsed
	var kit := CulvertKit.new()
	kit.kit_id = str(d.get("kit_id", kit_id))
	kit.revision = int(d.get("revision", 1))
	kit.size_in = float(d.get("size_in", REF_SIZE_IN))
	kit.family = str(d.get("family", FAMILY))
	kit.nominal_od_m = float(d.get("nominal_od_m", 0.24))
	kit.pitch_m = float(d.get("pitch_m", 0.057))
	kit.source_glb = str(d.get("source_glb", SRC_GLB))
	var mesh_path := str(d.get("ring_mesh_res", ""))
	if mesh_path.is_empty():
		var parts: Dictionary = d.get("parts", {}) as Dictionary
		var ring: Dictionary = parts.get("ring", {}) as Dictionary
		mesh_path = str(ring.get("mesh_res", ""))
	if mesh_path.is_empty() or not ResourceLoader.exists(mesh_path):
		push_warning("CulvertKit: ring mesh missing for %s" % kit_id)
		return null
	kit.ring_mesh = load(mesh_path) as Mesh
	if kit.ring_mesh == null:
		return null
	return kit


## Minimum centerline bend radius for PE culvert of this size.
func bend_radius_m(style: Dictionary = {}) -> float:
	var mult := float(style.get("bend_radius_od_mult", DEFAULT_BEND_RADIUS_OD_MULT))
	mult = clampf(mult, 2.0, 12.0)
	return maxf(nominal_od_m * mult, pitch_m * 6.0)


static func bend_radius_for_type(type_id: String, style: Dictionary = {}) -> float:
	var sz := ConduitKinds.pipe_size_in(type_id, style)
	var kit := load_kit(kit_id_for_size(sz))
	if kit == null:
		var od := (sz * 0.0254) * 1.18  # rough OD from ID
		return od * DEFAULT_BEND_RADIUS_OD_MULT
	return kit.bend_radius_m(style)
