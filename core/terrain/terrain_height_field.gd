class_name TerrainHeightField
extends Node3D

## Renders the high-resolution terrain edit layer (TerrainEditTiles) as per-tile
## meshes + HeightMapShape3D colliders at ~1.5 m/vertex — far finer than the
## DetailGround DEM mesh (~12–47 m/vertex), which cannot visibly show a brush
## stroke or pond. Only dirty tiles rebuild, throttled per frame, so a live brush
## drag updates the world in real time without the old full-remesh crash path.
##
## Height convention: `base_fn(x, z)` returns the composed base surface in WORLD
## Y (the loader's footing math already subtracts center_elev), so tile verts and
## collider map_data are world-space directly — no second centring offset. The
## loader sinks the DetailGround mesh/collider beneath active tiles so cut bowls
## are not occluded from above or bridged by the coarser collider.

## Max tile (mesh + collider) rebuilds per frame. A tile is ~65² verts; a brush
## stroke touches 1–4 tiles, so live strokes reconcile the same frame.
const MAX_REBUILDS_PER_FRAME := 4
## Stop rebuilding queued tiles once this much of the frame has gone (at least
## one tile a frame): a channel re-carve touches ~90 tiles.
const REBUILD_BUDGET_MS := 6.0
## Perimeter skirt drop (m). Must exceed the loader's TILE_SINK_HEADROOM_M
## (60 m): the DetailGround is sunk that far beneath active tiles, and where a
## cut reaches the tile perimeter the skirt is the only thing sealing the sink
## chasm from view. Outside cuts the deep skirt is buried underground (invisible).
const SKIRT_DROP_M := 65.0

var tiles: TerrainEditTiles = null

var _base_fn: Callable = Callable()
## Per tile key, its base heights (build_tile_mesh_data's "base").
var _base_cache: Dictionary = {}
var _uv_scale: float = 0.0
var _uv_origin: float = 0.5
var _material: Material = null
var _cast_shadow: GeometryInstance3D.ShadowCastingSetting = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
var _collision_layer: int = 1
var _collision_mask: int = 0

## Optional hook run before this field consumes the store's dirty set. The
## loader binds it to its layer composition (channel + player → composed), so
## every existing queue/reconcile call site picks up edits to EITHER layer
## without knowing the stack exists.
var pre_consume: Callable = Callable()

var _rebuild_queue: Array = []       ## tile keys awaiting mesh/collider reconcile
var _queued: Dictionary = {}         ## dedup set for _rebuild_queue


func _ready() -> void:
	set_process(false)


## (Re)configure against the current terrain. `base_fn(x, z)` returns the composed
## base WORLD-Y height WITHOUT this edit layer (no double counting). `material`
## should be the DetailGround drape material so tiles shade identically.
func configure(store: TerrainEditTiles, base_fn: Callable,
		detail_extent_m: float, material: Material) -> void:
	tiles = store
	_base_fn = base_fn
	_base_cache = {}
	_material = material
	var e := maxf(detail_extent_m, 1.0)
	_uv_scale = 1.0 / e
	_uv_origin = 0.5


## Re-point every tile mesh at a new drape material (hyper/detail imagery lands
## after load and replaces DetailGround's material — tiles must follow).
func set_material(material: Material) -> void:
	_material = material
	for child in get_children():
		var mi := child.get_node_or_null("Mesh") as MeshInstance3D
		if mi != null:
			mi.material_override = material


## Match the shadow casting of the ground the tiles sit in (the loader passes
## the DetailGround's own setting).
func set_cast_shadow(setting: GeometryInstance3D.ShadowCastingSetting) -> void:
	_cast_shadow = setting
	for child in get_children():
		var mi := child.get_node_or_null("Mesh") as MeshInstance3D
		if mi != null:
			mi.cast_shadow = setting


func has_edits() -> bool:
	return tiles != null and not tiles.is_empty()


# ---------------------------------------------------------------------------
# Dirty reconcile
# ---------------------------------------------------------------------------

## Pull freshly-dirtied tiles into the throttled rebuild queue (call after a tool
## op). Live strokes call this every frame; only touched tiles are enqueued.
func queue_dirty() -> void:
	if tiles == null:
		return
	_run_pre_consume()
	for key in tiles.consume_dirty():
		if not _queued.has(key):
			_queued[key] = true
			_rebuild_queue.append(key)
	if not _rebuild_queue.is_empty():
		set_process(true)


func _process(_delta: float) -> void:
	var budget := MAX_REBUILDS_PER_FRAME
	PerfSpan.begin("terrain_tiles")
	var t0 := Time.get_ticks_usec()
	while budget > 0 and not _rebuild_queue.is_empty():
		var key: Vector2i = _rebuild_queue.pop_front()
		_queued.erase(key)
		_reconcile_tile(key)
		budget -= 1
		if float(Time.get_ticks_usec() - t0) / 1000.0 >= REBUILD_BUDGET_MS:
			break
	PerfSpan.end("terrain_tiles")
	if _rebuild_queue.is_empty():
		set_process(false)


## Drain the whole rebuild queue immediately (no frame budget). Called on edit
## COMMIT before the loader sinks the DetailGround collider beneath the tiles —
## the tile colliders must exist the same frame, or a player standing in the
## edited area would briefly have nothing to stand on and fall into the sink.
func reconcile_dirty_now() -> void:
	if tiles == null:
		return
	queue_dirty()
	while not _rebuild_queue.is_empty():
		var key: Vector2i = _rebuild_queue.pop_front()
		_queued.erase(key)
		_reconcile_tile(key)
	set_process(false)


## Rebuild every active tile immediately (load / undo / full recompose) and drop
## nodes for tiles that no longer exist. Bypasses the frame budget.
func rebuild_all_now() -> void:
	if tiles == null:
		return
	_run_pre_consume()
	tiles.consume_dirty()
	_rebuild_queue.clear()
	_queued.clear()
	set_process(false)
	var active := {}
	for key in tiles.active_tiles():
		active[_node_name(key)] = true
	for child in get_children():
		if not active.has(child.name):
			child.queue_free()
	for key in tiles.active_tiles():
		_reconcile_tile(key)


func _run_pre_consume() -> void:
	if pre_consume.is_valid():
		pre_consume.call()


func clear_all() -> void:
	_rebuild_queue.clear()
	_queued.clear()
	set_process(false)
	for child in get_children():
		child.queue_free()


func _node_name(key: Vector2i) -> String:
	return "T_%d_%d" % [key.x, key.y]


## Build/update/remove the one StaticBody3D (mesh + collider) for a tile.
func _reconcile_tile(key: Vector2i) -> void:
	if tiles == null or not _base_fn.is_valid():
		return
	var name := _node_name(key)
	var existing := get_node_or_null(name) as StaticBody3D
	# Flat / dropped tile → remove its node.
	if not tiles.tile_has_edits(key):
		if existing != null:
			existing.queue_free()
		return

	# center_elev = 0: base_fn already returns world-Y heights. One height pass
	# feeds both the mesh and the collider.
	var md := tiles.build_tile_mesh_data(key, _base_fn, 0.0, _uv_scale, _uv_origin,
		_base_cache.get(key, PackedFloat32Array()))
	_base_cache[key] = md["base"]
	var arrays: Array = md["arrays"]
	_append_skirt(arrays)
	var mesh := TerrainBuilder.make_array_mesh(arrays)
	var hm_data: PackedFloat32Array = md["heightmap"]
	var rect := tiles.tile_world_rect(key)
	var cx := rect.position.x + rect.size.x * 0.5
	var cz := rect.position.y + rect.size.y * 0.5
	var e := tiles.tile_cells + 1

	var body := existing
	var mi: MeshInstance3D = null
	var cs: CollisionShape3D = null
	if body == null:
		body = StaticBody3D.new()
		body.name = name
		body.collision_layer = _collision_layer
		body.collision_mask = _collision_mask
		mi = MeshInstance3D.new()
		mi.name = "Mesh"
		mi.extra_cull_margin = rect.size.x
		body.add_child(mi)
		cs = CollisionShape3D.new()
		cs.name = "Col"
		body.add_child(cs)
		add_child(body)
	else:
		mi = body.get_node_or_null("Mesh") as MeshInstance3D
		cs = body.get_node_or_null("Col") as CollisionShape3D

	if mi != null:
		mi.mesh = mesh
		mi.material_override = _material
		mi.cast_shadow = _cast_shadow
	if cs != null:
		# Reuse the HeightMapShape3D and rewrite map_data in place when possible.
		var shape := cs.shape as HeightMapShape3D
		if shape == null or shape.map_width != e or shape.map_depth != e:
			shape = HeightMapShape3D.new()
			shape.map_width = e
			shape.map_depth = e
			cs.shape = shape
		shape.map_data = hm_data
		cs.position = Vector3(cx, 0.0, cz)
		cs.scale = Vector3(tiles.cell_m, 1.0, tiles.cell_m)


## Append a downward perimeter skirt to a tile's e×e grid surface arrays so tiny
## interpolation differences against the coarser DetailGround never open a gap.
## The drape shader is cull_disabled, so winding does not matter.
func _append_skirt(arrays: Array) -> void:
	if tiles == null:
		return
	var e := tiles.tile_cells + 1
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if verts.size() != e * e:
		return
	# Perimeter ring indices, clockwise: top row, right col, bottom row, left col.
	var ring := PackedInt32Array()
	for c in e:
		ring.append(c)
	for r in range(1, e):
		ring.append(r * e + (e - 1))
	for c in range(e - 2, -1, -1):
		ring.append((e - 1) * e + c)
	for r in range(e - 2, 0, -1):
		ring.append(r * e)
	var base := verts.size()
	for idx in ring:
		var p := verts[idx]
		verts.append(Vector3(p.x, p.y - SKIRT_DROP_M, p.z))
		normals.append(normals[idx])
		uvs.append(uvs[idx])
	var n := ring.size()
	for i in n:
		var a := ring[i]
		var b := ring[(i + 1) % n]
		var a2 := base + i
		var b2 := base + ((i + 1) % n)
		indices.append(a)
		indices.append(b)
		indices.append(a2)
		indices.append(b)
		indices.append(b2)
		indices.append(a2)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
