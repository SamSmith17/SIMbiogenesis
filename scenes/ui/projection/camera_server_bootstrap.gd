extends Node

signal feeds_rescan_completed(feed_count: int, feed_names: PackedStringArray, status_message: String)

var extension: Object = null
var last_status_message: String = "Camera extension not initialized"
var _feeds_updated_connected: bool = false

func _ready() -> void:
	rescan_feeds()

func rescan_feeds() -> Dictionary:
	_teardown_extension()
	CameraServer.monitoring_feeds = true

	if not ClassDB.class_exists("CameraServerExtension"):
		last_status_message = "CameraServerExtension plugin not loaded"
		_emit_rescan_result()
		return _result_dictionary()

	extension = ClassDB.instantiate("CameraServerExtension")
	if extension == null:
		last_status_message = "CameraServerExtension failed to initialize"
		_emit_rescan_result()
		return _result_dictionary()

	_connect_feed_signals()
	_warn_if_camera_permission_blocked()

	var feed_names := _collect_feed_names()
	if feed_names.is_empty():
		last_status_message = "No camera feeds detected. Start OBS Virtual Camera, then refresh."
	else:
		last_status_message = "Detected %s: %s" % [UiText.count(feed_names.size(), "feed"), ", ".join(feed_names)]

	_emit_rescan_result()
	return _result_dictionary()

func get_feed_names() -> PackedStringArray:
	return _collect_feed_names()

func get_feed_count() -> int:
	return CameraServer.get_feed_count()

func is_ready() -> bool:
	return extension != null

func permission_granted() -> bool:
	if extension == null or not extension.has_method("permission_granted"):
		return true
	return bool(extension.call("permission_granted"))

func _teardown_extension() -> void:
	_disconnect_feed_signals()
	extension = null

func _connect_feed_signals() -> void:
	if _feeds_updated_connected:
		return
	if not CameraServer.camera_feeds_updated.is_connected(_on_camera_feeds_updated):
		CameraServer.camera_feeds_updated.connect(_on_camera_feeds_updated)
	_feeds_updated_connected = true

func _disconnect_feed_signals() -> void:
	if not _feeds_updated_connected:
		return
	if CameraServer.camera_feeds_updated.is_connected(_on_camera_feeds_updated):
		CameraServer.camera_feeds_updated.disconnect(_on_camera_feeds_updated)
	_feeds_updated_connected = false

func _on_camera_feeds_updated() -> void:
	var feed_names := _collect_feed_names()
	if feed_names.is_empty():
		last_status_message = "No camera feeds detected. Start OBS Virtual Camera, then refresh."
	else:
		last_status_message = "Detected %s: %s" % [UiText.count(feed_names.size(), "feed"), ", ".join(feed_names)]
	feeds_rescan_completed.emit(feed_names.size(), feed_names, last_status_message)

func _collect_feed_names() -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	for feed in CameraServer.feeds():
		var feed_name: String = str(feed.get_name()).strip_edges()
		if feed_name == "":
			feed_name = "Camera Feed %d" % int(feed.get_id())
		names.append(feed_name)
	return names

func _warn_if_camera_permission_blocked() -> void:
	if permission_granted():
		return
	if OS.get_name() == "Windows":
		last_status_message += " Windows camera access may be blocked in Privacy settings."

func _emit_rescan_result() -> void:
	feeds_rescan_completed.emit(get_feed_count(), get_feed_names(), last_status_message)

func _result_dictionary() -> Dictionary:
	return {
		"feed_count": get_feed_count(),
		"feed_names": get_feed_names(),
		"status_message": last_status_message,
	}
