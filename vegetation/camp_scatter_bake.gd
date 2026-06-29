@tool
extends Resource
class_name CampScatterBake

@export var candidates : Array[ CampScatterCandidate ] = []
@export var generated_at_unix : int = 0
@export var source_image_path : String = ""
@export var source_image_size : Vector2i = Vector2i.ZERO
@export var downsampled_size : Vector2i = Vector2i.ZERO
