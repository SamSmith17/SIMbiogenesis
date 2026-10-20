extends RefCounted
class_name KmlParser
## Parse minimal KML Placemark polygons (coordinates + styleUrl → zone id)

const DEFAULT_KML: String = """<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<kml xmlns=\"http://www.opengis.net/kml/2.2\">
  <Document>
    <Placemark>
      <name>Zone 6 (Sahara)</name>
      <styleUrl>#zone6Style</styleUrl>
      <Polygon>
        <outerBoundaryIs>
          <LinearRing>
            <coordinates>-5,18,0 35,18,0 35,32,0 -5,32,0 -5,18,0</coordinates>
          </LinearRing>
        </outerBoundaryIs>
      </Polygon>
    </Placemark>
  </Document>
</kml>
"""


static func parse_kml(kml_text: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if kml_text.is_empty():
		return out
	var re_block: RegEx = RegEx.new()
	re_block.compile("<Placemark>([\\s\\S]*?)</Placemark>")
	var re_name: RegEx = RegEx.new()
	re_name.compile("<name>\\s*([^<]+?)\\s*</name>")
	var re_style: RegEx = RegEx.new()
	re_style.compile("<styleUrl>\\s*([^<]+?)\\s*</styleUrl>")
	var re_coord: RegEx = RegEx.new()
	re_coord.compile("<coordinates>\\s*([\\s\\S]*?)\\s*</coordinates>")
	var re_zone: RegEx = RegEx.new()
	re_zone.compile("(?i)zone(\\d+)Style")
	var mlist: Array[RegExMatch] = re_block.search_all(kml_text)
	for m in mlist:
		if m.get_group_count() < 2:
			continue
		var block: String = m.get_string(1)
		var nm: RegExMatch = re_name.search(block)
		var st: RegExMatch = re_style.search(block)
		var co: RegExMatch = re_coord.search(block)
		if co == null or co.get_group_count() < 2:
			continue
		var coord_str: String = co.get_string(1)
		var crd: PackedVector2Array = _parse_coord_string(coord_str)
		if crd.size() < 3:
			continue
		var sname: String = nm.get_string(1).strip_edges() if nm else "Placemark"
		var style_url: String = st.get_string(1) if st else "#zone1Style"
		var zid: int = 1
		var zm: RegExMatch = re_zone.search(style_url)
		if zm and zm.get_group_count() > 1:
			zid = int(zm.get_string(1))
		out.append({
			"name": sname,
			"styleUrl": style_url,
			"zone_id": zid,
			"coordinates": crd,
		})
	return out


static func _parse_coord_string(s: String) -> PackedVector2Array:
	var r := PackedVector2Array()
	for token in s.strip_edges().split(" ", false):
		var parts: PackedStringArray = token.split(",", false)
		if parts.size() < 2:
			continue
		r.append(Vector2(float(parts[0]), float(parts[1])))
	return r
