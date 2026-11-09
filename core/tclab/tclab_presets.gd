class_name TcPresets
extends RefCounted

## Built-in TC designs and the player's library (`user://tclab_library.json`,
## every world). Built-ins are assembled through TcAssembly.add_part so their
## joints are the real mates; `_attach` picks each part's roll from the
## direction one of its ends should face, so a preset reads like a build
## sheet ("an elbow on the tee's left end, its other end down").
##
## The biochar reactor + its TC condenser replicate the user's
## "Biochar Reactor.glb" (measured 2026-11-06): a Ø340 boiler in a steam
## jacket (396 mm outside, as the model), 650 mm tall, the lid (a Ø342 dome
## on a Ø380 flange, clamped to the rim) with a crown port, the element, drain and back ports at the model's
## heights, six ½" NPT bungs where the model has them, a retort can inside,
## and on the back a three-column 2" condenser: a tee on the upper back port,
## short elbows down into two 18" dephlegmators, short tees and a centre tee
## across the bottom (the loop closes on standard + short centre-to-face
## lengths: the outer columns stand ±140 mm out, the model ±121), drains on
## the outer ends and a jacketed gas column up the middle to the woodgas
## outlet.

const LIBRARY_PATH := "user://tclab_library.json"

static var _builtins: Array = []


static func builtins() -> Array:
	if not _builtins.is_empty():
		return _builtins
	_builtins = [
		{"id": "biochar_reactor", "name": "Biochar reactor + condenser", "blurb": "The jacketed boiler with its retort can, element, butterfly drain, bungs and the three-column TC condenser on the back.", "spec": biochar_reactor()},
		{"id": "biochar_genset", "name": "Biochar reactor → genset", "blurb": "The reactor and condenser feeding a barrel-in-barrel gasometer (30 gal base, 15 gal float), a silica-gel dryer and a small 48 V generator that runs at 350–750 W whenever the float is well up.", "spec": biochar_genset()},
		{"id": "plastic_retort", "name": "Plastic retort (PP → oil, wax, gas)", "blurb": "The reactor loaded with 8 kg of polypropylene pellets: they melt, crack into light gas, oil and wax, and the condensers drop the oil and wax.", "spec": plastic_retort()},
		{"id": "tc_condenser", "name": "TC condenser (3 columns, 2\")", "blurb": "The reactor's condenser on its own: two 18\" dephlegmators down, a gas column up, drains at the bottom.", "spec": tc_condenser()},
		{"id": "pot_still", "name": "Pot still with column", "blurb": "A dished boiler, sight glass, packed column with a window, thermometer tee, dephlegmator and product condenser.", "spec": pot_still()},
		{"id": "brew_kettle", "name": "Brew kettle 50 L", "blurb": "A lidded kettle with a false bottom and hop basket, element, thermometer, ball-valve drain and a whirlpool port.", "spec": brew_kettle()},
		{"id": "ring_stand_reactor", "name": "Jacketed reactor on a ring stand", "blurb": "A Ø420 dished vessel with a jacket band, a 6\" neck under a bowl reducer and valve cross, three head ports, a bottom drain, a handle ring, on a three-leg ring stand with casters.", "spec": ring_stand_reactor()},
		{"id": "tall_tank", "name": "Tall jacketed tank on casters", "blurb": "A Ø360 × 1150 jacketed tank with a clamped dome lid: gauge, relief and valve on the lid, a side valve near the top, a drain.", "spec": tall_tank()},
		{"id": "horizontal_receiver", "name": "Horizontal receiver on a skid", "blurb": "A Ø460 × 900 tank on its side with dished ends, a 3\" clamp port in each end, three valved ports and a gauge along the top, on a caster skid.", "spec": horizontal_receiver()},
		{"id": "parts_kit", "name": "Tubes, columns and pots (parts kit)", "blurb": "The loose parts laid out: a 6\" × 1 m material tube with bowl reducers, a 4\" tube, a long 3\" jacketed condenser, a column, a sight glass, a jacketed collection pot and a recovery cylinder.", "spec": parts_kit()},
		{"id": "filter_train", "name": "Filter train (1½\")", "blurb": "Y strainer, a gauge tee, a cartridge housing and a carbon column to a hose barb.", "spec": filter_train()},
		{"id": "elbow_run", "name": "Elbow run (1½\")", "blurb": "Spool, elbow, spool, a 45°, a cap.", "spec": elbow_run()},
		{"id": "square_loop", "name": "Square loop (2\", fit length)", "blurb": "Four elbows round a loop; one spool fits itself so the loop closes.", "spec": square_loop()},
		{"id": "manifold", "name": "Sample manifold (1½\")", "blurb": "A cross with a thermometer cap, a hose barb, a male NPT adapter and a ½\" mini reducer.", "spec": manifold()},
	]
	return _builtins


static func builtin(id: String) -> Dictionary:
	for b in builtins():
		if str(b["id"]) == id:
			return (b["spec"] as Dictionary).duplicate(true)
	return {}


## Add `type` with its end `own` on the open end `target`; `want` =
## [[port id, world direction], …] picks the roll (15° steps) that points
## those ends that way ("@up" = the part's own +Y). Returns [spec, new id].
static func _attach(s: Dictionary, type: String, size: String, params: Dictionary, target: String,
		own: String = "a", want: Array = []) -> Array:
	var roll := 0.0
	if not want.is_empty():
		var res := TcAssembly.solve(TcSpec.resolve(s))
		var txf := Transform3D.IDENTITY
		var tport := {}
		for op in res["open"]:
			if str(op["ref"]) == target:
				txf = op["xf"]
				tport = op["port"]
		var b := TcParts.build(type, size, params)
		var ports := {}
		for q in b["ports"]:
			ports[str(q["id"])] = q
		if ports.has(own) and not tport.is_empty():
			var gap := TcParts.joint_gap(tport, ports[own])
			var best := -INF
			for k in 24:
				var r := 15.0 * float(k)
				var xf := TcAssembly.place_on(txf, ports[own], gap, r)
				var score := 0.0
				for w in want:
					if str(w[0]) == "@up":
						# The part's own up (a unit that stands on the floor).
						score += (xf.basis * Vector3.UP).dot((w[1] as Vector3).normalized())
					elif ports.has(str(w[0])):
						score += (xf.basis * (ports[str(w[0])]["z"] as Vector3)).dot((w[1] as Vector3).normalized())
				if score > best + 1e-6:
					best = score
					roll = r
	return TcAssembly.add_part(s, type, size, params, Transform3D.IDENTITY, {"target": target, "own": own, "roll": roll})


static func _label(s: Dictionary, ref: String, text: String, kind: String = "") -> void:
	(s["labels"] as Dictionary)[ref] = {"text": text, "kind": kind}


# ---------------------------------------------------------------------------
# The biochar reactor and its condenser
# ---------------------------------------------------------------------------

const REACTOR_BUNGS := [[0.0, 603.0], [65.0, 603.0], [45.0, 127.0], [45.0, 49.0], [315.0, 226.0], [0.0, 159.0]]


static func reactor_vessel() -> Dictionary:
	var ports: Array = [
		{"id": "crown", "kind": "tc", "size": "1.5", "face": "lid", "angle_deg": 0.0, "r_mm": 0.0, "stub_mm": 30.0},
		# Two elements up through the bottom, the charge loaded round them
		# (the user's reactor, 2026-11-06; the GLB had one on the shell).
		{"id": "element", "kind": "tc", "size": "2", "face": "bottom", "angle_deg": 90.0, "r_mm": 80.0, "stub_mm": 20.0},
		{"id": "element2", "kind": "tc", "size": "2", "face": "bottom", "angle_deg": 270.0, "r_mm": 80.0, "stub_mm": 20.0},
		{"id": "drain", "kind": "tc", "size": "2", "face": "shell", "angle_deg": 270.0, "h_mm": 98.0, "stub_mm": 20.0},
		{"id": "back_low", "kind": "tc", "size": "2", "face": "shell", "angle_deg": 180.0, "h_mm": 66.0, "stub_mm": 20.0},
		{"id": "vapour", "kind": "tc", "size": "2", "face": "shell", "angle_deg": 180.0, "h_mm": 620.0, "stub_mm": 20.0},
	]
	var k := 0
	for b in REACTOR_BUNGS:
		k += 1
		ports.append({"id": "bung%d" % k, "kind": "npt", "size": "0.5", "face": "shell",
			"angle_deg": float(b[0]), "h_mm": float(b[1]), "stub_mm": 12.0})
	# The inner vessel is Ø340 in a 26 mm jacket gap (Ø396 outside, as the
	# model). The model's inside face measures Ø366: the process runs are
	# calibrated on Ø340, so the inner wall was left there.
	return {"od_mm": 340.0, "height_mm": 650.0, "wall_mm": 2.0, "bottom": "flat", "top": "open",
		# The model's lid (measured 2026-11-08): a Ø342 × 59 mm dome on a
		# Ø380 flange ring that sits on the rim, held by a band clamp.
		"lid": true, "lid_od_mm": 380.0, "lid_dome_od_mm": 342.0, "lid_depth_mm": 59.0, "lid_handles": true,
		"lid_clamp": true, "lid_shape": "cap",
		# The model's two hoops round the jacket.
		"bands": [290.0, 490.0],
		# A flat double bottom, no feet: the steam jacket wraps under the inner
		# bottom and the vessel stands on the jacket's own bottom. The two
		# elements are on the INNER bottom; their heads sit between the two.
		# 150 mm puts the underside on the floor the gasometer and generator
		# stand on, with the gas line a hand's width above it.
		"jacket": "full", "jacket_gap_mm": 26.0, "jacket_bottom_mm": 150.0,
		"legs": "none",
		"internals": [],
		"ports": ports}


## The three-column condenser off `target` (an open 2" clamp end facing the
## way the condenser should stand off). `back` is the direction behind the
## columns (where the water and gas ends face). Returns the spec.
static func _condenser(s: Dictionary, target: String, own_c: bool, back: Vector3) -> Dictionary:
	var right := Vector3.UP.cross(back).normalized()   # +X when back is −Z
	var r := _attach(s, "tee", "2", {}, target, "c" if own_c else "a", [["a", -right]] if own_c else [["c", Vector3.DOWN]])
	s = r[0]
	var top: String = r[1]
	var cols: Array = []
	for side in [["a", -right], ["b", right]]:
		r = _attach(s, "elbow90", "2", {"short": true}, "%s:%s" % [top, side[0]], "a", [["b", Vector3.DOWN]])
		s = r[0]
		var el: String = r[1]
		r = _attach(s, "dephlegmator", "2", {"length_mm": 457.2, "shell": "2.5"}, el + ":b", "a", [["w1", back]])
		s = r[0]
		var dep: String = r[1]
		_label(s, dep + ":w2", "Cooling water in", "water")
		_label(s, dep + ":w1", "Cooling water out", "hot_water")
		r = _attach(s, "tee", "2", {"short": true}, dep + ":b", "c", [["a", -(side[1] as Vector3)]])
		s = r[0]
		cols.append(r[1])
	# Across the bottom: the centre tee on the left column's inner end, its
	# branch up; the right column's inner end closes the loop.
	r = _attach(s, "tee", "2", {}, str(cols[0]) + ":a", "a", [["c", Vector3.UP]])
	s = r[0]
	var mid: String = r[1]
	(s["joints"] as Array).append({"a": mid + ":b", "b": str(cols[1]) + ":a", "roll_deg": 0.0,
		"gasket": "silicone", "clamp": "single_pin"})
	for c in cols:
		r = _attach(s, "tc_npt_m", "2", {"npt": "0.5"}, str(c) + ":b", "a")
		s = r[0]
		_label(s, str(r[1]) + ":b", "Condensate out (wood vinegar)", "wood_vinegar")
	r = _attach(s, "dephlegmator", "2", {"length_mm": 346.0, "shell": "2.5"}, mid + ":c", "a", [["w1", back]])
	s = r[0]
	var gas: String = r[1]
	_label(s, gas + ":w2", "Cooling water in", "water")
	_label(s, gas + ":w1", "Cooling water out", "hot_water")
	r = _attach(s, "elbow90", "2", {"short": true}, gas + ":b", "a", [["b", back]])
	s = r[0]
	_label(s, str(r[1]) + ":b", "Woodgas out", "woodgas")
	return s


static func biochar_reactor() -> Dictionary:
	var s := TcSpec.empty("Biochar reactor + condenser")
	s["design_c"] = 140.0
	# On the graph it is the Biochar Reactor processor: its labelled ends
	# become that node's ports (TcDesign.graph_handles).
	s["binds"] = "Biochar Reactor"
	var r := TcAssembly.add_part(s, "vessel", "2", reactor_vessel(), Transform3D.IDENTITY)
	s = r[0]
	var v: String = r[1]
	_label(s, v + ":crown", "Feed / vent", "biomass")
	# The first element on its bottom port, its loops up into the charge
	# (the second goes on last, so the condenser's part ids stay put).
	r = _attach(s, "heating_element", "2", {"length_mm": 300.0}, v + ":element", "a")
	s = r[0]
	# Drain: a short spool (the model's long ferrule), the butterfly valve
	# with its handle up, a short elbow down.
	r = _attach(s, "spool", "2", {"length_mm": 40.0}, v + ":drain", "a")
	s = r[0]
	var sp: String = r[1]
	r = _attach(s, "butterfly", "2", {"open": false}, sp + ":b", "a", [["stem", Vector3.UP]])
	s = r[0]
	var bf: String = r[1]
	r = _attach(s, "elbow90", "2", {"short": true}, bf + ":b", "a", [["b", Vector3.DOWN]])
	s = r[0]
	_label(s, str(r[1]) + ":b", "Drain", "water")
	r = _attach(s, "cap", "2", {}, v + ":back_low", "a")
	s = r[0]
	# Instruments on two of the bungs.
	r = _attach(s, "thermometer", "2", {"mount": "npt", "npt": "0.5", "probe_mm": 80.0}, v + ":bung1", "a")
	s = r[0]
	r = _attach(s, "gauge", "2", {"mount": "npt", "npt": "0.5"}, v + ":bung2", "a")
	s = r[0]
	s = _condenser(s, v + ":vapour", true, Vector3(0, 0, -1))
	r = _attach(s, "heating_element", "2", {"length_mm": 300.0}, v + ":element2", "a")
	s = r[0]
	s["process"] = _with_done_rule(TcProcSpec.biochar_default(), str(s["name"]))
	return TcSpec.resolve(s)


## `p` with the "elements off when the charge is done" rule for a design
## called `name` (the rule's sensor carries the design's slug).
static func _with_done_rule(p: Dictionary, name: String) -> Dictionary:
	var autos: Array = (p.get("automations", []) as Array).duplicate(true)
	autos.append(TcProcControl.done_rule(TcProcControl.slug(name)))
	p["automations"] = autos
	return p


## The reactor as a plastic retort: same vessel and condenser, loaded with
## PP pellets. No graph node (nothing on the graph makes oil from plastic
## yet); its drains carry the tar / bio-oil kind.
static func plastic_retort() -> Dictionary:
	var s := biochar_reactor()
	s["name"] = "Plastic retort"
	s["binds"] = ""
	var labels: Dictionary = s["labels"]
	for k in labels.keys():
		var t := str((labels[k] as Dictionary).get("text", ""))
		if t.begins_with("Condensate out"):
			labels[k] = {"text": "Oil and wax out", "kind": "tar"}
		elif t == "Woodgas out":
			labels[k] = {"text": "Light gas out", "kind": "woodgas"}
		elif t == "Feed / vent":
			labels[k] = {"text": "Feed / vent", "kind": "plastic_waste"}
	s["process"] = _with_done_rule(TcProcSpec.plastic_default(), str(s["name"]))
	return TcSpec.resolve(s)


## Where an open end is ({xf, port}); {} when `ref` is not open.
static func _open_end(s: Dictionary, ref: String) -> Dictionary:
	var res := TcAssembly.solve(TcSpec.resolve(s))
	for op in res["open"]:
		if str(op["ref"]) == ref:
			return op
	return {}


## The whole chain (Phase 8 of plans/TC_PROCESS_LAB_PLAN.md): the reactor and
## condenser, the gas line down behind it to a bell gas holder, a silica-gel
## dryer and a 48 V genset. The genset runs from the holder (on at 60 %, off
## at 15 %). On the graph the reactor, the holder (a woodgas tank) and the
## genset (a Woodgas DC Generator) are three nodes, wired in that order.
static func biochar_genset() -> Dictionary:
	var s := biochar_reactor()
	s["name"] = "Biochar reactor → genset"
	var out_ref := ""
	for k in (s["labels"] as Dictionary).keys():
		if str((s["labels"][k] as Dictionary).get("text", "")) == "Woodgas out":
			out_ref = str(k)
	(s["labels"] as Dictionary).erase(out_ref)
	# Down: an elbow turned to the ground, a spool, an elbow back out.
	var r := _attach(s, "elbow90", "2", {}, out_ref, "a", [["b", Vector3.DOWN]])
	s = r[0]
	var down: String = r[1]
	# The run along the ground sits at GAS_LINE_Y: the holder's tank then
	# stands on the floor the reactor's flat bottom stands on, the pipe
	# about 90 mm above it.
	var y_top := float((_open_end(s, down + ":b")["xf"] as Transform3D).origin.y)
	var drop := maxf(y_top - GAS_LINE_Y - TcStandards.elbow90_ctf("2"), 60.0)
	r = _attach(s, "spool", "2", {"length_mm": drop}, down + ":b", "a")
	s = r[0]
	r = _attach(s, "elbow90", "2", {}, str(r[1]) + ":b", "a", [["b", Vector3(0, 0, -1)]])
	s = r[0]
	r = _attach(s, "spool", "2", {"length_mm": 250.0}, str(r[1]) + ":b", "a")
	s = r[0]
	r = _attach(s, "gas_holder", "2", {}, str(r[1]) + ":b", "a", [["@up", Vector3.UP]])   # the barrel gasometer, 30 gal base
	s = r[0]
	var holder: String = r[1]
	r = _attach(s, "dryer", "2", {"length_mm": 450.0, "packing": "silica"}, holder + ":b", "a", [["@up", Vector3.UP]])
	s = r[0]
	r = _attach(s, "genset", "2", {}, str(r[1]) + ":b", "a", [["@up", Vector3.UP]])   # the small generator, 350–750 W
	s = r[0]
	var gen: String = r[1]
	s["part_binds"] = [[holder, "holder"], [gen, "genset"]]
	var p := TcProcSpec.biochar_default()
	p["duration_h"] = 8.0
	var slug := TcProcControl.slug(str(s["name"]))
	var lvl := "sensor.%s_%s_level" % [slug, holder]
	var sw := "switch.%s_%s" % [slug, gen]
	p["automations"] = [
		{"id": "genset_on", "alias": "Generator on when the gasometer is 80 % full", "enabled": true,
			"triggers": [{"kind": "numeric", "entity_id": lvl, "above": 80.0}],
			"conditions": [], "actions": [{"kind": "scene_node", "command": "turn_on", "target": sw}]},
		{"id": "genset_off", "alias": "Generator off when the gasometer is down to 15 %", "enabled": true,
			"triggers": [{"kind": "numeric", "entity_id": lvl, "below": 15.0}],
			"conditions": [], "actions": [{"kind": "scene_node", "command": "turn_off", "target": sw}]},
		TcProcControl.done_rule(slug)]
	s["process"] = p
	return TcSpec.resolve(s)


const GAS_LINE_Y := -60.0


static func tc_condenser() -> Dictionary:
	var s := TcSpec.empty("TC condenser")
	# A free 2" ferrule stands in for the boiler's vapour port.
	var r := TcAssembly.add_part(s, "ferrule", "2", {}, Transform3D(Basis.IDENTITY, Vector3(0, 620, -218)))
	s = r[0]
	var f: String = r[1]
	_label(s, f + ":b", "Weld to the vessel", "steam")
	s = _condenser(s, f + ":a", true, Vector3(0, 0, -1))
	return TcSpec.resolve(s)


# ---------------------------------------------------------------------------
# More process presets
# ---------------------------------------------------------------------------

static func pot_still() -> Dictionary:
	var s := TcSpec.empty("Pot still with column")
	var vp: Dictionary = (TcVessel.PRESETS["pot_still"]["params"] as Dictionary).duplicate(true)
	vp["ports"] = [
		{"id": "crown", "kind": "tc", "size": "2", "face": "top", "angle_deg": 0.0, "r_mm": 0.0, "stub_mm": 40.0},
		{"id": "element", "kind": "tc", "size": "2", "face": "shell", "angle_deg": 90.0, "h_mm": 90.0, "stub_mm": 30.0},
		{"id": "drain", "kind": "tc", "size": "1.5", "face": "shell", "angle_deg": 270.0, "h_mm": 40.0, "stub_mm": 30.0},
		{"id": "temp", "kind": "npt", "size": "0.5", "face": "shell", "angle_deg": 0.0, "h_mm": 300.0, "stub_mm": 12.0}]
	var r := TcAssembly.add_part(s, "vessel", "2", vp, Transform3D.IDENTITY)
	s = r[0]
	var v: String = r[1]
	r = _attach(s, "heating_element", "2", {"length_mm": 220.0}, v + ":element", "a")
	s = r[0]
	r = _attach(s, "ball_valve", "1.5", {"open": false}, v + ":drain", "a", [["stem", Vector3.UP]])
	s = r[0]
	r = _attach(s, "tc_barb", "1.5", {"barb": "0.5"}, str(r[1]) + ":b", "a")
	s = r[0]
	_label(s, str(r[1]) + ":b", "Drain", "water")
	r = _attach(s, "thermometer", "2", {"mount": "npt", "npt": "0.5"}, v + ":temp", "a")
	s = r[0]
	r = _attach(s, "sight_glass", "2", {"length_mm": 150.0}, v + ":crown", "a")
	s = r[0]
	r = _attach(s, "column", "2", {"length_mm": 450.0, "window": true, "packing": "copper_mesh"}, str(r[1]) + ":b", "a")
	s = r[0]
	r = _attach(s, "tee", "2", {}, str(r[1]) + ":b", "a", [["c", Vector3(0, 0, 1)]])
	s = r[0]
	var tee: String = r[1]
	r = _attach(s, "thermometer", "2", {"probe_mm": 40.0}, tee + ":c", "a")
	s = r[0]
	r = _attach(s, "dephlegmator", "2", {"length_mm": 457.2, "shell": "2.5"}, tee + ":b", "a", [["w1", Vector3(0, 0, -1)]])
	s = r[0]
	var dep: String = r[1]
	_label(s, dep + ":w2", "Cooling water in", "water")
	_label(s, dep + ":w1", "Cooling water out", "water")
	r = _attach(s, "elbow90", "2", {}, dep + ":b", "a", [["b", Vector3(1, 0, 0)]])
	s = r[0]
	r = _attach(s, "spool", "2", {"length_mm": 200.0}, str(r[1]) + ":b", "a")
	s = r[0]
	r = _attach(s, "elbow90", "2", {}, str(r[1]) + ":b", "a", [["b", Vector3.DOWN]])
	s = r[0]
	r = _attach(s, "dephlegmator", "2", {"length_mm": 609.6, "shell": "2.5"}, str(r[1]) + ":b", "a", [["w1", Vector3(1, 0, 0)]])
	s = r[0]
	var cond: String = r[1]
	_label(s, cond + ":w1", "Cooling water in", "water")
	_label(s, cond + ":w2", "Cooling water out", "water")
	r = _attach(s, "tc_barb", "2", {"barb": "0.5"}, cond + ":b", "a")
	s = r[0]
	_label(s, str(r[1]) + ":b", "Product out", "")
	s["process"] = TcProcSpec.pot_still_default()
	return TcSpec.resolve(s)


static func brew_kettle() -> Dictionary:
	var s := TcSpec.empty("Brew kettle 50 L")
	var vp: Dictionary = (TcVessel.PRESETS["brew_kettle"]["params"] as Dictionary).duplicate(true)
	vp["internals"] = [{"kind": "false_bottom", "od_mm": 380.0, "h_mm": 2.0, "z_mm": 30.0},
		{"kind": "basket", "od_mm": 180.0, "h_mm": 240.0, "z_mm": 150.0}]
	vp["ports"] = [
		{"id": "drain", "kind": "tc", "size": "1.5", "face": "shell", "angle_deg": 0.0, "h_mm": 40.0, "stub_mm": 40.0},
		{"id": "whirlpool", "kind": "tc", "size": "1.5", "face": "shell", "angle_deg": 60.0, "h_mm": 150.0, "stub_mm": 40.0},
		{"id": "temp", "kind": "npt", "size": "0.5", "face": "shell", "angle_deg": 300.0, "h_mm": 120.0, "stub_mm": 12.0},
		{"id": "element", "kind": "tc", "size": "1.5", "face": "shell", "angle_deg": 180.0, "h_mm": 80.0, "stub_mm": 30.0},
		{"id": "vent", "kind": "tc", "size": "1.5", "face": "lid", "angle_deg": 0.0, "r_mm": 0.0, "stub_mm": 30.0}]
	var r := TcAssembly.add_part(s, "vessel", "1.5", vp, Transform3D.IDENTITY)
	s = r[0]
	var v: String = r[1]
	r = _attach(s, "ball_valve", "1.5", {"open": false}, v + ":drain", "a", [["stem", Vector3.UP]])
	s = r[0]
	r = _attach(s, "tc_barb", "1.5", {"barb": "0.5"}, str(r[1]) + ":b", "a")
	s = r[0]
	_label(s, str(r[1]) + ":b", "Wort out", "water")
	_label(s, v + ":whirlpool", "Whirlpool return", "water")
	_label(s, v + ":vent", "Vent", "steam")
	r = _attach(s, "thermometer", "1.5", {"mount": "npt", "npt": "0.5"}, v + ":temp", "a")
	s = r[0]
	r = _attach(s, "heating_element", "1.5", {"length_mm": 260.0}, v + ":element", "a")
	s = r[0]
	s["process"] = TcProcSpec.kettle_default()
	return TcSpec.resolve(s)


# ---------------------------------------------------------------------------
# From the user's photos (2026-11-08): tanks and loose parts. Sizes were read
# off the pictures against the clamps, casters and bus wheel in them, so they
# are estimates to a few centimetres; every one is a normal design the
# player can resize.
# ---------------------------------------------------------------------------

static func _tc(id: String, size: String, face: String, angle: float, at: float, stub: float = 40.0) -> Dictionary:
	var q := {"id": id, "kind": "tc", "size": size, "face": face, "angle_deg": angle, "stub_mm": stub}
	q["h_mm" if face == "shell" else "r_mm"] = at
	return q


static func _npt(id: String, angle: float, h: float) -> Dictionary:
	return {"id": id, "kind": "npt", "size": "0.5", "face": "shell", "angle_deg": angle, "h_mm": h, "stub_mm": 12.0}


## The reactor on its ring stand: dished top and bottom, a jacket band round
## the lower shell, a 6" neck on the crown closed by a bowl reducer and a
## cross (gauge, relief valve, a ball valve up), three ports round the head
## (one with a capped elbow), a bottom drain through an elbow and a
## butterfly valve, and the handle ring.
static func ring_stand_reactor() -> Dictionary:
	var s := TcSpec.empty("Jacketed reactor on a ring stand")
	var vp: Dictionary = (TcVessel.PRESETS["ring_stand_reactor"]["params"] as Dictionary).duplicate(true)
	vp["ports"] = [_tc("neck", "6", "top", 0.0, 0.0, 70.0), _tc("head1", "2", "top", 0.0, 150.0, 45.0),
		_tc("head2", "3", "top", 120.0, 150.0, 45.0), _tc("head3", "2", "top", 240.0, 150.0, 45.0),
		_tc("drain", "2", "bottom", 0.0, 0.0, 60.0), _npt("jacket_in", 90.0, 30.0), _npt("jacket_out", 270.0, 160.0)]
	# Lifted so its casters stand on the floor.
	var lift := TcVessel.head_depth(TcVessel.resolve(vp), "bottom") + float(vp["leg_h_mm"])
	var r := TcAssembly.add_part(s, "vessel", "2", vp, Transform3D(Basis.IDENTITY, Vector3(0, lift, 0)))
	s = r[0]
	var v: String = r[1]
	_label(s, v + ":jacket_in", "Jacket water in", "water")
	_label(s, v + ":jacket_out", "Jacket water out", "hot_water")
	r = _attach(s, "bowl_reducer", "6", {"small": "2"}, v + ":neck", "a")
	s = r[0]
	r = _attach(s, "cross", "2", {}, str(r[1]) + ":b", "a", [["b", Vector3.UP]])
	s = r[0]
	var x: String = r[1]
	r = _attach(s, "gauge", "2", {}, x + ":c", "a")
	s = r[0]
	r = _attach(s, "relief_valve", "2", {}, x + ":d", "a")
	s = r[0]
	r = _attach(s, "ball_valve", "2", {"open": false}, x + ":b", "a", [["stem", Vector3(1, 0, 0)]])
	s = r[0]
	r = _attach(s, "tc_barb", "2", {"barb": "0.5"}, str(r[1]) + ":b", "a")
	s = r[0]
	_label(s, str(r[1]) + ":b", "Vapour out", "steam")
	r = _attach(s, "elbow90", "2", {}, v + ":head1", "a", [["b", Vector3(0, 0, 1)]])
	s = r[0]
	r = _attach(s, "cap", "2", {}, str(r[1]) + ":b", "a")
	s = r[0]
	r = _attach(s, "cap_npt", "3", {"npt": "0.5"}, v + ":head2", "a")
	s = r[0]
	r = _attach(s, "cap", "2", {}, v + ":head3", "a")
	s = r[0]
	r = _attach(s, "elbow90", "2", {}, v + ":drain", "a", [["b", Vector3(-1, 0, 0)]])
	s = r[0]
	r = _attach(s, "butterfly", "2", {"open": false}, str(r[1]) + ":b", "a", [["stem", Vector3.UP]])
	s = r[0]
	_label(s, str(r[1]) + ":b", "Drain", "water")
	return TcSpec.resolve(s)


## The tall jacketed tank: a clamped dome lid carrying a cross (gauge, relief,
## a valve to a hose), a second lid port, a valved side port near the top, a
## drain valve, the jacket's two bungs, on four casters.
static func tall_tank() -> Dictionary:
	var s := TcSpec.empty("Tall jacketed tank on casters")
	var vp: Dictionary = (TcVessel.PRESETS["tall_tank"]["params"] as Dictionary).duplicate(true)
	vp["ports"] = [_tc("lid1", "1.5", "lid", 0.0, 0.0, 40.0), _tc("lid2", "2", "lid", 90.0, 105.0, 35.0),
		_tc("side", "1.5", "shell", 0.0, 950.0, 35.0), _tc("drain", "1.5", "shell", 180.0, 40.0, 35.0),
		_npt("jacket_in", 270.0, 100.0), _npt("jacket_out", 270.0, 1050.0)]
	var r := TcAssembly.add_part(s, "vessel", "1.5", vp, Transform3D(Basis.IDENTITY, Vector3(0, float(vp["leg_h_mm"]) + 2.0, 0)))
	s = r[0]
	var v: String = r[1]
	_label(s, v + ":jacket_in", "Jacket water in", "water")
	_label(s, v + ":jacket_out", "Jacket water out", "hot_water")
	r = _attach(s, "cross", "1.5", {}, v + ":lid1", "a", [["b", Vector3.UP]])
	s = r[0]
	var x: String = r[1]
	r = _attach(s, "gauge", "1.5", {}, x + ":c", "a")
	s = r[0]
	r = _attach(s, "ball_valve", "1.5", {"open": false}, x + ":d", "a", [["stem", Vector3.UP]])
	s = r[0]
	r = _attach(s, "tc_barb", "1.5", {"barb": "0.5"}, str(r[1]) + ":b", "a")
	s = r[0]
	_label(s, str(r[1]) + ":b", "Vapour in / out", "steam")
	r = _attach(s, "relief_valve", "1.5", {}, x + ":b", "a")
	s = r[0]
	r = _attach(s, "cap", "2", {}, v + ":lid2", "a")
	s = r[0]
	r = _attach(s, "ball_valve", "1.5", {"open": false}, v + ":side", "a", [["stem", Vector3.UP]])
	s = r[0]
	r = _attach(s, "tc_barb", "1.5", {"barb": "0.5"}, str(r[1]) + ":b", "a")
	s = r[0]
	_label(s, str(r[1]) + ":b", "Liquid in", "water")
	r = _attach(s, "ball_valve", "1.5", {"open": false}, v + ":drain", "a", [["stem", Vector3.UP]])
	s = r[0]
	_label(s, str(r[1]) + ":b", "Drain", "water")
	return TcSpec.resolve(s)


## The horizontal receiver: the tank turned on its side (its skid along the
## shell's back, underneath), three valved clamp ports and a gauge along the
## top, a 3" clamp port in each dished end.
static func horizontal_receiver() -> Dictionary:
	var s := TcSpec.empty("Horizontal receiver on a skid")
	var vp: Dictionary = (TcVessel.PRESETS["horizontal_tank"]["params"] as Dictionary).duplicate(true)
	vp["ports"] = [_tc("top1", "1.5", "shell", 0.0, 200.0, 35.0), _tc("top2", "1.5", "shell", 0.0, 450.0, 35.0),
		_tc("top3", "1.5", "shell", 0.0, 700.0, 35.0), _npt("gauge", 0.0, 820.0), _npt("side", 90.0, 120.0),
		_tc("end_a", "3", "top", 0.0, 0.0, 50.0), _tc("end_b", "3", "bottom", 0.0, 0.0, 50.0)]
	# A quarter turn: the vessel's axis lies along −Z, its −Z side (the skid) down.
	var lift := float(vp["od_mm"]) * 0.5 + float(vp["leg_h_mm"]) + 15.0
	var r := TcAssembly.add_part(s, "vessel", "1.5", vp, Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0, lift, 450)))
	s = r[0]
	var v: String = r[1]
	var names := ["Vapour in", "Vent", "Liquid out"]
	var kinds := ["steam", "steam", "water"]
	for k in 3:
		r = _attach(s, "ball_valve", "1.5", {"open": false}, "%s:top%d" % [v, k + 1], "a", [["stem", Vector3(1, 0, 0)]])
		s = r[0]
		r = _attach(s, "tc_npt_m", "1.5", {"npt": "0.5"}, str(r[1]) + ":b", "a")
		s = r[0]
		_label(s, str(r[1]) + ":b", names[k], kinds[k])
	r = _attach(s, "gauge", "1.5", {"mount": "npt", "npt": "0.5"}, v + ":gauge", "a")
	s = r[0]
	r = _attach(s, "cap", "3", {}, v + ":end_a", "a")
	s = r[0]
	r = _attach(s, "cap_npt", "3", {"npt": "0.5"}, v + ":end_b", "a")
	s = r[0]
	return TcSpec.resolve(s)


## The loose parts from the photo, laid out side by side: each is a free
## group the player can pick up, copy into a design or build on.
static func parts_kit() -> Dictionary:
	var s := TcSpec.empty("Tubes, columns and pots")
	var lay := func(x: float, r_mm: float) -> Transform3D:
		return Transform3D(Basis.IDENTITY, Vector3(x, r_mm, 0.0))
	# A 6" × 1 m material tube, a bowl reducer on each end.
	var r := TcAssembly.add_part(s, "spool", "6", {"length_mm": 1000.0}, lay.call(0.0, 112.0))
	s = r[0]
	var tube: String = r[1]
	r = _attach(s, "bowl_reducer", "6", {"small": "2"}, tube + ":a", "a")
	s = r[0]
	r = _attach(s, "bowl_reducer", "6", {"small": "2"}, tube + ":b", "a")
	s = r[0]
	# A 4" × 900 mm tube with cone reducers.
	r = TcAssembly.add_part(s, "spool", "4", {"length_mm": 900.0}, lay.call(300.0, 84.0))
	s = r[0]
	tube = r[1]
	r = _attach(s, "reducer", "4", {"small": "1.5"}, tube + ":a", "a")
	s = r[0]
	r = _attach(s, "reducer", "4", {"small": "1.5"}, tube + ":b", "a")
	s = r[0]
	# A long jacketed condenser (3" in a 4" jacket).
	r = TcAssembly.add_part(s, "dephlegmator", "3", {"length_mm": 900.0, "shell": "4"}, lay.call(560.0, 84.0))
	s = r[0]
	# A packed column with a window, and a sight glass.
	r = TcAssembly.add_part(s, "column", "3", {"length_mm": 600.0, "window": true, "packing": "raschig"}, lay.call(790.0, 66.0))
	s = r[0]
	r = TcAssembly.add_part(s, "sight_glass", "3", {"length_mm": 200.0}, lay.call(990.0, 66.0))
	s = r[0]
	# A jacketed collection pot: clamp ports top and bottom, jacket bungs.
	var pot: Dictionary = (TcVessel.PRESETS["collection_pot"]["params"] as Dictionary).duplicate(true)
	pot["ports"] = [_tc("top", "1.5", "top", 0.0, 0.0, 35.0), _tc("bottom", "1.5", "bottom", 0.0, 0.0, 35.0),
		_npt("jacket_in", 90.0, 40.0), _npt("jacket_out", 270.0, 260.0)]
	r = TcAssembly.add_part(s, "vessel", "1.5", pot, Transform3D(Basis.IDENTITY, Vector3(1290.0, 120.0, 200.0)))
	s = r[0]
	# A recovery cylinder with its collar and a valve.
	var cyl: Dictionary = (TcVessel.PRESETS["cylinder"]["params"] as Dictionary).duplicate(true)
	cyl["ports"] = [_tc("valve", "1.5", "top", 0.0, 0.0, 30.0)]
	r = TcAssembly.add_part(s, "vessel", "1.5", cyl, Transform3D(Basis.IDENTITY, Vector3(1640.0, 105.0, 200.0)))
	s = r[0]
	r = _attach(s, "ball_valve", "1.5", {"open": false}, str(r[1]) + ":valve", "a", [["stem", Vector3(1, 0, 0)]])
	s = r[0]
	return TcSpec.resolve(s)


static func filter_train() -> Dictionary:
	var s := TcSpec.empty("Filter train")
	var r := TcAssembly.add_part(s, "y_strainer", "1.5", {}, Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(0, 320, 0)))
	s = r[0]
	var y: String = r[1]
	_label(s, y + ":a", "Water in", "water")
	r = _attach(s, "spool", "1.5", {"length_mm": 100.0}, y + ":b", "a")
	s = r[0]
	r = _attach(s, "tee", "1.5", {}, str(r[1]) + ":b", "a", [["c", Vector3.UP]])
	s = r[0]
	var tee: String = r[1]
	r = _attach(s, "gauge", "1.5", {}, tee + ":c", "a")
	s = r[0]
	r = _attach(s, "cartridge_housing", "1.5", {"element_mm": 254.0}, tee + ":b", "a", [["drain", Vector3.DOWN]])
	s = r[0]
	var cart: String = r[1]
	r = _attach(s, "spool", "1.5", {"length_mm": 100.0}, cart + ":b", "a")
	s = r[0]
	r = _attach(s, "column", "1.5", {"length_mm": 300.0, "window": false, "packing": "raschig"}, str(r[1]) + ":b", "a")
	s = r[0]
	r = _attach(s, "tc_barb", "1.5", {"barb": "0.5"}, str(r[1]) + ":b", "a")
	s = r[0]
	_label(s, str(r[1]) + ":b", "Clean water out", "water")
	return TcSpec.resolve(s)


## Add `type` mated to `target` ("pid:port") by its port `own`.
static func _chain(spec: Dictionary, type: String, size: String, params: Dictionary, target: String,
		own: String = "a", roll: float = 0.0) -> Array:
	return TcAssembly.add_part(spec, type, size, params, Transform3D.IDENTITY,
		{"target": target, "own": own, "roll": roll})


static func elbow_run() -> Dictionary:
	var s := TcSpec.empty("Elbow run")
	var r := TcAssembly.add_part(s, "spool", "1.5", {"length_mm": 152.4}, Transform3D(Basis.IDENTITY, Vector3(0, 300, 0)))
	s = r[0]
	var p1: String = r[1]
	r = _chain(s, "elbow90", "1.5", {}, p1 + ":b")
	s = r[0]
	var p2: String = r[1]
	r = _chain(s, "spool", "1.5", {"length_mm": 254.0}, p2 + ":b")
	s = r[0]
	var p3: String = r[1]
	r = _chain(s, "elbow45", "1.5", {}, p3 + ":b", "a", 90.0)
	s = r[0]
	r = _chain(s, "cap", "1.5", {}, str(r[1]) + ":b")
	return TcSpec.resolve(r[0])


static func square_loop() -> Dictionary:
	var s := TcSpec.empty("Square loop")
	var r := TcAssembly.add_part(s, "elbow90", "2", {}, Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0, 200, 0)))
	s = r[0]
	var first: String = r[1]
	var prev := first
	for k in 4:
		var fit := k == 2
		r = _chain(s, "spool", "2", {"length_mm": 120.0 if fit else 200.0, "fit": fit}, prev + ":b")
		s = r[0]
		var sp: String = r[1]
		if k == 3:
			# Close the loop onto the first elbow's open end.
			(s["joints"] as Array).append({"a": sp + ":b", "b": first + ":a", "roll_deg": 0.0,
				"gasket": "epdm", "clamp": "single_pin"})
			break
		r = _chain(s, "elbow90", "2", {}, sp + ":b")
		s = r[0]
		prev = r[1]
	return TcSpec.resolve(s)


static func manifold() -> Dictionary:
	var s := TcSpec.empty("Sample manifold")
	var r := TcAssembly.add_part(s, "cross", "1.5", {}, Transform3D(Basis.IDENTITY, Vector3(0, 250, 0)))
	s = r[0]
	var x: String = r[1]
	r = _chain(s, "cap_npt", "1.5", {"npt": "0.5"}, x + ":a")
	s = r[0]
	r = _chain(s, "tc_barb", "1.5", {"barb": "0.5"}, x + ":b")
	s = r[0]
	r = _chain(s, "tc_npt_m", "1.5", {"npt": "0.75"}, x + ":c")
	s = r[0]
	r = _chain(s, "reducing_cap", "1.5", {"small": "0.5"}, x + ":d")
	s = r[0]
	return TcSpec.resolve(s)


# ---------------------------------------------------------------------------
# Library
# ---------------------------------------------------------------------------

static func load_library() -> Array:
	if not FileAccess.file_exists(LIBRARY_PATH):
		return []
	var f := FileAccess.open(LIBRARY_PATH, FileAccess.READ)
	if f == null:
		return []
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (data is Dictionary):
		return []
	var out: Array = []
	for e in (data as Dictionary).get("designs", []):
		if e is Dictionary and (e as Dictionary).has("spec"):
			out.append(e)
	return out


static func save_library(entries: Array) -> bool:
	var f := FileAccess.open(LIBRARY_PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": 1, "designs": entries}, "  "))
	f.close()
	return true


## Save (or replace by name) a design. Returns the library.
static func save_design(name: String, spec: Dictionary) -> Array:
	var lib := load_library()
	var s := spec.duplicate(true)
	s["name"] = name
	var found := false
	for e in lib:
		if str(e["name"]) == name:
			e["spec"] = s
			found = true
	if not found:
		lib.append({"id": "u%d" % Time.get_unix_time_from_system(), "name": name, "spec": s})
	save_library(lib)
	return lib


static func forget_design(name: String) -> Array:
	var lib: Array = []
	for e in load_library():
		if str(e["name"]) != name:
			lib.append(e)
	save_library(lib)
	return lib
