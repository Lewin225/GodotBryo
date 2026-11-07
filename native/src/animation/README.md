# animation

`KfAnimator` (`kf_animator.{h,cpp}`): a Node that plays Gamebryo KF clips on a `Skeleton3D`. The
class reference, shown in the editor's help and inspector tooltips, is
[`native/doc_classes/KfAnimator.xml`](../../doc_classes/KfAnimator.xml); keep it current with the
bindings.

Design and findings: [`Plans/Actors/animation_blending.md`](../../../Plans/Actors/animation_blending.md)
(priorities, slots, root motion), [`Plans/Actors/first_person.md`](../../../Plans/Actors/first_person.md)
(sync mode).

Callers: `ActorAnimator` (an actor's locomotion and idles), `FirstPersonRig` through `KfClipSync`
(the first-person viewmodel following the actor), `animation_viewer.tscn` (the launcher's
Animation viewer). Test: `project/tests/test_kf_animator_sync.tscn`.

---

## Clips

A clip is a NifServer `Animation` from `NifServer.request_kf()`: transform tracks whose paths are
bone names, with metadata

| Meta | Use |
|---|---|
| `nif_track_priorities` | track path -> controlled block priority |
| `nif_text_keys` | `[{time, value}]`; `StartLoop` / `EndLoop` give the loop section, the rest are emitted as `text_key` |
| `nif_start_time` | the sequence's start, subtracted from text key times |

A channel with no keys in the KF (a controlled block holding a static pose) is a one-key track,
so it holds that pose for the whole clip (NifServer, `kf_static_pose_census`).

KfAnimator does not load clips. Callers request them from NifServer and pass the `Animation`.

## Slots and priorities

- A slot is an animation group section number chosen by the caller (ActorAnimator: IDLE DATA's
  section; 1 is Movement). A slot plays at most one current clip, plus the clips it fades out from.
- `play()` fades the new clip in over `fade_seconds`, in an empty slot too, so it rises over
  whatever lower priorities hold its bones instead of snapping.
- Per bone channel (position, rotation, scale), every playing clip keying it gives a sample. The
  samples are taken highest priority first: a priority's samples share the weight still
  unclaimed (their fade weights, at most all of it), and what is left passes to the next
  priority. Weight no priority claims is shared among them in proportion, so a clip fading out
  alone holds its pose rather than easing to the bone's rest.
- `tie_mode`: at one priority, clips blend by fade weight (Blend) or only the newest counts
  (Newest).
- Bones no clip keys, and `disabled_bones`, are not written.

## Writing the pose

- Poses are written with `Skeleton3D.set_bone_pose_*`, as AnimationMixer does, not as a
  `SkeletonModifier3D`. Skeleton3D restores every pose after its modifiers each frame, so the
  written pose is what `LookAtModifier3D` and IK start from, and it stays put on frames
  `update_interval` skips.
- Each process frame: unless `paused`, clocks, fades and loop sections advance; every
  `update_interval` frames the pose is written. `update_pose()` writes it now.
- A pose read after the frame is the restored one; read modifier results on
  `Skeleton3D.skeleton_updated`.

## Events

- `clip_finished(slot, animation)`: a once-only clip reached its end and holds its last frame.
- `text_key(slot, key, time)`: the current clip passed a text key.
- Both are queued while slots advance and emitted after, so a handler may play or stop clips.
- `clip_started(slot, path, animation, serial, fade_seconds, keep_root, speed)`: every start, played
  or announced. Emitted after the start is recorded (`get_start()` returns it).
- `clip_stopped(slot, fade_seconds)`: `stop()` or `stop_all()` ended a slot with a start.

## Root motion

`root_motion_mode` chooses how a clip played with `keep_root` is read. The KFs split the root
between `Bip01` (translation) and `Bip01 NonAccum` (facing). Every `keep_root` clip is drawn without
its own root change since it started. The root clip, the most recently started `keep_root` clip
outside `root_motion_excluded_slot`, is reported by `get_root_motion()`; its motion is added up at
each pose write for `consume_root_motion()`, including a root clip that ended or was replaced since
the last call.

| Mode | Taken |
|---|---|
| None | nothing |
| Bip01 | Bip01's translation |
| Bip01 + NonAccum Yaw | Bip01's translation and NonAccum's yaw about Z |
| NonAccum | NonAccum's translation in XY and its yaw about Z |
| Root Transform | Bip01's translation then NonAccum's facing against the stance yaw (90 degrees), as one transform; the clip is drawn with all of it out (Bip01 at the origin, NonAccum turned to the stance) |

Root Transform is what ActorAnimator uses, with `root_motion_excluded_slot = 1` (locomotion, which
the controller moves). It is a tested guess: the only reading that plays Doc Mitchell's chair
enter, seated loop and exit correctly; not checked against the original. The other modes are kept
for comparison in the Animation viewer.

`hold_unkeyed_root`: a root clip that keys no Bip01 has Bip01 drawn at the clip's origin.

Known gap: a looping clip with root motion steps back a cycle at each wrap.

## Sync mode

One KfAnimator can follow another (`sync_source`):

- Every start has a serial. `play()` returns it. `announce()` records a start the animator cannot
  play (its clip keys none of its bones) and emits it all the same.
- A clip played on the follower with `source_serial` takes, each frame, the time, loop section and
  end of the source's clip of that serial in the same slot (current or fading out), and emits no
  `text_key` or `clip_finished`. While the source has no such clip it runs on its own clock and
  emits both.
- The follower reads the source's time as it stands when the follower processes: give it a higher
  `process_priority` (KfClipSync does).
- Which clip the follower plays for a start is the caller's choice. `KfClipSync`
  (`project/GodotBryo/Types/Node/kf_clip_sync.gd`) remaps the path (`_male` to `_1stperson`) or
  plays the source's own clip.

## Rules for changing it

- Bindings and `doc_classes/KfAnimator.xml` change together.
- No caller-specific flags or special cases: a rule must hold for every clip (a per-call "ends the
  others" flag was rejected for this).
- Behaviour read from the data is marked as such; guesses (Root Transform, Whole Body ending other
  idles in ActorAnimator) say so where they are implemented.
- Rebuild the extension after changing it (`native/README.md`); a stale `.so` runs the old code
  without an error.
