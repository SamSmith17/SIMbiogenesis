extends SceneTree

## Offline: NpcNavGrid.begin_bake / begin_bake_reusing against a frozen copy
## of their old per-cell loops, every array byte for byte (steep terrain, one
## and three layers, a reuse of a reuse). Run it after ANY change to them:
##   Godot --headless --path . --script tools/diag/nav_reuse_parity.gd

func _old_reuse(g: NpcNavGrid, prev: NpcNavGrid, hf: Callable, sf: Callable) -> void:
	g.begin_bake(hf, [], "b", sf)
	# begin_bake's upper-layer fill, as it was
	var n := g.nx * g.nz * g.layers
	var f := PackedByteArray()
	f.resize(n)
	for l in range(1, g.layers):
		for i in range(l * g.nx * g.nz, (l + 1) * g.nx * g.nz):
			f[i] = NpcNavGrid.F_BLOCKED
	var h := PackedFloat32Array()
	h.resize(n)
	var sl := PackedFloat32Array()
	sl.resize(g.nx * g.nz)
	for i in g.nx * g.nz:
		h[i] = prev._height[i]
		var deg: float = prev._slope[i]
		sl[i] = deg
		if deg > NpcNavGrid.MAX_SLOPE_DEG:
			f[i] = f[i] | NpcNavGrid.F_STEEP | NpcNavGrid.F_BLOCKED
	g._height = h
	g._slope = sl
	g._flags = f


func _initialize() -> void:
	var fails := 0
	for case_i in 3:
		var hf := func(x: float, z: float) -> float:
			return sin(x * 0.21 + case_i) * 9.0 + cos(z * 0.17) * 6.0 + (x * 0.4 if case_i == 2 else 0.0)
		var sf := func(_x: float, _z: float) -> PackedFloat32Array: return PackedFloat32Array()
		var prev := NpcNavGrid.new()
		prev.configure_region(Vector2(3.0, -7.0), 60.0 + 40.0 * case_i)
		prev.set_priority_center(Vector2(10.0, 5.0))
		prev.begin_bake(hf, [], "a", sf if case_i != 1 else Callable())
		while not prev.bake_step(5000):
			pass
		var steep := 0
		for i in prev.nx * prev.nz:
			if prev._slope[i] > NpcNavGrid.MAX_SLOPE_DEG:
				steep += 1
		var a := NpcNavGrid.new()
		a.configure_region(Vector2(3.0, -7.0), 60.0 + 40.0 * case_i)
		a.begin_bake_reusing(prev, hf, [], "b", sf if case_i != 1 else Callable())
		var b := NpcNavGrid.new()
		b.configure_region(Vector2(3.0, -7.0), 60.0 + 40.0 * case_i)
		_old_reuse(b, prev, hf, sf if case_i != 1 else Callable())
		var same := a._height == b._height and a._slope == b._slope and a._flags == b._flags
		# a fresh bake's upper-layer flags as the old loop made them
		var c := NpcNavGrid.new()
		c.configure_region(Vector2(3.0, -7.0), 60.0 + 40.0 * case_i)
		c.begin_bake(hf, [], "c", sf if case_i != 1 else Callable())
		var f_old := PackedByteArray()
		f_old.resize(c.nx * c.nz * c.layers)
		for l in range(1, c.layers):
			for i in range(l * c.nx * c.nz, (l + 1) * c.nx * c.nz):
				f_old[i] = NpcNavGrid.F_BLOCKED
		var same_begin := c._flags == f_old
		# a reuse of a reuse: finish a first, then the new and old ways
		while not a.bake_step(5000):
			pass
		var e := NpcNavGrid.new()
		e.configure_region(Vector2(3.0, -7.0), 60.0 + 40.0 * case_i)
		_old_reuse(e, a, hf, sf if case_i != 1 else Callable())
		var d := NpcNavGrid.new()
		d.configure_region(Vector2(3.0, -7.0), 60.0 + 40.0 * case_i)
		d.begin_bake_reusing(a, hf, [], "d", sf if case_i != 1 else Callable())
		var same_chain := d._flags == e._flags and d._slope == e._slope and d._height == e._height and d.reused_ground
		print("navparity case %d: %d x %d x %d layers, %d steep: reuse %s, begin %s, chain %s" % [
			case_i, a.nx, a.nz, a.layers, steep, same, same_begin, same_chain])
		if not (same and same_begin and same_chain) or steep == 0:
			fails += 1
	print("navparity %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit()
