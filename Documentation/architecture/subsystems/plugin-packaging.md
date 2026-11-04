# Subsystem: Plugin Packaging

## 1. Responsibility

Declares how devhouse is discovered, installed, and shipped as a Claude Code plugin. It owns
the two manifests that let the plugin loader find the marketplace, resolve the plugin source,
and register its command, agents and skills into a session. It is the distribution layer. It also ships behaviour: its first executable file, the Python script `team/intake-check.py`, which
research intake's members run (§3), alongside the verification script `tools/check-frontmatter.py` and the
shipped script's test, both of which it owns and which are not installed (§3). It ships a second
script, the shell script `team/git-tripwire.sh` (the git tripwire's checks), with its own test.

## 2. Entry points

- `.claude-plugin/marketplace.json` — the marketplace manifest at repo root; lists the
  `devhouse` plugin and points `source` to `./plugins/devhouse`.
- `plugins/devhouse/.claude-plugin/plugin.json` — the plugin manifest; declares `name`,
  `description`, `version`, `author`, `homepage`, `repository` and `license`.
- `LICENSE` and `plugins/devhouse/LICENSE` — the MIT licence, two byte-identical copies: the first for the
  repository, the second so that an installed plugin carries it.
- `plugins/devhouse/team/intake-check.py` — the research-intake checker, called by the team's members as
  `command python -I -S -B '<script>' <mode> … || fail 'intake: <label>'` (eight modes: the default, `--staging`,
  `--check`, `--crate-index`, `--extract`, `--list`, `--names` and `--tree`; `team/protocol.md`, "Research intake",
  *The checker script*). It is reached through `${CLAUDE_PLUGIN_ROOT}/team/`, beside the protocol.
- `plugins/devhouse/team/git-tripwire.sh` — the git tripwire's script, called by the manager, the reviewer and the
  orchestrator as `env -i PATH=… HOME="$HOME" [XDG_CONFIG_HOME=…] /usr/bin/bash --noprofile --norc '<script>' '<args folder>'
  || fail 'git tripwire: call'` (nine modes: `check-unit`, `merge-unit`, `check-checkout`, `merge-handsoff`, `commit`,
  `close`, `salt`, `select` and `remove`; `team/protocol.md`, "Units and branches", *The git tripwire*). Reached the same
  way as the intake checker, from the protocol's folder.
- `tools/check-frontmatter.py` — the frontmatter check, at the repository root, outside `plugins/`; run
  by hand (§3).
- `tools/tests/intake-check/run.py` — the checker script's test, at the repository root, outside `plugins/`;
  run by hand (§3, §7).
- `tools/tests/git-tripwire/run.sh` — the git tripwire's test, at the repository root, outside `plugins/`; run by
  hand (§3, §7).

## 3. Key components

- **marketplace.json** — fields: `name` ("devhouse"), `owner.name` ("Cring-von-Conman"), and a `plugins`
  array with one entry: `name` "devhouse", `source` "./plugins/devhouse", plus a
  `description`, `homepage`, `repository` and `license`. Consumed by `/plugin marketplace add`.
- **plugin.json** — fields: `name`, `description`, `version` (the one place a version is declared),
  `author.name` ("Cring-von-Conman"), `homepage` and `repository` (`https://github.com/Cring-von-Conman/devhouse`) and `license` ("MIT").
  Consumed by `/plugin install devhouse@devhouse`. Neither manifest declares configuration: the one
  optional setting, the environment variable `DEVHOUSE_HOME` (the devhouse home), is read by the
  session form's members, not by any code in the plugin (`team/protocol.md`, "Tests", *The hidden
  set*), and is set by the human in the OS environment (`README.md`, *Advanced*), not by a manifest
  field. Without it the home comes from a machine pointer file, `<user home>/.devhouse-home`, which the
  manager writes on the human's answer, else it is `$HOME/.devhouse`. Crew
  memory is likewise not a manifest setting: it is switched on by the line `crew memory: on` in the
  project's `CLAUDE.md` and the folder `<devhouse home>/crew/`, which the manager makes on the human's yes (`README.md`;
  `team/protocol.md`, "Crew memory").
- **Implicit convention structure** — `commands/`, `agents/` and `skills/` under
  `plugins/devhouse/` are discovered by the loader by directory convention; none is enumerated
  in `plugin.json`. Confirmed by grepping `plugins/devhouse/.claude-plugin/plugin.json` for
  `commands`, `agents` and `skills`: no key or value referencing any of the directories exists
  in the file (its only fields are `name`, `description`, `version`, `author`, `homepage`, `repository`, `license`). Discovery of
  `commands/devhouse.md`, `agents/*.md` and `skills/<role>/SKILL.md` is
  directory-convention-based, not manifest-enumerated. `skills/` is the third convention
  directory.
- **`team/intake-check.py`** — the plugin's first executable file, shipped in `team/` beside the protocol and
  owned here. Python 3.9 or later, standard library only, run with `command python -I -S -B` (`command` skips a shell function of that name, `-I` keeps the
  script's folder and `PYTHON*` variables out, `-S` the interpreter's `.pth` files and `sitecustomize`, `-B`
  writes no bytecode); the binary is `python`, never the WindowsApps `python3` stub. **Line endings:** the root
  `.gitattributes` holds `plugins/devhouse/team/*.py text eol=lf` (and `tools/tests/**/*.py text eol=lf` for
  its test), so the installed copy has LF whatever `core.autocrlf` says; **a CR check** belongs to the build's
  verification and to a fresh checkout (`tr -cd '\r' < <file> | wc -c` prints 0 for the script and the test).
  Its checks, modes, outputs and tests are the protocol's *Research intake*, *The checker script*; the
  rationale and limits are [ADR 0016](../decisions/0016-research-intake.md). Not in the release stage's process set, so it
  **ships** in devhouse's own public release; it holds no project content. **Trust anchor, stated:** it lives
  in the plugin cache, so any same-user process can change it.
- **`tools/tests/intake-check/run.py`** — the script's test, at the repository root, outside `plugins/`, so
  **not installed**; this subsystem owns it. Run from the repository root as
  `python -I -S -B tools/tests/intake-check/run.py [<script path>]` (the default is the working tree's
  script). It makes its own work folder under the system temp folder (refusing to run if it is not under it)
  and removes it. One line per case, `pass` or `FAIL`, and a last line `<n> cases, <n> pass, <m> FAIL`; exit 0
  only if every case passes (a skipped case fails; a control that cannot run on the machine is recorded as a
  passing case that says so); every case also asserts exactly one stdout line, an empty
  stderr and exit 0 or 1. Its coverage self-check fails if a hostile input the reviews named has no case. Its
  real-git cases (a real `git ls-tree -z -l` listing piped through `--names -`, the clone line, the checkout,
  `--tree` and the re-check, with controls for the attribute source, `autocrlf` and hooks, and a repository of a
  few KB that lists half a million paths) need git 2.45.3 or later on the machine that runs it, and make their
  repositories under its own work folder. A finite stream of padded records over 320 MiB is sent through a pipe
  from a generator, so no such file is ever written.
- **`team/git-tripwire.sh`** — the plugin's second executable file and its first shell script, shipped in
  `team/` beside the protocol and owned here. Bash 4 or later under Git Bash (or GNU tools), run as
  `/usr/bin/env -i PATH=/usr/bin:/mingw64/bin HOME="$HOME" [XDG_CONFIG_HOME=…] /usr/bin/bash --noprofile --norc '<script>' '<args folder>'`,
  which keeps an exported shell function, `BASH_ENV`, the profile and the Bash tool's shell snapshot out;
  its dependencies are §6's. **Line endings:** the root `.gitattributes` holds `plugins/devhouse/team/*.sh text eol=lf`
  (and `tools/tests/**/*.sh text eol=lf` for its test), so the installed copy has LF whatever `core.autocrlf` says;
  a CR byte would make bash read `\r` into every command, and the script's own test fails on one. Its checks,
  modes, outputs and limits are the protocol's *The git tripwire*; the script is canonical for the checks. Not in
  the release stage's process set, so it **ships**; it holds no project content. **Trust anchor, stated:** it lives in the plugin
  cache, so any same-user process can change it (the protocol's *Detection, not prevention* watches writes there).
- **`tools/tests/git-tripwire/run.sh`** — the script's test, at the repository root, outside `plugins/`, so
  **not installed**; this subsystem owns it. Run from the repository root as
  `bash tools/tests/git-tripwire/run.sh [<script path>]` (the default is the working tree's script), with a scratch
  `HOME`, `TMPDIR` and `TW_VOLUME2` (a folder on a second volume, for the cases that need one). **It runs the cases in
  parallel:** `TW_JOBS=<n>` workers (default the CPU count, at least 4 and at most 12; `TW_JOBS=1` runs them one after the
  other in one process), each building its own base fixture and working in its own folder, and claiming a case by making
  a folder named for the case's number. The machine is probed once (junctions, hard links, `icacls`, native symlinks, the
  second volume, 8.3 names) and the workers are told the answers; the cases' output is printed in the cases' order
  whatever the split; a worker that dies mid-case leaves that case a `FAIL`; `TW_ONLY=<text>` runs only the cases whose
  name holds the text and `TW_TIMING=<file>` appends each case's seconds. **A `TW_ONLY` run is partial:** it prints
  `partial run (TW_ONLY=<text>): not a full pass` at the start and at the end, and is **never a gate's or a Verify's
  result**, whatever its counts. The driver exits 2 when a worker reports no case count, or none reports any case. It makes one
  `mktemp -d` work folder (refusing to run unless it is under the temp area) and removes it, junctions unlinked first.
  **Output and exit:** the prerequisites, one line per case (`pass`, `FAIL`, or `SKIP <what it lacked>`), then
  `<n> pass, <m> FAIL, <s> SKIP` and the list of what stayed unproven. **Exit 0 means no `FAIL`; a `SKIP` does not fail
  the run, and is never a pass:** the native-symlink variants cannot be made without the Windows symlink privilege, so
  they SKIP (and run, passing, in MSYS shortcut form), and an `icacls`, second-volume or 8.3 case SKIPs when the
  machine lacks it. A prerequisite the whole suite needs (junctions, hard links) exits 2. The skipped cases are listed,
  so the human sees what was not proven. It runs against the working tree's script and again against the installed
  copy after a reinstall. A `git` shim first on `PATH` logs each call, so "no connection made" is "no
  `git -C <checkout>` call before the stop", and marker files show that nothing ran. Its work needs git 2.45.3 or
  later, and takes about 15 to 35 minutes, depending on load, with the default workers on the build machine (about 50 minutes with `TW_JOBS=1`
  for earlier builds, not timed on this one; 183 case lines). A machine starts processes only so fast, and a call of
  the script starts over a hundred: past about 8 workers each case only gets slower, so a faster run needs the script to
  start fewer.
- **`team/`** — `plugins/devhouse/team/protocol.md`, shared by the eight skills, and, beside it,
  `intake-check.py` and `git-tripwire.sh`, whose paths every intake and every tripwire call derives from the
  protocol's (the folder of the resolved protocol path plus `/intake-check.py` or `/git-tripwire.sh`). It is **not** a
  convention directory: the loader does not register it. It is reached from skill bodies through
  `${CLAUDE_PLUGIN_ROOT}`, the plugin's installation directory (for a directory-marketplace
  install the host resolved it to the source folder, `plugins/devhouse`, when measured). The
  charter (`commands/devhouse.md`) also uses it, to reach the manager skill; substitution in a
  command body was measured.
- **`tools/check-frontmatter.py`** — a repository tool at the repository root, outside `plugins/`,
  so it is **not installed**; this subsystem owns it. Run from the repository root, in Git Bash or
  PowerShell (never `cmd.exe`), as `python -I tools/check-frontmatter.py`; with no arguments it globs
  `plugins/devhouse/agents/*.md`, `skills/*/SKILL.md` and `commands/*.md` relative to the current
  folder. It needs Python 3.12 or later (for `os.path.isjunction`) with PyYAML. **Output and exit code:** one line per file, `ok <file> …` or
  `FAIL <file>: <reason>`, then `<n> checked, <m> failed`; exit 0 when nothing failed, 1 when anything
  did, 2 when Python is older than 3.12 or PyYAML cannot be imported. For each file it fails on a path that is or goes through a
  symlink (or a Windows junction); reads the raw bytes and fails on a CR not
  followed by LF; requires the frontmatter delimiters; runs the runtime's own delimiter pattern and
  fails if the runtime would end the block at a `---` earlier than the closing line; loads the block
  as strict YAML that rejects duplicate keys, unhashable keys, anchors, aliases and `<<` merge keys (a
  `FAIL` reason keeps PyYAML's message and drops its snippet of the line); and checks the
  keys by kind (an agent holds exactly `name`, `description`, `model` and `tools`, with `name` the
  file's stem and `model` and `tools` equal to the raw text of their lines, and `tools` holding only
  the characters `A-Z a-z 0-9 _ ( ) , : * . -` and the ASCII space, with parentheses neither nested nor
  unbalanced, and, split on commas and spaces outside parentheses, neither empty nor holding an element
  `*`, which would give the agent every tool; a skill holds `name`
  (its folder), `description` and `disable-model-invocation: true`; the command holds only
  `description`). It also fails on any file under `agents/` that the glob would miss; on any file under `skills/` that
  is not `skills/<folder>/SKILL.md`, any under `commands/` that is not `commands/*.md` (the runtime's
  folder walk recurses) and any symlinked folder there; on `plugins/devhouse/agents` being absent (a run
  from the wrong folder); and on an `agents`, `skills` or `commands` key in `plugin.json`. It refuses
  to pass having checked nothing, and, given arguments, to pass with no agent file among them. Why: §9. It is not in the release stage's process set, so it **ships** in
  devhouse's own public release; it holds no project content.

## 4. Data & state

None persisted by this repo. The manifests are static config read by the host at
install time; they store no runtime state.

## 5. Observability

None. This subsystem emits no runtime operational output: it is a static markdown/JSON
definition consumed by the Claude Code plugin loader, not a running process (apart from
`tools/check-frontmatter.py`, a check run by hand whose output is its stdout and exit code, §3, and the
shipped `team/intake-check.py`, which writes no log either: its only output is **one line** on stdout,
`intake-check: pass`, `intake-check: pass, yanked` or `intake-check: refused`, nothing on stderr, and exit 0 or 1;
the test's output is one line per case and a counts line, §3; and the shipped `team/git-tripwire.sh`,
which writes no log either: its output is lines on stdout, the first `git tripwire: args <mode>`, then hit lines,
`git tripwire: note: …` lines and a final `git tripwire: tip <sha>`, `salt made`, `closed <n>`, `id <id>`,
`removed <class>` or, on a stop, `git tripwire: <label>` from a closed list, with exit 0 or 1 and no value or config
content ever printed; its test prints one line per case, §3). It has no log
files, no telemetry, no metrics, and no health surface of its own. Any logging or transcript
capture belongs to the host Claude Code runtime and is out of this repo's scope (see
`overview.md` §5 Cross-cutting concerns, "Logging").

Applicability of the omission sweep's canonical questions:
- *How do I tell whether this is running and healthy?* — **N/A.** There is no process to be
  running; this subsystem is inert text read by the loader at load time (apart from
  `tools/check-frontmatter.py`, a check run by hand whose output is its stdout and exit code, §3, and
  `team/intake-check.py`, which runs only while a member's intake call does and is healthy when it prints
  `intake-check: pass` and exits 0, and `team/git-tripwire.sh`, which runs only while a merge, commit, wake or
  removal does and is healthy when it prints `git tripwire: args <mode>` and exits 0).
- *What does failure look like from outside?* — **Answered:** it presents as the plugin
  failing to register, `/devhouse` not activating, a specialist misrouting, or an agent listed as
  `Agent from devhouse plugin (Tools: All tools)` with no description: its frontmatter did not parse
  (§9; `tools/check-frontmatter.py` prints a `FAIL` line for the file). It produces no
  runtime artefact to read; it is diagnosed by the manual verification steps in §10 Tests.
  **The intake script's failure** shows in the member's call as `stop: intake: <label>` (the caller's `fail`,
  from a closed list of labels), with the script's own one line, `intake-check: refused`, and no reason, by
  design: a refused field, folder, archive or tree is never described, since the description would carry
  the untrusted text. A missing or too-old `python`, or a script path that did not resolve, shows as the shell's
  `command not found` or a refusal, and the intake is a no. Run the script's test (§3) to tell a bad
  input from a broken script. **The tripwire script's failure** shows as `stop: git tripwire: <label>` (the
  caller's `fail`) or the script's own `git tripwire: <label>` line, with any `note:` line before it that says
  whether a ref moved; `call` means a missing or non-GNU tool, an older git, a wrong environment variable or an
  `XDG_CONFIG_HOME` that is not an absolute `C:/…` path. Run the test (§3) to tell a bad checkout from a broken script.

## 6. Dependencies

- **Out → orchestrator-charter, specialist-roster & role-skills:** packaging exists to ship
  those three subsystems; `source: ./plugins/devhouse` (`marketplace.json`, `"source":`) is the
  directory containing `commands/`, `agents/`, `skills/` and `team/`.
- **Out → host runtime:** entirely dependent on the Claude Code plugin loader's manifest
  schema and discovery rules.
- **Out → Python 3.12 or later with PyYAML** (the check only, §3).
- **Out → Python 3.9 or later, standard library only** (the shipped intake checker and its test, §3). This is
  now an **end-user requirement for research intake**: a machine without a usable `python` can use the
  rest of the plugin, but every intake is a no. Unpacking an archive also needs the patch release of the
  Python line (3.9.24, 3.10.19, 3.11.14, 3.12.12, 3.13.6, or 3.14.0 final and later, a later minor or major line
  only as a final release), and the intake's calls that contact a remote (a clone, `ls-remote`) need git with the
  July 2025 fixes (README, *Bringing things in*). **GNU tools** are needed too (`mv -T`, `sha256sum` and `timeout`:
  Git Bash on Windows). A Python package's vulnerability scan needs `pip-audit` importable by `python -I`.
- **Out → Git Bash (bash 4 or later) and GNU tools, `gawk` and git 2.45.3 or later** (the shipped git tripwire
  script and its test, §3): GNU `sed -z`, `sort -z`, `head -c`, `cp --remove-destination`,
  `mv -n -T`, `ln -T`, `stat -c`, `mktemp -p`, `readlink`, `sha256sum`, `find -printf` and `-links`, `cmp`, `od`, `tr`,
  `cygpath` (Windows only) and `/dev/urandom`, plus `gawk` for arrays of arrays. A missing or non-GNU tool stops
  the call (`call`); Git for Windows ships all of them. The devhouse home must be on a volume that supports hard
  links (NTFS, not exFAT), since the salt is made with `ln -T`.
- **In ← user:** invoked by the install commands in `README.md` § "Install (user-global)".
- No dependency the other direction: the charter and roster do not read these manifests.

## 7. Invariants & constraints

- `marketplace.json` `plugins[].source` must point at the real plugin directory
  (`./plugins/devhouse`); a restructure moved it there.
- The install reference `devhouse@devhouse` (`README.md` § "Install (user-global)", `/plugin install devhouse@devhouse`) is `plugin-name@marketplace-name`;
  both are "devhouse" here, so the marketplace `name` and the plugin `name` must both stay
  "devhouse" or the install string breaks.
- `plugin.json` and `marketplace.json` must be valid JSON — a parse error blocks install.
  Check both with `python -m json.tool`.
- README's `marketplace add` command names the public repository, `Cring-von-Conman/devhouse` (see Gotchas).
- `team/intake-check.py` and `tools/tests/intake-check/run.py` hold no CR byte (the root `.gitattributes` forces
  LF for them), and the test passes on the script's working-tree bytes before a merge and on the installed copy
  after a reinstall (§3).
- `team/git-tripwire.sh` and `tools/tests/git-tripwire/run.sh` hold no CR byte (the root `.gitattributes` forces LF
  for them, §3), `bash -n` passes on both, and the test ends with no `FAIL` on the script's working-tree bytes
  before a merge and on the installed copy after a reinstall (§3). The version is declared in
  `plugin.json` only; no architecture doc or product file names one (the release notes and changelog do).
- Every frontmatter in `agents/`, `skills/` and `commands/` must be strict YAML, and an agent's `tools`
  must name its tools: no element `*`, never empty, only the characters listed in §3, with parentheses neither nested nor unbalanced (§9; checked by `tools/check-frontmatter.py`, §3). A skill
  folder holds only `SKILL.md`, and no skill or command name starts with a dot (§3).

## 8. Design rationale

- **Marketplace-wraps-plugin nesting** (`README.md` § "Layout") — the repo is a *marketplace* that
  contains a plugin, rather than a bare plugin. This is a deliberate restructure: a
  root-as-plugin layout (`source` ".") was not supported by the Claude Code version then installed. The nesting
  lets the marketplace list more plugins later while keeping install semantics stable.
- **Thin manifests** — only the minimum fields are declared; `commands/`, `agents/` and `skills/`
  are discovered by convention, keeping the manifest small and the source layout the source of
  truth.
- **User-global install** (`README.md` § "Install (user-global)" and "dormant by default") — installed once per machine so `/devhouse` is
  available in every project; the orchestrator is dormant until invoked.

## 9. Gotchas

- **The install line names the public repository.** `README.md` § "Install (user-global)" instructs
  `/plugin marketplace add Cring-von-Conman/devhouse`. A fork, or a local clone, must substitute its own
  location (an absolute path to a clone works too).
- **`owner`/`author` are just a handle.** Both manifests list `"name": "Cring-von-Conman"` only — no email.
  `plugin.json` adds `homepage`, `repository` and `license`; the marketplace's plugin entry repeats the three.
- **No version coupling check.** `plugin.json` carries the `version`; `marketplace.json`
  carries no version. Nothing verifies the two manifests agree on plugin identity beyond the
  shared string "devhouse".
- **Directory discovery is unstated.** Neither manifest references `commands/`, `agents/` or
  `skills/`; correct registration relies entirely on host convention. `team/` is not discovered
  at all: a rename of the directory or of `protocol.md` breaks the eight skills silently, because
  they name it by path, and it also breaks the paths to `intake-check.py` and `git-tripwire.sh`, which are
  derived from the protocol's (a script path that does not resolve makes every intake a no, and every tripwire
  call a stop).
- **CRLF in an installed shell script.** The marketplace is a directory
  source on the working tree, and under `core.autocrlf=true` git writes CRLF into a file it updates there. A
  `git-tripwire.sh` with CRLF endings makes bash read a `\r` into every word, so every call fails in a way that
  looks like a missing tool. The root `.gitattributes` forces LF for `team/*.sh` (and for the test), and the
  test fails on a CR byte; **check the installed copy too** (`tr -cd '\r' < <file> | wc -c` prints 0).
- **A home volume without hard links.** The salt is made with `ln -T`, a hard link; on exFAT or
  a share that does not support them the `salt` mode stops (`salt`) and no later call runs. Move the home
  (README, *Setting the devhouse home*) to an NTFS volume.
- **`tripwire` means two things.** The guard's check 3 (the `devhouse home:` line compared
  with the pin) is also called "the tripwire"; *the git tripwire* is the script. The glossary in `overview.md` §9 tells them apart.
- **Ways an agent's frontmatter fields are lost or its allowlist widened.** This is the
  canonical statement; other documents cite it. The first is a frontmatter that is not strict YAML,
  which loads with every field but its name dropped, on CRLF.
  - **Cause.** `remi.md` and `shiro.md` had unquoted `description:` values holding `: `, which is not
    strict YAML. The runtime's frontmatter parser tries a strict parse, then retries after a
    fallback that double-quotes any value holding `: ` (or `{}[]*&#!|>%@` or a backtick). The
    fallback's line pattern does not match `\r`: **on LF it recovers the frontmatter, on CRLF it
    does nothing**, and the agent loads with its name taken from the file name and every other field
    dropped. That means every tool, no model set and no description. `claude plugin validate` uses
    the same parser, so it fails these two files on CRLF and passes them on LF; on these two files it
    agreed with the runtime, and an earlier reading of the failure as a validator quirk was wrong.
  - **How CRLF reaches an install.** The marketplace is a directory source on the working tree, so
    the installed copy carries the working tree's bytes. Under `core.autocrlf=true`, git writes CRLF
    into a file it updates there (a checkout, a merge, a fast-forward), while a file a tool edits in
    place keeps LF. So any agent file is one merge away from CRLF, and **every frontmatter must be
    strict YAML.** Quote a `description:` (or any value) holding `: `, as a single-quoted scalar with
    each `'` doubled.
  - **The window,** by cache evidence (CR bytes in the installed copies under
    `~/.claude/plugins/cache/devhouse/devhouse/<version>/agents/`): for some installed versions Shiro's and Remi's
    copies were CRLF; earlier installs were LF and loaded through the
    fallback. Fixed by quoting both descriptions (the runtime check passed, §10; `ADR 0006` and `ADR 0011`, *Amendment: a parseable agent file*,
    record what ran without its allowlist).
  - **A second way to lose every field: a `---` inside the frontmatter.** The runtime ends the
    frontmatter at the first `---` anywhere, so a value containing `---` cuts the block and the
    keys after it (`model`, `tools`) become body. Neither PyYAML nor `claude plugin validate`
    catches it; `tools/check-frontmatter.py` does (§3).
  - **A third: CR-only line endings** (a lone `\r`, even one stray CR after the opening `---`). The
    runtime's `^---\s*\n` needs a real `\n`, so it finds no frontmatter, while Python's default
    newline handling reads the file as ordinary lines. Git and the usual editors do not produce it;
    the check refuses it.
  - **A fourth: a `*` in `tools`.** The runtime gives an agent every tool when `tools` is missing or
    any element of it is `*` (it splits on commas and on spaces outside parentheses). The check fails
    that, and an empty list, and, stricter than the runtime's splitter so that no difference between the
    two can hide a `*`, any character in `tools` outside `A-Z a-z 0-9 _ ( ) , : * . -` and the ASCII
    space, and nested or unbalanced parentheses.
  - **What to run.** `claude plugin validate plugins/devhouse` on the CRLF tree, which is the
    runtime's strict parse alone, plus `tools/check-frontmatter.py`, whose result does not depend on
    line endings. Neither is the runtime check: the agent listing in a new session after a reinstall is
    (§10).

## 10. Tests

No test suite for the manifests, which are declarative. What exists is run by hand: `tools/check-frontmatter.py`
(§3), the shipped intake checker's test, `python -I -S -B tools/tests/intake-check/run.py` (§3), and the shipped
git tripwire's test, `bash tools/tests/git-tripwire/run.sh` (§3); this subsystem owns all three. After any change
to a manifest, an agent file, a skill, the command or a shipped script, and before a release:

- `claude plugin validate plugins/devhouse` and `claude plugin validate .` both pass (exit 0, "Validation
  passed"). Run them on the CRLF tree, not on an LF copy (§9). The first prints plugin-directory advice about a
  missing icon, which does not change the result; the second prints one warning, that the marketplace has no
  `description`.
- `python -I -B tools/check-frontmatter.py` prints `16 checked, 0 failed`.
- Both manifests parse with `python -m json.tool`, and `cmp LICENSE plugins/devhouse/LICENSE` finds no difference.
- The two shipped scripts and their tests hold no CR byte (`tr -cd '\r' < <file> | wc -c` prints 0), `bash -n`
  passes on the shell script and its test, and each test ends with no `FAIL` on the working-tree bytes, and again
  on the installed copy after a reinstall. The tripwire's test needs a scratch `HOME`, `TMPDIR` and
  `TW_VOLUME2`, each in POSIX form (`/d/…`, not `D:/…`, which breaks its `PATH`), and takes about 15 to 35 minutes.
- The runtime check: after a reinstall, a new session lists every agent with its description and its tools (for
  example `devhouse:remi` with `Tools: Read, Glob, Grep, Write, Bash`). Neither `claude plugin validate` nor the
  frontmatter check is that check (§9).

**Version note.** The version is the one in `plugin.json`; no architecture doc or product file names a plugin
version (the release notes and changelog record theirs), so a release changes it in one place.

Not exercised: a from-scratch install and uninstall cycle through `/plugin marketplace add` and
`/plugin install` (host slash commands, not something a script can invoke), and any team-level behaviour, which
`role-skills.md` §10 Tests and `overview.md` §7 describe.
