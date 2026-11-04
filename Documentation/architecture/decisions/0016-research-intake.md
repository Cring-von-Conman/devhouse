# 0016 — Research intake: the security reviewer's sanity check on what a member brings in

**Status:** Accepted. Amends ADR 0013 (the shared git header; see its *Amendment: the shared git header*).
Subsystems: `Documentation/architecture/subsystems/role-skills.md`,
`Documentation/architecture/subsystems/orchestrator-charter.md`,
`Documentation/architecture/subsystems/specialist-roster.md` and
`Documentation/architecture/subsystems/plugin-packaging.md`.

## Decision

A team member researching a problem can bring in something she will then use: a new dependency, a snippet copied
from a doc page, a repository cloned to run, a file downloaded. Nothing looked at those before they were in the
project. A reviewer sees a dependency in a diff, after it was installed; a clone that is run and never committed
is seen by nobody. So what a member brings in *to use* is shown first to Shiro, who answers in one abrupt line.
The rules are in the protocol's *Research intake*; this ADR records why.

- **Scope.** It covers what a member brings in to use. It does not cover pages read for facts, or what the
  manifest and lock file already pin.
- **Before, not at review.** A review sees a dependency only after it is installed and a clone only if it was
  committed. An intake is the check before the material is used; the review's detection (every direct dependency
  added or changed, and every vendored file, since the security start point, needs a `passed.md` line) is the
  backstop for marked units.
- **One line.** The answer is `Intake: pass: <name> <id8>.` or `Intake: no: <name> <id8>.`, with the fewest words
  she judges right. A refusal a member still needs gets a full report on request, and only the human overrules
  the security reviewer: the manager applies a report that clears the material, and one that still says no goes to
  the human.
- **Outside the repository.** The record (`passed.md`), fetched material (`items/`), staging folders and the
  security reviewer's working folder are under `<devhouse home>/intake/<project>/` and `verify/`, so nothing
  fetched is committed by accident and a reinstall does not lose the record. A dependency is declared in the
  manifest and lock file, and copied code goes into the project when it becomes part of it.
- **A shipped checker, not shell written out.** Shell written out for each member had a defect in its quoting and
  in the combination of steps every time it was reviewed. `team/intake-check.py` is the one home of every check
  on an intake field, an index file, an archive and a fetched tree, with a test that runs against its
  working-tree bytes (`tools/tests/intake-check/run.py`). It is the plugin's first executable file, so intake needs
  Python 3 and GNU tools.
- **Fields are untrusted text,** checked only by the script. A field enters a command only as a value the script
  passed in that call, captured into a variable and used as `"$v"`, in one of four shapes (a named option's value
  or an operand after `--`; a path operand under the pinned home or the project's `Documentation/dev-prompts/`; a
  git revision after `--end-of-options`; one side of a comparison), and never in a pattern or a `-m`.
- **The identifier is immutable** (`sha256:`, `pypi:…@sha256:`, `git:` full SHA, `npm:…@sha512-…`,
  `crate:…@<64 hex>`), because a floating range, a branch or a bare tag would let the thing change after the pass.
- **One rule set for a fetched tree: `--names` before the checkout, `--tree` after it.** The archive gate's name,
  repeat, conflict and `HEAD` rules apply to a clone's tree through the same code. `--names -` judges the tree
  from `git ls-tree -r -t -z -l`, piped and never saved, so no file of a refused tree and no listing is ever
  written; `--tree` walks what was written, for the links and hard links a listing cannot show. The listing is
  read with `-l`, not `--format`, because newer git versions C-quote `%(path)` under `--format` even with `-z`.
- **A staging line is a notice, and the full line is judged.** `Intake staging:` goes to the manager alone and
  asks nothing; after the rename the member sends the full `Intake:` line with its `<id>`, and only that line is
  judged, answered, recorded or put to the human.
- **The hidden set** is handled by habit and a stated visible cost: the tester's lines go only to the security
  reviewer and the manager, the material stays beside the set and never inside it, and a hidden test uses only
  dependencies the project already declares.

## Consequences

Stated limits:

- **Enforcement.** It is a habit, not enforcement. Nothing detects a missing intake in an unmarked unit, or a tool
  cloned and run and never committed.
- **What a pass is.** Reading plus metadata, not malware analysis. Transitive dependencies are covered only as
  the lock file pins them. The human's yes is not a security check. `pypi:` checks only the file pip chooses on
  her machine. **The advisory scans are keyed to the public ecosystem named in the query,** whatever `<source>`
  is: with a private index, the OSV query and pip-audit report on the public package of that name. `pip-audit`
  runs the user's interpreter with its `site`, and is judged by its output, never its exit status; a run that
  printed no result is a missing scan, named in her answer.
- **What a passed tool can do.** It runs with the member's full access (the hidden set, the crew vault, the
  release record, credentials), and the transcript audit cannot see a tool's own reads.
- **The interpreter is inside the trust boundary.** It is the first `python` on `PATH`, run as `command python`
  so a shell function is skipped; `PATH` is inside the trust boundary. `-I` keeps the script's folder,
  `PYTHONPATH` and `PYTHONHOME` out, `-S` stops the interpreter's own `.pth` files and `sitecustomize`, and `-B`
  writes no bytecode.
- **What can change after the pass.** `items/` can. The re-check catches accidental change, index-level hiding,
  attribute filters, nested repositories and a committed bare-repository shape, not every writer of the clone's
  `.git`, and only at each use; material that matters gets a fresh clone per use. **Files written into a
  gitlink's empty folder are not seen:** `--ignore-submodules=all` hides them from `status` and `--tree` checks
  names only, so the security reviewer weighs any gitlink. The checkout runs under the empty-tree attribute
  source, with `core.autocrlf=false` and `core.hooksPath=/dev/null`, so neither a system `autocrlf` nor a hook
  from the user's template directory or global config acts inside the tree. The clone line also carries
  `-c core.hooksPath=/dev/null` and `--template=`, because a clone fires hooks of its own and a template's
  `info/attributes` would act at the checkout. A hook defined in git config itself (`hook.<name>.command`) runs
  whatever `core.hooksPath` says, so one in the user's own config still fires at the clone and the checkout (a
  stated limit). The clone call ends with the re-check's index and status lines, because a checkout can exit 0
  with files missing.
- **A refusal at fetch.** `--names` refuses before the checkout and writes no listing and no file of the tree
  (only the clone's `.git`, the fetched pack, is on disk). Failures after it (`--tree`, a checkout failure that
  leaves a partial `repo/`, a `HEAD` mismatch) leave `repo/` on disk. **In every case a member never removes a
  fetched tree or a clone,** because a hostile tree is not for a member to handle; the human deletes it, and the
  README lists the folders. The pass is void (a `voided` line carrying the full `<id>`).
- **Time, and a killed call.** Every intake call passes `timeout: 600000`. A call the tool kills skips its `trap`,
  which leaves the re-check's index folder in the system temp: fail-closed, and the README lists it. **If
  `timeout` itself is killed hard, git is orphaned and runs on** (it spends CPU and writes nothing), a stated
  limit.
- **Forgery.** `passed.md` could be forged by a member despite the audit's flag.
- **Hidden sets.** Hidden-set files are unseen by detection; a dependency a hidden test needs is visible to the
  developer, because it comes in as an ordinary visible intake; nothing detects a hidden test using an
  undeclared dependency; the tester's line names a hidden input to the security reviewer and the manager, and the
  security reviewer reads copied code a hidden test will hold. This is an explicit exception to *The tester's
  messages are visible*, and an ADR limit.
- **Networks.** A DNS name can still resolve to a loopback or private address, and the tools follow https
  redirects to any host, so the IP-literal and `localhost` refusals (by name only) govern what the human sees,
  not where the request goes.
- **Costs.** A project with no lock file, or with unhashed pins, gets a detection finding for every added or
  changed dependency until it pins hashes. SHA-256 git repositories are refused. Crates come only from
  `https://index.crates.io`. Intake needs Python 3 and GNU tools (`mv -T`, `sha256sum`, `timeout`: Git Bash on
  Windows); where only `python3` exists, or the tools are BSD ones, an intake is a no.
- **What a person sees.** Copied code inside a larger file is seen only through the commit message. `<id8>` is 32
  bits and author-chosen (matching also needs `<name>`). Prompt injection aims at her one-line answer.
- **The script itself** lives in the writable plugin cache, so any same-user process can change it, and `--check`
  runs the same file: it guards against changed outputs, not a changed script. Its `digest` is an unkeyed sha256.
- **The archive gate** is `tarfile`'s view. A second xz stream `tarfile` never reads is never decoded. **NUL
  padding between or after xz streams is refused,** because Python's `LZMAFile` takes it for trailing junk and
  silently stops while the `xz` command decodes it all. An xz stream that wants 256 MiB or more is refused, and a
  legacy `.lzma` file is not read. The Python patch floors are the first release on each line with the `tarfile`
  offset fix (3.9.24, 3.10.19, 3.11.14, 3.12.12, 3.13.6, 3.14.0 final).
- **Header bounds.** Header blocks are bounded at 1 MiB each, 16 MiB in all, 4 in a row before a member, with an
  entries charge against 1 Mi entries together; measured for known shapes, not proved as a maximum.
- **The private `tarfile` hooks.** If one is missing the call fails closed, but the spy cases prove the hooks are
  called only on the Python the tests ran on. A future `tarfile` that reads a header block's body before
  `_proc_member` would bypass the bound.
- **The `HEAD` rule's cost.** A regular file called `HEAD` (any case or width) beside an `objects`, `refs` or
  `commondir` is refused, in an archive and in a tree, wider than git needs. A legitimate git-internals fixture is
  refused.
- **A part-filled `dest`, and the swap race.** A refusal during extraction can leave `<dest>` part-filled; the
  human deletes it. A file swapped between the checks and the open needs a concurrent writer and is outside the
  model.
- **`--names` and `--tree`.** Both check names, repeats, conflicts and the `HEAD` rule, with the tree's own caps
  (500,000 entries and 64 Mi characters of names). `--names` runs before the checkout and also caps the summed
  blob sizes at 2 GiB, a blob counted once for every name that holds it, because a tiny repository can name one
  blob thousands of times. The listing is a stream with its own 320 MiB cap, git runs under `timeout 120`, and the
  call's `pipefail` fails on git's own status, so a stream cut short never passes. **The clone's own pack is not
  bounded:** it is real bytes the attacker must serve (a stated limit). Their costs on real clones, all
  fail-closed: a repository above 500,000 entries or 2 GiB of files is refused; format characters such as a
  zero-width non-joiner are refused; two names equal after NFC are refused; a path that is not UTF-8 is refused. A
  refusal repeats on every fresh clone, so it voids the pass and goes back to the security reviewer.
- **What was not tested.** `pip-audit` itself; Python 3.9 to 3.12 and 3.14 (only one 3.13 release was available);
  POSIX (a FIFO and a file symlink in a tree cannot be made on Windows, so those cases have never run);
  `--extract` of 100,000 members (only `--list`); the tree count cap and the 2 GiB cap end to end; and git other
  than the Windows build used.
- **The `safe.bareRepository=explicit` setting** is the shared header's key 3 (ADR 0013, *Amendment: the shared
  git header*). It blocks a committed bare shape for every git call in or under `items/`, including git run by a
  build tool. It cannot protect a tool that is run with its own environment.

**What it adds.** Four members change their method (the developer, the tester and the designer bring things in
through an intake; the security reviewer answers), the manager records and routes, the subagent form's
orchestrator does the folder work for every subagent, and the plugin ships its first executable file and a test
for it. The README says what the human is asked, what intake needs, and which folders the human deletes.
