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
	//
	// `lod_mesh_entries` (phases/2/12-distant-object-lod.md, step 7):
	// same Dictionary shape as `mesh_entries`, but for this placement's
	// optional LOD variant (GamebryoMeshResolver.build_geometry_entries()'s
	// own "lod_mesh_entries", present only for the small minority of
	// placements that are VWD-flagged with a resolvable `_lod.nif`
	// companion, see step 4) -- accumulated into a SEPARATE set of MeshGroups
	// keyed by the LOD mesh's own RID, not merged into `mesh_entries`'s
	// groups. Non-empty `lod_mesh_entries` also marks every full-detail
	// MeshGroup this same call touches as `has_lod` (see build()) -- eligibility
	// is tracked per MESH GROUP, not per placement, matching this task doc's
	// own "one crossover distance per distinct mesh, not per placement"
	// design (a MultiMesh instance can't have two different visibility
	// ranges within itself). Empty for the overwhelming majority of calls.
	void add_object(const Transform3D &world_transform, const Array &mesh_entries, const Array &shape_entries, const Array &lod_mesh_entries = Array());

	// Creates the actual RenderingServer MultiMesh instances from every
	// mesh entry accumulated by add_object() calls so far -- one instance
	// per distinct mesh Resource, not one per placement. Call once, after
	// the batch's placements are all added, before the first set_enabled(true).
	// A no-op if called again (accumulated data is cleared after building).
	void build();

	// Rendering visibility + physics space attach/detach for the whole
	// batch at once -- hidden + collision-disabled until this batch is
	// fully built, then flipped on atomically. phases/2/12-distant-object-
	// lod.md's construct-step change made the Node-based streaming path
	// reveal progressively (one object at a time, as it's add_child()'d)
	// instead of also waiting for an atomic flip -- this batch deliberately
	// still stays atomic, since a MultiMesh instance can't grow
	// incrementally the way a Node tree can (see WorldStreamer's own
	// _construct_results() doc comment for the full reasoning). Only
	// affects instances/bodies that already exist (i.e. call build() first
	// for meshes to have any effect).
	void set_enabled(bool enabled);

	// Explicit RID release -- nothing frees these automatically the way
	// Node.free() does. Safe to call more than once (a no-op after the
	// first call). Also called from the destructor as a safety net, but a
	// caller should still call this explicitly at the point a tile/the
	// persistent root actually unloads, not rely on GC timing.
	void free_all();

	int get_instance_count() const { return static_cast<int>(instances_.size()); } // distinct-mesh MultiMesh instances, not placement count -- BOTH tiers combined (full-detail + LOD, phases/2/12 step 7)
	int get_body_count() const { return static_cast<int>(bodies_.size()); }
	int get_batched_placement_count() const; // total placements folded into those instances, for the debug overlay
	int get_lod_instance_count() const { return lod_instance_count_; } // phases/2/12-distant-object-lod.md, step 7: the LOD-tier subset of get_instance_count() specifically -- 0 for the overwhelming majority of batches (no VWD-eligible content), test-facing since RenderingServer has no getter for an instance's own visibility_range to verify against directly

	// phases/2/12-distant-object-lod.md, step 7 (values now real per step 8):
	// called once per batch (WorldStreamer, right after init()) to set the
	// crossover distance/margin used for every LOD-eligible MeshGroup this
	// batch's build() creates. Sourced from WorldStreamer's own
	// @export lod_crossover_distance_m/_margin_m -- the same single real
	// value GamebryoMeshResolver.set_lod_crossover() (the Node-based path's
	// equivalent) is also sourced from, not two independently-tuned numbers.
	// Defaults to a sane, real distance (matching GamebryoMeshResolver's own
	// default) if never called at all, e.g. a test constructing a batch
	// directly.
	void set_lod_crossover(float distance_m, float margin_m);

private:
	struct MeshGroup {
		RID mesh;
		std::vector<Transform3D> transforms;
		bool has_lod = false; // phases/2/12-distant-object-lod.md, step 7 -- true if ANY add_object() call contributing to this group also had a non-empty lod_mesh_entries; see add_object()'s own doc comment for why this is tracked per-group, not per-transform
	};

	// A distinct-LOD-mesh counterpart to MeshGroup -- same accumulate-by-
	// Resource-identity shape, kept as a fully separate vector/RID set
	// rather than folded into pending_mesh_groups_, since an LOD mesh is a
	// different Resource (and gets the opposite visibility range) from the
	// full-detail mesh it's paired with.
	struct LodMeshGroup {
		RID mesh;
		std::vector<Transform3D> transforms;
	};

	RID scenario_;
	RID space_;
	bool initialized_ = false;
	bool enabled_ = true;
	float lod_crossover_distance_m_ = 100.0f; // matches GamebryoMeshResolver's own default (step 8) -- only relevant if a caller never calls set_lod_crossover(); WorldStreamer/CellLoader always do, sourced from their own single real @export value
	float lod_crossover_margin_m_ = 5.0f; // see lod_crossover_distance_m_ above

	std::vector<MeshGroup> pending_mesh_groups_; // accumulated by add_object(), consumed and cleared by build()
	std::vector<LodMeshGroup> pending_lod_mesh_groups_; // accumulated by add_object()'s own lod_mesh_entries, consumed and cleared by build()
	std::vector<RID> multimeshes_; // MultiMesh resource RIDs (separate from the instance RIDs that reference them -- both need freeing) -- holds both full-detail and LOD-tier multimeshes
	std::vector<RID> instances_; // RenderingServer instance RIDs (one per distinct mesh, post-build()) -- holds both full-detail and LOD-tier instances
	std::vector<RID> bodies_; // PhysicsServer3D body RIDs (one per placement, unchanged)
	int placed_mesh_count_ = 0; // total FULL-DETAIL mesh entries ever added (LOD entries deliberately not counted here -- this is what the debug overlay's "placed objects" figure means, unchanged by this step), independent of pending_mesh_groups_ being cleared by build() -- what get_batched_placement_count() actually reports
	int lod_instance_count_ = 0; // phases/2/12-distant-object-lod.md, step 7 -- see get_lod_instance_count()
};

} // namespace godot

#endif // DIRECT_GEOMETRY_BATCH_H
