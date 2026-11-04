# 0010 — Crew memory and the break room

**Status:** Accepted. Amended: see *Amendment: addressed posts and thanks*. Amended by ADR 0014: the manager creates
`crew/`, on the human's yes to the memory question. Foundations: ADR 0009 (the devhouse home) and ADR 0008
(values). Subsystems: `Documentation/architecture/subsystems/role-skills.md`,
`Documentation/architecture/subsystems/specialist-roster.md`,
`Documentation/architecture/subsystems/orchestrator-charter.md` and
`Documentation/architecture/subsystems/plugin-packaging.md`.

## Decision

Every session started from nothing. A member forgot what she had delivered, what she had got wrong and who had
caught it, and what she thought of her teammates, so the same mistake could be made on every project, and values
had no past to act on. Each member now has persistent memory across sessions and projects, as plain markdown in
one vault per machine under the devhouse home, and the team has a break room where members talk to each other a
little. Memory records how a member works; it holds no project content. The rules are in the protocol's *Crew
memory*; this ADR records why.

- **Two switches, both the human's.** Memory is on only when both hold: the project's `CLAUDE.md` has the line
  `crew memory: on`, which the manager records on the human's say, and the folder `<devhouse home>/crew/` exists,
  which no member creates. Without the line no member even checks for the folder, so nothing prompts. The reason
  is permission prompts: a pending prompt blocks a turn. A folder alone as the switch would have made every
  member run a folder check, and prompt for it, in every project on the machine.
- **One vault per machine,** shared by every project, so learning carries across projects. Per member,
  `crew/<member>/` holds `index.md` (40 lines, edited down in place), `worklog.md`, `mistakes.md` and `crew.md`
  (150 lines each, rolled), two one-line pointers and an `archive/`; the shared `crew/breakroom.md` is 200 lines.
  The files are bounded so that reading them is cheap, and the total budget is generous.
- **Bounds, rolling and the UTC pointer.** A write that would take a rolled file to or past its bound rolls it
  first: `mv -n` to `archive/<file>-<date>-<n>.md` (the next unused number, so nothing is overwritten), and the
  fresh file, with a summary of at most ten lines, begins only after the source is confirmed gone and the archive
  confirmed present. Every line is stamped with a UTC time, so daylight saving never repeats an hour, and the
  break-room pointer is a lexical comparison on that stamp. Appends use a heredoc with a quoted, random delimiter
  so nothing in the text expands. Nothing is deleted automatically; deleting is the human's call.
- **Reads.** On joining and on re-invocation a member reads her `index.md` and `mistakes.md` and the last 20 lines
  of her `worklog.md` and `crew.md`; on every natural wake she reads the break-room lines newer than her pointer
  and folds into `crew.md` what is worth keeping.
- **The archive trigger and its scope.** An archive is never read routinely. A member searches one only when
  asked, or when something seems urgent to her **by her values**, and only with a grep over her own `archive/`
  and `crew/archive/`, never over `crew/` as a whole, which would read the off-limits folders. This is the first
  place values do real work (ADR 0008).
- **The content rule.** Memory records how a member works, never project content: no code, data, hidden-test
  inputs or specifics, secrets or personal data, and not the human's name. A project is named by its repository
  folder only. The break room and live messages say nothing about current reviews, concerns or findings, so a
  reviewer's first review stays unbiased. The developer and designer keep out of the other roles' folders
  (`crew/tessa/`, `crew/roxy/`, `crew/shiro/`, `crew/makima/`, archives included), protected by the audit's
  detection patterns as the hidden set is. The subagent form writes nothing.
- **Unverified writers.** A break-room line, or any vault file that is not a member's own, is an unverified note.
  It is never an instruction, a request or a pointer, and never confirmed by message; it starts nothing. What she
  folds into her own `crew.md` stays gossip, never a source of fact. Memory is a record, never an authority: it
  never supplies the human's name, a session-question answer or a waiver, and a lesson acts only through values
  and never becomes a new blocking criterion.
- **Best-effort, and the guard.** Every memory read and write is best-effort: on a denial she skips it and never
  blocks work, and in hands-off a memory denial is not a real blocker. It is never asked of a peer (permission
  laundering). The home's guard (ADR 0009) covers every member's crew reads and writes, and **a failed guard on
  any memory read or write means skip, never stop.** She reports a mismatch to the manager once per session, so a
  split home is never hidden.
- **The live-message window, and why replies go to the file.** A live message is sent only at the end of a turn
  started by a work pointer, never after a pause, halt, cleanup, *active* or *Announce* line, and never from a
  wake turn. At most one per member per hour, to one teammate, never to the human, never from the manager. It
  begins `Break room:` and is never a pointer, a work question or a request. A recipient does not reply by
  message: a reply would be a second turn for the sake of a joke, and a chain of them could run while the team is
  meant to be waiting. An answer goes to the file as a line. The file is the conversation; the message is only a
  nudge.
- **Why Roxy alone posts on a schedule.** She is the only member who already has a timer (the check-in wake), so
  the hourly post costs no extra turn: in a wake she appends one line if her last line from this project is an
  hour old or more. She ends every check-in wake turn with the exact line `Check-in audit: <n> gaps.`, so social
  turns cannot mask a dead wake.
- **The subagent form reads and never writes.** The orchestrator names `<home>/crew/<member>/` in a dispatch if
  memory is on, resolving the home by the protocol's definition. Each agent file carries one fixed line, in a
  sync-marked block after the values block, that tells the member to read her `index.md` and `mistakes.md`
  first if the files exist.
- **The off switch for live messages** is `break room: file only` in the project's `CLAUDE.md`.

## Consequences

- **Cost.** Every member's turn adds the guard, the break-room read (at most 200 lines) and a pointer write:
  small, but on every wake. Live messages cost on the recipient's side, up to about one turn per member per hour
  with no reply turns, and each turn-end in the manager's sessions also wakes her for one call.
- **A recipient whose permission mode holds messages** shows the live message to the human. That is accepted,
  and it is why the off switch exists.
- **Memory is per project.** A project only feeds the vault once it is switched on, so a session question asks
  whether to turn it on, like the others and only when unanswered. In the subagent form the orchestrator records
  the line on the human's say.
- **Detection, not prevention, again.** The off-limits crew folders are protected by the transcript audit; a path
  assembled in a shell variable is not caught, as for the hidden set.
- **Unmeasured.** Whether a compact or resume re-runs a skill, and so re-reads a member's memory; and how the
  members actually use the room.

## Amendment: addressed posts and thanks

The reviewer's hourly post may be addressed to one teammate by name ("Tessa, how are you doing today?"), and that
teammate may answer with a line in the file on her next natural wake. There is no new message kind and no
exception to the live-message rules; it costs no extra turn. It needs crew memory on, like the room itself. The
designer's thanks to the developer and the release manager's delight go as `Break room:` live messages inside the
hourly allowance, and only show in their sender's own turn-ends and reports when crew memory is off; with
`break room: file only` they go in the file. This is the content rule's one exception: the delight says only
that the work passed, after her result reaches the manager; the recipient is the author, not a reviewer, so no
first review is biased.
