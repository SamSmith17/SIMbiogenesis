class_name KmlPoiParser
extends RefCounted

## Pure KML / KMZ reader for the points-of-interest import (core/poi/).
##
## Reads what a Google Earth "export" carries and nothing more: Placemarks
## with a Point, LineString or Polygon (outer ring only — holes are ignored),
## their name / description / folder, and the colour their style resolves to.
## Everything else in the file (LookAt, balloons, the proprietary `ex:extension`
## blobs, CascadingStyle wrappers, hotspots) is skipped on purpose.
##
## No scene, no autoload, no file side effects beyond reading — so the
## selftest feeds it the shipped fixture offline. Coordinates come back as
## WGS84 (lon, lat, alt) in a Vector3, exactly as the file orders them; the
## layer (`PoiLayer`) turns them into the game's site-relative metres.
##
## Style colours: a KML <color> is AABBGGRR hex (NOT rrggbb). Google Earth
## encodes a point's pin colour in the icon URL instead (`color=1976d2`, rrggbb),
## so that is read as the fallback for points.

const KIND_POINT := "point"
const KIND_LINE := "line"
const KIND_POLYGON := "polygon"


## Read a .kml or .kmz from disk. Returns the same shape as parse_text
## ({ok, error, name, placemarks, warnings}).
static func parse_file(path: String) -> Dictionary:
	var ext := path.get_extension().to_lower()
	var text := ""
	if ext == "kmz":
		var zr := ZIPReader.new()
		if zr.open(path) != OK:
			return _fail("Could not open KMZ: %s" % path)
		var entry := ""
		for f in zr.get_files():
			if f.to_lower() == "doc.kml":
				entry = f
				break
			if entry.is_empty() and f.to_lower().ends_with(".kml"):
				entry = f
		if entry.is_empty():
			zr.close()
			return _fail("No .kml inside the KMZ")
		text = zr.read_file(entry).get_string_from_utf8()
		zr.close()
	else:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			return _fail("Could not read %s" % path)
		text = f.get_as_text()
		f.close()
	var out := parse_text(text)
	if bool(out.get("ok", false)) and str(out.get("name", "")).is_empty():
		out["name"] = path.get_file().get_basename()
	return out


## Parse KML XML text. Result:
##   {ok: bool, error: String, name: String (Document name),
##    placemarks: [{kml_id, name, description, folder, style_url, kind,
##                  coords: Array of [lon, lat, alt] floats, color: String ("#rrggbb" or "")}],
##    warnings: Array[String]}
## A Placemark with several geometries (MultiGeometry) becomes one entry per
## geometry, the later ones suffixed " (2)", " (3)" …
static func parse_text(text: String) -> Dictionary:
	if text.begins_with("﻿"):
		text = text.substr(1)
	var p := XMLParser.new()
	if p.open_buffer(text.to_utf8_buffer()) != OK:
		return _fail("Not readable as XML")
	var stack: Array[String] = []
	var buf := ""
	var doc_name := ""
	var folders: Array[String] = []
	var raw_placemarks: Array = []
	var styles: Dictionary = {}       # id -> {icon_color, icon_href, line_color, poly_color}
	var style_maps: Dictionary = {}   # id -> {key: url}
	var cur_pm: Dictionary = {}
	var in_pm := false
	var cur_geom := ""
	var in_inner := false
	var cur_style: Dictionary = {}
	var cur_style_id := ""
	var cascading_id := ""
	var cur_map: Dictionary = {}
	var cur_pair: Dictionary = {}
	var warnings: Array[String] = []
	var saw_kml := false

	while p.read() == OK:
		var t := p.get_node_type()
		if t == XMLParser.NODE_ELEMENT:
			var name := _local(p.get_node_name())
			var empty := p.is_empty()
			buf = ""
			match name:
				"kml":
					saw_kml = true
				"Placemark":
					in_pm = true
					cur_pm = {
						"kml_id": p.get_named_attribute_value_safe("id"),
						"name": "", "description": "", "folder": "/".join(folders),
						"style_url": "", "geoms": [],
					}
				"Folder":
					folders.append("")
				"Style":
					cur_style = {}
					cur_style_id = p.get_named_attribute_value_safe("id")
					if cur_style_id.is_empty():
						cur_style_id = cascading_id
				"CascadingStyle":
					cascading_id = p.get_named_attribute_value_safe("kml:id")
					if cascading_id.is_empty():
						cascading_id = p.get_named_attribute_value_safe("id")
				"StyleMap":
					cur_map = {"id": p.get_named_attribute_value_safe("id"), "pairs": {}}
				"Pair":
					cur_pair = {"key": "", "url": ""}
				"Point", "LineString", "Polygon":
					cur_geom = name
				"innerBoundaryIs":
					in_inner = true
			if not empty:
				stack.append(name)
			else:
				# A self-closing element has no end event — nothing to dispatch.
				pass
		elif t == XMLParser.NODE_TEXT:
			buf += p.get_node_data()
		elif t == XMLParser.NODE_CDATA:
			# XMLParser hands a CDATA section's CONTENT back through
			# get_node_name(); get_node_data() errors on anything but text.
			buf += p.get_node_name()
		elif t == XMLParser.NODE_ELEMENT_END:
			var name := _local(p.get_node_name())
			var parent := stack[stack.size() - 2] if stack.size() >= 2 else ""
			var txt := buf.strip_edges()
			match name:
				"name":
					if parent == "Placemark":
						cur_pm["name"] = txt
					elif parent == "Folder" and not folders.is_empty():
						folders[folders.size() - 1] = txt
					elif parent == "Document" and doc_name.is_empty():
						doc_name = txt
				"description":
					if parent == "Placemark":
						cur_pm["description"] = strip_html(buf)
				"styleUrl":
					if parent == "Placemark":
						cur_pm["style_url"] = txt
					elif parent == "Pair":
						cur_pair["url"] = txt
				"key":
					if parent == "Pair":
						cur_pair["key"] = txt
				"coordinates":
					if in_pm and not cur_geom.is_empty() and not in_inner:
						var coords := parse_coordinates(buf)
						if coords.is_empty():
							warnings.append("Placemark '%s': empty coordinates" % str(cur_pm.get("name", "")))
						else:
							(cur_pm["geoms"] as Array).append({"kind": cur_geom, "coords": coords})
				"color":
					if parent == "IconStyle":
						cur_style["icon_color"] = kml_color_to_html(txt)
					elif parent == "LineStyle":
						cur_style["line_color"] = kml_color_to_html(txt)
					elif parent == "PolyStyle":
						cur_style["poly_color"] = kml_color_to_html(txt)
				"href":
					if parent == "Icon" and stack.size() >= 3 and stack[stack.size() - 3] == "IconStyle":
						cur_style["icon_href"] = txt
				"Pair":
					if cur_map.has("pairs") and not str(cur_pair.get("key", "")).is_empty():
						(cur_map["pairs"] as Dictionary)[str(cur_pair["key"])] = str(cur_pair.get("url", ""))
				"StyleMap":
					if not str(cur_map.get("id", "")).is_empty():
						style_maps[str(cur_map["id"])] = cur_map.get("pairs", {})
					cur_map = {}
				"Style":
					if not cur_style_id.is_empty():
						styles[cur_style_id] = cur_style
					cur_style = {}
					cur_style_id = ""
				"CascadingStyle":
					cascading_id = ""
				"Point", "LineString", "Polygon":
					cur_geom = ""
				"innerBoundaryIs":
					in_inner = false
				"Folder":
					if not folders.is_empty():
						folders.pop_back()
				"Placemark":
					if in_pm:
						raw_placemarks.append(cur_pm)
					in_pm = false
					cur_pm = {}
			if not stack.is_empty():
				stack.pop_back()
			buf = ""

	if not saw_kml:
		return _fail("No <kml> root element")

	var placemarks: Array = []
	for pm in raw_placemarks:
		var geoms: Array = pm.get("geoms", [])
		if geoms.is_empty():
			warnings.append("Placemark '%s' has no geometry (skipped)" % str(pm.get("name", "")))
			continue
		for gi in geoms.size():
			var g: Dictionary = geoms[gi]
			var kind := _kind_for(str(g["kind"]))
			var coords: Array = g["coords"]
			if kind == KIND_POLYGON and coords.size() >= 2 \
					and _same_point(coords[0], coords[coords.size() - 1]):
				coords = coords.slice(0, coords.size() - 1)
			if kind == KIND_POINT and coords.size() > 1:
				coords = [coords[0]]
			if (kind != KIND_POINT and coords.size() < 2) or (kind == KIND_POLYGON and coords.size() < 3):
				warnings.append("Placemark '%s': too few points for a %s" % [str(pm.get("name", "")), kind])
				continue
			var nm := str(pm.get("name", ""))
			if gi > 0:
				nm = "%s (%d)" % [nm, gi + 1]
			placemarks.append({
				"kml_id": str(pm.get("kml_id", "")),
				"name": nm,
				"description": str(pm.get("description", "")),
				"folder": str(pm.get("folder", "")),
				"style_url": str(pm.get("style_url", "")),
				"kind": kind,
				"coords": coords,
				"color": resolve_color(styles, style_maps, str(pm.get("style_url", "")), kind),
			})
	return {"ok": true, "error": "", "name": doc_name, "placemarks": placemarks, "warnings": warnings}


## "lon,lat[,alt] lon,lat[,alt] …" → Array of [lon, lat, alt] (three floats).
## Whitespace-separated tuples, comma-separated components, alt optional.
## ⚠ Plain float Arrays, NEVER Vector3: Godot vectors are float32, and a
## longitude of −122.2468056 stored in one comes back as −122.2468 — a metre
## off on the ground, which is the whole error budget of this feature.
static func parse_coordinates(text: String) -> Array:
	var out: Array = []
	for tok in _tuples(text):
		var parts := tok.split(",", false)
		if parts.size() < 2:
			continue
		if not parts[0].strip_edges().is_valid_float() or not parts[1].strip_edges().is_valid_float():
			continue
		var lon := float(parts[0])
		var lat := float(parts[1])
		var alt := float(parts[2]) if parts.size() >= 3 and parts[2].strip_edges().is_valid_float() else 0.0
		if not is_finite(lon) or not is_finite(lat) or absf(lat) > 90.0 or absf(lon) > 180.0:
			continue
		out.append([lon, lat, alt])
	return out


static func _same_point(a: Array, b: Array) -> bool:
	return a.size() >= 2 and b.size() >= 2 \
		and absf(float(a[0]) - float(b[0])) < 1e-9 and absf(float(a[1]) - float(b[1])) < 1e-9


static func _tuples(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for raw in text.replace("\t", " ").replace("\n", " ").replace("\r", " ").split(" ", false):
		if not raw.is_empty():
			out.append(raw)
	return out


## KML "aabbggrr" → "#rrggbb" ("" when unparsable). Alpha is dropped: a pin or
## a line in the world gets the game's own opacity.
static func kml_color_to_html(abgr: String) -> String:
	var s := abgr.strip_edges().to_lower()
	if s.begins_with("#"):
		s = s.substr(1)
	if s.length() == 6:
		s = "ff" + s
	if s.length() != 8 or not s.is_valid_hex_number(false):
		return ""
	return "#" + s.substr(6, 2) + s.substr(4, 2) + s.substr(2, 2)


## The colour a Google Earth icon URL carries: "…?color=1976d2&…" → "#1976d2".
static func icon_href_color(href: String) -> String:
	var i := href.find("color=")
	if i < 0:
		return ""
	var v := href.substr(i + 6, 6).to_lower()
	if v.length() == 6 and v.is_valid_hex_number(false):
		return "#" + v
	return ""


## Follow a Placemark's styleUrl through a StyleMap's "normal" pair to a
## Style and pick the colour that applies to this geometry kind.
static func resolve_color(styles: Dictionary, style_maps: Dictionary, style_url: String, kind: String) -> String:
	var id := style_url.strip_edges()
	if id.begins_with("#"):
		id = id.substr(1)
	if id.is_empty():
		return ""
	var hops := 0
	while style_maps.has(id) and hops < 4:
		var pairs: Dictionary = style_maps[id]
		var nxt := str(pairs.get("normal", ""))
		if nxt.is_empty():
			nxt = str(pairs.values()[0]) if not pairs.is_empty() else ""
		if nxt.begins_with("#"):
			nxt = nxt.substr(1)
		if nxt.is_empty() or nxt == id:
			break
		id = nxt
		hops += 1
	if not styles.has(id):
		return ""
	var st: Dictionary = styles[id]
	if kind == KIND_POINT:
		var c := str(st.get("icon_color", ""))
		if c.is_empty():
			c = icon_href_color(str(st.get("icon_href", "")))
		return c
	var lc := str(st.get("line_color", ""))
	if lc.is_empty() and kind == KIND_POLYGON:
		lc = str(st.get("poly_color", ""))
	return lc


## Google Earth descriptions are HTML fragments. Keep the words, drop the tags.
static func strip_html(html: String) -> String:
	var s := html
	var re := RegEx.new()
	re.compile("<br\\s*/?>|</div>|</p>|</li>")
	s = re.sub(s, "\n", true)
	re.compile("<[^>]*>")
	s = re.sub(s, " ", true)
	s = s.replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<") \
		.replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'").replace("&apos;", "'")
	# NOT \v: in PCRE that is the VERTICAL-whitespace class and eats the
	# newlines the <br> pass just put in.
	re.compile("[ \\t\\r\\f]+")
	s = re.sub(s, " ", true)
	re.compile(" *\\n+ *")
	s = re.sub(s, "\n", true)
	return s.strip_edges()


static func _kind_for(elem: String) -> String:
	match elem:
		"Point":
			return KIND_POINT
		"LineString":
			return KIND_LINE
		"Polygon":
			return KIND_POLYGON
	return KIND_POINT


## "gx:CascadingStyle" → "CascadingStyle", "kml:id" stays an attribute name.
static func _local(n: String) -> String:
	var i := n.find(":")
	return n.substr(i + 1) if i >= 0 else n


static func _fail(msg: String) -> Dictionary:
	return {"ok": false, "error": msg, "name": "", "placemarks": [], "warnings": []}
