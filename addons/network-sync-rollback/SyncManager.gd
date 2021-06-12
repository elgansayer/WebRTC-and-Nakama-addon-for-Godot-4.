extends Node
class_name SyncManager

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

var peers := {}
var input_buffer := []
var state_buffer := []

var max_state_count := 20
var ticks_to_calculate_advantage := 60
var input_delay := 2 setget set_input_delay
var rollback_debug_ticks := 0

# In seconds, because we don't want it to be dependent on the network tick.
var ping_frequency := 1.0 setget set_ping_frequency

var input_tick: int = 0 setget _set_readonly_variable
var current_tick: int = 0 setget _set_readonly_variable
var skip_ticks: int = 0 setget _set_readonly_variable
var rollback_ticks: int = 0 setget _set_readonly_variable
var started := false setget _set_readonly_variable

var _ping_timer: Timer
var _input_buffer_start_tick: int

signal sync_started ()
signal sync_stopped ()
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
	
	if peers.has(peer_id):
		return
	peers[peer_id] = Peer.new(peer_id)

func has_peer(peer_id: int) -> bool:
	return peers.has(peer_id)

func remove_peer(peer_id: int) -> void:
	peers.erase(peer_id)

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

func _do_tick(delta: float) -> void:
	var input_frame := _get_input_frame(current_tick)
	var previous_frame := _get_input_frame(current_tick - 1)
	
	for peer_id in peers:
		if not input_frame.players.has(peer_id) or input_frame.players[peer_id].predicted:
			var predicted_input := {}
			if previous_frame:
				predicted_input = _call_predict_network_input(previous_frame.get_player_input(peer_id))
			input_frame.players[peer_id] = InputForPlayer.new(predicted_input, true)
	
	_call_network_process(delta, input_frame)
	
	state_buffer.append(StateBufferFrame.new(current_tick, _call_save_state()))
	while state_buffer.size() > max_state_count:
		state_buffer.pop_front()

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
			push_error("Requested input frame not found in buffer")
			stop()
			return null
	
	# Clean-up old input buffer frames.
	while input_buffer.size() > max_state_count:
		_input_buffer_start_tick += 1
		var retired_input_frame = input_buffer.pop_front()
		if not retired_input_frame.is_complete(peers):
			push_error("Retired an incomplete input frame")
			# @todo Yell loudly that things are broken!
			stop()
			return null
	
	return input_frame

func _get_input_frame(tick: int) -> InputBufferFrame:
	if tick < _input_buffer_start_tick:
		return null
	var input_frame = input_buffer[tick - _input_buffer_start_tick]
	assert(input_frame.tick == tick, "Input frame retreived from input buffer has mismatched tick number")
	return input_frame

func is_player_input_complete(tick: int) -> bool:
	var input_frame = _get_input_frame(tick)
	if input_frame == null:
		# This means this frame has already been removed from the buffer, which
		# we would never allow if it wasn't complete.
		return true
	return input_frame.is_complete(peers)

func _physics_process(delta: float) -> void:
	if not started:
		return
	
	if current_tick == 0:
		# Store an initial state before any ticks.
		state_buffer.append(StateBufferFrame.new(current_tick, _call_save_state()))
	
	if rollback_debug_ticks > 0 and current_tick >= rollback_debug_ticks:
		rollback_ticks = max(rollback_ticks, rollback_debug_ticks)
	
	if rollback_ticks > 0:
		var original_tick = current_tick
		
		# Rollback our internal state.
		assert(rollback_ticks + 1 <= state_buffer.size(), "Not enough state in buffer to rollback requested number of frames")
		if rollback_ticks + 1 > state_buffer.size():
			# @todo Report error in some organized way!
			push_error("Not enough state in buffer to rollback %s frame" % rollback_ticks)
			stop()
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
	
	if skip_ticks > 0:
		skip_ticks -= 1
		if skip_ticks == 0:
			for peer in peers.values():
				peer.clear_advantage()
		else:
			return
	
	var max_advantage: float
	for peer_id in peers:
		var peer = peers[peer_id]
		# Number of frames we are predicting for this peer.
		peer.local_lag = (input_tick + 1) - peer.last_remote_tick_received
		# Calculate the advantage the peer has over us.
		peer.record_advantage(ticks_to_calculate_advantage)
		# Attempt to find the greatest advantage.
		max_advantage = max(max_advantage, peer.calculated_advantage)
		
	if max_advantage >= 2.0 and skip_ticks == 0:
		skip_ticks = int(max_advantage / 2)
		return
	
	input_tick += 1
	current_tick += 1
	
	var local_input = _call_get_local_input()
	
	for peer_id in peers:
		var peer = peers[peer_id]
		var msg = {
			tick = input_tick,
			next_tick_requested = peer.last_remote_tick_received + 1,
			input = local_input,
		}
		# @todo Convert this to rpc_unreliable_id() by including multiple sets
		#       of input back to the peer.next_local_tick_requested
		rpc_id(peer_id, "receive_tick", msg)
	
	var input_frame := _get_or_create_input_frame(input_tick)
	if input_frame == null:
		return
	
	input_frame.players[get_tree().get_network_unique_id()] = InputForPlayer.new(local_input, false)
	
	
	if current_tick > 0:
		_do_tick(delta)

remote func receive_tick(msg: Dictionary) -> void:
	if not started:
		return
	
	var peer_id = get_tree().get_rpc_sender_id()
	var peer = peers[peer_id]
	peer.last_remote_tick_received = msg['tick']
	peer.next_local_tick_requested = msg['next_tick_requested']
	
	# Number of frames the remote is predicting for us.
	peer.remote_lag = (peer.last_remote_tick_received + 1) - peer.next_local_tick_requested
	
	#
	# Integrate the input we received into the input buffer.
	#
	
	var input: Dictionary = msg['input']
	var input_frame := _get_or_create_input_frame(msg['tick'])
	var tick_delta = current_tick - msg['tick']
	
	# If we received a tick in the past...
	if tick_delta >= 0:
		# Check if input matches what we had predicted, if not, inject it and then
		# flag that we need to rollback.	
		if input_frame.get_player_input(peer_id).hash() != input.hash():
			print ("Received input: %s" % input)
			print ("Predicted input: %s" % input_frame.get_player_input(peer_id))
			print ("-----")
			input_frame.players[peer_id] = InputForPlayer.new(input, false)
			# If we already flagged a rollback even further back, then we're good,
			# we don't want to inadvertedly shorten the rollback.
			if tick_delta + 1 > rollback_ticks:
				rollback_ticks = tick_delta + 1
				print ("Flagging a rollback of %s ticks" % rollback_ticks)
		else:
			# We predicted right, so just mark the input as correct!
			input_frame.players[peer_id].predicted = false
	# If we received a tick in the future...
	else:
		# So, we just store this input for when we get to it.
		input_frame.players[peer_id] = InputForPlayer.new(input, false)
