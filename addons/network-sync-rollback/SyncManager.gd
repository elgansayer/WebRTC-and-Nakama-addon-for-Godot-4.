extends Node

const SpawnManager = preload("res://addons/network-sync-rollback/SpawnManager.gd")

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
	
	func clear() -> void:
		rtt = 0
		last_ping_received = 0
		time_delta = 0
		last_remote_tick_received = 0
		next_local_tick_requested = 0
		remote_lag = 0
		local_lag = 0
		clear_advantage()

class InputForPlayer:
	var input := {}
	var predicted: bool
	
	func _init(_input: Dictionary, _predicted: bool) -> void:
		input = _input
		predicted = _predicted
		if not input.has('$'):
			input['$'] = _calculate_cleaned_hash()
	
	# Calculates the input hash without any keys that start with '_' (if string)
	# or less than 0 (if integer) to allow some properties to not count when
	# comparing predicted input with real input.
	func _calculate_cleaned_hash() -> int:
		var cleaned_input := input.duplicate(true)
		for path in cleaned_input:
			if path == '$':
				continue
			for key in cleaned_input[path].keys():
				var value = cleaned_input[path]
				if key is String:
					if key.begins_with('_'):
						value.erase(key)
				elif key is int:
					if key < 0:
						value.erase(key)
		return cleaned_input.hash()

class InputBufferFrame:
	var tick: int
	var players := {}
	
	func _init(_tick: int) -> void:
		tick = _tick
	
	func get_player_input(peer_id: int) -> Dictionary:
		if players.has(peer_id):
			return players[peer_id].input
		return {}
	
	func is_player_input_predicted(peer_id: int) -> bool:
		if players.has(peer_id):
			return players[peer_id].predicted
		return true
	
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

var max_buffer_size := 60
var ticks_to_calculate_advantage := 60
var input_delay := 2 setget set_input_delay
var max_messages_per_rpc := 3
var max_rpcs_per_tick := 5
var max_input_buffer_underruns := 10
var rollback_debug_ticks := 2
var debug_message_bytes := 500
var log_state := false

# In seconds, because we don't want it to be dependent on the network tick.
var ping_frequency := 1.0 setget set_ping_frequency

var input_tick: int = 0 setget _set_readonly_variable
var current_tick: int = 0 setget _set_readonly_variable
var skip_ticks: int = 0 setget _set_readonly_variable
var rollback_ticks: int = 0 setget _set_readonly_variable
var input_buffer_underruns := 0 setget _set_readonly_variable
var started := false setget _set_readonly_variable

var _input_path_map := {}
var _input_path_map_reverse := {}

var _ping_timer: Timer
var _spawn_manager
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
signal state_loaded (rollback_ticks)
signal tick_finished (is_rollback)
signal scene_spawned (name, spawned_node, scene, data)

func _ready() -> void:
	get_tree().connect("network_peer_disconnected", self, "remove_peer")
	
	_ping_timer = Timer.new()
	_ping_timer.name = "PingTimer"
	_ping_timer.wait_time = ping_frequency
	_ping_timer.autostart = true
	_ping_timer.one_shot = false
	_ping_timer.pause_mode = Node.PAUSE_MODE_PROCESS
	_ping_timer.connect("timeout", self, "_on_ping_timer_timeout")
	add_child(_ping_timer)
	
	_spawn_manager = SpawnManager.new()
	_spawn_manager.name = "SpawnManager"
	add_child(_spawn_manager)
	_spawn_manager.connect("scene_spawned", self, "_on_SpawnManager_scene_spawned")

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

func get_peer(peer_id: int) -> Peer:
	return peers.get(peer_id)

func remove_peer(peer_id: int) -> void:
	if peers.has(peer_id):
		peers.erase(peer_id)
		emit_signal("peer_removed", peer_id)

func clear_peers() -> void:
	for peer_id in peers.keys().duplicate():
		remove_peer(peer_id)

func add_input_path_mapping(path: String, alias) -> void:
	_input_path_map[path] = alias
	_input_path_map_reverse[alias] = path

func update_input_path_mapping(mapping: Dictionary) -> void:
	for path in mapping:
		add_input_path_mapping(path, mapping[path])

func clear_input_path_mapping() -> void:
	_input_path_map.clear()
	_input_path_map_reverse.clear()

func _map_input_paths(input: Dictionary) -> Dictionary:
	if _input_path_map.size() == 0:
		return input
	var mapped_input := {}
	for path in input:
		var mapped_path = _input_path_map.get(path, path)
		mapped_input[mapped_path] = input[path]
	return mapped_input

func _unmap_input_paths(mapped_input: Dictionary) -> Dictionary:
	if _input_path_map_reverse.size() == 0:
		return mapped_input
	var input := {}
	for mapped_path in mapped_input:
		var path = _input_path_map_reverse.get(mapped_path, mapped_path)
		input[path] = mapped_input[mapped_path]
	return input

func _on_ping_timer_timeout() -> void:
	var system_time = OS.get_system_time_msecs()
	for peer_id in peers:
		assert(peer_id != get_tree().get_network_unique_id(), "Cannot ping ourselves")
		var msg = {
			local_time = system_time,
		}
		rpc_unreliable_id(peer_id, "_remote_ping", msg)

remote func _remote_ping(msg: Dictionary) -> void:
	var peer_id = get_tree().get_rpc_sender_id()
	assert(peer_id != get_tree().get_network_unique_id(), "Cannot ping back ourselves")
	msg['remote_time'] = OS.get_system_time_msecs()
	rpc_unreliable_id(peer_id, "_remote_ping_back", msg)

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
	if started:
		return
	if get_tree().is_network_server():
		var highest_rtt: int = 0
		for peer in peers.values():
			highest_rtt = max(highest_rtt, peer.rtt)
		
		# Call _remote_start() on all the other peers.
		rpc("_remote_start")
		
		# Wait for half the highest RTT to start locally.
		print ("Delaying host start by %sms" % (highest_rtt / 2))
		yield(get_tree().create_timer(highest_rtt / 2000.0), 'timeout')
		_remote_start()

remote func _remote_start() -> void:
	input_tick = 0
	current_tick = input_tick - input_delay
	skip_ticks = 0
	rollback_ticks = 0
	input_buffer_underruns = 0
	input_buffer.clear()
	state_buffer.clear()
	_input_buffer_start_tick = 1
	_state_buffer_start_tick = 0
	_logged_remote_state.clear()
	started = true
	emit_signal("sync_started")

func stop() -> void:
	if get_tree().is_network_server():
		rpc("_remote_stop")
	else:
		_remote_stop()

remotesync func _remote_stop() -> void:
	started = false
	input_tick = 0
	current_tick = 0
	skip_ticks = 0
	rollback_ticks = 0
	input_buffer_underruns = 0
	input_buffer.clear()
	state_buffer.clear()
	_input_buffer_start_tick = 0
	_state_buffer_start_tick = 0
	_logged_remote_state.clear()
	
	for peer in peers.values():
		peer.clear()
	
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
		if node.is_network_master() and node.has_method('_get_local_input') and node.is_inside_tree():
			var node_input = node._get_local_input()
			if node_input.size() > 0:
				input[str(node.get_path())] = node_input
	return input

func _call_predict_remote_input(previous_input: Dictionary) -> Dictionary:
	var input := {}
	var nodes: Array = get_tree().get_nodes_in_group('network_sync')
	for node in nodes:
		if node.is_network_master():
			continue
		
		var node_path_str := str(node.get_path())
		var has_predict_network_input: bool = node.has_method('_predict_remote_input')
		if has_predict_network_input or previous_input.has(node_path_str):
			var previous_input_for_node = previous_input.get(node_path_str, {})
			var predicted_input_for_node = node._predict_remote_input(previous_input_for_node) if has_predict_network_input else previous_input_for_node.duplicate()
			if predicted_input_for_node.size() > 0:
				input[node_path_str] = predicted_input_for_node
	
	return input

func _call_network_process(delta: float, input_frame: InputBufferFrame) -> void:
	var nodes: Array = get_tree().get_nodes_in_group('network_sync')
	var i = nodes.size()
	while i > 0:
		i -= 1
		var node = nodes[i]
		if node.has_method('_network_process') and node.is_inside_tree():
			var player_input = input_frame.get_player_input(node.get_network_master())
			node._network_process(delta, player_input.get(str(node.get_path()), {}))

func _call_save_state() -> Dictionary:
	var state := {}
	var nodes: Array = get_tree().get_nodes_in_group('network_sync')
	for node in nodes:
		if node.has_method('_save_state') and node.is_inside_tree() and not node.is_queued_for_deletion():
			var node_path = str(node.get_path())
			if node_path != "":
				state[node_path] = node._save_state()
	return state

func _call_load_state(state: Dictionary) -> void:
	for node_path in state:
		assert(has_node(node_path), "Unable to restore state to missing node: %s" % node_path)
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

func _do_tick(delta: float, is_rollback: bool = false) -> void:
	var input_frame := get_input_frame(current_tick)
	var previous_frame := get_input_frame(current_tick - 1)
	
	assert(input_frame != null, "Input frame for current_tick is null")
	
	# Predict any missing input.
	for peer_id in peers:
		if not input_frame.players.has(peer_id) or input_frame.players[peer_id].predicted:
			var predicted_input := {}
			if previous_frame:
				predicted_input = _call_predict_remote_input(previous_frame.get_player_input(peer_id))
			input_frame.players[peer_id] = InputForPlayer.new(predicted_input, true)
	
	_call_network_process(delta, input_frame)
	_save_current_state()
	
	emit_signal("tick_finished", is_rollback)

func _get_or_create_input_frame(tick: int) -> InputBufferFrame:
	var input_frame: InputBufferFrame
	if input_buffer.size() == 0:
		input_frame = InputBufferFrame.new(tick)
		input_buffer.append(input_frame)
	elif tick > input_buffer[-1].tick:
		var highest = input_buffer[-1].tick
		while highest < tick:
			highest += 1
			input_frame = InputBufferFrame.new(highest)
			input_buffer.append(input_frame)
	else:
		input_frame = get_input_frame(tick)
		if input_frame == null:
			return _handle_fatal_error("Requested input frame (%s) not found in buffer" % tick)
	
	# Clean-up old input buffer frames. Unlike state frames, we can have many
	# frames from the future if we are running behind. We don't want having too
	# many future frames to end up discarding input for the current frame, so we
	# only count input frames before the current frame towards the buffer size.
	while (current_tick - _input_buffer_start_tick) > max_buffer_size:
		var input_frame_to_retire = input_buffer[0]
		if not input_frame_to_retire.is_complete(peers):
			input_buffer_underruns += 1
			var missing: Array = input_frame_to_retire.get_missing_peers(peers)
			if input_buffer_underruns > max_input_buffer_underruns:
				return _handle_fatal_error("Retired an incomplete input frame %s (missing peer(s): %s)" % [input_frame_to_retire.tick, missing])
			print ("Input buffer underrun")
			# Resend input to this peer - if we're missing their input, they're
			# probably missing ours too.
			for peer_id in missing:
				_send_input_to_peer(peer_id, true)
			if not _calculate_skip_ticks(true):
				skip_ticks = 10
				emit_signal("skip_ticks_flagged", skip_ticks)
		else:
			_input_buffer_start_tick += 1
			input_buffer.pop_front()
			input_buffer_underruns = 0
	
	return input_frame

func get_input_frame(tick: int) -> InputBufferFrame:
	if tick < _input_buffer_start_tick:
		return null
	var index = tick - _input_buffer_start_tick
	if index >= input_buffer.size():
		return null
	var input_frame = input_buffer[index]
	assert(input_frame.tick == tick, "Input frame retreived from input buffer has mismatched tick number")
	return input_frame

func get_latest_input_from_peer(peer_id: int) -> Dictionary:
	if peers.has(peer_id):
		var peer: Peer = peers[peer_id]
		var input_frame = get_input_frame(peer.last_remote_tick_received)
		if input_frame:
			return input_frame.get_player_input(peer_id)
	return {}

func get_latest_input_for_node(node: Node) -> Dictionary:
	return get_latest_input_from_peer_for_path(node.get_network_master(), str(node.get_path()))

func get_latest_input_from_peer_for_path(peer_id: int, path: String) -> Dictionary:
	return get_latest_input_from_peer(peer_id).get(path, {})

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
	
	var input_frame = get_input_frame(tick)
	if input_frame == null:
		# This means this frame has already been removed from the buffer, which
		# we would never allow if it wasn't complete.
		return true
	return input_frame.is_complete(peers)

func is_current_player_input_complete() -> bool:
	return is_player_input_complete(current_tick)

func _get_input_messages_for_peer(peer: Peer, disable_max_rpcs: bool = false) -> Array:
	var index := 0
	# If we no longer have the next tick they requested, we just start at 0 in
	# the buffer and hope they got that input frame from a previous message.
	if peer.next_local_tick_requested > _input_buffer_start_tick:
		index = peer.next_local_tick_requested - _input_buffer_start_tick
	
	# Only send a certain amount of RPCs and messages per tick.
	var max_messages = (max_messages_per_rpc * max_rpcs_per_tick)
	if not disable_max_rpcs and input_tick - (_input_buffer_start_tick + index) > max_messages:
		index = input_tick - _input_buffer_start_tick - max_messages
	
	var local_peer_id = get_tree().get_network_unique_id()
	
	var all_messages := []
	var msg := {}
	while index < input_buffer.size():
		var input_frame: InputBufferFrame = input_buffer[index]
		if not input_frame.players.has(local_peer_id):
			break
		msg[input_frame.tick] = _map_input_paths(input_frame.players[local_peer_id].input)
		
		if max_messages_per_rpc > 0 and msg.size() >= max_messages_per_rpc:
			all_messages.push_front(msg)
			msg = {}
		
		index += 1
	
	if msg.size() > 0:
		all_messages.push_front(msg)
	
	if all_messages.size() > 0:
		var first_message_keys = all_messages[0].keys()
		var last_message_keys = all_messages[-1].keys()
		print ("Sending %s RPCs (%s messages: ticks %s - %s)" % [all_messages.size(), first_message_keys[-1] - last_message_keys[0], last_message_keys[0], first_message_keys[-1]])
	
	return all_messages

func _calculate_skip_ticks(force_calculate_advantage: bool = false) -> bool:
	var max_advantage: float
	for peer in peers.values():
		# Number of frames we are predicting for this peer.
		peer.local_lag = (input_tick + 1) - peer.last_remote_tick_received
		# Calculate the advantage the peer has over us.
		peer.record_advantage(ticks_to_calculate_advantage if not force_calculate_advantage else 0)
		# Attempt to find the greatest advantage.
		max_advantage = max(max_advantage, peer.calculated_advantage)
		
	if max_advantage >= 2.0 and skip_ticks == 0:
		skip_ticks = int(max_advantage / 2)
		emit_signal("skip_ticks_flagged", skip_ticks)
		return true
	
	return false

func _calculate_message_bytes(msg) -> int:
	return var2bytes(msg).size()

func _send_input_to_peer(peer_id: int, disable_max_rpcs: bool = false) -> void:
	assert(peer_id != get_tree().get_network_unique_id(), "Cannot send input to ourselves")
	var peer = peers[peer_id]
	
	for input in _get_input_messages_for_peer(peer, disable_max_rpcs):
		var msg = {
			InputMessageKey.NEXT_TICK_REQUESTED: peer.last_remote_tick_received + 1,
			InputMessageKey.INPUT: input,
		}
		
		# See https://gafferongames.com/post/packet_fragmentation_and_reassembly/
		if debug_message_bytes:
			var bytes = _calculate_message_bytes(msg)
			if bytes > debug_message_bytes:
				push_error("Sending message w/ size %s bytes" % bytes)
		
		rpc_unreliable_id(peer_id, "_rit", msg)

func _send_input_to_all_peers() -> void:
	for peer_id in peers:
		_send_input_to_peer(peer_id)

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
		
		emit_signal("state_loaded", rollback_ticks)
		
		# Iterate forward until we're at the same spot we left off.
		while rollback_ticks > 0:
			current_tick += 1
			_do_tick(delta, true)
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
			# Even when we're skipping ticks, still send input.
			_send_input_to_all_peers()
			return
	
	if _calculate_skip_ticks():
		return
	
	input_tick += 1
	current_tick += 1
	
	var input_frame := _get_or_create_input_frame(input_tick)
	# The underlying error would have already been reported in
	# _get_or_create_input_frame() so we can just return here.
	if input_frame == null:
		return
		
	var local_input = _call_get_local_input()
	input_frame.players[get_tree().get_network_unique_id()] = InputForPlayer.new(local_input, false)
	_send_input_to_all_peers()
	
	if current_tick > 0:
		_do_tick(delta)

# _rit is short for _receive_input_tick. The method name ends up in each message
# so, we're trying to keep it short.
remote func _rit(msg: Dictionary) -> void:
	if not started:
		return
	
	var all_remote_input: Dictionary = msg[InputMessageKey.INPUT]
	var all_remote_ticks = all_remote_input.keys()
	var first_remote_tick = all_remote_ticks[0]
	var last_remote_tick = all_remote_ticks[-1]

	if first_remote_tick >= input_tick + max_buffer_size:
		# This either happens because we are really far behind (but maybe, just
		# maybe could catch up) or we are receiving old ticks from a previous
		# round that hadn't yet arrived. Just discard the message and hope for
		# the best, but if we can't keep up, another one of the fail safes will
		# detect that we are out of sync.
		print ("Discarding message from the future")
		return
	
	var peer_id = get_tree().get_rpc_sender_id()
	var peer: Peer = peers[peer_id]
	
	# Integrate the input we received into the input buffer.
	for remote_tick in all_remote_ticks:
		# Skip ticks we already have.
		if remote_tick <= peer.last_remote_tick_received:
			continue
		# This means the input frame has already been retired, which can only
		# happen if we already had all the input.
		if remote_tick < _input_buffer_start_tick:
			continue
		
		var remote_input = _unmap_input_paths(all_remote_input[remote_tick])
		var input_frame := _get_or_create_input_frame(remote_tick)
		if input_frame == null:
			# _get_or_create_input_frame() will have already flagged the error,
			# so we can just return here.
			return
		
		# If we already have non-predicted input for this peer, then skip it.
		if not input_frame.is_player_input_predicted(peer_id):
			continue
		
		print ("Received remote tick %s from %s" % [remote_tick, peer_id])
		
		# If we received a tick in the past and we aren't already setup to
		# rollback earlier than that...
		var tick_delta = current_tick - remote_tick
		if tick_delta >= 0 and rollback_ticks <= tick_delta:
			# Grab our predicted input, and store the remote input.
			var local_input = input_frame.get_player_input(peer_id)
			input_frame.players[peer_id] = InputForPlayer.new(remote_input, false)
			
			# Check if the remote input matches what we had predicted, if not,
			# flag that we need to rollback.
			if local_input['$'] != remote_input['$']:
				rollback_ticks = tick_delta + 1
				emit_signal("rollback_flagged", remote_tick, peer_id, local_input, remote_input)
		else:
			# Otherwise, just store it.
			input_frame.players[peer_id] = InputForPlayer.new(remote_input, false)
	
	# Record stats about the integrated input.
	if first_remote_tick == peer.last_remote_tick_received + 1:
		peer.last_remote_tick_received = max(last_remote_tick, peer.last_remote_tick_received)
	peer.next_local_tick_requested = max(msg[InputMessageKey.NEXT_TICK_REQUESTED], peer.next_local_tick_requested)
	# Number of frames the remote is predicting for us.
	peer.remote_lag = (peer.last_remote_tick_received + 1) - peer.next_local_tick_requested

master func _log_saved_state(tick: int, remote_data: Dictionary) -> void:
	if not started:
		return
	
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

func spawn(name: String, parent: Node, scene: PackedScene, data: Dictionary = {}, rename: bool = true, signal_name: String = '') -> Node:
	return _spawn_manager.spawn(name, parent, scene, data, rename, signal_name)

func _on_SpawnManager_scene_spawned(name: String, spawned_node: Node, scene: PackedScene, data: Dictionary) -> void:
	emit_signal("scene_spawned", name, spawned_node, scene, data)
