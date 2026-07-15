extends SceneTree

## Offline checks for habitat / catchment education card copy.

const EduScript := preload("res://system_graph/graph_education_cards.gd")


func _initialize() -> void:
	var fails := 0
	fails += _expect_title({"type": "processor", "specs": {"role": "habitat", "occupants": 2}}, "Habitat")
	fails += _expect_title({"type": "catchment", "specs": {"catchment_kind": "biomass"}}, "Biomass")
	fails += _expect_title({"type": "catchment", "specs": {"catchment_kind": "rain"}}, "Rain")
	fails += _expect_title({"type": "processor", "specs": {"role": "import", "counts_as_import": true}}, "Import")
	fails += _expect_empty({"type": "panel", "specs": {"name": "PV"}})
	if fails == 0:
		print("GRAPH EDUCATION SELFTEST PASS  (5 checks)")
		quit(0)
	else:
		print("GRAPH EDUCATION SELFTEST FAIL  (%d failed)" % fails)
		quit(1)


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


func _expect_empty(item: Dictionary) -> int:
	var card: Dictionary = EduScript.card_for_item(item)
	if not card.is_empty():
		push_error("expected no card for panel, got %s" % str(card.get("title", "")))
		return 1
	return 0
