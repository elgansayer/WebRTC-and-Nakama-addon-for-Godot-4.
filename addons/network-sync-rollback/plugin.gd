tool
extends EditorPlugin


func _enter_tree() -> void:
	add_custom_type("NetworkTimer", "Node", preload("res://addons/network-sync-rollback/NetworkTimer.gd"), null)


func _exit_tree() -> void:
	remove_custom_type("NetworkTimer")
