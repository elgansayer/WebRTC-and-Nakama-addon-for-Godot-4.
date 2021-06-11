extends KinematicBody2D

onready var player_name_label := $NameRect/NameLabel
onready var hit_box = $HitBox
onready var animation_player := $AnimationPlayer

export (bool) var player_controlled := false
export (String) var input_prefix := "player1_"

var speed := 400.0

signal player_dead ()

func set_player_name(player_name: String) -> void:
	player_name_label.text = player_name

func attack() -> void:
	for body in hit_box.get_overlapping_bodies():
		if body == self:
			continue
		if body.has_method("hurt"):
			body.hurt()

func hurt() -> void:
	if not GameState.online_play:
		die()
	elif is_network_master():
		rpc("die")

remotesync func die() -> void:
	# Add what you want to happen in your game when a player dies.
	queue_free()
	emit_signal("player_dead")

func _network_process(delta: float, input_frame, sync_manager) -> void:
	var input = input_frame.players[get_network_master()].input
	var vector = input.get('input_vector', Vector2.ZERO)
	vector *= (speed * delta)
	move_and_collide(vector)
	
	var is_attacking: bool = not animation_player.is_playing() and input.get('attack_pressed', false)
	if is_attacking:
		animation_player.play("Attack")
	
	#if GameState.online_play and player_controlled:
	#	rpc("update_remote_player", global_position, is_attacking)

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

# Extremely naive position and animation sync'ing.
#
# This will work locally, and under ideal network conditions, but likely won't 
# be acceptable over the live internet for a large percentage of users.
#
# You'll need to replace this with more efficient sync'ing mechanism, which
# could include input prediction, rollback, limiting how often sync'ing happens
# or any other number of techniques.
#
# In addition to that, you'll also need to expand the number of things that are
# sync'd, depending on the needs of your game.
puppet func update_remote_player(_position: Vector2, is_attacking: bool) -> void:
	global_position = _position
	
	if is_attacking and not animation_player.is_playing():
		animation_player.play("Attack")
