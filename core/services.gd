extends Node
## Services — lightweight node/service registry (autoload "Services").
##
## Core scene nodes self-register here in their _ready() under a stable key;
## consumers look them up by key instead of hardcoded scene paths like
## get_node_or_null("UILayer/SystemGraphView"). This decouples code from the
## Main scene's node names (renaming a node, or a mod swapping in its own view,
## no longer silently breaks 48 files) and is the intended replacement for the
## remaining node-name lookups tracked in ARCHITECTURE.md (debt #1).
##
## Migration is incremental and non-breaking: unregistered keys simply return
## null, exactly like the get_node_or_null() calls they replace, so old lookups
## keep working while call sites are converted a handful at a time.
##
## NOTE: this is for SCENE nodes (Main, the graph view, terrain, player, …).
## Autoloads (WeatherService, TimeDirector, …) are already global singletons —
## reference them directly by name; they do not belong in this registry.

signal service_registered(key: StringName, node: Node)
signal service_removed(key: StringName)

# Canonical keys — use the constant, not a raw string, to avoid typos.
const MAIN := &"main"
const GRAPH := &"graph"              # SystemGraphView (UILayer child)
const SOLAR_UI := &"solar_ui"
const TIMELINE_UI := &"timeline_ui"
const UI_LAYER := &"ui_layer"
const TERRAIN_LOADER := &"terrain_loader"
const PLAYER := &"player"
const HA_CLIENT := &"ha_client"

var _nodes: Dictionary = {}   # StringName -> Node

## Register (or replace) the node for `key`. Safe to call from any _ready().
## Auto-clears when the node leaves the tree (map switches recreate Main), so
## a stale/freed node never lingers as a live-looking service.
func register(key: StringName, node: Node) -> void:
	if node == null:
		return
	_nodes[key] = node
	# One-shot cleanup on the way out (tree_exiting fires while the node is still
	# valid, before it leaves — so the compare + signal are safe). Erase only if
	# this exact node is still the registered one; a later re-register under the
	# same key wins and reconnects its own hook.
	node.tree_exiting.connect(func() -> void:
		if _nodes.get(key) == node:
			_nodes.erase(key)
			service_removed.emit(key)
	, CONNECT_ONE_SHOT)
	service_registered.emit(key, node)

## Look up a registered node, or null. Lazily drops freed nodes.
func get_service(key: StringName) -> Node:
	var n: Node = _nodes.get(key)
	if n != null and not is_instance_valid(n):
		_nodes.erase(key)
		return null
	return n

func has_service(key: StringName) -> bool:
	return get_service(key) != null

# --- Convenience accessors (return the node or null) --------------------------
func get_main() -> Node: return get_service(MAIN)
func get_graph() -> Node: return get_service(GRAPH)
func get_solar_ui() -> Node: return get_service(SOLAR_UI)
func get_timeline_ui() -> Node: return get_service(TIMELINE_UI)
func get_ui_layer() -> Node: return get_service(UI_LAYER)
func get_terrain_loader() -> Node: return get_service(TERRAIN_LOADER)
func get_player() -> Node: return get_service(PLAYER)
func get_ha_client() -> Node: return get_service(HA_CLIENT)
