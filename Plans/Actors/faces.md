# Faces, hair, hats and lip sync

The parts of a humanoid's head the actor node does not yet build from data: each NPC's
FaceGen shape and skin, hair colour, hats that sit on the head and replace the hair, and
lip sync for spoken lines. Done before stage J (creatures). See `actors.md`.

## Facts

From FalloutNV.esm, the BSAs and the running actor node (`_diag/diag_hat_placement`, scratch
ESM and BSA scans, `native/tools/facegen_asset_census`, `facegen_census`).

### FaceGen

- 3,814 of 3,816 NPC_ carry FGGS (50 floats, geometry symmetric), FGGA (30, geometry
  asymmetric) and FGTS (50, texture symmetric). `EsmServer` reads them into
  `NpcBase.face_gen` (`FaceGenData`); nothing applies them.
- 275 EGM (geometry morph bases), 36 EGT (texture morph bases) and 49 TRI (named morph
  targets) under `meshes\`:
  - every head part: heads (human, female, old, ghoul, child), eyes, mouth, teeth, tongue;
  - every hair NIF, its Hat and NoHat halves each with an EGM, and beards, brows, glasses;
  - about 75 headgear NIFs under `armor\` (cowboy hats, helmets, caps, goggles, masks), so a
    hat is morphed to the face it sits on;
  - EGT on the heads, eyes, and on the body, hands and upper bodies (`characters\_male\`), so
    FGTS tints skin beyond the face.
- `RACE` PNAM / UNAM (FaceGen main and face clamps) are read into `RaceBase`; not used.
- The legacy assembly (`project/gamebryo/mesh_resolver.gd`: `_parse_facegen_egm`,
  `_apply_facegen_geometry`, `_apply_tri_morph_targets`) applied FGGS/FGGA through the EGM to
  head part geometry and turned TRI targets into blend shapes. It never built EGT/FGTS
  textures. `native/src/tri/` (`TriReader`) is still built and registered.

### Hair

- HNAM on 2,767 NPC_, HCLR on all 3,816 (698 distinct colours; the commonest 4b3219, on
  1,031). `NpcBase.hair_color` is read; not used, so hair renders in its texture's colour.
- Hair NIFs hold a NoHat and a Hat mesh. `EsmActorNode.wearing_hat` picks one; nothing sets
  it, so the NoHat hair shows, also under a hat (GoodspringsSettler04's CowboyHat3).

### Hats

- Unskinned headgear is attached by `ActorEquipment._attach_unskinned` to a `BoneAttachment3D`
  on HeadAnims, chosen by the path containing `hat`, `hair`, `head`, `shades` or `glasses`, not
  by the ARMO's biped slots.
- A `BoneAttachment3D` on an external skeleton follows the animated bone but not the look-at
  modifier: GoodspringsSettler04's CowboyHat3 sat up to 50 deg off the posed HeadAnims while
  the head tracked a target, against 0.1 deg for the hair's attachment under the skeleton. The
  staged path to the skeleton also broke when the equipment was committed one level up.
  Committed attachments now hang under the skeleton (`_hang_attachments_from_skeleton`); the
  hat stays within 0.1 deg (`tests/test_actor_headgear`). Weapons attach the same way.
- BMDT on ARMO and ARMA covering a head slot (Head 0x1, Hair 0x2, Headband 0x200, Hat 0x400,
  EyeGlasses 0x800, Mask 0x4000), FalloutNV.esm:
  - 0x602 Hair, Headband, Hat: 45 ARMO, 4 ARMA (every cowboy hat, CassHat, Raul's hat, hoods,
    combat helmet mk2);
  - 0x600 Headband, Hat: 30 ARMO (Ranger civilian hats, 1950s caps and bonnets, fire helmet);
  - 0x4202 Hair, Headband, Mask: 14 (metal helmet, Legion helmets);
  - 0x4800 EyeGlasses, Mask: 11 (glasses);
  - 0x4E03 Head, Hair, Headband, Hat, EyeGlasses, Mask: 7 (power armour helmets);
  - 0x200 Headband: 3 (bandanas, surgical mask); 0x202: 5; the rest 1 to 3 each.

### Lip sync

- 60,702 `.lip` files sit beside the voice files (same stem; `enginedocs/Data Types/LIP.txt`).
  Doc's `vcg01_vcg01intro_00104bee_1.lip` is 2,804 bytes: u32 1, u32 0x4194, u32 1, then
  packed records mixing 16-bit fields and floats. The format is not documented anywhere
  found; it has to be decoded from the files.
- The head TRI files name phoneme and expression targets (`Aah`, `BigAah`, `BlinkLeft`,
  `BlinkRight`, `Anger`, ...); `testfacialanims.kf` drives them through a
  `NiGeomMorpherController` on HeadAnims, so KF clips can carry face tracks too.

## Shape (proposed)

- **FaceGen geometry.** NifServer (or a FaceGen helper beside it) reads EGM; each head part,
  hair and headgear mesh is morphed by the NPC's FGGS/FGGA, as the legacy code did. Morphed
  meshes are per NPC, cached by (mesh, FaceGen values). Morph cost is measured first; if it
  stalls a frame, it moves off the main thread and is delivered by callback, like a NIF
  request.
- **FaceGen texture.** FGTS through each EGT gives a per-NPC diffuse for the head and the skin
  parts. Built once per NPC and cached; until then the base texture.
- **Hair colour.** HCLR tints the hair material (and brows and beards). How the original
  combines tint and texture is to check against the hair shader flags and textures.
- **Hats.** Headgear hangs from a HeadAnims attachment under the skeleton (done).
  `wearing_hat` is true while equipment covers the Hat slot (0x400), showing the hair's Hat
  variant (done). Attachment chosen by biped slots rather than path.
- **Lip sync.** A decoder for `.lip` (native, beside `TriReader`), TRI targets as blend
  shapes on the head, mouth, teeth and tongue, and a facial player that DialogueServer starts
  with each line's voice. Blinks and KF face tracks run on the same player.

## Build order

1. **Hats.** `wearing_hat` from the equipped headgear's biped slots; headgear on the hair's
   attachment, chosen by slot; checked in play and against a turned head.
2. **Hair colour.** HCLR on hair, brows and beards.
3. **FaceGen geometry.** EGM read; head parts, hair and headgear morphed by FGGS/FGGA.
4. **TRI blend shapes and a facial player.** Named targets on the head parts; blinks.
5. **LIP decoding and lip sync.** Census of the `.lip` header and records over all 60,702
   files before a decoder; then lines drive the facial player.
6. **FaceGen texture.** EGT read; FGTS skin per NPC.

## Open

- What the `.lip` records are (keys, channels, timing) and how channels name TRI targets.
- How HCLR combines with the hair texture.
- Whether Head (0x1) or Hair (0x2) without Hat should hide the hair (helmets, masks). Only
  Hat is acted on; no source found. Every cowboy hat carries Hair and Hat, so "Hair hides
  hair" alone would leave them bald.
- FaceGen morph cost per NPC.
- EGT size and cost per NPC; whether textures are built for every loaded NPC or only near ones.
- What blinks: a KF, a timer, or the TRI targets directly.
