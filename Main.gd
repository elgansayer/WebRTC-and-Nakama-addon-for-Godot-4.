extends Node2D

onready var game = $Game
onready var ui_layer: UILayer = $UILayer
onready var ready_screen = $UILayer/Screens/ReadyScreen
onready var show_score_timer = $ShowScoreTimer
onready var next_round_timer = $NextRoundTimer

var players := {}

var players_ready := {}
var players_score := {}
var match_over := false

func _ready() -> void:
	OnlineMatch.connect("error", self, "_on_OnlineMatch_error")
	OnlineMatch.connect("disconnected", self, "_on_OnlineMatch_disconnected")
	OnlineMatch.connect("player_status_changed", self, "_on_OnlineMatch_player_status_changed")
	OnlineMatch.connect("player_left", self, "_on_OnlineMatch_player_left")
	SyncManager.connect("sync_error", self, "_on_SyncManager_sync_error")

#func _unhandled_input(event: InputEvent) -> void:
#	# Trigger debugging action!
#	if event.is_action_pressed("player_debug"):
#		# Close all our peers to force a reconnect (to make sure it works).
#		for session_id in OnlineMatch.webrtc_peers:
#			var webrtc_peer = OnlineMatch._webrtc_peers[session_id]
#			webrtc_peer.close()

#####
# UI callbacks
#####

func _on_TitleScreen_play_local() -> void:
	GameState.online_play = false
	
	ui_layer.hide_screen()
	ui_layer.show_back_button()
	
	start_game()

func _on_TitleScreen_play_online() -> void:
	GameState.online_play = true
	
	# Show the game map in the background because we have nothing better.
	game.reload_map()
	
	ui_layer.show_screen("ConnectionScreen")

func _on_UILayer_change_screen(name: String, _screen) -> void:
	if name == 'TitleScreen':
		ui_layer.hide_back_button()
	else:
		ui_layer.show_back_button()

func _on_UILayer_back_button() -> void:
	ui_layer.hide_message()
	
	stop_game()
	
	if ui_layer.current_screen_name in ['ConnectionScreen', 'MatchScreen']:
		ui_layer.show_screen("TitleScreen")
	elif not GameState.online_play:
		ui_layer.show_screen("TitleScreen")
	else:
		ui_layer.show_screen("MatchScreen")

func _on_ReadyScreen_ready_pressed() -> void:
	rpc("player_ready", OnlineMatch.get_my_session_id())

#####
# OnlineMatch callbacks
#####

func _on_OnlineMatch_error(message: String):
	if message != '':
		ui_layer.show_message(message)
	ui_layer.show_screen("MatchScreen")
	SyncManager.stop()
	SyncManager.clear_peers()

func _on_OnlineMatch_disconnected():
	#_on_OnlineMatch_error("Disconnected from host")
	_on_OnlineMatch_error('')

func _on_OnlineMatch_player_left(player) -> void:
	ui_layer.show_message(player.username + " has left")
	
	game.kill_player(player.peer_id)
	
	SyncManager.remove_peer(player.peer_id)
	
	players.erase(player.peer_id)
	players_ready.erase(player.peer_id)

func _on_OnlineMatch_player_status_changed(player, status) -> void:
	if status == OnlineMatch.PlayerStatus.CONNECTED:
		if player.peer_id != get_tree().get_network_unique_id():
			SyncManager.add_peer(player.peer_id)
		if get_tree().is_network_server():
			# Tell this new player about all the other players that are already ready.
			for session_id in players_ready:
				rpc_id(player.peer_id, "player_ready", session_id)

func _on_SyncManager_sync_error(_msg: String) -> void:
	OnlineMatch.leave()
	SyncManager.clear_peers()
	ui_layer.show_message("Synchronization lost")

#####
# Gameplay methods and callbacks
#####

remotesync func player_ready(session_id: String) -> void:
	ready_screen.set_status(session_id, "READY!")
	
	if get_tree().is_network_server() and not players_ready.has(session_id):
		players_ready[session_id] = true
		if players_ready.size() == OnlineMatch.players.size():
			if OnlineMatch.match_state != OnlineMatch.MatchState.PLAYING:
				OnlineMatch.start_playing()
			start_game()

func start_game(immediate: bool = false) -> void:
	if GameState.online_play:
		players = OnlineMatch.get_player_names_by_peer_id()
	else:
		players = {
			1: "Player1",
			2: "Player2",
		}
	
	game.game_start(players, immediate)

func stop_game(leave: bool = true) -> void:
	if leave:
		OnlineMatch.leave()
	
	show_score_timer.stop()
	next_round_timer.stop()
	
	players.clear()
	players_ready.clear()
	players_score.clear()
	match_over = false
	
	game.game_stop()

func restart_game() -> void:
	stop_game(false)
	start_game(true)

func _on_Game_game_started() -> void:
	# @todo This is kind of a hack - we need a better way to set this always.
	if players.size() == 0 and GameState.online_play:
		players = OnlineMatch.get_player_names_by_peer_id()
	
	ui_layer.hide_screen()
	ui_layer.hide_all()
	ui_layer.show_back_button()

func _on_Game_player_dead(player_id: int) -> void:
	if GameState.online_play:
		var my_id = get_tree().get_network_unique_id()
		if player_id == my_id:
			ui_layer.show_message("You lose!")

func _on_Game_game_over(player_id: int) -> void:
	if not GameState.online_play:
		show_winner(players[player_id])
	else:
		if not players_score.has(player_id):
			players_score[player_id] = 1
		else:
			players_score[player_id] += 1
		
		match_over = players_score[player_id] >= 5
		show_winner(players[player_id])

func show_winner(name: String) -> void:
	if match_over:
		ui_layer.show_message(name + " WINS THE WHOLE MATCH!")
	else:
		ui_layer.show_message(name + " wins this round!")
	
	show_score_timer.start()

func _on_ShowScoreTimer_timeout() -> void:
	if not game.game_started:
		return
	
	if GameState.online_play:
		if match_over:
			stop_game()
			ui_layer.show_screen("MatchScreen")
			ready_screen.show_ready_button()
		else:
			ready_screen.hide_match_id()
			ready_screen.reset_status("Waiting...")
			ready_screen.hide_ready_button()
			for player_id in players_score:
				var player_session_id = OnlineMatch.get_session_id(player_id)
				ready_screen.set_score(player_session_id, players_score.get(player_id, 0))
			ui_layer.show_screen("ReadyScreen")
			next_round_timer.start()
	else:
		restart_game()

func _on_NextRoundTimer_timeout() -> void:
	restart_game()

func _save_state() -> Dictionary:
	return {
		players_score = players_score.duplicate(),
	}

func _load_state(state: Dictionary) -> void:
	players_score = state['players_score'].duplicate()
