# devhouse 1.0.0

This is the first public release of devhouse, a Claude Code plugin that gives a project a small software team: a manager who plans and gates the work, and specialists who design, build, test, review, secure and release it.

## What it is

- **A co-PM orchestrator and seven specialists.** Run `/devhouse` and the session takes the manager's role. Pris plans, Delia designs, Dahlia builds, Tessa tests, Roxy reviews, Shiro checks security and Remi checks what ships and how text lands with its reader.
- **Two forms.** In the *subagent form* one session dispatches the specialists. In the *session form*, which needs Claude Desktop, every member is its own session in a sidebar group, with a role skill (`/devhouse:manager` and one per specialist), and the manager routes the work between them.
- **Three tracks.** Build (a greenfield project, one step at a time), Maintenance (discrete changes to existing code) and Track 0 (a one-time documentation project when you adopt a codebase cold). A fixed documentation standard gives "documented" one checkable meaning.
- **Gates.** A human approval between steps, a three-iteration cap, a review before work counts as done, and a security review for work marked security-relevant.

## What 1.0.0 brings together

- **Project start and the spec flow.** A team can begin from nothing: a brief, a recommendation you approve, then a specification the team drafts, reviews and locks in numbered revisions.
- **Units of work.** Each build step or task runs on its own branches in separate git worktrees. The developer freezes a commit, the reviewer and tester work on exactly that commit, and the manager merges only when the review, the tests and any security review have passed.
- **Hidden tests.** The tester keeps a second set of tests outside the repository until the unit has passed review and testing, and then commits it, so passing the visible tests is not enough. The protection is detection, not prevention: the reviewer looks for special-casing, and the manager searches transcripts for access.
- **A security reviewer.** Shiro threat-models each spec revision and reviews marked units. Her blocking findings block, and only you can waive them.
- **A release manager and a release stage.** Remi audits what would ship for private data, local paths, secrets, names, process traces and commit metadata. The release stage builds a fresh public repository from a pinned release commit, with one public history that is never force-pushed, and a push that happens once per approval from you.
- **Text for people.** Members draft; they do not send. Drafts for outside readers are checked for the data and for how they will land, and posting is only ever on your approval.
- **Research intake.** Whatever a member brings in to use (a dependency, copied code, a cloned repository, a download) is shown to Shiro first. A checker script the plugin ships validates every field, archive and fetched tree.
- **The git tripwire.** A script the plugin ships looks for hooks, filters, links, submodules and risky config before every merge and manager commit, and holds the merge until Shiro or you judge the hit.
- **One devhouse home per machine.** Hidden tests, verification worktrees, drafts and release records live in a folder you choose once, outside every repository.
- **Crew memory and a break room (optional, off by default).** Each member can keep a small bounded memory of how she works, and the team shares a file for short social notes. Neither holds project content.
- **Voices and values.** Each member has a distinct voice and a ranked list of cares. They shape attention and tone, never authority.

## Requirements

- Claude Code. The session form needs Claude Desktop.
- Git 2.45.3 or later for the release stage and the git tripwire. Research intake that contacts a remote (a clone, or a look-up of a branch or tag) needs git with the July 2025 fixes: 2.43.7, 2.44.4, 2.45.4, 2.46.4, 2.47.3, 2.48.2, 2.49.1, 2.50.1, or 2.51 and later.
- For research intake: Python 3.9 or later (the `python` binary, not the Windows Store stub), and GNU `mv`, `sha256sum` and `timeout`. On Windows the GNU tools come with Git Bash; Python does not, and without a usable Python every intake is refused. A Python package's vulnerability scan also needs `pip-audit`, and unpacking an archive needs a recent Python patch release. The README's *Bringing things in* has the details.
- For the git tripwire: Git Bash (or bash 4 with GNU `sed`, `sort`, `find`, `cmp`, `gawk`, `sha256sum`, `ln`, `stat` and `mktemp`), and a devhouse home on a volume that supports hard links.

## Install

```
/plugin marketplace add Cring-von-Conman/devhouse
/plugin install devhouse@devhouse
```

The README covers setting the devhouse home, standing up a team and releasing a version.

## Known limits

- **The session form is heavy.** Every member carries the whole team protocol and every unit gets its full set of reviews and tests, so even a small project takes hours and a lot of usage. A lighter mode, with review depth set by project size, is planned for the next version, along with per-member rules and per-unit cost reports.
- **Devhouse guards against accidents, not a hostile team member.** In the session form every member has full shell access as you. Anything that needs someone to tamper with your `.git` on purpose is a stated limit. Checks are habits the team keeps and scripts it runs, not enforcement by the plugin.
- **The tripwire has a cost.** A project that uses Git LFS or another clean or smudge filter cannot take changes to filtered files through devhouse, and a project's own pre-commit hooks do not run on the team's commits. The README says what to do instead.
- **Release prompts.** In a mode that prompts, a release asks for many approvals. In a mode that does not, nobody checks the specialists' commands one by one. The README says what is covered and what is not.
- **Platforms.** Developed and checked on Windows with Git Bash. Other platforms and other Python versions are untested.

## Licence

MIT. See `LICENSE`.
