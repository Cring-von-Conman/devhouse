# 0001 — Roster single-source policy

**Status:** Accepted

## Context

The specialist roster (name, handle, model, tools, and a one-line role summary) is
represented in three places: the `plugins/devhouse/agents/*.md` frontmatter blocks, the
charter roster table (`plugins/devhouse/commands/devhouse.md`), and the README roster table
(`README.md`). With no build step to generate the tables, these copies drift. They already
had: the README's Pris row omitted "scope," which the charter's row and Pris's own
frontmatter both include.

The charter cannot be collapsed into a single shared table: it is the instruction set loaded
when `/devhouse` runs and must be self-contained, so it needs its own roster and cannot defer
to the README. The README wants a readable roster for its front-door role. Some duplication
is therefore unavoidable without tooling.

## Decision

- **`agents/*.md` frontmatter is authoritative** for `name` (= `@handle`), `model`, and
  `tools`. These are machine-consumed by the plugin loader; the tables and docs mirror them.
- **The charter roster table is canonical for the human "Role" summary text.**
- **The README roster table is a mirror** and must be kept identical to the charter table.
- Both tables carry an HTML-comment **sync marker** pointing at this ADR and the canonical
  sources, so any editor touching one knows to update the other.
- Architecture docs that restate model/role (e.g. `subsystems/specialist-roster.md`,
  `overview.md` §2 Tech stack) remain governed by the existing "docs stay current" rule; they are
  descriptive mirrors, not additional sources of truth.

## Consequences

- A role/model/handle change must be made in the agent file first, then propagated to both
  tables (and any doc that restates it). The sync markers make the linkage discoverable.
- Drift is mitigated, not eliminated — there is no automated check. If the plugin later gains
  a build/lint step, generating the tables from frontmatter would supersede this policy.
- This is the repo's first ADR; it establishes `Documentation/architecture/decisions/` per
  the documentation standard.
- **Why manual sync rather than codegen:** the roster was intentionally small (five specialists
  at the time of writing) and was not expected to grow, so a code-generation toolchain to keep a five-row
  table in sync would be disproportionate complexity for a zero-dependency markdown plugin. The manual
  sync-marker approach was chosen deliberately with that assumption stated, not by omission. If
  that assumption ever changes (the roster starts churning, or the same single-sourcing is
  wanted for the model-tier mirrors in overview.md §2 Tech stack and specialist-roster.md §2 Entry points), revisit with
  a generator in a superseding ADR.

## Note — the session-form skills

The assumption above ("five specialists, not expected to grow") held when the same specialists
also became session-form role skills (`plugins/devhouse/skills/<role>/SKILL.md`, plus the
manager, Makima): that is a second *form*, not a sixth member, and the roster still had five
rows. The skills cite the agent files and the charter rather than restating the roster, so the
policy for the roster tables is unchanged. The skills do mirror each member's intended model (and
the README's Session-form table carries a Model column), as descriptive mirrors under the same
"docs stay current" rule; the manager's model has no agent-file source, so her skill is canonical
for it. See `Documentation/architecture/subsystems/role-skills.md` and
`Documentation/architecture/decisions/0003-team-membership-by-sidebar-group.md`.

## Note — the roster grows

**This supersedes the previous note's "not a sixth member".** Shiro, the security reviewer
([ADR 0006](0006-a-security-reviewer.md)), joined as a sixth specialist: the charter and README
rosters gained a sixth row, and the session-form skills a seventh. The assumption in the
Consequences ("the roster is intentionally small ... and is not expected to grow") no longer holds
as written.

The Consequences also say to revisit "if ... the roster starts churning". That judgement is
recorded here: the roster grew by one, and by one more was planned (Remi, the release manager).
That is **growth, not churn**. Members are added; none is renamed, re-modelled or removed, and each
addition touches the same fixed set of sites (the agent file, both roster tables, the skills and
the docs that count members). The single-source policy therefore still holds, and the manual sync
markers stay; a generator remains the answer to revisit if rows start to change rather than to
accrue.

## Note — Remi

Remi, the release manager ([ADR 0011](0011-a-release-manager.md)), joined as a seventh
specialist: the charter and README rosters have seven rows, the agent files seven, and the
session-form skills eight. This is the further growth the previous note planned for, and it touches
the same fixed set of sites (her agent file, both roster tables, her skill and the docs that count
members), so the judgement stands: **growth, not churn**, and the manual sync markers stay.
