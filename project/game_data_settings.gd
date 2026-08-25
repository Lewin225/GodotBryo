@tool
extends Node

## Application-owned game-install settings. Runtime code reads the resolved
## configuration here; worker contexts receive its immutable data directory
## explicitly and never access this autoload from a worker thread.

const GameDataConfigScript := preload("res://game_data_config.gd")

var _config: Dictionary = {}


func _ready() -> void:
	_config = GameDataConfigScript.resolve()
	if not String(_config.get("error", "")).is_empty():
		push_error("GameDataSettings: " + String(_config["error"]))


func get_data_dir() -> String:
	return String(_config.get("data_dir", ""))


func get_config():
	return _config
