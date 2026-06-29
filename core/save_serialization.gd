extends RefCounted
class_name SaveSerialization

## Static JSON-friendly types for save files. Used by scripts that cannot reference the SaveSystem autoload
## (e.g. @tool main.gd) and by FPV drone during compilation order.

const SAVE_VERSION: int = 2


static func vec3_to_dict(v: Vector3) -> Dictionary:
	return {"x": v.x, "y": v.y, "z": v.z}


static func dict_to_vec3(d: Variant) -> Vector3:
	if d is Dictionary:
		var dd: Dictionary = d
		return Vector3(float(dd.get("x", 0.0)), float(dd.get("y", 0.0)), float(dd.get("z", 0.0)))
	return Vector3.ZERO


static func transform3d_to_dict(t: Transform3D) -> Dictionary:
	return {
		"o": vec3_to_dict(t.origin),
		"x": vec3_to_dict(t.basis.x),
		"y": vec3_to_dict(t.basis.y),
		"z": vec3_to_dict(t.basis.z),
	}


static func dict_to_transform3d(d: Variant) -> Transform3D:
	if d is Dictionary:
		var dd: Dictionary = d
		var ox: Vector3 = dict_to_vec3(dd.get("o", {}))
		var bx: Vector3 = dict_to_vec3(dd.get("x", {}))
		var by: Vector3 = dict_to_vec3(dd.get("y", {}))
		var bz: Vector3 = dict_to_vec3(dd.get("z", {}))
		return Transform3D(bx, by, bz, ox)
	return Transform3D.IDENTITY
