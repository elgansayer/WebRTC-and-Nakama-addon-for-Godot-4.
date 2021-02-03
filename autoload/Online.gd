extends Node

# For developers to set from the outside, for example:
#   Online.nakama_host = 'nakama.example.com'
#   Online.nakama_scheme = 'https'
var nakama_server_key: String = 'defaultkey'
var nakama_host: String = 'localhost'
var nakama_port: int = 7350
var nakama_scheme: String = 'http'

# For other scripts to access:
var nakama_client: NakamaClient setget _set_readonly_variable, get_nakama_client
var nakama_session: NakamaSession setget set_nakama_session
var nakama_socket: NakamaSocket setget _set_readonly_variable

const CREDENTIALS_FILENAME = 'user://credentials.json'

var _user_credentials := {}
var _nakama_session_resumable: GDScriptFunctionState

# Internal variable for initializing the socket.
var _nakama_socket_connecting := false

signal session_changed (nakama_session)
signal socket_connected (nakama_socket)

func _set_readonly_variable(_value) -> void:
	pass

func _ready() -> void:
	# Don't stop processing messages from Nakama when the game is paused.
	Nakama.pause_mode = Node.PAUSE_MODE_PROCESS

func get_nakama_client() -> NakamaClient:
	if nakama_client == null:
		nakama_client = Nakama.create_client(
			nakama_server_key,
			nakama_host,
			nakama_port,
			nakama_scheme,
			Nakama.DEFAULT_TIMEOUT,
			NakamaLogger.LOG_LEVEL.ERROR)
	
	return nakama_client

func set_nakama_session(_nakama_session: NakamaSession) -> void:
	# Close out the old socket.
	if nakama_socket:
		nakama_socket.close()
		nakama_socket = null
	
	nakama_session = _nakama_session
	
	emit_signal("session_changed", nakama_session)

func connect_nakama_socket() -> void:
	if nakama_socket != null:
		return
	if _nakama_socket_connecting:
		return
	_nakama_socket_connecting = true
	
	var new_socket = Nakama.create_socket_from(nakama_client)
	yield(new_socket.connect_async(nakama_session), "completed")
	nakama_socket = new_socket
	_nakama_socket_connecting = false
	
	emit_signal("socket_connected", nakama_socket)

func is_nakama_socket_connected() -> bool:
	   return nakama_socket != null && nakama_socket.is_connected_to_host()

func _load_credentials() -> void:
	var file = File.new()
	if file.file_exists(CREDENTIALS_FILENAME):
		file.open(CREDENTIALS_FILENAME, File.READ)
		var result := JSON.parse(file.get_as_text())
		if result.result is Dictionary:
			_user_credentials = result.result
		file.close()

func _save_credentials() -> void:
	var file = File.new()
	file.open(CREDENTIALS_FILENAME, File.WRITE)
	file.store_line(JSON.print(_user_credentials))
	file.close()

func set_user_credentials(credentials: Dictionary, save: bool = false) -> void:
	_user_credentials = credentials
	if save:
		_save_credentials()

# Returns a GDScriptFunctionState that we can resume manually.
func _resumable():
	var value = yield()
	if value is NakamaSession:
		if value.is_exception():
			return false
		else:
			nakama_session = value
			return true
	return value

func _resume_nakama_session(value):
	if _nakama_session_resumable:
		_nakama_session_resumable.resume(value)
		_nakama_session_resumable = null

func ensure_nakama_session():
	if _nakama_session_resumable:
		return _nakama_session_resumable
	_nakama_session_resumable = _resumable()
	
	if nakama_session and not nakama_session.is_expired():
		call_deferred('_resume_nakama_session', true)
	elif not _user_credentials.has_all(['email', 'password']):
		call_deferred('_resume_nakama_session', false)
	else:
		nakama_client.authenticate_email_async(_user_credentials['email'], _user_credentials['password'], null, false).connect("completed", self, "_resume_nakama_session")
	
	return _nakama_session_resumable
