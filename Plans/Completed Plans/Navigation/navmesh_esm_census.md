# NAVM ESM census

## Scope and method

Read every record in the shipped official master files and count `NAVM` and
`NAVI` record types. For each `NAVM`, read its `DATA` subrecord counts. For
the interior/exterior split, classify a NAVM as exterior when the `CELL`
FormID stored in its `DATA` subrecord resolves to a CELL containing `XCLC`.

No ESPs, mods, generated data, NIFs, or runtime objects are included.

## Record totals

| Master | NAVI | NAVM |
|---|---:|---:|
| FalloutNV.esm | 1 | 4,771 |
| DeadMoney.esm | 1 | 146 |
| HonestHearts.esm | 1 | 585 |
| OldWorldBlues.esm | 1 | 346 |
| LonesomeRoad.esm | 1 | 290 |
| GunRunnersArsenal.esm | 1 | 1 |
| **Total** | **6** | **6,139** |

`CaravanPack.esm`, `ClassicPack.esm`, `MercenaryPack.esm`, and
`TribalPack.esm` contain zero `NAVI` and zero `NAVM` records.

## NAVM DATA totals

| Master | Vertices | Triangles | Edge links | Cover triangles | Door links |
|---|---:|---:|---:|---:|---:|
| FalloutNV.esm | 500,693 | 674,700 | 94,543 | 15,791 | 1,100 |
| DeadMoney.esm | 17,414 | 19,803 | 1,092 | 4,952 | 75 |
| HonestHearts.esm | 49,842 | 67,583 | 9,304 | 8,979 | 47 |
| OldWorldBlues.esm | 34,071 | 41,806 | 3,512 | 6,647 | 93 |
| LonesomeRoad.esm | 19,231 | 22,737 | 1,702 | 3,788 | 50 |
| GunRunnersArsenal.esm | 5 | 3 | 0 | 0 | 0 |
| **Total** | **621,256** | **826,632** | **110,153** | **40,157** | **1,365** |

Largest single NAVM records:

| Master | Vertices | Triangles |
|---|---:|---:|
| FalloutNV.esm | 1,211 | 1,275 |
| DeadMoney.esm | 766 | 945 |
| HonestHearts.esm | 715 | 960 |
| OldWorldBlues.esm | 730 | 873 |
| LonesomeRoad.esm | 904 | 1,083 |
| GunRunnersArsenal.esm | 5 | 3 |

## Owning CELL split

| Master | Exterior NAVM | Exterior triangles | Interior NAVM | Interior triangles |
|---|---:|---:|---:|---:|
| FalloutNV.esm | 4,260 | 608,609 | 511 | 66,091 |
| DeadMoney.esm | 111 | 13,855 | 35 | 5,948 |
| HonestHearts.esm | 562 | 59,987 | 23 | 7,596 |
| OldWorldBlues.esm | 293 | 30,297 | 53 | 11,509 |
| LonesomeRoad.esm | 262 | 17,988 | 28 | 4,749 |
| GunRunnersArsenal.esm | 0 | 0 | 1 | 3 |
| **Total** | **5,488** | **730,736** | **651** | **95,896** |

The `FalloutNV.esm` exterior NAVMs contain 440,028 vertices, 608,609
triangles, 94,467 edge links, and 488 door links. Its interior NAVMs contain
60,665 vertices, 66,091 triangles, 76 edge links, and 612 door links.

## Subrecord layout observed in FalloutNV.esm

Every one of the 4,771 NAVM records contains these subrecords:

| Subrecord | Records | Observed item size |
|---|---:|---:|
| `NVER` | 4,771 | 4 bytes |
| `DATA` | 4,771 | 24 bytes |
| `NVVX` | 4,771 | 12 bytes per vertex |
| `NVTR` | 4,771 | 16 bytes per triangle |
| `NVGD` | 4,771 | 40-byte header plus 2-byte grid entries |

Optional subrecords in FalloutNV.esm:

| Subrecord | Records |
|---|---:|
| `NVEX` | 4,105 |
| `NVCA` | 1,659 |
| `NVDP` | 687 |

The single FalloutNV.esm `NAVI` record contains one `NVER`, 4,771 `NVMI`
entries, and 4,771 `NVCI` entries.

## xEdit schema labels

The local xEdit FNV definition labels:

| Record/subrecord | Label |
|---|---|
| `NAVI` | Navmesh Info Map |
| `NAVM` | Navmesh |
| `NVMI` | Navmesh Info |
| `NVCI` | Navmesh Connections |
| `NVVX` | Vertices |
| `NVTR` | Triangles |
| `NVCA` | Cover Triangles |
| `NVDP` | Door Links |
| `NVGD` | Navmesh Grid |
| `NVEX` | Edge Links |

`NAVM.DATA` is defined as `Cell`, `Vertex Count`, `Triangle Count`, `Edge
Link Count`, `Cover Triangle Count`, and `Door Link Count`.

`NVDP` entries are defined as `Door Ref`, `Triangle`, and two unused bytes.

## GSDocMitchellHouse

`CELL 0x00103DF9` (`GSDocMitchellHouse`) contains one NAVM:

| NAVM | Version | Vertices | Triangles | Edge links | Cover triangles | Door links |
|---|---:|---:|---:|---:|---:|---:|
| `0x00108724` | 11 | 118 | 123 | 0 | 0 | 1 |

Its `NVDP` entry contains `REFR 0x00103E61` and triangle `77`.

## Placed actor-record census

`ACHR` and `ACRE` are counted as record types. The base-type columns count
only records whose `NAME` FormID resolves within the same master file; they
therefore do not include references to bases supplied by an earlier master.

| Master | ACHR | ACHR resolving to local NPC_ | ACRE | ACRE resolving to local CREA |
|---|---:|---:|---:|---:|
| FalloutNV.esm | 3,386 | 3,386 | 2,999 | 2,999 |
| DeadMoney.esm | 27 | 23 | 190 | 173 |
| HonestHearts.esm | 246 | 242 | 185 | 169 |
| OldWorldBlues.esm | 115 | 112 | 273 | 254 |
| LonesomeRoad.esm | 180 | 176 | 145 | 129 |
| GunRunnersArsenal.esm | 3 | 0 | 12 | 0 |
| **Total** | **3,957** | **3,939** | **3,804** | **3,724** |

`FalloutNV.esm` contains 3,816 `NPC_` base records and 1,578 `CREA` base
records.

## Package-record census

`NPC_.PKID` is an ordered array of `PACK` FormIDs in the local xEdit schema.

| Master | PACK | NPC_ | NPC_ with one or more PKID | PKID entries |
|---|---:|---:|---:|---:|
| FalloutNV.esm | 4,163 | 3,816 | 3,073 | 7,376 |
| DeadMoney.esm | 144 | 34 | 19 | 79 |
| HonestHearts.esm | 367 | 170 | 167 | 597 |
| OldWorldBlues.esm | 72 | 100 | 78 | 125 |
| LonesomeRoad.esm | 142 | 102 | 93 | 244 |
| GunRunnersArsenal.esm | 0 | 0 | 0 | 0 |
| **Total** | **4,888** | **4,222** | **3,430** | **8,421** |

Every one of the 4,163 FalloutNV.esm `PACK` records contains `PKDT` and
`PSDT`. FalloutNV.esm contains 2,992 `CTDA` subrecords within its PACK
records.

FalloutNV.esm package `PKDT.Type` values, using the local xEdit labels:

| Type | Label | PACK records |
|---:|---|---:|
| 0 | Find | 81 |
| 1 | Follow | 132 |
| 2 | Escort | 12 |
| 3 | Eat | 317 |
| 4 | Sleep | 390 |
| 5 | Wander | 31 |
| 6 | Travel | 1,260 |
| 7 | Accompany | 14 |
| 8 | Use Item At | 26 |
| 9 | Ambush | 38 |
| 10 | Flee Not Combat | 15 |
| 12 | Sandbox | 753 |
| 13 | Patrol | 505 |
| 14 | Guard | 175 |
| 15 | Dialogue | 332 |
| 16 | Use Weapon | 82 |

The local xEdit schema labels `PACK` fields as follows:

| Field | Label |
|---|---|
| `PKDT` | General |
| `PLDT` / `PLD2` | Location 1 / Location 2 |
| `PSDT` | Schedule |
| `PTDT` / `PTD2` | Target 1 / Target 2 |
| `CTDA` | Conditions |

The local GECK package documentation states that an actor considers packages
in their listed order; a package is selected when its schedule is valid and
its conditions are met. The same documentation states that actors with `No
Low Level Processing` and Travel packages only travel while the player is
near.

## Sources

- `fresh_nv_copy/Data/*.esm`, read with a standalone C++ diagnostic linked to
  `native/src/esm/esm_file.cpp`.
- `enginedocs/xEdit/Core/wbDefinitionsFNV.pas`, NAVI/NAVM definition.
- `enginedocs/Geck/AI Packages Tab - GECK.html` and
  `enginedocs/Geck/Category_Packages - GECK.html`.
