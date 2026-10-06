class_name PlacedLightPower
extends RefCounted

## Whether a placed light is lit right now.
##
## A J-placed light is NOT a graph load by default: it follows its own
## `schedule` ("always" | "dusk_dawn") and draws nothing. Only after the
## player presses "Add to graph" does it carry a `graph_item_id`; from then on
## it is lit only when that item is switched on AND AC power is available
## (the item is what the graph bills), on top of its schedule.


## main: the scene Main (has day_time / sunrise_hour / sunset_hour).
static func is_lit(main: Node, rec: Dictionary, fields: Dictionary) -> bool:
	if not bool(rec.get("enabled", true)):
		return false
	if not schedule_on(main, str(fields.get("schedule", "always"))):
		return false
	var gid := str(rec.get("graph_item_id", ""))
	if gid.is_empty():
		return true
	return graph_item_on(gid) and ac_available(main)


static func schedule_on(main: Node, schedule: String) -> bool:
	if schedule != "dusk_dawn" or main == null:
		return true
	var now: float = float(main.get("day_time")) if "day_time" in main else 12.0
	var sunrise: float = float(main.get("sunrise_hour")) if "sunrise_hour" in main else 6.0
	var sunset: float = float(main.get("sunset_hour")) if "sunset_hour" in main else 18.0
	if sunset > sunrise:
		return now >= sunset or now < sunrise
	return now >= sunset and now < sunrise


static func graph_item_on(gid: String) -> bool:
	var gv := ServiceLocator.graph()
	if gv == null or not is_instance_valid(gv):
		return true   # no graph on this scene: never strand the light dark
	var model: Variant = gv.get("model")
	if model == null:
		return true
	var item: Dictionary = model.call("get_item", gid)
	if item.is_empty():
		return true   # the item was deleted outside the dock: fall back to schedule
	var specs: Dictionary = item.get("specs", {})
	var is_on_v: Variant = item.get("is_on", null)
	if is_on_v != null and not bool(is_on_v):
		return false
	var req := str(specs.get("requested_state", "on")).to_lower()
	return req != "off"


static func ac_available(main: Node) -> bool:
	var tree := main.get_tree() if main != null and main.is_inside_tree() else null
	if tree == null:
		return true
	var apb := tree.root.get_node_or_null("AcPowerBus")
	if apb == null:
		return true
	return bool(apb.get("power_available"))


static func parse_color(s: String) -> Color:
	var hex := s.strip_edges()
	if hex.is_empty():
		return Color.WHITE
	if not hex.begins_with("#"):
		hex = "#" + hex
	return Color.html(hex) if Color.html_is_valid(hex) else Color.WHITE


## 0 by day, 1 at night, with a twilight ramp — read off the scene's sun the
## same way CampLightPool does. Beams in haze are nearly invisible at noon.
static func night_factor(main: Node) -> float:
	if main == null or not is_instance_valid(main) or not ("sun" in main):
		return 1.0
	var sun: Variant = main.get("sun")
	if not is_instance_valid(sun) or not (sun is Node3D):
		return 1.0
	# The light shines along its -Z; basis.z.y tracks the sun's altitude.
	var alt_sin := (sun as Node3D).global_transform.basis.z.y
	return clampf((0.05 - alt_sin) / 0.15, 0.0, 1.0)
