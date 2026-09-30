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

**State** is kept per actor, by `EsmReference.instance_id`. The day for Say Once a Day is
`GameDaysPassed`, rounded down. None of the state is saved yet.

**Scripts** reach it through `GetTalkedToPC`. Dialogue conditions also use `GetIsSex`,
`GetIsVoiceType`, `GetInFaction` and `GetFactionRank`, which read the actor's traits and
factions from its record or, when its template flags say so, its template
(`ActorStats.template_source`).

## Not yet

- Saying an INFO (responses, result scripts, SayTo, SayToDone): stage C of the plan.
- The conversation menu, AddTopic and INFO Add Topics: stage D.
- Runtime faction changes (SetFactionRank, AddToFaction); GetInFaction reads authored SNAM.
- Templates that are leveled lists are not followed.

## Unverified

- The choice order is documented for Oblivion's Construction Set; FNV following it is
  assumed. Quests of equal priority keep file order.
- Say Once per actor, Random End: from search summaries of geckwiki.com.
- ANAM restricting the speaker at runtime.

## Tests

`tests/test_dialogue_server.tscn`.
