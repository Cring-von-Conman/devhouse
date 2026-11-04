#!/usr/bin/env bash
# Tests for the git tripwire. Usage: bash run.sh [path to git-tripwire.sh]
# Default script: the working tree's plugins/devhouse/team/git-tripwire.sh. Never installed with the plugin.
#
# Safety: everything is written under one `mktemp -d` folder (printed first), with a scratch HOME. Nothing
# touches ~/.gitconfig, ~/.claude, ~/.ssh, the real repo or any devhouse home. Junctions are made by
# PowerShell New-Item and unlinked before their folder is removed.
#
# Output: the prerequisites, one line per case (pass, FAIL, or SKIP <reason>), then the counts. Exit 0 only with
# no FAIL. A SKIP names what it lacked: a native symlink, a second volume, an 8.3 volume. It is reported, never
# a pass, and the list of what stayed unproven is printed at the end.
#
# Environment: TW_VOLUME2 may name an existing folder on a volume other than the temp folder's. It is used for
# the cases that need another volume, and for the 8.3 short-name case when that volume has 8.3 names. Without
# it those cases SKIP: no other drive is ever scanned or written.
#
# Parallel run: TW_JOBS=<n> runs the cases in n worker processes (default the number of CPUs, at least 4 and at most 12:
# a case spends its time starting processes, which a machine does only so fast, and past about 12 workers each case
# only gets slower); TW_JOBS=1 runs them one after the other in this process. TW_ONLY=<text> runs only the cases whose
# name holds the text. The machine is probed once. Each worker builds its own base fixture and works in its own folder
# under the temp folder (and, for the second volume, under one folder there), and claims a case by making a folder named
# for the case's number, so no two workers touch the same files.
# The cases' output is collected and printed in the cases' order, so a run reads the same however it was split.
# A worker that dies mid-case leaves that case a FAIL. TW_TIMING=<file> appends "<seconds> <case>" per case.
# A TW_ONLY run is partial: it prints "partial run (TW_ONLY=<text>): not a full pass" at the start and at the end, and is
# never a gate's or a Verify's result, whatever its counts.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=${1:-"$here/../../../plugins/devhouse/team/git-tripwire.sh"}
script=$(cd "$(dirname "$script")" && pwd)/$(basename "$script")
[ -f "$script" ] || { echo "no script at $script"; exit 2; }
script_m=$(cygpath -m "$script")
REALGIT=$(command -v git)

SHARD=${TW_SHARD:-} # set only in a worker: its number
JOBS=${TW_JOBS:-}
if [ -z "$SHARD" ]; then
  if [ -z "$JOBS" ]; then JOBS=$(nproc 2>/dev/null) || JOBS=1; [ "$JOBS" -ge 4 ] || JOBS=4; [ "$JOBS" -le 12 ] || JOBS=12; fi
  case $JOBS in '' | *[!0-9]* | 0) echo "TW_JOBS must be a positive number"; exit 2 ;; esac
fi
T=$(mktemp -d) || exit 2
T2=''
[ -n "$SHARD" ] || echo "temp folder: $T (script under test: $script_m)"
[ -n "$SHARD" ] || [ -z "${TW_ONLY:-}" ] || echo "partial run (TW_ONLY=$TW_ONLY): not a full pass"
case $T in /tmp/* | "$TEMP"* | /c/Users/*) ;; *) if [ -z "${TMPDIR:-}" ] || [ "${T#"$TMPDIR"/}" = "$T" ]; then echo "temp folder is not under a temp area"; exit 2; fi ;; esac

# ---------------------------------------------------------------- scratch HOME and the git shim
HOME1=$T/home
HOME2=$T/home2
mkdir -p "$HOME1" "$HOME2" "$T/shim" || exit 2
for h in "$HOME1" "$HOME2"; do
  printf '[user]\n\tname = Test User\n\temail = test@example.invalid\n[core]\n\tautocrlf = false\n[init]\n\tdefaultBranch = main\n' > "$h/.gitconfig"
done
export HOME=$HOME1
# The environment git reads its global setup from is the harness's own to set, case by case: none is inherited.
unset XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_ATTR_NOSYSTEM
cat > "$T/shim/git" <<EOF
#!/usr/bin/bash
{ printf 'GIT_DIR=%s' "\${GIT_DIR-<unset>}"; printf ' [%s]' "\$@"; printf '\n'; } >> "\$SHIMLOG"
if [ -n "\${SHIMVERSION:-}" ] && [ "\${1:-}" = --version ]; then echo "git version \$SHIMVERSION"; exit 0; fi
exec $REALGIT "\$@"
EOF
chmod +x "$T/shim/git"
SHIM=$T/shim
LOGF=$T/shim.log

pass_n=0; fail_n=0; skip_n=0
SKIPS=()
JUNC=()
ACLFIX=()
WPIDS=()
CUR=''; FAILMSG=''; OUT=''; RC=0

cleanup() {
  local p
  cd /
  [ ${#WPIDS[@]} -eq 0 ] || { kill "${WPIDS[@]}" 2>/dev/null; wait "${WPIDS[@]}" 2>/dev/null; }
  for p in "${ACLFIX[@]:-}"; do [ -n "$p" ] && acl_reset "$p"; done
  local i
  for i in 1 2 3; do
    while IFS= read -r -d '' p; do rmjunc "$p"; done < <(find -P "$T" ${T2:+"$T2"} -type l -print0 2>/dev/null)
  done
  # files, then empty folders, deepest first; the links were unlinked above
  for p in "$T" "$T2"; do
    [ -n "$p" ] || continue
    for i in 1 2 3; do
      chmod -R u+w -- "$p" 2>/dev/null
      find -P "$p" -depth -delete 2>/dev/null
      [ -e "$p" ] || break
    done
    if [ -e "$p" ]; then echo "cleanup: LEFT BEHIND (remove it by hand): $p"; else echo "cleanup: removed $p"; fi
  done
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------- helpers
acl_deny() { MSYS_NO_PATHCONV=1 icacls "$(cygpath -w "$1")" /deny "${ME}:($2)" >/dev/null 2>&1; }
acl_reset() { MSYS_NO_PATHCONV=1 icacls "$(cygpath -w "$1")" /reset >/dev/null 2>&1; }
psq() { local s; s=$(cygpath -w "$1"); printf '%s' "${s//\'/\'\'}"; } # a path for a PowerShell single-quoted string: ' is doubled
mkjunc() { # <link path> <target path>, MSYS forms
  powershell.exe -NoProfile -Command "New-Item -ItemType Junction -Path '$(psq "$1")' -Target '$(psq "$2")' | Out-Null" >/dev/null 2>&1
}
rmjunc() {
  powershell.exe -NoProfile -Command "[System.IO.Directory]::Delete('$(psq "$1")', \$false)" >/dev/null 2>&1 || rm -f -- "$1" 2>/dev/null
}
# native symlink: SYMMODE=native tries nativestrict; SYMMODE=lnk makes an MSYS shortcut-form link
mksym() { # <target> <link>
  if [ "$SYMMODE" = native ]; then MSYS=winsymlinks:nativestrict ln -s -- "$1" "$2" 2>/dev/null
  else MSYS=winsymlinks:lnk ln -s -- "$1" "$2" 2>/dev/null; fi
}
native_ok() {
  local d=$T/_nat
  mkdir -p "$d" && : > "$d/t" && MSYS=winsymlinks:nativestrict ln -s -- "$d/t" "$d/l" 2>/dev/null
}

mkdir -p "$T/nohooks" || exit 2
hg() { git -C "$WT" -c "core.hooksPath=$(cygpath -m "$T/nohooks")" "$@"; }
sha_str() { { printf '%s\0' "$(cat "$DH/tripwire/proj.salt")"; printf '%s' "$1"; } | sha256sum | cut -c1-64; }

TR=$T # the root of the case's folders: $T, or $V83 for the 8.3 case
setn() { # <name>: sets N CO WT GD DH TWP
  N=$1
  WT=$TR/$N/proj; CO=$(cygpath -m "$WT"); GD=$WT/.git; DH=$TR/$N/dh; TWP=$DH/tripwire/proj
  TWHOME=$HOME1
}
fx() { # <name>: a copy of the base fixture
  setn "$1"
  rm -rf -- "${TR:?}/$N"
  cp -a "$T/_base" "$TR/$N" || { echo "cannot copy fixture"; exit 2; }
}

# tw <mode> [name=value ...]: makes an args folder, runs the script, sets OUT RC ARGS
# TWENV holds extra NAME=value pairs for the script's environment (a version shim, for one).
TWENV=()
declare -A CYGC=()
cyg() { if [ -z "${CYGC[$1]+x}" ]; then CYGC[$1]=$(cygpath -m "$1"); fi; CYGV=${CYGC[$1]}; } # cygpath -m, once per distinct path
tw() {
  local mode=$1 kv; shift
  ARGS=$(mktemp -d -p "$TWP" args.XXXXXXXXXX) || { echo "mktemp failed"; exit 2; }
  printf '%s\n' "$mode" > "$ARGS/mode"
  for kv in "$@"; do printf '%s\n' "${kv#*=}" > "$ARGS/${kv%%=*}"; done
  # a commit needs a message file; a case that tests the message passes message=..., or NOMSG=1 to write its own
  if [ "$mode" = commit ] && [ ! -e "$ARGS/message" ] && [ -z "${NOMSG:-}" ]; then printf 'harness: a commit\n' > "$ARGS/message"; fi
  [ -n "${PREFN:-}" ] && "$PREFN"
  : > "$LOGF"
  # The protocol's call form, line 1: the call stops, before the header and before the script, when the caller's environment
  # holds a variable that would send plain git to other config or attribute files than the ones the script reads.
  if [ -n "${GIT_CONFIG_GLOBAL+x}${GIT_CONFIG_SYSTEM+x}${GIT_CONFIG_NOSYSTEM+x}${GIT_ATTR_NOSYSTEM+x}" ]; then
    OUT='stop: git tripwire: call'; RC=1; TZ=UTC0 printf -v D '%(%Y%m%d)T' -1; return 0
  fi
  local extra=("${TWENV[@]}") hm lg
  cyg "$TWHOME"; hm=$CYGV; cyg "$LOGF"; lg=$CYGV
  [ -n "${TWTRACE:-}" ] && extra+=(GIT_TRACE="$(cygpath -m "$TWTRACE")")
  # The protocol's call form, line 2: XDG_CONFIG_HOME goes through only when it is set, as `${XDG_CONFIG_HOME+"XDG_CONFIG_HOME=$XDG_CONFIG_HOME"}`.
  OUT=$(env -i PATH="${TWPATH:-$SHIM:/usr/bin:/mingw64/bin}" HOME="$hm" ${XDG_CONFIG_HOME+"XDG_CONFIG_HOME=$XDG_CONFIG_HOME"} SHIMLOG="$lg" "${extra[@]}" /usr/bin/bash --noprofile --norc "$script_m" "$(cygpath -m "$ARGS")" 2>&1)
  RC=$?
  TZ=UTC0 printf -v D '%(%Y%m%d)T' -1 # read again after every call, so a run across UTC midnight names the day the script used
}
hitlines() { printf '%s\n' "$OUT" | grep -E '^(config key|symlink|gitlink|git file|hook framework file|claude file|editor file|short name|worktree config|hard link|hook|info file|legacy remote|shallow|git dir link|worktree link|submodule dir|replace ref) '; }
hitline() { hitlines | grep -E -- "$1"; }
lasthash() { printf '%s\n' "${1##* }"; }
hit_id() { # <class> <hit line> : the escaped id as the line shows it
  local l=${2#"$1 "}
  printf '%s\n' "${l% *}"
}
sel_rm() { # <class> <hit line> : runs select, then remove, by class, the line's escaped id and its hash
  local sid sh
  sid=$(hit_id "$1" "$2"); sh=$(lasthash "$2")
  tw select "checkout=$CO" "class=$1" "id=$sid" "hash=$sh"; SELOUT=$OUT; SELRC=$RC
  tw remove "checkout=$CO" "class=$1" "id=$sid" "hash=$sh"
}
mkrun() { # <run> <expected> <hidden> <released> [hidden-released]
  mkdir -p "$TWP/runs/$1"
  printf '%s' "$2" | sed '/./!d' > "$TWP/runs/$1/expected"
  printf '%s' "$3" | sed '/./!d' > "$TWP/runs/$1/hidden"
  printf '%s' "$4" | sed '/./!d' > "$TWP/runs/$1/released"
  printf '%s' "${5:-}" | sed '/./!d' > "$TWP/runs/$1/hidden-released"
}
rel_unit() { # <run> <S> <P>: the manager's rounds for a unit whose part 3 holds. check-unit (run none) stops at part 3, the lines
  # are released, check-unit then reads parts 1-2, and those lines are released too. Leaves the lines in L and the run in place.
  tw check-unit "S=$2" "P=$3" I=main "checkout=$CO" run=none; L=$(hitlines); mkrun "$1" "$L" '' "$L"
  tw check-unit "S=$2" "P=$3" I=main "checkout=$CO" run="$1"; L=$(hitlines); mkrun "$1" "$L" '' "$L"
}
mktree() { # <base treeish> <spec>... : spec is mode:path:content or del:path; prints the tree sha
  local base=$1 idx s mode rest path content blob; shift
  idx=$(cygpath -m "$TR/$N/idx.tmp"); rm -f "$TR/$N/idx.tmp"
  GIT_INDEX_FILE=$idx hg read-tree "$base" || return 1
  for s in "$@"; do
    case $s in
      del:*) GIT_INDEX_FILE=$idx hg update-index --force-remove -- "${s#del:}" ;;
      *)
        mode=${s%%:*}; rest=${s#*:}; path=${rest%%:*}; content=${rest#*:}
        if [ "$mode" = 160000 ]; then blob=$content; else blob=$(printf '%s' "$content" | hg hash-object -w --stdin); fi
        GIT_INDEX_FILE=$idx hg update-index --add --cacheinfo "$mode,$blob,$path"
        ;;
    esac
  done
  GIT_INDEX_FILE=$idx hg write-tree
  rm -f "$TR/$N/idx.tmp"
}
mkcommit() { # <tree> <unix date> [parent]... : prints the commit sha
  local tree=$1 when=$2 args=() p; shift 2
  for p in "$@"; do args+=(-p "$p"); done
  printf 'c%s\n' "$when" | GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000" hg commit-tree "$tree" "${args[@]}"
}
mkunit() { # <branch> <spec>...: spec is mode:path:content or del:path; prints the sha
  local br=$1 tree c; shift
  tree=$(mktree main "$@") || return 1
  c=$(printf 'unit\n' | hg commit-tree "$tree" -p main)
  hg update-ref "refs/heads/$br" "$c"
  printf '%s' "$c"
}
mkunit_ntfs() { # <branch> <path> <content>: a unit that adds one executable file at a path git refuses on Windows by default (.claude./x); prints the sha
  local br=$1 idx tree c blob
  idx=$(cygpath -m "$TR/$N/idx.tmp"); rm -f "$TR/$N/idx.tmp"
  GIT_INDEX_FILE=$idx hg read-tree main || return 1
  blob=$(printf '%s' "$3" | hg hash-object -w --stdin)
  GIT_INDEX_FILE=$idx hg -c core.protectNTFS=false update-index --add --cacheinfo "100755,$blob,$2" || return 1
  tree=$(GIT_INDEX_FILE=$idx hg write-tree); rm -f "$TR/$N/idx.tmp"
  c=$(printf 'unit\n' | hg commit-tree "$tree" -p main)
  hg update-ref "refs/heads/$br" "$c"
  printf '%s' "$c"
}
tip() { hg rev-parse "refs/heads/$1"; }

# ---------------------------------------------------------------- assertions
chk() { local d=$1; shift; if ! "$@"; then FAILMSG+="[$d] "; fi; }
has() { printf '%s\n' "$OUT" | grep -Eq -- "$1"; }
hasnt() { ! printf '%s\n' "$OUT" | grep -Eq -- "$1"; }
rc_is() { [ "$RC" = "$1" ]; }
stop_is() { [ "$RC" = 1 ] && [ "$(printf '%s\n' "$OUT" | tail -n 1)" = "git tripwire: $1" ]; }
nocall() { ! grep -qF -e "[-C] [$CO]" -e "GIT_DIR=$CO/.git" "$LOGF"; }
nolog() { ! grep -qF -e "$1" "$LOGF"; }
absent_f() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
eq() { [ "$1" = "$2" ]; }
ncount_is() { [ "$(printf '%s\n' "$OUT" | grep -Ec -- "$1")" = "$2" ]; }
nohits() { [ -z "$(hitlines)" ]; }
selhas() { printf '%s\n' "$SELOUT" | grep -Eq -- "$1"; }
selhasnt() { ! printf '%s\n' "$SELOUT" | grep -Eq -- "$1"; }
note_before_label() { printf '%s\n' "$OUT" | tail -n 2 | head -n 1 | grep -q '^git tripwire: note: '; }
ME=${USERNAME:-$(id -un)}

# Every case is `if CASE '<name>'; then ... DONE; fi`. A case has a number, counted in file order by every process; a
# worker runs it only when it wins the claim (a folder named for the number), and sends its output to that number's
# file, which the driver prints in order. Outside a worker (TW_JOBS=1) every case is run and printed as it goes.
CASE_NO=0
claim() { # <name>: 0 when this process runs the case
  CASE_NO=$((CASE_NO + 1))
  if [ -n "${TW_ONLY:-}" ] && [[ $1 != *"$TW_ONLY"* ]]; then return 1; fi
  [ -n "$SHARD" ] || return 0
  mkdir "$TW_CLAIMS/$CASE_NO" 2>/dev/null || return 1
  printf '%s\n' "$1" > "$TW_CLAIMS/$CASE_NO/name"
  exec 7>&1 8>&2 >"$TW_OUTDIR/$CASE_NO.out" 2>&1
}
finish_case() { # <pass|FAIL|SKIP>
  [ -z "${TW_TIMING:-}" ] || printf '%s %s\n' "$(awk -v a="$CT0" -v b="${EPOCHREALTIME/./}" 'BEGIN { printf "%.1f", (b - a) / 1000000 }')" "$CUR" >> "$TW_TIMING"
  [ -n "$SHARD" ] || return 0
  printf '%s\n' "$1" > "$TW_OUTDIR/$CASE_NO.status"
  exec >&7 2>&8 7>&- 8>&-
}
CASE() { claim "$1" || return 1; CUR=$1; CT0=${EPOCHREALTIME/./}; FAILMSG=''; PREFN=''; TWHOME=$HOME1; TWTRACE=''; TWENV=(); TWPATH=''; }
DONE() {
  if [ -z "$FAILMSG" ]; then pass_n=$((pass_n + 1)); echo "pass $CUR"; finish_case pass
  else
    fail_n=$((fail_n + 1)); echo "FAIL $CUR: $FAILMSG"
    printf '%s\n' "$OUT" | head -n 12 | sed 's/^/     | /'
    finish_case FAIL
  fi
}
SKIP() {
  claim "$1: $2" || return 0
  CUR=$1; CT0=${EPOCHREALTIME/./}
  skip_n=$((skip_n + 1)); SKIPS+=("$1: $2"); echo "SKIP $1: $2"
  [ -z "$SHARD" ] || printf '%s\n' "$1: $2" > "$TW_OUTDIR/$CASE_NO.skip"
  finish_case SKIP
}
# stop <label>: a stop with no git call on the checkout
STOPCASE() { chk "stop $1" stop_is "$1"; chk 'no checkout call' nocall; }

# ---------------------------------------------------------------- the base fixture
build_base() {
  setn _base
  mkdir -p "$T/_base/src" "$TWP" || exit 2
  git -C "$T/_base/src" init -q -b main
  ( cd "$T/_base/src" && mkdir -p .claude sub hidden \
    && printf '# project\ntripwire salt: made 2025-01-01\n' > CLAUDE.md \
    && printf 'readme\n' > README && printf '{}\n' > .claude/settings.json && printf '* text\n' > sub/.gitattributes && printf 'h\n' > hidden/a.txt \
    && git add -A && git -c core.hooksPath=/dev/null commit -qm base )
  git clone -q "$T/_base/src" "$T/_base/proj" 2>/dev/null || exit 2
  tw salt "checkout=$CO"
  if [ "$RC" != 0 ]; then echo "base: salt mode failed: $OUT"; exit 2; fi
  tw check-checkout "checkout=$CO" run=none
  if [ "$RC" != 0 ]; then echo "base: check failed: $OUT"; exit 2; fi
  mkrun checkout-0 "$(hitlines)" '' "$(hitlines)"
  tw close "checkout=$CO" run=checkout-0
  if [ "$RC" != 0 ]; then echo "base: close failed: $OUT"; exit 2; fi
  rm -rf -- "$TWP"/args.*
}

# ---------------------------------------------------------------- prerequisites, each checked and reported
# Probed once, by the process that was started (a worker is told the answers). The native-capability probes (a junction,
# a hard link, an icacls deny, a native symlink, the second volume, 8.3 names) each start a program, and are slow.
prereq() { echo "prerequisite $1: $2"; }
if [ -z "$SHARD" ]; then
PRE=$T/_pre; mkdir -p "$PRE/jt" || exit 2

HAVE_JUNC=0
if mkjunc "$PRE/jl" "$PRE/jt" && [ -L "$PRE/jl" ]; then HAVE_JUNC=1; rmjunc "$PRE/jl"; fi
prereq 'junctions (New-Item -ItemType Junction)' "$([ "$HAVE_JUNC" = 1 ] && echo yes || echo 'NO: the suite cannot run')"
[ "$HAVE_JUNC" = 1 ] || exit 2

HAVE_HLINK=0
printf 'h\n' > "$PRE/h1"
if ln "$PRE/h1" "$PRE/h2" 2>/dev/null && [ "$(stat -c %h "$PRE/h1")" = 2 ]; then HAVE_HLINK=1; fi
prereq 'hard links (ln, as mklink /H)' "$([ "$HAVE_HLINK" = 1 ] && echo yes || echo 'NO: the suite cannot run')"
[ "$HAVE_HLINK" = 1 ] || exit 2

HAVE_ACL=0
printf 'a\n' > "$PRE/acl"
ACLFIX+=("$PRE/acl"); acl_deny "$PRE/acl" R
if ! cat "$PRE/acl" >/dev/null 2>&1; then HAVE_ACL=1; fi
acl_reset "$PRE/acl"
prereq 'icacls deny (read)' "$([ "$HAVE_ACL" = 1 ] && echo yes || echo 'no: the two unreadable-file cases will SKIP')"

HAVE_NATIVE=0
native_ok && HAVE_NATIVE=1
prereq 'native symlinks' "$([ "$HAVE_NATIVE" = 1 ] && echo yes || echo 'no: the native-symlink cases will SKIP (the lnk form runs)')"

prereq 'the localhost admin share' 'not needed: the mixed-slash cases only hand the script a string'

# a second volume, for the cross-volume removals and, where it has 8.3 names, the short-name case
vol_of() { stat -c %d "$1" 2>/dev/null; }
if [ -n "${TW_VOLUME2:-}" ]; then
  if [ -d "$TW_VOLUME2" ] && [ "$(vol_of "$TW_VOLUME2")" != "$(vol_of "$T")" ]; then T2=$(mktemp -d -p "$TW_VOLUME2" 2>/dev/null) || T2=''; fi
fi
if [ -n "$T2" ]; then prereq 'a second volume' "yes ($T2)"
elif [ -n "${TW_VOLUME2:-}" ]; then prereq 'a second volume' 'NO: TW_VOLUME2 is not a folder on another volume: the cross-volume cases will SKIP'
else prereq 'a second volume' 'NO: TW_VOLUME2 is not set (no other drive is scanned): the cross-volume cases will SKIP'; fi

has83() { # <folder>: 0 when a folder made there gets a short name
  local p=$1/LongFolderNameForProbe
  mkdir -p -- "$p" || return 1
  case $(basename -- "$(cygpath -d "$p")") in *~*) rmdir -- "$p"; return 0 ;; esac
  rmdir -- "$p"; return 1
}
V83=''
if has83 "$T"; then V83=$T; elif [ -n "$T2" ] && has83 "$T2"; then V83=$T2; fi
if [ -n "$V83" ]; then prereq '8.3 short names' "yes ($V83)"; else prereq '8.3 short names' 'no volume here has them: the landing case will SKIP; the fixture case still runs'; fi
echo
else
  HAVE_JUNC=1; HAVE_HLINK=1; HAVE_ACL=${TW_HAVE_ACL:?}; HAVE_NATIVE=${TW_HAVE_NATIVE:?}
  if [ -n "${TW_T2_ROOT:-}" ]; then T2=$TW_T2_ROOT/w$SHARD; mkdir -p "$T2" || exit 2; fi
  case ${TW_V83:-} in T) V83=$T ;; T2) V83=$T2 ;; *) V83='' ;; esac
fi

# The driver: start the workers, wait, and print the cases' output in the cases' order. The workers are this same file.
run_parallel() {
  local w=$T/_par i n total t fn rc=0 wrc tag='' bad
  local CL=$T/_par/claims OD=$T/_par/out
  mkdir -p "$CL" "$OD" || exit 2
  [ "$V83" != "$T" ] || tag=T
  [ -z "$T2" ] || [ "$V83" != "$T2" ] || tag=T2
  echo "workers: $JOBS (TW_JOBS=1 runs the cases one after the other)"
  for ((i = 1; i <= JOBS; i++)); do
    mkdir -p "$w/tmp$i" || exit 2
    TW_SHARD=$i TW_CLAIMS=$CL TW_OUTDIR=$OD TMPDIR=$w/tmp$i TMP=$w/tmp$i TEMP=$w/tmp$i \
      TW_HAVE_ACL=$HAVE_ACL TW_HAVE_NATIVE=$HAVE_NATIVE TW_T2_ROOT=$T2 TW_V83=$tag \
      bash "$here/$(basename "${BASH_SOURCE[0]}")" "$script" > "$w/worker$i.log" 2>&1 &
    WPIDS+=($!)
  done
  for ((i = 1; i <= JOBS; i++)); do
    wait "${WPIDS[$((i - 1))]}"; wrc=$?
    if [ "$wrc" -gt 1 ]; then
      echo "worker $i exited $wrc; its log:"; sed 's/^/  | /' "$w/worker$i.log" | tail -n 25; rc=2
    fi
  done
  WPIDS=()
  total=0
  for ((i = 1; i <= JOBS; i++)); do
    [ -f "$OD/total.$i" ] || { echo "FAIL harness: worker $i did not report its case count"; rc=2; }
  done
  for fn in "$OD"/total.*; do
    [ -f "$fn" ] || continue
    t=$(cat "$fn")
    if [ "$total" -ne 0 ] && [ "$t" -ne "$total" ]; then echo "FAIL harness: the workers disagree on the number of cases ($total and $t)"; fail_n=$((fail_n + 1)); fi
    [ "$t" -le "$total" ] || total=$t
  done
  [ "$total" -gt 0 ] || { echo "FAIL harness: no worker reported any case"; rc=2; }
  for ((n = 1; n <= total; n++)); do
    if [ -f "$OD/$n.status" ]; then
      cat "$OD/$n.out" 2>/dev/null
      case $(cat "$OD/$n.status") in
        pass) pass_n=$((pass_n + 1)) ;;
        FAIL) fail_n=$((fail_n + 1)) ;;
        SKIP) skip_n=$((skip_n + 1)); SKIPS+=("$(cat "$OD/$n.skip")") ;;
      esac
    elif [ -d "$CL/$n" ] || [ -z "${TW_ONLY:-}" ]; then
      bad=$(cat "$CL/$n/name" 2>/dev/null || echo 'a case no worker claimed')
      echo "FAIL $bad: the worker did not finish this case"
      sed 's/^/     | /' "$OD/$n.out" 2>/dev/null | tail -n 12
      fail_n=$((fail_n + 1))
    fi
  done
  echo
  echo "$pass_n pass, $fail_n FAIL, $skip_n SKIP"
  [ -z "${TW_ONLY:-}" ] || echo "partial run (TW_ONLY=$TW_ONLY): not a full pass"
  if [ "$skip_n" -gt 0 ]; then
    echo "unproven (skipped):"
    printf '  %s\n' "${SKIPS[@]}"
  fi
  [ "$rc" -eq 0 ] || exit "$rc"
  [ "$fail_n" -eq 0 ]
  exit
}
if [ -z "$SHARD" ] && [ "$JOBS" -gt 1 ]; then run_parallel; fi

build_base

# ================================================================ the cases
if CASE 'the script: bash -n passes, no CR byte, LF endings'; then
bash -n "$script" 2>/dev/null; chk 'bash -n' eq "$?" 0
chk 'no CR byte' bash -c "! grep -q \$'\\r' '$script'"
chk 'bash shebang' bash -c "head -n 1 '$script' | grep -q '^#!/usr/bin/bash\$'"
DONE; fi

if CASE 'salt mode: made the salt, runs/ and removed/, once'; then
setn _s; rm -rf "${T:?}/$N"; mkdir -p "$T/$N" && git clone -q "$T/_base/src" "$WT" 2>/dev/null; mkdir -p "$TWP"
tw salt "checkout=$CO"
chk rc rc_is 0; chk made has '^git tripwire: salt made$'
chk salt-file [ -f "$DH/tripwire/proj.salt" ]; chk runs [ -d "$TWP/runs" ]; chk removed [ -d "$TWP/removed" ]
chk 'no work left' bash -c "[ -z \"\$(find '$ARGS' -name 'work.*')\" ]"
tw salt "checkout=$CO"; chk 'second salt stops' stop_is salt
DONE; fi

if CASE 'args: first line is the args line; a mode with a missing or an extra file stops'; then
fx a1
tw check-checkout "checkout=$CO" run=none
chk first-line bash -c "[ \"\$(printf '%s\n' \"$OUT\" | head -n 1)\" = 'git tripwire: args check-checkout' ]"
tw check-checkout "checkout=$CO"; chk missing stop_is args
tw check-checkout "checkout=$CO" run=none S=aaaa; chk extra stop_is args
tw 'nope' "checkout=$CO" run=none; chk 'bad mode' stop_is args
DONE; fi

if CASE 'base: a clean clone has the four remote and branch keys as hits before they are allowed'; then
fx b1; rm -f "$TWP/allowed"
tw check-checkout "checkout=$CO" run=none
chk rc rc_is 0; chk 'four hits' ncount_is '^config key ' 4
chk url has '^config key remote\.<masked>\.url#[0-9a-f]{8}\$ [0-9a-f]{64}$'
DONE; fi

if CASE 'base: clone plus worktree add gives zero hits once the keys are allowed'; then
fx b2; hg worktree add -q "$T/b2/wt-u1" -b work/u1 2>/dev/null
tw check-checkout "checkout=$CO" run=none
chk rc rc_is 0; chk 'no hit lines' nohits; chk 'no worktree hit' hasnt 'worktree'
DONE; fi

if CASE 'hit: a planted hook file'; then
fx h1; printf '#!/bin/sh\ntouch m\n' > "$GD/hooks/pre-commit"
tw check-checkout "checkout=$CO" run=none
chk rc rc_is 0; chk hook has '^hook hooks/pre-commit\$ [0-9a-f]{64}$'
chk 'samples are not hits' hasnt 'hooks/.*\.sample'
DONE; fi

if CASE 'hit: a hook entry that is a folder (hash of "not a file")'; then
fx h2; mkdir "$GD/hooks/sub"
tw check-checkout "checkout=$CO" run=none
chk hit has "^hook hooks/sub\\\$ $(sha_str 'not a file')\$"
DONE; fi

if CASE 'hit: a linked hooks/ is a git dir link in a check, a stop when acting'; then
fx h3; mkdir "$T/h3/elsewhere"; printf 'x\n' > "$T/h3/elsewhere/pre-commit"
mv "$GD/hooks" "$T/h3/hooks.orig"; mkjunc "$GD/hooks" "$T/h3/elsewhere"
tw check-checkout "checkout=$CO" run=none
chk rc rc_is 0; chk hit has '^git dir link hooks\$ [0-9a-f]{64}$'; chk 'no checkout call' nocall; chk 'a partial-output marker is printed' has '^git tripwire: note: partial output, links under .git were listed and nothing else was read$'
S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none
chk acting-stop stop_is links; chk 'no checkout call' nocall; chk 'main unmoved' [ "$(tip main)" = "$P" ]
DONE; fi

if CASE 'hit: a linked worktrees/<id> is a worktree link hit, not a stop'; then
fx h4; hg worktree add -q "$T/h4/wt-u1" -b work/u1 2>/dev/null
mv "$GD/worktrees/wt-u1" "$T/h4/entry.copy"; mkjunc "$GD/worktrees/wt-u1" "$T/h4/entry.copy"
tw check-checkout "checkout=$CO" run=none
chk rc rc_is 0; chk hit has '^worktree link worktrees/wt-u1\$ [0-9a-f]{64}$'
tw check-checkout "checkout=$CO" run=none; chk 'no stop line' hasnt '^git tripwire: (links|folders|worktrees)$'
DONE; fi

if CASE 'hit: a hard-linked .git/config'; then
fx h5; ln "$GD/config" "$T/h5/cfg.link"
tw check-checkout "checkout=$CO" run=none
chk rc rc_is 0; chk hit has '^hard link config\$ [0-9a-f]{64}$'
DONE; fi

if CASE 'hit: a worktrees/<id> whose rev-parse fails'; then
fx h6; hg worktree add -q "$T/h6/wt-u1" -b work/u1 2>/dev/null
rm -f "$GD/worktrees/wt-u1/HEAD"
tw check-checkout "checkout=$CO" run=none
chk rc rc_is 0; chk hit has '^worktree link worktrees/wt-u1\$ [0-9a-f]{64}$'
DONE; fi

if CASE 'hit: a worktree gitdir of //127.0.0.1/x is a hit and no connection is attempted'; then
fx h7; hg worktree add -q "$T/h7/wt-u1" -b work/u1 2>/dev/null
printf '//127.0.0.1/x/.git\n' > "$GD/worktrees/wt-u1/gitdir"
tw check-checkout "checkout=$CO" run=none
chk rc rc_is 0; chk hit has '^worktree link worktrees/wt-u1\$ [0-9a-f]{64}$'; chk 'no 127.0.0.1 in any call' nolog '127.0.0.1'
DONE; fi

if CASE 'hit: a token-bearing url.<base>.insteadOf is masked and no token is printed'; then
fx c1; hg config 'url.https://TOKEN123SECRET@example.invalid/.insteadOf' 'https://example.invalid/'
tw check-checkout "checkout=$CO" run=none
chk hit has '^config key url\.<masked>\.insteadof#[0-9a-f]{8}\$ [0-9a-f]{64}$'; chk 'no token' hasnt 'TOKEN123SECRET'
DONE; fi

if CASE 'hit: a local credential helper, never allowed, still fires after its run closes'; then
fx c2; hg config credential.helper "!touch $T/c2/marker"
tw check-checkout "checkout=$CO" run=none
chk hit has '^config key credential\.helper#[0-9a-f]{8}\$ '
L=$(hitline '^config key credential\.helper'); mkrun checkout-1 "$L" '' "$L"
tw close "checkout=$CO" run=checkout-1; chk closed rc_is 0
tw check-checkout "checkout=$CO" run=none; chk 'fires again' has '^config key credential\.helper#'
chk 'nothing ran' absent_f "$T/c2/marker"
DONE; fi

if CASE 'hit: [credential ""] helper'; then
fx c3; printf '[credential ""]\n\thelper = x\n' >> "$GD/config"
tw check-checkout "checkout=$CO" run=none
chk hit has '^config key credential\.<masked>\.helper#[0-9a-f]{8}\$ '
DONE; fi

if CASE 'hit: http.proxy'; then
fx c4; hg config http.proxy 'http://192.0.2.9:3128'
tw check-checkout "checkout=$CO" run=none
chk hit has '^config key http\.proxy#[0-9a-f]{8}\$ '; chk 'no value' hasnt '192\.0\.2\.9'
DONE; fi

if CASE 'hit: a config.worktree'; then
fx c5; printf '[core]\n\tbare = false\n' > "$GD/config.worktree"
tw check-checkout "checkout=$CO" run=none
chk hit has '^worktree config config\.worktree\$ [0-9a-f]{64}$'
DONE; fi

if CASE 'hit: a removed reference key is hashed absent'; then
fx c6; hg config --unset core.bare
tw check-checkout "checkout=$CO" run=none
chk hit has "^config key core\\.bare#[0-9a-f]{8}\\\$ $(sha_str absent)\$"
DONE; fi

if CASE 'hit: a section named [-f]'; then
fx c7; printf '[-f]\n\tx = 1\n' >> "$GD/config"
tw check-checkout "checkout=$CO" run=none
chk rc rc_is 0; chk hit has '^config key -f\.x#[0-9a-f]{8}\$ '
DONE; fi

if CASE 'hit: a valueless key changed to empty fires again'; then
fx c8; printf '[core]\n\tzzflag\n' >> "$GD/config"
tw check-checkout "checkout=$CO" run=none; L=$(hitline '^config key core\.zzflag'); chk first-hit [ -n "$L" ]
mkrun checkout-1 "$L" '' "$L"; tw close "checkout=$CO" run=checkout-1
tw check-checkout "checkout=$CO" run=none; chk 'allowed' hasnt 'core\.zzflag'
sed -i 's/^\tzzflag$/\tzzflag =/' "$GD/config"
tw check-checkout "checkout=$CO" run=none; chk 'fires again' has 'core\.zzflag'
DONE; fi

if CASE 'hit: diff.ignoreSubmodules=all does not hide a gitlink'; then
fx c9; hg config diff.ignoreSubmodules all
S=$(mkunit work/u1 '160000:sub1:1111111111111111111111111111111111111111'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none
chk 'the config key is a part 3 line, so check-unit holds' has '^git tripwire: note: part 3 holds; parts 1-2 were not read$'
rel_unit u1-1 "$S" "$P"
chk gitlink has '^gitlink sub1\$ [0-9a-f]{64}$'
DONE; fi

if CASE 'hit: a local hook.x.command is a config key hit, never allowed, never released, and runs nowhere'; then
fx c10; hg config hook.x.command "touch $T/c10/marker"; hg config hook.x.event post-merge
S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none
chk hit has '^config key hook\.<masked>\.command#[0-9a-f]{8}\$ '
L=$(hitlines); mkrun u1-1 "$L" '' "$L"
tw close "checkout=$CO" run=u1-1; tw check-checkout "checkout=$CO" run=none; chk 'still fires' has '^config key hook\.<masked>\.command#'
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1
chk 'a released hook line still stops the merge' stop_is expected; chk 'the hit is printed first' has '^config key hook\.<masked>\.command#'
chk 'main unmoved' [ "$(tip main)" = "$P" ]; chk 'the hook ran nowhere' absent_f "$T/c10/marker"
tw check-checkout "checkout=$CO" run=none
for k in command event; do
  L=$(hitline "^config key hook\\.<masked>\\.$k#"); sel_rm 'config key' "$L"
  chk "removed hook.x.$k" has '^git tripwire: removed config key$'
  tw check-checkout "checkout=$CO" run=none
done
chk 'no hook line is left' hasnt '^config key hook\.'
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none; chk 'the merge goes through once they are removed' has '^git tripwire: tip [0-9a-f]{40}$'
chk 'the hook ran nowhere' absent_f "$T/c10/marker"
DONE; fi

if CASE 'unit: a symlink entry, and a gitlink behind an untracked .gitmodules with ignore = all'; then
fx u1
printf '[submodule "s"]\n\tpath = s\n\turl = x\n\tignore = all\n' > "$WT/.gitmodules"
S=$(mkunit work/u1 "120000:link1:target" '160000:s:2222222222222222222222222222222222222222'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none
chk rc rc_is 0; chk symlink has '^symlink link1\$ [0-9a-f]{64}$'; chk gitlink has '^gitlink s\$ [0-9a-f]{64}$'
DONE; fi

if CASE 'unit: git files (renamed, mixed-case) and a .husky file'; then
fx u2
S=$(mkunit work/u1 'del:sub/.gitattributes' '100644:other/.gitattributes:* text' '100644:x/.GitAttributes:* text' '100644:.husky/pre-commit:x'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none
chk deleted has '^git file sub/\.gitattributes\$ '; chk renamed-to has '^git file other/\.gitattributes\$ '
chk mixed has '^git file x/\.GitAttributes\$ '; chk husky has '^hook framework file \.husky/pre-commit\$ '
DONE; fi

if CASE 'unit: .claude/settings.json and its deletion'; then
fx u3
S=$(mkunit work/u1 '100644:.claude/settings.json:{"a":1}' '100644:deep/.claude/x.json:{}'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none
chk changed has '^claude file \.claude/settings\.json\$ '; chk deep has '^claude file deep/\.claude/x\.json\$ '
S2=$(mkunit work/u2 'del:.claude/settings.json')
tw check-unit "S=$S2" "P=$P" I=main "checkout=$CO" run=none
chk deletion has '^claude file \.claude/settings\.json\$ '
DONE; fi

if CASE 'unit: nested CLAUDE.md, CLAUDE.local.md, .envrc, .vscode/tasks.json; the root CLAUDE.md is no hit'; then
fx u4
S=$(mkunit work/u1 '100644:docs/CLAUDE.md:x' '100644:CLAUDE.local.md:x' '100644:.envrc:x' '100644:.vscode/tasks.json:{}' '100644:CLAUDE.md:changed root'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none
chk nested has '^claude file docs/CLAUDE\.md\$ '; chk local has '^claude file CLAUDE\.local\.md\$ '
chk envrc has '^editor file \.envrc\$ '; chk vscode has '^editor file \.vscode/tasks\.json\$ '; chk 'root is no hit' hasnt 'file CLAUDE\.md\$'
S2=$(mkunit work/u2 '100644:CLAUDE.md:only the root changed')
tw check-unit "S=$S2" "P=$P" I=main "checkout=$CO" run=none; chk 'no hit' nohits; chk rc rc_is 0
DONE; fi

if CASE 'refs: a replace ref; info/grafts'; then
fx r1; B=$(hg rev-parse main); O=$(printf 'o\n' | hg commit-tree "$(hg rev-parse 'main^{tree}')"); hg replace "$B" "$O"
printf '%s\n' "$B" > "$GD/info/grafts"
tw check-checkout "checkout=$CO" run=none
chk replace has '^replace ref refs/replace/[0-9a-f]{40}\$ [0-9a-f]{64}$'; chk grafts has '^info file info/grafts\$ '
DONE; fi

if CASE 'hidden: a hidden/ hit passes only from hidden and hidden-released; an expected line is never under hidden/'; then
fx hd
S=$(mkunit work/u1 '100644:hidden/.gitattributes:* text'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; L=$(hitlines); chk hit has '^git file hidden/\.gitattributes\$ '
mkrun u1-1 '' "$L" '' "$L"; tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1
chk merged has '^git tripwire: tip [0-9a-f]{40}$'; chk 'the hit line is printed before the tip' has '^git file hidden/\.gitattributes\$ '
fx hd2; S=$(mkunit work/u1 '100644:hidden/.gitattributes:* text'); P=$(tip main)
mkrun u1-1 '' '' '' "$L"; tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk 'in hidden-released alone' stop_is expected; chk 'hit printed first' has '^git file hidden/'
mkrun u1-1 "$L" '' "$L" ''; tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk 'an expected line under hidden/ stops, though released' stop_is expected
mkrun u1-1 '' "$L" "$L" ''; tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk 'a hidden line found only in released stops' stop_is expected
mkrun u1-1 '' "$L" "$L" "$L"; tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk 'merged with both releases' has '^git tripwire: tip [0-9a-f]{40}$'
fx hd3; S=$(mkunit work/u1 '100644:other/.gitattributes:* text'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; L=$(hitlines); chk 'hit' has '^git file other/\.gitattributes\$ '
mkrun u1-1 '' "$L" '' "$L"; tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk 'a hidden line whose id is not under hidden/ stops' stop_is expected
mkrun u1-1 "$L" '' "$L" ''; tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk 'the same line, in expected and released, merges' has '^git tripwire: tip [0-9a-f]{40}$'
DONE; fi

if CASE 'names: a repointed remote.origin.url fires after it was allowed'; then
fx n1; hg config remote.origin.url 'https://example.invalid/other.git'
tw check-checkout "checkout=$CO" run=none
chk url has '^config key remote\.<masked>\.url#'; chk 'only that one' ncount_is '^config key ' 1
DONE; fi

# ---------------------------------------------------------------- stops, with no checkout call
if CASE 'stop: a .git gitfile'; then
fx s1; rm -rf "$GD"; printf 'gitdir: ../elsewhere\n' > "$WT/.git"
tw check-checkout "checkout=$CO" run=none; STOPCASE folders
DONE; fi

if CASE 'stop: a junctioned .git'; then
fx s2; mv "$GD" "$T/s2/realgit"; mkjunc "$GD" "$T/s2/realgit"
tw check-checkout "checkout=$CO" run=none; STOPCASE links
DONE; fi

for SYMMODE in native lnk; do
  if [ "$SYMMODE" = native ] && ! native_ok; then
    for nm in 'stop: a symlinked .git/config' 'stop: a dangling symlinked commondir' 'stop: a symlinked HEAD' 'remove: a symlinked HEAD is a stop, never a removal' 'stop: an args file that is a link'; do SKIP "$nm (native symlink)" 'prerequisite missing: native symlinks (no privilege to make one); unproven for them'; done
    continue
  fi
  if CASE "stop: a symlinked .git/config ($SYMMODE)"; then
  fx "s3$SYMMODE"; mv "$GD/config" "$T/s3$SYMMODE/cfg.real"; mksym "$T/s3$SYMMODE/cfg.real" "$GD/config"
  tw check-checkout "checkout=$CO" run=none; STOPCASE links
  DONE; fi
  if CASE "stop: a dangling symlinked commondir ($SYMMODE)"; then
  fx "s4$SYMMODE"; mksym "$T/s4$SYMMODE/nowhere" "$GD/commondir"
  tw check-checkout "checkout=$CO" run=none; STOPCASE links
  DONE; fi
  if CASE "stop: a symlinked HEAD ($SYMMODE)"; then
  fx "s5$SYMMODE"; mv "$GD/HEAD" "$T/s5$SYMMODE/head.real"; mksym "$T/s5$SYMMODE/head.real" "$GD/HEAD"
  tw check-checkout "checkout=$CO" run=none; STOPCASE links
  DONE; fi
  if CASE "remove: a symlinked HEAD is a stop, never a removal ($SYMMODE)"; then
  fx "s5r$SYMMODE"; mv "$GD/HEAD" "$T/s5r$SYMMODE/head.real"; mksym "$T/s5r$SYMMODE/head.real" "$GD/HEAD"
  tw remove "checkout=$CO" "class=git dir link" 'id=HEAD$' "hash=$(printf '%064d' 1)"; chk stop stop_is links; chk 'the link is still there' [ -L "$GD/HEAD" ]
  DONE; fi
  if CASE "stop: an args file that is a link ($SYMMODE)"; then
  fx "s6$SYMMODE"; export SYMMODE
  linkrun() { rm -f "$ARGS/run"; printf 'none\n' > "$T/$N/run.real"; mksym "$T/$N/run.real" "$ARGS/run"; }
  PREFN=linkrun; tw check-checkout "checkout=$CO" run=none; PREFN=''
  chk stop stop_is args; chk 'no checkout call' nocall
  DONE; fi
done

if CASE 'stop: .git/commondir'; then
fx s7; printf '../..\n' > "$GD/commondir"
tw check-checkout "checkout=$CO" run=none; STOPCASE 'common dir'
DONE; fi

n=0
for spelling in '[include]\n\tpath = ../inc' '[Include]\n\tPath = ../inc' '[includeIf "gitdir:C:/"]\n\tpath = ../inc' '[INCLUDEIF "gitdir/i:c:/"]\n\tPATH = ../inc' '[include]\n\tpath = /\\\\localhost\\\\c$/x' "[include]\\n\\tpath = @WT@/inc1"; do
  n=$((n + 1))
  if CASE "stop: include.path spelling $n"; then
  fx "s8$n"; spelling=${spelling//@WT@/$CO}; printf "$spelling\n" >> "$GD/config"
  printf '[include]\n\tpath = inc2\n' > "$WT/inc1"
  tw check-checkout "checkout=$CO" run=none; STOPCASE config
  DONE; fi
done

if CASE 'stop: an include in config.worktree'; then
fx s9; printf '[include]\n\tpath = x\n' > "$GD/config.worktree"
tw check-checkout "checkout=$CO" run=none; STOPCASE config
DONE; fi

if CASE 'stop: core.worktree'; then
fx s10; printf '[core]\n\tworktree = C:/nowhere\n' >> "$GD/config"
tw check-checkout "checkout=$CO" run=none; STOPCASE config
DONE; fi

if CASE 'stop: an alternates line, and an alternates chain'; then
fx s11; printf '//192.0.2.7/x/objects\n' > "$GD/objects/info/alternates"
tw check-checkout "checkout=$CO" run=none; STOPCASE entries; chk 'no 192.0.2.7' nolog '192.0.2.7'
fx s12; mkdir -p "$T/s12/other/objects/info"; printf '%s\n' "$(cygpath -m "$T/s12/other2/objects")" > "$T/s12/other/objects/info/alternates"
printf '%s\n' "$(cygpath -m "$T/s12/other/objects")" > "$GD/objects/info/alternates"
tw check-checkout "checkout=$CO" run=none; STOPCASE entries
DONE; fi

if [ "$HAVE_ACL" = 1 ]; then
if CASE 'stop: a list-denied hooks/ stops'; then
fx s13; ACLFIX+=("$GD/hooks"); acl_deny "$GD/hooks" RD
tw check-checkout "checkout=$CO" run=none
chk 'a stop' bash -c "[ \"$RC\" = 1 ] && printf '%s\n' \"$OUT\" | tail -n 1 | grep -Eq '^git tripwire: (links|hooks|entries)$'"; chk 'no checkout call' nocall
acl_reset "$GD/hooks"
DONE; fi
else SKIP 'stop: a list-denied hooks/ stops' 'prerequisite missing: an icacls deny that bites'; fi

if CASE "stop: a <u> holding ' runs nothing"; then
fx s14; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw merge-unit "S=$S" "P=$P" "u=x';touch $(cygpath -m "$T/s14")/pwned;'" I=main "checkout=$CO" run=none
chk stop stop_is args; chk 'nothing ran' absent_f "$T/s14/pwned"; chk 'no checkout call' nocall
DONE; fi

if CASE 'stop: project not matching checkout'; then
fx s15; mkdir -p "$DH/tripwire/other"; TWP=$DH/tripwire/other
tw check-checkout "checkout=$CO" run=none; STOPCASE args; TWP=$DH/tripwire/proj
DONE; fi

mkargs_cr() { printf 'none\r\n' > "$ARGS/run"; }
mkargs_nul() { printf 'no\0ne\n' > "$ARGS/run"; }
mkargs_two() { printf 'none\nnone\n' > "$ARGS/run"; }
mkargs_fifo() { rm -f "$ARGS/run"; mkfifo "$ARGS/run"; }
mkargs_hard() { ln "$ARGS/run" "$ARGS/run2.tmp" && rm -f "$ARGS/run2.tmp"; ln "$ARGS/run" "$T/$N/hl.tmp"; }
for variant in cr nul two fifo hard; do
  if CASE "stop: an args file with $variant"; then
  fx "s16$variant"; PREFN="mkargs_$variant"; tw check-checkout "checkout=$CO" run=none; PREFN=''
  chk stop stop_is args; chk 'no checkout call' nocall
  DONE; fi
done

if CASE 'stop: a broken HEAD with a work-tree commondir at //192.0.2.7, and planted in the parent'; then
fx s17; printf 'garbage\n' > "$GD/HEAD"
printf '//192.0.2.7/share/far\n' > "$WT/commondir"; mkdir -p "$WT/objects" "$WT/refs"; printf 'ref: refs/heads/main\n' > "$WT/HEAD"
printf '//192.0.2.7/share/far\n' > "$T/s17/commondir"; mkdir -p "$T/s17/objects" "$T/s17/refs"; printf 'ref: refs/heads/main\n' > "$T/s17/HEAD"
tw check-checkout "checkout=$CO" run=none; STOPCASE folders; chk 'no connection' nolog '192.0.2.7'
fx s18; rm -rf "$GD/objects"; printf '//192.0.2.7/share/far\n' > "$WT/commondir"; mkdir -p "$WT/objects" "$WT/refs"; printf 'ref: refs/heads/main\n' > "$WT/HEAD"
tw check-checkout "checkout=$CO" run=none; STOPCASE folders; chk 'no connection' nolog '192.0.2.7'
DONE; fi

if CASE 'stop: links under .git that step 0 does not name (refs/heads, objects/pack, refs/replace) read nothing'; then
fx s19; mkdir -p "$T/s19/far/planted"; printf 'x\n' > "$T/s19/far/planted/f"
mv "$GD/refs/heads" "$T/s19/heads.real"; mkjunc "$GD/refs/heads" "$T/s19/heads.real"
tw check-checkout "checkout=$CO" run=none
chk rc rc_is 0; chk 'link hit' has '^git dir link refs/heads\$ '; chk 'only link hits' ncount_is '^(config key|hook|replace ref)' 0; chk 'no checkout call' nocall
tw merge-unit "S=$(printf '%040d' 1)" "P=$(printf '%040d' 2)" u=u1 I=main "checkout=$CO" run=none
chk 'acting stops' stop_is links; chk 'no checkout call' nocall
fx s20; mv "$GD/objects/pack" "$T/s20/pack.real"; mkjunc "$GD/objects/pack" "$T/s20/pack.real"
tw check-checkout "checkout=$CO" run=none; chk 'pack link hit' has '^git dir link objects/pack\$ '; chk 'no checkout call' nocall
fx s21; mkdir -p "$T/s21/far/refs-replace"; mkjunc "$GD/refs/replace" "$T/s21/far/refs-replace"
tw check-checkout "checkout=$CO" run=none; chk 'replace link hit' has '^git dir link refs/replace\$ '; chk 'no checkout call' nocall
fx s22; mv "$GD/objects" "$T/s22/obj.real"; mkjunc "$GD/objects" "$T/s22/obj.real"
tw check-checkout "checkout=$CO" run=none; STOPCASE links
fx s23; mv "$GD/refs" "$T/s23/refs.real"; mkjunc "$GD/refs" "$T/s23/refs.real"
tw check-checkout "checkout=$CO" run=none; STOPCASE links
DONE; fi

if CASE 'stop: runs/ as a junction'; then
fx s24; mv "$TWP/runs" "$T/s24/runs.real"; mkjunc "$TWP/runs" "$T/s24/runs.real"
tw check-checkout "checkout=$CO" run=none; STOPCASE folders
DONE; fi

if CASE 'stop: a checkout argument with mixed slashes and backslashes'; then
fx s25
tw check-checkout 'checkout=/\localhost\c$/x' run=none; chk stop stop_is args
tw check-checkout "checkout=//localhost/c\$/x" run=none; chk stop2 stop_is args
tw check-checkout "checkout=C:/a/../b/proj" run=none; chk stop3 stop_is args
DONE; fi

# ---------------------------------------------------------------- the salt
if CASE 'salt: missing fails closed; planted as a FIFO, folder or junction stops; found before its made line stops'; then
fx t1; rm -f "$DH/tripwire/proj.salt"
tw check-checkout "checkout=$CO" run=none; chk missing stop_is salt; chk 'no checkout call' nocall
mkfifo "$DH/tripwire/proj.salt"; tw check-checkout "checkout=$CO" run=none; chk fifo stop_is salt; rm -f "$DH/tripwire/proj.salt"
mkdir "$DH/tripwire/proj.salt"; tw check-checkout "checkout=$CO" run=none; chk folder stop_is salt; rmdir "$DH/tripwire/proj.salt"
mkdir "$T/t1/saltdir"; printf '%064d\n' 0 > "$T/t1/saltdir/f"; mkjunc "$DH/tripwire/proj.salt" "$T/t1/saltdir"
tw check-checkout "checkout=$CO" run=none; chk junction stop_is salt; rmjunc "$DH/tripwire/proj.salt"
printf '%064d\n' 0 > "$DH/tripwire/proj.salt"; sed -i '/tripwire salt: made/d' "$WT/CLAUDE.md"
tw check-checkout "checkout=$CO" run=none; chk 'no made line' stop_is salt
fx t2
for kind in fifo folder junction file; do
  rm -rf "$DH/tripwire/proj.salt" 2>/dev/null; rm -f "$DH/tripwire/proj.salt"
  case $kind in fifo) mkfifo "$DH/tripwire/proj.salt" ;; folder) mkdir "$DH/tripwire/proj.salt" ;; junction) mkdir -p "$T/t2/sd"; mkjunc "$DH/tripwire/proj.salt" "$T/t2/sd" ;; file) printf '%064d\n' 0 > "$DH/tripwire/proj.salt" ;; esac
  tw salt "checkout=$CO"; chk "salt mode over a planted $kind" stop_is salt
  [ "$kind" = junction ] && rmjunc "$DH/tripwire/proj.salt"; [ "$kind" = folder ] && rmdir "$DH/tripwire/proj.salt"; rm -f "$DH/tripwire/proj.salt"
done
DONE; fi

if CASE 'output: core.packedGitLimit=<value> prints no value'; then
fx t3; hg config core.packedGitLimit 987654321
tw check-checkout "checkout=$CO" run=none; chk hit has '^config key core\.packedgitlimit#'; chk 'no value' hasnt '987654321'
fx t3b; hg config core.packedGitLimit SECRETVALUE987
tw check-checkout "checkout=$CO" run=none; chk 'an invalid value stops' stop_is 'common dir'; chk 'no value in the stop' hasnt 'SECRETVALUE987'
DONE; fi

if CASE 'allowed: a forged never-allowed line, and a forged part 1-2 line, are ignored'; then
fx t4; hg config credential.helper 'x'
tw check-checkout "checkout=$CO" run=none; L=$(hitline '^config key credential\.helper'); printf '%s\n' "$L" >> "$TWP/allowed"
tw check-checkout "checkout=$CO" run=none; chk 'credential still fires' has '^config key credential\.helper#'
hg config --unset credential.helper # check-unit holds on a part 3 line, so the part 1-2 forgery is tried without one
S=$(mkunit work/u1 '120000:lnk:t'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; L2=$(hitline '^symlink lnk'); printf '%s\n' "$L2" >> "$TWP/allowed"
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none
chk 'symlink still fires' has '^symlink lnk\$ '
DONE; fi

if CASE 'allowed: a line carrying a placeholder hash is dropped on read'; then
fx t4b; mkdir "$GD/hooks/sub"
tw check-checkout "checkout=$CO" run=none; L=$(hitline '^hook hooks/sub\$'); chk 'a folder hook is a hit' eq "$([ -n "$L" ] && echo y)" y
printf '%s\n' "$L" >> "$TWP/allowed"
tw check-checkout "checkout=$CO" run=none; chk 'it still fires: a placeholder hash is never allowed' has '^hook hooks/sub\$ '
DONE; fi

if [ "$HAVE_ACL" != 1 ]; then SKIP 'allowed: unreadable allowed and unreadable released stop' 'prerequisite missing: an icacls deny that bites'; else
if CASE 'allowed: unreadable allowed and unreadable released stop'; then
fx t5; ACLFIX+=("$TWP/allowed"); acl_deny "$TWP/allowed" R
tw check-checkout "checkout=$CO" run=none; chk 'allowed unreadable' stop_is allowed
acl_reset "$TWP/allowed"
printf '#!/bin/sh\n' > "$GD/hooks/pre-commit"; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; L=$(hitlines); mkrun u1-1 "$L" '' "$L"
ACLFIX+=("$TWP/runs/u1-1/released"); acl_deny "$TWP/runs/u1-1/released" R
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk 'released unreadable' stop_is expected; chk 'main unmoved' [ "$(tip main)" = "$P" ]
acl_reset "$TWP/runs/u1-1/released"
DONE; fi
fi

# ---------------------------------------------------------------- allowing, holds, merges
if CASE 'allowing: a released checkout hit, once its run closes, does not fire at the next merge; a placeholder hash is never allowed'; then
fx a2; printf '#!/bin/sh\n' > "$GD/hooks/pre-commit"; mkdir "$GD/hooks/sub"
S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; L=$(hitlines); chk 'two hits' eq "$(printf '%s\n' "$L" | wc -l | tr -d ' ')" 2
mkrun u1-1 "$L" '' "$L"; tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk merged has '^git tripwire: tip [0-9a-f]{40}$'
tw close "checkout=$CO" run=u1-1; chk closed has '^git tripwire: closed 1$'
P2=$(tip main); S2=$(mkunit work/u2 '100644:f2:y'); P2=$(tip main)
tw check-unit "S=$S2" "P=$P2" I=main "checkout=$CO" run=none
chk 'hook no longer fires' hasnt '^hook hooks/pre-commit'; chk 'folder placeholder still fires' has '^hook hooks/sub\$ '
DONE; fi

if CASE 'allowing: an abandoned unit (no close) allows nothing'; then
fx a3; printf '#!/bin/sh\n' > "$GD/hooks/pre-commit"
tw check-checkout "checkout=$CO" run=none; L=$(hitlines); mkrun checkout-1 "$L" '' "$L"
tw check-checkout "checkout=$CO" run=none; chk 'still fires' has '^hook hooks/pre-commit'
DONE; fi

if CASE 'hold: an unreleased line stops the merge, the hit is printed first, main is unmoved'; then
fx m1; printf '#!/bin/sh\n' > "$GD/hooks/pre-commit"; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; L=$(hitlines); mkrun u1-1 "$L" '' ''
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1
chk stop stop_is expected; chk 'hit before stop' has '^hook hooks/pre-commit'; chk unmoved [ "$(tip main)" = "$P" ]
DONE; fi

if CASE 'hold: a hook swapped between the run and the merge stops at the hold'; then
fx m2; printf 'A\n' > "$GD/hooks/pre-commit"; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; L=$(hitlines); mkrun u1-1 "$L" '' "$L"
printf 'B\n' > "$GD/hooks/pre-commit"
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk stop stop_is expected; chk unmoved [ "$(tip main)" = "$P" ]
DONE; fi

if CASE 'hold: a line that vanished after the run is no failure'; then
fx m3; printf 'A\n' > "$GD/hooks/pre-commit"; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; L=$(hitlines); mkrun u1-1 "$L" '' "$L"
rm -f "$GD/hooks/pre-commit"
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk merged has '^git tripwire: tip [0-9a-f]{40}$'
DONE; fi

if CASE 'hold: a checkout run and a unit run share a line; one closes and the other merges'; then
fx m4; printf 'A\n' > "$GD/hooks/pre-commit"; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw check-checkout "checkout=$CO" run=none; LC=$(hitlines); mkrun checkout-1 "$LC" '' "$LC"
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; LU=$(hitlines); mkrun u1-1 "$LU" '' "$LU"
tw close "checkout=$CO" run=checkout-1
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk merged has '^git tripwire: tip [0-9a-f]{40}$'
DONE; fi

if CASE 'merge: the subject is Merge branch work/<u>; first parent P, second S; no hit merges with run none'; then
fx m5; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none
chk tip has '^git tripwire: tip [0-9a-f]{40}$'
chk subject [ "$(hg log -1 --format=%s main)" = "Merge branch 'work/u1'" ]
chk parent1 eq "$(hg rev-parse main^1)" "$P"; chk parent2 eq "$(hg rev-parse main^2)" "$S"
chk 'file in tree' [ -f "$WT/f1" ]
DONE; fi

if CASE 'merge: a member git branch -f <I> <S> stops at <P>; a moved work/<u> stops'; then
fx m6; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main); hg update-ref refs/heads/main "$S"
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none; chk 'main moved' stop_is unit
hg update-ref refs/heads/main "$P"; S2=$(mkunit work/u2 '100644:f2:x')
tw merge-unit "S=$S" "P=$P" u=u2 I=main "checkout=$CO" run=none; chk 'work/u2 is not S' stop_is unit
DONE; fi

if CASE 'merge: HEAD must be refs/heads/<I>'; then
fx m7; hg checkout -q -b other; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none; chk 'head elsewhere' stop_is merge
DONE; fi

if CASE 'unit: P=none while <I> exists stops (none means the ref must be absent)'; then
fx m10; S=$(mkunit work/u1 '100644:f1:x')
tw check-unit "S=$S" P=none I=main "checkout=$CO" run=none; chk 'check-unit' stop_is unit
tw merge-unit "S=$S" P=none u=u1 I=main "checkout=$CO" run=none; chk 'merge-unit' stop_is unit
Pt=$(tip main); tw merge-handsoff Pt=none "Ps=$S" from=work/u1 to=main "checkout=$CO" run=none; chk 'handsoff Pt none' stop_is unit
DONE; fi

if CASE 'check-unit and check-checkout never merge or move a ref or the index'; then
fx m8; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main); I0=$(sha256sum "$GD/index" | cut -c1-64)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; tw check-checkout "checkout=$CO" run=none
chk unmoved [ "$(tip main)" = "$P" ]; chk index [ "$(sha256sum "$GD/index" | cut -c1-64)" = "$I0" ]
DONE; fi

if CASE 'merge-handsoff: merges by the pinned shas; a wrong Ps or a HEAD elsewhere stops'; then
fx m9; hg checkout -q -b devhouse/hands-off; S=$(mkunit devhouse/hands-off '100644:ho:x'); hg checkout -q main
Pt=$(tip main); Ps=$(tip devhouse/hands-off)
tw merge-handsoff "Pt=$Pt" "Ps=$(printf '%040d' 3)" from=devhouse/hands-off to=main "checkout=$CO" run=none; chk 'wrong Ps' stop_is unit
hg checkout -q devhouse/hands-off; tw merge-handsoff "Pt=$Pt" "Ps=$Ps" from=devhouse/hands-off to=main "checkout=$CO" run=none; chk 'head elsewhere' stop_is merge
hg checkout -q main; tw merge-handsoff "Pt=$Pt" "Ps=$Ps" from=devhouse/hands-off to=main "checkout=$CO" run=none
chk merged has '^git tripwire: tip [0-9a-f]{40}$'; chk parent2 eq "$(hg rev-parse main^2)" "$Ps"
DONE; fi

# ---------------------------------------------------------------- nothing runs at a merge, commit, update-ref or unshallow
fire_setup() { # [1]: plant file hooks, a gpg.program and, with 1, local config hooks (a hold never releases those); markers in $T/$N/mk
  mkdir -p "$T/$N/mk"; M=$(cygpath -m "$T/$N/mk")
  local h
  for h in pre-merge-commit post-merge reference-transaction post-index-change commit-msg post-commit; do printf '#!/bin/sh\ntouch "%s/file-%s"\n' "$M" "$h" > "$GD/hooks/$h"; done
  [ "${1:-0}" = 1 ] && for h in post-merge reference-transaction post-index-change; do hg config "hook.cfg-$h.command" "touch $M/cfg-$h"; hg config "hook.cfg-$h.event" "$h"; done
  hg config gpg.program "sh -c 'touch $M/gpg'"
}
if CASE 'nothing runs at a merge: no hook file, no gpg.program (a local config hook is held, never released: case c10)'; then
fx f1; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
fire_setup
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; L=$(hitlines); mkrun u1-1 "$L" '' "$L"
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk merged has '^git tripwire: tip [0-9a-f]{40}$'
chk 'markers absent' bash -c "[ -z \"\$(ls '$T/f1/mk')\" ]"
DONE; fi

if CASE 'control: plain git does run those hooks (so the case above is not vacuous)'; then
fx f2; S=$(mkunit work/u1 '100644:f1:x'); fire_setup 1; git -C "$WT" merge -q --no-ff --no-edit "$S" >/dev/null 2>&1
chk 'a hook file ran' [ -e "$T/f2/mk/file-post-merge" ]; chk 'a config hook ran' [ -e "$T/f2/mk/cfg-post-merge" ]
DONE; fi

global_cfg() { # <home dir> <marker dir (MSYS)> <all|hookgc|gpg>: a global config with a hook, a signing program and an eager gc
  local M
  M=$(cygpath -m "$2")
  printf '[user]\n\tname = Test User\n\temail = test@example.invalid\n[core]\n\tautocrlf = false\n' > "$1/.gitconfig"
  case $3 in all | hookgc) printf '[hook "g"]\n\tcommand = touch %s/global\n\tevent = post-merge\n[gc]\n\tauto = 1\n\tautoPackLimit = 1\n\tautoDetach = false\n' "$M" >> "$1/.gitconfig" ;; esac
  case $3 in all | gpg)
    printf '#!/bin/sh\ntouch "%s/gpg"\nexit 1\n' "$M" > "$1/signer.sh"; chmod +x "$1/signer.sh"
    printf '[gpg]\n\tprogram = %s\n[commit]\n\tgpgsign = true\n' "$(cygpath -m "$1")/signer.sh" >> "$1/.gitconfig" ;;
  esac
}
if CASE 'nothing runs at a merge: a global config hook, a global gpg.program and an eager auto-maintenance'; then
fx f3; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main); mkdir -p "$T/f3/mk" "$T/f3/home"; global_cfg "$T/f3/home" "$T/f3/mk" all
TWHOME=$T/f3/home; TWTRACE=$T/f3/trace; tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none; TWHOME=$HOME1; TWTRACE=''
chk merged has '^git tripwire: tip [0-9a-f]{40}$'; chk 'no marker' bash -c "[ -z \"\$(ls '$T/f3/mk')\" ]"
chk 'trace is not empty' [ -s "$T/f3/trace" ]
chk 'no maintenance or gc was started' bash -c "! grep -Eq 'maintenance run|gc --auto|git gc' '$T/f3/trace'"
DONE; fi

if CASE 'control: with that global config, plain git merge fires the hook and starts auto-maintenance; a signing merge calls the signer'; then
fx f4; S=$(mkunit work/u1 '100644:f1:x'); mkdir -p "$T/f4/mk" "$T/f4/home"; global_cfg "$T/f4/home" "$T/f4/mk" hookgc
HOME=$T/f4/home GIT_TRACE="$(cygpath -m "$T/f4/trace")" git -C "$WT" merge -q --no-ff --no-edit "$S" >/dev/null 2>&1
chk 'global config hook ran' [ -e "$T/f4/mk/global" ]
chk 'auto-maintenance was started' bash -c "grep -Eq 'maintenance run|gc --auto' '$T/f4/trace'"
fx f5; S=$(mkunit work/u1 '100644:f1:x'); mkdir -p "$T/f5/mk" "$T/f5/home"; global_cfg "$T/f5/home" "$T/f5/mk" gpg
HOME=$T/f5/home git -C "$WT" merge -q --no-ff --no-edit "$S" >/dev/null 2>&1
chk 'signing program ran' [ -e "$T/f5/mk/gpg" ]
DONE; fi

# ---------------------------------------------------------------- commits
if CASE 'commit: a part 3 hit and a part 1 hit commit after both rounds; a held commit leaves the real index untouched'; then
fx k1; mkdir -p "$WT/nested" && git init -q "$WT/nested" && git -C "$WT/nested" -c core.hooksPath=/dev/null commit -q --allow-empty -m n
printf 'readme changed\n' > "$WT/README"; printf '#!/bin/sh\n' > "$GD/hooks/pre-commit"
P=$(tip main); printf 'README\nnested\n' > "$T/k1/paths.txt"
IX0=$(sha256sum "$GD/index" | cut -c1-64)
cpaths() { cp "$T/k1/paths.txt" "$ARGS/paths"; }
PREFN=cpaths
tw commit "P=$P" I=main "checkout=$CO" run=none; chk 'round 1 stops expected' stop_is expected; chk 'round 1 prints the hook' has '^hook hooks/pre-commit\$ '
chk 'index untouched' [ "$(sha256sum "$GD/index" | cut -c1-64)" = "$IX0" ]; chk 'main unmoved' [ "$(tip main)" = "$P" ]
L1=$(hitlines); mkrun c-1 "$L1" '' "$L1"
tw commit "P=$P" I=main "checkout=$CO" run=c-1; chk 'round 2 stops expected' stop_is expected; chk 'round 2 prints the gitlink' has '^gitlink nested\$ '
chk 'index untouched 2' [ "$(sha256sum "$GD/index" | cut -c1-64)" = "$IX0" ]; chk 'main unmoved 2' [ "$(tip main)" = "$P" ]
L2=$(hitlines); mkrun c-1 "$L2" '' "$L2"
tw commit "P=$P" I=main "checkout=$CO" run=c-1; chk 'round 3 commits' has '^git tripwire: tip [0-9a-f]{40}$'; chk 'the hit lines are printed with the tip' has '^gitlink nested\$ '
PREFN=''
N1=$(tip main); chk 'parent is P' [ "$(hg rev-parse "$N1^")" = "$P" ]
chk 'tree: README changed, nested is a gitlink' bash -c "git -C '$WT' ls-tree '$N1' nested | grep -q '^160000 commit' && [ \"\$(git -C '$WT' show '$N1:README')\" = 'readme changed' ]"
chk 'real index matches the new tip' bash -c "git -C '$WT' diff --cached --quiet"
DONE; fi

if CASE 'commit: only the checked tree is committed (staged-commit form); a member-staged file is refused'; then
fx k2; printf 'a2\n' > "$WT/README"; printf 'kept out\n' > "$WT/extra"; P=$(tip main)
cpaths2() { printf 'README\n' > "$ARGS/paths"; }
PREFN=cpaths2; tw commit "P=$P" I=main "checkout=$CO" run=none; PREFN=''
chk committed has '^git tripwire: tip [0-9a-f]{40}$'
N1=$(tip main); chk 'only README' [ "$(hg diff --name-only "$P" "$N1")" = README ]
chk 'extra untouched' [ -f "$WT/extra" ]
fx k3; printf 'x\n' > "$WT/staged"; hg add staged; printf 'a2\n' > "$WT/README"; P=$(tip main)
PREFN=cpaths2; tw commit "P=$P" I=main "checkout=$CO" run=none; PREFN=''
chk 'staged file refused' stop_is commit; chk unmoved [ "$(tip main)" = "$P" ]
DONE; fi

if CASE 'commit: a first commit with no <I> commits'; then
setn k5; rm -rf "${T:?}/$N"; mkdir -p "$WT" "$TWP"; git init -q -b main "$WT"; printf 'p\ntripwire salt: made 2025-01-01\n' > "$WT/CLAUDE.md"
tw salt "checkout=$CO"; chk salt rc_is 0
cpaths3() { printf 'CLAUDE.md\n' > "$ARGS/paths"; }
PREFN=cpaths3; tw commit P=none I=main "checkout=$CO" run=none; PREFN=''
chk commit has '^git tripwire: tip [0-9a-f]{40}$'; chk 'branch exists' [ -n "$(hg rev-parse -q --verify refs/heads/main)" ]; chk 'no parent' [ -z "$(hg rev-parse -q --verify main^ 2>/dev/null)" ]
DONE; fi

# Note: the clean-filter part of this case proves little. The commit's paths are CLAUDE.md only, so the script never reads
# README's content, and README is not in the paths for the filter check either. The blanking of `filter.x.clean` is
# shown by S1 (s1b, at merge-tree); the filter check by the filter cases below.
if CASE 'commit: a clean filter, a post-index-change config hook, reference-transaction and file hooks run nothing'; then
fx k6; M=$(cygpath -m "$T/k6/mk"); mkdir -p "$T/k6/mk"
printf 'changed\ntripwire salt: made 2025-01-01\n' > "$WT/CLAUDE.md"
touch -d '2001-01-01' "$WT/README"
hg config filter.x.clean "sh -c 'touch $M/clean; cat'"; printf 'README filter=x\n' > "$GD/info/attributes"
mkdir -p "$T/k6/home" # the config hooks are global ones: a local hook.* line is held and never released
printf '[user]\n\tname = Test User\n\temail = test@example.invalid\n[core]\n\tautocrlf = false\n[hook "pic"]\n\tcommand = touch %s/pic\n\tevent = post-index-change\n[hook "rt"]\n\tcommand = touch %s/rt\n\tevent = reference-transaction\n' "$M" "$M" > "$T/k6/home/.gitconfig"
mkdir -p "$T/k6/sgn"; printf '#!/bin/sh\ntouch "%s/gpg"\nexit 1\n' "$M" > "$T/k6/sgn/signer.sh"; chmod +x "$T/k6/sgn/signer.sh"
hg config gpg.program "$(cygpath -m "$T/k6/sgn/signer.sh")"; hg config commit.gpgsign true
for h in reference-transaction post-index-change post-commit; do printf '#!/bin/sh\ntouch "%s/file-%s"\n' "$M" "$h" > "$GD/hooks/$h"; done
P=$(tip main); cpaths4() { printf 'CLAUDE.md\n' > "$ARGS/paths"; }
TWHOME=$T/k6/home; PREFN=cpaths4; tw commit "P=$P" I=main "checkout=$CO" run=none; L=$(hitlines); mkrun c-1 "$L" '' "$L"
tw commit "P=$P" I=main "checkout=$CO" run=c-1; PREFN=''; TWHOME=$HOME1
chk committed has '^git tripwire: tip [0-9a-f]{40}$'; chk 'markers absent' bash -c "[ -z \"\$(ls '$T/k6/mk')\" ]"
DONE; fi

if CASE 'control: plain reset --mixed runs the clean filter; plain update-ref runs the config hook'; then
fx k7; M=$(cygpath -m "$T/k7/mk"); mkdir -p "$T/k7/mk"; touch -d '2001-01-01' "$WT/README"
git -C "$WT" config filter.x.clean "sh -c 'touch $M/clean; cat'"; printf 'README filter=x\n' > "$GD/info/attributes"
git -C "$WT" config hook.rt.command "touch $M/rt"; git -C "$WT" config hook.rt.event reference-transaction
git -C "$WT" reset -q --mixed >/dev/null 2>&1; git -C "$WT" update-ref refs/heads/zz "$(git -C "$WT" rev-parse main)" >/dev/null 2>&1
chk 'clean filter ran' [ -e "$T/k7/mk/clean" ]; chk 'config hook ran' [ -e "$T/k7/mk/rt" ]
DONE; fi

# ---------------------------------------------------------------- removals
D=$(date -u +%Y%m%d)
if CASE 'remove: a moved hook does not re-fire; a second removal the same day gets its own n'; then
fx r2; printf 'A\n' > "$GD/hooks/pre-commit"; printf 'B\n' > "$GD/hooks/post-merge"
tw check-checkout "checkout=$CO" run=none
L1=$(hitline '^hook hooks/pre-commit'); L2=$(hitline '^hook hooks/post-merge')
sel_rm hook "$L1"; chk select selhas '^git tripwire: id hooks/pre-commit\$$'; chk 'select ok' eq "$SELRC" 0; chk removed has '^git tripwire: removed hook$'
sel_rm hook "$L2"; chk removed2 has '^git tripwire: removed hook$'
chk 'moved 1' [ -e "$TWP/removed/$D-1" ]; chk 'moved 2' [ -e "$TWP/removed/$D-2" ]; chk 'gone' absent_f "$GD/hooks/pre-commit"
chk 'index.txt' bash -c "[ \$(wc -l < '$TWP/removed/index.txt') = 2 ]"
tw check-checkout "checkout=$CO" run=none; chk 'no re-fire' hasnt '^hook hooks/'
DONE; fi

if CASE 'remove: select with a wrong hash, or a wrong id, stops'; then
fx r3; printf 'A\n' > "$GD/hooks/pre-commit"
tw select "checkout=$CO" class=hook 'id=hooks/pre-commit$' "hash=$(printf '%064d' 1)"; chk 'wrong hash' stop_is remove
tw check-checkout "checkout=$CO" run=none; L=$(hitline '^hook hooks/pre-commit')
tw select "checkout=$CO" class=hook 'id=hooks/other$' "hash=$(lasthash "$L")"; chk 'wrong id' stop_is remove
DONE; fi

if CASE 'remove: two items with the same placeholder hash are told apart by their id'; then
fx r3b; mkdir "$GD/hooks/a" "$GD/hooks/b"
tw check-checkout "checkout=$CO" run=none; LA=$(hitline '^hook hooks/a\$'); LB=$(hitline '^hook hooks/b\$')
chk 'the two hashes are the same' eq "$(lasthash "$LA")" "$(lasthash "$LB")"
sel_rm hook "$LB"; chk 'select prints b' selhas '^git tripwire: id hooks/b\$$'; chk 'b removed' has '^git tripwire: removed hook$'
chk 'b is gone' absent_f "$GD/hooks/b"; chk 'a is still there' [ -d "$GD/hooks/a" ]
DONE; fi

if CASE 'remove: a junction named a&mkdir,pwned1 is unlinked, nothing is run, copied or followed (home on another volume when available)'; then
fx r4
if [ -n "$T2" ]; then echo "     (second volume for the home: $T2)"; mv "$DH" "$T2/r4-dh" && DH=$T2/r4-dh && TWP=$DH/tripwire/proj; fi
mkdir -p "$TR/r4/target"; printf 'keep\n' > "$TR/r4/target/keep.txt"
mkjunc "$GD/a&mkdir,pwned1" "$TR/r4/target"
tw check-checkout "checkout=$CO" run=none; chk hit has '^git dir link a&mkdir,pwned1\$ '
L=$(hitline '^git dir link a&mkdir,pwned1')
sel_rm 'git dir link' "$L"
chk removed has '^git tripwire: removed git dir link$'; chk 'junction gone' absent_f "$GD/a&mkdir,pwned1"
chk 'target intact' [ -f "$TR/r4/target/keep.txt" ]
chk 'nothing copied to removed/' bash -c "[ -z \"\$(ls '$TWP/removed' | grep -v index.txt)\" ]"
chk 'nothing run' bash -c "[ -z \"\$(find '$T' ${T2:+'$T2'} -name '*pwned1*' -not -path '*a&mkdir,pwned1*' 2>/dev/null)\" ]"
DONE; fi

if [ -n "$T2" ]; then
  if CASE 'remove: a file removal with removed/ on another volume stops and leaves the file'; then
  fx r5
  mv "$DH" "$T2/r5-dh"; DH=$T2/r5-dh; TWP=$DH/tripwire/proj
  printf 'A\n' > "$GD/hooks/pre-commit"; tw check-checkout "checkout=$CO" run=none; L=$(hitline '^hook hooks/pre-commit')
  sel_rm hook "$L"; chk stop stop_is remove; chk 'hook intact' [ -f "$GD/hooks/pre-commit" ]
  DONE; fi
else
  SKIP 'remove: a file removal with removed/ on another volume stops and leaves the file' 'prerequisite missing: a second volume (TW_VOLUME2 names a folder on one)'
fi

if CASE 'remove: modules/ holding a junction is refused'; then
fx r6; mkdir -p "$GD/modules" "$T/r6/target"; printf 'k\n' > "$T/r6/target/k"; mkjunc "$GD/modules/m" "$T/r6/target"
tw check-checkout "checkout=$CO" run=none; chk 'link hit' has '^git dir link modules/m\$ '
tw select "checkout=$CO" "class=submodule dir" 'id=modules$' "hash=$(printf '%064d' 1)"; chk 'select stops (links)' stop_is links
chk 'target intact' [ -f "$T/r6/target/k" ]
DONE; fi

if CASE 'remove: --unset-all on a token-bearing name; select and index.txt show the masked id only; the old record is saved; an absent key is restored and re-hashed'; then
fx r7; hg config 'url.https://TOKEN123SECRET@example.invalid/.insteadOf' 'https://example.invalid/'; hg config --unset core.bare
tw check-checkout "checkout=$CO" run=none
LU=$(hitline '^config key url\.'); LB=$(hitline '^config key core\.bare')
sel_rm 'config key' "$LU"; chk 'removed url key' has '^git tripwire: removed config key$'; chk 'key gone' bash -c "! git -C '$WT' config --local --get-regexp 'insteadof' >/dev/null 2>&1"
chk 'select prints the masked id' selhas '^git tripwire: id url\.<masked>\.insteadof#[0-9a-f]{8}\$$'; chk 'select prints no token' selhasnt 'TOKEN123SECRET'
chk 'no token in the output' hasnt 'TOKEN123SECRET'
chk 'no token in index.txt' bash -c "! grep -q TOKEN123SECRET '$TWP/removed/index.txt'"
chk 'index.txt has the masked id' bash -c "grep -qF 'config key url.<masked>.insteadof#' '$TWP/removed/index.txt'"
chk 'a credential-looking record is not saved: no file in removed/ holds the token' bash -c "[ -z \"\$(grep -rl TOKEN123SECRET '$TWP/removed' 2>/dev/null)\" ]"
chk 'index.txt says so' bash -c "grep -qF 'edited; not saved: may hold a credential; restore by hand; records: 1; salted hashes: $(sha_str $'url.https://TOKEN123SECRET@example.invalid/.insteadof\nhttps://example.invalid/')' '$TWP/removed/index.txt'"
chk 'no .config slot was made' bash -c "[ -z \"\$(ls '$TWP/removed' | grep '\\.config\$')\" ]"
sel_rm 'config key' "$LB"; chk 'restored bare' bash -c "[ \"\$(git -C '$WT' config --local core.bare)\" = false ]"
tw check-checkout "checkout=$CO" run=none; chk 'no hits left' nohits
DONE; fi

if CASE 'remove: core.repositoryformatversion and extensions.* (bar worktreeConfig) are fixed by hand'; then
fx r7b; hg config core.repositoryformatversion 1; hg config extensions.partialClone origin
tw check-checkout "checkout=$CO" run=none
LV=$(hitline '^config key core\.repositoryformatversion'); LX=$(hitline '^config key extensions\.partialclone')
chk 'both are hits' eq "$([ -n "$LV" ] && [ -n "$LX" ] && echo y)" y
sel_rm 'config key' "$LV"; chk 'version refused' stop_is remove; chk 'version kept' bash -c "[ \"\$(git -C '$WT' config --local core.repositoryformatversion)\" = 1 ]"
sel_rm 'config key' "$LX"; chk 'extension refused' stop_is remove; chk 'extension kept' bash -c "[ \"\$(git -C '$WT' config --local extensions.partialClone)\" = origin ]"
DONE; fi

if CASE 'remove: a SHA-256 checkout is compared with a SHA-256 reference repo'; then
setn r7c; rm -rf "${TR:?}/$N"; mkdir -p "$TR/$N"; cp -a "$T/_base/dh" "$DH"
git init -q --object-format=sha256 -b main "$WT" 2>/dev/null && printf 'p\ntripwire salt: made 2025-01-01\n' > "$WT/CLAUDE.md"
tw check-checkout "checkout=$CO" run=none
chk 'no hit for the format keys' hasnt '^config key (extensions\.objectformat|core\.repositoryformatversion)'; chk rc rc_is 0
DONE; fi

if CASE 'remove: a hard link is broken with its content kept'; then
fx r8; ln "$GD/config" "$T/r8/other.link"; tw check-checkout "checkout=$CO" run=none; L=$(hitline '^hard link config')
C0=$(sha256sum "$GD/config" | cut -c1-64)
sel_rm 'hard link' "$L"; chk removed has '^git tripwire: removed hard link$'
chk 'content kept' [ "$(sha256sum "$GD/config" | cut -c1-64)" = "$C0" ]; chk 'count 1' [ "$(stat -c %h "$GD/config")" = 1 ]
chk 'other link unchanged' [ "$(sha256sum "$T/r8/other.link" | cut -c1-64)" = "$C0" ]; chk 'no temp left' bash -c "[ -z \"\$(ls '$GD' | grep '^tw\.')\" ]"
DONE; fi

if CASE 'remove: a replace ref is deleted'; then
fx r9; B=$(hg rev-parse main); O=$(printf 'o\n' | hg commit-tree "$(hg rev-parse 'main^{tree}')"); hg replace "$B" "$O"
tw check-checkout "checkout=$CO" run=none; L=$(hitline '^replace ref')
sel_rm 'replace ref' "$L"; chk removed has '^git tripwire: removed replace ref$'; chk 'ref gone' bash -c "[ -z \"\$(git -C '$WT' for-each-ref refs/replace/)\" ]"
DONE; fi

shallow_fixture() { # <name>: a --depth 1 clone, with the base home
  setn "$1"; rm -rf "${TR:?}/$N"; mkdir -p "$TR/$N"; cp -a "$T/_base/dh" "$DH"
  git clone -q --depth 1 "file:///$(cygpath -m "$T/_base/src")" "$WT" 2>/dev/null
}
if CASE 'remove: shallow is removed by --unshallow, with no hook or fetch hook running'; then
shallow_fixture r10
mkdir -p "$T/r10/mk"; M=$(cygpath -m "$T/r10/mk"); for h in reference-transaction post-checkout post-merge; do printf '#!/bin/sh\ntouch "%s/f-%s"\n' "$M" "$h" > "$GD/hooks/$h"; done
tw check-checkout "checkout=$CO" run=none; chk 'shallow hit' has '^shallow shallow\$ '
LS=$(hitline '^shallow shallow')
sel_rm shallow "$LS"; chk 'held while a config key hit is not allowed' stop_is remove
tw check-checkout "checkout=$CO" run=none
printf '%s\n' "$(hitlines | grep '^config key ')" >> "$TWP/allowed"
tw check-checkout "checkout=$CO" run=none; LS=$(hitline '^shallow shallow')
sel_rm shallow "$LS"
chk removed has '^git tripwire: removed shallow$'; chk 'shallow gone' absent_f "$GD/shallow"; chk 'no hook ran' bash -c "[ -z \"\$(ls '$T/r10/mk')\" ]"
DONE; fi

if CASE 'remove: shallow is held while a worktree link stands'; then
shallow_fixture r10w
tw check-checkout "checkout=$CO" run=none; printf '%s\n' "$(hitlines | grep '^config key ')" >> "$TWP/allowed"
hg worktree add -q "$TR/$N/wt-u1" -b work/u1 2>/dev/null; rm -f -- "$GD/worktrees/wt-u1/HEAD"
tw check-checkout "checkout=$CO" run=none; chk 'a worktree link hit' has '^worktree link worktrees/wt-u1\$ '; LS=$(hitline '^shallow shallow')
chk 'no config key is left to blame' hasnt '^config key '
sel_rm shallow "$LS"; chk 'held' stop_is remove; chk 'still shallow' [ -e "$GD/shallow" ]
DONE; fi

if CASE 'remove: unshallow with a global config hook and an eager gc runs no hook and starts no maintenance'; then
shallow_fixture r10b
mkdir -p "$T/r10b/mk" "$T/r10b/home" "$T/r10b/home2"; M=$(cygpath -m "$T/r10b/mk")
for hm in home home2; do
  printf '[user]\n\tname = Test User\n\temail = test@example.invalid\n[core]\n\tautocrlf = false\n[hook "g"]\n\tcommand = touch %s/global\n\tevent = reference-transaction\n[hook "g2"]\n\tcommand = touch %s/global2\n\tevent = post-checkout\n[gc]\n\tauto = 1\n\tautoPackLimit = 1\n\tautoDetach = false\n' "$M" "$M" > "$T/r10b/$hm/.gitconfig"
done
tw check-checkout "checkout=$CO" run=none; printf '%s\n' "$(hitlines | grep '^config key ')" >> "$TWP/allowed"
tw check-checkout "checkout=$CO" run=none; LS=$(hitline '^shallow shallow')
TWHOME=$T/r10b/home; TWTRACE=$T/r10b/trace; sel_rm shallow "$LS"; TWHOME=$HOME1; TWTRACE=''
chk removed has '^git tripwire: removed shallow$'; chk 'no marker' bash -c "[ -z \"\$(ls '$T/r10b/mk')\" ]"
chk 'trace is not empty' [ -s "$T/r10b/trace" ]; chk 'no maintenance or gc was started' bash -c "! grep -Eq 'maintenance run|gc --auto|git gc' '$T/r10b/trace'"
shallow_fixture r10c; mkdir -p "$T/r10c/mk"; M2=$(cygpath -m "$T/r10c/mk")
printf '[user]\n\tname = Test User\n\temail = test@example.invalid\n[core]\n\tautocrlf = false\n[hook "g"]\n\tcommand = touch %s/global\n\tevent = reference-transaction\n[gc]\n\tauto = 1\n\tautoPackLimit = 1\n\tautoDetach = false\n' "$M2" > "$T/r10c/home.gitconfig"
mkdir -p "$T/r10c/home"; cp "$T/r10c/home.gitconfig" "$T/r10c/home/.gitconfig"
HOME=$T/r10c/home GIT_TRACE="$(cygpath -m "$T/r10c/trace")" git -C "$WT" fetch -q --unshallow >/dev/null 2>&1
chk 'control: plain fetch runs the global hook' [ -e "$T/r10c/mk/global" ]
chk 'control: plain fetch starts maintenance' bash -c "grep -Eq 'maintenance run|gc --auto' '$T/r10c/trace'"
DONE; fi

if CASE 'remove: a link at objects/ or refs/ is a stop, a link under refs/ is never removed'; then
fx r11; mv "$GD/objects" "$T/r11/o.real"; mkjunc "$GD/objects" "$T/r11/o.real"
tw remove "checkout=$CO" "class=git dir link" 'id=objects$' "hash=$(printf '%064d' 1)"; chk objects stop_is links
fx r12; mv "$GD/refs" "$T/r12/r.real"; mkjunc "$GD/refs" "$T/r12/r.real"
tw remove "checkout=$CO" "class=git dir link" 'id=refs$' "hash=$(printf '%064d' 1)"; chk refs stop_is links
fx r13; mv "$GD/refs/heads" "$T/r13/h.real"; mkjunc "$GD/refs/heads" "$T/r13/h.real"
tw check-checkout "checkout=$CO" run=none; L=$(hitline '^git dir link refs/heads')
sel_rm 'git dir link' "$L"; chk 'refs/heads link refused' stop_is remove; chk 'junction still there' [ -L "$GD/refs/heads" ]
DONE; fi

if CASE 'remove: the never-removed list is compared in lower case (a refs folder renamed Refs)'; then
fx r14; mv "$GD/refs" "$GD/refs.tmp" && mv "$GD/refs.tmp" "$GD/Refs"; mv "$GD/Refs/tags" "$T/r14/tags.real"; mkjunc "$GD/Refs/tags" "$T/r14/tags.real"
tw check-checkout "checkout=$CO" run=none; L=$(hitline '^git dir link Refs/tags')
chk 'the link is listed under the folder case' eq "$([ -n "$L" ] && echo y)" y
sel_rm 'git dir link' "$L"; chk 'refused' stop_is remove; chk 'junction still there' [ -L "$GD/Refs/tags" ]
DONE; fi

# ---------------------------------------------------------------- hits and removals the first build left unshown
plant_g() { # plants one of each: a legacy remote and branch, a modules/ folder, the two info files, a config.worktree
  mkdir -p "$GD/remotes" "$GD/branches" "$GD/modules/m1"
  printf 'URL: x\n' > "$GD/remotes/old"; printf 'x\n' > "$GD/branches/oldb"; printf 'x\n' > "$GD/modules/m1/f"
  printf '* x\n' > "$GD/info/attributes"; printf 'sub/\n' > "$GD/info/sparse-checkout"
  printf '[core]\n\tbare = false\n' > "$GD/config.worktree"
}
if CASE 'hit: a legacy remote and branch, a modules/ folder, info/attributes, info/sparse-checkout'; then
fx g1; plant_g
tw check-checkout "checkout=$CO" run=none
chk remote has '^legacy remote remotes/old\$ '; chk branch has '^legacy remote branches/oldb\$ '; chk modules has '^submodule dir modules\$ '
chk attributes has '^info file info/attributes\$ '; chk sparse has '^info file info/sparse-checkout\$ '; chk worktreeconfig has '^worktree config config\.worktree\$ '
DONE; fi

if CASE 'remove: an info file, a legacy remote, a worktree config and a submodule dir are each moved; the next check is clean'; then
fx g2; plant_g
tw check-checkout "checkout=$CO" run=none; ALL=$(hitlines)
for spec in 'info file|^info file info/attributes' 'info file|^info file info/sparse-checkout' 'legacy remote|^legacy remote remotes/old' 'legacy remote|^legacy remote branches/oldb' 'worktree config|^worktree config config\.worktree' 'submodule dir|^submodule dir modules'; do
  cls=${spec%%|*}; L=$(printf '%s\n' "$ALL" | grep -E -- "${spec#*|}")
  sel_rm "$cls" "$L"; chk "removed $cls (${spec#*|})" has "^git tripwire: removed $cls\$"
done
tw check-checkout "checkout=$CO" run=none; chk 'the next check is clean' nohits
chk 'six slots' bash -c "[ \$(ls '$TWP/removed' | grep -c '^$D-') = 6 ]"
DONE; fi

if CASE 'remove: a stale worktree entry is pruned when it is the only stale one'; then
fx g3; hg worktree add -q "$TR/$N/wt-u1" -b work/u1 2>/dev/null; rm -rf -- "$TR/$N/wt-u1"
tw check-checkout "checkout=$CO" run=none; L=$(hitline '^worktree link worktrees/wt-u1\$')
chk 'a hit' eq "$([ -n "$L" ] && echo y)" y
sel_rm 'worktree link' "$L"; chk removed has '^git tripwire: removed worktree link$'; chk 'entry gone' absent_f "$GD/worktrees/wt-u1"
chk 'logged as pruned' bash -c "grep -q 'worktree link worktrees/wt-u1\\\$ pruned' '$TWP/removed/index.txt'"
DONE; fi

if CASE 'remove: with two stale entries the selected one is moved, not pruned'; then
fx g4; hg worktree add -q "$TR/$N/wt-u1" -b work/u1 2>/dev/null; hg worktree add -q "$TR/$N/wt-u2" -b work/u2 2>/dev/null
rm -rf -- "$TR/$N/wt-u1" "$TR/$N/wt-u2"
tw check-checkout "checkout=$CO" run=none; L=$(hitline '^worktree link worktrees/wt-u1\$')
sel_rm 'worktree link' "$L"; chk removed has '^git tripwire: removed worktree link$'
chk 'wt-u1 gone' absent_f "$GD/worktrees/wt-u1"; chk 'wt-u2 not pruned' [ -d "$GD/worktrees/wt-u2" ]; chk 'moved' [ -e "$TWP/removed/$D-1" ]
chk 'logged as moved' bash -c "grep -q 'worktree link worktrees/wt-u1\\\$ moved to' '$TWP/removed/index.txt'"
DONE; fi

# ---------------------------------------------------------------- links on the home's own folders
if CASE 'stop: tripwire/ as a junction'; then
fx l1; mvtw() { mv "$DH/tripwire" "$TR/$N/tw.real" && mkjunc "$DH/tripwire" "$TR/$N/tw.real"; }
PREFN=mvtw; tw check-checkout "checkout=$CO" run=none; PREFN=''; STOPCASE folders
rmjunc "$DH/tripwire"
DONE; fi

if CASE 'stop: tripwire/<project>/ as a junction'; then
fx l2; mvproj() { mv "$DH/tripwire/proj" "$TR/$N/proj.real" && mkjunc "$DH/tripwire/proj" "$TR/$N/proj.real"; }
PREFN=mvproj; tw check-checkout "checkout=$CO" run=none; PREFN=''; STOPCASE folders
rmjunc "$DH/tripwire/proj"
DONE; fi

if CASE 'stop: the args folder as a junction'; then
fx l3; mvargs() { mv "$ARGS" "$ARGS.real" && mkjunc "$ARGS" "$ARGS.real"; }
PREFN=mvargs; tw check-checkout "checkout=$CO" run=none; PREFN=''; STOPCASE folders
rmjunc "$ARGS"
DONE; fi

# ---------------------------------------------------------------- the parts of this iteration
if CASE 'unit: a short-name segment is a hit (CLAUDE~1/settings.json, HUSKY~1)'; then
fx sn1
S=$(mkunit work/u1 '100644:CLAUDE~1/settings.json:{}' '100644:src/HUSKY~1/pre:x' '100644:plain/file~2.txt:x'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none
chk claude has '^short name CLAUDE~1/settings\.json\$ [0-9a-f]{64}$'; chk husky has '^short name src/HUSKY~1/pre\$ '; chk 'any segment' has '^short name plain/file~2\.txt\$ '
chk 'not a claude file' hasnt '^claude file '
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none
L=$(hitlines); mkrun u1-1 "$L" '' "$L"; tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk 'released short names merge' has '^git tripwire: tip [0-9a-f]{40}$'
DONE; fi

if [ -n "$V83" ]; then
  if CASE 'unit: an 8.3 alias of a tracked folder lands in it, and the script stops at the hit'; then
  TR=$V83
  fx sn3; S3=$(mkunit work/u1 '100644:CLAUDE~1/alias.json:{"a":1}')
  git -C "$WT" -c "core.hooksPath=$(cygpath -m "$T/nohooks")" merge -q --no-ff --no-edit "$S3" >/dev/null 2>&1
  ALIAS=0; [ -f "$WT/.claude/alias.json" ] && ALIAS=1
  chk 'control: plain git lands CLAUDE~1/alias.json as .claude/alias.json' eq "$ALIAS" 1
  fx sn2; S=$(mkunit work/u1 '100644:CLAUDE~1/alias.json:{"a":1}'); P=$(tip main)
  tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none
  chk 'stops at the hit' stop_is expected; chk 'the short name is printed' has '^short name CLAUDE~1/alias\.json\$ '
  chk 'main unmoved' [ "$(tip main)" = "$P" ]; chk 'nothing landed in .claude' absent_f "$WT/.claude/alias.json"
  TR=$T
  DONE; fi
else
  SKIP 'unit: an 8.3 alias of a tracked folder lands in it, and the script stops at the hit' 'prerequisite missing: a volume with 8.3 short names (TW_VOLUME2 may name a folder on one); the fixture case above still proves the pattern'
fi

if CASE 'merge: a criss-cross history cannot land a steering file past parts 1-2'; then
fx cc
B=$(tip main)
X1=$(mktree main '100644:.gitattributes:* filter=evil'); C1=$(mkcommit "$X1" 1700001000 "$B")
X2=$(mktree "$C1" 'del:.gitattributes'); C2=$(mkcommit "$X2" 1700002000 "$C1")
XB=$(mktree "$C1" '100644:x1:one'); C1B=$(mkcommit "$XB" 1700003000 "$C1")
XM=$(mktree "$C1B" 'del:.gitattributes'); M1=$(mkcommit "$XM" 1700004000 "$C1B" "$C2")
S=$(mkcommit "$XB" 1700005000 "$C1B" "$C2")
hg update-ref refs/heads/main "$M1" && hg update-ref refs/heads/work/u1 "$S" && hg reset -q --hard main
P=$(tip main)
chk 'fixture: merge-base is the later of the two best bases' eq "$(hg merge-base "$P" "$S")" "$C1B"
chk 'fixture: the old diff, merge-base..S, is empty' hg diff --quiet "$C1B" "$S"
chk 'fixture: P has no .gitattributes' bash -c "! git -C '$WT' cat-file -e '$P:.gitattributes' 2>/dev/null"
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; chk 'check-unit shows the file' has '^git file \.gitattributes\$ '
L=$(hitlines)
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none; chk 'merge-unit stops' stop_is expected; chk 'the hit is printed' has '^git file \.gitattributes\$ '
chk 'main unmoved' [ "$(tip main)" = "$P" ]; chk 'no .gitattributes in the work tree' absent_f "$WT/.gitattributes"
mkrun u1-1 "$L" '' "$L"; tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1
chk 'released, it merges' has '^git tripwire: tip [0-9a-f]{40}$'; chk 'control: the file did arrive' bash -c "git -C '$WT' cat-file -e 'main:.gitattributes'"
DONE; fi

if CASE 'merge-handsoff: the hands-off merge brings in a steering file and the script stops at the hit'; then
fx hs; S=$(mkunit devhouse/hands-off '100644:.husky/pre-commit:x'); Pt=$(tip main); Ps=$S
tw merge-handsoff "Pt=$Pt" "Ps=$Ps" from=devhouse/hands-off to=main "checkout=$CO" run=none
chk 'stops at the hit' stop_is expected; chk 'the hit is printed' has '^hook framework file \.husky/pre-commit\$ '; chk 'main unmoved' [ "$(tip main)" = "$Pt" ]
L=$(hitlines); mkrun h-1 "$L" '' "$L"
tw merge-handsoff "Pt=$Pt" "Ps=$Ps" from=devhouse/hands-off to=main "checkout=$CO" run=h-1
chk 'released, it merges' has '^git tripwire: tip [0-9a-f]{40}$'; chk 'the hit line is printed before the tip' has '^hook framework file \.husky/pre-commit\$ '
DONE; fi

if CASE 'merge: part 3 is held before the unit is read (no merge-tree call is made)'; then
fx ph; printf 'A\n' > "$GD/hooks/pre-commit"; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none
chk 'stops expected' stop_is expected; chk 'the hook is printed' has '^hook hooks/pre-commit\$ '; chk 'no merge-tree call' nolog 'merge-tree'; chk 'main unmoved' [ "$(tip main)" = "$P" ]
DONE; fi

if CASE 'merge: a content merge that does not apply cleanly stops merge, and check-unit says the same'; then
fx mc; S=$(mkunit work/u1 '100644:README:unit side')
printf 'main side\n' > "$WT/README"; git -C "$WT" -c "core.hooksPath=$(cygpath -m "$T/nohooks")" commit -qam 'main side'; P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; chk 'check-unit stops' stop_is merge
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none; chk 'merge-unit stops' stop_is merge; chk 'main unmoved' [ "$(tip main)" = "$P" ]
DONE; fi

cpaths5() { printf 'README\n' > "$ARGS/paths"; }
if CASE 'merge: a dirty or colliding file in the way stops with nothing moved, and the note says so'; then
fx nm; S=$(mkunit work/u1 '100644:README:unit side'); P=$(tip main)
printf 'dirty\n' > "$WT/README"
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none
chk 'stop merge' stop_is merge; chk 'nothing-moved note' has "^git tripwire: note: nothing moved: refs/heads/main is still at $P\$"
chk 'the note comes right before the label' note_before_label
chk 'main unmoved' [ "$(tip main)" = "$P" ]; chk 'the dirty file is untouched' eq "$(cat "$WT/README")" dirty; chk 'no MERGE_HEAD' absent_f "$GD/MERGE_HEAD"
chk 'the index still matches P' bash -c "git -C '$WT' diff --cached --quiet"
fx nm2; S=$(mkunit work/u1 '100644:newfile:from the unit'); P=$(tip main); printf 'mine\n' > "$WT/newfile"
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none
chk 'an untracked file in the way: stop merge' stop_is merge; chk 'main unmoved' [ "$(tip main)" = "$P" ]; chk 'the untracked file is untouched' eq "$(cat "$WT/newfile")" mine
DONE; fi

# a git shim for the moved-branch notes: SHIMMODE=lockafter plants index.lock after a successful update-ref; SHIMMODE=race moves
# the branch to SHIMSHA just before the update-ref (so its old-value check fails)
mkdir -p "$T/shim3"
cat > "$T/shim3/git" <<EOF
#!/usr/bin/bash
{ printf 'GIT_DIR=%s' "\${GIT_DIR-<unset>}"; printf ' [%s]' "\$@"; printf '\n'; } >> "\$SHIMLOG"
for a in "\$@"; do
  if [ "\$a" = update-ref ]; then
    case \${SHIMMODE:-} in
      lockafter) $REALGIT "\$@"; rc=\$?; [ \$rc = 0 ] && : > "\$SHIMLOCK"; exit \$rc ;;
      race) $REALGIT update-ref refs/heads/main "\$SHIMSHA" ;;
    esac
    break
  fi
done
exec $REALGIT "\$@"
EOF
chmod +x "$T/shim3/git"
if CASE 'merge: a stop after update-ref names the moved branch; a lost update-ref race names where the branch is'; then
fx nc2; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
TWPATH="$T/shim3:/usr/bin:/mingw64/bin"; TWENV=(SHIMMODE=lockafter "SHIMLOCK=$(cygpath -m "$GD/index.lock")")
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none
chk 'stop merge' stop_is merge; chk 'moved note' has '^git tripwire: note: refs/heads/main has moved to [0-9a-f]{40}; the work tree may be partly written$'
chk 'the note comes right before the label' note_before_label; chk 'the branch did move' [ "$(tip main)" != "$P" ]
chk 'the moved branch is the merge with the parents P and S' bash -c "[ \"\$(git -C '$WT' rev-parse main^1)\" = '$P' ] && [ \"\$(git -C '$WT' rev-parse main^2)\" = '$S' ]"
rm -f -- "$GD/index.lock"
fx nc3; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main); OTHER=$(printf 'other\n' | hg commit-tree "$(hg rev-parse 'main^{tree}')" -p "$P")
TWPATH="$T/shim3:/usr/bin:/mingw64/bin"; TWENV=(SHIMMODE=race "SHIMSHA=$OTHER")
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none
chk 'stop merge' stop_is merge; chk 'the note names the other tip' has "^git tripwire: note: refs/heads/main is at $OTHER, not at $P or [0-9a-f]{40}; the work tree was not written\$"
chk 'the note comes right before the label' note_before_label; chk 'main is where the other process put it' [ "$(tip main)" = "$OTHER" ]
chk 'the work tree was not written' absent_f "$WT/f1"
DONE; fi
if CASE 'commit: a stop after update-ref names the moved branch'; then
fx nc; printf 'readme again\n' > "$WT/README"; P=$(tip main)
TWPATH="$T/shim3:/usr/bin:/mingw64/bin"; TWENV=(SHIMMODE=lockafter "SHIMLOCK=$(cygpath -m "$GD/index.lock")") # the lock appears after update-ref returns: the index write fails behind the moved branch
PREFN=cpaths5; tw commit "P=$P" I=main "checkout=$CO" run=none; PREFN=''
chk 'stop commit' stop_is commit; chk 'moved note' has '^git tripwire: note: refs/heads/main has moved to [0-9a-f]{40}$'
chk 'the note comes right before the label' note_before_label
chk 'the branch did move' [ "$(tip main)" != "$P" ]
rm -f -- "$GD/index.lock"
DONE; fi

if CASE 'merge: the hooks folder is the script own empty one, so a planted nul/ folder in the work tree runs nothing'; then
fx nl; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main); M=$(cygpath -m "$T/nl/mk"); mkdir -p "$T/nl/mk" "$WT/nul"
for h in reference-transaction post-merge pre-merge-commit; do printf '#!/bin/sh\ntouch "%s/%s"\n' "$M" "$h" > "$WT/nul/$h"; done
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none
chk merged has '^git tripwire: tip [0-9a-f]{40}$'; chk 'no hook ran' bash -c "[ -z \"\$(ls '$T/nl/mk')\" ]"
chk 'the hooks path is an absolute folder of the script' bash -c "grep -F 'core.hooksPath=' '$LOGF' | grep -F 'nohooks' | grep -qv 'hooksPath=/dev/null'"
chk 'no call used /dev/null as the hooks path' nolog 'hooksPath=/dev/null'
rm -f -- "$WT/nul/reference-transaction" "$WT/nul/post-merge" "$WT/nul/pre-merge-commit"; rmdir -- "$WT/nul"
DONE; fi

global_filters() { # <home dir> <marker dir (MSYS)>: a global config with a smudge and a clean filter, as files (a config value cannot hold a ;)
  local Mm
  Mm=$(cygpath -m "$2")
  printf '#!/bin/sh\ntouch "%s/smudge"\ncat\n' "$Mm" > "$1/smudge.sh"; printf '#!/bin/sh\ntouch "%s/clean"\ncat\n' "$Mm" > "$1/clean.sh"; chmod +x "$1/smudge.sh" "$1/clean.sh"
  printf '[user]\n\tname = Test User\n\temail = test@example.invalid\n[core]\n\tautocrlf = false\n[filter "demo"]\n\tsmudge = %s/smudge.sh\n\tclean = %s/clean.sh\n' "$(cygpath -m "$1")" "$(cygpath -m "$1")" > "$1/.gitconfig"
}
if CASE 'merge: an untracked .gitattributes in the work tree drives no filter'; then
fx at1; S=$(mkunit work/u1 '100644:f1.txt:x'); P=$(tip main); mkdir -p "$T/at1/mk" "$T/at1/home"; global_filters "$T/at1/home" "$T/at1/mk"
printf '*.txt filter=demo\n' > "$WT/.gitattributes"
TWHOME=$T/at1/home; tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none; TWHOME=$HOME1
chk merged has '^git tripwire: tip [0-9a-f]{40}$'; chk 'f1.txt arrived' [ -f "$WT/f1.txt" ]; chk 'no filter ran' bash -c "[ -z \"\$(ls '$T/at1/mk')\" ]"
fx at2; S=$(mkunit work/u1 '100644:f1.txt:x'); mkdir -p "$T/at2/mk" "$T/at2/home"; global_filters "$T/at2/home" "$T/at2/mk"; printf '*.txt filter=demo\n' > "$WT/.gitattributes"
HOME=$T/at2/home git -C "$WT" -c "core.hooksPath=$(cygpath -m "$T/nohooks")" merge -q --no-ff --no-edit "$S" >/dev/null 2>&1
chk 'control: plain git merge runs the smudge filter' [ -e "$T/at2/mk/smudge" ]
DONE; fi

global_driver() { # <home dir> <marker dir (MSYS)>: a global config with a custom merge driver that leaves a marker and fails
  local Mm
  Mm=$(cygpath -m "$2")
  printf '#!/bin/sh\ntouch "%s/drv"\nexit 1\n' "$Mm" > "$1/drv.sh"; chmod +x "$1/drv.sh"
  printf '[user]\n\tname = Test User\n\temail = test@example.invalid\n[core]\n\tautocrlf = false\n[merge "drv"]\n\tname = demo\n\tdriver = %s/drv.sh %%A %%O %%B\n' "$(cygpath -m "$1")" > "$1/.gitconfig"
}
if CASE 'merge: an untracked .gitattributes in the work tree drives no merge driver at the merge-tree step'; then
fx at5; mkdir -p "$T/at5/mk" "$T/at5/home"; global_driver "$T/at5/home" "$T/at5/mk"
printf 'a\nb\nc\n' > "$WT/m.txt"; hg add m.txt; hg commit -qm 'add m'
S=$(mkunit work/u1 $'100644:m.txt:A\nb\nc\n'); printf 'a\nb\nC\n' > "$WT/m.txt"; hg commit -qam 'edit m'; P=$(tip main)
printf '* merge=drv\n' > "$WT/.gitattributes"
TWHOME=$T/at5/home; tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none; TWHOME=$HOME1
chk merged has '^git tripwire: tip [0-9a-f]{40}$'; chk 'no driver ran' bash -c "[ -z \"\$(ls '$T/at5/mk')\" ]"
chk 'both edits are in the merged file' eq "$(tr -d '\r' < "$WT/m.txt" | tr '\n' '|')" 'A|b|C|'
HOME=$T/at5/home git -C "$WT" merge-tree --write-tree --no-messages "$P" "$S" >/dev/null 2>&1
chk 'control: plain merge-tree runs the untracked driver' [ -e "$T/at5/mk/drv" ]
DONE; fi

if CASE 'commit: an untracked .gitattributes in the work tree drives no clean filter, and since plain git add would run it, the commit stops with nothing moved (build 5: the work tree is one of the sources asked)'; then
fx at3; mkdir -p "$T/at3/mk" "$T/at3/home"; global_filters "$T/at3/home" "$T/at3/mk"; printf '%s\n' 'README filter=demo' > "$WT/.gitattributes"
printf 'readme changed\n' > "$WT/README"; P=$(tip main)
TWHOME=$T/at3/home; PREFN=cpaths5; tw commit "P=$P" I=main "checkout=$CO" run=none; PREFN=''; TWHOME=$HOME1
chk 'stop commit' stop_is commit; chk 'the filter note' has "^git tripwire: note: nothing moved: 1 path\\(s\\) the commit would add name a filter driver the config defines \\(a clean filter would not run\\); refs/heads/main is still at $P\$"; chk 'main unmoved' eq "$(tip main)" "$P"
chk 'no filter ran' bash -c "[ -z \"\$(ls '$T/at3/mk')\" ]"
fx at4; mkdir -p "$T/at4/mk" "$T/at4/home"; global_filters "$T/at4/home" "$T/at4/mk"; printf '%s\n' 'README filter=demo' > "$WT/.gitattributes"; printf 'readme changed\n' > "$WT/README"
HOME=$T/at4/home git -C "$WT" add README >/dev/null 2>&1
chk 'control: plain git add runs the clean filter' [ -e "$T/at4/mk/clean" ]
DONE; fi

# ---------------------------------------------------------------- the message and the paths of a commit
msg_run() { printf 'README\n' > "$ARGS/paths"; printf '%b' "$MSGRAW" > "$ARGS/message"; }
bump() { printf 'readme %s\n' "$RANDOM$RANDOM" > "$WT/README"; P=$(tip main); }
if CASE 'commit: a normal subject, a non-ASCII one and a 200-byte one commit as written'; then
fx mg; bump; PREFN=msg_run
MSGRAW='fix: tidy `x` (y), step 2 -- done\n'; tw commit "P=$P" I=main "checkout=$CO" run=none
chk 'a normal subject commits' has '^git tripwire: tip [0-9a-f]{40}$'; chk 'stored as written' eq "$(hg log -1 --format=%B main)" 'fix: tidy `x` (y), step 2 -- done'
bump; MSGRAW='docs \xe2\x80\x94 \xc2\xa7 4: tidy\n'; tw commit "P=$P" I=main "checkout=$CO" run=none
chk 'a non-ASCII subject commits' has '^git tripwire: tip [0-9a-f]{40}$'; chk 'stored byte for byte' eq "$(hg log -1 --format=%B main)" "$(printf 'docs \xe2\x80\x94 \xc2\xa7 4: tidy')"
bump; MSGRAW="$(head -c 200 /dev/zero | tr '\0' 'a')\\n"; tw commit "P=$P" I=main "checkout=$CO" run=none
chk '200 bytes commits' has '^git tripwire: tip [0-9a-f]{40}$'
bump; MSGRAW='merge notes: lower case and "Merge" alone are fine\n'; tw commit "P=$P" I=main "checkout=$CO" run=none
chk 'a subject that merely mentions merge commits' has '^git tripwire: tip [0-9a-f]{40}$'
bump; MSGRAW='edge: nbsp \xc2\xa0, U+2029 \xe2\x80\xa9, U+202F \xe2\x80\xaf, U+2065 \xe2\x81\xa5, U+206A \xe2\x81\xaa\n'; tw commit "P=$P" I=main "checkout=$CO" run=none
chk 'characters just outside the refused C1 and bidi ranges commit' has '^git tripwire: tip [0-9a-f]{40}$'
PREFN=''
DONE; fi

if CASE 'commit: a Merge subject, two lines, control characters (C0, DEL, C1, bidi), bad UTF-8, an empty and a long message are refused'; then
fx mg2; bump; PREFN=msg_run
for MSGRAW in "Merge branch 'work/x'\n" 'Merge branch x\n' 'Merge a thing\n' 'one\ntwo\n' 'a\tb\n' 'a\x7fb\n' 'a\x01b\n' 'a\xc3\n' 'a\xc0\x80\n' 'a\xed\xa0\x80\n' 'a\xf4\x90\x80\x80\n' '\n' 'a\r\n' "$(head -c 201 /dev/zero | tr '\0' 'a')\\n" \
  'a\xc2\x80b\n' 'a\xc2\x85b\n' 'a\xc2\x9fb\n' 'a\xe2\x80\xaab\n' 'a\xe2\x80\xacb\n' 'a\xe2\x80\xaeb\n' 'a\xe2\x81\xa6b\n' 'a\xe2\x81\xa8b\n' 'a\xe2\x81\xa9b\n'; do
  tw commit "P=$P" I=main "checkout=$CO" run=none
  chk "refused: ${MSGRAW:0:24}" stop_is args; chk "main unmoved: ${MSGRAW:0:24}" eq "$(tip main)" "$P"
done
PREFN=''
DONE; fi

pa_run() { printf '%s\n' "${PALINES[@]}" > "$ARGS/paths"; }
if CASE 'commit: paths with spaces, non-ASCII and + @ , ( ) are accepted'; then
fx pa; P=$(tip main); U=$(printf '\xc3\xbcn\xc3\xaf.txt')
mkdir -p "$WT/dir with space"; printf 'a\n' > "$WT/dir with space/a b.txt"; printf 'b\n' > "$WT/x+y@z,(1).txt"; printf 'c\n' > "$WT/$U"
PALINES=('dir with space/a b.txt' 'x+y@z,(1).txt' "$U"); PREFN=pa_run; tw commit "P=$P" I=main "checkout=$CO" run=none; PREFN=''
chk committed has '^git tripwire: tip [0-9a-f]{40}$'
chk 'exactly those three paths' eq "$(hg diff --name-only -z "$P" main | tr '\0' '\n' | LC_ALL=C sort | tr '\n' '|')" "$(printf '%s\n' "${PALINES[@]}" | LC_ALL=C sort | tr '\n' '|')"
DONE; fi

if CASE 'commit: control characters, a backslash, a leading quote or dash, empty and dot segments and .git in any case are refused'; then
fx pb; P=$(tip main)
for bad in '../x' '.git/config' '.GIT/config' 'a/.Git/b' '-x' '/abs' 'a//b' 'a/' $'a\tb' 'a\b' '"q"' '.' 'a/./b' 'a/../b'; do
  PALINES=("$bad"); PREFN=pa_run; tw commit "P=$P" I=main "checkout=$CO" run=none; PREFN=''
  chk "refused: $bad" stop_is args; chk "main unmoved: $bad" eq "$(tip main)" "$P"
done
PALINES=(':(top,glob)**'); PREFN=pa_run; tw commit "P=$P" I=main "checkout=$CO" run=none; PREFN=''
chk 'a magic-looking name is only a literal, so git add finds no such file' stop_is commit; chk 'main unmoved' eq "$(tip main)" "$P"
DONE; fi

# ---------------------------------------------------------------- the tools and the git version
if CASE 'call: git older than 2.45.3 stops, 2.45.3 and later run'; then
fx v1
TWENV=(SHIMVERSION=2.45.2); tw check-checkout "checkout=$CO" run=none; chk '2.45.2' stop_is call; chk 'no checkout call' nocall
TWENV=(SHIMVERSION=2.44.9); tw check-checkout "checkout=$CO" run=none; chk '2.44.9' stop_is call
TWENV=(SHIMVERSION=1.9.0); tw check-checkout "checkout=$CO" run=none; chk '1.9.0' stop_is call
TWENV=(SHIMVERSION=nonsense); tw check-checkout "checkout=$CO" run=none; chk 'unparsable' stop_is call
TWENV=(SHIMVERSION=2.45.3.windows.1); tw check-checkout "checkout=$CO" run=none; chk '2.45.3 runs' rc_is 0
TWENV=(SHIMVERSION=3.0.0); tw check-checkout "checkout=$CO" run=none; chk '3.0.0 runs' rc_is 0
TWENV=()
DONE; fi

if CASE 'call: a gawk that is not GNU Awk stops'; then
fx v2; mkdir -p "$T/shim2"; printf '#!/bin/sh\necho "mawk 1.3.4"\n' > "$T/shim2/gawk"; chmod +x "$T/shim2/gawk"
TWPATH="$T/shim2:$SHIM:/usr/bin:/mingw64/bin"; tw check-checkout "checkout=$CO" run=none; TWPATH=''
chk 'stop call' stop_is call; chk 'no checkout call' nocall
DONE; fi

if CASE 'step 0: a global reference-transaction config hook does not run at the reference repo init'; then
fx ig; mkdir -p "$T/ig/mk" "$T/ig/home"; M=$(cygpath -m "$T/ig/mk")
printf '[user]\n\tname = Test User\n\temail = test@example.invalid\n[core]\n\tautocrlf = false\n[hook "g"]\n\tcommand = touch %s/g\n\tevent = reference-transaction\n' "$M" > "$T/ig/home/.gitconfig"
TWHOME=$T/ig/home; tw check-checkout "checkout=$CO" run=none; TWHOME=$HOME1
chk 'a check runs' rc_is 0; chk 'no marker' bash -c "[ -z \"\$(ls '$T/ig/mk')\" ]"
HOME=$T/ig/home git init -q --template= "$T/ig/ctl" >/dev/null 2>&1
chk 'control: a plain git init runs the hook' [ -e "$T/ig/mk/g" ]
DONE; fi

# ---------------------------------------------------------------- build 3: part 3 first, the hand-made merge, link aliases, the reference repo, config commands, records
mdrv() { # <name>: a fixture whose m.txt is edited on both sides; sets S and P; a driver script in $T/<name>/drv.sh
  fx "$1"; mkdir -p "$T/$1/mk"; M=$(cygpath -m "$T/$1/mk")
  printf '#!/bin/sh\ntouch "%s/drv"\nexit 1\n' "$M" > "$T/$1/drv.sh"; chmod +x "$T/$1/drv.sh"
  printf 'a\nb\nc\n' > "$WT/m.txt"; hg add m.txt; hg commit -qm 'add m'
  S=$(mkunit work/u1 $'100644:m.txt:A\nb\nc\n'); printf 'a\nb\nC\n' > "$WT/m.txt"; hg commit -qam 'edit m'; P=$(tip main)
}

if CASE 'check-unit: part 3 holds before the unit is read; a merge driver named in config runs nothing, and a clean filter at renormalize runs nothing'; then
mdrv p3a
git -C "$WT" config merge.x.driver "$(cygpath -m "$T/p3a/drv.sh") %A %O %B"; printf '* merge=x\n' > "$GD/info/attributes"
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none
chk rc rc_is 0; chk 'the config key line' has '^config key merge\.<masked>\.driver#[0-9a-f]{8}\$ [0-9a-f]{64}$'; chk 'the info/attributes line' has '^info file info/attributes\$ [0-9a-f]{64}$'
chk 'the note' has '^git tripwire: note: part 3 holds; parts 1-2 were not read$'; chk 'no merge-tree call was made' nolog 'merge-tree'; chk 'no driver ran' absent_f "$T/p3a/mk/drv"
chk 'no part 1-2 line is printed' hasnt '^(git file|claude file|symlink|gitlink|short name|hook framework file|editor file) '
git -C "$WT" merge-tree --write-tree --no-messages "$P" "$S" >/dev/null 2>&1
chk 'control: plain merge-tree runs the driver the same config names' [ -e "$T/p3a/mk/drv" ]
mdrv p3b; mkdir -p "$T/p3b/mk"
printf '#!/bin/sh\ntouch "%s/clean"\ncat\n' "$M" > "$T/p3b/clean.sh"; chmod +x "$T/p3b/clean.sh"
git -C "$WT" config merge.renormalize true; git -C "$WT" config filter.y.clean "$(cygpath -m "$T/p3b/clean.sh")"; printf '* filter=y\n' > "$GD/info/attributes"
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none
chk 'the note, for the filter too' has '^git tripwire: note: part 3 holds; parts 1-2 were not read$'; chk 'no merge-tree call was made' nolog 'merge-tree'; chk 'no clean filter ran' absent_f "$T/p3b/mk/clean"
git -C "$WT" merge-tree --write-tree --no-messages "$P" "$S" >/dev/null 2>&1
chk 'control: plain merge-tree runs the clean filter at renormalize' [ -e "$T/p3b/mk/clean" ]
DONE; fi

if CASE 'check-unit: once part 3 is released it reads parts 1-2; with no part 3 line it does not hold'; then
fx p3c; hg config core.zzflag 7; S=$(mkunit work/u1 '100644:.husky/pre-commit:x'); P=$(tip main)
rel_unit u1-1 "$S" "$P"
chk 'released: no note' hasnt '^git tripwire: note: part 3 holds'; chk 'the part 3 line is printed' has '^config key core\.zzflag#'; chk 'and the part 1-2 line' has '^hook framework file \.husky/pre-commit\$ '
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; chk 'unreleased: the note' has '^git tripwire: note: part 3 holds; parts 1-2 were not read$'; chk 'and no part 1-2 line' hasnt '^hook framework file '
fx p3d; S=$(mkunit work/u1 '100644:.husky/pre-commit:x'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; chk 'no part 3 line: no note' hasnt '^git tripwire: note:'; chk 'the part 1-2 line' has '^hook framework file \.husky/pre-commit\$ '
DONE; fi

if CASE 'S1: a released merge driver and a released clean filter run nothing at merge-tree; the call stops merge'; then
mdrv s1a
git -C "$WT" config merge.x.driver "$(cygpath -m "$T/s1a/drv.sh") %A %O %B"; printf '* merge=x\n' > "$GD/info/attributes"
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; L=$(hitlines); mkrun u1-1 "$L" '' "$L"
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=u1-1; chk 'check-unit: stop merge (the blanked driver cannot run)' stop_is merge; chk 'no driver ran' absent_f "$T/s1a/mk/drv"
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk 'merge-unit: stop merge' stop_is merge; chk 'main unmoved' [ "$(tip main)" = "$P" ]; chk 'no driver ran' absent_f "$T/s1a/mk/drv"
mdrv s1b
printf '#!/bin/sh\ntouch "%s/clean"\ncat\n' "$M" > "$T/s1b/clean.sh"; chmod +x "$T/s1b/clean.sh"
git -C "$WT" config merge.renormalize true; git -C "$WT" config filter.y.clean "$(cygpath -m "$T/s1b/clean.sh")"; printf '* filter=y\n' > "$GD/info/attributes"
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; L=$(hitlines); mkrun u1-1 "$L" '' "$L"
# the blanked clean filter cannot run at merge-tree (no marker); the filter check then stops the call, as the merged file names the driver
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=u1-1; chk 'check-unit: no clean filter ran at merge-tree' absent_f "$T/s1b/mk/clean"; chk 'check-unit says in advance that merge-unit will stop' has '^git tripwire: note: 1 path\(s\) the merge would write name a filter driver the config defines; merge-unit will stop \(merge\)$'
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk 'merge-unit: stop merge, nothing moved' stop_is merge; chk 'no clean filter ran' absent_f "$T/s1b/mk/clean"; chk 'main unmoved' [ "$(tip main)" = "$P" ]
git -C "$WT" merge-tree --write-tree --no-messages "$P" "$S" >/dev/null 2>&1; chk 'control: plain merge-tree runs the clean filter with the same config' [ -e "$T/s1b/mk/clean" ]
DONE; fi

smudge_fixture() { # <name>: main tracks *.txt filter=demo; a unit adds b.txt; the local config has a smudge filter that leaves a marker
  fx "$1"; mkdir -p "$T/$1/mk"; M=$(cygpath -m "$T/$1/mk")
  printf '*.txt filter=demo\n' > "$WT/.gitattributes"; hg add .gitattributes; hg commit -qm attrs
  S=$(mkunit work/u1 '100644:b.txt:x'); P=$(tip main)
  printf '#!/bin/sh\ntouch "%s/smudge"\ncat\n' "$M" > "$T/$1/sm.sh"; chmod +x "$T/$1/sm.sh"
  git -C "$WT" config filter.demo.smudge "$(cygpath -m "$T/$1/sm.sh")"
}
if CASE 'S1: a smudge filter (required or not) runs nothing at read-tree -u, and the call stops before anything moves (control: plain read-tree runs it, and the blanked required one dies after the dry run passed)'; then
smudge_fixture s1c
rel_unit u1-1 "$S" "$P"; chk 'the filter key is a part 3 line' has '^config key filter\.<masked>\.smudge#'
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=u1-1; chk 'check-unit says in advance that merge-unit will stop' has '^git tripwire: note: 1 path\(s\) the merge would write name a filter driver the config defines; merge-unit will stop \(merge\)$'
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1
chk 'stop merge' stop_is merge; chk 'nothing moved' has "^git tripwire: note: nothing moved: 1 path\\(s\\) the merge would write name a filter driver the config defines; refs/heads/main is still at $P\$"
chk 'main unmoved' [ "$(tip main)" = "$P" ]; chk 'b.txt did not arrive' absent_f "$WT/b.txt"; chk 'no smudge ran' absent_f "$T/s1c/mk/smudge"
smudge_fixture s1d; git -C "$WT" read-tree -m -u "$P" "$S" >/dev/null 2>&1
chk 'control: plain read-tree -m -u runs the smudge filter' [ -e "$T/s1d/mk/smudge" ]
smudge_fixture s1e; git -C "$WT" config filter.demo.required true
rel_unit u1-1 "$S" "$P"
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1
chk 'a required filter: stop merge' stop_is merge; chk 'no smudge ran' absent_f "$T/s1e/mk/smudge"
chk 'nothing moved: the note says so' has "^git tripwire: note: nothing moved: 1 path\\(s\\) the merge would write name a filter driver the config defines; refs/heads/main is still at $P\$"; chk 'main unmoved' [ "$(tip main)" = "$P" ]; chk 'b.txt did not arrive' absent_f "$WT/b.txt"
git -C "$WT" -c filter.demo.smudge= read-tree -m -u -n "$P" "$S" >/dev/null 2>&1 && DRY=0 || DRY=$?
git -C "$WT" -c filter.demo.smudge= read-tree -m -u "$P" "$S" >/dev/null 2>&1 && REAL=0 || REAL=$?
chk 'control: with the smudge blanked, the dry run passes' eq "$DRY" 0; chk 'control: and the real read-tree dies (so a dry run alone cannot see a required filter)' bash -c "[ '$REAL' != 0 ]"
DONE; fi

crcount() { tr -cd '\r' < "$1" | wc -c | tr -d ' '; }
if CASE 'attr-source: the unit own new .gitattributes drives no eol at read-tree -u, an untracked one no union merge at merge-tree and no text conversion at add'; then
fx as1; S=$(mkunit work/u1 '100644:.gitattributes:*.txt eol=crlf' $'100644:f1.txt:x\ny\n'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; L=$(hitlines); mkrun u1-1 "$L" '' "$L"; chk 'its .gitattributes is a part 2 hit' has '^git file \.gitattributes\$ '
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1
chk merged has '^git tripwire: tip [0-9a-f]{40}$'; chk 'f1.txt was written with LF' eq "$(crcount "$WT/f1.txt")" 0; chk 'and .gitattributes arrived' [ -f "$WT/.gitattributes" ]
fx as2; S=$(mkunit work/u1 '100644:.gitattributes:*.txt eol=crlf' $'100644:f1.txt:x\ny\n'); git -C "$WT" merge -q --no-ff --no-edit "$S" >/dev/null 2>&1
chk 'control: plain git merge writes f1.txt with CRLF' eq "$(crcount "$WT/f1.txt")" 2
fx as3; printf 'a\nb\nc\n' > "$WT/m.txt"; hg add m.txt; hg commit -qm 'add m'
S=$(mkunit work/u1 $'100644:m.txt:A\nb\nc\n'); printf 'X\nb\nc\n' > "$WT/m.txt"; hg commit -qam 'edit m'; P=$(tip main); printf '* merge=union\n' > "$WT/.gitattributes"
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none; chk 'the same line edited on both sides is a conflict, not a union: stop merge' stop_is merge
git -C "$WT" merge-tree --write-tree --no-messages "$P" "$S" >/dev/null 2>&1 && MTRC=0 || MTRC=$?; chk 'control: plain merge-tree takes the untracked union attribute (no conflict)' eq "$MTRC" 0
fx as4; printf 'readme\r\nmore\r\n' > "$WT/README"; printf 'README text\n' > "$WT/.gitattributes"; P=$(tip main)
PREFN=cpaths5; tw commit "P=$P" I=main "checkout=$CO" run=none; PREFN=''
chk committed has '^git tripwire: tip [0-9a-f]{40}$'; chk 'the blob keeps its CR bytes (no text attribute applied)' bash -c "[ \"\$(git -C '$WT' cat-file -p 'main:README' | tr -cd '\\r' | wc -c | tr -d ' ')\" = 2 ]"
fx as5; printf 'readme\r\nmore\r\n' > "$WT/README"; printf 'README text\n' > "$WT/.gitattributes"; git -C "$WT" add README >/dev/null 2>&1
chk 'control: plain git add applies it (the staged blob has no CR)' bash -c "[ \"\$(git -C '$WT' cat-file -p ':README' | tr -cd '\\r' | wc -c | tr -d ' ')\" = 0 ]"
DONE; fi

if CASE 'hold: a worktree config file and extensions.worktreeConfig are never released, with both released'; then
fx wc; hg config extensions.worktreeConfig true; printf '[hook "wx"]\n\tcommand = touch %s/wc/marker\n\tevent = post-merge\n' "$T" > "$GD/config.worktree"
S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none
chk 'the worktree config line' has '^worktree config config\.worktree\$ [0-9a-f]{64}$'; chk 'the extensions key line' has '^config key extensions\.worktreeconfig#[0-9a-f]{8}\$ '
L=$(hitlines); mkrun u1-1 "$L" '' "$L"
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=u1-1; chk 'check-unit holds even with both released' has '^git tripwire: note: part 3 holds; parts 1-2 were not read$'
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk 'merge-unit stops expected, though both are released' stop_is expected; chk 'main unmoved' [ "$(tip main)" = "$P" ]
chk 'the hook in config.worktree ran nowhere' absent_f "$T/wc/marker"
fx wc2; printf '[core]\n\tbare = false\n' > "$GD/config.worktree"; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; chk 'a config.worktree alone: one part 3 line' ncount_is '^(worktree config|config key) ' 1; chk 'it is the worktree config line' has '^worktree config config\.worktree\$ '
L=$(hitlines); mkrun u1-1 "$L" '' "$L"
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk 'the worktree config alone, released: stop expected' stop_is expected; chk 'main unmoved' [ "$(tip main)" = "$P" ]
fx wc3; hg config extensions.worktreeConfig true; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; chk 'the extensions key alone: one part 3 line' ncount_is '^(worktree config|config key) ' 1; chk 'it is the extensions key line' has '^config key extensions\.worktreeconfig#'
L=$(hitlines); mkrun u1-1 "$L" '' "$L"
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk 'the extensions key alone, released: stop expected' stop_is expected; chk 'main unmoved' [ "$(tip main)" = "$P" ]
DONE; fi

# the merge is built by hand: the tree is the merge-tree result whatever merge config says
mo_fixture() { # <name> <config key> <value>: a unit deletes .claude/settings.json and adds a root settings.json; sets S P and WANT, the plain merge-tree tree
  fx "$1"; S=$(mkunit work/u1 'del:.claude/settings.json' '100644:settings.json:{"unit":1}'); P=$(tip main)
  git -C "$WT" config "$2" "$3"
  WANT=$(hg merge-tree --write-tree --no-messages "$P" "$S")
}
mo_script() { # <name> <config key> <value>
  mo_fixture "$1" "$2" "$3"
  rel_unit u1-1 "$S" "$P"
  tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1
  chk "$2: it lands" has '^git tripwire: tip [0-9a-f]{40}$'
  chk "$2: the tree is exactly the merge-tree tree" eq "$(hg rev-parse 'main^{tree}')" "$WANT"
  chk "$2: the unit's root settings.json is at the root, and .claude/settings.json is gone" bash -c "[ -f '$WT/settings.json' ] && [ ! -e '$WT/.claude/settings.json' ]"
  chk "$2: the parents are P and S" bash -c "[ \"\$(git -C '$WT' rev-parse main^1)\" = '$P' ] && [ \"\$(git -C '$WT' rev-parse main^2)\" = '$S' ]"
  chk "$2: no merge is left pending" absent_f "$GD/MERGE_HEAD"; chk "$2: the index matches the new tip" bash -c "git -C '$WT' diff --cached --quiet && git -C '$WT' diff --quiet"
}
if CASE 'merge: branch.main.mergeOptions -Xsubtree, -s ours, --no-commit and pull.twohead=ours change nothing: the tree is exactly the merge-tree tree'; then
mo_script mo1 branch.main.mergeoptions -Xsubtree=.claude
mo_script mo2 branch.main.mergeoptions '-s ours'
mo_script mo3 branch.main.mergeoptions --no-commit
mo_script mo4 pull.twohead ours
DONE; fi

if CASE 'control: plain git merge with those settings lands another tree, or leaves the merge pending'; then
mo_fixture mc1 branch.main.mergeoptions -Xsubtree=.claude; git -C "$WT" merge -q --no-ff --no-edit "$S" >/dev/null 2>&1
chk '-Xsubtree: another tree' bash -c "[ \"\$(git -C '$WT' rev-parse 'main^{tree}')\" != '$WANT' ]"
mo_fixture mc2 branch.main.mergeoptions '-s ours'; git -C "$WT" merge -q --no-ff --no-edit "$S" >/dev/null 2>&1
chk '-s ours: another tree' bash -c "[ \"\$(git -C '$WT' rev-parse 'main^{tree}')\" != '$WANT' ]"
mo_fixture mc3 branch.main.mergeoptions --no-commit; git -C "$WT" merge -q --no-ff --no-edit "$S" >/dev/null 2>&1
chk '--no-commit: MERGE_HEAD is left' [ -e "$GD/MERGE_HEAD" ]
mo_fixture mc4 pull.twohead ours; git -C "$WT" merge -q --no-ff --no-edit "$S" >/dev/null 2>&1
chk 'pull.twohead=ours: another tree' bash -c "[ \"\$(git -C '$WT' rev-parse 'main^{tree}')\" != '$WANT' ]"
DONE; fi

if CASE 'merge-handsoff: branch.main.mergeOptions -s ours changes nothing either'; then
fx moh; hg checkout -q -b devhouse/hands-off; Ps=$(mkunit devhouse/hands-off 'del:.claude/settings.json' '100644:settings.json:{"unit":1}'); hg checkout -q main
Pt=$(tip main); git -C "$WT" config branch.main.mergeoptions '-s ours'; WANT=$(hg merge-tree --write-tree --no-messages "$Pt" "$Ps")
tw merge-handsoff "Pt=$Pt" "Ps=$Ps" from=devhouse/hands-off to=main "checkout=$CO" run=none; L=$(hitlines); mkrun h-1 "$L" '' "$L"
tw merge-handsoff "Pt=$Pt" "Ps=$Ps" from=devhouse/hands-off to=main "checkout=$CO" run=h-1; L=$(hitlines); mkrun h-1 "$L" '' "$L"
tw merge-handsoff "Pt=$Pt" "Ps=$Ps" from=devhouse/hands-off to=main "checkout=$CO" run=h-1
chk lands has '^git tripwire: tip [0-9a-f]{40}$'; chk 'the tree is exactly the merge-tree tree' eq "$(hg rev-parse 'main^{tree}')" "$WANT"; chk 'subject' eq "$(hg log -1 --format=%s main)" "Merge branch 'devhouse/hands-off'"
DONE; fi

if CASE 'unit: an untracked junction in the work tree that aliases .claude stops the call, with or without info/exclude (control: plain git lands in .claude)'; then
fx al; mkjunc "$WT/foo" "$WT/.claude"; chk 'the junction is there' [ -L "$WT/foo" ]
S=$(mkunit work/u1 '100644:foo/settings.local.json:{"u":1}'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; chk 'check-unit: stop unit' stop_is unit; chk 'check-unit: no merge-tree call was made (the check comes first)' nolog 'merge-tree'
chk 'the note names the folder, escaped' has '^git tripwire: note: the leading folder foo\$ is a link in the checkout$'
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none; chk 'merge-unit: stop unit' stop_is unit; chk 'merge-unit: no merge-tree call was made' nolog 'merge-tree'; chk 'main unmoved' [ "$(tip main)" = "$P" ]; chk 'nothing landed in .claude' absent_f "$WT/.claude/settings.local.json"
printf 'foo\n' >> "$GD/info/exclude"
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none; chk 'excluded: stop unit' stop_is unit; chk 'excluded: main unmoved' [ "$(tip main)" = "$P" ]; chk 'excluded: nothing landed' absent_f "$WT/.claude/settings.local.json"
tw check-checkout "checkout=$CO" run=none; chk 'the junction is no hit, so no part-3 line shows it' nohits
S2=$(mkunit work/u2 '100644:FOO/settings.local.json:{"u":2}'); tw merge-unit "S=$S2" "P=$P" u=u2 I=main "checkout=$CO" run=none; chk 'a different case of the folder name: stop unit' stop_is unit
mkdir -p "$WT/nest"; mkjunc "$WT/nest/deep" "$WT/.claude"; S3=$(mkunit work/u3 '100644:nest/deep/settings.local.json:{"u":3}')
tw merge-unit "S=$S3" "P=$P" u=u3 I=main "checkout=$CO" run=none; chk 'a junction two levels down: stop unit' stop_is unit; chk 'nothing landed' absent_f "$WT/.claude/settings.local.json"
S4=$(mkunit work/u4 '100644:other/x:fine'); tw merge-unit "S=$S4" "P=$P" u=u4 I=main "checkout=$CO" run=none; chk 'a unit with no path behind the junction merges (the junction foo still stands, and lead_walk ran on other/x)' has '^git tripwire: tip [0-9a-f]{40}$'; chk 'other/x arrived' [ -f "$WT/other/x" ]
rmjunc "$WT/foo"; rmjunc "$WT/nest/deep"
fx al2; mkjunc "$WT/foo" "$WT/.claude"; S=$(mkunit work/u1 '100644:foo/settings.local.json:{"u":1}'); git -C "$WT" merge -q --no-ff --no-edit "$S" >/dev/null 2>&1
chk 'control: plain git merge writes the file into .claude/' [ -f "$WT/.claude/settings.local.json" ]
rmjunc "$WT/foo"
DONE; fi

if CASE 'commit: a path behind a junction that aliases .claude is refused with unit, with or without info/exclude'; then
fx alc; mkjunc "$WT/foo" "$WT/.claude"; printf 'x\n' > "$WT/foo/new.txt"; P=$(tip main)
cpaths_foo() { printf 'foo/new.txt\n' > "$ARGS/paths"; }
PREFN=cpaths_foo; tw commit "P=$P" I=main "checkout=$CO" run=none; chk 'stop unit' stop_is unit; chk 'main unmoved' [ "$(tip main)" = "$P" ]
chk 'the note names the folder' has '^git tripwire: note: the leading folder foo\$ is a link in the checkout$'
chk 'a commit stop before update-ref says nothing moved' has "^git tripwire: note: nothing moved: refs/heads/main is still at $P\$"
printf 'foo\n' >> "$GD/info/exclude"; tw commit "P=$P" I=main "checkout=$CO" run=none; chk 'excluded: stop unit' stop_is unit; chk 'excluded: main unmoved' [ "$(tip main)" = "$P" ]
PREFN=''; rmjunc "$WT/foo"
DONE; fi

if CASE 'step 0: global includeIf gitdir hooks do not run at the reference repo init, and a global init.defaultRefFormat does not skew it'; then
fx ib; mkdir -p "$T/ib/mk" "$T/ib/home"; M=$(cygpath -m "$T/ib/mk"); HH=$(cygpath -m "$T/ib/home")
printf '[hook "r"]\n\tcommand = touch %s/ref\n\tevent = reference-transaction\n' "$M" > "$T/ib/home/inc-ref.gitconfig"
printf '[hook "w"]\n\tcommand = touch %s/work\n\tevent = reference-transaction\n' "$M" > "$T/ib/home/inc-work.gitconfig"
printf '[user]\n\tname = Test User\n\temail = test@example.invalid\n[core]\n\tautocrlf = false\n[init]\n\tdefaultRefFormat = reftable\n[includeIf "gitdir:**/ref/"]\n\tpath = %s/inc-ref.gitconfig\n[includeIf "gitdir/i:**/work.*/"]\n\tpath = %s/inc-work.gitconfig\n' "$HH" "$HH" > "$T/ib/home/.gitconfig"
TWHOME=$T/ib/home; tw check-checkout "checkout=$CO" run=none; TWHOME=$HOME1
chk 'a check runs' rc_is 0; chk 'no hit: the reference repo has the files ref format and its local config matches a plain checkout' nohits
chk 'neither include fired' bash -c "[ -z \"\$(ls '$T/ib/mk')\" ]"
mkdir -p "$T/ib/ctl1/ref" "$T/ib/ctl2/work.ABC"
HOME=$T/ib/home git init -q --template= "$T/ib/ctl1/ref" >/dev/null 2>&1; chk 'control: a plain init in a folder named ref fires the first hook' [ -e "$T/ib/mk/ref" ]
HOME=$T/ib/home git init -q --template= "$T/ib/ctl2/work.ABC/x" >/dev/null 2>&1; chk 'control: a plain init under work.* fires the second hook' [ -e "$T/ib/mk/work" ]
DONE; fi

if CASE 'remove: a replace ref is deleted with a local reference-transaction config hook present, which does not fire (control: plain update-ref -d fires it)'; then
fx rh; B=$(hg rev-parse main); O=$(printf 'o\n' | hg commit-tree "$(hg rev-parse 'main^{tree}')"); hg replace "$B" "$O"
mkdir -p "$T/rh/mk"; M=$(cygpath -m "$T/rh/mk"); git -C "$WT" config hook.rt.command "touch $M/rt"; git -C "$WT" config hook.rt.event reference-transaction
tw check-checkout "checkout=$CO" run=none; L=$(hitline '^replace ref'); chk 'a replace ref hit' eq "$([ -n "$L" ] && echo y)" y; chk 'and the hook line' has '^config key hook\.<masked>\.command#'
sel_rm 'replace ref' "$L"; chk removed has '^git tripwire: removed replace ref$'; chk 'the ref is gone' bash -c "[ -z \"\$(git -C '$WT' for-each-ref refs/replace/)\" ]"; chk 'the hook did not fire' absent_f "$T/rh/mk/rt"
rm -f -- "$T/rh/mk/rt"; hg replace "$B" "$O"; rm -f -- "$T/rh/mk/rt"
git -C "$WT" update-ref -d "refs/replace/$B" >/dev/null 2>&1; chk 'control: a plain update-ref -d fires the hook' [ -e "$T/rh/mk/rt" ]
DONE; fi

if CASE "remove: a junction named it's (a quote) is made, listed, removed by the script, and unlinked by the harness helpers"; then
fx jq; mkdir -p "$T/jq/target"; printf 'k\n' > "$T/jq/target/k"; mkjunc "$GD/it's" "$T/jq/target"
chk 'the junction exists' [ -L "$GD/it's" ]
tw check-checkout "checkout=$CO" run=none; L=$(hitline "^git dir link it's\\\$ "); chk 'a hit' eq "$([ -n "$L" ] && echo y)" y
sel_rm 'git dir link' "$L"; chk removed has '^git tripwire: removed git dir link$'; chk 'the junction is gone' absent_f "$GD/it's"; chk 'the target is intact' [ -f "$T/jq/target/k" ]
mkjunc "$GD/it's" "$T/jq/target"; rmjunc "$GD/it's"; chk 'rmjunc unlinks it too' absent_f "$GD/it's"; chk 'and the target is intact' [ -f "$T/jq/target/k" ]
DONE; fi

if CASE 'remove: a linked worktrees/<id> is unlinked, and its target kept'; then
fx wl; hg worktree add -q "$T/wl/wt-u1" -b work/u1 2>/dev/null
mv "$GD/worktrees/wt-u1" "$T/wl/entry.copy"; mkjunc "$GD/worktrees/wt-u1" "$T/wl/entry.copy"
tw check-checkout "checkout=$CO" run=none; L=$(hitline '^worktree link worktrees/wt-u1\$ '); chk 'a hit' eq "$([ -n "$L" ] && echo y)" y
sel_rm 'worktree link' "$L"; chk removed has '^git tripwire: removed worktree link$'; chk 'the junction is gone' absent_f "$GD/worktrees/wt-u1"; chk 'the entry copy is intact' [ -f "$T/wl/entry.copy/gitdir" ]
DONE; fi

if CASE 'remove: select and remove take an id with escaped bytes (a non-ASCII hook name) exactly as the hit line prints it'; then
fx es; U=$(printf 'pr\xc3\xa9-commit'); printf 'A\n' > "$GD/hooks/$U"
tw check-checkout "checkout=$CO" run=none; L=$(hitline '^hook hooks/pr\\303\\251-commit\$ '); chk 'the id is printed escaped' eq "$([ -n "$L" ] && echo y)" y
sel_rm hook "$L"; chk 'select prints the escaped id' selhas '^git tripwire: id hooks/pr\\303\\251-commit\$$'; chk removed has '^git tripwire: removed hook$'; chk 'the file is gone' absent_f "$GD/hooks/$U"
DONE; fi

rmkey() { # <regex of the key as printed>: removes that config key through select and remove
  local l
  tw check-checkout "checkout=$CO" run=none
  l=$(hitline "^config key $1#"); [ -n "$l" ] || { FAILMSG+="[no hit for $1] "; return; }
  sel_rm 'config key' "$l"
}
if CASE 'remove: raw records are saved as <date>-<n>.config only when neither the key nor a value may hold a credential'; then
fx rs
hg config core.abbrev 12; hg config core.zzmsg 'https://user:PWHOST@host.invalid/x'; hg config core.mytoken ABCVALUE
hg config core.zzhdr 'Authorization: Bearer XYZSECRET'; hg config core.zzpassword HUNTER2; hg config core.zzextraheader EXTRAVALUE; hg config credential.username BOBCRED
hg config 'url.https://plain.invalid/.insteadOf' 'https://other.invalid/'; hg config http.sslverify false # no credential word in either record: only the section rule stops the save
tw check-checkout "checkout=$CO" run=none
rmkey 'core\.abbrev'; chk 'the benign key is removed' has '^git tripwire: removed config key$'
chk 'its record is saved as <date>-1.config, key and value, NUL-ended' bash -c "cmp -s '$TWP/removed/$D-1.config' <(printf 'core.abbrev\n12\0')"
chk 'index.txt has the line written before the save and the one after' bash -c "grep -qF 'config key core.abbrev#' '$TWP/removed/index.txt' && grep -qF 'saving 1 records to $D-1.config' '$TWP/removed/index.txt' && grep -qF 'edited; records saved to $D-1.config' '$TWP/removed/index.txt'"
for k in 'core\.zzmsg' 'core\.mytoken' 'core\.zzhdr' 'core\.zzpassword' 'core\.zzextraheader' 'credential\.username' 'url\.<masked>\.insteadof' 'http\.sslverify'; do
  rmkey "$k"; chk "removed: $k" has '^git tripwire: removed config key$'
done
chk 'only the one .config exists' bash -c "[ \"\$(ls '$TWP/removed' | grep -c '\\.config\$')\" = 1 ]"
chk 'no value of a credential-looking record is anywhere in removed/ or in the output' bash -c "[ -z \"\$(grep -rlE 'PWHOST|ABCVALUE|XYZSECRET|HUNTER2|EXTRAVALUE|BOBCRED' '$TWP/removed' 2>/dev/null)\" ]"
chk 'eight lines say not saved' bash -c "[ \"\$(grep -c 'not saved: may hold a credential; restore by hand' '$TWP/removed/index.txt')\" = 8 ]"
chk 'a line keeps the record count and the salted hash of the record' bash -c "grep -qF 'edited; not saved: may hold a credential; restore by hand; records: 1; salted hashes: $(sha_str $'core.zzhdr\nAuthorization: Bearer XYZSECRET')' '$TWP/removed/index.txt'"
tw check-checkout "checkout=$CO" run=none; chk 'the next check is clean' nohits
printf 'A\n' > "$GD/hooks/pre-commit"; tw check-checkout "checkout=$CO" run=none; L=$(hitline '^hook hooks/pre-commit'); sel_rm hook "$L"
chk 'a moved item takes the next number: <date>-2, and <date>-1 is not reused' bash -c "[ -e '$TWP/removed/$D-2' ] && [ ! -e '$TWP/removed/$D-1' ]"
DONE; fi

if [ "$HAVE_ACL" = 1 ]; then
if CASE 'remove: a record that cannot be saved leaves the key in place, the index line before it, and no slot'; then
fx rf; hg config core.abbrev 12; hg config core.zzother 3
tw check-checkout "checkout=$CO" run=none
rmkey 'core\.zzother'; chk 'the first removal works (so index.txt exists)' has '^git tripwire: removed config key$'
ACLFIX+=("$TWP/removed"); acl_deny "$TWP/removed" 'WD,AD'
rmkey 'core\.abbrev'; RF_RC=$RC; RF_OUT=$OUT; acl_reset "$TWP/removed"; OUT=$RF_OUT; RC=$RF_RC
chk 'stop remove' stop_is remove; chk 'the key is still set' bash -c "[ \"\$(git -C '$WT' config --local core.abbrev)\" = 12 ]"
chk 'the index line was written before the save, for the second slot (the first removal wrote the first)' bash -c "grep -qF 'saving 1 records to $D-2.config' '$TWP/removed/index.txt'"
chk 'it also says the save failed' bash -c "grep -qF 'save failed; nothing was removed' '$TWP/removed/index.txt'"
chk 'no half-written slot is left' bash -c "[ \"\$(ls '$TWP/removed' | grep -c '\\.config\$')\" = 1 ]"
DONE; fi
else SKIP 'remove: a record that cannot be saved leaves the key in place, the index line before it, and no slot' 'prerequisite missing: an icacls deny that bites'; fi

# ---------------------------------------------------------------- build 4: submodules, NTFS names, the filter check, merge state
subfix() { # <name> <inplace|absorbed>: main has an active, populated submodule `lib` at C1; work/u1 bumps it to C2. Sets S P C1 C2 M
  local nm=$1 form=$2 src
  fx "$nm"; src=$TR/$nm/subsrc; M=$(cygpath -m "$TR/$nm/mk"); mkdir -p "$TR/$nm/mk"
  git init -q -b main "$src"
  printf '*.txt filter=demo\n' > "$src/.gitattributes"; printf 'one\n' > "$src/s.txt"
  git -C "$src" add -A >/dev/null 2>&1; git -C "$src" commit -q -m c1; C1=$(git -C "$src" rev-parse HEAD)
  printf 'two\n' > "$src/s.txt"; git -C "$src" commit -q -a -m c2; C2=$(git -C "$src" rev-parse HEAD)
  if [ "$form" = absorbed ]; then
    git -C "$WT" -c protocol.file.allow=always submodule add -q "$(cygpath -m "$src")" lib >/dev/null 2>&1
  else
    git -C "$WT" -c protocol.file.allow=always clone -q "$(cygpath -m "$src")" lib >/dev/null 2>&1
    printf '[submodule "lib"]\n\tpath = lib\n\turl = %s\n' "$(cygpath -m "$src")" > "$WT/.gitmodules"
    git -C "$WT" config submodule.lib.url "$(cygpath -m "$src")"; git -C "$WT" config submodule.lib.active true
  fi
  git -C "$WT/lib" checkout -q "$C1" >/dev/null 2>&1
  hg add .gitmodules lib >/dev/null 2>&1; hg commit -q -m 'add lib'
  S=$(mkunit work/u1 "160000:lib:$C2"); P=$(tip main)
}
subplant() { # <name>: a config hook and a smudge filter in the submodule's own config (the superproject's config knows neither)
  printf '#!/bin/sh\ntouch "%s/smudge"\ncat\n' "$M" > "$TR/$1/sm.sh"; chmod +x "$TR/$1/sm.sh"
  git -C "$WT/lib" config hook.zz.command "touch $M/subhook"; git -C "$WT/lib" config hook.zz.event reference-transaction
  git -C "$WT/lib" config filter.demo.smudge "$(cygpath -m "$TR/$1/sm.sh")"
}
subreplace() { # a replace ref in the submodule: C2 is replaced by a commit that also holds evil.txt
  local R
  git -C "$WT/lib" checkout -q -b evilb "$C2" >/dev/null 2>&1; printf 'evil\n' > "$WT/lib/evil.txt"
  git -C "$WT/lib" add evil.txt >/dev/null 2>&1; git -C "$WT/lib" commit -q -m evil; R=$(git -C "$WT/lib" rev-parse HEAD)
  git -C "$WT/lib" checkout -q "$C1" >/dev/null 2>&1; git -C "$WT/lib" branch -q -D evilb >/dev/null 2>&1
  git -C "$WT/lib" replace "$C2" "$R"
}
subnone() { # <name>: nothing ran in the submodule, and its work tree is where it was
  chk "$1: merged" has '^git tripwire: tip [0-9a-f]{40}$'; chk "$1: the gitlink moved to C2" eq "$(hg rev-parse main:lib)" "$C2"
  chk "$1: nothing ran in the submodule" bash -c "[ -z \"\$(ls '$TR/$1/mk')\" ]"; chk "$1: the submodule work tree was not touched" eq "$(git -C "$WT/lib" rev-parse HEAD)" "$C1"
  chk "$1: no evil.txt" absent_f "$WT/lib/evil.txt"
}
if CASE 'submodule.recurse=true set globally: a gitlink bump runs nothing in the submodule (a hook and a smudge filter in its own config); control: plain read-tree -m -u runs both'; then
subfix sa inplace; subplant sa; mkdir -p "$T/sa/home"; cp "$HOME1/.gitconfig" "$T/sa/home/.gitconfig"; printf '[submodule]\n\trecurse = true\n' >> "$T/sa/home/.gitconfig"
TWHOME=$T/sa/home; rel_unit u1-1 "$S" "$P"; tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; TWHOME=$HOME1
subnone sa
subfix sa2 inplace; subplant sa2; HOME=$T/sa/home git -C "$WT" read-tree -m -u "$P" "$S" >/dev/null 2>&1
chk 'control: plain read-tree -m -u runs the hook in the submodule' [ -e "$T/sa2/mk/subhook" ]; chk 'control: and its smudge filter' [ -e "$T/sa2/mk/smudge" ]
DONE; fi

if CASE 'submodule.recurse=true set locally (a releasable config key): the same, nothing runs in the submodule (control: plain read-tree -m -u runs both)'; then
subfix sb inplace; subplant sb; git -C "$WT" config submodule.recurse true
rel_unit u1-1 "$S" "$P"; chk 'submodule.recurse is a part 3 line' has '^config key submodule\.recurse#'
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; subnone sb
subfix sb2 inplace; subplant sb2; git -C "$WT" config submodule.recurse true; git -C "$WT" read-tree -m -u "$P" "$S" >/dev/null 2>&1
chk 'control: plain read-tree -m -u runs the hook in the submodule' [ -e "$T/sb2/mk/subhook" ]; chk 'control: and its smudge filter' [ -e "$T/sb2/mk/smudge" ]
DONE; fi

if CASE 'submodule.recurse=true with the submodule absorbed (.git/modules/lib): a config hook and a replace ref there act nowhere (control: plain read-tree -m -u runs the hook and writes evil.txt)'; then
subfix sc absorbed; subreplace; subplant sc; git -C "$WT" config submodule.recurse true
rel_unit u1-1 "$S" "$P"; chk 'the submodule dir line is there' has '^submodule dir modules\$ '
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; subnone sc
subfix sc2 absorbed; subreplace; subplant sc2; git -C "$WT" config submodule.recurse true; git -C "$WT" read-tree -m -u "$P" "$S" >/dev/null 2>&1
chk 'control: plain read-tree -m -u runs the hook' [ -e "$T/sc2/mk/subhook" ]; chk 'control: and the replace ref writes evil.txt into the submodule' [ -f "$WT/lib/evil.txt" ]
DONE; fi

sdline() { tw check-checkout "checkout=$CO" run=none; SDL=$(hitline '^submodule dir modules\$ '); }
if CASE 'check: the submodule dir line hashes what a submodule git dir acts on (config, hooks, info, replace refs, packed-refs replace lines) and not objects, logs, index, HEAD, other refs or samples'; then
subfix sd absorbed; MG=$GD/modules/lib
sdline; SD0=$SDL; chk 'the line is there' eq "$([ -n "$SD0" ] && echo y)" y
printf 'x\n' >> "$MG/logs/HEAD"; mkdir -p "$MG/objects/zz"; printf 'x\n' > "$MG/objects/zz/obj"; printf '%s\n' "$C2" > "$MG/refs/heads/other"; printf 'x\n' > "$MG/FETCH_HEAD"
printf 'x\n' > "$MG/hooks/post-checkout.sample"; printf '# pack-refs with: peeled fully-peeled sorted\n%s refs/heads/zz\n' "$C1" > "$MG/packed-refs"; touch "$MG/index"
sdline; chk 'objects, logs, other refs, FETCH_HEAD, a hook sample, a packed non-replace ref and the index do not change the line' eq "$SDL" "$SD0"
SDP=$SD0
printf '#!/bin/sh\n:\n' > "$MG/hooks/post-checkout"; sdline; chk 'a hook file changes it' [ "$SDL" != "$SDP" ]; SDP=$SDL
git config --file "$MG/config" zz.x 1; sdline; chk 'a config edit changes it' [ "$SDL" != "$SDP" ]; SDP=$SDL
printf '* -text\n' > "$MG/info/attributes"; sdline; chk 'an info/attributes file changes it' [ "$SDL" != "$SDP" ]; SDP=$SDL
mkdir -p "$MG/refs/replace"; printf '%s\n' "$C1" > "$MG/refs/replace/$C2"; sdline; chk 'a loose replace ref changes it' [ "$SDL" != "$SDP" ]; SDP=$SDL
printf '%s refs/replace/%s\n' "$C1" "$C1" >> "$MG/packed-refs"; sdline; chk 'a packed replace ref changes it' [ "$SDL" != "$SDP" ]; SDP=$SDL
printf '[core]\n\tbare = false\n' > "$MG/config.worktree"; sdline; chk 'a config.worktree there changes it' [ "$SDL" != "$SDP" ]
DONE; fi

# a name git refuses on Windows by default is made with core.protectNTFS=false, and then lands in .claude/ or .git/hooks/ through the name folding
ntfs_fix() { # <name> <path> <global|local>: S adds one executable file at <path>; core.protectNTFS is off in a home of its own, or locally
  fx "$1"; mkdir -p "$T/$1/home"; cp "$HOME1/.gitconfig" "$T/$1/home/.gitconfig"
  S=$(mkunit_ntfs work/u1 "$2" $'#!/bin/sh\ntrue\n'); P=$(tip main)
  if [ "$3" = global ]; then printf '[core]\n\tprotectNTFS = false\n' >> "$T/$1/home/.gitconfig"; else git -C "$WT" config core.protectNTFS false; fi
}
ntfs_case() { # <name> <path> <hit regex> <where plain git lands it, in the checkout> <global|local>
  local nm=$1
  ntfs_fix "$nm" "$2" "$5"
  if [ "$5" = global ]; then TWHOME=$T/$nm/home; fi
  rel_unit u1-1 "$S" "$P"
  chk "$nm: the spelling is a hit" has "$3"
  tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; TWHOME=$HOME1
  chk "$nm: merge-unit stops (released, git itself refuses the name at the dry run, so: merge)" stop_is merge; chk "$nm: nothing moved" has "^git tripwire: note: nothing moved: refs/heads/main is still at $P\$"; chk "$nm: no tip" hasnt '^git tripwire: tip '; chk "$nm: main unmoved" eq "$(tip main)" "$P"
  chk "$nm: nothing landed" absent_f "$WT/$4"
  ntfs_fix "${nm}c" "$2" "$5"
  if [ "$5" = global ]; then HOME=$T/${nm}c/home git -C "$WT" merge -q --no-ff --no-edit "$S" >/dev/null 2>&1; else git -C "$WT" merge -q --no-ff --no-edit "$S" >/dev/null 2>&1; fi
  if [ "${6:-}" = refused ]; then chk "$nm: control: plain git cannot create it on this git (a trailing space); the hit is the whole proof" absent_f "$WT/$4"
  else chk "$nm: control: plain git lands it as $4" [ -f "$WT/$4" ]; fi
}
if CASE 'unit: NTFS spellings of .claude and .git are hits and land nowhere, with core.protectNTFS off globally or locally (control: plain git lands each one)'; then
ntfs_case nt1 '.claude./settings.local.json' '^claude file \.claude\./settings\.local\.json\$ ' '.claude/settings.local.json' global
ntfs_case nt2 '.claude./settings.local.json' '^claude file \.claude\./settings\.local\.json\$ ' '.claude/settings.local.json' local
ntfs_case nt3 '.claude::$INDEX_ALLOCATION/settings.local.json' '^claude file \.claude::\$INDEX_ALLOCATION/settings\.local\.json\$ ' '.claude/settings.local.json' global
ntfs_case nt4 '.claude::$INDEX_ALLOCATION/settings.local.json' '^claude file \.claude::\$INDEX_ALLOCATION/settings\.local\.json\$ ' '.claude/settings.local.json' local
ntfs_case nt5 '.git./hooks/post-merge' '^git file \.git\./hooks/post-merge\$ ' '.git/hooks/post-merge' global
ntfs_case nt6 '.git./hooks/post-merge' '^git file \.git\./hooks/post-merge\$ ' '.git/hooks/post-merge' local
ntfs_case nt7 '.claude /settings.local.json' '^claude file \.claude /settings\.local\.json\$ ' '.claude/settings.local.json' global refused
ntfs_case nt8 '.claude /settings.local.json' '^claude file \.claude /settings\.local\.json\$ ' '.claude/settings.local.json' local refused
DONE; fi

if CASE 'unit: a backslash in a tree path is a separator for the classifier (.claude\settings.local.json is a claude file hit; git itself refuses it at the dry run)'; then
fx bs; S=$(mkunit_ntfs work/u1 '.claude\settings.local.json' '{"u":1}'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; chk 'the hit shows' has '^claude file \.claude\\\\settings\.local\.json\$ '
rel_unit u1-1 "$S" "$P"; tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1
chk 'merge-unit stops merge (git refuses the name at the dry run)' stop_is merge; chk 'main unmoved' eq "$(tip main)" "$P"; chk 'nothing landed in .claude' absent_f "$WT/.claude/settings.local.json"
DONE; fi

# ---------------------------------------------------------------- the merge state
if CASE 'merge: a pending merge, a staged index, or a cherry-pick, revert or rebase in progress stops merge with nothing moved (both merge modes)'; then
fx ms1; S0=$(mkunit work/side '100644:.husky/pre-commit:x'); git -C "$WT" merge -q --no-ff --no-commit "$S0" >/dev/null 2>&1
chk 'fixture: MERGE_HEAD stands and .husky/pre-commit is staged' bash -c "[ -e '$GD/MERGE_HEAD' ] && git -C '$WT' diff --cached --name-only | grep -q husky"
S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none
chk 'merge-unit: stop merge' stop_is merge; chk 'the note says nothing moved, and why' has "^git tripwire: note: nothing moved: a merge, cherry-pick, revert or rebase is pending in the checkout; refs/heads/main is still at $P\$"; chk 'main unmoved' eq "$(tip main)" "$P"
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; chk 'check-unit says in advance that merge-unit will stop' has '^git tripwire: note: a merge, cherry-pick, revert or rebase is pending in the checkout; merge-unit will stop \(merge\)$'; chk 'check-unit itself exits 0' rc_is 0
chk 'the pending merge and the staged file survive' bash -c "[ -e '$GD/MERGE_HEAD' ] && git -C '$WT' diff --cached --name-only | grep -q husky"; chk 'f1 was not written' absent_f "$WT/f1"
tw merge-handsoff "Pt=$P" "Ps=$S" from=work/u1 to=main "checkout=$CO" run=none; chk 'merge-handsoff: stop merge' stop_is merge; chk 'main unmoved' eq "$(tip main)" "$P"
fx ms2; printf 'x\n' > "$WT/staged"; hg add staged; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; chk 'check-unit predicts a staged file too' has '^git tripwire: note: the index holds staged changes; merge-unit will stop \(merge\)$'
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none; chk 'a staged file alone: stop merge' stop_is merge; chk 'and says why' has "^git tripwire: note: nothing moved: the index holds staged changes; refs/heads/main is still at $P\$"; chk 'main unmoved' eq "$(tip main)" "$P"; chk 'the staged file survives' bash -c "git -C '$WT' diff --cached --name-only | grep -qx staged"
for mk in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer; do
  fx "ms_$mk"; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
  case $mk in rebase-merge | rebase-apply | sequencer) mkdir -p "$GD/$mk" ;; *) printf '%s\n' "$P" > "$GD/$mk" ;; esac
  tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none
  chk "$mk: stop merge" stop_is merge; chk "$mk: main unmoved" eq "$(tip main)" "$P"; chk "$mk: f1 was not written" absent_f "$WT/f1"
  rm -rf -- "$GD/$mk"
  tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none; chk "$mk: control: without it the same unit merges" has '^git tripwire: tip [0-9a-f]{40}$'
done
DONE; fi

# ---------------------------------------------------------------- the filter check
filt_fixture() { # <name>: main tracks a.txt and .gitattributes (*.txt filter=demo); S adds b.txt; f.sh is a driver command that leaves a marker. Sets S P M
  fx "$1"; mkdir -p "$T/$1/mk"; M=$(cygpath -m "$T/$1/mk")
  printf '*.txt filter=demo\n' > "$WT/.gitattributes"; printf 'a\n' > "$WT/a.txt"
  hg add .gitattributes a.txt; hg commit -q -m attrs
  printf '#!/bin/sh\ntouch "%s/ran"\ncat\n' "$M" > "$T/$1/f.sh"; chmod +x "$T/$1/f.sh"
  S=$(mkunit work/u1 '100644:b.txt:x'); P=$(tip main)
}
if CASE 'filters: a path naming a driver the config defines stops merge with nothing moved (clean, smudge, process, required alone), check-unit says so first; a driver nobody names, required=false and a deleted path do not stop it'; then
for kind in clean smudge process required
do
  filt_fixture "f_$kind"
  case $kind in required) git -C "$WT" config filter.demo.required true ;; *) git -C "$WT" config "filter.demo.$kind" "$(cygpath -m "$T/f_$kind/f.sh")" ;; esac
  rel_unit u1-1 "$S" "$P"
  tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=u1-1; chk "$kind: check-unit says in advance" has '^git tripwire: note: 1 path\(s\) the merge would write name a filter driver the config defines; merge-unit will stop \(merge\)$'
  tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1
  chk "$kind: stop merge" stop_is merge; chk "$kind: nothing moved" has "^git tripwire: note: nothing moved: 1 path\\(s\\) the merge would write name a filter driver the config defines; refs/heads/main is still at $P\$"
  chk "$kind: main unmoved" eq "$(tip main)" "$P"; chk "$kind: b.txt not written" absent_f "$WT/b.txt"; chk "$kind: no driver ran" absent_f "$T/f_$kind/mk/ran"
done
filt_fixture f_rv; printf '[filter "demo"]\n\trequired\n' >> "$GD/config"; rel_unit u1-1 "$S" "$P"
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=u1-1; chk 'a valueless required key (true to git): check-unit says in advance' has '^git tripwire: note: 1 path\(s\) the merge would write name a filter driver the config defines; merge-unit will stop \(merge\)$'
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk 'a valueless required key: stop merge, main unmoved' stop_is merge; chk 'and main is unmoved' eq "$(tip main)" "$P"
filt_fixture f_other; git -C "$WT" config filter.other.clean "$(cygpath -m "$T/f_other/f.sh")"; rel_unit u1-1 "$S" "$P"
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk 'a driver the path does not name: merges' has '^git tripwire: tip [0-9a-f]{40}$'; chk 'and no driver ran' absent_f "$T/f_other/mk/ran"
filt_fixture f_req0; git -C "$WT" config filter.demo.required false; rel_unit u1-1 "$S" "$P"
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1; chk 'required=false and no command: merges' has '^git tripwire: tip [0-9a-f]{40}$'
filt_fixture f_del; git -C "$WT" config filter.demo.clean "$(cygpath -m "$T/f_del/f.sh")"; S2=$(mkunit work/u2 'del:a.txt'); rel_unit u1-1 "$S2" "$P"
tw merge-unit "S=$S2" "P=$P" u=u2 I=main "checkout=$CO" run=u1-1; chk 'a unit that only deletes a filtered path merges' has '^git tripwire: tip [0-9a-f]{40}$'; chk 'a.txt is gone' absent_f "$WT/a.txt"
DONE; fi

scrub_fixture() { # <name> <attributes file text, or '' for none in P> [local|global|defaultdir|xdgenv]: main tracks .gitattributes; a scrubbing clean filter is in the local config; or (global, defaultdir) in a home of its own with the attributes in core.attributesFile or in the default ~/.config/git/attributes (XDG_CONFIG_HOME unset); or (xdgenv) in $XDG_CONFIG_HOME/git/config and attributes, in a folder the case then exports as XDG_CONFIG_HOME (the layout nbstripout --install --global writes when there is no ~/.gitconfig filter); conf.env and conf/app.env hold a live key. Sets P
  local where=${3:-local}
  fx "$1"; mkdir -p "$T/$1/mk" "$WT/conf"
  if [ -n "$2" ]; then printf '%s\n' "$2" > "$WT/.gitattributes"; hg add .gitattributes; hg commit -q -m attrs; fi
  printf '#!/bin/sh\nsed "s/APIKEY=.*/APIKEY=REDACTED/"\n' > "$T/$1/scrub.sh"; chmod +x "$T/$1/scrub.sh"
  if [ "$where" = local ]; then git -C "$WT" config filter.scrub.clean "$(cygpath -m "$T/$1/scrub.sh")"
  elif [ "$where" = xdgenv ]; then
    mkdir -p "$T/$1/xdg/git"
    printf '[filter "scrub"]\n\tclean = %s\n' "$(cygpath -m "$T/$1/scrub.sh")" > "$T/$1/xdg/git/config"
    printf '*.env filter=scrub\n' > "$T/$1/xdg/git/attributes"
  else
    mkdir -p "$T/$1/home"; cp "$HOME1/.gitconfig" "$T/$1/home/.gitconfig"
    printf '[filter "scrub"]\n\tclean = %s\n' "$(cygpath -m "$T/$1/scrub.sh")" >> "$T/$1/home/.gitconfig"
    if [ "$where" = global ]; then
      printf '*.env filter=scrub\n' > "$T/$1/gattr"; printf '[core]\n\tattributesFile = %s\n' "$(cygpath -m "$T/$1/gattr")" >> "$T/$1/home/.gitconfig"
    else
      mkdir -p "$T/$1/home/.config/git"; printf '*.env filter=scrub\n' > "$T/$1/home/.config/git/attributes"
    fi
    TWHOME=$T/$1/home
  fi
  printf 'APIKEY=live-key-123\n' > "$WT/conf.env"; printf 'APIKEY=live-key-456\n' > "$WT/conf/app.env"; printf 'readme again\n' > "$WT/README"
  P=$(tip main)
}
cpaths_var() { printf '%s\n' "${CPATHS[@]}" > "$ARGS/paths"; }
scrub_commit() { # <paths>...: the manager's two rounds (part 3 released), then the commit
  CPATHS=("$@"); PREFN=cpaths_var
  tw commit "P=$P" I=main "checkout=$CO" run=none; L=$(hitlines); mkrun c-1 "$L" '' "$L"
  tw commit "P=$P" I=main "checkout=$CO" run=c-1; PREFN=''
}
SCRUBNOTE='^git tripwire: note: nothing moved: 1 path\(s\) the commit would add name a filter driver the config defines \(a clean filter would not run\); refs/heads/main is still at [0-9a-f]{40}$'
if CASE 'commit: a path whose filter attribute names a configured clean filter stops with nothing committed (a scrubbing filter would not scrub; control: plain git add scrubs)'; then
scrub_fixture sc1 '*.env filter=scrub'; scrub_commit conf.env
chk 'stop commit' stop_is commit; chk 'the note' has "$SCRUBNOTE"; chk 'main unmoved' eq "$(tip main)" "$P"; chk 'the live key is in no commit' bash -c "! git -C '$WT' cat-file -e main:conf.env 2>/dev/null"
scrub_fixture sc2 '*.env filter=scrub'; git -C "$WT" add conf.env >/dev/null 2>&1
chk 'control: plain git add stores the scrubbed blob' eq "$(git -C "$WT" cat-file -p :conf.env)" 'APIKEY=REDACTED'
scrub_fixture sc3 '*.env filter=scrub'; scrub_commit conf
chk 'a folder named in paths never commits: stop commit, by the names check (no filter note)' stop_is commit; chk 'it is not the filter note' hasnt 'name a filter driver'; chk 'main unmoved' eq "$(tip main)" "$P"
scrub_fixture sc4 '*.env filter=scrub'; printf 'conf.env -filter\n*.env -filter\n' > "$WT/.gitattributes"; scrub_commit conf.env
chk 'sc4: a work tree .gitattributes that unsets the filter (-filter) is one source of several, and P tree still names it: stop commit (an over-match: plain git add stores this file raw too, so the stop prevents no harm; its one distinct catch is the sc8 note)' stop_is commit; chk 'main unmoved' eq "$(tip main)" "$P"
scrub_fixture sc5 'README text'; printf 'conf.env filter=scrub\n' > "$GD/info/attributes"; scrub_commit conf.env
chk 'the filter named in .git/info/attributes only: stop commit' stop_is commit; chk 'main unmoved' eq "$(tip main)" "$P"
scrub_fixture sc6 '*.env filter=scrub'; git -C "$WT" config --unset filter.scrub.clean; git -C "$WT" config filter.scrub.process "$(cygpath -m "$T/sc6/scrub.sh")"; scrub_commit conf.env
chk 'a process filter: stop commit' stop_is commit; chk 'main unmoved' eq "$(tip main)" "$P"
scrub_fixture sc7 '*.env filter=scrub'; scrub_commit README
chk 'a path that names no driver commits though the config defines one' has '^git tripwire: tip [0-9a-f]{40}$'
DONE; fi

# ---------------------------------------------------------------- build 5: the filter named where only plain git looks
lhas() { printf '%s\n' "$L" | grep -Eq -- "$1"; } # against the lines of the manager's first round (set by scrub_commit)
if CASE 'commit: a filter named in the global core.attributesFile (X1a) or the default ~/.config/git/attributes (X1b), with the driver in the global config, stops with nothing committed (control: plain git add scrubs)'; then
scrub_fixture x1a '' global; scrub_commit conf.env
chk 'X1a: no part 3 line exists to release (a global filter is no hit)' eq "$L" ''
chk 'X1a: stop commit' stop_is commit; chk 'X1a: the note' has "$SCRUBNOTE"; chk 'X1a: main unmoved' eq "$(tip main)" "$P"; chk 'X1a: the live key is in no commit' bash -c "! git -C '$WT' cat-file -e main:conf.env 2>/dev/null"
HOME=$T/x1a/home git -C "$WT" add conf.env >/dev/null 2>&1; chk 'X1a: control: plain git add stores the scrubbed blob' eq "$(git -C "$WT" cat-file -p :conf.env)" 'APIKEY=REDACTED'
scrub_fixture x1b '' defaultdir; scrub_commit conf.env
chk 'X1b: stop commit' stop_is commit; chk 'X1b: the note' has "$SCRUBNOTE"; chk 'X1b: main unmoved' eq "$(tip main)" "$P"; chk 'X1b: the live key is in no commit' bash -c "! git -C '$WT' cat-file -e main:conf.env 2>/dev/null"
HOME=$T/x1b/home git -C "$WT" add conf.env >/dev/null 2>&1; chk 'X1b: control: plain git add stores the scrubbed blob' eq "$(git -C "$WT" cat-file -p :conf.env)" 'APIKEY=REDACTED'
scrub_fixture x1d '' global; CPATHS=(README); PREFN=cpaths_var; tw commit "P=$P" I=main "checkout=$CO" run=none; PREFN='' # no part 3 line exists, so the first round commits
chk 'X1: a path that names no driver commits though the global config defines one' has '^git tripwire: tip [0-9a-f]{40}$'
DONE; fi

if CASE 'commit: a filter named by a .gitattributes that arrives in the commit (X2a) or that is modified, uncommitted, in the work tree (X2b) stops with nothing committed (control: plain git add scrubs)'; then
scrub_fixture x2a ''; printf '*.env filter=scrub\n' > "$WT/.gitattributes"; scrub_commit .gitattributes conf.env
chk 'X2a: the manager had the config key to release (and releasing it says nothing of the scrub)' lhas '^config key filter\.<masked>\.clean#'
chk 'X2a: stop commit' stop_is commit; chk 'X2a: the note' has "$SCRUBNOTE"; chk 'X2a: main unmoved' eq "$(tip main)" "$P"; chk 'X2a: the live key is in no commit' bash -c "! git -C '$WT' cat-file -e main:conf.env 2>/dev/null"
git -C "$WT" add .gitattributes conf.env >/dev/null 2>&1; chk 'X2a: control: plain git add stores the scrubbed blob' eq "$(git -C "$WT" cat-file -p :conf.env)" 'APIKEY=REDACTED'
scrub_fixture x2b 'README text'; printf '*.env filter=scrub\n' >> "$WT/.gitattributes"; scrub_commit conf.env
chk 'X2b: stop commit' stop_is commit; chk 'X2b: the note' has "$SCRUBNOTE"; chk 'X2b: main unmoved' eq "$(tip main)" "$P"; chk 'X2b: the live key is in no commit' bash -c "! git -C '$WT' cat-file -e main:conf.env 2>/dev/null"
git -C "$WT" add conf.env >/dev/null 2>&1; chk 'X2b: control: plain git add stores the scrubbed blob' eq "$(git -C "$WT" cat-file -p :conf.env)" 'APIKEY=REDACTED'
DONE; fi

mkdir -p "$T/shim6"
cat > "$T/shim6/git" <<EOF
#!/usr/bin/bash
{ printf 'GIT_DIR=%s' "\${GIT_DIR-<unset>}"; printf ' [%s]' "\$@"; printf '\n'; } >> "\$SHIMLOG"
case " \$* " in
  *" add "*) if [ ! -e "\$SHIMDONE" ]; then : > "\$SHIMDONE"; printf '*.env filter=scrub\n' > "\$SHIMATTR"; fi ;;
esac
exec $REALGIT "\$@"
EOF
chmod +x "$T/shim6/git"
if CASE 'commit: each source is the one that stops it where the others cannot: a required filter named only in P tree (the work tree unsets it) stops before add with the filter note; a .gitattributes edited between the checks and add is caught on the new tree (control: plain git add scrubs)'; then
scrub_fixture sc8 '*.env filter=scrub'; git -C "$WT" config filter.scrub.required true; printf '*.env -filter\n' > "$WT/.gitattributes"; scrub_commit conf.env
chk 'sc8: stop commit' stop_is commit; chk 'sc8: the filter note, not the generic one a dying add would leave' has "$SCRUBNOTE"; chk 'sc8: main unmoved' eq "$(tip main)" "$P"
scrub_fixture x2c 'README text'
TWPATH="$T/shim6:/usr/bin:/mingw64/bin"; TWENV=("SHIMDONE=$(cygpath -m "$T/x2c/done")" "SHIMATTR=$(cygpath -m "$WT/.gitattributes")")
scrub_commit .gitattributes conf.env
chk 'x2c: the shim edited .gitattributes at the add call' [ -e "$T/x2c/done" ]
chk 'x2c: stop commit' stop_is commit; chk 'x2c: the filter note' has "$SCRUBNOTE"; chk 'x2c: main unmoved' eq "$(tip main)" "$P"; chk 'x2c: the live key is in no commit' bash -c "! git -C '$WT' cat-file -e main:conf.env 2>/dev/null"
git -C "$WT" add .gitattributes conf.env >/dev/null 2>&1; chk 'x2c: control: plain git add stores the scrubbed blob' eq "$(git -C "$WT" cat-file -p :conf.env)" 'APIKEY=REDACTED'
DONE; fi

if CASE 'commit: a pending merge made with -s ours (the staged diff is empty) stops commit with nothing moved (control: without it the commit goes)'; then
fx cm; S0=$(mkunit work/side '100644:z.txt:z'); git -C "$WT" merge -q --no-ff --no-commit -s ours "$S0" >/dev/null 2>&1
chk 'fixture: MERGE_HEAD stands and nothing is staged' bash -c "[ -e '$GD/MERGE_HEAD' ] && [ -z \"\$(git -C '$WT' diff --cached --name-only)\" ]"
printf 'readme two\n' > "$WT/README"; P=$(tip main); CPATHS=(README); PREFN=cpaths_var
tw commit "P=$P" I=main "checkout=$CO" run=none; PREFN=''
chk 'stop commit' stop_is commit; chk 'nothing moved' has "^git tripwire: note: nothing moved: refs/heads/main is still at $P\$"; chk 'main unmoved' eq "$(tip main)" "$P"
rm -f -- "$GD/MERGE_HEAD" "$GD/MERGE_MODE" "$GD/MERGE_MSG"; PREFN=cpaths_var
tw commit "P=$P" I=main "checkout=$CO" run=none; PREFN=''; chk 'control: without MERGE_HEAD the same commit goes' has '^git tripwire: tip [0-9a-f]{40}$'
DONE; fi

# ---------------------------------------------------------------- the records, and the checks a build-3 review found unobserved
if CASE 'remove: raw records are saved for the core and branch sections only, and the words pass, secret, bearer, auth and sshcommand keep a record out'; then
fx rs2
hg config branch.main.zzbenign 5
hg config sendemail.smtppass SMTPPASSVAL; hg config core.zzsecret SECRETVAL; hg config core.zzbear 'Bearer BEARERVAL'; hg config core.zzauthx AUTHVAL; hg config sendemail.smtpserver smtp.invalid
hg config core.sshCommand 'ssh -i SSHKEYVAL' # a key in the core section, with no credential word in it or its value: only the sshcommand word keeps it out
tw check-checkout "checkout=$CO" run=none
rmkey 'branch\.<masked>\.zzbenign'; chk 'the benign branch key is removed and saved' has '^git tripwire: removed config key$'; chk 'saved as <date>-1.config' bash -c "cmp -s '$TWP/removed/$D-1.config' <(printf 'branch.main.zzbenign\n5\0')"
for k in 'sendemail\.smtppass' 'core\.zzsecret' 'core\.zzbear' 'core\.zzauthx' 'sendemail\.smtpserver' 'core\.sshcommand'
do
  rmkey "$k"; chk "removed: $k" has '^git tripwire: removed config key$'
done
chk 'only the one .config exists' bash -c "[ \"\$(ls '$TWP/removed' | grep -c '\\.config\$')\" = 1 ]"
chk 'no value of the six is anywhere in removed/' bash -c "[ -z \"\$(grep -rlE 'SMTPPASSVAL|SECRETVAL|BEARERVAL|AUTHVAL|smtp\\.invalid|SSHKEYVAL' '$TWP/removed' 2>/dev/null)\" ]"
chk 'six lines say not saved' bash -c "[ \"\$(grep -c 'not saved: may hold a credential; restore by hand' '$TWP/removed/index.txt')\" = 6 ]"
tw check-checkout "checkout=$CO" run=none; chk 'the next check is clean' nohits
DONE; fi

if CASE 'remove: an --unset-all that fails after the save ends the index line it began (a config.lock in the way)'; then
fx ru; hg config core.abbrev 12
tw check-checkout "checkout=$CO" run=none; L=$(hitline '^config key core\.abbrev#'); SID=$(hit_id 'config key' "$L"); SH=$(lasthash "$L")
tw select "checkout=$CO" "class=config key" "id=$SID" "hash=$SH"; chk 'select works' rc_is 0
: > "$GD/config.lock"; tw remove "checkout=$CO" "class=config key" "id=$SID" "hash=$SH"; rm -f -- "$GD/config.lock"
chk 'stop remove' stop_is remove; chk 'the key is still set' bash -c "[ \"\$(git -C '$WT' config --local core.abbrev)\" = 12 ]"
chk 'the saving line stands' bash -c "grep -qF 'saving 1 records to $D-1.config' '$TWP/removed/index.txt'"; chk 'and its outcome line: the records are kept, nothing was removed from config' bash -c "grep -qF 'unset failed; records saved; nothing was removed from config' '$TWP/removed/index.txt'"; chk 'and the saved slot is there, as the line says' bash -c "[ -s '$TWP/removed/$D-1.config' ]"
DONE; fi

if CASE 'unit: a directory rename lands a unit file in a folder the first diff never named; that folder is a junction, and the call stops (the check after merge-tree)'; then
fx dr; mkdir -p "$WT/a"; printf 'old\n' > "$WT/a/old.txt"; hg add a; hg commit -q -m 'add a'
S=$(mkunit work/u1 'del:a/old.txt' $'100644:b/old.txt:old\n' '100644:a/new.txt:new')
hg mv a b; hg commit -q -m 'rename a to b'; P=$(tip main)
mkdir -p "$T/dr/home"; cp "$HOME1/.gitconfig" "$T/dr/home/.gitconfig"; printf '[merge]\n\tdirectoryRenames = true\n' >> "$T/dr/home/.gitconfig"
DRT=$(HOME=$T/dr/home git -C "$WT" merge-tree --write-tree --no-messages "$P" "$S")
chk 'fixture: the merge-tree tree has b/new.txt and no a/new.txt' bash -c "git -C '$WT' cat-file -e '$DRT:b/new.txt' && ! git -C '$WT' cat-file -e '$DRT:a/new.txt' 2>/dev/null"
rm -rf -- "$WT/b"; mkjunc "$WT/b" "$WT/.claude"; chk 'the junction stands where b was' [ -L "$WT/b" ]
TWHOME=$T/dr/home
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; chk 'check-unit: stop unit' stop_is unit; chk 'merge-tree was called (the first check passed)' bash -c "grep -qF 'merge-tree' '$LOGF'"; chk 'the note names b' has '^git tripwire: note: the leading folder b\$ is a link in the checkout$'
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none; chk 'merge-unit: stop unit' stop_is unit; chk 'main unmoved' eq "$(tip main)" "$P"; chk 'nothing landed in .claude' absent_f "$WT/.claude/new.txt"
TWHOME=$HOME1; rmjunc "$WT/b"
DONE; fi

mkdir -p "$T/shim4"
cat > "$T/shim4/git" <<EOF
#!/usr/bin/bash
{ printf 'GIT_DIR=%s' "\${GIT_DIR-<unset>}"; printf ' [%s]' "\$@"; printf '\n'; } >> "\$SHIMLOG"
for a in "\$@"; do
  if [ "\$a" = --raw ] && [ ! -e "\$SHIMDONE" ]; then
    : > "\$SHIMDONE"
    /c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command "New-Item -ItemType Junction -Path '\$SHIMLINK' -Target '\$SHIMTARGET' | Out-Null" >/dev/null 2>&1
    break
  fi
done
exec $REALGIT "\$@"
EOF
chmod +x "$T/shim4/git"
if CASE 'unit: a junction made after the unit was read (between its checks and the merge) stops the call at the start of the merge, with nothing moved'; then
fx jp; S=$(mkunit work/u1 '100644:foo/settings.local.json:{"u":1}'); P=$(tip main)
TWPATH="$T/shim4:/usr/bin:/mingw64/bin"; TWENV=("SHIMDONE=$(cygpath -m "$T/jp/done")" "SHIMLINK=$(cygpath -w "$WT/foo")" "SHIMTARGET=$(cygpath -w "$WT/.claude")")
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none
chk 'the shim made the junction at the diff --raw call' [ -L "$WT/foo" ]
chk 'stop unit' stop_is unit; chk 'main unmoved' eq "$(tip main)" "$P"; chk 'nothing landed in .claude' absent_f "$WT/.claude/settings.local.json"
chk 'the stop came at the start of the merge: the unit diff was read before it' bash -c "grep -qF '[--raw]' '$LOGF'"
rmjunc "$WT/foo"
DONE; fi

# The filter check covers the paths a unit writes. `update-index --refresh` also rehashes any stat-dirty tracked file through its
# clean (or process) filter, whatever the unit writes: that route is closed by the blanked commands, shown here. (A smudge filter has a route too, read-tree -u under a legacy sparse
# checkout writes and smudges a path outside the unit; the sparse stop closes it, so the blanked smudge command is the second line behind the sparse stop and the filter check: see the sparse cases below.)
if CASE 'merge: the refresh before the move runs no clean or process filter on a stat-dirty tracked file outside the unit (control: plain update-index --refresh runs it)'; then
for kind in clean process
do
  filt_fixture "rf_$kind"; git -C "$WT" config "filter.demo.$kind" "$(cygpath -m "$T/rf_$kind/f.sh")"
  S2=$(mkunit work/u2 '100644:c.md:x'); rel_unit u1-1 "$S2" "$P"; touch -d '2001-01-01' "$WT/a.txt"
  tw merge-unit "S=$S2" "P=$P" u=u2 I=main "checkout=$CO" run=u1-1
  chk "$kind: the unit merges (c.md names no driver)" has '^git tripwire: tip [0-9a-f]{40}$'; chk "$kind: the filter did not run" absent_f "$T/rf_$kind/mk/ran"
  touch -d '2002-01-01' "$WT/a.txt"; git -C "$WT" update-index -q --refresh >/dev/null 2>&1
  chk "$kind: control: a plain refresh of the same stat-dirty file runs the filter" [ -e "$T/rf_$kind/mk/ran" ]
done
DONE; fi

REFNOTE='^git tripwire: note: nothing moved: the index refresh failed; the usual cause is a filter marked required meeting a tracked file the unit does not touch: a plain git status, run by the human outside the team, refreshes a file whose stat data is stale, and a filtered file that really changed has to be committed or restored; refs/heads/main is still at [0-9a-f]{40}$'
if CASE 'merge: a filter marked required and a stat-dirty tracked file the unit does not touch stop the merge at the refresh, nothing moved, with a note that names the refresh (control: the same unit merges when no file is stat-dirty)'; then
filt_fixture rr1; git -C "$WT" config filter.demo.required true; git -C "$WT" config filter.demo.clean "$(cygpath -m "$T/rr1/f.sh")"
S2=$(mkunit work/u2 '100644:c.md:x'); rel_unit u1-1 "$S2" "$P"; touch -d '2001-01-01' "$WT/a.txt"
tw merge-unit "S=$S2" "P=$P" u=u2 I=main "checkout=$CO" run=u1-1
chk 'stop merge' stop_is merge; chk 'the refresh note' has "$REFNOTE"; chk 'main unmoved' eq "$(tip main)" "$P"; chk 'c.md did not arrive' absent_f "$WT/c.md"; chk 'no filter ran' absent_f "$T/rr1/mk/ran"; chk 'the index is not locked' absent_f "$GD/index.lock"
filt_fixture rr2; git -C "$WT" config filter.demo.required true; git -C "$WT" config filter.demo.clean "$(cygpath -m "$T/rr2/f.sh")"
touch -d '2001-01-01' "$WT/a.txt"; git -C "$WT" update-index -q --refresh >/dev/null 2>&1 # the index is current: a.txt is not racily clean
S2=$(mkunit work/u2 '100644:c.md:x'); rel_unit u1-1 "$S2" "$P"
tw merge-unit "S=$S2" "P=$P" u=u2 I=main "checkout=$CO" run=u1-1; chk 'control: with no stat-dirty file the same unit merges' has '^git tripwire: tip [0-9a-f]{40}$'
DONE; fi

# ---------------------------------------------------------------- sparse checkout
# A legacy sparse checkout (core.sparseCheckout in .git/config or a global config, and a hand-widened info/sparse-checkout)
# makes read-tree -m -u re-apply the sparse patterns to a path the unit never names: it is written, and smudged.
sp_fixture() { # <name> <local|cfgonly|globalonly|skip|none>: a required smudge driver on a.txt (outside the unit); the unit adds c.md. Sets S2 P
  local nm=$1 how=$2
  filt_fixture "$nm"
  printf '#!/bin/sh\ntouch "%s/smudge"\ncat\n' "$M" > "$T/$nm/sm.sh"; chmod +x "$T/$nm/sm.sh"
  git -C "$WT" config filter.demo.smudge "$(cygpath -m "$T/$nm/sm.sh")"; git -C "$WT" config filter.demo.required true
  git -C "$WT" config filter.demo.clean "$(cygpath -m "$T/$nm/f.sh")"
  # a.txt is made old and the index refreshed through the real clean filter, so a freshly written file is not "racily clean"
  # (git rehashes those, and a required filter that the script blanks would fail the refresh: the refresh case below)
  touch -d '2001-01-01' "$WT/a.txt"; git -C "$WT" update-index -q --refresh >/dev/null 2>&1
  S2=$(mkunit work/u2 '100644:c.md:x'); P=$(tip main)
  case $how in local | skip) hg update-index --skip-worktree a.txt; rm -f -- "$WT/a.txt" ;; esac
  case $how in
    local | cfgonly) git -C "$WT" config core.sparseCheckout true ;;
    globalonly) mkdir -p "$T/$nm/home"; cp "$HOME1/.gitconfig" "$T/$nm/home/.gitconfig"; printf '[core]\n\tsparseCheckout = true\n' >> "$T/$nm/home/.gitconfig"; TWHOME=$T/$nm/home ;;
  esac
  case $how in local | globalonly) printf '/*\n' > "$GD/info/sparse-checkout" ;; esac
}
sp_run() { # <name>: the manager's rounds, then merge-unit
  rel_unit u1-1 "$S2" "$P"; tw merge-unit "S=$S2" "P=$P" u=u2 I=main "checkout=$CO" run=u1-1
}
if CASE 'merge: core.sparseCheckout in any scope, or a skip-worktree entry, stops merge with nothing moved (the route: a hand-widened sparse file makes read-tree -u write and smudge a path outside the unit)'; then
sp_fixture sp1 local; sp_run
chk 'R2a: stop merge' stop_is merge; chk 'R2a: nothing moved, and why' has "^git tripwire: note: nothing moved: core\\.sparseCheckout is on; refs/heads/main is still at $P\$"; chk 'R2a: main unmoved' eq "$(tip main)" "$P"
chk 'R2a: a.txt was not written' absent_f "$WT/a.txt"; chk 'R2a: c.md did not arrive' absent_f "$WT/c.md"; chk 'R2a: no smudge ran' absent_f "$T/sp1/mk/smudge"
tw check-unit "S=$S2" "P=$P" I=main "checkout=$CO" run=u1-1; chk 'R2a: check-unit predicts the stop' has '^git tripwire: note: core\.sparseCheckout is on; merge-unit will stop \(merge\)$'
sp_fixture sp2 local; git -C "$WT" read-tree -m -u "$P" "$S2" >/dev/null 2>&1
chk 'R2c: control: plain read-tree -m -u writes a.txt, which the unit never names' [ -f "$WT/a.txt" ]; chk 'R2c: control: and runs the smudge filter on it' [ -e "$T/sp2/mk/smudge" ]
sp_fixture sp3 cfgonly; sp_run; chk 'the config limb alone (no skip-worktree entry): stop merge' stop_is merge; chk 'main unmoved' eq "$(tip main)" "$P"
sp_fixture sp4 globalonly; sp_run; TWHOME=$HOME1; chk 'a global core.sparseCheckout alone (any scope): stop merge' stop_is merge; chk 'main unmoved' eq "$(tip main)" "$P"
sp_fixture sp5 skip; sp_run; chk 'the skip-worktree limb alone (core.sparseCheckout off): stop merge' stop_is merge; chk 'and says so' has "^git tripwire: note: nothing moved: an index entry is marked skip-worktree; refs/heads/main is still at $P\$"; chk 'main unmoved' eq "$(tip main)" "$P"
sp_fixture sp6 none; sp_run; chk 'control: the same driver and unit with no sparse checkout merges' has '^git tripwire: tip [0-9a-f]{40}$'
DONE; fi

# ---------------------------------------------------------------- the submodule dir line, anchored at each git dir
if CASE 'check: the submodule dir line hashes commondir and objects/info/alternates and nested git dirs, and not objects/info/packs, info/refs or refs named info, hooks or config; an include in a submodule config is its own hit and is never released'; then
subfix se absorbed; MG=$GD/modules/lib
sdline; SE0=$SDL; chk 'the line is there' eq "$([ -n "$SE0" ] && echo y)" y
mkdir -p "$MG/info" "$MG/refs/heads/info" "$MG/refs/heads/hooks"
printf 'x\n' > "$MG/objects/info/packs"; printf 'x\n' > "$MG/info/refs"; printf '%s\n' "$C2" > "$MG/refs/heads/info/x"; printf '%s\n' "$C2" > "$MG/refs/heads/hooks/y"; printf '%s\n' "$C2" > "$MG/refs/heads/config"
mkdir -p "$MG/objects/hooks"; printf 'x\n' > "$MG/objects/hooks/h"; printf 'x\n' > "$MG/objects/config"
sdline; chk 'an objects/info/packs write, info/refs, branches named info/x, hooks/y and config, and files named hooks/h and config in objects/ change nothing' eq "$SDL" "$SE0"
SDP=$SE0
printf '../elsewhere\n' > "$MG/commondir"; sdline; chk 'a planted commondir changes it' [ "$SDL" != "$SDP" ]; SDP=$SDL
rm -f -- "$MG/commondir"; sdline; chk 'removing it puts the line back' eq "$SDL" "$SE0"
printf '/x/objects\n' > "$MG/objects/info/alternates"; sdline; chk 'an objects/info/alternates file changes it' [ "$SDL" != "$SE0" ]; rm -f -- "$MG/objects/info/alternates"
mkdir -p "$MG/modules/inner/objects" "$MG/modules/inner/hooks"; printf 'ref: refs/heads/main\n' > "$MG/modules/inner/HEAD"; printf '#!/bin/sh\n:\n' > "$MG/modules/inner/hooks/post-checkout"
sdline; chk 'a hook in a git dir nested in the submodule git dir changes it' [ "$SDL" != "$SE0" ]; SDP=$SDL
printf 'x\n' > "$MG/modules/inner/stray"; mkdir -p "$MG/modules/inner/objects/info"; printf 'x\n' > "$MG/modules/inner/objects/info/packs"; sdline; chk 'but an objects/info/packs write there does not' eq "$SDL" "$SDP"
rm -rf -- "$MG/modules"; sdline; chk 'removing the nested git dir puts the line back' eq "$SDL" "$SE0"
# a git dir is recognised by a HEAD file next to an objects folder, a commondir or a config (any case: NTFS opens Head as HEAD)
mkdir -p "$MG/modules/cd/hooks"; printf 'ref: refs/heads/main\n' > "$MG/modules/cd/HEAD"; printf '../x\n' > "$MG/modules/cd/commondir"
sdline; chk 'a nested git dir with only HEAD and commondir is seen' [ "$SDL" != "$SE0" ]; rm -rf -- "$MG/modules"
mkdir -p "$MG/modules/cf/hooks"; printf 'ref: refs/heads/main\n' > "$MG/modules/cf/HEAD"; printf '[core]\n\tbare = true\n' > "$MG/modules/cf/config"
sdline; chk 'a nested git dir with only HEAD and config is seen' [ "$SDL" != "$SE0" ]; rm -rf -- "$MG/modules"
mkdir -p "$MG/modules/up/Objects" "$MG/modules/up/Hooks"; printf 'ref: refs/heads/main\n' > "$MG/modules/up/Head"; printf '#!/bin/sh\n:\n' > "$MG/modules/up/Hooks/Post-Checkout"
sdline; chk 'a nested git dir spelled Head, Objects and Hooks is seen (names are folded)' [ "$SDL" != "$SE0" ]; rm -rf -- "$MG/modules"
sdline; chk 'the line is back again' eq "$SDL" "$SE0"
printf '[include]\n\tpath = ../../../inc.cfg\n' >> "$MG/config"
tw check-checkout "checkout=$CO" run=none
chk 'an include in modules/lib/config is a hit of its own' has '^submodule dir modules/lib/config\$ [0-9a-f]{64}$'; chk 'and the modules line is still there' has '^submodule dir modules\$ '
rel_unit u1-1 "$S" "$P"; tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1
chk 'released in full, merge-unit still stops (expected: that line is never released)' stop_is expected; chk 'main unmoved' eq "$(tip main)" "$P"
git config --file "$MG/config" --unset include.path; printf '[core]\n\tbare = false\n[includeIf "gitdir:/x/"]\n\tpath = y\n' > "$MG/config.worktree"
tw check-checkout "checkout=$CO" run=none; chk 'an includeIf in modules/lib/config.worktree is a hit too' has '^submodule dir modules/lib/config\.worktree\$ [0-9a-f]{64}$'; chk 'and the include in config is gone' hasnt '^submodule dir modules/lib/config\$ '
rm -f -- "$MG/config.worktree"; rel_unit u1-1 "$S" "$P"; tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1
chk 'control: with no include, the released unit merges' has '^git tripwire: tip [0-9a-f]{40}$'
DONE; fi

# ---------------------------------------------------------------- stops after the unset in remove_key
mkdir -p "$T/shim5"
cat > "$T/shim5/git" <<EOF
#!/usr/bin/bash
{ printf 'GIT_DIR=%s' "\${GIT_DIR-<unset>}"; printf ' [%s]' "\$@"; printf '\n'; } >> "\$SHIMLOG"
case " \$* " in *" --unset-all "*) : > "\$SHIMFLAG" ;; esac
if [ -n "\${GIT_DIR+x}" ] && [ -e "\${SHIMFLAG:-/nonexistent}" ]; then
  case " \$* " in
    *" \$SHIMFAIL "*) if [ "\${SHIMMODE:-fail}" = empty ]; then exit 0; else exit 1; fi ;;
  esac
fi
exec $REALGIT "\$@"
EOF
chmod +x "$T/shim5/git"
# a gawk that fails, or prints a record with no value, for the one listing named by SHIMGAWK, once the unset has happened
cat > "$T/shim5/gawk" <<'EOF'
#!/usr/bin/bash
if [ -n "${SHIMGAWK:-}" ] && [ -e "${SHIMFLAG:-/nonexistent}" ]; then
  case " $* " in
    *"$SHIMGAWK "*) if [ "${SHIMGMODE:-fail}" = nonl ]; then printf 'core.logallrefupdates\0'; exit 0; else exit 1; fi ;;
  esac
fi
exec /usr/bin/gawk "$@"
EOF
chmod +x "$T/shim5/gawk"
if CASE 'remove: every stop after the unset ends the index line with what was kept (an --add that fails; a list that fails on the credential path, with its count and hashes; a list that comes back empty; the reference or the new records unreadable or malformed)'; then
fx ra; hg config core.logallrefupdates false
TWPATH="$T/shim5:/usr/bin:/mingw64/bin"; TWENV=("SHIMFLAG=$(cygpath -m "$T/ra/flag")" "SHIMFAIL=--add")
rmkey 'core\.logallrefupdates'; chk 'ra: stop remove' stop_is remove
chk 'ra: the saving line, and the line that says the restore failed and what was saved' bash -c "grep -qF 'saving 1 records to $D-1.config' '$TWP/removed/index.txt' && grep -qF 'restore failed after the unset; edited; records saved to $D-1.config' '$TWP/removed/index.txt'"
chk 'ra: the slot holds the record' bash -c "cmp -s '$TWP/removed/$D-1.config' <(printf 'core.logallrefupdates\nfalse\0')"
fx rb; hg config sendemail.smtppass SMTPPASSVAL
TWENV=("SHIMFLAG=$(cygpath -m "$T/rb/flag")" "SHIMFAIL=config --local --includes --list -z")
rmkey 'sendemail\.smtppass'; chk 'rb: stop config' stop_is config
chk 'rb: the credential path writes its count and its salted hash on the failure line' bash -c "grep -qF 'restore failed after the unset; edited; not saved: may hold a credential; restore by hand; records: 1; salted hashes: $(sha_str $'sendemail.smtppass\nSMTPPASSVAL')' '$TWP/removed/index.txt'"
chk 'rb: no value is in removed/' bash -c "[ -z \"\$(grep -rl SMTPPASSVAL '$TWP/removed' 2>/dev/null)\" ]"
fx rc; hg config core.logallrefupdates false
TWENV=("SHIMFLAG=$(cygpath -m "$T/rc/flag")" "SHIMFAIL=config --local --includes --list -z" "SHIMMODE=empty")
rmkey 'core\.logallrefupdates'; chk 'rc: stop remove (the restored key is not there when compared)' stop_is remove
chk 'rc: the failure line' bash -c "grep -qF 'restore failed after the unset; edited; records saved to $D-1.config' '$TWP/removed/index.txt'"
for v in "rd:cfg.r:fail:the reference records cannot be read" "re:cfg.r:nonl:a reference record has no value" "rg:cfg.c2:fail:the new records cannot be read"
do
  IFS=: read -r vn vf vm vd <<< "$v"
  fx "$vn"; hg config core.logallrefupdates false
  TWENV=("SHIMFLAG=$(cygpath -m "$T/$vn/flag")" "SHIMGAWK=$vf" "SHIMGMODE=$vm")
  rmkey 'core\.logallrefupdates'; chk "$vn: stop remove ($vd)" stop_is remove
  chk "$vn: the failure line" bash -c "grep -qF 'restore failed after the unset; edited; records saved to $D-1.config' '$TWP/removed/index.txt'"
done
DONE; fi

# ---------------------------------------------------------------- build 6: XDG_CONFIG_HOME, stat data after a commit, a stale index.lock, the project's own guards
# The call form's two lines are the protocol's text: tw above carries their logic, and this case compares the strings.
PROTO=$(dirname "$script")/protocol.md
if CASE 'call: the protocol carries the call form tw mirrors (the first line before the header; XDG_CONFIG_HOME only when set)'; then
CF1='[ -z "${GIT_CONFIG_GLOBAL+x}${GIT_CONFIG_SYSTEM+x}${GIT_CONFIG_NOSYSTEM+x}${GIT_ATTR_NOSYSTEM+x}" ] || { printf '"'"'stop: git tripwire: call\n'"'"'; exit 1; }'
CF2='${XDG_CONFIG_HOME+"XDG_CONFIG_HOME=$XDG_CONFIG_HOME"}'
chk 'the protocol file is there' [ -f "$PROTO" ]
chk 'line 1 is in the protocol, exactly' bash -c 'tr -d "\r" < "$2" | grep -qxF -- "$1"' _ "$CF1" "$PROTO"
chk 'the XDG pass-through is in the protocol call line, exactly' bash -c 'tr -d "\r" < "$2" | grep -F -- "$1" | grep -q "env -i"' _ "$CF2" "$PROTO"
# Line 2 in full: the PATH, HOME, the pass-through, bash's flags, the two arguments and the fail label cannot drift.
CFL2='/usr/bin/env -i PATH=/usr/bin:/mingw64/bin HOME="$HOME" ${XDG_CONFIG_HOME+"XDG_CONFIG_HOME=$XDG_CONFIG_HOME"} /usr/bin/bash --noprofile --norc '"'"'<script>'"'"' '"'"'<args folder>'"'"' || fail '"'"'git tripwire: call'"'"
chk 'line 2 is in the protocol, whole, once' bash -c 'test "$(tr -d "\r" < "$2" | grep -cxF -- "$1")" = 1' _ "$CFL2" "$PROTO"
# tw's own line differs on purpose (the git shim in PATH, SHIMLOG, a cygpath -m HOME, the script and args as MSYS paths, no fail label); what must not
# differ is the rest of the call: env -i, the pass-through, and bash with its two flags.
TWDEF=$(declare -f tw)
chk 'tw: env -i, then PATH= and HOME= in that order' bash -c '[[ $1 == *"env -i PATH="*" HOME="* ]]' _ "$TWDEF"
chk 'tw: the pass-through, written as the protocol writes it' bash -c '[[ $1 == *"$2"* ]]' _ "$TWDEF" "$CF2"
chk 'tw: bash with --noprofile --norc, as /usr/bin/bash' bash -c '[[ $1 == *" /usr/bin/bash --noprofile --norc "* ]]' _ "$TWDEF"
DONE; fi

if CASE 'commit: a filter named under XDG_CONFIG_HOME (global config and attributes there) stops with nothing committed once the variable goes through the call form (control: plain git add scrubs)'; then
scrub_fixture xe1 '' xdgenv; export XDG_CONFIG_HOME=$(cygpath -m "$T/xe1/xdg")
scrub_commit conf.env
chk 'xdg: no part 3 line exists to release (a global filter is no hit)' eq "$L" ''
chk 'xdg: stop commit' stop_is commit; chk 'xdg: the note' has "$SCRUBNOTE"; chk 'xdg: main unmoved' eq "$(tip main)" "$P"; chk 'xdg: the live key is in no commit' bash -c "! git -C '$WT' cat-file -e main:conf.env 2>/dev/null"
git -C "$WT" add conf.env >/dev/null 2>&1; chk 'xdg: control: plain git add (XDG_CONFIG_HOME set) stores the scrubbed blob' eq "$(git -C "$WT" cat-file -p :conf.env)" 'APIKEY=REDACTED'
scrub_fixture xe2 '' xdgenv; CPATHS=(README); PREFN=cpaths_var; tw commit "P=$P" I=main "checkout=$CO" run=none; PREFN='' # no part 3 line exists, so the first round commits
chk 'xdg: a path that names no driver commits though the driver is defined under XDG_CONFIG_HOME' has '^git tripwire: tip [0-9a-f]{40}$'
unset XDG_CONFIG_HOME
DONE; fi

if CASE 'call: an XDG_CONFIG_HOME that is set but not an absolute plain path stops the call, with no git call on the checkout; a good one runs'; then
fx xe3
for v in 'rel/dir' '' 'C:\x\y' '/d/some-folder/x' "$(cygpath -m "$T")/a'b" "$(cygpath -m "$T")/a b/../c" "$(cygpath -m "$T")//c"
do
  export XDG_CONFIG_HOME=$v
  tw check-checkout "checkout=$CO" run=none; chk "stop call for [$v]" stop_is call; chk "no checkout call for [$v]" nocall
done
mkdir -p "$T/xe3/okx"; export XDG_CONFIG_HOME=$(cygpath -m "$T/xe3/okx")
tw check-checkout "checkout=$CO" run=none; chk 'a good absolute value runs' rc_is 0
unset XDG_CONFIG_HOME
DONE; fi

if CASE 'call: GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM, GIT_CONFIG_NOSYSTEM or GIT_ATTR_NOSYSTEM set in the caller environment (even empty) stops the call before the script runs'; then
fx xe4
for v in GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_ATTR_NOSYSTEM
do
  export "$v=x"
  tw check-checkout "checkout=$CO" run=none; chk "$v: the stop line" eq "$OUT" 'stop: git tripwire: call'; chk "$v: exit 1" rc_is 1; chk "$v: no git call at all" bash -c "! [ -s '$LOGF' ]"
  export "$v="
  tw check-checkout "checkout=$CO" run=none; chk "$v set empty: the stop line" eq "$OUT" 'stop: git tripwire: call'
  unset "$v"
done
tw check-checkout "checkout=$CO" run=none; chk 'control: with none of the four set the same call runs' rc_is 0
DONE; fi

if CASE 'commit: a modified tracked path commits, a required-filter file keeps its stat data, and the next merge-unit goes through (read-tree -m -i; control: a plain read-tree drops every entry stat data)'; then
filt_fixture st1; git -C "$WT" config filter.demo.required true; git -C "$WT" config filter.demo.clean "$(cygpath -m "$T/st1/f.sh")"
touch -d '2001-01-01' "$WT/a.txt"; git -C "$WT" update-index -q --refresh >/dev/null 2>&1
chk 'fixture: a.txt has stat data in the index' bash -c "! git -C '$WT' ls-files --debug a.txt | grep -q 'mtime: 0:0'"
printf 'readme changed\n' > "$WT/README"; P=$(tip main); scrub_commit README # the two rounds: the filter config keys are released first
chk 'a modified tracked path commits' has '^git tripwire: tip [0-9a-f]{40}$'; chk 'main moved' [ "$(tip main)" != "$P" ]
chk 'the index equals the new tree' bash -c "[ -z \"\$(git -C '$WT' diff --cached --name-only)\" ]"
chk 'a.txt kept its stat data' bash -c "! git -C '$WT' ls-files --debug a.txt | grep -q 'mtime: 0:0'"
P2=$(tip main); S2=$(mkunit work/u2 '100644:c.md:x'); rel_unit u1-1 "$S2" "$P2"
tw merge-unit "S=$S2" "P=$P2" u=u2 I=main "checkout=$CO" run=u1-1; chk 'the next merge-unit goes through' has '^git tripwire: tip [0-9a-f]{40}$'; chk 'no refresh note' hasnt 'index refresh failed'
git -C "$WT" read-tree "$(tip main)" >/dev/null 2>&1
chk 'control: a plain read-tree of the tree drops the stat data (mtime 0:0)' bash -c "git -C '$WT' ls-files --debug a.txt | grep -q 'mtime: 0:0'"
DONE; fi

if CASE 'lock: a stale .git/index.lock stops commit and merge-unit with nothing moved and a note that names the lock (check-unit says so first); a lock made after the checks stops at update-ref (control: plain git commit refuses it too)'; then
fx lk1; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main); : > "$GD/index.lock"
printf 'readme two\n' > "$WT/README"; CPATHS=(README); PREFN=cpaths_var
tw commit "P=$P" I=main "checkout=$CO" run=none; PREFN=''
chk 'commit: stop commit' stop_is commit; chk 'commit: nothing moved, and the lock is named' has "^git tripwire: note: nothing moved: \\.git/index\\.lock exists \\(a git command is running, or one was killed and left it behind\\); refs/heads/main is still at $P\$"; chk 'commit: main unmoved' eq "$(tip main)" "$P"
tw check-unit "S=$S" "P=$P" I=main "checkout=$CO" run=none; chk 'check-unit predicts the stop' has '^git tripwire: note: \.git/index\.lock exists .*; merge-unit will stop \(merge\)$'
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none
chk 'merge-unit: stop merge' stop_is merge; chk 'merge-unit: the note names the lock, not a filter' has "^git tripwire: note: nothing moved: \\.git/index\\.lock exists .*; refs/heads/main is still at $P\$"; chk 'merge-unit: hasnt the refresh note' hasnt 'index refresh failed'; chk 'merge-unit: main unmoved' eq "$(tip main)" "$P"; chk 'merge-unit: f1 not written' absent_f "$WT/f1"
git -C "$WT" -c core.hooksPath=/dev/null commit -q -m ctl README >/dev/null 2>&1; chk 'control: plain git commit refuses a stale lock and moves nothing' eq "$(tip main)" "$P"
rm -f -- "$GD/index.lock"
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none; chk 'control: without the lock the merge goes' has '^git tripwire: tip [0-9a-f]{40}$'
# the race: a lock appears after the checks, as the last read-tree dry run (merge) or commit-tree (commit) returns
mkdir -p "$T/shim7"
cat > "$T/shim7/git" <<SHIMEOF
#!/usr/bin/bash
{ printf 'GIT_DIR=%s' "\${GIT_DIR-<unset>}"; printf ' [%s]' "\$@"; printf '\n'; } >> "\$SHIMLOG"
$REALGIT "\$@"; rc=\$?
case " \$* " in *" \$SHIMON "*) : > "\$SHIMLOCK" ;; esac
exit \$rc
SHIMEOF
chmod +x "$T/shim7/git"
fx lk2; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
TWPATH="$T/shim7:/usr/bin:/mingw64/bin"; TWENV=("SHIMON=-n" "SHIMLOCK=$(cygpath -m "$GD/index.lock")")
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none
chk 'race, merge: the lock was made after the dry run' [ -e "$GD/index.lock" ]; chk 'race, merge: stop merge' stop_is merge; chk 'race, merge: nothing moved, lock named' has "^git tripwire: note: nothing moved: \\.git/index\\.lock exists .*; refs/heads/main is still at $P\$"; chk 'race, merge: main unmoved' eq "$(tip main)" "$P"; chk 'race, merge: f1 not written' absent_f "$WT/f1"
rm -f -- "$GD/index.lock"
fx lk3; P=$(tip main); printf 'readme two\n' > "$WT/README"; CPATHS=(README); PREFN=cpaths_var
TWPATH="$T/shim7:/usr/bin:/mingw64/bin"; TWENV=("SHIMON=commit-tree" "SHIMLOCK=$(cygpath -m "$GD/index.lock")")
tw commit "P=$P" I=main "checkout=$CO" run=none; PREFN=''
chk 'race, commit: the lock was made at commit-tree' [ -e "$GD/index.lock" ]; chk 'race, commit: stop commit' stop_is commit; chk 'race, commit: nothing moved, lock named' has "^git tripwire: note: nothing moved: \\.git/index\\.lock exists .*; refs/heads/main is still at $P\$"; chk 'race, commit: main unmoved' eq "$(tip main)" "$P"; chk 'race, commit: the real index is untouched (README is not staged)' bash -c "[ -z \"\$(git -C '$WT' diff --cached --name-only)\" ]"
rm -f -- "$GD/index.lock"
DONE; fi

if CASE 'guard note: a project guard that commits and merges do not run (a pre-commit hook file, core.hooksPath in any scope, .pre-commit-config.yaml, .husky/) is named in a note on commit, merge-unit and merge-handsoff; a project with none prints no note'; then
gnote='^git tripwire: note: this project has a pre-commit guard \(.*\) that devhouse commits and merges do not run; run it yourself over the commits since your last push, not only the current files: a secret committed and later removed stays in history$'
fx gn0; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none; chk 'none: merges' has '^git tripwire: tip [0-9a-f]{40}$'; chk 'none: no guard note' hasnt 'pre-commit guard'
for g in hookfile commitmsg premerge cfgcfg precommitcfg husky; do
  fx "gn_$g"; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main); want=''
  case $g in
    hookfile) printf '#!/bin/sh\n:\n' > "$GD/hooks/pre-commit"; want='.git/hooks/pre-commit' ;;
    commitmsg) printf '#!/bin/sh\n:\n' > "$GD/hooks/commit-msg"; want='.git/hooks/commit-msg' ;;
    premerge) printf '#!/bin/sh\n:\n' > "$GD/hooks/pre-merge-commit"; want='.git/hooks/pre-merge-commit' ;;
    cfgcfg) mkdir -p "$T/gn_$g/home"; cp "$HOME1/.gitconfig" "$T/gn_$g/home/.gitconfig"; printf '[core]\n\thooksPath = %s\n' "$(cygpath -m "$T/gn_$g/ghooks")" >> "$T/gn_$g/home/.gitconfig"; TWHOME=$T/gn_$g/home; want='core.hooksPath' ;;
    precommitcfg) printf 'repos: []\n' > "$WT/.pre-commit-config.yaml"; want='.pre-commit-config.yaml' ;;
    husky) mkdir -p "$WT/.husky"; printf 'x\n' > "$WT/.husky/pre-commit"; want='.husky/' ;;
  esac
  rel_unit u1-1 "$S" "$P"
  tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=u1-1
  chk "$g: merge-unit merges" has '^git tripwire: tip [0-9a-f]{40}$'; chk "$g: the note" has "$gnote"; chk "$g: and naming $want" has "pre-commit guard \\(.*$(printf '%s' "$want" | sed 's/[.]/\\./g').*\\)"; chk "$g: the note comes before the tip line" bash -c "printf '%s\n' \"\$1\" | tail -n 2 | head -n 1 | grep -q 'pre-commit guard'" _ "$OUT"
  TWHOME=$HOME1
done
fx gnc; printf '#!/bin/sh\n:\n' > "$GD/hooks/pre-commit"; printf 'readme two\n' > "$WT/README"; P=$(tip main); CPATHS=(README); PREFN=cpaths_var
tw commit "P=$P" I=main "checkout=$CO" run=none; L=$(hitlines); mkrun c-1 "$L" '' "$L"; tw commit "P=$P" I=main "checkout=$CO" run=c-1; PREFN=''
chk 'commit: commits' has '^git tripwire: tip [0-9a-f]{40}$'; chk 'commit: the note' has "$gnote"
fx gnh; printf '#!/bin/sh\n:\n' > "$GD/hooks/pre-commit"; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main)
tw check-checkout "checkout=$CO" run=none; L=$(hitlines); mkrun h-1 "$L" '' "$L"
tw merge-handsoff "Pt=$P" "Ps=$S" from=work/u1 to=main "checkout=$CO" run=h-1; chk 'merge-handsoff: merges' has '^git tripwire: tip [0-9a-f]{40}$'; chk 'merge-handsoff: the note' has "$gnote"
DONE; fi

if CASE 'guard note: a failure working out the note (gawk cannot read the config dump) stops commit, merge-unit and merge-handsoff before the branch moves: nothing moved, no moved-note (control: without the failure the same call merges)'; then
mkdir -p "$T/shimg"
cat > "$T/shimg/gawk" <<'EOF2'
#!/usr/bin/bash
for a in "$@"; do case $a in *'tolower(k)=="core.hookspath"'*) exit 2 ;; esac; done
exec /usr/bin/gawk "$@"
EOF2
chmod +x "$T/shimg/gawk"
fx gg1; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main); TWPATH="$T/shimg:$SHIM:/usr/bin:/mingw64/bin"
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none
chk 'merge-unit: stop config' stop_is config; chk 'merge-unit: main unmoved' eq "$(tip main)" "$P"; chk 'merge-unit: no moved-note' hasnt 'has moved'; chk 'merge-unit: nothing landed in the work tree' absent_f "$WT/f1"
fx gg2; printf 'readme two\n' > "$WT/README"; P=$(tip main); TWPATH="$T/shimg:$SHIM:/usr/bin:/mingw64/bin"
PREFN=cpaths5; tw commit "P=$P" I=main "checkout=$CO" run=none; PREFN=''
chk 'commit: stop config' stop_is config; chk 'commit: main unmoved' eq "$(tip main)" "$P"; chk 'commit: the note says nothing moved' has '^git tripwire: note: nothing moved: refs/heads/main is still at '; chk 'commit: no moved-note' hasnt 'has moved'
fx gg3; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main); TWPATH="$T/shimg:$SHIM:/usr/bin:/mingw64/bin"
tw merge-handsoff "Pt=$P" "Ps=$S" from=work/u1 to=main "checkout=$CO" run=none
chk 'merge-handsoff: stop config' stop_is config; chk 'merge-handsoff: main unmoved' eq "$(tip main)" "$P"; chk 'merge-handsoff: no moved-note' hasnt 'has moved'
fx gg4; S=$(mkunit work/u1 '100644:f1:x'); P=$(tip main); TWPATH=''
tw merge-unit "S=$S" "P=$P" u=u1 I=main "checkout=$CO" run=none
chk 'control: without the shim the same merge-unit merges' has '^git tripwire: tip [0-9a-f]{40}$'
DONE; fi

if CASE 'remove: an include hit in a submodule config (submodule dir modules/lib/config) is selected and never removed: stop remove, the file still there (fix it by hand)'; then
subfix sx absorbed; MG=$GD/modules/lib
printf '[include]\n\tpath = ../../../inc.cfg\n' >> "$MG/config"
tw check-checkout "checkout=$CO" run=none; L=$(hitline '^submodule dir modules/lib/config\$ ')
chk 'the include hit is there' eq "$([ -n "$L" ] && echo y)" y
sel_rm 'submodule dir' "$L"
chk 'select names it' selhas '^git tripwire: id modules/lib/config\$$'; chk 'remove: stop remove' stop_is remove; chk 'the file is still there' [ -f "$MG/config" ]; chk 'nothing was moved to removed/' bash -c "[ ! -e '$TWP/removed/index.txt' ] || ! grep -q 'submodule dir' '$TWP/removed/index.txt'"
tw check-checkout "checkout=$CO" run=none; L=$(hitline '^submodule dir modules\$ '); sel_rm 'submodule dir' "$L"; chk 'control: the modules line is still removable' has '^git tripwire: removed submodule dir$'
DONE; fi

if CASE 'check: a submodule config that cannot be read as config stops the call (config) and no hit line is printed (control: a readable one lists its hits)'; then
subfix sy absorbed; MG=$GD/modules/lib
tw check-checkout "checkout=$CO" run=none; chk 'control: readable: the modules line is listed' has '^submodule dir modules\$ '
printf '[core\nbogus = (\n' > "$MG/config"
tw check-checkout "checkout=$CO" run=none; chk 'unreadable: stop config' stop_is config; chk 'unreadable: no hit line' nohits
DONE; fi

if CASE 'merge: a global core.sparseCheckout=true overridden by a local false is not sparse: the unit merges (the effective value is asked)'; then
sp_fixture sp7 globalonly; git -C "$WT" config core.sparseCheckout false; sp_run; TWHOME=$HOME1
chk 'merges' has '^git tripwire: tip [0-9a-f]{40}$'; chk 'no sparse note' hasnt 'sparseCheckout is on'
DONE; fi

# ---------------------------------------------------------------- results
if [ -n "$SHARD" ]; then echo "$CASE_NO" > "$TW_OUTDIR/total.$SHARD"; exit 0; fi
echo
echo "$pass_n pass, $fail_n FAIL, $skip_n SKIP"
[ -z "${TW_ONLY:-}" ] || echo "partial run (TW_ONLY=$TW_ONLY): not a full pass"
if [ "$skip_n" -gt 0 ]; then
  echo "unproven (skipped):"
  printf '  %s\n' "${SKIPS[@]}"
fi
[ "$fail_n" -eq 0 ]
