# Subsystem: Specialist Roster

## 1. Responsibility

Defines the seven dispatchable specialist subagents the orchestrator uses (the single-session
form; the same seven agent files are also adopted, as translated, by the session-form skills — see
[role-skills](role-skills.md)): their identity,
role scope, model tier, and tool allowlist. Each file is a self-contained persona that the
host runtime registers as an `@handle`-invokable agent and auto-routes to by matching the
task against its `description`. The roster owns *who does the work and what each is allowed
to touch*. What each may touch depends on the form: in the subagent form, exactly what its
`tools:` allowlist grants; in session form, whatever its session's tools allow, with its agent
file's method (and the protocol's "Files" ownership rules) as the only boundary.

## 2. Entry points

Each file is registered as an agent by its `name` frontmatter (the `@handle`). The `tools:` lines
below describe the **subagent form**; in session form a role session holds its session's tools
and only method keeps it to its role (`role-skills.md` §7 Invariants & constraints):

- `plugins/devhouse/agents/pris.md` — `@pris`, planner/architect, opus, tools: Read, Glob,
  Grep, WebSearch, WebFetch.
- `plugins/devhouse/agents/delia.md` — `@delia`, designer, sonnet, tools: Read, Glob, Grep,
  Write, Edit.
- `plugins/devhouse/agents/dahlia.md` — `@dahlia`, developer, sonnet, tools: Read, Glob,
  Grep, Write, Edit, Bash.
- `plugins/devhouse/agents/tessa.md` — `@tessa`, tester, sonnet, tools: Read, Glob, Grep,
  Write, Edit, Bash.
- `plugins/devhouse/agents/roxy.md` — `@roxy`, reviewer, opus, tools: Read, Glob, Grep.
- `plugins/devhouse/agents/shiro.md` — `@shiro`, security reviewer, opus, tools: Read, Glob, Grep,
  Bash (scanners and git; no Write).
- `plugins/devhouse/agents/remi.md` — `@remi`, release manager, sonnet, tools: Read, Glob, Grep,
  Write, Bash (read-only `git ls-tree`, `git show`, `git grep`, `git log` and `git diff` for reads; `Write` for her release files, to the charter's closed target list, and no Edit).

## 3. Key components

- **YAML frontmatter (per file)** — `name` (the handle), `description` (the auto-dispatch
  routing key), `model` (tier), `tools` (capability allowlist). Load-bearing: the
  `description` is what makes "a coding job reaches Dahlia even if her name isn't typed"
  (`devhouse.md` § "The dev house roster", "Auto-dispatch routes by task type"). The one exception is
  Remi: her `description` names her two questions and carries no "use when" trigger, and ends "Invoke
  only when named (@remi)", so she is never auto-routed ([ADR 0012](../decisions/0012-outbound-to-people.md)).
- **Persona body (per file)** — role identity, responsibilities, a working method
  (numbered), and principles, then her **values**: one fixed label line (a mirror of the rule in
  `team/protocol.md`, *Values*, which is canonical) and a numbered list of three to six ranked
  cares, then one sync-marked **crew-memory line** (after a blank line), before the closing paragraph.
  Shapes agent behavior but is not machine-parsed for routing.
  The block is checked by the values check in `role-skills.md` §10 Tests, which also keeps the seven
  label lines identical; rationale in [ADR 0008](../decisions/0008-values.md). The crew-memory line is
  the subagent form's whole share of crew memory: it tells the member to read her `index.md` and
  `mistakes.md` first when her dispatch names a crew path and the files exist, and calls memory a
  record, not an authority. It is byte-identical in the seven files, as the values label is; the rule is
  `team/protocol.md`, *Crew memory*, which is canonical
  ([ADR 0010](../decisions/0010-crew-memory-and-the-break-room.md)).
- **Role boundary clauses** — each persona states what it will NOT do and to whom it
  escalates (in the closing paragraph, the last thing in the file; Roxy has no closing paragraph, so
  hers is her last Principle, followed by her values block and the crew-memory line): Pris "do not write code" (pris.md); Dahlia escalates redesign to Delia and
  replanning to Pris (`dahlia.md`, "escalate those decisions to Delia (design) or Pris (planning)"); Tessa "You do not fix bugs yourself — you write the test that proves the bug exists and hand it to Dahlia (the developer)."
  (tessa.md); Roxy "You critique; you do not fix. Hand the fix to Pris (planner) or Dahlia (developer)."
  (roxy.md); Shiro "You critique; you do not fix. Hand the fix to Dahlia (developer), through the manager."
  and "You write no code." (shiro.md); Remi "For a release or an audit finding, you audit; you do not fix or push. In a release you also draft the notes and changelog entry, build the public tree, and run the filter (protocol *Release*, *The release stage*); no step tags it, since the push makes the public tag. Hand each fix to Pris (planner), through the manager (the orchestrator, in the subagent form)"
  (outbound findings go to the human beside the draft) and "You write no code, and you never send, post or push." followed by "In a release you also write the release files the protocol gives you, with `Write` for text that is not your own (protocol, *Files*), and run git whose writes stay inside the public tree, apart from the seal's scratch folder, only through the exact forms of steps 4–6; your reads of R are read-only. You never run `git remote`, `git replace` or `git push`, and you run `git config` only as the seal's two `--local --list -z` reads and step 5's global `core.sshCommand` read (protocol, *The release stage*, *The release manager's limits*). In the subagent form, outside a release, you write nothing and return your findings to the orchestrator; in a release you are the runner, as in the session form: you write only the file names your dispatch gives you, from the charter's closed `Write` list, your calls are the charter's legitimate calls, and your return holds only what the charter lists (*A release in the subagent form*)." (remi.md); Delia "don't write backend logic" (delia.md).

## 4. Data & state

None. Each agent file is a static definition; agents hold no persistent state between
invocations. Any files they produce at runtime (code, tests, docs) live in the *host
project*, not here, and are owned by that project, not by the roster. The one thing they may read
is the crew vault, `<devhouse home>/crew/<member>/`, when a dispatch names it; the subagent form writes
nothing to it (`team/protocol.md`, *Crew memory*).

## 5. Observability

None. This subsystem emits no runtime operational output: it is a static markdown/JSON
definition consumed by the Claude Code plugin loader, not a running process. It has no log
files, no telemetry, no metrics, and no health surface of its own. Any logging or transcript
capture belongs to the host Claude Code runtime and is out of this repo's scope (see
`overview.md` §5 Cross-cutting concerns, "Logging"). The crew vault the session form writes is
described in `role-skills.md` §5 Observability; the subagent form only reads it.

Applicability of the omission sweep's canonical questions:
- *How do I tell whether this is running and healthy?* — **N/A.** There is no process to be
  running; this subsystem is inert text read by the loader at load time.
- *What does failure look like from outside?* — **Answered:** it presents as the plugin
  failing to register, `/devhouse` not activating, a specialist misrouting, or an agent listed as
  `Agent from devhouse plugin (Tools: All tools)` with no description: its frontmatter did not parse
  (`plugin-packaging.md` §9). It produces no
  runtime artefact to read; it is diagnosed by the manual verification steps in §10 Tests.

## 6. Dependencies

- **In ← orchestrator-charter:** in the single-session form all seven are dispatched exclusively
  by the co-PM (`devhouse.md` § "The dev house roster"). They cannot dispatch each other (`README.md`, "which can't dispatch each other").
- **In ← plugin-packaging:** `plugin.json` packages the `agents/` directory so the loader
  registers them.
- **Out → host runtime:** rely on the runtime to enforce the `tools` allowlist and `model`
  selection.
- **In ← role-skills:** each specialist skill reads its `agents/<name>.md` and adopts it.
- **Out → the crew vault (read-only, optional):** a dispatch that names `<home>/crew/<member>/` (only
  when the project has `crew memory: on` and the folder exists) lets
  the agent read her `index.md` and `mistakes.md`; the orchestrator names the path (the charter,
  *Invariants*), because a read-only subagent cannot resolve `<devhouse home>` itself: the dispatch carries the orchestrator's pin (the protocol's *The devhouse home*, *In the subagent form*).
- **Peer relationships (escalation, not dispatch):** the personas name each other as
  escalation targets (Dahlia→Delia/Pris, Tessa→Dahlia, Roxy→Pris/Dahlia, Shiro→Dahlia, Remi→Pris). This is advisory
  hand-off routed *through the co-PM* (or, in session form, through the manager:
  `plugins/devhouse/team/protocol.md`, "Routing"), not direct agent-to-agent calls.

## 7. Invariants & constraints

- The handle equals the `name` frontmatter; renaming a file's `name` changes the handle and
  breaks every `@handle` reference in the charter/README.
- Read-only roles (in subagent form) must not carry write/exec tools: Pris (`pris.md` frontmatter, `tools:`) and Roxy (`roxy.md` frontmatter, `tools:`) have
  no `Write`/`Edit`/`Bash`. This encodes "Pris is read-only" in subagent form (`devhouse.md`, "Pris is read-only").
  Shiro (`shiro.md`) carries `Bash` for scanners and git but no `Write`/`Edit`: she writes no code. Remi (`remi.md`) carries `Bash` and `Write`, with the charter's closed target list (her audits, manifest and notes drafts), but no `Edit`: every release file is written once, and she writes no code.
- Model tier per role is fixed by the standard: Opus for Pris/Roxy/Shiro, Sonnet for Remi and the three
  executors (`devhouse.md`, "Use the cheapest sufficient model per role").
- The crew-memory line is identical in all seven agent files and follows a blank line after the values
  block, so the values check's block ends where it did (`role-skills.md` §10 Tests).
- Every agent's frontmatter must be strict YAML, and its `tools` must hold no element `*`, never be empty, and use only the characters listed in `plugin-packaging.md` §3, with parentheses neither nested nor unbalanced: otherwise the
  runtime drops every field but the name (on CRLF) or gives the agent every tool (`plugin-packaging.md` §9;
  checked by `tools/check-frontmatter.py`, `plugin-packaging.md` §3).
- Each `description` must remain distinct enough for correct auto-routing (`devhouse.md` § "The dev house roster", "Auto-dispatch routes by task type").

## 8. Design rationale

- **Description-based auto-dispatch** (`devhouse.md` § "The dev house roster", "Auto-dispatch routes by task type") — routing by task type, not just
  literal handle, so the user need not remember who does what; the `description` fields are
  written as routing prompts ("Use when…", "Invoke with @x or when…"), except Remi's, which routes only by name.
- **Tool allowlist encodes the role boundary** — the capability list is the enforcement
  mechanism for "who may change what." Pris/Roxy being denied write tools (subagent form) is *why* they are
  structurally incapable of the thing their personas also forbid in prose — belt and
  suspenders.
- **Model tiering by cognitive load** — planning and adversarial review (Pris, Roxy, Shiro) get
  Opus; mechanical execution (Delia, Dahlia, Tessa) gets Sonnet, and so does Remi, whose audit is a scan of the tree and history — the explicit
  "cheapest sufficient model" stance (`devhouse.md`, "Use the cheapest sufficient model per role").
- **A separate security reviewer.** Roxy asks whether work is right and consistent and Tessa whether
  it behaves; nobody asked whether it is secure, so Shiro asks that and only that, and her
  blocking findings are about security only. The authority choice and its rationale:
  [ADR 0006](../decisions/0006-a-security-reviewer.md).
- **A separate release manager.** Nobody asked whether the work is safe to publish, so Remi asks that
  of what ships (is the data right for its reader), writes no code and never sends, posts or pushes, and her
  audits name class and location, never the value. Rationale:
  [ADR 0011](../decisions/0011-a-release-manager.md).
- **Remi's second question.** Text going out to people gets no member of its own; Remi's role widens
  to cover it. She asks two questions of such text, is the
  data right for its reader and how will it land, and never sends, posts or pushes. Because a task
  match must not send her a draft nobody asked her to check, her `description` has no trigger and she
  is invoked only when named. The reasons are in [ADR 0012](../decisions/0012-outbound-to-people.md).
- **Research intake in the method.** Three builders' methods gain one step: Dahlia's "How you
  work" item 7, Tessa's "How you approach testing" item 6 and a bullet in Delia's principles say that before
  she brings anything in to use she makes an intake, and that in the subagent form she returns the
  `Intake: …` (or `Intake staging: …`) line to the orchestrator and stops, which does the folder work and
  re-dispatches her with the pass (Delia, who has no `Bash`, writes copied code to `snippet.txt` only, in the
  folder the orchestrator names); only the full `Intake: …` line is judged. Shiro's method gains item 8, the
  sanity check: one abrupt answer, her own folder (she runs nothing fetched and writes there only what she
  fetches and her own checks' outputs), and the full report on request. No `tools:` line changes: the checks are made by a script the
  orchestrator or a member runs through the `Bash` she already has, and Delia's fetches are the orchestrator's.
  Rationale and limits: [ADR 0016](../decisions/0016-research-intake.md).
- **Shiro judges the git tripwire's hits.** Her method gains item 9: when the manager (the
  orchestrator, in the subagent form) points her at a git tripwire run file she judges each line by class and id,
  *benign* with a reason or a blocking finding, from the material itself and never by quoting a value; she never
  opens the run folder's `hidden` file, and a `hook.*` line is never released by her. No `tools:` line changes: she
  reads the hook, the config record or the file with the `Bash` she already has; the script is run by the manager,
  the reviewer and the orchestrator. The session skill's method additions go from five to six. The protocol's *The git
  tripwire* is canonical for the rule. Rationale: [ADR 0015](../decisions/0015-the-git-tripwire.md).
- **Test writes in the method.** Four methods gain one step each: Dahlia's "How you work" item 8,
  Tessa's "How you approach testing" item 7 and Shiro's "How you work" item 10 say that a test, scratch or throwaway write
  stays where the protocol's *Where test writes go* (*Tests*) says (the Bash tool, one `mktemp -d` folder per run, `&&`
  chains, `"${X:?}/…"` paths); Roxy's "How you work" item 6 has her check, at a review of a frozen SHA, the tests for a
  literal absolute output path (a should-fix in the visible tests, a note in the hidden set's validity file). Remi's
  method is unchanged: her calls are a closed list. No `tools:` line changes; the habit is checked after the fact, by
  the protocol's *Where writes landed*. The protocol is canonical.
- **Remi's and Shiro's release methods.** In a release Remi also drafts the notes and
  changelog entry, builds the public tree and runs the filter (no step tags it: the push makes the public tag; in both forms, where in the subagent form she is the runner and the orchestrator dispatches her step by step), and her classes gain **process
  traces** (marks of the project's own process or of other real projects in files that would ship). She
  still does not fix or push: the manager makes the push (the orchestrator, in the subagent form), and Shiro's method gains a security pass over
  the whole public tree, with the hidden folder excluded, that starts only after the final checks' first check (no symlink or gitlink) has passed, and with a link check on the folder she works in. Her `description` names process traces. The
  Role text in the charter and README rosters is unchanged, because it already says she writes no code
  and never sends or pushes. The reasons are in [ADR 0013](../decisions/0013-the-release-stage.md).
- **The subagent form reads and never writes memory.** A dispatch is one short run for a task; letting
  it write would put concurrent, unsupervised writers on files the session form edits, and the
  read-only members (Pris and Roxy) have no way to append anyway. Reading is cheap and is
  where the value is ([ADR 0010](../decisions/0010-crew-memory-and-the-break-room.md)).
- **Escalation instead of lateral dispatch** — personas hand decisions back rather than call
  peers, preserving the single-orchestrator control model (`README.md`, "which can't dispatch each other").
- **Dispositions may overlap roles; enforcement differs by direction.** Personas carry habits
  that reach past their own role — Dahlia sweeps for other assertions of a fact she changed and
  reports what she finds (`dahlia.md`, "How you work" item 6, which the intake step 7 follows), and Roxy hunts omissions rather
  than only errors (`roxy.md`, responsibilities). The two directions are **not** enforced the
  same way: in subagent form Roxy's inability to write is tool-enforced (her grant is `Read, Glob, Grep`),
  whereas nothing in Dahlia's grant — a superset of Roxy's — stops her auditing; only prose and
  dispatch do. The split is deliberate: detection is mechanical and starts with whoever made
  the change, while judgement is what the reviewer is for. Roxy's gate is unchanged by it — the
  sweep is redundancy, not a handoff, and catching stale cross-references remains her stated
  responsibility.

## 9. Gotchas

- **Roster duplicated in three places.** The seven agent files are authoritative for
  name/handle/model/tools; the charter table (devhouse.md) is canonical for the Role text and
  the README table (README.md) mirrors it. The two tables are now reconciled and carry
  sync-marker comments; the policy is recorded in
  `Documentation/architecture/decisions/0001-roster-single-source.md`. Duplication is
  mitigated, not eliminated — there is no automated sync check, so a role/model change must be
  propagated by hand. The agent files number seven; the eight session-form skills
  and the README's Session-form table state each member's intended model, so a model change must
  reach them too. The manager's model (Opus) has no agent-file frontmatter; her skill is canonical
  for it.
- **`description` collisions degrade routing.** Because auto-dispatch keys off
  `description`, overlapping descriptions (e.g. Roxy "review… plans" vs. Pris "planning")
  could misroute; the current split (Roxy = critique-only, Pris = create) relies on careful
  wording, not a hard rule. Shiro's `description` is written to stay off Roxy's ground: Shiro is
  for "is this secure?", never consistency, correctness or style. Remi's `description` overlaps
  Shiro's on "secrets", and is written to stay off hers: Remi is for the data in what ships or goes
  out to people, and how it lands, Shiro for "is this secure?", so a secret in the code's logic is
  Shiro's and a secret about to be published is Remi's. It has no routing trigger at all and ends
  "Invoke only when named (@remi)", so a collision cannot misroute to her.
- **The crew path is only as good as the dispatch.** The agent line says "if your dispatch names a
  crew path"; a dispatch that does not name one (a hand-typed `@roxy`, outside the orchestrator) reads
  nothing, and that is correct. Nothing checks that the path the orchestrator wrote resolves.
- **No in-repo enforcement of read-only.** The read-only guarantee for Pris/Roxy (subagent form)
  depends entirely on the host honoring the `tools` list; nothing in this repo enforces it. Shiro
  and Remi are weaker still: their `Bash` can write files, so "writes no code" is their personas'
  habit, not something their `tools:` lines guarantee. Remi's `Write` is bounded by the
  charter's closed target list and, where the session prompts, by the per-call prompts (in a mode that does not prompt,
  nobody checks her calls one by one: the charter's stated limit; the protocol's precondition 10 informs); outside a release her allowlist holds
  `Write` too, and "she writes no file" there (audit-only mode, outbound reviews) is habit. A `tools:` line holds only if the frontmatter
  parses (`plugin-packaging.md` §9). In
  session form it extends by design: a role session holds its session's tools, no tool
  restriction is applied, and method alone keeps a member to its role (in a release, Remi's method
  has her write inside the public tree and the release record, by design).

## 10. Tests

No test suite — these are persona definition files. Their frontmatter is checked by hand with
`tools/check-frontmatter.py` (`plugin-packaging.md` §3); the runtime check, the agent listing in a new
session after a reinstall, is described in `plugin-packaging.md` §10. Verification is manual and behavioural.
Exercised: dispatch by explicit `@handle` of `@pris`, `@dahlia`, `@roxy`, `@shiro` and `@remi` (Pris read-only;
Dahlia writing with Write, Edit and Bash; Shiro and Remi within their allowlists once their frontmatter parsed,
`plugin-packaging.md` §9). Unexercised: dispatch of `@delia` and `@tessa`, and description-based routing without
an explicit `@handle`.

Also unexercised: Shiro's
threat model of a step's design in build step 2, and description-based routing between Roxy and Shiro (that
"is this secure?" reaches Shiro and "is this consistent?" reaches Roxy). The subagent-form offer of `@remi` for
outbound text is unexercised. She has no description-based routing to exercise: she is
invoked only when named. Remi's and Shiro's release methods are unexercised, and so is the subagent release by
`@remi` (her release steps, her `Write` targets and the charter's home at entry and permission mode).

No probe has tested whether a values block changes what a subagent does.
Delia's capitals and emoji reach that form through her agent file, which is harmless. The crew-memory line is
likewise unexercised in the subagent form (one `@roxy` dispatch with the crew path would exercise it).
