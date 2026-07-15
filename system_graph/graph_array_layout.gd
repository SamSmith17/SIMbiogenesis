class_name GraphArrayLayout
extends RefCounted

## Solar-array compound sizing: each cell uses the same graph-space dimensions as a
## standalone panel node so arrays read as panels stuck together.

const PANEL_W := 210.0
const PANEL_H := 128.0
const CELL_GAP := 1.0
const BODY_PAD := 4.0
const FOOTER_H := 22.0
const TITLE_BAND_GRAPH := 36.0


static func grid_dims(specs: Dictionary) -> Vector2i:
	var s := maxi(1, int(specs.get("array_series", 1)))
	var p := maxi(1, int(specs.get("array_parallel", 1)))
	var units := maxi(1, int(specs.get("array_panel_units", s * p)))
	if s * p < units:
		s = maxi(s, int(ceil(float(units) / float(p))))
	return Vector2i(s, p)


static func compound_size(specs: Dictionary) -> Vector2:
	var grid := grid_dims(specs)
	var cols := grid.x
	var rows := grid.y
	var body_w := BODY_PAD * 2.0 \
			+ float(cols) * PANEL_W \
			+ float(maxi(0, cols - 1)) * CELL_GAP
	var body_h := BODY_PAD * 2.0 \
			+ float(rows) * PANEL_H \
			+ float(maxi(0, rows - 1)) * CELL_GAP \
			+ FOOTER_H
	return Vector2(body_w, TITLE_BAND_GRAPH + body_h)


static func default_handles() -> Array:
	return [
		{"id": "positive", "polarity": "positive", "rx": 0.67, "ry": 1.0},
		{"id": "negative", "polarity": "negative", "rx": 0.33, "ry": 1.0},
	]


static func consolidated_handle_id(polarity: String) -> String:
	if polarity == "negative":
		return "negative"
	return "positive"
