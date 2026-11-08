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
## [path, start frame, end frame, looping, loop begin frame] -> the chunk's
## AudioStream; null
## for one that cannot be cut.
var _chunks := {}


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


## The archive paths `sound`'s FNAM names, in the order get_streams() returns
## their streams.
func get_paths(sound: SoundBase) -> PackedStringArray:
	if sound == null or sound.file_name.is_empty():
		return PackedStringArray()
	return _paths_of(sound.file_name)


## The frames from `start_frame` up to `end_frame` of the .wav at `path`, as its
## own stream; -1 for the file's start or end. With `looping` the chunk loops
## from `loop_begin_frame` (a frame of the file; -1 the chunk's start) to its
## end, so what comes before plays once (a wind-up). Cut once and cached: every
## caller asking for the same chunk shares it. Null for a file that is missing,
## not 8- or 16-bit PCM (an .ogg cannot be cut by frame), or a range outside it.
func get_stream_chunk(path: String, start_frame := -1, end_frame := -1, looping := false, loop_begin_frame := -1) -> AudioStream:
	var key := [path, start_frame, end_frame, looping, loop_begin_frame]
	if _chunks.has(key):
		return _chunks[key]
	var chunk := _cut(_stream(path) as AudioStreamWAV, start_frame, end_frame, looping, loop_begin_frame)
	_chunks[key] = chunk
	return chunk


static func _cut(source: AudioStreamWAV, start_frame: int, end_frame: int, looping: bool, loop_begin_frame: int) -> AudioStreamWAV:
	if source == null:
		return null
	var bytes_per_sample := 0
	match source.format:
		AudioStreamWAV.FORMAT_8_BITS:
			bytes_per_sample = 1
		AudioStreamWAV.FORMAT_16_BITS:
			bytes_per_sample = 2
	if bytes_per_sample == 0:
		return null
	var bytes_per_frame := bytes_per_sample * (2 if source.stereo else 1)
	var frames := source.data.size() / bytes_per_frame
	var first := 0 if start_frame < 0 else start_frame
	var last := frames if end_frame < 0 else end_frame
	if first >= last or last > frames:
		return null
	var chunk := AudioStreamWAV.new()
	chunk.format = source.format
	chunk.stereo = source.stereo
	chunk.mix_rate = source.mix_rate
	chunk.data = source.data.slice(first * bytes_per_frame, last * bytes_per_frame)
	if looping:
		chunk.loop_mode = AudioStreamWAV.LOOP_FORWARD
		chunk.loop_begin = clampi(loop_begin_frame - first, 0, last - first - 1) if loop_begin_frame >= 0 else 0
		chunk.loop_end = last - first
	return chunk


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
