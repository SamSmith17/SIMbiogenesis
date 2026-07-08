class_name GraphVirtualIds
extends RefCounted

## Registry of auto-generated virtual graph node IDs (SolarBridge legacy stack).

const V_PANEL_ID := "virtual_solar_array"
const V_CTRL_ID := "virtual_controller"
const V_BATTERY_ID := "virtual_battery"
const V_BASELINE_ID := "virtual_baseline"

const ARRAY_GROUPS := 3
const ARRAY_STRINGS_PER_GROUP := 2
const ARRAY_SERIES_PER_STRING := 3
const ARRAY_PANEL_COUNT := ARRAY_GROUPS * ARRAY_STRINGS_PER_GROUP * ARRAY_SERIES_PER_STRING

const V_CONN_PC_POS := "vconn_pc_pos"
const V_CONN_PC_NEG := "vconn_pc_neg"
const V_CONN_CB_POS := "vconn_cb_pos"
const V_CONN_CB_NEG := "vconn_cb_neg"


static func panel_node_id(idx: int) -> String:
	return "virtual_panel_%02d" % (idx + 1)


static func panel_node_position(idx: int) -> Vector2:
	var per_group := ARRAY_STRINGS_PER_GROUP * ARRAY_SERIES_PER_STRING
	var g := idx / per_group
	var rem := idx % per_group
	var s := rem / ARRAY_SERIES_PER_STRING
	var p := rem % ARRAY_SERIES_PER_STRING
	var x0 := -980.0 + float(g) * 300.0
	var y0 := -380.0 + float(s) * 210.0
	return Vector2(x0 + float(p) * 82.0, y0)


static func array_connection_ids() -> Array[String]:
	var out: Array[String] = []
	for g in range(ARRAY_GROUPS):
		for s in range(ARRAY_STRINGS_PER_GROUP):
			var key := "g%d_s%d" % [g + 1, s + 1]
			out.append("vconn_arr_%s_s1" % key)
			out.append("vconn_arr_%s_s2" % key)
			out.append("vconn_arr_%s_pos" % key)
			out.append("vconn_arr_%s_neg" % key)
	return out


static func all_legacy_solar_ids() -> Array[String]:
	var out: Array[String] = [
		V_PANEL_ID, V_CTRL_ID, V_BATTERY_ID, V_BASELINE_ID,
		V_CONN_PC_POS, V_CONN_PC_NEG, V_CONN_CB_POS, V_CONN_CB_NEG,
	]
	for i in range(ARRAY_PANEL_COUNT):
		out.append(panel_node_id(i))
	out.append_array(array_connection_ids())
	return out


static func suppression_dictionary() -> Dictionary:
	var d: Dictionary = {}
	for id: String in all_legacy_solar_ids():
		d[id] = true
	return d


static func merge_suppression(into: Dictionary) -> Dictionary:
	var out: Dictionary = into.duplicate(true)
	for id: String in all_legacy_solar_ids():
		out[id] = true
	return out


static func has_legacy_virtual_solar(model: GraphModel) -> bool:
	if model == null:
		return false
	if not model.get_item(V_PANEL_ID).is_empty():
		return true
	for i in range(ARRAY_PANEL_COUNT):
		if not model.get_item(panel_node_id(i)).is_empty():
			return true
	return false


static func has_user_solar_content(model: GraphModel) -> bool:
	if model == null:
		return false
	for item: Dictionary in model.items:
		if bool(item.get("is_virtual", false)):
			continue
		var itype := str(item.get("type", ""))
		if itype == "panel":
			return true
		if itype == "compound" and str((item.get("specs", {}) as Dictionary).get("compound_kind", "")) == "array":
			return true
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(specs.get("source", "")) in ["starshade", "osm_import"]:
			return true
		if str(specs.get("array_tag", "")).begins_with("osm_"):
			return true
		if bool(specs.get("osm_import", false)):
			return true
	return false


## True when the graph is only the old auto-virtual 18-panel stack with no real design.
static func is_legacy_auto_virtual_only(model: GraphModel) -> bool:
	if model == null:
		return false
	if has_user_solar_content(model):
		return false
	return has_legacy_virtual_solar(model)


static func strip_legacy_virtual_solar(model: GraphModel) -> bool:
	if model == null or not is_legacy_auto_virtual_only(model):
		return false
	var remove_ids: Dictionary = {}
	for id: String in all_legacy_solar_ids():
		remove_ids[id] = true
	for item: Dictionary in model.items:
		var iid := str(item.get("id", ""))
		if bool(item.get("is_virtual", false)):
			remove_ids[iid] = true
	for conn: Dictionary in model.connections:
		var cid := str(conn.get("id", ""))
		if cid.begins_with("vconn_"):
			model.remove_connection(cid)
	for iid: String in remove_ids.keys():
		if not model.get_item(iid).is_empty():
			model.remove_item(iid)
	# Remove any remaining virtual-only items
	for i in range(model.items.size() - 1, -1, -1):
		var item: Dictionary = model.items[i]
		if bool(item.get("is_virtual", false)):
			model.remove_item(str(item.get("id", "")))
	return true
