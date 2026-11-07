extends TourStop

## The ESP board designer: pick an ESPHome board, add sensors and actuators,
## and the tool wires them to the right pins by protocol, writes the YAML,
## and runs a simulated twin that reports exactly what the real board will.


func _init() -> void:
	id = "esplab"
	title = "ESP board designer"
	chapter = "Build"
	summary = "Pick an ESPHome board, add sensors and actuators, and the tool wires them to the right pins, writes the ESPHome YAML and runs a twin that reports what the real board will."
	how = PackedStringArray(["Library → Structures → ESP board designer (ESPHome)…, or Edit board… on a placed one",
		"Pick a board, click parts to add them: I2C, SPI, UART, 1-Wire and analog pins are chosen for you",
		"Drag a part's pin onto a board pin to wire it yourself; the checks say what is wrong and why",
		"ESPHome YAML: copy it or export the files (Wi-Fi and keys stay in secrets.yaml)",
		"Compare: lay the real board's Home Assistant history over the twin, then calibrate"])
	button = "ESP board designer (ESPHome)…"
	world = "burningman"
	budget_s = 40.0
	hour = 14.0
	blurb = ("Eighteen ESPHome boards (ESP32, S2, S3, C3, C6, ESP8266, Pico W and screen boards) and sixty-odd " +
		"modules, each with its real pinout and its protocol. The tool shares the I2C bus and moves a part " +
		"to its other address on a clash, gives every SPI device its own chip select, keeps the logger's UART " +
		"free, puts analog parts on ADC pins that work with Wi-Fi on, and warns about strapping pins and 5 V " +
		"signals. The YAML it writes passes ESPHome's own validator. A simulated twin names its entities " +
		"exactly as Home Assistant will and reads the world at its spot with each part's own resolution and " +
		"accuracy, so the Compare tab can lay the real board's history over it and write a calibration.")


func run(ctx: TourContext) -> void:
	var main := ctx.main
	if not ctx.require(main != null and main.has_method("open_esplab"), "Main hosts the designer"):
		return
	var ui: Variant = main.call("open_esplab", {})
	await ctx.wait(1.5)
	if not ctx.require(ui != null and is_instance_valid(ui) and bool((ui as CanvasItem).visible), "the designer opened"):
		return
	ui.call("load_builtin", "weather_station")
	ctx.caption("A weather station: the BME280, light sensor and screen share one I2C bus", 3.0)
	await ctx.wait(3.0)
	ui.call("load_builtin", "greenhouse")
	ctx.caption("A greenhouse on an ESP32-S3: CO₂, two soil probes on analog pins, a fan relay", 3.0)
	await ctx.wait(3.0)
	ui.call("load_builtin", "rs485_meter")
	ctx.caption("RS-485, CAN and an ADC on one board: each gets the pins its protocol needs", 3.0)
	await ctx.wait(3.0)
	ui.call("_set_tab", "yaml")
	ctx.caption("The ESPHome YAML it writes, with secrets kept in secrets.yaml", 3.0)
	await ctx.wait(3.0)
	ui.call("_set_tab", "diagram")
	ui.call("load_builtin", "weather_station")
	ctx.caption("The twin's live readings: the weather at your spot, through each part's own accuracy", 3.0)
	await ctx.wait(1.5)
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var main := ctx.main
	if main == null:
		return
	var ui: Variant = main.get("esplab_ui")
	if ui != null and is_instance_valid(ui):
		ui.call("close")
