#include "nif_source_gd.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include <cstring>

using namespace godot;

void NifSource::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load", "bytes"), &NifSource::load);
	ClassDB::bind_method(D_METHOD("get_last_error"), &NifSource::get_last_error);
	ClassDB::bind_method(D_METHOD("get_version"), &NifSource::get_version);
	ClassDB::bind_method(D_METHOD("get_block_count"), &NifSource::get_block_count);
	ClassDB::bind_method(D_METHOD("has_bone_hierarchy"), &NifSource::has_bone_hierarchy);
	ClassDB::bind_method(D_METHOD("get_nodes"), &NifSource::get_nodes);
	ClassDB::bind_method(D_METHOD("get_object_palettes"), &NifSource::get_object_palettes);
	ClassDB::bind_method(D_METHOD("get_sequences"), &NifSource::get_sequences);
	ClassDB::bind_method(D_METHOD("get_collision_shapes"), &NifSource::get_collision_shapes);
	ClassDB::bind_method(D_METHOD("get_collision_bodies"), &NifSource::get_collision_bodies);
}

bool NifSource::load(const PackedByteArray &bytes) {
	try {
		// Parsed in place out of the PackedByteArray: no copy of the payload.
		doc_ = nifsrc::load(bytes.ptr(), static_cast<size_t>(bytes.size()));
		loaded_ = true;
		last_error_ = String();
	} catch (const std::exception &e) {
		loaded_ = false;
		last_error_ = String(e.what());
	}
	return loaded_;
}

String NifSource::get_version() const {
	return loaded_ ? String(doc_.version.c_str()) : String();
}

int NifSource::get_block_count() const {
	return loaded_ ? static_cast<int>(doc_.block_count) : 0;
}

bool NifSource::has_bone_hierarchy() const {
	return loaded_ && doc_.has_bone_hierarchy;
}

Array NifSource::get_nodes() const {
	Array out;
	if (!loaded_) {
		return out;
	}
	for (const auto &n : doc_.nodes) {
		Dictionary d;
		d["name"] = String(n.name.c_str());
		d["block_type"] = String(n.block_type.c_str());
		d["parent_index"] = n.parent_index;
		d["block_index"] = static_cast<int>(n.block_index);
		d["is_declared_bone"] = n.is_declared_bone;
		d["collision_type"] = String(n.collision_type.c_str());
		d["collision_block_index"] = n.collision_block_index;
		d["collision_target_block_index"] = n.collision_target_block_index;
		PackedStringArray slots;
		for (const auto &t : n.texture_slots) {
			slots.push_back(String(t.c_str()));
		}
		d["texture_slots"] = slots;
		d["texture_set_block_index"] = n.texture_set_block_index;
		d["shader_type"] = String(n.shader_type.c_str());
		d["texture_convention"] = String(n.texture_convention.c_str());
		d["has_alpha_property"] = n.has_alpha_property;
		if (n.has_alpha_property) {
			d["alpha_blend_enabled"] = n.alpha_blend_enabled;
			d["alpha_test_enabled"] = n.alpha_test_enabled;
			d["alpha_threshold"] = n.alpha_threshold;
			d["alpha_blend_func"] = String(n.alpha_blend_func.c_str());
		}
		PackedInt32Array prop_blocks;
		for (int32_t idx : n.property_block_indices) {
			prop_blocks.push_back(idx);
		}
		d["property_block_indices"] = prop_blocks;
		PackedStringArray prop_types;
		for (const auto &t : n.property_types) {
			prop_types.push_back(String(t.c_str()));
		}
		d["property_types"] = prop_types;
		Array extras;
		for (const auto &ed : n.extra_data) {
			Dictionary x;
			x["block_index"] = static_cast<int>(ed.block_index);
			x["block_type"] = String(ed.block_type.c_str());
			x["name"] = String(ed.name.c_str());
			if (ed.has_integer) {
				x["integer"] = ed.integer_value;
			}
			if (ed.has_float) {
				x["float"] = ed.float_value;
			}
			if (ed.has_string) {
				x["string"] = String(ed.string_value.c_str());
			}
			if (ed.has_bounds) {
				x["bounds_center"] = Vector3(ed.bounds_center[0], ed.bounds_center[1], ed.bounds_center[2]);
				x["bounds_half_extents"] = Vector3(ed.bounds_half_extents[0], ed.bounds_half_extents[1], ed.bounds_half_extents[2]);
			}
			if (!ed.text_keys.empty()) {
				Array keys;
				for (const auto &tk : ed.text_keys) {
					Dictionary k;
					k["time"] = tk.time;
					k["value"] = String(tk.value.c_str());
					keys.push_back(k);
				}
				x["text_keys"] = keys;
			}
			extras.push_back(x);
		}
		d["extra_data"] = extras;

		const auto &geo = n.geometry;
		if (!geo.positions.empty()) {
			PackedVector3Array positions;
			for (size_t v = 0; v + 2 < geo.positions.size(); v += 3) {
				positions.push_back(Vector3(geo.positions[v], geo.positions[v + 1], geo.positions[v + 2]));
			}
			d["positions"] = positions;

			PackedVector3Array normals;
			for (size_t v = 0; v + 2 < geo.normals.size(); v += 3) {
				normals.push_back(Vector3(geo.normals[v], geo.normals[v + 1], geo.normals[v + 2]));
			}
			d["normals"] = normals;

			PackedVector2Array uvs;
			for (size_t v = 0; v + 1 < geo.uvs.size(); v += 2) {
				uvs.push_back(Vector2(geo.uvs[v], geo.uvs[v + 1]));
			}
			d["uvs"] = uvs;

			PackedColorArray colors;
			for (size_t v = 0; v + 3 < geo.colors.size(); v += 4) {
				colors.push_back(Color(geo.colors[v], geo.colors[v + 1], geo.colors[v + 2], geo.colors[v + 3]));
			}
			d["colors"] = colors;

			PackedInt32Array indices;
			for (uint32_t idx : geo.indices) {
				indices.push_back(static_cast<int32_t>(idx));
			}
			d["indices"] = indices;

			if (geo.has_skin) {
				Dictionary skin;
				PackedStringArray bone_names;
				for (const auto &b : geo.skin.bone_names) {
					bone_names.push_back(String(b.c_str()));
				}
				skin["bone_names"] = bone_names;

				// One bind pose per bone, row-major float[16] -> Transform3D.
				Array binds;
				for (size_t b = 0; b + 15 < geo.skin.bind_transforms.size(); b += 16) {
					const float *m = &geo.skin.bind_transforms[b];
					Basis basis(
							Vector3(m[0], m[4], m[8]),
							Vector3(m[1], m[5], m[9]),
							Vector3(m[2], m[6], m[10]));
					binds.push_back(Transform3D(basis, Vector3(m[3], m[7], m[11])));
				}
				skin["bind_transforms"] = binds;

				PackedInt32Array bone_indices;
				for (int32_t b : geo.skin.bone_indices) {
					bone_indices.push_back(b);
				}
				skin["bone_indices"] = bone_indices;

				PackedFloat32Array bone_weights;
				for (float w : geo.skin.bone_weights) {
					bone_weights.push_back(w);
				}
				skin["bone_weights"] = bone_weights;

				d["skin"] = skin;
			}
		}

		if (!n.morphs.empty()) {
			Array morphs;
			for (const auto &frame : n.morphs) {
				Dictionary m;
				m["name"] = String(frame.name.c_str());
				PackedVector3Array deltas;
				for (size_t v = 0; v + 2 < frame.deltas.size(); v += 3) {
					deltas.push_back(Vector3(frame.deltas[v], frame.deltas[v + 1], frame.deltas[v + 2]));
				}
				m["deltas"] = deltas;
				morphs.push_back(m);
			}
			d["morphs"] = morphs;
		}
		Basis basis(
				Vector3(n.rotation[0], n.rotation[3], n.rotation[6]),
				Vector3(n.rotation[1], n.rotation[4], n.rotation[7]),
				Vector3(n.rotation[2], n.rotation[5], n.rotation[8]));
		basis = basis.scaled(Vector3(n.scale, n.scale, n.scale));
		d["transform"] = Transform3D(basis,
				Vector3(n.translation[0], n.translation[1], n.translation[2]));
		out.push_back(d);
	}
	return out;
}

Array NifSource::get_object_palettes() const {
	Array out;
	if (!loaded_) {
		return out;
	}
	for (const auto &palette : doc_.palettes) {
		Dictionary d;
		d["block_index"] = static_cast<int>(palette.block_index);
		Array entries;
		for (const auto &entry : palette.entries) {
			Dictionary e;
			e["name"] = String(entry.name.c_str());
			e["object_block_index"] = entry.object_block_index;
			entries.push_back(e);
		}
		d["entries"] = entries;
		out.push_back(d);
	}
	return out;
}

namespace {

Array vec3_keys(const std::vector<nifsrc::Vec3Key> &keys) {
	Array out;
	for (const auto &k : keys) {
		Dictionary d;
		d["time"] = k.time;
		d["value"] = Vector3(k.value[0], k.value[1], k.value[2]);
		d["interp"] = String(k.interp.c_str());
		out.push_back(d);
	}
	return out;
}

Array quat_keys(const std::vector<nifsrc::QuatKey> &keys) {
	Array out;
	for (const auto &k : keys) {
		Dictionary d;
		d["time"] = k.time;
		d["value"] = Quaternion(k.value[0], k.value[1], k.value[2], k.value[3]);
		d["interp"] = String(k.interp.c_str());
		out.push_back(d);
	}
	return out;
}

Array scalar_keys(const std::vector<nifsrc::ScalarKey> &keys) {
	Array out;
	for (const auto &k : keys) {
		Dictionary d;
		d["time"] = k.time;
		d["value"] = k.value;
		d["interp"] = String(k.interp.c_str());
		out.push_back(d);
	}
	return out;
}

// Always returned, even when absent: a consumer reads "present" rather than
// having to probe for a missing key.
Dictionary interpolator_dict(const nifsrc::Interpolator &ip) {
	Dictionary d;
	d["present"] = ip.present;
	d["block_index"] = static_cast<int>(ip.block_index);
	d["block_type"] = String(ip.block_type.c_str());
	d["kind"] = String(ip.kind.c_str());
	d["resampled"] = ip.resampled;
	d["rotation_from_euler"] = ip.rotation_from_euler;
	d["has_static_transform"] = ip.has_static_transform;
	d["translation"] = Vector3(ip.translation[0], ip.translation[1], ip.translation[2]);
	d["rotation"] = Quaternion(ip.rotation[0], ip.rotation[1], ip.rotation[2], ip.rotation[3]);
	d["scale"] = ip.scale;
	d["has_static_float"] = ip.has_static_float;
	d["static_float"] = ip.static_float;
	d["translation_keys"] = vec3_keys(ip.translation_keys);
	d["rotation_keys"] = quat_keys(ip.rotation_keys);
	d["scale_keys"] = scalar_keys(ip.scale_keys);
	d["float_keys"] = scalar_keys(ip.float_keys);
	d["point3_keys"] = vec3_keys(ip.point3_keys);
	return d;
}

} // namespace

Array NifSource::get_sequences() const {
	Array out;
	if (!loaded_) {
		return out;
	}
	for (const auto &seq : doc_.sequences) {
		Dictionary d;
		d["block_index"] = static_cast<int>(seq.block_index);
		d["name"] = String(seq.name.c_str());
		d["accum_root_name"] = String(seq.accum_root_name.c_str());
		d["cycle_type"] = static_cast<int>(seq.cycle_type);
		d["start_time"] = seq.start_time;
		d["stop_time"] = seq.stop_time;
		Array blocks;
		for (const auto &cb : seq.controlled_blocks) {
			Dictionary b;
			b["node_name"] = String(cb.node_name.c_str());
			b["property_type"] = String(cb.property_type.c_str());
			b["controller_type"] = String(cb.controller_type.c_str());
			b["controller_id"] = String(cb.controller_id.c_str());
			b["interpolator_id"] = String(cb.interpolator_id.c_str());
			b["from_string_palette"] = cb.from_string_palette;
			b["interpolator"] = interpolator_dict(cb.interpolator);
			blocks.push_back(b);
		}
		d["controlled_blocks"] = blocks;
		Array text_keys;
		for (const auto &tk : seq.text_keys) {
			Dictionary k;
			k["time"] = tk.time;
			k["value"] = String(tk.value.c_str());
			text_keys.push_back(k);
		}
		d["text_keys"] = text_keys;
		out.push_back(d);
	}
	return out;
}

Array NifSource::get_collision_shapes() const {
	Array out;
	if (!loaded_) {
		return out;
	}
	for (const auto &cs : doc_.collision_shapes) {
		Dictionary d;
		d["block_index"] = static_cast<int>(cs.block_index);
		d["block_type"] = String(cs.block_type.c_str());
		d["owning_node_index"] = cs.owning_node_index;
		d["body_index"] = cs.body_index;
		d["kind"] = String(cs.kind.c_str());
		d["half_extents"] = Vector3(cs.half_extents[0], cs.half_extents[1], cs.half_extents[2]);
		d["radius"] = cs.radius;
		d["point_a"] = Vector3(cs.point_a[0], cs.point_a[1], cs.point_a[2]);
		d["point_b"] = Vector3(cs.point_b[0], cs.point_b[1], cs.point_b[2]);
		d["capsule_radius"] = cs.capsule_radius;
		PackedVector3Array positions;
		for (size_t v = 0; v + 2 < cs.positions.size(); v += 3) {
			positions.push_back(Vector3(cs.positions[v], cs.positions[v + 1], cs.positions[v + 2]));
		}
		d["positions"] = positions;
		PackedInt32Array indices;
		for (uint32_t i : cs.indices) {
			indices.push_back(static_cast<int32_t>(i));
		}
		d["indices"] = indices;
		d["has_transform"] = cs.has_transform;
		// Row-major, translation already in meters.
		d["transform"] = Transform3D(
				Basis(cs.transform[0], cs.transform[1], cs.transform[2],
						cs.transform[4], cs.transform[5], cs.transform[6],
						cs.transform[8], cs.transform[9], cs.transform[10]),
				Vector3(cs.transform[3], cs.transform[7], cs.transform[11]));
		out.push_back(d);
	}
	return out;
}

Array NifSource::get_collision_bodies() const {
	Array out;
	if (!loaded_) {
		return out;
	}
	for (const auto &cb : doc_.collision_bodies) {
		Dictionary d;
		d["block_index"] = static_cast<int>(cb.block_index);
		d["block_type"] = String(cb.block_type.c_str());
		d["owning_node_index"] = cb.owning_node_index;
		d["mass"] = cb.mass;
		d["friction"] = cb.friction;
		d["restitution"] = cb.restitution;
		d["linear_damping"] = cb.linear_damping;
		d["angular_damping"] = cb.angular_damping;
		d["translation"] = Vector3(cb.translation[0], cb.translation[1], cb.translation[2]);
		d["rotation"] = Quaternion(cb.rotation[0], cb.rotation[1], cb.rotation[2], cb.rotation[3]);
		out.push_back(d);
	}
	return out;
}
