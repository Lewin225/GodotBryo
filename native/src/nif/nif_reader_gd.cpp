#include "nif_reader_gd.h"

#include "gltf_export.h"
#include "nif_loader.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstring>
#include <stdexcept>

using namespace godot;

void NifReader::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load", "bytes"), &NifReader::load);
	ClassDB::bind_method(D_METHOD("get_last_error"), &NifReader::get_last_error);
	ClassDB::bind_method(D_METHOD("get_nif_version"), &NifReader::get_nif_version);
	ClassDB::bind_method(D_METHOD("get_submesh_count"), &NifReader::get_submesh_count);
	ClassDB::bind_method(D_METHOD("get_submesh_name", "index"), &NifReader::get_submesh_name);
	ClassDB::bind_method(D_METHOD("get_positions", "index"), &NifReader::get_positions);
	ClassDB::bind_method(D_METHOD("get_normals", "index"), &NifReader::get_normals);
	ClassDB::bind_method(D_METHOD("get_uvs", "index"), &NifReader::get_uvs);
	ClassDB::bind_method(D_METHOD("get_colors", "index"), &NifReader::get_colors);
	ClassDB::bind_method(D_METHOD("get_indices", "index"), &NifReader::get_indices);
	ClassDB::bind_method(D_METHOD("get_texture_path", "index"), &NifReader::get_texture_path);
	ClassDB::bind_method(D_METHOD("get_normal_texture_path", "index"), &NifReader::get_normal_texture_path);
	ClassDB::bind_method(D_METHOD("get_glow_texture_path", "index"), &NifReader::get_glow_texture_path);
	ClassDB::bind_method(D_METHOD("get_alpha_info", "index"), &NifReader::get_alpha_info);
	ClassDB::bind_method(D_METHOD("is_unlit", "index"), &NifReader::is_unlit);
	ClassDB::bind_method(D_METHOD("get_transform", "index"), &NifReader::get_transform);
	ClassDB::bind_method(D_METHOD("get_submesh_owning_node_index", "index"), &NifReader::get_submesh_owning_node_index);
	ClassDB::bind_method(D_METHOD("export_gltf", "path"), &NifReader::export_gltf);
	ClassDB::bind_method(D_METHOD("get_collision_shapes"), &NifReader::get_collision_shapes);
	ClassDB::bind_method(D_METHOD("has_collision_data"), &NifReader::has_collision_data);
	ClassDB::bind_method(D_METHOD("get_animation_sequences"), &NifReader::get_animation_sequences);
	ClassDB::bind_method(D_METHOD("get_scene_nodes"), &NifReader::get_scene_nodes);
}

bool NifReader::load(const PackedByteArray &bytes) {
	try {
		std::vector<uint8_t> buf(bytes.size());
		if (!buf.empty()) {
			std::memcpy(buf.data(), bytes.ptr(), buf.size());
		}
		mesh_ = nif::load_mesh(buf);
		loaded_ = true;
		last_error_ = "";
		return true;
	} catch (const std::exception &e) {
		loaded_ = false;
		last_error_ = String(e.what());
		return false;
	}
}

String NifReader::get_nif_version() const {
	return loaded_ ? String(mesh_.nif_version.c_str()) : String();
}

int NifReader::get_submesh_count() const {
	return loaded_ ? static_cast<int>(mesh_.submeshes.size()) : 0;
}

const nif::SubMesh *NifReader::submesh(int index) const {
	if (!loaded_ || index < 0 || static_cast<size_t>(index) >= mesh_.submeshes.size()) {
		return nullptr;
	}
	return &mesh_.submeshes[index];
}

String NifReader::get_submesh_name(int index) const {
	const nif::SubMesh *s = submesh(index);
	return s ? String(s->name.c_str()) : String();
}

PackedFloat32Array NifReader::get_positions(int index) const {
	PackedFloat32Array out;
	const nif::SubMesh *s = submesh(index);
	if (!s) {
		return out;
	}
	out.resize(static_cast<int>(s->positions.size()));
	for (size_t i = 0; i < s->positions.size(); ++i) {
		out[static_cast<int>(i)] = s->positions[i];
	}
	return out;
}

PackedFloat32Array NifReader::get_normals(int index) const {
	PackedFloat32Array out;
	const nif::SubMesh *s = submesh(index);
	if (!s) {
		return out;
	}
	out.resize(static_cast<int>(s->normals.size()));
	for (size_t i = 0; i < s->normals.size(); ++i) {
		out[static_cast<int>(i)] = s->normals[i];
	}
	return out;
}

PackedFloat32Array NifReader::get_uvs(int index) const {
	PackedFloat32Array out;
	const nif::SubMesh *s = submesh(index);
	if (!s) {
		return out;
	}
	out.resize(static_cast<int>(s->uvs.size()));
	for (size_t i = 0; i < s->uvs.size(); ++i) {
		out[static_cast<int>(i)] = s->uvs[i];
	}
	return out;
}

PackedColorArray NifReader::get_colors(int index) const {
	PackedColorArray out;
	const nif::SubMesh *s = submesh(index);
	if (!s) {
		return out;
	}
	size_t count = s->colors.size() / 4;
	out.resize(static_cast<int>(count));
	for (size_t i = 0; i < count; ++i) {
		out[static_cast<int>(i)] = Color(s->colors[i * 4], s->colors[i * 4 + 1], s->colors[i * 4 + 2], s->colors[i * 4 + 3]);
	}
	return out;
}

PackedInt32Array NifReader::get_indices(int index) const {
	PackedInt32Array out;
	const nif::SubMesh *s = submesh(index);
	if (!s) {
		return out;
	}
	out.resize(static_cast<int>(s->indices.size()));
	for (size_t i = 0; i < s->indices.size(); ++i) {
		out[static_cast<int>(i)] = static_cast<int32_t>(s->indices[i]);
	}
	return out;
}

String NifReader::get_texture_path(int index) const {
	const nif::SubMesh *s = submesh(index);
	return s ? String(s->texture_path.c_str()) : String();
}

String NifReader::get_normal_texture_path(int index) const {
	const nif::SubMesh *s = submesh(index);
	return s ? String(s->normal_texture_path.c_str()) : String();
}

String NifReader::get_glow_texture_path(int index) const {
	const nif::SubMesh *s = submesh(index);
	return s ? String(s->glow_texture_path.c_str()) : String();
}

Dictionary NifReader::get_alpha_info(int index) const {
	Dictionary out;
	const nif::SubMesh *s = submesh(index);
	out["has_alpha_property"] = s ? s->has_alpha_property : false;
	out["blend_enabled"] = s ? s->alpha_blend_enabled : false;
	out["test_enabled"] = s ? s->alpha_test_enabled : false;
	out["threshold"] = s ? s->alpha_threshold : 0.5f;
	out["blend_func"] = s ? static_cast<int>(s->alpha_blend_func) : 0;
	return out;
}

bool NifReader::is_unlit(int index) const {
	const nif::SubMesh *s = submesh(index);
	return s ? s->no_lighting : false;
}

Transform3D NifReader::get_transform(int index) const {
	const nif::SubMesh *s = submesh(index);
	if (!s) {
		return Transform3D();
	}
	const float *r = s->rotation;
	float scale = s->scale;
	Basis basis(
			r[0] * scale, r[1] * scale, r[2] * scale,
			r[3] * scale, r[4] * scale, r[5] * scale,
			r[6] * scale, r[7] * scale, r[8] * scale);
	Vector3 origin(s->translation[0], s->translation[1], s->translation[2]);
	return Transform3D(basis, origin);
}

int NifReader::get_submesh_owning_node_index(int index) const {
	const nif::SubMesh *s = submesh(index);
	return s ? s->owning_node_index : -1;
}

namespace {
const char *collision_kind_name(nif::CollisionShapeKind kind) {
	switch (kind) {
		case nif::CollisionShapeKind::kTriangleMesh:
			return "triangle_mesh";
		case nif::CollisionShapeKind::kBox:
			return "box";
		case nif::CollisionShapeKind::kSphere:
			return "sphere";
		case nif::CollisionShapeKind::kCapsule:
			return "capsule";
		case nif::CollisionShapeKind::kConvexHull:
			return "convex_hull";
		default:
			return "";
	}
}
// phases/3/00-door-completion.md, Part A: nif::FloatKey/Vector3Key/QuatKey
// -> Dictionary, one shared shape per Godot-side doc comment in
// nif_reader_gd.h. `interp` is passed straight through as nif::KeyInterpolation's
// own int value -- both sides agree on the enum order via that header
// comment, not a second translation table here.
Dictionary float_key_to_dict(const nif::FloatKey &k) {
	Dictionary d;
	d["time"] = k.time;
	d["value"] = k.value;
	d["forward"] = k.forward;
	d["backward"] = k.backward;
	d["tension"] = k.tension;
	d["bias"] = k.bias;
	d["continuity"] = k.continuity;
	d["interp"] = static_cast<int>(k.interp);
	return d;
}

Dictionary vec3_key_to_dict(const nif::Vector3Key &k) {
	Dictionary d;
	d["time"] = k.time;
	d["value"] = Vector3(k.value[0], k.value[1], k.value[2]);
	d["forward"] = Vector3(k.forward[0], k.forward[1], k.forward[2]);
	d["backward"] = Vector3(k.backward[0], k.backward[1], k.backward[2]);
	d["tension"] = k.tension;
	d["bias"] = k.bias;
	d["continuity"] = k.continuity;
	d["interp"] = static_cast<int>(k.interp);
	return d;
}

Dictionary quat_key_to_dict(const nif::QuatKey &k) {
	Dictionary d;
	d["time"] = k.time;
	d["value"] = Quaternion(k.value[0], k.value[1], k.value[2], k.value[3]);
	d["interp"] = static_cast<int>(k.interp);
	return d;
}

Array float_keys_to_array(const std::vector<nif::FloatKey> &keys) {
	Array out;
	for (const auto &k : keys) out.push_back(float_key_to_dict(k));
	return out;
}

} // namespace

Array NifReader::get_animation_sequences() const {
	Array out;
	if (!loaded_) {
		return out;
	}
	for (const nif::AnimationSequence &seq : mesh_.animation_sequences) {
		Dictionary sd;
		sd["name"] = String(seq.name.c_str());
		sd["cycle_type"] = static_cast<int>(seq.cycle_type);
		sd["start_time"] = seq.start_time;
		sd["stop_time"] = seq.stop_time;

		Array tracks;
		for (const nif::AnimationTrack &track : seq.tracks) {
			Dictionary td;
			td["target_node_name"] = String(track.target_node_name.c_str());
			td["has_quaternion_keys"] = track.has_quaternion_keys;
			Array quat_keys;
			for (const auto &k : track.quaternion_keys) quat_keys.push_back(quat_key_to_dict(k));
			td["quaternion_keys"] = quat_keys;
			td["has_axis_keys"] = track.has_axis_keys;
			td["x_rotation_keys"] = float_keys_to_array(track.x_rotation_keys);
			td["y_rotation_keys"] = float_keys_to_array(track.y_rotation_keys);
			td["z_rotation_keys"] = float_keys_to_array(track.z_rotation_keys);
			Array translation_keys;
			for (const auto &k : track.translation_keys) translation_keys.push_back(vec3_key_to_dict(k));
			td["translation_keys"] = translation_keys;
			td["scale_keys"] = float_keys_to_array(track.scale_keys);
			tracks.push_back(td);
		}
		sd["tracks"] = tracks;
		out.push_back(sd);
	}
	return out;
}

Array NifReader::get_scene_nodes() const {
	Array out;
	if (!loaded_) {
		return out;
	}
	for (const nif::SceneNode &node : mesh_.scene_nodes) {
		Dictionary d;
		d["name"] = String(node.name.c_str());
		d["parent_index"] = node.parent_index;
		const float *r = node.rotation;
		float scale = node.scale;
		Basis basis(
				r[0] * scale, r[1] * scale, r[2] * scale,
				r[3] * scale, r[4] * scale, r[5] * scale,
				r[6] * scale, r[7] * scale, r[8] * scale);
		Vector3 origin(node.translation[0], node.translation[1], node.translation[2]);
		d["transform"] = Transform3D(basis, origin);
		out.push_back(d);
	}
	return out;
}

Array NifReader::get_collision_shapes() const {
	Array out;
	if (!loaded_) {
		return out;
	}
	for (const nif::CollisionShape &cs : mesh_.collision_shapes) {
		Dictionary d;
		d["kind"] = String(collision_kind_name(cs.kind));
		d["name"] = String(cs.node_name.c_str());
		d["owning_node_index"] = cs.owning_node_index;

		const float *r = cs.rotation;
		Basis basis(r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8]);
		Vector3 origin(cs.translation[0], cs.translation[1], cs.translation[2]);
		d["transform"] = Transform3D(basis, origin);

		switch (cs.kind) {
			case nif::CollisionShapeKind::kTriangleMesh:
			case nif::CollisionShapeKind::kConvexHull: {
				PackedFloat32Array positions;
				positions.resize(static_cast<int>(cs.positions.size()));
				for (size_t i = 0; i < cs.positions.size(); ++i) {
					positions[static_cast<int>(i)] = cs.positions[i];
				}
				d["positions"] = positions;
				if (cs.kind == nif::CollisionShapeKind::kTriangleMesh) {
					PackedInt32Array indices;
					indices.resize(static_cast<int>(cs.indices.size()));
					for (size_t i = 0; i < cs.indices.size(); ++i) {
						indices[static_cast<int>(i)] = static_cast<int32_t>(cs.indices[i]);
					}
					d["indices"] = indices;
				}
				break;
			}
			case nif::CollisionShapeKind::kBox:
				d["half_extents"] = Vector3(cs.half_extents[0], cs.half_extents[1], cs.half_extents[2]);
				break;
			case nif::CollisionShapeKind::kSphere:
				d["radius"] = cs.radius;
				break;
			case nif::CollisionShapeKind::kCapsule:
				d["point_a"] = Vector3(cs.point_a[0], cs.point_a[1], cs.point_a[2]);
				d["point_b"] = Vector3(cs.point_b[0], cs.point_b[1], cs.point_b[2]);
				d["capsule_radius"] = cs.capsule_radius;
				break;
			default:
				break;
		}
		out.push_back(d);
	}
	return out;
}

bool NifReader::export_gltf(const String &path) const {
	if (!loaded_) {
		return false;
	}
	try {
		nif::export_gltf(mesh_, path.utf8().get_data());
		return true;
	} catch (const std::exception &) {
		return false;
	}
}
