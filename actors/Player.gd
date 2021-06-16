extends KinematicBody2D

onready var player_name_label := $NameRect/NameLabel
onready var hit_box = $HitBox
onready var animation_player := $AnimationPlayer

export (bool) var player_controlled := false
export (String) var input_prefix := "player1_"

var speed := 400.0

signal player_dead ()

enum PlayerInputKey {
	INPUT_VECTOR,
	ATTACK_PRESSED,
}

func set_player_name(player_name: String) -> void:
	player_name_label.text = player_name

func attack() -> void:
	for body in hit_box.get_overlapping_bodies():
		if body == self:
			continue
		if body.has_method("hurt"):
			body.hurt()

func hurt() -> void:
	die()

func die() -> void:
	# Add what you want to happen in your game when a player dies.
	queue_free()
	emit_signal("player_dead")

func _get_local_input() -> Dictionary:
	var input := {}
	
	var input_vector = Vector2(
		Input.get_action_strength(input_prefix + "right") - Input.get_action_strength(input_prefix + "left"),
		Input.get_action_strength(input_prefix + "down") - Input.get_action_strength(input_prefix + "up")).normalized()
	if input_vector != Vector2.ZERO:
		input[PlayerInputKey.INPUT_VECTOR] = input_vector
	
	if Input.is_action_just_pressed(input_prefix + "attack"):
		input[PlayerInputKey.ATTACK_PRESSED] = true
	
	return input

func _predict_network_input(previous_input: Dictionary) -> Dictionary:
	var predicted = previous_input.duplicate()
	predicted.erase(PlayerInputKey.ATTACK_PRESSED)
	return predicted

func _network_process(delta: float, input: Dictionary, sync_manager) -> void:
	var vector = input.get(PlayerInputKey.INPUT_VECTOR, Vector2.ZERO)
	vector *= (speed * delta)
	move_and_collide(vector)
	
	var is_attacking: bool = not animation_player.is_playing() and input.get(PlayerInputKey.ATTACK_PRESSED, false)
	if is_attacking:
		animation_player.play("Attack")

func _save_state() -> Dictionary:
	return {
		position = position,
	}

func _load_state(state: Dictionary) -> void:
	position = state['position']
