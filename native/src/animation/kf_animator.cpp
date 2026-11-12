#include "animation/kf_animator.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

namespace {

// The bones that carry root motion; their tracks play only with keep_root.
const char *const ROOT_BONE = "Bip01";
const char *const NON_ACCUM_BONE = "Bip01 NonAccum";
// Per-bone channels, in the order samples are stored.
constexpr int CHANNEL_POSITION = 0;
constexpr int CHANNEL_ROTATION = 1;
constexpr int CHANNEL_SCALE = 2;
constexpr int CHANNEL_COUNT = 3;
// A Node3D target's visibility, after its transform channels.
constexpr int CHANNEL_VISIBLE = 3;
constexpr int NODE_CHANNEL_COUNT = 4;
// A visibility track's path is its target's name with this property
// (NifServer's NifAnimationBuilder.VISIBILITY_SUFFIX).
const char *const VISIBILITY_SUFFIX = ":visible";
// Below this, a weight counts as nothing.
constexpr float WEIGHT_EPSILON = 0.0001f;

// NonAccum's facing in the KFs: its X axis along Bip01's +Y, yaw 90 degrees
// (the standing stance of 342 Special Idles; kf_root_census).
constexpr float STANCE_YAW = 1.5707963f;

// Rotation about Z of `q`'s X axis, radians.
float yaw_about_z(const Quaternion &q) {
	const Vector3 axis = q.xform(Vector3(1.0f, 0.0f, 0.0f));
	return std::atan2(axis.y, axis.x);
}

int channel_of(Animation::TrackType p_type) {
	if (p_type == Animation::TYPE_POSITION_3D) {
		return CHANNEL_POSITION;
	}
	if (p_type == Animation::TYPE_ROTATION_3D) {
		return CHANNEL_ROTATION;
	}
	return CHANNEL_SCALE;
}

} // namespace

void KfAnimator::_bind_methods() {
	// Properties.
	ClassDB::bind_method(D_METHOD("set_skeleton_path", "path"), &KfAnimator::set_skeleton_path);
	ClassDB::bind_method(D_METHOD("get_skeleton_path"), &KfAnimator::get_skeleton_path);
	ClassDB::bind_method(D_METHOD("set_node_root", "path"), &KfAnimator::set_node_root);
	ClassDB::bind_method(D_METHOD("get_node_root"), &KfAnimator::get_node_root);
	ClassDB::bind_method(D_METHOD("set_update_interval", "frames"), &KfAnimator::set_update_interval);
	ClassDB::bind_method(D_METHOD("get_update_interval"), &KfAnimator::get_update_interval);
	ClassDB::bind_method(D_METHOD("set_paused", "paused"), &KfAnimator::set_paused);
	ClassDB::bind_method(D_METHOD("is_paused"), &KfAnimator::is_paused);
	ClassDB::bind_method(D_METHOD("set_tie_mode", "mode"), &KfAnimator::set_tie_mode);
	ClassDB::bind_method(D_METHOD("get_tie_mode"), &KfAnimator::get_tie_mode);
	ClassDB::bind_method(D_METHOD("set_disabled_bones", "bones"), &KfAnimator::set_disabled_bones);
	ClassDB::bind_method(D_METHOD("get_disabled_bones"), &KfAnimator::get_disabled_bones);
	ClassDB::bind_method(D_METHOD("set_root_motion_mode", "mode"), &KfAnimator::set_root_motion_mode);
	ClassDB::bind_method(D_METHOD("get_root_motion_mode"), &KfAnimator::get_root_motion_mode);
	ClassDB::bind_method(D_METHOD("set_root_motion_excluded_slot", "slot"), &KfAnimator::set_root_motion_excluded_slot);
	ClassDB::bind_method(D_METHOD("get_root_motion_excluded_slot"), &KfAnimator::get_root_motion_excluded_slot);
	ClassDB::bind_method(D_METHOD("set_hold_unkeyed_root", "hold"), &KfAnimator::set_hold_unkeyed_root);
	ClassDB::bind_method(D_METHOD("is_holding_unkeyed_root"), &KfAnimator::is_holding_unkeyed_root);
	ClassDB::bind_method(D_METHOD("set_sync_source", "path"), &KfAnimator::set_sync_source);
	ClassDB::bind_method(D_METHOD("get_sync_source"), &KfAnimator::get_sync_source);
	ClassDB::bind_method(D_METHOD("set_slot_sync_sources", "sources"), &KfAnimator::set_slot_sync_sources);
	ClassDB::bind_method(D_METHOD("get_slot_sync_sources"), &KfAnimator::get_slot_sync_sources);

	// Playing.
	ClassDB::bind_method(D_METHOD("play", "slot", "animation", "fade_seconds", "keep_root", "speed", "path", "source_serial"),
			&KfAnimator::play, DEFVAL(0.2f), DEFVAL(false), DEFVAL(1.0f), DEFVAL(String()), DEFVAL(0));
	ClassDB::bind_method(D_METHOD("announce", "slot", "path", "animation", "fade_seconds", "keep_root", "speed"),
			&KfAnimator::announce, DEFVAL(Ref<Animation>()), DEFVAL(0.2f), DEFVAL(false), DEFVAL(1.0f));
	ClassDB::bind_method(D_METHOD("stop", "slot", "fade_seconds"), &KfAnimator::stop, DEFVAL(0.2f));
	ClassDB::bind_method(D_METHOD("stop_all"), &KfAnimator::stop_all);
	ClassDB::bind_method(D_METHOD("seek", "slot", "time"), &KfAnimator::seek);
	ClassDB::bind_method(D_METHOD("set_loop_section", "slot", "start", "end", "count"), &KfAnimator::set_loop_section,
			DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("update_pose"), &KfAnimator::update_pose);

	// State.
	ClassDB::bind_method(D_METHOD("get_animation", "slot"), &KfAnimator::get_animation);
	ClassDB::bind_method(D_METHOD("get_time", "slot"), &KfAnimator::get_time);
	ClassDB::bind_method(D_METHOD("get_slots"), &KfAnimator::get_slots);
	ClassDB::bind_method(D_METHOD("get_start", "slot"), &KfAnimator::get_start);
	ClassDB::bind_method(D_METHOD("get_started_slots"), &KfAnimator::get_started_slots);
	ClassDB::bind_method(D_METHOD("get_root_motion"), &KfAnimator::get_root_motion);
	ClassDB::bind_method(D_METHOD("get_root_clip_serial"), &KfAnimator::get_root_clip_serial);
	ClassDB::bind_method(D_METHOD("get_root_clip_slot"), &KfAnimator::get_root_clip_slot);
	ClassDB::bind_method(D_METHOD("consume_root_motion"), &KfAnimator::consume_root_motion);

	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "skeleton_path", PROPERTY_HINT_NODE_PATH_VALID_TYPES, "Skeleton3D"),
			"set_skeleton_path", "get_skeleton_path");
	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "node_root", PROPERTY_HINT_NODE_PATH_VALID_TYPES, "Node3D"),
			"set_node_root", "get_node_root");
	ADD_GROUP("Playback", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "update_interval", PROPERTY_HINT_RANGE, "1,120,1,suffix:frames"),
			"set_update_interval", "get_update_interval");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "paused"), "set_paused", "is_paused");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "tie_mode", PROPERTY_HINT_ENUM, "Blend,Newest"),
			"set_tie_mode", "get_tie_mode");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "disabled_bones"), "set_disabled_bones",
			"get_disabled_bones");
	ADD_GROUP("Root Motion", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "root_motion_mode", PROPERTY_HINT_ENUM,
						 "None,Bip01,Bip01 + NonAccum Yaw,NonAccum,Root Transform"),
			"set_root_motion_mode", "get_root_motion_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "root_motion_excluded_slot"), "set_root_motion_excluded_slot",
			"get_root_motion_excluded_slot");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "hold_unkeyed_root"), "set_hold_unkeyed_root", "is_holding_unkeyed_root");
	ADD_GROUP("Sync", "");
	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "sync_source", PROPERTY_HINT_NODE_PATH_VALID_TYPES, "KfAnimator"),
			"set_sync_source", "get_sync_source");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "slot_sync_sources", PROPERTY_HINT_DICTIONARY_TYPE, "int;NodePath"),
			"set_slot_sync_sources", "get_slot_sync_sources");

	BIND_ENUM_CONSTANT(TIE_BLEND);
	BIND_ENUM_CONSTANT(TIE_NEWEST);
	BIND_ENUM_CONSTANT(ROOT_MOTION_NONE);
	BIND_ENUM_CONSTANT(ROOT_MOTION_BIP01);
	BIND_ENUM_CONSTANT(ROOT_MOTION_BIP01_NONACCUM_YAW);
	BIND_ENUM_CONSTANT(ROOT_MOTION_NONACCUM);
	BIND_ENUM_CONSTANT(ROOT_MOTION_ROOT_TRANSFORM);

	ADD_SIGNAL(MethodInfo("clip_started", PropertyInfo(Variant::INT, "slot"), PropertyInfo(Variant::STRING, "path"),
			PropertyInfo(Variant::OBJECT, "animation", PROPERTY_HINT_RESOURCE_TYPE, "Animation"),
			PropertyInfo(Variant::INT, "serial"), PropertyInfo(Variant::FLOAT, "fade_seconds"),
			PropertyInfo(Variant::BOOL, "keep_root"), PropertyInfo(Variant::FLOAT, "speed")));
	ADD_SIGNAL(MethodInfo("clip_stopped", PropertyInfo(Variant::INT, "slot"), PropertyInfo(Variant::FLOAT, "fade_seconds")));
	ADD_SIGNAL(MethodInfo("clip_finished", PropertyInfo(Variant::INT, "slot"),
			PropertyInfo(Variant::OBJECT, "animation", PROPERTY_HINT_RESOURCE_TYPE, "Animation")));
	ADD_SIGNAL(MethodInfo("text_key", PropertyInfo(Variant::INT, "slot"), PropertyInfo(Variant::STRING, "key"),
			PropertyInfo(Variant::FLOAT, "time")));
}

void KfAnimator::_notification(int p_what) {
	if (p_what == NOTIFICATION_READY) {
		set_process(true);
		return;
	}
	if (p_what != NOTIFICATION_PROCESS) {
		return;
	}
	if (!_paused) {
		_advance(static_cast<float>(get_process_delta_time()));
	}
	_frame++;
	if (_frame % static_cast<uint64_t>(_update_interval) == 0) {
		_write_pose();
	}
}

void KfAnimator::set_skeleton_path(const NodePath &p_path) {
	_skeleton_path = p_path;
}

NodePath KfAnimator::get_skeleton_path() const {
	return _skeleton_path;
}

void KfAnimator::set_node_root(const NodePath &p_path) {
	_node_root_path = p_path;
}

NodePath KfAnimator::get_node_root() const {
	return _node_root_path;
}

void KfAnimator::set_sync_source(const NodePath &p_path) {
	_sync_source_path = p_path;
}

NodePath KfAnimator::get_sync_source() const {
	return _sync_source_path;
}

void KfAnimator::set_slot_sync_sources(const Dictionary &p_sources) {
	_slot_sync_sources = p_sources;
}

Dictionary KfAnimator::get_slot_sync_sources() const {
	return _slot_sync_sources;
}

void KfAnimator::set_update_interval(int p_frames) {
	_update_interval = std::max(1, p_frames);
}

int KfAnimator::get_update_interval() const {
	return _update_interval;
}

void KfAnimator::set_paused(bool p_paused) {
	_paused = p_paused;
}

bool KfAnimator::is_paused() const {
	return _paused;
}

void KfAnimator::set_tie_mode(int p_mode) {
	_tie_mode = p_mode == TIE_NEWEST ? TIE_NEWEST : TIE_BLEND;
}

int KfAnimator::get_tie_mode() const {
	return _tie_mode;
}

void KfAnimator::set_root_motion_mode(int p_mode) {
	_root_motion_mode = std::clamp(p_mode, static_cast<int>(ROOT_MOTION_NONE), static_cast<int>(ROOT_MOTION_ROOT_TRANSFORM));
}

int KfAnimator::get_root_motion_mode() const {
	return _root_motion_mode;
}

void KfAnimator::set_disabled_bones(const PackedStringArray &p_bones) {
	_disabled_bones = p_bones;
}

PackedStringArray KfAnimator::get_disabled_bones() const {
	return _disabled_bones;
}

void KfAnimator::set_hold_unkeyed_root(bool p_hold) {
	_hold_unkeyed_root = p_hold;
}

bool KfAnimator::is_holding_unkeyed_root() const {
	return _hold_unkeyed_root;
}

Transform3D KfAnimator::get_root_motion() const {
	return _root_motion;
}

int64_t KfAnimator::get_root_clip_serial() const {
	return static_cast<int64_t>(_root_serial);
}

Transform3D KfAnimator::consume_root_motion() {
	const Transform3D motion = _pending_root_motion;
	_pending_root_motion = Transform3D();
	return motion;
}

void KfAnimator::set_root_motion_excluded_slot(int p_slot) {
	_root_motion_excluded_slot = p_slot;
}

int KfAnimator::get_root_motion_excluded_slot() const {
	return _root_motion_excluded_slot;
}

int KfAnimator::get_root_clip_slot() const {
	const Clip *clip = _root_clip();
	if (clip == nullptr) {
		return -1;
	}
	for (const auto &entry : _slots) {
		if (entry.second.has_current && &entry.second.current == clip) {
			return entry.first;
		}
	}
	return -1;
}

Skeleton3D *KfAnimator::_skeleton() const {
	if (_skeleton_path.is_empty()) {
		return nullptr;
	}
	return Object::cast_to<Skeleton3D>(get_node_or_null(_skeleton_path));
}

// The node targets' root: node_root, used only when there is no skeleton.
Node3D *KfAnimator::_node_root() const {
	if (_skeleton() != nullptr || _node_root_path.is_empty()) {
		return nullptr;
	}
	return Object::cast_to<Node3D>(get_node_or_null(_node_root_path));
}

// The KfAnimator `slot`'s following clips follow: its slot_sync_sources entry,
// else sync_source; null for none or this animator.
KfAnimator *KfAnimator::_source(int p_slot) const {
	NodePath path = _sync_source_path;
	if (_slot_sync_sources.has(p_slot)) {
		path = _slot_sync_sources[p_slot];
	}
	if (path.is_empty()) {
		return nullptr;
	}
	KfAnimator *source = Object::cast_to<KfAnimator>(get_node_or_null(path));
	return source == this ? nullptr : source;
}

// The clip of `serial` in `slot`, current or fading out; null when there is
// none.
const KfAnimator::Clip *KfAnimator::_source_clip(int p_slot, uint64_t p_serial) const {
	auto found = _slots.find(p_slot);
	if (found == _slots.end()) {
		return nullptr;
	}
	const Slot &slot = found->second;
	if (slot.has_current && slot.current.serial == p_serial) {
		return &slot.current;
	}
	for (const Clip &clip : slot.fading) {
		if (clip.serial == p_serial) {
			return &clip;
		}
	}
	return nullptr;
}

// Sets a following clip's time, loop section and end from its source clip.
// False when the clip follows none or the source no longer has it.
bool KfAnimator::_follow_source(int p_slot, Clip &r_clip) const {
	if (r_clip.source_serial == 0) {
		return false;
	}
	const KfAnimator *source = _source(p_slot);
	if (source == nullptr) {
		return false;
	}
	const Clip *followed = source->_source_clip(p_slot, r_clip.source_serial);
	if (followed == nullptr) {
		return false;
	}
	r_clip.time = std::min(followed->time, r_clip.length);
	r_clip.loop_start = followed->loop_start;
	r_clip.loop_end = followed->loop_end;
	r_clip.loops_left = followed->loops_left;
	r_clip.finished = followed->finished;
	return true;
}

// Ends the slot's current clip: it fades out over `fade_seconds` (it is
// dropped at once for 0) and the slot has no current clip.
void KfAnimator::_end_current(Slot &r_slot, float p_fade_seconds) {
	if (r_slot.has_current && p_fade_seconds > 0.0f) {
		Clip outgoing = r_slot.current;
		outgoing.weight_rate = -outgoing.weight / p_fade_seconds;
		r_slot.fading.push_back(outgoing);
	}
	r_slot.has_current = false;
	r_slot.current = Clip();
}

// Makes `start` the slot's latest start and emits clip_started for it.
void KfAnimator::_record_start(int p_slot, const Start &p_start, float p_fade_seconds) {
	Slot &slot = _slots[p_slot];
	slot.start = p_start;
	slot.has_start = true;
	emit_signal("clip_started", p_slot, p_start.path, p_start.animation, static_cast<int64_t>(p_start.serial), p_fade_seconds,
			p_start.keep_root, p_start.speed);
}

// Maps the clip's transform tracks to skeleton bones and reads each track's
// priority. False when no track names a bone.
bool KfAnimator::_bind(Clip &r_clip, bool p_keep_root) const {
	Skeleton3D *skeleton = _skeleton();
	if (r_clip.animation.is_null()) {
		return false;
	}
	if (skeleton == nullptr) {
		return _bind_nodes(r_clip);
	}
	const Ref<Animation> &animation = r_clip.animation;
	Dictionary priorities = animation->get_meta("nif_track_priorities", Dictionary());
	const String root_bone = ROOT_BONE;
	const String non_accum_bone = NON_ACCUM_BONE;
	for (int track = 0; track < animation->get_track_count(); track++) {
		const Animation::TrackType type = animation->track_get_type(track);
		const bool transform = type == Animation::TYPE_POSITION_3D || type == Animation::TYPE_ROTATION_3D ||
				type == Animation::TYPE_SCALE_3D;
		if (!transform || animation->track_get_key_count(track) == 0) {
			continue;
		}
		const String path = String(animation->track_get_path(track));
		if (!p_keep_root && (path == root_bone || path == non_accum_bone)) {
			continue;
		}
		const int bone = skeleton->find_bone(path);
		if (bone == -1) {
			continue;
		}
		if (path == root_bone && type == Animation::TYPE_POSITION_3D) {
			r_clip.root_position_track = track;
			r_clip.root_position_start = animation->position_track_interpolate(track, 0.0);
		} else if (path == non_accum_bone && type == Animation::TYPE_POSITION_3D) {
			r_clip.non_accum_position_track = track;
			r_clip.non_accum_position_start = animation->position_track_interpolate(track, 0.0);
		} else if (path == non_accum_bone && type == Animation::TYPE_ROTATION_3D) {
			r_clip.non_accum_rotation_track = track;
			r_clip.non_accum_rotation_start = animation->rotation_track_interpolate(track, 0.0);
		}
		BoundTrack bound;
		bound.bone = bone;
		bound.track = track;
		bound.type = type;
		bound.priority = static_cast<int>(priorities.get(path, 0));
		r_clip.tracks.push_back(bound);
	}
	return !r_clip.tracks.empty();
}

// Maps the clip's transform, visibility and value tracks to the Node3Ds under
// node_root and reads each track's priority. A track's node part is a path
// from node_root (a NIF's own clips) or a node's name (KF clips), the root
// itself included. A value track other than visibility sets its property as a
// float. Root motion does not apply: Bip01 and Bip01 NonAccum tracks are
// skipped. False when no track names a node.
bool KfAnimator::_bind_nodes(Clip &r_clip) const {
	Node3D *root = _node_root();
	if (root == nullptr) {
		return false;
	}
	const Ref<Animation> &animation = r_clip.animation;
	Dictionary priorities = animation->get_meta("nif_track_priorities", Dictionary());
	const String root_bone = ROOT_BONE;
	const String non_accum_bone = NON_ACCUM_BONE;
	const String visibility_suffix = VISIBILITY_SUFFIX;
	for (int track = 0; track < animation->get_track_count(); track++) {
		const Animation::TrackType type = animation->track_get_type(track);
		const bool transform = type == Animation::TYPE_POSITION_3D || type == Animation::TYPE_ROTATION_3D ||
				type == Animation::TYPE_SCALE_3D;
		const String path = String(animation->track_get_path(track));
		const bool value = type == Animation::TYPE_VALUE;
		const bool visibility = value && path.ends_with(visibility_suffix);
		if ((!transform && !value) || animation->track_get_key_count(track) == 0) {
			continue;
		}
		const int colon = path.find(":");
		if (value && colon < 0) {
			continue;
		}
		const String name = value ? path.substr(0, colon) : path;
		if (name == root_bone || name == non_accum_bone) {
			continue;
		}
		Node3D *target = nullptr;
		if (String(root->get_name()) == name) {
			target = root;
		} else {
			target = Object::cast_to<Node3D>(root->get_node_or_null(NodePath(name)));
			if (target == nullptr) {
				// A KF clip's bare name, or a path whose hierarchy was
				// collapsed since (an actor's skinned part): its last node.
				target = Object::cast_to<Node3D>(root->find_child(name.get_file(), true, false));
			}
		}
		if (target == nullptr) {
			continue;
		}
		BoundTrack bound;
		bound.node = target->get_instance_id();
		bound.track = track;
		bound.type = type;
		bound.priority = static_cast<int>(priorities.get(path, 0));
		if (value && !visibility) {
			bound.property = StringName(path.substr(colon + 1));
		}
		r_clip.tracks.push_back(bound);
	}
	return !r_clip.tracks.empty();
}

int64_t KfAnimator::play(int p_slot, const Ref<Animation> &p_animation, float p_fade_seconds, bool p_keep_root,
		float p_speed, const String &p_path, int64_t p_source_serial) {
	if (p_animation.is_null()) {
		return 0;
	}
	Clip clip;
	clip.animation = p_animation;
	clip.speed = p_speed;
	clip.length = static_cast<float>(p_animation->get_length());
	clip.loops = p_animation->get_loop_mode() != Animation::LOOP_NONE;
	clip.serial = _next_serial++;
	clip.keep_root = p_keep_root;
	clip.source_serial = static_cast<uint64_t>(std::max<int64_t>(p_source_serial, 0));
	// With node targets a clip plays even when it keys none of the nodes: it
	// still has a clock and events (a weapon's clip, followed by its holder,
	// whose parts it may not key: 1hpequip keys none of the 10mm pistol's).
	const bool clock_only = _skeleton() == nullptr && _node_root() != nullptr;
	if (!_bind(clip, p_keep_root) && !clock_only) {
		return 0;
	}
	Slot &slot = _slots[p_slot];
	const bool fade = p_fade_seconds > 0.0f;
	_end_current(slot, p_fade_seconds);
	// A clip fades in whether or not it replaces one: in an empty slot it rises
	// over whatever lower priorities hold its bones, rather than snapping.
	clip.weight = fade ? 0.0f : 1.0f;
	clip.weight_rate = fade ? 1.0f / p_fade_seconds : 0.0f;
	slot.current = clip;
	slot.has_current = true;
	if (!_follow_source(p_slot, slot.current)) {
		_emit_text_keys(p_slot, slot.current, -1.0f, 0.0f);
	}
	Start start;
	start.serial = clip.serial;
	start.path = p_path;
	start.animation = p_animation;
	start.keep_root = p_keep_root;
	start.speed = p_speed;
	start.played = true;
	_record_start(p_slot, start, p_fade_seconds);
	return static_cast<int64_t>(clip.serial);
}

int64_t KfAnimator::announce(int p_slot, const String &p_path, const Ref<Animation> &p_animation, float p_fade_seconds,
		bool p_keep_root, float p_speed) {
	auto found = _slots.find(p_slot);
	if (found != _slots.end()) {
		_end_current(found->second, p_fade_seconds);
	}
	Start start;
	start.serial = _next_serial++;
	start.path = p_path;
	start.animation = p_animation;
	start.keep_root = p_keep_root;
	start.speed = p_speed;
	_record_start(p_slot, start, p_fade_seconds);
	return static_cast<int64_t>(start.serial);
}

void KfAnimator::stop(int p_slot, float p_fade_seconds) {
	auto found = _slots.find(p_slot);
	if (found == _slots.end()) {
		return;
	}
	Slot &slot = found->second;
	_end_current(slot, p_fade_seconds);
	if (!slot.has_start) {
		return;
	}
	slot.has_start = false;
	slot.start = Start();
	emit_signal("clip_stopped", p_slot, p_fade_seconds);
}

void KfAnimator::stop_all() {
	PackedInt32Array started;
	for (const auto &entry : _slots) {
		if (entry.second.has_start) {
			started.push_back(entry.first);
		}
	}
	_slots.clear();
	for (int i = 0; i < started.size(); i++) {
		emit_signal("clip_stopped", started[i], 0.0f);
	}
}

Dictionary KfAnimator::get_start(int p_slot) const {
	Dictionary start;
	auto found = _slots.find(p_slot);
	if (found == _slots.end() || !found->second.has_start) {
		return start;
	}
	const Start &recorded = found->second.start;
	start["path"] = recorded.path;
	start["animation"] = recorded.animation;
	start["played"] = recorded.played;
	start["serial"] = static_cast<int64_t>(recorded.serial);
	start["keep_root"] = recorded.keep_root;
	start["speed"] = recorded.speed;
	return start;
}

void KfAnimator::seek(int p_slot, float p_time) {
	auto found = _slots.find(p_slot);
	if (found == _slots.end() || !found->second.has_current) {
		return;
	}
	Clip &clip = found->second.current;
	clip.time = std::clamp(p_time, 0.0f, clip.length);
	clip.finished = false;
}

void KfAnimator::set_loop_section(int p_slot, float p_start, float p_end, int p_count) {
	auto found = _slots.find(p_slot);
	if (found == _slots.end() || !found->second.has_current) {
		return;
	}
	Clip &clip = found->second.current;
	if (p_end < 0.0f || p_end <= p_start) {
		clip.loop_start = -1.0f;
		clip.loop_end = -1.0f;
		return;
	}
	clip.loop_start = std::max(0.0f, p_start);
	clip.loop_end = std::min(p_end, clip.length);
	clip.loops_left = p_count < 0 ? -1 : std::max(p_count, 1) - 1;
}

Ref<Animation> KfAnimator::get_animation(int p_slot) const {
	auto found = _slots.find(p_slot);
	if (found == _slots.end() || !found->second.has_current) {
		return Ref<Animation>();
	}
	return found->second.current.animation;
}

float KfAnimator::get_time(int p_slot) const {
	auto found = _slots.find(p_slot);
	if (found == _slots.end() || !found->second.has_current) {
		return 0.0f;
	}
	return found->second.current.time;
}

PackedInt32Array KfAnimator::get_started_slots() const {
	PackedInt32Array slots;
	for (const auto &entry : _slots) {
		if (entry.second.has_start) {
			slots.push_back(entry.first);
		}
	}
	return slots;
}

PackedInt32Array KfAnimator::get_slots() const {
	PackedInt32Array slots;
	for (const auto &entry : _slots) {
		if (entry.second.has_current) {
			slots.push_back(entry.first);
		}
	}
	return slots;
}

void KfAnimator::update_pose() {
	_write_pose();
}

void KfAnimator::_advance(float p_delta) {
	for (auto &entry : _slots) {
		Slot &slot = entry.second;
		if (slot.has_current) {
			_advance_clip(entry.first, slot.current, p_delta, true);
		}
		for (Clip &clip : slot.fading) {
			_advance_clip(entry.first, clip, p_delta, false);
		}
		slot.fading.erase(std::remove_if(slot.fading.begin(), slot.fading.end(),
								  [](const Clip &clip) { return clip.weight <= 0.0f; }),
				slot.fading.end());
	}
	std::vector<Event> events;
	events.swap(_events);
	for (const Event &event : events) {
		if (event.finished) {
			emit_signal("clip_finished", event.slot, event.animation);
		} else {
			emit_signal("text_key", event.slot, event.key, event.time);
		}
	}
}

// Moves the clip's clock and fade weight on by `delta`. A current clip fires
// its text keys, repeats its loop section, wraps when it loops and reports when
// a once-only clip reaches its end, which it then holds.
void KfAnimator::_advance_clip(int p_slot, Clip &r_clip, float p_delta, bool p_is_current) {
	r_clip.weight = std::clamp(r_clip.weight + r_clip.weight_rate * p_delta, 0.0f, 1.0f);
	if (r_clip.weight >= 1.0f && r_clip.weight_rate > 0.0f) {
		r_clip.weight_rate = 0.0f;
	}
	// A clip following its source takes the source's clock; the source emits
	// the events.
	if (_follow_source(p_slot, r_clip)) {
		return;
	}
	if (r_clip.finished) {
		return;
	}
	float from = r_clip.time;
	float to = from + p_delta * r_clip.speed;
	if (r_clip.loop_end >= 0.0f && to >= r_clip.loop_end && r_clip.loops_left != 0) {
		if (p_is_current) {
			_emit_text_keys(p_slot, r_clip, from, r_clip.loop_end);
		}
		if (r_clip.loops_left > 0) {
			r_clip.loops_left--;
		}
		to = r_clip.loop_start + std::fmod(to - r_clip.loop_end, std::max(r_clip.loop_end - r_clip.loop_start, 0.001f));
		if (p_is_current) {
			_emit_text_keys(p_slot, r_clip, r_clip.loop_start, to);
		}
		r_clip.time = to;
		return;
	}
	if (to >= r_clip.length) {
		if (r_clip.loops && r_clip.length > 0.0f) {
			if (p_is_current) {
				_emit_text_keys(p_slot, r_clip, from, r_clip.length);
			}
			to = std::fmod(to, r_clip.length);
			if (p_is_current) {
				_emit_text_keys(p_slot, r_clip, -1.0f, to);
			}
			r_clip.time = to;
			return;
		}
		r_clip.time = r_clip.length;
		r_clip.finished = true;
		if (p_is_current) {
			_emit_text_keys(p_slot, r_clip, from, r_clip.length);
			Event event;
			event.slot = p_slot;
			event.finished = true;
			event.animation = r_clip.animation;
			_events.push_back(event);
		}
		return;
	}
	if (p_is_current) {
		_emit_text_keys(p_slot, r_clip, from, to);
	}
	r_clip.time = to;
}

// Emits the clip's text keys (NifServer's nif_text_keys, times in the
// sequence's own clock, rebased by nif_start_time) in (from, to].
void KfAnimator::_emit_text_keys(int p_slot, const Clip &p_clip, float p_from, float p_to) {
	const Ref<Animation> &animation = p_clip.animation;
	Array keys = animation->get_meta("nif_text_keys", Array());
	const float start = static_cast<float>(animation->get_meta("nif_start_time", 0.0));
	for (int i = 0; i < keys.size(); i++) {
		Dictionary key = keys[i];
		const float time = static_cast<float>(key.get("time", 0.0)) - start;
		if (time > p_from && time <= p_to) {
			Event event;
			event.slot = p_slot;
			event.key = String(key.get("value", ""));
			event.time = time;
			_events.push_back(event);
		}
	}
}

// Gives each sample its share of the bone channel's weight, highest priority
// first (`r_samples` sorted on return). Weight no priority claims (clips fading
// out with nothing below them) is shared among the samples in proportion, so a
// lone fading clip holds its pose rather than easing to the bone's rest.
void KfAnimator::_resolve(std::vector<Sample> &r_samples) const {
	std::sort(r_samples.begin(), r_samples.end(), [](const Sample &a, const Sample &b) {
		if (a.priority != b.priority) {
			return a.priority > b.priority;
		}
		return a.serial > b.serial;
	});
	float remaining = 1.0f;
	size_t group_start = 0;
	while (group_start < r_samples.size()) {
		size_t group_end = group_start;
		while (group_end < r_samples.size() && r_samples[group_end].priority == r_samples[group_start].priority) {
			group_end++;
		}
		if (_tie_mode == TIE_NEWEST) {
			for (size_t i = group_start + 1; i < group_end; i++) {
				r_samples[i].weight = 0.0f;
			}
		}
		float group_weight = 0.0f;
		for (size_t i = group_start; i < group_end; i++) {
			group_weight += r_samples[i].weight;
		}
		const float take = std::min(group_weight, remaining);
		const float scale = group_weight > WEIGHT_EPSILON ? take / group_weight : 0.0f;
		for (size_t i = group_start; i < group_end; i++) {
			r_samples[i].weight *= scale;
		}
		remaining -= take;
		group_start = group_end;
		if (remaining <= WEIGHT_EPSILON) {
			for (size_t i = group_start; i < r_samples.size(); i++) {
				r_samples[i].weight = 0.0f;
			}
			remaining = 0.0f;
			break;
		}
	}
	const float taken = 1.0f - remaining;
	if (taken > WEIGHT_EPSILON && remaining > WEIGHT_EPSILON) {
		for (Sample &sample : r_samples) {
			sample.weight /= taken;
		}
	}
}

// Samples every playing clip, resolves each keyed bone channel and writes it
// to the skeleton.
void KfAnimator::_write_pose() {
	Skeleton3D *skeleton = _skeleton();
	if (skeleton == nullptr) {
		_write_node_pose();
		return;
	}
	const int bone_count = skeleton->get_bone_count();
	const int root_bone = skeleton->find_bone(ROOT_BONE);
	const int non_accum_bone = skeleton->find_bone(NON_ACCUM_BONE);
	const Clip *root_clip = _root_clip();
	Vector3 root_translation;
	float root_yaw = 0.0f;
	_root_motion = Transform3D();
	_root_serial = root_clip != nullptr ? root_clip->serial : 0;
	const bool whole_root = _root_motion_mode == ROOT_MOTION_ROOT_TRANSFORM;
	if (root_clip != nullptr) {
		_root_motion = _clip_root_motion(*root_clip);
	}
	_accumulate_root_motion(root_clip, get_root_clip_slot());
	const bool takes_bip01 = _root_motion_mode == ROOT_MOTION_BIP01 || _root_motion_mode == ROOT_MOTION_BIP01_NONACCUM_YAW;
	const bool takes_non_accum = _root_motion_mode == ROOT_MOTION_NONACCUM;
	std::vector<std::vector<Sample>> channels(static_cast<size_t>(bone_count) * CHANNEL_COUNT);
	std::vector<bool> disabled(static_cast<size_t>(bone_count), false);
	for (int i = 0; i < _disabled_bones.size(); i++) {
		const int bone = skeleton->find_bone(_disabled_bones[i]);
		if (bone != -1) {
			disabled[static_cast<size_t>(bone)] = true;
		}
	}
	auto add_clip = [&](const Clip &clip) {
		if (clip.weight <= WEIGHT_EPSILON) {
			return;
		}
		// Every clip with root tracks is drawn without its own root motion
		// since it started, the root clip's and those fading out alike: the
		// actor has taken (or, for an earlier clip, already took) that motion.
		Vector3 clip_translation;
		float clip_yaw = 0.0f;
		if (clip.keep_root && whole_root) {
			// All of the root is the actor's: Bip01 drawn at the origin,
			// NonAccum turned from its facing to the stance.
			const Transform3D root = _root_transform(clip, clip.time);
			clip_translation = root.origin;
			clip_yaw = yaw_about_z(root.basis.get_rotation_quaternion());
		} else if (clip.keep_root) {
			_measure_root_motion(clip, clip_translation, clip_yaw);
		}
		const Quaternion yaw_removed(Vector3(0.0f, 0.0f, 1.0f), -clip_yaw);
		const double time = clip.time;
		for (const BoundTrack &bound : clip.tracks) {
			if (bound.bone >= bone_count || disabled[static_cast<size_t>(bound.bone)]) {
				continue;
			}
			Sample sample;
			sample.priority = bound.priority;
			sample.weight = clip.weight;
			sample.serial = clip.serial;
			if (bound.type == Animation::TYPE_POSITION_3D) {
				sample.vector = clip.animation->position_track_interpolate(bound.track, time);
			} else if (bound.type == Animation::TYPE_ROTATION_3D) {
				sample.rotation = clip.animation->rotation_track_interpolate(bound.track, time);
			} else {
				sample.vector = clip.animation->scale_track_interpolate(bound.track, time);
			}
			if (clip.keep_root) {
				if ((takes_bip01 || whole_root) && bound.bone == root_bone && bound.type == Animation::TYPE_POSITION_3D) {
					sample.vector -= clip_translation;
				}
				if (takes_non_accum && bound.bone == non_accum_bone && bound.type == Animation::TYPE_POSITION_3D) {
					sample.vector -= clip_translation;
				}
				if (bound.bone == non_accum_bone && bound.type == Animation::TYPE_ROTATION_3D) {
					sample.rotation = yaw_removed * sample.rotation;
				}
			}
			channels[static_cast<size_t>(bound.bone) * CHANNEL_COUNT + channel_of(bound.type)].push_back(sample);
		}
	};
	for (const auto &entry : _slots) {
		const Slot &slot = entry.second;
		if (slot.has_current) {
			add_clip(slot.current);
		}
		for (const Clip &clip : slot.fading) {
			add_clip(clip);
		}
	}
	for (int bone = 0; bone < bone_count; bone++) {
		for (int channel = 0; channel < CHANNEL_COUNT; channel++) {
			std::vector<Sample> &samples = channels[static_cast<size_t>(bone) * CHANNEL_COUNT + channel];
			if (samples.empty()) {
				continue;
			}
			_resolve(samples);
			if (channel == CHANNEL_ROTATION) {
				const Quaternion reference = samples.front().rotation;
				Quaternion sum(0.0f, 0.0f, 0.0f, 0.0f);
				for (const Sample &sample : samples) {
					if (sample.weight <= 0.0f) {
						continue;
					}
					const float sign = sample.rotation.dot(reference) < 0.0f ? -1.0f : 1.0f;
					sum = sum + sample.rotation * (sample.weight * sign);
				}
				if (sum.length_squared() > WEIGHT_EPSILON) {
					skeleton->set_bone_pose_rotation(bone, sum.normalized());
				}
				continue;
			}
			Vector3 sum;
			float total = 0.0f;
			for (const Sample &sample : samples) {
				sum += sample.vector * sample.weight;
				total += sample.weight;
			}
			if (total <= WEIGHT_EPSILON) {
				continue;
			}
			if (channel == CHANNEL_POSITION) {
				skeleton->set_bone_pose_position(bone, sum);
			} else {
				skeleton->set_bone_pose_scale(bone, sum);
			}
		}
	}
	// Under ROOT_TRANSFORM all of the root is the actor's, so Bip01 is drawn at
	// the origin, unrotated, whichever clip plays (mtidle keys no Bip01, and no
	// clip keys its rotation). hold_unkeyed_root does the same in the other
	// modes for a root clip that keys no Bip01.
	if (root_clip != nullptr && root_bone != -1) {
		bool keys_root = false;
		for (const BoundTrack &bound : root_clip->tracks) {
			keys_root = keys_root || bound.bone == root_bone;
		}
		if (whole_root || (_hold_unkeyed_root && !keys_root)) {
			skeleton->set_bone_pose_position(root_bone, Vector3());
			skeleton->set_bone_pose_rotation(root_bone, Quaternion());
		}
	}
}

// Samples every playing clip's node tracks, resolves each keyed channel and
// writes it to its Node3D. Transforms resolve as bone channels do; visibility
// takes the highest priority clip's value, the newest at a tie.
void KfAnimator::_write_node_pose() {
	if (_node_root() == nullptr) {
		return;
	}
	std::map<uint64_t, std::vector<std::vector<Sample>>> channels;
	// Node -> property -> its samples, one per clip keying it.
	std::map<uint64_t, std::map<StringName, std::vector<Sample>>> properties;
	auto add_clip = [&](const Clip &clip) {
		if (clip.weight <= WEIGHT_EPSILON) {
			return;
		}
		const double time = clip.time;
		for (const BoundTrack &bound : clip.tracks) {
			if (bound.bone != -1) {
				continue;
			}
			Sample sample;
			sample.priority = bound.priority;
			sample.weight = clip.weight;
			sample.serial = clip.serial;
			if (!bound.property.is_empty()) {
				const Variant property_value = clip.animation->value_track_interpolate(bound.track, time);
				sample.vector.x = static_cast<float>(property_value);
				properties[static_cast<uint64_t>(bound.node)][bound.property].push_back(sample);
				continue;
			}
			int channel = CHANNEL_VISIBLE;
			if (bound.type == Animation::TYPE_VALUE) {
				const bool shown = clip.animation->value_track_interpolate(bound.track, time);
				sample.vector.x = shown ? 1.0f : 0.0f;
			} else {
				channel = channel_of(bound.type);
				if (bound.type == Animation::TYPE_POSITION_3D) {
					sample.vector = clip.animation->position_track_interpolate(bound.track, time);
				} else if (bound.type == Animation::TYPE_ROTATION_3D) {
					sample.rotation = clip.animation->rotation_track_interpolate(bound.track, time);
				} else {
					sample.vector = clip.animation->scale_track_interpolate(bound.track, time);
				}
			}
			std::vector<std::vector<Sample>> &node_channels = channels[static_cast<uint64_t>(bound.node)];
			node_channels.resize(NODE_CHANNEL_COUNT);
			node_channels[static_cast<size_t>(channel)].push_back(sample);
		}
	};
	for (const auto &entry : _slots) {
		const Slot &slot = entry.second;
		if (slot.has_current) {
			add_clip(slot.current);
		}
		for (const Clip &clip : slot.fading) {
			add_clip(clip);
		}
	}
	// A property takes the highest priority clip's value, the newest at a tie,
	// as visibility does.
	for (auto &entry : properties) {
		Node3D *node = Object::cast_to<Node3D>(ObjectDB::get_instance(ObjectID(entry.first)));
		if (node == nullptr) {
			continue;
		}
		for (auto &property : entry.second) {
			const Sample *chosen = &property.second.front();
			for (const Sample &sample : property.second) {
				const bool higher = sample.priority > chosen->priority;
				const bool newer_tie = sample.priority == chosen->priority && sample.serial > chosen->serial;
				if (higher || newer_tie) {
					chosen = &sample;
				}
			}
			node->set(property.first, chosen->vector.x);
		}
	}
	for (auto &entry : channels) {
		Node3D *node = Object::cast_to<Node3D>(ObjectDB::get_instance(ObjectID(entry.first)));
		if (node == nullptr) {
			continue;
		}
		std::vector<std::vector<Sample>> &node_channels = entry.second;
		const std::vector<Sample> &visible = node_channels[CHANNEL_VISIBLE];
		if (!visible.empty()) {
			const Sample *chosen = &visible.front();
			for (const Sample &sample : visible) {
				const bool higher = sample.priority > chosen->priority;
				const bool newer_tie = sample.priority == chosen->priority && sample.serial > chosen->serial;
				if (higher || newer_tie) {
					chosen = &sample;
				}
			}
			node->set_visible(chosen->vector.x > 0.5f);
		}
		for (int channel = 0; channel < CHANNEL_COUNT; channel++) {
			std::vector<Sample> &samples = node_channels[static_cast<size_t>(channel)];
			if (samples.empty()) {
				continue;
			}
			_resolve(samples);
			if (channel == CHANNEL_ROTATION) {
				const Quaternion reference = samples.front().rotation;
				Quaternion sum(0.0f, 0.0f, 0.0f, 0.0f);
				for (const Sample &sample : samples) {
					if (sample.weight <= 0.0f) {
						continue;
					}
					const float sign = sample.rotation.dot(reference) < 0.0f ? -1.0f : 1.0f;
					sum = sum + sample.rotation * (sample.weight * sign);
				}
				if (sum.length_squared() > WEIGHT_EPSILON) {
					node->set_quaternion(sum.normalized());
				}
				continue;
			}
			Vector3 sum;
			float total = 0.0f;
			for (const Sample &sample : samples) {
				sum += sample.vector * sample.weight;
				total += sample.weight;
			}
			if (total <= WEIGHT_EPSILON) {
				continue;
			}
			if (channel == CHANNEL_POSITION) {
				node->set_position(sum);
			} else {
				node->set_scale(sum);
			}
		}
	}
}

// The clip's root at `time` as one transform, skeleton space: Bip01's
// translation, then NonAccum's facing as a rotation about Z (0 at the stance).
// A clip without the track has the origin, or the stance.
Transform3D KfAnimator::_root_transform(const Clip &p_clip, double p_time) const {
	Vector3 translation;
	if (p_clip.root_position_track != -1) {
		translation = p_clip.animation->position_track_interpolate(p_clip.root_position_track, p_time);
	}
	float facing = 0.0f;
	if (p_clip.non_accum_rotation_track != -1) {
		facing = yaw_about_z(p_clip.animation->rotation_track_interpolate(p_clip.non_accum_rotation_track, p_time)) - STANCE_YAW;
	}
	return Transform3D(Basis(Vector3(0.0f, 0.0f, 1.0f), facing), translation);
}

// The clip's root change since its start under the root motion mode, skeleton
// space.
Transform3D KfAnimator::_clip_root_motion(const Clip &p_clip) const {
	if (_root_motion_mode == ROOT_MOTION_ROOT_TRANSFORM) {
		return _root_transform(p_clip, 0.0).affine_inverse() * _root_transform(p_clip, p_clip.time);
	}
	Vector3 translation;
	float yaw = 0.0f;
	_measure_root_motion(p_clip, translation, yaw);
	return Transform3D(Basis(Vector3(0.0f, 0.0f, 1.0f), yaw), translation);
}

// The playing or fading clip started as `serial`, or null once it is gone.
const KfAnimator::Clip *KfAnimator::_clip_by_serial(uint64_t p_serial) const {
	for (const auto &entry : _slots) {
		const Slot &slot = entry.second;
		if (slot.has_current && slot.current.serial == p_serial) {
			return &slot.current;
		}
		for (const Clip &clip : slot.fading) {
			if (clip.serial == p_serial) {
				return &clip;
			}
		}
	}
	return nullptr;
}

// Adds the root clips' motion since the last pose write to what
// consume_root_motion() returns: the rest of the clip measured last time, when
// another has taken over (while it is still playing or fading), then the
// current root clip's since it was last measured, or since its start.
void KfAnimator::_accumulate_root_motion(const Clip *p_root_clip, int p_root_slot) {
	const uint64_t serial = p_root_clip != nullptr ? p_root_clip->serial : 0;
	if (serial != _measured_serial && _measured_serial != 0) {
		const Clip *previous = _clip_by_serial(_measured_serial);
		if (previous != nullptr && _measured_slot != _root_motion_excluded_slot) {
			_pending_root_motion = _pending_root_motion * (_measured_motion.affine_inverse() * _clip_root_motion(*previous));
		}
		_measured_motion = Transform3D();
	}
	_measured_serial = serial;
	_measured_slot = p_root_slot;
	if (p_root_clip == nullptr) {
		_measured_motion = Transform3D();
		return;
	}
	const Transform3D motion = _clip_root_motion(*p_root_clip);
	if (p_root_slot != _root_motion_excluded_slot) {
		_pending_root_motion = _pending_root_motion * (_measured_motion.affine_inverse() * motion);
	}
	_measured_motion = motion;
}

// The most recently started current clip played with keep_root outside
// root_motion_excluded_slot, else the excluded slot's (locomotion restarted
// while an idle plays does not take the root from it), or null.
const KfAnimator::Clip *KfAnimator::_root_clip() const {
	const Clip *found = nullptr;
	const Clip *excluded = nullptr;
	for (const auto &entry : _slots) {
		const Slot &slot = entry.second;
		if (!slot.has_current || !slot.current.keep_root) {
			continue;
		}
		if (entry.first == _root_motion_excluded_slot) {
			excluded = &slot.current;
			continue;
		}
		if (found == nullptr || slot.current.serial > found->serial) {
			found = &slot.current;
		}
	}
	return found != nullptr ? found : excluded;
}

// The clip's root change since its start under the root motion mode:
// translation in the skeleton's space and yaw about Z, radians.
void KfAnimator::_measure_root_motion(const Clip &p_clip, Vector3 &r_translation, float &r_yaw) const {
	r_translation = Vector3();
	r_yaw = 0.0f;
	if (_root_motion_mode == ROOT_MOTION_NONE) {
		return;
	}
	const double time = p_clip.time;
	const Ref<Animation> &animation = p_clip.animation;
	if (_root_motion_mode == ROOT_MOTION_BIP01 || _root_motion_mode == ROOT_MOTION_BIP01_NONACCUM_YAW) {
		if (p_clip.root_position_track != -1) {
			r_translation = animation->position_track_interpolate(p_clip.root_position_track, time) - p_clip.root_position_start;
		}
	}
	if (_root_motion_mode == ROOT_MOTION_NONACCUM && p_clip.non_accum_position_track != -1) {
		r_translation = animation->position_track_interpolate(p_clip.non_accum_position_track, time) - p_clip.non_accum_position_start;
		r_translation.z = 0.0f;
	}
	if (_root_motion_mode == ROOT_MOTION_BIP01) {
		return;
	}
	if (p_clip.non_accum_rotation_track != -1) {
		const Quaternion now = animation->rotation_track_interpolate(p_clip.non_accum_rotation_track, time);
		r_yaw = yaw_about_z(now) - yaw_about_z(p_clip.non_accum_rotation_start);
	}
}
