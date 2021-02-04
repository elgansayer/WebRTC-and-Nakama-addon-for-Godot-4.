extends Control

onready var matchmaker_player_count_control := $PanelContainer/VBoxContainer/MatchPanel/SpinBox
onready var join_match_id_control := $PanelContainer/VBoxContainer/JoinPanel/LineEdit

func _ready() -> void:
	$PanelContainer/VBoxContainer/MatchPanel/MatchButton.connect("pressed", self, "_on_match_button_pressed", [OnlineMatch.MatchMode.MATCHMAKER])
	$PanelContainer/VBoxContainer/CreatePanel/CreateButton.connect("pressed", self, "_on_match_button_pressed", [OnlineMatch.MatchMode.CREATE])
	$PanelContainer/VBoxContainer/JoinPanel/JoinButton.connect("pressed", self, "_on_match_button_pressed", [OnlineMatch.MatchMode.JOIN])
	
	OnlineMatch.connect("matchmaker_matched", self, "_on_OnlineMatch_matchmaker_matched")
	OnlineMatch.connect("match_created", self, "_on_OnlineMatch_created")
	OnlineMatch.connect("match_joined", self, "_on_OnlineMatch_joined")

func initialize() -> void:
	matchmaker_player_count_control.value = 2
	join_match_id_control.text = ''

func _on_match_button_pressed(mode) -> void:
	# If our session has expired, show the ConnectionScreen again.
	if Online.nakama_session == null or Online.nakama_session.is_expired():
		UI.show_screen("ConnectionScreen", [{ reconnect = true }])
		
		# Wait to see if we get a new valid session.
		yield(Online, "session_changed")
		if Online.nakama_session == null:
			return
	
	# Connect socket to realtime Nakama API if not connected.
	if not Online.is_nakama_socket_connected():
		Online.connect_nakama_socket()
		yield(Online, "socket_connected")
	
	# Call internal method to do actual work.
	match mode:
		OnlineMatch.MatchMode.MATCHMAKER:
			_start_matchmaking()
		OnlineMatch.MatchMode.CREATE:
			_create_match()
		OnlineMatch.MatchMode.JOIN:
			_join_match()

func _start_matchmaking() -> void:
	var min_players = matchmaker_player_count_control.value
	
	visible = false
	UI.show_message("Looking for match...")
	
	var data = {
		min_count = min_players,
		string_properties = {
			game = "test_game",
		},
		query = "+properties.game:test_game",
	}
	
	OnlineMatch.start_matchmaking(Online.nakama_socket, data)

func _on_OnlineMatch_matchmaker_matched(_players: Dictionary):
	UI.hide_message()
	UI.show_screen("ReadyScreen", [_players])

func _create_match() -> void:
	OnlineMatch.create_match(Online.nakama_socket)

func _on_OnlineMatch_created(match_id: String):
	UI.show_screen("ReadyScreen", [{}, match_id, true])

func _join_match() -> void:
	var match_id = join_match_id_control.text.strip_edges()
	if not match_id.ends_with('.'):
		match_id += '.'
	if match_id == '':
		UI.show_message("Need to paste Match ID to join")
		return
	
	OnlineMatch.join_match(Online.nakama_socket, match_id)

func _on_OnlineMatch_joined(match_id: String):
	UI.show_screen("ReadyScreen", [{}, match_id, true])

func _on_PasteButton_pressed() -> void:
	join_match_id_control.text = OS.clipboard
