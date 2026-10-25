class_name GameDataConfig
extends RefCounted

## Pure resolver for an immutable game-data configuration Dictionary. It has no
## scene-tree dependency, so tests and worker-owned readers can safely consume
## a path resolved by the application at boot.

const ESM_FILE := "FalloutNV.esm"
const ENVIRONMENT_VARIABLES := ["GODOTBRYO_DATA_DIR", "FNV_DATA_DIR"]
## The data directory chosen in the launcher.
const SAVED_CONFIG := "user://game_data.cfg"

static func resolve() -> Dictionary:
	var environment_data_dir := ""
	for variable_name in ENVIRONMENT_VARIABLES:
		var value := OS.get_environment(variable_name)
		if value != "":
			environment_data_dir = value
			break
	var candidates: Array[String] = []
	var saved := saved_data_dir()
	if not saved.is_empty():
		candidates.append(saved)
	return resolve_from_candidates(environment_data_dir, candidates)


## The data directory the launcher saved, or "" when none is saved.
static func saved_data_dir() -> String:
	var file := ConfigFile.new()
	if file.load(SAVED_CONFIG) != OK:
		return ""
	return String(file.get_value("game_data", "data_dir", ""))


## Saves `data_dir` as the launcher's choice. False when it holds no ESM_FILE
## or the file cannot be written.
static func save_data_dir(data_dir: String) -> bool:
	var normalised := normalise_data_dir(data_dir)
	if not has_base_esm(normalised):
		return false
	var file := ConfigFile.new()
	file.set_value("game_data", "data_dir", normalised)
	return file.save(SAVED_CONFIG) == OK


## Public for tests and a future installation picker. An explicit override is
## authoritative: an invalid override reports an actionable error rather than
## silently selecting another installation.
static func resolve_from_candidates(environment_data_dir: String, candidates: Array[String]) -> Dictionary:
	var config := { "data_dir": "", "source": "", "error": "" }
	if environment_data_dir != "":
		var override_dir := normalise_data_dir(environment_data_dir)
		if has_base_esm(override_dir):
			config["data_dir"] = override_dir
			config["source"] = "environment"
			return config
		config["error"] = "Configured game data directory does not contain %s: %s" % [ESM_FILE, override_dir]
		return config

	for candidate in candidates:
		var data_dir_candidate := normalise_data_dir(candidate)
		# An existing but empty/incomplete directory must not mask a later
		# valid install candidate.
		if has_base_esm(data_dir_candidate):
			config["data_dir"] = data_dir_candidate
			config["source"] = "saved"
			return config

	config["error"] = "Could not find %s. Choose it in the launcher, or set GODOTBRYO_DATA_DIR to the game's Data directory." % ESM_FILE
	return config


static func normalise_data_dir(path: String) -> String:
	var normalised := path.replace("\\", "/")
	if not normalised.ends_with("/"):
		normalised += "/"
	return normalised


static func has_base_esm(candidate: String) -> bool:
	return FileAccess.file_exists(candidate + ESM_FILE)
