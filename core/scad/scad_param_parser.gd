class_name ScadParamParser
extends RefCounted

## Parses an OpenSCAD file's Customizer metadata block into a structured schema
## the in-game panel can render (the "recreate the Customizer modal" half of the
## parametric store — see PARAMETRIC_STORE_PLAN.md Phase 1). Pure text parsing,
## no OpenSCAD binary needed.
##
## Rules (the OpenSCAD Customizer convention; the seed vase file follows them):
##  * Only top-level `name = value;` assignments BEFORE the first module/function
##    definition are candidate parameters.
##  * Only assignments to a LITERAL constant (number/string/bool/vector) are
##    exposed — an assignment whose RHS is an expression referencing other
##    variables (e.g. `inner_radius = radius - thickness;`) is a *calculated*
##    value and is skipped, exactly as the Customizer hides it.
##  * The trailing `//…` comment encodes the widget:
##       //[min:max]        -> slider
##       //[min:step:max]   -> stepped slider
##       //[a,b,c]          -> dropdown of values
##       //[a:Label,b:Lbl]  -> dropdown with labels
##       (no annotation)    -> free field / checkbox (bool)
##  * The contiguous `//` comment line(s) directly ABOVE the assignment are the
##    human label/tooltip.
##  * `/* [Group Name] */` block comments segment params into groups;
##    `/* [Hidden] */` marks following params hidden.
##
## Returns { ok, source, title, params: [ParamDict], groups: [String], warnings }.
## ParamDict = {
##   name, label, group, hidden(bool),
##   type: "int"|"float"|"string"|"bool"|"vector",
##   widget: "slider"|"dropdown"|"checkbox"|"field",
##   default: <typed>,
##   min, max, step,                    # sliders only
##   options: [ {value, label} ],       # dropdowns only
##   raw_rhs, raw_annotation,           # provenance
## }

const DEFAULT_GROUP := "Parameters"


static func parse_file(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"ok": false, "error": "file not found: %s" % path, "params": [], "groups": [], "warnings": []}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "cannot open: %s" % path, "params": [], "groups": [], "warnings": []}
	var text := f.get_as_text()
	f.close()
	return parse_text(text, path.get_file())


static func parse_text(text: String, source_name: String = "") -> Dictionary:
	var params: Array = []
	var groups: Array = []          # ordered unique
	var warnings: Array = []
	var current_group := DEFAULT_GROUP
	var in_hidden := false
	var pending_label: Array = []   # contiguous // comment lines above an assignment

	var re_group := RegEx.new()
	re_group.compile("^\\s*/\\*\\s*\\[([^\\]]+)\\]\\s*\\*/\\s*$")
	var re_module := RegEx.new()
	re_module.compile("^\\s*(module|function)\\s+")
	var re_assign := RegEx.new()
	# name = rhs ;  optional trailing //comment
	re_assign.compile("^\\s*([A-Za-z_$][A-Za-z0-9_]*)\\s*=\\s*(.+?)\\s*;\\s*(//.*)?$")

	var lines := text.split("\n")
	var lineno := 0
	for raw in lines:
		lineno += 1
		var line := String(raw)
		var stripped := line.strip_edges()

		# Group / Hidden marker.
		var mg := re_group.search(line)
		if mg:
			var gname := mg.get_string(1).strip_edges()
			if gname.to_lower() == "hidden":
				in_hidden = true
				current_group = "Hidden"
			else:
				in_hidden = false
				current_group = gname
				if not groups.has(gname):
					groups.append(gname)
			pending_label.clear()
			continue

		# First module/function definition ends the parameter region.
		if re_module.search(line):
			break

		# Blank line breaks label contiguity.
		if stripped.is_empty():
			pending_label.clear()
			continue

		# Pure comment line -> candidate label text.
		if stripped.begins_with("//"):
			pending_label.append(_clean_comment(stripped))
			continue
		if stripped.begins_with("/*"):
			# Non-group block comment; ignore for labels.
			pending_label.clear()
			continue

		# Assignment?
		var ma := re_assign.search(line)
		if ma:
			var name := ma.get_string(1)
			var rhs := ma.get_string(2).strip_edges()
			var comment := ma.get_string(3)  # includes leading // or ""
			var lit := _parse_literal(rhs)
			if not lit.get("ok", false):
				# Calculated/expression value — not a Customizer parameter.
				pending_label.clear()
				continue
			var p := {
				"name": name,
				"label": " ".join(pending_label).strip_edges() if not pending_label.is_empty() else name,
				"group": current_group,
				"hidden": in_hidden,
				"type": lit["type"],
				"default": lit["value"],
				"raw_rhs": rhs,
				"raw_annotation": "",
				"widget": "field",
			}
			_apply_annotation(p, comment, warnings, lineno)
			# Register default group lazily so it appears in the ordered list.
			if not groups.has(p["group"]):
				groups.append(p["group"])
			params.append(p)
			pending_label.clear()
			continue

		# Any other code line breaks label contiguity.
		pending_label.clear()

	return {
		"ok": true,
		"source": source_name,
		"title": _title_from_source(source_name),
		"params": params,
		"groups": groups,
		"warnings": warnings,
	}


# -- Literal parsing (also the calculated-value filter) ------------------------

## Returns { ok, value, type } if rhs is a literal constant, else { ok=false }.
static func _parse_literal(rhs: String) -> Dictionary:
	var s := rhs.strip_edges()
	if s.is_empty():
		return {"ok": false}
	# String literal.
	if s.length() >= 2 and s.begins_with("\"") and s.ends_with("\""):
		return {"ok": true, "value": s.substr(1, s.length() - 2), "type": "string"}
	# Bool.
	if s == "true" or s == "false":
		return {"ok": true, "value": s == "true", "type": "bool"}
	# Numeric vector of literals, e.g. [1, 2, 3] or [1.0, -2, 3].
	if s.begins_with("[") and s.ends_with("]"):
		var inner := s.substr(1, s.length() - 2).strip_edges()
		if inner.is_empty():
			return {"ok": false}
		var out := []
		for tok in inner.split(","):
			var t := tok.strip_edges()
			if not _is_number(t):
				return {"ok": false}  # contains identifiers -> expression, not a literal
			out.append(t.to_float())
		return {"ok": true, "value": out, "type": "vector"}
	# Integer.
	if s.is_valid_int():
		return {"ok": true, "value": s.to_int(), "type": "int"}
	# Float.
	if _is_number(s):
		return {"ok": true, "value": s.to_float(), "type": "float"}
	return {"ok": false}


static func _is_number(s: String) -> bool:
	return s.is_valid_float() or s.is_valid_int()


# -- Annotation (widget) parsing -----------------------------------------------

static func _apply_annotation(p: Dictionary, comment: String, warnings: Array, lineno: int) -> void:
	# Default widget by type when there is no bracket annotation.
	if p["type"] == "bool":
		p["widget"] = "checkbox"
	var lb := comment.find("[")
	if lb < 0:
		return
	var rb := comment.find("]", lb)
	var closed := rb >= 0
	var body := ""
	if closed:
		body = comment.substr(lb + 1, rb - lb - 1)
	else:
		body = comment.substr(lb + 1)
		warnings.append("line %d (%s): unclosed '[' in annotation — parsed leniently" % [lineno, p["name"]])
	body = body.strip_edges()
	p["raw_annotation"] = "[%s%s" % [body, "]" if closed else ""]
	if body.is_empty():
		return

	if body.contains(","):
		_apply_dropdown(p, body)
	elif body.contains(":"):
		var parts := body.split(":")
		var nums := true
		for part in parts:
			if not _is_number(part.strip_edges()):
				nums = false
				break
		if nums and (parts.size() == 2 or parts.size() == 3):
			_apply_slider(p, parts)
		else:
			# A single value:label pair with no comma -> treat as one-option dropdown.
			_apply_dropdown(p, body)
	else:
		# A lone bracket value like [5] — uncommon; leave as a field.
		pass


static func _apply_slider(p: Dictionary, parts: PackedStringArray) -> void:
	p["widget"] = "slider"
	if parts.size() == 2:
		p["min"] = parts[0].strip_edges().to_float()
		p["max"] = parts[1].strip_edges().to_float()
		p["step"] = 1.0 if p["type"] == "int" else 0.0
	elif parts.size() == 3:
		p["min"] = parts[0].strip_edges().to_float()
		p["step"] = parts[1].strip_edges().to_float()
		p["max"] = parts[2].strip_edges().to_float()


static func _apply_dropdown(p: Dictionary, body: String) -> void:
	p["widget"] = "dropdown"
	var options: Array = []
	for tok in body.split(","):
		var item := tok.strip_edges()
		if item.is_empty():
			continue
		var value_str := item
		var label := ""
		# value:label — but not a quoted string containing ':'.
		var ci := _top_level_colon(item)
		if ci >= 0:
			value_str = item.substr(0, ci).strip_edges()
			label = item.substr(ci + 1).strip_edges()
		var value: Variant = _coerce_option_value(value_str)
		if label.is_empty():
			# str() not String(): the String() constructor rejects int/float/bool
			# (numeric dropdown options like [8,16,32]); str() converts any Variant.
			label = str(value)
		options.append({"value": value, "label": _unquote(label)})
	p["options"] = options


## Colon position that is NOT inside a quoted string (so "a:b" strings survive).
static func _top_level_colon(s: String) -> int:
	var in_q := false
	for i in s.length():
		var c := s[i]
		if c == "\"":
			in_q = not in_q
		elif c == ":" and not in_q:
			return i
	return -1


static func _coerce_option_value(s: String) -> Variant:
	var t := s.strip_edges()
	if t.begins_with("\"") and t.ends_with("\"") and t.length() >= 2:
		return t.substr(1, t.length() - 2)
	if t == "true" or t == "false":
		return t == "true"
	if t.is_valid_int():
		return t.to_int()
	if t.is_valid_float():
		return t.to_float()
	return t  # bare identifier value (OpenSCAD treats yes/no here as strings)


static func _unquote(s: String) -> String:
	var t := s.strip_edges()
	if t.begins_with("\"") and t.ends_with("\"") and t.length() >= 2:
		return t.substr(1, t.length() - 2)
	return t


# -- Small helpers -------------------------------------------------------------

static func _clean_comment(s: String) -> String:
	var t := s.strip_edges()
	while t.begins_with("/"):
		t = t.substr(1)
	return t.strip_edges()


static func _title_from_source(source_name: String) -> String:
	var base := source_name.get_file().get_basename()
	# Drop a trailing _<digits> (Thingiverse date/id suffix) and prettify.
	var re := RegEx.new()
	re.compile("_[0-9]{4,}$")
	base = re.sub(base, "")
	base = base.replace("_", " ").replace("-", " ").strip_edges()
	if base.is_empty():
		return source_name
	return base.substr(0, 1).to_upper() + base.substr(1)


## Convenience: the default parameter dict {name: default_value} ready to hand to
## ScadRuntime.render_to_stl for an unmodified render.
static func default_params(schema: Dictionary) -> Dictionary:
	var out := {}
	for p in schema.get("params", []):
		out[p["name"]] = p["default"]
	return out
