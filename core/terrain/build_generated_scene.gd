extends SceneTree

## One-off builder for scenes/maps/generated_location.tscn — the reusable shell
## for ALL user-created location maps. It instantiates the existing Mars shell
## (which carries the full Main wiring: environment, sun/moon, player, every UI,
## HAClient), strips the Mars-specific world content, adds a TerrainLoader, and
## repacks. Doing this programmatically preserves all resource/UI wiring exactly
## rather than hand-editing a 6000-line .tscn.
##
## Run once (and again if the shell scene changes):
##   godot --headless --path . --script core/terrain/build_generated_scene.gd

const SOURCE := "res://scenes/maps/mars_aerial.tscn"
const OUT := "res://scenes/maps/generated_location.tscn"

## Direct children of Main to KEEP — the reusable shell. Everything else at the
## root (terrain meshes, Mars/Starshade models, vehicles, props, collision
## helpers) is removed.
const KEEP_ROOT_CHILDREN := [
	"WorldEnvironment", "Sun", "Moon", "PlanetSystem", "StarSystem",
	"Player", "UILayer", "HAClient",
]

## UILayer children that are Mars-specific and should be dropped.
const DROP_UI_CHILDREN := ["MarsCollegeCreditsUI"]


func _initialize() -> void:
	var packed: PackedScene = load(SOURCE)
	if packed == null:
		print("BUILD FAIL: could not load %s" % SOURCE)
		quit(1)
		return
	var root: Node = packed.instantiate()  # _ready does NOT run (not in tree)

	var removed := 0
	for child in root.get_children():
		if not KEEP_ROOT_CHILDREN.has(child.name):
			root.remove_child(child)
			child.free()
			removed += 1

	var ui := root.get_node_or_null("UILayer")
	if ui != null:
		for name in DROP_UI_CHILDREN:
			var n := ui.get_node_or_null(name)
			if n != null:
				ui.remove_child(n)
				n.free()

	# Add the runtime terrain loader, owned by root so it serializes.
	var loader := Node3D.new()
	loader.name = "TerrainLoader"
	loader.set_script(load("res://core/terrain/terrain_loader.gd"))
	root.add_child(loader)
	loader.owner = root

	var out_scene := PackedScene.new()
	var err := out_scene.pack(root)
	if err != OK:
		print("BUILD FAIL: pack() error %d" % err)
		quit(1)
		return
	err = ResourceSaver.save(out_scene, OUT)
	if err != OK:
		print("BUILD FAIL: save() error %d" % err)
		quit(1)
		return
	print("BUILD OK: wrote %s (stripped %d root world nodes, kept %d shell nodes)" %
		[OUT, removed, root.get_child_count()])
	quit(0)
