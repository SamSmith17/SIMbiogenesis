class_name FabContextRig
extends RefCounted
## The canonical WORK a fabrication clip is authored against: a bench, a beam,
## a post, a carried beam — and where the tool (or the carried part) is at
## each moment of the op. The animation editor plays a clip in this context
## so the author sees the figure actually sawing / drilling / driving; the
## swarm (B4/B5) uses real plans with the SAME op timing (LinkageBuildOps), so
## what is authored here is what is played there.
##
## Figure at the origin, facing +Z, in metres. Bench-frame plans
## (LinkageBuildOps, inches) are mapped by `bench_to_world`: bench X (along
## the beam) -> world X, bench Z (across it) -> world +Z (away from the
## worker), bench Y -> up, bench top at BENCH_TOP_M.

const KINDS := ["none", "cut", "drill", "fasten", "place", "carry", "lift",
	"chop", "stir", "plate", "wash", "carry_pot", "carry_crate"]
const IN_TO_M := 0.0254
const BENCH_TOP_M := 0.8
## The clip a context is authored for (the editor's default pairing).
const CLIP_FOR := {"cut": "saw_cut", "drill": "drill_hole", "fasten": "fasten_bolt",
	"place": "place_beam", "carry": "carry_beam", "lift": "lift_ring",
	"chop": "chop", "stir": "stir_pot", "plate": "plate_up", "wash": "wash_dishes",
	"carry_pot": "carry_pot", "carry_crate": "carry_pot"}
## The kitchen (MealJobPlan): a counter 0.9 m high whose near edge is 0.2 m in
## front of the cook; the same in CampKitchenBuilder.
const COUNTER_TOP_M := 0.9
const KITCHEN_TOOL := {"chop": "knife", "stir": "ladle", "plate": "ladle", "wash": "sponge",
	"carry_pot": "pot", "carry_crate": "crate"}


## {kind, tool_id ("" = a carried beam), plan (LinkageBuildOps plan for cut /
## drill), bench: Transform3D (bench frame inches -> world metres),
## workpieces: [{size: Vector3 m, xform: Transform3D, color}]}.
static func setup(kind: String) -> Dictionary:
	var rig := {"kind": kind, "tool_id": "", "plan": {}, "bench": Transform3D(), "workpieces": []}
	match kind:
		"cut":
			rig["tool_id"] = "circular_saw"
			var g := _group(84.0, 3.5, 1.5, [])
			var plan := LinkageBuildSteps.plan_bench([g], {"stock": true})
			var item: Dictionary = plan["items"][0]
			rig["plan"] = {"kind": "cut", "rows": plan["items"], "bench": plan, "kerf": 0.125,
				"saw_radius": clampf(float(item["t"]) + 0.75, 2.25, 4.5)}
			# The cut line just left of the worker's centre, the stock's near
			# edge 0.32 m in front.
			rig["bench"] = _bench_xf(-float(item["cutAt"]) * IN_TO_M - 0.04, 0.32)
			_add_bench(rig)
			_add_bench_beam(rig, item, float(item["stockLength"]))
		"drill":
			rig["tool_id"] = "drill"
			# Holes within both hands' reach of a worker at the bench centre.
			var holes := [_hole(-6.0), _hole(0.0), _hole(6.0)]
			var g2 := _group(60.0, 3.5, 1.5, holes)
			var plan2 := LinkageBuildSteps.plan_bench([g2], {"stock": false})
			var jobs: Array = []
			for hi in holes.size():
				jobs.append({"row": 0, "hole": hi})
			rig["plan"] = {"kind": "drill", "rows": plan2["items"], "bench": plan2, "jobs": jobs,
				"bit_diameter": 0.5, "bit_length": 1.5 + 2.5}
			rig["bench"] = _bench_xf(-30.0 * IN_TO_M, 0.30)
			_add_bench(rig)
			_add_bench_beam(rig, plan2["items"][0], 60.0)
		"fasten":
			rig["tool_id"] = "impact_driver"
			# A post in front at chest height; the bolt goes in along +Z.
			rig["workpieces"].append({"size": Vector3(0.089, 1.6, 0.089), "color": Color(0.8, 0.65, 0.45),
				"xform": Transform3D(Basis(), Vector3(-0.1, 0.8, 0.5))})
		"place", "carry", "lift":
			rig["workpieces"] = []
		"chop", "stir", "plate", "wash":
			rig["tool_id"] = str(KITCHEN_TOOL[kind])
			# The counter (or the stove / basins / serving table) in front.
			rig["workpieces"].append({"size": Vector3(1.2, COUNTER_TOP_M, 0.6), "color": Color(0.45, 0.38, 0.3),
				"xform": Transform3D(Basis(), Vector3(0.0, COUNTER_TOP_M / 2.0 - 0.002, 0.5))})
			if kind == "chop":
				rig["workpieces"].append({"size": Vector3(0.4, 0.025, 0.28), "color": Color(0.78, 0.62, 0.42),
					"xform": Transform3D(Basis(), Vector3(-0.04, COUNTER_TOP_M + 0.0125, 0.38))})
			elif kind == "stir" or kind == "plate":
				rig["workpieces"].append({"size": Vector3(0.32, 0.18, 0.32), "color": Color(0.55, 0.57, 0.6),
					"xform": Transform3D(Basis(), Vector3(-0.2 if kind == "plate" else 0.0, COUNTER_TOP_M + 0.09, 0.42))})
			elif kind == "wash":
				rig["workpieces"].append({"size": Vector3(0.45, 0.02, 0.35), "color": Color(0.35, 0.5, 0.6),
					"xform": Transform3D(Basis(), Vector3(0.0, COUNTER_TOP_M - 0.08, 0.42))})
		"carry_pot", "carry_crate":
			rig["tool_id"] = str(KITCHEN_TOOL[kind])
	return rig


static func _group(length: float, w: float, t: float, holes: Array) -> Dictionary:
	return {"key": "ctx", "length": length, "w": w, "t": t, "count": 1, "beams": [],
		"rep": {}, "stackTypes": ["vertical"], "holes": holes}


static func _hole(pos_l: float) -> Dictionary:
	return {"pos_l": pos_l, "pos_w": 0.0, "pos_t": 0.0, "radius": 0.25, "through": "T"}


static func _bench_xf(x_m: float, z_m: float) -> Transform3D:
	return Transform3D(Basis().scaled(Vector3.ONE * IN_TO_M), Vector3(x_m, BENCH_TOP_M, z_m))


static func _add_bench(rig: Dictionary) -> void:
	rig["workpieces"].append({"size": Vector3(1.6, BENCH_TOP_M, 0.6), "color": Color(0.33, 0.29, 0.24),
		"xform": Transform3D(Basis(), Vector3(0.0, BENCH_TOP_M / 2.0 - 0.002, 0.55))})


static func _add_bench_beam(rig: Dictionary, item: Dictionary, length_in: float) -> void:
	var b: Transform3D = rig["bench"]
	var centre := b * Vector3(float(item["x0"]) + length_in / 2.0, float(item["t"]) / 2.0, float(item["z"]))
	rig["workpieces"].append({"size": Vector3(length_in, float(item["t"]), float(item["w"])) * IN_TO_M,
		"color": Color(0.86, 0.7, 0.5), "xform": Transform3D(Basis(), centre)})


## A carried beam's grip sockets (FabToolCatalog hand frame), part-local metres.
static func beam_sockets() -> Dictionary:
	var hb := FabToolCatalog.hand_basis(Vector3(1, 0, 0), Vector3(0, 0.35, -1))
	return {"grip": Transform3D(hb, Vector3(-0.32, 0, 0)), "grip2": Transform3D(hb, Vector3(0.32, 0, 0))}


## Where the tool (or carried beam) is at progress u in [0, 1]: {xform:
## Transform3D (world, metres), spin: float (radians about the spin axis),
## visible: bool}.
static func tool_at(rig: Dictionary, u: float) -> Dictionary:
	var b: Transform3D = rig.get("bench", Transform3D())
	match str(rig.get("kind", "")):
		"cut":
			var c := LinkageBuildOps.cut_at(rig["plan"], u)
			return {"xform": Transform3D(Basis(), b * (c["tool"]["pos"] as Vector3)),
				"spin": float(c["tool"]["blade_angle"]), "visible": true}
		"drill":
			var d := LinkageBuildOps.drill_at(rig["plan"], u)
			return {"xform": Transform3D(Basis(Vector3.UP, PI), b * (d["tool"]["tip"] as Vector3)),
				"spin": float(d["tool"]["bit_angle"]), "visible": true}
		"fasten":
			# LinkageBuildOps fasten: back out 0.8 x a 3 in bolt, three turns in.
			var e := LinkageBuildSteps.ease_in_out_cubic(u)
			var seat := Vector3(-0.1, 1.12, 0.5 - 0.0445)
			var travel := maxf(1.0, 3.0 * 0.8) * IN_TO_M
			return {"xform": Transform3D(Basis(Vector3(1, 0, 0), -PI / 2.0), seat - Vector3(0, 0, 1) * travel * (1.0 - e)),
				"spin": 3.0 * TAU * (1.0 - e), "visible": true}
		"place":
			# LinkageBuildOps place: in from above, 24 in, eased.
			var e2 := LinkageBuildSteps.ease_in_out_cubic(u)
			# Seated on a 0.72 m rail: within a crouching worker's reach.
			return {"xform": Transform3D(Basis(), Vector3(0.0, 0.72, 0.45) + Vector3.UP * 24.0 * IN_TO_M * (1.0 - e2)),
				"spin": 0.0, "visible": true}
		"carry":
			return {"xform": Transform3D(Basis(), Vector3(0.0, 0.95, 0.32)), "spin": 0.0, "visible": true}
		"chop":
			# Three chops a cycle along the board, the blade lifting off it.
			var lift := 0.06 * absf(sin(u * TAU * 3.0))
			return {"xform": Transform3D(Basis(), Vector3(-0.06 + 0.06 * u, COUNTER_TOP_M + 0.03 + lift, 0.4)),
				"spin": 0.0, "visible": true}
		"stir":
			var a := u * TAU
			return {"xform": Transform3D(Basis(), Vector3(0.07 * cos(a), COUNTER_TOP_M + 0.06, 0.42 + 0.07 * sin(a))),
				"spin": 0.0, "visible": true}
		"plate":
			# From the pot (left) to the plate (right) and back, over the rim.
			var e := 0.5 - 0.5 * cos(u * TAU)
			return {"xform": Transform3D(Basis(), Vector3(lerpf(-0.2, 0.18, e), COUNTER_TOP_M + 0.07 + 0.08 * sin(e * PI), 0.4)),
				"spin": 0.0, "visible": true}
		"wash":
			var a2 := u * TAU * 2.0
			return {"xform": Transform3D(Basis(), Vector3(0.08 * cos(a2), COUNTER_TOP_M - 0.02, 0.4 + 0.05 * sin(a2))),
				"spin": 0.0, "visible": true}
		"carry_pot":
			return {"xform": Transform3D(Basis(), Vector3(0.0, 0.86, 0.3)), "spin": 0.0, "visible": true}
		"carry_crate":
			return {"xform": Transform3D(Basis(), Vector3(0.0, 0.84, 0.32)), "spin": 0.0, "visible": true}
		"lift":
			var e3 := LinkageBuildSteps.ease_in_out_cubic(u)
			return {"xform": Transform3D(Basis(), Vector3(0.0, lerpf(0.55, 1.92, e3), lerpf(0.42, 0.15, e3))),
				"spin": 0.0, "visible": true}
	return {"xform": Transform3D(), "spin": 0.0, "visible": false}
