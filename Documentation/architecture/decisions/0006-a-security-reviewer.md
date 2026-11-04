# 0006 — A security reviewer

**Status:** Accepted. Amended: see *Amendment: a parseable agent file*. Subsystems:
`Documentation/architecture/subsystems/role-skills.md` and `Documentation/architecture/subsystems/specialist-roster.md`.

## Decision

Every member of the team asks a question, and none asked whether the work is secure. The reviewer asks whether it
is right and consistent; the tester asks whether it behaves. A clean, consistent, passing unit can still read a
path from user input unchecked, log a secret or pull in a vulnerable dependency. Shiro, the security reviewer,
asks "is this secure?" and nothing else, and her blocking findings are about security only, so her gate cannot be
diluted into a second consistency review. The rules are in `plugins/devhouse/team/protocol.md`; this ADR records
why.

- **Authority: neither reviewer outranks the other, and the human is the tiebreak.** The reviewer's view
  outranks every other member's except the security reviewer's. The security reviewer's blocking finding is a
  blocker that only the human waives, as the human alone waives a missing security review. When the two
  reviewers disagree, over a finding or over whether a question is a security one at all, it goes to the human,
  and the manager relays both positions and takes no side.
- **The mark.** Every work order carries `**Security-relevant:** yes | no`, set by its writer by stated
  criteria and checked by the reviewer's pre-dispatch review (a wrong *no* is blocking, and so is a missing line
  in a new work order). The audit treats a missing line as grandfathered, not as *yes*. Until the project has a
  security start point the marks gate nothing. Once it has one, and the human declined opening her for a marked
  unit, that unit's merge also needs the human's waiver of the missing review, recorded in the project's
  `CLAUDE.md` under "Security waivers". In hands-off the missing review is a real blocker, so the manager stops
  and asks. Grandfathering is an explicit list, as ADR 0007 records. **Stated limit:** the subagent form has no
  pre-dispatch review, so nothing there catches a wrong *no*.
- **Shiro is deliberately not in the pre-dispatch loop:** she reviews the frozen SHA, where the code exists.
- **In the spec flow** the manager points her at each revision. Each reviewer reviews unbiased first and does not
  open the concerns file or the other's first review until her own is written. Approval needs all four review
  files, none with a blocking finding; if the human declined opening her, approval additionally needs the
  human's waiver. In the subagent form she threat-models what the planner produces and a blocking finding goes
  back to the planner.
- **The confirmation round waits for her.** The hidden set is committed only after the reviewer and, where
  marked, the security reviewer have passed the frozen SHA, so it is never committed while a security fix could
  still follow. The developer's confirmation re-freeze report records `re-freeze of: <F>`, and the confirmation
  review checks that the diff from F touches only the hidden folder, which is what makes her pass of F cover the
  confirmation SHA.
- **Her hidden-set boundary.** She never reads the hidden set (she excludes `hidden/` at every SHA); her files
  carry the results' disclosure rule; her transcript is off limits to the developer and designer and is on the
  manager's detection list as belt and braces.
- **The security start point.** When she first joins a project the manager records "security review from: the
  next spec revision she reviews" in `CLAUDE.md`. Everything earlier is grandfathered, so the audit's new
  conditions do not flag every historical unit on the first wake. The audit gives a two-interval grace before
  flagging a report or spec revision without a security review.

## Consequences

- **The roster and the skills grow.** ADR 0001 carries the judgement that this is growth, not churn.
- **A unit marked security-relevant is slower.** It needs her pass before the confirmation round, and a blocking
  security finding is a new iteration counted toward the cap.
- **A missing scan is stated, not hidden.** Dependency advisory tools need an install and the network; if she
  cannot run one her review says so.
- **Not exercised by design:** the negative paths of the audit's security conditions, a disagreement between the
  two reviewers, and whether a session can invoke `/security-review` on itself.
- **The canonical statements are in one place each:** authority in the protocol's *Authority*; the spec flow in
  *Spec flow*; the mark and the `re-freeze of:` line in *Files*; her unit review, the merge trigger and the
  hand-offs in *Units and branches*; the hidden-set boundary and the confirmation round in *Tests*; the audit
  conditions in *Check-ins*; opening her and the start point in the manager skill's *Opening members*; the
  subagent form in the charter.

## Amendment: a parseable agent file

An agent file whose frontmatter does not parse as strict YAML loses every field but its name on some installs
(line endings decide whether the runtime recovers it). In the subagent form she then ran with every tool, no
model and no description, not her agent file's allowlist (`Read, Glob, Grep, Bash`). While that held, the claims
"you write no code", "no Write" and "no `Write`/`Edit`" in her agent file, the roster doc and the overview held
by habit only. A review of her runs in that state found no use of a tool outside her allowlist beyond read-only
checks.

The fix is to quote the `description:` value, and a check script (`tools/check-frontmatter.py`) now verifies
every agent and skill file. With the allowlist in force it removes the file-edit, agent, web, connector and
PowerShell tools, but `Bash` can still write and send, so "writes no file" stays habit (`specialist-roster.md`
§9). The cause and the check: `plugin-packaging.md` §9 and §3.
