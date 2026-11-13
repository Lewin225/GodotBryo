# Unlit shapes (PATH_UNLIT)

Every `BSShaderNoLightingProperty` shape in the BSAs' 20,542 NIFs: 7,936 shapes in 3,512 files.
Each shape is a row of `unlit_shapes.csv`: file, shape, diffuse texture, NiAlphaProperty flags (empty when it has
none), shader flags1 and flags2. Source: `native/tools/alpha_survey --dump meshes` (all NIFs).

Checked in game on the unlit shader and found to be the correct behaviour: light shafts, muzzle
flashes, Mr. Gutsy jets, the missile launcher explosion's sparks, the Strip's signs and lights.
The casino game tables are not in the game yet.

## By alpha

| NiAlphaProperty | Shapes |
|---|---|
| blend mix | 3,246 |
| blend add | 1,967 |
| none (opaque) | 1,301 |
| blend multiply | 749 |
| blend add + test | 334 |
| test only | 188 |
| blend mix + test | 123 |
| blend, other function | 19 |
| blend, other function + test | 5 |
| blend multiply + test | 4 |

## By folder (top 40)

| Folder | Shapes |
|---|---|
| dlc05\effects | 750 |
| dlc05\dungeons | 672 |
| terminals\nv_caravan | 481 |
| dlc03\effects | 289 |
| nvdlc03\dungeons | 274 |
| effects\ambient | 243 |
| effects\nv | 230 |
| architecture\strip | 220 |
| architecture\urban | 181 |
| terminals\nv_roulette | 168 |
| nvdlc04\dungeons | 145 |
| dungeons\enclave | 128 |
| dlcanch\dungeons | 127 |
| dlcpitt\dungeons | 124 |
| nvdlc01\effects | 116 |
| dungeons\vaultruined | 115 |
| nvdlc03\clutter | 112 |
| nvdlc04\effects | 99 |
| dlcanch\effects | 91 |
| dungeons\utility | 87 |
| nvdlc03\effects | 87 |
| vehicles\b29 | 86 |
| nvdlc01\dungeons | 82 |
| dlc04\effects | 79 |
| dungeons\office | 79 |
| nvdlc03\architecture | 76 |
| nvdlc03\creatures | 70 |
| dungeons\vault | 68 |
| clutter\consoles | 60 |
| nvdlc01\clutter | 56 |
| nvdlc05\weapons | 56 |
| nvdlc03\weapons | 55 |
| dungeons\nvlucky38 | 53 |
| effects\forcefieldfx | 53 |
| dlc04\dungeons | 52 |
| effects\muzzleflashes | 50 |
| nvdlc04\weapons | 46 |
| terminals\nv_blackjack | 46 |
| dungeons\industrial | 43 |
| nvdlc04\clutter | 42 |

Not yet checked in game, by what they are: the casino game tables (`terminals\nv_caravan`,
`nv_roulette`, `nv_blackjack`; not in the game yet), Mothership
interiors and effects (`dlc05`), AO fades in architecture (`textures\shared\shadefade01.dds`, 241),
force fields, holograms, consoles, the B-29.
