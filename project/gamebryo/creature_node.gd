class_name CreatureNode
extends GamebryoActor

## Issue #52 chunk 5: thin leaf for a placed CREA. No fields of its own yet
## (same "genuinely thin leaf" shape as NPCNode).
##
## Deliberately does NOT get automatic skeleton/body-mesh wiring from
## GamebryoObjectRegistry._build_creature(), unlike NPCNode -- a real,
## confirmed gap, not an oversight: CREA.MODL only ever points at a
## bone-only Skeleton.nif (confirmed real against creatures\NVRaven\
## Skeleton.nif: 0 skin entries, same shape as the human skeleton.nif), and
## the real body mesh (creatures\NVRaven\nvraven.nif, confirmed to carry
## real skin data whose bone names resolve against that skeleton) is only
## discoverable by a same-folder file-naming CONVENTION -- unlike RACE's
## own explicit ESM-declared INDX-tagged part list for NPC_. Wiring
## automatic resolution here would mean guessing a per-creature filename
## rule from a single confirmed sample rather than a real ESM structure;
## left as a follow-up once that convention (or a better one) is confirmed
## across more than one real creature.
