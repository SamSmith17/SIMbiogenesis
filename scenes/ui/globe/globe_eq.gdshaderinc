// Equirect (plate carree) lookups from a direction in the globe frame
// (GlobeMath: +Y north pole, lon 0 on +Z, 90° E on +X). Row 0 = 90° N.

vec2 globe_eq_uv(vec3 n) {
	return vec2(atan(n.x, n.z) / (2.0 * PI) + 0.5, 0.5 - asin(clamp(n.y, -1.0, 1.0)) / PI);
}

// textureGrad with the gradient of a seam-free copy of u where that is the
// smaller one, so mip selection does not draw a line down the antimeridian.
vec4 globe_eq_sample(sampler2D t, vec3 n) {
	vec2 uv = globe_eq_uv(n);
	vec2 uvb = vec2(fract(uv.x + 0.5), uv.y);
	vec2 dx = dFdx(uv);
	vec2 dy = dFdy(uv);
	vec2 dxb = dFdx(uvb);
	vec2 dyb = dFdy(uvb);
	if (dot(dxb, dxb) + dot(dyb, dyb) < dot(dx, dx) + dot(dy, dy)) {
		dx = dxb;
		dy = dyb;
	}
	return textureGrad(t, uv, dx, dy);
}
