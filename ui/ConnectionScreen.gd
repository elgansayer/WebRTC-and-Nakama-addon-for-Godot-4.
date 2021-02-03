extends Control

onready var tab_container := $TabContainer
onready var login_email_field := $TabContainer/Login/GridContainer/Email
onready var login_password_field := $TabContainer/Login/GridContainer/Password

const CREDENTIALS_FILENAME = 'user://credentials.json'

var email: String = ''
var password: String = ''

var _reconnect: bool = false

func _ready() -> void:
	var file = File.new()
	if file.file_exists(CREDENTIALS_FILENAME):
		file.open(CREDENTIALS_FILENAME, File.READ)
		var result := JSON.parse(file.get_as_text())
		if result.result is Dictionary:
			email = result.result['email']
			password = result.result['password']
			login_email_field.text = email
			login_password_field.text = password
		file.close()

func _save_credentials() -> void:
	var file = File.new()
	file.open(CREDENTIALS_FILENAME, File.WRITE)
	var credentials = {
		email = email,
		password = password,
	}
	file.store_line(JSON.print(credentials))
	file.close()

func initialize(info: Dictionary = {}) -> void:
	_reconnect = info.get('reconnect', false)
	
	tab_container.current_tab = 0
	
	# If we have a stored email and password, attempt to login straight away.
	if email != '' and password != '':
		do_login()

func do_login(save_credentials: bool = false) -> void:
	visible = false
	
	if _reconnect:
		UI.show_message("Session expired! Reconnecting...")
	else:
		UI.show_message("Logging in...")
	
	var nakama_session = yield(Online.nakama_client.authenticate_email_async(email, password, null, false), "completed")
	
	if nakama_session.is_exception():
		visible = true
		UI.show_message("Login failed!")
		
		# Clear stored email and password, but leave the fields alone so the
		# user can attempt to correct them.
		email = ''
		password = ''
		
		# We always set Online.nakama_session in case something is yielding
		# on the "session_changed" signal.
		Online.nakama_session = null
	else:
		if save_credentials:
			_save_credentials()
		Online.nakama_session = nakama_session
		UI.hide_message()
		
		if not _reconnect:
			UI.show_screen("MatchScreen")

func _on_LoginButton_pressed() -> void:
	email = login_email_field.text.strip_edges()
	password = login_password_field.text.strip_edges()
	do_login($TabContainer/Login/GridContainer/SaveCheckBox.pressed)

func _on_CreateAccountButton_pressed() -> void:
	email = $"TabContainer/Create Account/GridContainer/Email".text.strip_edges()
	password = $"TabContainer/Create Account/GridContainer/Password".text.strip_edges()
	
	var username = $"TabContainer/Create Account/GridContainer/Username".text.strip_edges()
	var save_credentials = $"TabContainer/Create Account/GridContainer/SaveCheckBox".pressed
	
	if email == '':
		UI.show_message("Must provide email")
		return
	if password == '':
		UI.show_message("Must provide password")
		return
	if username == '':
		UI.show_message("Must provide username")
		return
	
	visible = false
	UI.show_message("Creating account...")

	var nakama_session = yield(Online.nakama_client.authenticate_email_async(email, password, username, true), "completed")
	
	if nakama_session.is_exception():
		visible = true
		
		var msg = nakama_session.get_exception().message
		# Nakama treats registration as logging in, so this is what we get if the
		# the email is already is use but the password is wrong.
		if msg == 'Invalid credentials.':
			msg = 'E-mail already in use.'
		elif msg == '':
			msg = "Unable to create account"
		UI.show_message(msg)
		
		# We always set Online.nakama_session in case something is yielding
		# on the "session_changed" signal.
		Online.nakama_session = null
	else:
		if save_credentials:
			_save_credentials()
		Online.nakama_session = nakama_session
		UI.hide_message()
		UI.show_screen("MatchScreen")
