#ifndef NV_PING_H
#define NV_PING_H

#include <godot_cpp/classes/node.hpp>

namespace godot {

// Phase 0.0 sanity-check class: proves the GDExtension build/load round trip
// works before any real parsing code (BSA/ESM/NIF/DDS) is written.
class NVPing : public Node {
	GDCLASS(NVPing, Node)

protected:
	static void _bind_methods();

public:
	String ping() const;
};

} // namespace godot

#endif // NV_PING_H
