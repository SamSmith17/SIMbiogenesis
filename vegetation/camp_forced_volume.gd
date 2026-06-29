@tool
extends Resource
class_name CampForcedVolume

@export var class_id : StringName = &"popup_tent"
@export var volume_path : NodePath = NodePath( "" )
@export_range( 0.0, 1.0, 0.01 ) var confidence_boost : float = 0.15
