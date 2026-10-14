@tool
class_name ImportMaterialFixer
extends RefCounted

## Fixes the "everything is glossy plastic" look of SketchUp glTF exports.
##
## SketchUp has no PBR: a SketchUp material is a colour, an optional texture
## and an opacity. Every glTF exporter therefore INVENTS the shading terms.
## The SimLab exporter (the common SketchUp → glTF route, generator
## "SimLab GLTF") writes KHR_materials_pbrSpecularGlossiness with specular 0.5
## and glossiness 0.5 on every material, plus a metallic/roughness fallback of
## 0.5 / 0.5. Godot converts the spec-gloss block to metallic 0 / roughness 0.5
## / specular 0.5 — a semi-gloss sheen on brick, shingles, bark and siding
## alike (measured on the user's "Halvorsen" models, 2026-10-13). This class
## throws the invented numbers away and assigns real-world values from the
## material NAME (SketchUp's library names — "Brick_Antique",
## "Roofing_Shingles_Multi", "Metal Corrugated Shiny", "[Translucent Glass
## Gray]" — say what the surface is) and its opacity.
##
## Values are dielectric/metal roughness classes from physically based
## material references (e.g. the Physically Based database,
## physicallybased.info, and Unreal / Substance material guides): rough
## masonry and soil ~0.9, sawn or weathered wood ~0.8, painted walls ~0.7,
## glazed ceramic / laminate ~0.35, glass ~0.05; metals metallic 1 with
## roughness by finish, and PAINTED metal roofing treated as a coated
## dielectric (the paint is what light sees).
##
## Pure static so it runs anywhere a glTF is turned into a scene: the in-game
## importer (ModelCatalog, user://models) and the editor import hook
## (addons/sketchup_import_fix), and so the selftest can feed it fixtures.

const MODE_AUTO := "auto"   # fix when the file is recognised as a SketchUp export
const MODE_OFF := "off"     # leave the exporter's materials alone
const MODE_FORCE := "force" # fix whatever exported it

## Lower-case substrings of asset.generator that mean "came out of SketchUp".
const SKETCHUP_GENERATORS := ["sketchup", "simlab", "su2gltf", "trimble", "skp"]

## Ordered rules: the FIRST rule whose keyword appears in the material name
## wins, so specific finishes ("shiny", "rust", "painted") sit above their
## families. [profile, keywords].
const RULES := [
	# SketchUp's geolocated terrain: the imported aerial photo, named
	# "Geolocation /api/v2/tile/bing?… tile" — its "tile" must not read as
	# ceramic. Matte ground.
	["ground", ["geolocation", "/api/v2/tile", "bing?x="]],
	["mirror", ["mirror", "chrome", "polished steel", "polished_steel"]],
	["glass", ["glass", "glazing", "window pane", "windowpane", "translucent",
		"acrylic", "plexiglas", "lexan", "polycarb"]],
	["water", ["water", "pool", "pond", "lake"]],
	["solar", ["pv_", "pv ", "photovolt", "phono", "solar"]],
	["rust", ["rust", "corten", "weathered steel"]],
	["metal_roof", ["corrugat", "corrogat", "seamed", "standing seam", "metal roof",
		"metal_roof", "roofing_metal", "metal painted", "painted metal", "metal_painted",
		"painted_metal"]],
	["metal_shiny", ["shiny", "polish", "stainless", "anodized", "anodised"]],
	["metal", ["aluminum", "aluminium", "steel", "galvan", "zinc", "tin ", "iron",
		"copper", "brass", "bronze", "metal", "screw", "bolt", "nail", "hinge",
		"rebar", "chain", "wire"]],
	["fabric", ["fabric", "carpet", "canvas", "cloth", "felt", "rug", "textile",
		"upholst", "curtain", "tarp", "mesh"]],
	["glazed", ["tile", "ceramic", "porcelain", "marble", "granite", "quartz",
		"laminate", "formica", "enamel", "gloss", "lacquer", "vinyl floor", "linoleum"]],
	["plastic", ["plastic", "pvc", "vinyl", "polyeth", "hdpe", "nylon"]],
	["rubber", ["rubber", "tire", "tyre", "foam"]],
	["ground", ["grass", "soil", "dirt", "sand", "gravel", "mulch", "lawn", "turf",
		"vegetation", "leaf", "leaves", "foliage", "moss", "hedge", "bark", "earth", "mud"]],
	["masonry", ["brick", "concrete", "stone", "stucco", "cement", "block", "cinder",
		"asphalt", "shingle", "slate", "mortar", "rock", "cobble", "paver", "plaster",
		"adobe", "terracotta", "clay"]],
	["wood", ["wood", "oak", "pine", "cherry", "maple", "walnut", "birch", "bamboo",
		"plywood", "cedar", "deck", "lumber", "timber", "osb", "cardboard", "parquet",
		"douglas", "spruce", "teak", "mahogany", "chipboard", "particleboard", "floorboard",
		"plank", "veneer", "cab_door"]],
	["siding", ["siding", "cladding", "clapboard", "shake"]],
	["paint", ["color", "colour", "paint", "shadow", "<", "["]],
]

## profile → [metallic, roughness, specular(0..1, 0.5 = F0 4 %)].
const PROFILES := {
	"mirror": [1.0, 0.06, 0.5],
	"glass": [0.0, 0.05, 0.5],
	"water": [0.0, 0.04, 0.5],
	"solar": [0.0, 0.16, 0.5],
	"rust": [0.15, 0.85, 0.4],
	"metal_roof": [0.25, 0.55, 0.5],
	"metal_shiny": [1.0, 0.28, 0.5],
	"metal": [0.85, 0.45, 0.5],
	"glazed": [0.0, 0.35, 0.5],
	"plastic": [0.0, 0.55, 0.5],
	"rubber": [0.0, 0.9, 0.35],
	"fabric": [0.0, 0.97, 0.3],
	"ground": [0.0, 0.96, 0.3],
	"masonry": [0.0, 0.92, 0.4],
	"wood": [0.0, 0.8, 0.4],
	"siding": [0.0, 0.72, 0.45],
	"paint": [0.0, 0.72, 0.45],
	"default": [0.0, 0.8, 0.45],
}


## "sketchup" when the glTF JSON says it came from a SketchUp exporter, else "".
## Two signals, either is enough: the generator string, or the SimLab
## fingerprint (every material spec-gloss with the 0.5 invented glossiness).
static func source_app(gltf_json: Dictionary) -> String:
	var asset: Dictionary = gltf_json.get("asset", {}) as Dictionary
	var gen := str(asset.get("generator", "")).to_lower()
	for k: String in SKETCHUP_GENERATORS:
		if gen.contains(k):
			return "sketchup"
	var mats: Array = gltf_json.get("materials", []) as Array
	if mats.size() >= 2:
		var invented := 0
		for m_v in mats:
			var ext: Dictionary = (m_v as Dictionary).get("extensions", {}) as Dictionary
			var sg: Dictionary = ext.get("KHR_materials_pbrSpecularGlossiness", {}) as Dictionary
			if not sg.is_empty() and absf(float(sg.get("glossinessFactor", 1.0)) - 0.5) < 0.001:
				invented += 1
		if float(invented) / float(mats.size()) >= 0.8:
			return "sketchup"
	return ""


## Whether to fix, given the file's JSON and a catalog/import mode.
static func should_fix(gltf_json: Dictionary, mode: String = MODE_AUTO) -> bool:
	match mode:
		MODE_OFF:
			return false
		MODE_FORCE:
			return true
	return source_app(gltf_json) == "sketchup"


## Read the JSON chunk of a .glb (or a .gltf file) without building a scene.
## Cheap: the JSON sits at the front of a .glb. {} on any failure.
static func read_gltf_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	if path.get_extension().to_lower() == "gltf":
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		return parsed as Dictionary if parsed is Dictionary else {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 20:
		return {}
	if f.get_32() != 0x46546C67:  # "glTF"
		return {}
	f.get_32()  # version
	f.get_32()  # total length
	var clen := f.get_32()
	var ctype := f.get_32()
	if ctype != 0x4E4F534A or clen <= 0 or clen > f.get_length():  # "JSON"
		return {}
	var parsed2: Variant = JSON.parse_string(f.get_buffer(clen).get_string_from_utf8())
	return parsed2 as Dictionary if parsed2 is Dictionary else {}


## The profile a material name falls into ("default" when nothing matches).
static func classify(name: String) -> String:
	var n := name.to_lower().replace("-", "_")
	# SketchUp's colour library ("[0109_DarkSlateBlue]", "[0023_FireBrick]"):
	# a paint colour, whatever the colour's name says.
	if n.length() > 6 and n[0] == "[" and n.substr(1, 4).is_valid_int() and n[5] == "_":
		return "paint"
	for rule: Array in RULES:
		for k: String in rule[1]:
			if n.contains(k):
				return str(rule[0])
	return "default"


## Rewrite one material's shading terms in place. Returns the profile used.
## Colour, textures and UVs are the artist's and are never touched; the
## exporter's metallic/roughness MAPS go (they were made up as well), and an
## alpha-scissor material whose albedo has no transparency anywhere becomes
## opaque (SimLab marks every material MASK, which forces alpha testing —
## and its aliased edges — onto solid walls).
static func fix_material(mat: StandardMaterial3D) -> String:
	var profile := classify(mat.resource_name)
	var transparent_color := mat.albedo_color.a < 0.98
	# A see-through material named after nothing reads as glass.
	if transparent_color and profile in ["default", "paint"]:
		profile = "glass"
	var v: Array = PROFILES.get(profile, PROFILES["default"])
	mat.metallic = float(v[0])
	mat.roughness = float(v[1])
	mat.metallic_specular = float(v[2])
	mat.metallic_texture = null
	mat.roughness_texture = null
	if mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR and not transparent_color:
		if mat.albedo_texture == null or not _texture_has_alpha(mat.albedo_texture):
			mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	if profile == "glass" or profile == "water":
		# Glass keeps its colour's opacity; make sure it is drawn transparent
		# and lets light through instead of picking up a mirror sheen.
		if transparent_color and mat.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.set_meta("sketchup_fix", profile)
	return profile


static func _texture_has_alpha(tex: Texture2D) -> bool:
	var img := tex.get_image()
	if img == null or img.is_empty():
		return true  # unknown: keep the alpha test, the safe choice
	if img.is_compressed():
		img = img.duplicate() as Image
		if img.decompress() != OK:
			return true
	return img.detect_alpha() != Image.ALPHA_NONE


## Fix every StandardMaterial3D in a scene (surface materials, surface
## overrides and material overrides; each material once, however many meshes
## share it). Returns {fixed, profiles: {profile: n}}.
static func fix_scene(root: Node) -> Dictionary:
	var seen: Dictionary = {}
	var profiles: Dictionary = {}
	_fix_walk(root, seen, profiles)
	return {"fixed": seen.size(), "profiles": profiles}


static func _fix_walk(n: Node, seen: Dictionary, profiles: Dictionary) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.material_override is StandardMaterial3D:
			_fix_once(mi.material_override as StandardMaterial3D, seen, profiles)
		if mi.mesh != null:
			for i in mi.mesh.get_surface_count():
				var sm := mi.mesh.surface_get_material(i)
				if sm is StandardMaterial3D:
					_fix_once(sm as StandardMaterial3D, seen, profiles)
				var so := mi.get_surface_override_material(i)
				if so is StandardMaterial3D:
					_fix_once(so as StandardMaterial3D, seen, profiles)
	elif n.get_class() == "ImporterMeshInstance3D":
		var im: Variant = n.get("mesh")
		if im != null and im is ImporterMesh:
			var imesh := im as ImporterMesh
			for i in imesh.get_surface_count():
				var m := imesh.get_surface_material(i)
				if m is StandardMaterial3D:
					_fix_once(m as StandardMaterial3D, seen, profiles)
	for c in n.get_children():
		_fix_walk(c, seen, profiles)


static func _fix_once(m: StandardMaterial3D, seen: Dictionary, profiles: Dictionary) -> void:
	var id := m.get_instance_id()
	if seen.has(id):
		return
	seen[id] = true
	var p := fix_material(m)
	profiles[p] = int(profiles.get(p, 0)) + 1
