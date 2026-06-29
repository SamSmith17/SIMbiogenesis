class_name HistoryManager
extends RefCounted
## Snapshot-based undo/redo for the GraphModel.
##
## Stores a linear sequence of serialized model states.
## `_cursor` always points to the currently-displayed state.
##
## Typical flow (push-after-action):
##   initial push:  history=[S0], cursor=0
##   user adds node → push(S1):  history=[S0,S1], cursor=1
##   undo → restore S0:          cursor=0
##   redo → restore S1:          cursor=1
##   user does something new → push(S2): history=[S0,S2], cursor=1

const MAX_HISTORY := 60

var _stack:  Array[Dictionary] = []
var _cursor: int               = -1


## Append a new state, discarding any redo states past the cursor.
func push(snapshot: Dictionary) -> void:
	# Trim redo branch
	if _cursor < _stack.size() - 1:
		_stack.resize(_cursor + 1)
	_stack.append(snapshot.duplicate(true))
	# Evict oldest entry when over limit
	if _stack.size() > MAX_HISTORY:
		_stack.pop_front()
	_cursor = _stack.size() - 1


## Return the snapshot to restore for an Undo step, or {} when at the start.
func undo() -> Dictionary:
	if not can_undo():
		return {}
	_cursor -= 1
	return _stack[_cursor].duplicate(true)


## Return the snapshot to restore for a Redo step, or {} when at the end.
func redo() -> Dictionary:
	if not can_redo():
		return {}
	_cursor += 1
	return _stack[_cursor].duplicate(true)


func can_undo() -> bool:
	return _cursor > 0


func can_redo() -> bool:
	return _cursor >= 0 and _cursor < _stack.size() - 1


func clear() -> void:
	_stack.clear()
	_cursor = -1


## How deep is the undo stack (steps available)?
func undo_depth() -> int:
	return _cursor
