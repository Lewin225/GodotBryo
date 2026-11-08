extends Node

## Turns SOUN records into audio streams. Autoloaded singleton `SoundServer`.
## README.md in this folder holds the contract and the census behind it.

## The folder SOUN FNAM paths are relative to.
const SOUND_ROOT := "sound/"
## File extensions a SOUN's files have (the weapons' and clips' 621 SOUN: PCM
## .wav, and 4 .ogg in folders).
const WAV_EXTENSION := ".wav"
const OGG_EXTENSION := ".ogg"

## Archive path -> its AudioStream; null for a file that is missing or does not
## decode.
var _streams := {}
## Folder path -> the archive paths of the sound files directly in it.
var _folders := {}


## Every stream `sound`'s FNAM names, in file order: one for a file, each of a
## folder's files for a folder (the caller picks among them, for example with an
## AudioStreamRandomizer). Empty for no sound, an empty FNAM or nothing found.
## Decoded once and cached.
func get_streams(sound: SoundBase) -> Array[AudioStream]:
	var result: Array[AudioStream] = []
	if sound == null or sound.file_name.is_empty():
		return result
	for path in _paths_of(sound.file_name):
		var stream := _stream(path)
		if stream != null:
			result.append(stream)
	return result


## The archive paths a FNAM names: the file, or the sound files directly in
## the folder.
func _paths_of(file_name: String) -> PackedStringArray:
	var path := SOUND_ROOT + file_name.replace("\\", "/").to_lower()
	if path.ends_with(WAV_EXTENSION) or path.ends_with(OGG_EXTENSION):
		return PackedStringArray([path])
	if not path.ends_with("/"):
		path += "/"
	if _folders.has(path):
		return _folders[path]
	var files := PackedStringArray()
	for listed in ArchiveServer.list_files_with_prefix(path):
		var canonical := String(listed).replace("\\", "/").to_lower()
		var in_folder := not canonical.trim_prefix(path).contains("/")
		if in_folder and (canonical.ends_with(WAV_EXTENSION) or canonical.ends_with(OGG_EXTENSION)):
			files.append(canonical)
	files.sort()
	_folders[path] = files
	return files


func _stream(path: String) -> AudioStream:
	if _streams.has(path):
		return _streams[path]
	var file: Dictionary = ArchiveServer.read(path)
	var stream: AudioStream = null
	if bool(file.get("found", false)):
		var data: PackedByteArray = file["data"]
		if path.ends_with(OGG_EXTENSION):
			stream = AudioStreamOggVorbis.load_from_buffer(data)
		else:
			stream = AudioStreamWAV.load_from_buffer(data)
	if stream == null:
		push_warning("SoundServer: could not load " + path)
	_streams[path] = stream
	return stream
