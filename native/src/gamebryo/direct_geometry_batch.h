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

// phases/2/09-direct-server-static-geometry.md, steps 1 and 6 (MultiMesh
// batching). Tracks RenderingServer/PhysicsServer3D RIDs for a batch of
// non-interactive, static placements (one instance per WorldStreamer
// resident tile, plus one for the persistent root) -- no Node involved at
// all. Implemented in C++ rather than GDScript deliberately: the actual
// per-frame FPS cost this task is chasing is already 100% engine-native
// regardless of which language creates the RIDs, but *constructing*
// potentially thousands of instances/bodies per tile during streaming pays
// real per-call GDScript marshalling overhead -- directly relevant to the
// streaming-stall issue, not just steady-state FPS. Consistent with this
// project's own stated architecture split (heavy GDExtension for
// performance-critical work, GDScript for game-logic glue).
//
// Render meshes are batched via RenderingServer's own MultiMesh mechanism
// (one RenderingServer instance per DISTINCT mesh Resource, holding every
// placement that reuses it as an array of transforms) rather than one
// instance per placement -- add_object() only accumulates data; the actual
// MultiMesh RenderingServer calls happen once in build(), after every
// placement for a tile has been added. Confirmed via direct measurement
// that this step matters: creating one instance per placement (this
// class's first version) roughly halved total Node count but left
// process_frame wall time completely unchanged, because Godot's renderer
// still has to cull/process the same number of RenderingServer instances
// either way -- reducing Node count alone doesn't reduce instance count.
// Physics has no equivalent instancing primitive, so bodies stay one per
// placement, same as before.
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
	// TRUE WORLD transform (see GamebryoMeshResolver.world_transform_no_parent()
	// -- NOT the same as the Node-based path's RefrRoot-relative local
	// transform; there's no parent Node here to compose the Z-up->Y-up axis
	// conversion for you). `mesh_entries` is an Array of Dictionary
	// { "mesh": Mesh, "transform": Transform3D } (local, composed with
	// world_transform) -- accumulated by mesh Resource identity, not
	// instanced immediately; call build() once every placement for this
	// batch has been added. `shape_entries` is an Array of Dictionary
	// { "shape": Shape3D, "transform": Transform3D } (local) -- all added to
	// a SINGLE static PhysicsServer3D body created immediately (matching how
	// a single StaticBody3D today holds multiple CollisionShape3D children
	// as one body with multiple shapes, not one body per shape -- physics
	// has no batching equivalent to MultiMesh, so this part of add_object()
	// is unchanged from before). Either array may be empty.
	void add_object(const Transform3D &world_transform, const Array &mesh_entries, const Array &shape_entries);

	// Creates the actual RenderingServer MultiMesh instances from every
	// mesh entry accumulated by add_object() calls so far -- one instance
	// per distinct mesh Resource, not one per placement. Call once, after
	// the batch's placements are all added, before the first set_enabled(true).
	// A no-op if called again (accumulated data is cleared after building).
	void build();

	// Rendering visibility + physics space attach/detach for the whole
	// batch at once -- the RID equivalent of the Node-based streaming
	// pattern's "hidden + collision-disabled until fully built, then
	// flipped on atomically" (CellStreamBuilder.set_collision_disabled()).
	// Only affects instances/bodies that already exist (i.e. call build()
	// first for meshes to have any effect).
	void set_enabled(bool enabled);

	// Explicit RID release -- nothing frees these automatically the way
	// Node.free() does. Safe to call more than once (a no-op after the
	// first call). Also called from the destructor as a safety net, but a
	// caller should still call this explicitly at the point a tile/the
	// persistent root actually unloads, not rely on GC timing.
	void free_all();

	int get_instance_count() const { return static_cast<int>(instances_.size()); } // distinct-mesh MultiMesh instances, not placement count
	int get_body_count() const { return static_cast<int>(bodies_.size()); }
	int get_batched_placement_count() const; // total placements folded into those instances, for the debug overlay

private:
	struct MeshGroup {
		RID mesh;
		std::vector<Transform3D> transforms;
	};

	RID scenario_;
	RID space_;
	bool initialized_ = false;
	bool enabled_ = true;

	std::vector<MeshGroup> pending_mesh_groups_; // accumulated by add_object(), consumed and cleared by build()
	std::vector<RID> multimeshes_; // MultiMesh resource RIDs (separate from the instance RIDs that reference them -- both need freeing)
	std::vector<RID> instances_; // RenderingServer instance RIDs (one per distinct mesh, post-build())
	std::vector<RID> bodies_; // PhysicsServer3D body RIDs (one per placement, unchanged)
	int placed_mesh_count_ = 0; // total mesh entries ever added, independent of pending_mesh_groups_ being cleared by build() -- what get_batched_placement_count() actually reports
};

} // namespace godot

#endif // DIRECT_GEOMETRY_BATCH_H
