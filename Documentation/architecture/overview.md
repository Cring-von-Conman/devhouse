# devhouse — Architecture Overview

## 1. Purpose

devhouse is a portable "dev-house" for Claude Code: a co-PM orchestrator role plus seven
named specialist agents, packaged as a Claude Code plugin that drops into any project on the
machine. It provides opinionated build, maintenance, and cold-adoption (Track 0) workflows
and a fixed documentation standard, so that orchestrated multi-agent development follows one
checkable process regardless of project, and it contains no application code — just markdown
agent/command/skill definitions consumed by the Claude Code plugin loader at runtime, apart from two
shipped scripts, `plugins/devhouse/team/intake-check.py` (research intake's checks; it needs Python 3) and
`plugins/devhouse/team/git-tripwire.sh` (the git tripwire's checks; it needs Git Bash or GNU tools and `gawk`),
and three verification files, `tools/check-frontmatter.py` and the two shipped scripts' tests. It runs
in two forms: the single-session form (`/devhouse` dispatching the seven as subagents) and a
session form for Claude Desktop, where each of eight members (the seven plus the manager, Makima)
is a skill a separate session loads (`/devhouse:<role>`). One of the seven, Shiro, is the security
reviewer: she asks only "is this secure?", which neither the reviewer nor the tester asks. Another,
Remi, is the release manager: she asks two questions, is the data right for its reader and how will
it land, audits what would ship for private data and checks text going out to people, and never
sends, posts or pushes; in a release she also builds the public tree, and the manager makes
the one push (the orchestrator, in the subagent form), on the human's approval. Bare `/devhouse` offers both forms in
Claude Desktop. In the session form the manager can also found a new project (brief, repo, sidebar
group), open the other members herself, and run a spec flow (draft, review, lock) before any
build step. Each build step or maintenance task then runs as a **unit**: its own branches and
git worktrees, a hidden test set, and a reviewer who audits the team's files and git on a timer.

## 2. Tech stack

| Layer | Choice | Version |
|---|---|---|
| Runtime / host | Claude Code plugin + subagent runtime | host-provided // VERIFY (the plugin cannot introspect the installed Claude Code host's own version number) |
| Command definition | Markdown + YAML frontmatter (slash command) | n/a |
| Agent definition | Markdown + YAML frontmatter (subagent persona) | n/a |
| Skill definition | Markdown + YAML frontmatter (`skills/<role>/SKILL.md`, session form) | n/a |
| Session-form host | Claude Desktop (session-management, sidebar and cross-session messaging tools) | host-provided // VERIFY (version not introspectable by the plugin) |
| Packaging manifest | JSON (`plugin.json`, `marketplace.json`) | the `version` in `plugin.json` |
| Orchestrator model | Opus | host-selected // VERIFY (which specific Opus model build the host assigns to the orchestrator session is a runtime/session detail this repo does not declare and the plugin cannot introspect) |
| Specialist models | Opus (Pris, Roxy, Shiro) / Sonnet (Delia, Dahlia, Tessa, Remi) | per-agent `model:` field |
| Build tooling | None | — |
| Shipped script | Python 3 (`plugins/devhouse/team/intake-check.py`, research intake's checker; standard library only; installed with the plugin and run by the team's members, which need a `python` and GNU tools on the machine; archive extraction needs the patch release of its line) | 3.9 or later |
| Shipped shell script | Bash (`plugins/devhouse/team/git-tripwire.sh`, the git tripwire's checks; installed with the plugin and run by the manager, the reviewer and the orchestrator, which need Git Bash or bash 4 with GNU `sed`, `sort`, `find`, `cmp`, `stat`, `mktemp`, `ln`, `sha256sum`, `gawk`, and git on the machine) | bash 4 or later; git 2.45.3 or later |
| Test tooling | None, apart from three verification files, `tools/check-frontmatter.py` (see the next row), `tools/tests/intake-check/run.py` (the intake script's test; standard library only; `python -I -S -B`) and `tools/tests/git-tripwire/run.sh` (the tripwire script's test; `bash`) | — |
| Verification script dependency | Python 3.12 or later with PyYAML (`tools/check-frontmatter.py`, verification only; not installed with the plugin) | installed by hand, with no lockfile |
| Lint/format tooling | None | — |

Apart from the verification script's PyYAML dependency (installed by hand, with no lockfile), there is no compiler, package manager, or dependency lockfile in this repo. The only
"runtime" is the Claude Code plugin/agent loader (and, for the session form, Claude Desktop),
whose version is host-provided and not declared here.

## 3. Subsystem map

- **orchestrator-charter** (`subsystems/orchestrator-charter.md`) — the `/devhouse` slash
  command: defines the co-PM role, advisory/loop modes, the three tracks (build /
  maintenance / Track 0 onboarding), the invariants and guardrails, and the documentation
  standard. The control plane.
- **specialist-roster** (`subsystems/specialist-roster.md`) — the seven subagent persona
  files (Pris, Delia, Dahlia, Tessa, Roxy, Shiro, Remi) the orchestrator dispatches; each defines a role,
  a model tier, and a tool allowlist. The workers.
- **role-skills** (`subsystems/role-skills.md`) — the session form: eight skills
  (`skills/<role>/SKILL.md`) plus the shared discovery protocol and coordination habits
  (`team/protocol.md`), letting separate Claude Desktop sessions each take one role and work as a
  team, found by sidebar group and role title. The manager also founds projects and runs the spec flow
  (project start, opening members, spec revisions); the protocol also carries the unit mechanics
  (branches and worktrees, tests and the hidden set, check-ins). Claude Desktop only. The
  multi-session workers.
- **plugin-packaging** (`subsystems/plugin-packaging.md`) — `marketplace.json` +
  `plugin.json`: how the plugin is declared, discovered, and installed into a Claude Code
  session. The distribution layer. It also owns the frontmatter check, `tools/check-frontmatter.py`
  (a script run by hand, outside `plugins/`), the shipped intake checker `team/intake-check.py` and its test
  `tools/tests/intake-check/run.py`, and the shipped git tripwire script `team/git-tripwire.sh` and its test
  `tools/tests/git-tripwire/run.sh` (the tests are outside `plugins/`; not installed).

Interaction in one line: **packaging** installs the plugin, which registers the
**orchestrator-charter** command, the **specialist-roster** agents and the **role-skills**; at
runtime the charter dispatches roster members and gates their output, or — in session form —
the manager skill adopts the charter and routes work between separate sessions that each adopted a
roster member's agent file.

## 4. Primary data flows

**Flow A — Session invokes /devhouse (activation).**
User runs `/devhouse` in a Claude Code session → the host loads
`plugins/devhouse/commands/devhouse.md` as the active instruction set → in Claude Desktop the
charter's first step asks "Sessions or Subagents?", with three options, *Subagents*, *Sessions* and
*Sessions in windows* (without `get_session`, the CLI, it proceeds as the subagent form without asking; both
session answers read the manager skill instead and carry the window choice, see Flows E and F)
→ the main session assumes the co-PM/orchestrator role → it orients from `## Current status & next step` in the
project's `CLAUDE.md` if present, states current status in a few lines → **defaults to
advisory mode and waits** (`devhouse.md`, "On activation:"). No agents are dispatched on activation.

**Flow B — Orchestrator dispatches a specialist.**
In loop mode the co-PM writes a work order to
`Documentation/dev-prompts/<NN>-<slug>/<NN>-<slug>.md` (numbered for build steps, descriptive slug for
non-build tasks; its folder holds all its artefacts, and the layout is `team/protocol.md`, "Files") → fires it with a short pointer, e.g.
`@dahlia: implement Documentation/dev-prompts/01-scaffold/01-scaffold.md exactly; read no other docs for implementation guidance.`
(`devhouse.md`, "File-based handoff (no clipboard relay)") → the host auto-dispatches by matching the handle or the task type against
each agent's `description` frontmatter (`devhouse.md` § "The dev house roster", "Auto-dispatch routes by task type"; Remi is invoked only when named) → the specialist runs with only its
allowlisted tools → returns output to the orchestrator. Specialists cannot dispatch each
other; in this single-session form only the co-PM dispatches (`README.md`, "which can't dispatch each other"). In session form no member dispatches a subagent either (the manager only with the human's approval for that step); see Flow E.

**Flow C — Work order: creation → implementation → audit (build track).**
Read current step from `CLAUDE.md` `## Current status & next step` → ensure/author a work
order (dispatch **@pris** first if design/spec work is needed, then **@shiro** threat-models what
she produced) → dispatch **@dahlia** to implement → verify against the step's **Done** gate:
**@roxy** audits correctness/consistency, **@shiro** reviews for security where the work order is
marked security-relevant, **@dahlia** runs gate commands, **@tessa** writes/runs tests (skipped for pure
scaffolding) → blocking issues loop back to @dahlia, **capped at 3 iterations** then STOP →
on a clean gate, update `CLAUDE.md`, produce/update the subsystem doc if a subsystem changed
(Roxy validates it), `git commit`, summarize, and **STOP for the human gate**
(`devhouse.md` § "Build track — greenfield (project build order)", steps 1–7). In the session
form the same loop runs as a unit with branches, hidden tests and check-ins (Flow H).

**Flow D — Track 0 onboarding (cold adoption).**
For a codebase the dev-house did not build: run a one-time onboarding *project*, subsystem by
subsystem with a checkpoint per subsystem → **@pris** structures the map → **@dahlia** reads
the code and *executes* every build/lint/test/run command to verify it → **@roxy** audits
each subsystem doc against the actual code and the documentation standard → output is a doc
set conforming to the standard (`overview.md` + one `subsystems/<name>.md` per subsystem)
plus a populated `CLAUDE.md`. Human-gated per subsystem; proposed, not silently run
(`devhouse.md`, "Track 0 — Onboarding (adopting an existing codebase)"). This very document is the product of Flow D applied to devhouse itself.

**Flow E — A team forms in Claude Desktop (session form).**
The user creates a sidebar group and opens one session per member in the project folder, files
each in the group, and runs `/devhouse:<role>` in each → the skill reads `team/protocol.md` and
runs its discovery protocol: get its own session record, take the sidebar group as the team,
list the group's sessions, keep those whose title is exactly a role title, refuse if its role is
held, claim its role title by renaming itself, re-check, report a team table, and announce itself
to the manager by `sessionId` → it stops and waits for the manager's pointer or the human. Work
then moves by a pointer from the manager to a member's session, the member writes an artefact under
`Documentation/dev-prompts/` and points the manager to it (`team/protocol.md`; rules and failure
modes in `subsystems/role-skills.md`). The manager can also open the other members herself with
`start_session` and `prompt: "/devhouse:<role>"`; a started session lands in her group, nested
under her, runs the same discovery and joins (Flow F, its last step; manager skill, "Opening members").

**Flow F — A project starts (session form, Claude Desktop).**
Bare `/devhouse` answered "Sessions" or "Sessions in windows" (or `/devhouse:manager` typed) in a folder with no `CLAUDE.md`
→ the manager asks for a 50,000-foot brief → reads the human's other sessions' folders for related
work → recommends, in one message, a folder, `git init`, the files, **two commits**, the move
and a new sidebar group, and asks approval for all of it at once → on approval she creates the
repo (`.gitignore`, `CLAUDE.md` with status `project start, step 5`,
`Documentation/brief/brief.md`) and commits → `change_directory` to the folder, which takes effect
at turn end, so she asks the six session questions (the first, where the machine keeps its devhouse files, only on a machine with no home yet; with `/devhouse:manager` typed, also the window question) and ends the turn → on the answers, in the new
folder: create the group and move herself in, run the discovery protocol (Flow E), record the
answers, the window choice (`member windows:`) and the team's devhouse home in `CLAUDE.md` with status `planning` and commit → open the whole planning set (the planner,
the reviewer, the security reviewer, the designer, the developer, the tester and the release manager) and point the planner
at the brief (manager skill, "Project start"; rationale in
[ADR 0004](decisions/0004-project-start-and-the-spec-flow.md)).

**Flow G — The spec is made, reviewed and locked (session form).**
The planner writes `Documentation/spec/r1/` with rough architecture docs → the manager's shallow
smoke check ("redo" or "pass", never a sign-off) → on pass she points the reviewer and the
security reviewer at the revision and sends the designer, the developer, the tester and the release manager a work notice (every role is asked
for concerns at each spec revision; a role the human declined is recorded as "not consulted") →
members send concerns to the manager
(never the planner) → she writes `r<k>/concerns.makima.md` → the reviewer reviews unbiased
(`review-1.roxy.md`), then checks the concerns (`review-2.roxy.md`), and the security reviewer
does the same in her own files (`security-1.shiro.md`, a threat model plus findings, then
`security-2.shiro.md`), neither opening the other's first review before her own → a fix is always a
new revision `r<k+1>/` → once a complete, non-halted set of four reviews has no blocking finding
the manager asks the human to approve (and, if the human declined opening the security reviewer, to
waive her missing review), and on yes records the locked spec and commits the planning documents
(`team/protocol.md`, "Spec flow").

**Flow H — A unit runs (session form).**
A **unit** is a build step `<NN>` or a maintenance task `<slug>`; `<u>` is either. Once its work
order has had the reviewer's pre-dispatch review, the manager creates `work/<u>` from the
**integration branch** (`main`, or `devhouse/hands-off`), points each builder the unit needs at it
and sends the reviewer an **active** pointer → each builder works in her own git worktree under
`.claude/worktrees/`, on her own branch (`work/<u>` the developer, `design/<u>` the designer,
`tests/<u>` the tester), and tells the other builders which shared files she will touch; the tester
also writes a **hidden set** outside every repo → when every builder reports done, the developer
merges the others' branches and records `ready: <sha>` (the **freeze**) → the reviewer reviews
exactly that SHA while the tester runs the visible and hidden tests in a **verification worktree**
at it, reporting a hidden failure by requirement and class of input, and, where the work order is
marked **security-relevant**, the security reviewer reviews it too, never reading the hidden set →
blocking findings return to the developer
(**capped at 3 iterations**) → on a pass (both, where marked) the tester commits the hidden set, the developer
re-freezes, and a **confirmation review** names the new SHA and checks that the re-freeze changed only the hidden folder → the manager runs the
**git tripwire** on the unit (its `check-unit`: links, submodules and steering files the unit adds, and the shared
checkout's `.git`) and any hit it prints is judged by the security reviewer first → the manager asks the human to approve
the merge (in hands-off the standing approval covers it), merges with the tripwire's `merge-unit` (a `--no-ff`
merge commit, not `git merge`), commits the
unit's artefacts (in the tripwire's `commit` mode), sends the cleanup pointers, and deletes the unit's branches. While a unit is
active the reviewer audits files and git about every 15 minutes, running the tripwire's `check-checkout` as one of its
conditions (`team/protocol.md`, "Units and
branches", "The git tripwire", "Tests" and "Check-ins"; rationale in
[ADR 0005](decisions/0005-units-of-work-in-the-session-form.md) and
[ADR 0015](decisions/0015-the-git-tripwire.md)).

## 5. Cross-cutting concerns

- **Auth** — None. This repo has no accounts, tokens, or secrets. Authorization exists only
  as a *conceptual* capability model: in subagent form each agent's `tools:` frontmatter is an
  allowlist (e.g. Pris and Roxy get no `Write`/`Edit`/`Bash`; Shiro gets `Bash` for scanners and git, and no `Write`/`Edit`; Remi gets `Bash` and `Write` (she writes her release files, never code), and no `Edit`), enforced by the host runtime (when the frontmatter parses, `subsystems/plugin-packaging.md` §9), not
  by code here. In session form there is deliberately no tool restriction: a role session holds
  its session's tools and its method keeps it to its role (`subsystems/role-skills.md` §7 Invariants & constraints).
- **Config** — Minimal and static: the JSON manifests (`plugin.json`, `marketplace.json`)
  and per-file YAML frontmatter. No config files consumed at runtime by this repo's own logic (its
  scripts, `tools/check-frontmatter.py` and the shipped `team/intake-check.py`, read no config file), and one optional environment variable, read by the session form's members and not by
  any code here: **`DEVHOUSE_HOME`**, which moves the folder for the hidden sets, verification
  worktrees, `release/` and `crew/`. Without it the folder comes from the machine pointer
  `<user home>/.devhouse-home`, which the manager writes on the human's answer to the first session
  question, else it is `$HOME/.devhouse`; the rule is in `team/protocol.md`, "Tests", *The hidden
  set*; [ADR 0009](decisions/0009-a-configurable-devhouse-home.md);
  [ADR 0014](decisions/0014-setup-in-one-question.md)). Crew memory has two switches: it
  is on only when the project's `CLAUDE.md` has the line `crew memory: on` (the manager records it on
  the human's say) **and** the folder `<devhouse home>/crew/` exists (the manager makes it on the human's yes); the
  project's `CLAUDE.md` can add the line `break room: file only` to stop live messages (`team/protocol.md`, "Crew memory"; [ADR 0010](decisions/0010-crew-memory-and-the-break-room.md)). In the session form the
  runtime config is the sidebar group a session is filed in and the host project's `CLAUDE.md`,
  which records the session questions' answers and the team's `devhouse home:` line
  (`subsystems/role-skills.md` §5 Observability).
- **Logging** — None in this repo's code. The shipped tripwire script, `team/git-tripwire.sh`, writes no log
  either: its output is lines on stdout (`git tripwire: args <mode>`, hit lines, `note:` lines, a `tip` line or a
  stop label) and a record under `<devhouse home>/tripwire/<project>/` the manager writes from it (`runs/`,
  `removed/index.txt`). The shipped checker script, `team/intake-check.py`, writes no
  log: its only output is one line on stdout (`intake-check: pass`, `pass, yanked` or `refused`), with nothing
  on stderr (`team/protocol.md`, "Research intake", *The checker script*). The single-session form relies on host transcripts
  and telemetry, out of scope. The session form uses the host's per-session transcripts as its
  message log: each cross-session message is recorded as a turn in the *receiver's* transcript
  (`~/.claude/projects/<working directory, every character that is not a letter or digit replaced by ->/<session id>.jsonl`, one JSON
  object per line), readable with `grep -rl 'cross-session-message' ~/.claude/projects` or in
  the app. Details and the read commands (`list_events` is the host-native read; the `grep` form is Git Bash/POSIX): `subsystems/role-skills.md` §5 Observability.
  With crew memory on, the members also write plain markdown under `<devhouse home>/crew/`: one
  `worklog.md`, `mistakes.md` and `crew.md` per member, and the shared `breakroom.md`, each line
  stamped in UTC (`YYYY-MM-DDTHH:MM:SSZ <member> [<project folder>]: <text>`). Read it with any
  text reader or by opening `crew/` as an Obsidian vault; the files, bounds and rolling are in
  `subsystems/role-skills.md` §5 Observability.
- **Error handling** — Process-level, not code-level. The charter's guardrails are the error
  policy: the **3-iteration cap** stops thrash loops (`devhouse.md`, "Cap: 3 iterations." and "Iteration cap within a step (3)"), the **human gate**
  stops runaway autonomy, and the **`// VERIFY` rule** stops guessed constants from being
  treated as authoritative (`devhouse.md`, "Verify real-world constants."). There is no exception handling because there is
  no executing code (the verification script `tools/check-frontmatter.py` reports problems as `FAIL` lines and
  exit codes; the shipped `team/intake-check.py` refuses with its one `intake-check: refused` line and exit 1, and
  every caller turns that into a `|| fail 'intake: <label>'` stop, because the Bash tool ignores errexit; the shipped
  `team/git-tripwire.sh` stops with `git tripwire: <label>` from a closed list and exit 1, and its caller adds the same `|| fail`).
- **Background jobs** — None in this repo's code. In the session form one thing does run on a
  timer, while a unit is active: the reviewer's **check-in** wake, a self-chaining one-shot
  `CronCreate` job about every 15 minutes that audits the team's files and git and ends her turn;
  it is cancelled whenever the team waits on the human, and jobs are session-only
  (`team/protocol.md`, "Check-ins"; [ADR 0005](decisions/0005-units-of-work-in-the-session-form.md)).
  With crew memory on, that wake also makes the break room's hourly post, a file append
  (`team/protocol.md`, "Crew memory" and "Check-ins").
  Nothing else runs unattended; every track is explicitly human-gated between steps/tasks. The
  one exception is the session form's **hands-off** mode, between build steps only (the
  maintenance per-task gate stands), where the human's standing approval lets the manager advance
  once a unit's checkpoint merge is made and merge each unit into the branch
  `devhouse/hands-off`; merging to main and approving the spec still wait for the human (manager
  skill, *Modes*; [ADR 0004](decisions/0004-project-start-and-the-spec-flow.md)).
- **State & persistence (cross-cutting)** — The dev-house writes state to *the host
  project*, not to this repo: `CLAUDE.md` (status; in the session form also the session
  questions' answers and the locked spec revision), `Documentation/dev-prompts/` (work
  orders), `Documentation/brief/` (the brief and conversation summaries), `Documentation/spec/r<k>/`
  (spec revisions, rough architecture docs, concerns, reviews), `Documentation/design/` and
  `Documentation/architecture/` (docs). In the session form the state also includes git
  branches (`work/<u>`, `design/<u>`, `tests/<u>`) with their worktrees under the project's
  `.claude/worktrees/` (git-ignored), and six folders **outside every repo and the plugin**, under
  the **devhouse home** (the environment variable `DEVHOUSE_HOME`, else the machine pointer `<user home>/.devhouse-home`, else `$HOME/.devhouse`; one home
  per machine, confirmed by the `devhouse home:` line in the project's `CLAUDE.md`, a tripwire and never the source):
  `<devhouse home>/hidden-tests/<project>/<u>/` (the hidden set; the sibling
  `<u>-validity/` holds the reviewer's validity notes) and `<devhouse home>/verify/<project>-<u>-<k>/`
  (verification worktrees, removed after each run; the security reviewer's, for scanners, are
  `<project>-<u>-sec-<k>/`, or `<project>-release-<version>-sec-<k>/` for a release pass), `<devhouse home>/release/<project>/` (the release manager's audit files,
  `audit-<date>.audit-<k>.remi.md`, and, in a release, the record of pins, audits, manifests, waivers and push
  outcomes (and, in the subagent form, the notes base), the filter's values file, and each version's rebuilt `public/` repo and its `work/` and `check-<n>/` folders, and a sealed call's scratch `tmp.*` folder, which the call removes), `<devhouse home>/outbound/<project>/` (drafts of text for people
  other than the team, reader files, summaries and the release manager's reviews of them) and, once the manager has made it, `<devhouse home>/crew/` (the
  members' memory and the break room: one vault per machine, shared by every project; on only with the
  `crew memory: on` line) and `<devhouse home>/intake/<project>/` (research intake: the manager's `passed.md`
  record and the `items/` folder of fetched material and staging folders; the security reviewer's
  intake folders are under `verify/<project>-intake-<k>-sec/`, and the hidden set's are under
  `hidden-tests/<project>/<u>-intake/` and `intake.md`); a plugin data
  folder was lost once, a reinstall being the likely cause, so none of them lives there
  (`team/protocol.md`, "Tests", *The hidden set*, "Crew memory", "Release" and its *Outbound to people*;
  [ADR 0009](decisions/0009-a-configurable-devhouse-home.md);
  [ADR 0010](decisions/0010-crew-memory-and-the-break-room.md);
  [ADR 0011](decisions/0011-a-release-manager.md);
  [ADR 0012](decisions/0012-outbound-to-people.md);
  [ADR 0013](decisions/0013-the-release-stage.md);
  [ADR 0016](decisions/0016-research-intake.md)). In the project, a release leaves in the private repo: the prep
  unit's version bump, `Documentation/release/<version>/release-notes.md` and `CHANGELOG.md`; the
  fix units' commits; the filter unit's permanent `release-filter/` folder (script, visible tests and
  committed hidden set); the committed `release identity:` line in `CLAUDE.md`, if it was missing; and the private tag
  `v<version>` on R, if the human said yes. Within this repo,
  all files are static definitions, apart from the verification script `tools/check-frontmatter.py`, the shipped
  checker `plugins/devhouse/team/intake-check.py`, the shipped tripwire script `plugins/devhouse/team/git-tripwire.sh`
  and the two tests. The git tripwire writes under `<devhouse home>/tripwire/<project>/` (the salt, `allowed`, `runs/`,
  `removed/`, the args folders) and the run files in the project's `Documentation/dev-prompts/`
  (`team/protocol.md`, "The git tripwire"; [ADR 0015](decisions/0015-the-git-tripwire.md)).

## 6. External integrations

- **Claude Code plugin/agent runtime** — the only external dependency. It (a) reads
  `marketplace.json` on `/plugin marketplace add`, (b) installs the plugin from `plugin.json`
  on `/plugin install`, (c) registers `commands/devhouse.md` as the `/devhouse` slash
  command, (d) registers each `agents/*.md` as a dispatchable subagent and routes to it by
  handle or `description`, and (e) enforces each agent's `tools:` allowlist and `model:`
  selection (subagent form), when the frontmatter parses (`subsystems/plugin-packaging.md` §9). Invoked implicitly everywhere; this repo ships no explicit API calls.
- **Claude Desktop** — the host of the session form, and a hard dependency of the `role-skills`
  subsystem only (plus the charter's first step, which probes for `get_session`). The skills call
  its session-management tools (`get_session`, `list_sessions`, `set_session_title`), its sidebar
  tools (`list_groups`, `move_sessions`) and its cross-session `SendMessage` tool, all via
  `team/protocol.md`; outside Claude Desktop the first step finds no `get_session` and the protocol
  tells the skill to stop with a message (untried for the role skills; bare `/devhouse` in the CLI
  is measured: no question, subagent form). The manager alone also calls `change_directory`,
  `create_group` (Project start), `start_session` and `open_session_in` (opening members). The
  reviewer alone calls the scheduling tools `CronCreate`, `CronDelete` and `CronList` for her
  check-in wakes. The single-session form does not need any of these.
- **git** — in the session form the manager runs `git init -b main` in Project start, makes the
  approved commits (founding, answers, planning documents), creates, checks out and, on the
  human's say, merges the branch `devhouse/hands-off`, and for each unit creates and deletes its
  branches and merges `work/<u>` into the integration branch through the git tripwire (`team/git-tripwire.sh`: a
  two-parent commit built with `commit-tree`, never `git merge`); each builder runs
  `git worktree add` for her own worktree, and the tester and the security reviewer each a detached
  verification worktree (`team/protocol.md`, "Units and branches"). In a release the release manager
  builds a fresh public repo with plumbing git inside `public/`, and the manager makes the one
  push to the remote the human names, once per approval (the orchestrator, in the subagent form), from a fresh bare repository
  and not from `public/` (`team/protocol.md`, *The release stage*, *The push*;
  the remote is the human's, and authentication is left to git). Otherwise referenced as the checkpoint mechanism in both loop tracks (`git commit` a
  checkpoint, `devhouse.md` § "Build track — greenfield (project build order)" step 6, and § "Maintenance track — existing code" step 6 "Gate"; in the session form the checkpoint is the unit's merge). It is a workflow instruction to the developer agent, not an
  integration this repo's code calls.
- No third-party HTTP APIs, SDKs, or services are called by this repo.

## 7. Build / run / test

There is no build, test, or lint step, apart from three verification files, `tools/check-frontmatter.py`, `tools/tests/intake-check/run.py` (the shipped intake checker's test) and `tools/tests/git-tripwire/run.sh` (the shipped git tripwire script's test) — this is a markdown/JSON plugin. "Running" it means
installing it into Claude Code and invoking the command. Commands below are from
`README.md` § "Install (user-global)".

```
# Install (user-global), from a Claude Code session:
/plugin marketplace add Cring-von-Conman/devhouse
/plugin install devhouse@devhouse

# Invoke, in any project on this machine:
/devhouse
```

- **Build:** None (no build system).
- **Test:** None (no test suite exists in this repo), apart from `tools/check-frontmatter.py` and the intake checker's test, run from the repository root as `python -I -S -B tools/tests/intake-check/run.py [<script path>]` (one line per case, a last line with the counts, exit 0 only if every case passes; run it on the working-tree bytes and again on the installed copy after a reinstall), and the git tripwire's test, run from the repository root as `bash tools/tests/git-tripwire/run.sh [<script path>]` with a scratch `HOME`, `TMPDIR` and `TW_VOLUME2`, each in POSIX form (`/d/…`, not `D:/…`) (one line per case, `pass`, `FAIL` or `SKIP <reason>`, a counts line and the list of what stayed unproven; exit 0 means no `FAIL`, and a skipped case never counts as a pass; about 15 to 35 minutes, depending on load, with its default parallel workers, not timed with `TW_JOBS=1`; a `TW_ONLY` run prints `partial run … not a full pass` and is never a gate's or a Verify's result; the same two runs).
- **Lint/format:** None (no linter configured).
- **Verification for this repo** means: (1) `plugin.json` and `marketplace.json` parse; (2)
  `/devhouse` activates (in Claude Desktop after the "Sessions or Subagents?" question) and enters advisory mode; (3) each `@handle` dispatches the correct
  agent with the correct tool allowlist; (4) for the session form, `claude plugin validate
  plugins/devhouse` passes, and it has been exercised in Claude Desktop for discovery and delivery, project
  start and the spec flow, units of work (worktrees, hidden tests, the audit, check-ins), the security
  reviewer, and voices and values, with some limbs unexercised. Crew memory and the break room, the configurable devhouse home, the machine's home
  setup, the release manager, outbound text, the release stage, voices in small messages, the window choice (`member windows:`), research intake and
  the git tripwire have **not been run by a team**; the two shipped scripts' tests pass
  (`python -I -S -B tools/tests/intake-check/run.py` and `bash tools/tests/git-tripwire/run.sh`); and (5) `python -I tools/check-frontmatter.py`
  (Python 3.12 or later with PyYAML) passes, which checks that every agent, skill and command frontmatter is
  strict YAML whatever its line endings, with `claude plugin validate` run on the CRLF tree
  (`subsystems/plugin-packaging.md` §9); the runtime check is the agent listing in a new session
  after a reinstall. See each subsystem's
  **Tests** section.

  Item (1) is checked with `python -m json.tool` on `.claude-plugin/marketplace.json` and
  `plugins/devhouse/.claude-plugin/plugin.json`. Items (2) and (3) cannot be run as shell commands
  (`/plugin marketplace add`, `/plugin install`, `/devhouse` and `@handle` dispatch are host
  mechanisms a Bash tool call cannot invoke); they are checked by hand in a session. An install
  from the public repository on a clean machine has not been exercised.

## 8. Conventions

- **File layout** — Marketplace repo at root holds `.claude-plugin/marketplace.json`; the
  plugin lives under `plugins/devhouse/` with its own `.claude-plugin/plugin.json`,
  `commands/`, `agents/`, and `skills/` (all by directory convention), plus `team/`
  (`protocol.md`, `intake-check.py` and `git-tripwire.sh`, shared by the skills and reached through `${CLAUDE_PLUGIN_ROOT}`; not a
  convention directory) (`README.md` § "Layout"), and, at the repository root and outside the plugin,
  `tools/check-frontmatter.py`, `tools/tests/intake-check/run.py` and `tools/tests/git-tripwire/run.sh` (`subsystems/plugin-packaging.md` §3). This nesting was a deliberate restructure.
- **Agent file shape** — every `agents/*.md` opens with YAML frontmatter carrying exactly
  `name`, `description`, `model`, `tools` (read by the runtime only when the frontmatter parses, `subsystems/plugin-packaging.md` §9),
  followed by a persona body in a fixed rhythm:
  a one-line identity, a "Your responsibilities" list, a "How you work"/"output format"
  block, a "Principles" list, then a values block (a fixed label line and a numbered list,
  `team/protocol.md`, *Values*) and, except Roxy's, a closing paragraph. Consistency across the
  seven is itself the convention.
- **Handle naming** — the agent `name` (lowercase, single word) is the invocation handle;
  `@name` dispatches it (`devhouse.md` § "The dev house roster"). The seven are single female first names.
- **Model tiering** — "cheapest sufficient model per role": Opus for planning/critique
  (Pris, Roxy, Shiro) and orchestration; Sonnet for execution (Delia, Dahlia, Tessa, Remi)
  (`devhouse.md`, "Use the cheapest sufficient model per role").
- **Tool allowlisting** (subagent form; in session form there is no tool restriction) — read-only reviewers get `Read, Glob, Grep` (+ web for Pris);
  writers add `Write, Edit`; code/test runners add `Bash`; the security reviewer, who writes nothing but runs scanners and git, gets `Read, Glob, Grep, Bash`; the release manager, who writes her release files (never code) and runs git, gets `Read, Glob, Grep, Write, Bash`. The allowlist, when the frontmatter parses (`subsystems/plugin-packaging.md` §9), encodes the role
  boundary (e.g. "Pris is read-only", `devhouse.md`, "Pris is read-only").
- **Work-order naming** — `Documentation/dev-prompts/<NN>-<slug>/<NN>-<slug>.md`, one folder per work order; numbered for
  build-order steps, descriptive slug for non-build tasks (`devhouse.md`, "File-based handoff (no clipboard relay)").
  Session-form artefacts about a work order are `<basename>.<kind>-<k>.<member>.md` in the same
  folder (`team/protocol.md`, "Files", is canonical for the layout), `<kind>` one of `review`, `security`, `report`, `design`, `tests`,
  `validity` and `intake` (a research-intake report or answer file; plus `audit`, `outbound`, `pin`, `manifest`, `waiver`, `push` and, in the subagent form only, `base` for artefacts about no work order, such as the release manager's, written under `<devhouse home>/release/` and `<devhouse home>/outbound/<project>/`); spec revisions also hold
  `security-<n>.shiro.md`. The `validity` kind is an
  exception: it is written under the hidden home, `<devhouse home>/hidden-tests/<project>/<u>-validity/`
  (`team/protocol.md`, "Tests", *The hidden set*), outside every repo and not under `Documentation/`;
  `audit`, `outbound` and the release kinds are written outside `Documentation/` too.
- **Grounded claims** — every factual claim in a doc must be verifiable against the artifact;
  unverified figures/commands are marked `// VERIFY` (`devhouse.md`, "Every factual claim grounded.").
- **Emphasis style** — bold for defined terms and non-negotiable rules; em-dashes for
  inline definitions. Consistent across charter and README.

## 9. Glossary

- **research intake / intake line** — the habit that whatever a member brings in *to use* (a dependency,
  copied code, a clone, a download) is shown first to the security reviewer, who answers in one abrupt
  line, `Intake: pass: <name> <id8>.` or `Intake: no: <name> <id8>.`; the member's line is `Intake: …` (a
  `Intake staging: …` notice to the manager precedes it when the `<id>` is not yet known, and is never judged).
  Recorded by the manager in `<devhouse home>/intake/<project>/passed.md`
  (`team/protocol.md`, "Research intake"; [ADR 0016](decisions/0016-research-intake.md)).
- **intake start point** — the `Intake start point: <sha>` line in the project's `CLAUDE.md`: what was present
  then is grandfathered, and detection checks the diff since it.
- **checker script / field folder** — `team/intake-check.py`, the one home of every intake check, and the
  `mktemp -d` folder of five field files (`kind`, `name`, `id`, `source`, `purpose`) it checks and derives its
  parts into; its only output is one line.
- **the git tripwire / the tripwire** — `team/git-tripwire.sh` and its rules: a mechanical check, run before every
  unit merge and manager commit and in the reviewer's wake, for what changes what git does (links, submodules,
  steering files a unit adds; hooks, filters, config values and replace refs in the shared checkout's `.git`). It
  finds and the security reviewer judges; it protects against accidents and not a hostile member
  (`team/protocol.md`, "The git tripwire"; [ADR 0015](decisions/0015-the-git-tripwire.md) and
  [ADR 0017](decisions/0017-threat-model-accidents-first.md)). **Not the guard's "tripwire",** its check 3
  (the project's `devhouse home:` line compared with the home pin: `team/protocol.md`, "Tests", *The project's home
  line*), which that section and the manager skill's *The devhouse home* call "the tripwire" or "check 3". This
  one is always written in full, "the git tripwire", and lives under `<devhouse home>/tripwire/`.
- **hit / run / `allowed` / the salt** — a hit is one line of the tripwire's output, `<class> <id> <hash>`; a run
  is its folder under `<devhouse home>/tripwire/<project>/runs/` holding `expected`, `hidden`, `released` and
  `hidden-released`; `allowed` is the file of lines the human has let stand; the salt is the secret that keys
  every hash, so a hit's value never appears in a file the team reads.
- **dev-house** — the whole system: one orchestrator role plus seven specialist agents (and,
  in session form, eight role skills), shipped as a plugin, that runs a fixed multi-agent
  development process.
- **co-PM / orchestrator** — the role the *main* Claude Code session assumes when `/devhouse`
  runs (in session form, the manager skill adopts the same role as Makima). Not an agent; cannot be dispatched. It dispatches specialists and gates their work
  (`README.md`, "The **co-PM** is not an agent").
- **specialist / agent** — one of the seven subagents (Pris/Delia/Dahlia/Tessa/Roxy/Shiro/Remi).
  Dispatched by the co-PM; cannot dispatch each other.
- **session form / single-session form** — the two ways to run the house: single-session is
  `/devhouse` dispatching subagents; session form is one Claude Desktop session per member,
  each running a role skill (`subsystems/role-skills.md`).
- **role skill / role title / team** — a skill `/devhouse:<role>` a session loads to become one
  member; the exact session title it takes (e.g. `Roxy the DH Reviewer`); and the team itself,
  which is the Claude Desktop sidebar group the sessions are filed in
  (`decisions/0003-team-membership-by-sidebar-group.md`).
- **project start** — the manager skill's procedure for founding a team project: brief, related-work
  scan, one approval, repo and first commit, move, group, discovery, answers commit, open the
  planning set and point the planner at the brief (Flow F).
- **brief** — the 50,000-foot description of the project, `Documentation/brief/brief.md`.
- **spec revision / locked spec** — a spec revision is the folder `Documentation/spec/r<k>/`,
  never overwritten (a change is `r<k+1>/`); the locked spec is the revision the human approved,
  named in the project's `CLAUDE.md`.
- **smoke check** — the manager's shallow look at a new spec revision; its only outcomes are "redo"
  and "pass", and it is never a sign-off.
- **work notice** — the one-line message the manager sends the designer, the developer, the tester and
  the release manager at every spec revision, pointing at the brief and the revision, asking for concerns (every role
  is asked, present or not; a role the human declined is recorded as "not consulted"); it starts
  no work beyond a reply.
- **halt pointer** — a manager's pointer that stops a reviewer (the reviewer, the security reviewer or
  both) at her next tool round, who then writes what she has as a review headed `halted at …`.
- **hands-on / hands-off** — the manager's two involvement modes: hands-on (default) stops at the
  human gate between steps; hands-off ("leave me till final", final being the end of the project)
  is the human's standing approval to advance once a unit's checkpoint merge is made and to merge
  each unit into the branch `devhouse/hands-off`, with merging to main left to the human.
- **unit / `<u>`** — a build step (`<NN>`) or a maintenance task (`<slug>`), the thing the team
  branches, builds, tests, reviews and merges as one (Flow H).
- **integration branch (`<I>`)** — the branch the shared checkout has checked out: `main`, or
  `devhouse/hands-off` from the start of hands-off until the human merges it. Only the manager
  switches it.
- **unit branch** — `work/<u>` (the developer's, created by the manager at first dispatch),
  `design/<u>` and `tests/<u>` (created by their builders from `work/<u>`), each in its builder's
  git worktree under `.claude/worktrees/`.
- **freeze** — the developer merges the other builders' branches into `work/<u>` and records
  `ready: <sha>` in her report; the reviewer, the tester and, where marked, the security reviewer
  then work on exactly that SHA, and a
  later commit is a new iteration (except the post-pass re-freeze and the re-freeze after a merge
  conflict, which are not iterations).
- **hidden set** — the tester's second set of tests, written at the unit's start from the spec
  and the work order, testing the same requirements in a different manner, kept outside every repo
  and off limits to the developer and designer, run at each review and committed after the unit
  passes (`team/protocol.md`, "Tests").
- **devhouse home** — the folder, outside every repo and the plugin, that holds the hidden sets,
  the reviewer's validity folders, the verification worktrees, the release manager's audit files and the release record (`release/`) and the outbound drafts (`outbound/`): the environment variable `DEVHOUSE_HOME` if set, else
  the machine pointer `<user home>/.devhouse-home` (one line, written by the manager on the human's
  answer), else `$HOME/.devhouse`. One home per machine, shared by every team on it; the `devhouse home:` line in the project's
  `CLAUDE.md` only confirms it, and each member's guard checks it as a tripwire before she reads or writes there (`team/protocol.md`,
  "Tests", *The hidden set*; [ADR 0009](decisions/0009-a-configurable-devhouse-home.md);
  [ADR 0014](decisions/0014-setup-in-one-question.md)). It also
  holds `crew/` once the manager has made it.
- **crew memory** — each member's small memory of how she works (a worklog, her mistakes, her
  notes on the others) and the shared break room, in one vault of markdown per machine at
  `<devhouse home>/crew/`. On only when the project's `CLAUDE.md` has `crew memory: on` and that
  folder exists; a record, never an authority; the
  session form writes it and the subagent form only reads it (`team/protocol.md`, "Crew memory";
  [ADR 0010](decisions/0010-crew-memory-and-the-break-room.md)).
- **break room** — `crew/breakroom.md`, the file where members post a line or two, in voice, with
  the occasional live message on top (a message that begins `Break room:`, sent only from a turn that
  handed her work, at most one per member per hour).
- **distinctive inputs** — the unusual values the hidden set uses, so that a hard-coded answer in
  the code is recognisable; the reviewer checks for special-casing of them and reports only
  whether and where.
- **verification worktree** — a detached git worktree outside the repo, at the frozen SHA, where
  the tester runs the visible and hidden tests and then removes it. The security reviewer has her
  own, `<project>-<u>-sec-<k>`, for advisory scanners, with no hidden set in it.
- **provenance line** — a line in a gate or test run's output showing where the code under test
  was imported from, so that a run from the wrong checkout is visible.
- **confirmation review** — the review, headed `confirmation`, that follows the hidden set's
  commit and the developer's re-freeze: it confirms the committed files equal the set that was
  run and that the diff from the frozen SHA to the re-frozen one touches only the hidden folder
  (which is what lets the re-freeze skip a second security review), and does not count toward the
  iteration cap.
- **security reviewer (Shiro)** — the member who asks only "is this secure?": threat-models spec
  revisions and reviews security-relevant units. Her blocking findings are about security only; only
  the human waives one; where she and the reviewer disagree it goes to the human (`team/protocol.md`,
  "Authority"; [ADR 0006](decisions/0006-a-security-reviewer.md)).
- **release manager (Remi)** — the member who asks two questions, is the data right for its reader and
  how will it land: audits what would ship for private data (personal data, local paths, secrets, IP
  references (a named franchise or work), internal hostnames and network addresses, process traces,
  commit and tag metadata) and checks text going out to people, reports class and location (and risk, for outbound) and
  never the value, writes no code and never sends, posts or pushes. Her
  **audit-only mode** is asked of the manager; the audit is a file under `<devhouse home>/release/`,
  outside the repo, and blocks nothing. Her outbound reviews sit under `<devhouse home>/outbound/<project>/`,
  are advisory and never gate a merge or a unit. In a release she also drafts the notes, builds
  the public tree and runs the filter (in both forms; in the subagent form the orchestrator dispatches her step by step), and her findings block the push. She is invoked only when named.
  Where she and either reviewer disagree it goes to the human
  (`team/protocol.md`, "Release", its *Outbound to people* and *The release stage*, and "Authority"; [ADR 0011](decisions/0011-a-release-manager.md);
  [ADR 0012](decisions/0012-outbound-to-people.md); [ADR 0013](decisions/0013-the-release-stage.md)).
- **outbound text** — text a member drafts for people other than the team: external text is drafted only
  and the human sends it (the one exception is the release push, the manager's or the orchestrator's); an internal pull request or PR or issue comment may be posted by a member only
  on the human's approval for that act, signed `Generated by Claude <model>; posted with approval.`; other
  internal text is drafted only. A draft reaches the human with the release manager's review beside it
  (`team/protocol.md`, "Authority" and "Release", *Outbound to people*;
  [ADR 0012](decisions/0012-outbound-to-people.md)).
- **release stage** — releasing a version of the project to the public: the human asks the manager, in a
  hands-on session with the mainline checked out and no unit in flight; a prep unit carries the approved
  notes and `CHANGELOG.md`; the release manager audits the release commit R, a publish-time filter replaces
  values that must not ship, and she rebuilds a public repo from R every time, with the fixed process set
  (*The release stage*, *The public tree*, step 3) left out and a fresh,
  single-parent history under a release identity; the security reviewer passes it; the manager makes the
  one push, per approval and by SHA, from a fresh bare repository after the seal has checked that `public/.git` is what the stage made. A release finding blocks the push and only the human waives it, except a committed symlink or
  submodule or a `filter=` attribute, which nobody can waive (*The release stage*, *Waivers*). In the
  subagent form the orchestrator makes the push, on the human's approval (`team/protocol.md`, "Release", *The release
  stage*; [ADR 0013](decisions/0013-the-release-stage.md)).
- **security-relevant mark** — the line `**Security-relevant:** yes | no` every work order carries,
  set by its writer; a missing line in a new work order is a blocking finding of the reviewer's
  pre-dispatch review (`team/protocol.md`, "Files").
- **security start point** — what the manager records in the project's `CLAUDE.md` when the security
  reviewer first joins: "security review from: the next spec revision she reviews". Earlier spec
  revisions, work orders with no mark, and the units in the `Grandfathered units:` list written
  beside it (every unit dispatched before the turn of the `start_session` call, or the ask to the
  human, that she joined from, or if neither, before the turn her announcement reached the
  manager; "none" if there are none; the unit she was opened for is never listed) are
  grandfathered; with no start point the marks gate nothing. Waivers of a missing security review on a unit are kept in a
  "Security waivers" list in the same file.
- **voice / `Sounds like:`** — how a member sounds: four to twelve trait lines and two to eight
  samples in her skill's `## Voice`. It colours her messages, acknowledgements and the turn-end to the human included, and the
  prose of her `dev-prompts/` artefacts, and stays out of what ships and the normative text of specs
  and work orders (`team/protocol.md`, *Voice*; [ADR 0007](decisions/0007-voices-that-show-and-the-manager.md)).
- **values** — a member's ranked cares (three to six): what she notices first, pushes hardest on and
  holds most urgent. Specialists' are a numbered list in their agent file, opened by one fixed label
  line that mirrors the rule; the manager's are `## Values` in her skill. They may strengthen a gate
  within the member's own role and never weaken one, widen a unit's scope or outrank her method, the
  protocol or the human (`team/protocol.md`, *Values*, canonical;
  [ADR 0008](decisions/0008-values.md)).
- **check-in** — the reviewer's timed audit of the team's files and git while a unit is active
  (missing reviews, merges without review, missing security reviews, missing tests), reported to the manager once per gap; the
  manager is told of each wake, which is the heartbeat (the reviewer ends each wake turn with
  `Check-in audit: <n> gaps.`, and a turn-end counts only if its notice includes `Check-in audit:`).
- **whistleblowing** — any member may raise a concern about the process or the manager directly with
  the human, in her own session, at any time; it is exempt from the summary rule and never blocks
  work.
- **handle** — the `@name` used to invoke an agent (e.g. `@dahlia`); equals the agent's
  `name` frontmatter.
- **advisory mode** — the default co-PM mode: review output *with* the user, draft work
  orders, wait; does not self-drive dispatch (`devhouse.md`, "Advisory (default).").
- **autonomous loop / loop mode** — the co-PM self-drives the dispatch/verify cycle after the
  user hands it work (`devhouse.md`, "Autonomous loop.").
- **build track** — greenfield loop; one build step at a time from an ordered plan, human
  gate between steps (`devhouse.md` § "Build track — greenfield (project build order)").
- **maintenance track** — per-task loop for existing code; the next task comes from the user,
  not a sequence (`devhouse.md` § "Maintenance track — existing code").
- **Track 0 / onboarding** — a one-time comprehensive documentation project run when adopting
  a codebase the dev-house did not build; precondition for the maintenance track
  (`devhouse.md`, "Track 0 — Onboarding (adopting an existing codebase)").
- **work order** — a lossless, file-based task spec at
  `Documentation/dev-prompts/<NN>-<slug>/<NN>-<slug>.md` (its own folder: `team/protocol.md`, "Files"), fired with a short pointer (`devhouse.md`, "File-based handoff (no clipboard relay)").
- **Done gate** — the completion condition for a step/task; nothing is done until it is met
  and (per the guardrail) Roxy's audit (and Shiro's, for security-relevant work) is clean or the user waives it (`devhouse.md`, `Roxy gates "done."`).
- **human gate** — the mandatory stop for user approval at every step/task boundary
  (`devhouse.md`, "Human gate between every step."). In the session form hands-off is the one
  named exception, between build steps only (see **hands-on / hands-off**).
- **iteration cap (3)** — the fix/verify loop within a step retries at most 3 times, then
  stops and surfaces to the user (`devhouse.md`, "Cap: 3 iterations." and "Iteration cap within a step (3)").
- **documentation standard** — the fixed schema (required sections per doc, grounded-claims
  rule, Roxy checklist) that defines what "documented" means (`devhouse.md` § "Documentation standard").
- **ADR** — Architecture Decision Record, stored at
  `Documentation/architecture/decisions/NNNN-<slug>.md` (`devhouse.md` § "Documentation standard", `decisions/NNNN-<slug>.md`). The ADRs in `decisions/` start with ADR 0001
  (roster single-source policy) and ADR 0002 (the omission sweep); from ADR 0003 on, each is a short
  stub of its decision and consequence.
