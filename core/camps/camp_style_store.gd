class_name CampStyleStore
extends RefCounted

## The player's camp-style edits (user://camp_styles.json): per-style layout
## and household mix, plus the models they have added as camp classes. Global,
## like the vegetation styles — it is a taste about how camps look, and a camp
## record stores only a style id, so one edit restyles every camp of that style
## on every map.
##
## Holds ONLY what differs from the shipped tables in CampStyles; `apply()`
## hands it to `CampStyles.set_user_layer`, which is where the generator reads.
##
## File:
##   {version, styles: {style_id: {<entry keys>, templates: {template_id: weight},
##                                 default_weight,
##                                 variants: [{id, name, weight, <entry>}]}},
##    models: {class_id: {model_id, label, mode, size: [x, y, z], tris}}}

const VERSION := 1
const PATH := "user://camp_styles.json"
const MAX_MODELS := 24
const MAX_VARIANTS := 8

## Soft performance thresholds. Nothing is refused — these only word a warning.
## A model this heavy is fine once and expensive a few hundred times.
const HEAVY_MODEL_TRIS := 15000
const VERY_HEAVY_MODEL_TRIS := 60000
## Triangles per hectare of camp, drawn up close, before a warning.
const HEAVY_TRIS_PER_HA := 3000000
## A footprint longer than this is bigger than any shipped household.
const LARGE_MODEL_M := 16.0


static func empty() -> Dictionary:
	return {"version": VERSION, "styles": {}, "models": {}}


static func load_data(path: String = PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return empty()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return empty()
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return normalize(parsed as Dictionary) if parsed is Dictionary else empty()


static func save_data(data: Dictionary, path: String = PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(normalize(data), "\t"))
	return true


static func load_and_apply(path: String = PATH) -> Dictionary:
	var data := load_data(path)
	apply(data)
	return data


## Push a data set into CampStyles (the layer the generator reads).
static func apply(data: Dictionary) -> void:
	var d := normalize(data)
	var models: Dictionary = {}
	for cid in (d["models"] as Dictionary).keys():
		var m: Dictionary = d["models"][cid]
		var sz: Array = m["size"]
		models[cid] = {"model_id": m["model_id"], "label": m["label"], "mode": m["mode"],
			"size": Vector3(float(sz[0]), float(sz[1]), float(sz[2])), "tris": m["tris"]}
	CampStyles.set_user_layer((d["styles"] as Dictionary).duplicate(true), models)


## Drop anything malformed; keep unknown styles/templates out of the layer.
static func normalize(data: Dictionary) -> Dictionary:
	var out := empty()
	var models_in: Variant = data.get("models", {})
	if models_in is Dictionary:
		for cid in (models_in as Dictionary).keys():
			var m: Variant = models_in[cid]
			if not (m is Dictionary) or (out["models"] as Dictionary).size() >= MAX_MODELS:
				continue
			var sz: Variant = (m as Dictionary).get("size", [])
			if not (sz is Array) or (sz as Array).size() < 3:
				continue
			var x := float(sz[0])
			var y := float(sz[1])
			var z := float(sz[2])
			if not (is_finite(x) and is_finite(y) and is_finite(z)) or x < 0.2 or y < 0.2 or z < 0.2:
				continue
			out["models"][str(cid)] = {
				"model_id": str((m as Dictionary).get("model_id", "")),
				"label": str((m as Dictionary).get("label", str(cid))),
				"mode": clampi(int((m as Dictionary).get("mode", CampStyles.FREE)),
					CampStyles.ALIGNED, CampStyles.FREE),
				"size": [x, y, z],
				"tris": maxi(int((m as Dictionary).get("tris", 0)), 0),
			}
	var known_models: Dictionary = out["models"]
	var styles_in: Variant = data.get("styles", {})
	if styles_in is Dictionary:
		for sid in (styles_in as Dictionary).keys():
			var st: Variant = styles_in[sid]
			if not (st is Dictionary) or not CampStyles.STYLES.has(str(sid)):
				continue
			var entry := normalize_entry(st as Dictionary, known_models)
			if (st as Dictionary).has("default_weight"):
				entry["default_weight"] = clampf(float(st["default_weight"]), 0.0, 20.0)
			var variants: Array = []
			var vin: Variant = (st as Dictionary).get("variants", [])
			if vin is Array:
				for v in (vin as Array):
					if not (v is Dictionary) or variants.size() >= MAX_VARIANTS:
						continue
					var vid := str((v as Dictionary).get("id", ""))
					if vid.is_empty():
						continue
					var ve := normalize_entry(v as Dictionary, known_models)
					ve["id"] = vid
					ve["name"] = str((v as Dictionary).get("name", vid)).substr(0, 40)
					ve["weight"] = clampf(float((v as Dictionary).get("weight", 1.0)), 0.0, 20.0)
					variants.append(ve)
			if not variants.is_empty():
				entry["variants"] = variants
			if not entry.is_empty():
				out["styles"][str(sid)] = entry
	return out


## Clean ONE style entry (the sparse edit dict used at every layer: global,
## layout, map, camp). `known_models` = class ids that exist; null = ask
## CampStyles (the live layer).
static func normalize_entry(st: Dictionary, known_models: Variant = null) -> Dictionary:
	var entry := {}
	for key in CampStyles.ENTRY_KEYS:
		if st.has(key) and is_finite(float(st[key])):
			entry[key] = int(st[key]) if key == "rows_per_block" else float(st[key])
	var mix := {}
	var mix_in: Variant = st.get("templates", {})
	if mix_in is Dictionary:
		for tid in (mix_in as Dictionary).keys():
			var t := str(tid)
			var known := CampStyles.TEMPLATES.has(t)
			if t.begins_with(CampStyles.MODEL_TEMPLATE_PREFIX):
				var cid := t.substr(CampStyles.MODEL_TEMPLATE_PREFIX.length())
				known = (known_models as Dictionary).has(cid) if known_models is Dictionary \
					else CampStyles.is_user_class(cid)
			if known and is_finite(float(mix_in[tid])):
				mix[t] = clampf(float(mix_in[tid]), 0.0, 20.0)
	if not mix.is_empty():
		entry["templates"] = mix
	return entry


## `delta` laid over `base`, key by key (templates merged, not replaced).
static func merge_entry(base: Dictionary, delta: Dictionary) -> Dictionary:
	var out := base.duplicate(true)
	for k in delta.keys():
		if k == "templates":
			var mix: Dictionary = (out.get("templates", {}) as Dictionary).duplicate()
			for tid in (delta["templates"] as Dictionary).keys():
				mix[tid] = delta["templates"][tid]
			out["templates"] = mix
		else:
			out[k] = delta[k]
	return out


## Add a named layout to a style from an entry. Returns its id.
static func add_variant(data: Dictionary, style_id: String, name: String,
		entry: Dictionary) -> String:
	var styles: Dictionary = data["styles"]
	if not styles.has(style_id):
		styles[style_id] = {}
	var st: Dictionary = styles[style_id]
	if not st.has("variants"):
		st["variants"] = []
	var list: Array = st["variants"]
	if list.size() >= MAX_VARIANTS:
		return ""
	var n := 1
	var ids := {}
	for v in list:
		ids[str((v as Dictionary).get("id", ""))] = true
	while ids.has("v%d" % n):
		n += 1
	var ve := normalize_entry(entry)
	ve["id"] = "v%d" % n
	ve["name"] = name if not name.strip_edges().is_empty() else "Layout %d" % n
	ve["weight"] = 1.0
	list.append(ve)
	return str(ve["id"])


static func remove_variant(data: Dictionary, style_id: String, variant_id: String) -> void:
	var st: Dictionary = (data["styles"] as Dictionary).get(style_id, {})
	var list: Array = st.get("variants", [])
	for i in list.size():
		if str((list[i] as Dictionary).get("id", "")) == variant_id:
			list.remove_at(i)
			return


static func class_id_for_model(model_id: String) -> String:
	return "u_" + model_id.validate_node_name().replace(" ", "_")


## Register a measured model as a camp class. `measured` = CampMeshLibrary
## .measure_model's result. Returns the class id ("" when refused).
static func add_model(data: Dictionary, model_id: String, label: String,
		measured: Dictionary) -> String:
	if measured.is_empty() or model_id.is_empty():
		return ""
	var models: Dictionary = data["models"]
	var cid := class_id_for_model(model_id)
	if not models.has(cid) and models.size() >= MAX_MODELS:
		return ""
	var size: Vector3 = measured["size"]
	models[cid] = {
		"model_id": model_id, "label": label,
		# Long things park square to the camp; round things sit any way up.
		"mode": CampStyles.ALIGNED if size.x >= size.z * 1.3 else CampStyles.FREE,
		"size": [size.x, size.y, size.z], "tris": int(measured.get("tris", 0)),
	}
	return cid


## Remove a model and every style's reference to it.
static func remove_model(data: Dictionary, class_id: String) -> void:
	(data["models"] as Dictionary).erase(class_id)
	var tid := CampStyles.MODEL_TEMPLATE_PREFIX + class_id
	for sid in (data["styles"] as Dictionary).keys():
		var mix: Variant = (data["styles"][sid] as Dictionary).get("templates", {})
		if mix is Dictionary:
			(mix as Dictionary).erase(tid)


## Plain-language warnings for ONE model (shown beside it in the modal).
static func model_warnings(size: Vector3, tris: int) -> Array:
	var out: Array = []
	if tris >= VERY_HEAVY_MODEL_TRIS:
		out.append("Very detailed (%s triangles) — a camp draws it hundreds of times; expect a frame-rate hit" % _k(tris))
	elif tris >= HEAVY_MODEL_TRIS:
		out.append("Detailed (%s triangles) — fine in small numbers, costly across a big camp" % _k(tris))
	if size.x >= LARGE_MODEL_M:
		out.append("Large (%.0f m long) — the whole style's spacing grows to fit it" % size.x)
	return out


## Warnings for a laid-out sample. `counts` = class -> instances in the sample,
## `tris` = class -> triangles of that class's near mesh, `area_m2` = the
## sample's area. Returns {tris_per_ha, structures_per_ha, warnings: Array}.
static func layout_cost(counts: Dictionary, tris: Dictionary, area_m2: float) -> Dictionary:
	var total_tris := 0.0
	var total_n := 0
	var worst_cls := ""
	var worst := 0.0
	for cls in counts.keys():
		var n := int(counts[cls])
		var t := float(n) * float(tris.get(cls, 0))
		total_n += n
		total_tris += t
		if t > worst:
			worst = t
			worst_cls = str(cls)
	var ha := maxf(area_m2, 1.0) / 10000.0
	var per_ha := total_tris / ha
	var warnings: Array = []
	if per_ha >= float(HEAVY_TRIS_PER_HA):
		var msg := "About %s triangles per hectare of camp up close" % _k(int(per_ha))
		if not worst_cls.is_empty() and total_tris > 0.0:
			msg += " — %d%% of it is %s" % [int(round(100.0 * worst / total_tris)), worst_cls]
		warnings.append(msg + ". Lower its share, the density, or use a lighter model.")
	return {"tris_per_ha": per_ha, "structures_per_ha": float(total_n) / ha, "warnings": warnings}


static func _k(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (float(n) / 1000000.0)
	if n >= 1000:
		return "%dk" % int(round(float(n) / 1000.0))
	return str(n)
