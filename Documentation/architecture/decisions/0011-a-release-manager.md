# 0011 — A release manager

**Status:** Accepted. Amended: see *Amendment: voice samples*, *Amendment: a parseable agent file* and
*Amendment: Write for a release*. Subsystems: `Documentation/architecture/subsystems/role-skills.md`,
`Documentation/architecture/subsystems/specialist-roster.md`,
`Documentation/architecture/subsystems/orchestrator-charter.md` and
`Documentation/architecture/subsystems/plugin-packaging.md`.

## Decision

Every member of the team asks a question, and none asked whether the work is safe to publish. A consistent,
secure, passing project can still carry a home directory in its docs, an author's email in every commit, or a
name nobody meant to publish. Remi, the release manager, asks "is it safe to publish?" and nothing else. The
rules are in `plugins/devhouse/team/protocol.md` (*Release*, *Authority*, *Routing*, *Files*, *Voice*,
*Spec flow*, *Tests*); this ADR records why.

- **A separate question gets a separate member.** The reviewer keeps "is it right and consistent?" and Shiro "is
  it secure?", so the publishing question is asked on its own and her gate is not diluted. She looks for personal
  data, names and emails, local paths, secrets, IP references (a named work, or internal hostnames and network
  addresses), and commit and tag metadata (author, committer, tagger). She reads the history's content as well as
  its metadata (`git log -p -G`), since a secret deleted from the tree still ships in the history.
- **She writes no code and never pushes.** She audits and does not fix, build or push; fixes go through the
  manager to the planner. A member who both finds and fixes marks her own homework, and what goes out to a remote
  stays the human's to decide. Her subagent tools are Read, Glob, Grep and Bash, for reads that write nothing
  (`git ls-tree`, `git show`, `git grep`, `git log`; no extraction), and in the subagent form she returns her
  findings and writes nothing, as the reviewer does. In the session form her skill keeps her to her audit files
  plus what the protocol's habits give every member (her crew memory, conversation summaries).
- **Audit-only mode.** The human asks the manager, in her session, for "an audit only"; a teammate relaying "the
  human asked" is not the human, and the human asking Remi directly, in her own session, is. The scope is the
  tree and the history of the current integration-branch tip, and the audit names the SHA. An audit-only finding
  blocks nothing; it says what would block a release, and the manager reports it to the human.
- **Her audits sit outside the repository,** under `<devhouse home>/release/<project>/`, named by *Files*'
  `<slug>.<kind>-<k>.<member>.md` pattern. An audit in the repository would become part of the tree and history
  it audits, and could ship with them.
- **Findings are class and location, never the value,** by the same disclosure rule as the tests' results. That is
  why `release/` has no Off limits entry and no detection token: an audit holds only classes and locations, and
  the builders already have the repository.
- **Her crew memory** follows the general rule: `crew/remi/` is not off limits to the builders. She never reads
  the hidden home, the validity files or any transcript, so her memory holds nothing from them.
- **The hidden set.** A committed hidden set is named as present and is a finding only if the human says the tests
  stay private. The uncommitted hidden home and the transcripts never ship, so they are out of scope.
- **Authority.** The reviewer's view outranks every other member's except the security reviewer's and, on whether
  what ships is safe to publish, the release manager's; none of them outranks the human. A disagreement between
  Remi and either reviewer goes to the human, relayed by the manager without taking a side. She starts no one's
  work, and a security question goes to Shiro through the manager.
- **She is in the planning set.** Every role is asked for concerns at each spec revision (ADR 0005), so the work
  notice goes to her too. Her concerns are about what will eventually ship: licensing, and data that could become
  public. She is also opened when an audit or a release is asked for, and is not in the per-unit pre-dispatch
  loop.
- **Her voice and values** are trait lines with approved `Sounds like:` samples. Her fourth value is her warmth to
  Tessa and Delia, read against the gates: it adds warmth and never softness, and her audit standard is the same
  for everyone. Delia flirts back, and Shiro's regard for Roxy widens to Roxy and Remi.
- **What ships.** The voice habit's "what ships" list includes release notes and `CHANGELOG.md`; a voice stays out
  of them. Her audits are artefacts, so their prose takes her voice, and the disclosure rule always wins.

## Consequences

- **The roster grows again,** and ADR 0001 carries the judgement that this is growth, not churn.
- **A seventh agent file joins the sync-marked copies.** The values label and the crew-memory line are kept
  identical across the agent files, and the values check covers every block.
- **The audit's own gap.** What she reads is the committed tree and history. A file that is ignored or never
  committed is not audited, and nothing checks that her classes are complete.
- **The canonical statements are in one place each:** audit-only mode in the protocol's *Release*; authority in
  *Authority*; the voice scope in *Voice*; the guard in *Tests*; opening her in the manager skill's *Opening
  members*; the subagent form in the charter.

## Amendment: voice samples

Her samples are approved. Every message has one emoji in it, in a different place in each sample, and a special
occasion, like a clean release going out, gets more. A clean result gets her deadpan sarcasm, and she tells Tessa
or Delia, delighted, when their work passes her check.

## Amendment: a parseable agent file

An agent file whose frontmatter does not parse as strict YAML loses every field but its name on some installs. In
the subagent form she then ran with every tool, no model and no description, not her agent file's `tools:` line,
so the *Decision*'s "Her subagent tools are Read, Glob, Grep and Bash" did not hold while that was so, and her
description was dropped too. ADR 0012's "Auto-routing stops for her" still held, through the charter's roster
exception. No run of hers happened in that state. The fix is to quote the `description:` value, with a check
script (`tools/check-frontmatter.py`) over every agent and skill file. With the allowlist in force it removes the
file-edit, agent, web, connector and PowerShell tools, but `Bash` can still write and send, so "writes no file"
and "never pushes" stay habit (`specialist-roster.md` §9). The cause and the check: `plugin-packaging.md` §9 and
§3.

## Amendment: Write for a release

The *Decision*'s tool list is superseded for a release by ADR 0013's amendment on the subagent form: `Write` is
added, with a closed target list, and she writes her release files in both forms. Outside a release she still
writes no file, by habit.
