extends Node

class Peer extends Reference:
	var peer_id: int
	
	var rtt: int
	var last_ping_received: int
	var time_delta: float
	
	var last_remote_tick_received: int
	var next_local_tick_requested: int
	
	var remote_lag: int
	var local_lag: int
	
	var calculated_advantage: float
	var advantage_list := []
	
	func _init(_peer_id: int) -> void:
		peer_id = _peer_id
	
	func record_advantage(ticks_to_calculate_advantage: int) -> void:
		advantage_list.append(local_lag - remote_lag)
		if advantage_list.size() >= ticks_to_calculate_advantage:
			var total: float = 0
			for x in advantage_list:
				total += x
			calculated_advantage = total / advantage_list.size()
			advantage_list.clear()
	
	func clear_advantage() -> void:
		calculated_advantage = 0.0
		advantage_list.clear()

class InputForPlayer:
	var input := {}
	var predicted: bool
	
	func _init(_input: Dictionary, _predicted: bool) -> void:
		input = _input
		predicted = _predicted

class InputBufferFrame:
	var tick: int
	var players := {}
	
	func _init(_tick: int) -> void:
		tick = _tick
	
	func get_player_input(peer_id: int) -> Dictionary:
		if players.has(peer_id):
			return players[peer_id].input
		return {}
	
	func get_missing_peers(peers: Dictionary) -> Array:
		var missing := []
		for peer_id in peers:
			if not players.has(peer_id) or players[peer_id].predicted:
				missing.append(peer_id)
		return missing
	
	func is_complete(peers: Dictionary) -> bool:
		for peer_id in peers:
			if not players.has(peer_id) or players[peer_id].predicted:
				return false
		return true

class StateBufferFrame:
	var tick: int
	var data: Dictionary
	
	func _init(_tick, _data) -> void:
		tick = _tick
		data = _data

enum InputMessageKey {
	TICK,
	NEXT_TICK_REQUESTED,
	INPUT,
}

var peers := {}
var input_buffer := []
var state_buffer := []

var max_buffer_size := 20
var ticks_to_calculate_advantage := 60
var input_delay := 2 setget set_input_delay
var rollback_debug_ticks := 0
var log_state := true

# In seconds, because we don't want it to be dependent on the network tick.
var ping_frequency := 1.0 setget set_ping_frequency

var input_tick: int = 0 setget _set_readonly_variable
var current_tick: int = 0 setget _set_readonly_variable
var skip_ticks: int = 0 setget _set_readonly_variable
var rollback_ticks: int = 0 setget _set_readonly_variable
var started := false setget _set_readonly_variable

var _ping_timer: Timer
var _input_buffer_start_tick: int
var _state_buffer_start_tick: int
var _logged_remote_state: Dictionary

signal sync_started ()
signal sync_stopped ()
signal sync_error (msg)
signal skip_ticks_flagged (count)
signal rollback_flagged (tick, peer_id, local_input, remote_input)
signal remote_state_mismatch (tick, peer_id, local_state, remote_state)
signal peer_added (peer_id)
signal peer_removed (peer_id)
signal peer_pinged_back (peer)

func _ready() -> void:
	_ping_timer = Timer.new()
	_ping_timer.wait_time = ping_frequency
	_ping_timer.autostart = true
	_ping_timer.one_shot = false
	_ping_timer.connect("timeout", self, "_on_ping_timer_timeout")
	add_child(_ping_timer)

func _set_readonly_variable(_value) -> void:
	pass

func set_ping_frequency(_ping_frequency) -> void:
	ping_frequency = _ping_frequency
	if _ping_timer:
		_ping_timer.wait_time = _ping_frequency

func set_input_delay(_input_delay: int) -> void:
	if started:
		push_warning("Cannot change input delay after sync'ing has already started")
	input_delay = _input_delay

func add_peer(peer_id: int) -> void:
	assert(not peers.has(peer_id), "Peer with given id already exists")
	assert(peer_id != get_tree().get_network_unique_id(), "Cannot add ourselves as a peer in SyncManager")
	
	if peers.has(peer_id):
		return
	if peer_id == get_tree().get_network_unique_id():
		return
	
	peers[peer_id] = Peer.new(peer_id)
	emit_signal("peer_added", peer_id)

func has_peer(peer_id: int) -> bool:
	return peers.has(peer_id)

func remove_peer(peer_id: int) -> void:
	if peers.has(peer_id):
		peers.erase(peer_id)
		emit_signal("peer_removed", peer_id)

func clear_peers() -> void:
	for peer_id in peers.keys().duplicate():
		remove_peer(peer_id)

func _on_ping_timer_timeout() -> void:
	var system_time = OS.get_system_time_msecs()
	for peer_id in peers:
		var msg = {
			local_time = system_time,
		}
		rpc_id(peer_id, "_remote_ping", msg)

remote func _remote_ping(msg: Dictionary) -> void:
	msg['remote_time'] = OS.get_system_time_msecs()
	rpc_id(get_tree().get_rpc_sender_id(), "_remote_ping_back", msg)

remote func _remote_ping_back(msg: Dictionary) -> void:
	var system_time = OS.get_system_time_msecs()
	var peer_id = get_tree().get_rpc_sender_id()
	var peer = peers[peer_id]
	peer.last_ping_received = system_time
	peer.rtt = system_time - msg['local_time']
	peer.time_delta = msg['remote_time'] - msg['local_time'] - (peer.rtt / 2.0)
	emit_signal("peer_pinged_back", peer)

func start() -> void:
	assert(get_tree().is_network_server(), "start() should only be called on the host")
	if get_tree().is_network_server():
		# @todo Use latency information to time when we do our local start.
		rpc("_remote_start")

remotesync func _remote_start() -> void:
	input_tick = 0
	current_tick = input_tick - input_delay
	skip_ticks = 0
	rollback_ticks = 0
	input_buffer.clear()
	state_buffer.clear()
	_input_buffer_start_tick = 1
	_state_buffer_start_tick = 0
	_logged_remote_state.clear()
	started = true
	emit_signal("sync_started")

func stop() -> void:
	if get_tree().is_network_server():
		# @todo Use latency information to time when we do our local start.
		rpc("_remote_stop")
	else:
		_remote_stop()

remotesync func _remote_stop() -> void:
	started = false
	input_tick = 0
	current_tick = 0
	skip_ticks = 0
	rollback_ticks = 0
	input_buffer.clear()
	state_buffer.clear()
	_input_buffer_start_tick = 0
	_state_buffer_start_tick = 0
	_logged_remote_state.clear()
	
	emit_signal("sync_stopped")

func _handle_fatal_error(msg: String):
	emit_signal("sync_error", msg)
	push_error("NETWORK SYNC LOST: " + msg)
	stop()
	return null

func _call_get_local_input() -> Dictionary:
	var input := {}
	var nodes: Array = get_tree().get_nodes_in_group('network_sync')
	for node in nodes:
		if node.is_network_master() and node.has_method('_get_local_input'):
			var node_input = node._get_local_input()
			if node_input.size() > 0:
				input[str(node.get_path())] = node_input
	return input

func _call_predict_network_input(previous_input: Dictionary) -> Dictionary:
	var input := {}
	var nodes: Array = get_tree().get_nodes_in_group('network_sync')
	for node in nodes:
		if node.is_network_master():
			continue
		
		var node_path_str := str(node.get_path())
		var has_predict_network_input: bool = node.has_method('_predict_network_input')
		if has_predict_network_input or previous_input.has(node_path_str):
			var previous_input_for_node = previous_input.get(node_path_str, {})
			var predicted_input_for_node = node._predict_network_input(previous_input_for_node) if has_predict_network_input else previous_input_for_node.duplicate()
			if predicted_input_for_node.size() > 0:
				input[node_path_str] = predicted_input_for_node
	
	return input

func _call_network_process(delta: float, input_frame: InputBufferFrame) -> void:
	var nodes: Array = get_tree().get_nodes_in_group('network_sync')
	var i = nodes.size()
	while i > 0:
		i -= 1
		var node = nodes[i]
		if node.has_method('_network_process'):
			var player_input = input_frame.get_player_input(node.get_network_master())
			node._network_process(delta, player_input.get(str(node.get_path()), {}), self)

func _call_save_state() -> Dictionary:
	var state := {}
	var nodes: Array = get_tree().get_nodes_in_group('network_sync')
	for node in nodes:
		if node.has_method('_save_state'):
			state[str(node.get_path())] = node._save_state()
	return state

func _call_load_state(state: Dictionary) -> void:
	for node_path in state:
		if has_node(node_path):
			var node = get_node(node_path)
			if node.has_method('_load_state'):
				node._load_state(state[node_path])

func _save_current_state() -> void:
	assert(current_tick >= 0, "Attempting to store state for negative tick")
	if current_tick < 0:
		return
	
	var state_data = _call_save_state()
	state_buffer.append(StateBufferFrame.new(current_tick, state_data))
	
	while state_buffer.size() > max_buffer_size:
		state_buffer.pop_front()
		_state_buffer_start_tick += 1
	
	if log_state and not get_tree().is_network_server() and is_player_input_complete(current_tick):
		rpc_id(1, "_log_saved_state", current_tick, state_data)

func _do_tick(delta: float) -> void:
	var input_frame := _get_input_frame(current_tick)
	var previous_frame := _get_input_frame(current_tick - 1)
	
	# Predict any missing input.
	for peer_id in peers:
		if not input_frame.players.has(peer_id) or input_frame.players[peer_id].predicted:
			var predicted_input := {}
			if previous_frame:
				predicted_input = _call_predict_network_input(previous_frame.get_player_input(peer_id))
			input_frame.players[peer_id] = InputForPlayer.new(predicted_input, true)
	
	_call_network_process(delta, input_frame)
	_save_current_state()

func _get_or_create_input_frame(tick: int) -> InputBufferFrame:
	var input_frame: InputBufferFrame
	if input_buffer.size() == 0:
		input_frame = InputBufferFrame.new(tick)
		input_buffer.append(input_frame)
	elif input_buffer[-1].tick < tick:
		var highest = input_buffer[-1].tick
		while highest < tick:
			highest += 1
			input_frame = InputBufferFrame.new(highest)
			input_buffer.append(input_frame)
	else:
		input_frame = _get_input_frame(tick)
		if input_frame == null:
			return _handle_fatal_error("Requested input frame (%s) not found in buffer" % tick)
	
	# Clean-up old input buffer frames.
	while input_buffer.size() > max_buffer_size:
		_input_buffer_start_tick += 1
		var retired_input_frame = input_buffer.pop_front()
		if not retired_input_frame.is_complete(peers):
			var missing: Array = retired_input_frame.get_missing_peers(peers)
			return _handle_fatal_error("Retired an incomplete input frame (missing peer(s): %s)" % missing)
	
	return input_frame

func _get_input_frame(tick: int) -> InputBufferFrame:
	if tick < _input_buffer_start_tick:
		return null
	var index = tick - _input_buffer_start_tick
	if index >= input_buffer.size():
		return null
	var input_frame = input_buffer[index]
	assert(input_frame.tick == tick, "Input frame retreived from input buffer has mismatched tick number")
	return input_frame

func _get_state_frame(tick: int) -> StateBufferFrame:
	if tick < _state_buffer_start_tick:
		return null
	var index = tick - _state_buffer_start_tick
	if index >= state_buffer.size():
		return null
	var state_frame = state_buffer[index]
	assert(state_frame.tick == tick, "State frame retreived from state buffer has mismatched tick number")
	return state_frame

func is_player_input_complete(tick: int) -> bool:
	if tick > input_buffer[-1].tick:
		# We don't have any input for this tick.
		return false
	
	var input_frame = _get_input_frame(tick)
	if input_frame == null:
		# This means this frame has already been removed from the buffer, which
		# we would never allow if it wasn't complete.
		return true
	return input_frame.is_complete(peers)

func _get_input_message_for_peer(peer: Peer) -> Dictionary:
	var msg := {}
	
	var index := 0
	# If we no longer have the next tick they requested, we just start at 0 in
	# the buffer and hope they got that input frame from a previous message.
	if peer.next_local_tick_requested > _input_buffer_start_tick:
		index = peer.next_local_tick_requested - _input_buffer_start_tick
	
	var local_peer_id = get_tree().get_network_unique_id()
	while index < input_buffer.size():
		var input_frame: InputBufferFrame = input_buffer[index]
		if not input_frame.players.has(local_peer_id):
			break
		msg[input_frame.tick] = input_frame.players[local_peer_id].input
		index += 1
	
	return msg

func _physics_process(delta: float) -> void:
	if not started:
		return
	
	if current_tick == 0:
		# Store an initial state before any ticks.
		_save_current_state()
	
	if rollback_debug_ticks > 0 and current_tick >= rollback_debug_ticks:
		rollback_ticks = max(rollback_ticks, rollback_debug_ticks)
	
	if rollback_ticks > 0:
		var original_tick = current_tick
		
		# Rollback our internal state.
		assert(rollback_ticks + 1 <= state_buffer.size(), "Not enough state in buffer to rollback requested number of frames")
		if rollback_ticks + 1 > state_buffer.size():
			_handle_fatal_error("Not enough state in buffer to rollback %s frames" % rollback_ticks)
			return
		
		_call_load_state(state_buffer[-rollback_ticks - 1].data)
		state_buffer.resize(state_buffer.size() - rollback_ticks)
		current_tick -= rollback_ticks
		
		# Iterate forward until we're at the same spot we left off.
		while rollback_ticks > 0:
			current_tick += 1
			_do_tick(delta)
			rollback_ticks -= 1
		assert(current_tick == original_tick, "Rollback didn't return to the original tick")
	
	if get_tree().is_network_server() and _logged_remote_state.size() > 0:
		_process_logged_remote_state()
	
	if skip_ticks > 0:
		skip_ticks -= 1
		if skip_ticks == 0:
			for peer in peers.values():
				peer.clear_advantage()
		else:
			return
	
	var max_advantage: float
	for peer in peers.values():
		# Number of frames we are predicting for this peer.
		peer.local_lag = (input_tick + 1) - peer.last_remote_tick_received
		# Calculate the advantage the peer has over us.
		peer.record_advantage(ticks_to_calculate_advantage)
		# Attempt to find the greatest advantage.
		max_advantage = max(max_advantage, peer.calculated_advantage)
		
	if max_advantage >= 2.0 and skip_ticks == 0:
		skip_ticks = int(max_advantage / 2)
		emit_signal("skip_ticks_flagged", skip_ticks)
		return
	
	input_tick += 1
	current_tick += 1
	
	var local_input = _call_get_local_input()
	var input_frame := _get_or_create_input_frame(input_tick)
	if input_frame == null:
		return
	
	input_frame.players[get_tree().get_network_unique_id()] = InputForPlayer.new(local_input, false)
	
	for peer_id in peers:
		var peer = peers[peer_id]
		var msg = {
			InputMessageKey.TICK: input_tick,
			InputMessageKey.NEXT_TICK_REQUESTED: peer.last_remote_tick_received + 1,
			InputMessageKey.INPUT: _get_input_message_for_peer(peer),
		}
		rpc_unreliable_id(peer_id, "_receive_input_tick", msg)
	
	if current_tick > 0:
		_do_tick(delta)

remote func _receive_input_tick(msg: Dictionary) -> void:
	if not started:
		return
	if msg[InputMessageKey.TICK] >= input_tick + max_buffer_size:
		# This either happens because we are really far behind (but maybe, just
		# maybe could catch up) or we are receiving old ticks from a previous
		# round that hadn't yet arrived. Just discard the message and hope for
		# the best, but if we can't keep up, another one of the fail safes will
		# detect that we are out of sync.
		return
	
	var peer_id = get_tree().get_rpc_sender_id()
	var peer: Peer = peers[peer_id]
	
	# Integrate the input we received into the input buffer.
	var all_remote_input: Dictionary = msg[InputMessageKey.INPUT]
	for remote_tick in all_remote_input:
		# Skip ticks we already have.
		if remote_tick <= peer.last_remote_tick_received:
			continue
		
		var remote_input = all_remote_input[remote_tick]
		var input_frame := _get_or_create_input_frame(remote_tick)
		var tick_delta = current_tick - remote_tick
		
		# If we received a tick in the past and we aren't already setup to
		# rollback earlier than that...
		if tick_delta >= 0 and rollback_ticks <= tick_delta:
			# Check if input matches what we had predicted, if not, inject it and then
			# flag that we need to rollback.	
			var local_input = input_frame.get_player_input(peer_id)
			if local_input.hash() != remote_input.hash():
				rollback_ticks = tick_delta + 1
				input_frame.players[peer_id] = InputForPlayer.new(remote_input, false)
				emit_signal("rollback_flagged", remote_tick, peer_id, local_input, remote_input)
				

			else:
				# We predicted right, so just mark the input as correct!
				input_frame.players[peer_id].predicted = false
		# If we received a tick in the future, or are already set to rollback
		# further anyway...
		else:
			# So, we just store this input for when we get to it.
			input_frame.players[peer_id] = InputForPlayer.new(remote_input, false)
	
	# Record stats about the integrated input.
	peer.last_remote_tick_received = max(msg[InputMessageKey.TICK], peer.last_remote_tick_received)
	peer.next_local_tick_requested = max(msg[InputMessageKey.NEXT_TICK_REQUESTED], peer.next_local_tick_requested)
	# Number of frames the remote is predicting for us.
	peer.remote_lag = (peer.last_remote_tick_received + 1) - peer.next_local_tick_requested

master func _log_saved_state(tick: int, remote_data: Dictionary) -> void:
	var peer_id = get_tree().get_rpc_sender_id()
	if not _logged_remote_state.has(peer_id):
		_logged_remote_state[peer_id] = []
		
	# The logged state will be processed once we have complete player input in
	# the _process_logged_remote_state() and _check_remote_state() methods below.
	_logged_remote_state[peer_id].append(StateBufferFrame.new(tick, remote_data))

func _process_logged_remote_state() -> void:
	for peer_id in _logged_remote_state:
		var remote_state_buffer = _logged_remote_state[peer_id]
		while remote_state_buffer.size() > 0:
			var remote_tick = remote_state_buffer[0].tick
			if not is_player_input_complete(remote_tick):
				break
			
			var local_state = _get_state_frame(remote_tick)
			if local_state == null:
				break
			
			var remote_state = remote_state_buffer.pop_front()
			_check_remote_state(peer_id, remote_state, local_state)

func _check_remote_state(peer_id: int, remote_state: StateBufferFrame, local_state: StateBufferFrame) -> void:
	#print ("checking remote state for tick: %s" % remote_state.tick)
	if local_state.data.hash() != remote_state.data.hash():
		emit_signal("remote_state_mismatch", local_state.tick, peer_id, local_state.data, remote_state.data)

