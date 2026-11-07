class_name EspAutoWire
extends RefCounted

## Wires a resolved EspSpec to its board's pins, the way a careful person
## would, and says what is wrong with the result.
##
## Order (deterministic: parts in spec order, pins in part order):
##   1. locked wires (dragged by hand) are honoured first, or reported;
##   2. the I2C bus on the board's usual SDA / SCL, addresses handed out per
##      bus; a clash moves the part to its other address, then to a second
##      bus where the chip has one, else an error naming both parts;
##   3. one shared SPI bus (SCK / MISO / MOSI as the parts need), a CS each;
##   4. a hardware UART per serial part (never the console's pins on a chip
##      whose logger uses them);
##   5. one shared 1-Wire pin for every 1-Wire part;
##   6. analog parts on ADC pins that work with Wi-Fi on (ADC1 on the ESP32);
##   7. every other signal pin on the best free GPIO for its direction.
##
## A GPIO's cost (lower is better) prefers free pins with no boot duty, keeps
## ADC pins for analog parts, uses input-only pins for inputs, and avoids the
## onboard LED / button. Returns
##   {assign: {iid: {pin_label: "GPIO" int | "3V3" | "5V" | "GND" | ""}},
##    buses: {i2c: [...], spi: [...], uart: [...], one_wire: [...]},
##    addr: {iid: int}, uart_of: {iid: bus id}, i2c_of: {iid: bus id},
##    used: {gpio: [[iid, pin_label]...]}, nets: [...], checks: [...],
##    power: {ma_3v3, ma_5v, reg_ma, usb_ma}}

const COST_STRAP := 60.0
const COST_STRAP_BAD := 160.0
const COST_ONBOARD := 45.0
const COST_CONSOLE := 30.0
const COST_ADC_FOR_DIGITAL := 4.0
const COST_NO_PULL := 40.0
const COST_INPUT_ONLY_BONUS := -6.0
const USB_MA := 500.0

var _board: Dictionary
var _chip: Dictionary
var _chip_id: String
var _spec: Dictionary
var _header: Array
var _used := {}
var _assign := {}
var _checks: Array = []
var _buses := {"i2c": [], "spi": [], "uart": [], "one_wire": []}
var _addr := {}
var _i2c_of := {}
var _uart_of := {}


static func solve(spec: Dictionary) -> Dictionary:
	var w := EspAutoWire.new()
	return w._run(spec)


func _run(spec: Dictionary) -> Dictionary:
	_spec = spec
	_board = EspBoards.get_board(str(spec["board"]))
	_chip_id = str(_board["chip"])
	_chip = EspChips.get_chip(_chip_id)
	_header = EspBoards.header_gpios(_board)
	for inst in spec["parts"]:
		_assign[str(inst["iid"])] = {}
	_apply_locks()
	_power_pins()
	_wire_i2c()
	_wire_spi()
	_wire_uart()
	_wire_onewire()
	_wire_singles()
	_electrical_checks()
	return {
		"assign": _assign, "buses": _buses, "addr": _addr, "i2c_of": _i2c_of, "uart_of": _uart_of,
		"used": _used, "nets": _nets(), "checks": _checks, "power": _power_budget(),
		"board": str(spec["board"]), "chip": _chip_id,
	}


# ------------------------------------------------------------------ helpers

func _parts() -> Array:
	return _spec["parts"]


func _part_of(inst: Dictionary) -> Dictionary:
	return EspParts.get_part(str(inst["part"]))


func _check(level: String, text: String, why: String, ids: Array = []) -> void:
	_checks.append({"level": level, "text": text, "why": why, "ids": ids})


func _take(g: int, iid: String, label: String) -> void:
	if not _used.has(g):
		_used[g] = []
	(_used[g] as Array).append([iid, label])
	(_assign[iid] as Dictionary)[label] = g


func _is_free(g: int) -> bool:
	return not _used.has(g)


## Can this GPIO carry a signal at all on this board?
func _usable(g: int) -> bool:
	if not _header.has(g) or not EspChips.has_gpio(_chip, g):
		return false
	if EspBoards.hard_reserved(_board, g):
		return false
	# The console UART: the logger owns it on chips that print to UART0.
	if str(_chip.get("logger_uart", "")) == "UART0" and (_chip.get("console", []) as Array).has(g):
		return false
	return true


## The cost of putting a signal on GPIO g (INF = not possible).
##   dir_out   the board drives the pin
##   need_pull the line needs a pull-up
##   analog    the pin must be an ADC that works with Wi-Fi on
##   interrupt the part needs an edge interrupt (pulse counting)
func _cost(g: int, dir_out: bool, need_pull: bool, analog: bool = false, interrupt: bool = false) -> float:
	if not _usable(g):
		return INF
	if analog:
		if not EspChips.is_adc(_chip, g, true):
			return INF
	elif (_chip.get("analog_only", []) as Array).has(g):
		return INF
	if dir_out and EspChips.is_input_only(_chip, g):
		return INF
	if interrupt and (_chip.get("no_interrupt", []) as Array).has(g):
		return INF
	var c := 0.0
	var strap := EspChips.strapping_note(_chip, g)
	if strap != "":
		c += COST_STRAP_BAD if (strap.find("flash voltage") >= 0 or strap.find("download") >= 0 or strap.find("must be HIGH") >= 0) else COST_STRAP
	if EspBoards.board_use(_board, g) != "":
		c += COST_ONBOARD
	if (_chip.get("console", []) as Array).has(g):
		c += COST_CONSOLE
	if not analog and EspChips.is_adc(_chip, g, true):
		c += COST_ADC_FOR_DIGITAL
	if need_pull and (_chip.get("no_pull", []) as Array).has(g):
		c += COST_NO_PULL
	if not dir_out and not need_pull and EspChips.is_input_only(_chip, g):
		c += COST_INPUT_ONLY_BONUS
	if (_chip.get("no_interrupt", []) as Array).has(g):
		c += 20.0
	return c + float(g) * 0.001


func _best(candidates: Array, dir_out: bool, need_pull: bool, analog: bool = false, interrupt: bool = false) -> int:
	var best := -1
	var bc := INF
	for g in candidates:
		var gi := int(g)
		if not _is_free(gi):
			continue
		var c := _cost(gi, dir_out, need_pull, analog, interrupt)
		if c < bc:
			bc = c
			best = gi
	return best


func _role_out(role: String) -> bool:
	return EspParts.is_board_output(role)


func _needs_pull(part: Dictionary, role: String) -> bool:
	return (part.get("pullup", []) as Array).has(role)


# ------------------------------------------------------------------ locks

func _apply_locks() -> void:
	var locks: Dictionary = _spec.get("locks", {})
	var keys: Array = locks.keys()
	keys.sort()
	for k in keys:
		var bits := str(k).split(":")
		var iid := bits[0]
		var label := bits[1] if bits.size() > 1 else ""
		var g := int(locks[k])
		var inst := _inst(iid)
		if inst.is_empty():
			continue
		var part := _part_of(inst)
		var role := _role_of(part, label)
		if role == "":
			continue
		var why := _lock_problem(g, role, part)
		if why != "":
			_check("error", "%s %s can't go on %s" % [str(inst["label"]), label, EspBoards.label_of(_board, g)],
				why + " The tool wired it elsewhere.", [iid])
			continue
		var bus := EspParts.is_bus_role(str(part["iface"]), role)
		if not bus and not _is_free(g):
			_check("error", "%s is wired twice" % EspBoards.label_of(_board, g),
				"Two parts' signals were dragged onto the same pin; only a bus (I2C, SPI, 1-Wire) may share a pin.", [iid])
			continue
		if bus:
			(_assign[iid] as Dictionary)[label] = g
		else:
			_take(g, iid, label)


func _lock_problem(g: int, role: String, part: Dictionary) -> String:
	if not _header.has(g):
		return "That pin isn't on this board's header."
	if EspChips.is_flash(_chip, g):
		return "GPIO%d is wired to the flash chip; using it crashes the board." % g
	if EspChips.is_usb(_chip, g):
		return "GPIO%d is USB; ESPHome's console uses it." % g
	var res := str((_board.get("reserved", {}) as Dictionary).get(g, ""))
	if res != "":
		return "The board already uses GPIO%d (%s)." % [g, res]
	if _role_out(role) and EspChips.is_input_only(_chip, g):
		return "GPIO%d is input-only; it can't drive %s." % [g, role.to_upper()]
	if str(part.get("iface", "")) == "adc" and role == "aout" and not EspChips.is_adc(_chip, g, true):
		return "GPIO%d can't read an analog voltage with Wi-Fi on." % g
	if role != "aout" and (_chip.get("analog_only", []) as Array).has(g):
		return "%s only reads an analog voltage; it can't carry a digital signal." % EspChips.pin_name(str(_chip_id), g)
	return ""


func _inst(iid: String) -> Dictionary:
	for inst in _parts():
		if str(inst["iid"]) == iid:
			return inst
	return {}


func _role_of(part: Dictionary, label: String) -> String:
	for p in part.get("pins", []):
		if str(p[0]) == label:
			return str(p[1])
	return ""


func _locked(iid: String, label: String) -> int:
	var a: Dictionary = _assign.get(iid, {})
	if a.has(label) and a[label] is int:
		return int(a[label])
	return -1


# ------------------------------------------------------------------ power

func _power_pins() -> void:
	var has5 := EspBoards.has_rail(_board, "5v")
	for inst in _parts():
		var part := _part_of(inst)
		var iid := str(inst["iid"])
		for p in part.get("pins", []):
			var role := str(p[1])
			var label := str(p[0])
			if role == "gnd":
				_assign[iid][label] = "GND"
			elif role == "vcc":
				var sup := str(part.get("supply", "3v3"))
				if sup == "5v":
					if has5:
						_assign[iid][label] = "5V"
					else:
						_assign[iid][label] = ""
						_check("error", "%s needs 5 V" % str(inst["label"]),
							"This board has no 5 V pin. Power it from a separate 5 V supply with a shared GND.", [iid])
				else:
					_assign[iid][label] = "3V3"
			elif role == "nc":
				_assign[iid][label] = ""


# ------------------------------------------------------------------ I2C

func _wire_i2c() -> void:
	var members: Array = []
	for inst in _parts():
		if str(_part_of(inst).get("iface", "")) == "i2c":
			members.append(inst)
	if members.is_empty():
		return
	for inst in members:
		var part := _part_of(inst)
		var iid := str(inst["iid"])
		var placed := false
		for bi in (_buses["i2c"] as Array).size():
			if _try_address(inst, part, bi):
				placed = true
				break
		if not placed:
			var nb := (_buses["i2c"] as Array).size()
			if nb < int(_chip.get("i2c_buses", 1)) and _open_i2c_bus(inst, part):
				placed = _try_address(inst, part, nb)
			if not placed:
				var other := _addr_holder(part)
				_check("error", "%s has no free I2C address" % str(inst["label"]),
					"Its addresses (%s) are taken%s, and this chip has no other I2C bus. Change the address on one board (%s) or use a different part." % [
						_hex_list(part.get("addr", [])), (" by " + other) if other != "" else "", str(part.get("addr_note", "no address pin"))], [iid])
		# The bus pins on the instance.
		if _i2c_of.has(iid):
			var bus := _bus("i2c", str(_i2c_of[iid]))
			for p in part["pins"]:
				if str(p[1]) == "sda":
					_assign[iid][str(p[0])] = int(bus["sda"])
				elif str(p[1]) == "scl":
					_assign[iid][str(p[0])] = int(bus["scl"])
	var n := 0
	for b in _buses["i2c"]:
		n += (b["members"] as Array).size()
	if n > 4:
		_check("info", "%d I2C breakouts share the bus" % n,
			"Each breakout usually carries its own 4.7-10 kΩ pull-ups; with many in parallel the bus gets stiff. If readings fail, remove pull-ups from all but one board.", [])


func _addr_holder(part: Dictionary) -> String:
	for b in _buses["i2c"]:
		for m in b["members"]:
			var a := int(_addr.get(m, -1))
			if (part.get("addr", []) as Array).has(a):
				return str(_inst(m).get("label", m))
	return ""


func _try_address(inst: Dictionary, part: Dictionary, bi: int) -> bool:
	var bus: Dictionary = _buses["i2c"][bi]
	var taken := {}
	for m in bus["members"]:
		taken[int(_addr[m])] = true
	var want := int(inst.get("addr", -1))
	var options: Array = part.get("addr", [])
	var order: Array = []
	if want >= 0 and options.has(want):
		order.append(want)
	for a in options:
		if not order.has(a):
			order.append(a)
	for a in order:
		if not taken.has(int(a)):
			var iid := str(inst["iid"])
			_addr[iid] = int(a)
			_i2c_of[iid] = str(bus["id"])
			(bus["members"] as Array).append(iid)
			# A first bus opened with a locked pin keeps it; later members must agree.
			return true
	return false


func _open_i2c_bus(inst: Dictionary, part: Dictionary) -> bool:
	var iid := str(inst["iid"])
	var first := (_buses["i2c"] as Array).is_empty()
	var sda := -1
	var scl := -1
	for p in part["pins"]:
		if str(p[1]) == "sda":
			sda = _locked(iid, str(p[0]))
		elif str(p[1]) == "scl":
			scl = _locked(iid, str(p[0]))
	var routing: Variant = EspChips.routing(_chip, "i2c")
	var ctrl := -1
	if routing is Array:
		ctrl = _pick_controller(routing, ["sda", "scl"], {"sda": sda, "scl": scl}, (_buses["i2c"] as Array).size())
		if ctrl < 0:
			return false
	var dflt: Array = _board.get("i2c", [])
	if first and sda < 0 and scl < 0 and dflt.size() == 2:
		var ds := int(dflt[0])
		var dc := int(dflt[1])
		if _usable(ds) and _usable(dc) and _is_free(ds) and _is_free(dc) and _in_ctrl(routing, ctrl, "sda", ds) and _in_ctrl(routing, ctrl, "scl", dc):
			sda = ds
			scl = dc
	if sda < 0:
		sda = _best(_ctrl_pins(routing, ctrl, "sda"), true, true)
		if sda >= 0:
			_used[sda] = []
	if scl < 0:
		scl = _best(_ctrl_pins(routing, ctrl, "scl"), true, true)
	if sda >= 0 and _used.has(sda) and (_used[sda] as Array).is_empty():
		_used.erase(sda)
	if sda < 0 or scl < 0 or sda == scl:
		_check("error", "No free pins for an I2C bus", "Every pin that could carry SDA / SCL is taken.", [iid])
		return false
	var id := "bus_%s" % String.chr(97 + (_buses["i2c"] as Array).size())
	var bus := {"id": id, "sda": sda, "scl": scl, "members": [], "ctrl": ctrl}
	(_buses["i2c"] as Array).append(bus)
	_mark_bus_pin(sda, id, "SDA")
	_mark_bus_pin(scl, id, "SCL")
	return true


func _mark_bus_pin(g: int, bus_id: String, role: String) -> void:
	if not _used.has(g):
		_used[g] = []
	(_used[g] as Array).append([bus_id, role])


## Pins of a peripheral role: the header for the GPIO matrix, else the
## controller's fixed list.
func _ctrl_pins(routing: Variant, ctrl: int, role: String) -> Array:
	if routing is Array and ctrl >= 0:
		return ((routing as Array)[ctrl] as Dictionary).get(role, [])
	return _header


func _in_ctrl(routing: Variant, ctrl: int, role: String, g: int) -> bool:
	if routing is Array and ctrl >= 0:
		return (((routing as Array)[ctrl] as Dictionary).get(role, []) as Array).has(g)
	return true


## A fixed-function controller that fits the locked pins (if any), skipping
## the ones already used by earlier buses.
func _pick_controller(routing: Array, roles: Array, locked: Dictionary, skip: int) -> int:
	var used_ctrl := {}
	for kind in ["i2c", "spi", "uart"]:
		for b in _buses[kind]:
			if int(b.get("ctrl", -1)) >= 0 and routing == EspChips.routing(_chip, kind):
				used_ctrl[int(b["ctrl"])] = true
	for ci in routing.size():
		if used_ctrl.has(ci):
			continue
		var ok := true
		for r in roles:
			var g := int(locked.get(r, -1))
			if g >= 0 and not ((routing[ci] as Dictionary).get(r, []) as Array).has(g):
				ok = false
		if ok:
			return ci
	return -1


func _bus(kind: String, id: String) -> Dictionary:
	for b in _buses[kind]:
		if str(b["id"]) == id:
			return b
	return {}


static func _hex_list(a: Array) -> String:
	var s := PackedStringArray()
	for x in a:
		s.append("0x%02X" % int(x))
	return ", ".join(s)


# ------------------------------------------------------------------ SPI

func _wire_spi() -> void:
	var members: Array = []
	var need := {"sck": false, "miso": false, "mosi": false}
	for inst in _parts():
		var part := _part_of(inst)
		if str(part.get("iface", "")) != "spi":
			continue
		members.append(inst)
		for p in part["pins"]:
			if need.has(str(p[1])):
				need[str(p[1])] = true
	if members.is_empty():
		return
	var routing: Variant = EspChips.routing(_chip, "spi")
	var ctrl := -1
	if routing is Array:
		ctrl = _pick_controller(routing, ["sck", "miso", "mosi"], {}, 0)
	var dflt: Dictionary = _board.get("spi", {})
	var bus := {"id": "spi_a", "members": [], "ctrl": ctrl}
	for role in ["sck", "miso", "mosi"]:
		if not bool(need[role]):
			continue
		var g := -1
		# A locked pin on any member wins.
		for inst in members:
			for p in _part_of(inst)["pins"]:
				if str(p[1]) == role and _locked(str(inst["iid"]), str(p[0])) >= 0:
					g = _locked(str(inst["iid"]), str(p[0]))
		if g < 0 and dflt.has(role):
			var d := int(dflt[role])
			if _usable(d) and _is_free(d) and _in_ctrl(routing, ctrl, role, d) and not (role != "miso" and EspChips.is_input_only(_chip, d)):
				g = d
		if g < 0:
			g = _best(_ctrl_pins(routing, ctrl, role), role != "miso", false)
		if g < 0:
			_check("error", "No free pin for SPI %s" % role.to_upper(), "Every pin that could carry it is taken.", [])
			continue
		bus[role] = g
		_mark_bus_pin(g, "spi_a", role.to_upper())
	(_buses["spi"] as Array).append(bus)
	for inst in members:
		var iid := str(inst["iid"])
		(bus["members"] as Array).append(iid)
		for p in _part_of(inst)["pins"]:
			var role := str(p[1])
			if bus.has(role) and role in ["sck", "miso", "mosi"]:
				_assign[iid][str(p[0])] = int(bus[role])


# ------------------------------------------------------------------ UART

func _wire_uart() -> void:
	var free := int(_chip.get("uarts_free", 0))
	var software := _chip_id == "esp8266"
	var routing: Variant = EspChips.routing(_chip, "uart")
	for inst in _parts():
		var part := _part_of(inst)
		if str(part.get("iface", "")) != "uart":
			continue
		var iid := str(inst["iid"])
		var use := str((part.get("uart", {}) as Dictionary).get("use", "both"))
		if (_buses["uart"] as Array).size() >= free and not software:
			_check("error", "No UART left for %s" % str(inst["label"]),
				"%s has %d hardware UART%s free for parts (the console uses one). Remove a serial part or use a bigger chip." % [
					str(_chip["label"]), free, "" if free == 1 else "s"], [iid])
			continue
		var ctrl := -1
		var locked := {}
		for p in part["pins"]:
			var r := str(p[1])
			var g := _locked(iid, str(p[0]))
			if g >= 0:
				locked["rx" if r == "tx" else "tx"] = g
		if routing is Array:
			ctrl = _pick_controller(routing, ["tx", "rx"], locked, 0)
			if ctrl < 0:
				_check("error", "No UART left for %s" % str(inst["label"]), "Both of the chip's UARTs are in use.", [iid])
				continue
		var bus := {"id": "uart_%s" % iid, "baud": int((part.get("uart", {}) as Dictionary).get("baud", 9600)),
			"members": [iid], "ctrl": ctrl}
		# The part's TX feeds the board's RX and the other way round.
		for p in part["pins"]:
			var r := str(p[1])
			var label := str(p[0])
			if r != "tx" and r != "rx":
				continue
			var board_role := "rx" if r == "tx" else "tx"
			if (board_role == "rx" and use == "tx") or (board_role == "tx" and use == "rx"):
				_assign[iid][label] = ""
				continue
			var g := _locked(iid, label)
			if g < 0:
				g = _best(_ctrl_pins(routing, ctrl, board_role), board_role == "tx", false)
			if g < 0:
				_check("error", "No free pin for %s %s" % [str(inst["label"]), label], "Every pin that could carry it is taken.", [iid])
				continue
			bus[board_role] = g
			_assign[iid][label] = g
			_mark_bus_pin(g, str(bus["id"]), board_role.to_upper())
		(_buses["uart"] as Array).append(bus)
		_uart_of[iid] = str(bus["id"])
		if software and (_buses["uart"] as Array).size() == 1:
			_check("info", "%s uses a software serial port" % str(inst["label"]),
				"The ESP8266's one real UART is the USB console. ESPHome talks to this part with software serial, which is fine at %d baud." % int(bus["baud"]), [iid])


# ------------------------------------------------------------------ 1-Wire

func _wire_onewire() -> void:
	var members: Array = []
	for inst in _parts():
		if str(_part_of(inst).get("iface", "")) == "onewire":
			members.append(inst)
	if members.is_empty():
		return
	var g := -1
	for inst in members:
		for p in _part_of(inst)["pins"]:
			if str(p[1]) == "data" and _locked(str(inst["iid"]), str(p[0])) >= 0:
				g = _locked(str(inst["iid"]), str(p[0]))
	if g < 0:
		g = _best(_header, true, true)
	if g < 0:
		_check("error", "No free pin for the 1-Wire bus", "Every pin is taken.", [])
		return
	var bus := {"id": "ow_a", "pin": g, "members": []}
	_mark_bus_pin(g, "ow_a", "1-Wire")
	for inst in members:
		var iid := str(inst["iid"])
		(bus["members"] as Array).append(iid)
		for p in _part_of(inst)["pins"]:
			if str(p[1]) == "data":
				_assign[iid][str(p[0])] = g
	(_buses["one_wire"] as Array).append(bus)
	_check("info", "The 1-Wire line needs one 4.7 kΩ pull-up",
		"Fit a 4.7 kΩ resistor from %s to 3V3 (modules with a little PCB usually have it)." % EspBoards.label_of(_board, g),
		[str(members[0]["iid"])])
	if members.size() > 1:
		_check("info", "%d DS18B20s share one wire" % members.size(),
			"Each probe has its own 64-bit address. Flash the board once, read the addresses from its log, and add `address:` to each sensor in the YAML.", [])


# ------------------------------------------------------------------ singles

func _wire_singles() -> void:
	var pulse_units := int(_chip.get("pcnt", 0))
	var pulses := 0
	var rmt_left := int(_chip.get("rmt", 0))
	for inst in _parts():
		var part := _part_of(inst)
		var iid := str(inst["iid"])
		var iface := str(part.get("iface", ""))
		for p in part.get("pins", []):
			var label := str(p[0])
			var role := str(p[1])
			if role in ["vcc", "gnd", "nc"] or EspParts.is_bus_role(iface, role):
				continue
			if iface == "spi" and role in ["sck", "miso", "mosi"]:
				continue
			if _locked(iid, label) >= 0:
				continue
			var dir_out := _role_out(role) or role == "data"
			var pull := _needs_pull(part, role)
			var analog := role == "aout"
			var irq := role == "pulse"
			var g := _best(_header, dir_out, pull, analog, irq)
			if g < 0:
				var what := "an analog pin that works with Wi-Fi on" if analog else "a free GPIO"
				_check("error", "No pin for %s %s" % [str(inst["label"]), label],
					"The board has no %s left. Remove a part or pick a bigger board." % what, [iid])
				_assign[iid][label] = ""
				continue
			_take(g, iid, label)
			if role == "pulse":
				pulses += 1
			if role == "led" and _chip_id.begins_with("esp32"):
				rmt_left -= 1
		if iface == "pulse" and pulse_units == 0 and _chip_id.begins_with("esp32"):
			_check("info", "%s counts pulses in software" % str(inst["label"]),
				"The %s has no pulse-counter hardware; ESPHome counts on interrupts instead (use_pcnt: false), fine below a few kHz." % str(_chip["label"]), [iid])
	if pulse_units > 0 and pulses > pulse_units:
		_check("error", "Too many pulse counters", "%s has %d counter units." % [str(_chip["label"]), pulse_units], [])
	if _chip_id.begins_with("esp32") and rmt_left < 0:
		_check("error", "Too many LED strips", "%s has %d RMT channels." % [str(_chip["label"]), int(_chip.get("rmt", 0))], [])


# ------------------------------------------------------------------ checks

func _electrical_checks() -> void:
	for g in _used:
		var strap := EspChips.strapping_note(_chip, int(g))
		var owners: Array = _used[g]
		if strap != "" and not owners.is_empty():
			_check("warn", "%s is a strapping pin" % EspBoards.label_of(_board, int(g)),
				"GPIO%d %s. Whatever is wired here must not hold it the wrong way while the board resets." % [int(g), strap],
				_owner_ids(owners))
		var bu := EspBoards.board_use(_board, int(g))
		if bu != "" and not owners.is_empty():
			_check("info", "%s is also the %s" % [EspBoards.label_of(_board, int(g)), bu],
				"It still works; the %s will react to this signal." % bu, _owner_ids(owners))
	for inst in _parts():
		var part := _part_of(inst)
		var iid := str(inst["iid"])
		var only: Array = part.get("chips", [])
		if not only.is_empty() and not only.any(func(c): return _chip_id.begins_with(str(c))):
			_check("error", "%s needs an ESP32-family board" % str(inst["label"]),
				"ESPHome drives it only through the ESP32's own hardware (the %s has none for it). Pick an ESP32, S2, S3, C3 or C6 board." % str(_chip["label"]), [iid])
		var a: Dictionary = _assign[iid]
		for p in part.get("pins", []):
			var role := str(p[1])
			var label := str(p[0])
			var g: Variant = a.get(label, "")
			if not (g is int):
				continue
			var into_board := role in ["out", "tx", "pulse", "data", "aout", "miso"]
			if bool(part.get("logic5", false)) and into_board:
				_check("warn", "%s %s sends 5 V into a 3.3 V pin" % [str(inst["label"]), label],
					"The %s is not 5 V tolerant. Put a divider on %s (1 kΩ in series, 2 kΩ to GND) or a level shifter." % [
						str(_chip["label"]), label], [iid])
			if _needs_pull(part, role) and (_chip.get("no_pull", []) as Array).has(int(g)):
				_check("warn", "%s has no internal pull-up" % EspBoards.label_of(_board, int(g)),
					"Add a 10 kΩ resistor from %s to 3V3 for the %s." % [EspBoards.label_of(_board, int(g)), str(inst["label"])], [iid])
		if str(part.get("iface", "")) == "led" and str(part.get("supply", "")) == "5v":
			_check("info", "%s data is 3.3 V into a 5 V strip" % str(inst["label"]),
				"It usually works; a 74AHCT125 level shifter (or a sacrificial first LED) makes it reliable.", [iid])
		if str(part.get("iface", "")) == "adc" and _chip_id == "esp8266":
			_check("info", "A0 reads 0-%.1f V" % float(_board.get("a0_scale", 1.0)),
				"The board's divider scales A0; the YAML multiplies it back so the reading is in volts.", [iid])
		var mu := float(part.get("min_update", 0.0))
		var upd := float(inst.get("update_s", -1.0))
		if mu > 0.0 and upd > 0.0 and upd < mu:
			_check("warn", "%s can't update faster than every %d s" % [str(inst["label"]), int(mu)],
				"Faster reads return errors.", [iid])
	var pb := _power_budget()
	if float(pb["ma_3v3"]) > float(pb["reg_ma"]):
		_check("warn", "The 3V3 regulator is overloaded (%d of %d mA)" % [int(pb["ma_3v3"]), int(pb["reg_ma"])],
			"Peak draw on 3V3 exceeds what the board's regulator gives. Move power-hungry parts to 5 V or a separate supply.", [])
	if float(pb["ma_5v"]) > USB_MA:
		_check("warn", "More than a USB port gives (%d mA)" % int(pb["ma_5v"]),
			"Powered from USB the board gets 500 mA. Use a 5 V supply of at least %d mA." % int(ceilf(float(pb["ma_5v"]) * 1.25 / 100.0) * 100), [])


func _owner_ids(owners: Array) -> Array:
	var out: Array = []
	for o in owners:
		var id := str(o[0])
		if _assign.has(id) and not out.has(id):
			out.append(id)
	return out


func _power_budget() -> Dictionary:
	var ma3 := float(_chip.get("base_ma", 200))
	var ma5 := 0.0
	for inst in _parts():
		var part := _part_of(inst)
		var ma := float(part.get("ma", 0.0))
		if str(part.get("supply", "3v3")) == "5v":
			ma5 += ma
		else:
			ma3 += ma
	# The 3V3 rail is made from 5 V on every board here.
	return {"ma_3v3": ma3, "ma_5v": ma5 + ma3, "reg_ma": float(_board.get("reg_ma", 500)), "usb_ma": USB_MA}


# ------------------------------------------------------------------ nets

## Every connection as a net: {name, kind (power / gnd / i2c / spi / uart /
## onewire / signal), gpio (-1 for rails), board_pin, members: [[iid, pin]]}.
func _nets() -> Array:
	var nets: Array = []
	var rails := {"3V3": [], "5V": [], "GND": []}
	var by_gpio := {}
	for inst in _parts():
		var iid := str(inst["iid"])
		var a: Dictionary = _assign[iid]
		for label in a:
			var v: Variant = a[label]
			if v is String:
				if rails.has(v):
					(rails[v] as Array).append([iid, label])
			elif v is int:
				if not by_gpio.has(v):
					by_gpio[v] = []
				(by_gpio[v] as Array).append([iid, label])
	for r in ["3V3", "5V", "GND"]:
		if not (rails[r] as Array).is_empty():
			nets.append({"name": r, "kind": "gnd" if r == "GND" else "power", "gpio": -1, "board_pin": r, "members": rails[r]})
	var gs: Array = by_gpio.keys()
	gs.sort()
	for g in gs:
		var kind := "signal"
		var name := "GPIO%d" % int(g)
		for b in _buses["i2c"]:
			if int(b["sda"]) == int(g):
				kind = "i2c"
				name = "SDA"
			elif int(b["scl"]) == int(g):
				kind = "i2c"
				name = "SCL"
		for b in _buses["spi"]:
			for r in ["sck", "miso", "mosi"]:
				if b.has(r) and int(b[r]) == int(g):
					kind = "spi"
					name = r.to_upper()
		for b in _buses["uart"]:
			for r in ["tx", "rx"]:
				if b.has(r) and int(b[r]) == int(g):
					kind = "uart"
					name = r.to_upper()
		for b in _buses["one_wire"]:
			if int(b["pin"]) == int(g):
				kind = "onewire"
				name = "1-Wire"
		nets.append({"name": name, "kind": kind, "gpio": int(g),
			"board_pin": EspBoards.label_of(_board, int(g)), "members": by_gpio[g]})
	return nets
