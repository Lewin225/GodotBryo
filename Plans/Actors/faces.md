# Faces, hair, hats and lip sync

The parts of a humanoid's head the actor node does not yet build from data: each NPC's
FaceGen shape and skin, hair colour, hats that sit on the head and replace the hair, and
lip sync for spoken lines. Done before stage J (creatures). See `actors.md`.

## Facts

From FalloutNV.esm, the BSAs, `Fallout_default.ini` and the running actor node
(`_diag/diag_hat_placement`, scratch ESM and BSA scans, `native/tools/facegen_asset_census`,
`facegen_census`, `facegen_file_census`, `facegen_base_fit`, `facegen_facemod_fit`). File layouts follow the FaceGen SDK's file format
page (facegen.com/dl/sdk/doc/manual/fileformats.html) and every shipped file matches them.

### FaceGen records

- 3,814 of 3,816 NPC_ carry FGGS (50 floats, geometry symmetric), FGGA (30, geometry
  asymmetric) and FGTS (50, texture symmetric). `EsmServer` reads them into
  `NpcBase.face_gen` (`FaceGenData`); nothing applies them.
- FGGS is all zero on 782 NPC_ and FGTS on 789, mostly NPCs whose template supplies traits.
  No NPC_'s FGGS or FGTS equals its race's.
- An NPC_'s FGTS is an offset from its race's FGTS for its gender: the shipped facemods fit
  race + NPC FGTS on 2,908 of 2,989 NPCs (see Face textures), and fit FGTS minus the race's on
  none. FGGS is an offset too: in each of the 17 race and gender groups with 50 or more NPC_
  (non-zero FGGS), the NPC_ mean per coefficient is near zero (RMS 0.5 to 1.3) and 1.8 to 4.0
  from the race's (race values RMS 1.3 to 3.5; NPC_ spread 1.5 to 1.9).
- RACE PNAM (FaceGen main clamp) is 5.0 and UNAM (face clamp) 3.0 on all 22 races. Race + NPC
  FGGS components reach 25.2 and FGTS 14.6. Clamping race + NPC FGTS to 5 or 3 does not
  improve the facemod fit.
- RACE carries FGGS, FGGA and FGTS per gender after MNAM / FNAM, each followed by SNAM (u16,
  the same value for both genders). FGGA is zero on every race. TestQACaucasian is all zero.
- `RACE` PNAM / UNAM (FaceGen main and face clamps) are read into `RaceBase`; not used.
- ARMO and ARMA carry MODD (male model) and MOSD (female model), xEdit's "FaceGen Model
  Flags": Head 0x1, Torso 0x2, Right Hand 0x4, Left Hand 0x8. In FalloutNV.esm:
  - Head: 96 ARMO MODD, 26 ARMO MOSD, 5 ARMA (headgear, glasses, hoods);
  - Torso: 64 ARMO MODD, 83 ARMO MOSD (outfits);
  - hands: 15 + 12 ARMA each gender (gloves, spiked knuckles), 1 ARMO each gender
    (Pip-Boy glove).

### FaceGen files

- 275 EGM, 36 EGT and 49 TRI, all in `Fallout - Meshes.bsa`; no DLC or Update BSA ships any.
- **EGM** (`FREGM002`): u32 vertex count, symmetric mode count (50), asymmetric mode count
  (30), basis version (2001060901 on all 275), 40 reserved bytes; then per mode a float scale
  and vertex count x3 s16. Symmetric modes first. A vertex moves by the sum over modes of
  coefficient x scale x s16, symmetric modes with FGGS and asymmetric with FGGA. The deltas
  are in NIF units (70 per metre).
- **EGT** (`FREGT003`): u32 rows, columns, symmetric mode count (50), asymmetric mode count
  (0 on all 36), basis version (81); then per mode a float scale and three s8 planes (R, G,
  B), rows x columns each. A texel moves by the sum of FGTS x scale x s8.
  - heads: 256 x 256 (the diffuse is 1024 x 1024); human eyes 64 x 64, female eyes 32 x 32;
  - upper bodies, hands and `body.egt`: 32 x 32.
- **TRI** (`FRTRI003`): ten s32 (V, T, Q, LV, LS, X, ext, Md, Ms, K), 16 reserved bytes,
  then (V + K) float vertices, triangles, quads, labels, UVs, Md difference morphs (name,
  float scale, V x3 s16) and Ms statistical morphs (name, count L, L vertex indices; the L sum
  to K).

### Pairing with meshes

- An EGM pairs with the NIF of the same stem. Its vertex count is the TRI's V + K, not the
  NIF's: `headhuman.egm` has 1,449 against the NIF's 1,211 (K = 238), an eye's 245 against 49
  (K = 196). The first V EGM vertices are the NIF's, in NIF order; the K after them are the
  TRI's extra vertices.
- TRI base vertices equal the NIF's to within 2e-6 for adult eyes, mouth, teeth, tongue,
  brows, eyepatch and most beards. Head NIFs differ from their TRI base by 0.09 to 0.84 units,
  child mouth, teeth and tongue NIFs by about 1.7, and five beards by 0.09 to 0.42
  (`facegen_base_fit`, scratch scans):
  - old, ghoul and child heads: 25 vertices, at most 0.11 units;
  - `headhuman`: 675 vertices (mean 0.08, max 0.53); `headfemale`: 1,087 (mean 0.21, max
    0.84). Least squares onto the 80 EGM modes leaves the same residual, so the difference is
    not a FaceGen morph: the NIFs were edited after the TRI was made;
  - on the head's statistical-morph vertices the NIF is off the TRI by up to 0.27 (blinks) and
    0.84 (`headfemale` squints), while those morphs move vertices 0.12 to 1.38;
  - child mouth, tongue and lower teeth NIFs sit about (0, 1.4, 1.0) units from the TRI, plus
    up to 1.1 of shape change.
- Child FaceGen files are adult copies: `headchild.egm` is byte-identical to `headhuman.egm`,
  `tonguehumanchild.tri` / `.egm` to `tonguehuman`'s, `mouthhumanchild.tri` / `.egm` to
  `mouthhuman`'s, `teethlowerhumanchild.egm` to `teethlowerhuman.egm`.
- So the EGM and TRI apply to a NIF as offsets: EGM deltas and TRI difference morphs are
  deltas already; a statistical morph's offset for a vertex is its extra vertex minus that
  vertex's TRI base position.
- Hair EGMs are `<stem>hat.egm` and `<stem>nohat.egm`, one per hair NIF shape named `Hat` and
  `NoHat`.
- 220 EGMs match one shape of their NIF by vertex count and 16 hair EGMs match both
  (Hat and NoHat have equal counts), so the pairing is by shape name, not count. 20 have no
  NIF of the same stem (mostly DLC headgear). Gambler pillbox, mask and NV rebreather EGMs do
  not match their NIF's vertex count.
- NifServer keeps NIF vertex order in each delivered mesh, also across BSDismember
  partitions, so EGM indices apply to its meshes. Delivered meshes are shared by every
  instance; a morphed one is per NPC.
- RACE body INDX 3 names the upper-body EGT (`Characters\_Male\UpperBodyHumanMale.egt`,
  `UpperBodyHumanFemale.egt`, `UpperBodyChild.egt`, `UpperBodyChildFemale.egt`).
  `EsmFile::get_race_body_parts` drops it because it is not a `.nif`. `FalloutNV.exe` holds
  `Characters\_Male\UpperBodyHumanMale.egt` and `UpperBodyHumanFemale.egt` as strings.
- Nothing names a hand EGT, `body.egt`, or the old and ghoul upper-body EGTs: no record, no
  hand or body NIF (which name only their `Hand*.dds`, `_n` and `_sk` textures), and no
  string in `FalloutNV.exe`.

### TRI morphs

- `headhuman.tri`: 38 difference morphs (phonemes `Aah` .. `W`, brows, moods, `Pained`,
  `CombatAnger`) and 8 statistical morphs: `BlinkLeft` (20 vertices), `BlinkRight` (20),
  `SquintLeft` (35), `SquintRight` (41), `LookDown` (39), `LookLeft` (0), `LookRight` (0),
  `LookUp` (83).
- Eye TRIs have only statistical morphs: `LookDown`, `LookLeft`, `LookRight`, `LookUp`, 49
  vertices each (K = 196).
- Mouth: 5 difference morphs. Beards and brows: difference morphs only (brows carry
  `BlinkLeft` / `BlinkRight` as difference morphs).
- A statistical morph moves its listed vertices to the TRI's extra vertices, in order. The EGM
  morphs those extra vertices too, so blinks and eye looks follow each NPC's face.

### Face textures

- `textures\characters\facemods\<esm>\<form id>_0.dds`: 2,989 for FalloutNV.esm (in
  `Fallout - Textures.bsa`), 11 HonestHearts.esm, 34 OldWorldBlues.esm. Every one is
  256 x 256 DXT1 with 9 mips, named by the NPC_'s file-local form ID. No other suffix than
  `_0` exists, so there are none for bodies or hands.
- They are mid-grey offset maps (Doc Mitchell, Sunny Smiles, Boone: channel means 109 to 122,
  range 90 to 148), not face textures. The race head diffuse is 1024 x 1024 DXT1.
- Fit of every FalloutNV.esm facemod against the race head EGT, EGT rows flipped
  (`facegen_facemod_fit`, DXT1 decoded, one fit per channel):
  facemod ~ 126.3 + 0.46 x sum((race FGTS + NPC FGTS) x scale x s8). Medians: r 0.92, slope
  0.457 (deciles 0.39 to 0.50), intercept 126.3, residual RMS 1.6 levels. Race + NPC is the
  best of the tested coefficients for 2,908 NPCs (NPC alone 76, race alone 5); for the 137
  NPCs with zero FGTS the race alone gives r 0.87. Three facemods are flat (Narrator,
  Testacles, NelsonNCRTrooperHostage3).
- In `Shaders\shaderpackage019.sdp` (u32 100, u32 count, u32 size, then per shader a
  256-byte name, u32 size and D3D9 bytecode), the pixel shaders `SKIN2000`-`2003`,
  `SKIN2010`-`2012`, `SM3008`, `SM3009`, `SM3020`, `SM3021` and their `SM3LL` variants sample
  `BaseMap`, `NormalMap`, `FaceGenMap0` and `FaceGenMap1`; `SLS1017`-`1020` sample `FaceGenMap`
  and `FaceGenMap2`. The constant names do not say how the maps combine.
- `FalloutNV.exe` holds the path patterns `data\Textures\Characters\FaceMods\%s\%08X_%i.dds`,
  `...\M%08X_%08X_%i.dds` and `...\F%08X_%08X_%i.dds`. No file of the `M` / `F` patterns
  ships.
- FalloutNV.esm NPC_ by facemod:

  | | facemod | none |
  |---|---:|---:|
  | own traits, FGTS non-zero | 2,826 | 82 |
  | own traits, FGTS zero | 119 | 45 |
  | template traits, FGTS non-zero | 43 | 74 |
  | template traits, FGTS zero | 1 | 626 |

  DeadMoney.esm and LonesomeRoad.esm ship none.
- `Fallout_default.ini`: `bFaceGenTexturing=1`, `bLoadFaceGenHeadEGTFiles=0`,
  `bUseFaceGenHeads=1`, `bUseMultiThreadedFaceGen=1`. With `bLoadFaceGenHeadEGTFiles=0` the
  game does not build a head texture from the EGT; community reports tie NPCs without a
  facemod to face and body colour mismatches under that setting.

### Cost

- GDScript, one head (80 modes x 1,211 vertices): 4.4 ms as a `Vector3` loop, 5.9 ms as a flat
  float loop. An NPC's FaceGen meshes (head, eyes, mouth, teeth, tongue, hair Hat and NoHat,
  beard, brows, headgear) are about 4,000 vertices, so about 15 ms.
- A head facemod from the EGT is 256 x 256 x 3 x 50 multiply-adds (9.8 M); a 32 x 32 body EGT
  is 154 K.

### Legacy

- The legacy assembly (`project/gamebryo/mesh_resolver.gd`: `_parse_facegen_egm`,
  `_apply_facegen_geometry`, `_apply_tri_morph_targets`) applied FGGS/FGGA through the EGM to
  head part geometry and turned TRI difference morphs into blend shapes. It built no
  statistical morphs (no blinks or eye looks) and no EGT/FGTS textures. `native/src/tri/`
  (`TriReader`) is still built and registered. `FaceGenData` and `FaceGenGeometryAsset` live
  in `project/gamebryo/`.

### Hair

- HNAM on 2,767 NPC_, HCLR on all 3,816 (698 distinct colours; the commonest 4b3219, on
  1,031). `EsmActorNode._apply_hair_color` tints the hair material path with it
  (`linear_to_srgb`, as XEMI). Beards (PNAM head parts) are not loaded yet.
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

- **FaceGen coordinates.** An NPC's effective FGGS, FGGA and FGTS are its race's (for its
  gender) plus its own.
- **FaceGen geometry.** `FaceGenServer` (done): native `EgmReader`; each head part, eye and
  hair shape is morphed once at load by the effective FGGS/FGGA as offsets on the NIF
  vertices, delivered by callback, cached by (mesh, EGM, values). Headgear morphs are
  [`headgear_facegen.md`](headgear_facegen.md).
- **TRI expressions.** Difference morphs and statistical morphs (blinks, squints, eye looks)
  become blend shapes as offsets from the TRI base; statistical offsets come from the
  EGM-morphed extra vertices, so they are per NPC.
- **Face texture.** The NPC's shipped facemod, where one exists, on the head through the
  material path the skin shader needs. NPCs without one get the same map built from the
  effective FGTS and the head EGT (126 + 0.46 x sum), natively.
- **Body tint.** The race's upper-body EGT (RACE body INDX 3) with the effective FGTS on the
  upper body; hands left untinted until something names their EGT.
- **Hair colour.** HCLR tints the hair material path (done); beards and brows once PNAM head
  parts load.
- **Hats.** Headgear hangs from a HeadAnims attachment under the skeleton (done).
  `wearing_hat` is true while equipment covers the Hat slot (0x400), showing the hair's Hat
  variant (done). Attachment chosen by biped slots rather than path.
- **Lip sync.** A decoder for `.lip` (native, beside `TriReader`), TRI targets as blend
  shapes on the head, mouth, teeth and tongue, and a facial player that DialogueServer starts
  with each line's voice. Blinks and KF face tracks run on the same player.

## Build order

1. **Hats.** Done: `wearing_hat` from the equipped headgear's biped slots; headgear on the
   hair's attachment.
2. **Hair colour.** Done for hair; beards and brows wait on PNAM head parts.
3. **FaceGen geometry.** Done for head parts, eyes and hair (`FaceGenServer`).
4. **Facemods.** Shipped facemod on the head; combination with the base texture decided by
   a visual check against the game.
5. **TRI blend shapes and a facial player.** Difference and statistical morphs; blinks.
6. **LIP decoding and lip sync.** Census of the `.lip` header and records over all 60,702
   files before a decoder; then lines drive the facial player.
7. **EGT synthesis.** Facemods for NPCs without one; upper-body tint.

## Open

- How `FaceGenMap0` / `FaceGenMap1` combine with `BaseMap` (2x modulate or signed add), and
  what `FaceGenMap1` holds. The shader bytecode answers it but reading it is disassembling
  engine code; the alternative is comparing renders with game screenshots.
- Whether to build head maps for NPCs without a facemod. The shipped INI does not
  (`bLoadFaceGenHeadEGTFiles=0`); building them matches `=1` instead.
- The facemod slope 0.46 rather than 0.5.
- Which EGT, if any, tints hands; nothing names one.
- What the `M%08X_%08X_%i` / `F%08X_%08X_%i` facemod patterns are for (no files ship).
- Whether Gamebryo recomputes normals after the EGM morph.
- What the `.lip` records are (keys, channels, timing) and how channels name TRI targets.
- Whether Head (0x1) or Hair (0x2) without Hat should hide the hair (helmets, masks). Only
  Hat is acted on; no source found. Every cowboy hat carries Hair and Hat, so "Hair hides
  hair" alone would leave them bald.
- What blinks: a KF, a timer, or the TRI targets directly.
