# Head parts: brows, beards and eyepatches

An NPC's own head parts (NPC_ PNAM → HDPT) are built on its head with its FaceGen shape,
expressions and hair colour, as the race's head parts are. Follow-on to
[`Completed Plans/Actors/faces.md`](../Completed%20Plans/Actors/faces.md).

## Facts

From FalloutNV.esm (Python scan of every HDPT and NPC_ PNAM).

- 61 HDPT. 46 carry a MODL: brows (`EyebrowM`, `EyebrowF`, four `EyebrowOldMBeard*`), 39
  beards and `Eyepatch`. The other 15 (`BeardMix*`) have no MODL and name two or three other
  HDPTs in HNAM (`HeadPartBase.extra_parts`); each of those has a MODL and no HNAM.
- 26 HDPT carry MODS (alternate textures): the `Thin` / `Full` / `Circle` variants of one beard
  share a NIF and differ only by texture set (`BeardGoatee`, `BeardGoateeFull`,
  `BeardGoateeCircle` and `BeardGoateeThin` all use `BeardGoatee.nif`). MODS is read into
  `HeadPartBase.alternate_textures`; nothing in the project applies alternate textures yet.
- DATA (Playable) is set on the beards, not on the brows, `BeardFullOld`, the `*Old` beards or
  `Eyepatch`.
- PNAM is on 1,479 NPC_ (23 of them take traits from a template): one part on 1,204, two on
  240, three on 33, four on 2. `EyebrowM` on 677, `EyebrowF` on 432, `BeardThin` 85,
  `BeardFull` 58, `BeardMustacheThin` 51, `Eyepatch` 13; 55 of the 61 HDPT are named by some
  NPC_.
- `NpcBase.head_parts` holds PNAM's HDPTs; `NpcBase.get_model_parts` does not list them, so the
  actor node builds none.
- Doc Mitchell: `BeardMustacheCurly` and `EyebrowM`. Sunny Smiles: `EyebrowF`.
- Every shape of every HDPT NIF has an EGM that fits (`tests/servers/test_face_gen_server`'s
  census of HAIR, HDPT and RACE head-part NIFs). Beard and brow TRIs carry difference morphs
  (24 to 34), brows and `BeardSide` include `BlinkLeft` / `BlinkRight`.
- Beard shapes carry the Hair shader flag, so NifMaterialBuilder sends them to `PATH_HAIR` and
  `EsmActorNode._apply_hair_color` tints them with HCLR once they load (`BeardChinCurtain` is
  the material-path test's fixture). Brows and the eyepatch not checked.

## Shape (proposed)

- `NpcBase.get_model_parts` lists each PNAM HDPT with a MODL as a `head_part` part, and each
  `BeardMix` HDPT's extra parts in its place, from the trait source when the NPC takes traits
  from a template.
- The actor node attaches them as it does hair (the facial attachment, or skinned beside the
  head if a NIF is skinned) and tags them as head parts, so FaceGenServer morphs them and the
  facial player drives their blend shapes.
- MODS: the actor swaps the named shape's diffuse and normal for the TXST's, on its own copy of
  the material (as hair colour does).

## Build order

1. **Head parts with a model.** Brows, beards and the eyepatch built, morphed and tinted. Gate:
   Doc's curly moustache and brows on his face, following his face and blinking with it.
2. **BeardMix.** Extra parts in place of the mix record.
3. **Alternate textures.** MODS on head parts. Gate: an NPC with `BeardGoateeThin` and one with
   `BeardGoateeFull` look different.

## Open

- What MODS's 3D Index means (−1 on 7 HDPT entries, beside one with 0 for the same shape).
- Whether a hat hides beards or brows (no head slot covers them).
