class_name TerrainHoleMask
extends RefCounted

## The drawn half of a structure's opening in the terrain: one R8 layer per
## hole (Texture2DArray), each covering that hole's padded bounds, read by
## terrain_detail.gdshader (`hole_tex`, `hole_rects`, `hole_count`). The
## shader discards where the mask is over 0.5, and the texture filters
## linearly, so the cut sits on the polygon edge to a fraction of a texel —
## the soil meets the wall face exactly, which a 1.5 m heightfield never can.

const MAX_HOLES := 16
const LAYER_PX := 256
## Padding round each hole's rect (m), so the edge texels are outside.
const PAD_M := 0.6


## {tex: Texture2DArray or null, rects: PackedVector4Array (x0, z0, sx, sz), count}
static func build(holes: Array) -> Dictionary:
	var rects := PackedVector4Array()
	var images: Array[Image] = []
	for h in holes:
		if images.size() >= MAX_HOLES:
			break
		var poly: PackedVector2Array = h["poly"]
		if poly.size() < 3:
			continue
		var r := Rect2(poly[0], Vector2.ZERO)
		for p in poly:
			r = r.expand(p)
		r = r.grow(PAD_M)
		var img := Image.create(LAYER_PX, LAYER_PX, false, Image.FORMAT_R8)
		var sx := r.size.x / float(LAYER_PX)
		var sz := r.size.y / float(LAYER_PX)
		for j in LAYER_PX:
			var z := r.position.y + (float(j) + 0.5) * sz
			for i in LAYER_PX:
				var x := r.position.x + (float(i) + 0.5) * sx
				if Geometry2D.is_point_in_polygon(Vector2(x, z), poly):
					img.set_pixel(i, j, Color(1, 0, 0))
		images.append(img)
		rects.append(Vector4(r.position.x, r.position.y, r.size.x, r.size.y))
	if images.is_empty():
		return {"tex": null, "rects": rects, "count": 0}
	var tex := Texture2DArray.new()
	tex.create_from_images(images)
	return {"tex": tex, "rects": rects, "count": images.size()}


## Push onto one terrain material (only terrain_detail.gdshader has the uniforms).
static func push(sm: ShaderMaterial, mask: Dictionary) -> void:
	if sm == null or sm.shader == null or not sm.shader.resource_path.ends_with("terrain_detail.gdshader"):
		return
	var n := int(mask.get("count", 0))
	sm.set_shader_parameter("hole_count", n)
	if n <= 0:
		return
	sm.set_shader_parameter("hole_tex", mask["tex"])
	var rects: PackedVector4Array = mask["rects"]
	var arr: Array = []
	for i in MAX_HOLES:
		arr.append(rects[i] if i < rects.size() else Vector4.ZERO)
	sm.set_shader_parameter("hole_rects", arr)
