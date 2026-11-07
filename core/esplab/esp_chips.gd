class_name EspChips
extends RefCounted

## What each microcontroller allows, as data: which GPIOs exist, which are
## input-only, strapping, flash / PSRAM / USB, the ADC units, the counts of
## each peripheral, and where a peripheral's pins may go (any pin through the
## GPIO matrix, or a fixed list). The board files (EspBoards) say which of
## these pins a particular board brings out and what it already uses.
##
## Sources: the Espressif datasheets ("ESP32 Series Datasheet" v4.x §2,
## "ESP32-S2 Series Datasheet" §2, "ESP32-S3 Series Datasheet" §2, "ESP32-C3 Series Datasheet" §2,
## "ESP32-C6 Series Datasheet" §2, "ESP8266EX Datasheet" §4), the RP2040
## datasheet §1.4.3 (GPIO functions), and ESPHome's logger defaults (which
## UART the console takes on each chip). Facts only: no text copied.
##
## Pin-routing model, read by EspAutoWire:
##   "matrix"  every non-reserved GPIO can carry the signal;
##   [[...]]   a list of controllers, each a dict role -> allowed GPIOs
##             (RP2040: I2C0 SDA is GP0/4/8/12/16/20 and so on).

const ALL := ["esp32", "esp32s2", "esp32s3", "esp32c3", "esp32c6", "esp8266", "rp2040"]

const CHIPS := {
	"esp32": {
		"label": "ESP32", "platform": "esp32", "variant": "",
		"gpios": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
			21, 22, 23, 25, 26, 27, 32, 33, 34, 35, 36, 37, 38, 39],
		"input_only": [34, 35, 36, 37, 38, 39],
		"no_pull": [34, 35, 36, 37, 38, 39],
		"strapping": {0: "boot mode: must be HIGH at reset or the board waits for a download",
			2: "boot mode: must be LOW or floating at reset",
			5: "SDIO timing at reset (usually fine)",
			12: "flash voltage: HIGH at reset makes a 3.3 V-flash module fail to boot",
			15: "boot log on/off at reset (usually fine)"},
		"flash": [6, 7, 8, 9, 10, 11],
		"usb": [],
		"console": [1, 3],
		"adc1": [32, 33, 34, 35, 36, 37, 38, 39],
		"adc2": [0, 2, 4, 12, 13, 14, 15, 25, 26, 27],
		"adc2_dead_with_wifi": true,
		"adc_max_v": 3.1,
		"dac": [25, 26],
		"i2c_buses": 2, "uarts": 3, "uarts_free": 2, "spi_hosts": 2,
		"rmt": 8, "ledc": 16, "pcnt": 8, "i2s": 2,
		"i2c_pins": "matrix", "spi_pins": "matrix", "uart_pins": "matrix",
		"logger_uart": "UART0", "wifi": true, "base_ma": 240,
	},
	"esp32s2": {
		"label": "ESP32-S2", "platform": "esp32", "variant": "esp32s2",
		"gpios": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
			26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46],
		"input_only": [46],
		"no_pull": [46],
		"strapping": {0: "boot mode: must be HIGH at reset", 45: "flash voltage: HIGH at reset breaks 3.3 V flash",
			46: "boot mode / ROM log at reset (input only)"},
		"flash": [26, 27, 28, 29, 30, 31, 32],
		"usb": [19, 20],
		"console": [43, 44],
		"adc1": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
		"adc2": [11, 12, 13, 14, 15, 16, 17, 18, 19, 20],
		"adc2_dead_with_wifi": true,
		"adc_max_v": 2.5,
		"dac": [17, 18],
		"i2c_buses": 2, "uarts": 2, "uarts_free": 2, "spi_hosts": 2,
		"rmt": 4, "ledc": 8, "pcnt": 4, "i2s": 1,
		"i2c_pins": "matrix", "spi_pins": "matrix", "uart_pins": "matrix",
		"logger_uart": "USB_CDC", "wifi": true, "base_ma": 200,
	},
	"esp32s3": {
		"label": "ESP32-S3", "platform": "esp32", "variant": "esp32s3",
		"gpios": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
			21, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43,
			44, 45, 46, 47, 48],
		"input_only": [],
		"no_pull": [],
		"strapping": {0: "boot mode: must be HIGH at reset", 3: "JTAG source at reset (usually fine)",
			45: "flash voltage: HIGH at reset breaks 3.3 V flash",
			46: "boot mode: must be LOW at reset"},
		"flash": [26, 27, 28, 29, 30, 31, 32],
		"usb": [19, 20],
		"console": [43, 44],
		"adc1": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
		"adc2": [11, 12, 13, 14, 15, 16, 17, 18, 19, 20],
		"adc2_dead_with_wifi": true,
		"adc_max_v": 3.1,
		"dac": [],
		"i2c_buses": 2, "uarts": 3, "uarts_free": 3, "spi_hosts": 2,
		"rmt": 4, "ledc": 8, "pcnt": 4, "i2s": 2,
		"i2c_pins": "matrix", "spi_pins": "matrix", "uart_pins": "matrix",
		"logger_uart": "USB_SERIAL_JTAG", "wifi": true, "base_ma": 240,
	},
	"esp32c3": {
		"label": "ESP32-C3", "platform": "esp32", "variant": "esp32c3",
		"gpios": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21],
		"input_only": [],
		"no_pull": [],
		"strapping": {2: "boot mode: must be HIGH at reset", 8: "boot mode: must be HIGH at reset",
			9: "boot mode: LOW at reset enters download mode (the BOOT button)"},
		"flash": [11, 12, 13, 14, 15, 16, 17],
		"usb": [18, 19],
		"console": [20, 21],
		"adc1": [0, 1, 2, 3, 4],
		"adc2": [5],
		"adc2_dead_with_wifi": true,
		"adc_max_v": 2.5,
		"dac": [],
		"i2c_buses": 1, "uarts": 2, "uarts_free": 2, "spi_hosts": 1,
		"rmt": 2, "ledc": 6, "pcnt": 0, "i2s": 1,
		"i2c_pins": "matrix", "spi_pins": "matrix", "uart_pins": "matrix",
		"logger_uart": "USB_SERIAL_JTAG", "wifi": true, "base_ma": 200,
	},
	"esp32c6": {
		"label": "ESP32-C6", "platform": "esp32", "variant": "esp32c6",
		"gpios": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
			21, 22, 23, 24, 25, 26, 27, 28, 29, 30],
		"input_only": [],
		"no_pull": [],
		"strapping": {4: "JTAG source at reset (usually fine)", 5: "JTAG source at reset (usually fine)",
			8: "boot mode: must be HIGH at reset", 9: "boot mode: LOW at reset enters download mode",
			15: "JTAG source at reset (usually fine)"},
		"flash": [24, 25, 26, 27, 28, 29, 30],
		"usb": [12, 13],
		"console": [16, 17],
		"adc1": [0, 1, 2, 3, 4, 5, 6],
		"adc2": [],
		"adc2_dead_with_wifi": false,
		"adc_max_v": 3.1,
		"dac": [],
		"i2c_buses": 1, "uarts": 2, "uarts_free": 2, "spi_hosts": 1,
		"rmt": 2, "ledc": 6, "pcnt": 4, "i2s": 1,
		"i2c_pins": "matrix", "spi_pins": "matrix", "uart_pins": "matrix",
		"logger_uart": "USB_SERIAL_JTAG", "wifi": true, "base_ma": 200,
		"framework": "esp-idf",
	},
	"esp8266": {
		"label": "ESP8266", "platform": "esp8266", "variant": "",
		"gpios": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17],
		"input_only": [17],
		"no_pull": [16],
		"strapping": {0: "boot mode: must be HIGH at reset (pull-up on most boards)",
			2: "boot mode: must be HIGH at reset; also the blue LED",
			15: "boot mode: must be LOW at reset (pull-down on most boards)"},
		"flash": [6, 7, 8, 9, 10, 11],
		"usb": [],
		"console": [1, 3],
		"adc1": [17],
		"adc2": [],
		"adc2_dead_with_wifi": false,
		"adc_max_v": 3.2,
		"dac": [],
		"i2c_buses": 1, "uarts": 1, "uarts_free": 0, "spi_hosts": 1,
		"rmt": 0, "ledc": 0, "pcnt": -1, "i2s": 0,
		"i2c_pins": "matrix", "spi_pins": "matrix", "uart_pins": "matrix",
		"logger_uart": "UART0", "wifi": true, "base_ma": 170,
		# GPIO16 has no interrupt and no I2C clock-stretching; 17 is the A0 pin,
		# which reads a voltage and nothing else.
		"no_interrupt": [16, 17],
		"analog_only": [17],
	},
	"rp2040": {
		"label": "RP2040", "platform": "rp2", "variant": "",
		"gpios": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
			21, 22, 26, 27, 28],
		"input_only": [],
		"no_pull": [],
		"strapping": {},
		"flash": [],
		"usb": [],
		"console": [],
		"adc1": [26, 27, 28],
		"adc2": [],
		"adc2_dead_with_wifi": false,
		"adc_max_v": 3.3,
		"dac": [],
		"i2c_buses": 2, "uarts": 2, "uarts_free": 2, "spi_hosts": 2,
		"rmt": 0, "ledc": 16, "pcnt": -1, "i2s": 0, "pio": 8,
		"i2c_pins": [
			{"sda": [0, 4, 8, 12, 16, 20], "scl": [1, 5, 9, 13, 17, 21]},
			{"sda": [2, 6, 10, 14, 18, 26], "scl": [3, 7, 11, 15, 19, 27]}],
		"spi_pins": [
			{"miso": [0, 4, 16, 20], "sck": [2, 6, 18, 22], "mosi": [3, 7, 19]},
			{"miso": [8, 12, 28], "sck": [10, 14, 26], "mosi": [11, 15, 27]}],
		"uart_pins": [
			{"tx": [0, 12, 16, 28], "rx": [1, 13, 17]},
			{"tx": [4, 8, 20], "rx": [5, 9, 21]}],
		"logger_uart": "USB_CDC", "wifi": true, "base_ma": 150,
	},
}


static func get_chip(id: String) -> Dictionary:
	return CHIPS.get(id, {})


static func has_gpio(chip: Dictionary, g: int) -> bool:
	return (chip.get("gpios", []) as Array).has(g)


static func is_input_only(chip: Dictionary, g: int) -> bool:
	return (chip.get("input_only", []) as Array).has(g)


static func is_flash(chip: Dictionary, g: int) -> bool:
	return (chip.get("flash", []) as Array).has(g)


static func is_usb(chip: Dictionary, g: int) -> bool:
	return (chip.get("usb", []) as Array).has(g)


static func strapping_note(chip: Dictionary, g: int) -> String:
	return str((chip.get("strapping", {}) as Dictionary).get(g, ""))


static func is_adc(chip: Dictionary, g: int, wifi_on: bool) -> bool:
	if (chip.get("adc1", []) as Array).has(g):
		return true
	if (chip.get("adc2", []) as Array).has(g):
		return not (wifi_on and bool(chip.get("adc2_dead_with_wifi", false)))
	return false


## The routing table for a peripheral ("i2c" / "spi" / "uart"): "matrix", or
## the controller list.
static func routing(chip: Dictionary, periph: String) -> Variant:
	return chip.get(periph + "_pins", "matrix")


## The ESPHome pin name for a GPIO on this chip (the ESP8266's analog pin is A0).
static func pin_name(chip_id: String, g: int) -> String:
	if chip_id == "esp8266" and g == 17:
		return "A0"
	return "GPIO%d" % g


## What a GPIO can do, in words, for the pin card.
static func functions_of(chip_id: String, g: int) -> PackedStringArray:
	var c := get_chip(chip_id)
	var out := PackedStringArray()
	if c.is_empty() or not has_gpio(c, g):
		return out
	if is_flash(c, g):
		out.append("connected to the flash chip: never use")
		return out
	if is_usb(c, g):
		out.append("USB D%s" % ("-" if g == (c["usb"] as Array)[0] else "+"))
	if (c.get("console", []) as Array).has(g):
		out.append("serial console " + ("TX" if g == (c["console"] as Array)[0] else "RX"))
	if is_input_only(c, g):
		out.append("input only")
	if (c.get("no_pull", []) as Array).has(g):
		out.append("no internal pull-up")
	if (c.get("adc1", []) as Array).has(g):
		out.append("analog in (ADC1)")
	if (c.get("adc2", []) as Array).has(g):
		out.append("analog in (ADC2%s)" % (", not while Wi-Fi is on" if bool(c.get("adc2_dead_with_wifi", false)) else ""))
	if (c.get("dac", []) as Array).has(g):
		out.append("analog out (DAC)")
	var s := strapping_note(c, g)
	if s != "":
		out.append("strapping pin: " + s)
	if not is_input_only(c, g):
		out.append("digital in / out, PWM")
	return out
