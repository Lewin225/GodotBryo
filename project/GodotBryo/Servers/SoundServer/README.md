# SoundServer

Turns SOUN records into audio streams. Autoloaded singleton `SoundServer`.

It loads and caches; it does not play. Whoever plays a sound owns its players (`EsmWeaponNode`
for weapon sounds) and decides how to pick among several files.

---

## Contract

```gdscript
SoundServer.get_streams(sound: SoundBase) -> Array[AudioStream]  # every file the FNAM names
SoundServer.get_paths(sound: SoundBase) -> PackedStringArray     # their archive paths, same order
SoundServer.get_stream_chunk(path, start_frame := -1, end_frame := -1, looping := false) -> AudioStream
```

- A SOUN's `FNAM` (`SoundBase.file_name`) is relative to `sound\`. It names a `.wav` or `.ogg`
  file, or a folder: then every sound file directly in that folder (not below it) is returned, in
  path order. Picking among them is the caller's (`EsmWeaponNode` puts several in an
  `AudioStreamRandomizer`).
- Files are read through ArchiveServer and decoded once (`AudioStreamWAV.load_from_buffer`,
  `AudioStreamOggVorbis.load_from_buffer`); a missing or undecodable file is cached as null and
  left out, with a warning.
- Decoding runs on the calling thread, the first time a file is asked for.
- `get_stream_chunk()` cuts frames `start_frame` up to `end_frame` (-1: the file's start or end)
  out of a PCM .wav as its own stream, looping over all of it with `looping`, and caches it by
  (path, start, end, looping), so callers share one copy. A SOUN's SNDD loop points are sample
  frames (WPNMinigunSpinLPM's 3505 to 68400 equal its .wav's `smpl` loop). An .ogg cannot be cut:
  null.

## Census

Six ESMs (FalloutNV.esm and the five DLC): 3,676 SOUN, 3,674 with `FNAM`. The 621 SOUN that
WEAP sound fields and `Sound:` text keys in the `_male` and `_1stperson` KFs name: `FNAM` a
`.wav` on 347, a folder on 274. Their files: PCM (format 1), 16-bit, mono or stereo, 8 to 48 kHz;
4 are `.ogg` inside folders.
