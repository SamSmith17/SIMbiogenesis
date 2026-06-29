@tool
extends Resource
class_name CampScatterCandidate

## Single placement record produced by either the image scanner or a manual
## stamp. The bake resource is just an array of these. Keep this resource
## lightweight so a large bake doesn't bloat the saved file.

enum Source {
	IMAGE_DETECTION = 0,
	MANUAL_STAMP = 1,
}

@export var class_id : StringName = &""
@export var confidence : float = 0.0
@export var world_position : Vector3 = Vector3.ZERO
## Real-world footprint extents (length along heading, width perpendicular).
@export var footprint_size : Vector2 = Vector2.ONE
## Yaw (Y rotation) in radians.
@export var heading_radians : float = 0.0
@export var source_blob_id : int = -1
@export var source : int = Source.IMAGE_DETECTION
@export var stamp_node_path : NodePath = NodePath( "" )
@export var bounds_min_px : Vector2i = Vector2i.ZERO
@export var bounds_max_px : Vector2i = Vector2i.ZERO
