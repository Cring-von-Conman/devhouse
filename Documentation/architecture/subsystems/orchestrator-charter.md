# Subsystem: Orchestrator Charter

## 1. Responsibility

Defines the co-PM/orchestrator role and the entire operating process of the dev-house: the
two modes (advisory, autonomous loop), the invariants that hold in both, the three tracks
(build, maintenance, Track 0 onboarding), the guardrails, and the documentation standard.
It is the single source of truth for *how the house runs*. It owns process, not code — it
never edits plan/source/schema, only meta files (`devhouse.md`, "Never edit the plan, source, or schema directly").

## 2. Entry points

- `plugins/devhouse/commands/devhouse.md` — the whole subsystem is this one file. Its YAML
  frontmatter `description` (`devhouse.md` frontmatter, `description:`) registers the `/devhouse` slash command; the body is
  the instruction set the main session adopts.

## 3. Key components

- **Activation block** (`devhouse.md`, "You are now the **co-PM / orchestrator**", "First step, before anything else." and "On activation:") — assumes the orchestrator role, orients from
  `CLAUDE.md` `## Current status & next step`, defaults to advisory and waits. In Claude Desktop
  the first step asks "Sessions or Subagents?" before any of that, as an options prompt with three options:
  *Subagents* continues with the charter; *Sessions* and *Sessions in windows* read the manager skill and
  follow it (session form), carrying the window choice (`member windows: off` or `on`), with a fallback telling
  the user to type `/devhouse:manager` if the path did not resolve (the choice is lost; the manager uses the project's `member windows:` line, or asks). Without `get_session` (the CLI) it
  proceeds as the subagent form without asking. The first paragraph says the command offers both
  forms and cites the manager skill.
- **Modes** (`devhouse.md` § "Modes") — advisory (default) vs. autonomous loop.
- **Invariants (both modes)** (`devhouse.md` § "Invariants (both modes)") — never edit plan/source/schema
  (the meta-files exception also lists the subagent form's `outbound/` writes (apart from the release notes drafts, which are `@remi`'s) and, in a release, its record files under `release/<project>/` (the public tree and the release manager's files are `@remi`'s), and its release push and private tag, with the protocol's guard);
  file-based handoff; crew memory (subagent form); research intake (subagent form: a subagent that needs to
  bring something in returns an `Intake: …` line (or an `Intake staging: …` notice, after which the orchestrator
  sends the full line) and stops; the orchestrator does the folder work for every
  subagent, runs the shipped checker script, dispatches `@shiro` in the foreground with the full line quoted as
  data and the protocol and script paths, accepts only a
  pass that starts her return, records in `passed.md` and writes `<basename>.intake-<k>.orchestrator.md`; the
  meta-files exception lists these writes; [ADR 0016](../decisions/0016-research-intake.md)); the git tripwire
  (subagent form: the orchestrator runs the shipped script's `commit` mode before each checkpoint commit, writes the run
  folder, the run file and the record of `@shiro`'s judgement, keeps `allowed`, the salt and the removals, and makes the
  salt before its first checkpoint commit; the meta-files exception lists these writes;
  [ADR 0015](../decisions/0015-the-git-tripwire.md)); test writes (subagent form: every dispatch of `@dahlia`,
  `@tessa` or `@shiro` carries the protocol's *Where test writes go* by name and the resolved protocol path; when the
  subagent returns, the orchestrator runs the protocol's *Where writes landed* pattern over its transcript, judges each
  hit and reports a confirmed write to the human; `@remi`'s calls are a closed list); outbound text (neither the orchestrator nor any
  specialist it dispatches sends, posts or publishes text for people other than the team, except as the
  protocol's *Authority* allows, and only the orchestrator posts, never a subagent: a dispatch prompt is a
  relay; [ADR 0012](../decisions/0012-outbound-to-people.md)); verify real-world constants (`// VERIFY`); decide,
  don't punt; Pris read-only (subagent form) / only Dahlia writes application code. The crew-memory
  invariant is one line: if the project's `CLAUDE.md` has `crew memory: on` and `<devhouse home>/crew/`
  exists, name `<home>/crew/<member>/` in each dispatch, with the home as the orchestrator's pin (a read-only subagent cannot resolve
  the home; every dispatch that touches it carries the pin, its case, the user home and `CLAUDE_CONFIG_DIR` when set), and the subagent form reads memory and writes none (`team/protocol.md`, *Crew
  memory*; [ADR 0010](../decisions/0010-crew-memory-and-the-break-room.md)).
- **Roster table** (`devhouse.md` § "The dev house roster", the table beginning `| Name | Handle |`) — the dispatch reference; duplicates the roster
  subsystem's authoritative data (see Gotchas). One citing line follows the table: each specialist's
  agent file carries her ranked values, which never weaken a gate, and in the subagent form the
  orchestrator has no persona, so it has no values (`team/protocol.md`, *Values*; rationale in
  [ADR 0008](../decisions/0008-values.md)). A second line follows it: `@remi`'s audit-only mode and outbound text are
  the protocol's *Release* and its *Outbound to people*, and in the subagent form she returns her
  findings (class and location, plus risk for outbound) to the orchestrator, which shows the human,
  and she writes no file outside a release (in a release she is the runner: *A release in the subagent form*); for outbound, the orchestrator offers her and never auto-dispatches
  ([ADR 0011](../decisions/0011-a-release-manager.md); [ADR 0012](../decisions/0012-outbound-to-people.md)).
  The roster's introduction excepts her from description-based auto-dispatch: she is invoked only
  when named, and that includes her release audits. A third item follows the `@remi` line:
  **a release in the subagent form** (the protocol's *The release stage*; not a loop track, so the charter
  still has two tracks). The prep, fix and filter units are ordinary maintenance work orders for
  `@dahlia`, gated by `@roxy`. The charter's first bullet, *Who does what*, is the one mapping: the orchestrator
  takes the manager's place, `@remi` (dispatched for each of her steps) takes the release manager's and is the runner, and `@shiro`
  takes the security reviewer's. `@remi` drafts the notes (`….remi.md`) for the human to approve, builds the public tree and runs the
  filter there (she passes the values file's path to the filter and nobody opens the file; unprobed), and writes her audits and the
  manifest, through a closed `Write` list. The orchestrator dispatches her and `@shiro`, writes the record in
  `<devhouse home>/release/<project>/` with the `.orchestrator.md` writer segment (pins, waivers, `base`, push files and the security
  file), trusts from her nothing it can build itself (the names it gave her, P from the latest audit at P, its own masker, hashes of
  its own files), checks the protocol's preconditions 2–10 and states the home at entry (the human confirms it, and the orchestrator waits; the release
  runs in any permission mode, with a baseline of the checkout's git config, hooks and `.claude/` recorded before any dispatch and compared before each push question, and the human decides what a difference means), and **ends with the push, which it makes** on the human's approval for that push
  (the protocol's *The push*: the pre-asking call, the question, and the push call from a fresh bare repository, one per approval;
  no command is handed to the human). The push by SHA also creates the remote's tag, and no step makes a local public tag (the
  protocol's *Tags*). After a successful push it asks the private-tag question and, on the human's say, runs the tag. It
  records the push's outcome from the push call's own post-push check that `refs/heads/main` and `refs/tags/v<version>`
  both point at P (*The push* is the canonical statement), and records `release identity:` in `CLAUDE.md` on the
  human's say. For the prep unit's review, where Roxy has no shell, the orchestrator works out her notes base
  and passes it to her inline, recording it as `base-<k>` in `<devhouse home>/release/<project>/` (the protocol's *The prep unit and the
  notes*, step 4; the charter's *Units* sub-bullet holds the rules) ([ADR 0013](../decisions/0013-the-release-stage.md)).
  Its bullets carry the canonical statements: *Who does what*, the home at entry and the permission mode, her `Write` targets, what the orchestrator trusts from her, the dispatch contents with her legitimate calls, and the security reviewer's pass (whose return is entry numbers, never paths, whenever a values file exists). Another only cites the values file's stated limit, whose home is the protocol's *Tests*, *Detection, not prevention*. The model guardrail ("cheapest sufficient model per role") names Remi on Sonnet. None of the three citing lines is
  part of the table the README mirrors.
- **Build track** (`devhouse.md` § "Build track — greenfield (project build order)") — the per-step greenfield loop + guardrails.
- **Maintenance track incl. Track 0** (`devhouse.md` § "Maintenance track — existing code", incl. "Track 0 — Onboarding") — per-task loop and the onboarding
  project definition.
- **Session-form qualifiers on the loop** — parenthetical "(Session form: …)" clauses that point
  the loop at `plugins/devhouse/team/protocol.md` for the session form's unit mechanics; the
  subagent form reads as before. Build step 3: the manager also creates the unit's branch on first
  dispatch and dispatches the other builders the unit needs, and a re-dispatch after step 5 reuses
  the branch and the builders' worktrees (*Units and branches*). Build step 4 (Tessa): she also
  writes a hidden set at the unit's start and runs it at each review (*Tests*). Build step 6: the
  checkpoint is the unit's merge into the integration branch, asked for when *Units and branches*'
  merge trigger holds. Maintenance step 5 (Verify): the same hidden-set clause as build step 4.
  Maintenance step 6 (Gate): the same merge clause as build step 6. The cap itself ("Cap: 3
  iterations.") has no qualifier in the charter; the protocol applies it in the session form by
  counting a unit's frozen SHAs, and **excludes the confirmation re-freeze and the re-freeze after
  a merge conflict** (*Units and branches*, *Freeze*). Rationale:
  [ADR 0005](../decisions/0005-units-of-work-in-the-session-form.md).
- **Security review in the loop** (`devhouse.md`, build step 2, build step 4, maintenance step 5 and
  the guardrails) — subagent form: after @pris produces spec or work-order design, @shiro
  threat-models it; the orchestrator sets the work order's `**Security-relevant:** yes | no` mark
  when it assembles it, by the criteria in the protocol's *Files* (the charter cites them and does
  not restate them); where marked, @shiro reviews the output and her pass is part of the Done gate
  (the "Roxy gates done" guardrail names her). *Stated limit:* the subagent form has no
  pre-dispatch review, so nothing catches a wrong *no*. Rationale:
  [ADR 0006](../decisions/0006-a-security-reviewer.md).
- **Documentation standard** (`devhouse.md` § "Documentation standard") — layout, required sections for
  `overview.md` and `subsystems/*.md`, the grounded-claims rules, and Roxy's validation
  checklist.

## 4. Data & state

None owned in this repo. At runtime the charter *directs writes* to host-project files it
treats as state — `CLAUDE.md`, `Documentation/dev-prompts/`, `Documentation/architecture/` —
but the charter file itself holds no persistent state and stores nothing. `Documentation/dev-prompts/`
now also holds the session form's per-work-order artefacts (reviews, reports, designs, tests; the `validity` kind is the exception, written outside `Documentation/`), named
`<basename>.<kind>-<k>.<member>.md` by `plugins/devhouse/team/protocol.md` ("Files"); the charter
still owns the directory and the `<NN>-<slug>` naming; the protocol's "Files" states the folder layout (one folder per work order), and the charter cites it. The charter reads the crew vault only to
resolve and name the path in a dispatch; the vault is written by the session form, and its files
are described in `role-skills.md` §4. In the subagent form the orchestrator pins the home itself (the variable, else the machine pointer `<user home>/.devhouse-home`, else the default), asks question (f) when there is neither (writing the pointer on the answer), states the home in one line before its first use, always records the `devhouse home:` line before a dispatch carries the home (a missing line means stop), and, on the human's say, makes `<devhouse home>/crew/`
(the protocol's *The devhouse home* and *The guard*; [ADR 0014](../decisions/0014-setup-in-one-question.md)). It also writes outbound drafts, reader files
and summaries to `<devhouse home>/outbound/<project>/` (or `general`), outside the repo (`role-skills.md` §4);
in a release it also writes its record files under `<devhouse home>/release/<project>/`
(the public tree and the release manager's files are `@remi`'s; `role-skills.md` §4).

## 5. Observability

None. This subsystem emits no runtime operational output: it is a static markdown/JSON
definition consumed by the Claude Code plugin loader, not a running process. It has no log
files, no telemetry, no metrics, and no health surface of its own. Any logging or transcript
capture belongs to the host Claude Code runtime and is out of this repo's scope (see
`overview.md` §5 Cross-cutting concerns, "Logging").

Applicability of the omission sweep's canonical questions:
- *How do I tell whether this is running and healthy?* — **N/A.** There is no process to be
  running; this subsystem is inert text read by the loader at load time.
- *What does failure look like from outside?* — **Answered:** it presents as the plugin
  failing to register, `/devhouse` not activating, or a specialist misrouting. It produces no
  runtime artefact to read; it is diagnosed by the manual verification steps in §10 Tests.

## 6. Dependencies

- **Out → specialist-roster:** the charter dispatches the seven agents and references them by
  handle; it cannot function without the roster existing.
- **Out → host runtime:** relies on the plugin loader to register the slash command and to
  auto-dispatch by `description`.
- **In ← plugin-packaging:** `plugin.json` packages this file so the loader can register it.
- **In ← role-skills:** the manager skill reads this file and adopts it as translated for session
  form (`plugins/devhouse/skills/manager/SKILL.md`); that skill is the canonical statement of the
  single-session / multi-session distinction. This file's first paragraph and first step cite it,
  and the first step hands over to it on "Sessions" or "Sessions in windows".
- **Out → host runtime, first step:** probes for `mcp__ccd_session_mgmt__get_session` (Claude
  Desktop only) and, on "Sessions" or "Sessions in windows", reads the manager skill through `${CLAUDE_PLUGIN_ROOT}`;
  substitution in a command body is measured, and the
  tell-the-user-to-type-`/devhouse:manager` fallback is kept though not needed where the path resolves.
- **In ← user:** invoked by the user running `/devhouse`; driven by user commands ("run the
  loop", "go").
- Does **not** depend on any agent file's contents at authoring time — but see Gotchas re:
  the duplicated roster table.

## 7. Invariants & constraints

- The co-PM is a role, never a dispatchable agent (`README.md`, "The **co-PM** is not an agent").
- Orchestrator edits only meta files (`CLAUDE.md`, `Documentation/dev-prompts/`); never
  plan/source/schema (`devhouse.md`, "Never edit the plan, source, or schema directly"). In the subagent
  form its outbound writes under `<devhouse home>/outbound/`, and in a release its record files
  under `<devhouse home>/release/<project>/` (the public tree and the release manager's files are `@remi`'s), and for research intake its
  writes under `<devhouse home>/intake/<project>/` (`passed.md`, `items/`), the field folders it writes for `@shiro`,
  the fetches it does for `@delia`, the `Intake start point:` line and `<basename>.intake-<k>.orchestrator.md`, are an exception named in the same invariant, and so are,
  for the git tripwire, its writes under `<devhouse home>/tripwire/<project>/` (the salt, `allowed`, `runs/`, `removed/`, the args
  folders), the run file `<basename>.tripwire-<k>.orchestrator.md`, `<basename>.judged-<k>.orchestrator.md`, the script's removals in the shared checkout's `.git`, and the
  `tripwire salt: made` line in `CLAUDE.md`.
- The orchestrator sends, posts and publishes nothing for people other than the team except as the
  protocol's *Authority* allows, and no subagent does (`devhouse.md`, "Outbound text.").
- Handoff is always file-based; never relay a multi-line spec through a pasted code block —
  terminal copy truncates silently (`devhouse.md`, "File-based handoff (no clipboard relay)").
- In the subagent form the orchestrator pins `<devhouse home>` (the protocol's source: the variable, else the
  machine pointer, else the default), records the `devhouse home:` line before any dispatch carries the home, and names the crew path in a
  dispatch only if memory is on (the `crew memory: on` line and the folder, which it makes on the human's say); the subagent reads, never writes (`devhouse.md`, "Crew memory
  (subagent form)").
- Human gate at every step/task boundary; the loop never auto-crosses one (`devhouse.md`, "Human gate between every step."). **Session form:** qualified by the manager skill's *Modes*: in hands-off, which applies between build steps only (the maintenance per-task gate stands), on the human's standing approval, the manager advances once the unit's checkpoint merge is made and merges each unit into the hands-off branch as its checkpoint; merging to main waits for the human, and approving the spec is a stop in both modes. The charter's guardrails and never-edit invariant each carry a pointer to that skill (*Modes*, *Never-edit*); [ADR 0004](../decisions/0004-project-start-and-the-spec-flow.md) records the override.
- Iteration cap = 3 within a step/task; then STOP and surface (`devhouse.md`, "Cap: 3 iterations." and "Iteration cap within a step (3)"). **Session form:** the protocol counts a unit's frozen SHAs and excludes the confirmation re-freeze and the re-freeze after a merge conflict (*Units and branches*, *Freeze*).
- Roxy gates "done"; nothing is complete until her audit is clean (and Shiro's, for
  security-relevant work) or the user waives it (`devhouse.md`, `Roxy gates "done."`).
- Track 0 is a precondition for the maintenance per-task loop; skip only if the dev-house
  built the code or the user waives it (`devhouse.md` § "Maintenance track — existing code" Guardrails, "The per-task loop presupposes **Track 0 is complete**").
- Specialists cannot dispatch each other (`README.md`, "which can't dispatch each other"). True
  in both forms: in the single-session form only the co-PM dispatches; in the session form no
  member dispatches a subagent, the manager only with the human's approval for that step
  (`plugins/devhouse/team/protocol.md`, "Routing").

## 8. Design rationale

- **Advisory as default** (`devhouse.md`, "On activation:" and "Advisory (default).") — autonomy is opt-in to keep the human in
  control; the co-PM is "dormant by default" (`README.md`, "dormant by default"). The design fears runaway
  dispatch more than slowness. **Session form:** the manager runs the autonomous loop and is advisory
  only until the session questions' answers are in (manager skill, *Modes*); the human's "hands-off"
  is an explicit, bounded opt-out of the gate, not a change of default.
- **File-based handoff** (`devhouse.md`, "File-based handoff (no clipboard relay)") — the explicit reason is stated: "terminal copy
  truncates silently." Correctness/auditability over convenience.
- **3-iteration cap** (`devhouse.md`, "Cap: 3 iterations." and "Iteration cap within a step (3)") — "a failing gate stops and asks rather than
  burning budget in a thrash loop." An explicit anti-thrash / cost guardrail.
- **Model tiering** (`devhouse.md`, "Use the cheapest sufficient model per role") — "cheapest sufficient model per role" is a deliberate
  cost stance, not incidental.
- **Track 0 as a project, not a step** (`devhouse.md`, "Track 0 — Onboarding (adopting an existing codebase)") — the charter insists on
  "calibrated depth… do NOT transcribe implementation line-by-line — the code stays the
  source of truth… that layer rots fastest for least value." The whole doc standard is built
  to resist doc-rot.
- **`None` is an assertion, not an omission** (`devhouse.md`, "Every required section present in every doc.") — makes the standard
  "mood-proof": a missing section is a defect; explicit `None` is a decision.
- **The omission sweep and the Observability section exist because a complete, gated doc set
  failed by silence** — every claim was true and the gate still missed a
  load-bearing fact. See
  `Documentation/architecture/decisions/0002-omission-sweep.md`.

## 9. Gotchas

- **Roster duplicated across README and charter.** The roster table appears in both
  README.md and devhouse.md (plus the seven agent files). The agent files are authoritative
  for name/handle/model/tools; the charter table (devhouse.md) is canonical for the Role
  text and the README table mirrors it. The two tables are now reconciled and carry
  sync-marker comments; the policy is recorded in
  `Documentation/architecture/decisions/0001-roster-single-source.md`. Duplication is
  mitigated, not eliminated — there is no automated sync check, so a role/model change must
  be propagated by hand. The agent files number seven; the eight session-form skills
  (`plugins/devhouse/skills/`) and the README's Session-form table also state each member's
  intended model, so a model change must reach them too. The manager's model (Opus) has no
  agent-file frontmatter; her skill is canonical for it.
- **Tessa skip rule is narrow.** Build track says @tessa is skipped "for pure scaffolding"
  (`devhouse.md` § "Build track — greenfield (project build order)" step 4, "skip for pure scaffolding"); the boundary between "scaffolding" and "feature step" is a judgment call
  left to the co-PM and can be gamed to skip tests.
- **Advisory vs. loop transition is user-phrase-driven.** Triggers like "run the loop",
  "go", "keep building" (`devhouse.md`, "Autonomous loop." and § "Autonomous work — two tracks", "pick by context") are informal; there is no strict grammar, so mode
  detection depends on the co-PM's interpretation.

## 10. Tests

No test suite exists — this is a markdown instruction file, not executable code. Verification
is manual and behavioural. Exercised: (1) `/devhouse` activation, stating status from `CLAUDE.md` (or its
absence) and landing in advisory mode without dispatching, as `devhouse.md`, "On activation:" specifies; (2)
dispatch through a file-based work order rather than editing source or plan directly, per the invariant
(`devhouse.md`, "Never edit the plan, source, or schema directly"); (3) the human gate and the 3-iteration cap,
on the maintenance track; (4) the charter's first step ("Sessions or Subagents?": in Claude Desktop the
question, `${CLAUDE_PLUGIN_ROOT}` substituted in the command, *Subagents* giving the orchestrator; in the CLI no
question, subagent form). Its third answer, *Sessions in windows*, and the `member windows:` line are not yet
exercised. The build track's steps have not been run end to end in the subagent form.

Also unexercised: Shiro's threat model after @pris in build step 2
(including a blocking finding going back to @pris) and description-based routing between Roxy and
Shiro. Dispatching `@shiro` and her Done-gate review have been
exercised. The charter's crew-path line, the
outbound-text invariant, the roster introduction's exception for Remi and the `@remi` line's
offer-and-never-auto-dispatch clause are unexercised. So is the subagent form of the release stage: the
subagent-form release paragraph and the meta-files exception's `release/` clause, the notes-base sub-bullet
(its `base-<k>` record, the item-1 check, the first-release confirmation and the ancestor check), the
post-push check of `refs/heads/main`, the precondition set and the hardened build steps, the orchestrator's own
push and private-tag calls with the seal and header they run, and the release by `@remi` (*Who does what*, the
home at entry and the permission mode, her `Write` targets and the dispatch contents). None has a probe of its own.
