#ifndef KF_ANIMATOR_H
#define KF_ANIMATOR_H

#include <godot_cpp/classes/animation.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/core/object_id.hpp>

#include <map>
#include <vector>

namespace godot {

// Plays several KF clips on one Skeleton3D at once, one per slot (an animation
// group section), and resolves each bone channel by the clips' controlled
// block priorities: highest first, each priority's clips sharing the weight
// still unclaimed. Writes poses with Skeleton3D::set_bone_pose_*, so the
// skeleton's modifiers apply on top. Reports root motion
// (root_motion_mode), every start and stop (clip_started, clip_stopped), and
// can follow another KfAnimator's clocks (sync_source). With no skeleton it
// plays on the Node3Ds under node_root instead (a weapon's parts), including
// their visibility tracks.
//
// The module's README (native/src/animation/README.md) describes slots,
// priorities, root motion and sync mode; the class reference is
// native/doc_classes/KfAnimator.xml. Plans/Actors/animation_blending.md and
// Plans/Actors/first_person.md hold the findings behind them.
class KfAnimator : public Node {
	GDCLASS(KfAnimator, Node)

public:
	enum TieMode {
		TIE_BLEND = 0,
		TIE_NEWEST = 1,
	};

	enum RootMotionMode {
		ROOT_MOTION_NONE = 0,
		ROOT_MOTION_BIP01 = 1,
		ROOT_MOTION_BIP01_NONACCUM_YAW = 2,
		ROOT_MOTION_NONACCUM = 3,
		ROOT_MOTION_ROOT_TRANSFORM = 4,
	};

	KfAnimator() = default;

	void set_skeleton_path(const NodePath &p_path);
	NodePath get_skeleton_path() const;
	// The node whose Node3D descendants (and itself) are the targets when
	// skeleton_path resolves to no skeleton: a track binds to the node named
	// as its path.
	void set_node_root(const NodePath &p_path);
	NodePath get_node_root() const;
	void set_update_interval(int p_frames);
	int get_update_interval() const;
	void set_paused(bool p_paused);
	bool is_paused() const;
	void set_tie_mode(int p_mode);
	int get_tie_mode() const;
	void set_root_motion_mode(int p_mode);
	int get_root_motion_mode() const;
	void set_disabled_bones(const PackedStringArray &p_bones);
	PackedStringArray get_disabled_bones() const;
	void set_hold_unkeyed_root(bool p_hold);
	bool is_holding_unkeyed_root() const;
	// The root clip's root change since it started, skeleton space; identity
	// with no root clip or mode NONE. Updated when the pose is written.
	Transform3D get_root_motion() const;
	// Which clip get_root_motion() is measured from (its play order), 0 for
	// none: a new value means a new clip, from whose start the motion restarts.
	int64_t get_root_clip_serial() const;
	// The slot of the clip get_root_motion() is measured from, -1 for none.
	int get_root_clip_slot() const;
	// The root clips' motion added up at each pose write since the last call,
	// and reset: a root clip that ends or is replaced between calls has its
	// motion up to then included. Clips in root_motion_excluded_slot are left
	// out (locomotion, which the controller moves).
	Transform3D consume_root_motion();
	void set_root_motion_excluded_slot(int p_slot);
	int get_root_motion_excluded_slot() const;

	// The KfAnimator that clips played with a source_serial follow.
	void set_sync_source(const NodePath &p_path);
	NodePath get_sync_source() const;
	// Slot -> the KfAnimator that clips played with a source_serial in that
	// slot follow, in place of sync_source (an actor's weapon slot follows the
	// weapon, its other slots the default).
	void set_slot_sync_sources(const Dictionary &p_sources);
	Dictionary get_slot_sync_sources() const;

	// Starts `animation` in `slot`, fading in over `fade_seconds` (in an empty
	// slot too) while the slot's current clip fades out. Bip01 and Bip01 NonAccum tracks play
	// only with `keep_root`. `path` is the clip's KF path, reported by
	// clip_started; a non-zero `source_serial` makes the clip follow the
	// sync_source clip of that serial. Returns the start's serial, 0 when the
	// animation is null or keys none of the skeleton's bones (nothing starts and
	// nothing is emitted). With node targets a clip keying none of the nodes
	// still plays, for its clock and events.
	int64_t play(int p_slot, const Ref<Animation> &p_animation, float p_fade_seconds, bool p_keep_root, float p_speed,
			const String &p_path, int64_t p_source_serial);
	// Records a start of the KF at `path` (loaded as `animation`, or null) in
	// `slot` that this animator does not play, and emits clip_started for it:
	// the slot's current clip fades out over `fade_seconds` and the slot is
	// left empty. Returns the serial.
	int64_t announce(int p_slot, const String &p_path, const Ref<Animation> &p_animation, float p_fade_seconds,
			bool p_keep_root, float p_speed);
	// Fades the slot's clip out over `fade_seconds`; the slot is then empty.
	// Emits clip_stopped when the slot had a start.
	void stop(int p_slot, float p_fade_seconds);
	void stop_all();
	// The slot's latest start, played or announced: {path, animation, serial,
	// keep_root, speed, played}; empty when the slot has none (never started,
	// or stopped). `played` is false for an announced start.
	Dictionary get_start(int p_slot) const;
	// The slots with a start, played or announced.
	PackedInt32Array get_started_slots() const;
	// Moves the slot's current clip to `time` seconds.
	void seek(int p_slot, float p_time);
	// Loops the slot's current clip between `start` and `end` seconds (its
	// StartLoop and EndLoop keys) `count` times in all, then lets it play on
	// to its end; a negative `count` loops forever and a negative `end`
	// clears the section.
	void set_loop_section(int p_slot, float p_start, float p_end, int p_count);
	Ref<Animation> get_animation(int p_slot) const;
	float get_time(int p_slot) const;
	PackedInt32Array get_slots() const;
	// Writes the pose now, whatever the update interval.
	void update_pose();

protected:
	static void _bind_methods();
	void _notification(int p_what);

private:
	// One track of a clip bound to a skeleton bone, or to a Node3D under
	// node_root (`node`, with `bone` -1).
	struct BoundTrack {
		int bone = -1;
		ObjectID node;
		int track = -1;
		Animation::TrackType type = Animation::TYPE_POSITION_3D;
		int priority = 0;
		// A value track's property on a node target, set to the track's value
		// as it is, a float or a Color (the NIF shaders' instance uniforms,
		// `instance_shader_parameters/<name>`).
		// Empty for transform and visibility tracks.
		StringName property;
	};

	// A clip playing in a slot.
	struct Clip {
		Ref<Animation> animation;
		std::vector<BoundTrack> tracks;
		float time = 0.0f;
		float speed = 1.0f;
		float length = 0.0f;
		bool loops = false;
		// Fade weight, 0 to 1, and its change per second.
		float weight = 1.0f;
		float weight_rate = 0.0f;
		// Order of play: higher started later.
		uint64_t serial = 0;
		bool keep_root = false;
		// The root tracks, -1 when the clip has none, and their values at the
		// clip's start.
		int root_position_track = -1;
		int non_accum_position_track = -1;
		int non_accum_rotation_track = -1;
		Vector3 root_position_start;
		Vector3 non_accum_position_start;
		Quaternion non_accum_rotation_start;
		float loop_start = -1.0f;
		float loop_end = -1.0f;
		// Passes of the loop section still to start after the current one;
		// negative loops forever.
		int loops_left = -1;
		bool finished = false;
		// The sync_source clip this one follows (its serial), 0 for none.
		uint64_t source_serial = 0;
	};

	// A start in a slot, played or announced.
	struct Start {
		uint64_t serial = 0;
		String path;
		Ref<Animation> animation;
		bool keep_root = false;
		float speed = 1.0f;
		bool played = false;
	};

	struct Slot {
		Clip current;
		bool has_current = false;
		std::vector<Clip> fading;
		Start start;
		bool has_start = false;
	};

	// A signal raised while advancing, emitted once every slot has advanced:
	// a handler may play or stop clips, which must not happen mid-iteration.
	struct Event {
		int slot = 0;
		bool finished = false;
		Ref<Animation> animation;
		String key;
		float time = 0.0f;
	};

	// One clip's sample for one bone channel.
	struct Sample {
		int priority = 0;
		float weight = 0.0f;
		uint64_t serial = 0;
		Vector3 vector;
		Quaternion rotation;
		// A property track's value.
		Variant value;
	};

	Skeleton3D *_skeleton() const;
	Node3D *_node_root() const;
	bool _bind_nodes(Clip &r_clip) const;
	void _write_node_pose();
	KfAnimator *_source(int p_slot) const;
	const Clip *_source_clip(int p_slot, uint64_t p_serial) const;
	bool _follow_source(int p_slot, Clip &r_clip) const;
	void _end_current(Slot &r_slot, float p_fade_seconds);
	void _record_start(int p_slot, const Start &p_start, float p_fade_seconds);
	bool _bind(Clip &r_clip, bool p_keep_root) const;
	void _advance(float p_delta);
	void _advance_clip(int p_slot, Clip &r_clip, float p_delta, bool p_is_current);
	void _emit_text_keys(int p_slot, const Clip &p_clip, float p_from, float p_to);
	void _write_pose();
	void _resolve(std::vector<Sample> &r_samples) const;
	const Clip *_root_clip() const;
	void _measure_root_motion(const Clip &p_clip, Vector3 &r_translation, float &r_yaw) const;
	Transform3D _root_transform(const Clip &p_clip, double p_time) const;
	Transform3D _clip_root_motion(const Clip &p_clip) const;
	const Clip *_clip_by_serial(uint64_t p_serial) const;
	void _accumulate_root_motion(const Clip *p_root_clip, int p_root_slot);

	std::vector<Event> _events;
	NodePath _skeleton_path;
	NodePath _node_root_path;
	NodePath _sync_source_path;
	Dictionary _slot_sync_sources;
	int _update_interval = 1;
	bool _paused = false;
	int _tie_mode = TIE_BLEND;
	int _root_motion_mode = ROOT_MOTION_NONE;
	bool _hold_unkeyed_root = false;
	PackedStringArray _disabled_bones;
	Transform3D _root_motion;
	uint64_t _root_serial = 0;
	// consume_root_motion(): the motion added up, the clip and slot last
	// measured and its root motion then.
	Transform3D _pending_root_motion;
	uint64_t _measured_serial = 0;
	int _measured_slot = -1;
	Transform3D _measured_motion;
	int _root_motion_excluded_slot = -1;
	std::map<int, Slot> _slots;
	uint64_t _next_serial = 1;
	uint64_t _frame = 0;
};

} // namespace godot

VARIANT_ENUM_CAST(KfAnimator::TieMode);
VARIANT_ENUM_CAST(KfAnimator::RootMotionMode);

#endif // KF_ANIMATOR_H
