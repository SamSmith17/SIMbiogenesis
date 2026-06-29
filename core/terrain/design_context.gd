extends Node

## Transient hand-off for a LinkageLab game bundle import.
## Written before scene change (location picker) or consumed on the current map.

var has_pending: bool = false
var bundle_name: String = ""
var model_id: String = ""
var graph_save_state: Dictionary = {}
var solar: Dictionary = {}
var ibc: Dictionary = {}
var bundle_path: String = ""


func set_pending(model_id_in: String, graph_state: Dictionary, solar_in: Dictionary,
		ibc_in: Dictionary, name_in: String = "", path_in: String = "") -> void:
	model_id = model_id_in
	graph_save_state = graph_state.duplicate(true)
	solar = solar_in.duplicate(true)
	ibc = ibc_in.duplicate(true)
	bundle_name = name_in
	bundle_path = path_in
	has_pending = true


func consume() -> Dictionary:
	var d := {
		"has_pending": has_pending,
		"model_id": model_id,
		"graph_save_state": graph_save_state.duplicate(true),
		"solar": solar.duplicate(true),
		"ibc": ibc.duplicate(true),
		"bundle_name": bundle_name,
		"bundle_path": bundle_path,
	}
	has_pending = false
	model_id = ""
	graph_save_state = {}
	solar = {}
	ibc = {}
	bundle_name = ""
	bundle_path = ""
	return d
