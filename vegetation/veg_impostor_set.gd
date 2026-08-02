class_name VegImpostorSet
extends Resource

## One baked impostor atlas set for a (species + look) combination — Phase 3b.
## 8 yaw views + 1 top view of the parametric NEAR mesh in a 3×3 grid, plus a
## parallel foliage-vs-bark mask atlas so the impostor shader can apply the
## SAME seasonal uniforms (autumn/leaf_coverage/winter) to leaves only.
## Baked at runtime by VegImpostorBaker (there are no static GLBs to pre-bake
## — trees are procedurally generated), cached to user://veg_impostors/.

@export var bake_version: int = 0
@export var key: String = ""
@export var species: String = ""
@export var atlas: Texture2D
@export var mask: Texture2D
@export var frames_x: int = 3
@export var frames_y: int = 3
@export var yaw_frames: int = 8
## World size of one unscaled tree as framed in each cell (metres).
@export var world_w: float = 8.0
@export var world_h: float = 8.0
## Mesh-space foot Y of the source mesh (quad base maps here).
@export var foot_y: float = 0.0


func is_usable() -> bool:
	return atlas != null and world_w > 0.01 and world_h > 0.01
