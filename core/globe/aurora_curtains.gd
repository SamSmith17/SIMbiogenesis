class_name AuroraCurtains
extends RefCounted

## Field-aligned aurora curtains for the globe. A centred dipole,
## r = L sin²θ (θ = colatitude from the local magnetic pole). Going up the
## line, r grows, so θ grows: the curtain leans away from the magnetic pole,
## toward the equator, which is the way a dipole field actually leaves the
## atmosphere. Magnetic longitude stays fixed, so each ribbon is one field line.
##
## The oval's peak magnetic latitude is AuroraModel's (the same fit the shell
## shader mirrors). Both hemispheres. The mesh is a continuous sheet (three
## per oval); globe_aurora_curtain.gdshader folds it in real time and colours
## it from the footpoint. The first cut was 72 separate 140 km ribbons with
## ~100 km of nothing between them, which read as a segmented ring.

const H0_KM := 100.0
const H1_KM := 400.0
const LON_STEPS := 360
const H_STEPS := 10
const R_KM := 6371.0
## [latitude shift of the sheet's foot from the oval's peak (deg), fold phase
## 0..1]: the main curtain, one poleward, one equatorward.
const SHEETS := [[0.0, 0.0], [-2.2, 0.37], [1.6, 0.71]]


## Peak |magnetic latitude| of the oval at `phi` radians from magnetic midnight.
static func peak_mag_lat(kp: float, phi: float) -> float:
	return AuroraModel.edge_lat(kp, phi) + 0.5 * AuroraModel.width(kp, phi)


## One point on the field line through the oval's peak.
## `hemi` is +1 (north) or -1 (south). `phi` is the angle from magnetic
## midnight (it sets the peak latitude; the point itself sits on longitude 0
## of the dipole basis). Returns pos (globe radii), theta (colatitude from
## the local pole, radians) and mag_lat (degrees, signed).
static func sample(kp: float, phi: float, hemi: int, height_km: float,
		pole: Vector3 = AuroraModel.pole_dir()) -> Dictionary:
	var c := clampf(peak_mag_lat(kp, phi), 40.0, 85.0)
	var theta0 := deg_to_rad(90.0 - c)
	var r0 := 1.0 + H0_KM / R_KM
	var L := r0 / maxf(sin(theta0) * sin(theta0), 1e-4)
	var r := 1.0 + height_km / R_KM
	var sin2 := clampf(r / L, 0.0, 1.0)
	var theta := asin(sqrt(sin2))
	var axis := pole * float(hemi)
	var pos := _on_line(axis, theta, 0.0, _basis(pole)) * r
	return {
		"pos": pos,
		"theta": theta,
		"mag_lat": AuroraModel.mag_lat(pos.normalized(), pole),
		"peak": c * float(hemi),
	}


## Magnetic longitude (radians) of a direction about the dipole axis.
static func mag_lon(p: Vector3, pole: Vector3 = AuroraModel.pole_dir()) -> float:
	var b := _basis(pole)
	var a := p - pole * p.dot(pole)
	return atan2(a.dot(b[1]), a.dot(b[0]))


## Both ovals as CONTINUOUS sheets, in globe space (Earth radius 1). Per
## hemisphere SHEETS curtains: the main one on the oval's peak and fainter
## ones a few degrees either side (they take their brightness from the smooth
## band at their own foot, so the offset ones are dimmer by the band's own
## profile). Each sheet is one closed strip round the pole, LON_STEPS columns
## by H_STEPS rows, so there are no gaps between ribbons; the shader folds it
## in real time. NORMAL = the sheet's horizontal (poleward) normal, COLOR.r =
## the sheet's fold phase, UV = (longitude fraction, height fraction).
static func build_mesh(kp: float, sun: Vector3, pole: Vector3 = AuroraModel.pole_dir()) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var basis := _basis(pole)
	var sun_lon := mag_lon(sun, pole)
	var r0 := 1.0 + H0_KM / R_KM
	for hemi in [1, -1]:
		var axis := pole * float(hemi)
		for sheet in SHEETS.size():
			var shift: float = SHEETS[sheet][0]
			var phase: float = SHEETS[sheet][1]
			var base := verts.size()
			for s in LON_STEPS + 1:
				var lon := TAU * float(s % LON_STEPS) / float(LON_STEPS)
				var phi := PI - absf(wrapf(lon - sun_lon, -PI, PI))
				# A side sheet drifts toward and away from the main one round the
				# oval, so the three never read as parallel rings.
				var drift := 0.55 + 0.45 * sin(lon * 3.0 + phase * TAU)
				var c := clampf(peak_mag_lat(kp, phi) + shift * drift, 40.0, 86.0)
				var theta0 := deg_to_rad(90.0 - c)
				var L := r0 / maxf(sin(theta0) * sin(theta0), 1e-4)
				for h in H_STEPS + 1:
					var hk := lerpf(H0_KM, H1_KM, float(h) / float(H_STEPS))
					var r := 1.0 + hk / R_KM
					var sin2 := clampf(r / L, 0.0, 1.0)
					var theta := asin(sqrt(sin2))
					var d := _on_line(axis, theta, lon, basis)
					verts.append(d * r)
					# Poleward along the sheet: the tangent toward the axis.
					var pw := (axis - d * d.dot(axis))
					norms.append(pw.normalized() if pw.length() > 1e-6 else basis[0])
					cols.append(Color(phase, float(sheet) / 4.0, 0.0, 1.0))
					uvs.append(Vector2(float(s) / float(LON_STEPS), float(h) / float(H_STEPS)))
			for s in LON_STEPS:
				for h in H_STEPS:
					var i := base + s * (H_STEPS + 1) + h
					var j := i + H_STEPS + 1
					idx.append_array(PackedInt32Array([i, i + 1, j, i + 1, j + 1, j]))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


static func _basis(pole: Vector3) -> Array:
	var ref := pole.cross(Vector3(0, 0, 1))
	if ref.length() < 1e-4:
		ref = pole.cross(Vector3(1, 0, 0))
	ref = ref.normalized()
	return [ref, pole.cross(ref).normalized()]


static func _on_line(axis: Vector3, theta: float, lon: float, basis: Array) -> Vector3:
	var horiz: Vector3 = basis[0] * cos(lon) + basis[1] * sin(lon)
	return (axis * cos(theta) + horiz * sin(theta)).normalized()
