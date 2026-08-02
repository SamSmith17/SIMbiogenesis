extends SceneTree

## One-off photocard ingest tool (veg overhaul Phase 5+). Prepares CC0 cutout
## textures for assets/vegetation/photocards/<species>.png:
##
##   # Split a multi-tree atlas into per-tree PNGs (islands separated by fully
##   # transparent columns):
##   Godot.exe.exe --headless --path . --script vegetation/tools/photocard_ingest.gd -- --split=<in.png> --out-dir=<dir>
##
##   # Trim to the opaque bounding box + downscale to --max-h (default 1024)
##   # and save (the standard per-species prep):
##   Godot.exe.exe --headless --path . --script vegetation/tools/photocard_ingest.gd -- --pack=<in.png> --out=<species.png> [--max-h=1024]
##
##   # Alpha/size stats for every PNG in a dir (curation shortlist):
##   Godot.exe.exe --headless --path . --script vegetation/tools/photocard_ingest.gd -- --stats=<dir>
##
## Pure Image ops (no Pillow / external deps), matching the project's other
## one-off --script tools (pipe_kit_extractor, scad_ingest).

const DEFAULT_MAX_H := 1024


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var opts := {}
	for a in args:
		if a.begins_with("--") and a.contains("="):
			opts[a.get_slice("=", 0).trim_prefix("--")] = a.get_slice("=", 1)
	var code := 1
	if opts.has("split"):
		code = _split_atlas(str(opts["split"]), str(opts.get("out-dir", ".")))
	elif opts.has("pack"):
		# Optional --crop=x,y,w,h applied BEFORE trim/resize (for hand-cutting
		# touching trees an automatic split can't separate).
		var crop := Rect2i()
		if opts.has("crop"):
			var parts := str(opts["crop"]).split(",")
			if parts.size() == 4:
				crop = Rect2i(int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3]))
		code = _pack(str(opts["pack"]), str(opts.get("out", "out.png")),
			int(opts.get("max-h", DEFAULT_MAX_H)), crop)
	elif opts.has("stats"):
		code = _stats(str(opts["stats"]))
	else:
		print("photocard_ingest: need --split=, --pack= or --stats= (see header)")
	quit(code)


static func _load_img(path: String) -> Image:
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		print("photocard_ingest: cannot load %s" % path)
		return null
	img.convert(Image.FORMAT_RGBA8)
	return img


## Opaque bounding box (alpha > threshold), or empty Rect2i.
static func _opaque_bbox(img: Image, threshold := 8) -> Rect2i:
	var min_x := img.get_width()
	var max_x := -1
	var min_y := img.get_height()
	var max_y := -1
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a8 > threshold:
				min_x = mini(min_x, x)
				max_x = maxi(max_x, x)
				min_y = mini(min_y, y)
				max_y = maxi(max_y, y)
	if max_x < 0:
		return Rect2i()
	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


static func _pack(in_path: String, out_path: String, max_h: int,
		crop := Rect2i()) -> int:
	var img := _load_img(in_path)
	if img == null:
		return 1
	if crop.size.x > 0 and crop.size.y > 0:
		img = img.get_region(crop.intersection(Rect2i(0, 0, img.get_width(), img.get_height())))
	var bbox := _opaque_bbox(img)
	if bbox.size.x <= 0:
		print("photocard_ingest: %s has no opaque pixels" % in_path)
		return 1
	var trimmed := img.get_region(bbox)
	if trimmed.get_height() > max_h:
		var scale := float(max_h) / float(trimmed.get_height())
		trimmed.resize(maxi(int(trimmed.get_width() * scale), 1), max_h,
			Image.INTERPOLATE_LANCZOS)
	trimmed.save_png(out_path)
	print("photocard_ingest: %s -> %s  (%dx%d)" % [
		in_path.get_file(), out_path, trimmed.get_width(), trimmed.get_height()])
	return 0


## Split an atlas into islands separated by FULLY transparent pixel columns.
static func _split_atlas(in_path: String, out_dir: String) -> int:
	var img := _load_img(in_path)
	if img == null:
		return 1
	DirAccess.make_dir_recursive_absolute(out_dir)
	var w := img.get_width()
	var h := img.get_height()
	var col_opaque := PackedByteArray()
	col_opaque.resize(w)
	for x in w:
		var any := 0
		for y in h:
			if img.get_pixel(x, y).a8 > 8:
				any = 1
				break
		col_opaque[x] = any
	var islands: Array = []
	var start := -1
	for x in w:
		if col_opaque[x] == 1 and start < 0:
			start = x
		elif col_opaque[x] == 0 and start >= 0:
			islands.append(Vector2i(start, x - 1))
			start = -1
	if start >= 0:
		islands.append(Vector2i(start, w - 1))
	var idx := 0
	for isl in islands:
		var span: Vector2i = isl
		if span.y - span.x < 24:
			continue  # skip slivers/debris
		var slice := img.get_region(Rect2i(span.x, 0, span.y - span.x + 1, h))
		var bbox := _opaque_bbox(slice)
		if bbox.size.x <= 0:
			continue
		idx += 1
		var out := "%s/tree_%02d.png" % [out_dir, idx]
		slice.get_region(bbox).save_png(out)
		print("photocard_ingest: island %d cols %d..%d -> %s" % [idx, span.x, span.y, out])
	print("photocard_ingest: %d islands" % idx)
	return 0 if idx > 0 else 1


static func _stats(dir_path: String) -> int:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		print("photocard_ingest: cannot open %s" % dir_path)
		return 1
	print("%-24s %6s %6s %7s %7s" % ["file", "w", "h", "alpha%", "aspect"])
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.to_lower().ends_with(".png"):
			var img := _load_img("%s/%s" % [dir_path, f])
			if img != null:
				var transparent := 0
				var stride := maxi(int(img.get_width() * img.get_height() / 20000.0), 1)
				var sampled := 0
				var i := 0
				for y in img.get_height():
					for x in img.get_width():
						if i % stride == 0:
							sampled += 1
							if img.get_pixel(x, y).a8 <= 8:
								transparent += 1
						i += 1
				var alpha_pct := 100.0 * float(transparent) / maxf(float(sampled), 1.0)
				print("%-24s %6d %6d %6.1f%% %7.2f" % [f, img.get_width(), img.get_height(),
					alpha_pct, float(img.get_height()) / maxf(float(img.get_width()), 1.0)])
		f = dir.get_next()
	return 0
