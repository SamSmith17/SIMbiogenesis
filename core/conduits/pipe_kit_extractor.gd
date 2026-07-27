extends SceneTree

## Bake US Sch40 fittings GLB → per-size kits + fittings inventory.
## Active v1 parts: Pipe + Elbow 45 + Elbow 90 (Long preferred).
## Tees/wyes/reducers are inventoried only for a later pass.
## Run (after --import):
##   Godot.exe.exe --headless --path . --script core/conduits/pipe_kit_extractor.gd

const SRC_GLB := "res://Imported Models/PipeFittings/us_sch40_fittings.glb"
const OUT_DIR := "res://core/conduits/data/"
const FAMILY := "us_sch40"
const INVENTORY_PATH := OUT_DIR + "fittings_inventory_us_sch40.json"
const REVISION := 2  ## v2: bend-aware socket pair pick (fixes 45° outer/inner rim)

const SCH40_SIZES_IN := [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0]


func _initialize() -> void:
	if not ResourceLoader.exists(SRC_GLB):
		push_error("PipeKitExtractor: missing %s — run --import first" % SRC_GLB)
		quit(1)
		return
	var packed := load(SRC_GLB) as PackedScene
	if packed == null:
		push_error("PipeKitExtractor: failed to load PackedScene")
		quit(1)
		return
	var root := packed.instantiate() as Node3D
	if root == null:
		push_error("PipeKitExtractor: root not Node3D")
		quit(1)
		return
	root.name = "KitRoot"
	var host := Node3D.new()
	get_root().add_child(host)
	host.add_child(root)

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var catalog := _build_catalog(root)
	var inventory := {
		"source_glb": SRC_GLB,
		"revision": REVISION,
		"family": FAMILY,
		"sizes_in": SCH40_SIZES_IN.duplicate(),
		"active_roles": ["pipe", "elbow_45", "elbow_90"],
		"catalog": catalog,
	}
	var inv_f := FileAccess.open(INVENTORY_PATH, FileAccess.WRITE)
	if inv_f == null:
		push_error("PipeKitExtractor: cannot write %s" % INVENTORY_PATH)
		quit(1)
		return
	inv_f.store_string(JSON.stringify(inventory, "\t"))
	inv_f.close()
	print("PipeKitExtractor: wrote %s" % INVENTORY_PATH)

	var baked := 0
	var failed := 0
	for size_in: float in SCH40_SIZES_IN:
		var token := _size_token(size_in)
		var kit_id := "%s_%s" % [FAMILY, token]
		var pipe_e: Dictionary = (catalog.get("pipe", {}) as Dictionary).get(str(size_in), {}) as Dictionary
		var e45_e: Dictionary = (catalog.get("elbow_45", {}) as Dictionary).get(str(size_in), {}) as Dictionary
		var e90_e: Dictionary = (catalog.get("elbow_90", {}) as Dictionary).get(str(size_in), {}) as Dictionary
		if pipe_e.is_empty() or e45_e.is_empty() or e90_e.is_empty():
			push_error("PipeKitExtractor: incomplete size %.2f (pipe/45/90)" % size_in)
			failed += 1
			continue
		var specs: Array = [
			{"node": str(pipe_e.get("node_name", "")), "bend": 0.0, "key": "0"},
			{"node": str(e45_e.get("node_name", "")), "bend": 45.0, "key": "45"},
			{"node": str(e90_e.get("node_name", "")), "bend": 90.0, "key": "90"},
		]
		var parts_out: Dictionary = {}
		var od_m := 0.0
		var ok := true
		for spec: Dictionary in specs:
			var node_name := str(spec["node"])
			var part_root := _find_named(root, node_name) as Node3D
			if part_root == null:
				push_error("PipeKitExtractor: missing node '%s'" % node_name)
				ok = false
				break
			var mesh_info := _gather_part_mesh(part_root, ["Geom3D_"])
			if mesh_info.is_empty():
				push_error("PipeKitExtractor: no mesh for '%s'" % node_name)
				ok = false
				break
			var unit_scale := _ancestry_scale(part_root)
			var verts: PackedVector3Array = mesh_info["verts"]
			for vi: int in range(verts.size()):
				verts[vi] = verts[vi] * unit_scale
			var indices: PackedInt32Array = mesh_info["indices"]
			var bend := float(spec["bend"])
			var sockets := _detect_sockets(verts, indices)
			if sockets.size() < 2:
				push_error("PipeKitExtractor: <2 sockets on '%s' (got %d)" % [node_name, sockets.size()])
				ok = false
				break
			# Prefer the socket pair whose flow turn matches bend_deg. Farthest-pair
			# alone often picks outer+inner rim of ONE collar on 45° elbows.
			var pair := _pick_socket_pair(sockets, bend)
			var canon := _canonicalize(verts, indices, pair[0], pair[1], bend)
			if not _canon_bend_ok(canon, bend):
				# Try swapped A/B — rim winding / loop order can flip which is inlet.
				var canon2 := _canonicalize(verts, indices, pair[1], pair[0], bend)
				if _canon_bend_ok(canon2, bend) \
						or _canon_bend_error(canon2, bend) < _canon_bend_error(canon, bend):
					canon = canon2
			if not _canon_bend_ok(canon, bend):
				push_warning("PipeKitExtractor: bend angle mismatch on '%s' (want %.0f°, got %.1f°)" % [
					node_name, bend, _canon_flow_turn_deg(canon)])
			var mesh_res_path := OUT_DIR + "pipe_kit_%s_part_%s.res" % [kit_id, str(spec["key"])]
			var save_err := ResourceSaver.save(canon["mesh"], mesh_res_path)
			if save_err != OK:
				push_error("PipeKitExtractor: save mesh failed %s (%d)" % [mesh_res_path, save_err])
				ok = false
				break
			var sa: Dictionary = canon["socket_a"]
			var sb: Dictionary = canon["socket_b"]
			var length_m := float(canon["centerline_length_m"])
			var takeout := float(canon["takeout_m"])
			var radius_cl := float(canon["centerline_radius_m"])
			var part_od := float(canon["od_m"])
			if bend < 0.5:
				od_m = part_od
			parts_out[str(spec["key"])] = {
				"bend_deg": bend,
				"mesh_res": mesh_res_path,
				"node_name": node_name,
				"centerline_length_m": length_m,
				"takeout_m": takeout,
				"centerline_radius_m": radius_cl,
				"od_m": part_od,
				"socket_a": sa,
				"socket_b": sb,
			}
			print("PipeKitExtractor: baked %s [%s] bend=%.0f L=%.4f takeout=%.4f od=%.4f" % [
				kit_id, node_name, bend, length_m, takeout, part_od])
		if not ok:
			failed += 1
			continue
		var kit := {
			"kit_id": kit_id,
			"family": FAMILY,
			"size_in": size_in,
			"revision": REVISION,
			"source_glb": SRC_GLB,
			"nominal_od_m": od_m if od_m > 0.01 else 0.07,
			"parts": parts_out,
		}
		var json_path := OUT_DIR + "pipe_kit_%s.json" % kit_id
		var jf := FileAccess.open(json_path, FileAccess.WRITE)
		if jf == null:
			push_error("PipeKitExtractor: cannot write %s" % json_path)
			failed += 1
			continue
		jf.store_string(JSON.stringify(kit, "\t"))
		jf.close()
		print("PipeKitExtractor: wrote %s" % json_path)
		baked += 1

	# Legacy alias: abs_dwv → 2.5″ kit (compat for old PipeKit.KITS / saves).
	var alias_src := OUT_DIR + "pipe_kit_%s_%s.json" % [FAMILY, _size_token(2.5)]
	if FileAccess.file_exists(alias_src):
		var af := FileAccess.open(alias_src, FileAccess.READ)
		if af != null:
			var alias_text := af.get_as_text()
			af.close()
			var alias_parsed: Variant = JSON.parse_string(alias_text)
			if alias_parsed is Dictionary:
				var ad: Dictionary = (alias_parsed as Dictionary).duplicate(true)
				ad["kit_id"] = "abs_dwv"
				ad["alias_of"] = "%s_%s" % [FAMILY, _size_token(2.5)]
				# Remap mesh paths to shared 2.5″ part files (same meshes).
				var parts_a: Dictionary = ad.get("parts", {}) as Dictionary
				for pk: Variant in parts_a.keys():
					var pd: Dictionary = (parts_a[pk] as Dictionary).duplicate(true)
					pd["mesh_res"] = OUT_DIR + "pipe_kit_%s_%s_part_%s.res" % [
						FAMILY, _size_token(2.5), str(pk)]
					parts_a[str(pk)] = pd
				ad["parts"] = parts_a
				var out_a := FileAccess.open(OUT_DIR + "pipe_kit_abs_dwv.json", FileAccess.WRITE)
				if out_a != null:
					out_a.store_string(JSON.stringify(ad, "\t"))
					out_a.close()
					print("PipeKitExtractor: wrote legacy alias pipe_kit_abs_dwv.json → 2.5in")

	host.queue_free()
	if baked < SCH40_SIZES_IN.size():
		push_error("PipeKitExtractor: baked %d/%d sizes (%d failed)" % [
			baked, SCH40_SIZES_IN.size(), failed])
		quit(1)
		return
	print("PipeKitExtractor: DONE — %d size kits" % baked)
	quit(0)


func _size_token(size_in: float) -> String:
	var nearest := _nearest_size(size_in)
	var whole := int(floor(nearest + 1e-6))
	var frac := nearest - float(whole)
	if frac < 0.01:
		return str(whole)
	if absf(frac - 0.5) < 0.01:
		return "%d_5" % whole if whole > 0 else "0_5"
	if absf(frac - 0.25) < 0.01:
		return "%d_25" % whole if whole > 0 else "0_25"
	if absf(frac - 0.75) < 0.01:
		return "%d_75" % whole if whole > 0 else "0_75"
	return str(nearest).replace(".", "_")


func _nearest_size(size_in: float) -> float:
	var best := SCH40_SIZES_IN[0]
	var best_d := INF
	for s: float in SCH40_SIZES_IN:
		var d := absf(s - size_in)
		if d < best_d:
			best_d = d
			best = s
	return best


## Walk GLB nodes → catalog roles → size_in string keys.
func _build_catalog(root: Node3D) -> Dictionary:
	var names: Array = []
	_collect_names(root, names)
	var catalog := {
		"pipe": {},
		"elbow_45": {},
		"elbow_90": {},
		"tee_90": {},
		"tee_ty_90": {},
		"wye_45": {},
		"reducing_tee": {},
		"reducing_socket": {},
		"socket": {},
		"p_trap": {},
		"u_trap": {},
	}
	for n: String in names:
		var role := ""
		var rest := ""
		if n.begins_with("Pipe "):
			role = "pipe"
			rest = n.substr(5)
		elif n.begins_with("Elbows 45 "):
			role = "elbow_45"
			rest = n.substr(10)
		elif n.begins_with("Elbows 90 "):
			role = "elbow_90"
			rest = n.substr(10)
		elif n.begins_with("Tee-90 "):
			role = "tee_90"
			rest = n.substr(7)
		elif n.begins_with("Tee-TY 90 "):
			role = "tee_ty_90"
			rest = n.substr(10)
		elif n.begins_with("Tee-Y 45 "):
			role = "wye_45"
			rest = n.substr(9)
		elif n.begins_with("REDUCING TEE "):
			role = "reducing_tee"
			rest = n.substr(13)
		elif n.begins_with("REDUCING SOCKET "):
			role = "reducing_socket"
			rest = n.substr(16)
		elif n.begins_with("Socket "):
			role = "socket"
			rest = n.substr(7)
		elif n.begins_with("P-TRAP "):
			role = "p_trap"
			rest = n.substr(7)
		elif n.begins_with("U-TRAP "):
			role = "u_trap"
			rest = n.substr(7)
		else:
			continue
		var parsed := _parse_size_and_variant(rest)
		var size_in := float(parsed.get("size_in", -1.0))
		if size_in < 0.0:
			continue
		var key := str(_nearest_size(size_in))
		var entry := {
			"node_name": n,
			"variant": str(parsed.get("variant", "")),
			"size_in": float(key),
		}
		var bucket: Dictionary = catalog[role] as Dictionary
		if not bucket.has(key):
			bucket[key] = entry
		else:
			bucket[key] = _prefer_entry(role, bucket[key] as Dictionary, entry)
		catalog[role] = bucket
	return catalog


func _prefer_entry(role: String, cur: Dictionary, nxt: Dictionary) -> Dictionary:
	var cv := str(cur.get("variant", ""))
	var nv := str(nxt.get("variant", ""))
	if role == "elbow_90":
		# Prefer Long over Short/thick.
		if nv == "long" and cv != "long":
			return nxt
		if cv == "long":
			return cur
		if nv == "short" and cv == "thick":
			return nxt
		return cur
	if role == "elbow_45":
		# Prefer non-thick when both exist.
		if cv == "thick" and nv != "thick":
			return nxt
		return cur
	return cur


func _parse_size_and_variant(rest: String) -> Dictionary:
	var s := rest.strip_edges()
	s = s.replace(" inch", "").replace("  ", " ").strip_edges()
	var variant := ""
	if s.ends_with(" Long"):
		variant = "long"
		s = s.substr(0, s.length() - 5).strip_edges()
	elif s.ends_with(" Short"):
		variant = "short"
		s = s.substr(0, s.length() - 6).strip_edges()
	elif s.ends_with(" thick"):
		variant = "thick"
		s = s.substr(0, s.length() - 6).strip_edges()
	# Drop trailing empty tokens / dashes from messy CAD names.
	s = s.strip_edges()
	while s.ends_with("-") or s.ends_with(" "):
		s = s.substr(0, s.length() - 1).strip_edges()
	# Reducing fittings: "6 x 4" / "2 - 1 1-2" — catalog by the first (usually larger) NPS.
	var x_idx := s.find(" x ")
	if x_idx >= 0:
		s = s.substr(0, x_idx).strip_edges()
	var dash_idx := s.find(" - ")
	if dash_idx >= 0:
		s = s.substr(0, dash_idx).strip_edges()
	# "1 1-4 3-4" (no separator) → keep first whole+frac pair only.
	var toks := s.split(" ", false)
	if toks.size() >= 3 and _parse_frac(toks[1]) >= 0.0:
		s = "%s %s" % [toks[0], toks[1]]
	elif toks.size() >= 2 and _parse_frac(toks[0]) >= 0.0 and _parse_frac(toks[1]) >= 0.0:
		s = toks[0]
	var size_in := _parse_nps_token(s)
	return {"size_in": size_in, "variant": variant}


func _parse_nps_token(s: String) -> float:
	s = s.strip_edges()
	# "1 1-2" → 1.5, "2 1-2" → 2.5, "1-2" → 0.5, "3-4" → 0.75, "4" → 4
	var parts := s.split(" ", false)
	if parts.size() >= 2:
		var whole := parts[0].to_float()
		var frac := _parse_frac(parts[1])
		if frac >= 0.0:
			return whole + frac
	var frac_only := _parse_frac(s)
	if frac_only >= 0.0:
		return frac_only
	if s.is_valid_float():
		return s.to_float()
	return -1.0


func _parse_frac(s: String) -> float:
	s = s.strip_edges()
	if not s.contains("-"):
		return -1.0
	var ab := s.split("-", false, 1)
	if ab.size() != 2:
		return -1.0
	var a := ab[0].to_float()
	var b := ab[1].to_float()
	if b < 1e-6:
		return -1.0
	return a / b


func _collect_names(n: Node, out: Array) -> void:
	var nm := str(n.name)
	if not nm.is_empty() and not out.has(nm):
		out.append(nm)
	for c in n.get_children():
		_collect_names(c, out)


## Product of ancestor Node3D scales (inch kits nest under scale 0.0254).
func _ancestry_scale(n: Node3D) -> float:
	var s := 1.0
	var cur: Node = n.get_parent()
	while cur != null:
		if cur is Node3D:
			var sc: Vector3 = (cur as Node3D).scale
			s *= (absf(sc.x) + absf(sc.y) + absf(sc.z)) / 3.0
		cur = cur.get_parent()
	if s < 0.1:
		s = 0.0254
	return s


func _find_named(n: Node, want: String) -> Node:
	if n.name == want:
		return n
	for c in n.get_children():
		var hit := _find_named(c, want)
		if hit != null:
			return hit
	return null


func _gather_part_mesh(part_root: Node3D, skip_names: Array) -> Dictionary:
	var verts := PackedVector3Array()
	var indices := PackedInt32Array()
	_collect_meshes(part_root, part_root, Transform3D.IDENTITY, skip_names, verts, indices)
	if verts.is_empty():
		return {}
	return {"verts": verts, "indices": indices}


func _collect_meshes(n: Node, part_root: Node3D, local_from_part: Transform3D,
		skip_names: Array, verts: PackedVector3Array, indices: PackedInt32Array) -> void:
	var next_xf := local_from_part
	if n != part_root and n is Node3D:
		next_xf = local_from_part * (n as Node3D).transform
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var skip := false
		for sn: Variant in skip_names:
			if str(mi.name) == str(sn) or str(mi.name).begins_with(str(sn)):
				skip = true
				break
		if not skip and mi.mesh != null:
			var aabb := mi.mesh.get_aabb()
			var vol := aabb.size.x * aabb.size.y * aabb.size.z
			var max_dim := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
			if max_dim > 1e-4 and vol / max_dim < 0.02:
				skip = true
		if not skip and mi.mesh != null:
			_append_mesh(mi.mesh, next_xf, verts, indices)
	for c in n.get_children():
		_collect_meshes(c, part_root, next_xf, skip_names, verts, indices)


func _append_mesh(mesh: Mesh, xform: Transform3D,
		verts: PackedVector3Array, indices: PackedInt32Array) -> void:
	for s: int in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(s)
		var sv: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var si: Variant = arrays[Mesh.ARRAY_INDEX]
		var base := verts.size()
		for v: Vector3 in sv:
			verts.append(xform * v)
		if si is PackedInt32Array and (si as PackedInt32Array).size() >= 3:
			for idx: int in si as PackedInt32Array:
				indices.append(base + idx)
		else:
			for i: int in range(sv.size()):
				indices.append(base + i)


func _detect_sockets(verts: PackedVector3Array, indices: PackedInt32Array) -> Array:
	var edge_count: Dictionary = {}
	var i := 0
	while i + 2 < indices.size():
		var a := indices[i]
		var b := indices[i + 1]
		var c := indices[i + 2]
		_bump_edge(edge_count, a, b)
		_bump_edge(edge_count, b, c)
		_bump_edge(edge_count, c, a)
		i += 3
	var boundary: Array = []
	for k: Variant in edge_count.keys():
		if int(edge_count[k]) == 1:
			var parts: PackedStringArray = str(k).split(":")
			boundary.append([int(parts[0]), int(parts[1])])
	if boundary.is_empty():
		return _sockets_from_aabb(verts)
	var adj: Dictionary = {}
	for e: Array in boundary:
		var u: int = e[0]
		var v: int = e[1]
		if not adj.has(u):
			adj[u] = []
		if not adj.has(v):
			adj[v] = []
		(adj[u] as Array).append(v)
		(adj[v] as Array).append(u)
	var loops: Array = []
	var seen: Dictionary = {}
	for start: int in adj.keys():
		if seen.has(start):
			continue
		var loop: Array = []
		var cur := start
		var prev := -1
		while not seen.has(cur):
			seen[cur] = true
			loop.append(cur)
			var nexts: Array = adj[cur] as Array
			var nxt := -1
			for cand: int in nexts:
				if cand != prev:
					nxt = cand
					if not seen.has(cand):
						break
			if nxt < 0:
				break
			prev = cur
			cur = nxt
			if cur == start:
				break
		if loop.size() >= 8:
			loops.append(loop)
	if loops.size() < 2:
		return _sockets_from_aabb(verts)
	loops.sort_custom(func(a, b): return (a as Array).size() > (b as Array).size())
	var sockets: Array = []
	var mesh_c := _centroid(verts)
	# Keep enough rim candidates — 45° collars often expose 4–6 boundary loops
	# (outer/inner per mouth). Pair selection happens in _pick_socket_pair.
	for li: int in range(mini(loops.size(), 8)):
		var loop: Array = loops[li]
		var c := Vector3.ZERO
		for vi: int in loop:
			c += verts[vi]
		c /= float(loop.size())
		var nrm := Vector3.ZERO
		for j: int in range(loop.size()):
			var p0: Vector3 = verts[loop[j]]
			var p1: Vector3 = verts[loop[(j + 1) % loop.size()]]
			nrm += (p0 - c).cross(p1 - c)
		if nrm.length_squared() < 1e-12:
			continue
		nrm = nrm.normalized()
		if nrm.dot(c - mesh_c) < 0.0:
			nrm = -nrm
		# Approx rim radius — used to reject outer/inner of the same mouth.
		var rad := 0.0
		for vi: int in loop:
			rad += verts[vi].distance_to(c)
		rad /= float(loop.size())
		sockets.append({"origin": c, "outward": nrm, "radius": rad})
	if sockets.size() < 2:
		return _sockets_from_aabb(verts)
	return sockets


## Pick two socket mouths for a known bend. Scores by flow-turn vs bend_deg so we
## don't pair outer+inner rim of one collar (common failure on 45° fittings).
func _pick_socket_pair(sockets: Array, bend_deg: float) -> Array:
	if sockets.size() < 2:
		return sockets
	var best_i := 0
	var best_j := 1
	var best_score := -INF
	# Flow-turn target: enter −na → leave +nb. Straight ≈ 0°, elbows ≈ bend_deg.
	var target := bend_deg if bend_deg > 0.5 else 0.0
	for a: int in range(sockets.size()):
		for b: int in range(a + 1, sockets.size()):
			var sa: Dictionary = sockets[a]
			var sb: Dictionary = sockets[b]
			var oa: Vector3 = sa["origin"]
			var ob: Vector3 = sb["origin"]
			var na: Vector3 = (sa["outward"] as Vector3).normalized()
			var nb: Vector3 = (sb["outward"] as Vector3).normalized()
			var sep := oa.distance_to(ob)
			if sep < 1e-4:
				continue
			var along := (ob - oa).normalized()
			var n_dot := na.dot(nb)
			# Same-mouth outer/inner: nearly parallel normals stacked along the axis.
			var same_mouth := n_dot > 0.85 and absf(along.dot(na)) > 0.85
			# Flow turn: enter along −na, leave along +nb (or swapped).
			var turn := rad_to_deg((-na).angle_to(nb))
			var turn_alt := rad_to_deg((-nb).angle_to(na))
			var err := minf(absf(turn - target), absf(turn_alt - target))
			var ra := float(sa.get("radius", 0.0))
			var rb := float(sb.get("radius", 0.0))
			var rad_pen := 0.0
			if ra > 1e-4 and rb > 1e-4:
				rad_pen = absf(ra - rb) / maxf(ra, rb)
			var score := -err * 12.0 + sep * 3.0 - rad_pen * 4.0
			if same_mouth:
				score -= 80.0
			if bend_deg < 0.5:
				# Straight: reward opposing socket outbounds (n_dot ≈ -1).
				score += (1.0 + n_dot) * -10.0
			if score > best_score:
				best_score = score
				best_i = a
				best_j = b
	# Orient so A→B flow turn is the closer match (caller may still swap).
	var sa0: Dictionary = sockets[best_i]
	var sb0: Dictionary = sockets[best_j]
	var na0: Vector3 = (sa0["outward"] as Vector3).normalized()
	var nb0: Vector3 = (sb0["outward"] as Vector3).normalized()
	var t0 := rad_to_deg((-na0).angle_to(nb0))
	var t1 := rad_to_deg((-nb0).angle_to(na0))
	if absf(t1 - target) < absf(t0 - target):
		return [sb0, sa0]
	return [sa0, sb0]


func _canon_flow_turn_deg(canon: Dictionary) -> float:
	var sb: Dictionary = canon.get("socket_b", {}) as Dictionary
	var nb := _arr_to_v3(sb.get("outward", [0, 0, 1]))
	# Canonical: enter along +Z, leave along socket_b outward.
	# Straight pipe → ~0°; elbows → ~bend_deg.
	return rad_to_deg(Vector3(0, 0, 1).angle_to(nb))


func _canon_bend_error(canon: Dictionary, bend_deg: float) -> float:
	var target := bend_deg if bend_deg > 0.5 else 0.0
	return absf(_canon_flow_turn_deg(canon) - target)


func _canon_bend_ok(canon: Dictionary, bend_deg: float) -> bool:
	var tol := 12.0 if bend_deg > 0.5 else 25.0
	return _canon_bend_error(canon, bend_deg) <= tol


func _arr_to_v3(v: Variant) -> Vector3:
	if v is Vector3:
		return (v as Vector3).normalized()
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		var out := Vector3(float(a[0]), float(a[1]), float(a[2]))
		if out.length_squared() < 1e-12:
			return Vector3(0, 0, 1)
		return out.normalized()
	return Vector3(0, 0, 1)


func _bump_edge(edge_count: Dictionary, a: int, b: int) -> void:
	var lo := mini(a, b)
	var hi := maxi(a, b)
	var k := "%d:%d" % [lo, hi]
	edge_count[k] = int(edge_count.get(k, 0)) + 1


func _centroid(verts: PackedVector3Array) -> Vector3:
	var c := Vector3.ZERO
	for v: Vector3 in verts:
		c += v
	return c / float(maxi(verts.size(), 1))


func _sockets_from_aabb(verts: PackedVector3Array) -> Array:
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for v: Vector3 in verts:
		mn = mn.min(v)
		mx = mx.max(v)
	var size := mx - mn
	var axis := 0
	if size.y >= size.x and size.y >= size.z:
		axis = 1
	elif size.z >= size.x and size.z >= size.y:
		axis = 2
	var c := (mn + mx) * 0.5
	var a_o := c
	var b_o := c
	var a_n := Vector3.ZERO
	var b_n := Vector3.ZERO
	match axis:
		0:
			a_o = Vector3(mn.x, c.y, c.z)
			b_o = Vector3(mx.x, c.y, c.z)
			a_n = Vector3(-1, 0, 0)
			b_n = Vector3(1, 0, 0)
		1:
			a_o = Vector3(c.x, mn.y, c.z)
			b_o = Vector3(c.x, mx.y, c.z)
			a_n = Vector3(0, -1, 0)
			b_n = Vector3(0, 1, 0)
		_:
			a_o = Vector3(c.x, c.y, mn.z)
			b_o = Vector3(c.x, c.y, mx.z)
			a_n = Vector3(0, 0, -1)
			b_n = Vector3(0, 0, 1)
	return [
		{"origin": a_o, "outward": a_n},
		{"origin": b_o, "outward": b_n},
	]


func _canonicalize(verts: PackedVector3Array, indices: PackedInt32Array,
		sock_a: Dictionary, sock_b: Dictionary, bend_deg: float) -> Dictionary:
	var oa: Vector3 = sock_a["origin"]
	var na: Vector3 = (sock_a["outward"] as Vector3).normalized()
	var ob: Vector3 = sock_b["origin"]
	var nb: Vector3 = (sock_b["outward"] as Vector3).normalized()
	var z_axis := -na
	if z_axis.length_squared() < 1e-10:
		z_axis = Vector3.FORWARD
	z_axis = z_axis.normalized()
	var x_axis: Vector3
	if bend_deg > 0.5:
		var to_b := ob - oa
		x_axis = to_b - z_axis * to_b.dot(z_axis)
		if x_axis.length_squared() < 1e-10:
			x_axis = nb - z_axis * nb.dot(z_axis)
		if x_axis.length_squared() < 1e-10:
			x_axis = z_axis.cross(Vector3.UP)
		if x_axis.length_squared() < 1e-10:
			x_axis = z_axis.cross(Vector3.RIGHT)
		x_axis = x_axis.normalized()
	else:
		x_axis = z_axis.cross(Vector3.UP)
		if x_axis.length_squared() < 1e-10:
			x_axis = z_axis.cross(Vector3.RIGHT)
		x_axis = x_axis.normalized()
	var y_axis := z_axis.cross(x_axis).normalized()
	x_axis = y_axis.cross(z_axis).normalized()
	var basis := Basis(x_axis, y_axis, z_axis)
	var inv_b := basis.inverse()
	var new_verts := PackedVector3Array()
	new_verts.resize(verts.size())
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for i: int in range(verts.size()):
		var p := inv_b * (verts[i] - oa)
		new_verts[i] = p
		mn = mn.min(p)
		mx = mx.max(p)
	var ob_c := inv_b * (ob - oa)
	var nb_c := (inv_b * nb).normalized()
	# Rotate about +Z so the bend lies in the +X / +Z half-plane (nb.y ≈ 0, nb.x ≥ 0).
	if bend_deg > 0.5:
		var n_xy := Vector2(nb_c.x, nb_c.y)
		if n_xy.length_squared() > 1e-10:
			var yaw := -atan2(n_xy.y, n_xy.x)
			var q_yaw := Quaternion(Vector3(0, 0, 1), yaw)
			for i: int in range(new_verts.size()):
				new_verts[i] = q_yaw * new_verts[i]
			ob_c = q_yaw * ob_c
			nb_c = (q_yaw * nb_c).normalized()
			mn = Vector3(INF, INF, INF)
			mx = Vector3(-INF, -INF, -INF)
			for p: Vector3 in new_verts:
				mn = mn.min(p)
				mx = mx.max(p)
	var od_m := maxf(mx.x - mn.x, mx.y - mn.y)
	var length_m := ob_c.length()
	var takeout_m := 0.0
	var radius_cl := 0.0
	if bend_deg > 0.5:
		var bend_rad := deg_to_rad(bend_deg)
		var dir_a := Vector3(0, 0, 1)
		# Trace back into the fitting from socket B (−outward) to meet inlet axis.
		var dir_b := -nb_c
		if absf(dir_a.dot(dir_b.normalized())) > 0.98:
			# Degenerate socket pair — synthesize takeout from chord length.
			takeout_m = maxf(ob_c.length() * 0.5, 0.01)
		else:
			var corner := _line_intersect(Vector3.ZERO, dir_a, ob_c, dir_b)
			var t_a := corner.distance_to(Vector3.ZERO)
			var t_b := corner.distance_to(ob_c)
			takeout_m = (t_a + t_b) * 0.5
		radius_cl = takeout_m
		length_m = takeout_m * bend_rad
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var i := 0
	while i + 2 < indices.size():
		st.add_vertex(new_verts[indices[i]])
		st.add_vertex(new_verts[indices[i + 1]])
		st.add_vertex(new_verts[indices[i + 2]])
		i += 3
	st.generate_normals()
	var am := st.commit()
	# Harden collar/rim edges — full smooth normals make elbows look melted.
	am = PipeKit.crease_normals(am, 32.0)
	return {
		"mesh": am,
		"socket_a": {
			"origin": [0.0, 0.0, 0.0],
			"outward": [0.0, 0.0, -1.0],
		},
		"socket_b": {
			"origin": [ob_c.x, ob_c.y, ob_c.z],
			"outward": [nb_c.x, nb_c.y, nb_c.z],
		},
		"centerline_length_m": length_m,
		"takeout_m": takeout_m if bend_deg > 0.5 else 0.0,
		"centerline_radius_m": radius_cl,
		"od_m": od_m,
	}


func _line_intersect(p0: Vector3, d0: Vector3, p1: Vector3, d1: Vector3) -> Vector3:
	var a := d0
	var b := d1
	var w0 := p0 - p1
	var aa := a.dot(a)
	var bb := b.dot(b)
	var ab := a.dot(b)
	var aw := a.dot(w0)
	var bw := b.dot(w0)
	var den := aa * bb - ab * ab
	var t := 0.0
	var s := 0.0
	if absf(den) > 1e-12:
		t = (ab * bw - bb * aw) / den
		s = (aa * bw - ab * aw) / den
	var q0 := p0 + a * t
	var q1 := p1 + b * s
	return (q0 + q1) * 0.5
