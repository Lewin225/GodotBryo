Each server is a autoloaded singleton in global scope, in the same vein as godot's render/physics servers

They should offer a defined contract, thread and coroutine as much of their work as possible.

They should not call into *non* server scripts, so checking GodotBryoSettings for the esm path is okay.

# NOTE - GodotBryoSettings will be moved into this folder soon as GodotBryoSettingsServer
