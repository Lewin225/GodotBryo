# DialogueServer

Chooses what actors say and holds dialogue state. Autoloaded singleton `DialogueServer`.

Topics (DIAL) and their INFOs are authored resources, `DialogueTopicBase` and
`DialogueInfoBase`, from `EsmServer`. This server holds only runtime state: which actor has
said which INFO, which actors have talked to the player, and the player's added topics.
The design and its sources are in `Plans/Dialogue/dialogue.md`.

---

## Contract

```gdscript
DialogueServer.choose_info(topic, speaker, listener) -> DialogueInfoBase   # null when none qualifies
DialogueServer.say(speaker, topic, listener) -> DialogueLine   # null when none qualifies; listener null for Say
DialogueServer.get_line(speaker) -> DialogueLine                # the line being said, or null
DialogueServer.response_duration(info, index, speaker) -> float
DialogueServer.voice_path(info, index, speaker) -> String       # "" when the speaker has no voice type
signal response_started(line, text)                              # a subtitle
signal line_finished(line)
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

**Saying.** `say()` chooses the INFO and marks it said, then runs its begin script on the
speaker (the listener as action reference), so an end script that says the same topic
again gets the next line. Each response lasts its voice file's length; with no voice file,
its text at `fNoticeTextTimePerCharacter` seconds a character. `_process(delta)` advances
every line; when its last response ends, the end script runs on the speaker, then the
speaker's `SayToDone` block for the topic, then `line_finished`. A new line from a speaker
replaces the one it is saying. The player's HUD shows each response as a subtitle.

**Voice files** are `sound\voice\falloutnv.esm\<voice type>\<quest>_<topic>_<INFO>_<n>.ogg`
in `Fallout - Voices1.bsa`, lowercase; when the quest and topic editor IDs exceed 25
characters together, the quest keeps 10 and the topic the rest. The voice type is the
speaker's VTCK (from its template when that supplies traits) or TACT VNAM. Voice is not
played yet.

**State** is kept per actor, by `EsmReference.instance_id`. The day for Say Once a Day is
`GameDaysPassed`, rounded down. None of the state is saved yet.

**Scripts** reach it through `GetTalkedToPC`. Dialogue conditions also use `GetIsSex`,
`GetIsVoiceType`, `GetInFaction` and `GetFactionRank`, which read the actor's traits and
factions from its record or, when its template flags say so, its template
(`ActorStats.template_source`).

## Not yet

- Playing voice (stage E); lip sync and speaker/listener idles.
- The conversation menu, AddTopic and INFO Add Topics: stage D.
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

## Tests

`tests/test_dialogue_server.tscn`, `tests/test_vcg01_opening.tscn` (VCG01 stage 0 to 55).
