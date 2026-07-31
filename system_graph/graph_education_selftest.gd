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
	fails += _test_override_keys()
	fails += _test_override_store()
	if fails == 0:
		print("GRAPH EDUCATION SELFTEST PASS  (18 checks)")
		quit(0)
	else:
		print("GRAPH EDUCATION SELFTEST FAIL  (%d failed)" % fails)
		quit(1)


## Every fault card must carry a stable override_key (the dev copy-editor's
## identity), kind-qualified where one reason has different copy per kind.
func _test_override_keys() -> int:
	var plain: Dictionary = EduScript.card_for_fault("overvoltage",
		{"string_voc": 192.0, "max_voc": 150.0})
	if str(plain.get("override_key", "")) != "fault:overvoltage":
		push_error("overvoltage card key expected 'fault:overvoltage' got '%s'" %
			str(plain.get("override_key", "")))
		return 1
	var pv: Dictionary = EduScript.card_for_fault("reverse_polarity", {"kind": "pv"})
	var bat: Dictionary = EduScript.card_for_fault("reverse_polarity", {"kind": "battery"})
	if str(pv.get("override_key", "")) != "fault:reverse_polarity:pv" \
			or str(bat.get("override_key", "")) != "fault:reverse_polarity:battery":
		push_error("reverse-polarity cards must be kind-qualified, got '%s' / '%s'" % [
			str(pv.get("override_key", "")), str(bat.get("override_key", ""))])
		return 1
	return 0


## The dev copy-edit store: save → apply replaces title/body; keyless cards and
## suffix text pass through untouched; clear restores the authored copy.
func _test_override_store() -> int:
	EducationCardOverrides.path_override = "user://selftest_card_overrides.json"
	EducationCardOverrides.reset_cache()
	if FileAccess.file_exists(EducationCardOverrides.path_override):
		DirAccess.remove_absolute(
			ProjectSettings.globalize_path(EducationCardOverrides.path_override))
	var card := {"title": "Authored", "body": "Original copy",
		"override_key": "fault:overvoltage", "body_suffix": "per-occurrence"}
	var out := EducationCardOverrides.apply(card)
	if str(out.get("title", "")) != "Authored":
		push_error("no override saved — card must pass through untouched")
		return 1
	EducationCardOverrides.save_override("fault:overvoltage", "Edited", "New copy")
	out = EducationCardOverrides.apply(card)
	if str(out.get("title", "")) != "Edited" or str(out.get("body", "")) != "New copy":
		push_error("saved override should replace title/body, got %s" % str(out))
		return 1
	if str(out.get("body_suffix", "")) != "per-occurrence":
		push_error("body_suffix must never be overridden (it is per-occurrence)")
		return 1
	# Survives a cache drop (fresh session).
	EducationCardOverrides.reset_cache()
	if str(EducationCardOverrides.apply(card).get("title", "")) != "Edited":
		push_error("override lost across a cache drop")
		return 1
	# Keyless cards are untouchable.
	var keyless := {"title": "X", "body": "Y"}
	if EducationCardOverrides.apply(keyless) != keyless:
		push_error("cards without an override_key must pass through identically")
		return 1
	EducationCardOverrides.clear_override("fault:overvoltage")
	if str(EducationCardOverrides.apply(card).get("title", "")) != "Authored":
		push_error("clear_override should restore the authored copy")
		return 1
	if FileAccess.file_exists(EducationCardOverrides.path_override):
		DirAccess.remove_absolute(
			ProjectSettings.globalize_path(EducationCardOverrides.path_override))
	EducationCardOverrides.path_override = ""
	EducationCardOverrides.reset_cache()
	return 0


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
