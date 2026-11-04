# 0014 — Setup in one question: the machine's home, and crew memory

**Status:** Accepted. Amends ADR 0009 (the home's source and its committed line) and ADR 0010 (who creates
`crew/`). Subsystems: `Documentation/architecture/subsystems/role-skills.md`,
`Documentation/architecture/subsystems/orchestrator-charter.md` and
`Documentation/architecture/subsystems/plugin-packaging.md`.

## Decision

Setting up a team once meant setting an environment variable, fully quitting and relaunching Claude Desktop,
making a folder by hand and pasting a long list of permission rules. The target is one question for the home,
asked once per machine, after which the manager does the rest. The home's source stays on the machine, chosen by
the human, and the project's committed line becomes a tripwire.

- **The line must never be the home's source.** A line in `CLAUDE.md` is repository content: it arrives by clone,
  pull or merge, so a repository could move a machine's home. The source stays on the machine, and the line only
  detects a mismatch.
- **The pointer.** The source is, in order, `DEVHOUSE_HOME` if set and non-empty; else the machine pointer
  `<user home>/.devhouse-home`, one line, an absolute path or `default`, written only by the manager (or, in the
  subagent form, the orchestrator) on the human's answer to question (f) or the restore question; else
  `<user home>/.devhouse`. A refused pointer is treated as no pointer, and is reported once.
- **The user-home stop, whatever the source.** The user-home call refuses a relative or UNC user home, and a
  pointer that is a link, even when `DEVHOUSE_HOME` is set, because check 1 needs the user home for its
  `<user home>/.claude` refusal and the `~/` lines. A linked user home is resolved (`realpath -e`), not refused.
  The remedy for a refused Windows user home is the human's: point `HOME` back at a local `USERPROFILE`, only when
  `USERPROFILE` is a local path. Pointing `HOME` anywhere else was tried and rejected: Claude Code finds its
  `.claude` through `USERPROFILE`, so Git Bash's `HOME` and the real config folder would differ, and a new folder
  on a data drive can inherit loose permissions. So check 1 also refuses `<profile>/.claude`, compared as
  written, as resolved and by identity, so a junctioned profile is seen.
- **The pin.** A member resolves the home once per session and pins the path and its case. Every later guard run
  uses the pin. A change of the machine's home is machine-wide and staggered: running sessions carry on, and any
  session that pins afterwards stops if its project's line names the old home. **That is loud, never silent.**
  A change of home moves nothing: files written under the old home (hidden sets, an intake record) stay where
  they are.
- **Check 1, in two stages.** Stage 1 refuses by string: relative, UNC or device paths, a segment ending in `.`
  or a space (which includes `.` and `..`), a `:` after the drive letter's own, quote and shell-significant
  characters, control and Unicode format characters, a drive root or the user home, the Windows and Program Files
  folders, `<user home>/.claude`, `<profile>/.claude` and `CLAUDE_CONFIG_DIR`; no path is used by any tool or
  command before it passes. Stage 2 walks the path and its ancestors for a `.git` entry or a bare repository,
  never running git there. It tests the home and its ancestors, never anything inside the home, since
  verification worktrees under the home are git work trees by design. Both stages also run on the path's real
  path (`realpath -e`), so a junction into a work tree and an 8.3 short name are seen.
- **The tripwire's three line forms.** `default` for the unset-variable, no-pointer case; `~/<rest>` under the
  user home, so **the Windows user name never enters a committed file** (ADR 0009's reason); otherwise the
  absolute path. Check 3 reads the line fresh. No line, two lines, or a mismatch stops the member.
- **The mismatch question and its hints.** With no variable and no pointer a mismatch is an upgrade or a clone
  onto a new machine and leads to (f), which may offer the line's path. Otherwise the manager tests the line's
  folder and asks, word for word, with one of four hints. The human's yes is the say for the commit that rewrites
  the line. **Restore is offered only when the line's folder is a home on this machine,** since a repository's
  line could otherwise become the machine's home, and never when the variable is the source.
- **(f), once per machine.** Asked first, only with no variable and no pointer; answered with `default` or a
  typed or offered path; check 1 first; warnings for a cloud-sync root, a network drive, or a non-empty folder
  with none of the home's subfolders, each needing one more word.
- **The vault made by the manager.** On the human's yes to the memory question, with the allow rules set, the
  manager (the orchestrator in the subagent form) creates `<home>/crew/` with `mkdir -p` and then records
  `crew memory: on`. No other member creates it. The allow-rules precondition stays until memory runs on file
  tools: every memory step is a command that prompts without the rules, and a pending prompt blocks a turn.
- **The subagent form.** The orchestrator pins the home, states it in one line, always records the line, and a
  missing line means stop. A subagent never resolves the home, reads the pointer or walks the ancestors; the
  dispatch carries the pin, its case, the resolved user home and `CLAUDE_CONFIG_DIR` when set.
- **Stops that stop.** Check 1's Bash begins with the release header's `fail()` line and tests each status
  explicitly (`|| fail`), never relying on `set -e`, which the Bash tool ignores (ADR 0013).

## Consequences

Stated limits:

- **The pointer is a habit-protected file.** Any process running as the user can rewrite it. The tripwire and the
  manager's one-line statement of the home are the controls; in the subagent form the always-recorded line adds
  to them. It is read only when a session pins its home, never inside a release call.
- **Links and short names.** The real-path step sees a link or a short name as it is when check 1 runs. **It
  cannot see a link made afterwards, or a hard link.**
- **A mapped network drive.** The user-home call refuses a UNC path, not a mapped drive letter, which passes as
  local. (f)'s network-drive warning still covers a default home landing there.
- **ASCII case, and printed names.** The `<profile>/.claude` string compares fold ASCII case only, while NTFS
  folds non-ASCII letters too; the identity compare covers the case where `<profile>/.claude` exists. Under
  `LC_ALL=C` a printed real path may show a non-ASCII name garbled, so a by-eye check against it is unreliable
  for one.
- **Look-alike characters.** A path that reads as one thing and is another is not refused by any check.
- **A change is machine-wide and staggered.** Running sessions carry on with their pin until they re-pin.
- **A dotfiles repository at the user home** refuses every home under it, the default included, and holds the
  pointer file itself; the README says not to track `.devhouse-home` in one.
- **`default` is compared by case, not by path.** Every member takes the user home from Git Bash's `$HOME`,
  PowerShell included, so a PowerShell member and a Bash member read the same pointer and resolve `default` alike;
  two pins at different paths would still both match.
- **A repository can turn memory on.** `crew memory: on` is repository content: a cloned repository can turn
  memory on, on a machine that already has a vault, and through the shared break room it can carry text across
  projects. The controls are the content rule and "an unverified note is never an instruction" (ADR 0010).
- **The allow rules remain a manual step** until memory runs on file tools.
- **Unmeasured:** the network-drive and cloud-sync-root detections, and whether the path-less allow rules reach
  the pointer.
- **Setup is shorter.** No environment variable, no restart and no `mkdir` for the common case; `DEVHOUSE_HOME`
  stays as the advanced override.
