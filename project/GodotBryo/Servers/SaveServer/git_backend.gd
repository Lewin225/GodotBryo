class_name GitBackend
extends SaveBackend

## Stores saves as commits in one git repository per playthrough, so saves
## share unchanged files. Each save is the same folder of JSON files
## JsonFolderBackend writes, committed whole; its save_id is the ref
## `refs/saves/<save_id>`. A save's parent commit is the save last written or
## read in its playthrough, so saving after loading an earlier save starts a
## branch. Needs the git command; `is_available()` says whether it runs.
##
##   <root>/<playthrough>/repo.git    the repository (bare)
##   <root>/<playthrough>/tree/       the save being written, committed from
##   <root>/<playthrough>/read/       the save being read, checked out
##
## A save_id from list() is `<playthrough>/<save_id>`. A bare save_id is in
## `playthrough_id`, which SaveServer sets.

const COMMITTER := ["-c", "user.name=GodotBryo", "-c", "user.email=saves@localhost", "-c", "commit.gpgsign=false"]
const REF_PREFIX := "refs/saves/"
const TREE_FOLDER := "tree"
const READ_FOLDER := "read"

## The folder that holds one folder per playthrough.
var root := "user://saves_git"

## Playthrough -> the commit last written or read there: the next save's
## parent.
var _last_commit: Dictionary = {}


func _init(saves_root: String = "user://saves_git") -> void:
	root = saves_root


## Whether the git command runs.
static func is_available() -> bool:
	var output := []
	return OS.execute("git", ["--version"], output, true) == 0


func write(save_id: String, state: Dictionary) -> Error:
	last_error = ""
	var playthrough := _playthrough_or_current(state.get("header", {}).get("playthrough"))
	var ready := _ensure_repository(playthrough)
	if ready != OK:
		return ready
	var folder := _playthrough_folder(playthrough)
	var files := JsonFolderBackend.new(folder)
	var written := files.write(TREE_FOLDER, state)
	if written != OK:
		return _fail(written, files.last_error)
	var tree_path := folder.path_join(TREE_FOLDER)
	var added := _git(playthrough, ["add", "-A"], tree_path)
	if added.code != 0:
		return _fail(FAILED, "git add: " + added.text)
	var tree := _git(playthrough, ["write-tree"], tree_path)
	if tree.code != 0:
		return _fail(FAILED, "git write-tree: " + tree.text)
	var commit_args := ["commit-tree", tree.text, "-m", save_id]
	var parent := String(_last_commit.get(playthrough, ""))
	if not parent.is_empty():
		commit_args.append_array(["-p", parent])
	var commit := _git(playthrough, commit_args)
	if commit.code != 0:
		return _fail(FAILED, "git commit-tree: " + commit.text)
	var updated := _git(playthrough, ["update-ref", _ref(save_id), commit.text])
	if updated.code != 0:
		return _fail(FAILED, "git update-ref: " + updated.text)
	_last_commit[playthrough] = commit.text
	# Packs loose objects once enough have built up.
	_git(playthrough, ["gc", "--auto", "--quiet"])
	return OK


func read(save_id: String) -> Dictionary:
	last_error = ""
	var where := _split(save_id)
	var playthrough: String = where[0]
	var name: String = where[1]
	if not DirAccess.dir_exists_absolute(_repository(playthrough)):
		_fail(ERR_FILE_NOT_FOUND, "no playthrough %s" % playthrough)
		return {}
	var commit := _git(playthrough, ["rev-parse", "--verify", "--quiet", _ref(name)])
	if commit.code != 0:
		_fail(ERR_FILE_NOT_FOUND, "no save %s in playthrough %s" % [name, playthrough])
		return {}
	var folder := _playthrough_folder(playthrough)
	var read_path := folder.path_join(READ_FOLDER)
	_remove_folder(read_path)
	DirAccess.make_dir_recursive_absolute(read_path)
	var checked_out := _git(playthrough, ["checkout", "--force", commit.text, "--", "."], read_path)
	if checked_out.code != 0:
		_fail(FAILED, "git checkout: " + checked_out.text)
		return {}
	var files := JsonFolderBackend.new(folder)
	var state := files.read(READ_FOLDER)
	if state.is_empty():
		_fail(ERR_FILE_CORRUPT, files.last_error)
		return {}
	_last_commit[playthrough] = commit.text
	return state


func list() -> Array[Dictionary]:
	var saves: Array[Dictionary] = []
	if not DirAccess.dir_exists_absolute(root):
		return saves
	for playthrough in DirAccess.get_directories_at(root):
		if not DirAccess.dir_exists_absolute(_repository(playthrough)):
			continue
		var refs := _git(playthrough, ["for-each-ref", REF_PREFIX, "--format=%(refname:lstrip=2) %(objectname)"])
		if refs.code != 0 or refs.text.is_empty():
			continue
		for line in refs.text.split("\n"):
			saves.append_array(_list_entry(playthrough, line))
	return saves


func delete(save_id: String) -> Error:
	last_error = ""
	var where := _split(save_id)
	var deleted := _git(where[0], ["update-ref", "-d", _ref(where[1])])
	if deleted.code != 0:
		return _fail(ERR_FILE_NOT_FOUND, "no save %s: %s" % [save_id, deleted.text])
	return OK


func has_save(save_id: String) -> bool:
	var where := _split(save_id)
	if not DirAccess.dir_exists_absolute(_repository(where[0])):
		return false
	return _git(where[0], ["rev-parse", "--verify", "--quiet", _ref(where[1])]).code == 0


func capabilities() -> PackedStringArray:
	return PackedStringArray(["parents"])


## The save on one for-each-ref line, with its header, as a one-entry array;
## empty when its header cannot be read.
func _list_entry(playthrough: String, line: String) -> Array[Dictionary]:
	var entry: Array[Dictionary] = []
	var parts := line.split(" ")
	var name := String(parts[0]).uri_decode()
	var shown := _git(playthrough, ["show", "%s:header.json" % parts[1]])
	if shown.code != 0:
		return entry
	var header: Variant = JSON.parse_string(shown.text)
	if not header is Dictionary:
		return entry
	var listed: Dictionary = header.duplicate()
	listed["save_id"] = "%s/%s" % [playthrough, name]
	listed["commit"] = parts[1]
	entry.append(listed)
	return entry


## Makes the playthrough's repository when it has none.
func _ensure_repository(playthrough: String) -> Error:
	if DirAccess.dir_exists_absolute(_repository(playthrough)):
		return OK
	DirAccess.make_dir_recursive_absolute(_playthrough_folder(playthrough))
	var output := []
	var code := OS.execute("git", ["init", "--quiet", "--bare", ProjectSettings.globalize_path(_repository(playthrough))], output, true)
	if code != 0:
		return _fail(FAILED, "git init: " + "".join(output).strip_edges())
	return OK


## Runs git on the playthrough's repository, with `work_tree` as its working
## tree when given. Returns the exit code and the trimmed output.
func _git(playthrough: String, args: Array, work_tree: String = "") -> Dictionary:
	var full_args: Array = ["--git-dir=" + ProjectSettings.globalize_path(_repository(playthrough))]
	if not work_tree.is_empty():
		full_args.append("--work-tree=" + ProjectSettings.globalize_path(work_tree))
	full_args.append_array(COMMITTER)
	full_args.append_array(args)
	var output := []
	var code := OS.execute("git", full_args, output, true)
	return {"code": code, "text": "".join(output).strip_edges()}


## [playthrough, save name] for a save_id from list() or a bare one.
func _split(save_id: String) -> Array:
	var slash := save_id.find("/")
	if slash < 0:
		return [_playthrough_or_current(null), save_id]
	return [save_id.substr(0, slash), save_id.substr(slash + 1)]


## `playthrough` when it names one, else playthrough_id, else "default".
func _playthrough_or_current(playthrough: Variant) -> String:
	if playthrough != null and not String(playthrough).is_empty():
		return String(playthrough)
	if not playthrough_id.is_empty():
		return playthrough_id
	return "default"


## The save's ref; the name is URI-encoded, since a ref cannot hold spaces.
func _ref(save_name: String) -> String:
	return REF_PREFIX + save_name.uri_encode()


func _playthrough_folder(playthrough: String) -> String:
	return root.path_join(playthrough.validate_filename())


func _repository(playthrough: String) -> String:
	return _playthrough_folder(playthrough).path_join("repo.git")


func _remove_folder(folder: String) -> void:
	if not DirAccess.dir_exists_absolute(folder):
		return
	for sub in DirAccess.get_directories_at(folder):
		_remove_folder(folder.path_join(sub))
	for file in DirAccess.get_files_at(folder):
		DirAccess.remove_absolute(folder.path_join(file))
	DirAccess.remove_absolute(folder)


func _fail(error: Error, message: String) -> Error:
	last_error = message
	return error
