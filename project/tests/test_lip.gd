extends Node

## LipReader on shipped .lip files: Doc Mitchell's "You're awake. How about
## that." (INFO 00104BEE response 1) and a 128-byte combat line. The frame
## numbers checked are where the census found the K of "awake" and the B of
## "about" peaking.

const DOC_VOICE := "sound\\voice\\falloutnv.esm\\maleuniquedocmitchell\\vcg01_vcg01intro_00104bee_1.ogg"
const SHORT_LIP := "sound\\voice\\falloutnv.esm\\maleadult08\\vdialoguekings_hit_0015361a_1.lip"
const CHANNEL_K := 9
const CHANNEL_BMP := 2

var failures := 0

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var doc_path := DialogueServer.lip_path(DOC_VOICE)
	check(doc_path.ends_with("_00104bee_1.lip"), "a voice file's .lip is beside it (%s)" % doc_path)
	var doc := _load(doc_path)
	if doc != null:
		check(doc.get_frame_count() == 127 and doc.get_header_value() == -4, "Doc's line has 127 frames, header value -4 (got %d, %d)" % [doc.get_frame_count(), doc.get_header_value()])
		check(doc.get_channel_count() == 33 and doc.get_frames().size() == 127 * 33, "33 channels a frame")
		check(_channel(doc, 26, CHANNEL_K) > 0.95, "K peaks on frame 26, the k of awake (%.2f)" % _channel(doc, 26, CHANNEL_K))
		check(_channel(doc, 63, CHANNEL_BMP) > 0.95, "BMP peaks on frame 63, the b of about (%.2f)" % _channel(doc, 63, CHANNEL_BMP))
		check(_channel(doc, 120, 0) == 0.0, "the trailing frames are silent")
	var short := _load(SHORT_LIP)
	if short != null:
		check(short.get_frame_count() == 15, "the 128-byte line has 15 frames (got %d)" % short.get_frame_count())
	var broken := LipReader.new()
	var truncated := PackedByteArray([1, 0, 0, 0, 200, 0, 0, 0, 1, 0, 0, 0, 5, 0])
	check(not broken.load(truncated) and not broken.get_last_error().is_empty(), "a file whose body is short of its size fails to load (%s)" % broken.get_last_error())
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

func _load(path: String) -> LipReader:
	var file: Dictionary = ArchiveServer.read(path)
	check(bool(file.get("found", false)), "%s is in the archives" % path.get_file())
	if not bool(file.get("found", false)):
		return null
	var lip := LipReader.new()
	check(lip.load(file["data"], path), "%s decodes (%s)" % [path.get_file(), lip.get_last_error()])
	return lip

func _channel(lip: LipReader, frame: int, channel: int) -> float:
	return lip.get_frames()[frame * lip.get_channel_count() + channel]
