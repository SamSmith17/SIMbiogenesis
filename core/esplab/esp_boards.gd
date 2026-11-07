class_name EspBoards
extends RefCounted

## ESPHome-supported development boards as data. A board says which chip it
## carries (EspChips holds the chip's rules), the ESPHome `board:` id, the two
## header rows top to bottom with the antenna / USB end up, what the board
## itself already uses (LED, button, a screen board's display and touch), its
## usual bus pins, and how much its 3V3 regulator can give.
##
## A header pin is written "LABEL=gpio" for a GPIO and plain "LABEL" for power
## and control pins (3V3, 5V, VIN, VBUS, GND, EN, RST, NC…). One GPIO may sit
## on two header pins (the Cheap Yellow Display's IO22).
##
## Sources: Espressif's ESP32-DevKitC V4, ESP32-S3-DevKitC-1 and
## ESP32-C6-DevKitC-1 user guides; DOIT ESP32 DevKit V1 silkscreen; Seeed's
## XIAO ESP32C3 / ESP32S3 wiki pinouts; WEMOS D1 mini and NodeMCU v2 (Amica)
## schematics; Raspberry Pi Pico W datasheet §2.1; the ESP32-2432S028R
## (Cheap Yellow Display) schematic; the LOLIN S2 mini, ESP32-C3-DevKitM-1,
## XIAO ESP32C6, Waveshare ESP32-S3-Zero, LilyGO T-Display-S3, M5Stack ATOM
## Lite and ESP-01 makers' pinouts / schematics. Clones differ: the pin card says so.

const BOARDS := {
	"esp32_devkit_v1": {
		"label": "ESP32 DevKit V1 (30-pin)", "chip": "esp32", "board": "esp32dev",
		"left": ["EN", "VP=36", "VN=39", "D34=34", "D35=35", "D32=32", "D33=33", "D25=25", "D26=26",
			"D27=27", "D14=14", "D12=12", "D13=13", "GND", "VIN"],
		"right": ["D23=23", "D22=22", "TX0=1", "RX0=3", "D21=21", "D19=19", "D18=18", "D5=5",
			"TX2=17", "RX2=16", "D4=4", "D2=2", "D15=15", "GND", "3V3"],
		"onboard": {"led": {"gpio": 2, "inverted": false}, "button": 0},
		"reserved": {},
		"i2c": [21, 22], "spi": {"sck": 18, "miso": 19, "mosi": 23, "cs": 5},
		"reg_ma": 500, "size_mm": [28.0, 52.0], "usb_bridge": true,
	},
	"esp32_devkitc_38": {
		"label": "ESP32-DevKitC (38-pin)", "chip": "esp32", "board": "esp32dev",
		"left": ["3V3", "EN", "VP=36", "VN=39", "IO34=34", "IO35=35", "IO32=32", "IO33=33",
			"IO25=25", "IO26=26", "IO27=27", "IO14=14", "IO12=12", "GND", "IO13=13", "SD2=9",
			"SD3=10", "CMD=11", "5V"],
		"right": ["GND", "IO23=23", "IO22=22", "TX=1", "RX=3", "IO21=21", "GND", "IO19=19",
			"IO18=18", "IO5=5", "IO17=17", "IO16=16", "IO4=4", "IO0=0", "IO2=2", "IO15=15",
			"SD1=8", "SD0=7", "CLK=6"],
		"onboard": {"button": 0},
		"reserved": {},
		"i2c": [21, 22], "spi": {"sck": 18, "miso": 19, "mosi": 23, "cs": 5},
		"reg_ma": 500, "size_mm": [28.0, 55.0], "usb_bridge": true,
	},
	"esp32s3_devkitc1": {
		"label": "ESP32-S3-DevKitC-1", "chip": "esp32s3", "board": "esp32-s3-devkitc-1",
		"left": ["3V3", "3V3", "RST", "4=4", "5=5", "6=6", "7=7", "15=15", "16=16", "17=17", "18=18",
			"8=8", "3=3", "46=46", "9=9", "10=10", "11=11", "12=12", "13=13", "14=14", "5V", "GND"],
		"right": ["GND", "TX=43", "RX=44", "1=1", "2=2", "42=42", "41=41", "40=40", "39=39",
			"38=38", "37=37", "36=36", "35=35", "0=0", "45=45", "48=48", "47=47", "21=21",
			"20=20", "19=19", "GND", "GND"],
		"onboard": {"rgb": 48, "button": 0},
		"reserved": {35: "octal PSRAM on N8R8 / N16R8 modules", 36: "octal PSRAM on N8R8 / N16R8 modules",
			37: "octal PSRAM on N8R8 / N16R8 modules"},
		"i2c": [8, 9], "spi": {"sck": 12, "miso": 13, "mosi": 11, "cs": 10},
		"reg_ma": 800, "size_mm": [26.0, 63.0], "usb_bridge": true,
	},
	"esp32c3_supermini": {
		"label": "ESP32-C3 SuperMini", "chip": "esp32c3", "board": "esp32-c3-devkitm-1",
		"left": ["5=5", "6=6", "7=7", "8=8", "9=9", "10=10", "RX=20", "TX=21"],
		"right": ["5V", "GND", "3V3", "4=4", "3=3", "2=2", "1=1", "0=0"],
		"onboard": {"led": {"gpio": 8, "inverted": true}, "button": 9},
		"reserved": {},
		"i2c": [8, 9], "spi": {"sck": 4, "miso": 5, "mosi": 6, "cs": 7},
		"reg_ma": 500, "size_mm": [18.0, 22.5], "usb_bridge": false,
	},
	"xiao_esp32c3": {
		"label": "Seeed XIAO ESP32C3", "chip": "esp32c3", "board": "seeed_xiao_esp32c3",
		"left": ["D0=2", "D1=3", "D2=4", "D3=5", "D4=6", "D5=7", "D6=21"],
		"right": ["5V", "GND", "3V3", "D10=10", "D9=9", "D8=8", "D7=20"],
		"onboard": {"button": 9},
		"reserved": {},
		"i2c": [6, 7], "spi": {"sck": 8, "miso": 9, "mosi": 10, "cs": 5},
		"reg_ma": 500, "size_mm": [17.5, 21.0], "usb_bridge": false,
	},
	"xiao_esp32s3": {
		"label": "Seeed XIAO ESP32S3", "chip": "esp32s3", "board": "seeed_xiao_esp32s3",
		"left": ["D0=1", "D1=2", "D2=3", "D3=4", "D4=5", "D5=6", "D6=43"],
		"right": ["5V", "GND", "3V3", "D10=9", "D9=8", "D8=7", "D7=44"],
		"onboard": {"led": {"gpio": 21, "inverted": true}},
		"reserved": {},
		"i2c": [5, 6], "spi": {"sck": 7, "miso": 8, "mosi": 9, "cs": 4},
		"reg_ma": 700, "size_mm": [17.5, 21.0], "usb_bridge": false,
	},
	"esp32c6_devkitc1": {
		"label": "ESP32-C6-DevKitC-1", "chip": "esp32c6", "board": "esp32-c6-devkitc-1",
		"left": ["3V3", "RST", "4=4", "5=5", "6=6", "7=7", "0=0", "1=1", "8=8", "10=10", "11=11",
			"2=2", "3=3", "5V", "GND", "NC"],
		"right": ["GND", "TX=16", "RX=17", "15=15", "23=23", "22=22", "21=21", "20=20", "19=19",
			"18=18", "9=9", "GND", "13=13", "12=12", "GND", "NC"],
		"onboard": {"rgb": 8, "button": 9},
		"reserved": {},
		"i2c": [6, 7], "spi": {"sck": 21, "miso": 20, "mosi": 19, "cs": 18},
		"reg_ma": 500, "size_mm": [25.4, 53.0], "usb_bridge": true,
	},
	"wemos_d1_mini": {
		"label": "WEMOS D1 mini (ESP8266)", "chip": "esp8266", "board": "d1_mini",
		"left": ["RST", "A0=17", "D0=16", "D5=14", "D6=12", "D7=13", "D8=15", "3V3"],
		"right": ["TX=1", "RX=3", "D1=5", "D2=4", "D3=0", "D4=2", "GND", "5V"],
		"onboard": {"led": {"gpio": 2, "inverted": true}},
		"reserved": {},
		"i2c": [4, 5], "spi": {"sck": 14, "miso": 12, "mosi": 13, "cs": 15},
		"reg_ma": 500, "size_mm": [25.6, 34.2], "usb_bridge": true,
		"a0_scale": 3.2,
	},
	"nodemcu_v2": {
		"label": "NodeMCU v2 (ESP8266)", "chip": "esp8266", "board": "nodemcuv2",
		"left": ["A0=17", "RSV", "RSV", "SD3=10", "SD2=9", "SD1=8", "CMD=11", "SD0=7", "CLK=6",
			"GND", "3V3", "EN", "RST", "GND", "VIN"],
		"right": ["D0=16", "D1=5", "D2=4", "D3=0", "D4=2", "3V3", "GND", "D5=14", "D6=12",
			"D7=13", "D8=15", "RX=3", "TX=1", "GND", "3V3"],
		"onboard": {"led": {"gpio": 2, "inverted": true}, "button": 0},
		"reserved": {},
		"i2c": [4, 5], "spi": {"sck": 14, "miso": 12, "mosi": 13, "cs": 15},
		"reg_ma": 500, "size_mm": [26.0, 48.0], "usb_bridge": true,
		"a0_scale": 3.3,
	},
	"pico_w": {
		"label": "Raspberry Pi Pico W", "chip": "rp2040", "board": "rpipicow",
		"left": ["GP0=0", "GP1=1", "GND", "GP2=2", "GP3=3", "GP4=4", "GP5=5", "GND", "GP6=6",
			"GP7=7", "GP8=8", "GP9=9", "GND", "GP10=10", "GP11=11", "GP12=12", "GP13=13", "GND",
			"GP14=14", "GP15=15"],
		"right": ["VBUS", "VSYS", "GND", "3V3_EN", "3V3", "ADC_VREF", "GP28=28", "AGND", "GP27=27",
			"GP26=26", "RUN", "GP22=22", "GND", "GP21=21", "GP20=20", "GP19=19", "GP18=18", "GND",
			"GP17=17", "GP16=16"],
		"onboard": {},
		"reserved": {},
		"i2c": [4, 5], "spi": {"sck": 18, "miso": 16, "mosi": 19, "cs": 17},
		"reg_ma": 300, "size_mm": [21.0, 51.0], "usb_bridge": false,
	},
	"cyd_2432s028r": {
		"label": "ESP32 Cheap Yellow Display (2432S028R)", "chip": "esp32", "board": "esp32dev",
		"left": ["VIN", "TX=1", "RX=3", "GND", "GND", "IO35=35", "IO22=22", "IO21=21"],
		"right": ["GND", "IO22=22", "IO27=27", "3V3"],
		"onboard": {"rgb_led": [4, 16, 17], "ldr": 34, "speaker": 26, "button": 0},
		"reserved": {2: "display DC", 12: "display MISO", 13: "display MOSI", 14: "display SCK",
			15: "display CS", 21: "display backlight", 25: "touch CLK", 32: "touch MOSI",
			33: "touch CS", 36: "touch IRQ", 39: "touch MISO", 5: "SD card CS", 18: "SD card SCK",
			19: "SD card MISO", 23: "SD card MOSI", 4: "RGB LED (red)", 16: "RGB LED (green)",
			17: "RGB LED (blue)", 34: "light sensor (LDR)", 26: "speaker"},
		"i2c": [27, 22], "spi": {},
		"reg_ma": 500, "size_mm": [50.0, 86.0], "usb_bridge": true, "screen": "ILI9341 2.8\" 320x240",
	},	"lolin_s2_mini": {
		"label": "WEMOS / LOLIN S2 mini", "chip": "esp32s2", "board": "lolin_s2_mini",
		"left": ["EN", "1=1", "2=2", "3=3", "4=4", "5=5", "6=6", "7=7", "8=8", "9=9", "10=10", "11=11",
			"12=12", "13=13", "14=14", "15=15", "16=16", "3V3"],
		"right": ["VBUS", "GND", "40=40", "39=39", "38=38", "37=37", "36=36", "35=35", "34=34", "33=33",
			"21=21", "18=18", "17=17", "GND"],
		"onboard": {"led": {"gpio": 15, "inverted": false}, "button": 0},
		"reserved": {},
		"i2c": [33, 35], "spi": {"sck": 7, "miso": 9, "mosi": 11, "cs": 12},
		"reg_ma": 600, "size_mm": [25.4, 34.3], "usb_bridge": false,
		"pin_note": "The real board has two rows a side; listed here as one.",
	},
	"esp32c3_devkitm1": {
		"label": "ESP32-C3-DevKitM-1", "chip": "esp32c3", "board": "esp32-c3-devkitm-1",
		"left": ["GND", "3V3", "3V3", "2=2", "3=3", "GND", "RST", "GND", "0=0", "1=1", "10=10", "GND",
			"5V", "5V", "GND"],
		"right": ["GND", "TX=21", "RX=20", "GND", "9=9", "8=8", "GND", "7=7", "6=6", "5=5", "4=4", "GND",
			"18=18", "19=19", "GND"],
		"onboard": {"rgb": 8, "button": 9},
		"reserved": {},
		"i2c": [5, 6], "spi": {"sck": 4, "miso": 3, "mosi": 7, "cs": 10},
		"reg_ma": 500, "size_mm": [25.4, 46.0], "usb_bridge": true,
	},
	"xiao_esp32c6": {
		"label": "Seeed XIAO ESP32C6", "chip": "esp32c6", "board": "esp32-c6-devkitc-1", "flash_size": "4MB",
		"left": ["D0=0", "D1=1", "D2=2", "D3=21", "D4=22", "D5=23", "D6=16"],
		"right": ["5V", "GND", "3V3", "D10=18", "D9=20", "D8=19", "D7=17"],
		"onboard": {"led": {"gpio": 15, "inverted": true}, "button": 9},
		"reserved": {},
		"i2c": [22, 23], "spi": {"sck": 19, "miso": 20, "mosi": 18, "cs": 21},
		"reg_ma": 500, "size_mm": [17.5, 21.0], "usb_bridge": false,
	},
	"waveshare_s3_zero": {
		"label": "Waveshare ESP32-S3-Zero", "chip": "esp32s3", "board": "esp32-s3-devkitc-1", "flash_size": "4MB",
		"left": ["5V", "GND", "3V3", "1=1", "2=2", "3=3", "4=4", "5=5", "6=6"],
		"right": ["TX=43", "RX=44", "13=13", "12=12", "11=11", "10=10", "9=9", "8=8", "7=7"],
		"onboard": {"rgb": 21, "button": 0},
		"reserved": {},
		"i2c": [1, 2], "spi": {"sck": 12, "miso": 13, "mosi": 11, "cs": 10},
		"reg_ma": 500, "size_mm": [18.0, 23.5], "usb_bridge": false,
		"pin_note": "More GPIOs are on pads under the board; only the header is listed.",
	},
	"t_display_s3": {
		"label": "LilyGO T-Display-S3", "chip": "esp32s3", "board": "esp32-s3-devkitc-1", "flash_size": "16MB",
		"left": ["GND", "GND", "5V", "3V3", "43=43", "44=44", "18=18", "17=17", "21=21", "16=16"],
		"right": ["GND", "GND", "3V3", "1=1", "2=2", "3=3", "10=10", "11=11", "12=12", "13=13"],
		"onboard": {"button": 0},
		"reserved": {5: "display RD", 6: "display CS", 7: "display DC", 8: "display WR", 9: "display RST",
			38: "display backlight", 39: "display D0", 40: "display D1", 41: "display D2", 42: "display D3",
			45: "display D4", 46: "display D5", 47: "display D6", 48: "display D7", 15: "display power",
			14: "second button", 4: "battery voltage"},
		"i2c": [43, 44], "spi": {"sck": 12, "miso": 13, "mosi": 11, "cs": 10},
		"reg_ma": 500, "size_mm": [25.0, 62.0], "usb_bridge": false, "screen": "ST7789 1.9\" 170x320 (parallel)",
	},
	"m5stack_atom_lite": {
		"label": "M5Stack ATOM Lite", "chip": "esp32", "board": "m5stack-atom",
		"left": ["3V3", "G22=22", "G19=19", "G23=23", "G33=33"],
		"right": ["5V", "GND", "G21=21", "G25=25", "G26=26", "G32=32"],
		"onboard": {"rgb": 27, "button": 39},
		"reserved": {27: "RGB LED (SK6812)", 12: "IR LED"},
		"i2c": [26, 32], "spi": {"sck": 22, "miso": 23, "mosi": 19, "cs": 33},
		"reg_ma": 500, "size_mm": [24.0, 24.0], "usb_bridge": true,
		"pin_note": "G26 / G32 are the Grove port.",
	},
	"esp01_1m": {
		"label": "ESP-01 / ESP-01S (ESP8266)", "chip": "esp8266", "board": "esp01_1m",
		"left": ["GND", "GPIO2=2", "GPIO0=0", "RX=3"],
		"right": ["TX=1", "EN", "RST", "3V3"],
		"onboard": {"led": {"gpio": 2, "inverted": true}},
		"reserved": {},
		"i2c": [0, 2], "spi": {},
		"reg_ma": 500, "size_mm": [14.3, 24.8], "usb_bridge": false,
		"pin_note": "No regulator: feed it 3.3 V. GPIO0 and GPIO2 must be HIGH at boot.",
	},
}

const POWER_KINDS := {
	"3V3": "3v3", "3V3_EN": "ctrl", "5V": "5v", "VIN": "5v", "VBUS": "5v", "VSYS": "5v",
	"GND": "gnd", "AGND": "gnd", "EN": "ctrl", "RST": "ctrl", "RUN": "ctrl", "NC": "nc",
	"RSV": "nc", "ADC_VREF": "ctrl",
}


## How each board looks in the wiring diagram (the board's own photo, in
## shapes): PCB colour, what sits on it (a WROOM-style module with its PCB
## antenna, a bare chip with a ceramic or PCB antenna, a shield can, an
## ESP-12 module, a screen, a plastic case), the USB socket and which end it
## is on, the buttons, the USB-serial chip and whether it has mounting holes.
const LOOKS := {
	"esp32_devkit_v1": {"pcb": "2c2e33", "module": "wroom", "module_label": "ESP-WROOM-32", "usb": "micro",
		"buttons": ["EN", "BOOT"], "bridge": "CP2102", "reg": true, "leds": ["power", "gpio"], "holes": true},
	"esp32_devkitc_38": {"pcb": "1c1d20", "module": "wroom", "module_label": "ESP32-WROOM-32E", "usb": "micro",
		"buttons": ["EN", "BOOT"], "bridge": "CP2102N", "reg": true, "leds": ["power"]},
	"esp32s3_devkitc1": {"pcb": "1c1d20", "module": "wroom", "module_label": "ESP32-S3-WROOM-1", "usb": "c2",
		"buttons": ["BOOT", "RST"], "bridge": "CP2102N", "reg": true, "leds": ["power", "rgb"]},
	"esp32c3_supermini": {"pcb": "1d2a4f", "module": "chip", "chip_label": "ESP32-C3", "antenna": "pcb", "usb": "c",
		"buttons": ["BOOT", "RST"], "leds": ["gpio"]},
	"xiao_esp32c3": {"pcb": "16213a", "module": "can", "module_label": "XIAO", "usb": "c", "usb_top": true,
		"buttons": ["B", "R"], "leds": ["power"]},
	"xiao_esp32s3": {"pcb": "16213a", "module": "can", "module_label": "XIAO", "usb": "c", "usb_top": true,
		"buttons": ["B", "R"], "leds": ["gpio"]},
	"xiao_esp32c6": {"pcb": "16213a", "module": "can", "module_label": "XIAO", "usb": "c", "usb_top": true,
		"buttons": ["B", "R"], "leds": ["gpio"]},
	"esp32c6_devkitc1": {"pcb": "1c1d20", "module": "wroom", "module_label": "ESP32-C6-WROOM-1", "usb": "c2",
		"buttons": ["BOOT", "RST"], "bridge": "CH343", "reg": true, "leds": ["power", "rgb"]},
	"esp32c3_devkitm1": {"pcb": "1c1d20", "module": "mini_module", "module_label": "ESP32-C3-MINI-1", "usb": "micro",
		"buttons": ["BOOT", "RST"], "bridge": "CP2102N", "reg": true, "leds": ["rgb"]},
	"wemos_d1_mini": {"pcb": "1f3d7a", "module": "esp12", "module_label": "ESP8266MOD", "usb": "micro",
		"buttons": ["RST"], "bridge": "CH340", "leds": []},
	"nodemcu_v2": {"pcb": "1c1d20", "module": "esp12", "module_label": "ESP8266MOD", "usb": "micro",
		"buttons": ["RST", "FLASH"], "bridge": "CP2102", "reg": true, "leds": ["gpio"], "holes": true},
	"pico_w": {"pcb": "1b6b3a", "module": "pico", "chip_label": "RP2040", "usb": "micro", "usb_top": true,
		"buttons": ["BOOTSEL"], "leds": ["gpio"], "castellated": true},
	"cyd_2432s028r": {"pcb": "c9a227", "module": "screen", "screen": "2.8\" ILI9341", "usb": "micro",
		"buttons": ["BOOT", "RST"], "leds": ["rgb"], "holes": true},
	"lolin_s2_mini": {"pcb": "1d2a4f", "module": "chip", "chip_label": "ESP32-S2", "antenna": "pcb", "usb": "c",
		"buttons": ["0", "RST"], "leds": ["gpio"]},
	"waveshare_s3_zero": {"pcb": "1c1d20", "module": "chip", "chip_label": "ESP32-S3", "antenna": "ceramic", "usb": "c",
		"buttons": ["BOOT", "RST"], "leds": ["rgb"]},
	"t_display_s3": {"pcb": "1c1d20", "module": "screen", "screen": "1.9\" ST7789", "usb": "c",
		"buttons": ["BOOT", "KEY"], "leds": []},
	"m5stack_atom_lite": {"pcb": "3b3f46", "module": "atom", "usb": "c", "buttons": [], "leds": ["rgb"]},
	"esp01_1m": {"pcb": "1c1d20", "module": "esp01", "chip_label": "ESP8266EX", "antenna": "pcb", "usb": "",
		"buttons": [], "leds": ["power", "gpio"]},
}


static func look(id: String) -> Dictionary:
	return LOOKS.get(id, {"pcb": "1c1d20", "module": "wroom", "module_label": "ESP32", "usb": "micro", "buttons": []})

static func ids() -> Array:
	var out: Array = BOARDS.keys()
	out.sort()
	return out


static func get_board(id: String) -> Dictionary:
	return BOARDS.get(id, {})


static func chip_of(board: Dictionary) -> Dictionary:
	return EspChips.get_chip(str(board.get("chip", "")))


## Parse one header entry.
static func parse_pin(s: String) -> Dictionary:
	var eq := s.find("=")
	if eq >= 0:
		return {"label": s.substr(0, eq), "gpio": int(s.substr(eq + 1)), "kind": "gpio"}
	return {"label": s, "gpio": -1, "kind": str(POWER_KINDS.get(s, "nc"))}


## Every header pin with its side ("left" / "right") and index from the top.
static func pins(board: Dictionary) -> Array:
	var out: Array = []
	for side in ["left", "right"]:
		var arr: Array = board.get(side, [])
		for i in arr.size():
			var p := parse_pin(str(arr[i]))
			p["side"] = side
			p["index"] = i
			out.append(p)
	return out


## The GPIOs this board brings out to a header pin (each once).
static func header_gpios(board: Dictionary) -> Array:
	var out: Array = []
	for p in pins(board):
		var g := int(p["gpio"])
		if g >= 0 and not out.has(g):
			out.append(g)
	return out


static func has_rail(board: Dictionary, kind: String) -> bool:
	for p in pins(board):
		if str(p["kind"]) == kind:
			return true
	return false


## The header label of a GPIO ("D21"), the first one when it sits on two.
static func label_of(board: Dictionary, g: int) -> String:
	for p in pins(board):
		if int(p["gpio"]) == g:
			return str(p["label"])
	return "GPIO%d" % g


## Why the board itself uses a GPIO ("" = free): the onboard LED / button /
## RGB LED, a screen board's display, touch or SD card.
static func board_use(board: Dictionary, g: int) -> String:
	var res: Dictionary = board.get("reserved", {})
	if res.has(g):
		return str(res[g])
	var ob: Dictionary = board.get("onboard", {})
	var led: Dictionary = ob.get("led", {})
	if not led.is_empty() and int(led.get("gpio", -1)) == g:
		return "onboard LED"
	if int(ob.get("rgb", -1)) == g:
		return "onboard RGB LED"
	if int(ob.get("button", -1)) == g:
		return "BOOT button"
	return ""


## Is a GPIO a hard no for anything the player adds (flash, USB, a screen
## board's display / touch / SD)? The onboard LED / button are soft: scored.
static func hard_reserved(board: Dictionary, g: int) -> bool:
	var chip := chip_of(board)
	if EspChips.is_flash(chip, g) or EspChips.is_usb(chip, g):
		return true
	return (board.get("reserved", {}) as Dictionary).has(g)


## How safe a header pin is to wire, for the diagram's colours:
## free | caveat | input_only | reserved | 3v3 | 5v | gnd | ctrl | nc.
static func pin_state(board: Dictionary, p: Dictionary) -> String:
	var g := int(p.get("gpio", -1))
	if g < 0:
		return str(p.get("kind", "nc"))
	var chip := chip_of(board)
	if hard_reserved(board, g):
		return "reserved"
	if str(chip.get("logger_uart", "")) == "UART0" and (chip.get("console", []) as Array).has(g):
		return "reserved"
	if EspChips.is_input_only(chip, g):
		return "input_only"
	if EspChips.strapping_note(chip, g) != "" or board_use(board, g) != "" \
			or (chip.get("console", []) as Array).has(g) or (chip.get("no_pull", []) as Array).has(g):
		return "caveat"
	return "free"
