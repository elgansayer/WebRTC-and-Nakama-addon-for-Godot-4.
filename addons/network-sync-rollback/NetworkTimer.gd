extends Node

export (bool) var autostart := false
export (bool) var one_shot := false
export (int) var ticks_left := 0
export (int) var wait_ticks := 0
export (bool) var timeout_with_incomplete_input := true

var _running := false

signal timeout ()

func _ready() -> void:
	add_to_group('network_sync')
	if autostart:
		start()

func is_stopped() -> bool:
	return not _running

func start(ticks: int = -1) -> void:
	if ticks > 0:
		wait_ticks = ticks
	ticks_left = wait_ticks
	_running = true

func stop():
	_running = false

func _network_process(_delta: float, _input: Dictionary, sync_manager) -> void:
	if not _running:
		return
	if ticks_left <= 0:
		_running = false
		return
	
	ticks_left -= 1
	if ticks_left == 0:
		if one_shot:
			_running = false
		else:
			ticks_left = wait_ticks
		if timeout_with_incomplete_input or sync_manager.is_current_player_input_complete():
			emit_signal("timeout")

func _save_state() -> Dictionary:
	return {
		running = _running,
		wait_ticks = wait_ticks,
		ticks_left = ticks_left,
	}

func _load_state(state: Dictionary) -> void:
	_running = state['running']
	wait_ticks = state['wait_ticks']
	ticks_left = state['ticks_left']