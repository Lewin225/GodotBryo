@tool
class_name SoundBase
extends EsmBase

## SOUN (Sound). Named by CREA CSDI (creature sounds), WEAP's sound fields, the
## `Sound:` text keys of KF clips and many other records. EsmBase holds EDID.
## SoundServer turns it into its audio streams.
##
## Not read yet (xEdit labels): OBND Object Bounds; RNAM Random Chance %; SNDD
## static attenuation, start and stop time, attenuation curve, reverb
## attenuation, priority and loop points (SNDX carries none of the last five);
## ANAM Attenuation Curve; GNAM Reverb Attenuation Control; HNAM Priority.

## SNDD / SNDX flags, xEdit's names.
const FLAG_NAMES := "Random Frequency Shift:1,Play At Random:2,Environment Ignored:4,Random Location:8,Loop:16,Menu Sound:32,2D:64,360 LFE:128,Dialogue Sound:256,Envelope Fast:512,Envelope Slow:1024,2D Radius:2048,Mute When Submerged:4096,Start at Random Position:8192"
const FLAG_LOOP := 0x10
const FLAG_2D := 0x40

## FNAM: the sound file, or the folder of files one of which plays, relative to
## `sound\` (on 3,674 of the six ESMs' 3,676 SOUN; of the 621 the weapons and
## clip text keys use, a .wav on 347 and a folder on 274). Read; used by
## SoundServer.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var file_name: String = ""
## SNDD / SNDX byte 0, times 5: Minimum Attenuation Distance, game units (SNDD
## on 3,540 SOUN, SNDX on 136; both on none). Read; used by EsmWeaponNode for
## its sound players' unit size.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var minimum_attenuation_distance: float = 0.0
## SNDD / SNDX byte 1, times 100: Maximum Attenuation Distance, game units.
## Read; used by EsmWeaponNode for its sound players' maximum distance.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var maximum_attenuation_distance: float = 0.0
## SNDD / SNDX byte 2: Frequency Adjustment %, signed. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var frequency_adjustment: int = 0
## SNDD / SNDX offset 4: Flags (FLAG_NAMES). Read; not used yet (Loop and 2D
## by sound players).
@export_custom(PROPERTY_HINT_FLAGS, FLAG_NAMES, PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
