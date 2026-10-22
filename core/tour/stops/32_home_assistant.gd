extends TourStop

## Home Assistant Live links, against a stand-in Home Assistant on 127.0.0.1
## (HaFakeServer) so the tour never touches a real one.

var _srv: Node = null
var _linker: Node = null


func _init() -> void:
	id = "home_assistant"
	title = "Home Assistant live links"
	chapter = "Systems"
	summary = "Connect your Home Assistant and link any sensor to any value the simulation tracks."
	how = PackedStringArray(["Settings → Home Assistant: address + long-lived token → Connect",
		"Live links: pick a value, click the sensor that measures it",
		"Turn on Live mode and linked values follow your real system"])
	button = "HA"
	world = "mtvernon"
	budget_s = 40.0
	hour = 13.0
	blurb = ("Type your Home Assistant's address the way a browser shows it and paste a " +
		"long-lived token; the status card shows each step as it happens and offers the " +
		"right address when the port is wrong. Live links ties any HA sensor to any value " +
		"the simulation tracks — the battery, solar, a load, a tank, the weather — with " +
		"the units converted. In Live mode the simulation follows your real system; at any " +
		"speed the readings are recorded beside it on the timeline.")


func run(ctx: TourContext) -> void:
	var svc := ctx.autoload("HomeAssistant")
	var fake := ctx.klass("HaFakeServer")
	if not ctx.require(svc != null and fake != null, "the Home Assistant service exists"):
		return
	var tok := "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJ0b3VyMDEyMzQ1Njc4OWFiY2RlZjAxMjMiLCJpYXQiOjE3MDAwMDAwMDB9.tourtourtourtourtourtourtourtourtourtour_-xy"
	_srv = fake.new()
	_srv.set("token", tok)
	_srv.set("location_name", "Home")
	_srv.call("set_entity", "sensor.inverter_battery_soc", "78", {"unit_of_measurement": "%", "device_class": "battery", "friendly_name": "Inverter battery"})
	_srv.call("set_entity", "sensor.inverter_pv_power", "3120", {"unit_of_measurement": "W", "device_class": "power", "friendly_name": "PV power"})
	_srv.call("set_entity", "sensor.inverter_load_power", "860", {"unit_of_measurement": "W", "device_class": "power", "friendly_name": "House load"})
	_srv.call("set_entity", "sensor.station_temperature", "61", {"unit_of_measurement": "°F", "device_class": "temperature", "friendly_name": "Weather station temperature"})
	_srv.call("set_entity", "sensor.shed_battery", "51", {"unit_of_measurement": "%", "device_class": "battery", "friendly_name": "Shed battery"})
	ctx.main.add_child(_srv)
	var port := int(_srv.call("start", 39100))
	if not ctx.require(port > 0, "a stand-in Home Assistant is listening"):
		return
	svc.call("connect_with", "127.0.0.1:%d" % port, tok, "Home", false)
	var t0 := Time.get_ticks_msec()
	while not bool(svc.call("is_authed")) and Time.get_ticks_msec() - t0 < 5000:
		await ctx.wait(0.1)
	ctx.require(bool(svc.call("is_authed")), "connected")
	var g: Node = ctx.main.get_node_or_null("UILayer/SystemGraphView")
	_linker = g.get("_ha_linker") if g != null else null
	if not ctx.require(_linker != null, "the link runtime exists"):
		return
	_linker.call("link_entity", "sensor.inverter_pv_power", "site.solar_kw")
	_linker.call("link_entity", "sensor.inverter_load_power", "site.load_kw")
	_linker.call("link_entity", "sensor.station_temperature", "weather.temp_c")
	_linker.call("link_entity", "sensor.inverter_battery_soc", "site.battery_soc")
	ctx.caption("Pick a value, click the sensor that measures it", 3.0)
	ctx.main.call("open_ha_links", "site.battery_soc")
	await ctx.wait(3.0)
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var m: Node = ctx.main.get_node_or_null("HaLinksModal") if ctx.main != null else null
	if m != null:
		var frame: Variant = m.get("_frame")
		if frame != null:
			frame.call("close")
	if _linker != null:
		for tid in ["site.solar_kw", "site.load_kw", "weather.temp_c", "site.battery_soc"]:
			_linker.call("unlink_target", tid)
	var svc := ctx.autoload("HomeAssistant")
	if svc != null:
		svc.call("disconnect_ha")
	if _srv != null and is_instance_valid(_srv):
		_srv.call("stop")
		_srv.queue_free()
