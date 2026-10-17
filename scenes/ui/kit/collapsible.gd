class_name Collapsible
extends FoldableContainer

## THE collapsible section: Godot's FoldableContainer, styled by the shared
## Theme (UiThemeBuilder: a quiet title row with a Lucide chevron, small
## semibold caps, no box round the body), holding one VBox `body` the caller
## fills. Replaces the hand-rolled "▸ Title" / "▾ Title" toggle buttons that
## each kept their own open flag and redrew their own arrow.
##
##   var sec := Collapsible.make("Advanced", false)
##   parent.add_child(sec)
##   sec.body.add_child(row)
##   sec.folding_changed.connect(func(folded): _save_open(not folded))

var body: VBoxContainer


static func make(title_text: String, open: bool = true, tip: String = "") -> Collapsible:
	var c := Collapsible.new()
	c.title = title_text
	c.folded = not open
	c.tooltip_text = tip
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.body = VBoxContainer.new()
	c.body.add_theme_constant_override("separation", UITheme.SPACE_XS)
	c.body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.add_child(c.body)
	return c


func is_open() -> bool:
	return not folded


func set_open(open: bool) -> void:
	folded = not open
