class_name Grib2Decoder
extends RefCounted

## A small GRIB2 reader (pure, autoload-free) for one message on a regular
## lat/lon grid: grid definition template 3.0, product template 4.0, data
## representation 5.0 (simple packing) and 5.2 / 5.3 (complex packing, with
## spatial differencing for 5.3), bitmap absent or present. That covers NOAA
## GFS's pgrb2 fields (5.3). ECMWF open data is 5.42 (CCSDS) and is refused.
##
## Reference: WMO Manual on Codes, FM 92 GRIB edition 2, sections 0-8 and
## templates 3.0 / 4.0 / 5.0 / 5.2 / 5.3 / 7.2 / 7.3; the unpacking follows
## NCEP g2clib's comunpack.c (group references, widths and lengths each
## padded to a byte; spatial-differencing descriptors sign-magnitude).
##
## decode(bytes) -> {ok, error, values: PackedFloat32Array (row-major as
## stored), ni, nj, la1, lo1, la2, lo2, di, dj, scan, category, number,
## forecast_h, level_type, level, ref_unix, template}.
## Y = (R + X * 2^E) / 10^D.


## Signed integer stored sign-magnitude in `n` bytes (GRIB2's convention).
static func _smag(b: PackedByteArray, o: int, n: int) -> int:
	var v := 0
	for i in n:
		v = (v << 8) | b[o + i]
	var sign_bit := 1 << (8 * n - 1)
	if v & sign_bit:
		return -(v & (sign_bit - 1))
	return v


static func _u(b: PackedByteArray, o: int, n: int) -> int:
	var v := 0
	for i in n:
		v = (v << 8) | b[o + i]
	return v


static func _f32(b: PackedByteArray, o: int) -> float:
	var t := PackedByteArray([b[o + 3], b[o + 2], b[o + 1], b[o]])
	return t.decode_float(0)


## Big-endian bit reader over a PackedByteArray.
class Bits:
	var b: PackedByteArray
	var pos := 0   # in bits

	func _init(bytes: PackedByteArray, byte_offset: int) -> void:
		b = bytes
		pos = byte_offset * 8

	func read(n: int) -> int:
		if n <= 0:
			return 0
		var v := 0
		var left := n
		while left > 0:
			var byte_i := pos >> 3
			var bit_i := pos & 7
			var avail := 8 - bit_i
			var take := mini(avail, left)
			var cur := b[byte_i] if byte_i < b.size() else 0
			var chunk := (cur >> (avail - take)) & ((1 << take) - 1)
			v = (v << take) | chunk
			left -= take
			pos += take
		return v

	func align() -> void:
		pos = ((pos + 7) >> 3) << 3


static func decode(bytes: PackedByteArray) -> Dictionary:
	var out := {"ok": false, "error": ""}
	if bytes.size() < 16 or bytes.slice(0, 4).get_string_from_ascii() != "GRIB":
		out.error = "not a GRIB message"
		return out
	if bytes[7] != 2:
		out.error = "GRIB edition %d (only 2)" % bytes[7]
		return out
	var total := _u(bytes, 8, 8)
	var o := 16
	var s5 := -1
	var s6 := -1
	var s7 := -1
	while o + 5 <= mini(total, bytes.size()):
		if bytes.slice(o, o + 4).get_string_from_ascii() == "7777":
			break
		var length := _u(bytes, o, 4)
		var num := bytes[o + 4]
		if length < 5:
			out.error = "bad section length"
			return out
		match num:
			1:
				var dt := {"year": _u(bytes, o + 12, 2), "month": bytes[o + 14], "day": bytes[o + 15],
					"hour": bytes[o + 16], "minute": bytes[o + 17], "second": bytes[o + 18]}
				out.ref_unix = float(Time.get_unix_time_from_datetime_dict(dt))
			3:
				var tmpl := _u(bytes, o + 12, 2)
				if tmpl != 0:
					out.error = "grid template 3.%d (only 3.0)" % tmpl
					return out
				out.npts = _u(bytes, o + 6, 4)
				out.ni = _u(bytes, o + 30, 4)
				out.nj = _u(bytes, o + 34, 4)
				out.la1 = float(_smag(bytes, o + 46, 4)) * 1e-6
				out.lo1 = float(_smag(bytes, o + 50, 4)) * 1e-6
				out.la2 = float(_smag(bytes, o + 55, 4)) * 1e-6
				out.lo2 = float(_smag(bytes, o + 59, 4)) * 1e-6
				out.di = float(_u(bytes, o + 63, 4)) * 1e-6
				out.dj = float(_u(bytes, o + 67, 4)) * 1e-6
				out.scan = bytes[o + 71]
			4:
				out.category = bytes[o + 9]
				out.number = bytes[o + 10]
				out.forecast_h = _u(bytes, o + 18, 4)
				out.level_type = bytes[o + 22]
				var sf := _smag(bytes, o + 23, 1)
				out.level = float(_smag(bytes, o + 24, 4)) / pow(10.0, float(sf))
			5:
				s5 = o
			6:
				s6 = o
			7:
				s7 = o
		o += length
	if s5 < 0 or s7 < 0 or not out.has("ni"):
		out.error = "missing sections"
		return out
	var tmpl5 := _u(bytes, s5 + 9, 2)
	out.template = tmpl5
	var n := _u(bytes, s5 + 5, 4)
	var r := _f32(bytes, s5 + 11)
	var e := _smag(bytes, s5 + 15, 2)
	var d := _smag(bytes, s5 + 17, 2)
	var nbits := bytes[s5 + 19]
	var ints := PackedInt64Array()
	match tmpl5:
		0:
			ints = _unpack_simple(bytes, s7 + 5, n, nbits)
		2, 3:
			var res := _unpack_complex(bytes, s5, s7, n, nbits, tmpl5)
			if res.has("error"):
				out.error = res.error
				return out
			ints = res.ints
		_:
			out.error = "data template 5.%d (only 5.0 / 5.2 / 5.3)" % tmpl5
			return out
	var scale_e := pow(2.0, float(e))
	var scale_d := pow(10.0, float(-d))
	var vals := PackedFloat32Array()
	# Bitmap: present (indicator 0) -> spread the packed values over it.
	var npts := int(out.get("npts", n))
	vals.resize(npts)
	if s6 >= 0 and bytes[s6 + 5] == 0:
		var bm := Bits.new(bytes, s6 + 6)
		var k := 0
		for i in npts:
			if bm.read(1) == 1 and k < ints.size():
				vals[i] = (r + float(ints[k]) * scale_e) * scale_d
				k += 1
			else:
				vals[i] = NAN
	else:
		for i in mini(npts, ints.size()):
			vals[i] = (r + float(ints[i]) * scale_e) * scale_d
	out.values = vals
	out.ok = true
	return out


static func _unpack_simple(b: PackedByteArray, data_off: int, n: int, nbits: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	out.resize(n)
	if nbits == 0:
		return out
	var br := Bits.new(b, data_off)
	for i in n:
		out[i] = br.read(nbits)
	return out


static func _unpack_complex(b: PackedByteArray, s5: int, s7: int, n: int, nbits: int,
		tmpl: int) -> Dictionary:
	var missing_mgmt := b[s5 + 22]
	var ng := _u(b, s5 + 31, 4)
	var ref_w := b[s5 + 35]
	var bits_w := b[s5 + 36]
	var ref_l := _u(b, s5 + 37, 4)
	var incr_l := b[s5 + 41]
	var last_l := _u(b, s5 + 42, 4)
	var bits_l := b[s5 + 46]
	var order := 0
	var noct := 0
	if tmpl == 3:
		order = b[s5 + 47]
		noct = b[s5 + 48]
	if missing_mgmt != 0:
		return {"error": "complex packing with missing values is not supported"}
	var br := Bits.new(b, s7 + 5)
	var ival1 := 0
	var ival2 := 0
	var minsd := 0
	if order > 0:
		var nb := noct * 8
		var sgn := br.read(1)
		ival1 = br.read(nb - 1)
		if sgn == 1:
			ival1 = -ival1
		if order == 2:
			sgn = br.read(1)
			ival2 = br.read(nb - 1)
			if sgn == 1:
				ival2 = -ival2
		sgn = br.read(1)
		minsd = br.read(nb - 1)
		if sgn == 1:
			minsd = -minsd
	var grefs := PackedInt64Array()
	grefs.resize(ng)
	for g in ng:
		grefs[g] = br.read(nbits)
	br.align()
	var gwid := PackedInt32Array()
	gwid.resize(ng)
	for g in ng:
		gwid[g] = br.read(bits_w) + ref_w
	br.align()
	var glen := PackedInt32Array()
	glen.resize(ng)
	for g in ng:
		glen[g] = ref_l + br.read(bits_l) * incr_l
	br.align()
	if ng > 0:
		glen[ng - 1] = last_l
	var ints := PackedInt64Array()
	ints.resize(n)
	var k := 0
	for g in ng:
		var w := gwid[g]
		var ref := grefs[g]
		for _j in glen[g]:
			if k >= n:
				break
			ints[k] = ref + (br.read(w) if w > 0 else 0)
			k += 1
	if k != n:
		return {"error": "group lengths add up to %d, not %d" % [k, n]}
	if order == 1:
		ints[0] = ival1
		for i in range(1, n):
			ints[i] = ints[i] + minsd + ints[i - 1]
	elif order == 2:
		ints[0] = ival1
		if n > 1:
			ints[1] = ival2
		for i in range(2, n):
			ints[i] = ints[i] + minsd + 2 * ints[i - 1] - ints[i - 2]
	return {"ints": ints}


## A regular lat/lon grid as a north-up, east-going field from 0° E:
## {nx, ny, lat0 (north edge row), lon0, dlat (>0), dlon (>0), values}.
## Flips rows / columns per the scanning mode so callers index [j * nx + i]
## with j = 0 at the northern row and i = 0 at lon0.
static func to_field(msg: Dictionary) -> Dictionary:
	var nx := int(msg.ni)
	var ny := int(msg.nj)
	var scan := int(msg.scan)
	var src: PackedFloat32Array = msg.values
	var vals := PackedFloat32Array()
	vals.resize(nx * ny)
	var i_neg := (scan & 0x80) != 0
	var j_pos := (scan & 0x40) != 0   # rows south -> north
	for j in ny:
		for i in nx:
			var si := (nx - 1 - i) if i_neg else i
			var sj := (ny - 1 - j) if j_pos else j
			vals[j * nx + i] = src[sj * nx + si]
	var lat_n := maxf(float(msg.la1), float(msg.la2))
	var lon_w := minf(float(msg.lo1), float(msg.lo2)) if not i_neg else float(msg.lo2)
	return {"nx": nx, "ny": ny, "lat0": lat_n, "lon0": lon_w, "dlat": float(msg.dj),
		"dlon": float(msg.di), "values": vals}


## Bilinear sample of a field at lat / lon (longitude wraps).
static func sample(f: Dictionary, lat: float, lon: float) -> float:
	var nx := int(f.nx)
	var ny := int(f.ny)
	var fx := fposmod(lon - float(f.lon0), 360.0) / float(f.dlon)
	var fy := clampf((float(f.lat0) - lat) / float(f.dlat), 0.0, float(ny - 1))
	var x0 := int(floor(fx)) % nx
	var x1 := (x0 + 1) % nx
	var y0 := int(floor(fy))
	var y1 := mini(y0 + 1, ny - 1)
	var tx := fx - floorf(fx)
	var ty := fy - float(y0)
	var v: PackedFloat32Array = f.values
	var a := lerpf(v[y0 * nx + x0], v[y0 * nx + x1], tx)
	var c := lerpf(v[y1 * nx + x0], v[y1 * nx + x1], tx)
	return lerpf(a, c, ty)
