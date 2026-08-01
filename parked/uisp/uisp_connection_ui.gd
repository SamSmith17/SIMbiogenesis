extends Control

## UISP Connection UI
## Provides a configuration panel for connecting to UISP API
## Visibility is controlled by TimeUI (opens with ESC key)

@export var api_client: UISPApiClient

var _url_input: LineEdit
var _token_input: LineEdit
var _connect_button: Button
var _status_label: Label
var _device_list: ItemList
var _panel: PanelContainer

# Settings file path
const SETTINGS_PATH = "user://uisp_settings.cfg"

func _ready() -> void:
	# IMPORTANT: Set this Control to ignore mouse events so it doesn't block other UIs
	# Only the child _panel should receive mouse events
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	_setup_ui()
	_load_settings()
	
	# Find API client if not set
	if api_client == null:
		_find_api_client()
	
	# Connect to API client signals
	if api_client != null:
		api_client.connection_status_changed.connect(_on_connection_status_changed)
		api_client.devices_updated.connect(_on_devices_updated)
		api_client.api_error.connect(_on_api_error)

## Show the UISP panel (called by TimeUI)
func show_panel() -> void:
	if _panel:
		_panel.visible = true
		_panel.mouse_filter = Control.MOUSE_FILTER_STOP

## Hide the UISP panel (called by TimeUI)
func hide_panel() -> void:
	if _panel:
		_panel.visible = false
		# IMPORTANT: Also disable mouse input so hidden panel doesn't block other UIs
		_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

func _find_api_client() -> void:
	var clients = get_tree().get_nodes_in_group("uisp_api_client")
	if clients.size() > 0:
		api_client = clients[0] as UISPApiClient
	else:
		# Create one if it doesn't exist
		api_client = UISPApiClient.new()
		api_client.name = "UISPApiClient"
		api_client.add_to_group("uisp_api_client")
		get_tree().root.add_child.call_deferred(api_client)

func _setup_ui() -> void:
	# Main panel
	_panel = PanelContainer.new()
	_panel.name = "UISPPanel"
	_panel.visible = false
	# Start with IGNORE so hidden panel doesn't block other UIs
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.anchor_left = 0.0
	_panel.anchor_top = 0.0
	_panel.anchor_right = 0.0
	_panel.anchor_bottom = 0.0
	_panel.offset_left = 20
	_panel.offset_top = 20
	_panel.offset_right = 420
	_panel.offset_bottom = 500
	
	# Panel styling
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.12, 0.15, 0.95)
	style.border_color = Color(0.2, 0.5, 0.9, 0.8)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(16)
	_panel.add_theme_stylebox_override("panel", style)
	
	add_child(_panel)
	
	# Main container
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	_panel.add_child(vbox)
	
	# Title
	var title = Label.new()
	title.text = "🌐 UISP Network Connection"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.3, 0.7, 1.0))
	vbox.add_child(title)
	
	# Separator
	var sep1 = HSeparator.new()
	sep1.add_theme_constant_override("separation", 8)
	vbox.add_child(sep1)
	
	# URL input
	var url_label = Label.new()
	url_label.text = "UISP URL"
	url_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(url_label)
	
	_url_input = LineEdit.new()
	_url_input.placeholder_text = "https://your-uisp.com"
	_url_input.custom_minimum_size.y = 36
	var url_style = StyleBoxFlat.new()
	url_style.bg_color = Color(0.15, 0.17, 0.2)
	url_style.border_color = Color(0.3, 0.35, 0.4)
	url_style.set_border_width_all(1)
	url_style.set_corner_radius_all(4)
	url_style.set_content_margin_all(8)
	_url_input.add_theme_stylebox_override("normal", url_style)
	vbox.add_child(_url_input)
	
	# Token input
	var token_label = Label.new()
	token_label.text = "API Token (from UISP → Settings → Users → Your User)"
	token_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(token_label)
	
	_token_input = LineEdit.new()
	_token_input.placeholder_text = "Your UISP API token"
	_token_input.secret = true
	_token_input.custom_minimum_size.y = 36
	_token_input.add_theme_stylebox_override("normal", url_style)
	vbox.add_child(_token_input)
	
	# Connect button
	_connect_button = Button.new()
	_connect_button.text = "Connect"
	_connect_button.custom_minimum_size.y = 40
	var btn_style = StyleBoxFlat.new()
	btn_style.bg_color = Color(0.2, 0.5, 0.9)
	btn_style.set_corner_radius_all(4)
	btn_style.set_content_margin_all(8)
	_connect_button.add_theme_stylebox_override("normal", btn_style)
	var btn_hover = btn_style.duplicate()
	btn_hover.bg_color = Color(0.3, 0.6, 1.0)
	_connect_button.add_theme_stylebox_override("hover", btn_hover)
	var btn_pressed = btn_style.duplicate()
	btn_pressed.bg_color = Color(0.15, 0.4, 0.8)
	_connect_button.add_theme_stylebox_override("pressed", btn_pressed)
	_connect_button.pressed.connect(_on_connect_pressed)
	vbox.add_child(_connect_button)
	
	# Status label
	_status_label = Label.new()
	_status_label.text = "⚪ Not connected"
	_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_status_label)
	
	# Separator
	var sep2 = HSeparator.new()
	sep2.add_theme_constant_override("separation", 8)
	vbox.add_child(sep2)
	
	# Device list header
	var device_header = Label.new()
	device_header.text = "Discovered Devices"
	device_header.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(device_header)
	
	# Device list
	_device_list = ItemList.new()
	_device_list.custom_minimum_size = Vector2(0, 150)
	_device_list.auto_height = false
	var list_style = StyleBoxFlat.new()
	list_style.bg_color = Color(0.08, 0.1, 0.12)
	list_style.border_color = Color(0.2, 0.25, 0.3)
	list_style.set_border_width_all(1)
	list_style.set_corner_radius_all(4)
	_device_list.add_theme_stylebox_override("panel", list_style)
	_device_list.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	_device_list.item_selected.connect(_on_device_selected)
	vbox.add_child(_device_list)
	
	# Help text
	var help_label = Label.new()
	help_label.text = "Press ESC to close settings"
	help_label.add_theme_font_size_override("font_size", 12)
	help_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	help_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(help_label)

func _on_connect_pressed() -> void:
	if api_client == null:
		_find_api_client()
	
	if api_client == null:
		_status_label.text = "❌ API client not found"
		_status_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
		return
	
	var url = _url_input.text.strip_edges()
	var token = _token_input.text.strip_edges()
	
	if url == "" or token == "":
		_status_label.text = "⚠️ Please enter URL and token"
		_status_label.add_theme_color_override("font_color", Color(0.9, 0.7, 0.2))
		return
	
	_status_label.text = "🔄 Connecting..."
	_status_label.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
	_connect_button.disabled = true
	
	# Save settings
	_save_settings()
	
	# Connect to UISP
	api_client.connect_to_uisp(url, token)

func _on_connection_status_changed(connected: bool) -> void:
	_connect_button.disabled = false
	
	if connected:
		_status_label.text = "✅ Connected"
		_status_label.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))
		_connect_button.text = "Refresh"
	else:
		_status_label.text = "⚪ Disconnected"
		_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		_connect_button.text = "Connect"
		_device_list.clear()

func _on_devices_updated(devices: Dictionary) -> void:
	_device_list.clear()
	
	for device_id in devices:
		var device = devices[device_id]
		var identification = device.get("identification", {})
		var overview = device.get("overview", {})
		
		var name = identification.get("name", device_id.substr(0, 8) + "...")
		var model = identification.get("model", "Unknown")
		var status = overview.get("status", "unknown")
		
		var icon = "🟢" if status == "active" else "🔴"
		var text = "%s %s (%s)" % [icon, name, model]
		
		var idx = _device_list.add_item(text)
		_device_list.set_item_metadata(idx, device_id)

func _on_api_error(endpoint: String, error_message: String) -> void:
	_connect_button.disabled = false
	_status_label.text = "❌ Error: %s" % error_message
	_status_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))

func _on_device_selected(index: int) -> void:
	var device_id = _device_list.get_item_metadata(index)
	
	# Copy device ID to clipboard for easy use
	DisplayServer.clipboard_set(device_id)
	
	# Show brief notification
	var original_text = _status_label.text
	_status_label.text = "📋 Device ID copied!"
	_status_label.add_theme_color_override("font_color", Color(0.5, 0.8, 1.0))
	
	await get_tree().create_timer(2.0).timeout
	
	if api_client != null and api_client._is_connected:
		_status_label.text = "✅ Connected"
		_status_label.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))
	else:
		_status_label.text = original_text

func _save_settings() -> void:
	var config = ConfigFile.new()
	config.set_value("uisp", "url", _url_input.text)
	config.set_value("uisp", "token", _token_input.text)
	config.save(SETTINGS_PATH)

func _load_settings() -> void:
	var config = ConfigFile.new()
	if config.load(SETTINGS_PATH) == OK:
		_url_input.text = config.get_value("uisp", "url", "")
		_token_input.text = config.get_value("uisp", "token", "")

