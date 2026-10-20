extends Control
class_name ZonePopulationChart
## Vertical bar chart: % world population by zone (port of ZonePopulationDistribution.tsx)

var _by_zone: Dictionary = {}
var _world: int = 0
var _active_id: int = 1
var _year: int = 0
var G: GhiService

func _ready() -> void:
	G = get_node_or_null("/root/GhiService") as GhiService
	custom_minimum_size = Vector2(200, 220)
func set_data(by_zone: Dictionary, world_total: int, active_zone_id: int, year: int) -> void:
	_by_zone = by_zone
	_world = world_total
	_active_id = active_zone_id
	_year = year
	queue_redraw()

func _draw() -> void:
	if G == null:
		G = get_node_or_null("/root/GhiService") as GhiService
	if G == null or _world <= 0:
		return
	var zones: Array[Dictionary] = G.get_zones() as Array[Dictionary]
	var pcts: Array[float] = []
	var max_pct: float = 0.5
	for z in zones:
		var p: float = 100.0 * float(int(_by_zone.get(str(int(z["id"])), 0))) / float(_world)
		pcts.append(p)
		max_pct = maxf(max_pct, p)
	var y_max: float = maxf(15.0, ceili((max_pct * 1.12) / 5.0) * 5.0)
	var w: float = size.x
	var h: float = size.y - 28.0
	var n: int = zones.size()
	if n == 0 or w < 4:
		return
	# y-axis
	var axis_w: float = 40.0
	var chart_l: float = axis_w
	var bar_w: float = (w - axis_w - 4.0) / float(n)
	# mean zone index
	var sum_zx: float = 0.0
	for z2 in zones:
		sum_zx += float(int(z2["id"])) * float(int(_by_zone.get(str(int(z2["id"])), 0)))
	var mean_zi: float = sum_zx / float(_world)
	var mean_x: float = ((mean_zi - 1.0) / 5.0) * 100.0
	# grid
	var ticks: int = 5
	var div: int = maxi(1, ticks - 1)
	for ti in range(ticks):
		var tval: float = y_max * (1.0 - float(ti) / float(div))
		var yl: float = 8.0 + h * float(ti) / float(div)
		_dash_line(Vector2(chart_l, yl), Vector2(w, yl), Color(0.3, 0.35, 0.4, 0.35), 1.0, 4.0)
		var ts: String = str(roundi(tval)) + "%"
		draw_string(ThemeDB.fallback_font, Vector2(0, yl + 2), ts, HORIZONTAL_ALIGNMENT_RIGHT, int(axis_w - 4), 10, Color(0.85, 0.9, 0.95))
	# mu line
	var mx: float = chart_l + (mean_x / 100.0) * (w - chart_l) if _world > 0 else 0.0
	_dash_line(Vector2(mx, 8.0), Vector2(mx, 8.0 + h), Color(0.95, 0.6, 0.2, 0.5), 1.0, 3.0)
	# bars
	for i in range(n):
		var zi: int = int(zones[i]["id"])
		var pct: float = pcts[i] if i < pcts.size() else 0.0
		var col: Color = zones[i]["color"] as Color
		var bx: float = chart_l + i * bar_w
		var bh: float = (pct / y_max) * h if y_max > 0 else 0.0
		bh = mini(bh, h)
		var active: bool = (zi == _active_id)
		if pct > 0.0 and bh < 2.0:
			bh = 2.0
		if active:
			draw_rect(Rect2(bx + 1, 8.0 + h - bh, bar_w - 2, bh), col, true)
		else:
			draw_rect(Rect2(bx + 1, 8.0 + h - bh, bar_w - 2, bh), Color(col.r, col.g, col.b, 0.8), true)
	# X labels
	for i2 in range(n):
		var zi2: int = int(zones[i2]["id"])
		var lab: String = "Zone " + str(zi2)
		var bx2: float = chart_l + i2 * bar_w + bar_w * 0.5
		var col2: Color = Color(0.95, 0.7, 0.25) if zi2 == _active_id else Color(0.4, 0.45, 0.5)
		draw_string(ThemeDB.fallback_font, Vector2(bx2 - 10, 8.0 + h + 12), lab, HORIZONTAL_ALIGNMENT_CENTER, 24, 9, col2)
	draw_string(ThemeDB.fallback_font, Vector2(0, size.y - 4), "μ ≈ %.2f" % [mean_zi] + " — " + str(_year), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.45, 0.5, 0.55))

func _dash_line(from: Vector2, to: Vector2, c: Color, w: float, dlen: float) -> void:
	var seg: Vector2 = to - from
	var dist: float = seg.length()
	if dist < 0.001:
		return
	var dir: Vector2 = seg / dist
	var t: float = 0.0
	var cur: int = 0
	while t < dist:
		var t2: float = minf(t + dlen, dist)
		if cur % 2 == 0:
			draw_line(from + dir * t, from + dir * t2, c, w, true)
		t = t2 + 2.0
		cur += 1
