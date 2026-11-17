class_name MimicIcons
extends RefCounted
## Equipment pictures for the process picture (the Process lens). Pure.
##
## A node with a 3D model (its own `model_id`, or its placed prop's) is
## drawn from the same model the graph cards snapshot, but seen straight on
## (orthographic, side by default) and redrawn in the picture's own look:
## flat grey tones in three bands, light line work where the shading turns
## and a light outline round the silhouette (`stylize`). Colour stays for
## state (the lamp, the selection), as in a high-performance HMI.
##
## A node with no model gets a pictogram of what it does (`glyph_for`).
##
##   VIEWS / LABELS / camera(view)   side | front | three_quarter | top
##   stylize(img) -> Image           cropped to the silhouette, RGBA8
##   glyph_for(item) -> String       a UiIcons name ("" = none fits)

const VIEW_SIDE := "side"
const VIEW_FRONT := "front"
const VIEW_3Q := "three_quarter"
const VIEW_TOP := "top"
const VIEW_BOXES := "boxes"
const VIEWS := [VIEW_SIDE, VIEW_FRONT, VIEW_3Q, VIEW_TOP]
const LABELS := {VIEW_SIDE: "Side", VIEW_FRONT: "Front", VIEW_3Q: "¾ view", VIEW_TOP: "Top", VIEW_BOXES: "Boxes"}
## Bump when the look of a stylized icon changes (cached on disk).
const STYLE_VERSION := 2

## Tones (light to dark), the line work and the outline.
const TONES := [Color(0.56, 0.61, 0.68), Color(0.42, 0.46, 0.53), Color(0.30, 0.33, 0.39)]
const LINE := Color(0.70, 0.75, 0.82)
const OUTLINE := Color(0.80, 0.84, 0.90)
## Luminance turn (0..1, after normalising) that draws a line.
const EDGE_AT := 0.28
const PAD := 3


## Camera for a view: yaw (degrees, 0 = looking at the model's front from
## +Z) and pitch (degrees above level).
static func camera(view: String) -> Dictionary:
	match view:
		VIEW_FRONT:
			return {"yaw": 0.0, "pitch": 0.0}
		VIEW_3Q:
			return {"yaw": 38.0, "pitch": 24.0}
		VIEW_TOP:
			return {"yaw": 0.0, "pitch": 89.0}
	return {"yaw": 90.0, "pitch": 0.0}


static func next_view(view: String) -> String:
	var i := VIEWS.find(view)
	return VIEWS[(i + 1) % VIEWS.size()] if i >= 0 else VIEWS[0]


## The picture's look applied to a rendered model (transparent background).
## Cropped to the silhouette plus a small margin; empty when nothing drew.
static func stylize(src: Image) -> Image:
	if src == null or src.is_empty():
		return Image.new()
	var img := src.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	# Silhouette and its box.
	var x0 := w
	var y0 := h
	var x1 := -1
	var y1 := -1
	var lum := PackedFloat32Array()
	lum.resize(w * h)
	var mask := PackedByteArray()
	mask.resize(w * h)
	for y in h:
		for x in w:
			var i := y * w + x
			var o := i * 4
			if data[o + 3] > 110:
				mask[i] = 1
				lum[i] = (0.30 * data[o] + 0.59 * data[o + 1] + 0.11 * data[o + 2]) / 255.0
				x0 = mini(x0, x)
				y0 = mini(y0, y)
				x1 = maxi(x1, x)
				y1 = maxi(y1, y)
	if x1 < 0:
		return Image.new()
	# Normalise the shading over the silhouette (5th to 95th percentile).
	var vals := PackedFloat32Array()
	for i in w * h:
		if mask[i] == 1:
			vals.append(lum[i])
	vals.sort()
	var lo := vals[int(vals.size() * 0.05)]
	var hi := vals[mini(int(vals.size() * 0.95), vals.size() - 1)]
	var span := maxf(hi - lo, 0.08)
	# Smoothed shading (3×3 over the silhouette only), so bands are not speckle.
	var sm := PackedFloat32Array()
	sm.resize(w * h)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var i := y * w + x
			if mask[i] == 0:
				continue
			var s := 0.0
			var n := 0
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var xx := x + dx
					var yy := y + dy
					if xx < 0 or yy < 0 or xx >= w or yy >= h:
						continue
					var j := yy * w + xx
					if mask[j] == 1:
						s += lum[j]
						n += 1
			sm[i] = clampf((s / float(n) - lo) / span, 0.0, 1.0)
	# Out: the box grown by PAD.
	var ox0 := maxi(x0 - PAD, 0)
	var oy0 := maxi(y0 - PAD, 0)
	var ow := mini(x1 + PAD, w - 1) - ox0 + 1
	var oh := mini(y1 + PAD, h - 1) - oy0 + 1
	var out := PackedByteArray()
	out.resize(ow * oh * 4)
	for oy in oh:
		for ox in ow:
			var x := ox + ox0
			var y := oy + oy0
			var i := y * w + x
			var col := Color(0, 0, 0, 0)
			if mask[i] == 1:
				var v := sm[i]
				var band := 0 if v > 0.62 else (1 if v > 0.30 else 2)
				col = TONES[band]
				# The edge of the silhouette: the outline.
				var edge := false
				for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var xx := x + d.x
					var yy := y + d.y
					if xx < 0 or yy < 0 or xx >= w or yy >= h or mask[yy * w + xx] == 0:
						edge = true
						break
				if edge:
					col = OUTLINE
				else:
					# Where the shading turns sharply: a line.
					var gx := _at(sm, mask, w, h, x + 1, y, v) - _at(sm, mask, w, h, x - 1, y, v)
					var gy := _at(sm, mask, w, h, x, y + 1, v) - _at(sm, mask, w, h, x, y - 1, v)
					var g := sqrt(gx * gx + gy * gy)
					if g > EDGE_AT:
						col = col.lerp(LINE, clampf((g - EDGE_AT) / EDGE_AT, 0.0, 1.0) * 0.8)
			else:
				# A soft rim just outside, so the outline is not stair-stepped.
				var near := 0
				for d2: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var xx2 := x + d2.x
					var yy2 := y + d2.y
					if xx2 >= 0 and yy2 >= 0 and xx2 < w and yy2 < h and mask[yy2 * w + xx2] == 1:
						near += 1
				if near > 0:
					col = Color(OUTLINE, 0.30 + 0.15 * float(near))
			var o2 := (oy * ow + ox) * 4
			out[o2] = int(clampf(col.r, 0.0, 1.0) * 255.0)
			out[o2 + 1] = int(clampf(col.g, 0.0, 1.0) * 255.0)
			out[o2 + 2] = int(clampf(col.b, 0.0, 1.0) * 255.0)
			out[o2 + 3] = int(clampf(col.a, 0.0, 1.0) * 255.0)
	return Image.create_from_data(ow, oh, false, Image.FORMAT_RGBA8, out)


static func _at(sm: PackedFloat32Array, mask: PackedByteArray, w: int, h: int, x: int, y: int, fallback: float) -> float:
	if x < 0 or y < 0 or x >= w or y >= h:
		return fallback
	var i := y * w + x
	return sm[i] if mask[i] == 1 else fallback


## Width / height of a picture (1 when empty).
static func aspect(img_or_tex: Variant) -> float:
	var sz := Vector2.ONE
	if img_or_tex is Image:
		sz = Vector2((img_or_tex as Image).get_size())
	elif img_or_tex is Texture2D:
		sz = (img_or_tex as Texture2D).get_size()
	return sz.x / sz.y if sz.y > 0.5 else 1.0


## Words in a node that say what it is → a pictogram (first match wins, so
## the specific come before the general).
const GLYPHS := [
	[["breaker", "plug", "outlet", "socket", "fuse"], "plug"],
	[["battery", "bank"], "battery"],
	[["inverter", "controller", "mppt", "charger", "board", " esp"], "cpu"],
	[["generator", "genset", "turbine", "alternator"], "zap"],
	[["solar", "panel", " pv ", "sunlight", "sun"], "sun"],
	[["wind"], "wind"],
	[["hydro", "siphon", "pelton", "stream"], "waves"],
	[["rain", "catchment", "apron", "roof water"], "cloud-rain"],
	[["kitchen", "stove", "cook", "burner", "boiler", "heater", "biochar", "reactor", "retort", "kiln", "digester", "compost", "fire"], "flame"],
	[["fridge", "freezer", "cool", " ac ", "air con"], "thermometer"],
	[["light", "lamp"], "lightbulb"],
	[["filter", "water", " awg", "atmospheric", " well", "treatment", "distil", "urine", "nutrient", "greywater", "blackwater"], "droplet"],
	[[" bed", "garden", "greenhouse", "plant", "crop", "farm", "orchard", "forest"], "sprout"],
	[["shredder", "molder", "mould", "mold", "extruder", "press", "printer", "cnc", "router", "workshop", "saw", "drill"], "hammer"],
	[["habitat", "population", "camp", "house", "people", "the ten"], "users"],
	[["vehicle", " bus", " van", " rv ", "truck", "skoolie", "trailer"], "truck"],
	[[" fan"], "wind"],
	[["unpack", "supply", "store", "pantry", "delivery", "collection", "import"], "package"],
]


## The pictogram for a node with no model ("" = none fits: a plain cabinet).
static func glyph_for(item: Dictionary) -> String:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var text := " %s %s %s %s " % [str(specs.get("name", "")), str(specs.get("role", "")),
		str(item.get("type", "")), str(specs.get("preset", specs.get("preset_label", "")))]
	text = text.to_lower().replace("_", " ")
	for g in GLYPHS:
		for word in (g[0] as Array):
			if text.contains(str(word)):
				return str(g[1])
	match str(item.get("type", "")):
		"panel":
			return "sun"
		"battery", "smartbattery":
			return "battery"
		"controller":
			return "cpu"
		"wind":
			return "wind"
		"hydro":
			return "waves"
		"plant":
			return "sprout"
		"catchment":
			return "cloud-rain"
		"appliance", "acload":
			return "plug"
	return "wrench" if str(item.get("type", "")) == "processor" else ""
