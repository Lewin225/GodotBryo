@tool
class_name ScriptBase
extends EsmBase

## SCPT (Script). Named by SCRI on any record that runs a script. EsmBase holds
## EDID. ScriptServer compiles and runs scripts from the record's FormID.
##
## Not read yet (xEdit labels): SCHR Basic Script Data (ref count, compiled
## size, variable count, type, flags); SCDA Compiled Script; SCTX Script Source;
## SLSD / SCVR local variables; SCRO / SCRV references. ScriptServer reads the
## record directly; these become fields if scripts are shown or edited as
## resources.
