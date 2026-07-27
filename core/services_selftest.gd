extends SceneTree
## Offline deterministic selftest for the Services registry (core/services.gd).
## Run: Godot.exe.exe --headless --path . --script core/services_selftest.gd
## Instantiates a fresh registry (not the autoload) so the test is isolated.

const ServicesScript := preload("res://core/services.gd")

var _fails := 0
var _checks := 0

func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])

func _init() -> void:
	# Defer: during _init() the root Window is not yet inside the tree, so
	# add_child() would not fire tree_entered/tree_exiting. Run once the tree
	# is live so registration + auto-clear-on-exit behave as they do in game.
	_run.call_deferred()

func _run() -> void:
	await process_frame
	var reg: Node = ServicesScript.new()
	root.add_child(reg)

	# --- register + look up -------------------------------------------------
	var a := Node.new()
	a.name = "GraphStandIn"
	root.add_child(a)
	reg.register(reg.GRAPH, a)
	_check("has after register", reg.has_service(reg.GRAPH))
	_check("get returns same node", reg.get_service(reg.GRAPH) == a)
	_check("accessor get_graph", reg.get_graph() == a)
	_check("unregistered key is null", reg.get_service(reg.SOLAR_UI) == null)
	_check("has is false for unregistered", not reg.has_service(reg.SOLAR_UI))

	# --- signal fires on register ------------------------------------------
	var seen: Array = []
	reg.service_registered.connect(func(k: StringName, _n: Node) -> void: seen.append(k))
	var b := Node.new()
	b.name = "SolarStandIn"
	root.add_child(b)
	reg.register(reg.SOLAR_UI, b)
	_check("registered signal fired", reg.SOLAR_UI in seen)

	# --- re-register under a key replaces the node --------------------------
	var a2 := Node.new()
	a2.name = "GraphStandIn2"
	root.add_child(a2)
	reg.register(reg.GRAPH, a2)
	_check("re-register replaces", reg.get_service(reg.GRAPH) == a2)

	# --- auto-clear when a node leaves the tree -----------------------------
	var removed: Array = []
	reg.service_removed.connect(func(k: StringName) -> void: removed.append(k))
	b.free()  # leaves tree -> tree_exited -> registry erases SOLAR_UI
	_check("auto-cleared on tree exit", not reg.has_service(reg.SOLAR_UI))
	_check("removed signal fired", reg.SOLAR_UI in removed)

	# --- the OLD registered node leaving does NOT clobber the replacement ---
	# a (original GRAPH) was replaced by a2; freeing a must not clear GRAPH.
	a.free()
	_check("stale node exit keeps replacement", reg.get_service(reg.GRAPH) == a2)

	# --- freed node without explicit exit is lazily nulled ------------------
	var c := Node.new()
	c.name = "TerrainLoaderStandIn"
	root.add_child(c)
	reg.register(reg.TERRAIN_LOADER, c)
	c.free()
	_check("freed node lazily nulled", reg.get_service(reg.TERRAIN_LOADER) == null)

	# --- null register is a no-op ------------------------------------------
	reg.register(reg.PLAYER, null)
	_check("null register ignored", not reg.has_service(reg.PLAYER))

	if _fails == 0:
		print("SERVICES SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("SERVICES SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)
