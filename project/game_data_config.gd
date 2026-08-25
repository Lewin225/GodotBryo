class_name GameDataConfig
extends RefCounted

## Pure resolver for an immutable game-data configuration Dictionary. It has no
## scene-tree dependency, so tests and worker-owned readers can safely consume
## a path resolved by the application at boot.

const ESM_FILE := "FalloutNV.esm"
const ENVIRONMENT_VARIABLES := ["GODOTBRYO_DATA_DIR", "FNV_DATA_DIR"]

static func resolve() -> Dictionary:
	var environment_data_dir := ""
	for variable_name in ENVIRONMENT_VARIABLES:
		var value := OS.get_environment(variable_name)
		if value != "":
			environment_data_dir = value
			break
	return resolve_from_candidates(environment_data_dir, default_candidates())


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
			config["source"] = "checkout"
			return config

	config["error"] = "Could not find %s. Set GODOTBRYO_DATA_DIR to the game's Data directory." % ESM_FILE
	return config


static func default_candidates() -> Array[String]:
	return [
		ProjectSettings.globalize_path("res://../fresh_nv_copy/Data/"),
		ProjectSettings.globalize_path("res://../fresh_nv_copy/NV/Data/"),
		ProjectSettings.globalize_path("res://fresh_nv_copy/Data/"),
		ProjectSettings.globalize_path("res://fresh_nv_copy/NV/Data/"),
	]


static func normalise_data_dir(path: String) -> String:
	var normalised := path.replace("\\", "/")
	if not normalised.ends_with("/"):
		normalised += "/"
	return normalised


static func has_base_esm(candidate: String) -> bool:
	return FileAccess.file_exists(candidate + ESM_FILE)
