class_name GlobeQuadtree
extends RefCounted

## Which Web Mercator tiles the globe draws for a camera (pure, deterministic).
##
## Starts from every visible tile at MIN_ZOOM and keeps splitting the tile
## whose screen size most exceeds a 256 px tile until no tile does, the zoom
## cap is reached or the tile budget is spent. A tile is visible if it is
## above the horizon (a spherical cap test) and its bounding sphere meets the
## view cone. The result never contains a tile and one of its ancestors.
##
## Poles above MERCATOR_MAX_LAT are not tiles; the globe draws caps there.

const MIN_ZOOM := 2
const TILE_PX := 256.0
const SPLIT_RATIO := 1.15
const DEFAULT_MAX_TILES := 220


## cam_basis: the camera's global basis (looks along -Z). Returns the
## selected keys (z, x, y) sorted by zoom, then x, then y.
static func select(cam_pos: Vector3, cam_basis: Basis, fov_y_deg: float, aspect: float,
		viewport_h: float, max_zoom: int, max_tiles: int = DEFAULT_MAX_TILES,
		split_ratio: float = SPLIT_RATIO) -> Array[Vector3i]:
	var ctx := _ctx(cam_pos, cam_basis, fov_y_deg, aspect, viewport_h)
	var active: Array = []   # [key, ratio]
	var n0 := 1 << MIN_ZOOM
	for x in n0:
		for y in n0:
			var k := Vector3i(MIN_ZOOM, x, y)
			var info := tile_info(k, ctx)
			if info.visible:
				active.append([k, info.ratio])
	var guard := 0
	while guard < 8000:
		guard += 1
		var best := -1
		var best_r := split_ratio
		for i in active.size():
			var k: Vector3i = active[i][0]
			if k.x >= max_zoom:
				continue
			if float(active[i][1]) > best_r:
				best_r = float(active[i][1])
				best = i
		if best < 0:
			break
		var parent: Vector3i = active[best][0]
		var kids: Array = []
		for dy in 2:
			for dx in 2:
				var c := Vector3i(parent.x + 1, parent.y * 2 + dx, parent.z * 2 + dy)
				var ci := tile_info(c, ctx)
				if ci.visible:
					kids.append([c, ci.ratio])
		if active.size() - 1 + kids.size() > max_tiles:
			# Over budget: stop refining this tile, try the others.
			active[best][1] = 0.0
			continue
		active.remove_at(best)
		active.append_array(kids)
	var out: Array[Vector3i] = []
	for a in active:
		out.append(a[0])
	out.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x:
			return a.x < b.x
		if a.y != b.y:
			return a.y < b.y
		return a.z < b.z)
	return out


static func _ctx(cam_pos: Vector3, cam_basis: Basis, fov_y_deg: float, aspect: float,
		viewport_h: float) -> Dictionary:
	var half := deg_to_rad(fov_y_deg) * 0.5
	var t := tan(half)
	var d := maxf(cam_pos.length(), 1.0 + 1e-7)
	return {
		"pos": cam_pos,
		"fwd": -cam_basis.z.normalized(),
		"cone": atan(t * sqrt(1.0 + aspect * aspect)),
		"px_per_rad": viewport_h / (2.0 * t),
		"horizon": acos(clampf(1.0 / d, -1.0, 1.0)),
		"dir": cam_pos / d,
	}


## {visible, ratio, center, ang_r, edge} of one tile for a camera context.
static func tile_info(k: Vector3i, ctx: Dictionary) -> Dictionary:
	var c := GlobeMath.tile_point(k.x, k.y, k.z, 0.5, 0.5)
	var corners := [
		GlobeMath.tile_point(k.x, k.y, k.z, 0.0, 0.0),
		GlobeMath.tile_point(k.x, k.y, k.z, 1.0, 0.0),
		GlobeMath.tile_point(k.x, k.y, k.z, 0.0, 1.0),
		GlobeMath.tile_point(k.x, k.y, k.z, 1.0, 1.0),
	]
	var ang_r := 0.0
	for p: Vector3 in corners:
		# From the chord: acos of a float32 dot rounds a z14+ tile to 0 rad
		# (cos within 6e-8 of 1), which culled visible tiles at the screen edge.
		ang_r = maxf(ang_r, 2.0 * asin(minf(1.0, c.distance_to(p) * 0.5)))
	# Longest edge chord (the top / bottom rows differ in width).
	var edge := maxf(maxf(corners[0].distance_to(corners[1]), corners[2].distance_to(corners[3])),
		corners[0].distance_to(corners[2]))
	var res := {"visible": false, "ratio": 0.0, "center": c, "ang_r": ang_r, "edge": edge}
	# Horizon: the cap of the tile reaches the visible cap of the sphere.
	var alpha := 2.0 * asin(minf(1.0, c.distance_to(ctx.dir) * 0.5))
	if alpha - ang_r > float(ctx.horizon) + 1e-4:
		return res
	# View cone vs the tile's bounding sphere (chord radius + the bulge).
	var rs := 2.0 * sin(ang_r * 0.5) + (1.0 - cos(ang_r))
	var v: Vector3 = c - ctx.pos
	var vl := v.length()
	if vl > rs:
		var ang := acos(clampf(v.dot(ctx.fwd) / vl, -1.0, 1.0))
		if ang - float(ctx.cone) > asin(clampf(rs / vl, 0.0, 1.0)):
			return res
	res.visible = true
	var dist := maxf(vl - rs, 1e-7)
	res.ratio = edge / dist * float(ctx.px_per_rad) / TILE_PX
	return res
