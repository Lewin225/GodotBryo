#ifndef DIRECT_GEOMETRY_BATCH_H
#define DIRECT_GEOMETRY_BATCH_H

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/shape3d.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include <vector>

namespace godot {

// phases/2/09-direct-server-static-geometry.md, step 1. Tracks
// RenderingServer/PhysicsServer3D RIDs for a batch of non-interactive,
// static placements (one instance per WorldStreamer resident tile, plus one
// for the persistent root) -- no Node involved at all. Implemented in C++
// rather than GDScript deliberately: the actual per-frame FPS cost this
// task is chasing is already 100% engine-native regardless of which
// language creates the RIDs (RenderingServer/PhysicsServer3D are compiled
// singletons either way), but *constructing* potentially thousands of
// instances/bodies per tile during streaming pays real per-call GDScript
// marshalling overhead -- directly relevant to the streaming-stall issue
// (rendering-issues list #5), not just steady-state FPS. Consistent with
// this project's own stated architecture split (heavy GDExtension for
// performance-critical work, GDScript for game-logic glue).
class DirectGeometryBatch : public RefCounted {
	GDCLASS(DirectGeometryBatch, RefCounted)

protected:
	static void _bind_methods();

public:
	DirectGeometryBatch() = default;
	~DirectGeometryBatch() override;

	// Must be called once before add_object(); pulls the scenario/space RIDs
	// from `world_node`'s own World3D so instances/bodies land in the same
	// World3D the rest of the scene renders/simulates in. Takes a Node3D
	// (not a World3D directly) since that's what a caller (WorldStreamer)
	// already has on hand.
	void init(Node3D *world_node);

	// One placement: `world_transform` is the placement's own resolved
	// world transform (position/rotation/scale, same convention
	// GamebryoObjectRegistry._finalize() already computes for the Node-based
	// path). `mesh_entries` is an Array of Dictionary { "mesh": Mesh,
	// "transform": Transform3D } (local, composed with world_transform) --
	// one RenderingServer instance per entry. `shape_entries` is an Array of
	// Dictionary { "shape": Shape3D, "transform": Transform3D } (local) --
	// all added to a SINGLE static PhysicsServer3D body (matching how a
	// single StaticBody3D today holds multiple CollisionShape3D children as
	// one body with multiple shapes, not one body per shape). Either array
	// may be empty (e.g. a shape with no render mesh, or vice versa).
	void add_object(const Transform3D &world_transform, const Array &mesh_entries, const Array &shape_entries);

	// Rendering visibility + physics space attach/detach for the whole
	// batch at once -- the RID equivalent of the Node-based streaming
	// pattern's "hidden + collision-disabled until fully built, then
	// flipped on atomically" (CellStreamBuilder.set_collision_disabled()).
	void set_enabled(bool enabled);

	// Explicit RID release -- nothing frees these automatically the way
	// Node.free() does. Safe to call more than once (a no-op after the
	// first call). Also called from the destructor as a safety net, but a
	// caller should still call this explicitly at the point a tile/the
	// persistent root actually unloads, not rely on GC timing.
	void free_all();

	int get_instance_count() const { return static_cast<int>(instances_.size()); }
	int get_body_count() const { return static_cast<int>(bodies_.size()); }

private:
	RID scenario_;
	RID space_;
	bool initialized_ = false;
	bool enabled_ = true;

	std::vector<RID> instances_; // RenderingServer instance RIDs
	std::vector<RID> bodies_; // PhysicsServer3D body RIDs
};

} // namespace godot

#endif // DIRECT_GEOMETRY_BATCH_H
