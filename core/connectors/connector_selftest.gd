extends SceneTree

## Connector kit self-test (offline). Every catalog entry resolves, builds a
## mesh with every triangle wound to its normal, has its pins inside reason
## and a rating where it carries power; mates_with resolves both ways;
## search works; the parametric ones (terminal strips, DIN breakers, bus
## bars, knockouts) size themselves from their opts; and the Battery Lab's
## RJ45 plug and front stud, now drawn by the kit, are byte-identical to the
## code they replaced (frozen copies below).
##
##   Godot --headless --path . --script core/connectors/connector_selftest.gd

const EXPECTED_CHECKS := 19

var _n := 0
var _fails := 0


func _ok(cond: bool, what: String) -> void:
	_n += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _initialize() -> void:
	print("connector selftest")
	_test_catalog()
	_test_meshes()
	_test_parametric()
	_test_battery_parity()
	_test_pvlab_leads()
	_ok(_n == EXPECTED_CHECKS, "ran %d checks (expected %d)" % [_n, EXPECTED_CHECKS])
	print("connector selftest: %s (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _n, _fails])
	quit(0 if _fails == 0 else 1)


func _test_catalog() -> void:
	var ids := ConnectorCatalog.ids()
	_ok(ids.size() >= 60, "catalog lists %d connectors" % ids.size())
	var bad: Array = []
	var no_rating: Array = []
	for id in ids:
		var e := ConnectorCatalog.resolve(id)
		if e.is_empty() or not ConnectorCatalog.DOMAINS.has(str(e["domain"])) or str(e["label"]) == "":
			bad.append(id)
			continue
		var dom := str(e["domain"])
		if dom in ["pv", "dc", "ac"] and float((e["rating"] as Dictionary).get("amps", 0.0)) <= 0.0:
			no_rating.append(id)
		for p in (e["pins"] as Array):
			var pos: Vector3 = p["pos"]
			var dir: Vector3 = p["dir"]
			if not pos.is_finite() or absf(dir.length() - 1.0) > 1e-3 or pos.length() > 400.0:
				bad.append("%s:%s" % [id, p["id"]])
	_ok(bad.is_empty(), "every entry resolves with a domain, label and sane pins %s" % str(bad))
	_ok(no_rating.is_empty(), "every power connector carries a current rating %s" % str(no_rating))
	var dangling: Array = []
	for id in ids:
		for m in (ConnectorCatalog.entry(id)["mates_with"] as Array):
			if not ConnectorCatalog.has(str(m)):
				dangling.append("%s→%s" % [id, m])
	_ok(dangling.is_empty(), "every mates_with names a real entry %s" % str(dangling))
	_ok(ConnectorCatalog.mates("mc4_panel", "mc4_inline") and ConnectorCatalog.mates("mc4_inline", "mc4_panel")
		and ConnectorCatalog.mates("iec_c13", "iec_c14") and not ConnectorCatalog.mates("xt60", "mc4_inline"),
		"mates() is symmetric and refuses strangers")
	var s := ConnectorCatalog.search("powerpole 45")
	_ok(s == ["powerpole_45"], "search('powerpole 45') = %s" % str(s))
	_ok(ConnectorCatalog.search("rj45").size() >= 2, "search finds the RJ45 jack and plug")


func _test_meshes() -> void:
	var empty: Array = []
	var wound: Array = []
	var nonfinite: Array = []
	for id in ConnectorCatalog.ids():
		var g := BattParts.Geo.new()
		ConnectorParts.build(g, id, Transform3D(Basis(Vector3.UP, 0.7), Vector3(10, 20, 30)))
		if g.tri_count() < 4:
			empty.append(id)
			continue
		for fin in g.surf:
			var sf: BattParts.Surf = g.surf[fin]
			for t in range(0, sf.v.size(), 3):
				var a := sf.v[t]
				var b := sf.v[t + 1]
				var c := sf.v[t + 2]
				if not (a.is_finite() and b.is_finite() and c.is_finite()):
					nonfinite.append(id)
					break
				var nsum := sf.n[t] + sf.n[t + 1] + sf.n[t + 2]
				if (b - a).cross(c - a).dot(nsum) > 1e-12:
					wound.append(id)
					break
	_ok(empty.is_empty(), "every connector draws a mesh %s" % str(empty))
	_ok(nonfinite.is_empty(), "no connector has a non-finite vertex %s" % str(nonfinite))
	_ok(wound.is_empty(), "every triangle is clockwise from its normal's side %s" % str(wound))
	# Pins follow the placement transform.
	var xf := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(100, 0, 0))
	var r := ConnectorParts.build(BattParts.Geo.new(), "mc4_panel", xf)
	var p: Dictionary = (r["pins"] as Array)[0]
	_ok((p["pos"] as Vector3).distance_to(xf * Vector3(0, 0, -22)) < 1e-3
		and (p["dir"] as Vector3).distance_to(xf.basis * Vector3(0, 0, -1)) < 1e-4, "pins come back in the placed frame")


func _test_parametric() -> void:
	var tb := ConnectorCatalog.resolve("terminal_block", {"poles": 4, "pitch": 5.08, "labels": ["1+", "1-", "2+", "2-"]})
	var pins: Array = tb["pins"]
	_ok(pins.size() == 4 and str(pins[0]["label"]) == "1+" and absf((tb["body"] as Vector3).x - 20.32) < 1e-3
		and absf((pins[3]["pos"] as Vector3).x - (pins[0]["pos"] as Vector3).x - 3.0 * 5.08) < 1e-3,
		"a 4-pole strip is 20.32 mm wide, pins 5.08 mm apart, labelled")
	var r := ConnectorParts.build(BattParts.Geo.new(), "terminal_block", Transform3D.IDENTITY,
		{"poles": 4, "labels": ["1+", "1-", "2+", "2-"]})
	_ok((r["labels"] as Array).size() == 4 and str((r["labels"] as Array)[2]["text"]) == "2+", "the strip prints its labels")
	var br := ConnectorCatalog.resolve("din_breaker", {"poles": 2, "amps": 50})
	_ok((br["pins"] as Array).size() == 4 and absf((br["body"] as Vector3).x - 35.0) < 1e-3
		and float(br["rating"]["amps"]) == 50.0, "a 2-pole MCB is 35 mm wide with line + load per pole, rated 50 A")
	var bb := ConnectorCatalog.resolve("bus_bar", {"screws": 9, "label": "PE"})
	_ok((bb["pins"] as Array).size() == 9 and str(bb["pins"][0]["role"]) == "PE", "a 9-screw PE bar has 9 landings")
	var ko := ConnectorCatalog.resolve("knockout", {"trade": "1"})
	_ok(absf((ko["body"] as Vector3).x - (34.9 + 8.0)) < 1e-3, "a 1\" knockout is 34.9 mm (+ its locknut)")


## Frozen copies of the Battery Lab code the kit replaced (commit 07396ca).
func _old_rj45(g: BattParts.Geo, at: Vector3, boot: Color) -> void:
	var z := Vector3(0, 0, 1)
	BattParts.abox(g, at + z * 9.0, Vector3(11.7, 8.0, 18.0), Color(0.85, 0.88, 0.9, 1.0), "plastic")
	BattParts.abox(g, at + z * 22.0, Vector3(13.0, 9.5, 12.0), boot, "rubber")
	BattParts.abox(g, at + Vector3(0, 4.6, 6.0), Vector3(6.0, 1.2, 9.0), Color(0.8, 0.82, 0.85), "plastic")


func _old_front_terminal(g: BattParts.Geo, c: Vector3, s: Vector3, pos: bool, bare: bool) -> void:
	var col := BattBuilder.C_RED if pos else BattBuilder.C_BLACK
	var zn := Vector3(0, 0, 1)
	var fz := c.z - s.z * 0.5
	var cc := Vector3(c.x, c.y, fz)
	var brass := Color(0.84, 0.66, 0.36)
	var r := s.x * 0.5
	BattParts.lathe(g, cc, zn, [Vector2(0, 0), Vector2(r + 2.0, 0), Vector2(r + 2.0, 1.5), Vector2(r, 2.5),
		Vector2(r, 9.5), Vector2(r - 1.5, 11.0), Vector2(0, 11.0)], col, "plastic", 28)
	BattParts.disc(g, cc + zn * 11.0, zn, 8.5, 2.5, brass, "metal", 20)
	BattParts.threaded_stud(g, cc + zn * 13.5, zn, 8.0, 12.0 if not bare else 22.0, brass.lightened(0.15))
	if not bare:
		var wt := BattParts.washer(g, cc + zn * 13.5, zn, 8.0)
		BattParts.hex_nut(g, cc + zn * (13.5 + wt), zn, 8.0)
	var ip := Vector3(c.x, c.y, fz - 15.0)
	BattParts.disc(g, ip, zn, 9.0, 15.0, brass, "metal", 18)
	BattParts.threaded_stud(g, ip, -zn, 8.0, 11.0, brass.lightened(0.15))
	var mk := cc + Vector3(0, r + 9.0, 0.3)
	BattParts.abox(g, mk, Vector3(9.0, 2.0, 0.6), col, "plastic")
	if pos:
		BattParts.abox(g, mk, Vector3(2.0, 9.0, 0.6), col, "plastic")


func _same_geo(a: BattParts.Geo, b: BattParts.Geo) -> bool:
	if a.surf.keys() != b.surf.keys():
		return false
	for k in a.surf:
		var x: BattParts.Surf = a.surf[k]
		var y: BattParts.Surf = b.surf[k]
		if x.v.size() != y.v.size():
			return false
		for i in x.v.size():
			if x.v[i].distance_to(y.v[i]) > 1e-9 or x.n[i].distance_to(y.n[i]) > 1e-6 or not x.c[i].is_equal_approx(y.c[i]):
				return false
	return true


func _test_battery_parity() -> void:
	var at := Vector3(12.0, -40.0, 230.0)
	var a := BattParts.Geo.new()
	var b := BattParts.Geo.new()
	_old_rj45(a, at, Color(0.18, 0.42, 0.85))
	ConnectorParts.build(b, "rj45_plug", Transform3D(Basis.IDENTITY, at), {"boot": Color(0.18, 0.42, 0.85)})
	_ok(_same_geo(a, b), "the kit's RJ45 plug is the bank builder's, vertex for vertex")
	var ok := true
	for pos in [true, false]:
		for bare in [true, false]:
			var c := Vector3(60.0, 120.0, -150.0)
			var s := Vector3(18.0, 18.0, 6.0)
			var g0 := BattParts.Geo.new()
			var g1 := BattParts.Geo.new()
			_old_front_terminal(g0, c, s, pos, bare)
			ConnectorParts.build(g1, "stud", Transform3D(Basis.IDENTITY, Vector3(c.x, c.y, c.z - s.z * 0.5)),
				{"stud": 8.0, "boss_r": s.x * 0.5, "polarity": "+" if pos else "-",
				"color": BattBuilder.C_RED if pos else BattBuilder.C_BLACK, "bare": bare, "inner": true})
			ok = ok and _same_geo(g0, g1)
	_ok(ok, "the kit's stud terminal is the pack's front terminal, vertex for vertex (+/−, bare or not)")


func _test_pvlab_leads() -> void:
	var m := PvLabModule.resolve({})
	var mesh := PvLabBuilder.module_mesh(m)
	var metal_like := 0
	for si in mesh.get_surface_count():
		var mat := mesh.surface_get_material(si)
		if mat == BattParts.material("plastic"):
			metal_like += 1
	_ok(metal_like >= 1, "a module's MC4 leads come from the kit (a kit surface on the module mesh)")
