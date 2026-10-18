# Headgear FaceGen

Headgear whose model carries the FaceGen Head flag is morphed to the wearer's face through its
EGM, as head parts are. Separate from [`faces.md`](faces.md), which does not depend on it.

## Facts

- ARMO and ARMA carry MODD (male model) and MOSD (female model), xEdit's "FaceGen Model Flags":
  Head 0x1, Torso 0x2, Right Hand 0x4, Left Hand 0x8. Head in FalloutNV.esm: 96 ARMO MODD,
  26 ARMO MOSD, 5 ARMA (headgear, glasses, hoods). Neither is read yet.
- 20 EGMs have no NIF of the same stem (mostly DLC headgear). The Gambler pillbox, mask and NV
  rebreather EGMs do not match their NIF's vertex count.
- Unskinned headgear is attached by `ActorEquipment._attach_unskinned` under the skeleton,
  without a morph.
- `FaceGenServer.request_morph` takes any NifServer mesh with its model path and shape name;
  `egm_path_for` gives `<stem>.egm`.
- An NPC's offsets are up to about 8 mm (Doc Mitchell's head: 8.4 mm), so an unmorphed hat
  can clip or gap by that much at the brim.

## Shape

- **Records.** EsmServer reads MODD / MOSD into the ARMO and ARMA resources as flags fields.
  Own task: census, test, README.
- **Equipment.** `ActorEquipment` asks `FaceGenServer` for a morph of each shape of a model
  whose flags for the wearer's gender include Head, and swaps the mesh on delivery before
  committing the equipment.

## Build order

1. Census of MODD / MOSD against the EGMs beside each model: how many Head-flagged models have
   an EGM that fits each shape, and which do not.
2. Read MODD / MOSD (EsmServer).
3. Morph Head-flagged headgear in `ActorEquipment`; extend `tests/test_actor_headgear`.

## Open

- What the game does with a Head-flagged model whose EGM does not fit (pillbox, mask,
  rebreather).
