class_name WasteBinBuilder
extends RefCounted
## The typed waste bin a store's packaging visibly fills (plans/
## FOOD_WASTE_REALISM_PLAN.md Phase 8): an open-top enclosure whose
## interior piles up with REAL bottle / can / box meshes (WasteItemMeshes)
## driven by the bound store's item ledger — WasteBinRuntime polls the
## counts and writes the MultiMesh transforms; this file owns the shell
## and the PURE pile layout, so the selftest proves determinism and the
## volume honesty analytically.
##
## `bin_spec` on the record: {style: "bin"|"bay", kind: <waste kind>,
## capacity_l}. The pile height maps the LEDGER's loose litres
## (PackagingArchetypes loose_l) onto the interior: at capacity_l the pile
## reaches the rim; past it, items heap above the rim (the overfull cue).

const MODEL_ID := "waste_bin"

const STYLES := {
	# A 360 L wheelie-class bin (0.66 x 0.78 plan, 1.0 m rim).
	"bin": {"w": 0.66, "d": 0.78, "h": 1.0, "wall_t": 0.025, "capacity_l": 360.0},
	# An open sorting bay (concrete-block walls, the yard look).
	"bay": {"w": 2.4, "d": 2.4, "h": 1.2, "wall_t": 0.09, "capacity_l": 4000.0},
}

## The graph store a placed bin binds to, kg by kind — the Phase 4 bin
## presets' own capacities, so a placed bin and a graph-placed bin agree.
const KIND_CAPACITY_KG := {
	"pet_waste": 40.0, "hdpe_waste": 40.0, "film_waste": 25.0,
	"mixed_plastic_waste": 50.0, "alu_waste": 40.0, "steel_waste": 80.0,
	"glass_waste": 150.0, "cardboard_waste": 60.0, "paper_waste": 40.0,
	"cullet": 300.0,
}

## Elongated items lie on their SIDE in a bin; flat things lie flat.
const _LYING := ["pet_bottle", "pet_bottle_large", "hdpe_bottle", "alu_can",
	"steel_can", "steel_can_large", "glass_bottle", "carton"]

## Visual budget per mesh family per bin (the pile is a jumble; past this
## the extra items still raise the pile but draw no new instance).
const MAX_PER_MESH := 256


static func resolve(spec: Dictionary) -> Dictionary:
	var style := str(spec.get("style", "bin"))
	if not STYLES.has(style):
		style = "bin"
	var base: Dictionary = STYLES[style]
	return {
		"style": style,
		"kind": ResourceKinds.normalize_kind(str(spec.get("kind", "pet_waste"))),
		"w": float(base["w"]), "d": float(base["d"]), "h": float(base["h"]),
		"wall_t": float(base["wall_t"]),
		"capacity_l": maxf(float(spec.get("capacity_l", base["capacity_l"])), 10.0),
	}


## The interior frame the layout and the runtime share: local metres,
## origin at the bin's plan centre on the ground.
static func interior(r: Dictionary) -> Dictionary:
	var t := float(r["wall_t"])
	return {"w": float(r["w"]) - 2.0 * t, "d": float(r["d"]) - 2.0 * t,
		"floor_y": t, "rim_y": float(r["h"])}


static func build_node(spec: Dictionary, node_name: String = "WasteBin") -> Node3D:
	var r := resolve(spec)
	var root := Node3D.new()
	root.name = node_name
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w: float = r["w"]
	var d: float = r["d"]
	var h: float = r["h"]
	var t: float = r["wall_t"]
	# Floor + four walls (open top), boxes composited the winding-safe way.
	_part(st, Vector3(w, t, d), Vector3(0, t * 0.5, 0))
	_part(st, Vector3(w, h, t), Vector3(0, h * 0.5, -(d - t) * 0.5))
	_part(st, Vector3(w, h, t), Vector3(0, h * 0.5, (d - t) * 0.5))
	_part(st, Vector3(t, h, d - 2.0 * t), Vector3(-(w - t) * 0.5, h * 0.5, 0))
	_part(st, Vector3(t, h, d - 2.0 * t), Vector3((w - t) * 0.5, h * 0.5, 0))
	# A rim lip FRAME over the wall tops (never one covering slab — that
	# reads as a closed lid and hides the whole pile), so the opening reads.
	_part(st, Vector3(w + 0.05, 0.03, t + 0.05), Vector3(0, h + 0.015, -(d - t) * 0.5))
	_part(st, Vector3(w + 0.05, 0.03, t + 0.05), Vector3(0, h + 0.015, (d - t) * 0.5))
	_part(st, Vector3(t + 0.05, 0.03, d + 0.05), Vector3(-(w - t) * 0.5, h + 0.015, 0))
	_part(st, Vector3(t + 0.05, 0.03, d + 0.05), Vector3((w - t) * 0.5, h + 0.015, 0))
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	var kind_col := ResourceKinds.wire_color(str(r["kind"]))
	mat.albedo_color = Color(0.16, 0.17, 0.18).lerp(kind_col, 0.35)
	mat.roughness = 0.85
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	root.add_child(mi)
	# A kind stripe round the walls, in the resource's own colour. A HOLLOW
	# band of four thin boxes — a single BoxMesh spanning the plan caps the
	# opening from above like a lid and hides the whole pile (found by the
	# render probe: the pile drew fine, UNDER the stripe's top face).
	var stripe := MeshInstance3D.new()
	stripe.name = "Stripe"
	var ss := SurfaceTool.new()
	ss.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bt := 0.012   # how proud of the wall the band stands
	_part(ss, Vector3(w + bt * 2.0, 0.08, bt), Vector3(0, 0, -(d + bt) * 0.5))
	_part(ss, Vector3(w + bt * 2.0, 0.08, bt), Vector3(0, 0, (d + bt) * 0.5))
	_part(ss, Vector3(bt, 0.08, d + bt * 2.0), Vector3(-(w + bt) * 0.5, 0, 0))
	_part(ss, Vector3(bt, 0.08, d + bt * 2.0), Vector3((w + bt) * 0.5, 0, 0))
	var smesh := ss.commit()
	var sm := StandardMaterial3D.new()
	sm.albedo_color = kind_col
	sm.roughness = 0.6
	smesh.surface_set_material(0, sm)
	stripe.mesh = smesh
	stripe.position = Vector3(0, h - 0.08, 0)
	stripe.set_meta("skip_prop_collision", true)
	root.add_child(stripe)
	var piles := Node3D.new()
	piles.name = "Piles"
	root.add_child(piles)
	root.set_meta("bin_resolved", r)
	root.set_meta("bin_interior", interior(r))
	return root


static func _part(st: SurfaceTool, size: Vector3, at: Vector3) -> void:
	var b := BoxMesh.new()
	b.size = size
	st.append_from(b, 0, Transform3D(Basis.IDENTITY, at))


## --- the pile, pure ---------------------------------------------------------

## counts ({archetype_id: n}, insertion-ordered: the ledger's arrival
## order) -> one placed item per piece: [{mesh_id, xform, over_rim}].
## Deterministic in (store_id, counts, interior, capacity_l): the same
## ledger always draws the same pile, which is what makes a scrub back
## simply lower it. The pile height maps cumulative LOOSE litres onto the
## interior height (capacity_l reaches the rim); an item's BASE stays
## below the rim while the bin is within capacity (the volume-honesty
## property the selftest pins), past it the heap climbs above the rim.
static func layout(store_id: String, counts: Dictionary, inter: Dictionary,
		capacity_l: float) -> Array:
	var out: Array = []
	var w := float(inter.get("w", 0.6))
	var d := float(inter.get("d", 0.6))
	var floor_y := float(inter.get("floor_y", 0.02))
	var rim_y := float(inter.get("rim_y", 1.0))
	var h_cap := maxf(rim_y - floor_y, 0.1)
	var per_l := h_cap / maxf(capacity_l, 1.0)
	var v := 0.0
	for aid in counts:
		var a := str(aid)
		var mesh_id := PackagingArchetypes.mesh_id(a)
		if mesh_id.is_empty():
			mesh_id = a if WasteItemMeshes.ids().has(a) else "plastic_tub"
		var litres := maxf(PackagingArchetypes.loose_l(a), 0.05)
		var half := WasteItemMeshes.half_h(mesh_id)
		var lying := _LYING.has(mesh_id)
		var n := int(counts[aid])
		for k in n:
			var key := "%s|%s|%d" % [store_id, a, k]
			var u1 := NpcHash.unit01(key, "x")
			var u2 := NpcHash.unit01(key, "z")
			var u3 := NpcHash.unit01(key, "yaw")
			var u4 := NpcHash.unit01(key, "roll")
			var y := floor_y + half + v * per_l
			var margin := minf(0.1 + half, w * 0.45)
			var pos := Vector3((u1 - 0.5) * (w - 2.0 * margin),
				y, (u2 - 0.5) * (d - 2.0 * margin))
			var basis := Basis(Vector3.UP, u3 * TAU)
			if lying:
				basis = basis * Basis(Vector3.FORWARD, PI * 0.5 + (u4 - 0.5) * 0.5)
			else:
				basis = basis * Basis(Vector3.FORWARD, (u4 - 0.5) * 0.4)
			out.append({"mesh_id": mesh_id,
				"xform": Transform3D(basis, pos),
				"over_rim": v > capacity_l})
			v += litres
	return out


## Fallback counts for a store with kg but no item ledger (an old save, a
## bulk-mode unpack): the bin's kind drawn as its representative archetype.
static func counts_from_kg(kind: String, kg: float) -> Dictionary:
	if kg <= 0.001:
		return {}
	var rep := ""
	for aid in PackagingArchetypes.ids():
		if PackagingArchetypes.waste_kind(aid) == kind:
			rep = aid
			break
	if rep.is_empty():
		return {}
	var n := int(floor(kg * 1000.0 / maxf(PackagingArchetypes.mass_g(rep), 1.0)))
	return {rep: n} if n > 0 else {}
