# Changelog

All notable changes to this project are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-04

First public release.

### Added

- A co-PM orchestrator (`/devhouse`) and seven specialist agents: Pris (planner), Delia (designer), Dahlia (developer), Tessa (tester), Roxy (reviewer), Shiro (security reviewer) and Remi (release manager).
- Build, Maintenance and Track 0 (onboarding) workflows, and a fixed documentation standard.
- A session form for Claude Desktop: eight role skills (`/devhouse:manager`, `:planner`, `:designer`, `:developer`, `:tester`, `:reviewer`, `:security-reviewer`, `:release-manager`) that turn separate sessions into a team, with a shared protocol.
- Project start and a numbered, reviewed spec flow.
- Units of work on their own branches and worktrees, with frozen commits, a hidden test set kept outside the repository until the unit passes, and timed check-in audits.
- Security review of marked units, with security start points and recorded waivers.
- A release manager and a release stage: an audit of what would ship, a fresh public tree, a security pass, and a push made once per approval into a single public history.
- A sending rule for outbound text: members draft, and post only internal pull requests and comments on approval, signed as AI-generated.
- Research intake: a security check on anything a member brings in to use, with a shipped checker script (`team/intake-check.py`).
- A git tripwire: a shipped script (`team/git-tripwire.sh`) that finds hooks, filters, links, submodules and risky config before merges and commits.
- A configurable devhouse home, chosen once per machine.
- Optional crew memory and a break room.
- Voices and ranked values for every member.
- A choice at session entry between subagents, sessions, and sessions in their own windows.
- Verification tools: `tools/check-frontmatter.py` and test harnesses for both shipped scripts.

### Known limits

- The session form is heavy; a lighter mode is planned.
- Devhouse defends against accidents, not a hostile team member.
- Projects that use Git LFS or another filter cannot take changes to filtered files through the tripwire.
- Checked on Windows with Git Bash only.

[1.0.0]: https://github.com/Cring-von-Conman/devhouse/tree/v1.0.0
