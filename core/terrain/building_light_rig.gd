class_name BuildingLightRig
extends Node

## Turns window and porch lights on after dusk. The studio sets
## night_override on the building mesh (1 night, 0 day, -1 follow the sky)
## because its SubViewport does not see Main's sun. In the world the rig
## walks up to Main and reads the same DaylightModel night signal.
## Area lights drop out past LIGHT_CULL_M; the emissive glass stays.

const LIGHT_CULL_M := 40.0
const NIGHT_ON := 0.5

var _acc := 0.0


func _ready() -> void:
	_apply()


func _process(delta: float) -> void:
	_acc += delta
	if _acc < 0.25:
		return
	_acc = 0.0
	_apply()


func _apply() -> void:
	var host := get_parent()
	if host == null:
		return
	var night := _is_night(host)
	var windows_on := bool(host.get_meta("light_windows", false)) if host.has_meta("light_windows") else false
	var cam := host.get_viewport().get_camera_3d() if host.is_inside_tree() else null
	var far := false
	if cam != null:
		far = cam.global_position.distance_to(host.global_position) > LIGHT_CULL_M
	for child in host.get_children():
		if child is MeshInstance3D and child.has_meta("bld_glass"):
			var mat := (child as MeshInstance3D).material_override as StandardMaterial3D
			if mat != null:
				var on := BuildingFeatures.light_on(
					str(child.get_meta("bld_lit", "auto")), windows_on, night)
				mat.emission_enabled = on
				mat.emission_energy_multiplier = 2.2 if on else 0.0
		elif child is AreaLight3D:
			var on_area := BuildingFeatures.light_on(
				str(child.get_meta("bld_light_mode", "auto")), windows_on, night)
			(child as AreaLight3D).visible = on_area and not far
		elif child is OmniLight3D or child is SpotLight3D:
			var on_fix := BuildingFeatures.light_on(
				str(child.get_meta("bld_light_mode", "auto")), true, night)
			(child as Light3D).visible = on_fix


func _is_night(host: Node) -> bool:
	var override := int(host.get_meta("night_override", -1)) if host.has_meta("night_override") else -1
	if override == 0:
		return false
	if override == 1:
		return true
	var n: Node = host
	while n != null:
		var sun: Variant = n.get("sun")
		if sun is DirectionalLight3D:
			# Main aims the light so local -Z shines from the sun toward the
			# scene. Local +Z is the direction back up to the sun, the same
			# vector SolarUI reads. night_amount wants that altitude.
			var to_sun: Vector3 = (sun as DirectionalLight3D).global_basis.z
			return DaylightModel.night_amount(to_sun.y) > NIGHT_ON
		n = n.get_parent()
	return false
