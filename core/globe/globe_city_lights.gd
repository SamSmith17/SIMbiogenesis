class_name GlobeCityLights
extends Node3D

## City lights as POINTS, not a texture. Each NASA Black Marble tile the globe
## has in use is turned into a point cloud (every pixel above MIN_LUMA, the
## brightest MAX_POINTS of them) on a worker, and drawn as one MultiMesh of
## glow discs (globe_city_light.gdshader): each disc sits on the ground at the
## pixel's centre, is as wide as the pixel's footprint (the tile's zoom sets
## it: ~160 km at z2, ~600 m at z8), and never thinner than a pixel on screen.
## So from orbit the lights are the familiar glow, and as the camera comes
## down finer tiles bind and the glow resolves into towns, roads and single
## lights. The view calls begin_frame / use(key) / end_frame with the night
## tiles its patches are bound to this frame; tiles nobody uses are hidden
## and, after a while, freed.

const SHADER := preload("res://scenes/ui/globe/globe_city_light.gdshader")
const MIN_LUMA := 0.12
const MAX_POINTS := 2600
## Just over the ground, so the discs are not cut by it.
const HEIGHT := 1.00018
const KEEP_FRAMES := 900

var enabled := true

var _tiles := {}       # key_str -> {mmi: MultiMeshInstance3D, used: int, n: int}
var _pending := {}     # key_str -> task id
var _results := {}     # key_str -> Dictionary (filled by the worker)
var _used := {}
var _frame := 0
var _mat: ShaderMaterial
var _quad: QuadMesh
var _mutex := Mutex.new()


func _ready() -> void:
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_quad = QuadMesh.new()
	_quad.size = Vector2.ONE


func _exit_tree() -> void:
	for ks in _pending.keys():
		WorkerThreadPool.wait_for_task_completion(int(_pending[ks]))
	_pending.clear()


func set_sun(dir: Vector3) -> void:
	if _mat != null:
		_mat.set_shader_parameter("sun_dir", dir)


func set_enabled(on: bool) -> void:
	enabled = on
	visible = on


func begin_frame() -> void:
	_frame += 1
	_used.clear()


## A night tile some ground patch is bound to this frame. `image` is the
## tile's pixels (null while they are not in memory yet).
func use(k: Vector3i, image: Image) -> void:
	var ks := GlobeTileFetcher.key_str("night", k)
	_used[ks] = true
	if _tiles.has(ks):
		_tiles[ks].used = _frame
		return
	if _pending.has(ks) or image == null:
		return
	var img := image.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8 and img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGBA8)
	_pending[ks] = WorkerThreadPool.add_task(func() -> void:
		var res := extract(img, k)
		_mutex.lock()
		_results[ks] = res
		_mutex.unlock())


func end_frame() -> void:
	_mutex.lock()
	var done := _results.keys()
	_mutex.unlock()
	for ks in done:
		if _pending.has(ks):
			WorkerThreadPool.wait_for_task_completion(int(_pending[ks]))
			_pending.erase(ks)
		_mutex.lock()
		var res: Dictionary = _results[ks]
		_results.erase(ks)
		_mutex.unlock()
		_build(str(ks), res)
	for ks in _tiles.keys():
		var t: Dictionary = _tiles[ks]
		var mmi: MultiMeshInstance3D = t.mmi
		mmi.visible = _used.has(ks)
		if not _used.has(ks) and _frame - int(t.used) > KEEP_FRAMES:
			mmi.queue_free()
			_tiles.erase(ks)


## How many light points are drawn now (for checks).
func point_count() -> int:
	var n := 0
	for ks in _tiles:
		if (_tiles[ks].mmi as MultiMeshInstance3D).visible:
			n += int(_tiles[ks].n)
	return n


func tile_count() -> int:
	var n := 0
	for ks in _tiles:
		if (_tiles[ks].mmi as MultiMeshInstance3D).visible:
			n += 1
	return n


func pending_count() -> int:
	return _pending.size()


## The bright pixels of a Black Marble tile as points: unit directions x
## HEIGHT, luma, the pixel's ground footprint (world units). Pure; runs on a
## worker.
static func extract(img: Image, k: Vector3i) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	var cands: Array = []
	for py in h:
		var v := (float(py) + 0.5) / float(h)
		for px in w:
			var c := img.get_pixel(px, py)
			var l := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			# Moonlit snow and sea ice in the composite are blue-white; lights
			# are warm or white.
			if l < MIN_LUMA or c.b > c.r * 1.04 + 0.02:
				continue
			cands.append([l, (float(px) + 0.5) / float(w), v])
	if cands.size() > MAX_POINTS:
		cands.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) > float(b[0]))
		cands.resize(MAX_POINTS)
	var pos := PackedVector3Array()
	var lum := PackedFloat32Array()
	var foot := PackedFloat32Array()
	var ang := TAU / (float(w) * float(1 << k.x))
	for c in cands:
		var d := GlobeMath.tile_point(k.x, k.y, k.z, float(c[1]), float(c[2]))
		pos.append(d * HEIGHT)
		lum.append(float(c[0]))
		foot.append(ang * sqrt(maxf(1.0 - d.y * d.y, 1e-4)))
	return {"pos": pos, "lum": lum, "foot": foot}


func _build(ks: String, res: Dictionary) -> void:
	var pos: PackedVector3Array = res.get("pos", PackedVector3Array())
	var lum: PackedFloat32Array = res.get("lum", PackedFloat32Array())
	var foot: PackedFloat32Array = res.get("foot", PackedFloat32Array())
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _quad
	mm.instance_count = pos.size()
	for i in pos.size():
		var seed := int(absf(pos[i].x * 7919.0 + pos[i].z * 104729.0 + pos[i].y * 1301.0)) % 1000
		var l := clampf((lum[i] - MIN_LUMA) / (1.0 - MIN_LUMA), 0.0, 1.0)
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * foot[i]), pos[i]))
		mm.set_instance_custom_data(i, Color(0.25 + 0.75 * sqrt(l), float(seed) / 1000.0, 0.0, 1.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Lights_" + ks.replace("|", "_")
	mmi.multimesh = mm
	mmi.material_override = _mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The engine's own bounds come from the unit quads: cover the tile.
	var aabb := AABB()
	if pos.size() > 0:
		aabb = AABB(pos[0], Vector3.ZERO)
		for p in pos:
			aabb = aabb.expand(p)
		aabb = aabb.grow(0.02)
	mmi.custom_aabb = aabb
	mmi.visible = _used.has(ks)
	add_child(mmi)
	_tiles[ks] = {"mmi": mmi, "used": _frame, "n": pos.size()}
