# Subsystem: Role Skills

## 1. Responsibility

The **session form** of the dev-house: eight skills, one per team member, that let separate Claude
Desktop sessions each take on one role and cooperate as a team. A session loads a skill
(`/devhouse:<role>`), finds its teammates, claims its role by renaming itself, and from then on
coordinates with the others by messages and files. The manager also founds projects and runs the
spec flow (project start, opening members, spec revisions), and the team builds in **units**: the
protocol carries the branches and worktrees, the tests and the hidden set, and the check-ins that
a unit runs on. The single-session form (`/devhouse`
dispatching subagents) is a different subsystem, [orchestrator-charter](orchestrator-charter.md);
the manager skill is the canonical statement of the distinction between the two. This subsystem owns
the discovery protocol, the coordination habits, and the eight skills that carry them. It owns no
specialist's responsibilities or method: those stay in the agent files and are cited, not restated.

The rules themselves are in [`team/protocol.md`](../../../plugins/devhouse/team/protocol.md),
their canonical home. This document describes the subsystem and links there; it does not restate
the protocol.

## 2. Entry points

- `plugins/devhouse/skills/manager/SKILL.md` — `/devhouse:manager`, Makima, Opus.
- `plugins/devhouse/skills/planner/SKILL.md` — `/devhouse:planner`, Pris, Opus.
- `plugins/devhouse/skills/designer/SKILL.md` — `/devhouse:designer`, Delia, Sonnet.
- `plugins/devhouse/skills/developer/SKILL.md` — `/devhouse:developer`, Dahlia, Sonnet.
- `plugins/devhouse/skills/tester/SKILL.md` — `/devhouse:tester`, Tessa, Sonnet.
- `plugins/devhouse/skills/reviewer/SKILL.md` — `/devhouse:reviewer`, Roxy, Opus.
- `plugins/devhouse/skills/security-reviewer/SKILL.md` — `/devhouse:security-reviewer`, Shiro, Opus.
- `plugins/devhouse/skills/release-manager/SKILL.md` — `/devhouse:release-manager`, Remi, Sonnet.
- `plugins/devhouse/team/protocol.md` — not an entry point a user invokes; every skill's first
  instruction reads it.

- `plugins/devhouse/commands/devhouse.md` — bare `/devhouse` is also an entry to the session form:
  in Claude Desktop it first asks "Sessions or Subagents?", with three options: *Subagents*, *Sessions* and
  *Sessions in windows*. Both session answers read the manager skill and follow it as if invoked, carrying
  the window choice (`member windows: off` or `on`: the manager skill's *The window setting*) (in the CLI there is no question and it is the subagent form). The
  command belongs to [orchestrator-charter](orchestrator-charter.md).

None takes an argument. Each is `disable-model-invocation: true`, which keeps the model from
invoking a role on its own. A role starts three ways: the user types its skill; the user answers
"Sessions" or "Sessions in windows" to bare `/devhouse` (the session becomes the manager); or the manager starts a new session
with `prompt: "/devhouse:<role>"` (`mcp__ccd_session__start_session`). So "only the user starts a
role" is no longer true: the manager starts the other members. A started session's prompt runs the
skill although `disable-model-invocation` hides it from the starter's own skill list (measured).

## 3. Key components

- **The role skill (eight).** Frontmatter `name`, `description`, `disable-model-invocation`; a body
  that cites rather than restates. Specialist skills carry seven items, the manager eight: run the
  protocol; adopt the agent file (specialists) or the charter as translated (manager); the
  tools sentence; method additions (every skill's but the manager's is non-empty; see each skill's item 4); the precedence line;
  `## Voice` (and, in the manager's skill only, `## Values`); the intended model. The skill body asks the user to set the session's model; no
  skill pins one.
- **The manager's charter translation** (in `skills/manager/SKILL.md`, "Translations"). The manager adopts
  `commands/devhouse.md` with two exclusions and a set of translations (dispatch becomes a pointer
  to a session, with the unit's branch, the builders' pointers and the cleanup pointers; who writes
  work orders; inline steering; handoff pointer form; modes, with hands-on and hands-off;
  never-edit; commits, where the Done-gate commit is the unit's merge; check-ins and the transcript
  audit; activation). That skill is its canonical home.
- **Project start** (`skills/manager/SKILL.md`, "Project start") — how a team project begins: brief,
  related-work scan, one recommendation approved at once, found the repo, move, group, join,
  record, open the planning set and point the planner at the brief. Its trigger is a folder with no `CLAUDE.md`, or a `CLAUDE.md` with
  status `project start, step <N>`; for a folder with no `CLAUDE.md` a **folder check** runs first
  (a session filed in one project's group but sitting in another folder is asked which project
  it meant).
- **The session questions** (`skills/manager/SKILL.md`, "The session questions") — the six
  questions, five asked once per project (open members without asking each time; hands-on or
  hands-off; may members contact the human directly; what the team should call the human; whether to
  turn crew memory on, recorded as the `crew memory: on` line) and (f), asked first and once per
  machine, only when there is no `DEVHOUSE_HOME` and no pointer (where the machine keeps its devhouse
  files; recorded in the variable or the pointer, not in `CLAUDE.md`),
  recorded in `CLAUDE.md` as a record, not an authority. She asks whichever has no recorded
  answer, so an existing project is asked only what it lacks.
- **The devhouse home** (`skills/manager/SKILL.md`, "The devhouse home") — the manager's part of the
  team-wide home: pin it, write the machine pointer `<user home>/.devhouse-home` on the human's answer to (f)
  or to the restore question, ask the mismatch question (with its four hints) and the restore question, make
  `<devhouse home>/crew/` on the human's yes to (e), record the `devhouse home:` line in `CLAUDE.md` (Project start before the
  planning set, else before creating any `work/<u>` while `CLAUDE.md` has no line, or on the
  human's say when a member reports none), repeat it in each started session's `background` and in
  her first pointer to a member the human opened by hand, and rewrite it only between units on the human's say. The definition, the
  source (the variable, else the pointer, else the default), the pin, check 1 and the tripwire are the protocol's *Tests* → *The hidden set*; the reasons are
  [ADR 0009](../decisions/0009-a-configurable-devhouse-home.md) and
  [ADR 0014](../decisions/0014-setup-in-one-question.md).
- **Opening members** (`skills/manager/SKILL.md`, "Opening members") — how the manager starts a member
  with `start_session`: initiation, fields, when, and the ladder (user-asked, then a card, then the
  human by hand). The whole planning set (planner, reviewer, security reviewer, designer, developer, tester, release manager) is
  opened in the human's turn that asks for spec work; the absent builders at each "go" on a unit,
  and the security reviewer if the unit's work order is marked security-relevant; the release manager
  is also opened when an audit or a release is asked for, or when an outbound draft needs her check (a card, in a teammate-triggered turn), and is not in the per-unit pre-dispatch loop. For a release the manager opens the release manager, the planner, the developer, the reviewer and the security reviewer, whichever are absent, in the human's release-ask turn. It is also where
  the manager records the **security start point** in the project's `CLAUDE.md`.
- **The discovery protocol** (`team/protocol.md`, "Discovery protocol") — self, team, teammates,
  check the role, claim, re-check, report, announce, stop.
- **The coordination habits** (`team/protocol.md`, "Coordination habits") — Re-read on change,
  Voice, Values, Crew memory, Routing (with the builders' channel), Authority, Files (including the document-folder table),
  Session method (reports, grounded docs, cleanup), Spec flow (with the rough architecture docs),
  Units and branches, Tests, Check-ins, Contact, Waiting.
- **Units and branches** (`team/protocol.md`, "Units and branches") — a unit is a build step or a
  maintenance task. The integration branch; `work/<u>` created by the manager, `design/<u>` and
  `tests/<u>` by their builders; one git worktree per builder under `.claude/worktrees/`; code
  runs from its worktree, with a provenance line; the freeze (`ready: <sha>`); the security review of
  a unit marked security-relevant; the hand-offs; the merge trigger and the check that the branch tip equals the reviewed SHA; cleanup.
- **Tests** (`team/protocol.md`, "Tests") — visible tests (from the spec, never from the code), the
  hidden set outside every repo and the configurable devhouse home it sits in (with the guard that
  checks the home), validity, the verification worktree, results and disclosure, the
  post-pass commit and confirmation review, and detection, not prevention (the canonical statement
  of what the transcript audit does and does not catch).
- **Check-ins** (`team/protocol.md`, "Check-ins") — the reviewer's timed audit of files and git
  (nine flags: five about reviews, three about missing security reviews, and the git tripwire's
  *checkout tripwire*, which runs the shipped script's `check-checkout` each wake), active and pause pointers,
  reporting, the heartbeat the manager checks, the break room's hourly post (a file append) and the
  cost with crew memory on.
- **The git tripwire** (`team/protocol.md`, *Units and branches* → *The git tripwire*; the manager skill's *The git
  tripwire*; the charter's *The git tripwire (subagent form)*) — a mechanical check, by the shipped script
  `team/git-tripwire.sh`, of what a unit or a manager commit adds (links, submodules; files that steer git, a hook
  framework, Claude Code or an editor) and of the shared checkout's `.git` (config, hooks, `info/`, replace refs,
  worktree links, submodule git dirs), run before every unit merge and commit, before the hands-off merges and in
  the reviewer's wake. It finds and does not judge: the security reviewer judges each hit (benign or a blocking
  finding), the human when she is absent or the line is under `hidden/`; a released line is allowed
  (`allowed`, keyed by a salted hash) and a never-allowed one is removed on the human's say. Merges and commits go
  through the script, not `git merge` or `git commit`. It protects against accidents and not a hostile member
  (the protocol's *What it protects against, and what it does not* holds the threat model; the stated limits and costs are in *Limits, and what they cost*).
  Rationale: [ADR 0015](../decisions/0015-the-git-tripwire.md) and
  [ADR 0017](../decisions/0017-threat-model-accidents-first.md).
- **The security reviewer's slice** — Shiro's skill and agent file hold her method and voice; her
  rules live once each, in the protocol: the spec flow (*Spec flow*, her `security-<n>.shiro.md`
  files and the approval and waiver), the work-order mark (*Files*), her review of a unit's frozen
  SHA, never reading the hidden set, the confirmation round waiting for her, and the audit's three
  security conditions (*Units and branches*, *Tests*, *Check-ins*), her authority (*Authority*), and
  opening her (the manager skill's *Opening members*). Rationale:
  [ADR 0006](../decisions/0006-a-security-reviewer.md).
- **Voice sections.** Four to twelve second-person, indicative trait lines describing how the
  member sounds, then the label `Sounds like:` and two to eight samples. A voice is never a rule and
  never weakens a gate; where voice and method conflict, the precedence line makes method win. The
  protocol's *Voice* habit says where a voice applies (small messages and the turn-end to the human included) and where it stays
  out (what ships, the normative text of specs and work orders, exact strings); each skill's
  *Precedence* item cites it by name. Rationale: [ADR 0007](../decisions/0007-voices-that-show-and-the-manager.md).
- **Small messages between members** (each one short, starts no work beyond its
  own answer, and carries no project content beyond what its form says). The manager's *Praise*: a
  word at a unit's merge, folded into the next pointer (manager skill). The planner's *Drafting
  questions*: a short question to a teammate other than the reviewer while a work order is drafted,
  answered once, recorded in the work order, information and never a pass (protocol, *Routing*). The
  reviewer's *Teaching note*: a short message to a member whose work held a finding, after her review
  pointer, answered with one line (protocol, *Routing*; her skill). The reviewer's hourly break-room
  post, which may be addressed to one teammate (protocol, *Crew memory*, *The break room*). The tester's
  messages are visible to the developer, so the hidden set never relies on them (protocol, *Tests*).
  The *Values* habit also gains *Extras are few*, a proportion rule for the session form. Rationale:
  [ADR 0007](../decisions/0007-voices-that-show-and-the-manager.md) and
  [ADR 0008](../decisions/0008-values.md), amended.
- **Values.** Where a voice is how a member sounds, her values are what she cares about: three to six
  ranked, numbered items. The specialists' sit in their agent files (so the subagent form reads them
  too), opened by one fixed label line that mirrors the protocol's *Values* habit; the manager has no
  agent file, so hers are the `## Values` section of her skill after `## Voice`. The rule lives
  once, in the protocol's *Values* habit; this document cites it. Rationale:
  [ADR 0008](../decisions/0008-values.md).
- **Crew memory and the break room** (`team/protocol.md`, "Crew memory") — the fourth coordination
  habit and the canonical home of the vault `<devhouse home>/crew/`: the two switches (the
  project's `CLAUDE.md` line `crew memory: on`, which the manager records on the human's say, and the
  folder existing), the per-member files with their bounds, the line format and the UTC time, safe
  appends (a quoted heredoc) and rolling, the reads (on joining and on each natural wake), the write triggers, the rules
  that bind memory, the break room and its live messages. Each skill's step 1 cites it; each agent
  file carries one fixed line (a sync-marked copy, like the values label) that tells the subagent
  form to read; the charter names the crew path in a dispatch. Rationale:
  [ADR 0010](../decisions/0010-crew-memory-and-the-break-room.md).
- **The release manager's slice** — Remi's skill and agent file hold her method, write list and voice;
  her rules live once each, in the protocol: audit-only mode (*Release*: entry through the manager,
  scope, the output file, class and location only, nothing afterwards), her authority and the
  disagreement route (*Authority*), her routing (*Routing*), the guard that names her as a writer
  under `release/` and `outbound/` (*Tests*, *The guard*), and her place in the planning set (*Spec flow*, step 3, and
  the manager skill's *Opening members*). In a release she also drafts the notes, builds the public tree and
  runs the filter, under the write list her skill gives her (*Release*, *The release stage*). Rationale:
  [ADR 0011](../decisions/0011-a-release-manager.md).
- **Outbound to people** (`team/protocol.md`, *Release* → *Outbound to people*; the sending rule in
  *Authority*) — text for people other than the team: what a member may send (external text drafted
  only; an internal pull request or PR or issue comment posted only on the human's approval for that
  act, with a fixed signature; other internal text drafted only), the closed scope, who drafts, the
  versioned drafts and reader files under `<devhouse home>/outbound/<project>/` (*Files*), Remi's two
  questions (the data against the reader; how it lands, with no profiling), the route every draft takes
  through the manager to her and back to the deliverer, the three fallback lines, and the advisory authority of
  her findings. The manager skill's *Outbound text* is the manager's part, and her skill and agent
  file cite the protocol. The subagent form offers `@remi` and never auto-dispatches her (the
  charter). Rationale: [ADR 0012](../decisions/0012-outbound-to-people.md).
- **Research intake** (`team/protocol.md`, *Coordination habits* → *Research intake*) — before a member
  brings in something to use (a dependency, copied code, a clone, a download) the security reviewer sees it and
  answers in one abrupt line. The member's `Intake: <kind>: <name> <id> from <source>, for <purpose>.` goes to
  the security reviewer, copied to the manager (when the `<id>` is not yet known, an `Intake staging: …` notice
  goes to the manager alone first, and the full line follows the rename: only the full line is judged); the answer is `Intake: pass: <name> <id8>.` or `Intake: no: <name> <id8>.`; a refusal the member still
  needs gets a full report (`<basename>.intake-<k>.shiro.md`), and one that still says no goes to the
  human (`<basename>.intake-<k>.makima.md`). The manager records passes in
  `<devhouse home>/intake/<project>/passed.md`; the security reviewer's review of a marked unit checks every
  direct dependency added or changed, and every vendored file, since the `Intake start point:` line against it.
  **Every field is untrusted text:** the plugin's `team/intake-check.py` checks it before anything uses it, and
  derives the parts that commands may use. The same script lists and extracts archives, judges a clone's tree
  from git's listing, piped, before the checkout (`--names -`, so no file of a refused tree and no listing
  is written) and walks it after
  (`--tree`) for names, repeats, links and a committed bare-repository shape. The skills (developer, tester,
  designer, security reviewer, manager) and the agent files cite the protocol; the charter's *Research intake
  (subagent form)* has the orchestrator do the folder work for every subagent, and `@shiro` compare each field with
  the quoted line and run `--check`. Rationale and limits: [ADR 0016](../decisions/0016-research-intake.md).
- **The release stage** (`team/protocol.md`, *Release* → *The release stage*; the push exception in
  *Authority*) — releasing a version to the public: the preconditions and the freeze, the record
  (pin, audits, security pass, manifest, waivers and push outcomes, and, in the subagent form, the notes base) in `<devhouse home>/release/<project>/`,
  outside the repo, the prep unit that carries the approved notes and `CHANGELOG.md`, the audit of the
  release commit (with a class of process traces), fixes and a publish-time filter whose values stay
  outside the repo, a public tree rebuilt from scratch with a fixed process set left out, the release
  identity and UTC dates, the final checks and the manifest, lightweight tags, and the manager's one
  push per approval, by SHA, made from a fresh bare repository. The header every call begins with, the stop rule (`fail`, since the Bash tool
  ignores `set -e`), the seal that checks `public/.git` before any call reads or writes it, the push and its post-push check, and the escaping of recorded paths are canonical in *The public tree*,
  *How each step runs*, *The push* and *The audit of R*. The skills and agent files cite the protocol; the manager skill's
  *Never-edit* and *Opening members* are the manager's part. In the subagent form the orchestrator makes the push, on the human's
  approval, as *The push* says (the charter); the human is handed no command. Rationale:
  [ADR 0013](../decisions/0013-the-release-stage.md).

## 4. Data & state

Team membership is held by the host: a session's **title** and its **sidebar group** in Claude
Desktop. The team table a joining session prints is not stored anywhere but that session's
transcript. The subsystem writes state to the host project, none to this repo:

- Artefacts members write (work orders, reviews, reports, design and test files) live under
  `Documentation/dev-prompts/`; their layout (one folder per work order) and naming are in `team/protocol.md` ("Files"), and the charter
  owns the directory.
- The project's document folders (`team/protocol.md`, "Files"): `Documentation/brief/` (the brief,
  and a summary of each member's conversation with the human), `Documentation/spec/r<k>/` (spec
  revision *k*, with its rough `architecture/` docs, `concerns.makima.md`, `review-<n>.roxy.md` and
  `security-<n>.shiro.md`),
  and `Documentation/design/`. Spec revisions are never overwritten; a change is `r<k+1>/`.
- The project's `CLAUDE.md`: during Project start its status is `project start, step <N>`, then
  `planning`; it records the session questions' answers with the date (including what to call the
  human, and their pronouns if given), the **`member windows: on|off`** line (the window layout, read as written; the manager skill's *The window setting*), the team's **`devhouse home:`** line (`default` when the home is the default, `~/<rest>` when it is under the user home,
  otherwise the absolute path; a tripwire, never the source; recorded in Project start before the planning set is
  opened, else before creating any `work/<u>` while it has none, or on the human's say when a
  member reports none), a declined spec approval with its date, and names the locked
  spec revision once the human has approved one; once the security reviewer has joined, it also
  holds the **security start point**, "security review from: the next spec revision she reviews",
  the **`Grandfathered units:`** line written beside it (written when she first joins; it lists the units dispatched before the turn of the `start_session` call, or the ask to the human, that she joined from, or if neither, before the turn her announcement reached the manager, never the unit she was opened for; a start point without the line reads as "none"), and a **Security waivers** list (a line
  per declined-for-a-unit and per waiver: unit, SHA, date, the human's words). The recorded
  answers are a record, not an authority.
- Commits the human approved: the founding commit and the answers commit (approved together in
  Project start step 3), the planning-documents commit (approved at the spec approval), and, in
  hands-off, one checkpoint merge per unit on the branch `devhouse/hands-off` (the branch is one per
  project, created from main after the planning commit). Merging that branch into main waits for the human.
- Per unit, in git: the branches `work/<u>`, `design/<u>`, `tests/<u>` and each builder's worktree
  under the project's `.claude/worktrees/` (git-ignored); the unit's artefacts are written in the
  shared checkout and stay untracked until the manager commits them with the unit's merge
  (`team/protocol.md`, "Units and branches" and "Files").
- Retention: the hidden-set folders `<devhouse home>/hidden-tests/<project>/<u>/` and `<u>-validity/`
  are kept after the merge. The committed `hidden/` folder is canonical from then on; removing the
  folders is the human's call, and nothing deletes them automatically. Changing the home
  mid-project (between units, on the human's say) leaves earlier units' sets where they are.
- Outside every repo and the plugin, under the **devhouse home** (`DEVHOUSE_HOME` if set, else
  the machine pointer `<user home>/.devhouse-home`, else `$HOME/.devhouse`; one home per machine, the `devhouse home:` line above confirming it and checked as a tripwire): the hidden set,
  `<devhouse home>/hidden-tests/<project>/<u>/`; its sibling `<u>-validity/`, which holds the
  reviewer's `validity` notes and is not part of the set; and the verification worktrees, the
  tester's `<devhouse home>/verify/<project>-<u>-<k>/` and the security reviewer's
  `<devhouse home>/verify/<project>-<u>-sec-<k>/`, which exist only during a run and are removed
  after each. A plugin data folder is not used: its contents were lost once, a reinstall being the
  likely cause (`team/protocol.md`, "Tests", *The hidden set*; [ADR 0009](../decisions/0009-a-configurable-devhouse-home.md)).
- Also under the devhouse home: **outbound text**, `<devhouse home>/outbound/<project>/` (`<project>` the
  shared checkout's folder name; in the subagent form the orchestrator's working folder's name, or
  `general`): drafts `<slug>.v<n>.<member>.md`, reader files `<slug>.reader-<k>.<member>.md`,
  summaries `<slug>.summary-<k>.<member>.md` and Remi's reviews `<slug>.outbound-<k>.remi.md` (session
  form only), each with its one writer, never committed, and kept: the human deletes them by hand. A
  member reads only her own project's folder; only the subagent-form orchestrator reads `general`.
  The project's `CLAUDE.md` also records the internal repos as `outbound repos:` lines, one per repo,
  on the human's say (`team/protocol.md`, *Outbound to people*; [ADR 0012](../decisions/0012-outbound-to-people.md)).
- Also under the devhouse home: **research intake**, `<devhouse home>/intake/<project>/` (`<project>` the
  shared checkout's folder name): `passed.md` (the manager's record, one line per pass) and `items/`
  (`<name>-<id8>/` fetched material, `<name>-new-<n>/` staging folders, `<name>-<id8>-<n>/` fresh fetches after a
  failed re-check), made by the manager with `mkdir -p` on the human's say and at every home pin. Beside it:
  the security reviewer's `verify/<project>-intake-<k>-sec/` (left in place, since it can hold a clone: the human
  deletes it), and for hidden-set
  material `hidden-tests/<project>/<u>-intake/` (a sibling of the set, never inside it) with the tester's
  `hidden-tests/<project>/intake.md`. Field folders (`fields.XXXXXXXXXX`) are in the system temp, or under
  `<u>-intake/` for hidden-set lines, and each lives for one use. The artefacts are
  `<basename>.intake-<k>.shiro.md` (the full report), `<basename>.intake-<k>.makima.md` (the answer file) and, in
  the subagent form, `<basename>.intake-<k>.orchestrator.md`, in `Documentation/dev-prompts/`, or under
  `hidden-tests/<project>/` for hidden-set material. None of it is deleted automatically (README, *Bringing
  things in*). The project's `CLAUDE.md` records `Intake start point: <sha>` (or `none`).
- Also under the devhouse home: **the git tripwire**, `<devhouse home>/tripwire/<project>/` and
  `<devhouse home>/tripwire/<project>.salt`. The salt is 64 hex characters, made once per project by the `salt`
  mode (a hard link, `ln -T`), before the project records `tripwire salt: made <date>` beside its `devhouse home:`
  line; `allowed` holds one `<class> <id> <hash>` line per hit the human let stand, written only by the `close`
  mode; `runs/<basename>-<k>/` holds a run's four files; `removed/` holds what removals moved (`<yyyymmdd>-<n>`,
  `<yyyymmdd>-<n>.config`) and its `index.txt`; and each call's `args.XXXXXXXXXX/` folder holds one file per value
  and the script's `work.XXXXXXXXXX/` scratch folder, removed on exit. The run files and judgements are in the
  project's `Documentation/dev-prompts/` (`<basename>.tripwire-<k>.makima.md`, `.shiro.md`, and in the subagent form
  `.orchestrator.md` and `<basename>.judged-<k>.orchestrator.md`). **Readers:** the manager, the reviewer, the
  orchestrator and, for every file but `hidden`, the security reviewer; off limits to the developer, designer, tester,
  planner and release manager. `removed/` can hold a credential; a killed call leaves an `args.*/work.*/` folder; the README
  lists both for the human to delete.
- Also under the devhouse home, when both switches are on (the `crew memory: on` line in `CLAUDE.md`, and the manager having made the folder), **the crew vault**
  `<devhouse home>/crew/` (one per machine, shared by every project): per member, in
  `crew/<member>/`, `index.md` (40 lines, edited down in place), `worklog.md`, `mistakes.md` and
  `crew.md` (150 lines each, rolled), the one-line pointers `.breakroom-seen` and `.breakroom-sent`,
  and `archive/`; shared, `crew/breakroom.md` (200 lines, rolled into `crew/archive/`). Rolled files
  go to `archive/<file>-<YYYY-MM-DD>-<n>.md` with `mv -n`, so nothing is overwritten, and nothing is
  deleted automatically: removing files is the human's call. The memory records how a member works
  and never project content (`team/protocol.md`, "Crew memory";
  [ADR 0010](../decisions/0010-crew-memory-and-the-break-room.md)).
- Also under the devhouse home: **the release manager's audit files**,
  `<devhouse home>/release/<project>/audit-<date>.audit-<k>.remi.md`, written by Remi alone (her
  guard applies), outside every repo and never committed. They hold classes and locations, never
  values, so the folder has no *Off limits* entry and no detection token, except for the release
  filter's values file (below). Her crew folder
  `crew/remi/` follows the general rule and is not off limits either: she never reads the hidden
  home, the validity files or any transcript. Nothing deletes the audits
  (`team/protocol.md`, "Release"; [ADR 0011](../decisions/0011-a-release-manager.md)).
- Also under the devhouse home, in a release: **the release record**, in the same
  `<devhouse home>/release/<project>/` (`<rel>`), outside every repo and never committed. Per version,
  `release-<version>.pin-<k>.makima.md` (R, the remote, the previous public commit),
  `.audit-<k>.remi.md`, `.security-<k>.shiro.md`, `.manifest-<k>.remi.md`, `.waiver-<k>.makima.md` and
  `.push-<k>.makima.md` (in the subagent form the writer segment of the pin, waiver and push files, and of the
  security file, is `.orchestrator.md`; the audits and the manifest stay `.remi.md`, `@remi` writing them), and, in the
  subagent form only, `.base-<k>.orchestrator.md` (the reviewer's notes base and how it was chosen;
  it holds commit subjects and a diff stat, or the full path list, of the private repo); the filter's
  values file `filter-values.txt` (the human writes it, or the release manager on the human's say (the session form only; in the subagent form, the human only)), the
  one file in `release/` that is **off limits** (who may read it is `team/protocol.md`, *Release*,
  *Afterwards*; the developer's and designer's off-limits list and the manager's detection list carry
  it); `<version>/public/`, the public repo, deleted and rebuilt on every build; `<version>/work/`, the
  build's lists, temporary index and masker (it holds the private release commit's full path list, so
  it is private-repo content; it is removed at the start of the next build and kept until then for
  the audit); and `<version>/check-<n>/`, a transient copy of the public commit plus the filter, for
  the filter's check mode, removed in its own call; and `<version>/tmp.*`, a sealed call's scratch folder (the reference repository and the comparison lists), which the call removes and step 1 clears if a killed call left one. The
  security reviewer's release pass also uses `<devhouse home>/verify/<project>-release-<version>-sec-<k>/`,
  which exists only during the pass, and the notes drafts and the manager's approval summary sit in
  `outbound/<project>/`. The pin is outside the repo so that it never refers to itself. Nothing else deletes
  any of it (a sealed call removes its own `tmp.*` folder); the human does, by hand.
- In the project, in a release, what persists in the private repo is:
  - the prep unit's version bump, `Documentation/release/<version>/release-notes.md` and `CHANGELOG.md`,
    which arrive on its branch and are merged with it (the developer copies the human-approved drafts
    verbatim);
  - the fix units' commits;
  - the filter unit's permanent `release-filter/` folder (script, visible tests and committed hidden
    set);
  - the `release identity: <name> <<email>>` line in `CLAUDE.md`, recorded on the human's say and
    committed with their approval;
  - the private tag `v<version>` on R, made on the human's say after the push.

  So the stage writes into the shared checkout only through a unit branch or an act the human approved
  (the identity-line commit, the mainline checkout and the merge of the hands-off branch into it, the
  private tag). The remote's URL is recorded only
  in the release record (the pin and the manifest), never in `CLAUDE.md`
  (`team/protocol.md`, *The release stage*; [ADR 0013](../decisions/0013-the-release-stage.md)).

## 5. Observability

This subsystem emits no log of its own; its outputs are session titles, printed tables, messages
recorded by the host, and files. Per output:

- **Team membership** — where: the Claude Desktop sidebar group and its sessions' role titles.
  Read: call `mcp__ccd_session_mgmt__list_sessions` with that group, or look at the sidebar.
  The eight role titles are the table in `team/protocol.md`. Members the manager opened with
  `start_session` nest under her: `list_sessions` shows their `startedBy`.
- **Team table** — printed in each joining session's own transcript (the protocol's "Report"
  step); not persisted elsewhere.
- **Message traffic** — recorded by the host as a turn in the *receiver's* session transcript.
  Read it with `mcp__ccd_session_mgmt__list_events` on the receiver's `sessionId`, from another
  session: the host-native read, verified by the orchestrator, which reads another session's
  transcript including an archived one's. Cross-session messages appear in it as **user** turns
  wrapped `<cross-session-message from="local_…" name="<sender's title>">`. **Gotcha:** a reader
  that treats user turns as the human misattributes peer messages as the human's; look for the
  wrapper. The same transcript is also readable by opening the session in the app, and is the
  file `~/.claude/projects/<working directory, every character that is not a letter or digit replaced by ->/<session id>.jsonl`, one
  JSON object per line (on Windows, `C:\Users\<name>\.claude\projects\…`). From Git
  Bash/POSIX, `grep -rl 'cross-session-message' ~/.claude/projects` lists the transcripts that
  contain a message; verified to list transcripts. Retention and
  rotation are the host's and are unmeasured. The file is JSON Lines, so a message's
  embedded newlines are escaped and `grep` counts records correctly.
- **Artefacts** — the paths in `team/protocol.md` ("Files"), under the project's
  `Documentation/dev-prompts/`. The kinds are `review`, `security`, `report`, `design`, `tests` and
  `validity`, plus `audit`, `outbound`, `pin`, `manifest`, `waiver`, `push` and `base` (subagent form only) for work-order-less
  artefacts; `validity`, `audit`, `outbound` and the release kinds are written outside `Documentation/`,
  under the devhouse home.
- **The release manager's audits** — where: `<devhouse home>/release/<project>/`, one file per audit,
  `audit-<date>.audit-<k>.remi.md` (`<date>` as `YYYY-MM-DD`, `<k>` from 1, never reused). Read:
  open it with any file reader; `ls <devhouse home>/release/<project>/` lists them. It names the
  audited SHA and reports each finding as class and location, never the value, and says what would
  block a release. **Gotcha:** an audit-only finding blocks nothing, so a clean-looking merge history
  says nothing about whether an audit was run; look in this folder. In the subagent form an audit-only run writes no file
  and the audit comes back to the orchestrator (`team/protocol.md`, "Release"); a release's audits are the release record's, below.
- **The release record** — where: `<devhouse home>/release/<project>/` (files as in §4). Read: `ls` the
  folder; the newest `pin-<k>` names R, the remote and the previous public commit, the newest
  `manifest-<k>` names what would be pushed, and a `push-<k>` holding `pushed: <P>` (or `ended by the
  human`) is the outcome and, with `private tag: made` or `declined`, the stage's exit. A release's
  audits name both R and P and report class and location only. **Gotchas:** the public tree is rebuilt
  on every build, so `<version>/public/` is only ever the latest one; an audit is of a commit, so a
  finding that is gone after a fix is still in an older `audit-<k>`; and a clean-looking `git status`
  in the project says nothing about the release, since the record is outside the repo. In the subagent
  form the orchestrator writes the pins, waivers, push files and security file, `@remi` writes her audits and the manifest, and the orchestrator makes the push on the human's approval and records it from the push call's post-push check
  (`main` and the tag at P); it also writes a `base-<k>` for the prep unit's review
  (`team/protocol.md`, *The release stage*). **Where a stopped call shows,** in either form: in the call's own output, which is the Bash result in the transcript of the session that ran it, as `stop: <label>` (a fixed label, never a value), `push status: <n>` and the ref counts after a push, or `already pushed: <P>`. A failed seal's part is also recorded in the next record file the caller writes (the next `audit-<k>`, the security reviewer's `security-<k>` or the `push-<k>`), and a `file://` rehearsal's `To <url>` lines are git's own.
- **Outbound drafts and reviews** — where: `<devhouse home>/outbound/<project>/` (files as in §4). Read:
  open them with any file reader; `ls <devhouse home>/outbound/<project>/` lists the versions, reader
  files and reviews. A review names the draft version it covers and reports each finding as class,
  location and risk, never the value. **Gotcha:** a draft that reached the human with none of the
  review file and none of the three fallback lines (`Not checked by the release manager: declined.`,
  `…: absent.`, `…: waived.`) skipped the route. In the subagent form no review file is written;
  Remi's findings come back to the orchestrator (`team/protocol.md`, *Outbound to people*).
- **Research intake** — where: `<devhouse home>/intake/<project>/passed.md` and `items/` (files as in §4). Read:
  `cat <devhouse home>/intake/<project>/passed.md` lists what passed, one line each
  (`- <kind>: <name> <id> from <source>: passed <date> (<line | report file | answer file>)`); `ls` of `items/` lists
  fetched material. **The checker script writes no log:** a call's output is one line, `intake-check: pass`,
  `pass, yanked` or `refused`, and a stopped intake call prints `stop: intake: <label>` (`field`, `link`, `stage`,
  `fetch`, `hash`, `reach`, `recheck`, `extract`, `tree`, `record` or `settings`) in the Bash result, in the
  transcript of the session that ran it. **Gotcha:** a refused line is answered `Intake: no: a line its checks
  refused.` and never shown, so the reason is only in the checker's own run: re-run it on the field folder,
  which is removed after one use, so write the fields again.
- **Tests results** — `<basename>.tests-<k>.tessa.md`: names the frozen SHA, states how many
  visible and how many hidden tests ran (the hidden count must equal the set's size, or the run
  failed), and reports a hidden failure by requirement and class of input only. Every gate and
  test run records a **provenance line** showing where the code under test was imported from;
  read it to know whether a run used the worktree's code or the shared checkout's.
- **Crew memory and the break room** — where: plain markdown under `<devhouse home>/crew/`
  (`team/protocol.md`, "Crew memory"). Files: per member `index.md`, `worklog.md`, `mistakes.md`,
  `crew.md`, the pointers `.breakroom-seen` and `.breakroom-sent`, and `archive/`; shared
  `breakroom.md` and `archive/`. Format: one line each, `YYYY-MM-DDTHH:MM:SSZ <member> [<project
  folder>]: <text>`, the time in UTC. Read: open the folder in Obsidian, or with any text reader,
  for example `tail -n 20 <devhouse home>/crew/breakroom.md` for the room. Bounds: 40 lines for
  `index.md`, 150 for the other member files, 200 for the room; a full file is rolled to an
  `archive/` folder with `mv -n` and restarted with a summary of at most 10 lines, and nothing is
  deleted. Live messages are in the *receiver's* transcript, like any message, and begin
  `Break room:`; `grep -rl 'Break room:' ~/.claude/projects` lists the transcripts that hold one
  (the form of the `grep` read above; untested). To find the live messages sent, search the
  decoded `SendMessage` inputs, as the transcript audit decodes them (protocol, *Tests*, *Detection, not
  prevention*): a plain grep of the transcripts matches every member, since they all read the protocol. **Gotcha:** a member's reads and
  writes there are best-effort, so a denied or skipped write leaves a gap and no error; a read or
  write skipped after a failed guard (a mismatch, or no recorded line) skips rather than stops, and
  the mismatch is still reported to the manager once per session (a missing line only outside Project
  start).
- **Drafting questions, teaching notes and praise** — where: messages, in the
  *receiver's* transcript, beginning with the exact `Drafting question:` or `Teaching note:`; the
  manager's praise is a word inside a pointer, or a message ending `No reply needed.`; a drafting
  question's answers are also recorded in the work order's `## Drafting questions` section. Read: search
  the decoded `SendMessage` inputs, as the transcript audit decodes them (protocol, *Tests*,
  *Detection, not prevention*); a plain grep of the transcripts matches every member, since they all
  read the protocol and so hold the strings. The `Drafting questions` section reads in the work order.
- **The audit and its heartbeat** — the reviewer's wake audits files and git, never peers. Read a
  gap in her message to the manager (and, for a gap about the manager, to the human in her own session).
  Each wake ends a turn of hers, and the manager is told of it: that notice is the heartbeat, the
  answer to "is the audit running?". She ends every check-in wake turn with the exact line
  `Check-in audit: <n> gaps.` (n may be 0), and a turn-end counts toward the heartbeat only if its
  notice includes `Check-in audit:`, so a social turn (a break-room live message) cannot mask a dead
  wake. Whether the host's turn-end notice carries her final text is unmeasured; if it does not, every
  reviewer turn-end counts. In the reviewer's session
  `CronList` shows the pending job. A reviewer the human opened by hand sends the manager no turn-end
  notices.
- **The transcript audit** — the manager reads the developer's and designer's transcripts under
  `~/.claude/projects/<encoded path>/*.jsonl` and classifies each hit as access or mention
  (`team/protocol.md`, "Tests", *Detection, not prevention*). Its result goes to the human, in the
  manager's session, beside the merge question. Beside it, *Where writes landed* reads **every** member's transcript
  and each one's own subagents' (commands, and the paths of the file tools that write) for writes outside the project, the home and the system temp; a hit is judged and
  reported to the human, never blocking; in the subagent form the orchestrator runs it on each returned transcript.
- **The brief, spec revisions, concerns and reviews** — files in the project:
  `Documentation/brief/brief.md`, `Documentation/brief/<date>-<n>-<member>.md`,
  `Documentation/spec/r<k>/` (`spec.md`, `build-order.md`, `architecture/`), `concerns.makima.md`,
  `review-<n>.roxy.md` and `security-<n>.shiro.md` (a halted review of either kind is headed
  `halted at …`). Read them with any file
  reader; `ls Documentation/spec/` lists the revisions. Where a project is in its start, and which
  revision is locked, is in the project's `CLAUDE.md` (`project start, step <N>`, `planning`).
  The commits are in `git log`: on `main`, the founding commit, the answers commit and the spec lock.
- **Side-session notes** — seen once: a started member's concerns
  reached the manager as a file in the app's side-session notes folder
  (`…\Claude-Data\…\side-session-notes\<manager sessionId>\…`), an app feature, not this
  subsystem's. The protocol treats a file there as an unverified message: the manager confirms
  it with its supposed sender before acting (the folder is keyed by her `sessionId`), and copies what she needs into a file she
  owns (`team/protocol.md`, "Files").
- **Failure modes** — all visible in the session that hit them, as a message to its user:
  refusal (the role is held, or the session already holds another role); an unrenamed session
  (the skill prints the exact title and stops; such a session does not announce and is not a
  member); a near-miss warning (a title equal to a role title after case and whitespace folding,
  never messaged); an absent member (the report row says *absent*); a failed restore after a
  collision (the skill gives the user the prior title to set by hand); group not yet reported
  (try again in a moment); an ungrouped session (the skill asks which group is the team); the
  different-folder warning on a teammate; a retired-title warning (a session still titled
  `Makima the DH Lead`, listed and never messaged); the manager's folder-check question; a member stopped at the home guard (no `devhouse home:` line, or
  a mismatch with her own resolution), who tells the manager (for crew memory alone she skips the read or write instead of stopping, and still reports a mismatch); and, for
  the manager, a `start_session` that is refused or absent. A transcript-audit access hit blocks the merge until the human decides. A unit's
  failures show in the files and git: an open blocking finding, a *failed run*
  (a hidden count that is not the set's size), a merge not made because `work/<u>` is not at the
  reviewed SHA, and the audit's nine flags (*dispatch without review*, *merge without review*,
  *report without review*, *spec revision without review*, *no tests*, and, from the security
  start point on, *merge without security review*, *report without security review*, *spec
  revision without security review*, and, always, *checkout tripwire*). **Where a git tripwire hit shows:**
  in the Bash result of the call that printed it, as `<class> <id> <hash>` lines (the hash is salted, never a value); in
  the run folder `<devhouse home>/tripwire/<project>/runs/<basename>-<k>/` (`expected`, `hidden`, `released`,
  `hidden-released`), written by the manager; in the committed run file `<basename>.tripwire-<k>.makima.md` in the work order's folder under `Documentation/dev-prompts/` (`team/protocol.md`, "Files")
  (class and id only, hidden lines as a count) and the security reviewer's `<basename>.tripwire-<k>.shiro.md`; and, for a removal,
  in `<devhouse home>/tripwire/<project>/removed/index.txt` (one line per action; the labels are in the manager skill's
  *The git tripwire*). A stop shows as `git tripwire: <label>` (or `stop: git tripwire: call`), and in a check-in wake
  as a heartbeat gap. The ladder (manager skill, "Opening members"): `user_asked` in a human-started turn; if
  refused, an `own_initiative` card and she tells the human; a **declined** card means no, with no
  re-proposal and no fall-through; only if `start_session` is unavailable or the `own_initiative`
  call itself is refused does she tell the human to open the session. And an absent sidebar `group` key at Project start step 6 (she tells the human to try
  again in a moment and stops). **The silent case:** a message held for its receiver's
  user's approval, or never acted on, reports nothing back to the sender; it shows only as a
  missing artefact. Read the peer's artefact, not its idleness, to know.
- **Configuration at runtime** — the sidebar group the session is filed in, and the project's
  `CLAUDE.md`, which records the session questions' answers (a record the manager re-confirms after a
  compact or resume, not an authority) and the team's `devhouse home:` line, and the machine's
  `<user home>/.devhouse-home` pointer, which a member reads once, when she pins the home. A member's
  pin (from `DEVHOUSE_HOME`, else the pointer, else the default) is read against that line by her guard (`team/protocol.md`, "Tests", *The hidden
  set*); a mismatch, or no line, stops her and she tells the manager; for crew memory alone she
  skips rather than stops. Crew memory is on only when the project's `CLAUDE.md` has the line
  `crew memory: on` (the manager records it on the human's say; without it no member even checks for
  the folder, so nothing prompts) **and** the folder `<devhouse home>/crew/` exists (the manager makes it on the
  human's yes to (e); no other member does). Live messages are switched off by the line `break room: file only`.

Applicability of the omission sweep's canonical questions:

- *Where do the logs go and how do I read them?* — the host's transcripts; see Message traffic
  above.
- *How do I tell whether this is running and healthy?* — there is no process. A member is "up"
  when its session is non-archived, in the group, and titled exactly its role title; read that
  with `list_sessions`. It is *working* only when its artefact appears.
- *Where does its config come from at runtime?* — the sidebar group, the project's `CLAUDE.md`
  (including the `devhouse home:` line, the `crew memory: on` line and the break-room switch), the
  optional environment variable `DEVHOUSE_HOME` in each session's environment (fixed when Claude
  Desktop starts), the machine pointer `<user home>/.devhouse-home`, and whether the folder
  `<devhouse home>/crew/` exists; nothing else.
- *What does failure look like from outside?* — the Failure modes list above.

## 6. Dependencies

- **Out → Claude Desktop** (hard, and the only supported host): the session-management tools
  `mcp__ccd_session_mgmt__get_session`, `…__list_sessions`, `…__set_session_title`; the sidebar
  tools `mcp__ccd_sidebar__list_groups`, `…__move_sessions`; and the `SendMessage` tool for
  cross-session messages. Outside Desktop the first protocol step finds no `get_session`, and the
  protocol tells the skill to say so to the user and stop (untried: no CLI session has run a
  skill; bare `/devhouse` in the CLI is measured, see §9).
- **Out → Claude Desktop, manager only (Project start and Opening members):**
  `mcp__ccd_directory__change_directory` (effective at the end of the turn, so Project start ends
  its turn after calling it), `mcp__ccd_sidebar__create_group` (with `move_sessions`),
  `mcp__ccd_session__start_session` (deferred; present in fresh sessions, absent from one
  long-lived session) and `mcp__ccd_window__open_session_in`.
- **Out → Claude Desktop, reviewer only (Check-ins):** the scheduling tools `CronCreate`,
  `CronDelete` and `CronList`. Measured: a one-shot job fires as a user
  turn, jobs are session-only, and a session holding a job may pulse in the sidebar. A started member may announce with
  `mcp__ccd_session_mgmt__send_message` instead of `SendMessage`; it delivers (measured).
- **Out → git:** the manager runs `git init` and commits in the project (Project start, the planning
  commit, hands-off checkpoints), creates and deletes unit branches and merges `work/<u>` into the
  integration branch; each builder runs `git worktree add` for her own worktree and the tester a
  detached verification worktree, and so does the security reviewer, for advisory scanners that need
  an install and the network (`git worktree add --detach`, `git worktree remove --force`,
  `git worktree prune`). In an audit the release manager only reads, and writes nothing while she does: `git ls-tree`, `git show`
  and `git grep` for the tree at the tip, and `git log` (with `-p -G` for content), `git for-each-ref`
  and `git cat-file` for authors, committers, tags and what was deleted but still ships (her `log -p`, `show` and `diff` reads of R take `--no-textconv --no-ext-diff --text`). In a release
  her reads of the release commit stay read-only, and the git she writes with stays
  inside the public repo: `git archive` and `tar` to extract the tree, `init -q --template= -b main` (git 2.45.3 or later, checked in precondition 8's call),
  `fetch` of the previous public commit from the remote, `add -A --force`, `update-index --chmod=+x -z --stdin`, `write-tree`,
  `commit-tree` and `update-ref`; no step makes a tag. Every sealed call also runs `mktemp -d -p`, a reference `git init`, `config --local --list -z`, `find -printf`,
  `gawk`, `cmp` and `fsck` (the seal), the only write outside `public/` that every caller, `@remi` and `@shiro` included, may make. Her reads of the release commit add
  `ls-tree -r -z --full-tree`, and `read-tree` into a temporary index with `check-attr -z --stdin --cached`
  on it. The build steps also run `rev-parse --show-toplevel` and `--absolute-git-dir` (the toplevel check
  before each write), `sort -z`, `cmp` and `comm -z` on the lists, and `python -I -B` for the filter and
  its masker, with Python 3.8 or later for a filtered release. The manager's release git adds reads in a fresh bare repository (`rev-parse`, `rev-list
  --parents`, `ls-remote --refs`), a lightweight private `tag` in the shared checkout, and `git push --atomic`,
  the one release command that publishes to a remote (a network, or a `file://` remote), once per approval and by SHA, from that
  bare repository and never from `public/` (the orchestrator, in the subagent form).
- **Out → the shell, git and the filesystem (the git tripwire):** the manager, the reviewer and the orchestrator
  run `env -i … /usr/bin/bash --noprofile --norc '<script>' '<args folder>'` (the call form, protocol *The git
  tripwire*), after `mkdir -p`, `mktemp -d -p` and `cygpath -m` (Windows) for the args folder and `rm -f`, `rmdir` for
  its removal. The script itself uses `sha256sum`, `/dev/urandom` and `od` (the salt and every hash), `stat -c`,
  `find -P` (`-printf`, `-links`, `-type l`), `readlink`, `ln -T` (the salt is a hard link), `mv -n -T`,
  `cp --remove-destination`, `cmp`, `sort -z`, `gawk` and GNU `sed -z`; and git 2.45.3 or later: `rev-parse`,
  `config --list -z`, `diff --raw -z`, `merge-tree --write-tree`, `commit-tree`, `update-ref`, `read-tree -m -u` and
  `-m -i`, `check-attr`, `add --pathspec-from-file` into a private index, `write-tree`, `worktree prune`,
  `fetch --unshallow`, `for-each-ref`, `init` of a reference repository. A missing or non-GNU tool stops the call
  (`call`). The home must be on a volume with hard links.
- **Out → the shell and the filesystem (crew memory):** `cygpath -m`, `test -d`, `date -u`, `cat`
  (the quoted-heredoc append), `grep`, `mv -n`, `mkdir -p`, `wc` and `tail`, in the Bash tool, or the
  PowerShell cmdlets for a member who uses it, against `<devhouse home>/crew/`. The allow rules for
  them are the human's (`README.md`, *Turning on crew memory*), and the rules stay (without
  file-tool memory every memory step is a command that prompts). Without the `crew memory: on` line no
  member runs any of them for memory, and the folder is made by the manager on the human's yes, so a project or machine
  that has not switched memory on never prompts for it. The home check's own Bash calls (protocol, *Check 1's
  Bash*) begin `fail() {` and match none of those rules, so a member may meet one or two prompts at every
  pin; how many is unmeasured.
- **Out → specialist-roster:** every specialist skill reads its `agents/<name>.md` and adopts it.
- **Out → orchestrator-charter:** the manager skill reads `commands/devhouse.md` and adopts it as
  translated; every skill's "Files" rules assume the charter's `Documentation/dev-prompts/`.
- **Out → host skills runtime:** `${CLAUDE_PLUGIN_ROOT}` substitution in skill bodies, to reach
  `team/` and `agents/`; and, measured, in a plugin command's body (the charter
  reads the manager skill by that path). The charter keeps its tell-the-user-to-type-`/devhouse:manager`
  fallback for a path that does not resolve; harmless, and not needed where it does.
- **In ← plugin-packaging:** `skills/` is registered by directory convention.
- **In ← orchestrator-charter:** bare `/devhouse`, answered "Sessions" or "Sessions in windows", reads the manager skill.
- **In ← user:** `/devhouse:<role>`, the sidebar group, and the first message to each session.

## 7. Invariants & constraints

- **No restatement.** Skills cite `team/protocol.md`, the agent files and the charter; they do
  not repeat their sentences. The protocol is the canonical home of the discovery and
  coordination rules (the spec flow, the document folders and contact included); the manager skill is
  canonical for the charter translation, Project start, the session questions, opening members,
  hands-on / hands-off, and the single-session / multi-session distinction.
- **The verbatim lines.** The tools sentence (one wording for specialists, one for the manager) and
  the precedence line are verbatim in every skill that carries them.
- **No tool restriction.** A role session holds whatever tools its session holds; method, not
  tools, keeps a member to its role. The agents' `tools:` lines describe the subagent form.
- **One role per session; one holder per role.** Enforced by the protocol's "Check the role",
  by habit, not by code.
- **Messages go to a `sessionId`, never to a title.**
- **The team is one sidebar group; every session works in one checkout.** Builders' code lives in
  their own git worktrees, and **code runs from its worktree**, never the shared checkout's.
- **The voice stays out of what ships and out of exact strings.** The scope and the exceptions are
  the protocol's *Voice* habit, which this document links and does not restate.
- **Frontmatter:** `name`, `description`, `disable-model-invocation: true`, and no `arguments`,
  `argument-hint`, `model`, `allowed-tools` or `disallowed-tools`.
- **Nothing reaches the mainline without the human;** builders commit only on their own unit
  branches, and only the manager commits to the integration branch, only on the human's say-so for
  that commit (the unit merge is asked for once the merge trigger holds), plus the Project start
  and planning commits approved in Project start step 3 and at the spec approval, and hands-off
  checkpoint merges on the hands-off branch. Merging to the main branch always waits for the
  human.
- **Hands-off overrides two rules, by name, on the human's answers:** the charter's "Never
  auto-advance" / "Human gate between every step", and the protocol's per-commit rule, between build steps only (the maintenance per-task gate
  stands; manager skill, *Modes*). Both are
  recorded in [ADR 0004](../decisions/0004-project-start-and-the-spec-flow.md). In hands-off the manager advances once the unit's checkpoint merge is made. Approving the
  spec is a stop in both modes.
- **The merge trigger is canonical in `team/protocol.md`** ("Units and branches", *Merge into
  `<I>`*): the reviewer has passed the frozen SHA, where the unit is marked security-relevant the
  security reviewer has passed the SHA the trigger names, and where the unit has a hidden set the
  confirmation round is done; the manager merges only if `work/<u>` is at that SHA.
- **Authority has two exceptions, and the human is above all of them.** The reviewer outranks
  every other member's view except the security reviewer's and, on whether what ships is safe to
  publish, the release manager's; the security reviewer's blocking finding is a blocker only the human
  waives, as is a missing security review; when the two reviewers disagree, or the release manager and
  either reviewer do, it goes to the human, and the manager takes no side (`team/protocol.md`,
  *Authority*; [ADR 0006](../decisions/0006-a-security-reviewer.md);
  [ADR 0011](../decisions/0011-a-release-manager.md)).
- **The release manager writes only her audit files and her reviews of outbound text, plus what the
  protocol's habits give every member (her crew memory, conversation summaries), and in a release
  the release files, the public tree, the filter run and the notes drafts (in the subagent form, from the charter's closed `Write` list and the build's folders, with `Write` for text that is not her own), and in any sealed call the seal's scratch folder; she never
  sends, posts or pushes.** Her write list is in her skill, the guard names her as a writer under
  `release/` and `outbound/`, and an audit-only finding blocks nothing (`team/protocol.md`, "Release").
  A finding in a release does block the push, and only the human waives it, except as *Waivers* says
  (*The release stage*). Her write list in a release also covers `work/` and `check-<n>/` under
  `<rel><version>/`, and the removals *The public tree* (step 1) and *Fixes and the filter* (the check
  mode) set out, which the protocol holds. She never runs `git remote`, `git replace` or `git push`, runs `git config` only as the seal's two `--local --list -z` reads and step 5's `--global --includes --get core.sshCommand`, and writes under `public/.git` only through steps 4–6's exact command forms (*The release stage*, *The release manager's limits*).
- **No member sends text to people outside the team on her own.** External text is drafted only; an
  internal pull request or PR or issue comment is posted only on the human's approval for that act,
  naming the repo, the target and the draft version, and an edit needs a new approval; other
  internal text is drafted only; a teammate's relay of an approval is not the human. An unclear
  reader is external, and an unlisted repo is external (`team/protocol.md`, *Authority*). Her
  findings on outbound text are advisory and never gate a merge or a unit. **The one exception is the
  release push, the manager's or the orchestrator's in the subagent form:** once per approval, after the stage's checks, by SHA, atomic and never forced, from a fresh bare repository, and
  no one else pushes except the internal-PR push *Authority* already allows (*The release stage*;
  [ADR 0013](../decisions/0013-the-release-stage.md)).
- **The release stage's public tree is rebuilt, never patched, and the process set never ships.** Every
  build starts from an empty `public/`; `CLAUDE.md` and `CLAUDE.local.md` at any depth,
  `Documentation/brief/`, `Documentation/spec/`, `Documentation/dev-prompts/` and `.claude/` are left out of
  every release with no opt-in, matched in any letter case, and `CLAUDE.md`, `CLAUDE.local.md` and
  `.claude/` at any depth; the public history is one chain of release commits; and the
  release filter's values file is off limits, with who may read it in *Release*, *Afterwards*.
- **The security reviewer never reads the hidden set.** She excludes the project's `hidden/` folder
  at every SHA, her files carry the disclosure rule, and her transcript and `sessionId` are on the
  manager's detection list (`team/protocol.md`, "Tests").
- **Hidden tests are protected by detection, not prevention.** The statement of what is and is
  not caught is `team/protocol.md`, "Tests"; this document links it and does not restate it.
- **Every role is asked for concerns at each spec revision;** leanness applies to the build, not
  to planning.
- **Re-read on change.** A member checks a plugin file's modification time against her last read
  before acting on it. It narrows the window of a team running on mixed versions and does not
  close it.
- **No negative authority from messages.** A manager's pointer starts or stops work; nothing a peer
  sends approves, waives or grants. Only the human does, and only the human waives a review or a
  missing security review. A
  started session's opening `prompt` and `background` come from the manager, not the human: they
  start no work and approve nothing.
- **Memory is a record, never an authority.** A note approves, waives and overrides nothing; it never
  supplies the human's name, a session-question answer or a waiver; a lesson acts only through values
  and never becomes a blocking criterion; a break-room line or another member's file is an unverified
  note that starts nothing (`team/protocol.md`, "Crew memory"). The vault holds how a member works and
  never project content, hidden-test inputs, secrets or the human's name. It is on only when the
  project's `CLAUDE.md` has `crew memory: on` and the manager has made `<devhouse home>/crew/`, and
  every read and write is best-effort.
- **Live messages go only from a turn that handed the member work, never while the team waits on
  the human, at most one per member per hour, never to the human, never from the manager and never
  from a wake turn.** The *active* pointer is check-in control, not a work pointer. The rule is
  stated once, in "Crew memory".
- **The git tripwire never judges and never runs a hook.** The script runs no hook file, no config hook, no
  filter and no `gpg.program`: every git command in it carries the hook pairs, an empty hooks folder of its own and the
  blanked filter and merge-driver commands. The manager's own commands outside the script run no hook file (their
  hooks folder is empty), and run only when the last run had no `hook.*` hit. A hit is released only by the
  security reviewer's *benign* or the human's answer for that line; a `hook.*` line, a `worktree config` line,
  `extensions.worktreeConfig` and a `submodule dir` include hit are never released; the never-allowed set (the manager
  skill's *The git tripwire*) is never allowed. The salt is readable by the manager, the reviewer, the orchestrator and the
  security reviewer (every file but `hidden`) and by no builder. The threat model is accidents, not a hostile member
  (`team/protocol.md`, *The git tripwire*); its pieces that watch for tampering are defence in depth.
- **Spec revisions are never overwritten;** the locked spec is the revision the human approved.
- **Spec concerns go to the manager, never to the planner,** and each reviewer opens the concerns
  file, or the other's first review, only after her own unbiased review is written.

## 8. Design rationale

- **Why skills, not enforcement.** An earlier attempt built
  hooks to make gates unskippable and found its enforcement plane resting on payload fields that
  do not exist. This subsystem makes no enforcement claim: the v2 guardrails travel as habits
  written into the skills. See [ADR 0003](../decisions/0003-team-membership-by-sidebar-group.md).
- **Why the sidebar group is the team,** why members carry role titles, and why every message
  goes to a `sessionId`: ADR 0003, which also records the first design (a team argument and
  `<Member> @ <team>` titles) and why it was dropped (`SendMessage` refuses an address containing ` @ `).
- **Why no tool restriction:** a deny-list leaks (`PowerShell` is a separate tool on this
  platform, `Agent` can dispatch a subagent, MCP and future tools pass), and the thesis is
  habits. The `Agent` route is closed by habit in the protocol's Routing.
- **Why voices carry samples and a habit:** adjectives alone produced flat output; models copy
  examples, and a voice read first and buried under the protocol did not reach one-line
  acknowledgements. The habit widens the scope, `Sounds like:` gives the examples, and the 100-character
  cap is gone. Recorded in [ADR 0007](../decisions/0007-voices-that-show-and-the-manager.md).
- **Why turn-ends are in voice:** left to itself, a member's turn-end to the human takes the host's default report shape, and an announce gets a restatement of the rule; voice that
  reaches only mid-turn messages is hidden where the human reads most. The turn-end rule asks for it,
  and required content wins over variety. Recorded in
  [ADR 0007](../decisions/0007-voices-that-show-and-the-manager.md), amended.
- **Why the announce goes to the manager only:** an announce to all seven others wakes each receiver for a turn, so eight members announcing costs 56 turns before any work. The manager is the only receiver the protocol needs: her pointers start the work, and the
  security start point's fallback is the turn the security reviewer's announce reached her. Finding a teammate later is already
  *Waiting*'s rule (re-read the group before every send), so step 8 adds none.
- **Why values sit in the agent files, and the manager's in her skill:** a specialist in the
  subagent form reads only her agent file, so the values and a label mirroring the rule must be
  there; the manager has no agent file and no persona in the subagent form, so hers are in her skill
  and the subagent-form orchestrator has none. Recorded in [ADR 0008](../decisions/0008-values.md).
- **Why a vault per machine behind two switches, why the room feeds `crew.md`, and why live
  messages are tied to work pointers:** recorded in
  [ADR 0010](../decisions/0010-crew-memory-and-the-break-room.md). One vault shows a member
  everything the human is working on. Memory is on only with the project's `crew memory: on` line
  and the `crew/` folder; without the line no member even checks for the folder, so a project that
  has not switched memory on is never prompted, and a session question keeps a project from
  being left off by forgetting. A work pointer is the one moment a member is awake and the team is
  not waiting on the human.
- **Why a precedence line:** voices are character, methods are gates; a voice is allowed to
  colour how work is done and said but not whether it is sent to review. The line makes the
  tiebreak explicit. Dahlia's fear of Roxy and Tessa is deliberately kept and may make her check
  her own work harder; it may never delay, soften or avoid sending work to them.
- **Why `team/` is outside `skills/`:** `team/protocol.md` is shared by all eight skills and is not
  a skill. It is reached through `${CLAUDE_PLUGIN_ROOT}`; the host resolves that, for a
  directory-marketplace install, to the source folder.
- **Why units, plain git worktrees, detection and audits:** recorded, with the human's answers
  kept apart from the orchestrator's design, in
  [ADR 0005](../decisions/0005-units-of-work-in-the-session-form.md): builders work in parallel
  without clashing, the tests cannot simply be gamed, and members keep each other honest. The
  sessions stay in one checkout; the builders' git worktrees are made by the builders, not by the
  app.
- **Why a separate security reviewer, why neither reviewer outranks the other, and why the
  confirmation round waits for her:** recorded in
  [ADR 0006](../decisions/0006-a-security-reviewer.md). Roxy asks whether work is right and
  consistent and Tessa whether it behaves; nobody asked whether it is secure.
- **Why a release manager, why her audits sit outside the repo and why `release/` is not off
  limits:** recorded in
  [ADR 0011](../decisions/0011-a-release-manager.md). Nobody asked whether the work is safe to
  publish. An audit inside the repo would become part of the tree and history it audits; it holds
  only classes and locations, and the builders already have the repo, so unlike the hidden set it
  needs no detection token.
- **Why Remi's widening, the conservative reading of the human's sending rule, the reader-relative data
  check, no profiling and the cut unit path:** recorded in
  [ADR 0012](../decisions/0012-outbound-to-people.md). A draft goes through the manager to Remi and
  returns with her review so that no outbound text reaches the human unchecked, and the three fallback
  lines make an unchecked draft visible instead of silent.
- **Why the release stage is shaped as it is** (the step order and its reasons, fresh history and one
  public line, the fixed process set and the process-traces class, the filter's values outside the repo,
  the release identity and its hardening, lightweight tags, why the manager pushes and, in the subagent
  form, why the orchestrator does, on the human's approval for that push, and how the push squares with the sending rule):
  recorded in [ADR 0013](../decisions/0013-the-release-stage.md).
- **Why the push is made from a fresh repository, `public/` is sealed before every read, and every stop is `fail`** (the reasons in [ADR 0013](../decisions/0013-the-release-stage.md)'s *Amendment: the push, and every read of `public/`*):
  - *`set -e` and `fail`:* the Bash tool ignores `set -e`, so nothing the stage "stopped" on stopped; a label-only `fail` also keeps a
    credential or a planted name out of the output.
  - *The fresh repository:* the first design tried to prove `public/.git` harmless just before the push and every check left another way in, so the push fetches P into a bare repository made with
    `--template=` in the same call and checks it by SHA, where `index-pack` hashes what it receives.
  - *The seal:* the audits and extracts read `public/` too, and a replace ref, a forged commit graph or an attributes file makes them see a different commit from the one that ships; so every read is sealed against a reference repository made fresh in the same call.
  - *Switching off the global attributes file, but trusting the rest of the human's config:* switching it off costs a release nothing; the human's other files are inside the trust boundary, which the protocol states with its limit.
  - *Atomic, no tag from a step, text by file tool, escaped paths:* a partial push cannot be left behind; a local public tag is one more ref in a writable `.git`; a content line equal to a heredoc delimiter runs as shell; a newline in a path forges a record line.
- **Why one canonical home per fact,** and the copy policy: reading plugin files from outside the
  session's folder raised no permission card (measured), so skills reference the files
  instead of carrying copies. The `<!-- sync -->` copy fallback was designed for the opposite
  result and is not used. [ADR 0003](../decisions/0003-team-membership-by-sidebar-group.md)
  records that.
- **Why the window choice is a project setting.** Opening each member in her own window is the human's
  view of the team, not the team's, so it is a layout setting kept as one `member windows: on|off` line in the
  project's `CLAUDE.md` (the manager skill's *The window setting*). The line is the only source and is read as
  written after a compact or a resume, unlike (a) and (b), which are re-confirmed. The first question's third
  answer, *Sessions in windows*, writes it from the start. No new ADR: this is before v1.0, and ADR 0004's stub
  keeps its description of the first step as decided then.

## 9. Gotchas

- **Claude Desktop only.** The first protocol step needs `get_session`; in the CLI the protocol
  tells the skill to stop with a message (untried for the role skills). Bare `/devhouse` in the
  CLI is measured: no question, "session management isn't available here", and the subagent form.
  A CLI transport is not built.
- **The team must share the project folder.** A Desktop session opened with no project folder
  gets its own app-made scratch folder, so each of eight such sessions has a different `cwd` and a
  different checkout. The protocol warns *different folder* when a teammate's `cwd` differs, which
  fires on every session in that case; it also fires for worktrees. The manager founds the
  project folder and moves her own session in with `change_directory`, and the members she starts
  with `use_worktree: false` work in her current (post-move) folder, on her branch (measured).
  Members opened by hand still need the project folder.
- **Project start spans two turns.** `change_directory` takes effect at the end of the turn, so
  the manager asks the session questions and ends her turn; the answers arrive in the new folder,
  which then loads the new `CLAUDE.md`. Until the turn ends `get_session` shows the old `cwd`.
  After it, `get_session` and `list_sessions` show the new `cwd` and group (measured).
- **A `user_asked` start is refused in a turn a teammate's message triggered** (measured). The
  manager therefore opens members in turns the human starts, ahead of the phase that needs them
  (manager skill, "Opening members", *When*), and opens the whole planning set (planner, reviewer,
  security reviewer, designer, developer, tester, release manager) in the human's spec-work turn.
  Whether a standing "yes" is honoured in a late human-started turn is unmeasured, and so is
  `permission_mode` inheritance (an omitted field).
- **The recorded answers are not an authority.** The recorded session-question answers are a
  record; after a compact or a resume the manager treats "open without asking" and "hands-off" as
  not given until the human re-confirms.
- **Role titles are restated in several places and must change together:** the table in
  `team/protocol.md` (the matching key, and the table to read for the eight titles), each
  `SKILL.md` (its opening line and item 1), the README's Session-form table, `overview.md` §9
  Glossary's example, and ADR 0003's *Decision*. There is no automated check. A retired title (`Makima the DH Lead`) is
  listed in the protocol, beside the table.
- **Title propagation timing is unmeasured.** Collision handling assumes a rename shows in the
  other session's `list_sessions` before that session's re-check. How fast it does is unknown, so
  two sessions claiming one role at the same instant may both keep it. Collision handling has
  never been exercised.
- **Group not yet reported** is also unexercised: the app may omit a session's `group` key at
  startup; the protocol treats absent as unknown and asks the user to retry.
- **Whether a no-folder session's app-made folder is empty is unmeasured.** Project start's
  trigger depends on it: a non-empty one has no `CLAUDE.md` yet is not empty, so it would take the
  existing-codebase branch instead of founding a project.
- **Near-misses are warned about, not corrected.** A teammate titled `roxy the dh reviewer` is
  listed as a near-miss warning and never messaged, so it is not on the team; fix the title.
- **Silence is not agreement.** A message to a peer in a different permission mode may be held
  for its user's approval and may expire without notice.
- **A non-role session in the group is ignored.**
- **Cross-session `@path` attaches nothing;** messages carry plain absolute paths.
- **The planner's output is the work order itself,** not a `plan` artefact; the artefact kinds
  are `review`, `security`, `report`, `design`, `tests`, `validity` (written under the hidden home, outside
  `Documentation/`) and, for work-order-less artefacts, `audit`, `outbound`, `pin`, `manifest`, `waiver`, `push` and `base` (the last in the subagent form only; also outside `Documentation/`).
- **A scheduled prompt arrives as a user turn,** so it can look like the human; the protocol
  (*Authority*) says it is the reviewer's own reminder. A session holding a job may **pulse** in
  the sidebar.
- **A started member's turn-end wakes the manager,** whether or not she acts on it. Measured on a
  manager's transcript: a turn she only acknowledges is one call re-reading about
  314k to 351k cached tokens and writing about 40 tokens; a turn she acts on averaged about six
  calls and 1.3M cached tokens. The check-ins' cost (about four reviewer turns an hour while a
  unit is active) is this cost.
- **Detection has limits.** The transcript audit catches literal access to the hidden home, the
  verification worktrees, the off-limits crew folders (`crew/tessa`, `crew/roxy`, `crew/shiro` and
  `crew/makima`), the tester's, reviewer's, security reviewer's, manager's and release manager's
  transcripts and the side-session notes; it does not catch a glob of a parent folder, a path assembled in a shell variable, a copy
  made elsewhere, or a member relaying the set, and the reviewer's check does not catch a peek that
  led to a genuinely general fix (`team/protocol.md`, "Tests", *Detection, not prevention*). Run
  through the Bash tool, a regex with a doubled backslash silently missed a real hit three times,
  so the protocol has the manager normalise separators and avoid backslash literals.
- **A team can run on mixed versions.** For a directory-marketplace install the plugin is read from its source folder, so an edit
  reaches a running team piecemeal: a manager and planner can pick up an edit mid-run while
  the reviewer audits from her session-start copy, which produced a spurious finding and a missed
  human route. The protocol's *Re-read on change* narrows this and does not close it.
- **Several rules are sensitive to the Windows shell.** `%USERPROFILE%` expands only in cmd.exe and
  unquoted backslashes collapse in Bash; either yields a relative path inside the repo. The
  protocol writes the devhouse home as `<devhouse home>` and has each member resolve it to an
  absolute path first, in Bash (`cygpath -m`) or PowerShell, and refuse anything that is not
  absolute, which catches a literal `%USERPROFILE%` stored by `setx`.
- **The variable is read when the Claude Desktop process starts; the pointer is not.** An environment belongs to a process, so
  set `DEVHOUSE_HOME` (README, *Advanced*), fully quit Desktop (including from the tray), relaunch, and sessions reopened
  after that see it. That a full quit and relaunch is enough is unmeasured. The machine pointer `<user home>/.devhouse-home` is a file, read when a session pins its home, so
  a change takes effect for any session that pins afterwards and running sessions carry on with their pin until they re-pin or restart
  (the tripwire makes that loud, never silent: ADR 0014). The guard's `default` matches only a case-3 pin (no variable, and a pointer that is absent or says `default`), not by path. Every member takes the user home from Git Bash's `$HOME`, PowerShell included, so a
  PowerShell member and a Bash member read the same pointer and resolve the default alike. The detection patterns follow the home whatever its prefix, with the `.devhouse/` forms
  always searched; the access-or-mention rule is unchanged. The bare `DEVHOUSE_HOME` token
  is not a pattern (the guard's resolution command, which every member runs, names the variable): it
  flags only when followed, anywhere later in the same path argument and after any `}` or quote, by
  `/hidden-tests`, `/verify`, `/release/<project>/filter-values` or an off-limits crew folder, and `crew/(tessa|roxy|shiro|makima)` is
  searched on its own (`release/<project>/filter-values` too).
- **A pending permission prompt blocks a turn,** so memory is opt-in per project: the human sets the
  allow rules for reads and writes under `<devhouse home>/crew/**` and for the Bash commands the
  protocol uses, then says yes to (e), and the manager makes the folder and records `crew memory: on`,
  above all before hands-off. A memory denial is skipped, not escalated, and in hands-off it is not a
  real blocker.
- **Rolling and appending can race.** Two instances of one member can collide on `index.md` and the
  pointers, several members can roll the shared room at once, and an append that races a roll may
  land in the moved file; `mv -n` keeps anything from being overwritten, the fresh file starts only after the source is confirmed gone and the archive file present (a skipped `mv -n` is re-numbered and retried once, otherwise the write is skipped), and the rest is accepted.
  Lines rolled away before a member read them reach her only through the summary. A live message
  can also land in a wait that started just after it was sent; accepted.
- **The break room can show a message to the human.** A recipient whose permission mode holds
  messages shows a live message to the human; that is accepted, and `break room: file only` is the
  off switch.
- **Unmeasured:** whether a compact or resume re-runs a skill, which decides whether a member
  re-reads her memory then (`team/protocol.md`, "Crew memory"). The off-limits crew
  folders are protected by detection, as the hidden tests are (the audit's `crew/(tessa|roxy|shiro|makima)`
  pattern); a path assembled in a shell variable is not caught.
- **A missing scan is never a silent pass.** The security reviewer's dependency check needs an
  install and the network, in her own verification worktree; if she cannot run it, her review says
  so. She reports `/security-review` invocable through the Skill tool; it has not been run on a
  diff, and if it cannot run she says so and carries on.
- **A release is a stage the whole team waits in, and its habits can fail quietly.** The freeze holds
  every other commit on the mainline, so a release started mid-unit is refused at entry and a tip that
  moves is caught only at the checks (a human who commits meanwhile ends or re-pins the release). The
  remote must be created empty, or the push checks refuse it. The release identity, UTC dates and an
  unsigned P are checked after the commit, not enforced by git; two behaviours of `commit-tree` are
  unmeasured. A filter's values are protected by the detection pattern
  and the disclosure rule, not by a technical barrier (the file is readable by the human's user, as
  everything is). The transcript (access) audit covers only the developer and the designer, so for every other
  member, and every subagent, the values file rests on habit; the README's crew-memory allow rules, and
  any project-level `Read` rule over the home, let them read it without a prompt, which the manager's
  read-only check of the settings files tells the human about. Nothing stops a member running `git push` on her own; the exception in *Authority*
  is a habit like the rest, and the push is made by SHA so a wrong ref is visible in the record.
  Authentication, a retry after a failed push (a new approval and a new push call) and the subagent form are unprobed; the last includes
  `@remi` running the filter and the orchestrator making the push. The build steps run under a shell, and each of these can fail quietly: a committed symlink that `tar` copies the target of; an NTFS
  junction under the record that redirects an `rm -rf`; `git -C ""` and an inherited `GIT_DIR`, which
  defeat a toplevel check; an export attribute (`export-subst`, `export-ignore`, `ident`, `filter=`)
  that makes the public tree differ from the release commit; and a comparison through process
  substitution, which `pipefail` does not cover. The protocol's *How each step runs* closes
  each one, and none is probed.
- **Ways a stage command trusted state any member can write, or stopped nothing** (*The public tree*, *How each step runs* and *The push* close them):
  - **`set -e` does nothing in the Bash tool** (`set -e; false; echo after` prints `after`), so a
    push written with `set -euo pipefail` still ran after a failed SHA or URL check.
    `pipefail`, `exit`, shell functions and an `EXIT` trap work, so every stop is `|| fail '<label>'`, and `fail` runs at the call's top level only (`exit` in `$( )` leaves only the subshell).
  - **A replace ref** (`git replace P_bad P_good`) makes every read the audits make see P_good while `rev-parse` prints P_bad, which the manifest pins and the push sends. `GIT_NO_REPLACE_OBJECTS=1` and `GIT_GRAFT_FILE=/dev/null` close it for reads; the seal's `refs` part catches a ref in `public/`.
  - **A forged `objects/info/commit-graph`, an overwritten loose object or a patched `multi-pack-index`** changes what `git archive`, `show` and `log -p` report without changing the SHA. The seal's `objects/info` part and its integrity-only `fsck` catch them.
  - **An attributes file no check saw** (`.git/info/attributes`, or the global `~/.config/git/attributes`, which git reads with no config key) with `export-ignore` dropped a file from an extract, and a local `filter.<x>.smudge` ran during `git archive`. The header switches the global and system files off; the seal's `entries` part rejects `info/`.
  - **A local `url.<x>.pushInsteadOf`, a `pre-push` hook, `credential.helper = !<cmd>`, `core.sshCommand`** in `public/.git`, and a global `push.followTags`, acted on a push made from `public/`. The push runs from a fresh bare repository made with `--template=`, with `--no-verify --no-follow-tags`.
  - **`$(git config core.sshCommand)` with no `-C`** read the shared checkout's writable local config and became the push's `GIT_SSH_COMMAND`; it is `git config --global --includes`.
  - **The URL check printed a credential** held in a config key's name (`git config --get-regexp` on a `url.<token>@…` key). Every check prints a fixed label and nothing else.
  - **A global `core.fsmonitor=true`** (a Git for Windows installer option) made the seal's own commands create `.git/fsmonitor--daemon/`, so every later seal failed; the header sets `core.fsmonitor=false`.
  - **A heredoc delimiter on a content line** ends the heredoc early and the next line runs as shell; text that is not the writer's own is written with a file tool, and the two heredocs that stay check every line first.
  - **A path with a newline** splits one record line into two, the second looking like the writer's; paths in release files are escaped in sed's `l` form after masking.
- **The `Security-relevant` mark is only as good as its writer.** The reviewer's pre-dispatch review
  checks it in session form, and a missing line in a new work order is a blocking finding; in the
  subagent form nothing catches a wrong *no*. Revisions before a project's security start point,
  work orders with no line, and the units in the `Grandfathered units:` list written beside the
  start point (written when she first joins: the units dispatched before the turn of the
  `start_session` call, or the ask to the human, that she joined from, or if neither, before her
  announcement reached the manager) are grandfathered, so the audit stays silent on them; until a project
  has a start point (she was never opened, or was declined), its marks gate nothing. Once there is one, if the human declined opening her for a
  marked unit, its merge needs their waiver of the missing review, recorded (with "security
  reviewer declined for <u>") in the project's `CLAUDE.md` *Security waivers* list, not in the work
  order; in hands-off that is a real blocker.
- **The host's own summary format competes with voice.** Each Desktop session's system prompt tells
  the model how to write its end-of-turn summary (outcome first, then bullets), a standing
  instruction outside the skill. The turn-end rule asks for a line or two in voice; it
  does not enforce it.
- **Read-only wording is subagent-form.** The charter's "Pris is read-only" invariant, Roxy's
  "read-only" in the charter and README Role text, and the agents' `tools:` lines describe the
  subagent form. In session form nothing restricts tools.
- **The git tripwire's day-one noise.** These are expected, and each is told to the
  human in the README:
  - a clone's own `remote.<name>.url`, `branch.<name>.remote` and `merge`, VS Code's `branch.<name>.vscode-merge-base` and a
    `remote.<name>.pushurl` are `config key` hits once, and each allowed one draws a one-time keep-or-remove question;
  - a `pre-commit` or husky user's first unit that touches their config is a `hook framework file` hit, and husky's local
    `core.hooksPath` is a never-allowed key judged at every merge until removed; their own guard is skipped by every
    devhouse commit and merge (the script's note says so);
  - a stale `worktrees/<id>` entry (a deleted worktree's leftover) is a `worktree link` hit until pruned;
  - a unit that changes `.vscode/settings.json` fires an `editor file` hit;
  - **submodules and sparse checkouts are held:** a `modules/` folder is a `submodule dir` hit, `core.sparseCheckout` or
    any skip-worktree entry **stops `merge`** (nothing moved), and a unit that writes a path naming a configured filter driver
    (Git LFS, git-crypt, `nbstripout`) stops `merge` or `commit`; the human commits and merges those outside the team;
  - a stale `.git/index.lock`, a pending merge or rebase, or a staged file stops a merge or commit with nothing moved;
  - a second machine, or a moved home, has no salt: every call stops until it is made, and every allowed line fires again;
  - `check-unit` says "part 3 holds; parts 1-2 were not read" for a never-released line too, though releasing it cannot help.
- **`tripwire` is two things.** The guard's check 3 is also called "the tripwire"; the git tripwire is always
  written in full. `overview.md` §9 tells them apart.

## 10. Tests

No automated suite; the subsystem is markdown. Verification is the static checks below, plus runs by the human in Claude Desktop on Windows.

**Static checks** (re-run on every change to a skill, an agent file or the protocol): both manifests parse as
JSON; `claude plugin validate plugins/devhouse` passes (it also reports plugin-directory advice
about a missing icon, which is not a failure; run it on the CRLF tree, where it is the
runtime's strict parse alone, YAML 1.2, balancing PyYAML's 1.1, and its result depends on line
endings: `plugin-packaging.md` §9); `python -I tools/check-frontmatter.py` passes (the frontmatter
check, whose result does not depend on line endings: `plugin-packaging.md` §3); each `SKILL.md` has the frontmatter
above; no file under `plugins/devhouse/` contains ` @ <`, ` @ `, `<team>` or `$team`; no skill contains
a full sentence of the protocol, its agent file or the charter; the tools sentence and the
precedence line are verbatim; the shipped intake script `plugins/devhouse/team/intake-check.py` holds no CR
byte (`tr -cd '\r' < <file> | wc -c` prints 0), and `python -I -S -B tools/tests/intake-check/run.py` passes on
its working-tree bytes and, after a reinstall, on the installed copy (`plugin-packaging.md` §3, §7); every `## Voice` passes the voice check below, and every values block
passes the values check after it. For crew memory: the seven agent files carry the
same sync-marked line (`grep -h '^If your dispatch names a crew path' plugins/devhouse/agents/*.md | sort -u | wc -l`
prints 1, and `grep -c '^If your dispatch names a crew path' <F>` prints 1 in each file), placed after a blank line
that follows the values block, so the values check's block still ends where it did; and each skill's step 1 cites
the habit (`grep -c 'Crew memory' plugins/devhouse/skills/*/SKILL.md` prints at least 1 for each).

**The voice check.** A `## Voice` is its **trait lines**, the list items before the label
`Sounds like:`, then the label, then the samples.

- **Size:** 4 to 12 trait lines, counted as list items; the label and the samples are not counted.
  Pass or fail.
- **Trait lines:** second person and indicative; none an imperative; none containing a banned
  word: `must`, `should`, `always`, `never`, `if`, `unless`, `do not`, `don't` (a voice is
  character, not a rule). A quoted word inside a trait line is part of the trait line, and the
  checks apply to it.
- **The gate rule:** no voice line, trait or sample, weakens a gate. The reviewer judges it.
- **`Sounds like:`:** each Voice ends with the label and 2 to 8 samples, one list item per sample,
  counted by list item and not by quote marks. An item may carry a short unquoted prefix ("To
  Roxy:"). Only the items under the label are exempt from the banned-word list and the imperative
  test, so Tessa may say "if you design it right" and Delia "Fix it".

Commands, per skill (`<SKILL.md>`): the trait count `awk '/^## Voice/{f=1;next}/^## /{f=0}/^Sounds like:/{f=0}f&&/^- /' <SKILL.md> | wc -l` prints 4 to 12; the banned words `awk '/^## Voice/{f=1;next}/^## /{f=0}/^Sounds like:/{f=0}f&&NF' <SKILL.md> | grep -niE "\b(must|should|always|never|if|unless|do not|don't)\b"` prints nothing; the sample count `awk '/^Sounds like:/{g=1;next}/^## /{g=0}g&&/^- /' <SKILL.md> | wc -l` prints 2 to 8.

Counts, per skill (traits, then samples): manager 5 and 4, planner 6 and 5, designer 7 and 5,
developer 8 and 5, tester 8 and 6, reviewer 8 and 4, security reviewer 5 and 4, release manager 7 and 4. No
banned word is in any trait, and `awk '/^Sounds like:/{g=1;next}/^## /{g=0}g' plugins/devhouse/skills/*/SKILL.md | grep -niE "no reply needed|waiting for|protocol says"`
prints nothing (no sample narrates a rule).

**The values check.** It covers eight **blocks**: the seven agent files
(`plugins/devhouse/agents/*.md`) and the manager's `## Values` in `skills/manager/SKILL.md`. A block
runs from the **label line**, the line starting `Values (in order).`, to the first blank line; its
items are the numbered lines after the label.

- **Count:** 3 to 6 items, every line after the label numbered.
- **Form:** no item is an imperative, and the member herself is addressed in the second person
  ("you", "your"), never by her own name or as "she" (a teammate may be named, as the items name
  one). Judged by reading, with the mechanical part below.
- **Banned words:** none of the voice check's list (`must`, `should`, `always`, `never`, `if`,
  `unless`, `do not`, `don't`), applied to the **items only**. The label line is exempt, as
  `Sounds like:` items are.
- **The label line:** byte-identical in all seven agent files. The manager's block opens with
  `Values (in order).` and then cites the protocol's *Values* habit instead of mirroring it, so the
  mirror is kept in seven places and the rule stays canonical in one (ADR 0001's pattern).
- **The gate rule:** the protocol's *Values* habit applied by reading: no item breaks it. The
  reviewer judges it, with [ADR 0008](../decisions/0008-values.md)'s *The relational items, read
  against the gates*. **Remi's value 4**, "Tessa's and Delia's work, which you
  audit as strictly as anyone's and praise the loudest", is read the same way: it adds warmth and
  never softness, and her audit standard is the same for everyone. Shiro's value 4 names Roxy
  and Remi noticing her work, which is care for their regard and bypasses no routing.

Commands, per file (`<F>`; `BLOCK` stands for `awk '/^Values \(in order\)\./{f=1;next}f&&/^$/{exit}f' <F>`): the item count `BLOCK | grep -cE '^[0-9]+\. '` prints 3 to 6; the unnumbered lines `BLOCK | grep -vcE '^[0-9]+\. '` print 0; the banned words `BLOCK | grep -niE "\b(must|should|always|never|if|unless|do not|don't)\b"` print nothing; the member's own name or "she" `BLOCK | grep -niE "\b(<own name>|she)\b"` prints nothing; the label line is the same in the seven agent files `grep -h '^Values (in order)\.' plugins/devhouse/agents/*.md | sort -u | wc -l` prints 1, and `grep -c '^Values (in order)\.' <F>` prints 1 in each of the eight blocks' files.
