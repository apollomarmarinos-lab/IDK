class_name UILayout
extends RefCounted
## Explicit anchor + offset helpers.
##
## Why not Control.set_anchors_preset(): with its default keep_offsets=false
## it *recalculates the offsets to preserve the control's current rect*. A
## Control declared in a .tscn with no size starts at 0x0, so the preset
## faithfully preserves 0x0 and the panel never appears. Setting anchors and
## offsets explicitly leaves no room for that surprise.

## Anchors and offsets in one call. Offsets are in pixels; negative values
## measure back from the anchored edge, as usual for Control.
static func set_rect(c: Control,
		anchor_left: float, anchor_top: float, anchor_right: float, anchor_bottom: float,
		offset_left: float, offset_top: float, offset_right: float, offset_bottom: float) -> void:
	c.anchor_left = anchor_left
	c.anchor_top = anchor_top
	c.anchor_right = anchor_right
	c.anchor_bottom = anchor_bottom
	c.offset_left = offset_left
	c.offset_top = offset_top
	c.offset_right = offset_right
	c.offset_bottom = offset_bottom

## Fills the parent entirely.
static func fill(c: Control) -> void:
	set_rect(c, 0, 0, 1, 1, 0, 0, 0, 0)

## Full-width strip pinned to the top.
static func top_bar(c: Control, height: float) -> void:
	set_rect(c, 0, 0, 1, 0, 0, 0, 0, height)

## Full-width strip pinned to the bottom.
static func bottom_bar(c: Control, height: float) -> void:
	set_rect(c, 0, 1, 1, 1, 0, -height, 0, 0)

## Vertical panel down the left edge, inset from top and bottom.
static func left_panel(c: Control, width: float, top_inset: float, bottom_inset: float) -> void:
	set_rect(c, 0, 0, 0, 1, 0, top_inset, width, -bottom_inset)

## Box pinned to the bottom-right corner.
static func bottom_right(c: Control, width: float, height: float, bottom_inset: float) -> void:
	set_rect(c, 1, 1, 1, 1, -width, -(height + bottom_inset), 0, -bottom_inset)

## Gives a PanelContainer an opaque dark background. The default theme panel
## is semi-transparent, which leaves terrain showing through UI text.
static func style_panel(p: PanelContainer, content_margin: float = 10.0) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.09, 0.08, 0.96)
	sb.border_color = Color(0.32, 0.28, 0.22, 1.0)
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.content_margin_left = content_margin
	sb.content_margin_right = content_margin
	sb.content_margin_top = content_margin * 0.6
	sb.content_margin_bottom = content_margin * 0.6
	p.add_theme_stylebox_override("panel", sb)
