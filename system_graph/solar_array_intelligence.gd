class_name SolarArrayIntelligence
extends RefCounted

## Voc-aware topology + controller ranking for OSM / compound solar arrays.


## Best series×parallel layout that fits as many panels as possible under max_voc.
## Prefers longer series strings (better MPPT utilization) when Voc headroom allows,
## and clean divisors when available.
static func best_series_parallel(panel_count: int, panel_voc: float,
		max_voc: float) -> Dictionary:
	var out := {
		"series": 1,
		"parallel": 1,
		"fitted": 0,
		"equiv_voc": 0.0,
		"array_topology": "—",
		"wire_mode": "parallel",  # how the array node attaches to the controller
	}
	if panel_count <= 0 or panel_voc <= 0.0:
		return out
	if panel_voc > max_voc + 0.5:
		out["equiv_voc"] = panel_voc
		out["array_topology"] = "Voc exceeds controller"
		return out
	var max_s := maxi(1, int(floor((max_voc + 1e-6) / panel_voc)))
	max_s = mini(max_s, panel_count)
	var best_s := 1
	# Prefer the longest series that divides the count cleanly; else longest allowed.
	for try_s in range(max_s, 0, -1):
		if panel_count % try_s == 0:
			best_s = try_s
			break
	if best_s == 1 and max_s > 1:
		best_s = max_s
	var parallel := int(ceil(float(panel_count) / float(best_s)))
	out["series"] = best_s
	out["parallel"] = maxi(1, parallel)
	out["fitted"] = panel_count
	out["equiv_voc"] = float(best_s) * panel_voc
	out["array_topology"] = "%dS x %dP" % [best_s, out["parallel"]]
	# Single compound node → always one PV feed; topology is encoded in specs.
	# wire_mode hints UI: high series reads as series-configured; 1S as parallel.
	out["wire_mode"] = "series" if best_s > 1 else "parallel"
	return out


## Build electrical equivalent specs for an array compound from per-panel values.
static func build_array_equiv_specs(panel_count: int, panel_watts: float,
		panel_voc: float, panel_vmp: float, panel_imp: float, panel_isc: float,
		topo: Dictionary) -> Dictionary:
	var series := maxi(1, int(topo.get("series", 1)))
	var parallel := maxi(1, int(topo.get("parallel", 1)))
	var units := maxi(0, panel_count)
	return {
		"array_series": series,
		"array_parallel": parallel,
		"array_branches": parallel,
		"array_panel_units": units,
		"array_topology": str(topo.get("array_topology", "%dS x %dP" % [series, parallel])),
		"array_mixed_voltage": false,
		"array_equiv_wmp": panel_watts * float(units),
		"array_equiv_vmp": panel_vmp * float(series),
		"array_equiv_voc": panel_voc * float(series),
		"array_equiv_imp": panel_imp * float(parallel),
		"array_equiv_isc": panel_isc * float(parallel),
	}


## Score controllers for an array at canvas position `anchor`. Higher is better.
## Returns [{id, label, score, max_voc, distance, topo, fits, preset_idx}, ...]
## Controllers already on the canvas come first; preset_idx >= 0 means a library
## recommendation (not yet placed). `preset_idx` is into ComponentPresets.CONTROLLERS.
static func rank_controllers(model: GraphModel, anchor: Vector2,
		panel_count: int, panel_voc: float, panel_watts: float,
		scope_id: String = "root") -> Array:
	var ranked: Array = []
	if model == null:
		return ranked
	var array_watts := float(panel_count) * panel_watts
	for item in model.get_items_in_scope(scope_id):
		if not (item is Dictionary):
			continue
		var it: Dictionary = item
		if str(it.get("type", "")) != "controller":
			continue
		if bool(it.get("is_virtual", false)):
			continue
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		if bool(sp.get("destroyed", false)):
			continue
		var max_voc := float(sp.get("max_voc", 150.0))
		var max_pv := float(sp.get("max_pv_watts", 0.0))
		var px := float(it.get("x", 0.0)) + float(it.get("width", 140.0)) * 0.5
		var py := float(it.get("y", 0.0)) + float(it.get("height", 120.0)) * 0.5
		var dist := Vector2(px, py).distance_to(anchor)
		var topo := best_series_parallel(panel_count, panel_voc, max_voc)
		var fits := int(topo.get("fitted", 0)) >= panel_count and panel_voc <= max_voc + 0.5
		var score := _score_controller(fits, max_voc, float(topo.get("equiv_voc", 0.0)),
				max_pv, array_watts, dist, true)
		ranked.append({
			"id": str(it.get("id", "")),
			"label": str(sp.get("name", "Controller")),
			"score": score,
			"max_voc": max_voc,
			"max_pv_watts": max_pv,
			"distance": dist,
			"topo": topo,
			"fits": fits,
			"preset_idx": -1,
			"on_canvas": true,
		})
	# Also suggest library presets (always available for "place new").
	var presets: Array = ComponentPresets.CONTROLLERS
	for i in presets.size():
		var p: Dictionary = presets[i]
		var psp: Dictionary = p.get("specs", {}) as Dictionary
		var max_voc := float(psp.get("max_voc", 150.0))
		var max_pv := float(psp.get("max_pv_watts", 0.0))
		var topo := best_series_parallel(panel_count, panel_voc, max_voc)
		var fits := int(topo.get("fitted", 0)) >= panel_count and panel_voc <= max_voc + 0.5
		var score := _score_controller(fits, max_voc, float(topo.get("equiv_voc", 0.0)),
				max_pv, array_watts, 240.0, false)
		ranked.append({
			"id": "",
			"label": str(p.get("label", psp.get("name", "Controller"))),
			"score": score,
			"max_voc": max_voc,
			"max_pv_watts": max_pv,
			"distance": INF,
			"topo": topo,
			"fits": fits,
			"preset_idx": i,
			"on_canvas": false,
		})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("score", 0.0)) > float(b.get("score", 0.0))
	)
	return ranked


static func _score_controller(fits: bool, max_voc: float, equiv_voc: float,
		max_pv: float, array_watts: float, dist: float, on_canvas: bool) -> float:
	var score := 0.0
	if fits:
		score += 1000.0
		# Prefer snug Voc headroom (10–40%) over massive overspec.
		if equiv_voc > 0.0 and max_voc > 0.0:
			var headroom := (max_voc - equiv_voc) / max_voc
			score += 120.0 * (1.0 - clampf(absf(headroom - 0.2) / 0.5, 0.0, 1.0))
	else:
		score -= 500.0
		score -= maxf(0.0, equiv_voc - max_voc)
	if max_pv > 0.0:
		if array_watts <= max_pv:
			var util := array_watts / max_pv
			score += 80.0 * clampf(util, 0.0, 1.0)
		else:
			score -= (array_watts - max_pv) / 50.0
	if on_canvas:
		score += 40.0
		score -= minf(dist, 2000.0) / 20.0
	else:
		score -= 15.0  # slight preference for existing canvas controllers
	return score


## Recommend the best ComponentPresets controller for a brand-new install.
static func recommend_controller_preset(panel_count: int, panel_voc: float,
		panel_watts: float) -> Dictionary:
	var best: Dictionary = {}
	var best_score := -INF
	var array_watts := float(panel_count) * panel_watts
	for i in ComponentPresets.CONTROLLERS.size():
		var p: Dictionary = ComponentPresets.CONTROLLERS[i]
		var psp: Dictionary = p.get("specs", {}) as Dictionary
		var max_voc := float(psp.get("max_voc", 150.0))
		var max_pv := float(psp.get("max_pv_watts", 0.0))
		var topo := best_series_parallel(panel_count, panel_voc, max_voc)
		var fits := int(topo.get("fitted", 0)) >= panel_count and panel_voc <= max_voc + 0.5
		var score := _score_controller(fits, max_voc, float(topo.get("equiv_voc", 0.0)),
				max_pv, array_watts, 240.0, false)
		if score > best_score:
			best_score = score
			best = p.duplicate(true)
			best["preset_idx"] = i
			best["topo"] = topo
			best["score"] = score
	return best


## Wire a single PV-source item (panel or array compound) to a controller.
static func wire_array_to_controller(model: GraphModel, array_id: String,
		controller_id: String, scope_id: String = "root") -> void:
	if model == null or array_id.is_empty() or controller_id.is_empty():
		return
	# Drop prior PV edges from this array so re-import / re-pick is idempotent.
	var stale: Array = []
	for conn in model.get_connections_in_scope(scope_id):
		if not (conn is Dictionary):
			continue
		var c: Dictionary = conn
		var sid := str(c.get("source_item_id", ""))
		var tid := str(c.get("target_item_id", ""))
		if sid != array_id and tid != array_id:
			continue
		var pol := str(c.get("polarity", ""))
		if pol in ["positive", "negative", "pvPositive", "pvNegative"]:
			stale.append(str(c.get("id", "")))
	for cid in stale:
		if not str(cid).is_empty():
			model.remove_connection(str(cid))
	GraphPvWiring.wire_parallel(model, [array_id], controller_id, scope_id)


## Place a controller preset next to `anchor` and return its new item id.
static func place_controller_preset(model: GraphModel, preset: Dictionary,
		anchor: Vector2, scope_id: String = "root") -> String:
	if model == null or preset.is_empty():
		return ""
	var specs: Dictionary = (preset.get("specs", {}) as Dictionary).duplicate(true)
	var w := float(preset.get("width", 140.0))
	var h := float(preset.get("height", 120.0))
	var item := {
		"id": model.generate_item_id(),
		"type": "controller",
		"x": anchor.x + 220.0,
		"y": anchor.y - h * 0.5,
		"width": w,
		"height": h,
		"scope_id": scope_id,
		"is_virtual": false,
		"specs": specs,
	}
	model.add_item(item)
	return str(item["id"])
