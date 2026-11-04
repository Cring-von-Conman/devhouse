# 0013 — The release stage

**Status:** Accepted. Amended: see *Amendment: the push, and every read of `public/`*, *Amendment: the subagent
form*, *Amendment: the shared git header*, *Amendment: the git tripwire* and *Amendment: a release runs in any permission mode*. Subsystems:
`Documentation/architecture/subsystems/role-skills.md`,
`Documentation/architecture/subsystems/specialist-roster.md`,
`Documentation/architecture/subsystems/orchestrator-charter.md`,
`Documentation/architecture/subsystems/plugin-packaging.md` and `Documentation/architecture/overview.md`.

## Decision

ADR 0011 added the release manager with an audit-only mode and left the release itself undecided: the public and
private split, release notes, tags and the push. ADR 0012 wrote the sending rule, under which no member publishes
anything but an internal pull request or comment, on approval. A release stage has to square the two. The human
asks the manager for a release; the stage runs preconditions, a freeze, a prep unit, an audit, a public tree,
final checks, a manifest and a push. The rules are in `plugins/devhouse/team/protocol.md` (*Release*, *The release
stage*, *Authority*, *Files*, *Tests*, *Voice*), the manager and release-manager skills, `agents/remi.md`,
`agents/shiro.md` and the charter's roster note; this ADR records why.

- **The step order, and why each step sits where it does.** Entry, preconditions, a freeze; a prep unit that
  bumps the version and carries the approved notes; a pin of the release commit R; an audit of R; fixes and a
  publish-time filter; a public tree rebuilt from R and committed as P; a second audit of P; the security
  reviewer's pass; a manifest; the push question and the push; and the private-tag question last.
  - The preconditions (hands-on, the mainline checked out, no unit in flight, a clean checkout, a release
    identity, a remote URL, the release manager present, a free version tag) are checked at entry. A release that
    starts mid-unit, or on the hands-off branch, would audit something that moves.
  - The freeze holds every commit on the mainline except the release's own units and the identity-line commit, so
    that the notes, reviewed against the units merged since the previous release, stay true.
  - The notes are drafted before the freeze and approved by the human at a named version. The developer copies
    that version verbatim into the prep unit's branch, so the notes are in R and the reviewer reviews them at the
    frozen SHA.
  - R is pinned **outside the repository,** in `release/<project>/`: a pin inside the repository would refer to
    itself. R moves only after a fix or filter unit, and each new R is a new pin; a tip check before every build
    and every question stops a release whose mainline moved.
  - R is audited before anything is built, so a finding is fixed in the private repository, where the fix
    belongs, and the public tree is then rebuilt **from scratch every time.**
  - The private tag is asked for after a successful push, so a failed push leaves nothing to undo.
- **Fresh history only, and one public line.** The public repository's history starts fresh. There is one public
  repository per project and one history in it: each release's P is parented on the previous release's P, `main`
  only fast-forwards, and nothing is ever force-pushed. Publishing the private history would bypass the filter.
- **A fixed process set, and a class of process traces.** The public tree always leaves out, in any letter case,
  every `CLAUDE.md` and `CLAUDE.local.md`, every `.claude/` at any depth, and `Documentation/brief/`,
  `Documentation/spec/` and `Documentation/dev-prompts/`. There is no per-release opt-in, and nothing from a real
  project ships, the devhouse project itself included. Because the process files are removed whole, what is left
  to leak is a trace of them in files that do ship, so Remi's audit has a class, **process traces** (work-order
  and spec-revision references, quoted words, records of tests, sessions or conversations, other projects' names
  or paths). Her tree audit excludes the process set, which never ships.
- **The filter's values live outside the repository.** A value that must stay private but not ship is replaced at
  publish time by a script that takes the values file and the tree as arguments. The values file is
  `release/<project>/filter-values.txt`, written by the human or by the release manager on the human's say. The
  filter and its tests live under `release-filter/` and are removed from the public tree, and its tests use
  synthetic values only. No value goes in any artefact or message. The file is the one exception to *Release*'s
  rule that `release/` is not off limits; who may read it is *Release*, *Afterwards*.
- **The release identity.** The public commit carries a release identity from the project's `CLAUDE.md`
  (`release identity: <name> <<email>>`), not the author's own. The commit is made with plumbing (`write-tree`,
  `commit-tree`, `update-ref`) so the tree is exactly what was extracted and filtered. Identity variables are set
  explicitly, dates are UTC so the author's timezone does not ship, signing is switched off, and the message is
  the exact string `Release <version>`. The audit of P checks the outcome.
- **Lightweight tags.** Both tags are lightweight, so no tagger identity can enter one. The public tag is
  `v<version>` on P; the private tag is `v<version>` on R, in the shared checkout, and is never pushed.
- **No step makes a public tag, in either form.** The push by SHA (`<P>:refs/heads/main
  <P>:refs/tags/v<version>`) creates the remote's tag directly. The post-push check, that `refs/heads/main` and
  `refs/tags/v<version>` both point at P, is part of the push call, and the record rests on it, so the next
  release's parent is known. Where this is said: `team/protocol.md`, *The push* for the check and *Tags* for the
  tag.
- **Why the manager pushes.** The push is the one act that publishes the product, so exactly one member does it:
  the manager, who is the member the human talks to and who already asks for every merge and commit. She pushes
  once per approval, after the two checks, by SHA, never with force, and records the outcome. The release manager
  builds the public tree but never pushes, so the member who audited it cannot also publish it. In the subagent
  form the orchestrator takes her place, on the human's approval for that push.
- **How the release push squares with "only draft external comms" (ADR 0012).** The sending rule is about
  comms: text for people. The push publishes the product, not a message, and each push is the human's own
  approval, asked for in the exact words of the push question and tied to a manifest's P. *Authority* names it as
  the one exception, in both places the rule is stated, and says nothing wider: `gh repo create`, `gh release
  create` and any other network publish stay the human's.
- **Where the release notes stand.** They are checked here, with the public as the reader, but stay outside the
  outbound route: the drafts use only the `outbound/` folder and its naming, and the human's approval and the
  reviewer's review are the second reads.
- **Findings block, and only the human waives,** except *Waivers*' never-waivable class. A release finding from
  the release manager or the security reviewer blocks the push. A waiver is the human's answer to a fixed question
  and is recorded with their words. If the security reviewer is declined, the missing pass needs the same waiver,
  and the push question then carries the exact line `Not checked by the security reviewer: declined.` A
  disagreement between either reviewer and the release manager goes to the human, as in ADR 0011.
- **Never waivable:** a committed symlink or gitlink, and a `filter=` attribute. A link can point anywhere on the
  machine, the values file included; a submodule's contents are never in R; a waived LFS filter would ship
  pointers with nothing behind them. The only fix is removing it in the private repository. This narrows the
  human's power to waive deliberately, as least privilege.
- **In the subagent form the orchestrator works out the reviewer's notes base,** because the reviewer has no
  shell there. The private-tag item counts only if it matches the last pin's R; a first release is confirmed by
  the human and a tag-free checkout; an ancestor check runs before any base is used; and the orchestrator passes
  the base to the reviewer inline. **Stated limit:** the party that chooses the base also supplies the only
  evidence for it, so the cross-check shows consistency, not independence; the human's approval of the notes is
  the independent read.

## Amendment: the push, and every read of `public/`

What this amendment closes:

- **The push obeyed `public/.git`:** a local `url.<x>.pushInsteadOf` silently sent the push to another remote; a
  `pre-push` hook ran; `credential.helper = !<cmd>` and `core.sshCommand` would run code with the user's
  credentials; a planted annotated tag rode along with a global `push.followTags`.
- **The audits could see a different commit from the one that shipped:** with `git replace`, every read saw one
  commit while the manifest pinned and the push sent another; a forged commit-graph, an overwritten loose object or
  a patched multi-pack-index did the same to `git archive`, `show` and `log -p`.
- **The extracts obeyed attributes no check saw:** `.git/info/attributes` or the global attributes file with
  `export-ignore` dropped a file from `git archive`, and a local smudge filter ran its command during it.
- **`git init` keeps a planted `.git`,** and `init.templateDir` adds hooks and config.
- **A content line equal to a heredoc's delimiter** ends it early and the next line runs as shell.
- **`set -euo pipefail` does nothing in the Bash tool,** so every "stops" that relied on it did not stop.
- **The remote settings were read from the shared checkout,** which any member can write.
- **The URL check printed a credential** held in a config key's name.

The fixes: the push is never made from `public/`. One Bash call makes a fresh bare repository with `--template=`
(no hooks, no local config beyond `init`'s, no replace refs, no attributes, no alternates), fetches P into it,
checks it by SHA (`index-pack` hashes every object it receives, so the push sends P's true closure or fails),
checks the URL, and pushes `--atomic`. **The seal:** every call that runs git on `public/` first compares its
config with a reference repository made in the same call, checks the top of `.git` against it, requires
`objects/info` to be empty, runs `fsck` for integrity only and checks the refs; the header closes replace refs
and grafts and switches the global and system attributes files off. A failed seal is not a finding and not
waivable; it returns the stage to a rebuild. **`fail`, not `set -e`:** every command whose failure must stop the
call is followed by ` || fail '<label>'`, with a fixed label, so the output names the check that stopped it and
nothing else. **Trust, stated:** the user's global and system git config, shell profile, environment, credential
stores and `~/.ssh/` are trusted as the user's, with the stated limit that members can write several of those
files too. Text that is not the writer's own is written with a file tool, never typed into a shell command;
heredoc delimiters are random per call; the git floor is 2.45.3, the first release with the credential-protocol
fixes.

## Amendment: the subagent form

In a subagent-form release the orchestrator takes the manager's place and `@remi`, dispatched per step, takes the
release manager's: she is the runner (the build, the filter, the masker, her audits, the manifest, the notes
drafts). `@shiro` takes the security reviewer's place. Her `tools:` line is `Read, Glob, Grep, Write, Bash`:
*Files* says text not the writer's own is written with a file tool, so without `Write` she could not write an
audit or the manifest. **Her closed target list** is stated once, in the charter: her audits and stop records,
the manifest, and the notes and changelog drafts under `outbound/<project>/`; only the names the dispatch gives;
never inside the shared checkout or `public/`, never onto an existing file. Outside a release she writes no file,
by habit.

**What the orchestrator no longer trusts from her:** it reads only the file names it gave her, takes the verdict
from the file and not the return, takes P from the latest audit, decides "pass or waived" from its own list of the
files it wrote, and never runs a masker she wrote. **Her legitimate calls** are protocol forms taken exactly as
written, the charter's calls, her method's read forms, or a tool call on a named file or her `Write` targets. No
argument ever holds text from R or P, and `show` takes the SHA of a `blob` entry from her own `ls-tree` form,
never `<sha>:<path>`, since a path from R containing a `'` could otherwise run code (this also fixes the
session form).

## Amendment: the shared git header

*How each step runs*' header exports four config keys; key 3 is `safe.bareRepository=explicit`, and the header
unsets `MSYS_NO_PATHCONV` and `MSYS2_ARG_CONV_EXCL`. **Why.** Research intake (ADR 0016) clones untrusted
repositories, and a working tree can commit a bare-repository shape that git would take for a repository when a
command runs in or under that folder; `explicit` blocks it, in the `-c` and the environment forms, and the
environment form also reaches git run by a build tool. **Why in the header, and as key 3:** the header is the one
place the git settings live, and setting the count and a key again after it would replace key 0 and drop the
others, silently undoing `core.attributesFile` and `core.fsmonitor`. **Why the unsets:** the hooks-path form
`-c core.hooksPath=/dev/null` relies on the Bash tool converting `/dev/null` to `nul`, and with either variable set
git looks for hooks in a folder at the current drive's root. **What it costs the release stage: nothing.** Every
command that names a bare repository names it with `--git-dir`, which `explicit` allows; a `git -C` on a bare
repository fails under the setting, so a new call must use `--git-dir`. Git 2.38 or later is needed for the
setting, and the stage's floor is higher.

## Amendment: the git tripwire

The git tripwire (ADR 0015) watches the shared checkout's `.git`, including a planted `.git/shallow` and a local
config the stage does not neutralise, which *Trust, stated* left as stated limits. It runs at every unit merge and
manager commit, at every check-in wake and before the hands-off merges, **including the release stage's own unit
merges** (prep, fix and filter units) and the hands-off merge, and **not the release stage's own calls,** where the
final scans and the seal stay the backstop. It changes none of the stage's commands, header, seal or push. A
release in which a hit stands cannot merge its prep unit until the hit is released or removed.

## Amendment: a release runs in any permission mode

The subagent form's mode precondition is removed. It had the human confirm that every edit asks, that no "don't
ask again" of any kind was chosen and that no added folder covers any part of the home, held for the whole stage,
and ended the release on a mode change or an added rule. **Why.** It made the human approve every command from
every subagent for the whole release, and one "always allow" on anything ended the release with no waiver. It guarded
mainly against a member quietly changing things mid-release, the hostile-member class ADR 0017 defers until after the first
release. **What stays.** The home at entry (stated by the orchestrator, confirmed by the human, and recorded
before the baseline is printed); the baseline (hashes of the checkout's git config, attributes, hooks and
`.claude/`, printed with a UTC time before any dispatch and compared before each push question, with a list of every
file modified since against the expected set), where a difference goes to the human by name, never its value, and the
human decides whether it matters (a rule added by "always allow" is reported the same way and ends nothing); her
legitimate calls as the definition of a call, refused where the session prompts; and the push in every mode (the
pre-asking call, the question in chat, one push per yes, the post-push check). **The stated limit, said plainly:**
in a mode that does not prompt nobody checks `@remi`'s, `@shiro`'s or `@dahlia`'s calls one by one. A subagent that has read
untrusted R holds `Bash` and `Write`, and what remains is the baseline, the orchestrator's own checks (the pin,
the audit by SHA, the seal, the manifest), the security pass and the push. ADR 0017 lists it among the
hostile-member limits.

## Consequences

- **The roster text is unchanged.** Remi's and Shiro's methods change; the Role text and the charter and README
  rosters stay identical. A release is not a loop track, and the subagent form's share is a subsection beside the
  `@remi` sentence.
- **New artefact kinds.** `pin`, `manifest`, `waiver`, `push` and `base` (subagent form only) join `audit`,
  `outbound` and `validity` as kinds written outside `Documentation/`, beside the audits in `release/<project>/`.
- **The stage writes into the shared checkout only through a unit branch or an act the human approved** (the
  identity-line commit, the mainline checkout and the merge of the hands-off branch into it, the private tag).
  What a release leaves in the private repository is: the prep unit's version bump,
  `Documentation/release/<version>/release-notes.md` and `CHANGELOG.md`; the fix units' commits; the filter
  unit's permanent `release-filter/` folder; the committed `release identity:` line, if it was missing; and the
  private tag, if the human approved it. The pin, the audits, the security pass, the manifest, the waivers, the push
  outcomes, the notes base, the public tree and the values file are under the devhouse home.
- **Not tested end to end:** authentication and the network; `gh`; a retry after a failed push (a new approval and
  a new push call); the filter, unless a test value needs one; the subagent form; a GUI credential prompt;
  whether a `>` redirect follows a link at its target; the declined-security-reviewer line and its waiver.
- **The gaps.** The rules are habits, as everywhere in the session form (ADR 0003): nothing stops a member from
  running `git push` herself. The credentials rule refuses a URL carrying them but proves nothing about
  authentication. The audit is only as good as its classes; a trace that is not in the process set and not in the
  class list ships. Other stated limits: the transcript audit covers only the developer and the designer, so for
  every other member the values file rests on habit; a GUI credential prompt is not stopped by
  `GIT_TERMINAL_PROMPT=0`; a case-variant of a value in a file name is not masked; a project that needs Git LFS
  cannot use the stage.
- **Not decided here:** publishing the private history, session exports, `gh` and any publish other than `git
  push`, and a command-line transport.
- **The canonical statements are in one place each:** the stage in *Release* → *The release stage*; the push
  exception in *Authority*; the files in *Files*; the guard, the off-limits entry and the detection pattern in
  *Tests*; the exact strings in *Voice*; the values-file rule in *Release* → *Afterwards*; the filter's
  requirements, the masker and the check mode in *Fixes and the filter*; the build's guards in *The public tree* →
  *How each step runs*; the escaping of recorded paths in *The audit of R*; *Waivers*, with the never-waivable
  class, in *The final checks*; the push, its URL check and its post-push check in *The push*; the public tag in
  *Tags*; *Who does what* and its bullets, in the charter.
