extends SceneTree

## Offline checks for circular hub ports (Phase 3).

const GraphModelScript := preload("res://system_graph/data/graph_model.gd")


func _initialize() -> void:
	var fails := 0
	fails += _test_angle_from_rx_ry()
	fails += _test_migrate_handle()
	fails += _test_acquire_hub_port()
	fails += _test_set_handle_angle()
	fails += _test_deserialize_migrates_angles()
	fails += _test_screen_pos_on_circle()
	fails += _test_port_service_resolved_handles()
	fails += _test_array_layout_size()
	if fails == 0:
		print("GRAPH HUB PORT SELFTEST PASS  (8 checks)")
	else:
		print("GRAPH HUB PORT SELFTEST FAIL  (%d failed)" % fails)
	quit(1 if fails > 0 else 0)


func _test_angle_from_rx_ry() -> int:
	var left := GraphHubPorts.angle_from_rx_ry(0.0, 0.5)
	var right := GraphHubPorts.angle_from_rx_ry(1.0, 0.5)
	if absf(left - PI) > 0.01:
		push_error("left port angle expected PI got %f" % left)
		return 1
	if absf(right) > 0.01 and absf(right - TAU) > 0.01:
		push_error("right port angle expected 0 got %f" % right)
		return 1
	return 0


func _test_migrate_handle() -> int:
	var h := {"id": "input", "polarity": "resource", "rx": 0.0, "ry": 0.5}
	GraphHubPorts.migrate_handle(h)
	if not h.has("angle_rad"):
		push_error("migrate should set angle_rad")
		return 1
	if absf(float(h.get("angle_rad", 0.0)) - PI) > 0.01:
		push_error("migrated left port angle wrong")
		return 1
	if str(h.get("role", "")) != GraphHubPorts.ROLE_IN:
		push_error("input should get role in")
		return 1
	return 0


func _test_acquire_hub_port() -> int:
	var item := {
		"id": "tank1",
		"type": "resource",
		"width": 136.0,
		"height": 136.0,
		"specs": {"resource_kind": "water", "level": 0.5},
	}
	var wired := {}
	var p1 := GraphHubPorts.acquire_hub_port(item, "water", PI * 0.25, GraphHubPorts.ROLE_IN, wired)
	if str(p1.get("id", "")) != "input":
		push_error("first in-port should reuse default input, got %s" % str(p1.get("id", "")))
		return 1
	wired["input"] = true
	var p2 := GraphHubPorts.acquire_hub_port(item, "water", PI * 0.75, GraphHubPorts.ROLE_IN, wired)
	if not str(p2.get("id", "")).begins_with("hub_in_"):
		push_error("second in-port should be hub_in_*, got %s" % str(p2.get("id", "")))
		return 1
	var handles: Array = item.get("handles", []) as Array
	if handles.size() < 3:
		push_error("expected default in/out + new hub port, got %d" % handles.size())
		return 1
	return 0


func _test_set_handle_angle() -> int:
	var item := {
		"id": "tank2",
		"type": "resource",
		"handles": GraphHubPorts.default_resource_handles("water"),
	}
	var ok := GraphHubPorts.set_handle_angle(item, "output", PI * 0.5)
	if not ok:
		push_error("set_handle_angle failed")
		return 1
	var h := (item.get("handles", []) as Array)[1] as Dictionary
	if absf(float(h.get("angle_rad", 0.0)) - PI * 0.5) > 0.01:
		push_error("angle not updated")
		return 1
	return 0


func _test_deserialize_migrates_angles() -> int:
	var model: GraphModel = GraphModelScript.new()
	model.deserialize({
		"version": 5,
		"items": [{
			"id": "r1",
			"type": "resource",
			"x": 0.0, "y": 0.0,
			"width": 136.0, "height": 136.0,
			"scope_id": "root",
			"specs": {"resource_kind": "water", "level": 0.5, "capacity_qty": 100.0},
			"handles": [
				{"id": "input", "polarity": "resource", "rx": 0.0, "ry": 0.5},
				{"id": "output", "polarity": "resource", "rx": 1.0, "ry": 0.5},
			],
		}],
		"connections": [],
		"scopes": {"root": {"id": "root", "parent_scope_id": "", "owner_compound_id": "", "title": "Root"}},
	})
	var item := model.get_item("r1")
	var handles: Array = item.get("handles", []) as Array
	if handles.is_empty():
		push_error("handles missing after deserialize")
		return 1
	var hin: Dictionary = handles[0] as Dictionary
	if not hin.has("angle_rad"):
		push_error("deserialize should migrate angle_rad onto handles")
		return 1
	return 0


func _test_screen_pos_on_circle() -> int:
	var tl := Vector2(100.0, 100.0)
	var sz := Vector2(100.0, 100.0)
	var right := GraphHubPorts.screen_pos_on_circle(tl, sz, 0.0)
	var expected := Vector2(200.0, 150.0)
	if right.distance_to(expected) > 0.5:
		push_error("right perimeter pos expected %s got %s" % [str(expected), str(right)])
		return 1
	if not GraphHubPorts.point_in_hub_body(tl, sz, Vector2(150.0, 150.0)):
		push_error("center should be inside hub body")
		return 1
	if GraphHubPorts.point_in_hub_body(tl, sz, Vector2(10.0, 10.0)):
		push_error("far point should be outside hub body")
		return 1
	return 0


func _test_port_service_resolved_handles() -> int:
	var item := {
		"id": "r1",
		"type": "resource",
		"specs": {"resource_kind": "water"},
	}
	var handles := GraphPortService.resolved_handles(item, {})
	if handles.size() < 2:
		push_error("resource should resolve default in/out handles")
		return 1
	GraphHubPorts.migrate_handles_array(handles)
	if not (handles[0] as Dictionary).has("angle_rad"):
		push_error("resolved resource handles should carry angle_rad after migrate")
		return 1
	var msg := GraphPortService.format_soc_protection({"soc_shutdown_pct": 10.0, "soc_resume_pct": 20.0})
	if not msg.contains("10") or not msg.contains("20"):
		push_error("SOC protect format wrong: %s" % msg)
		return 1
	return 0


func _test_array_layout_size() -> int:
	var specs := {
		"array_series": 2,
		"array_parallel": 2,
		"array_panel_units": 4,
	}
	var sz := GraphArrayLayout.compound_size(specs)
	var want_w := GraphArrayLayout.BODY_PAD * 2.0 + 2.0 * GraphArrayLayout.PANEL_W + GraphArrayLayout.CELL_GAP
	var want_body_h := GraphArrayLayout.BODY_PAD * 2.0 + 2.0 * GraphArrayLayout.PANEL_H + GraphArrayLayout.CELL_GAP + GraphArrayLayout.FOOTER_H
	if absf(sz.x - want_w) > 1.0:
		push_error("array width expected %.0f got %.0f" % [want_w, sz.x])
		return 1
	if absf(sz.y - (GraphArrayLayout.TITLE_BAND_GRAPH + want_body_h)) > 1.0:
		push_error("array height wrong for 2x2 grid")
		return 1
	var handles := GraphArrayLayout.default_handles()
	if handles.size() != 2:
		push_error("array should expose exactly two handles")
		return 1
	return 0
