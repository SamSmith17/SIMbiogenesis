class_name SolarAim
extends RefCounted

## The orientation a solar collector is placed at, by type: ONE rule for every
## placement path (the placement ghost, Graph → "Place array in 3D", the prop
## editor's "Best angle"). Pure.
##
## - Fixed racks (`pv_array`, a designed array on a ground / tilted-roof /
##   ballast / pole mount) face the equator — south in the northern
##   hemisphere, north in the southern — at the latitude's annual-optimal
##   tilt (`SolarArrayBuilder.default_tilt_deg`, the Lave & Kleissl 2011 fit
##   the OSM arrays already use).
## - Single-axis trackers lay their axis north–south (yaw 0 in PvLabArray's
##   tracker frame) in either hemisphere; the heads turn east → west.
## - Flush mounts (roof_flush, none) lie in the surface: on a pitched roof they
##   face down its slope whatever the yaw says; on flat ground they face the
##   equator, flat.
## - Concentrators: the parabolic trough's pivot axis is fixed east–west
##   (CspTroughSource.TRACKING_AXIS, ModelCatalog forced_yaw_deg 0) and its
##   tracker tilts the aperture toward the equator itself; the dual-axis
##   heliostat points at the sun on both axes, so its yaw does not matter.
##
## Yaw follows PvArrayBuilder's convention: the face points to local +Z, which
## is due south at yaw 0 (CelestialClock: north −Z, east +X).

const KIND_FIXED := "fixed"
const KIND_TRACKER := "tracker"
const KIND_FLUSH := "flush"
const KIND_TROUGH := "axis_ew"
const KIND_DISH := "dual_axis"

## PvLab mounts whose tables stand at the array's own tilt.
const TILTED_MOUNTS := ["ground", "roof_tilt", "ballast", "pole"]


static func equator_azimuth_deg(lat_deg: float) -> float:
	return SolarArrayBuilder.default_azimuth_deg(lat_deg)


static func equator_yaw_deg(lat_deg: float) -> float:
	return PvArrayBuilder.yaw_for_azimuth(equator_azimuth_deg(lat_deg))


static func best_tilt_deg(lat_deg: float) -> float:
	return SolarArrayBuilder.default_tilt_deg(lat_deg)


## How `model_id` (with its record spec, if any) should be placed at latitude
## `lat_deg`: {kind, yaw_deg, tilt_deg (NAN = the type has no fixed tilt)}.
## kind "" = not a solar collector (yaw 0, nothing to say).
static func for_model(model_id: String, spec: Dictionary, lat_deg: float) -> Dictionary:
	match model_id:
		"pv_array":
			return {"kind": KIND_FIXED, "yaw_deg": equator_yaw_deg(lat_deg), "tilt_deg": best_tilt_deg(lat_deg)}
		"pvlab_array":
			var arr: Dictionary = spec.get("array", {}) if spec.get("array") is Dictionary else {}
			var mount := str(arr.get("mount", "ground"))
			if mount == "tracker":
				return {"kind": KIND_TRACKER, "yaw_deg": 0.0, "tilt_deg": NAN}
			if mount in TILTED_MOUNTS:
				return {"kind": KIND_FIXED, "yaw_deg": equator_yaw_deg(lat_deg), "tilt_deg": best_tilt_deg(lat_deg)}
			return {"kind": KIND_FLUSH, "yaw_deg": equator_yaw_deg(lat_deg), "tilt_deg": NAN}
		"csp_trough":
			return {"kind": KIND_TROUGH, "yaw_deg": ModelCatalog.forced_yaw_deg(model_id), "tilt_deg": NAN}
		"heliostat":
			return {"kind": KIND_DISH, "yaw_deg": ModelCatalog.forced_yaw_deg(model_id), "tilt_deg": NAN}
	return {"kind": "", "yaw_deg": 0.0, "tilt_deg": NAN}


static func compass_word(az_deg: float) -> String:
	const PTS := ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
	return PTS[int(round(fposmod(az_deg, 360.0) / 45.0)) % 8]


static func latitude_text(lat_deg: float) -> String:
	return "%.0f°%s" % [absf(lat_deg), "N" if lat_deg >= 0.0 else "S"]


## One line for the placement prompt. `tilt_now` is the tilt the thing will
## actually stand at (NAN = say nothing about tilt).
static func describe(aim: Dictionary, lat_deg: float, tilt_now: float = NAN) -> String:
	match str(aim.get("kind", "")):
		KIND_FIXED:
			var best := float(aim.get("tilt_deg", NAN))
			var face := "faces %s" % compass_word(equator_azimuth_deg(lat_deg))
			if is_nan(tilt_now) or is_nan(best) or absf(tilt_now - best) < 0.5:
				return "%s at %.0f° (best for %s)" % [face, best if is_nan(tilt_now) else tilt_now, latitude_text(lat_deg)]
			return "%s at %.0f° (best for %s: %.0f°)" % [face, tilt_now, latitude_text(lat_deg), best]
		KIND_TRACKER:
			return "tracker axis runs north–south"
		KIND_FLUSH:
			return "lies in the surface, faces %s on flat ground" % compass_word(equator_azimuth_deg(lat_deg))
		KIND_TROUGH:
			return "trough axis runs east–west, tilts to the sun"
		KIND_DISH:
			return "tracks the sun on both axes"
	return ""
