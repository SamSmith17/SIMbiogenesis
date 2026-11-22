class_name PropModelLights
extends RefCounted

## Bridges model-local lights and strings (designed inside structure modals or
## derived from parametric defaults) with J Light Studio's `PlacedLightLayer`.
##
## Once a prop stands in the world, EVERY light and string on it IS a real
## `PlacedLightLayer` record with `host_id = prop_id`, `host_xf = model_world_xf`,
## and `model_owned = true`. Moving or rotating the prop carries its lights via
## `LightHosts.follow`, and pressing J lets the player edit, restyle, move or
## delete any of them in the world. Re-opening the model's modal reads the live
## hosted lights back into the model's local frame, so edits made in J and edits
## made in the modal stay in two-way sync.

const KEY_MODEL_LIGHTS := "model_lights"
const KEY_SEEDED_SLOTS := "model_lights_seeded"


static func spec_key_for_model(model_id: String) -> String:
	match model_id:
		DomeLabBuilder.MODEL_ID:
			return "domelab_spec"
		ToroidLabBuilder.MODEL_ID:
			return "toroid_spec"
		PalletRackBuilder.MODEL_ID:
			return "rack_spec"
		GreenhouseBuilder.MODEL_ID:
			return GreenhouseSpec.KEY
		EarthshipBuilder.MODEL_ID:
			return EarthshipSpec.KEY
		ShowerHouseBuilder.MODEL_ID:
			return "shower_spec"
		IntermodalUnitBuilder.MODEL_ID:
			return "intermodal_spec"
		GeodesicDomeBuilder.MODEL_ID:
			return "dome_spec"
		LinkageStructureBuilder.MODEL_ID:
			return "linkage_spec"
		BuildingFeatures.MODEL_ID:
			return "building_spec"
		MudBuildingStructureBuilder.MODEL_ID:
			return "mud_spec"
		ToiletBankBuilder.MODEL_ID:
			return "toilet_spec"
		CampKitchenBuilder.MODEL_ID:
			return "kitchen_spec"
	return ""


static func spec_of_record(rec: Dictionary) -> Dictionary:
	var key := spec_key_for_model(str(rec.get("model_id", "")))
	if not key.is_empty() and rec.get(key) is Dictionary:
		return rec[key] as Dictionary
	return {}


static func has_default_lights(model_id: String) -> bool:
	return model_id in [
		DomeLabBuilder.MODEL_ID,
		GeodesicDomeBuilder.MODEL_ID,
		EarthshipBuilder.MODEL_ID,
		ShowerHouseBuilder.MODEL_ID,
		GreenhouseBuilder.MODEL_ID,
	]


# ---------------------------------------------------------------------------
# Parametric default slots (local model frame: ModelRoot origin, Y up)
# ---------------------------------------------------------------------------

static func default_slots_for(model_id: String, spec_in: Dictionary = {}) -> Array:
	match model_id:
		DomeLabBuilder.MODEL_ID:
			return _dome_slots(spec_in)
		GeodesicDomeBuilder.MODEL_ID:
			return _crafted_dome_slots(spec_in)
		EarthshipBuilder.MODEL_ID:
			return _earthship_slots(spec_in)
		ShowerHouseBuilder.MODEL_ID:
			return _shower_slots(spec_in)
		GreenhouseBuilder.MODEL_ID:
			return _greenhouse_slots(spec_in)
	return []


static func _dome_slots(spec_in: Dictionary) -> Array:
	if not bool(spec_in.get("peak_light", true)):
		return []
	var d := DomeLabDesign.solve(spec_in)
	var st: Dictionary = d.get("stats", {})
	var h := maxf(float(st.get("height_m", 3.0)), 0.6)
	var r_max := maxf(float(st.get("radius_max_m", 3.0)), 1.0)
	var peak_xz := Vector2.ZERO
	var verts: PackedVector3Array = (d.get("geo", {}) as Dictionary).get("verts", PackedVector3Array())
	if not verts.is_empty():
		var sum := Vector2.ZERO
		var cnt := 0
		for v in verts:
			if v.y >= h - 0.15:
				sum += Vector2(v.x, v.z)
				cnt += 1
		if cnt > 0:
			peak_xz = sum / float(cnt)
	var py := clampf(h - 0.28, 0.35, maxf(h - 0.12, 0.35))
	return [make_local_point("dome_peak", "omni", "Dome peak light",
		Vector3(peak_xz.x, py, peak_xz.y), Vector3.ZERO, "warm_bulb", {
			"color": "ffd49e",
			"energy": 3.2,
			"range": snappedf(clampf(maxf(r_max * 3.0, h * 2.2), 9.0, 34.0), 0.5),
			"show_body": true,
			"shadow_enabled": false,
			"fade_m": 75.0,
			"schedule": "dusk_dawn",
			"watts": 12.0,
		})]


static func _crafted_dome_slots(spec_in: Dictionary) -> Array:
	if not bool(spec_in.get("peak_light", true)):
		return []
	var r := maxf(float(spec_in.get("radius_m", GeodesicDomeBuilder.DEFAULT_RADIUS_M)), 1.5)
	var py := maxf(r - 0.25, 0.5)
	return [make_local_point("dome_peak", "omni", "Dome peak light",
		Vector3(0.0, py, 0.0), Vector3.ZERO, "warm_bulb", {
			"color": "ffd49e",
			"energy": 1.8,
			"range": snappedf(clampf(r * 2.6, 6.0, 24.0), 0.5),
			"show_body": true,
			"shadow_enabled": false,
			"fade_m": 70.0,
			"schedule": "dusk_dawn",
			"watts": 10.0,
		})]


static func _earthship_slots(spec_in: Dictionary) -> Array:
	var s := EarthshipSpec.resolve(spec_in)
	if not bool(s.get("room_lights", true)):
		return []
	var d := EarthshipDesign.solve(s)
	var rooms: Array = d.get("rooms", [])
	var yc := float((d.get("frame", {}) as Dictionary).get("yc", 1.7))
	var vd := float(s.get("viga_d", 0.25))
	var cy := yc - vd - 0.08
	var rng := snappedf(clampf(maxf(float(s["module_w"]), float(s["module_d"])) * 1.6, 6.5, 14.0), 0.5)
	var out: Array = []
	for i in rooms.size():
		var r: Dictionary = rooms[i]
		var cx := (float(r["x0"]) + float(r["x1"])) * 0.5
		var cz := (float(r["z0"]) + float(r["z1"])) * 0.5
		out.append(make_local_point("earthship_room:%d" % i, "omni",
			"Room %d ceiling bulb" % (i + 1),
			Vector3(cx, cy, cz), Vector3.ZERO, "warm_bulb", {
				"color": "ffd194",
				"energy": 2.2,
				"range": rng,
				"show_body": true,
				"shadow_enabled": false,
				"fade_m": 55.0,
				"schedule": "always",
				"watts": 9.0,
			}))
	return out


static func _shower_slots(spec_in: Dictionary) -> Array:
	var s := ShowerHouseBuilder.resolve(spec_in)
	if not bool(s.get("stall_lights", true)):
		return []
	var y := ShowerHouseBuilder.FLOOR_Y + ShowerHouseBuilder.WALL_H - 0.06
	var out: Array = []
	for k in int(s["stalls"]):
		var f := ShowerHouseBuilder.stall_frame(s, k)
		out.append(make_local_point("shower_stall:%d" % k, "omni",
			"Stall %d light" % (k + 1),
			Vector3(float(f["x"]), y, float(f["z"])), Vector3.ZERO, "warm_bulb", {
				"color": "ffd8a8",
				"energy": 1.8,
				"range": 5.0,
				"attenuation": 1.2,
				"show_body": true,
				"shadow_enabled": false,
				"fade_m": 45.0,
				"schedule": "dusk_dawn",
				"watts": 7.0,
			}))
	return out


static func _greenhouse_slots(spec_in: Dictionary) -> Array:
	var d := GreenhouseDesign.solve(spec_in)
	var s: Dictionary = d["spec"]
	var lt: Dictionary = s.get("lights", {})
	var spectrum := str(lt.get("spectrum", "blurple"))
	var sched_raw := str(lt.get("schedule", "dusk_dawn"))
	var j_sched := "always" if sched_raw == "always" else "dusk_dawn"
	var preset := "grow_full" if spectrum == "full_spectrum" else "grow_blurple"
	var col := GrowLightRack.hex_for_spectrum(spectrum)
	var energy := snappedf(clampf(float(lt.get("ppfd", 200.0)) / 110.0, 1.2, 3.2), 0.05)
	var out: Array = []
	for b in d.get("beds", []):
		var bd: Dictionary = b
		if not bd.has("light"):
			continue
		var bid := str(bd["id"])
		var crop_h := GreenhouseBeds.tallest_crop(bd["crops"])
		var hang := float(bd["wall_h_m"]) + maxf(float(bd["light"]["hang_m"]), crop_h * 0.6 + 0.3)
		hang = clampf(minf(hang, float(bd["wall_h_m"]) + float(bd["headroom_m"]) - 0.15),
			float(bd["wall_h_m"]) + 0.3, 4.0)
		var ly := maxf(hang - 0.05, 0.25)
		var bed_w_total := float(bd["light"]["w"])
		if str(bd["kind"]) == "keyhole":
			var outer_r := float(bd["keyhole"]["outer_r"])
			var inner_r := float(bd["keyhole"]["centre_r"])
			if outer_r <= 3.5:
				out.append(make_local_point("gh_bed:%s:0" % bid, "omni",
					"Grow light (%s)" % bid,
					Vector3(float(bd["x"]), ly, float(bd["z"])), Vector3.ZERO, preset, {
						"color": col, "energy": energy,
						"range": snappedf(clampf(outer_r * 2.4, 5.0, 12.0), 0.5),
						"show_body": false, "shadow_enabled": false, "fade_m": 85.0,
						"schedule": j_sched, "watts": snappedf(bed_w_total, 0.1),
					}))
			else:
				var rm := (inner_r + outer_r) * 0.5
				var count_r := 4
				for k in count_r:
					var ang := TAU * float(k) / float(count_r)
					var pos := Vector3(float(bd["x"]) + cos(ang) * rm, ly, float(bd["z"]) + sin(ang) * rm)
					out.append(make_local_point("gh_bed:%s:%d" % [bid, k], "omni",
						"Grow light %s.%d" % [bid, k + 1], pos, Vector3.ZERO, preset, {
							"color": col, "energy": energy,
							"range": snappedf(clampf(outer_r * 1.5, 6.0, 16.0), 0.5),
							"show_body": false, "shadow_enabled": false, "fade_m": 85.0,
							"schedule": j_sched,
							"watts": snappedf(bed_w_total / float(count_r), 0.1),
						}))
		else:
			var L := float(bd["length_m"])
			var W := float(bd["width_m"])
			var count := clampi(int(round(L / 4.5)), 1, 4)
			for k in count:
				var lx := float(bd["x"]) + (-L * 0.5 + L * (float(k) + 0.5) / float(count))
				var nm := ("Grow light (%s)" % bid) if count == 1 else ("Grow light %s.%d" % [bid, k + 1])
				out.append(make_local_point("gh_bed:%s:%d" % [bid, k], "omni", nm,
					Vector3(lx, ly, float(bd["z"])), Vector3.ZERO, preset, {
						"color": col, "energy": energy,
						"range": snappedf(clampf(maxf(W * 3.0, (L / float(count)) * 1.45), 4.5, 14.0), 0.5),
						"show_body": false, "shadow_enabled": false, "fade_m": 85.0,
						"schedule": j_sched,
						"watts": snappedf(bed_w_total / float(count), 0.1),
					}))
	return out


# ---------------------------------------------------------------------------
# Quick-add smart presets per model
# ---------------------------------------------------------------------------

static func quick_presets_for(model_id: String, spec_in: Dictionary, bounds: AABB = AABB()) -> Array:
	var out: Array = []
	match model_id:
		DomeLabBuilder.MODEL_ID:
			var d := DomeLabDesign.solve(spec_in)
			var st: Dictionary = d.get("stats", {})
			var r_fl := maxf(float(st.get("floor_radius_m", 3.0)), 1.2)
			var h := maxf(float(st.get("height_m", 3.0)), 1.2)
			out.append({"id": "dome_eave_ring", "label": "+ Perimeter string",
				"tip": "String warm patio bulbs round the dome at head height",
				"make": func() -> Array:
					var y := clampf(minf(h * 0.45, 2.2), 0.8, h - 0.3)
					var rr := sqrt(maxf(r_fl * r_fl - y * y * 0.35, 0.6)) * 0.92
					return [_ring_string("Perimeter string", rr, y, 10, "patio")]})
			out.append({"id": "dome_crown_ring", "label": "+ Crown fairy ring",
				"tip": "String fairy lights round the upper crown of the dome",
				"make": func() -> Array:
					var y := h * 0.78
					var rr := maxf(r_fl * 0.52, 0.5)
					return [_ring_string("Crown fairy ring", rr, y, 8, "fairy")]})
		ToroidLabBuilder.MODEL_ID:
			var d := ToroidLabDesign.solve(spec_in)
			var st: Dictionary = d.get("stats", {})
			var throat_r := maxf(float(st.get("throat_r_m", 1.2)), 0.5)
			var outer_r := maxf(float(st.get("outer_r_m", 3.5)), 1.5)
			var h := maxf(float(st.get("height_m", 3.0)), 1.5)
			out.append({"id": "toroid_throat_ring", "label": "+ Throat ring string",
				"tip": "String lights round the inner top ring of the toroid",
				"make": func() -> Array:
					return [_ring_string("Throat ring string", throat_r + 0.15, h * 0.72, 12, "patio")]})
			out.append({"id": "toroid_outer_ring", "label": "+ Canopy ring string",
				"tip": "String warm lights round the outer canopy eaves",
				"make": func() -> Array:
					return [_ring_string("Canopy ring string", outer_r * 0.88, h * 0.58, 16, "patio")]})
			out.append({"id": "toroid_uplights", "label": "+ Column uplights (4)",
				"tip": "Four uplight spots round the inner column",
				"make": func() -> Array:
					var items: Array = []
					for k in 4:
						var a := TAU * float(k) / 4.0
						var p := Vector3(cos(a) * (throat_r + 0.25), 0.35, sin(a) * (throat_r + 0.25))
						items.append(make_local_point("", "spot", "Column uplight %d" % (k + 1),
							p, Vector3(75.0, rad_to_deg(-a), 0.0), "uplight_par", {
								"color": "ffb870", "energy": 3.5, "range": h * 2.2,
								"spot_angle": 28.0, "schedule": "dusk_dawn", "shadow_enabled": false,
								"fade_m": 70.0, "show_body": true}))
					return items})
		PalletRackBuilder.MODEL_ID:
			var s := PalletRackBuilder.resolve_spec(spec_in)
			var fb := PalletRackBuilder.fused_bounds(s, 0)
			var lvs: Array = s.get("level_heights_ft", [8.0])
			var top_y := float(s.get("upright_height_ft", 12)) * PalletRackBuilder.FT - 0.12
			var ceil_y := top_y
			for lvf in lvs:
				if float(lvf) >= 5.5:
					ceil_y = float(lvf) * PalletRackBuilder.FT - 0.14
					break
			out.append({"id": "rack_bay_bulbs", "label": "+ Bay ceiling bulbs",
				"tip": "A warm ceiling bulb centred under each bay of the ground deck",
				"make": func() -> Array:
					var nb := maxi(int(s.get("bay_count", 1)), 1)
					var nc := maxi(int(s.get("column_count", 1)), 1)
					var items: Array = []
					for ci in nc:
						for bi in nb:
							var bx := fb.position.x + fb.size.x * (float(bi) + 0.5) / float(nb)
							var bz := fb.position.y + fb.size.y * (float(ci) + 0.5) / float(nc)
							items.append(make_local_point("", "omni", "Bay %d.%d bulb" % [ci + 1, bi + 1],
								Vector3(bx, ceil_y, bz), Vector3.ZERO, "warm_bulb", {
									"color": "ffd194", "energy": 1.35, "range": 6.5,
									"show_body": true, "shadow_enabled": false,
									"fade_m": 60.0, "schedule": "dusk_dawn"}))
					return items})
			out.append({"id": "rack_front_string", "label": "+ Front beam festoon",
				"tip": "Patio festoon string hung along the front beam",
				"make": func() -> Array:
					var nb := maxi(int(s.get("bay_count", 2)), 2)
					var pts: Array = []
					for i in nb + 1:
						var px := lerpf(fb.position.x + 0.1, fb.end.x - 0.1, float(i) / float(nb))
						pts.append(Vector3(px, ceil_y + 0.04, fb.position.y + 0.08))
					return [make_local_string("", "Front festoon", pts, "patio", {"sag": 0.22})]})
			out.append({"id": "rack_roof_string", "label": "+ Top perimeter string",
				"tip": "Patio festoon string all the way round the top uprights",
				"make": func() -> Array:
					var x0 := fb.position.x + 0.08
					var x1 := fb.end.x - 0.08
					var z0 := fb.position.y + 0.08
					var z1 := fb.end.y - 0.08
					return [make_local_string("", "Top perimeter string", [
						Vector3(x0, top_y, z0), Vector3(x1, top_y, z0),
						Vector3(x1, top_y, z1), Vector3(x0, top_y, z1),
						Vector3(x0, top_y, z0)], "patio", {"sag": 0.25})]})
		GreenhouseBuilder.MODEL_ID:
			var d := GreenhouseDesign.solve(spec_in)
			var s: Dictionary = d["spec"]
			var h := maxf(float(d["stats"].get("height_m", 3.2)), 1.8)
			var hl := float(s["length_m"]) * 0.5 - 0.25
			out.append({"id": "gh_ridge_string", "label": "+ Ridge work string",
				"tip": "Warm patio bulbs strung down the middle under the ridge",
				"make": func() -> Array:
					if str(s["form"]) == "dome":
						return [_ring_string("Dome ring string", float(s["width_m"]) * 0.35, h * 0.62, 8, "patio")]
					var spans := clampi(int(round(float(s["length_m"]) / 4.0)), 2, 10)
					var pts: Array = []
					for i in spans + 1:
						pts.append(Vector3(lerpf(-hl, hl, float(i) / float(spans)), h - 0.22, 0.0))
					return [make_local_string("", "Ridge string", pts, "patio", {"sag": 0.18})]})
		EarthshipBuilder.MODEL_ID:
			var d := EarthshipDesign.solve(spec_in)
			var fr: Dictionary = d["frame"]
			var x0 := float(fr["xg0"]) + 0.3
			var x1 := float(fr["xg1"]) - 0.3
			var y := float(fr["yc"]) - 0.18
			var z := float(d["spec"]["corridor_d"]) * 0.45
			out.append({"id": "es_corridor_string", "label": "+ Greenhouse corridor string",
				"tip": "Warm patio string along the planter corridor",
				"make": func() -> Array:
					var spans := clampi(int(round((x1 - x0) / 3.5)), 2, 10)
					var pts: Array = []
					for i in spans + 1:
						pts.append(Vector3(lerpf(x0, x1, float(i) / float(spans)), y, z))
					return [make_local_string("", "Corridor string", pts, "patio", {"sag": 0.18})]})
		ShowerHouseBuilder.MODEL_ID:
			var s := ShowerHouseBuilder.resolve(spec_in)
			var fp := ShowerHouseBuilder.footprint(s)
			var y := ShowerHouseBuilder.FLOOR_Y + ShowerHouseBuilder.WALL_H + 0.12
			var z := ShowerHouseBuilder.STALL_D * 0.5 + ShowerHouseBuilder.PORCH - 0.1
			if int(s["rows"]) == 2:
				z += (ShowerHouseBuilder.STALL_D + ShowerHouseBuilder.BACK_GAP) * 0.5
			out.append({"id": "shower_porch_string", "label": "+ Porch festoon string",
				"tip": "Warm patio bulbs strung across the front porch overhang",
				"make": func() -> Array:
					var hx := maxf(fp.x * 0.5 - 0.08, 0.4)
					var spans := clampi(int(round(fp.x / 2.0)), 1, 6)
					var pts: Array = []
					for i in spans + 1:
						pts.append(Vector3(lerpf(-hx, hx, float(i) / float(spans)), y, z))
					return [make_local_string("", "Porch string", pts, "patio", {"sag": 0.15})]})
		_:
			if bounds.size.length_squared() > 0.05:
				var c := bounds.get_center()
				var top_y := bounds.end.y - minf(0.22, bounds.size.y * 0.12)
				out.append({"id": "generic_overhead", "label": "+ Overhead bulb",
					"tip": "Warm omni light hung near the top centre of the model",
					"make": func() -> Array:
						return [make_local_point("", "omni", "Overhead light",
							Vector3(c.x, top_y, c.z), Vector3.ZERO, "warm_bulb", {
								"color": "ffd194", "energy": 1.6,
								"range": snappedf(clampf(bounds.size.length() * 1.4, 5.0, 24.0), 0.5),
								"show_body": true, "shadow_enabled": false,
								"fade_m": 60.0, "schedule": "dusk_dawn"})]})
				if bounds.size.x > 1.2 and bounds.size.z > 1.2:
					out.append({"id": "generic_eave_string", "label": "+ Perimeter string",
						"tip": "Patio festoon string round the upper perimeter of the model",
						"make": func() -> Array:
							var x0 := bounds.position.x + 0.1
							var x1 := bounds.end.x - 0.1
							var z0 := bounds.position.z + 0.1
							var z1 := bounds.end.z - 0.1
							var py := bounds.position.y + bounds.size.y * 0.82
							return [make_local_string("", "Perimeter string", [
								Vector3(x0, py, z0), Vector3(x1, py, z0),
								Vector3(x1, py, z1), Vector3(x0, py, z1),
								Vector3(x0, py, z0)], "patio", {"sag": 0.22})]})
	return out


static func _ring_string(label: String, radius: float, y: float, segments: int, preset: String) -> Dictionary:
	var pts: Array = []
	var n := maxi(segments, 4)
	for i in n + 1:
		var a := TAU * float(i % n) / float(n)
		pts.append(Vector3(cos(a) * radius, y, sin(a) * radius))
	return make_local_string("", label, pts, preset, {"sag": 0.18})


# ---------------------------------------------------------------------------
# Local item constructors & normalization
# ---------------------------------------------------------------------------

static func make_local_point(slot: String, kind: String, name: String, pos: Vector3,
		rot_deg: Vector3, preset: String = "", overrides: Dictionary = {}) -> Dictionary:
	var base := PlacedLightStyles.preset_fields(preset, kind) if not preset.is_empty() else {}
	var fields := PlacedLightStyles.resolve(kind, base, overrides)
	if not preset.is_empty():
		fields["preset"] = preset
	return {
		"id": "",
		"slot": slot,
		"kind": kind,
		"preset": preset,
		"name": name,
		"enabled": true,
		"x": snappedf(pos.x, 0.001),
		"y": snappedf(pos.y, 0.001),
		"z": snappedf(pos.z, 0.001),
		"pitch": snappedf(rot_deg.x, 0.01),
		"yaw": snappedf(rot_deg.y, 0.01),
		"roll": snappedf(rot_deg.z, 0.01),
		"waypoints": [],
		"fields": fields,
	}


static func make_local_string(slot: String, name: String, points: Array,
		preset: String = "patio", overrides: Dictionary = {}) -> Dictionary:
	var base := PlacedLightStyles.preset_fields(preset, "string") if not preset.is_empty() else {}
	var fields := PlacedLightStyles.resolve("string", base, overrides)
	fields["preset"] = preset if not preset.is_empty() else "patio"
	var wps: Array = []
	for p in points:
		var v := p as Vector3 if p is Vector3 else PlacedLightLayer.waypoint_vec(p as Dictionary)
		wps.append({"x": snappedf(v.x, 0.001), "y": snappedf(v.y, 0.001), "z": snappedf(v.z, 0.001)})
	var p0: Dictionary = wps[0] if not wps.is_empty() else {"x": 0.0, "y": 0.0, "z": 0.0}
	return {
		"id": "",
		"slot": slot,
		"kind": "string",
		"preset": str(fields["preset"]),
		"name": name,
		"enabled": true,
		"x": float(p0["x"]),
		"y": float(p0["y"]),
		"z": float(p0["z"]),
		"pitch": 0.0,
		"yaw": 0.0,
		"roll": 0.0,
		"waypoints": wps,
		"fields": fields,
	}


static func normalize_local_item(raw: Dictionary) -> Dictionary:
	var kind := str(raw.get("kind", "omni"))
	if not (kind in PlacedLightStyles.KINDS):
		kind = "omni"
	var preset := str(raw.get("preset", (raw.get("fields", {}) as Dictionary).get("preset", "")))
	var base := PlacedLightStyles.preset_fields(preset, kind) if not preset.is_empty() else {}
	var f_in: Dictionary = raw.get("fields", {}) if raw.get("fields") is Dictionary else {}
	var fields := PlacedLightStyles.resolve(kind, base, f_in)
	if not preset.is_empty():
		fields["preset"] = preset
	var wps: Array = []
	if kind == "string" and raw.get("waypoints") is Array:
		for w in raw["waypoints"]:
			if w is Vector3:
				var vv := w as Vector3
				wps.append({"x": snappedf(vv.x, 0.001), "y": snappedf(vv.y, 0.001), "z": snappedf(vv.z, 0.001)})
			elif w is Dictionary:
				wps.append({"x": snappedf(float(w.get("x", 0.0)), 0.001),
					"y": snappedf(float(w.get("y", 0.0)), 0.001),
					"z": snappedf(float(w.get("z", 0.0)), 0.001)})
	var x := snappedf(float(raw.get("x", 0.0)), 0.001)
	var y := snappedf(float(raw.get("y", 0.0)), 0.001)
	var z := snappedf(float(raw.get("z", 0.0)), 0.001)
	if kind == "string" and not wps.is_empty():
		x = float(wps[0]["x"])
		y = float(wps[0]["y"])
		z = float(wps[0]["z"])
	return {
		"id": str(raw.get("id", "")),
		"slot": str(raw.get("slot", raw.get("model_slot", ""))),
		"kind": kind,
		"preset": str(fields.get("preset", preset)),
		"name": str(raw.get("name", "")),
		"enabled": bool(raw.get("enabled", true)),
		"x": x, "y": y, "z": z,
		"pitch": snappedf(float(raw.get("pitch", 0.0)), 0.01),
		"yaw": snappedf(float(raw.get("yaw", 0.0)), 0.01),
		"roll": snappedf(float(raw.get("roll", 0.0)), 0.01),
		"waypoints": wps,
		"fields": fields,
	}


static func serialize_for_spec(items: Array) -> Array:
	var out: Array = []
	for it in items:
		if not (it is Dictionary):
			continue
		var n := normalize_local_item(it as Dictionary)
		# Strip runtime world light id when saving into a reusable spec/preset.
		n.erase("id")
		out.append(n)
	return out


# ---------------------------------------------------------------------------
# Modal <-> World two-way read & parametric reconciliation
# ---------------------------------------------------------------------------

## Load the local light list for a modal. When `prop_id` names a placed prop,
## reads the LIVE hosted lights from `PlacedLightLayer` (so J edits appear in
## the modal!). When designing a fresh prop, reads `spec["model_lights"]` or
## generates `default_slots_for(model_id, spec)`.
static func read_for_modal(main: Node, prop_id: String, model_id: String, spec: Dictionary) -> Array:
	if main != null and not prop_id.is_empty():
		var prec := PlacedPropService.get_prop_record(main, prop_id)
		var layer := PlacedLightService.get_layer(main)
		if not prec.is_empty() and layer != null:
			var xf := PlacedPropRuntime.model_world_xf(prec, TerrainSurfaceQuery.ground_y_callable(main))
			var out: Array = []
			for r in layer.lights:
				var rec := r as Dictionary
				if str(rec.get("host_id", "")) == prop_id:
					out.append(world_rec_to_local(layer, rec, xf))
			var seeded: Array = prec.get(KEY_SEEDED_SLOTS, []) if prec.get(KEY_SEEDED_SLOTS) is Array else []
			return sync_parametric_slots(out, model_id, spec, seeded, false)
	if spec.get(KEY_MODEL_LIGHTS) is Array:
		var stored: Array = []
		for it in (spec[KEY_MODEL_LIGHTS] as Array):
			if it is Dictionary:
				stored.append(normalize_local_item(it as Dictionary))
		# In a saved preset, all default slots that are absent from `stored` were
		# intentionally omitted unless geometry grew new rooms/stalls/beds.
		var present_slots: Array = []
		for d in default_slots_for(model_id, spec):
			var sl := str((d as Dictionary).get("slot", ""))
			for s_it in stored:
				if str((s_it as Dictionary).get("slot", "")) == sl:
					present_slots.append(sl)
		return stored
	return default_slots_for(model_id, spec)


## Reconcile `items` when parametric model settings (size, room count, stall
## count, bed layout, greenhouse spectrum / schedule, peak_light / room_lights /
## stall_lights toggles) change inside a modal.
## `force_gh_look`: true when greenhouse spectrum/schedule/ppfd changed in the modal.
static func sync_parametric_slots(items: Array, model_id: String, spec: Dictionary,
		already_seeded: Array = [], force_gh_look: bool = false) -> Array:
	if not has_default_lights(model_id):
		var plain: Array = []
		for it in items:
			if it is Dictionary:
				plain.append(normalize_local_item(it as Dictionary))
		return plain
	var wanted := default_slots_for(model_id, spec)
	var want_by_slot := {}
	for w in wanted:
		want_by_slot[str((w as Dictionary)["slot"])] = w
	var have_by_slot := {}
	var custom: Array = []
	for it in items:
		if not (it is Dictionary):
			continue
		var norm := normalize_local_item(it as Dictionary)
		var sl := str(norm.get("slot", ""))
		if sl.is_empty():
			custom.append(norm)
		else:
			have_by_slot[sl] = norm
	var out: Array = []
	for w in wanted:
		var wd := w as Dictionary
		var sl := str(wd["slot"])
		if have_by_slot.has(sl):
			var cur: Dictionary = (have_by_slot[sl] as Dictionary).duplicate(true)
			# Follow the parametric geometry (peak height, room centres, stall frames, bed racks).
			cur["x"] = wd["x"]
			cur["y"] = wd["y"]
			cur["z"] = wd["z"]
			cur["name"] = wd["name"]
			var wf: Dictionary = wd["fields"]
			var cf: Dictionary = cur["fields"]
			cf["range"] = wf["range"]
			cf["watts"] = wf["watts"]
			if force_gh_look and sl.begins_with("gh_bed:"):
				cur["preset"] = wd["preset"]
				cf["preset"] = wf.get("preset", wd["preset"])
				cf["color"] = wf["color"]
				cf["energy"] = wf["energy"]
				cf["schedule"] = wf["schedule"]
			out.append(cur)
		elif not (sl in already_seeded):
			out.append(wd.duplicate(true))
	out.append_array(custom)
	return out


# ---------------------------------------------------------------------------
# Coordinate conversion (local ModelRoot <-> world PlacedLightLayer)
# ---------------------------------------------------------------------------

static func world_rec_to_local(layer: PlacedLightLayer, rec: Dictionary, model_xf: Transform3D) -> Dictionary:
	var inv := model_xf.affine_inverse()
	var inv_b := model_xf.basis.orthonormalized().inverse()
	var kind := str(rec.get("kind", "omni"))
	var fields := layer.resolved(rec)
	var wpos := Vector3(float(rec.get("x", 0.0)), float(rec.get("y", 0.0)), float(rec.get("z", 0.0)))
	var lpos := inv * wpos
	var wb := LightGizmoMath.basis_of(Vector3(float(rec.get("pitch", 0.0)),
		float(rec.get("yaw", 0.0)), float(rec.get("roll", 0.0))))
	var e := (inv_b * wb).get_euler()
	var wps: Array = []
	if kind == "string":
		for w in PlacedLightLayer.waypoints_of(rec):
			var lv := inv * (w as Vector3)
			wps.append({"x": snappedf(lv.x, 0.001), "y": snappedf(lv.y, 0.001), "z": snappedf(lv.z, 0.001)})
		if not wps.is_empty():
			lpos = Vector3(float(wps[0]["x"]), float(wps[0]["y"]), float(wps[0]["z"]))
	return {
		"id": str(rec.get("id", "")),
		"slot": str(rec.get("model_slot", "")),
		"kind": kind,
		"preset": str(fields.get("preset", "")),
		"name": str(rec.get("name", "")),
		"enabled": bool(rec.get("enabled", true)),
		"x": snappedf(lpos.x, 0.001),
		"y": snappedf(lpos.y, 0.001),
		"z": snappedf(lpos.z, 0.001),
		"pitch": snappedf(rad_to_deg(e.x), 0.01),
		"yaw": snappedf(rad_to_deg(e.y), 0.01),
		"roll": snappedf(rad_to_deg(e.z), 0.01),
		"waypoints": wps,
		"fields": fields,
	}


static func local_to_world_pose(item: Dictionary, model_xf: Transform3D) -> Dictionary:
	var n := normalize_local_item(item)
	var wpos := model_xf * Vector3(float(n["x"]), float(n["y"]), float(n["z"]))
	var lb := LightGizmoMath.basis_of(Vector3(float(n["pitch"]), float(n["yaw"]), float(n["roll"])))
	var e := (model_xf.basis.orthonormalized() * lb).get_euler()
	var wps: Array = []
	if str(n["kind"]) == "string":
		for w in n["waypoints"]:
			var wd := w as Dictionary
			var wv := model_xf * Vector3(float(wd["x"]), float(wd["y"]), float(wd["z"]))
			wps.append(Vector3(snappedf(wv.x, 0.001), snappedf(wv.y, 0.001), snappedf(wv.z, 0.001)))
		if not wps.is_empty():
			wpos = wps[0]
	return {
		"pos": Vector3(snappedf(wpos.x, 0.001), snappedf(wpos.y, 0.001), snappedf(wpos.z, 0.001)),
		"rot": Vector3(snappedf(rad_to_deg(e.x), 0.01), snappedf(rad_to_deg(e.y), 0.01), snappedf(rad_to_deg(e.z), 0.01)),
		"waypoints": wps,
	}


# ---------------------------------------------------------------------------
# World synchronization (placement, modal Apply, world load, duplication)
# ---------------------------------------------------------------------------

## Materialize / update a placed prop's lights in `PlacedLightLayer`.
## - When `explicit_local_lights` is an Array (e.g. modal Apply or PropLightsModal
##   Save), that exact list becomes the prop's lights (deleting any hosted light
##   the user removed in the modal).
## - When `explicit_local_lights` is null (e.g. prop placement, `GreenhouseWorld.sync`,
##   `sync_earthship`, or world-load seeding), uses `rec["model_lights"]` or
##   `spec["model_lights"]` if present on a newly placed prop, else reconciles
##   parametric slots while keeping every hand-added J light on the prop intact.
static func sync_prop(main: Node, prop_id: String, explicit_local_lights: Variant = null,
		force_gh_look: bool = false, save_immediately: bool = true) -> Array:
	if main == null or prop_id.is_empty():
		return []
	var prec := PlacedPropService.get_prop_record(main, prop_id)
	if prec.is_empty():
		return []
	var layer := PlacedLightService.get_layer(main)
	if layer == null:
		return []
	var model_id := str(prec.get("model_id", ""))
	var spec := spec_of_record(prec)
	var gy := TerrainSurfaceQuery.ground_y_callable(main)
	var model_xf := PlacedPropRuntime.model_world_xf(prec, gy)
	var xf_arr := LightHosts.xf_to_array(model_xf)

	var seeded: Array = []
	if prec.get(KEY_SEEDED_SLOTS) is Array:
		for s in (prec[KEY_SEEDED_SLOTS] as Array):
			seeded.append(str(s))

	# Existing lights hosted on this prop in PlacedLightLayer.
	var existing_recs: Dictionary = {}   # light_id -> rec
	var existing_by_slot: Dictionary = {}  # slot -> rec
	for r in layer.lights:
		var rec := r as Dictionary
		if str(rec.get("host_id", "")) == prop_id:
			var lid := str(rec.get("id", ""))
			existing_recs[lid] = rec
			var sl := str(rec.get("model_slot", ""))
			if not sl.is_empty():
				existing_by_slot[sl] = rec

	var target_locals: Array = []
	var authoritative := false
	if explicit_local_lights is Array:
		authoritative = true
		for it in (explicit_local_lights as Array):
			if it is Dictionary:
				target_locals.append(normalize_local_item(it as Dictionary))
	elif existing_recs.is_empty() and (prec.get(KEY_MODEL_LIGHTS) is Array or spec.get(KEY_MODEL_LIGHTS) is Array):
		authoritative = true
		var src_arr: Array = prec[KEY_MODEL_LIGHTS] if prec.get(KEY_MODEL_LIGHTS) is Array else spec[KEY_MODEL_LIGHTS]
		for it in src_arr:
			if it is Dictionary:
				target_locals.append(normalize_local_item(it as Dictionary))
	else:
		if not has_default_lights(model_id):
			return existing_recs.keys()
		var cur_locals: Array = []
		for lid in existing_recs:
			cur_locals.append(world_rec_to_local(layer, existing_recs[lid], model_xf))
		target_locals = sync_parametric_slots(cur_locals, model_id, spec, seeded, force_gh_look)
		authoritative = true

	var kept_ids := {}
	var touched_ids: Array = []
	var changed_lights := false

	for item_v in target_locals:
		var item: Dictionary = item_v
		var kind := str(item["kind"])
		var sl := str(item.get("slot", ""))
		if not sl.is_empty() and not (sl in seeded):
			seeded.append(sl)
		var pose := local_to_world_pose(item, model_xf)
		var rec_id := str(item.get("id", ""))
		if rec_id.is_empty() and not sl.is_empty() and existing_by_slot.has(sl):
			rec_id = str((existing_by_slot[sl] as Dictionary)["id"])
		if not rec_id.is_empty() and existing_recs.has(rec_id):
			kept_ids[rec_id] = true
			var wrec: Dictionary = existing_recs[rec_id]
			wrec["name"] = str(item.get("name", wrec.get("name", "")))
			wrec["enabled"] = bool(item.get("enabled", true))
			wrec["host_id"] = prop_id
			wrec["host_xf"] = xf_arr
			if not sl.is_empty():
				wrec["model_slot"] = sl
				wrec["model_owned"] = true
			var pos: Vector3 = pose["pos"]
			var rot: Vector3 = pose["rot"]
			wrec["x"] = pos.x
			wrec["y"] = pos.y
			wrec["z"] = pos.z
			wrec["pitch"] = rot.x
			wrec["yaw"] = rot.y
			wrec["roll"] = rot.z
			if kind == "string":
				var wps: Array = pose["waypoints"]
				if wps.size() >= 2:
					layer.set_waypoints(rec_id, wps)
			_apply_fields_to_light(main, layer, wrec, item)
			touched_ids.append(rec_id)
			changed_lights = true
		else:
			# Avoid duplicating a light the player already placed by hand right on a default slot.
			if not sl.is_empty() and _has_nearby_unslotted_light(layer, prop_id, pose["pos"], 0.55):
				continue
			var sid := _style_id_for_item(main, layer, item)
			var new_id := ""
			if kind == "string":
				var wps2: Array = pose["waypoints"]
				if wps2.size() >= 2:
					new_id = layer.add_string(wps2, sid)
			else:
				new_id = layer.add_light(kind, pose["pos"], pose["rot"], sid)
			if new_id.is_empty():
				continue
			var nrec := layer.find_light(new_id)
			nrec["name"] = str(item.get("name", ""))
			nrec["enabled"] = bool(item.get("enabled", true))
			nrec["host_id"] = prop_id
			nrec["host_xf"] = xf_arr
			nrec["host_auto"] = true
			nrec["model_owned"] = true
			if not sl.is_empty():
				nrec["model_slot"] = sl
			_apply_fields_to_light(main, layer, nrec, item)
			kept_ids[new_id] = true
			touched_ids.append(new_id)
			changed_lights = true

	if authoritative:
		var to_remove: Array = []
		for lid in existing_recs:
			if not kept_ids.has(lid):
				var er: Dictionary = existing_recs[lid]
				# When explicit_local_lights was passed from a modal, remove anything
				# deleted in the modal; during automatic parametric sync, only remove
				# obsolete parametric slots (never hand-placed J lights!).
				if explicit_local_lights is Array or not str(er.get("model_slot", "")).is_empty():
					to_remove.append(str(lid))
		if not to_remove.is_empty():
			PlacedLightService.delete_ids(main, to_remove)
			changed_lights = true

	# Record all default slots that were evaluated so user deletions in J stick.
	for d in default_slots_for(model_id, spec):
		var dsl := str((d as Dictionary)["slot"])
		if not dsl.is_empty() and not (dsl in seeded):
			seeded.append(dsl)
	var prop_patch := {}
	if prec.get(KEY_SEEDED_SLOTS) != seeded and (not seeded.is_empty() or prec.has(KEY_SEEDED_SLOTS)):
		prop_patch[KEY_SEEDED_SLOTS] = seeded
	if prec.has(KEY_MODEL_LIGHTS):
		prop_patch[KEY_MODEL_LIGHTS] = null
	if not prop_patch.is_empty():
		var prop_layer := PlacedPropService._layer_for_main(main)
		if prop_layer != null:
			prop_layer.update_prop(prop_id, prop_patch)
			if save_immediately:
				PlacedPropService._save_layer(main, prop_layer)

	if not touched_ids.is_empty():
		PlacedLightService.refresh_ids(main, touched_ids)
	if changed_lights and save_immediately:
		PlacedLightService.save(main)
		PlacedLightService.notify()
	return kept_ids.keys()


static func _style_id_for_item(main: Node, layer: PlacedLightLayer, item: Dictionary) -> String:
	var kind := str(item["kind"])
	var preset := str(item.get("preset", ""))
	if not preset.is_empty() and (PlacedLightStyles.PRESETS.get(kind, {}) as Dictionary).has(preset):
		for sid in layer.styles.keys():
			var st: Dictionary = layer.styles[sid]
			if str(st.get("kind", "")) == kind and str(st.get("preset_id", "")) == preset:
				return str(sid)
		var nsid := layer.add_style(PlacedLightStyles.preset_label(kind, preset), kind,
			PlacedLightStyles.preset_fields(preset, kind))
		layer.styles[nsid]["preset_id"] = preset
		return nsid
	return layer.ensure_default_style(kind)


static func _apply_fields_to_light(_main: Node, layer: PlacedLightLayer, wrec: Dictionary, item: Dictionary) -> void:
	var kind := str(wrec.get("kind", "omni"))
	var fields: Dictionary = item.get("fields", {})
	var preset := str(item.get("preset", fields.get("preset", "")))
	if not preset.is_empty() and (PlacedLightStyles.PRESETS.get(kind, {}) as Dictionary).has(preset):
		var cur_st: Dictionary = layer.styles.get(str(wrec.get("style_id", "")), {})
		if str(cur_st.get("preset_id", "")) != preset and (wrec.get("overrides", {}) as Dictionary).is_empty():
			wrec["style_id"] = _style_id_for_item(_main, layer, item)
	var st_fields: Dictionary = (layer.styles.get(str(wrec.get("style_id", "")), {}) as Dictionary).get("fields", {})
	wrec["overrides"] = PlacedLightStyles.prune_overrides(kind, st_fields, fields)


static func _has_nearby_unslotted_light(layer: PlacedLightLayer, prop_id: String, pos: Vector3, tol_m: float) -> bool:
	for r in layer.lights:
		var rec := r as Dictionary
		if not str(rec.get("model_slot", "")).is_empty():
			continue
		if str(rec.get("kind", "")) == "string":
			continue
		var hid := str(rec.get("host_id", ""))
		if not hid.is_empty() and hid != prop_id:
			continue
		if layer.position_of(rec).distance_to(pos) <= tol_m:
			return true
	return false


## Seed parametric default lights on any already-placed dome, Earthship, shower
## house, or greenhouse (with grow lights enabled) that predates model lights.
## Runs once per world load after props and lights are built, saving immediately
## so world fingerprints and asset packs stay deterministic.
static func ensure_world_props_seeded(main: Node) -> int:
	if main == null:
		return 0
	var prop_layer := PlacedPropService._layer_for_main(main)
	var light_layer := PlacedLightService.get_layer(main)
	if prop_layer == null or light_layer == null:
		return 0
	var seeded_props := 0
	for item in prop_layer.props:
		if not (item is Dictionary):
			continue
		var rec := item as Dictionary
		var mid := str(rec.get("model_id", ""))
		if not has_default_lights(mid) and not (rec.get(KEY_MODEL_LIGHTS) is Array):
			continue
		if rec.has(KEY_SEEDED_SLOTS) and not (rec.get(KEY_MODEL_LIGHTS) is Array):
			continue
		var pid := str(rec.get("id", ""))
		if pid.is_empty():
			continue
		sync_prop(main, pid, null, false, false)
		seeded_props += 1
	if seeded_props > 0:
		PlacedPropService._save_layer(main, prop_layer)
		PlacedLightService.save(main)
		PlacedLightService.notify()
	return seeded_props


## Copy every J light hosted on `source_id` onto `new_id` in `new_id`'s model frame.
static func duplicate_for_prop(main: Node, source_id: String, new_id: String) -> void:
	if main == null or source_id.is_empty() or new_id.is_empty() or source_id == new_id:
		return
	var srec := PlacedPropService.get_prop_record(main, source_id)
	var nrec := PlacedPropService.get_prop_record(main, new_id)
	var layer := PlacedLightService.get_layer(main)
	if srec.is_empty() or nrec.is_empty() or layer == null:
		return
	var gy := TerrainSurfaceQuery.ground_y_callable(main)
	var sxf := PlacedPropRuntime.model_world_xf(srec, gy)
	var locals: Array = []
	for r in layer.lights.duplicate():
		var rec := r as Dictionary
		if str(rec.get("host_id", "")) == source_id:
			var loc := world_rec_to_local(layer, rec, sxf)
			loc["id"] = ""
			locals.append(loc)
	if not locals.is_empty():
		sync_prop(main, new_id, locals, false, true)


## Count how many lights/strings in `PlacedLightLayer` are currently hosted on `prop_id`.
static func count_for_prop(main: Node, prop_id: String) -> int:
	if main == null or prop_id.is_empty():
		return 0
	var layer := PlacedLightService.get_layer(main)
	if layer == null:
		return 0
	var n := 0
	for r in layer.lights:
		if str((r as Dictionary).get("host_id", "")) == prop_id:
			n += 1
	return n


## Ids of all lights/strings hosted on `prop_id`.
static func ids_for_prop(main: Node, prop_id: String) -> Array:
	var out: Array = []
	if main == null or prop_id.is_empty():
		return out
	var layer := PlacedLightService.get_layer(main)
	if layer == null:
		return out
	for r in layer.lights:
		var rec := r as Dictionary
		if str(rec.get("host_id", "")) == prop_id:
			out.append(str(rec.get("id", "")))
	return out


# ---------------------------------------------------------------------------
# Pure-mesh raycaster for clicking surfaces inside 3D designer studios
# ---------------------------------------------------------------------------

const _FACE_CACHE_META := "_pml_faces"
const _SKIP_NODE_NAMES := ["CollisionMesh", "Earth", "Ground", "ScalePerson", "ModelLightsPreview"]


## Raycast against all visible MeshInstance3D / MultiMeshInstance3D geometry
## under `root`. Ray and returned `position` / `normal` are in `root`'s parent
## space (world space of the studio SubViewport).
static func raycast_model(root: Node3D, ray_o: Vector3, ray_d: Vector3, max_dist: float = 400.0) -> Dictionary:
	var best := {"valid": false, "t": max_dist, "position": Vector3.ZERO, "normal": Vector3.UP}
	if root == null or ray_d.length_squared() < 1e-8:
		return best
	var dir := ray_d.normalized()
	_walk_raycast(root, ray_o, dir, best)
	return best


static func _walk_raycast(node: Node, ray_o: Vector3, ray_d: Vector3, best: Dictionary) -> void:
	if node is Node3D and not (node as Node3D).visible:
		return
	if String(node.name) in _SKIP_NODE_NAMES or node.has_meta("studio_no_frame"):
		return
	if node is MultiMeshInstance3D:
		_raycast_multimesh(node as MultiMeshInstance3D, ray_o, ray_d, best)
	elif node is MeshInstance3D:
		_raycast_mesh_instance(node as MeshInstance3D, ray_o, ray_d, best)
	for c in node.get_children():
		_walk_raycast(c, ray_o, ray_d, best)


static func _raycast_mesh_instance(mi: MeshInstance3D, ray_o: Vector3, ray_d: Vector3, best: Dictionary) -> void:
	if mi.mesh == null:
		return
	var gxf := mi.global_transform
	if absf(gxf.basis.determinant()) < 1e-10:
		return
	var inv := gxf.affine_inverse()
	var lo := inv * ray_o
	var ld_raw := inv.basis * ray_d
	var ld_len := ld_raw.length()
	if ld_len < 1e-8:
		return
	var ld := ld_raw / ld_len
	var aabb := mi.mesh.get_aabb().grow(0.02)
	if not aabb.has_point(lo) and aabb.intersects_ray(lo, ld) == null:
		return
	var faces: PackedVector3Array
	if mi.mesh.has_meta(_FACE_CACHE_META):
		faces = mi.mesh.get_meta(_FACE_CACHE_META)
	else:
		faces = mi.mesh.get_faces()
		mi.mesh.set_meta(_FACE_CACHE_META, faces)
	var max_local_t := float(best["t"]) * ld_len
	var seg_end := lo + ld * max_local_t
	var n_verts := faces.size()
	var k := 0
	while k + 2 < n_verts:
		var a := faces[k]
		var b := faces[k + 1]
		var c := faces[k + 2]
		k += 3
		var hit: Variant = Geometry3D.segment_intersects_triangle(lo, seg_end, a, b, c)
		if hit == null:
			continue
		var hp := hit as Vector3
		var wp := gxf * hp
		var wt := wp.distance_to(ray_o)
		if wt < float(best["t"]) and wt > 1e-4:
			var ln := (c - a).cross(b - a)
			if ln.length_squared() < 1e-12:
				ln = Vector3.UP
			var wn := (gxf.basis * ln).normalized()
			if wn.dot(ray_d) > 0.0:
				wn = -wn
			best["valid"] = true
			best["t"] = wt
			best["position"] = wp
			best["normal"] = wn
			seg_end = lo + ld * (wt * ld_len)


static func _raycast_multimesh(mmi: MultiMeshInstance3D, ray_o: Vector3, ray_d: Vector3, best: Dictionary) -> void:
	var mm := mmi.multimesh
	if mm == null or mm.mesh == null or mm.instance_count <= 0:
		return
	var base_aabb := mm.mesh.get_aabb().grow(0.02)
	var gxf := mmi.global_transform
	var count := mini(mm.instance_count, 2000)
	for i in count:
		var ixf := gxf * mm.get_instance_transform(i)
		if absf(ixf.basis.determinant()) < 1e-10:
			continue
		var inv := ixf.affine_inverse()
		var lo := inv * ray_o
		var ld_raw := inv.basis * ray_d
		var ld_len := ld_raw.length()
		if ld_len < 1e-8:
			continue
		var ld := ld_raw / ld_len
		var hit: Variant = base_aabb.intersects_ray(lo, ld)
		if hit == null:
			continue
		var wp := ixf * (hit as Vector3)
		var wt := wp.distance_to(ray_o)
		if wt < float(best["t"]) and wt > 1e-4:
			var center := base_aabb.get_center()
			var d_c := (hit as Vector3) - center
			var he := base_aabb.size * 0.5
			var ln := Vector3.UP
			var rx := absf(d_c.x) / maxf(he.x, 1e-4)
			var ry := absf(d_c.y) / maxf(he.y, 1e-4)
			var rz := absf(d_c.z) / maxf(he.z, 1e-4)
			if rx >= ry and rx >= rz:
				ln = Vector3(signf(d_c.x), 0.0, 0.0)
			elif ry >= rz:
				ln = Vector3(0.0, signf(d_c.y), 0.0)
			else:
				ln = Vector3(0.0, 0.0, signf(d_c.z))
			var wn := (ixf.basis * ln).normalized()
			if wn.dot(ray_d) > 0.0:
				wn = -wn
			best["valid"] = true
			best["t"] = wt
			best["position"] = wp
			best["normal"] = wn


## Measure local AABB of all visible MeshInstance3D nodes under `root`.
static func model_bounds(root: Node3D) -> AABB:
	var out := AABB()
	var found := false
	if root == null:
		return out
	var inv := root.global_transform.affine_inverse() if root.is_inside_tree() else Transform3D.IDENTITY
	for n in root.find_children("*", "GeometryInstance3D", true, false):
		if n is GPUParticles3D or n is CPUParticles3D or n is Label3D:
			continue
		var nm := String(n.name)
		if nm in _SKIP_NODE_NAMES or n.has_meta("studio_no_frame"):
			continue
		var gi := n as GeometryInstance3D
		if not gi.visible:
			continue
		var bb := gi.get_aabb()
		if bb.size.length_squared() < 1e-8:
			continue
		var rel := (inv * gi.global_transform) if root.is_inside_tree() else _local_xf_to(gi, root)
		var lbb: AABB = rel * bb
		out = lbb if not found else out.merge(lbb)
		found = true
	return out


static func _local_xf_to(node: Node3D, ancestor: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = node
	while cur != null and cur != ancestor:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf
