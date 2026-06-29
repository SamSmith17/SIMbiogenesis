extends CanvasLayer

signal continue_requested
signal load_slot_requested(slot_index: int)
signal save_slot_requested(slot_index: int)
signal delete_slot_requested(slot_index: int)

@onready var root: Control = $Root
@onready var slot_list: ItemList = $Root/Panel/Margin/VBox/SlotList
@onready var continue_btn: Button = $Root/Panel/Margin/VBox/ButtonsRow1/ContinueButton
@onready var save_btn: Button = $Root/Panel/Margin/VBox/ButtonsRow1/SaveButton
@onready var load_btn: Button = $Root/Panel/Margin/VBox/ButtonsRow1/LoadButton
@onready var delete_btn: Button = $Root/Panel/Margin/VBox/ButtonsRow2/DeleteButton
@onready var close_btn: Button = $Root/Panel/Margin/VBox/ButtonsRow2/CloseButton
@onready var status_label: Label = $Root/Panel/Margin/VBox/StatusLabel
@onready var confirm_overwrite: ConfirmationDialog = $ConfirmOverwrite
@onready var confirm_delete: ConfirmationDialog = $ConfirmDelete

var _main_node: Node = null
var _visible: bool = false
var _pending_save_slot: int = -1


func _save_game() -> SaveGameService:
	var st := get_tree()
	if st == null:
		return null
	return st.root.get_node_or_null("SaveSystem") as SaveGameService


func _ready() -> void:
	layer = 50
	add_to_group("save_load_ui")
	var p := get_parent()
	if p != null:
		_main_node = p.get_parent()
	root.visible = false
	_visible = false
	continue_btn.pressed.connect(_on_continue_pressed)
	save_btn.pressed.connect(_on_save_pressed)
	load_btn.pressed.connect(_on_load_pressed)
	delete_btn.pressed.connect(_on_delete_pressed)
	close_btn.pressed.connect(hide_panel)
	confirm_overwrite.confirmed.connect(_on_overwrite_confirmed)
	if confirm_overwrite.has_signal("canceled"):
		confirm_overwrite.canceled.connect(_on_overwrite_canceled)
	confirm_delete.confirmed.connect(_on_delete_confirmed)
	if confirm_delete.has_signal("canceled"):
		confirm_delete.canceled.connect(_on_delete_canceled)
	refresh_slot_list()


func is_panel_visible() -> bool:
	return _visible


func _unhandled_input(event: InputEvent) -> void:
	if not _visible:
		return
	if event.is_action_pressed("ui_cancel"):
		hide_panel()
		get_viewport().set_input_as_handled()


func show_panel() -> void:
	root.visible = true
	_visible = true
	refresh_slot_list()
	status_label.text = ""
	CursorController.request_modal("save_load", Callable(self, "hide_panel"))


func hide_panel() -> void:
	root.visible = false
	_visible = false
	CursorController.release_modal("save_load")


func refresh_slot_list() -> void:
	slot_list.clear()
	var sg := _save_game()
	if sg == null:
		return
	var rows: Array = sg.list_slot_summaries()
	for row in rows:
		if row is Dictionary:
			var d: Dictionary = row
			var idx: int = int(d.get("index", 0))
			var exists: bool = bool(d.get("exists", false))
			var summary: String = str(d.get("summary", ""))
			var line := "Slot %d — %s" % [idx + 1, "Empty" if not exists else summary]
			slot_list.add_item(line)
	if slot_list.item_count > 0:
		slot_list.select(0)


func _selected_slot() -> int:
	var sel: PackedInt32Array = slot_list.get_selected_items()
	if sel.is_empty():
		return 0
	return int(sel[0])


func _on_continue_pressed() -> void:
	var sg := _save_game()
	if sg == null or not sg.can_continue():
		show_load_message("No save to continue from.", false)
		return
	continue_requested.emit()


func _on_save_pressed() -> void:
	var idx := _selected_slot()
	var sg := _save_game()
	if sg == null:
		return
	var path: String = sg.get_manual_slot_path(idx)
	if FileAccess.file_exists(path):
		_pending_save_slot = idx
		confirm_overwrite.dialog_text = "Overwrite slot %d?" % (idx + 1)
		confirm_overwrite.popup_centered()
		return
	_do_save_slot(idx)


func _on_overwrite_confirmed() -> void:
	if _pending_save_slot >= 0:
		_do_save_slot(_pending_save_slot)
	_pending_save_slot = -1


func _on_overwrite_canceled() -> void:
	_pending_save_slot = -1


func _do_save_slot(idx: int) -> void:
	save_slot_requested.emit(idx)
	refresh_slot_list()
	status_label.text = "Saved to slot %d." % (idx + 1)


func _on_load_pressed() -> void:
	var idx := _selected_slot()
	var sg := _save_game()
	if sg == null:
		return
	var path: String = sg.get_manual_slot_path(idx)
	if not FileAccess.file_exists(path):
		show_load_message("Slot %d is empty." % (idx + 1), false)
		return
	load_slot_requested.emit(idx)


func show_load_message(text: String, _success: bool = true) -> void:
	status_label.text = text


var _pending_delete_slot: int = -1


func _on_delete_pressed() -> void:
	var idx := _selected_slot()
	var sg := _save_game()
	if sg == null:
		return
	var path: String = sg.get_manual_slot_path(idx)
	if not FileAccess.file_exists(path):
		status_label.text = "Slot %d is already empty." % (idx + 1)
		return
	_pending_delete_slot = idx
	confirm_delete.dialog_text = "Delete save in slot %d? This cannot be undone." % (idx + 1)
	confirm_delete.popup_centered()


func _on_delete_confirmed() -> void:
	if _pending_delete_slot >= 0:
		delete_slot_requested.emit(_pending_delete_slot)
		refresh_slot_list()
		status_label.text = "Deleted slot %d." % (_pending_delete_slot + 1)
	_pending_delete_slot = -1


func _on_delete_canceled() -> void:
	_pending_delete_slot = -1
