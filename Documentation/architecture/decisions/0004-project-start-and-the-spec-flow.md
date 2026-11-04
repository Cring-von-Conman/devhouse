# 0004 — Project start and the spec flow

**Status:** Accepted. Subsystem: `Documentation/architecture/subsystems/role-skills.md`.

## Decision

A team project can begin from nothing, and its spec is made, reviewed and locked by the team. The manager
founds the project and assembles the team; the planner writes the spec in numbered revisions; the reviewers read
each revision before it can be approved.

- **Project start precedes discovery.** A manager whose folder has no `CLAUDE.md` (or one whose status is
  `project start, step <N>`) runs Project start first. Discovery needs a sidebar group and a shared folder, and a
  new project has neither, so she founds the repository, moves into it, files herself in a new group, and only
  then runs discovery. The folder move takes effect at the end of the turn, so Project start spans two turns by
  construction.
- **One approval covers the whole recommendation.** Before anything is created the manager asks, in one
  message, for the folder, `git init`, the files, the founding commit, the move, the new group and the second
  commit that records the answers to her setup questions. That approval is the human's say for both commits and
  the group. A recorded approval is a record, not an authority: after a compact or a resume she asks again for
  whatever is unspent.
- **Spec revisions are never overwritten.** A spec lives in `Documentation/spec/r<k>/`; a change is `r<k+1>/`.
  Every review names the revision it covered, and the locked spec is the revision the human approved, named in
  `CLAUDE.md`.
- **Concerns go to the manager, never to the planner.** She bundles them in `r<k>/concerns.makima.md`. The
  reviewer reviews the revision unbiased first and opens the concerns file only after her first review is
  written, then checks the concerns in a second review. Routing concerns through one member keeps the planner
  from fixing a concern before the reviewer has formed her own view. It narrows *Questions go direct* for spec
  concerns only.
- **The manager's smoke check is never a sign-off,** only "redo" or "pass". Approval of a revision is asked of
  the human only when it has complete, non-halted reviews, none with a blocking finding.
- **The manager opens members herself** with `start_session`, and telling the human to open the session is the
  fallback.
- **Every role is asked for concerns at each spec revision.** The work notice goes to the designer, the
  developer and the tester every time, and a role the human declined is recorded as "not consulted". The
  manager opens the whole planning set in the human's turn that asks for spec work.

## Two hands-off overrides, named

Hands-off is a standing approval, for the session form, to depart from two shipped rules. Each is named where it
lives, and nowhere else is it relaxed.

1. **The charter's "Never auto-advance" and "Human gate between every step."** In hands-off the manager advances
   to the next step once the unit's checkpoint merge is made, which needs the reviewer's pass and, for a unit
   with a hidden set, the confirmation round.
2. **The protocol's rule that a commit needs the human's say "for that commit."** In hands-off the manager
   commits each step that passes as a checkpoint, a merge on the branch `devhouse/hands-off`.

**Merging to the main branch still waits for the human,** and approving the spec is a stop in both modes.
**Hands-off applies to the build track only; on the maintenance track the per-task gate stands,** since the
human requests or reports each maintenance task. The charter's guardrails carry a session-form qualifier
pointing at the manager skill's *Modes*; the subagent form is unchanged.

## Deviation from the original flow

Bare `/devhouse` asks "Sessions or Subagents?" first, and only *Sessions* leads to the manager; answering it
approves nothing. The manager does not ask the human for a sidebar group: she offers to create one, with the
approval for the whole recommendation (a session already in a group is asked whether that group is the team).
Creating a group needs no card, and asking the human to make one by hand would be the friction this flow exists
to remove.

## Finding: starts are refused in teammate-triggered turns

A `start_session` with `initiation: "user_asked"` is refused in a turn that a teammate's message triggered, and
accepted in a turn the human started. So the manager opens members in turns the human starts, ahead of the phase
that needs them. A member needed in a teammate-triggered turn is proposed with `own_initiative` (an approval
card), by an ordered ladder: a declined card means no, with no re-proposal and no fall-through; telling the human
to open the session by hand is the last resort, only when `start_session` is unavailable or the `own_initiative`
call itself is refused. A standing "yes" to opening members buys hands-free starts only at the moments the app
allows. The limits are in `role-skills.md` §9 Gotchas.

## Consequences

- **The manager is a larger role.** She writes more files (the brief, concerns, relayed-question summaries,
  `.gitignore` in Project start), runs `git init`, makes approved commits, and creates, checks out and, on the
  human's say, merges the hands-off branch. The manager skill's *Never-edit* translation says so, and the
  charter's never-edit invariant carries a session-form pointer to it.
- **Approval is a moving target after a compact.** The recorded session-question answers are a record; the
  manager treats "open without asking" and "hands-off" as not given until the human re-confirms, so a long
  session may re-ask.
- **Hands-off merges stay manual.** The end-of-project merge into main is the manager's, on the human's say. A
  spec change during hands-off needs the human anyway.
- **Not measured:** the halt pointer, whether an omitted `permission_mode` inherits the manager's, and a late
  human-started turn honouring a standing "yes" beyond the starts observed.
- **The canonical statements are in one place each:** Project start, the session questions, opening members and
  the modes in the manager skill; the spec flow, contact and the document folders in `team/protocol.md`. This ADR
  records why and does not restate the rules.
