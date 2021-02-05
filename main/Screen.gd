extends Control

export (bool) var add_to_stack := true

var ui_layer: UILayer

func _setup_screen(_ui_layer: UILayer) -> void:
	ui_layer = _ui_layer

func _show_screen(_info: Dictionary = {}) -> void:
	pass

func _hide_screen() -> void:
	pass
