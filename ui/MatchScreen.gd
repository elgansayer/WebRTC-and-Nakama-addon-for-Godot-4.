extends Control

onready var matchmaker_player_count_control := $PanelContainer/VBoxContainer/MatchPanel/SpinBox
onready var join_match_id_control := $PanelContainer/VBoxContainer/JoinPanel/LineEdit

func initialize() -> void:
	matchmaker_player_count_control.value = 2
	join_match_id_control.text = ''

func _check_session() -> bool:
	if Online.nakama_session == null or Online.nakama_session.is_expired():
		UI.show_message("Login session has expired")
		UI.show_screen("ConnectionScreen")
		return false
	return true

func _on_MatchButton_pressed() -> void:
	var min_players = matchmaker_player_count_control.value
	
	if _check_session():
		UI.hide_screen()
		UI.show_message("Looking for match...")
		UI.show_back_button()
		
		var data = {
			min_count = min_players,
			string_properties = {
				game = "test_game",
			},
			query = "+properties.game:test_game",
		}
		
		# @todo Is there a sane way to avoid duplicating this code?
		if not Online.is_nakama_socket_connected():
			Online.connect_nakama_socket()
			yield(Online, "socket_connected")
		
		OnlineMatch.start_matchmaking(Online.nakama_socket, data)

func _on_CreateButton_pressed() -> void:
	if _check_session():
		# @todo Is there a sane way to avoid duplicating this code?
		if not Online.is_nakama_socket_connected():
			Online.connect_nakama_socket()
			yield(Online, "socket_connected")
		
		OnlineMatch.create_match(Online.nakama_socket)

func _on_JoinButton_pressed() -> void:
	var match_id = join_match_id_control.text
	if not match_id:
		UI.show_message("Need to paste Match ID to join")
		return
	
	if _check_session():
		# @todo Is there a sane way to avoid duplicating this code?
		if not Online.is_nakama_socket_connected():
			Online.connect_nakama_socket()
			yield(Online, "socket_connected")
		
		OnlineMatch.join_match(Online.nakama_socket, match_id)

func _on_PasteButton_pressed() -> void:
	join_match_id_control.text = OS.clipboard
