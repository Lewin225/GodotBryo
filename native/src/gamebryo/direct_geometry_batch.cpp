#include "direct_geometry_batch.h"

#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>

using namespace godot;

void DirectGeometryBatch::_bind_methods() {
	ClassDB::bind_method(D_METHOD("init", "world_node"), &DirectGeometryBatch::init);
	ClassDB::bind_method(D_METHOD("add_object", "world_transform", "mesh_entries", "shape_entries"), &DirectGeometryBatch::add_object);
	ClassDB::bind_method(D_METHOD("set_enabled", "enabled"), &DirectGeometryBatch::set_enabled);
	ClassDB::bind_method(D_METHOD("free_all"), &DirectGeometryBatch::free_all);
	ClassDB::bind_method(D_METHOD("get_instance_count"), &DirectGeometryBatch::get_instance_count);
	ClassDB::bind_method(D_METHOD("get_body_count"), &DirectGeometryBatch::get_body_count);
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

void DirectGeometryBatch::add_object(const Transform3D &world_transform, const Array &mesh_entries, const Array &shape_entries) {
	if (!initialized_) {
		return; // init() wasn't called -- nothing to attach these to
	}

	RenderingServer *rs = RenderingServer::get_singleton();
	for (int i = 0; i < mesh_entries.size(); ++i) {
		Dictionary entry = mesh_entries[i];
		Ref<Mesh> mesh = entry.get("mesh", Variant());
		if (mesh.is_null()) {
			continue;
		}
		Transform3D local = entry.get("transform", Transform3D());
		RID instance = rs->instance_create2(mesh->get_rid(), scenario_);
		rs->instance_set_transform(instance, world_transform * local);
		rs->instance_set_visible(instance, enabled_);
		instances_.push_back(instance);
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
	if (!bodies_.empty()) {
		PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
		for (const RID &body : bodies_) {
			ps->free_rid(body);
		}
		bodies_.clear();
	}
}
