extends Node
class_name ToolManager

## Manages player tools/equipment (fire extinguisher, etc.)

signal tool_equipped(tool: Node3D)
signal tool_unequipped(tool: Node3D)

## Currently equipped tool
var current_tool: Node3D = null

## Available tools (tool_id -> tool_scene)
var available_tools: Dictionary = {}

## Player reference
var player: CharacterBody3D = null

## Camera reference (for positioning tools in FPS view)
var camera: Camera3D = null

func _ready() -> void:
	# Register available tools
	_register_tools()

func _register_tools() -> void:
	# Fire extinguisher
	var extinguisher_scene := preload("res://gameplay/player_tools/fire_extinguisher.tscn")
	if extinguisher_scene != null:
		available_tools["fire_extinguisher"] = extinguisher_scene

## Equip a tool by ID
func equip_tool(tool_id: String) -> bool:
	if tool_id == "":
		unequip_tool()
		return true
	
	if not available_tools.has(tool_id):
		push_warning("ToolManager: Unknown tool ID: %s" % tool_id)
		return false
	
	# Unequip current tool first
	unequip_tool()
	
	# Instantiate new tool
	var tool_scene: PackedScene = available_tools[tool_id]
	if tool_scene == null:
		return false
	
	var tool := tool_scene.instantiate()
	if tool == null:
		return false
	
	# Add to player camera
	if camera != null:
		camera.add_child(tool)
		# Position tool in FPS view (adjust as needed)
		tool.position = Vector3(0.3, -0.2, -0.5)
		tool.rotation = Vector3.ZERO
	
	current_tool = tool
	tool_equipped.emit(tool)
	
	# Initialize tool if it has setup method
	if tool.has_method("setup"):
		tool.setup(player, camera)
	
	return true

## Unequip current tool
func unequip_tool() -> void:
	if current_tool != null:
		var tool := current_tool
		current_tool = null
		
		# Cleanup tool if it has cleanup method
		if tool.has_method("cleanup"):
			tool.cleanup()
		
		tool.queue_free()
		tool_unequipped.emit(tool)

## Get currently equipped tool
func get_current_tool() -> Node3D:
	return current_tool

## Check if a tool is equipped
func is_tool_equipped(tool_id: String) -> bool:
	if current_tool == null:
		return false
	return current_tool.has_method("get_tool_id") and current_tool.get_tool_id() == tool_id

## Use the current tool (called by player input)
func use_tool() -> void:
	if current_tool != null and current_tool.has_method("use"):
		current_tool.use()

## Stop using the current tool (called when releasing input)
func stop_using_tool() -> void:
	if current_tool != null and current_tool.has_method("stop_using"):
		current_tool.stop_using()
