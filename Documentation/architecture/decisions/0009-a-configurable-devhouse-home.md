# 0009 — A configurable devhouse home

**Status:** Accepted. Amended by ADR 0014: the home's source gains a machine pointer, and the committed
`devhouse home:` line becomes a tripwire. Subsystems: `Documentation/architecture/subsystems/role-skills.md` and
`Documentation/architecture/subsystems/plugin-packaging.md`.

## Decision

The hidden-test sets, the reviewer's validity notes and the verification worktrees were hard-coded to
`$HOME/.devhouse/`, which on Windows is on the system drive. Every unit writes a fresh hidden set and at least one
worktree there, so the folder fills the drive that can least spare it, and nothing let a user move it. The
devhouse home becomes configurable, and a team never splits across two homes.

- **A configurable home.** `<devhouse home>` is the environment variable `DEVHOUSE_HOME` if set, else
  `$HOME/.devhouse`. The hidden sets, the validity folders and both kinds of verification worktree sit under it.
  The rule lives once, in the protocol's *Tests* → *The hidden set*; every other path cites it. The variable is
  read when Claude Desktop starts, so changing it needs a full quit and relaunch.
- **One home per team.** The manager records `devhouse home: <resolved path>` in the project's `CLAUDE.md`, or
  `devhouse home: default` when the variable is unset. **`default` exists for a reason: it keeps the Windows user
  name out of a committed file.** The copies she passes on in `background` and first pointers are for
  information only; the line in `CLAUDE.md` is the one the guard checks. A team must never split across two
  homes, because a hidden set written under one and read under another is a silent failure. Changing the home is
  the human's say, between units; earlier sets stay where they are.
- **The guard checks four things** before a member reads or writes under the home: the home resolves to an
  absolute path (a drive letter followed by `/`, or a leading `/` on other systems), which catches a
  `%USERPROFILE%` stored literally; it is outside the shared checkout; it equals the line in the shared
  checkout's `CLAUDE.md`, read fresh each time; and the resolved path is used everywhere. No line, or a
  mismatch, stops her and she tells the manager. "Equals" is a normalised comparison (backslashes to `/`,
  trailing `/` dropped, case-insensitive), so a PowerShell resolution and a Bash resolution of one folder match.
  Every member runs the guard for her crew memory too (ADR 0010), and there a failed guard means skip, never
  stop.
- **Stated limit: `default` matches by case, never by path.** It matches when the member's variable is unset, so
  two shells that resolve the default to different folders are not caught.
- **Detection follows the home, whatever its prefix.** The manager's transcript audit searches, after
  normalising separators and case-insensitively, for `hidden-tests/<project>`, `verify/<project>-`, the home
  variable's name followed by `/hidden-tests`, `/verify` or an off-limits crew folder (ADR 0010), and the
  literals `.devhouse/hidden-tests` and `.devhouse/verify`, which are always searched. A fixed `.devhouse/`
  pattern alone would go blind the moment the home moved.
- **Cleanup holds.** Verification worktrees are removed after each run. The hidden-set folders are kept after the
  merge; removing them is the human's call.

## Consequences

- **A drive can be chosen,** at the cost of one more line in `CLAUDE.md`, one more environment variable and a
  guard check.
- **A new failure mode: a stopped member.** A member whose setting differs from the recorded line, or who finds no
  line, stops at the guard and tells the manager. Loud and early beats a team split across two homes.
- **Unmeasured.** Whether a full quit and relaunch is always enough for sessions reopened afterwards to see a
  changed variable; a session whose environment lacks the variable has not been tested.
- **The audit still sees literal access only.** The patterns widen what a literal path can look like; a path
  assembled in a shell variable is still invisible (`subsystems/role-skills.md` §9 Gotchas).
