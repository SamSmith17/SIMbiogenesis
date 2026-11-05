class_name CspLabActuators
extends RefCounted

## The tracking drives of a concentrator as numbers a real motor can follow
## (pure). Every axis the 3D model turns is a CHANNEL with a stable id, a
## name, its range and its angle now in degrees — read off the SAME pose the
## builder draws (CspLabSite.pose / CspLabOptics.field_pose), so the angle a
## motor is sent is the angle the player sees.
##
##   two-axis, azimuth + elevation   "azimuth" 0–360 (compass in the mount's
##                                    frame: 0 = the mount's north, 90 = east)
##                                    and "elevation" 0–90 (the optic's axis
##                                    above the horizon)
##   two-axis, polar mount           "hour_angle" (0 = facing the meridian,
##                                    + = turned west) and "declination"
##   one axis (N–S, E–W, polar)      "rotation" about the axis (0 = aperture
##                                    straight up / at the meridian, + = the
##                                    right-hand turn about the axis)
##   linear Fresnel rows             "row<k>" each row's tilt about its axis
##   tower heliostats                "h<k>_az" and "h<k>_el" per heliostat
##   fixed / a level water lens      none: nothing moves
##
## A placed concentrator can push them to Home Assistant: its record carries
## `csplab_ha` = {enabled, mode ("live" | "always"), deadband_deg,
## min_interval_s, channels: {id: {entity_id, scale, offset, invert, min,
## max, enabled}}}. `value_for` maps an angle onto the entity (invert, then
## scale, then offset, then clamp), `service_for` names the service a
## domain takes (input_number / number set_value, cover / valve position).

const DOMAINS := {
	"input_number": "Helper number (input_number) — set_value",
	"number": "Device number (ESPHome, MQTT…) — set_value",
	"cover": "Cover / linear actuator — position 0–100 %",
	"valve": "Valve — position 0–100 %",
}

const MODES := {
	"live": "Only in Live mode (the real clock)",
	"always": "Always, following the simulation",
}

const DEFAULT_DEADBAND_DEG := 0.5
const DEFAULT_MIN_INTERVAL_S := 5.0


## The channels for a pose. `design` is the solved design (fields need its
## geometry); `pose` is CspLabSite.pose(spec, sun_in_mount_frame, lat).
static func channels(design: Dictionary, pose: Dictionary) -> Array:
	var spec: Dictionary = design.get("spec", {}) as Dictionary
	if spec.is_empty() or pose.is_empty():
		return []
	var t := str(spec["type"])
	var mode := str((spec["tracking"] as Dictionary)["mode"])
	var mount := str((spec["structure"] as Dictionary)["mount"])
	var out: Array = []
	if CspLabSite.is_field(spec):
		var g: Dictionary = design["geo"]
		var sl: Vector3 = pose.get("sun_local", Vector3.UP)
		if sl.y <= 0.02:
			sl = CspLabDesign.design_sun_local(spec)
		var fp := CspLabOptics.field_pose(g, sl)
		var ns: PackedVector3Array = fp.get("n", PackedVector3Array())
		if t == "linear_fresnel":
			for k in ns.size():
				var n := ns[k]
				out.append(_ch("row%d" % (k + 1), "Row %d tilt" % (k + 1), rad_to_deg(atan2(n.x, n.y)), -90.0, 90.0,
					"Row %d turns about its own axis; + tilts its face toward the field's +X side" % (k + 1)))
		else:
			var fb := CspLabSite.field_basis(spec)
			for k in ns.size():
				var ae := CspLabSite.az_el(fb * ns[k])
				out.append(_ch("h%d_az" % (k + 1), "Heliostat %d azimuth" % (k + 1), ae.x, 0.0, 360.0,
					"Compass bearing its mirror faces (0 = north, 90 = east)"))
				out.append(_ch("h%d_el" % (k + 1), "Heliostat %d elevation" % (k + 1), ae.y, 0.0, 90.0,
					"Its mirror's normal above the horizon"))
		return out
	var angs: Dictionary = pose.get("angles", {}) as Dictionary
	match mode:
		"two_axis":
			if mount == "polar_mount":
				out.append(_ch("hour_angle", "Hour angle", float(angs.get("Hour angle", 0.0)), -180.0, 180.0,
					"About the polar axis; 0 = facing the meridian, + = turned toward the west"))
				out.append(_ch("declination", "Declination", float(angs.get("Declination", 0.0)), -30.0, 30.0,
					"The tilt off the equator's plane: ±23.4° over the year"))
			else:
				out.append(_ch("azimuth", "Azimuth", fposmod(float(angs.get("Azimuth", 180.0)), 360.0), 0.0, 360.0,
					"Compass bearing the optic faces in the mount's frame (0 = north, 90 = east)"))
				out.append(_ch("elevation", "Elevation", float(angs.get("Elevation", 90.0)), 0.0, 90.0,
					"The optic's axis above the horizon (90 = facing straight up, the stow)"))
		"ns_horizontal", "ew_horizontal", "polar":
			out.append(_ch("rotation", "Rotation", float(angs.get("Rotation", 0.0)), -90.0, 90.0,
				"About the tracking axis; 0 = aperture straight up (or at the meridian on a polar axis)"))
	return out


static func _ch(id: String, label: String, deg: float, lo: float, hi: float, tip: String) -> Dictionary:
	return {"id": id, "label": label, "deg": deg, "min": lo, "max": hi, "tip": tip}


## The entity's domain ("input_number.dish_az" → "input_number").
static func domain_of(entity_id: String) -> String:
	var e := entity_id.strip_edges()
	var dot := e.find(".")
	return e.substr(0, dot) if dot > 0 else ""


## Whether the game can drive an entity of this id.
static func supported(entity_id: String) -> bool:
	return DOMAINS.has(domain_of(entity_id)) and entity_id.strip_edges().length() > domain_of(entity_id).length() + 1


## The value sent for an angle: invert, scale, offset, then clamp to the
## link's [min, max] when it has one (a position domain is a percentage of
## that range, 0–100).
static func value_for(deg: float, link: Dictionary, ch: Dictionary = {}) -> float:
	var v := -deg if bool(link.get("invert", false)) else deg
	v = v * float(link.get("scale", 1.0)) + float(link.get("offset", 0.0))
	var lo := float(link.get("min", 0.0))
	var hi := float(link.get("max", 0.0))
	var dom := domain_of(str(link.get("entity_id", "")))
	if dom == "cover" or dom == "valve":
		# Position: the channel's (or the link's) range mapped onto 0–100 %.
		if hi <= lo:
			lo = float(ch.get("min", 0.0))
			hi = float(ch.get("max", 100.0))
		return clampf((v - lo) / maxf(hi - lo, 1e-6) * 100.0, 0.0, 100.0)
	if hi > lo:
		v = clampf(v, lo, hi)
	return v


## {domain, service, data} for sending `value` to `entity_id`.
static func service_for(entity_id: String, value: float) -> Dictionary:
	var dom := domain_of(entity_id)
	match dom:
		"input_number", "number":
			return {"domain": dom, "service": "set_value", "data": {"value": snappedf(value, 0.01)}}
		"cover":
			return {"domain": "cover", "service": "set_cover_position", "data": {"position": int(roundf(value))}}
		"valve":
			return {"domain": "valve", "service": "set_valve_position", "data": {"position": int(roundf(value))}}
	return {}


## A config with every key, keeping what `cfg` has.
static func normalized(cfg: Dictionary) -> Dictionary:
	var out := {"enabled": bool(cfg.get("enabled", false)),
		"mode": str(cfg.get("mode", "live")) if MODES.has(str(cfg.get("mode", "live"))) else "live",
		"deadband_deg": maxf(float(cfg.get("deadband_deg", DEFAULT_DEADBAND_DEG)), 0.0),
		"min_interval_s": maxf(float(cfg.get("min_interval_s", DEFAULT_MIN_INTERVAL_S)), 0.5),
		"channels": {}}
	var chs: Dictionary = cfg.get("channels", {}) as Dictionary
	for k in chs:
		var l: Dictionary = chs[k] as Dictionary
		out["channels"][str(k)] = {"entity_id": str(l.get("entity_id", "")).strip_edges(),
			"scale": float(l.get("scale", 1.0)), "offset": float(l.get("offset", 0.0)),
			"invert": bool(l.get("invert", false)), "min": float(l.get("min", 0.0)),
			"max": float(l.get("max", 0.0)), "enabled": bool(l.get("enabled", true))}
	return out


## Which channels are due a send: changed past the deadband since the last
## sent value (or never sent), with at least min_interval_s since the last
## send of any channel. Returns [{id, entity_id, value, call}].
static func due(cfg: Dictionary, chans: Array, last_sent: Dictionary, since_last_s: float) -> Array:
	var c := normalized(cfg)
	if not bool(c["enabled"]) or since_last_s < float(c["min_interval_s"]):
		return []
	var out: Array = []
	var links: Dictionary = c["channels"]
	for chv in chans:
		var ch: Dictionary = chv
		var id := str(ch["id"])
		if not links.has(id):
			continue
		var l: Dictionary = links[id]
		var eid := str(l["entity_id"])
		if not bool(l["enabled"]) or not supported(eid):
			continue
		var v := value_for(float(ch["deg"]), l, ch)
		var dom := domain_of(eid)
		var db := float(c["deadband_deg"])
		if dom == "cover" or dom == "valve":
			db = maxf(db / maxf(float(ch["max"]) - float(ch["min"]), 1e-6) * 100.0, 0.5)
		if last_sent.has(eid) and absf(float(last_sent[eid]) - v) < db:
			continue
		out.append({"id": id, "entity_id": eid, "value": v, "call": service_for(eid, v)})
	return out


## A name as a Home Assistant object id ("Dish cooker 1.5 m" → "dish_cooker_1_5_m").
static func slug(name: String) -> String:
	var clean := ""
	for ch in name.to_lower().strip_edges():
		clean += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "_"
	while clean.contains("__"):
		clean = clean.replace("__", "_")
	clean = clean.trim_prefix("_").trim_suffix("_")
	return clean if not clean.is_empty() else "concentrator"


## The helper a channel is linked to by default (what ha_yaml declares).
static func default_entity(name: String, ch_id: String) -> String:
	return "input_number.%s_%s" % [slug(name), ch_id]


## Home Assistant YAML for the helpers the channels need (input_number) and
## an example automation that follows one of them — what a builder pastes
## into configuration.yaml to start wiring motors.
static func ha_yaml(name: String, chans: Array) -> String:
	var clean := slug(name)
	var lines: Array = ["# %s — tracking angles from SIMbiogenesis" % name,
		"# Paste under configuration.yaml, restart, then link each axis to its helper.", "input_number:"]
	for chv in chans:
		var ch: Dictionary = chv
		lines.append("  %s_%s:" % [clean, str(ch["id"])])
		lines.append("    name: \"%s %s\"" % [name, str(ch.get("label", ch["id"])).to_lower()])
		lines.append("    min: %s" % str(float(ch["min"])))
		lines.append("    max: %s" % str(float(ch["max"])))
		lines.append("    step: 0.1")
		lines.append("    unit_of_measurement: \"°\"")
		lines.append("    mode: box")
	if not chans.is_empty():
		var first: Dictionary = chans[0]
		lines.append("")
		lines.append("# Example: drive an ESPHome / MQTT motor from the first axis.")
		lines.append("automation:")
		lines.append("  - alias: \"%s follows the simulation (%s)\"" % [name, str(first.get("label", first["id"])).to_lower()])
		lines.append("    trigger:")
		lines.append("      - platform: state")
		lines.append("        entity_id: input_number.%s_%s" % [clean, str(first["id"])])
		lines.append("    action:")
		lines.append("      - service: number.set_value")
		lines.append("        target:")
		lines.append("          entity_id: number.REPLACE_WITH_YOUR_MOTOR")
		lines.append("        data:")
		lines.append("          value: \"{{ trigger.to_state.state | float }}\"")
	return "\n".join(PackedStringArray(lines)) + "\n"
