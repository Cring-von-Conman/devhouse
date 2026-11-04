# 0015 — The git tripwire: a mechanical check for what changes what git does

**Status:** Accepted. Amends ADR 0013 (see *Amendments*). The threat model it works under is ADR 0017.
Subsystems: `Documentation/architecture/subsystems/role-skills.md`,
`Documentation/architecture/subsystems/orchestrator-charter.md`,
`Documentation/architecture/subsystems/specialist-roster.md` and
`Documentation/architecture/subsystems/plugin-packaging.md`.

## Decision

Some things in a repository change what git does, not just what the files say: a symlink or a submodule, a
`filter=` attribute, a hook, a config value, a replace ref, a worktree link. The release stage scans for some of
these, but only when a release is made. Nothing watched the shared checkout's own `.git` (its config, hooks,
`info/`, replace refs and worktree links), which every member's git obeys, nor what a unit or a manager commit
added before it reached the mainline. A member can add one by accident, or because something she read told her
to. The tripwire is a shipped script that finds these mechanically. The rules are in the protocol's *The git
tripwire*; this ADR keeps the reasoning.

- **Detection, not judgement.** A mechanical check finds the hits; the security reviewer judges them (benign, or a
  blocking finding only the human waives); the human judges when she is absent or the line is under `hidden/`.
  The script never decides that something is safe.
- **Two checks.** The *unit check* reads what one unit or one commit adds: symlinks and submodules, and files
  that steer git, a hook framework, Claude Code or an editor. The *checkout check* reads the shared checkout's
  `.git`. It runs before every merge and commit, at every check-in wake and before the hands-off merges.
- **A script and its modes.** `team/git-tripwire.sh` is Bash, because Git Bash is already required, so it adds no
  dependency to a Windows machine that has Git. Its nine modes (`check-unit`, `merge-unit`, `check-checkout`,
  `merge-handsoff`, `commit`, `close`, `salt`, `select`, `remove`) are a closed list, and each reads exactly its
  own files from an args folder. Putting the checks in a tested script, and not in prose each member re-types, was
  chosen because a defect appeared in every re-typed copy. It is called through `env -i` with `--noprofile
  --norc`, and the first line of the call refuses four git variables, so no inherited function, profile or
  snapshot takes it over.
- **It makes the merge and the commit itself.** `git merge` and `git commit` run hooks, filters, merge drivers and
  signing programs, and read `branch.<b>.mergeOptions` and `pull.twohead`, so the tree a merge makes would not be
  the tree the hits were read on. `merge-unit` reads the tree with `merge-tree --write-tree`, builds the merge
  commit with `commit-tree`, moves the branch with a compare-and-swap `update-ref` and updates the index and work
  tree with `read-tree -m -u` after a dry run. `commit` stages the named paths into a private index, so a member's
  own `git add` is never committed. The merge commit has the explicit subject `Merge branch 'work/<u>'` so the
  reviewer's audit still sees it.
- **No hook runs in the script.** A hook is code the project owns; running one would let a hit the script exists
  to catch run inside the script. Every git command carries the hook pairs for every `hook.<name>.command`, an
  empty hooks folder of the script's own (not `/dev/null`, which Windows turns into a path relative to the work
  tree), and the config's filter and merge-driver commands blanked. The price: a project's own pre-commit guard
  is skipped, and a clean filter would not run, which is why a path naming a configured filter stops a merge or
  commit (the **filter check**).
- **Identity: `<class> <id> <hash>`.** A hit is named by its class, an id (a path, or a masked key plus a few
  characters of its salted hash) and a salted hash of its value, so a changed value is a new hit and no value is
  ever printed or committed. The salt is made once per project, outside the repository, and is readable by the
  manager, the reviewer, the orchestrator and the security reviewer, never the developer, designer, tester,
  planner or release manager.
- **Only `user.name` and `user.email` are exempt from the config comparison;** every other key that differs from
  a fresh repository's is a hit, so a key nobody thought of is seen. The cost is noise on the first day (the
  remote and branch keys, an editor's merge base), answered once by the keep-or-remove question.
- **`allowed` is not in the repository.** A released checkout hit becomes a line in
  `<home>/tripwire/<project>/allowed`, written only by `close`, never a never-allowed line, keyed by the value's
  hash. A committed list is repository content a clone brings from elsewhere.
- **Never allowed, by two limbs:** **(a) where git loads code, config or objects from** (`core.hooksPath`,
  `core.fsmonitor`, `core.worktree`, `core.attributesFile`, `hook.*`, `include.*`, the worktree-config, link,
  hard-link, worktree-link, submodule-dir and replace-ref classes, `info/grafts`); and **(b) programs git runs, or
  credentials or trust it hands over, when it reaches a remote** (`core.sshCommand`, `core.gitProxy`,
  `core.askPass`, `credential.helper`, `remote.*.uploadpack|receivepack|vcs|proxy`, every `http.*`,
  `protocol.allow`).
- **Removal is the human's, per item, and moves rather than deletes** (into `removed/`, with an index line). It
  re-selects by class, id and hash first, and refuses what it cannot do safely.
- **The environment.** Plain git reads its global config and attributes from `XDG_CONFIG_HOME` when that is set,
  so the call passes it through (only when set, and only as an absolute plain path) and refuses
  `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`, `GIT_CONFIG_NOSYSTEM` and `GIT_ATTR_NOSYSTEM`: a commit must see the
  same clean filters plain git would apply, or it stores raw what plain git would scrub. The cost: a Windows
  `XDG_CONFIG_HOME` in its usual backslash form stops every call, and the app must be relaunched before the Bash
  tool sees a changed variable.
- **The script keeps its own copy of the release header's first three keys** with `GIT_LFS_SKIP_SMUDGE` and a
  `GIT_CEILING_DIRECTORIES` of the args folder; it has neither the bare-repository key nor the MSYS unset, since
  every git command in it names its repository. The copy is not read from the header, so the protocol asks that
  it be checked whenever the header changes.
- **Rejected alternatives:** running the project's hooks in a released form, or stopping where one exists (the
  first runs arbitrary code inside the check; the second makes hook-framework projects unusable); shell written
  out for every caller; defending against a hostile member (deferred, ADR 0017).

## Consequences

**Costs, all told to the human in the README** and in the protocol's *Limits, and what they cost*:

- **Filters.** A project using Git LFS, git-crypt, `nbstripout` or any clean, smudge or process filter, in any
  scope, cannot take through devhouse a unit that writes a path naming the driver, or a `commit` of such a path.
  The human commits and merges those paths outside the team. The check over-matches, and each over-match fails
  closed.
- **A pre-commit guard is skipped** on every devhouse commit and merge. The script prints a note; the human runs
  the guard over the commits since the last push, not only the current files, since a secret committed and later
  removed stays in history.
- **Stops:** the index refresh stop, the sparse and skip-worktree stop, and the merge-state and stale-lock stops,
  each with nothing moved and its recovery.
- **Day one:** the remote and branch keys, an editor's merge base, a hook framework's `core.hooksPath`, stale
  `worktrees/<id>` entries; a second machine's missing salt; a home on a volume without hard links.
- **Absorbed submodules** give a `submodule dir modules` hit at every merge, commit and wake, judged each time
  and kept. A worktree config, a `hook.*` key or a submodule's own config with an include holds every merge until
  removed or fixed by hand; a hard link or a planted `core.hooksPath` is judged at every merge until removed; a
  partial clone cannot merge.

**Stated limits** (the protocol's, with the reasoning behind each class):

- **What it cannot see:** a member's tools outside git; the contents of steering files (it flags a change); an
  untracked steering file other than `.gitattributes`; global and system config beyond driver names, hook
  commands and, at a commit, attribute files; HEAD's reflog. Each needs either reading what only the project
  understands or a hostile writer.
- **When it runs:** at merges, commits and wakes. A hook planted and used between them, a junction made between
  the leading-folder check and `read-tree -u`, a lock made between the check and the write, and a work-tree file
  edited between `commit`'s checks and its `add` are windows that need a hostile writer with a stopwatch. A lock
  is the exception: a background git (an editor's `git status`) takes `index.lock` routinely, so that window is
  also an accident, and its outcome is told in the protocol's costs and the README. Check-ins pause while the
  team waits on the human.
- **What it settles for:** an allowed command pins its string, not the program; nothing audits a merge made past
  a hit beyond its run file; the transcript audit covers only the developer and the designer; the salt's secrecy
  rests on a single user; a stop after `update-ref` leaves the branch moved, the index at the old tree and the
  work tree part-written, with a note and a recovery run by the human.
- **Defence in depth, not guarantees:** the `submodule dir` hash, the `commondir` stop, the include hits, the
  junction re-checks and the blanked filter and merge-driver commands, under ADR 0017.
- **Outside the script:** the manager's other git commands run without the hook pairs, so a config hook running
  there is a stated limit. The script itself lives in the writable plugin cache, and *Detection* watches writes
  there.
- **The test's exit rule:** the harness exits 0 with no `FAIL`, lists every `SKIP` and prints it as unproven (the
  native-symlink variants need a Windows privilege; `icacls`, second-volume and 8.3 cases skip without their
  prerequisites), and a prerequisite without which nothing can run exits 2. Unproven: the system config scope and
  the system attributes file, native symlinks, Git LFS and git-crypt themselves, a reftable checkout, Linux and
  macOS, a mapped network drive.

## Amendments

- **ADR 0013 (the release stage),** its *Trust, stated* sentence leaving a planted `.git/shallow` and a local
  config the stage does not neutralise as stated limits for the tripwire to watch: the tripwire watches them at
  merges, commits and wakes, including the release's own unit merges and the hands-off merge, and not inside the
  release stage's calls, where the final scans stay the backstop.
