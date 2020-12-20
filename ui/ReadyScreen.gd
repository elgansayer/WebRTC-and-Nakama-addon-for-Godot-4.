extends Control

var PeerStatus = preload("res://ui/PeerStatus.tscn");

onready var ready_button := $Panel/ReadyButton
onready var match_id_container := $Panel/MatchIDContainer
onready var match_id_label := $Panel/MatchIDContainer/MatchID
onready var status_container := $Panel/StatusContainer

signal ready_pressed ()

func _ready() -> void:
	clear_players()
	
	OnlineMatch.connect("player_joined", self, "_on_OnlineMatch_player_joined")
	OnlineMatch.connect("player_left", self, "_on_OnlineMatch_player_left")
	OnlineMatch.connect("player_status_changed", self, "_on_OnlineMatch_player_status_changed")
	OnlineMatch.connect("match_ready", self, "_on_OnlineMatch_match_ready")
	OnlineMatch.connect("match_not_ready", self, "_on_OnlineMatch_match_not_ready")

func initialize(players = [], match_id = '', clear = false):
	if players.size() > 0 or clear:
		clear_players()
	
	for session_id in players:
		add_player(session_id, players[session_id]['username'])
	
	if match_id:
		match_id_container.visible = true
		match_id_label.text = match_id
	else:
		match_id_container.visible = false
	
	ready_button.grab_focus()

func clear_players() -> void:
	for child in status_container.get_children():
		status_container.remove_child(child)
		child.queue_free()
	ready_button.disabled = true

func hide_match_id() -> void:
	match_id_container.visible = false

func add_player(session_id, username):
	if not status_container.has_node(session_id):
		var status = PeerStatus.instance()
		status_container.add_child(status)
		status.initialize(username)
		status.name = session_id

func remove_player(session_id):
	var status = status_container.get_node(session_id)
	if status:
		status.queue_free()

func set_status(session_id, status):
	var status_node = status_container.get_node(session_id)
	if status_node:
		status_node.set_status(status)

func get_status(session_id) -> String:
	var status_node = status_container.get_node(session_id)
	if status_node:
		return status_node.status
	return ''

func reset_status(status):
	for child in status_container.get_children():
		child.set_status(status)

func set_score(session_id, score: int) -> void:
	var status_node = status_container.get_node(session_id)
	if status_node:
		status_node.set_score(score)

func set_ready_button_enabled(enabled: bool = true):
	ready_button.disabled = !enabled
	if enabled:
		ready_button.grab_focus()

func _on_ReadyButton_pressed() -> void:
	emit_signal("ready_pressed")

func _on_MatchCopyButton_pressed() -> void:
	OS.clipboard = match_id_label.text

#####
# OnlineMatch callbacks:
#####

func _on_OnlineMatch_player_joined(player):
	add_player(player.session_id, player.username)

func _on_OnlineMatch_player_left(player):
	remove_player(player.session_id)

func _on_OnlineMatch_player_status_changed(player, status):
	if status == OnlineMatch.PlayerStatus.CONNECTED:
		# Don't go backwards from 'READY!'
		if get_status(player.session_id) != 'READY!':
			set_status(player.session_id, 'Connected.')
	elif status == OnlineMatch.PlayerStatus.CONNECTING:
		set_status(player.session_id, 'Connecting...')

func _on_OnlineMatch_match_ready(_players):
	set_ready_button_enabled(true)

func _on_OnlineMatch_match_not_ready():
	set_ready_button_enabled(false)
