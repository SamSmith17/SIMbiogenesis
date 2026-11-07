class_name EspParts
extends RefCounted

## The sensors, actuators and breakouts a player can add, as data.
##
## A part says:
##   iface    how it talks: i2c, spi, uart, onewire, gpio, adc, pulse, led
##            (a WS2812 data line), pwm, hx711 (two plain GPIOs)
##   addr     I2C addresses it can take, in order of preference
##   supply   3v3 | 5v | any (any = wired to 3V3 so its logic stays 3.3 V)
##   logic5   true when its signal TO the board swings to 5 V (needs a divider
##            or level shifter on a 3.3 V chip)
##   ma       typical supply current, mA (the 3V3 / 5V budget)
##   pins     [label, role, yaml key]: roles are from the PART's side —
##            vcc gnd sda scl sck miso mosi cs, tx (the part transmits: goes
##            to the board's RX), rx, out (part → board digital), in (board →
##            part digital), data (both ways on one wire), aout (analog out of
##            the part), pulse, led, pwm
##   pullup   roles that need a pull-up resistor
##   chips    chip id prefixes the part works with (absent = every chip):
##            the CAN controller and I2S are ESP32-family only in ESPHome
##   note     a caveat shown on the part's card
##   uart     {baud, use: rx | tx | both}
##   yaml     {dom, platform, fields}: the ESPHome block; `special` names an
##            emitter in EspYaml for blocks that are not one list entry
##   update   default update_interval, s (0 = event driven / none)
##   ents     the entities it makes: k (and `sub`, the YAML key under the
##            block, "" = the block itself is the entity), name, kind
##            (default = yaml dom), unit, dc (device_class), sc
##            (state_class), dec (accuracy_decimals), set (keys EspYaml must
##            write because the platform's own default differs), src (what
##            the twin measures), and the twin's error model: res
##            (resolution), acc (± absolute accuracy, a fixed per-unit bias
##            within it), acc_pct (± relative), noise (per-reading sd), lo / hi
##            (range), tau (response time constant, s)
##
## Units, device classes and decimals are what the ESPHome platform sends to
## Home Assistant, so the twin's entities look exactly like the real ones.
## Sources: each maker's datasheet (accuracy / resolution / range / address)
## and the ESPHome component reference (config keys, facts only).

const CATEGORIES := [
	["env", "Temperature & humidity"], ["air", "Air quality"], ["light", "Light"],
	["power", "Power"], ["distance", "Distance & presence"], ["water", "Water & soil"],
	["wx", "Rain & wind"], ["weight", "Weight & position"], ["actuator", "Actuators"], ["input", "Inputs"],
	["display", "Displays"], ["io", "I/O & comms"],
]

const PARTS := {
	# ---------------------------------------------------------------- env
	"bme280": {
		"label": "BME280", "cat": "env", "desc": "Temperature, humidity and pressure (Bosch).",
		"iface": "i2c", "addr": [0x76, 0x77], "addr_note": "SDO to GND = 0x76, to VCC = 0x77",
		"supply": "3v3", "ma": 1.0, "price": 4.5,
		"pins": [["VIN", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "sensor", "platform": "bme280_i2c"}, "update": 60,
		"ents": [
			{"k": "temperature", "sub": "temperature", "name": "Temperature", "unit": "°C", "dc": "temperature",
				"sc": "measurement", "dec": 1, "src": "air.temp_c", "res": 0.01, "acc": 1.0, "noise": 0.02, "lo": -40.0, "hi": 85.0},
			{"k": "pressure", "sub": "pressure", "name": "Pressure", "unit": "hPa", "dc": "atmospheric_pressure",
				"sc": "measurement", "dec": 1, "src": "air.pressure_hpa", "res": 0.01, "acc": 1.0, "noise": 0.03, "lo": 300.0, "hi": 1100.0},
			{"k": "humidity", "sub": "humidity", "name": "Humidity", "unit": "%", "dc": "humidity",
				"sc": "measurement", "dec": 1, "src": "air.rh_pct", "res": 0.01, "acc": 3.0, "noise": 0.1, "lo": 0.0, "hi": 100.0, "tau": 1.0},
		],
		"src_doc": "Bosch BME280 datasheet BST-BME280-DS002 §1",
	},
	"bmp280": {
		"label": "BMP280", "cat": "env", "desc": "Temperature and pressure (no humidity).",
		"iface": "i2c", "addr": [0x76, 0x77], "addr_note": "SDO to GND = 0x76, to VCC = 0x77",
		"supply": "3v3", "ma": 1.0, "price": 2.0,
		"pins": [["VCC", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "sensor", "platform": "bmp280_i2c"}, "update": 60,
		"ents": [
			{"k": "temperature", "sub": "temperature", "name": "Temperature", "unit": "°C", "dc": "temperature",
				"sc": "measurement", "dec": 1, "src": "air.temp_c", "res": 0.01, "acc": 1.0, "noise": 0.02, "lo": -40.0, "hi": 85.0},
			{"k": "pressure", "sub": "pressure", "name": "Pressure", "unit": "hPa", "dc": "atmospheric_pressure",
				"sc": "measurement", "dec": 1, "src": "air.pressure_hpa", "res": 0.01, "acc": 1.0, "noise": 0.03, "lo": 300.0, "hi": 1100.0},
		],
		"src_doc": "Bosch BMP280 datasheet BST-BMP280-DS001 §1",
	},
	"aht20": {
		"label": "AHT20", "cat": "env", "desc": "Temperature and humidity (Aosong).",
		"iface": "i2c", "addr": [0x38], "supply": "3v3", "ma": 0.5, "price": 1.5,
		"pins": [["VIN", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "sensor", "platform": "aht10", "fields": {"variant": "AHT20"}}, "update": 60,
		"ents": [
			{"k": "temperature", "sub": "temperature", "name": "Temperature", "unit": "°C", "dc": "temperature",
				"sc": "measurement", "dec": 2, "src": "air.temp_c", "res": 0.01, "acc": 0.3, "noise": 0.02, "lo": -40.0, "hi": 85.0},
			{"k": "humidity", "sub": "humidity", "name": "Humidity", "unit": "%", "dc": "humidity",
				"sc": "measurement", "dec": 2, "src": "air.rh_pct", "res": 0.024, "acc": 2.0, "noise": 0.1, "lo": 0.0, "hi": 100.0, "tau": 8.0},
		],
		"src_doc": "Aosong AHT20 datasheet v1.0 §4",
	},
	"sht31": {
		"label": "SHT31", "cat": "env", "desc": "Temperature and humidity (Sensirion).",
		"iface": "i2c", "addr": [0x44, 0x45], "addr_note": "ADDR to GND = 0x44, to VCC = 0x45",
		"supply": "3v3", "ma": 0.8, "price": 6.0,
		"pins": [["VIN", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "sensor", "platform": "sht3xd"}, "update": 60,
		"ents": [
			{"k": "temperature", "sub": "temperature", "name": "Temperature", "unit": "°C", "dc": "temperature",
				"sc": "measurement", "dec": 1, "src": "air.temp_c", "res": 0.015, "acc": 0.3, "noise": 0.02, "lo": -40.0, "hi": 125.0},
			{"k": "humidity", "sub": "humidity", "name": "Humidity", "unit": "%", "dc": "humidity",
				"sc": "measurement", "dec": 1, "src": "air.rh_pct", "res": 0.01, "acc": 2.0, "noise": 0.08, "lo": 0.0, "hi": 100.0, "tau": 8.0},
		],
		"src_doc": "Sensirion SHT3x-DIS datasheet v6 §2",
	},
	"sht40": {
		"label": "SHT40", "cat": "env", "desc": "Temperature and humidity (Sensirion, newest).",
		"iface": "i2c", "addr": [0x44], "supply": "3v3", "ma": 0.4, "price": 5.0,
		"pins": [["VIN", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "sensor", "platform": "sht4x"}, "update": 60,
		"ents": [
			{"k": "temperature", "sub": "temperature", "name": "Temperature", "unit": "°C", "dc": "temperature",
				"sc": "measurement", "dec": 1, "src": "air.temp_c", "res": 0.01, "acc": 0.2, "noise": 0.01, "lo": -40.0, "hi": 125.0},
			{"k": "humidity", "sub": "humidity", "name": "Humidity", "unit": "%", "dc": "humidity",
				"sc": "measurement", "dec": 1, "src": "air.rh_pct", "res": 0.01, "acc": 1.8, "noise": 0.08, "lo": 0.0, "hi": 100.0, "tau": 4.0},
		],
		"src_doc": "Sensirion SHT4x datasheet v6.5 §2",
	},
	"dht22": {
		"short": "DHT22", "label": "DHT22 / AM2302", "cat": "env", "desc": "Temperature and humidity on one wire (slow, cheap).",
		"iface": "gpio", "supply": "any", "ma": 1.5, "price": 3.0,
		"pins": [["VCC", "vcc"], ["DATA", "data", "pin"], ["GND", "gnd"]], "pullup": ["data"],
		"yaml": {"dom": "sensor", "platform": "dht", "fields": {"model": "DHT22"}}, "update": 60,
		"ents": [
			{"k": "temperature", "sub": "temperature", "name": "Temperature", "unit": "°C", "dc": "temperature",
				"sc": "measurement", "dec": 1, "src": "air.temp_c", "res": 0.1, "acc": 0.5, "noise": 0.05, "lo": -40.0, "hi": 80.0},
			{"k": "humidity", "sub": "humidity", "name": "Humidity", "unit": "%", "dc": "humidity",
				"sc": "measurement", "dec": 0, "src": "air.rh_pct", "res": 0.1, "acc": 2.0, "noise": 0.3, "lo": 0.0, "hi": 100.0, "tau": 6.0},
		],
		"min_update": 2, "src_doc": "Aosong AM2302 datasheet §3",
	},
	"dht11": {
		"label": "DHT11", "cat": "env", "desc": "Temperature and humidity, coarse (±2 °C).",
		"iface": "gpio", "supply": "any", "ma": 1.0, "price": 1.0,
		"pins": [["VCC", "vcc"], ["DATA", "data", "pin"], ["GND", "gnd"]], "pullup": ["data"],
		"yaml": {"dom": "sensor", "platform": "dht", "fields": {"model": "DHT11"}}, "update": 60,
		"ents": [
			{"k": "temperature", "sub": "temperature", "name": "Temperature", "unit": "°C", "dc": "temperature",
				"sc": "measurement", "dec": 1, "src": "air.temp_c", "res": 1.0, "acc": 2.0, "noise": 0.2, "lo": 0.0, "hi": 50.0},
			{"k": "humidity", "sub": "humidity", "name": "Humidity", "unit": "%", "dc": "humidity",
				"sc": "measurement", "dec": 0, "src": "air.rh_pct", "res": 1.0, "acc": 5.0, "noise": 0.5, "lo": 20.0, "hi": 90.0, "tau": 10.0},
		],
		"min_update": 2, "src_doc": "Aosong DHT11 datasheet §2",
	},
	"ds18b20": {
		"label": "DS18B20", "cat": "env", "desc": "Waterproof temperature probe on a 1-Wire bus (many share one pin).",
		"iface": "onewire", "supply": "any", "ma": 1.5, "price": 2.5,
		"pins": [["VDD", "vcc"], ["DQ", "data"], ["GND", "gnd"]], "pullup": ["data"],
		"yaml": {"dom": "sensor", "platform": "dallas_temp"}, "update": 60,
		"ents": [
			{"k": "temperature", "sub": "", "name": "Temperature", "unit": "°C", "dc": "temperature",
				"sc": "measurement", "dec": 1, "src": "air.temp_c", "res": 0.0625, "acc": 0.5, "noise": 0.02, "lo": -55.0, "hi": 125.0, "tau": 20.0},
		],
		"src_doc": "Analog Devices DS18B20 datasheet 19-7487 §1",
	},
	"max6675": {
		"short": "MAX6675", "label": "MAX6675 + K thermocouple", "cat": "env", "desc": "Hot things to 1024 °C (stoves, kilns, the biochar reactor).",
		"iface": "spi", "supply": "any", "ma": 1.5, "price": 4.0,
		"pins": [["GND", "gnd"], ["VCC", "vcc"], ["SCK", "sck"], ["CS", "cs", "cs_pin"], ["SO", "miso"]],
		"yaml": {"dom": "sensor", "platform": "max6675"}, "update": 60,
		"ents": [
			{"k": "temperature", "sub": "", "name": "Thermocouple", "unit": "°C", "dc": "temperature",
				"sc": "measurement", "dec": 1, "src": "probe.temp_c", "res": 0.25, "acc": 2.0, "noise": 0.25, "lo": 0.0, "hi": 1024.0, "tau": 3.0},
		],
		"src_doc": "Maxim MAX6675 datasheet 19-2235 §1",
	},
	# ---------------------------------------------------------------- air
	"scd40": {
		"label": "SCD40", "cat": "air", "desc": "True CO₂ (photoacoustic), plus temperature and humidity.",
		"iface": "i2c", "addr": [0x62], "supply": "any", "ma": 18.0, "price": 30.0,
		"pins": [["VIN", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "sensor", "platform": "scd4x"}, "update": 60,
		"ents": [
			{"k": "co2", "sub": "co2", "name": "CO2", "unit": "ppm", "dc": "carbon_dioxide", "sc": "measurement",
				"dec": 0, "src": "air.co2_ppm", "res": 1.0, "acc": 50.0, "acc_pct": 5.0, "noise": 5.0, "lo": 400.0, "hi": 2000.0},
			{"k": "temperature", "sub": "temperature", "name": "Temperature", "unit": "°C", "dc": "temperature",
				"sc": "measurement", "dec": 1, "src": "air.temp_c", "res": 0.01, "acc": 0.8, "noise": 0.03, "lo": -10.0, "hi": 60.0},
			{"k": "humidity", "sub": "humidity", "name": "Humidity", "unit": "%", "dc": "humidity",
				"sc": "measurement", "dec": 1, "src": "air.rh_pct", "res": 0.01, "acc": 6.0, "noise": 0.2, "lo": 0.0, "hi": 100.0},
		],
		"src_doc": "Sensirion SCD4x datasheet v1.3 §1",
	},
	"sgp30": {
		"label": "SGP30", "cat": "air", "desc": "TVOC and estimated CO₂ (eCO₂, not true CO₂).",
		"iface": "i2c", "addr": [0x58], "supply": "3v3", "ma": 48.0, "price": 9.0,
		"pins": [["VIN", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "sensor", "platform": "sgp30"}, "update": 1,
		"ents": [
			{"k": "eco2", "sub": "eco2", "name": "eCO2", "unit": "ppm", "dc": "carbon_dioxide", "sc": "measurement",
				"dec": 0, "src": "air.eco2_ppm", "res": 1.0, "acc_pct": 15.0, "noise": 10.0, "lo": 400.0, "hi": 60000.0},
			{"k": "tvoc", "sub": "tvoc", "name": "TVOC", "unit": "ppb", "dc": "volatile_organic_compounds_parts",
				"sc": "measurement", "dec": 0, "src": "air.tvoc_ppb", "res": 1.0, "acc_pct": 15.0, "noise": 5.0, "lo": 0.0, "hi": 60000.0},
		],
		"src_doc": "Sensirion SGP30 datasheet v1.0 §1",
	},
	"pms5003": {
		"label": "PMS5003", "cat": "air", "desc": "Particulates PM1 / PM2.5 / PM10 (laser counter, needs 5 V).",
		"iface": "uart", "uart": {"baud": 9600, "use": "both"}, "supply": "5v", "ma": 100.0, "price": 18.0,
		"pins": [["VCC", "vcc"], ["GND", "gnd"], ["TX", "tx"], ["RX", "rx"]],
		"yaml": {"dom": "sensor", "platform": "pmsx003", "fields": {"type": "PMSX003"}}, "update": 60,
		"ents": [
			{"k": "pm_1_0", "sub": "pm_1_0", "name": "PM1.0", "unit": "µg/m³", "dc": "pm1", "sc": "measurement",
				"dec": 0, "src": "air.pm1_ugm3", "res": 1.0, "acc": 10.0, "noise": 1.5, "lo": 0.0, "hi": 1000.0},
			{"k": "pm_2_5", "sub": "pm_2_5", "name": "PM2.5", "unit": "µg/m³", "dc": "pm25", "sc": "measurement",
				"dec": 0, "src": "air.pm25_ugm3", "res": 1.0, "acc": 10.0, "noise": 2.0, "lo": 0.0, "hi": 1000.0},
			{"k": "pm_10_0", "sub": "pm_10_0", "name": "PM10", "unit": "µg/m³", "dc": "pm10", "sc": "measurement",
				"dec": 0, "src": "air.pm10_ugm3", "res": 1.0, "acc": 15.0, "noise": 3.0, "lo": 0.0, "hi": 1000.0},
		],
		"src_doc": "Plantower PMS5003 manual v2.3 §3",
	},
	"mhz19b": {
		"short": "MH-Z19B", "label": "MH-Z19B", "cat": "air", "desc": "CO₂ by infrared (NDIR), 5 V supply, 3.3 V serial.",
		"iface": "uart", "uart": {"baud": 9600, "use": "both"}, "supply": "5v", "ma": 60.0, "price": 18.0,
		"pins": [["Vin", "vcc"], ["GND", "gnd"], ["TX", "tx"], ["RX", "rx"]],
		"yaml": {"dom": "sensor", "platform": "mhz19"}, "update": 60,
		"ents": [
			{"k": "co2", "sub": "co2", "name": "CO2", "unit": "ppm", "dc": "carbon_dioxide", "sc": "measurement",
				"dec": 0, "src": "air.co2_ppm", "res": 1.0, "acc": 50.0, "acc_pct": 5.0, "noise": 8.0, "lo": 0.0, "hi": 5000.0, "tau": 60.0},
			{"k": "temperature", "sub": "temperature", "name": "Temperature", "unit": "°C", "dc": "temperature",
				"sc": "measurement", "dec": 0, "src": "air.temp_c", "res": 1.0, "acc": 2.0, "noise": 0.3, "lo": -10.0, "hi": 60.0},
		],
		"src_doc": "Winsen MH-Z19B manual v1.0 §2",
	},
	# ---------------------------------------------------------------- light
	"bh1750": {
		"label": "BH1750", "cat": "light", "desc": "Illuminance in lux (to 65 000 lx).",
		"iface": "i2c", "addr": [0x23, 0x5C], "addr_note": "ADDR to GND = 0x23, to VCC = 0x5C",
		"supply": "3v3", "ma": 0.2, "price": 1.5,
		"pins": [["VCC", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"], ["ADDR", "nc"]],
		"yaml": {"dom": "sensor", "platform": "bh1750"}, "update": 60,
		"ents": [
			{"k": "illuminance", "sub": "", "name": "Illuminance", "unit": "lx", "dc": "illuminance", "sc": "measurement",
				"dec": 1, "src": "light.lux", "res": 0.5, "acc_pct": 20.0, "noise": 0.5, "lo": 0.0, "hi": 65535.0},
		],
		"src_doc": "ROHM BH1750FVI datasheet §1",
	},
	"veml7700": {
		"label": "VEML7700", "cat": "light", "desc": "Illuminance, wide range (to 120 000 lx).",
		"iface": "i2c", "addr": [0x10], "supply": "3v3", "ma": 0.05, "price": 5.0,
		"pins": [["VIN", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "sensor", "platform": "veml7700"}, "update": 60,
		"ents": [
			{"k": "ambient_light", "sub": "ambient_light", "name": "Illuminance", "unit": "lx", "dc": "illuminance",
				"sc": "measurement", "dec": 1, "src": "light.lux", "res": 0.0036, "acc_pct": 10.0, "noise": 0.2, "lo": 0.0, "hi": 120000.0},
		],
		"src_doc": "Vishay VEML7700 datasheet 84286 §1",
	},
	"ltr390": {
		"label": "LTR390", "cat": "light", "desc": "UV index and ambient light.",
		"iface": "i2c", "addr": [0x53], "supply": "3v3", "ma": 0.1, "price": 5.0,
		"pins": [["VIN", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "sensor", "platform": "ltr390"}, "update": 60,
		"ents": [
			{"k": "light", "sub": "light", "name": "Light", "unit": "lx", "dc": "illuminance", "sc": "measurement",
				"dec": 1, "src": "light.lux", "res": 0.6, "acc_pct": 15.0, "noise": 0.5, "lo": 0.0, "hi": 100000.0},
			{"k": "uv_index", "sub": "uv_index", "name": "UV Index", "unit": "UVI", "dc": "", "sc": "measurement",
				"dec": 1, "src": "light.uv_index", "res": 0.01, "acc_pct": 15.0, "noise": 0.05, "lo": 0.0, "hi": 15.0},
		],
		"src_doc": "Lite-On LTR-390UV-01 datasheet §1",
	},
	# ---------------------------------------------------------------- power
	"ina219": {
		"label": "INA219", "cat": "power", "desc": "DC current, voltage and power up to 26 V / 3.2 A (0.1 Ω shunt).",
		"iface": "i2c", "addr": [0x40, 0x41, 0x44, 0x45], "addr_note": "A0 / A1 solder jumpers",
		"supply": "3v3", "ma": 1.0, "price": 3.0,
		"pins": [["VCC", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"], ["VIN+", "nc"], ["VIN-", "nc"]],
		"yaml": {"dom": "sensor", "platform": "ina219",
			"fields": {"shunt_resistance": "0.1 ohm", "max_voltage": "26.0V", "max_current": "3.2A"}}, "update": 60,
		"ents": [
			{"k": "bus_voltage", "sub": "bus_voltage", "name": "Bus Voltage", "unit": "V", "dc": "voltage", "sc": "measurement",
				"dec": 2, "src": "elec.bus_v", "res": 0.004, "acc_pct": 0.5, "noise": 0.004, "lo": 0.0, "hi": 26.0},
			{"k": "current", "sub": "current", "name": "Current", "unit": "A", "dc": "current", "sc": "measurement",
				"dec": 3, "src": "elec.current_a", "res": 0.0001, "acc_pct": 1.0, "noise": 0.001, "lo": -3.2, "hi": 3.2},
			{"k": "power", "sub": "power", "name": "Power", "unit": "W", "dc": "power", "sc": "measurement",
				"dec": 2, "src": "elec.power_w", "res": 0.002, "acc_pct": 1.5, "noise": 0.01, "lo": 0.0, "hi": 85.0},
		],
		"src_doc": "TI INA219 datasheet SBOS448G §6",
	},
	"ina226": {
		"label": "INA226", "cat": "power", "desc": "DC current, voltage and power up to 36 V (0.1 Ω shunt, 0.8 A).",
		"iface": "i2c", "addr": [0x40, 0x41, 0x44, 0x45], "addr_note": "A0 / A1 pins",
		"supply": "3v3", "ma": 0.4, "price": 4.0,
		"pins": [["VCC", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"], ["VBUS", "nc"]],
		"yaml": {"dom": "sensor", "platform": "ina226",
			"fields": {"shunt_resistance": "0.1 ohm", "max_current": "0.8A"}}, "update": 60,
		"ents": [
			{"k": "bus_voltage", "sub": "bus_voltage", "name": "Bus Voltage", "unit": "V", "dc": "voltage", "sc": "measurement",
				"dec": 2, "src": "elec.bus_v", "res": 0.00125, "acc_pct": 0.1, "noise": 0.002, "lo": 0.0, "hi": 36.0},
			{"k": "current", "sub": "current", "name": "Current", "unit": "A", "dc": "current", "sc": "measurement",
				"dec": 3, "src": "elec.current_a", "res": 0.0001, "acc_pct": 0.5, "noise": 0.0005, "lo": -0.8, "hi": 0.8},
			{"k": "power", "sub": "power", "name": "Power", "unit": "W", "dc": "power", "sc": "measurement",
				"dec": 2, "src": "elec.power_w", "res": 0.0025, "acc_pct": 0.6, "noise": 0.005, "lo": 0.0, "hi": 30.0},
		],
		"src_doc": "TI INA226 datasheet SBOS547A §6",
	},
	"pzem004t": {
		"short": "PZEM", "label": "PZEM-004T v3", "cat": "power", "desc": "Mains AC voltage, current, power and energy (Modbus).",
		"iface": "uart", "uart": {"baud": 9600, "use": "both"}, "supply": "any", "ma": 10.0, "price": 12.0,
		"pins": [["5V", "vcc"], ["RX", "rx"], ["TX", "tx"], ["GND", "gnd"]],
		"yaml": {"dom": "sensor", "platform": "pzemac", "special": "modbus"}, "update": 60,
		"ents": [
			{"k": "voltage", "sub": "voltage", "name": "Voltage", "unit": "V", "dc": "voltage", "sc": "measurement",
				"dec": 1, "src": "elec.ac_v", "res": 0.1, "acc_pct": 0.5, "noise": 0.2, "lo": 80.0, "hi": 260.0},
			{"k": "current", "sub": "current", "name": "Current", "unit": "A", "dc": "current", "sc": "measurement",
				"dec": 3, "src": "elec.ac_a", "res": 0.001, "acc_pct": 0.5, "noise": 0.002, "lo": 0.0, "hi": 100.0},
			{"k": "power", "sub": "power", "name": "Power", "unit": "W", "dc": "power", "sc": "measurement",
				"dec": 1, "src": "elec.ac_w", "res": 0.1, "acc_pct": 0.5, "noise": 0.3, "lo": 0.0, "hi": 23000.0},
			{"k": "energy", "sub": "energy", "name": "Energy", "unit": "Wh", "dc": "energy", "sc": "total_increasing",
				"dec": 0, "src": "elec.ac_wh", "res": 1.0, "acc_pct": 0.5, "noise": 0.0, "lo": 0.0, "hi": 1.0e10},
			{"k": "frequency", "sub": "frequency", "name": "Frequency", "unit": "Hz", "dc": "frequency", "sc": "measurement",
				"dec": 1, "src": "elec.ac_hz", "res": 0.1, "acc": 0.1, "noise": 0.02, "lo": 45.0, "hi": 65.0},
			{"k": "power_factor", "sub": "power_factor", "name": "Power Factor", "unit": "", "dc": "power_factor",
				"sc": "measurement", "dec": 2, "src": "elec.ac_pf", "res": 0.01, "acc": 0.01, "noise": 0.005, "lo": 0.0, "hi": 1.0},
		],
		"src_doc": "Peacefair PZEM-004T V3.0 user manual §2",
	},
	# ---------------------------------------------------------------- distance & presence
	"hcsr04": {
		"label": "HC-SR04", "cat": "distance", "desc": "Ultrasonic distance 2 cm - 4 m (5 V; echo is 5 V).",
		"iface": "gpio", "supply": "5v", "logic5": true, "ma": 15.0, "price": 1.5,
		"pins": [["VCC", "vcc"], ["Trig", "in", "trigger_pin"], ["Echo", "out", "echo_pin"], ["GND", "gnd"]],
		"yaml": {"dom": "sensor", "platform": "ultrasonic"}, "update": 60,
		"ents": [
			{"k": "distance", "sub": "", "name": "Distance", "unit": "m", "dc": "distance", "sc": "measurement",
				"dec": 2, "src": "dist.m", "res": 0.003, "acc": 0.003, "noise": 0.004, "lo": 0.02, "hi": 4.0},
		],
		"src_doc": "ElecFreaks HC-SR04 datasheet §2",
	},
	"jsnsr04t": {
		"short": "JSN-SR04T", "label": "JSN-SR04T (waterproof)", "cat": "distance", "desc": "Waterproof ultrasonic 25 cm - 4.5 m: tank levels.",
		"iface": "gpio", "supply": "any", "ma": 8.0, "price": 8.0,
		"pins": [["5V", "vcc"], ["Trig", "in", "trigger_pin"], ["Echo", "out", "echo_pin"], ["GND", "gnd"]],
		"yaml": {"dom": "sensor", "platform": "ultrasonic"}, "update": 60,
		"ents": [
			{"k": "distance", "sub": "", "name": "Distance", "unit": "m", "dc": "distance", "sc": "measurement",
				"dec": 2, "src": "dist.m", "res": 0.005, "acc": 0.01, "noise": 0.006, "lo": 0.25, "hi": 4.5},
		],
		"src_doc": "JSN-SR04T v3.0 module datasheet §2",
	},
	"vl53l0x": {
		"label": "VL53L0X", "cat": "distance", "desc": "Laser time-of-flight distance to 2 m.",
		"iface": "i2c", "addr": [0x29], "supply": "3v3", "ma": 19.0, "price": 4.0,
		"pins": [["VIN", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "sensor", "platform": "vl53l0x", "fields": {"long_range": "true"}}, "update": 60,
		"ents": [
			{"k": "distance", "sub": "", "name": "Distance", "unit": "m", "dc": "distance", "sc": "measurement",
				"dec": 3, "src": "dist.m", "res": 0.001, "acc_pct": 3.0, "noise": 0.004, "lo": 0.03, "hi": 2.0},
		],
		"src_doc": "ST VL53L0X datasheet DocID029104 §1",
	},
	"pir_sr501": {
		"short": "PIR", "label": "PIR HC-SR501", "cat": "distance", "desc": "Motion (people and animals), 5 V supply, 3.3 V output.",
		"iface": "gpio", "supply": "5v", "ma": 0.1, "price": 1.5,
		"pins": [["VCC", "vcc"], ["OUT", "out", "pin"], ["GND", "gnd"]],
		"yaml": {"dom": "binary_sensor", "platform": "gpio"}, "update": 0,
		"ents": [
			{"k": "motion", "sub": "", "name": "Motion", "kind": "binary_sensor", "dc": "motion", "set": ["dc"],
				"src": "motion.present", "range_m": 7.0, "cone_deg": 110.0},
		],
		"src_doc": "HC-SR501 module datasheet",
	},
	# ---------------------------------------------------------------- water & soil
	"soil_cap": {
		"short": "Soil", "label": "Capacitive soil moisture v1.2", "cat": "water", "desc": "Soil moisture as an analog voltage.",
		"iface": "adc", "supply": "3v3", "ma": 5.0, "price": 1.5,
		"pins": [["GND", "gnd"], ["VCC", "vcc"], ["AOUT", "aout", "pin"]],
		"yaml": {"dom": "sensor", "platform": "adc", "special": "adc"}, "update": 60,
		"ents": [
			{"k": "moisture", "sub": "", "name": "Moisture", "unit": "%", "dc": "moisture", "sc": "measurement",
				"dec": 0, "set": ["unit", "dc", "dec"], "src": "soil.moisture_pct", "res": 0.1, "acc": 5.0, "noise": 0.5,
				"lo": 0.0, "hi": 100.0, "filters": [{"calibrate_linear": [[2.6, 0.0], [1.2, 100.0]]}, {"clamp": [0.0, 100.0]}]},
		],
		"src_doc": "DFRobot SEN0193 wiki (dry ~2.6 V, wet ~1.2 V at 3.3 V)",
	},
	"float_switch": {
		"short": "Tank", "label": "Float switch", "cat": "water", "desc": "Closes when the water reaches it.",
		"iface": "gpio", "supply": "any", "ma": 0.0, "price": 2.0,
		"pins": [["COM", "gnd"], ["NO", "out", "pin"]], "pullup": ["out"], "inverted": ["out"],
		"yaml": {"dom": "binary_sensor", "platform": "gpio"}, "update": 0,
		"ents": [
			{"k": "float", "sub": "", "name": "Float", "kind": "binary_sensor", "dc": "moisture", "set": ["dc"],
				"src": "level.float"},
		],
		"src_doc": "generic reed float switch",
	},
	"yfs201": {
		"short": "Flow", "label": "YF-S201 flow meter", "cat": "water", "desc": "Water flow 1-30 L/min, a pulse per 2.2 mL.",
		"iface": "pulse", "supply": "5v", "logic5": true, "ma": 15.0, "price": 4.0,
		"pins": [["Red", "vcc"], ["Black", "gnd"], ["Yellow", "pulse", "pin"]],
		"yaml": {"dom": "sensor", "platform": "pulse_counter", "special": "pulse"}, "update": 60,
		"ents": [
			{"k": "flow", "sub": "", "name": "Rate", "unit": "L/min", "dc": "volume_flow_rate", "sc": "measurement",
				"dec": 2, "set": ["unit", "dc", "dec"], "src": "flow.lpm", "res": 0.00222, "acc_pct": 10.0, "noise": 0.02,
				"lo": 0.0, "hi": 30.0, "filters": [{"multiply": 0.00222}]},
		],
		"src_doc": "YF-S201 datasheet: F = 7.5 × Q (L/min)",
	},
	# ---------------------------------------------------------------- weight & position
	"hx711": {
		"short": "Scale", "label": "HX711 + load cell", "cat": "weight", "desc": "Weight from a load cell (calibrate with two known weights).",
		"iface": "hx711", "supply": "any", "ma": 1.5, "price": 4.0,
		"pins": [["VCC", "vcc"], ["GND", "gnd"], ["DT", "out", "dout_pin"], ["SCK", "in", "clk_pin"]],
		"yaml": {"dom": "sensor", "platform": "hx711", "fields": {"gain": "128"}}, "update": 60,
		"ents": [
			{"k": "weight", "sub": "", "name": "Weight", "unit": "kg", "dc": "weight", "sc": "measurement",
				"dec": 2, "set": ["unit", "dc", "dec"], "src": "mass.kg", "res": 0.001, "acc_pct": 0.5, "noise": 0.005,
				"lo": 0.0, "hi": 1000.0, "filters": [{"calibrate_linear": [[0.0, 0.0], [100000.0, 1.0]]}], "raw_per_kg": 100000.0},
		],
		"src_doc": "Avia HX711 datasheet §1",
	},
	"neo6m": {
		"short": "GPS", "label": "NEO-6M GPS", "cat": "weight", "desc": "Position, altitude and satellites (serial NMEA).",
		"iface": "uart", "uart": {"baud": 9600, "use": "rx"}, "supply": "any", "ma": 45.0, "price": 6.0,
		"pins": [["VCC", "vcc"], ["RX", "rx"], ["TX", "tx"], ["GND", "gnd"]],
		"yaml": {"dom": "gps", "platform": "", "special": "gps"}, "update": 60,
		"ents": [
			{"k": "latitude", "sub": "latitude", "kind": "sensor", "name": "Latitude", "unit": "°", "dc": "", "sc": "measurement",
				"dec": 6, "src": "gps.lat", "res": 0.000001, "acc": 0.00002, "noise": 0.00001},
			{"k": "longitude", "sub": "longitude", "kind": "sensor", "name": "Longitude", "unit": "°", "dc": "", "sc": "measurement",
				"dec": 6, "src": "gps.lon", "res": 0.000001, "acc": 0.00002, "noise": 0.00001},
			{"k": "altitude", "sub": "altitude", "kind": "sensor", "name": "Altitude", "unit": "m", "dc": "distance", "sc": "measurement",
				"dec": 1, "src": "gps.alt_m", "res": 0.1, "acc": 5.0, "noise": 1.5},
			{"k": "satellites", "sub": "satellites", "kind": "sensor", "name": "Satellites", "unit": "", "dc": "", "sc": "measurement",
				"dec": 0, "src": "gps.sats", "res": 1.0, "noise": 0.6, "lo": 0.0, "hi": 16.0},
		],
		"src_doc": "u-blox NEO-6 datasheet GPS.G6-HW-09005 §1",
	},
	# ---------------------------------------------------------------- actuators
	"relay_1ch": {
		"short": "Relay", "label": "Relay module (1-ch)", "cat": "actuator", "desc": "Switches a load up to 10 A (5 V coil, opto input).",
		"iface": "gpio", "supply": "5v", "ma": 70.0, "price": 2.0,
		"pins": [["VCC", "vcc"], ["GND", "gnd"], ["IN", "in", "pin"]],
		"yaml": {"dom": "switch", "platform": "gpio"}, "update": 0,
		"ents": [{"k": "relay", "sub": "", "name": "Relay", "kind": "switch", "dc": "", "src": "actuator.switch"}],
		"src_doc": "Songle SRD-05VDC relay module",
	},
	"buzzer": {
		"short": "Buzzer", "label": "Active buzzer", "cat": "actuator", "desc": "Beeps while its pin is on.",
		"iface": "gpio", "supply": "any", "ma": 25.0, "price": 0.5,
		"pins": [["+", "in", "pin"], ["-", "gnd"]],
		"yaml": {"dom": "switch", "platform": "gpio"}, "update": 0,
		"ents": [{"k": "buzzer", "sub": "", "name": "Buzzer", "kind": "switch", "dc": "", "src": "actuator.switch"}],
		"src_doc": "generic 3-5 V active buzzer",
	},
	"ws2812": {
		"short": "LED Strip", "label": "WS2812B strip (8 LEDs)", "cat": "actuator", "desc": "Addressable RGB LEDs, 5 V, one data wire.",
		"iface": "led", "supply": "5v", "ma": 480.0, "price": 4.0,
		"pins": [["5V", "vcc"], ["DIN", "led", "pin"], ["GND", "gnd"]],
		"yaml": {"dom": "light", "platform": "", "special": "led_strip", "num_leds": 8}, "update": 0,
		"ents": [{"k": "strip", "sub": "", "name": "LED Strip", "kind": "light", "dc": "", "src": "actuator.light"}],
		"src_doc": "Worldsemi WS2812B datasheet v1.0 (VIH = 0.7 × VDD)",
	},
	"servo_sg90": {
		"short": "Servo", "label": "Servo SG90", "cat": "actuator", "desc": "Hobby servo, 0-180°, PWM at 50 Hz.",
		"iface": "pwm", "supply": "5v", "ma": 150.0, "price": 2.0,
		"pins": [["Brown", "gnd"], ["Red", "vcc"], ["Orange", "pwm", "pin"]],
		"yaml": {"dom": "number", "platform": "template", "special": "servo"}, "update": 0,
		"ents": [{"k": "angle", "sub": "", "name": "Servo", "kind": "number", "dc": "", "src": "actuator.number"}],
		"src_doc": "TowerPro SG90 datasheet",
	},
	# ---------------------------------------------------------------- inputs & displays
	"button": {
		"short": "Button", "label": "Push button", "cat": "input", "desc": "A momentary button to ground.",
		"iface": "gpio", "supply": "any", "ma": 0.0, "price": 0.2,
		"pins": [["A", "out", "pin"], ["B", "gnd"]], "pullup": ["out"], "inverted": ["out"],
		"yaml": {"dom": "binary_sensor", "platform": "gpio"}, "update": 0,
		"ents": [{"k": "button", "sub": "", "name": "Button", "kind": "binary_sensor", "dc": "", "src": "input.button"}],
		"src_doc": "",
	},
	"ssd1306": {
		"short": "OLED", "label": "OLED SSD1306 128×64", "cat": "display", "desc": "Small I2C screen; shows the board's own readings.",
		"iface": "i2c", "addr": [0x3C, 0x3D], "supply": "3v3", "ma": 20.0, "price": 3.0,
		"pins": [["GND", "gnd"], ["VCC", "vcc"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "display", "platform": "ssd1306_i2c", "special": "ssd1306"}, "update": 0,
		"ents": [],
		"src_doc": "Solomon Systech SSD1306 datasheet",
	},	# ================================================================ phase 7
	# ---------------------------------------------------------------- env
	"htu21d": {
		"short": "HTU21D", "label": "HTU21D / SI7021", "cat": "env", "desc": "Temperature and humidity (cheap, common).",
		"iface": "i2c", "addr": [0x40], "supply": "3v3", "ma": 0.5, "price": 2.5,
		"pins": [["VIN", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "sensor", "platform": "htu21d"}, "update": 60,
		"ents": [
			{"k": "temperature", "sub": "temperature", "name": "Temperature", "unit": "°C", "dc": "temperature",
				"sc": "measurement", "dec": 1, "src": "air.temp_c", "res": 0.01, "acc": 0.3, "noise": 0.02, "lo": -40.0, "hi": 125.0},
			{"k": "humidity", "sub": "humidity", "name": "Humidity", "unit": "%", "dc": "humidity",
				"sc": "measurement", "dec": 1, "src": "air.rh_pct", "res": 0.04, "acc": 2.0, "noise": 0.1, "lo": 0.0, "hi": 100.0, "tau": 5.0},
		],
		"src_doc": "TE HTU21D(F) datasheet HPC199_6 §1",
	},
	"shtc3": {
		"label": "SHTC3", "cat": "env", "desc": "Temperature and humidity, tiny and low power (Sensirion).",
		"iface": "i2c", "addr": [0x70], "supply": "3v3", "ma": 0.4, "price": 4.0,
		"pins": [["VIN", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "sensor", "platform": "shtcx"}, "update": 60,
		"ents": [
			{"k": "temperature", "sub": "temperature", "name": "Temperature", "unit": "°C", "dc": "temperature",
				"sc": "measurement", "dec": 1, "src": "air.temp_c", "res": 0.01, "acc": 0.2, "noise": 0.02, "lo": -40.0, "hi": 125.0},
			{"k": "humidity", "sub": "humidity", "name": "Humidity", "unit": "%", "dc": "humidity",
				"sc": "measurement", "dec": 1, "src": "air.rh_pct", "res": 0.01, "acc": 2.0, "noise": 0.1, "lo": 0.0, "hi": 100.0, "tau": 8.0},
		],
		"src_doc": "Sensirion SHTC3 datasheet v4 §2",
	},
	"bme680": {
		"label": "BME680", "cat": "env", "desc": "Temperature, humidity, pressure and a gas (VOC) resistance.",
		"iface": "i2c", "addr": [0x77, 0x76], "addr_note": "SDO to VCC = 0x77, to GND = 0x76",
		"supply": "3v3", "ma": 12.0, "price": 9.0,
		"pins": [["VIN", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "sensor", "platform": "bme680"}, "update": 60,
		"ents": [
			{"k": "temperature", "sub": "temperature", "name": "Temperature", "unit": "°C", "dc": "temperature",
				"sc": "measurement", "dec": 1, "src": "air.temp_c", "res": 0.01, "acc": 1.0, "noise": 0.03, "lo": -40.0, "hi": 85.0},
			{"k": "pressure", "sub": "pressure", "name": "Pressure", "unit": "hPa", "dc": "atmospheric_pressure",
				"sc": "measurement", "dec": 1, "src": "air.pressure_hpa", "res": 0.18, "acc": 0.6, "noise": 0.05, "lo": 300.0, "hi": 1100.0},
			{"k": "humidity", "sub": "humidity", "name": "Humidity", "unit": "%", "dc": "humidity",
				"sc": "measurement", "dec": 1, "src": "air.rh_pct", "res": 0.008, "acc": 3.0, "noise": 0.1, "lo": 0.0, "hi": 100.0, "tau": 8.0},
			{"k": "gas_resistance", "sub": "gas_resistance", "name": "Gas Resistance", "unit": "Ω", "dc": "",
				"sc": "measurement", "dec": 0, "src": "air.gas_ohm", "res": 1.0, "acc_pct": 15.0, "noise": 400.0, "lo": 0.0, "hi": 500000.0, "tau": 60.0},
		],
		"src_doc": "Bosch BME680 datasheet BST-BME680-DS001 §1",
	},
	"max31865": {
		"short": "PT100", "label": "MAX31865 + PT100", "cat": "env", "desc": "Precise platinum RTD temperature (-200 to 850 °C).",
		"iface": "spi", "supply": "3v3", "ma": 2.0, "price": 12.0,
		"pins": [["VIN", "vcc"], ["GND", "gnd"], ["CLK", "sck"], ["SDO", "miso"], ["SDI", "mosi"], ["CS", "cs", "cs_pin"]],
		"yaml": {"dom": "sensor", "platform": "max31865",
			"fields": {"reference_resistance": "430 Ω", "rtd_nominal_resistance": "100 Ω"}}, "update": 60,
		"ents": [
			{"k": "temperature", "sub": "", "name": "RTD", "unit": "°C", "dc": "temperature",
				"sc": "measurement", "dec": 2, "src": "probe.temp_c", "res": 0.03125, "acc": 0.3, "noise": 0.02, "lo": -200.0, "hi": 850.0, "tau": 10.0},
		],
		"src_doc": "Analog Devices MAX31865 datasheet 19-6923 §1; IEC 60751 class B",
	},
	# ---------------------------------------------------------------- air
	"sen55": {
		"label": "SEN55", "cat": "air", "desc": "Particulates, VOC and NOx indices, temperature and humidity in one (5 V).",
		"iface": "i2c", "addr": [0x69], "supply": "5v", "ma": 70.0, "price": 30.0,
		"pins": [["VDD", "vcc"], ["GND", "gnd"], ["SDA", "sda"], ["SCL", "scl"], ["SEL", "gnd"]],
		"yaml": {"dom": "sensor", "platform": "sen5x"}, "update": 60,
		"ents": [
			{"k": "pm_1_0", "sub": "pm_1_0", "name": "PM1.0", "unit": "µg/m³", "dc": "pm1", "sc": "measurement",
				"dec": 1, "src": "air.pm1_ugm3", "res": 0.1, "acc": 5.0, "noise": 1.0, "lo": 0.0, "hi": 1000.0},
			{"k": "pm_2_5", "sub": "pm_2_5", "name": "PM2.5", "unit": "µg/m³", "dc": "pm25", "sc": "measurement",
				"dec": 1, "src": "air.pm25_ugm3", "res": 0.1, "acc": 5.0, "noise": 1.2, "lo": 0.0, "hi": 1000.0},
			{"k": "pm_4_0", "sub": "pm_4_0", "name": "PM4.0", "unit": "µg/m³", "dc": "pm4", "sc": "measurement",
				"dec": 1, "src": "air.pm4_ugm3", "res": 0.1, "acc": 25.0, "noise": 1.5, "lo": 0.0, "hi": 1000.0},
			{"k": "pm_10_0", "sub": "pm_10_0", "name": "PM10", "unit": "µg/m³", "dc": "pm10", "sc": "measurement",
				"dec": 1, "src": "air.pm10_ugm3", "res": 0.1, "acc": 25.0, "noise": 2.0, "lo": 0.0, "hi": 1000.0},
			{"k": "temperature", "sub": "temperature", "name": "Temperature", "unit": "°C", "dc": "temperature",
				"sc": "measurement", "dec": 1, "src": "air.temp_c", "res": 0.005, "acc": 0.45, "noise": 0.03, "lo": -10.0, "hi": 50.0},
			{"k": "humidity", "sub": "humidity", "name": "Humidity", "unit": "%", "dc": "humidity",
				"sc": "measurement", "dec": 1, "src": "air.rh_pct", "res": 0.01, "acc": 4.5, "noise": 0.2, "lo": 0.0, "hi": 100.0},
			{"k": "voc", "sub": "voc", "name": "VOC", "unit": "", "dc": "", "sc": "measurement",
				"dec": 0, "src": "air.voc_index", "res": 1.0, "acc": 15.0, "noise": 2.0, "lo": 1.0, "hi": 500.0},
			{"k": "nox", "sub": "nox", "name": "NOx", "unit": "", "dc": "", "sc": "measurement",
				"dec": 0, "src": "air.nox_index", "res": 1.0, "acc": 15.0, "noise": 0.5, "lo": 1.0, "hi": 500.0},
		],
		"src_doc": "Sensirion SEN5x datasheet v2 §1",
	},
	"ccs811": {
		"label": "CCS811", "cat": "air", "desc": "TVOC and estimated CO₂ (metal-oxide, eCO₂).",
		"iface": "i2c", "addr": [0x5A, 0x5B], "addr_note": "ADDR to GND = 0x5A, to VCC = 0x5B",
		"supply": "3v3", "ma": 30.0, "price": 8.0,
		"pins": [["VIN", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"], ["WAK", "gnd"]],
		"yaml": {"dom": "sensor", "platform": "ccs811"}, "update": 60,
		"ents": [
			{"k": "eco2", "sub": "eco2", "name": "eCO2", "unit": "ppm", "dc": "carbon_dioxide", "sc": "measurement",
				"dec": 0, "src": "air.eco2_ppm", "res": 1.0, "acc_pct": 20.0, "noise": 15.0, "lo": 400.0, "hi": 8192.0},
			{"k": "tvoc", "sub": "tvoc", "name": "TVOC", "unit": "ppb", "dc": "volatile_organic_compounds_parts",
				"sc": "measurement", "dec": 0, "src": "air.tvoc_ppb", "res": 1.0, "acc_pct": 20.0, "noise": 5.0, "lo": 0.0, "hi": 1187.0},
		],
		"src_doc": "ScioSense CCS811 datasheet DS000459 §1",
	},
	# ---------------------------------------------------------------- light
	"tsl2561": {
		"label": "TSL2561", "cat": "light", "desc": "Illuminance (visible and infrared photodiodes).",
		"iface": "i2c", "addr": [0x39, 0x29, 0x49], "addr_note": "ADDR floating = 0x39, to GND = 0x29, to VCC = 0x49",
		"supply": "3v3", "ma": 0.3, "price": 5.0,
		"pins": [["VIN", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "sensor", "platform": "tsl2561"}, "update": 60,
		"ents": [
			{"k": "illuminance", "sub": "", "name": "Illuminance", "unit": "lx", "dc": "illuminance", "sc": "measurement",
				"dec": 1, "src": "light.lux", "res": 1.0, "acc_pct": 20.0, "noise": 0.5, "lo": 0.0, "hi": 40000.0},
		],
		"src_doc": "ams TSL2561 datasheet TAOS059 §1",
	},
	"tsl2591": {
		"label": "TSL2591", "cat": "light", "desc": "Illuminance with a huge dynamic range (dim to full sun).",
		"iface": "i2c", "addr": [0x29], "supply": "3v3", "ma": 0.4, "price": 7.0,
		"pins": [["VIN", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "sensor", "platform": "tsl2591"}, "update": 60,
		"ents": [
			{"k": "calculated_lux", "sub": "calculated_lux", "name": "Illuminance", "unit": "lx", "dc": "illuminance",
				"sc": "measurement", "dec": 1, "src": "light.lux", "res": 0.01, "acc_pct": 15.0, "noise": 0.3, "lo": 0.0, "hi": 88000.0},
		],
		"src_doc": "ams TSL2591 datasheet DS000338 §1",
	},
	# ---------------------------------------------------------------- power
	"ina260": {
		"label": "INA260", "cat": "power", "desc": "DC current, voltage and power to 36 V / 15 A (shunt built in).",
		"iface": "i2c", "addr": [0x40, 0x41, 0x44, 0x45], "addr_note": "A0 / A1 solder jumpers",
		"supply": "3v3", "ma": 1.0, "price": 10.0,
		"pins": [["VCC", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"], ["VIN+", "nc"], ["VIN-", "nc"]],
		"yaml": {"dom": "sensor", "platform": "ina260"}, "update": 60,
		"ents": [
			{"k": "bus_voltage", "sub": "bus_voltage", "name": "Bus Voltage", "unit": "V", "dc": "voltage", "sc": "measurement",
				"dec": 2, "src": "elec.bus_v", "res": 0.00125, "acc_pct": 0.1, "noise": 0.002, "lo": 0.0, "hi": 36.0},
			{"k": "current", "sub": "current", "name": "Current", "unit": "A", "dc": "current", "sc": "measurement",
				"dec": 3, "src": "elec.current_a", "res": 0.00125, "acc_pct": 0.15, "noise": 0.002, "lo": -15.0, "hi": 15.0},
			{"k": "power", "sub": "power", "name": "Power", "unit": "W", "dc": "power", "sc": "measurement",
				"dec": 2, "src": "elec.power_w", "res": 0.01, "acc_pct": 0.5, "noise": 0.02, "lo": 0.0, "hi": 540.0},
		],
		"src_doc": "TI INA260 datasheet SBOS656C §6",
	},
	"acs712": {
		"short": "ACS712", "label": "ACS712 5 A current", "cat": "power", "desc": "DC current through a Hall sensor; analog out around 2.5 V.",
		"iface": "adc", "supply": "5v", "ma": 10.0, "price": 2.0,
		"pins": [["VCC", "vcc"], ["OUT", "aout", "pin"], ["GND", "gnd"]],
		"yaml": {"dom": "sensor", "platform": "adc", "special": "adc"}, "update": 10,
		"ents": [
			{"k": "current", "sub": "", "name": "Current", "unit": "A", "dc": "current", "sc": "measurement",
				"dec": 2, "set": ["unit", "dc", "dec"], "src": "elec.current_a", "res": 0.005, "acc_pct": 1.5, "noise": 0.03,
				"lo": -5.0, "hi": 5.0, "filters": [{"calibrate_linear": [[2.5, 0.0], [2.685, 1.0]]}]},
		],
		"src_doc": "Allegro ACS712 datasheet: 185 mV/A, Vout = Vcc/2 at 0 A",
		"note": "At 5 A the output reaches 3.4 V: past the ADC's range, so add a divider for full scale.",
	},
	"ads1115": {
		"short": "ADS1115", "label": "ADS1115 16-bit ADC", "cat": "io", "desc": "Four precise analog inputs over I2C (the ESP's own ADC is noisy).",
		"iface": "i2c", "addr": [0x48, 0x49, 0x4A, 0x4B], "addr_note": "ADDR to GND / VDD / SDA / SCL",
		"supply": "3v3", "ma": 0.2, "price": 3.0,
		"pins": [["VDD", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"], ["A0", "nc"]],
		"yaml": {"dom": "ads1115", "platform": "", "special": "ads1115"}, "update": 60,
		"ents": [
			{"k": "a0", "sub": "", "name": "A0", "kind": "sensor", "unit": "V", "dc": "voltage", "sc": "measurement",
				"dec": 3, "src": "adc.v", "res": 0.000125, "acc_pct": 0.1, "noise": 0.0003, "lo": 0.0, "hi": 4.096},
		],
		"src_doc": "TI ADS1115 datasheet SBAS444D §1",
	},
	# ---------------------------------------------------------------- distance & presence
	"ld2410": {
		"label": "HLK-LD2410", "cat": "distance", "desc": "mmWave presence: sees people sitting still, not only moving.",
		"iface": "uart", "uart": {"baud": 256000, "use": "both"}, "supply": "5v", "ma": 80.0, "price": 4.0,
		"pins": [["VCC", "vcc"], ["GND", "gnd"], ["TX", "tx"], ["RX", "rx"], ["OUT", "nc"]],
		"yaml": {"dom": "ld2410", "platform": "", "special": "ld2410"}, "update": 0,
		"ents": [
			{"k": "has_target", "sub": "has_target", "name": "Presence", "kind": "binary_sensor", "dc": "occupancy",
				"src": "motion.present", "range_m": 6.0, "cone_deg": 120.0},
			{"k": "detection_distance", "sub": "detection_distance", "name": "Detection Distance", "kind": "sensor",
				"unit": "cm", "dc": "distance", "sc": "measurement", "dec": 0, "src": "presence.cm",
				"res": 1.0, "acc": 15.0, "noise": 8.0, "lo": 0.0, "hi": 600.0},
		],
		"src_doc": "Hi-Link HLK-LD2410 manual v1.04 §2",
	},
	"rcwl0516": {
		"short": "RCWL-0516", "label": "RCWL-0516 microwave motion", "cat": "distance", "desc": "Doppler radar motion, sees through thin walls.",
		"iface": "gpio", "supply": "5v", "ma": 3.0, "price": 1.0,
		"pins": [["VIN", "vcc"], ["OUT", "out", "pin"], ["GND", "gnd"]],
		"yaml": {"dom": "binary_sensor", "platform": "gpio"}, "update": 0,
		"ents": [
			{"k": "motion", "sub": "", "name": "Motion", "kind": "binary_sensor", "dc": "motion", "set": ["dc"],
				"src": "motion.present", "range_m": 7.0, "cone_deg": 360.0},
		],
		"src_doc": "RCWL-0516 module notes (3.3 V output, 4-28 V supply)",
	},
	"a02yyuw": {
		"short": "A02YYUW", "label": "A02YYUW waterproof ultrasonic (UART)", "cat": "distance", "desc": "Waterproof distance 3 cm - 4.5 m, digital: steadier than the JSN.",
		"iface": "uart", "uart": {"baud": 9600, "use": "rx"}, "supply": "any", "ma": 8.0, "price": 14.0,
		"pins": [["VCC", "vcc"], ["GND", "gnd"], ["TX", "tx"], ["RX", "nc"]],
		"yaml": {"dom": "sensor", "platform": "a02yyuw"}, "update": 0,
		"ents": [
			{"k": "distance", "sub": "", "name": "Distance", "unit": "m", "dc": "distance", "sc": "measurement",
				"dec": 3, "set": ["unit", "dec"], "src": "dist.m", "res": 0.001, "acc": 0.003, "noise": 0.002,
				"lo": 0.03, "hi": 4.5, "filters": [{"multiply": 0.001}]},
		],
		"src_doc": "DFRobot SEN0311 (A02YYUW) wiki §Specification",
	},
	# ---------------------------------------------------------------- water & soil, rain & wind
	"leak_sensor": {
		"short": "Leak", "label": "Water leak probe (digital)", "cat": "water", "desc": "Goes wet when water bridges the probe (comparator board).",
		"iface": "gpio", "supply": "any", "ma": 5.0, "price": 1.5,
		"pins": [["VCC", "vcc"], ["GND", "gnd"], ["DO", "out", "pin"]], "inverted": ["out"],
		"yaml": {"dom": "binary_sensor", "platform": "gpio"}, "update": 0,
		"ents": [
			{"k": "leak", "sub": "", "name": "Leak", "kind": "binary_sensor", "dc": "moisture", "set": ["dc"], "src": "leak.wet"},
		],
		"src_doc": "generic LM393 rain / leak comparator module (DO low when wet)",
	},
	"rain_gauge": {
		"short": "Rain", "label": "Tipping-bucket rain gauge", "cat": "wx", "desc": "Rain rate: a reed switch closes once per 0.2794 mm.",
		"iface": "pulse", "supply": "any", "ma": 0.0, "price": 15.0,
		"pins": [["COM", "gnd"], ["SIG", "pulse", "pin"]], "pullup": ["pulse"],
		"yaml": {"dom": "sensor", "platform": "pulse_counter", "special": "pulse"}, "update": 60,
		"ents": [
			{"k": "rain", "sub": "", "name": "Rain Rate", "unit": "mm/h", "dc": "precipitation_intensity", "sc": "measurement",
				"dec": 2, "set": ["unit", "dc", "dec"], "src": "rain.mmh", "res": 0.2794, "acc_pct": 4.0, "noise": 0.0,
				"lo": 0.0, "hi": 300.0, "filters": [{"multiply": 16.764}]},
		],
		"src_doc": "SparkFun SEN-15901 weather meters datasheet: 0.011 in (0.2794 mm) per tip",
	},
	"anemometer": {
		"short": "Wind", "label": "Cup anemometer (reed)", "cat": "wx", "desc": "Wind speed: one switch closure per second = 2.4 km/h.",
		"iface": "pulse", "supply": "any", "ma": 0.0, "price": 20.0,
		"pins": [["COM", "gnd"], ["SIG", "pulse", "pin"]], "pullup": ["pulse"],
		"yaml": {"dom": "sensor", "platform": "pulse_counter", "special": "pulse"}, "update": 10,
		"ents": [
			{"k": "wind", "sub": "", "name": "Wind Speed", "unit": "m/s", "dc": "wind_speed", "sc": "measurement",
				"dec": 1, "set": ["unit", "dc", "dec"], "src": "air.wind_ms", "res": 0.011, "acc_pct": 5.0, "noise": 0.15,
				"lo": 0.0, "hi": 60.0, "filters": [{"multiply": 0.011111}]},
		],
		"src_doc": "SparkFun SEN-15901 weather meters datasheet: 1 Hz = 2.4 km/h",
	},
	# ---------------------------------------------------------------- weight & position
	"mpu6050": {
		"label": "MPU-6050", "cat": "weight", "desc": "Accelerometer and gyro: tilt, vibration, knocks.",
		"iface": "i2c", "addr": [0x68, 0x69], "addr_note": "AD0 to GND = 0x68, to VCC = 0x69",
		"supply": "3v3", "ma": 4.0, "price": 2.5,
		"pins": [["VCC", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "sensor", "platform": "mpu6050"}, "update": 60,
		"ents": [
			{"k": "accel_z", "sub": "accel_z", "name": "Accel Z", "unit": "m/s²", "dc": "", "sc": "measurement",
				"dec": 2, "src": "accel.z", "res": 0.0006, "acc_pct": 3.0, "noise": 0.04, "lo": -19.6, "hi": 19.6},
			{"k": "temperature", "sub": "temperature", "name": "Temperature", "unit": "°C", "dc": "temperature",
				"sc": "measurement", "dec": 1, "src": "air.temp_c", "res": 0.003, "acc": 3.0, "noise": 0.05, "lo": -40.0, "hi": 85.0},
		],
		"src_doc": "InvenSense MPU-6000/6050 product spec PS-MPU-6000A §6",
	},
	# ---------------------------------------------------------------- inputs
	"rotary_encoder": {
		"short": "Encoder", "label": "Rotary encoder (KY-040)", "cat": "input", "desc": "A knob that counts clicks either way.",
		"iface": "gpio", "supply": "3v3", "ma": 1.0, "price": 1.0,
		"pins": [["CLK", "out", "pin_a"], ["DT", "out", "pin_b"], ["+", "vcc"], ["GND", "gnd"]], "pullup": ["out"],
		"yaml": {"dom": "sensor", "platform": "rotary_encoder"}, "update": 0,
		"ents": [
			{"k": "position", "sub": "", "name": "Knob", "unit": "", "dc": "", "sc": "measurement", "dec": 0,
				"src": "input.encoder", "res": 1.0, "noise": 0.0},
		],
		"src_doc": "KY-040 module notes",
	},
	# ---------------------------------------------------------------- actuators
	"mosfet": {
		"short": "MOSFET", "label": "Logic-level MOSFET switch", "cat": "actuator", "desc": "Switches a DC load (pump, valve, LED strip) up to ~10 A.",
		"iface": "gpio", "supply": "any", "ma": 0.0, "price": 1.5,
		"pins": [["SIG", "in", "pin"], ["GND", "gnd"], ["VCC", "nc"]],
		"yaml": {"dom": "switch", "platform": "gpio"}, "update": 0,
		"ents": [{"k": "switch", "sub": "", "name": "Load", "kind": "switch", "dc": "", "src": "actuator.switch"}],
		"src_doc": "AO3400 / IRLZ44N logic-level MOSFET modules (IRF520 boards need ~10 V gate: avoid)",
	},
	# ---------------------------------------------------------------- displays
	"sh1106": {
		"short": "OLED 1.3\"", "label": "OLED SH1106 1.3\" 128×64", "cat": "display", "desc": "The bigger cheap I2C OLED (SH1106 driver).",
		"iface": "i2c", "addr": [0x3C, 0x3D], "supply": "3v3", "ma": 25.0, "price": 4.0,
		"pins": [["VCC", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "display", "platform": "ssd1306_i2c", "special": "ssd1306", "model": "SH1106 128x64"}, "update": 0,
		"ents": [],
		"src_doc": "Sino Wealth SH1106 datasheet",
	},
	"lcd1602": {
		"short": "LCD", "label": "LCD 16×2 with I2C backpack", "cat": "display", "desc": "Character LCD (PCF8574 backpack, 5 V).",
		"iface": "i2c", "addr": [0x27, 0x3F], "addr_note": "PCF8574 = 0x27, PCF8574A = 0x3F",
		"supply": "5v", "ma": 30.0, "price": 3.0,
		"pins": [["GND", "gnd"], ["VCC", "vcc"], ["SDA", "sda"], ["SCL", "scl"]],
		"yaml": {"dom": "display", "platform": "lcd_pcf8574", "special": "lcd"}, "update": 0,
		"ents": [],
		"src_doc": "Hitachi HD44780 + NXP PCF8574 datasheets",
		"note": "The backpack pulls SDA / SCL up to 5 V: fine on most ESP32 boards in practice, a level shifter is safer.",
	},
	"epaper_29": {
		"short": "E-paper", "label": "E-paper 2.9\" (Waveshare V2)", "cat": "display", "desc": "Readable in sun, holds the picture with no power.",
		"iface": "spi", "supply": "3v3", "ma": 8.0, "price": 20.0,
		"pins": [["VCC", "vcc"], ["GND", "gnd"], ["DIN", "mosi"], ["CLK", "sck"], ["CS", "cs", "cs_pin"],
			["DC", "in", "dc_pin"], ["RST", "in", "reset_pin"], ["BUSY", "out", "busy_pin"]],
		"yaml": {"dom": "display", "platform": "waveshare_epaper", "special": "epaper", "model": "2.90inv2"}, "update": 0,
		"ents": [],
		"src_doc": "Waveshare 2.9inch e-Paper Module (V2) manual",
	},
	# ---------------------------------------------------------------- I/O & comms
	"mcp23017": {
		"short": "MCP23017", "label": "MCP23017 16-pin I/O expander", "cat": "io", "desc": "Sixteen more digital pins over I2C.",
		"iface": "i2c", "addr": [0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27], "addr_note": "A0-A2 pins",
		"supply": "3v3", "ma": 1.0, "price": 2.0,
		"pins": [["VDD", "vcc"], ["VSS", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "mcp23017", "platform": "", "special": "hub"}, "update": 0,
		"ents": [],
		"src_doc": "Microchip MCP23017 datasheet DS20001952C §1",
	},
	"pcf8574": {
		"short": "PCF8574", "label": "PCF8574 8-pin I/O expander", "cat": "io", "desc": "Eight more digital pins over I2C (quasi-bidirectional).",
		"iface": "i2c", "addr": [0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27], "addr_note": "A0-A2 pins",
		"supply": "3v3", "ma": 0.1, "price": 1.5,
		"pins": [["VCC", "vcc"], ["GND", "gnd"], ["SCL", "scl"], ["SDA", "sda"]],
		"yaml": {"dom": "pcf8574", "platform": "", "special": "hub", "fields": {"pcf8575": false}}, "update": 0,
		"ents": [],
		"src_doc": "NXP PCF8574 datasheet rev 5 §1",
	},
	"max485": {
		"short": "RS485", "label": "MAX485 RS-485 (Modbus)", "cat": "io", "desc": "Talk Modbus RTU to meters, inverters and VFDs over long wires.",
		"iface": "uart", "uart": {"baud": 9600, "use": "both"}, "supply": "3v3", "ma": 1.0, "price": 1.5,
		"pins": [["VCC", "vcc"], ["GND", "gnd"], ["RO", "tx"], ["DI", "rx"], ["DE/RE", "in", "flow_control_pin"]],
		"yaml": {"dom": "modbus", "platform": "", "special": "hub"}, "update": 0,
		"ents": [],
		"src_doc": "Maxim MAX485 datasheet 19-0122 §1",
		"note": "Add a modbus_controller and its registers for your device to read anything.",
	},
	"sn65hvd230": {
		"short": "CAN", "label": "SN65HVD230 CAN transceiver", "cat": "io", "desc": "CAN bus (vehicles, battery BMSs) on the ESP32's TWAI controller.",
		"iface": "gpio", "chips": ["esp32"], "supply": "3v3", "ma": 10.0, "price": 2.0,
		"pins": [["3V3", "vcc"], ["GND", "gnd"], ["CTX", "in", "tx_pin"], ["CRX", "out", "rx_pin"]],
		"yaml": {"dom": "canbus", "platform": "esp32_can", "special": "hub", "fields": {"can_id": 4, "bit_rate": "125kbps"}}, "update": 0,
		"ents": [],
		"src_doc": "TI SN65HVD230 datasheet SLOS346 §1",
	},
	"inmp441": {
		"short": "Mic", "label": "INMP441 I2S microphone", "cat": "io", "desc": "A digital microphone (voice assistant, sound level).",
		"iface": "gpio", "chips": ["esp32"], "supply": "3v3", "ma": 1.5, "price": 3.0,
		"pins": [["VDD", "vcc"], ["GND", "gnd"], ["WS", "in", "i2s_lrclk_pin"], ["SCK", "in", "i2s_bclk_pin"],
			["SD", "out", "i2s_din_pin"], ["L/R", "gnd"]],
		"yaml": {"dom": "microphone", "platform": "i2s_audio", "special": "i2s_mic"}, "update": 0,
		"ents": [],
		"src_doc": "TDK InvenSense INMP441 datasheet DS-INMP441 §1",
	},
}


## The name an instance gets by default ("DHT22", "Soil"): `short`, else the
## label up to its first " (" / " /" / " +".
static func short_label(part: Dictionary) -> String:
	if part.has("short"):
		return str(part["short"])
	var lab := str(part.get("label", ""))
	for cut in [" (", " /", " +"]:
		var i := lab.find(cut)
		if i > 0:
			lab = lab.substr(0, i)
	return lab


static func ids() -> Array:
	var out: Array = PARTS.keys()
	out.sort()
	return out


static func get_part(id: String) -> Dictionary:
	return PARTS.get(id, {})


static func in_category(cat: String) -> Array:
	var out: Array = []
	for id in ids():
		if str((PARTS[id] as Dictionary).get("cat", "")) == cat:
			out.append(id)
	return out


## A part's pins that need a GPIO (anything but vcc / gnd / nc), in order.
static func signal_pins(part: Dictionary) -> Array:
	var out: Array = []
	for p in part.get("pins", []):
		var role := str(p[1])
		if role != "vcc" and role != "gnd" and role != "nc":
			out.append(p)
	return out


## Bus roles are routed by the bus, not per part.
static func is_bus_role(iface: String, role: String) -> bool:
	match iface:
		"i2c":
			return role == "sda" or role == "scl"
		"spi":
			return role == "sck" or role == "miso" or role == "mosi"
		"uart":
			return role == "tx" or role == "rx"
		"onewire":
			return role == "data"
	return false


## Does a role drive the pin from the board (an output)?
static func is_board_output(role: String) -> bool:
	return role in ["in", "rx", "mosi", "sck", "cs", "led", "pwm", "scl"]


## The interface badge for the palette.
static func badge(part: Dictionary) -> String:
	match str(part.get("iface", "")):
		"i2c": return "I²C"
		"spi": return "SPI"
		"uart": return "UART"
		"onewire": return "1-Wire"
		"adc": return "Analog"
		"pulse": return "Pulse"
		"led": return "LED data"
		"pwm": return "PWM"
		"hx711": return "2 GPIO"
	return "GPIO"
