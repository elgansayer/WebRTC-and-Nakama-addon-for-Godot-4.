extends "res://addons/network-sync-rollback/SyncManager.gd"

func _gather_local_input(player_index: int) -> Dictionary:
	var input_prefix = "player%s_" % player_index
	var input_vector = Vector2(
			Input.get_action_strength(input_prefix + "right") - Input.get_action_strength(input_prefix + "left"),
			Input.get_action_strength(input_prefix + "down") - Input.get_action_strength(input_prefix + "up")).normalized()
	
	if input_vector != Vector2.ZERO:
		print(input_vector)
	
	return {
		input_vector = input_vector,
		attack_pressed = Input.is_action_just_pressed(input_prefix + "attack"),
	}

func _predict_input(previous_input: Dictionary) -> Dictionary:
	var predicted = previous_input.duplicate()
	predicted['attack_pressed'] = false
	return predicted
