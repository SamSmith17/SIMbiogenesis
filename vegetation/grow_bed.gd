class_name GrowBed
extends Node3D

## A grow bed at its real size with its crops at their real spacing.
## Placed as a PlacedProp ModelRoot via ModelCatalog (`MODEL_ID`). The record
## (or the plant node's specs) carry `grow_bed_spec`:
##   layout    "bed" (raised beds 1.2 m wide), "plot" (an in-ground square),
##             "keyhole" (concentric ring beds round a centre, with a slot from
##             the edge to the middle; the bed a greenhouse dome holds)
##   area_m2   bed area for "bed" / "plot" (0 = one small 1.2 x 0.8 m bed)
##   crops     "garden" (mixed vegetables, GardenCrops.GARDEN_RINGS), a crop id
##             for a single crop ("willow", "sorghum", "lettuce", ...) or an
##             Array of crop ids to cycle
##   keyhole   {outer_r, ring_w, path_w, rings, slot_w, centre_r, wall_h}
##   plant_abs_h  when the bed was planted (absolute hours on Main's clock)
## Plants are drawn by garden_crop.gdshader, one MultiMesh per crop, each plant
## growing from its own sowing day: a bed is sown in succession, section by
## section, so it is never all bare or all ripe at once. Look only: what the
## bed yields is its plant node's model.

const MODEL_ID := "grow_bed"
const BED_W := 1.2
const BED_PATH := 0.6
const BED_MAX_LEN := 10.0
const SMALL_BED := Vector2(1.2, 0.8)
const WALL_H := 0.32
const PLOT_BERM := 0.12
## Plants are drawn to this distance (low crops to the shorter one); beyond it
## the bed shows its canopy band.
const CROP_DRAW_M := 75.0
const CROP_DRAW_LOW_M := 45.0
## Length of one bed section (one sowing) along a bed or a ring.
const SECTION_M := 2.8
const KEYHOLE_DEFAULTS := {"outer_r": 9.5, "ring_w": 1.2, "path_w": 0.6, "rings": 5,
	"slot_w": 1.0, "centre_r": 1.1, "wall_h": 0.42}
## Legacy record keys (the lettuce bed's clock), still read.
const DEFAULT_GROW_DAYS := 90.0

const _SHADER := preload("res://vegetation/garden_crop.gdshader")

@export var grow_days: float = DEFAULT_GROW_DAYS
@export var senescence_days: float = 15.0
## Absolute hours when this bed was planted.
var plant_abs_h: float = -1.0
var spec: Dictionary = {}

var _mat: ShaderMaterial = null
var _main: Node = null
var _tick := 0.0
var _plants_n := 0
var _crop_counts: Dictionary = {}


static func build_node(p_spec: Dictionary = {}, node_name: String = "GrowBed") -> GrowBed:
	var bed := GrowBed.new()
	bed.name = node_name
	bed.spec = p_spec.duplicate(true)
	if p_spec.has("grow_days"):
		bed.grow_days = float(p_spec["grow_days"])
	if p_spec.has("senescence_days"):
		bed.senescence_days = float(p_spec["senescence_days"])
	if p_spec.has("plant_abs_h"):
		bed.plant_abs_h = float(p_spec["plant_abs_h"])
	bed._build_visuals()
	return bed


## Legacy helper (tests / tools). Prefer library -> Place in world.
static func spawn_near_player(parent: Node3D, main: Node, offset := Vector3(2.5, 0.0, 1.5)) -> GrowBed:
	var bed := build_node({})
	parent.add_child(bed)
	bed._main = main
	var player: Node3D = null
	if main != null and main.get_tree() != null:
		player = main.get_tree().get_first_node_in_group("player") as Node3D
	var origin := offset
	if player != null:
		origin = player.global_position + player.global_transform.basis * offset
	bed.global_position = origin
	if main != null and main.has_method("get_absolute_hours"):
		bed.plant_abs_h = float(main.call("get_absolute_hours"))
	else:
		bed.plant_abs_h = 0.0
	bed._update_clock()
	return bed


func configure_from_record(rec: Dictionary) -> void:
	if rec.has("grow_days"):
		grow_days = float(rec["grow_days"])
	if rec.has("senescence_days"):
		senescence_days = float(rec["senescence_days"])
	if rec.has("plant_abs_h"):
		plant_abs_h = float(rec["plant_abs_h"])
	var s: Variant = rec.get("grow_bed_spec", {})
	if s is Dictionary and (s as Dictionary).has("plant_abs_h"):
		plant_abs_h = float((s as Dictionary)["plant_abs_h"])
	_update_clock()


func _ready() -> void:
	if _main == null:
		_main = _find_main()
	if plant_abs_h < 0.0:
		plant_abs_h = float(_main.call("get_absolute_hours")) if _main != null \
				and _main.has_method("get_absolute_hours") else 0.0
	if _mat == null:
		_build_visuals()
	_update_clock()


func _process(delta: float) -> void:
	_tick -= delta
	if _tick > 0.0:
		return
	_tick = 0.5
	_update_clock()


## The bed a plant node stands for: its specs' own grow_bed_spec, else a
## layout sized from its area (a food crop in raised beds, anything else as
## an in-ground plot of sorghum-sudan grass for biomass).
static func spec_for_plant(specs: Dictionary, plant_abs_h: float) -> Dictionary:
	var out: Dictionary = {}
	if specs.get("grow_bed_spec") is Dictionary:
		out = (specs["grow_bed_spec"] as Dictionary).duplicate(true)
	if not out.has("layout"):
		var food := float(specs.get("food_fraction", 0.0)) > 0.0
		out["layout"] = "bed" if food else "plot"
		out["crops"] = "garden" if food else "sorghum"
	if not out.has("area_m2") and str(out["layout"]) != "keyhole":
		out["area_m2"] = float(specs.get("area_m2", 10.0))
	out["plant_abs_h"] = plant_abs_h
	return out


## Plants drawn on this bed (for checks).
func plant_count() -> int:
	return _plants_n


## {crop id: plants} on this bed.
func crop_counts() -> Dictionary:
	return _crop_counts.duplicate()


## The growing area this bed's layout holds, m² (soil, not paths).
func bed_area_m2() -> float:
	return GrowBed.layout_area_m2(spec)


static func layout_area_m2(s: Dictionary) -> float:
	match str(s.get("layout", "bed")):
		"keyhole":
			var tot := 0.0
			for r in _keyhole_rings(_keyhole(s)):
				var rr: Dictionary = r
				tot += 0.5 * (float(rr["a1"]) - float(rr["a0"])) \
						* (pow(float(rr["r1"]), 2.0) - pow(float(rr["r0"]), 2.0))
			return tot
		"plot":
			return maxf(float(s.get("area_m2", 50.0)), 1.0)
		_:
			var a := float(s.get("area_m2", 0.0))
			return a if a > 0.0 else SMALL_BED.x * SMALL_BED.y


## What the kit weighs and packs to: galvanised corrugated bed walls (about
## 4.5 kg/m² of wall, 0.5 mm steel), drip line and fittings, seed and tools.
static func packed_spec(s: Dictionary) -> Dictionary:
	var wall_m := 0.0
	var wall_h := WALL_H
	match str(s.get("layout", "bed")):
		"keyhole":
			var k := _keyhole(s)
			wall_h = float(k["wall_h"])
			for r in _keyhole_rings(k):
				var rr: Dictionary = r
				var span := float(rr["a1"]) - float(rr["a0"])
				wall_m += span * (float(rr["r0"]) + float(rr["r1"])) + 2.0 * (float(rr["r1"]) - float(rr["r0"]))
		"plot":
			return {"w_m": 1.2, "d_m": 0.8, "h_m": 0.6, "mass_kg": 25.0 + 0.4 * float(s.get("area_m2", 50.0)),
				"form": "crate", "source": "computed"}
		_:
			var a := layout_area_m2(s)
			for b in _bed_rects(a):
				var rc: Rect2 = b
				wall_m += 2.0 * (rc.size.x + rc.size.y)
	var area := layout_area_m2(s)
	var mass := wall_m * wall_h * 4.5 + area * 0.25 + 12.0
	var sheets := ceilf(wall_m * wall_h / 2.4)
	return {"w_m": 2.45, "d_m": 0.9, "h_m": clampf(0.12 + sheets * 0.008, 0.2, 1.4),
		"mass_kg": snappedf(mass, 1.0), "form": "panel_stack", "source": "computed"}


# ---------------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------------

func _build_visuals() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_crop_counts.clear()
	_plants_n = 0
	_mat = ShaderMaterial.new()
	_mat.shader = _SHADER
	var rng := RandomNumberGenerator.new()
	rng.seed = int(spec.get("seed", 1)) * 7919 + 13
	var places: Dictionary = {}      # crop -> Array of [Transform3D, sow_d, seed]
	var shell := GrowBedShell.new()
	match str(spec.get("layout", "bed")):
		"keyhole":
			_layout_keyhole(shell, places, rng)
		"plot":
			_layout_plot(shell, places, rng)
		_:
			_layout_beds(shell, places, rng)
	var frame := MeshInstance3D.new()
	frame.name = "BedFrame"
	frame.mesh = shell.commit()
	add_child(frame)
	if shell.canopy.v.size() > 0:
		var can := MeshInstance3D.new()
		can.name = "Canopy"
		can.mesh = shell.canopy.commit()
		can.material_override = _canopy_mat()
		can.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		can.visibility_range_begin = CROP_DRAW_M - 10.0
		can.visibility_range_begin_margin = 10.0
		can.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		can.set_meta("skip_prop_collision", true)
		add_child(can)
	for crop in places.keys():
		var list: Array = places[crop]
		if list.is_empty():
			continue
		var info := GardenCrops.info(str(crop))
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = GardenCrops.mesh(str(crop))
		mm.instance_count = list.size()
		for i in list.size():
			var e: Array = list[i]
			mm.set_instance_transform(i, e[0])
			mm.set_instance_custom_data(i, Color(float(e[1]), float(info["cycle"]), float(info["mature"]), float(e[2])))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Crop_%s" % str(crop)
		mmi.multimesh = mm
		mmi.material_override = _mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if bool(info.get("shadow", false)) \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_end = CROP_DRAW_M if float(info["height"]) >= 0.5 else CROP_DRAW_LOW_M
		mmi.visibility_range_end_margin = 10.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		mmi.set_meta("skip_prop_collision", true)
		add_child(mmi)
		_crop_counts[str(crop)] = list.size()
		_plants_n += list.size()
	_update_clock()


func _canopy_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 0.85
	return m


## Sow `crop` over a set of points; one section shares one sowing day.
func _sow(places: Dictionary, crop: String, pts: Array, y: float, sow_d: float,
		rng: RandomNumberGenerator) -> void:
	if not places.has(crop):
		places[crop] = []
	for p in pts:
		var q: Vector2 = p
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(0.85, 1.1))
		var sd := sow_d + rng.randf_range(-2.0, 2.0)
		(places[crop] as Array).append([Transform3D(b, Vector3(q.x, y, q.y)), sd, rng.randf()])


## The day a section is first sown: the planting is spread over one cycle of
## its crop (succession sowing), so the bed comes up section by section.
func _first_sow(crop: String, k: int, n: int) -> float:
	var cyc := float(GardenCrops.info(crop)["cycle"])
	var share := fposmod(float(k) * 0.618034, 1.0)
	return 2.0 + share * minf(cyc, 120.0) * (0.9 if n > 1 else 0.0)


func _crop_for(ring: int, k: int, is_keyhole: bool) -> String:
	var c: Variant = spec.get("crops", "garden")
	if c is Array and not (c as Array).is_empty():
		return str((c as Array)[k % (c as Array).size()])
	var cs := str(c)
	if cs != "garden" and GardenCrops.CROPS.has(cs):
		return cs
	if not is_keyhole:
		var beds: Array = GardenCrops.GARDEN_BEDS
		return str(beds[(ring * 5 + k) % beds.size()])
	var rings: Array = GardenCrops.GARDEN_RINGS
	var row: Array = rings[mini(ring, rings.size() - 1)]
	return str(row[k % row.size()])


# --- keyhole: ring beds inside a dome -------------------------------------

static func _keyhole(s: Dictionary) -> Dictionary:
	var k: Dictionary = KEYHOLE_DEFAULTS.duplicate()
	var o: Variant = s.get("keyhole", {})
	if o is Dictionary:
		for key in (o as Dictionary).keys():
			k[key] = (o as Dictionary)[key]
	return k


## Each ring bed: {r0, r1, a0, a1} (radians; the slot is centred on +Z).
static func _keyhole_rings(k: Dictionary) -> Array:
	var out: Array = []
	var r1 := float(k["outer_r"])
	var rw := float(k["ring_w"])
	var pw := float(k["path_w"])
	var slot := float(k["slot_w"])
	for i in int(k["rings"]):
		var r0 := r1 - rw
		if r0 < float(k["centre_r"]) - 0.01:
			break
		# The slot (the path in from the door) cuts every ring: half its width
		# as an angle at the ring's inner edge.
		var half := asin(clampf(slot * 0.5 / maxf(r0, 0.1), 0.0, 0.99))
		out.append({"r0": r0, "r1": r1, "a0": half, "a1": TAU - half, "ring": i})
		r1 = r0 - pw
	return out


func _layout_keyhole(shell: GrowBedShell, places: Dictionary, rng: RandomNumberGenerator) -> void:
	var k := _keyhole(spec)
	var wall_h := float(k["wall_h"])
	var floor_r := float(k["outer_r"]) + 0.35
	shell.disc(floor_r, Color(0.52, 0.42, 0.3), 0.025)
	var sec := 0
	for r in _keyhole_rings(k):
		var rr: Dictionary = r
		var r0 := float(rr["r0"])
		var r1 := float(rr["r1"])
		var a0 := float(rr["a0"])
		var a1 := float(rr["a1"])
		var mid_r := 0.5 * (r0 + r1)
		var n := maxi(int(roundf((a1 - a0) * mid_r / SECTION_M)), 2)
		for s in n:
			var sa0 := lerpf(a0, a1, float(s) / float(n))
			var sa1 := lerpf(a0, a1, float(s + 1) / float(n))
			var crop := _crop_for(int(rr["ring"]), s, true)
			shell.ring_bed(r0, r1, sa0, sa1, wall_h, s == 0, s == n - 1)
			shell.canopy_band(r0, r1, sa0, sa1, wall_h + float(GardenCrops.info(crop)["height"]) * 0.45,
				_leaf_tint(crop))
			var pts := _sector_points(r0, r1, sa0, sa1, GardenCrops.spacing(crop), rng)
			_sow(places, crop, pts, wall_h - 0.02, _first_sow(crop, sec, 99), rng)
			sec += 1
	shell.compost_basket(float(k["centre_r"]) * 0.5, 0.85)


func _sector_points(r0: float, r1: float, a0: float, a1: float, sp: float,
		rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	var margin := sp * 0.45
	var dr := sp * 0.866
	var row := 0
	var r := r0 + margin
	while r <= r1 - margin + 0.001:
		var da := sp / maxf(r, 0.2)
		var start := a0 + margin / maxf(r, 0.2) + (da * 0.5 if row % 2 == 1 else 0.0)
		var a := start
		while a <= a1 - margin / maxf(r, 0.2) + 0.0001:
			var jr := r + rng.randf_range(-0.04, 0.04) * sp
			# Angle 0 is +Z (the slot): x = sin, z = cos.
			out.append(Vector2(sin(a) * jr, cos(a) * jr))
			a += da
		r += dr
		row += 1
	if out.is_empty():
		var am := 0.5 * (a0 + a1)
		var rm := 0.5 * (r0 + r1)
		out.append(Vector2(sin(am) * rm, cos(am) * rm))
	return out


# --- raised beds -----------------------------------------------------------

static func _bed_rects(area: float) -> Array:
	if area <= SMALL_BED.x * SMALL_BED.y + 0.01:
		return [Rect2(-SMALL_BED.x * 0.5, -SMALL_BED.y * 0.5, SMALL_BED.x, SMALL_BED.y)]
	var ln := minf(area / BED_W, BED_MAX_LEN)
	var n := maxi(int(ceilf(area / (BED_W * ln) - 0.01)), 1)
	ln = area / (BED_W * float(n))
	var out: Array = []
	var total_w := float(n) * BED_W + float(n - 1) * BED_PATH
	for i in n:
		var x0 := -total_w * 0.5 + float(i) * (BED_W + BED_PATH)
		out.append(Rect2(x0, -ln * 0.5, BED_W, ln))
	return out


func _layout_beds(shell: GrowBedShell, places: Dictionary, rng: RandomNumberGenerator) -> void:
	var sec := 0
	var rects := _bed_rects(layout_area_m2(spec))
	for bi in rects.size():
		var rc: Rect2 = rects[bi]
		shell.box_bed(rc, WALL_H)
		var n := maxi(int(roundf(rc.size.y / SECTION_M)), 1)
		for s in n:
			var z0 := rc.position.y + rc.size.y * float(s) / float(n)
			var z1 := rc.position.y + rc.size.y * float(s + 1) / float(n)
			var crop := _crop_for(bi, s, false)
			var sp := GardenCrops.spacing(crop)
			var pts := _rect_points(Rect2(rc.position.x, z0, rc.size.x, z1 - z0), sp, rng)
			shell.canopy_rect(Rect2(rc.position.x, z0, rc.size.x, z1 - z0),
				WALL_H + float(GardenCrops.info(crop)["height"]) * 0.45, _leaf_tint(crop))
			_sow(places, crop, pts, WALL_H - 0.02, _first_sow(crop, sec, rects.size() * n), rng)
			sec += 1


func _rect_points(rc: Rect2, sp: float, rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	var margin := minf(sp * 0.45, rc.size.x * 0.45)
	var row := 0
	var z := rc.position.y + margin
	while z <= rc.end.y - margin + 0.001:
		var x := rc.position.x + margin + (sp * 0.5 if row % 2 == 1 else 0.0)
		while x <= rc.end.x - margin + 0.001:
			out.append(Vector2(x + rng.randf_range(-0.03, 0.03) * sp, z))
			x += sp
		z += sp * 0.866
		row += 1
	if out.is_empty():
		out.append(rc.get_center())
	return out


# --- in-ground plot --------------------------------------------------------

func _layout_plot(shell: GrowBedShell, places: Dictionary, rng: RandomNumberGenerator) -> void:
	var side := sqrt(layout_area_m2(spec))
	var rc := Rect2(-side * 0.5, -side * 0.5, side, side)
	shell.plot(rc, PLOT_BERM)
	var crop := _crop_for(0, 0, false)
	var pts: Array = []
	if crop == "willow":
		# Twin rows 0.75 m apart, 1.5 m between pairs, 0.6 m in the row.
		var x := rc.position.x + 0.5
		var pair := 0
		while x <= rc.end.x - 0.4:
			var z := rc.position.y + 0.4 + (0.3 if pair % 2 == 1 else 0.0)
			while z <= rc.end.y - 0.3:
				pts.append(Vector2(x + rng.randf_range(-0.05, 0.05), z))
				z += 0.6
			x += 0.75 if pair % 2 == 0 else 1.5
			pair += 1
	else:
		pts = _rect_points(rc.grow(-0.2), GardenCrops.spacing(crop), rng)
	shell.canopy_rect(rc.grow(-0.2), float(GardenCrops.info(crop)["height"]) * 0.45, _leaf_tint(crop))
	# One plot is one planting, cut and regrown together, but not on the same
	# day as the next plot.
	var sow := 1.0 + fposmod(float(spec.get("seed", 1)) * 0.618034, 1.0) \
			* minf(float(GardenCrops.info(crop)["cycle"]), 120.0) * 0.5
	_sow(places, crop, pts, 0.02, sow, rng)


static func _leaf_tint(crop: String) -> Color:
	match crop:
		"lettuce_red":
			return Color(0.42, 0.3, 0.2)
		"kale":
			return Color(0.24, 0.38, 0.3)
		"willow":
			return Color(0.38, 0.5, 0.3)
		_:
			return Color(0.26, 0.46, 0.18)


# ---------------------------------------------------------------------------
# The clock
# ---------------------------------------------------------------------------

func _now_h() -> float:
	if _main == null:
		_main = _find_main()
	if _main != null and _main.has_method("get_absolute_hours"):
		return float(_main.call("get_absolute_hours"))
	return plant_abs_h


func _update_clock() -> void:
	if _mat == null:
		return
	var p := plant_abs_h if plant_abs_h >= 0.0 else _now_h()
	_mat.set_shader_parameter("now_d", (_now_h() - p) / 24.0)


## Days since the bed was planted.
func days_planted() -> float:
	var p := plant_abs_h if plant_abs_h >= 0.0 else _now_h()
	return (_now_h() - p) / 24.0


## Kept for older callers: the lettuce-bed lifecycle scale.
func current_scale() -> float:
	var age_h := maxf(_now_h() - plant_abs_h, 0.0)
	return VegetationGrowth.scale_for_lifecycle(age_h, grow_days * VegetationGrowth.HOURS_PER_DAY,
		senescence_days * VegetationGrowth.HOURS_PER_DAY)


func current_stage() -> String:
	var age_h := maxf(_now_h() - plant_abs_h, 0.0)
	return VegetationGrowth.growth_stage(age_h, grow_days * VegetationGrowth.HOURS_PER_DAY,
		senescence_days * VegetationGrowth.HOURS_PER_DAY)


func _find_main() -> Node:
	if not is_inside_tree():
		return null
	var n: Node = self
	while n != null:
		if "day_time" in n and n.has_method("get_absolute_hours"):
			return n
		n = n.get_parent()
	return get_tree().current_scene
