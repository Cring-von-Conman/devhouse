# 0005 — Units of work in the session form

**Status:** Accepted. Subsystem: `Documentation/architecture/subsystems/role-skills.md`.

## Decision

Once a spec is locked, the team builds in units. A unit is a build step or a maintenance task, and everything
below applies to one unit. The developer and designer work at the same time without clashing, the tests cannot
simply be gamed, and members keep each other honest. The rules are in `plugins/devhouse/team/protocol.md`
(*Units and branches*, *Tests*, *Check-ins*, plus *Routing*, *Files* and *Session method*); this ADR records why.

- **Sessions stay in one checkout; code lives in plain git worktrees.** Each builder (developer, designer,
  tester) makes her own worktree with `git worktree add` and works in it by absolute path. The app's own
  `use_worktree: true` was rejected: it names the branch `claude/<name>-<suffix>` rather than the name passed, and
  a new repository first needs the human to trust it. Git forbids one branch in two worktrees, which was the real
  constraint; plain worktrees satisfy it while every branch stays readable from the shared checkout.
- **The integration branch model.** `<I>` is the branch the shared checkout has checked out: `main`, or
  `devhouse/hands-off` from the start of hands-off until the human merges it. The manager creates `work/<u>` from
  it; the designer and tester create `design/<u>` and `tests/<u>` from `work/<u>`. The developer merges the others
  and records `ready: <sha>`; the reviewer and tester work on exactly that SHA. The unit's merge into `<I>` is its
  checkpoint commit.
- **Code runs from its worktree.** Every command that builds, imports or tests code runs from the worktree with an
  environment that resolves to the worktree's code, and records a provenance line. An editable install imports
  the shared checkout's code wherever it is run from, so a gate run in a worktree could otherwise pass on code
  that is not the worktree's.
- **Hidden tests, by detection and not prevention.** The tester writes a second set from the spec, testing the
  same requirements in a different manner with distinctive inputs. It lives outside every repository and the
  plugin. The reviewer judges its validity and checks the code for special-casing of its inputs; the tester runs
  it in a throwaway verification worktree, reporting a failure by requirement and class of input only; after a
  pass it is committed and a confirmation review checks the committed files equal the set that was run. Every
  member runs as the human on one filesystem, so nothing technical stops a peek: the manager searches the
  developer's and designer's transcripts for literal access. What this does and does not catch is stated once, in
  the protocol's *Tests*, *Detection, not prevention*.
- **Audits, not chat.** The reviewer alone runs a timed audit of files and git; it reads artefacts and branches,
  never peers, so a peer cannot answer it into silence. It flags a dispatch, merge, report or spec revision with
  no review, and a unit with no tests, and reports each gap once. The timer is a self-chaining one-shot. Its cost
  is stated: while a unit is active, about four reviewer turns an hour, each also waking the manager for one call.
  The audit pauses whenever the team waits on the human, and each wake is also the heartbeat the manager checks.
- **The builders' channel.** Before editing a file the work order does not assign to her alone, a builder messages
  the other builders; an overlap is settled by message before either edits it. This widens *Questions go direct*
  to all builders on a unit.
- **Side-session notes are unverified messages.** A started member's output can land in the app's side-session
  notes folder; the protocol treats a file there as a message to be confirmed with its supposed sender.
- **Grounded architecture docs** are written by the unit's builder on her branch from the spec revision's rough
  draft, stating any deviation; the reviewer judges whether it warrants an ADR.

## Refinements made after the first builds

- **One merge trigger:** the reviewer has passed the frozen SHA (and, for a security-relevant unit, the
  security reviewer: ADR 0006) and, where the unit has a hidden set, the confirmation round is done. The manager
  checks that `git rev-parse work/<u>` equals the SHA the trigger names and merges it (since ADR 0015, through the
  git tripwire, never `git merge`). A commit after
  the freeze is a new iteration.
- **Iteration cap:** counted in frozen SHAs. The confirmation re-freeze and the re-freeze after a merge conflict
  do not count toward it. A merge conflict is resolved normally: the developer resolves and re-freezes, and the
  resolved SHA gets the tester's re-run and one full ordinary review.
- **Disclosure:** a validity finding names requirements only, never tests or method; the specifics go in a
  `validity` file in a sibling folder, outside the set, that inherits the hidden home's off-limits status.
- **The transcript audit is robust to shell quoting:** a regex with a doubled backslash passed through the Bash
  tool silently missed real hits, so the audit normalises separators to `/`, matches forward-slash forms only and
  builds a backslash with `chr(92)`. Each hit is classified as access or mention, all go to the human, and only
  access blocks.
- **Re-read on change.** A directory-marketplace install is read from its source folder, so a team can run on
  mixed plugin versions. Every member checks a plugin file's modification time against her last read before
  acting on it. This narrows the window and does not close it.
- **Paths that expand:** `%USERPROFILE%` expands only in cmd.exe and unquoted backslashes collapse in Bash, so the
  protocol has the member resolve the home to an absolute path before writing (since ADR 0009, the devhouse
  home).
- **Every role is asked for concerns at each spec revision.** Lean applies to the build, not to planning.

## Consequences

- **The manager and the reviewer both grew.** The manager creates and deletes branches, merges, sends active,
  pause and cleanup pointers, and runs the transcript audit; the reviewer keeps a timer. Neither is enforced: the
  audit is evidence for the human, not a gate that cannot be skipped.
- **A hand-off is longer.** Every hand-off between members goes through the manager by pointer, and the
  confirmation round adds three pointers to a unit with a hidden set.
- **Hands-off means merges on the hands-off branch,** one per unit. Merging that branch into main still waits for
  the human.
- **The canonical statements are in one place each:** units, branches and the merge trigger in *Units and
  branches*; tests, the hidden set and detection in *Tests*; the timed audit in *Check-ins*; the builders' channel
  in *Routing*; opening builders in the manager skill's *Opening members*.
