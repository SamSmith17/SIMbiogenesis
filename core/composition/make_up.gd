class_name MakeUp
extends RefCounted

## What a kg of something holds, as it really is: a tank's own make-up once
## things mix in it, a machine's outputs following its inputs (resource
## composition plan Phase 10). Pure.
##
## A make-up is {water, C, N, P, K}: kg per kg of the stuff (the water in
## it and the four elements the ledger reports). Everything else (O, H …)
## stays the kind's own (CompositionCatalog).
##
##   of_kind(kind)               the kind's own make-up (CompositionData)
##   mix(a, kg_a, b, kg_b)       mass-weighted mix
##   derive_outputs(ins, outs)   a machine's outputs from its inputs:
##        ins  [{kind, kg_h, make_up}]  (make_up {} = the kind's own)
##        outs [{kind, kg_h}]
##      → [make_up per output]. For C, N, P and K each output carries what
##      came in, split as the design splits it and never more than came in
##      (a static design that "creates" an element — a shared make-up that
##      does not fit this feed — conserves here). Water scales with the
##      water coming in, as designed (reactions may make water).
##   embodied(kind, qty, mu)     CompositionCatalog.embodied with the
##                               tracked parts replaced
##   grade_of(mu, kind)          the water grade it would read as (the kind's)
##   same(a, b)                  equal within rounding

const KEYS := ["water", "C", "N", "P", "K"]
const ELEMENTS := ["C", "N", "P", "K"]
const EPS := 1e-12


static func of_kind(kind: String) -> Dictionary:
	var k := CompositionCatalog.canonical(ResourceKinds.normalize_kind(kind))
	var el: Dictionary = CompositionCatalog.elements_of(k)
	var out := {"water": CompositionCatalog.water_fraction(k)}
	for e in ELEMENTS:
		out[e] = float(el.get(e, 0.0))
	return out


static func mix(a: Dictionary, kg_a: float, b: Dictionary, kg_b: float) -> Dictionary:
	var t := maxf(kg_a, 0.0) + maxf(kg_b, 0.0)
	if t <= EPS:
		return a.duplicate() if not a.is_empty() else b.duplicate()
	var out: Dictionary = {}
	for q in KEYS:
		out[q] = (float(a.get(q, 0.0)) * maxf(kg_a, 0.0) + float(b.get(q, 0.0)) * maxf(kg_b, 0.0)) / t
	return out


static func derive_outputs(ins: Array, outs: Array) -> Array:
	var s_in: Dictionary = {}
	var a_in: Dictionary = {}
	for q in KEYS:
		s_in[q] = 0.0
		a_in[q] = 0.0
	for i in ins:
		var d: Dictionary = i
		var kg := maxf(float(d.get("kg_h", 0.0)), 0.0)
		var st := of_kind(str(d.get("kind", "")))
		var mu: Dictionary = d.get("make_up", {}) if d.get("make_up") is Dictionary else {}
		if mu.is_empty():
			mu = st
		for q in KEYS:
			s_in[q] = float(s_in[q]) + kg * float(st.get(q, 0.0))
			a_in[q] = float(a_in[q]) + kg * float(mu.get(q, 0.0))
	var s_k: Array = []
	var s_out: Dictionary = {}
	for q in KEYS:
		s_out[q] = 0.0
	for o in outs:
		var d2: Dictionary = o
		var kg2 := maxf(float(d2.get("kg_h", 0.0)), 0.0)
		var st2 := of_kind(str(d2.get("kind", "")))
		var row: Dictionary = {}
		for q in KEYS:
			row[q] = kg2 * float(st2.get(q, 0.0))
			s_out[q] = float(s_out[q]) + float(row[q])
		s_k.append(row)
	var total: Dictionary = {}
	for q in KEYS:
		var si := float(s_in[q])
		var so := float(s_out[q])
		var ai := float(a_in[q])
		if q == "water":
			total[q] = so * (ai / si) if si > EPS else so
		else:
			var t := so * (ai / si) if si > EPS else 0.0
			total[q] = minf(t, ai)
	var res: Array = []
	for j in outs.size():
		var kg3 := maxf(float((outs[j] as Dictionary).get("kg_h", 0.0)), 0.0)
		var mu2: Dictionary = {}
		for q in KEYS:
			var share := float(s_k[j][q]) / float(s_out[q]) if float(s_out[q]) > EPS else 0.0
			# A fraction of a kg never passes 1 (a far richer feed than the
			# design's makes more product, which this model does not size).
			mu2[q] = clampf(float(total[q]) * share / kg3, 0.0, 1.0) if kg3 > EPS else 0.0
		res.append(mu2)
	return res


## The kind's embodied() with its water and C N P K taken from `mu`.
static func embodied(kind: String, qty: float, mu: Dictionary) -> Dictionary:
	var emb := CompositionCatalog.embodied(kind, qty)
	if mu.is_empty() or not bool(emb.get("known", false)):
		return emb
	var kg := float(emb.get("kg", 0.0))
	emb["water_kg"] = kg * float(mu.get("water", 0.0))
	var el: Dictionary = (emb.get("elements", {}) as Dictionary).duplicate()
	for e in ELEMENTS:
		el[e] = kg * float(mu.get(e, 0.0))
	emb["elements"] = el
	return emb


static func same(a: Dictionary, b: Dictionary, rel: float = 1e-6) -> bool:
	for q in KEYS:
		var x := float(a.get(q, 0.0))
		var y := float(b.get(q, 0.0))
		if absf(x - y) > rel * maxf(maxf(absf(x), absf(y)), 1e-9):
			return false
	return true


## Rounded for storage on a tank's specs (6 significant figures).
static func rounded(mu: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for q in KEYS:
		var v := float(mu.get(q, 0.0))
		out[q] = snappedf(v, pow(10.0, floorf(log(maxf(absf(v), 1e-30)) / log(10.0)) - 5.0)) if v != 0.0 else 0.0
	return out


# --- water grades (Phase 10) -------------------------------------------------

## Whether `src` water may feed something that wants `need`: any water at or
## above the grade it asks for. Not water, or no grade: true (not a grade
## question).
static func grade_ok(src: String, need: String) -> bool:
	var a := CompositionCatalog.canonical(ResourceKinds.normalize_kind(src))
	var b := CompositionCatalog.canonical(ResourceKinds.normalize_kind(need))
	if CompositionCatalog.family_of(a) != "water" or CompositionCatalog.family_of(b) != "water":
		return true
	var ga := CompositionCatalog.grade_of(a)
	var gb := CompositionCatalog.grade_of(b)
	if ga < 0 or gb < 0:
		return true
	return ga >= gb


## "Greywater is grade 2 (greywater); this takes grade 5 (drinking): clean
## it on the way." "" when the grade is fine.
static func grade_warning(src: String, need: String) -> String:
	if grade_ok(src, need):
		return ""
	var a := CompositionCatalog.canonical(ResourceKinds.normalize_kind(src))
	var b := CompositionCatalog.canonical(ResourceKinds.normalize_kind(need))
	var ga := CompositionCatalog.grade_of(a)
	var gb := CompositionCatalog.grade_of(b)
	return "%s is grade %d (%s); this takes grade %d (%s): clean it on the way." % [
		ResourceKinds.display_name(a), ga, str(CompositionData.GRADES.get(ga, "")),
		gb, str(CompositionData.GRADES.get(gb, ""))]
