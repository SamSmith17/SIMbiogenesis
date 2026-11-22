class_name GreenhouseParts
extends RefCounted

## The props a greenhouse stands up inside itself: a grow bed (or a FarmBot
## bed with its gantry) per designed bed, and a grow-light rack over every
## lit bed. Each is its own placed prop mounted on the shell
## (`mount_host {kind: "prop", id: shell, owned: true}`), keyed by
## `gh_part` so re-applying a design updates them in place. Pure.
##
## Part: {part: "bed:<id>" | "lights:<id>", model_id, x, y, z (shell local),
##   yaw_deg, extra: {record keys}, label}

const BED_PART := "bed:"
const LIGHTS_PART := "lights:"
const KEY := "gh_part"
const OWNER_KEY := "gh_owner"


static func parts(d: Dictionary) -> Array:
	var s: Dictionary = d["spec"]
	var fr: Dictionary = d["frame"]
	var out: Array = []
	for b in d["beds"]:
		var bd: Dictionary = b
		var id := str(bd["id"])
		var label := "%s bed %s" % [str(s["name"]), id.trim_prefix("b")]
		if bool(bd.get("gantry", false)):
			out.append({"part": BED_PART + id, "model_id": FarmBotBuilder.MODEL_ID, "x": float(bd["x"]),
				"y": 0.0, "z": float(bd["z"]), "yaw_deg": 0.0, "label": label + " (FarmBot)",
				"extra": {"farmbot_spec": farmbot_spec_for(s, bd)}})
		else:
			out.append({"part": BED_PART + id, "model_id": GrowBed.MODEL_ID, "x": float(bd["x"]),
				"y": 0.0, "z": float(bd["z"]), "yaw_deg": 0.0, "label": label,
				"extra": {"grow_bed_spec": grow_bed_spec_for(bd)}})
		if bd.has("light"):
			var crop_h := GreenhouseBeds.tallest_crop(bd["crops"])
			var hang := float(bd["wall_h_m"]) + maxf(float(bd["light"]["hang_m"]), crop_h * 0.6 + 0.3)
			hang = minf(hang, float(bd["wall_h_m"]) + float(bd["headroom_m"]) - 0.15)
			var ls := {"watts": float(bd["light"]["w"]), "hang_m": maxf(hang, float(bd["wall_h_m"]) + 0.3),
				"spectrum": str((s.get("lights", {}) as Dictionary).get("spectrum", "blurple"))}
			if str(bd["kind"]) == "keyhole":
				ls["shape"] = "ring"
				ls["outer_r"] = float(bd["keyhole"]["outer_r"])
				ls["inner_r"] = float(bd["keyhole"]["centre_r"])
			else:
				ls["shape"] = "rect"
				ls["length_m"] = float(bd["length_m"])
				ls["width_m"] = float(bd["width_m"])
			out.append({"part": LIGHTS_PART + id, "model_id": GrowLightRack.MODEL_ID, "x": float(bd["x"]),
				"y": 0.0, "z": float(bd["z"]), "yaw_deg": 0.0, "label": "%s lights %s" % [str(s["name"]), id.trim_prefix("b")],
				"extra": {GrowLightRack.KEY: GrowLightRack.resolve(ls)}})
	return out


## A GrowBed spec for a designed bed (crop list from the mix's shares).
static func grow_bed_spec_for(bd: Dictionary) -> Dictionary:
	var crops: Variant = crop_list(bd["crops"])
	if str(bd["kind"]) == "keyhole":
		return {"layout": "keyhole", "keyhole": (bd["keyhole"] as Dictionary).duplicate(), "crops": crops,
			"seed": hash(str(bd["id"])) % 997 + 1}
	return {"layout": "rect", "size_m": [float(bd["length_m"]), float(bd["width_m"])],
		"wall_h": float(bd["wall_h_m"]), "crops": crops, "seed": hash(str(bd["id"])) % 997 + 1}


## A FarmBot spec for a designed bed with a gantry.
static func farmbot_spec_for(s: Dictionary, bd: Dictionary) -> Dictionary:
	var mix: Array = []
	if bd["crops"] is Array:
		for e in bd["crops"]:
			mix.append({"crop": str(e["crop"]), "share": float(e["share"])})
	else:
		var ids: Array = GreenhouseSpec.mix_crops("garden")
		for c in ids:
			mix.append({"crop": str(c), "share": 1.0 / float(ids.size())})
	var fs := FarmBotSpec.default_spec()
	fs["name"] = "%s FarmBot %s" % [str(s["name"]), str(bd["id"])]
	fs["crops"]["mix"] = mix
	if str(bd["kind"]) == "keyhole":
		fs["kind"] = "radial"
		var k: Dictionary = (bd["keyhole"] as Dictionary).duplicate()
		k["sweep"] = "slot"
		k["arms"] = 1 if float(k["outer_r"]) < 6.0 else 3
		fs["keyhole"] = k
	else:
		fs["bed"] = {"length_m": float(bd["length_m"]), "width_m": float(bd["width_m"]), "wall": "timber",
			"wall_h_m": maxf(float(bd["wall_h_m"]), 0.15)}
	return FarmBotSpec.resolve(fs)


## A crop mix as the id list GrowBed cycles through, in proportion.
static func crop_list(mix: Variant) -> Variant:
	if not (mix is Array):
		return "garden"
	var out: Array = []
	for e in mix:
		var n := maxi(int(round(float((e as Dictionary)["share"]) * 10.0)), 1)
		for i in n:
			out.append(str(e["crop"]))
	return out if out.size() > 1 else (out[0] if out.size() == 1 else "garden")
