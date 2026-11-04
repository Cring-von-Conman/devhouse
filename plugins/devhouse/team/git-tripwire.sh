#!/usr/bin/bash
# The git tripwire. The script is canonical for the checks; the protocol holds how to
# call it. Called as: env -i PATH=... HOME="$HOME" [XDG_CONFIG_HOME=<absolute path>, only when set] /usr/bin/bash --noprofile --norc <this file> <args folder>
set -o pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG GIT_CEILING_DIRECTORIES
export GIT_NO_REPLACE_OBJECTS=1 GIT_ATTR_NOSYSTEM=1 GIT_NO_LAZY_FETCH=1 GIT_GRAFT_FILE=/dev/null GIT_LFS_SKIP_SMUDGE=1
export GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=core.attributesFile GIT_CONFIG_VALUE_0=/dev/null GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false GIT_CONFIG_KEY_2=advice.graftFileDeprecated GIT_CONFIG_VALUE_2=false
export LC_ALL=C
# The two export lines above are this script's own copy of the release header's keys 0-2, with GIT_LFS_SKIP_SMUDGE. It has no key 3
# (safe.bareRepository) and no MSYS unset: every git command here names its repository, and `env -i` leaves the MSYS
# variables unset. The protocol's *The call* says so; check this copy whenever the release header changes.

args='' work='' out='' checkout='' gd='' ref='' NOTE=''
cleanup() {
  cd / 2>/dev/null
  case $work in "$args"/work.*) rm -rf -- "$work" 2>/dev/null ;; esac
  return 0
}
trap cleanup EXIT

# An expected stop is the normal hit path: it prints the hit lines first (the hold routes it). Every other
# label is a stop. Labels are a closed list: call args links folders reference config "common dir" entries
# worktrees hooks refs unit allowed salt expected commit merge remove.
# NOTE, when set, is one or two `git tripwire: note: ...` lines printed just before the label: it says what a stop
# after a merge, a commit or an update-ref left behind (or, for a link, which folder it was). It is never a label,
# and an expected stop, the normal hit path, prints none. That is sound because every `expected` stop (the hold) comes
# before any ref or work-tree change in every mode: a stop with that label has moved nothing.
fail() {
  if [ "$1" = expected ] && [ -n "$out" ] && [ -f "$out" ]; then cat -- "$out"; fi
  if [ -n "$NOTE" ] && [ "$1" != expected ]; then printf '%s\n' "$NOTE"; fi
  printf 'git tripwire: %s\n' "$1"
  exit 1
}

# The tools this script relies on. A missing one stops the call (`call`): the script cannot run here.
need_tools() {
  local t v maj min pat
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || fail 'call'
  for t in gawk sed grep find stat sort od tr head cat cp mv ln rm mkdir mktemp readlink sha256sum cmp dirname uname date git; do
    command -v "$t" >/dev/null 2>&1 || fail 'call'
  done
  # The GNU-only options the script uses: sed -z, sort -z, head -c, cp --remove-destination, mv -n -T, ln -T,
  # stat -c, mktemp -p, readlink, sha256sum, and find -printf and -links, cmp -s, gawk arrays of arrays.
  for t in sed sort head cp mv ln stat mktemp readlink sha256sum; do
    v=$("$t" --version 2>/dev/null)
    v=${v%%$'\n'*}
    case $v in *'GNU '*) ;; *) fail 'call' ;; esac
  done
  v=$(find --version 2>/dev/null); v=${v%%$'\n'*}
  case $v in *'GNU findutils'*) ;; *) fail 'call' ;; esac
  v=$(cmp --version 2>/dev/null); v=${v%%$'\n'*}
  case $v in *'GNU diffutils'*) ;; *) fail 'call' ;; esac
  v=$(gawk --version 2>/dev/null); v=${v%%$'\n'*}
  case $v in 'GNU Awk '*) ;; *) fail 'call' ;; esac
  gawk 'BEGIN { a[1][1] = 1; if (length(a) == 1) exit 0; exit 1 }' >/dev/null 2>&1 || fail 'call'
  v=$(git --version 2>/dev/null)
  v=${v%%$'\n'*}
  pat='^git version ([0-9]+)\.([0-9]+)\.([0-9]+)'
  [[ $v =~ $pat ]] || fail 'call'
  maj=${BASH_REMATCH[1]}; min=${BASH_REMATCH[2]}; t=${BASH_REMATCH[3]}
  if [ "$maj" -lt 2 ] || { [ "$maj" -eq 2 ] && { [ "$min" -lt 45 ] || { [ "$min" -eq 45 ] && [ "$t" -lt 3 ]; }; }; }; then fail 'call'; fi
}
need_tools

# ---------------------------------------------------------------- small helpers (none calls fail inside $( ))
isdir() { [ -d "$1" ] && [ ! -L "$1" ]; }
isfile() { [ -f "$1" ] && [ ! -L "$1" ]; }
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }

# escv <string> sets ESCV to the string as sed's `l` shows it (C escapes for \\ \a \b \f \n \r \t \v, three-digit octal for any
# other byte outside the printable ASCII range, a $ at the end); LC_ALL=C makes every character one byte. It replaces
# `printf '%s\0' "$1" | sed -z -n 'l 0' | tr '\0' '\n'`, which cost four processes a call; the two give the same text except for a CR before an LF, which MSYS `sed` drops and this keeps
# (as `\r\n`), the faithful one.
escv() {
  local s=$1 i c n
  if [[ $s != *[![:print:]]* && $s != *\\* ]]; then ESCV=$s'$'; return 0; fi
  ESCV=''
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      '\') ESCV+='\\' ;;
      $'\a') ESCV+='\a' ;;
      $'\b') ESCV+='\b' ;;
      $'\f') ESCV+='\f' ;;
      $'\n') ESCV+='\n' ;;
      $'\r') ESCV+='\r' ;;
      $'\t') ESCV+='\t' ;;
      $'\v') ESCV+='\v' ;;
      [[:print:]]) ESCV+=$c ;;
      *) printf -v n '%03o' "'$c"; ESCV+="\\$n" ;;
    esac
  done
  ESCV+='$'
}

norm() {
  local s=${1//\\//}
  while [[ $s == *//* ]]; do s=${s//\/\//\/}; done
  s=${s%/}
  if [ "$win" = 1 ]; then s=${s,,}; fi
  printf '%s' "$s"
}

# hs "string" / hf file / hl (stdin) set H to the salted hash: sha256sum of the salt, a NUL, then the value.
hs() { printf '%s\0%s' "$salt" "$1" > "$work/hs.in" || fail 'salt'; H=$(sha256sum < "$work/hs.in") || fail 'salt'; H=${H%% *}; }
hl() { H=$({ printf '%s\0' "$salt"; cat; } | sha256sum) || fail 'salt'; H=${H%% *}; }
hf() {
  if [ -L "$1" ] || [ ! -f "$1" ]; then hs 'not a file'; return 0; fi
  if ! cat -- "$1" >/dev/null 2>&1; then hs 'unreadable'; return 0; fi
  { printf '%s\0' "$salt"; cat -- "$1"; } > "$work/hs.in" && H=$(sha256sum < "$work/hs.in") || { hs 'unreadable'; return 0; }
  H=${H%% *}
}
hlink() {
  local t
  if t=$(readlink -- "$1" 2>/dev/null) && [ -n "$t" ]; then hs "link $t"; else hs 'unreadable'; fi
}

# readfile <path> <label>: sets rv. A regular file, not a link, link count 1, no CR, no NUL, one line.
readfile() {
  local f=$1 all st h s
  isfile "$f" || fail "$2"
  st=$(stat -c '%h %s' -- "$f") || fail "$2"
  h=${st% *}; s=${st#* }
  [ "$h" = 1 ] || fail "$2"
  all=''
  IFS= read -r -d '' all < "$f"
  [ "${#all}" = "$s" ] || fail "$2"
  [[ $all == *$'\r'* ]] && fail "$2"
  all=${all%$'\n'}
  [ -n "$all" ] || fail "$2"
  [[ $all == *$'\n'* ]] && fail "$2"
  rv=$all
}
# readlines <path>: the multi-line form for `paths`; sets rv to the text without its final LF.
readlines() {
  local f=$1 all st h s
  isfile "$f" || fail 'args'
  st=$(stat -c '%h %s' -- "$f") || fail 'args'
  h=${st% *}; s=${st#* }
  [ "$h" = 1 ] || fail 'args'
  all=''
  IFS= read -r -d '' all < "$f"
  [ "${#all}" = "$s" ] || fail 'args'
  [[ $all == *$'\r'* ]] && fail 'args'
  all=${all%$'\n'}
  [ -n "$all" ] || fail 'args'
  rv=$all
}

if [ "$(uname -s 2>/dev/null)" = '' ]; then fail 'args'; fi
case $(uname -s) in MINGW* | MSYS* | CYGWIN*) win=1 ;; *) win=0 ;; esac
if [ "$win" = 1 ]; then absre='^[A-Za-z]:/'; else absre='^/'; fi

good_abs() {
  local p=$1
  [[ $p =~ $absre ]] || return 1
  [[ $p == *\\* || $p == *\'* || $p == *\"* || $p == *\$* || $p == *\`* ]] && return 1
  [[ $p == *$'\n'* || $p == *$'\r'* ]] && return 1
  [[ $p == *//* ]] && return 1
  [[ "$p/" == */./* || "$p/" == */../* ]] && return 1
  return 0
}
# Plain git reads its global config and default attributes under $XDG_CONFIG_HOME/git when that is set. The call form
# passes the variable through only when it is set (`env -i` drops everything else), so its global filters and hooks are
# seen like ~/.gitconfig's. A value that is not an absolute, plain path stops the call: a relative one would resolve
# against the work folder, and on Windows only the `C:/…` form passes.
if [ -n "${XDG_CONFIG_HOME+x}" ]; then good_abs "$XDG_CONFIG_HOME" || fail 'call'; fi
re_sha='^[0-9a-f]{40}([0-9a-f]{24})?$'
re_hex64='^[0-9a-f]{64}$'
re_ref='^[A-Za-z0-9._][A-Za-z0-9._-]*(/[A-Za-z0-9._-]+)*$'
re_head='^(ref: refs/[^[:space:]]+|[0-9a-f]{40}|[0-9a-f]{64})$'
re_run='^[A-Za-z0-9._-]+-[0-9]+$'
good_ref() {
  [[ $1 =~ $re_ref ]] || return 1
  [[ "/$1/" == */./* || "/$1/" == */../* ]] && return 1
  git check-ref-format --branch "$1" >/dev/null 2>&1
}
# One relative path of a `paths` file. It travels by file into `--literal-pathspecs --pathspec-from-file`, so only
# what that file format or the work tree cannot take is refused: control characters, a backslash, a leading
# quote (the file's own quoting) or dash, an empty segment, and the `.`, `..` and `.git` (any case) segments.
good_relpath() {
  local p=$1 rest seg
  [[ $p == *[[:cntrl:]]* ]] && return 1
  [[ $p == *\\* ]] && return 1
  [[ $p == \"* ]] && return 1
  [[ $p == -* ]] && return 1
  rest=$p/
  while [ -n "$rest" ]; do
    seg=${rest%%/*}; rest=${rest#*/}
    [ -n "$seg" ] || return 1
    case ${seg,,} in . | .. | .git) return 1 ;; esac
  done
  return 0
}

# A commit message: one line (readfile has checked that), at most 200 bytes, no control character (C0, DEL, the C1
# range U+0080-U+009F, and the bidi controls U+202A-U+202E and U+2066-U+2069), valid UTF-8 (checked on the hex of its
# bytes, so no locale matters), and a subject not beginning `Merge `: the audit knows a unit merge by its subject,
# so a one-parent commit must not look like one.
cont='[89ab][0-9a-f]'
re_two="(c2[ab][0-9a-f])|((c[3-9a-f]|d[0-9a-f])$cont)"
re_e2="(e2(80([89][0-9a-f]|a[0-9f]|b[0-9a-f])|81([89][0-9a-f]|a[0-5a-f]|b[0-9a-f])|(8[2-9a-f]|9[0-9a-f]|[ab][0-9a-f])$cont))"
re_msg="^((([2-6][0-9a-f])|(7[0-9a-e]))|$re_two|(e0[ab][0-9a-f]$cont)|$re_e2|((e[13-9a-c]|e[ef])$cont$cont)|(ed[89][0-9a-f]$cont)|(f0[9ab][0-9a-f]$cont$cont)|(f[1-3]$cont$cont$cont)|(f48[0-9a-f]$cont$cont))+\$"
good_message() {
  local hx
  [ "${#1}" -le 200 ] || return 1
  [[ $1 == Merge\ * ]] && return 1
  hx=$(printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n') || return 1
  [[ $hx =~ $re_msg ]]
}

CLASSES=('hook framework file' 'worktree config' 'worktree link' 'submodule dir' 'legacy remote' 'git dir link' 'editor file' 'claude file' 'short name' 'config key' 'replace ref' 'hard link' 'info file' 'git file' 'symlink' 'gitlink' 'shallow' 'hook')
PART3=('config key' 'worktree config' 'hard link' 'hook' 'info file' 'legacy remote' 'shallow' 'git dir link' 'worktree link' 'submodule dir' 'replace ref')
in_list() { local x=$1; shift; local y; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }

# ---------------------------------------------------------------- the arguments
[ "$#" -eq 1 ] || fail 'args'
args=$1
good_abs "$args" || fail 'args'
re='^(.+)/tripwire/([A-Za-z0-9._-]+)/(args\.[A-Za-z0-9]{10})$'
[[ $args =~ $re ]] || fail 'args'
home=${BASH_REMATCH[1]}
project=${BASH_REMATCH[2]}
isdir "$home/tripwire" && isdir "$home/tripwire/$project" && isdir "$args" || fail 'folders'
tw=$home/tripwire/$project
saltf=$home/tripwire/$project.salt
runs=$tw/runs
removed=$tw/removed
allowedf=$tw/allowed

readfile "$args/mode" 'args'
mode=$rv
case $mode in
  check-unit) files=(S P I checkout run) ;;
  merge-unit) files=(S P u I checkout run) ;;
  check-checkout | close) files=(checkout run) ;;
  merge-handsoff) files=(Pt Ps from to checkout run) ;;
  commit) files=(P I checkout run paths message) ;;
  salt) files=(checkout) ;;
  select | remove) files=(checkout class id hash) ;;
  *) fail 'args' ;;
esac

fargs=(! -name mode)
for f in "${files[@]}"; do fargs+=(! -name "$f"); done
x=$(find -P "$args" -mindepth 1 -maxdepth 1 "${fargs[@]}" -print -quit 2>/dev/null) || fail 'args'
[ -z "$x" ] || fail 'args'

work=$(mktemp -d -p "$args" work.XXXXXXXXXX) || fail 'args'
good_abs "$work" || fail 'args'
case $work in "$args"/work.*) ;; *) fail 'args' ;; esac
cd "$work" || fail 'args'
export GIT_CEILING_DIRECTORIES=$args
# git's hooks folder for every command: an absolute, empty folder of ours. (A value of /dev/null becomes `nul`
# on Windows, which git then reads as <work tree>/nul/<hook>, a folder any member can make.)
mkdir -- "$work/nohooks" || fail 'args'

pathlist=()
for f in "${files[@]}"; do
  if [ "$f" = paths ]; then
    readlines "$args/paths"
    rest=$rv$'\n'
    while [ -n "$rest" ]; do
      line=${rest%%$'\n'*}; rest=${rest#*$'\n'}
      good_relpath "$line" || fail 'args'
      pathlist+=("$line")
    done
    continue
  fi
  readfile "$args/$f" 'args'
  case $f in
    S | Ps) [[ $rv =~ $re_sha ]] || fail 'args' ;;
    P | Pt) [[ $rv =~ $re_sha || $rv = none ]] || fail 'args' ;;
    u | I | from | to) good_ref "$rv" || fail 'args' ;;
    checkout)
      good_abs "$rv" || fail 'args'
      [[ $rv == */ ]] && fail 'args'
      [ "${rv##*/}" = "$project" ] || fail 'args'
      ;;
    run) [[ $rv = none || $rv =~ $re_run ]] || fail 'args' ;;
    class) in_list "$rv" "${CLASSES[@]}" || fail 'args' ;;
    hash) [[ $rv =~ $re_hex64 ]] || fail 'args' ;;
    message) good_message "$rv" || fail 'args' ;;
  esac
  printf -v "$f" '%s' "$rv"
done

printf 'git tripwire: args %s\n' "$mode"
escv "$home"; printf 'home: %s\n' "$ESCV"
escv "$project"; printf 'project: %s\n' "$ESCV"
for f in "${files[@]}"; do
  if [ "$f" = paths ]; then
    for line in "${pathlist[@]}"; do escv "$line"; printf 'paths: %s\n' "$ESCV"; done
  else
    escv "${!f}"; printf '%s: %s\n' "$f" "$ESCV"
  fi
done

gd=$checkout/.git
isdir "$checkout" || fail 'folders'

# ---------------------------------------------------------------- the salt mode
if [ "$mode" = salt ]; then
  for d in "$runs" "$removed"; do
    if [ -e "$d" ] || [ -L "$d" ]; then isdir "$d" || fail 'folders'; else mkdir -- "$d" || fail 'folders'; fi
  done
  absent "$saltf" || fail 'salt'
  t=$(mktemp -p "$work" salt.XXXXXXXXXX) || fail 'salt'
  x=$(head -c 32 /dev/urandom | od -An -v -tx1 | tr -d ' \n') || fail 'salt'
  [[ $x =~ $re_hex64 ]] || fail 'salt'
  printf '%s\n' "$x" > "$t" || fail 'salt'
  ln -T -- "$t" "$saltf" 2>/dev/null || fail 'salt'
  rm -- "$t" || fail 'salt'
  readfile "$saltf" 'salt'
  [[ $rv =~ $re_hex64 ]] || fail 'salt'
  printf 'git tripwire: salt made\n'
  exit 0
fi

# ---------------------------------------------------------------- the home's folders, the salt, the made line
isdir "$runs" && isdir "$removed" || fail 'folders'
if [ "$run" != none ]; then
  if [ -e "$runs/$run" ] || [ -L "$runs/$run" ]; then isdir "$runs/$run" || fail 'folders'; fi
fi
readfile "$saltf" 'salt'
[[ $rv =~ $re_hex64 ]] || fail 'salt'
salt=$rv
claude=$checkout/CLAUDE.md
isfile "$claude" || fail 'salt'
grep -Eq '^tripwire salt: made [^[:space:]]' -- "$claude"
case $? in 0) ;; *) fail 'salt' ;; esac

hits=$work/hits
recs=$work/recs
out=$work/out
: > "$hits"
: > "$recs"
: > "$out"

# hit <class> <display id> <hash> [raw id]. The line is printed with the escaped display id (a config key is masked
# there). recs, in $work only, holds class, escaped display id, raw id and hash, for select and remove.
hit() {
  local e
  escv "$2"; e=$ESCV
  printf '%s %s %s\n' "$1" "$e" "$3" >> "$hits"
  printf '%s\0%s\0%s\0%s\0' "$1" "$e" "${4-$2}" "$3" >> "$recs"
}

# ---------------------------------------------------------------- step 0, before git reads the repo
# submodule.recurse=false: a read-tree -u would otherwise run git inside a changed submodule, with that submodule's own
# config (hooks, filters) and refs (replace refs), none of which any hit covers. core.protectNTFS and core.protectHFS
# are pinned on: with them off (a global setting shows no hit) git writes `.claude./x` and `.git./hooks/x` through
# the Windows name folding into `.claude/` and `.git/hooks/`.
GIT_BASE=(-c core.commitGraph=false -c "core.hooksPath=$work/nohooks" -c submodule.recurse=false -c core.protectNTFS=true -c core.protectHFS=true)
g() { GIT_DIR="$gd" GIT_WORK_TREE="$checkout" git -C "$checkout" "${GIT_BASE[@]}" "$@" 2>/dev/null; }
gref() { git -C "$ref" "${GIT_BASE[@]}" "$@" 2>/dev/null; }

nonwt=0
nwl=()
wtl=()
step0_links() {
  local n p rel
  for n in '' /config /config.worktree /commondir /HEAD /objects /objects/info /objects/info/alternates /objects/info/http-alternates /refs /packed-refs /worktrees; do
    [ ! -L "$gd$n" ] || fail 'links'
  done
  [ -d "$gd" ] || fail 'folders'
  find -P "$gd" -type l -print0 > "$work/links" 2>/dev/null || fail 'links'
  while IFS= read -r -d '' p; do
    rel=${p#"$gd"/}
    if [[ $rel =~ ^worktrees/[^/]+$ ]]; then wtl+=("$rel"); else nwl+=("$rel"); nonwt=$((nonwt + 1)); fi
  done < "$work/links"
}
link_hits() {
  local rel
  for rel in "${nwl[@]}"; do hlink "$gd/$rel"; hit 'git dir link' "$rel" "$H"; done
  for rel in "${wtl[@]}"; do hlink "$gd/$rel"; hit 'worktree link' "$rel" "$H"; done
}

step0_rest() {
  local p h v e fmt
  [ -f "$gd/config" ] || fail 'config'
  absent "$gd/commondir" || fail 'common dir'
  isfile "$gd/HEAD" || fail 'folders'
  IFS= read -r v < "$gd/HEAD" || [ -n "$v" ]
  [[ $v =~ $re_head ]] || fail 'folders'
  isdir "$gd/objects" && isdir "$gd/refs" || fail 'folders'
  ref=$work/ref
  # The reference repo has the checkout's object format, so a SHA-256 checkout does not differ from it in
  # `extensions.objectformat` and `core.repositoryformatversion` alone. The value is read from the file with no
  # includes and no repo, and must be one of the two names.
  fmt=$(git config --file "$gd/config" --no-includes --get extensions.objectformat 2>/dev/null)
  case $? in 0) ;; 1) fmt=sha1 ;; *) fail 'config' ;; esac
  [[ $fmt == sha1 || $fmt == sha256 ]] || fail 'reference'
  # `git init` runs config hooks (reference-transaction) from the system and global config, and the checkout's
  # hook pairs are not known yet: so the hooks of those two scopes are switched off first, from a listing made
  # with no repository, and the hooks folder is our empty one.
  git config --list -z --includes > "$work/cfg.pre" 2>/dev/null || fail 'hooks'
  cfg_pairs "$work/cfg.pre"
  # The reference repo is made with no global and no system config at all: a gitdir/onbranch condition in an
  # [includeIf] cannot match in the listing above (no repository yet), but would match once `init` has made
  # one, and a global init.* default (a ref format, an object format) would skew what it is compared with.
  # --ref-format=files stays although GIT_CONFIG_GLOBAL=/dev/null makes it look redundant: the top of this file does
  # not unset GIT_DEFAULT_REF_FORMAT, which a caller that does not scrub its environment could set.
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "${GIT_BASE[@]}" init -q --template= --object-format="$fmt" --ref-format=files -b main "$ref" >/dev/null 2>&1 || fail 'reference'
  scan_config "$gd/config"
  if [ -e "$gd/config.worktree" ]; then isfile "$gd/config.worktree" || fail 'config'; scan_config "$gd/config.worktree"; fi
  if [ -e "$gd/worktrees" ]; then
    isdir "$gd/worktrees" || fail 'folders'
    find -P "$gd/worktrees" -mindepth 1 -maxdepth 1 -print0 > "$work/ids" 2>/dev/null || fail 'worktrees'
    while IFS= read -r -d '' p; do
      [ -L "$p" ] && continue
      isdir "$p" || continue
      if [ -e "$p/config.worktree" ]; then isfile "$p/config.worktree" || fail 'config'; scan_config "$p/config.worktree"; fi
    done < "$work/ids"
  fi
  for e in "$gd/objects/info/alternates" "$gd/objects/info/http-alternates"; do
    if [ -e "$e" ]; then
      isfile "$e" || fail 'entries'
      [ ! -s "$e" ] || fail 'entries'
    fi
  done
}
scan_config() {
  git -C "$ref" config --file "$1" --no-includes --get-regexp -z '^(include(if\..*)?\.path|core\.worktree)$' >/dev/null 2>&1
  case $? in 1) ;; *) fail 'config' ;; esac
}
# sub_include <file>: 0 when a submodule git dir's config file holds an include or includeIf key (read as a file, no
# includes followed). A file that cannot be read as config stops the call, as git would stop on it.
sub_include() {
  isfile "$1" || return 1
  git -C "$ref" config --file "$1" --no-includes --get-regexp -z '^(include|includeif)\.' >/dev/null 2>&1
  case $? in 0) return 0 ;; 1) return 1 ;; *) fail 'config' ;; esac
}

# The config pairs, from pair 3, for every scope (they sit in the command scope, so they outrank any file):
#   every hook.<name>.command gets hook.<name>.enabled=false;
#   every merge.<x>.driver and filter.<x>.clean, .smudge and .process is set to the empty value, so no command
#   named in config runs at a merge-tree, an add or a read-tree -u (a filter marked `required` then fails, which
#   stops the call); merge.renormalize is set to false (it would run a clean filter at a merge).
# VERIFY: which git version first runs config hooks and honours hook.<name>.enabled=false (the floor is 2.45.3).
cfg_pairs() { # <config list file, from config --list -z>
  local k v i=3
  gawk 'BEGIN{RS="\0"} {k=$0; j=index(k,"\n"); if (j) k=substr(k,1,j-1);
    if (k ~ /^hook\..+\.command$/) { kk="hook." substr(k,6,length(k)-13) ".enabled"; v="false" }
    else if (k ~ /^merge\..+\.driver$/ || k ~ /^filter\..+\.(clean|smudge|process)$/) { kk=k; v="" }
    else next
    if (!(kk in s)) { s[kk]=1; printf "%s\0%s\0", kk, v } }' "$1" > "$work/cfgpairs" || fail 'hooks'
  export "GIT_CONFIG_KEY_$i=merge.renormalize" "GIT_CONFIG_VALUE_$i=false"
  i=$((i + 1))
  while IFS= read -r -d '' k && IFS= read -r -d '' v; do
    export "GIT_CONFIG_KEY_$i=$k" "GIT_CONFIG_VALUE_$i=$v"
    i=$((i + 1))
  done < "$work/cfgpairs"
  export GIT_CONFIG_COUNT=$i
}

# ---------------------------------------------------------------- part 3
part3_stops() {
  local x d
  x=$(g rev-parse --path-format=absolute --git-common-dir) || fail 'common dir'
  [ "$(norm "$x")" = "$(norm "$gd")" ] || fail 'common dir'
  x=$(g rev-parse --show-toplevel) || fail 'common dir'
  [ "$(norm "$x")" = "$(norm "$checkout")" ] || fail 'common dir'
  for d in hooks info objects/info worktrees modules; do
    if [ -e "$gd/$d" ] || [ -L "$gd/$d" ]; then isdir "$gd/$d" || fail 'folders'; fi
  done
}

cfg_id() { # <key> sets cid to the masked key plus the first 8 of its salted name hash
  local k=$1 first last
  first=${k%%.*}; last=${k##*.}
  hs "$k"
  if [[ $k == *.*.* ]]; then cid="$first.<masked>.$last#${H:0:8}"; else cid="$k#${H:0:8}"; fi
}

gitdir_ok() { # <worktrees/<id> folder> : its gitdir text is drive-absolute with no // and no \
  local f=$1/gitdir all
  isfile "$f" || return 1
  all=''
  IFS= read -r -d '' all < "$f"
  all=${all%$'\n'}
  [[ $all =~ $absre ]] || return 1
  [[ $all == *//* || $all == *\\* ]] && return 1
  gdtext=$all
  return 0
}

wt_ok() { # <id> : 0 when the entry passes the five checks
  local id=$1 e all wt dot
  e=$gd/worktrees/$id
  isdir "$e" || return 1
  isfile "$e/commondir" || return 1
  all=''
  IFS= read -r -d '' all < "$e/commondir"
  all=${all%$'\n'}
  [ "$all" = '../..' ] || return 1
  gitdir_ok "$e" || return 1
  [[ $gdtext == */.git ]] || return 1
  wt=${gdtext%/.git}
  isdir "$wt" || return 1
  isfile "$wt/.git" || return 1
  all=''
  dot=''
  IFS= read -r -d '' dot < "$wt/.git"
  all=${dot%$'\n'}
  [[ $all == 'gitdir: '* ]] || return 1
  [ "$(norm "${all#gitdir: }")" = "$(norm "$e")" ] || return 1
  all=$(GIT_DIR="$e" GIT_WORK_TREE="$wt" git -C "$wt" "${GIT_BASE[@]}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$(norm "$all")" = "$(norm "$gd")" ] || return 1
  return 0
}

part3_hits() {
  local p rel k present line a b ids

  # hard links
  {
    find -P "$gd" -mindepth 1 -maxdepth 1 -type f -links +1 \( -name config -o -name config.worktree -o -name HEAD -o -name packed-refs \) -print0
    for d in hooks info; do
      if [ -d "$gd/$d" ]; then find -P "$gd/$d" -mindepth 1 -maxdepth 1 -type f -links +1 -print0; fi
    done
    if [ -d "$gd/worktrees" ]; then find -P "$gd/worktrees" -mindepth 2 -maxdepth 2 -type f -name config.worktree -links +1 -print0; fi
  } > "$work/hl" 2>/dev/null || fail 'entries'
  while IFS= read -r -d '' p; do
    rel=${p#"$gd"/}; hf "$p"; hit 'hard link' "$rel" "$H"
  done < "$work/hl"

  # config: both ways against the reference repo
  g config --local --includes --list -z > "$work/cfg.c" || fail 'config'
  gref config --local --includes --list -z > "$work/cfg.r" || fail 'config'
  gawk 'BEGIN{RS="\0"}
    FILENAME==ARGV[1] { k=$0; j=index(k,"\n"); if (j) k=substr(k,1,j-1); n=++nc[k]; c[k][n]=$0; keys[k]=1; next }
    { k=$0; j=index(k,"\n"); if (j) k=substr(k,1,j-1); n=++nr[k]; r[k][n]=$0; keys[k]=1 }
    END { for (k in keys) { if (k=="user.name" || k=="user.email") continue; d=(nc[k]!=nr[k]); if (!d) for (i=1;i<=nc[k];i++) if (c[k][i]!=r[k][i]) { d=1; break }; if (d) printf "%s\0%s\0", k, (nc[k]>0 ? "1" : "0") } }' "$work/cfg.c" "$work/cfg.r" > "$work/cfg.diff" || fail 'config'
  while IFS= read -r -d '' k && IFS= read -r -d '' present; do
    cfg_id "$k"
    if [ "$present" = 1 ]; then
      { printf '%s\0' "$salt"; K="$k" gawk 'BEGIN{RS="\0"} {s=$0; j=index(s,"\n"); if (j) s=substr(s,1,j-1); if (s==ENVIRON["K"]) printf "%s\0", $0}' "$work/cfg.c"; } > "$work/hs.in" || fail 'config'
      H=$(sha256sum < "$work/hs.in") || fail 'config'
      H=${H%% *}
    else
      hs 'absent'
    fi
    hit 'config key' "$cid" "$H" "$k"
  done < "$work/cfg.diff"

  # worktree config files
  if [ -e "$gd/config.worktree" ]; then hf "$gd/config.worktree"; hit 'worktree config' config.worktree "$H"; fi

  # worktrees
  if [ -d "$gd/worktrees" ]; then
    find -P "$gd/worktrees" -mindepth 1 -maxdepth 1 -print0 > "$work/ids" 2>/dev/null || fail 'worktrees'
    while IFS= read -r -d '' p; do
      rel=${p#"$gd"/}; k=${p##*/}
      [ -L "$p" ] && continue
      if isdir "$p" && [ -e "$p/config.worktree" ]; then hf "$p/config.worktree"; hit 'worktree config' "$rel/config.worktree" "$H"; fi
      if isdir "$p" && [ -d "$p/info" ]; then
        find -P "$p/info" -mindepth 1 -maxdepth 1 -print0 > "$work/wti" 2>/dev/null || fail 'worktrees'
        while IFS= read -r -d '' a; do hf "$a"; hit 'info file' "${a#"$gd"/}" "$H"; done < "$work/wti"
      fi
      if ! wt_ok "$k"; then
        if isdir "$p" && isfile "$p/commondir" && isfile "$p/gitdir"; then
          { printf '%s\0' "$salt"; cat -- "$p/commondir" "$p/gitdir"; } > "$work/hs.in" && H=$(sha256sum < "$work/hs.in") && H=${H%% *} || hs 'missing'
        else
          hs 'missing'
        fi
        hit 'worktree link' "$rel" "$H"
      fi
    done < "$work/ids"
  fi

  # hooks
  if [ -d "$gd/hooks" ]; then
    find -P "$gd/hooks" -mindepth 1 -maxdepth 1 ! \( -type f -name '*.sample' \) -print0 > "$work/hk" 2>/dev/null || fail 'hooks'
    while IFS= read -r -d '' p; do hf "$p"; hit hook "${p#"$gd"/}" "$H"; done < "$work/hk"
  fi

  # other entries
  for k in attributes grafts sparse-checkout; do
    if [ -e "$gd/info/$k" ] || [ -L "$gd/info/$k" ]; then hf "$gd/info/$k"; hit 'info file' "info/$k" "$H"; fi
  done
  if [ -e "$gd/shallow" ] || [ -L "$gd/shallow" ]; then hf "$gd/shallow"; hit shallow shallow "$H"; fi
  for k in remotes branches; do
    if [ -d "$gd/$k" ]; then
      find -P "$gd/$k" -mindepth 1 -maxdepth 1 -print0 > "$work/lr" 2>/dev/null || fail 'entries'
      while IFS= read -r -d '' p; do hf "$p"; hit 'legacy remote' "${p#"$gd"/}" "$H"; done < "$work/lr"
    fi
  done
  if [ -e "$gd/modules" ]; then
    # The line hashes the folder names under modules/ and, for every git dir among them (a "root": a folder holding a
    # HEAD file and an objects folder, a commondir or a config), the content of what that git dir acts on: its config
    # files (config, config.worktree, worktrees/<id>/config.worktree), commondir, hooks (bar the .sample files), info/
    # files (bar info/refs, which a repack writes and no local git reads), refs/replace/ files, objects/info/alternates
    # and http-alternates, and the replace lines of packed-refs. Every pattern is read relative to a root, so objects/
    # (bar the two alternates files), logs/, index, HEAD and every other ref are out, and a branch or a submodule named
    # info, hooks or config matches nothing by its name. Names are folded to lower case first (NTFS opens `Config` as
    # config). A config file that holds an include or includeIf key is a hit of its own (sub_include): the included file
    # is not hashed, and the hold never releases that line.
    find -P "$gd/modules" -mindepth 1 -maxdepth 1 -printf '%f\0' 2>/dev/null | sort -z > "$work/mods" || fail 'entries'
    : > "$work/modc"; : > "$work/modp"; : > "$work/modo"
    find -P "$gd/modules" -mindepth 1 -printf '%y %P\0' 2>/dev/null | LC_ALL=C gawk -v fc="$work/modc" -v fp="$work/modp" -v fo="$work/modo" 'BEGIN{RS="\0"}
      { t=substr($0,1,1); p=substr($0,3); lp=tolower(p)
        i=match(lp, /\/[^\/]*$/)
        if (i) { d=substr(lp,1,i-1); b=substr(lp,i+1) } else { d=""; b=lp }
        kid[d SUBSEP b]=t; P[++np]=p; L[np]=lp }
      END {
        for (k in kid) {
          split(k, a, SUBSEP)
          if (a[2]=="head" && kid[k]=="f" && (((a[1] SUBSEP "objects") in kid) || ((a[1] SUBSEP "commondir") in kid) || ((a[1] SUBSEP "config") in kid))) root[a[1]]=1
        }
        for (j=1; j<=np; j++) for (d in root) {
          if (d=="") r=L[j]; else if (index(L[j], d "/")==1) r=substr(L[j], length(d)+2); else continue
          f=""
          if (r=="config" || r=="config.worktree" || r ~ /^worktrees\/[^\/]+\/config\.worktree$/) f=fc
          else if (r=="packed-refs") f=fp
          else if (r=="commondir" || r=="objects/info/alternates" || r=="objects/info/http-alternates") f=fo
          else if (r ~ /^hooks\// && r !~ /^hooks\/[^\/]*\.sample$/) f=fo
          else if (r ~ /^info\// && r != "info/refs") f=fo
          else if (r ~ /^refs\/replace\//) f=fo
          if (f != "") { printf "%s\0", P[j] > f; break }
        }
      }' || fail 'entries'
    : > "$work/modh"
    for k in modc modp modo; do
      sort -z "$work/$k" > "$work/$k.s" || fail 'entries'
      while IFS= read -r -d '' p; do
        p=$gd/modules/$p
        if [ "$k" = modp ] && isfile "$p"; then
          grep -a -- ' refs/replace/' "$p" > "$work/pr.tmp" 2>/dev/null
          case $? in 0 | 1) ;; *) fail 'entries' ;; esac
          hf "$work/pr.tmp"
        else
          hf "$p"
          if [ "$k" = modc ] && sub_include "$p"; then hit 'submodule dir' "${p#"$gd"/}" "$H"; fi
        fi
        printf '%s\0%s\0' "${p#"$gd"/}" "$H" >> "$work/modh"
      done < "$work/$k.s"
    done
    { cat -- "$work/mods"; printf 'content\0'; cat -- "$work/modh"; } > "$work/modall" || fail 'entries'
    hl < "$work/modall"
    hit 'submodule dir' modules "$H"
  fi
  g for-each-ref --format='%(refname)%00%(objectname)%00' refs/replace/ > "$work/rr" || fail 'refs'
  while IFS= read -r -d '' k && IFS= read -r -d '' a; do
    hs "$k $a"
    hit 'replace ref' "$k" "$H"
  done < "$work/rr"
}

# ---------------------------------------------------------------- parts 1 and 2
unit_hits() { # <base treeish> <tip treeish>
  g diff --raw -z --ignore-submodules=none --no-renames --no-abbrev --no-relative "$1" "$2" > "$work/diff" || fail 'unit'
  LC_ALL=C gawk 'BEGIN{RS="\0"}
    NR%2==1 { meta=$0; next }
    { path=$0; split(meta, m, " "); nm=m[2]; noid=m[4];
      lp=tolower(path); gsub(/\\/, "/", lp); n=split(lp, seg, "/");
      # Windows folds a name before it meets the file system: a backslash is a separator, a stream suffix (:...) and
      # trailing dots and spaces are dropped, so `.claude.` and `.claude::$INDEX_ALLOCATION` are `.claude`, and `.git.`
      # is `.git`.
      for (i=1;i<=n;i++) { sub(/:.*$/, "", seg[i]); sub(/[. ]+$/, "", seg[i]) }
      last=seg[n];
      if (nm=="120000") printf "symlink\0%s\0%s %s\0", path, nm, noid;
      else if (nm=="160000") printf "gitlink\0%s\0%s %s\0", path, nm, noid;
      for (i=1;i<=n;i++) if (seg[i] ~ /~[0-9]/) { printf "short name\0%s\0%s %s\0", path, nm, noid; break }
      cls="";
      if (last==".gitattributes" || last==".gitmodules" || last==".lfsconfig" || last==".mailmap") cls="git file";
      for (i=1;i<=n;i++) if (seg[i]==".git") cls="git file";
      if (cls=="") {
        if (last==".pre-commit-config.yaml" || last ~ /^\.?lefthook(-local)?\.(yml|yaml|toml|json)$/) cls="hook framework file";
        for (i=1;i<n;i++) if (seg[i]==".husky") cls="hook framework file";
      }
      if (cls=="") {
        if (last==".mcp.json" || last=="claude.local.md" || (last=="claude.md" && n>1)) cls="claude file";
        for (i=1;i<=n;i++) if (seg[i]==".claude") cls="claude file";
      }
      if (cls=="") {
        if (last==".envrc") cls="editor file";
        if (n>1 && seg[n-1]==".vscode" && (last=="tasks.json" || last=="settings.json" || last=="launch.json")) cls="editor file";
      }
      if (cls!="") printf "%s\0%s\0%s %s\0", cls, path, nm, noid }' "$work/diff" > "$work/uh" || fail 'unit'
  local c p v
  while IFS= read -r -d '' c && IFS= read -r -d '' p && IFS= read -r -d '' v; do
    hs "$v"
    hit "$c" "$p" "$H"
  done < "$work/uh"
}

# ---------------------------------------------------------------- the allowed set, the output and the hold
parse_line() { # sets pcls pid phs ; 0 when the line is <class> <id> <64 hex>
  local line=$1 rest c
  [[ $line =~ ^(.*)\ ([0-9a-f]{64})$ ]] || return 1
  rest=${BASH_REMATCH[1]}; phs=${BASH_REMATCH[2]}
  for c in "${CLASSES[@]}"; do
    if [[ $rest == "$c "* ]]; then pcls=$c; pid=${rest#"$c "}; [ -n "$pid" ] && return 0; return 1; fi
  done
  return 1
}
never_allowed() { # <class> <id>
  local k sec var
  case $1 in
    'worktree config' | 'git dir link' | 'hard link' | 'worktree link' | 'submodule dir' | 'replace ref') return 0 ;;
    'info file') k=${2%\$}; [[ $k == info/grafts || $k == */info/grafts ]] && return 0; return 1 ;;
    'config key')
      k=${2%#*}
      sec=${k%%.*}; var=${k##*.}
      sec=${sec,,}; var=${var,,}
      case $sec in
        hook | include | includeif | http) return 0 ;;
        core) case $var in hookspath | fsmonitor | worktree | attributesfile | alternaterefscommand | sshcommand | gitproxy | askpass) return 0 ;; esac ;;
        extensions) case $var in worktreeconfig | partialclone) return 0 ;; esac ;;
        credential) [ "$var" = helper ] && return 0 ;;
        remote) case $var in uploadpack | receivepack | vcs | proxy) return 0 ;; esac ;;
        protocol) [ "$var" = allow ] && return 0 ;;
      esac
      return 1
      ;;
  esac
  return 1
}

prep_allowed() {
  local line
  # the three placeholder hashes are never allowed: a line carrying one is dropped on read
  hs 'not a file'; ph1=$H; hs 'unreadable'; ph2=$H; hs 'missing'; ph3=$H
  if [ -e "$allowedf" ] || [ -L "$allowedf" ]; then
    isfile "$allowedf" || fail 'allowed'
    cat -- "$allowedf" > "$work/allowed.raw" 2>/dev/null || fail 'allowed'
  else
    : > "$work/allowed.raw"
  fi
  : > "$work/allowed.clean"
  while IFS= read -r line || [ -n "$line" ]; do
    parse_line "$line" || continue
    in_list "$pcls" "${PART3[@]}" || continue
    never_allowed "$pcls" "$pid" && continue
    if [ "$phs" = "$ph1" ] || [ "$phs" = "$ph2" ] || [ "$phs" = "$ph3" ]; then continue; fi
    printf '%s\n' "$line" >> "$work/allowed.clean"
  done < "$work/allowed.raw"
}

finalize() { # the sorted hits, minus the allowed lines, into $out
  LC_ALL=C sort "$hits" > "$work/sorted" || fail 'allowed'
  grep -Fxv -f "$work/allowed.clean" "$work/sorted" > "$out" 2>/dev/null
  case $? in 0 | 1) ;; *) fail 'allowed' ;; esac
}

# The hold. Every line of $out must be released, by the file that fits it:
#   a line inside hidden/ is in `hidden` and in `hidden-released`; any other line is in `expected` and in `released`.
# A hook config key (any `hook.` section), a worktree config file and the extensions.worktreeConfig key are never
# released, so they stop here whatever the run files say (a config.worktree is read by git as config, so a hook or a
# core.hooksPath in one would escape the hook rule). So is a `submodule dir` line with any id but `modules`: it names
# a submodule config file that holds an include. The id rule turns the manager's split of the lines into a check:
# an `expected` line never has an id under hidden/, a `hidden` line always does. A line found in a file and no longer
# in the output is no failure. grep's exit 1, no line left over, is the pass; any other status stops.
# hold_ok returns 1 where the hold stops; hold stops the call.
hold_ok() {
  local rd f line s
  [ -s "$out" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    parse_line "$line" || continue
    case $pcls in
      'worktree config') return 1 ;;
      'submodule dir') [ "${pid%\$}" = modules ] || return 1 ;;
      'config key')
        s=${pid%%.*}; s=${s,,}
        [ "$s" != hook ] || return 1
        s=${pid%\#*}; s=${s,,}
        [ "$s" != extensions.worktreeconfig ] || return 1
        ;;
    esac
  done < "$out"
  [ "$run" != none ] || return 1
  rd=$runs/$run
  isdir "$rd" || return 1
  for f in expected hidden released hidden-released; do
    isfile "$rd/$f" || return 1
    cat -- "$rd/$f" > "$work/h.$f" 2>/dev/null || return 1
  done
  while IFS= read -r line || [ -n "$line" ]; do
    parse_line "$line" || continue
    s=${pid,,}
    [[ $s != hidden/* ]] || return 1
  done < "$work/h.expected"
  while IFS= read -r line || [ -n "$line" ]; do
    parse_line "$line" || continue
    s=${pid,,}
    [[ $s == hidden/* ]] || return 1
  done < "$work/h.hidden"
  cat "$work/h.expected" "$work/h.hidden" > "$work/h.eh" || return 1
  grep -Fxv -f "$work/h.eh" "$out" >/dev/null 2>&1
  case $? in 1) ;; *) return 1 ;; esac
  grep -Fx -f "$work/h.hidden" "$out" > "$work/o.hid" 2>/dev/null
  case $? in 0 | 1) ;; *) return 1 ;; esac
  grep -Fxv -f "$work/h.hidden" "$out" > "$work/o.rest" 2>/dev/null
  case $? in 0 | 1) ;; *) return 1 ;; esac
  grep -Fxv -f "$work/h.hidden-released" "$work/o.hid" >/dev/null 2>&1
  case $? in 1) ;; *) return 1 ;; esac
  grep -Fxv -f "$work/h.released" "$work/o.rest" >/dev/null 2>&1
  case $? in 1) ;; *) return 1 ;; esac
  return 0
}
hold() { hold_ok || fail 'expected'; }

# ---------------------------------------------------------------- refs and shas
tip_is() { # <ref name> <expected sha or none>
  local r rc
  r=$(g rev-parse --verify -q "refs/heads/$1^{commit}")
  rc=$?
  case $rc in
    0) [ "$2" != none ] && [ "$r" = "$2" ] || fail 'unit' ;;
    1) [ "$2" = none ] || fail 'unit' ;;
    *) fail 'refs' ;;
  esac
}
head_is() { # <branch> <label>
  local r
  r=$(g symbolic-ref -q HEAD)
  [ "$r" = "refs/heads/$1" ] || fail "$2"
}
commit_exists() {
  local r
  r=$(g rev-parse --verify -q "$1^{commit}") || fail 'unit'
  [ "$r" = "$1" ] || fail 'unit'
}

# ---------------------------------------------------------------- run
step0_links
link_cls_only=0
if [ "$nonwt" -gt 0 ]; then
  case $mode in
    check-unit | check-checkout)
      printf 'git tripwire: note: partial output, links under .git were listed and nothing else was read\n'
      link_hits
      prep_allowed
      finalize
      cat -- "$out"
      exit 0
      ;;
    select | remove)
      case $class in 'git dir link' | 'worktree link') link_cls_only=1 ;; *) fail 'links' ;; esac
      ;;
    *) fail 'links' ;;
  esac
fi

if [ "$link_cls_only" = 0 ]; then
  step0_rest
  g config --includes --list -z > "$work/cfg.all" || fail 'hooks'
  cfg_pairs "$work/cfg.all"
  part3_stops
fi

# ---------------------------------------------------------------- removal helpers
today=$(date -u +%Y%m%d) || fail 'remove'
seld='' # the selected item's escaped display id: what select prints and index.txt logs (a config key stays masked)
index_line() { # <class> <hash or label>
  local ix=$removed/index.txt
  if [ -e "$ix" ] || [ -L "$ix" ]; then isfile "$ix" || fail 'remove'; fi
  printf '%s %s %s %s\n' "$today" "$1" "$seld" "$2" >> "$ix" || fail 'remove'
}
free_slot() { # sets slot and slotn to the first unused removed/<yyyymmdd>-<n> (and <yyyymmdd>-<n>.config)
  slotn=1
  while :; do
    slot=$removed/$today-$slotn
    absent "$slot" && absent "$slot.config" && break
    slotn=$((slotn + 1))
  done
}
never_removed() { # compared in lower case: the work tree's folders may be case-folded
  case ${1,,} in
    head | config | packed-refs | index | objects | objects/* | refs | refs/* | logs | logs/*) return 0 ;;
  esac
  return 1
}
remove_link() { # <class> <raw id>
  local x=$gd/$2
  [ -L "$x" ] || fail 'remove'
  never_removed "$2" && fail 'remove'
  hlink "$x"
  index_line "$1" "$H"
  rm -- "$x" 2>/dev/null || fail 'remove'
  absent "$x" || fail 'remove'
}
remove_path() { # <class> <raw id>
  local x=$gd/$2 l v1 v2 n
  [ -e "$x" ] && [ ! -L "$x" ] || fail 'remove'
  if [ -d "$x" ]; then
    l=$(find -P "$x" -type l -print -quit 2>/dev/null) || fail 'remove'
    [ -z "$l" ] || fail 'remove'
  else
    [ -f "$x" ] || fail 'remove'
    n=$(stat -c %h -- "$x") || fail 'remove'
    [ "$n" = 1 ] || fail 'remove'
  fi
  v1=$(stat -c %d -- "$x") || fail 'remove'
  v2=$(stat -c %d -- "$removed") || fail 'remove'
  [ "$v1" = "$v2" ] || fail 'remove'
  free_slot
  mv -n -T -- "$x" "$slot" 2>/dev/null || fail 'remove'
  absent "$x" || fail 'remove'
  [ -e "$slot" ] || fail 'remove'
  index_line "$1" "moved to $today-$slotn"
}
remove_hardlink() { # <raw id>
  local x=$gd/$1 n c
  isfile "$x" || fail 'remove'
  n=$(mktemp -p "$(dirname -- "$x")" tw.XXXXXXXXXX) || fail 'remove'
  cp --remove-destination -- "$x" "$n" 2>/dev/null || { rm -f -- "$n"; fail 'remove'; }
  mv -f -- "$n" "$x" 2>/dev/null || { rm -f -- "$n"; fail 'remove'; }
  isfile "$x" || fail 'remove'
  c=$(stat -c %h -- "$x") || fail 'remove'
  [ "$c" = 1 ] || fail 'remove'
  index_line 'hard link' 'broken'
}
cfg_records() { # <list file> <key> : the key's records, NUL-terminated
  K="$2" gawk 'BEGIN{RS="\0"} {s=$0; j=index(s,"\n"); if (j) s=substr(s,1,j-1); if (s==ENVIRON["K"]) printf "%s\0", $0}' "$1"
}
# A config record (the key, a newline, the value) that may hold a credential: a URL with a userinfo part, or one of
# the words below in any case. Over-matching costs only a restore by hand. remove_key saves raw records only for the
# core and branch sections, and then only when this finds nothing.
looks_cred() { # <record>
  local s=${1,,}
  [[ $s == *://*@* ]] && return 0
  case $s in *extraheader* | *credential.* | *pass* | *token* | *secret* | *bearer* | *auth* | *sshcommand*) return 0 ;; esac
  return 1
}
restore_fail() { # <the removal's outcome label> <stop label>: a stop after the unset
  index_line 'config key' "restore failed after the unset; $1"
  fail "$2"
}
remove_key() { # <raw key>
  local key=$1 rec val lk label=edited n=0 cred=0 hl='' cslot
  lk=${key,,}
  # Keys that decide how git reads the repository are fixed by hand, whatever the human was asked.
  [ "$lk" != core.repositoryformatversion ] || fail 'remove'
  if [ "${lk%%.*}" = extensions ] && [ "$lk" != extensions.worktreeconfig ]; then fail 'remove'; fi
  # The records about to go are kept as <date>-<n>.config only for the core and branch sections, and only when
  # neither the key nor a value may hold a credential: removed/ is on the readers' list and would be a second
  # plaintext copy of a token. Otherwise the index keeps the masked id, the record count and each record's salted
  # hash, and the human restores by hand.
  cfg_records "$work/cfg.c" "$key" > "$work/k.saved" || fail 'remove'
  case ${lk%%.*} in core | branch) ;; *) cred=1 ;; esac
  while IFS= read -r -d '' rec; do
    n=$((n + 1))
    if looks_cred "$rec"; then cred=1; fi
    hs "$rec"; hl="$hl $H"
  done < "$work/k.saved"
  if [ "$n" -gt 0 ]; then
    if [ "$cred" = 1 ]; then
      label="edited; not saved: may hold a credential; restore by hand; records: $n; salted hashes:$hl"
    else
      free_slot
      cslot=$slot.config
      # the index line comes first, so a saved record is never without one; the slot is made exclusively, and a
      # half-written one is removed
      index_line 'config key' "saving $n records to $today-$slotn.config"
      if ! ( set -o noclobber; : > "$cslot" ) 2>/dev/null; then
        index_line 'config key' 'save failed; nothing was removed'
        fail 'remove'
      fi
      if ! cat -- "$work/k.saved" >> "$cslot" 2>/dev/null || ! cmp -s "$work/k.saved" "$cslot"; then
        rm -f -- "$cslot"
        index_line 'config key' 'save failed; nothing was removed'
        fail 'remove'
      fi
      label="edited; records saved to $today-$slotn.config"
    fi
  fi
  g config --local --unset-all -- "$key"
  case $? in
    0 | 5) ;;
    *)
      # a `saving` line may already stand: say how it ended (the slot is kept, the key is still set)
      if [ "$n" -gt 0 ] && [ "$cred" = 0 ]; then index_line 'config key' 'unset failed; records saved; nothing was removed from config'; fi
      fail 'remove'
      ;;
  esac
  # from here the key is gone: every stop ends the index line with what was kept (on the credential path the count and
  # the salted hashes, which are nowhere else)
  cfg_records "$work/cfg.r" "$key" > "$work/k.ref" || restore_fail "$label" 'remove'
  while IFS= read -r -d '' rec; do
    [[ $rec == *$'\n'* ]] || restore_fail "$label" 'remove'
    val=${rec#*$'\n'}
    g config --local --add -- "$key" "$val" || restore_fail "$label" 'remove'
  done < "$work/k.ref"
  g config --local --includes --list -z > "$work/cfg.c2" || restore_fail "$label" 'config'
  cfg_records "$work/cfg.c2" "$key" > "$work/k.now" || restore_fail "$label" 'remove'
  cmp -s "$work/k.ref" "$work/k.now" || restore_fail "$label" 'remove'
  index_line 'config key' "$label"
}
# Prune only when every entry passes the gitdir pattern and the selected one is the only stale entry: `worktree
# prune` takes every stale entry, not the one chosen. With another stale entry, the selected folder is moved.
remove_stale_worktree() { # <raw id>
  local p id other=0
  find -P "$gd/worktrees" -mindepth 1 -maxdepth 1 -print0 > "$work/ids2" 2>/dev/null || fail 'remove'
  while IFS= read -r -d '' p; do
    [ -L "$p" ] && fail 'remove'
    gitdir_ok "$p" || fail 'remove'
    id=${p##*/}
    [ "$id" = "${1#worktrees/}" ] || wt_ok "$id" || other=1
  done < "$work/ids2"
  if [ "$other" = 1 ]; then remove_path 'worktree link' "$1"; return 0; fi
  g worktree prune || fail 'remove'
  absent "$gd/$1" || fail 'remove'
  index_line 'worktree link' 'pruned'
}

# ---------------------------------------------------------------- the merge helpers
# No leading folder of a path may be a link in the checkout. A junction or a symlink in the shared work tree that
# nobody tracks (so no part-3 line, and `info/exclude` hides it) makes git write a tracked path through it: `foo`
# pointing at `.claude`, and a unit adding `foo/settings.local.json`, lands in `.claude/`. The folders are named by
# the diff of the two trees (adds, modifies and deletes), as the checkout sees them; a backslash counts as a
# separator, as it does on Windows. Any link stops the call (`unit`).
lead_walk() { # <relative path>
  local rest=${1//\\//} acc=$checkout seg
  while [[ $rest == */* ]]; do
    seg=${rest%%/*}; rest=${rest#*/}
    acc=$acc/$seg
    if [ -z "${leadseen[$acc]-}" ]; then
      leadseen[$acc]=1
      if [ -L "$acc" ]; then
        escv "${acc#"$checkout"/}"
        NOTE="git tripwire: note: the leading folder $ESCV is a link in the checkout${NOTE:+$'\n'$NOTE}"
        fail 'unit'
      fi
    fi
  done
}
declare -A leadseen
lead_check() { # <base treeish> <tip treeish>
  local p
  leadseen=()
  g diff --name-only -z --ignore-submodules=none --no-renames --no-abbrev --no-relative "$1" "$2" > "$work/lead.z" || fail 'unit'
  while IFS= read -r -d '' p; do lead_walk "$p"; done < "$work/lead.z"
}
lead_check_list() { # the `paths` of a commit
  local p
  leadseen=()
  for p in "${pathlist[@]}"; do lead_walk "$p"; done
}
# The tree a merge of <theirs> into <ours> would make, made without touching the index or the work tree. Attributes
# come from <ours>' own tree, never from the work tree, so an untracked .gitattributes drives nothing. The folders
# the merge would write into are checked for links before and after the tree is known (the diff of <ours> and
# <theirs> holds every path the tree can change, bar a directory rename; the diff of <ours> and the tree holds them all).
merged_tree() { # <ours> <theirs> : sets t
  lead_check "$1" "$2"
  t=$(g --attr-source="$1" -c gc.auto=0 -c maintenance.auto=false merge-tree --write-tree --no-messages "$1" "$2") || fail 'merge'
  [[ $t =~ $re_sha ]] || fail 'merge'
  lead_check "$1" "$t"
}
# After a failed update-ref, where the branch is now decides the note: the update-ref may have failed after it moved.
ref_note() { # <branch> <old> <new>
  local r
  r=$(g rev-parse --verify -q "refs/heads/$1^{commit}")
  if [ "$r" = "$2" ]; then NOTE="git tripwire: note: nothing moved: refs/heads/$1 is still at $2"
  elif [ "$r" = "$3" ]; then NOTE="git tripwire: note: refs/heads/$1 has moved to $3; the work tree was not written"
  else NOTE="git tripwire: note: refs/heads/$1 is at ${r:-an unreadable value}, not at $2 or $3; the work tree was not written"; fi
}
# The filters. Every command this script runs has the config's filter commands blanked (cfg_pairs), so a path whose
# `filter` attribute names a driver the config defines would be written as stored (a merge) or committed raw (a
# commit: a scrubbing clean filter would not scrub), and a driver marked `required` would die after the branch moved.
# So the paths a merge would write, or a commit would add, are asked for their `filter` attribute, and a path that
# names any driver the config defines (a clean, smudge or process command, or `required`) stops the call with nothing
# moved. The driver names are read from cfg.all, `git config --includes --list` run through g: every scope (system,
# global, local, the worktree config, what they include, and the command scope). The blank pairs only add empty
# values for names already listed, so no name is hidden. check-attr runs no filter.
# A merge asks from the attribute source the merge uses (<ours>' tree, plus .git/info/attributes). A commit asks from
# the union of the sources plain git's `add` would use (the harm is measured against plain git, not against this
# script's pinned `add`): P's tree; the new tree; the work tree's and the index's .gitattributes; and the global or
# default attributes file with the system one. The last two are one call (`wide`, no attribute source) that drops the
# pins on the global and system files: only the attribute sources widen, the call still goes through every other
# pin. At a merge those wider sources only change how a file is written as stored: nothing is run and nothing
# scrubbed is lost, so the merge asks only the one source.
# The check over-matches, and fails closed: it counts gitlinks and symlinks (no filter touches them), a driver named
# `set`, `unset` or `unspecified` (those are attribute states), and, at a commit, a path that is only deleted (a merge
# skips deletions: no clean filter runs on a deleted path) and a path whose driver is named by one source while another
# source (the work tree's `-filter`) unsets it, where plain git would store the file raw too and the stop prevents no harm.
# names_z <label> <base> <tip>: the paths that go from <base> to <tip> (no deletions), NUL-ended, in $work/fin
names_z() {
  : > "$work/fhits"
  g diff --name-only -z --diff-filter=d --ignore-submodules=none --no-renames --no-abbrev --no-relative "$2" "$3" > "$work/fin" || fail "$1"
}
# filter_scan <label> <attr source, or '' for none> [wide]: $work/fin holds the paths; the paths that name a defined
# driver are added to $work/fhits (emptied where fin is written); sets fcount to the number of distinct ones so far.
# `wide` keeps the global and system attribute files: the pair that sets core.attributesFile to /dev/null is replaced
# by a copy of the fsmonitor pair, and GIT_ATTR_NOSYSTEM is off. With no attribute source the call also reads the work
# tree's and the index's .gitattributes, as plain git does.
fcount=0
filter_scan() {
  local label=$1 src=${2-} wide=${3-} a=()
  if [ -s "$work/fin" ]; then
    [ -z "$src" ] || a=("--attr-source=$src")
    (
      if [ -n "$wide" ]; then export GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false GIT_ATTR_NOSYSTEM=0; fi
      g "${a[@]}" check-attr --stdin -z filter
    ) < "$work/fin" > "$work/fattr" || fail "$label"
    gawk 'BEGIN{RS="\0"}
      FILENAME==ARGV[1] {
        k=$0; j=index(k,"\n"); v=""; if (j) { v=substr(k,j+1); k=substr(k,1,j-1) }
        if (match(k, /^filter\.(.+)\.(clean|smudge|process)$/, m)) drv[m[1]]=1
        else if (match(k, /^filter\.(.+)\.required$/, m)) { lv=tolower(v); if (j==0 || !(lv=="" || lv=="false" || lv=="no" || lv=="off" || lv=="0")) drv[m[1]]=1 }
        next }
      { r=(FNR-1)%3; if (r==0) pth=$0; else if (r==2 && ($0 in drv)) printf "%s\0", pth }' "$work/cfg.all" "$work/fattr" >> "$work/fhits" || fail "$label"
  fi
  fcount=$(sort -z -u "$work/fhits" | tr -cd '\0' | wc -c) || fail "$label"
  fcount=${fcount//[[:space:]]/}
  [[ $fcount =~ ^[0-9]+$ ]] || fail "$label"
}
# What would stop a merge before it begins, whatever the unit holds: set swhy (empty when nothing). A pending merge,
# cherry-pick, revert or rebase, and a staged index, are kept by `read-tree -m` where `git merge` would refuse them
# (the branch would move past them); core.sparseCheckout (in any scope: the effective value is asked, as read-tree
# reads it) or any skip-worktree entry makes `read-tree -m -u` re-apply the sparse patterns to paths the unit never
# names, so a file outside the unit is written, and smudged through a filter the filter check never saw.
marker_present() {
  local x
  for x in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer; do
    if [ -e "$gd/$x" ] || [ -L "$gd/$x" ]; then return 0; fi
  done
  return 1
}
# A stale .git/index.lock (a killed or crashed git, an antivirus scan) makes the index writes fail after the branch has
# moved, which plain `git commit` and `git merge` refuse up front. So it is looked for before any ref moves; the one
# race that remains (a lock made between this check and the write) is a stated limit.
LOCKWHY='.git/index.lock exists (a git command is running, or one was killed and left it behind)'
lock_present() { [ -e "$gd/index.lock" ] || [ -L "$gd/index.lock" ]; }
# A guard the project has that this script does not run: the hook files and hooks path git would run, and the two
# frameworks that install them. A note only (no value is printed): the human runs the guard themselves.
#
# Two steps, so that nothing in the note can stop the call after a branch has moved: guard_cfg, the one step that can
# fail (it reads the config dump), runs before update-ref; guard_note, which cannot fail, runs after the merge or commit
# (a unit can bring in a .husky folder, so the file tests look at the work tree as it is then) and sets GNOTE, which is
# printed last.
GHP=0
GNOTE=''
guard_cfg() {
  gawk -v nh="$work/nohooks" 'BEGIN{RS="\0"} { k=$0; j=index(k,"\n"); v=""; if (j) { v=substr(k,j+1); k=substr(k,1,j-1) } if (tolower(k)=="core.hookspath" && v != nh) f=1 } END { exit f ? 0 : 1 }' "$work/cfg.all"
  case $? in 0) GHP=1 ;; 1) GHP=0 ;; *) fail 'config' ;; esac
}
guard_note() {
  local x found=''
  for x in pre-commit commit-msg pre-merge-commit; do
    if [ -f "$gd/hooks/$x" ] && [ ! -L "$gd/hooks/$x" ]; then found+=" .git/hooks/$x"; fi
  done
  if [ "$GHP" = 1 ]; then found+=' core.hooksPath'; fi
  if [ -e "$checkout/.pre-commit-config.yaml" ]; then found+=' .pre-commit-config.yaml'; fi
  if [ -e "$checkout/.husky" ]; then found+=' .husky/'; fi
  if [ -n "$found" ]; then
    printf -v GNOTE 'git tripwire: note: this project has a pre-commit guard (%s) that devhouse commits and merges do not run; run it yourself over the commits since your last push, not only the current files: a secret committed and later removed stays in history' "${found# }"
  fi
}
commit_filter_stop() { # after filter_scan in `commit`: a path that names a defined driver stops it, nothing moved
  [ "$fcount" -gt 0 ] || return 0
  NOTE="git tripwire: note: nothing moved: $fcount path(s) the commit would add name a filter driver the config defines (a clean filter would not run); refs/heads/$I $rstate"
  fail 'commit'
}
swhy=''
merge_state_why() { # <ours>
  local sp rc
  swhy=''
  if lock_present; then swhy=$LOCKWHY; return 0; fi
  if marker_present; then swhy='a merge, cherry-pick, revert or rebase is pending in the checkout'; return 0; fi
  g diff-index --cached --name-only -z --ignore-submodules=none --no-renames --no-abbrev --no-relative "$1" > "$work/staged" || fail 'merge'
  if [ -s "$work/staged" ]; then swhy='the index holds staged changes'; return 0; fi
  sp=$(g config --type=bool --get core.sparseCheckout)
  rc=$?
  case $rc in
    0) if [ "$sp" = true ]; then swhy='core.sparseCheckout is on'; return 0; fi ;;
    1) ;;
    *) fail 'merge' ;;
  esac
  g ls-files -t -z > "$work/lst" || fail 'merge'
  gawk 'BEGIN{RS="\0"} substr($0,1,2)=="S " { f=1 } END { exit f ? 0 : 1 }' "$work/lst"
  case $? in
    0) swhy='an index entry is marked skip-worktree' ;;
    1) ;;
    *) fail 'merge' ;;
  esac
}

# Merge <theirs> into the checked-out <branch> (tip <ours>) without `git merge`, whose result depends on
# branch.<b>.mergeOptions, pull.twohead and merge.* config that merge-tree (where the hits were read) ignores. The
# merge commit is built from the tree merged_tree made, so its tree is that tree by construction; the parents and
# the tree are read back before anything moves. A dry run of the work tree update comes first, so a dirty or
# colliding file stops the call with nothing moved. NOTE says what a stop leaves behind; fail prints it.
do_merge() { # <branch> <ours> <theirs> <subject> : sets new
  local br=$1 ours=$2 theirs=$3 subj=$4
  NOTE="git tripwire: note: nothing moved: refs/heads/$br is still at $ours"
  merge_state_why "$ours"
  if [ -n "$swhy" ]; then
    NOTE="git tripwire: note: nothing moved: $swhy; refs/heads/$br is still at $ours"
    fail 'merge'
  fi
  lead_check "$ours" "$t"
  names_z merge "$ours" "$t"
  filter_scan merge "$ours"
  if [ "$fcount" -gt 0 ]; then
    NOTE="git tripwire: note: nothing moved: $fcount path(s) the merge would write name a filter driver the config defines; refs/heads/$br is still at $ours"
    fail 'merge'
  fi
  new=$(g commit-tree --no-gpg-sign -p "$ours" -p "$theirs" -m "$subj" "$t") || fail 'merge'
  [[ $new =~ $re_sha ]] || fail 'merge'
  [ "$(g rev-parse --verify "$new^1")" = "$ours" ] || fail 'merge'
  [ "$(g rev-parse --verify "$new^2")" = "$theirs" ] || fail 'merge'
  [ "$(g rev-parse --verify "$new^{tree}")" = "$t" ] || fail 'merge'
  # read-tree -m takes an index whose stat data is current, as `git merge` makes it first; a file that really
  # differs stays "needs update" (exit 1) and the dry run below stops the call if the merge would touch it
  # (the refresh rehashes every stat-dirty tracked file through its clean or process filter, blanked here: for a driver
  # marked `required` the blanked filter fails, so a stat-dirty file anywhere in the tree stops the merge, whatever
  # the unit holds, and `check-unit` cannot foresee it)
  g --attr-source="$ours" update-index -q --refresh >/dev/null
  case $? in
    0 | 1) ;;
    *)
      NOTE="git tripwire: note: nothing moved: the index refresh failed; the usual cause is a filter marked required meeting a tracked file the unit does not touch: a plain git status, run by the human outside the team, refreshes a file whose stat data is stale, and a filtered file that really changed has to be committed or restored; refs/heads/$br is still at $ours"
      fail 'merge'
      ;;
  esac
  g --attr-source="$ours" read-tree -m -u -n --no-recurse-submodules "$ours" "$new" >/dev/null || fail 'merge'
  if lock_present; then
    NOTE="git tripwire: note: nothing moved: $LOCKWHY; refs/heads/$br is still at $ours"
    fail 'merge'
  fi
  if ! g update-ref "refs/heads/$br" "$new" "$ours"; then ref_note "$br" "$ours" "$new"; fail 'merge'; fi
  NOTE="git tripwire: note: refs/heads/$br has moved to $new; the work tree may be partly written"
  g --attr-source="$ours" read-tree -m -u --no-recurse-submodules "$ours" "$new" >/dev/null || fail 'merge'
  NOTE=''
}

# ---------------------------------------------------------------- the modes
case $mode in
  select | remove)
    if [ "$link_cls_only" = 1 ]; then link_hits; else link_hits; part3_hits; fi
    # By class, escaped id and hash: the placeholder hashes are the same for every item, so the id decides.
    n=0 sel=''
    while IFS= read -r -d '' c && IFS= read -r -d '' dd && IFS= read -r -d '' i && IFS= read -r -d '' h; do
      if [ "$c" = "$class" ] && [ "$dd" = "$id" ] && [ "$h" = "$hash" ]; then n=$((n + 1)); sel=$i; seld=$dd; fi
    done < "$recs"
    [ "$n" = 1 ] || fail 'remove'
    if [ "$mode" = select ]; then
      printf 'git tripwire: id %s\n' "$seld"
      exit 0
    fi
    prep_allowed
    finalize
    case $class in
      'git dir link') remove_link "$class" "$sel" ;;
      'worktree link')
        if [ -L "$gd/$sel" ]; then
          remove_link "$class" "$sel"
        elif isdir "$gd/$sel" && ! wt_ok "${sel#worktrees/}" && gitdir_ok "$gd/$sel" && [[ $gdtext == */.git ]] && ! isdir "${gdtext%/.git}"; then
          remove_stale_worktree "$sel"
        else
          remove_path "$class" "$sel"
        fi
        ;;
      'submodule dir')
        # only the `modules` line is removed; an include hit names one submodule's config file, which a submodule needs:
        # moving it breaks the absorbed submodule (it carries that submodule's remote and core.worktree), so the human
        # fixes it by hand
        [ "$sel" = modules ] || fail 'remove'
        remove_path "$class" "$sel"
        ;;
      'hook' | 'info file' | 'legacy remote' | 'worktree config') remove_path "$class" "$sel" ;;
      'hard link') remove_hardlink "$sel" ;;
      'config key') remove_key "$sel" ;;
      'replace ref')
        [[ $sel == refs/replace/* ]] || fail 'remove'
        cur=$(g rev-parse --verify "$sel") || fail 'remove'
        g update-ref -d "$sel" "$cur" || fail 'remove'
        g rev-parse --verify -q "$sel" >/dev/null && fail 'remove'
        index_line 'replace ref' 'deleted'
        ;;
      'shallow')
        # fetch reads the config and lists the worktrees: not while a config key or a worktree link stands
        grep -Eq '^(config key|worktree link) ' -- "$out"
        [ $? -eq 1 ] || fail 'remove'
        g -c maintenance.auto=false -c gc.auto=0 -c fetch.writeCommitGraph=false fetch --unshallow --no-recurse-submodules || fail 'remove'
        absent "$gd/shallow" || fail 'remove'
        index_line 'shallow' 'unshallowed'
        ;;
      *) fail 'remove' ;;
    esac
    printf 'git tripwire: removed %s\n' "$class"
    ;;

  check-checkout)
    link_hits; part3_hits; prep_allowed; finalize
    cat -- "$out"
    ;;

  check-unit)
    tip_is "$I" "$P"
    commit_exists "$S"
    link_hits; part3_hits
    # Part 3 is held before the unit is read, as merge-unit holds it: merge-tree runs the merge drivers and filters
    # that .git/config and .git/info/attributes name, which nobody has judged yet. Not a failure: the lines are
    # printed, with a note, and the manager releases them and calls again.
    prep_allowed; finalize
    if ! hold_ok; then
      cat -- "$out"
      printf 'git tripwire: note: part 3 holds; parts 1-2 were not read\n'
      exit 0
    fi
    if [ "$P" = none ]; then
      b=$(g hash-object -t tree /dev/null) || fail 'unit'
      unit_hits "$b" "$S"
    else
      commit_exists "$P"
      merged_tree "$P" "$S"
      unit_hits "$P" "$t"
      names_z merge "$P" "$t"
      filter_scan merge "$P"
      merge_state_why "$P"
    fi
    finalize
    cat -- "$out"
    # merge-unit would stop at this (nothing moved): a note, so the manager learns it now, not at the merge. The
    # merge-state stop comes first at a merge, so it is the one named.
    if [ -n "$swhy" ]; then
      printf 'git tripwire: note: %s; merge-unit will stop (merge)\n' "$swhy"
    elif [ "$fcount" -gt 0 ]; then
      printf 'git tripwire: note: %s path(s) the merge would write name a filter driver the config defines; merge-unit will stop (merge)\n' "$fcount"
    fi
    ;;

  merge-unit)
    [ "$P" != none ] || fail 'unit'
    link_hits; part3_hits
    tip_is "$I" "$P"
    head_is "$I" merge
    tip_is "work/$u" "$S"
    commit_exists "$P"
    # Part 3 is held before anything reads the unit; then parts 1-2 look at what the merge brings in (the tree
    # the merge makes, against P), not at merge-base..S, which a criss-cross history can empty.
    prep_allowed; finalize
    hold
    merged_tree "$P" "$S"
    unit_hits "$P" "$t"
    finalize
    hold
    guard_cfg
    do_merge "$I" "$P" "$S" "Merge branch 'work/$u'"
    cat -- "$out"
    guard_note
    [ -z "$GNOTE" ] || printf '%s\n' "$GNOTE"
    printf 'git tripwire: tip %s\n' "$new"
    ;;

  merge-handsoff)
    link_hits; part3_hits
    tip_is "$to" "$Pt"
    tip_is "$from" "$Ps"
    head_is "$to" merge
    [ "$Pt" != none ] || fail 'merge'
    prep_allowed; finalize
    hold
    merged_tree "$Pt" "$Ps"
    unit_hits "$Pt" "$t"
    finalize
    hold
    guard_cfg
    do_merge "$to" "$Pt" "$Ps" "Merge branch '$from'"
    cat -- "$out"
    guard_note
    [ -z "$GNOTE" ] || printf '%s\n' "$GNOTE"
    printf 'git tripwire: tip %s\n' "$new"
    ;;

  close)
    isdir "$runs/$run" || fail 'expected'
    [ "$run" != none ] || fail 'expected'
    rd=$runs/$run
    for f in expected hidden released; do
      isfile "$rd/$f" || fail 'expected'
      cat -- "$rd/$f" > "$work/h.$f" 2>/dev/null || fail 'expected'
    done
    cat "$work/h.expected" "$work/h.hidden" > "$work/h.eh" || fail 'expected'
    prep_allowed
    n=0
    if [ -e "$allowedf" ] || [ -L "$allowedf" ]; then isfile "$allowedf" || fail 'allowed'; else : >> "$allowedf" || fail 'allowed'; fi
    while IFS= read -r line || [ -n "$line" ]; do
      parse_line "$line" || continue
      in_list "$pcls" "${PART3[@]}" || continue
      never_allowed "$pcls" "$pid" && continue
      [ "$phs" = "$ph1" ] || [ "$phs" = "$ph2" ] || [ "$phs" = "$ph3" ] && continue
      printf '%s\n' "$line" | grep -Fxq -f "$work/h.eh" || continue
      grep -Fxq -- "$line" "$work/allowed.clean"
      case $? in 0) continue ;; 1) ;; *) fail 'allowed' ;; esac
      printf '%s\n' "$line" >> "$allowedf" || fail 'allowed'
      n=$((n + 1))
    done < "$work/h.released"
    printf 'git tripwire: closed %s\n' "$n"
    ;;

  commit)
    link_hits; part3_hits
    tip_is "$I" "$P"
    head_is "$I" commit
    if [ "$P" = none ]; then base=$(g hash-object -t tree /dev/null) || fail 'commit'
    else commit_exists "$P"; base=$P; fi
    prep_allowed; finalize
    hold
    if [ "$P" = none ]; then rstate='does not exist yet'; else rstate="is still at $P"; fi
    NOTE="git tripwire: note: nothing moved: refs/heads/$I $rstate"
    # a pending merge (or cherry-pick, revert, rebase) is no staged change when it was made with `-s ours`, yet a later
    # plain `git commit` would complete it with a parent nobody judged
    if marker_present; then fail 'commit'; fi
    # the real index must match P: a member's own staged file is refused
    g diff-index --cached --name-only -z --ignore-submodules=none --no-renames --no-abbrev --no-relative "$base" > "$work/staged" || fail 'commit'
    [ ! -s "$work/staged" ] || fail 'commit'
    d=$(mktemp -d -p "$work" idx.XXXXXXXXXX) || fail 'commit'
    ix=$d/index
    if [ "$P" = none ]; then GIT_INDEX_FILE=$ix g --attr-source="$base" read-tree --empty || fail 'commit'
    else GIT_INDEX_FILE=$ix g --attr-source="$base" read-tree "$P" || fail 'commit'; fi
    lead_check_list
    # The paths `add` would take are exactly the named ones: a folder in `paths` never passes the names check below.
    # They are asked for their filter attribute from every source plain git's `add` would read, before `add` runs
    # (see the filters, above): P's tree, and in one call with no attribute source the work tree's and the index's
    # .gitattributes together with the global, default and system attribute files. The new tree is asked after
    # write-tree (it closes the window between the checks and `add`: a .gitattributes edited in between arrives in
    # the tree). `add` itself cannot move after the names check, which reads the tree `add` makes. A pre-check that
    # refused every folder would refuse a submodule's path, which legitimately commits as a gitlink; one that refused
    # only a folder holding no `.git` entry was not built. The residue, when a folder (or a path the filters would have
    # scrubbed) reaches `add` and a later check stops the call, is raw loose objects that no ref reaches, until gc prunes
    # them: nothing of it reaches a commit.
    printf '%s\0' "${pathlist[@]}" | sort -z -u > "$work/fin" || fail 'commit'
    : > "$work/fhits"
    filter_scan commit "$base"
    filter_scan commit '' wide
    commit_filter_stop
    printf '%s\n' "${pathlist[@]}" > "$work/paths.copy" || fail 'commit'
    GIT_INDEX_FILE=$ix g --attr-source="$base" --literal-pathspecs add --pathspec-from-file="$work/paths.copy" || fail 'commit'
    t=$(GIT_INDEX_FILE=$ix g write-tree) || fail 'commit'
    [[ $t =~ $re_sha ]] || fail 'commit'
    g diff --name-only -z --ignore-submodules=none --no-renames --no-abbrev --no-relative "$base" "$t" > "$work/names.z" || fail 'commit'
    tr '\0' '\n' < "$work/names.z" | LC_ALL=C sort > "$work/names.got" || fail 'commit'
    printf '%s\n' "${pathlist[@]}" | LC_ALL=C sort > "$work/names.want" || fail 'commit'
    cmp -s "$work/names.got" "$work/names.want" || fail 'commit'
    filter_scan commit "$t"
    commit_filter_stop
    unit_hits "$base" "$t"
    finalize
    hold
    lead_check_list
    printf '%s\n' "$message" > "$work/msg.txt" || fail 'commit'
    if [ "$P" = none ]; then
      new=$(g commit-tree --no-gpg-sign -F "$work/msg.txt" "$t") || fail 'commit'
      old=${new//[0-9a-f]/0}
    else
      new=$(g commit-tree --no-gpg-sign -F "$work/msg.txt" "$t" -p "$P") || fail 'commit'
      old=$P
    fi
    [[ $new =~ $re_sha ]] || fail 'commit'
    guard_cfg
    if lock_present; then
      NOTE="git tripwire: note: nothing moved: $LOCKWHY; refs/heads/$I $rstate"
      fail 'commit'
    fi
    g update-ref "refs/heads/$I" "$new" "$old" || fail 'commit'
    NOTE="git tripwire: note: refs/heads/$I has moved to $new"
    head_is "$I" commit
    # -m -i: a plain `read-tree <tree>` builds a fresh index and drops every entry's stat data (and, in a legacy sparse
    # checkout, its skip-worktree bit), so the next merge's refresh would re-hash every tracked file through a blanked
    # `required` filter and stop. `-m` alone refuses a modified tracked file ("not uptodate") after the branch has
    # moved. `-m -i` keeps the entries equal to the tree, as they are, and reads or writes nothing in the work tree.
    g --attr-source="$new" read-tree -m -i "$new" || fail 'commit'
    NOTE=''
    cat -- "$out"
    guard_note
    [ -z "$GNOTE" ] || printf '%s\n' "$GNOTE"
    printf 'git tripwire: tip %s\n' "$new"
    ;;
esac
exit 0
