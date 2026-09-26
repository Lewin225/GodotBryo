@tool
class_name TerminalReference
extends EsmReference

## Current lock state. Starts from the base: locked unless TERM DNAM flags
## mark it unlocked. Placed terminals carry no lock data of their own.
@export var is_locked: bool = false
## Hacking difficulty, TERM DNAM byte 0: 0-4 Very Easy to Very Hard; 5 cannot
## be hacked and opens only with the password note or a script.
@export var lock_level: int = 0
