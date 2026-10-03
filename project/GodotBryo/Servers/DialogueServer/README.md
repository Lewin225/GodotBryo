# DialogueServer

Chooses what actors say and holds dialogue state. Autoloaded singleton `DialogueServer`.

Topics (DIAL) and their INFOs are authored resources, `DialogueTopicBase` and
`DialogueInfoBase`, from `EsmServer`. This server holds only runtime state: which actor has
said which INFO, which actors have talked to the player, and the player's added topics.
The design and its sources are in `Plans/Completed Plans/Dialogue/dialogue.md`.

---

## Contract

```gdscript
DialogueServer.choose_info(topic, speaker, listener) -> DialogueInfoBase   # null when none qualifies
DialogueServer.say(speaker, topic, listener) -> DialogueLine   # null when none qualifies; listener null for Say
DialogueServer.get_line(speaker) -> DialogueLine                # the line being said, or null
DialogueServer.response_duration(info, index, speaker) -> float  # loads on the calling thread
DialogueServer.wait_for_loads()                                  # blocks on pending voice loads (tests)
DialogueServer.voice_path(info, index, speaker) -> String       # "" when the speaker has no voice type
DialogueServer.start_conversation(speaker, listener, topic = GREETING) -> bool
DialogueServer.choose(index)                                     # one of the last choices_ready
DialogueServer.end_conversation(say_goodbye = true)
DialogueServer.get_conversation_speaker() -> EsmReference
DialogueServer.choices_after(info, speaker, listener) -> Array[DialogueChoice]
signal response_started(line, text)                              # a subtitle
signal line_finished(line)
signal conversation_started(speaker, listener) / choices_ready(choices) / conversation_ended(speaker)
DialogueServer.mark_said(info, speaker)                # for Say Once and Say Once a Day
DialogueServer.has_said(info, speaker) -> bool
DialogueServer.set_talked_to_player(actor) / has_talked_to_player(actor) -> bool
DialogueServer.add_topic(topic) / has_topic(topic) -> bool
DialogueServer.reset()                                 # clears all state, as for a new game
DialogueServer.rng: RandomNumberGenerator              # picks among a Random set
```

`speaker` and `listener` are `EsmReference`s; the speaker is the conditions' subject, the
listener their target.

**Choosing.** The topic's INFOs whose quest is running are taken by quest priority, highest
first, in file order within a priority. The first that qualifies is said: its quest's
conditions and its own pass, the speaker has not said it (Say Once) or has not said it today
(Say Once a Day), and its ANAM, when set, is the speaker's base. A qualifying Random INFO
starts a set: it and the qualifying Random INFOs after it, up to one flagged Random End; one
is chosen with `rng`.

**Saying.** `say()` chooses the INFO and marks it said at once, so an end script that says
the same topic again gets the next line. The line starts when its voice files are loaded:
cached ones at once, others read and parsed on a `WorkerThreadPool` task (usually ready the
next frame; Doc's 15 VCG01Intro files take 0.05-1.4 ms to read and 0.05 ms each to parse).
Starting runs the begin script on the speaker (the listener as action reference). Each
response lasts its voice file's length and plays it, not positionally, through an
`AudioStreamPlayer` the line owns; with no voice file it lasts its text at
`fNoticeTextTimePerCharacter` seconds a character. `_process(delta)` advances
every line; when its last response ends, the end script runs on the speaker, then the
speaker's `SayToDone` block for the topic, then `line_finished`. A new line from a speaker
replaces the one it is saying. The player's HUD shows each response as a subtitle. In menu
mode (`ScriptServer.is_menu_mode()`) lines do not advance and their voices pause.

**Conversations.** `start_conversation()` (StartConversation with the player, or the player
activating an NPC) opens the Dialog menu (1009), records that the speaker has talked to the
player, and has the speaker say the topic's INFO, GREETING by default; a said INFO's Add
Topics join the player's topics. When the line finishes, a Goodbye INFO ends the
conversation; otherwise the choices are its Link To topics, or else the topic list:
top-level topics, then the player's added topics, each by priority (highest first), each
with an INFO this speaker would say. A choice shows that INFO's prompt (RNAM), or else the
topic's name. `choose()` has the speaker say the chosen topic. Escape ends the conversation,
and the speaker says GOODBYE, which the GECK's Topics Tab says is used when the player
exits the dialogue menu. Lines run under the Dialog menu while other menus pause them. The
first topic list loads the 2,283 top-level topics once (425 ms; later lists about 20 ms).
The player's `DialogueSession` shows the speaker, the response and the choices.

**Voice files** are `sound\voice\falloutnv.esm\<voice type>\<quest>_<topic>_<INFO>_<n>.ogg`
in `Fallout - Voices1.bsa`, lowercase; when the quest and topic editor IDs exceed 25
characters together, the quest keeps 10 and the topic the rest. The voice type is the
speaker's VTCK (from its template when that supplies traits) or TACT VNAM.

**State** is kept per actor, by `EsmReference.instance_id`. The day for Say Once a Day is
`GameDaysPassed`, rounded down. None of the state is saved yet.

**Scripts** reach it through `GetTalkedToPC`. Dialogue conditions also use `GetIsSex`,
`GetIsVoiceType`, `GetInFaction` and `GetFactionRank`, which read the actor's traits and
factions from its record or, when its template flags say so, its template
(`ActorStats.template_source`).

## Not yet

- Positional voice at the speaker (stage E); lip sync and speaker/listener idles.
- The speaker walking to the player before StartConversation; conversations between NPCs.
- Shading heard choices, Info Refusal, speech challenges.
- Runtime faction changes (SetFactionRank, AddToFaction); GetInFaction reads authored SNAM.
- Templates that are leveled lists are not followed.

## Unverified

- The choice order is documented for Oblivion's Construction Set; FNV following it is
  assumed. Quests of equal priority keep file order.
- Say Once per actor, Random End: from search summaries of geckwiki.com.
- ANAM restricting the speaker at runtime.
- Result scripts running on the speaker; an INFO marked said as it starts; a new line
  replacing the one being said; subtitles always shown (SayTo's ForceSubtitle is ignored).
- The duration of an unvoiced response.
- The topic list: top-level topics without being added, top-level first, by priority; the
  speaker saying GOODBYE when the player leaves.

## Tests

`tests/test_dialogue_server.tscn`, `tests/test_vcg01_opening.tscn` (VCG01 stage 0 to 55).
