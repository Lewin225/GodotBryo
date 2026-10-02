# Dialogue (DIAL / INFO)

**Status: stages A-D done; voice plays non-positionally.**

Parse DIAL topics and their INFO responses into typed resources, choose the INFO an actor says
through the condition evaluator, and run its result scripts. Two consumers: scripted speech
(`SayTo`, `Say`), which carries VCG01's opening, and the player's conversation menu. Done when a
new game plays Doc Mitchell's opening through to the vigor tester, and the Rorschach test,
started as its trigger script starts it, reaches VCG01 stage 85.

## Facts

FalloutNV.esm census (`native/tools/dialogue_census.cpp`, every DIAL, INFO, QUST, NPC_, CREA and
TACT):

**Topics (DIAL).** 18,215, of which 9,493 have INFOs and 8,722 none. 138 name more than one
quest (QSTI). DATA type: Topic x16,350, Conversation x1,605, Combat x43, Persuasion x3,
Detection x12, Service x9, Miscellaneous x3, Radio x190. DATA flags: Top-level (0x02) x2,283,
Rumors (0x01) x1, none x15,921; 10 have no flags byte. PNAM priority: 50 on 17,230, the rest
spread from 5 to 100; 10 have none.

**INFOs.** 23,247, every one inside its topic's child GRUP (`get_child_records` agrees with file
order for all 18,215 topics). No INFO has PNAM (previous INFO). DATA is always 4 bytes. DATA type
differs from the topic's type on 803 INFOs. Every INFO has QSTI; on 43 it is not among its
topic's QSTI.

**Quest order within a topic.** 67 topics hold INFOs of two or more quests. In 29 of them a
quest's INFOs are not contiguous (GREETING interleaves over 100 quests), and in 47 the file order
is not in descending quest priority. File order alone therefore cannot be the choice order across
quests.

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
| Begin script (SCTX before NEXT) | 2,827 (2 are only `;`) |
| End script (SCTX after NEXT) | 4,544 (13 are only `;`; 990 INFOs have both) |
| Link To (TCLT, choices after it) | 6,348 |
| Link From (TCLF) | 645 |
| Follow Up (TCFU) | 1,107 |
| Add Topics (NAME) | 420 |
| Prompt (RNAM, the player's line) | 1,411 |
| Speaker (ANAM) | 11,355 |
| Actor value / perk (KNAM) | 1,097 |

**Speakers and listeners.** 17,865 INFOs have a GetIsID condition and 2,880 a GetIsVoiceType;
both run on the subject (GetIsID 18,424 of 18,568, GetIsVoiceType 16,832 of 16,833), so the
subject is the speaker. Conditions on the listener run on the target: VCG01DocReactions tests
`GetIsSex` on the target, the player. ANAM names an NPC_ (10,343) or CREA (1,012). On 11,154 ANAM
INFOs a subject GetIsID also names a speaker, the ANAM speaker on 10,896; 201 have ANAM and no
GetIsID.

**Voice types, sex and factions.** Every NPC_ (3,816) has VTCK; CREA 1,045 of 1,578; no TACT
has VTCK, whose voice type is VNAM (xEdit `wbDefinitionsFNV.pas`). SNAM factions: 14,625 on
NPC_ and CREA, all 8 bytes, a FACT FormID and a signed rank (0 on 14,566, 1-3 on the rest).
xEdit's shared definitions (`wbDefinitionsCommon.pas`, TES5Edit branch dev-4.1.6) give the ACBS
template flags as Traits 0x01, Stats 0x02, Factions 0x04, Actor Effect List 0x08, AI Data 0x10,
AI Packages 0x20, Model/Animation 0x40, Base Data 0x80, Inventory 0x100, Script 0x200; the
Female flag and VTCK follow Traits and SNAM Factions. Records keep stale SNAM and VTCK under
set flags (3,723 templated NPC_/CREA), so presence cannot stand in for the flags. The next
speaker byte is 0 Target, 1 Self, 2 Either.

**Quest flags (QUST DATA).** Allow Repeated Conversation Topics (0x04) on 94 quests, Allow
Repeated Stages (0x08) on 34, of 436. `QuestServer.set_stage()` ignores both: every SetStage runs
the stage again.

**VCG01's opening** (quest and INFO scripts, dumped from FalloutNV.esm): the quest's stages set a
timer (`VCG01.fTimer`), and the quest script advances the stage when it runs out. Stages 3, 8,
15, 25, 35, 40, 50 and 60 speak with `DocMitchellREF.SayTo player VCG01Intro`, and each
VCG01Intro INFO's end script either sets the next stage or calls SayTo again. VCG01Intro is a
Conversation topic of 15 INFOs, each flagged Say Once (one also Goodbye) with a single
`GetIsID DocMitchell == 1` condition, so each SayTo says the first INFO in file order not yet
said. Stage 10 calls `GetPlayerName` and stage 36 `ShowRaceMenu`. Stage 70 says
VCG01DocReactions, which picks a line by `GetQuestVariable VCG01 5` (the tested SPECIAL) and the
player's `GetIsSex`; its end scripts set stage 75. The Rorschach test starts from
VCG01DocMitchellCouchTriggerSCRIPT: once the player sits on DocMitchellCouchREF and Doc sits in
DocMitchellChairREF, it sets `VCG01.bGiveTest` and calls `DocMitchellREF.StartConversation
Player`, with no topic. Doc's GREETING INFO then offers VCG01DocMitchellTopic000-005 through TCLT,
each linking onward, ending in stage 85.

**Stage B results.** `DialogueServer.choose_info()` yields VCG01Intro's 15 INFOs in file order
as each is said; picks VCG01DocReactions' line by `nDocReaction` (VCG01 variable 5) and the
player's sex; gives Doc's GREETING from VCG01 while it runs and not after. `QuestServer`
refuses a repeated SetStage unless the quest allows repeated stages
(VEFR00LegionMix2CaesarsHire does). The actor functions read traits and factions through the
template flags (`ActorStats.template_source`).

**Stage C results.** `test_vcg01_opening` runs VCG01 from stage 0 to 55 headless in 73.9 s of
game time, through stages 0, 1, 3, 5, 7, 8, 10, 15, 25, 30, 35, 36, 40, 45, 50 and 55, with Doc
saying VCG01Intro's first 13 INFOs in order. Response durations are the voice files' lengths
(00104BEE's is 2.61 s). The opening needed, beyond SayTo: the VCG01 quest script's timers
(GetSecondsPassed now on `ScriptServer.clock`, steppable), `ShowRaceMenu` running the quest's
`MenuMode 1036` block (stage 36 to 40), and SetStage starting a quest that is not running, as
the GECK's Quest Data Tab says. Stage 17 (a sex choice by message box) is never set: no script
sets it. In play, `game.gd` sets VCG01 stage 0, as VCG00 stage 100 does at the end of the
cemetery intro, which is not played.

**Stage D results.** `test_vcg01_opening` continues from stage 79: with `VCG01.bGiveTest` set,
`DocMitchellREF.StartConversation Player` (from the console, as the couch trigger would)
opens a conversation in the Dialog menu (1009); Doc greets with 0010558F, whose Link To
offers VCG01DocMitchellTopic000-005, and choosing on through the test reaches stage 85,
whose Goodbye line ends the conversation. Doc's topic list after VCG01 (no Link To) offers
seven topics, from "I'm hurt. I need help, Doc." to "Goodbye.". The couch trigger itself
needs the player sitting (IsCurrentFurnitureRef) and Doc in his chair (AI packages).

**Script use.** Across all script sources: SayTo x760, Say x147, StartConversation x149,
AddTopic x11, and 136 `Begin SayToDone` blocks, most naming a topic. None is supported yet, nor
GetPlayerName or ShowRaceMenu; stage B added GetIsVoiceType, GetIsSex, GetInFaction,
GetFactionRank and GetTalkedToPC.

**Voice files.** `Fallout - Voices1.bsa` (52,896 `.ogg`, 52,581 `.lip`, 40 `.wav`) holds each
response at `sound\voice\falloutnv.esm\<voice type EDID>\<quest>_<topic>_<INFO>_<n>.ogg`, with a
`.lip` of the same name: quest and topic EDIDs, the INFO FormID as 8 hex digits and the TRDT
response number, lowercased. When the quest and topic EDIDs exceed 25 characters together, the
quest keeps its first 10 and the topic the rest of 25 (`vdialoguec_greeting_...`,
`vdoctors_doctormedical33ye_...`). Of 29,674 responses, the rule names the file of 28,767; one
file carries another topic's name (INFO 0015A304) and 906 responses have none. The file is under
one of the speaker's voice types (from ANAM, a subject GetIsID, or GetIsVoiceType, including form
lists) for 24,307 of the 27,121 responses whose speaker is named that way, and for all 149 of
VCG01's.

## References

Documented behaviour this plan follows. The GECK wiki pages were read from the Wayback Machine
copies of geck.bethsoft.com; geckwiki.com refuses automated reads, so its two claims below come
from search-result summaries of it and carry that hedge.

- **Choosing an INFO** (TES4 Construction Set wiki, [Dialogue](https://cs.uesp.net/wiki/Dialogue),
  written for Oblivion): the game takes the topic's INFOs from every active quest, sorted by quest
  priority, and says the first whose conditions pass. Responses in an INFO play top to bottom.
  A topic is only in the topic list once added, by AddTopic or Add Topics.
- **Quest priority and conditions** (GECK, Quest Data Tab): higher-priority quests' dialogue takes
  precedence. Quest conditions apply to all the quest's dialogue and are checked before the
  INFO's own. Without Allow Repeated Stages, SetStage has no effect after the first call for a
  stage. Without Allow Repeated Conversation Topics, a conversation never uses a topic twice.
- **Menu** (GECK, Quest and Dialogue Tutorial): every conversation with the player starts with
  GREETING. Choices are the INFO's Link To topics; a chain whose last choice lacks Goodbye
  returns to the topic list. Top-level topics show first; topic priority, defaulting to the
  quest's, orders the list. Result Script (Begin) runs as the line starts, (End) as it finishes.
  The Speaker field acts like GetIsID when dialogue is exported.
- **Conversations between NPCs** (GECK, Conversation Tab): Conversation topics hold random
  NPC-to-NPC conversations, started by a HELLO with no Link From; several Link To topics pick one
  at random. Only one response per INFO is used there.
- **Functions** (GECK): `SayTo Target Topic [ForceSubtitle] [NoTargetLook]` says one line; a
  `SayToDone [Topic]` block on the speaker's script runs when a Say or SayTo completes.
  `StartConversation Target [Topic]` makes the speaker seek the target and start a conversation;
  with the player as target it force-greets, using the topic in place of GREETING, and in combat
  it uses GREETING. `AddTopic Topic` adds to the player's known topics.
- **Flags** (geckwiki.com, through search summaries): Say Once stops a given actor saying the INFO
  again, though another qualifying actor may. Random End ends a set of Random INFOs. Info Refusal
  keeps the player's prompt highlighted rather than shaded the next time it shows.

## Design

**Authored: `DialogueTopicBase` and `DialogueInfoBase`.** DIAL and INFO become EsmBase
resources through `TYPE_TO_BASE`, each field described per AGENTS.md "Describing record fields".
A topic holds its type, flags, priority, quests and its INFOs in file order, from the record
index (which lists records in file order; an INFO follows its DIAL). An INFO holds its quest,
DATA type and flags, responses (`DialogueResponse`: emotion, response number, text, speaker and
listener idles), conditions, Link To / Link From / Follow Up / Add Topics, prompt, speaker,
KNAM, and its begin and end script sources. NPC_ and CREA gain VTCK and TACT VNAM, as a voice
type. QuestBase gains its DATA flags as named fields.

**Runtime: `DialogueServer`, an autoload.** It holds dialogue state and nothing authored: which
actor has said which INFO (Say Once, Say Once a Day), whether each actor has talked to the
player, and the player's added topics. It chooses an INFO:

```gdscript
DialogueServer.choose_info(topic: DialogueTopicBase, speaker: EsmReference, listener: EsmReference) -> DialogueInfoBase
```

It takes the topic's INFOs whose quest is running and whose quest conditions pass, orders them
by quest priority, highest first, keeping file order within a quest and between quests of equal
priority, and returns the first that the speaker has not spent by Say Once, whose ANAM (if any)
is the speaker, and whose conditions pass, with the speaker as subject and the listener as
target. A qualifying Random INFO starts a set of the qualifying Random INFOs that follow it, up
to one flagged Random End, and one of the set is chosen at random.

**Saying an INFO.** A `DialogueLine` runs one INFO: the begin script runs, each response shows
for its duration, then the end script runs, the INFO is marked said by its speaker, and the
speaker's `SayToDone` block for the topic runs. Result scripts run on the speaker. A response's
duration is its voice file's length; with no voice file it is estimated from the text.

**Scripted speech.** `SayTo target topic` and `Say topic` choose an INFO and run its line with
subtitles on the player's HUD, without a menu.

**Conversation menu.** A `DialogueSession` on the player, like `TerminalSession`. Activating an
actor, or `StartConversation Player`, says its GREETING INFO, or the given topic's. Choices after
an INFO are its Link To topics if it has any; otherwise the topic list: the top-level topics and
the player's added topics that have an available INFO for this speaker, top-level first, by topic
priority. Each choice shows its INFO's prompt, or else the topic's name; a heard choice is shaded
unless its INFO is Info Refusal. A Goodbye INFO ends the conversation. StartConversation starts at
once where the speaker is; walking to the target waits for AI packages.

## Stages

Each stage has a gate; a later stage does not start on an unmet gate.

| Stage | Work | Gate |
|---|---|---|
| A. Resources | `DialogueTopicBase`, `DialogueInfoBase`, `DialogueResponse`; the topic → INFO order from the record index; NPC_/CREA VTCK and TACT VNAM; QUST DATA flags; `dialogue_census.cpp` extended with a voice-file census (every response's path, from its speaker's voice types). | `test_esm_server` asserts the census totals (topics, INFOs, responses, conditions, scripts, links) field for field against the raw subrecords; the voice census resolves every VCG01 response. |
| B. Choosing (done) | `DialogueServer.choose_info()`: quest running, quest conditions, quest priority, per-speaker Say Once, ANAM, Random sets; GetIsVoiceType, GetIsSex, GetInFaction, GetTalkedToPC. `QuestServer.set_stage()` runs a stage once unless its quest allows repeated stages. | VCG01Intro yields its 15 INFOs in file order as each is said; VCG01DocReactions picks by SPECIAL and the player's sex; Doc's GREETING is VCG01's while VCG01 runs; a Say Once INFO said by one actor is still available to another; a repeated SetStage on a quest without the flag does nothing. |
| C. Scripted speech (done; play check pending) | `DialogueLine`; SayTo, Say; `SayToDone` blocks; HUD subtitles; response durations from voice files; GetPlayerName and ShowRaceMenu complete at once. | A headless test steps a new game from VCG01's start through to stage 55; a play check shows the subtitles. |
| D. Conversation (done; couch trigger needs furniture and AI packages) | `DialogueSession`: activating an actor, GREETING, Link To choices, topic list, prompts, Goodbye; StartConversation, AddTopic. | A test sets `VCG01.bGiveTest` and calls `DocMitchellREF.StartConversation Player`, and choosing through the Rorschach test reaches stage 85; in play, talking to Doc opens his GREETING. The trigger's own start needs Doc sitting in his chair, which waits for AI packages. |
| E. Voice | Play each response's `.ogg` at the speaker. Non-positional playback, loaded on worker threads, landed with stage C. | Doc Mitchell's opening is heard in play. |
| F. Coverage | Re-run `diag_condition_coverage` with INFO evaluated today; list the next functions. | Nothing to pass. |

## Unverified

- The choice order is documented for Oblivion; FNV following it is assumed. How quests of equal
  priority order their INFOs (file order here; 244 neighbouring quest blocks share a priority).
- Say Once per actor, Random End and Info Refusal: from search summaries of geckwiki.com, not
  read directly.
- Whether ANAM restricts the speaker at runtime or only when dialogue is exported; it restricts
  here. It matters on the 201 ANAM INFOs without a GetIsID.
- Whether a topic needs adding to be listed when it is top-level.
- Result scripts run with the speaker as the calling reference.
- The response duration when there is no voice file, and when subtitles show without
  ForceSubtitle.
- The folder of the 2,814 voiced responses not under a voice type their conditions name.
- The 803 INFOs whose type differs from their topic's; the 43 whose quest is not among their
  topic's; DIAL Added Quests' shared INFOs (INFC/INFX).

## Out of scope

- Lip sync, facial animation, speaker and listener idles, and the dialogue camera.
- Speech challenges (KNAM, DNAM) beyond showing the choice, barter and other services.
- NPC-to-NPC conversations (HELLO), combat, detection and miscellaneous barks (types 1 random,
  2, 4, 6), which need AI; radio (type 7).
- Speakers walking to their target for StartConversation, and Doc reaching his chair, which need
  AI packages.
- The name and race menus, which stage C completes at once.
