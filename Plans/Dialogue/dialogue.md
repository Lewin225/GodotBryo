# Dialogue (DIAL / INFO)

**Status: planned; stage A next.**

Parse DIAL topics and their INFO responses into typed resources, choose the INFO an actor says
through the condition evaluator, and run its result scripts. Two consumers: scripted speech
(`SayTo`, `Say`), which carries VCG01's opening, and the player's conversation menu. Done when a
new game plays Doc Mitchell's opening through to the vigor tester and the Rorschach test reaches
VCG01 stage 85.

## Facts

FalloutNV.esm census (`native/tools/dialogue_census.cpp`, every DIAL and INFO):

**Topics (DIAL).** 18,215, of which 9,493 have INFOs and 8,722 none. 138 name more than one
quest (QSTI). DATA type: Topic x16,350, Conversation x1,605, Combat x43, Persuasion x3,
Detection x12, Service x9, Miscellaneous x3, Radio x190. DATA flags: Top-level (0x02) x2,283,
Rumors (0x01) x1, none x15,921; 10 have no flags byte. PNAM priority: 50 on 17,230, the rest
spread from 5 to 100; 10 have none.

**INFOs.** 23,247, every one inside its topic's child GRUP (`get_child_records` agrees with file
order for all 18,215 topics). No INFO has PNAM (previous INFO), so an INFO's place in its topic is
its file order. DATA is always 4 bytes. DATA type differs from the topic's type on 803 INFOs.
Every INFO has QSTI; on 43 it is not among its topic's QSTI.

| DATA flags 1 | INFOs | | DATA flags 2 | INFOs |
|---|---|---|---|---|
| 0x01 Goodbye | 8,275 | | 0x01 Say Once a Day | 105 |
| 0x02 Random | 6,656 | | 0x02 Always Darken | 6 |
| 0x04 Say Once | 3,498 | | 0x10 Low Intelligence | 28 |
| 0x08 Run Immediately | 554 | | 0x20 High Intelligence | 20 |
| 0x10 Info Refusal | 48 | | | |
| 0x20 Random End | 860 | | | |
| 0x80 Speech Challenge | 3 | | | |

| Content | INFOs |
|---|---|
| Responses (TRDT + NAM1): 1 | 19,025 |
| 2 to 31 | 4,213 |
| none | 9 |
| Conditions (CTDA) | 22,471 (776 have none) |
| Begin script (SCTX before NEXT) | 2,825 |
| End script (SCTX after NEXT) | 4,531 (989 have both) |
| Link To (TCLT, choices after it) | 6,348 |
| Link From (TCLF) | 645 |
| Follow Up (TCFU) | 1,107 |
| Add Topics (NAME) | 420 |
| Prompt (RNAM, the player's line) | 1,411 |
| Speaker (ANAM) | 11,355 |
| Actor value / perk (KNAM) | 1,097 |

**Speakers.** 17,865 INFOs have a GetIsID condition and 2,880 a GetIsVoiceType; both run on the
subject (GetIsID 18,424 of 18,568, GetIsVoiceType 16,832 of 16,833), so the subject is the
speaker. ANAM names an NPC_ (10,343) or CREA (1,012). On 11,154 ANAM INFOs a subject GetIsID
also names a speaker, the ANAM speaker on 10,896; 201 have ANAM and no GetIsID.

**VCG01's opening** (quest and INFO scripts, dumped from FalloutNV.esm): the quest's stages set a
timer (`VCG01.fTimer`), and the quest script advances the stage when it runs out. Stages speak
with `DocMitchellREF.SayTo player VCG01Intro`, and each VCG01Intro INFO's end script either sets
the next stage or calls SayTo again. VCG01Intro is a Conversation topic of 15 INFOs, each flagged
Say Once (one also Goodbye) with a single `GetIsID DocMitchell == 1` condition, so each SayTo says
the first INFO in file order not yet said. Stage 10 calls `GetPlayerName` and stage 36 `ShowRaceMenu`. After the
vigor tester, VCG01DocReactions picks a line by `GetQuestVariable VCG01 5` (the tested SPECIAL)
and `GetIsSex`; its end scripts set stage 75. The Rorschach test is a GREETING INFO whose TCLT
links offer VCG01DocMitchellTopic000-005, each linking onward, ending in stage 85.

**Script use.** Across all script sources: SayTo x760, Say x147, StartConversation x149,
AddTopic x11. None is registered yet, nor GetIsVoiceType, GetInFaction, GetTalkedToPC,
GetPlayerName or ShowRaceMenu.

**Voice files.** One INFO checked: `Fallout - Voices1.bsa` holds
`sound\voice\falloutnv.esm\maleuniquedocmitchell\vcg01_vcg01intro_00104bee_1.ogg` and a `.lip`
of the same name: voice type EDID, then quest EDID, topic EDID, INFO FormID and response
number. The archive holds 52,896 `.ogg`, 52,581 `.lip` and 40 `.wav`.

## Design

**Authored: `DialogueTopicBase` and `DialogueInfoBase`.** DIAL and INFO become EsmBase
resources through `TYPE_TO_BASE`, each field described per AGENTS.md "Describing record fields".
A topic holds its type, flags, priority, quests and its INFOs in file order. The order comes from
the record index, which lists records in file order; an INFO follows its DIAL. An INFO holds its
quest, DATA type and flags, responses (`DialogueResponse`: emotion, response number, text, speaker
and listener idles), conditions, Link To / Link From / Follow Up / Add Topics, prompt, speaker,
KNAM, and its begin and end script sources. NPC_ and CREA gain their VTCK voice type.

**Runtime: `DialogueServer`, an autoload.** It holds dialogue state and nothing authored: INFOs
said (for Say Once and Say Once a Day), whether each actor has talked to the player, and topics
added to the player (NAME, AddTopic). It chooses an INFO:

```gdscript
DialogueServer.choose_info(topic: DialogueTopicBase, speaker: EsmReference, listener: EsmReference) -> DialogueInfoBase
```

It returns the first INFO in the topic's file order that its quest makes available, that is not
spent by Say Once, and whose conditions pass, with the speaker as subject and the listener as
target. Random INFOs choose among consecutive available Random INFOs.

**Saying an INFO.** A `DialogueLine` runs one INFO: the begin script runs, each response shows for
its duration, then the end script runs, and the INFO is marked said. Result scripts run on the
speaker. A response's duration is its voice file's length. With no voice file, it is estimated
from the text.

**Scripted speech.** `SayTo target topic` and `Say topic` choose an INFO and run its line with
subtitles on the player's HUD, without a menu. `StartConversation` opens the conversation menu.

**Conversation menu.** A `DialogueSession` on the player, like `TerminalSession`. Activating an
actor says its GREETING INFO. Choices after an INFO are its Link To topics if it has any.
Otherwise they are the top-level topics and the player's added topics that have an available INFO
for this speaker. Each choice shows its INFO's prompt, or else the topic's name. A Goodbye INFO
ends the conversation.

## Stages

Each stage has a gate; a later stage does not start on an unmet gate.

| Stage | Work | Gate |
|---|---|---|
| A. Resources | `DialogueTopicBase`, `DialogueInfoBase`, `DialogueResponse`; the topic → INFO order from the record index; NPC_/CREA VTCK; `dialogue_census.cpp` extended with a voice-file census (every response's path, from its speaker's voice types). | `test_esm_server` asserts the census totals (topics, INFOs, responses, conditions, scripts, links) field for field against the raw subrecords; the voice census resolves every VCG01 response. |
| B. Choosing | `DialogueServer.choose_info()`, said state, Random; GetIsVoiceType, GetIsSex, GetInFaction, GetTalkedToPC. | VCG01Intro yields its 15 INFOs in file order as each is said; VCG01DocReactions picks by SPECIAL and sex; a GREETING picks per speaker. |
| C. Scripted speech | `DialogueLine`; SayTo, Say; HUD subtitles; response durations from voice files; GetPlayerName and ShowRaceMenu complete at once. | A headless test steps a new game from VCG01's start through to stage 55; a play check shows the subtitles. |
| D. Conversation | `DialogueSession`: activating an actor, GREETING, Link To choices, topic list, prompts, Goodbye; StartConversation, AddTopic. | The Rorschach test runs to stage 85 in a test and in play. |
| E. Voice | Play each response's `.ogg` at the speaker. | Doc Mitchell's opening is heard in play. |
| F. Coverage | Re-run `diag_condition_coverage` with INFO evaluated today; list the next functions. | Nothing to pass. |

## Unverified

- An INFO is available only while its QSTI quest runs.
- The choice order: first passing INFO in file order, with no quest or topic priority between
  INFOs of one topic.
- Random and Random End: choosing among a run of consecutive Random INFOs.
- Say Once is global per INFO, not per speaker.
- Result scripts run with the speaker as the calling reference.
- The topic list: top-level topics plus added topics, ordered by topic priority.
- The response duration when there is no voice file.
- The voice path for every INFO; checked on one.
- The 803 INFOs whose type differs from their topic's; the 43 whose quest is not among their
  topic's; DIAL Added Quests' shared INFOs (INFC/INFX).
- What ANAM decides, beyond matching a GetIsID speaker on 10,896 INFOs.

## Out of scope

- Lip sync, facial animation, speaker and listener idles, and the dialogue camera.
- Speech challenges (KNAM, DNAM) beyond showing the choice, barter and other services.
- Combat, detection and miscellaneous barks (types 2, 4, 6), which need AI; radio (type 7).
- The name and race menus, which stage C completes at once.
