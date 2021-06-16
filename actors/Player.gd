extends KinematicBody2D

onready var player_name_label := $NameRect/NameLabel
onready var hit_box = $HitBox
onready var animation_player := $AnimationPlayer

export (bool) var player_controlled := false
export (String) var input_prefix := "player1_"

var speed := 400.0

signal player_dead ()

enum PlayerInputType {
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
		input[PlayerInputType.INPUT_VECTOR] = input_vector
	
	if Input.is_action_just_pressed(input_prefix + "attack"):
		input[PlayerInputType.ATTACK_PRESSED] = true
	
	return input

func _predict_network_input(previous_input: Dictionary) -> Dictionary:
	var predicted = previous_input.duplicate()
	predicted.erase(PlayerInputType.ATTACK_PRESSED)
	return predicted

func _network_process(delta: float, input: Dictionary, sync_manager) -> void:
	if animation_player.is_playing():
		animation_player.advance(delta)
	
	var vector = input.get(PlayerInputType.INPUT_VECTOR, Vector2.ZERO)
	vector *= (speed * delta)
	move_and_collide(vector)
	
	var is_attacking: bool = not animation_player.is_playing() and input.get(PlayerInputType.ATTACK_PRESSED, false)
	if is_attacking:
		animation_player.play("Attack")

func _save_state() -> Dictionary:
	var state = {
		position = position,
		animation_player_is_playing = false,
		animation_player_current_animation = '',
		animation_player_current_position = 0.0,
	}
	if animation_player.is_playing():
		state['animation_player_is_playing'] = true
		state['animation_player_current_animation'] = animation_player.current_animation
		state['animation_player_current_position'] = animation_player.current_animation_position
	return state

func _load_state(state: Dictionary) -> void:
	position = state['position']
	animation_player.stop()
	if state['animation_player_is_playing']:
		animation_player.play(state['animation_player_current_animation'])
		# @todo maybe use .advance() instead? (idea from Thomas Szot)
		animation_player.seek(state['animation_player_current_position'], true)

