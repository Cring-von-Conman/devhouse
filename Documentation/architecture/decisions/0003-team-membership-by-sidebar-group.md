# 0003 — Team membership by sidebar group and role title

**Status:** Accepted. Subsystem: `Documentation/architecture/subsystems/role-skills.md`.

## Decision

Each team member is a skill that a Claude Desktop session loads to become that member. A session finds its
teammates, and a message finds its recipient, through three choices:

- **The team is the sidebar group the session is filed in.** A session joins by being filed in the group and
  running its role skill, and leaves by being archived, moved out of the group or renamed.
- **A member is a session in that group whose title is exactly its role title** (case-sensitive, literal):
  `Makima the DH Manager`, `Pris the DH Planner`, `Delia the DH Designer`, `Dahlia the DH Developer`,
  `Tessa the DH Tester`, `Roxy the DH Reviewer`, and the later members on the same pattern. The role word is the
  skill name, so the title also says which command recreates the session.
- **Every message is addressed to the recipient's `sessionId`, never to its title.** The group is re-read before
  every send and on every message received, so a sender is trusted only if its `sessionId` is the one the fresh
  read shows for that role title.

Also decided:

- **A collision refuses rather than suffixing.** A second session asking for a held role title is refused and
  told how to resolve it. A suffixed title is not one of the literal role titles, so it would be invisible to the
  team, and two holders of one role would make the sender check ambiguous.
- **A team works in one checkout, and messages carry plain absolute paths.** The skills take no argument; there
  is no team name to type.
- **Desktop only.** The first protocol step requires the session-management tools and tells the skill to stop
  without them. A command-line transport is a follow-up, not a claim made here.

## Why the group, and why role titles

- **Why the group.** Users already sort their sessions by project in the sidebar, so the team needs no new
  concept and no argument; the grouping is visible to the user and to every session; the app exposes it through
  its session tools, so discovery needs no scanning of every session; and moving a session out is how a member
  leaves.
- **Why role titles.** A title that says the role is legible to a person looking at the sidebar cold, and it is
  both the key the protocol matches on and the instruction for recreating the session.
- **Why `sessionId` addressing.** The messaging tool accepts bare names only and rejects any address containing
  a space-delimited `@`, and a title is neither unique nor stable. A `sessionId` is both, and it is the `from` of
  any incoming message, so replies and sender checks use the same key.

## History: why not the first design

The first design made the team a name the user typed (`/devhouse:reviewer <team>`), gave each member the title
`<Member> @ <team>`, found teammates by matching peer-session names, and addressed messages by title. It failed
because the messaging tool refuses every address containing ` @ `, in both directions: a name cannot be an
address. Delivery by `sessionId` worked, so the design moved to the sidebar group, role titles and `sessionId`
addressing, and the team argument and its name-matching rules went away.

## Why skills, not enforcement

An earlier attempt at a multi-session team built hooks to make the gates unskippable. It rested on payload
fields that do not exist, showed an idle livelock in the ordinary handoff, and fed hook output to teammates as
instruction. What did work was the substrate: independent sessions can list and message each other. So the
guardrails travel as habits written into the skills, with no tool restriction and no code. This decision makes no
enforcement claim: nothing stops a member using a tool outside its role; method keeps it there.

## Plugin files are referenced, not copied

Skills read `team/protocol.md`, the agent files and the charter through `${CLAUDE_PLUGIN_ROOT}`. The design had a
fallback of embedding synchronised copies in each skill, to be used if those reads failed or were blocked. A
session opened outside the devhouse repository read plugin files with no permission card, so the fallback is not
used and no copy policy exists.

## Consequences

- **Role titles are restated in several places and must change together:** the member table in
  `team/protocol.md`, each `SKILL.md`, the README's session-form table, the overview's glossary example and this
  ADR's list above. There is no automated check.
- **Collision handling relies on an unmeasured timing:** that a title change shows in another session's group
  listing before that session re-checks.
- **The silent case persists.** A message held for its receiver's user's approval, or never acted on, reports
  nothing back; the protocol's answer is to read the peer's artefact, not to rely on replies.
- **Sessions opened with no project folder each get a separate app-made folder,** so a team must be opened in
  the project folder; the protocol warns when a teammate's folder differs, and the warning also fires for
  worktrees.
- **Desktop-only is a real limit.** In the command line the protocol tells the skill to stop at its first step.
