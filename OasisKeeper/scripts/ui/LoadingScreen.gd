extends Control
## Loading screen shown during map generation.

@onready var label: Label = $MarginContainer/VBoxContainer/Label
@onready var progress: ProgressBar = $MarginContainer/VBoxContainer/ProgressBar

var _current_message: String = "Generating terrain..."

func _ready() -> void:
	visible = false
	progress.visible = false
	progress.value = 0

func show_loading(message: String = "Generating terrain...") -> void:
	_current_message = message
	label.text = message
	progress.visible = true
	progress.value = 0
	visible = true

func hide_loading() -> void:
	visible = false

func update_progress(value: float) -> void:
	progress.value = value * 100.0
