# 0007 — Voices that show, and the Manager

**Status:** Accepted. Amended: see *Amendment: small messages and turn-ends*. Subsystems:
`Documentation/architecture/subsystems/role-skills.md` and
`Documentation/architecture/subsystems/orchestrator-charter.md`.

## Decision

Members' output was flat. A member whose voice is bombastic wrote a neutral two-sentence turn, and a member who
should answer in one word wrote a full sentence. The causes: each voice was a list of adjectives with no examples,
and models copy examples; a short Voice is read first and then buried under a long neutral protocol; nothing said
the voice covers small messages; and the app's own system prompt favours plain writing. The rules are in
`plugins/devhouse/team/protocol.md` (*Voice*, *Discovery protocol*, *Spec flow*, *Check-ins*) and the manager
skill; this ADR records why.

- **The voice covers small messages.** The protocol's *Voice* habit binds every member including the manager. It
  colours messages to the human and to teammates, acknowledgements included, and the prose of reports, reviews
  and other process artefacts. It stays out of what ships (code, markup and UI copy, tests, the grounded docs,
  ADRs, `README.md`, `CLAUDE.md`, commit messages, release notes) and out of the normative text of specs and work
  orders. Exact strings stay exact: whatever the protocol, a skill or the charter quotes or marks as exact, or
  that a check or the audit matches; every question given word for word; tool arguments; git's default merge
  message. Each skill's *Precedence* item cites the habit by name.
- **Voices get samples, and the size limit is relaxed.** Each `## Voice` has four to twelve trait lines (counted
  as list items) and ends with `Sounds like:` and two to eight samples. The hundred-character cap per line is
  dropped. Only the items under `Sounds like:` are
  exempt from the banned-word list and the imperative test, so Tessa can say "if you design it right" and Delia
  "Fix it"; trait lines keep every check, and the gate rule (a voice never weakens a gate) applies to every
  sample. **The canonical statement of the voice check is `role-skills.md` §10 *Static checks*.**
- **Cross-member traits are regard and tone only.** Makima's regard for Shiro is close behind her regard for
  Roxy, and Roxy's comes first. That is regard, not rank: in a disagreement between the two reviewers the
  protocol's *Authority* holds, so the manager relays both positions and takes no side. Tessa's pleas to Shiro
  for a testable design are tone only; routing is unchanged (Tessa raises it with the manager, who may pass it
  to Shiro), and Shiro's answer to such a request is not a blocking finding.
- **Makima the Manager.** The coordinating member's role title is `Makima the DH Manager` and her skill
  `/devhouse:manager`, so that every role title alliterates with its member's name. Renaming a skill breaks
  anything that invokes it. A session titled `Makima the DH Lead` is listed in *Discovery* as a retired title
  ("retired title; re-run /devhouse:manager") and never messaged. A live team under the old title is stranded:
  archive the team and start fresh; there is no migration.
- **The folder check.** In *Project start*, before the other branches, the manager reads her own `group` and
  `cwd` and, if another session in the group (archived ones included) works in a different folder, warns and
  asks. A null or absent `group` skips it.
- **Grandfathering is an explicit list** (cutoff amended by ADR 0008). When the security reviewer first joins, the
  manager writes `Grandfathered units:` beside the security start point, listing every unit dispatched before the
  turn of the `start_session` call, or the ask to the human, that she joined from. This supersedes ADR 0006's rule
  that unit merges preceding the start-point commit are grandfathered, which has a hole.
- **Unapproved spec revisions are history.** A declined approval is recorded in `CLAUDE.md`, and a further change
  is then a new revision, or the human stops there. Every unapproved revision folder is committed, with the brief
  summaries written while it was drafted, at the next spec approval, and the approval question names them. If no
  later approval comes they stay untracked, an accepted limit.
- **The human is called by name.** A session question, "What should the team call you?", is recorded beside the
  others with pronouns if given. The answer goes into every started session's `background` and into the first
  pointer of a member opened by hand. Skipped, the default is the name the host has already been told to use,
  else plain "you". **A name is never inferred** from an email address, a git user name or a folder path, so the
  rule fits any adopter.

## Consequences

- **Voice costs a little exactness and buys a lot of presence.** A member's small messages sound like her; the
  gates, the exact strings and everything that ships do not.
- **Live teams must restart across the rename** (archive, reinstall, open a fresh manager); the README carries
  the note.
- **The voice check is partly mechanical:** trait-line counts, banned words and sample counts are greps; "no
  imperative" and the gate rule still need a reader.
- **The canonical statements are in one place each:** the voice scope and the name habit in the protocol's
  *Voice*; the check in `role-skills.md` §10; the title and retired titles in the protocol's member table; the
  folder check, the session questions and `Grandfathered units:` in the manager skill; the audit's use of the list
  in the protocol's *Check-ins*.

## Amendment: small messages and turn-ends

This amends the decision above; its text is left as written, including the earlier sample count.

- **The sample limit is two to eight.** Four were too few to give each relational trait its own sample. The lower
  bound stays at two.
- **Small messages and turn-ends are in voice.** Three failures were shared: every member answered an announce
  line by narrating the protocol's rule, every turn-end to the human was the host's default report, and
  relational traits had no channel. The *Voice* habit gains four rules (turn-ends in voice; small messages vary;
  no narrating a rule you are following; the protocol's required content comes first) and the announce step asks
  for a reaction or nothing. **Required content wins over variety:** an exact string, a required line or a gate's
  question appears in full however often it recurs; voice shapes only the words around it. Every teammate is
  "she".
- **Praise is folded into pointers.** The manager's word of praise at a unit's merge rides in the next pointer she
  sends anyway, so it costs no extra turn; only when none is coming does it go alone, ending `No reply needed.`,
  and then it starts nothing. It goes at the merge only, so a later failed gate never leaves praise standing.
- **The planner asks drafting questions, and the reviewer is never asked one.** The planner consults the others
  while she writes a work order. The reviewer reviews every work order before dispatch and that review stays
  unbiased. An answer is information for the planner and decides nothing: not a review, not a pass, never the
  security mark.
- **The reviewer's teaching note.** She may tell someone directly about an issue she found in their work, as a
  teaching moment and not a work order; the only response expected is an acknowledgement in the recipient's
  voice. It follows her review pointer in the same turn, so the finding's routing comes first. It is her view
  and not a ruling, and it is never sent to the security reviewer or the release manager on a matter in their own
  domain.
- **The hourly post may be addressed.** The reviewer's hourly break-room post may be addressed to one teammate. It
  stays a file line, so it needs no new message kind and costs no turn.
