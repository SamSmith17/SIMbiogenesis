class_name DomeLabPresets
extends RefCounted

## Built-in dome and zome designs plus the player's library
## (user://domelab_library.json: {version, designs: [{id, name, spec}]}).

const LIBRARY_PATH := "user://domelab_library.json"


static func builtins() -> Array:
	var out: Array = []
	var d := DomeLabSpec.default_spec("geodesic")
	d["name"] = "2V conduit dome"
	d["radius_m"] = 3.0
	d["geodesic"]["frequency"] = 2
	d["geodesic"]["fraction"] = 0.5
	d["strut"]["material"] = "emt_34"
	out.append({"id": "2v_conduit", "name": "2V conduit dome (6 m)", "blurb": "The classic: 65 struts of two lengths, 26 bolts, a hemisphere on 3/4\" EMT.", "spec": d})
	d = DomeLabSpec.default_spec("geodesic")
	d["name"] = "3V 5/8 conduit dome"
	d["radius_m"] = 4.5
	d["geodesic"]["frequency"] = 3
	d["geodesic"]["fraction"] = 0.625
	d["geodesic"]["flat_base"] = true
	out.append({"id": "3v_58", "name": "3V 5/8 conduit dome (9 m)", "blurb": "Three strut lengths, 165 struts, flattened base. The Burning Man camp dome.", "spec": d})
	d = DomeLabSpec.default_spec("geodesic")
	d["name"] = "4V hub dome"
	d["radius_m"] = 6.0
	d["geodesic"]["frequency"] = 4
	d["geodesic"]["fraction"] = 0.5
	d["system"] = "hub"
	d["hub"]["kind"] = "socket"
	d["hub"]["reach_mm"] = 70.0
	d["strut"]["material"] = "pvc_1"
	out.append({"id": "4v_hub", "name": "4V PVC hub dome (12 m)", "blurb": "Six strut lengths on printed socket hubs; PVC cannot be flattened, so hubs it is.", "spec": d})
	d = DomeLabSpec.default_spec("geodesic")
	d["name"] = "Class II triacon"
	d["radius_m"] = 5.0
	d["geodesic"]["cls"] = 2
	d["geodesic"]["frequency"] = 4
	d["geodesic"]["fraction"] = 0.5
	d["geodesic"]["orientation"] = "edge"
	d["system"] = "hub"
	d["hub"]["kind"] = "plate"
	d["strut"]["material"] = "emt_1"
	out.append({"id": "triacon_4v", "name": "4V triacon on star plates", "blurb": "Class II: the great-circle grid, struts bolted to flat star plates with drill templates.", "spec": d})
	d = DomeLabSpec.default_spec("geodesic")
	d["name"] = "Flat-bar dome"
	d["radius_m"] = 3.5
	d["geodesic"]["frequency"] = 3
	d["geodesic"]["fraction"] = 0.625
	d["system"] = "flat_bar"
	d["strut"]["material"] = "hdpe_bar_50x6"
	d["hub"]["bolt"] = "m8"
	out.append({"id": "flat_bar", "name": "HDPE flat-bar dome", "blurb": "Flexible bars follow the curve, stacked on one bolt per hub; arc lengths, not chords.", "spec": d})
	d = DomeLabSpec.default_spec("geodesic")
	d["name"] = "Rotegrity"
	d["radius_m"] = 3.0
	d["geodesic"]["frequency"] = 2
	d["geodesic"]["fraction"] = 0.5
	d["system"] = "nexorade"
	d["nexorade"]["slat"] = "hdpe_bar_50x6"
	d["hub"]["bolt"] = "m6"
	out.append({"id": "rotegrity", "name": "Rotegrity (hubless)", "blurb": "Every strut turned and lengthened so it rests on the next: no hubs, four holes a slat.", "spec": d})
	d = DomeLabSpec.default_spec("geodesic")
	d["name"] = "Plate dome"
	d["radius_m"] = 2.0
	d["geodesic"]["frequency"] = 3
	d["geodesic"]["fraction"] = 0.625
	d["system"] = "plate"
	d["face"]["material"] = "alu_1"
	d["face"]["flange_mm"] = 35.0
	d["hub"]["bolt"] = "m6"
	out.append({"id": "plate_dome", "name": "Folded-plate dome", "blurb": "No struts: aluminium triangles with flanges folded to half the dihedral, bolted edge to edge.", "spec": d})
	d = DomeLabSpec.default_spec("geodesic")
	d["name"] = "Covered 3V"
	d["radius_m"] = 3.0
	d["geodesic"]["frequency"] = 3
	d["geodesic"]["fraction"] = 0.625
	d["face"]["material"] = "polycarb_6"
	out.append({"id": "covered_3v", "name": "3V greenhouse (polycarbonate)", "blurb": "The conduit frame with twin-wall panels cut to each face, nested on sheets.", "spec": d})
	d = DomeLabSpec.default_spec("geodesic")
	d["name"] = "Octa dome"
	d["radius_m"] = 3.0
	d["geodesic"]["base"] = "octa"
	d["geodesic"]["frequency"] = 4
	d["geodesic"]["fraction"] = 0.5
	out.append({"id": "octa_4v", "name": "Octahedral 4V", "blurb": "An octahedron base has a natural equator at any frequency and a square floor plan.", "spec": d})
	d = DomeLabSpec.default_spec("geodesic")
	d["name"] = "Ellipsoid dome"
	d["radius_m"] = 5.0
	d["geodesic"]["frequency"] = 4
	d["geodesic"]["fraction"] = 0.5
	d["geodesic"]["stretch"] = 0.7
	out.append({"id": "ellipsoid", "name": "Low ellipsoid 4V", "blurb": "The sphere squashed to 70 %: a low dome with more strut lengths.", "spec": d})
	d = DomeLabSpec.default_spec("zome")
	d["name"] = "8-sided zome"
	d["radius_m"] = 2.0
	d["zome"]["sides"] = 8
	d["zome"]["layers"] = 4
	d["face"]["material"] = "ply_6"
	d["system"] = "hub"
	d["hub"]["kind"] = "socket"
	d["strut"]["material"] = "wood_2x2"
	out.append({"id": "zome_8", "name": "8-sided zome (plywood)", "blurb": "Baer's polar zonohedron: one strut length, seven rhombus shapes, a flat octagon floor.", "spec": d})
	d = DomeLabSpec.default_spec("zome")
	d["name"] = "Helix zome"
	d["radius_m"] = 3.5
	d["zome"]["sides"] = 10
	d["zome"]["layers"] = 5
	d["zome"]["pitch_deg"] = 35.0
	d["zome"]["ribs"] = true
	d["system"] = "hub"
	d["strut"]["material"] = "ply_rib_18x90"
	out.append({"id": "helix_zome", "name": "Helix zome (CNC ribs)", "blurb": "Ten double helices of curved plywood rib, lapped where they cross — the zonohedron's smooth limit.", "spec": d})
	d = DomeLabSpec.default_spec("zome")
	d["name"] = "Onion zome"
	d["radius_m"] = 2.5
	d["zome"]["sides"] = 7
	d["zome"]["layers"] = 5
	d["zome"]["pitch_deg"] = 45.0
	d["zome"]["triangulate"] = true
	d["strut"]["material"] = "emt_12"
	out.append({"id": "onion", "name": "Onion zome (triangulated)", "blurb": "Five of seven layers, past the widest ring; diagonals make the rhombi rigid.", "spec": d})
	d = DomeLabSpec.default_spec("zome")
	d["name"] = "Plate zome"
	d["radius_m"] = 1.4
	d["zome"]["sides"] = 6
	d["zome"]["layers"] = 3
	d["system"] = "plate"
	d["face"]["material"] = "steel_06"
	out.append({"id": "plate_zome", "name": "Folded steel zome", "blurb": "Six-sided, three layers, sheet-steel rhombi with folded flanges and no frame.", "spec": d})
	return out


static func builtin(id: String) -> Dictionary:
	for p in builtins():
		if str(p["id"]) == id:
			return p
	return {}


static func load_library(path: String = LIBRARY_PATH) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return []
	var out: Array = []
	for d in (parsed as Dictionary).get("designs", []):
		if d is Dictionary and (d as Dictionary).get("spec") is Dictionary:
			out.append({"id": str(d.get("id", "")), "name": str(d.get("name", "Design")),
				"spec": DomeLabSpec.resolve(d["spec"])})
	return out


static func save_library(designs: Array, path: String = LIBRARY_PATH) -> bool:
	var out: Array = []
	for d in designs:
		out.append({"id": str(d.get("id", "")), "name": str(d.get("name", "Design")),
			"spec": DomeLabSpec.to_json_safe(d.get("spec", {}))})
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": 1, "designs": out}, "\t"))
	f.close()
	return true
