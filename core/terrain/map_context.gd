extends Node

## MapContext — a tiny transient hand-off for the location a generated map should
## build, set just before `change_scene_to_file()` (which cannot pass arguments).
## The map chooser / location picker writes here; the generated scene's
## TerrainLoader reads it on _ready and then clears it. Not persisted — saved
## games carry their own coordinates in the save payload.

var has_pending: bool = false
var latitude: float = 0.0
var longitude: float = 0.0
var label: String = ""
## Half-extent in metres (terrain is a square of side 2× this). 0 = use default.
var half_extent_m: float = 0.0
## True when this hand-off is a save resume — the loader then leaves the player at
## the restored save position instead of re-seating at the terrain centre.
var from_resume: bool = false


func set_pending(lat: float, lon: float, place_label: String,
		half_extent: float = 0.0, resume: bool = false) -> void:
	latitude = lat
	longitude = lon
	label = place_label
	half_extent_m = half_extent
	from_resume = resume
	has_pending = true


func consume() -> Dictionary:
	var d := {
		"latitude": latitude,
		"longitude": longitude,
		"label": label,
		"half_extent_m": half_extent_m,
		"from_resume": from_resume,
		"has_pending": has_pending,
	}
	has_pending = false
	from_resume = false
	return d
