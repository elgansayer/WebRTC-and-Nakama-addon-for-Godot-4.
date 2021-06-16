tool
extends EditorPlugin


func _enter_tree() -> void:
	add_custom_type("NetworkTimer", "Node", preload("res://addons/network-sync-rollback/NetworkTimer.gd"), null)
	add_custom_type("NetworkAnimationPlayer", "AnimationPlayer", preload("res://addons/network-sync-rollback/NetworkAnimationPlayer.gd"), null)


func _exit_tree() -> void:
	remove_custom_type("NetworkTimer")
	remove_custom_type("NetworkAnimationPlayer")
