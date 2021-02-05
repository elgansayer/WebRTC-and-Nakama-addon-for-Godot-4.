extends CanvasLayer
class_name UILayer

onready var screens = $Screens
onready var message_label = $Overlay/Message
onready var back_button = $Overlay/BackButton

signal change_screen (name, screen)
signal back_button ()

var current_screen: Control = null setget _set_readonly_variable
var current_screen_name: String = '' setget _set_readonly_variable, get_current_screen_name
var screen_stack := []

var _is_ready := false

func _set_readonly_variable(_value) -> void:
	pass

func _ready() -> void:
	for screen in screens.get_children():
		if screen.has_method('_setup_screen'):
			screen._setup_screen(self)
			screen.visible = false
	
	var first_screen = screens.get_child(0)
	if first_screen:
		show_screen("TitleScreen")
	_is_ready = true

func get_current_screen_name() -> String:
	if current_screen:
		return current_screen.name
	return ''

func _screen_stack_append(name: String) -> void:
	if screen_stack.size() == 0 or screen_stack.back() != name:
		screen_stack.append(name)

func show_screen(name: String, info: Dictionary = {}) -> void:
	var screen = screens.get_node(name)
	if not screen:
		return
	
	_do_hide_screen()
	screen.visible = true
	if screen.has_method("_show_screen"):
		screen.callv("_show_screen", [info])
	current_screen = screen
	
	var add_to_stack = current_screen.get("add_to_stack")
	if add_to_stack:
		_screen_stack_append(name)
	
	if screen_stack.size() > 1:
		show_back_button()
	else:
		hide_back_button()
	
	if _is_ready:
		emit_signal("change_screen", name, screen)

func hide_screen(add_to_stack: bool = true) -> void:
	if add_to_stack:
		_screen_stack_append('')
	_do_hide_screen()

func _do_hide_screen() -> void:
	if current_screen:
		if current_screen.has_method('_hide_screen'):
			current_screen._hide_screen()
		current_screen.visible = false
		current_screen = null

func go_back() -> void:
	if screen_stack.size() > 1:
		screen_stack.pop_back()
		emit_signal("back_button")
		show_screen(screen_stack.back())

func show_message(text: String) -> void:
	message_label.text = text
	message_label.visible = true

func hide_message() -> void:
	message_label.visible = false

func show_back_button() -> void:
	back_button.visible = true

func hide_back_button() -> void:
	back_button.visible = false

func _on_BackButton_pressed() -> void:
	go_back()
