class_name GraphInteractionControllerV2
extends RefCounted

## Centralizes high-level interaction state for GraphCanvasV2.
## This keeps canvas logic modular while parity work is in progress.

var last_pointer_pos: Vector2 = Vector2.ZERO
var hover_item_id: String = ""
var hover_connection_id: String = ""


func update_pointer(pos: Vector2) -> void:
	last_pointer_pos = pos
