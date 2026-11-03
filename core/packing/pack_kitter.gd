class_name PackKitter
extends RefCounted
## Parts list -> handling units, the way a crew actually kits a structure for
## the truck. Replaces the single idealised envelope most designers reported
## (a dome "packed" as one tight strut bundle, its hubs, panels and bolts
## nowhere), which is why parametric structures packed into far less room
## than their own parts.
##
## A PART ROW is {label, kind, len_m, w_m, h_m, mass_kg (each), qty,
## group?, fragile?, round?}:
##   stick  — a member: len_m long, w_m x h_m cross-section (tube: w = h = OD)
##   sheet  — a flat part: len_m x w_m, h_m thick
##   piece  — a rigid object of its own box (hub, motor, fitting)
##   loose  — hardware counted by the piece (bolts, nuts, clamps)
##
## kit(parts) returns PackedSpec units, each with:
##   label, handling ("hand" | "team" | "forklift"), parts = [{label, qty}]
##   and the usual w/d/h/mass/form/stackable keys.
## Every part lands in exactly one unit; mass is conserved (plus the
## packaging, reported per unit as packaging_kg); no unit is smaller than
## the parts it holds (checked by packing_selftest).
##
## Constants:
##   ONE_PERSON_KG 23 — NIOSH lifting equation load constant (Waters et al.
##     1993): the most one person should lift in ideal conditions.
##   TEAM_LIFT_KG 60 — two- to three-person carry (2.5 x the NIOSH constant,
##     the usual team-lift allowance).
##   BUNDLE_MAX_KG 500 — strapped bundle size a small forklift (1.5 t class)
##     handles safely on uneven ground; heavier kits split into more bundles.
##   STRAP_GAP_M 0.02 — dunnage / strap thickness each side of a bundle.
##   INTERLEAF_M 0.002 — slip sheet between stacked panels.
##   STACK_MAX_H_M 1.2 — a stable sheet stack before it is split.
##   CRATE_PAD_M 0.03 — foam / blocking round a piece crated on its own.
##   HARDWARE_BOX — a 400 x 300 x 250 mm parts carton, 25 kg max, filled to
##     ~60 % by loose fasteners (bulk density of bagged bolts).

const ONE_PERSON_KG := 23.0
const TEAM_LIFT_KG := 60.0
const BUNDLE_MAX_KG := 500.0
const BUNDLE_MAX_PIECES := 200
const LENGTH_CLASS_FRAC := 0.05
const STRAP_GAP_M := 0.02
const STRAP_KG := 0.5
const END_ALLOW_M := 0.05
const INTERLEAF_M := 0.002
const INTERLEAF_KG_M2 := 0.08
const STACK_MAX_H_M := 1.2
const CRATE_PAD_M := 0.03
const CRATE_KG_M2 := 9.0
const HARDWARE_BOX := {"w_m": 0.40, "d_m": 0.30, "h_m": 0.25, "max_kg": 25.0,
	"fill": 0.6, "tare_kg": 0.6}
const PIECE_CONTAINERS := ["tote_27gal", "action_packer_35", "job_box", "crate_8x4"]
const SOLVE_CHUNK := 160


## Normalizes one part row (fills defaults, sorts a sheet / piece box).
static func part(label: String, kind: String, len_m: float, w_m: float, h_m: float,
		mass_kg: float, qty: int = 1, extra: Dictionary = {}) -> Dictionary:
	var row := {"label": label, "kind": kind, "len_m": len_m, "w_m": w_m,
		"h_m": h_m, "mass_kg": mass_kg, "qty": maxi(qty, 0)}
	row.merge(extra, true)
	return row


## THE handling table: how a unit of a given mass is moved. Every reader —
## the kitter, the haul crew size (NpcHaulModel.carriers_for), the forklift
## rule (SiteProject.crate_needs_forklift, ForkliftRig.liftable), packing-list
## labels and the deploy planner's labour — asks this one table.
##   max_kg: the class's upper mass (INF = anything the forklift rates).
##   label: what the packing list prints.
##   labour_scale: person-hours per kg relative to carrying by hand (a
##     forklift lifts the weight; the crew only steadies and guides it —
##     an estimate, like the planner's KG_PER_HOUR).
const HANDLING := {
	"hand": {"max_kg": ONE_PERSON_KG, "label": "", "labour_scale": 1.0},
	"team": {"max_kg": TEAM_LIFT_KG, "label": "2-PERSON LIFT", "labour_scale": 1.0},
	"forklift": {"max_kg": INF, "label": "FORKLIFT", "labour_scale": 0.5},
}


static func handling_for(mass_kg: float) -> String:
	if mass_kg <= float(HANDLING["hand"]["max_kg"]):
		return "hand"
	if mass_kg <= float(HANDLING["team"]["max_kg"]):
		return "team"
	return "forklift"


## A handling class's row (hand when unknown).
static func handling(cls: String) -> Dictionary:
	return HANDLING.get(cls, HANDLING["hand"])


static func part_volume_m3(p: Dictionary) -> float:
	return maxf(float(p.get("len_m", 0.0)), 0.0) * maxf(float(p.get("w_m", 0.0)), 0.0) \
		* maxf(float(p.get("h_m", 0.0)), 0.0) * float(maxi(int(p.get("qty", 1)), 0))


static func parts_mass_kg(parts: Array) -> float:
	var m := 0.0
	for p in parts:
		m += maxf(float((p as Dictionary).get("mass_kg", 0.0)), 0.0) \
			* float(maxi(int((p as Dictionary).get("qty", 1)), 0))
	return m


static func kit(parts: Array, opts: Dictionary = {}) -> Array:
	var sticks: Array = []
	var sheets: Array = []
	var pieces: Array = []
	var loose: Array = []
	for raw in parts:
		var p: Dictionary = raw
		if int(p.get("qty", 1)) <= 0:
			continue
		match str(p.get("kind", "piece")):
			"stick": sticks.append(p)
			"sheet": sheets.append(p)
			"loose": loose.append(p)
			_: pieces.append(p)
	var units: Array = []
	units.append_array(_kit_sticks(sticks))
	units.append_array(_kit_sheets(sheets))
	units.append_array(_kit_pieces(pieces, opts))
	units.append_array(_kit_loose(loose))
	var prefix := str(opts.get("prefix", ""))
	for i in units.size():
		var u: Dictionary = units[i]
		u["unit_no"] = i + 1
		if not prefix.is_empty():
			u["label"] = "%s · %s" % [prefix, u.get("label", "")]
	return units


# --- sticks ----------------------------------------------------------------

static func _kit_sticks(rows: Array) -> Array:
	# Length classes: sorted longest first, a class takes every stick within
	# 5 % of its longest member that shares the cross-section and group.
	var flat: Array = []
	for p in rows:
		var d: Dictionary = p
		var a := maxf(float(d.get("w_m", 0.0)), float(d.get("h_m", 0.0)))
		var b := minf(float(d.get("w_m", 0.0)), float(d.get("h_m", 0.0)))
		flat.append({"row": d, "len": float(d.get("len_m", 0.0)), "a": a, "b": b,
			"key": "%s|%.3f|%.3f" % [str(d.get("group", "")), a, b]})
	flat.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		if x["key"] != y["key"]:
			return str(x["key"]) < str(y["key"])
		if absf(float(x["len"]) - float(y["len"])) > 1e-6:
			return float(x["len"]) > float(y["len"])
		return str((x["row"] as Dictionary).get("label", "")) \
			< str((y["row"] as Dictionary).get("label", "")))
	var units: Array = []
	var i := 0
	while i < flat.size():
		var head: Dictionary = flat[i]
		var cls: Array = [head]
		var j := i + 1
		while j < flat.size() and flat[j]["key"] == head["key"] \
				and float(flat[j]["len"]) >= float(head["len"]) * (1.0 - LENGTH_CLASS_FRAC):
			cls.append(flat[j])
			j += 1
		units.append_array(_bundle_class(cls))
		i = j
	return units


static func _bundle_class(cls: Array) -> Array:
	# Expand to (row, count) runs, then cut into bundles under the mass and
	# piece caps.
	var head: Dictionary = cls[0]
	var a := float(head["a"])
	var b := float(head["b"])
	var length := float(head["len"])
	var queue: Array = []
	for c in cls:
		var r: Dictionary = c["row"]
		queue.append({"row": r, "left": int(r.get("qty", 1))})
	var units: Array = []
	var qi := 0
	while qi < queue.size():
		var contents := {}
		var n := 0
		var mass := 0.0
		while qi < queue.size():
			var q: Dictionary = queue[qi]
			var r: Dictionary = q["row"]
			var each := maxf(float(r.get("mass_kg", 0.0)), 0.0)
			var room_n := BUNDLE_MAX_PIECES - n
			var room_m := int(floor((BUNDLE_MAX_KG - mass) / each)) if each > 0.0 else room_n
			var take := mini(int(q["left"]), mini(room_n, room_m))
			if take <= 0:
				if n == 0:
					take = 1  # a single stick over the cap still ships
				else:
					break
			var lbl := str(r.get("label", "part"))
			contents[lbl] = int(contents.get(lbl, 0)) + take
			n += take
			mass += each * take
			q["left"] = int(q["left"]) - take
			if int(q["left"]) <= 0:
				qi += 1
		var cols := int(ceil(sqrt(float(n))))
		var rows := int(ceil(float(n) / float(cols)))
		var sec_w := cols * a + 2.0 * STRAP_GAP_M
		var sec_h := rows * b + 2.0 * STRAP_GAP_M
		var total := mass + STRAP_KG
		var u := PackedSpec.normalize({
			"w_m": length + END_ALLOW_M, "d_m": sec_w, "h_m": sec_h,
			"form": "bundle", "mass_kg": total, "source": "computed",
		})
		u["label"] = "Bundle: %s" % _contents_text(contents)
		u["parts"] = _contents_list(contents)
		u["packaging_kg"] = STRAP_KG
		u["handling"] = handling_for(total)
		units.append(u)
	return units


# --- sheets ----------------------------------------------------------------

static func _kit_sheets(rows: Array) -> Array:
	var groups := {}
	var order: Array = []
	for p in rows:
		var d: Dictionary = p
		var l := maxf(float(d.get("len_m", 0.0)), float(d.get("w_m", 0.0)))
		var w := minf(float(d.get("len_m", 0.0)), float(d.get("w_m", 0.0)))
		var key := "%s|%.2f|%.2f|%s" % [str(d.get("group", "")), l, w,
			"f" if bool(d.get("fragile", false)) else ""]
		if bool(d.get("mixed", false)):
			key = "%s|mixed|%s" % [str(d.get("group", "")), "f" if bool(d.get("fragile", false)) else ""]
		if not groups.has(key):
			groups[key] = {"l": l, "w": w, "fragile": bool(d.get("fragile", false)), "rows": []}
			order.append(key)
		groups[key]["l"] = maxf(float(groups[key]["l"]), l)
		groups[key]["w"] = maxf(float(groups[key]["w"]), w)
		(groups[key]["rows"] as Array).append(d)
	order.sort()
	var units: Array = []
	for key in order:
		var g: Dictionary = groups[key]
		var l := float(g["l"])
		var w := float(g["w"])
		var fragile := bool(g["fragile"])
		var queue: Array = []
		for r in g["rows"]:
			queue.append({"row": r, "left": int((r as Dictionary).get("qty", 1))})
		var qi := 0
		while qi < queue.size():
			var contents := {}
			var height := 0.0
			var mass := 0.0
			var n := 0
			while qi < queue.size():
				var q: Dictionary = queue[qi]
				var r: Dictionary = q["row"]
				var t := maxf(float(r.get("h_m", 0.0)), 0.0005) + INTERLEAF_M
				var each := maxf(float(r.get("mass_kg", 0.0)), 0.0)
				var room_h := int(floor((STACK_MAX_H_M - height) / t))
				var room_m := int(floor((BUNDLE_MAX_KG - mass) / each)) if each > 0.0 else room_h
				var take := mini(int(q["left"]), mini(room_h, room_m))
				if take <= 0:
					if n == 0:
						take = 1
					else:
						break
				var lbl := str(r.get("label", "sheet"))
				contents[lbl] = int(contents.get(lbl, 0)) + take
				height += t * take
				mass += each * take
				n += take
				q["left"] = int(q["left"]) - take
				if int(q["left"]) <= 0:
					qi += 1
			var pack_kg := INTERLEAF_KG_M2 * l * w * n + STRAP_KG
			var pad := STRAP_GAP_M
			if fragile:
				pad = CRATE_PAD_M
			var dims := [l + 2.0 * pad, w + 2.0 * pad, height + 2.0 * pad]
			if fragile:
				pack_kg += CRATE_KG_M2 * _surface(dims)
			var total := mass + pack_kg
			var u := PackedSpec.normalize({
				"w_m": dims[0], "d_m": dims[1], "h_m": dims[2],
				"form": "crate" if fragile else "panel_stack",
				"mass_kg": total, "source": "computed",
				"this_side_up": fragile, "stackable": not fragile,
			})
			u["label"] = "%s: %s" % ["Crate" if fragile else "Stack", _contents_text(contents)]
			u["parts"] = _contents_list(contents)
			u["packaging_kg"] = pack_kg
			u["handling"] = handling_for(total)
			units.append(u)
	return units


# --- pieces ----------------------------------------------------------------

static func _kit_pieces(rows: Array, opts: Dictionary) -> Array:
	var units: Array = []
	var small: Array = []
	var biggest := ContainerCatalog.find(str(PIECE_CONTAINERS[PIECE_CONTAINERS.size() - 1]))
	for p in rows:
		var d: Dictionary = p
		var item := _piece_item(d)
		var each := maxf(float(d.get("mass_kg", 0.0)), 0.0)
		var fits := _fits_interior(item, biggest) and each <= float(biggest.get("payload_kg", 0.0)) * 0.5
		for k in int(d.get("qty", 1)):
			if fits and not bool(d.get("own_crate", false)):
				small.append(item)
			else:
				units.append(_own_crate(d))
	var containers: Array = opts.get("piece_containers", PIECE_CONTAINERS)
	var remaining := small
	var guard := 0
	while not remaining.is_empty() and guard < 2000:
		guard += 1
		var chunk: Array = remaining.slice(0, SOLVE_CHUNK)
		var rest: Array = remaining.slice(SOLVE_CHUNK)
		var chosen := {}
		var chosen_id := ""
		for cid in containers:
			var c := ContainerCatalog.find(str(cid))
			if c.is_empty():
				continue
			var r := PackSolver.solve(c, chunk)
			if bool(r.get("fit", false)) and bool(r.get("payload_ok", true)):
				chosen = r
				chosen_id = str(cid)
				break
		var taken: Array = []
		var left: Array = []
		if chosen.is_empty():
			chosen_id = str(containers[containers.size() - 1])
			var c2 := ContainerCatalog.find(chosen_id)
			var r2 := PackSolver.solve(c2, chunk)
			var cap := float(c2.get("payload_kg", 0.0))
			var mass := 0.0
			var used := {}
			for pl in r2.get("placements", []):
				var it: Dictionary = chunk[int(pl["item_index"])]
				var m := maxf(float(it.get("mass_kg", 0.0)), 0.0)
				if mass + m > cap and not taken.is_empty():
					continue
				mass += m
				taken.append(it)
				used[int(pl["item_index"])] = true
			if taken.is_empty():
				# Nothing would go in: crate the first piece on its own.
				units.append(_own_crate(chunk[0]["row"]))
				used[0] = true
			for k in chunk.size():
				if not used.has(k):
					left.append(chunk[k])
		else:
			taken = chunk
		if not taken.is_empty():
			units.append(_container_unit(chosen_id, taken))
		left.append_array(rest)
		remaining = left
	return units


static func _piece_item(d: Dictionary) -> Dictionary:
	var it := PackedSpec.normalize({
		"w_m": maxf(float(d.get("len_m", 0.0)), 0.001),
		"d_m": maxf(float(d.get("w_m", 0.0)), 0.001),
		"h_m": maxf(float(d.get("h_m", 0.0)), 0.001),
		"mass_kg": maxf(float(d.get("mass_kg", 0.0)), 0.0),
		"stackable": not bool(d.get("fragile", false)),
		"source": "computed",
	})
	it["label"] = str(d.get("label", "part"))
	it["row"] = d
	if float(d.get("mass_kg", 0.0)) <= 0.0:
		it["mass_kg"] = 0.0
	return it


static func _fits_interior(item: Dictionary, c: Dictionary) -> bool:
	var inner: Dictionary = c.get("interior", {})
	var a := [float(item["w_m"]), float(item["d_m"]), float(item["h_m"])]
	var b := [float(inner.get("l_m", 0.0)), float(inner.get("w_m", 0.0)), float(inner.get("h_m", 0.0))]
	a.sort()
	b.sort()
	for i in 3:
		if a[i] > b[i] + 1e-6:
			return false
	return true


static func _own_crate(d: Dictionary) -> Dictionary:
	var bare := bool(d.get("no_crate", false))
	var pad := STRAP_GAP_M if bare else CRATE_PAD_M
	var dims := [float(d.get("len_m", 0.1)) + 2.0 * pad,
		float(d.get("w_m", 0.1)) + 2.0 * pad,
		float(d.get("h_m", 0.1)) + 2.0 * pad]
	var each := maxf(float(d.get("mass_kg", 0.0)), 0.0)
	var pack_kg := STRAP_KG if bare else CRATE_KG_M2 * _surface(dims)
	var total := each + pack_kg
	var u := PackedSpec.normalize({
		"w_m": dims[0], "d_m": dims[1], "h_m": dims[2],
		"form": str(d.get("form", "bundle")) if bare else "crate",
		"mass_kg": total, "source": "computed",
		"this_side_up": bool(d.get("this_side_up", false)),
		"stackable": not bool(d.get("fragile", false)),
	})
	var lbl := str(d.get("label", "part"))
	u["label"] = lbl if bare else "Crate: %s" % lbl
	u["parts"] = [{"label": lbl, "qty": 1}]
	u["packaging_kg"] = pack_kg
	u["handling"] = handling_for(total)
	return u


static func _container_unit(cid: String, items: Array) -> Dictionary:
	var spec := ContainerCatalog.packed_spec_for(cid)
	var entry := ContainerCatalog.find(cid)
	var tare := float(entry.get("tare_kg", 0.0))
	var contents := {}
	var mass := 0.0
	for it in items:
		var lbl := str((it as Dictionary).get("label", "part"))
		contents[lbl] = int(contents.get(lbl, 0)) + 1
		mass += maxf(float((it as Dictionary).get("mass_kg", 0.0)), 0.0)
	var u := spec.duplicate(true)
	u["mass_kg"] = mass + tare
	u["source"] = "computed"
	u["label"] = "%s: %s" % [str(entry.get("label", cid)), _contents_text(contents)]
	u["parts"] = _contents_list(contents)
	u["packaging_kg"] = tare
	u["container_id"] = cid
	u["handling"] = handling_for(mass + tare)
	return u


# --- loose hardware --------------------------------------------------------

static func _kit_loose(rows: Array) -> Array:
	var units: Array = []
	var box_vol := float(HARDWARE_BOX["w_m"]) * float(HARDWARE_BOX["d_m"]) \
		* float(HARDWARE_BOX["h_m"]) * float(HARDWARE_BOX["fill"])
	var max_kg := float(HARDWARE_BOX["max_kg"])
	var contents := {}
	var vol := 0.0
	var mass := 0.0
	var sorted := rows.duplicate()
	sorted.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		return str(x.get("label", "")) < str(y.get("label", "")))
	for p in sorted:
		var d: Dictionary = p
		var each_v := maxf(float(d.get("len_m", 0.0)) * float(d.get("w_m", 0.0)) * float(d.get("h_m", 0.0)), 1e-7)
		var each_m := maxf(float(d.get("mass_kg", 0.0)), 0.0)
		var left := int(d.get("qty", 1))
		var lbl := str(d.get("label", "hardware"))
		while left > 0:
			var room_v := int(floor((box_vol - vol) / each_v))
			var room_m := int(floor((max_kg - mass) / each_m)) if each_m > 0.0 else room_v
			var take := mini(left, mini(room_v, room_m))
			if take <= 0:
				if contents.is_empty():
					take = 1
				else:
					units.append(_hardware_box(contents, mass))
					contents = {}
					vol = 0.0
					mass = 0.0
					continue
			contents[lbl] = int(contents.get(lbl, 0)) + take
			vol += each_v * take
			mass += each_m * take
			left -= take
	if not contents.is_empty():
		units.append(_hardware_box(contents, mass))
	return units


static func _hardware_box(contents: Dictionary, mass: float) -> Dictionary:
	var tare := float(HARDWARE_BOX["tare_kg"])
	var u := PackedSpec.normalize({
		"w_m": HARDWARE_BOX["w_m"], "d_m": HARDWARE_BOX["d_m"], "h_m": HARDWARE_BOX["h_m"],
		"form": "crate", "mass_kg": mass + tare, "source": "computed",
	})
	u["label"] = "Hardware: %s" % _contents_text(contents)
	u["parts"] = _contents_list(contents)
	u["packaging_kg"] = tare
	u["handling"] = handling_for(mass + tare)
	return u


# --- summaries -------------------------------------------------------------

## {count, mass_kg, volume_m3, longest_m, handling: {hand, team, forklift}}
static func summary(units: Array) -> Dictionary:
	var out := {"count": units.size(), "mass_kg": 0.0, "volume_m3": 0.0,
		"longest_m": 0.0, "handling": {"hand": 0, "team": 0, "forklift": 0}}
	for u in units:
		var d: Dictionary = u
		var c := maxi(int(d.get("count", 1)), 1)
		out["mass_kg"] = float(out["mass_kg"]) + maxf(float(d.get("mass_kg", 0.0)), 0.0) * c
		out["volume_m3"] = float(out["volume_m3"]) + PackedSpec.volume_m3(d) * c
		out["longest_m"] = maxf(float(out["longest_m"]),
			maxf(float(d.get("w_m", 0.0)), maxf(float(d.get("d_m", 0.0)), float(d.get("h_m", 0.0)))))
		var h := str(d.get("handling", "hand"))
		out["handling"][h] = int(out["handling"].get(h, 0)) + c
	return out


## One PackedSpec standing for the whole kit (for callers that still want a
## single number): the units stacked on the largest footprint at 75 % fill,
## never shorter than its tallest unit; `contains` holds the units.
static func envelope(units: Array, form: String = "crate") -> Dictionary:
	if units.is_empty():
		return {}
	var s := summary(units)
	var l := 0.0
	var w := 0.0
	var tallest := 0.0
	for u in units:
		var d: Dictionary = u
		var dims := [float(d["w_m"]), float(d["d_m"]), float(d["h_m"])]
		dims.sort()
		l = maxf(l, dims[2])
		w = maxf(w, dims[1])
		tallest = maxf(tallest, dims[0])
	var single: bool = units.size() == 1 and int((units[0] as Dictionary).get("qty", 1)) <= 1
	var fill := 1.0 if single else 0.75
	var h := maxf(tallest, float(s["volume_m3"]) / maxf(l * w, 1e-6) / fill)
	var spec := PackedSpec.normalize({
		"w_m": l, "d_m": w, "h_m": h, "form": form,
		"mass_kg": float(s["mass_kg"]), "source": "computed",
		"contains": units,
	})
	spec["units"] = units.size()
	return spec


## The handling units a packed spec ships as: a kit envelope's own units,
## else the spec itself as one unit. Never returns an empty list for a
## non-empty spec.
static func units_of(spec: Dictionary) -> Array:
	if spec.is_empty():
		return []
	var c: Variant = spec.get("contains", [])
	if spec.has("units") and c is Array and not (c as Array).is_empty():
		return (c as Array).duplicate(true)
	return [spec]


static func is_kit(spec: Dictionary) -> bool:
	return spec.has("units") and spec.get("contains", []) is Array \
		and not (spec.get("contains", []) as Array).is_empty()


static func _surface(dims: Array) -> float:
	var a := float(dims[0])
	var b := float(dims[1])
	var c := float(dims[2])
	return 2.0 * (a * b + b * c + a * c)


static func _contents_list(contents: Dictionary) -> Array:
	var keys := contents.keys()
	keys.sort()
	var out: Array = []
	for k in keys:
		out.append({"label": str(k), "qty": int(contents[k])})
	return out


static func _contents_text(contents: Dictionary) -> String:
	var keys := contents.keys()
	keys.sort()
	var bits: PackedStringArray = []
	for k in keys:
		bits.append("%d × %s" % [int(contents[k]), str(k)])
	if bits.size() > 3:
		return "%s + %s" % [", ".join(bits.slice(0, 3)), UiText.count(bits.size() - 3, "more line")]
	return ", ".join(bits)
