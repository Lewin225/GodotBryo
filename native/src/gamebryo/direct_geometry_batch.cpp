#include "direct_geometry_batch.h"

#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>

using namespace godot;

void DirectGeometryBatch::_bind_methods() {
	ClassDB::bind_method(D_METHOD("init", "world_node"), &DirectGeometryBatch::init);
	ClassDB::bind_method(D_METHOD("add_object", "world_transform", "mesh_entries", "shape_entries", "lod_mesh_entries"), &DirectGeometryBatch::add_object, DEFVAL(Array()));
	ClassDB::bind_method(D_METHOD("set_lod_crossover", "distance_m", "margin_m"), &DirectGeometryBatch::set_lod_crossover);
	ClassDB::bind_method(D_METHOD("build"), &DirectGeometryBatch::build);
	ClassDB::bind_method(D_METHOD("set_enabled", "enabled"), &DirectGeometryBatch::set_enabled);
	ClassDB::bind_method(D_METHOD("free_all"), &DirectGeometryBatch::free_all);
	ClassDB::bind_method(D_METHOD("get_instance_count"), &DirectGeometryBatch::get_instance_count);
	ClassDB::bind_method(D_METHOD("get_body_count"), &DirectGeometryBatch::get_body_count);
	ClassDB::bind_method(D_METHOD("get_batched_placement_count"), &DirectGeometryBatch::get_batched_placement_count);
	ClassDB::bind_method(D_METHOD("get_lod_instance_count"), &DirectGeometryBatch::get_lod_instance_count);
}

DirectGeometryBatch::~DirectGeometryBatch() {
	free_all(); // safety net -- a caller should still free explicitly at tile-unload time
}

void DirectGeometryBatch::init(Node3D *world_node) {
	if (world_node == nullptr) {
		return;
	}
	Ref<World3D> world = world_node->get_world_3d();
	if (world.is_null()) {
		return;
	}
	scenario_ = world->get_scenario();
	space_ = world->get_space();
	initialized_ = true;
}

void DirectGeometryBatch::add_object(const Transform3D &world_transform, const Array &mesh_entries, const Array &shape_entries, const Array &lod_mesh_entries) {
	if (!initialized_) {
		return; // init() wasn't called -- nothing to attach these to
	}

	bool placement_has_lod = lod_mesh_entries.size() > 0;

	for (int i = 0; i < mesh_entries.size(); ++i) {
		Dictionary entry = mesh_entries[i];
		Ref<Mesh> mesh = entry.get("mesh", Variant());
		if (mesh.is_null()) {
			continue;
		}
		Transform3D local = entry.get("transform", Transform3D());
		RID mesh_rid = mesh->get_rid();
		Transform3D instance_transform = world_transform * local;
		placed_mesh_count_++;

		bool found = false;
		for (MeshGroup &group : pending_mesh_groups_) {
			if (group.mesh == mesh_rid) {
				group.transforms.push_back(instance_transform);
				if (placement_has_lod) {
					group.has_lod = true;
				}
				found = true;
				break;
			}
		}
		if (!found) {
			MeshGroup group;
			group.mesh = mesh_rid;
			group.transforms.push_back(instance_transform);
			group.has_lod = placement_has_lod;
			pending_mesh_groups_.push_back(group);
		}
	}

	for (int i = 0; i < lod_mesh_entries.size(); ++i) {
		Dictionary entry = lod_mesh_entries[i];
		Ref<Mesh> mesh = entry.get("mesh", Variant());
		if (mesh.is_null()) {
			continue;
		}
		Transform3D local = entry.get("transform", Transform3D());
		RID mesh_rid = mesh->get_rid();
		Transform3D instance_transform = world_transform * local;

		bool found = false;
		for (LodMeshGroup &group : pending_lod_mesh_groups_) {
			if (group.mesh == mesh_rid) {
				group.transforms.push_back(instance_transform);
				found = true;
				break;
			}
		}
		if (!found) {
			LodMeshGroup group;
			group.mesh = mesh_rid;
			group.transforms.push_back(instance_transform);
			pending_lod_mesh_groups_.push_back(group);
		}
	}

	if (shape_entries.size() > 0) {
		PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
		RID body = ps->body_create();
		ps->body_set_mode(body, PhysicsServer3D::BODY_MODE_STATIC);
		ps->body_set_state(body, PhysicsServer3D::BODY_STATE_TRANSFORM, world_transform);
		for (int i = 0; i < shape_entries.size(); ++i) {
			Dictionary entry = shape_entries[i];
			Ref<Shape3D> shape = entry.get("shape", Variant());
			if (shape.is_null()) {
				continue;
			}
			Transform3D local = entry.get("transform", Transform3D());
			ps->body_add_shape(body, shape->get_rid(), local);
		}
		if (enabled_) {
			ps->body_set_space(body, space_);
		}
		bodies_.push_back(body);
	}
}

void DirectGeometryBatch::build() {
	if ((pending_mesh_groups_.empty() && pending_lod_mesh_groups_.empty()) || !initialized_) {
		return;
	}

	RenderingServer *rs = RenderingServer::get_singleton();
	for (const MeshGroup &group : pending_mesh_groups_) {
		RID multimesh = rs->multimesh_create();
		rs->multimesh_set_mesh(multimesh, group.mesh);
		rs->multimesh_allocate_data(multimesh, static_cast<int32_t>(group.transforms.size()), RenderingServer::MULTIMESH_TRANSFORM_3D);
		for (size_t i = 0; i < group.transforms.size(); ++i) {
			rs->multimesh_instance_set_transform(multimesh, static_cast<int32_t>(i), group.transforms[i]);
		}
		multimeshes_.push_back(multimesh);

		RID instance = rs->instance_create2(multimesh, scenario_);
		rs->instance_set_visible(instance, enabled_);
		// phases/2/12-distant-object-lod.md, step 7: this MeshGroup is only
		// visible within the crossover distance if a paired LOD group exists
		// for it (has_lod) -- otherwise leave the visibility range at its
		// RenderingServer default (always visible), the overwhelming common
		// case, completely unaffected by this step.
		if (group.has_lod) {
			rs->instance_geometry_set_visibility_range(instance, 0.0f, lod_crossover_distance_m_, 0.0f, lod_crossover_margin_m_, RenderingServer::VISIBILITY_RANGE_FADE_DISABLED);
		}
		instances_.push_back(instance);
	}

	for (const LodMeshGroup &group : pending_lod_mesh_groups_) {
		RID multimesh = rs->multimesh_create();
		rs->multimesh_set_mesh(multimesh, group.mesh);
		rs->multimesh_allocate_data(multimesh, static_cast<int32_t>(group.transforms.size()), RenderingServer::MULTIMESH_TRANSFORM_3D);
		for (size_t i = 0; i < group.transforms.size(); ++i) {
			rs->multimesh_instance_set_transform(multimesh, static_cast<int32_t>(i), group.transforms[i]);
		}
		multimeshes_.push_back(multimesh);

		RID instance = rs->instance_create2(multimesh, scenario_);
		rs->instance_set_visible(instance, enabled_);
		// The LOD tier is always paired with a has_lod full-detail group
		// (see add_object()) -- always visible only beyond the crossover.
		rs->instance_geometry_set_visibility_range(instance, lod_crossover_distance_m_, 0.0f, lod_crossover_margin_m_, 0.0f, RenderingServer::VISIBILITY_RANGE_FADE_DISABLED);
		instances_.push_back(instance);
		lod_instance_count_++;
	}

	pending_mesh_groups_.clear();
	pending_lod_mesh_groups_.clear();
}

void DirectGeometryBatch::set_lod_crossover(float distance_m, float margin_m) {
	lod_crossover_distance_m_ = distance_m;
	lod_crossover_margin_m_ = margin_m;
}

void DirectGeometryBatch::set_enabled(bool enabled) {
	if (enabled_ == enabled) {
		return;
	}
	enabled_ = enabled;

	RenderingServer *rs = RenderingServer::get_singleton();
	for (const RID &instance : instances_) {
		rs->instance_set_visible(instance, enabled_);
	}

	PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
	for (const RID &body : bodies_) {
		ps->body_set_space(body, enabled_ ? space_ : RID());
	}
}

void DirectGeometryBatch::free_all() {
	if (!instances_.empty()) {
		RenderingServer *rs = RenderingServer::get_singleton();
		for (const RID &instance : instances_) {
			rs->free_rid(instance);
		}
		instances_.clear();
	}
	if (!multimeshes_.empty()) {
		RenderingServer *rs = RenderingServer::get_singleton();
		for (const RID &mm : multimeshes_) {
			rs->free_rid(mm);
		}
		multimeshes_.clear();
	}
	if (!bodies_.empty()) {
		PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
		for (const RID &body : bodies_) {
			ps->free_rid(body);
		}
		bodies_.clear();
	}
	pending_mesh_groups_.clear();
}

int DirectGeometryBatch::get_batched_placement_count() const {
	return placed_mesh_count_;
}
