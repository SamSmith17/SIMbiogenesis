extends SceneTree

## Offline checks for habitat / catchment / solar education card copy.

const EduScript := preload("res://system_graph/graph_education_cards.gd")


func _initialize() -> void:
	var fails := 0
	fails += _expect_title({"type": "processor", "specs": {"role": "habitat", "occupants": 2}}, "Habitat")
	fails += _expect_title({"type": "catchment", "specs": {"catchment_kind": "biomass"}}, "Legacy")
	fails += _expect_title({"type": "catchment", "specs": {"catchment_kind": "rain"}}, "Rain")
	fails += _expect_title({"type": "processor", "specs": {"role": "import", "counts_as_import": true}}, "Import")
	fails += _expect_title({"type": "pbi", "specs": {"resource_kind": "sunlight"}}, "Sunlight")
	fails += _expect_title({"type": "pbi", "specs": {"resource_kind": "wind"}}, "Wind")
	fails += _expect_title({"type": "panel", "specs": {"name": "PV"}}, "Solar panel")
	fails += _expect_title({"type": "plant", "specs": {"name": "Bed"}}, "Grow Bed")
	fails += _expect_title({
		"type": "compound",
		"specs": {"name": "StarShade", "definition_id": "starshade", "node_banner": true, "model_id": "starshade"},
	}, "expand")
	fails += _expect_conn_title({
		"polarity": "resource", "resource_type": "sunlight",
	}, "Radiant")
	fails += _expect_conn_title({
		"polarity": "resource", "resource_type": "wind",
	}, "atmosphere")
	fails += _expect_conn_empty({"polarity": "positive"})
	# Electrical fault cards (keyed by GraphNodeState reason; live numbers must
	# land in the body — regression guard for the old %-precedence format bug).
	fails += _expect_fault("short_circuit", {"loop_emf_v": 24.0}, "Short circuit", "24 V")
	fails += _expect_fault("battery_overvoltage", {"string_voc": 40.0, "safe_v": 14.6},
		"overcharged", "40 V")
	fails += _expect_fault("overvoltage", {"string_voc": 192.0, "max_voc": 150.0},
		"Controller destroyed", "192 V")
	if EduScript.card_for_fault("no_such_reason").size() != 0:
		push_error("unknown fault reason should yield no card")
		fails += 1
	if fails == 0:
		print("GRAPH EDUCATION SELFTEST PASS  (16 checks)")
		quit(0)
	else:
		print("GRAPH EDUCATION SELFTEST FAIL  (%d failed)" % fails)
		quit(1)


func _expect_fault(reason: String, params: Dictionary, title_needle: String,
		body_needle: String) -> int:
	var card: Dictionary = EduScript.card_for_fault(reason, params)
	if card.is_empty():
		push_error("expected fault card for reason '%s'" % reason)
		return 1
	var title := str(card.get("title", ""))
	if title_needle.to_lower() not in title.to_lower():
		push_error("fault title '%s' missing '%s'" % [title, title_needle])
		return 1
	var body := str(card.get("body", ""))
	if body_needle.to_lower() not in body.to_lower():
		push_error("fault body for '%s' missing '%s' (format bug?)" % [reason, body_needle])
		return 1
	if "%.0f" in body or "%s" in body:
		push_error("fault body for '%s' contains a raw format specifier" % reason)
		return 1
	return 0


func _expect_title(item: Dictionary, needle: String) -> int:
	var card: Dictionary = EduScript.card_for_item(item)
	if card.is_empty():
		push_error("expected card for %s" % str(item.get("type", "")))
		return 1
	var title := str(card.get("title", ""))
	if needle.to_lower() not in title.to_lower():
		push_error("title '%s' missing '%s'" % [title, needle])
		return 1
	if str(card.get("body", "")).is_empty():
		push_error("empty body for %s" % title)
		return 1
	return 0


func _expect_conn_title(conn: Dictionary, needle: String) -> int:
	var card: Dictionary = EduScript.card_for_connection(conn)
	if card.is_empty():
		push_error("expected connection card for %s" % str(conn))
		return 1
	var title := str(card.get("title", ""))
	if needle.to_lower() not in title.to_lower():
		push_error("conn title '%s' missing '%s'" % [title, needle])
		return 1
	return 0


func _expect_conn_empty(conn: Dictionary) -> int:
	var card: Dictionary = EduScript.card_for_connection(conn)
	if not card.is_empty():
		push_error("expected no card for electrical wire, got %s" % str(card.get("title", "")))
		return 1
	return 0
