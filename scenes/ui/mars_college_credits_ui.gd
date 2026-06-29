extends CanvasLayer

## HUD for Mars College Credits earned by extinguishing fires with the extinguisher.

const CREDITS_PER_FIRE : int = 16
const POPUP_SHOW_SEC : float = 1.0
const POPUP_FADE_SEC : float = 0.4

var total_credits : int = 0

var _root : Control
var _total_label : Label
var _popup_label : Label
var _popup_tween : Tween


func _ready() -> void :
	layer = 25
	add_to_group( "mars_college_credits_ui" )
	_root = Control.new()
	_root.set_anchors_preset( Control.PRESET_FULL_RECT )
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child( _root )

	_total_label = Label.new()
	_total_label.text = "Mars College Credits: 0"
	_total_label.position = Vector2( 20, 20 )
	_total_label.add_theme_font_size_override( "font_size", 20 )
	_total_label.add_theme_color_override( "font_color", Color( 1.0, 0.92, 0.65 ) )
	_total_label.add_theme_color_override( "font_outline_color", Color( 0.05, 0.02, 0.0 ) )
	_total_label.add_theme_constant_override( "outline_size", 6 )
	_root.add_child( _total_label )

	_popup_label = Label.new()
	_popup_label.text = "Another %d Mars College Credits!" % CREDITS_PER_FIRE
	_popup_label.visible = false
	_popup_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_popup_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_popup_label.add_theme_font_size_override( "font_size", 52 )
	_popup_label.add_theme_color_override( "font_color", Color( 1.0, 0.88, 0.25 ) )
	_popup_label.add_theme_color_override( "font_shadow_color", Color( 0, 0, 0, 0.85 ) )
	_popup_label.add_theme_constant_override( "shadow_offset_x", 4 )
	_popup_label.add_theme_constant_override( "shadow_offset_y", 4 )
	_popup_label.add_theme_color_override( "font_outline_color", Color( 0.15, 0.05, 0.0 ) )
	_popup_label.add_theme_constant_override( "outline_size", 10 )
	_popup_label.set_anchors_preset( Control.PRESET_CENTER )
	_popup_label.offset_left = -640.0
	_popup_label.offset_top = -80.0
	_popup_label.offset_right = 640.0
	_popup_label.offset_bottom = 80.0
	_popup_label.pivot_offset = Vector2( 640, 80 )
	_root.add_child( _popup_label )


func collect_save_state() -> Dictionary :
	return { "total_credits": total_credits }


func apply_save_state( data: Dictionary ) -> void :
	total_credits = int( data.get( "total_credits", total_credits ) )
	_refresh_total_label()


## Called via SceneTree group when the player helps extinguish a fire.
func on_fire_extinguished_reward() -> void :
	total_credits += CREDITS_PER_FIRE
	_refresh_total_label()
	_play_popup()


func _refresh_total_label() -> void :
	if _total_label != null :
		_total_label.text = "Mars College Credits: %d" % total_credits


func _play_popup() -> void :
	if _popup_label == null :
		return
	if _popup_tween != null and _popup_tween.is_valid() :
		_popup_tween.kill()
	_popup_label.text = "Another %d Mars College Credits!" % CREDITS_PER_FIRE
	_popup_label.visible = true
	_popup_label.modulate = Color( 1, 1, 1, 1 )
	_popup_label.scale = Vector2( 0.35, 0.35 )

	_popup_tween = create_tween()
	_popup_tween.tween_property( _popup_label, "scale", Vector2.ONE * 1.08, 0.35 ).set_trans( Tween.TRANS_BACK ).set_ease( Tween.EASE_OUT )
	_popup_tween.tween_property( _popup_label, "scale", Vector2.ONE, 0.2 ).set_trans( Tween.TRANS_QUAD ).set_ease( Tween.EASE_IN_OUT )
	_popup_tween.tween_interval( POPUP_SHOW_SEC )
	_popup_tween.parallel()
	_popup_tween.tween_property( _popup_label, "modulate:a", 0.0, POPUP_FADE_SEC )
	_popup_tween.tween_property( _popup_label, "scale", Vector2( 1.12, 1.12 ), POPUP_FADE_SEC ).set_trans( Tween.TRANS_QUAD ).set_ease( Tween.EASE_IN )
	_popup_tween.tween_callback( func() -> void :
		if is_instance_valid( _popup_label ) :
			_popup_label.visible = false
	)
