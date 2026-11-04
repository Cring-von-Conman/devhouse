r"""Research-intake field checker: the one canonical home of every intake check.

Called as:  command python -I -S -B '<this file>' <mode> ... || fail '<label>'
Modes, with the label each takes:
  <folder>                         default: check the five field files, write the derived parts
                                   (including `digest`, a hash of all five)           intake: field
  --staging <folder>               check the four staging field files (no id); refuses kind
                                   dependency, which never stages; writes nothing
                                                                                      intake: field
  --check <folder>                 re-run every check, re-derive every part (`digest` included),
                                   compare byte for byte                              intake: field
  --crate-index <file> <folder>    --check, then judge a fetched crates.io index file intake: hash
  --extract <archive> <dest>       list-check a tar archive, then extract it with
                                   filter='data'                                      intake: extract
  --list <archive> <out file>      the same floor and listing gate, extracting nothing; writes
                                   one line per member to a new <out file>, "<f|d> <size> <name>",
                                   the name in ASCII: a backslash as two backslashes, and every
                                   other character outside 0x20-0x7e as \xNN, \uNNNN or \UNNNNNNNN
                                                                                      intake: extract
  --names -                        judge a clone's tree before anything is checked out: reads
                                   standard input, the NUL-separated output of `git ls-tree -r
                                   -t -z -l`, to its end (a pipe, never a file). Every entry
                                   gets the same gate as --tree (names, devices, UTF-16 lengths,
                                   .git and git~n, repeats, the file/folder conflict, the HEAD rule,
                                   the tree caps), the blob sizes are summed against
                                   MAX_TREE_BYTES, and the stream itself is cut off at
                                   MAX_LISTING_BYTES; writes nothing                     intake: tree
  --tree <folder>                  walk a folder (a clone's working tree) without following anything,
                                   skip only its top-level .git folder, and give every other entry
                                   the --extract name rules, its own caps (MAX_TREE_ENTRIES,
                                   MAX_TREE_NAME_CHARS), the file/folder conflict check and the HEAD
                                   rule; also refuse a regular file whose link count is not 1;
                                   writes nothing                                        intake: tree

Output: exactly one line on stdout, "intake-check: pass" (or "intake-check: pass, yanked"
for --crate-index) or "intake-check: refused", and nothing on stderr. Exit 0 on pass, 1 otherwise.
Python 3.9+, standard library only; --extract and --list also need the tarfile patch floors
(TAR_FLOORS). --names and --tree read no archive, so they have no floor.
Rationale: Documentation/architecture/decisions/0016-research-intake.md.
"""
import bisect
import contextlib
import hashlib
import io
import json
import os
import re
import stat
import sys
import unicodedata

PASS = "intake-check: pass"
PASS_YANKED = "intake-check: pass, yanked"
REFUSED = "intake-check: refused"

FIELD_FILES = ("kind", "name", "id", "source", "purpose")
STAGING_FILES = ("kind", "name", "source", "purpose")
MAX_FIELD = 4096
MAX_DERIVED = 65536
MAX_INDEX = 16 * 1024 * 1024
CRATE_SOURCE = "https://index.crates.io"

# Archive limits. MAX_ARCHIVE_BYTES caps the data the member headers declare. A pax, GNU long-name
# or sparse-map header block is not a member, yet tarfile reads each one whole into memory before
# it returns the next member, so BoundedTarInfo caps each block at MAX_HEADER_BYTES, all blocks
# together at MAX_HEADER_TOTAL, and the blocks in a row before one member at MAX_HEADER_CHAIN (they
# do not count against MAX_ARCHIVE_MEMBERS: the chain and the total bound them). tarfile also
# keeps a copy of the pax headers (global ones included) on every member it returns, and another
# for every extended header block in a chain, so the gate totals the copies: MAX_PAX_ENTRIES dict
# entries (each extended block charged the entries of the global dict it copies, each member the
# entries it retains) and MAX_PAX_CHARS key and value characters (members only).
# MAX_NAME_CHARS bounds the names kept for the duplicate check and for a --list file.
MAX_ARCHIVE_MEMBERS = 100000
MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024
MAX_HEADER_BYTES = 1024 * 1024
MAX_HEADER_TOTAL = 16 * 1024 * 1024
MAX_HEADER_CHAIN = 4  # real archives use at most a global, a pax block, a long name and a long link
MAX_PAX_ENTRIES = 1024 * 1024
MAX_PAX_CHARS = 32 * 1024 * 1024
MAX_NAME_CHARS = 32 * 1024 * 1024
# --tree has caps of its own: a clone is already on disk, so the walker's memory (about 340 bytes an
# entry, measured: 150,000 entries about 51 MB, 1,000,000 about 343 MB) is the lesser cost, and the
# archive caps would refuse a real repository of LLVM's size.
MAX_TREE_ENTRIES = 500000
MAX_TREE_NAME_CHARS = 64 * 1024 * 1024
# --names runs before the checkout, so it also bounds what the checkout would write: the blob sizes
# summed (a blob listed twice counts twice) against the archive gate's figure, and one listing
# record (type, size and a path) at 64 KiB. The listing itself arrives on a pipe and is read as it
# comes, so a shared subtree that git would print a billion times is refused when it has sent
# MAX_LISTING_BYTES, and nothing is written. A listing git prints for a tree within the tree caps stays
# under it: at most 500,000 records of about 74 bytes, plus 64 Mi path characters at up to 4 bytes
# each, about 292 MiB. (A stream padded by hand, which git never prints, can be longer and is refused.)
MAX_TREE_BYTES = MAX_ARCHIVE_BYTES
MAX_LISTING_RECORD = 64 * 1024
MAX_LISTING_BYTES = 320 * 1024 * 1024
# one `git ls-tree -r -t -z -l` record before its TAB: mode, type, object id (40 hex: a SHA-256
# repository is refused everywhere in intake), then the size, which git pads with spaces on the left
LISTING_HEAD = re.compile(rb"([0-7]{6}) (blob|tree|commit) ([0-9a-f]{40}) +([0-9]{1,15}|-)")
LISTING_MODES = {b"blob": (b"100644", b"100755", b"120000"), b"tree": (b"040000",), b"commit": (b"160000",)}
MAX_COMPONENT_UNITS = 255  # NTFS counts UTF-16 code units
ZIP_SIGNATURES = (b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08")
# tarfile's own .xz reader sets no memory limit, and a 156-byte file can ask for a 4 GiB dictionary
XZ_MAGIC = b"\xfd7zXZ\x00"
XZ_MEMLIMIT = 256 * 1024 * 1024

REPARSE_POINT = 0x400  # FILE_ATTRIBUTE_REPARSE_POINT: symlinks and junctions on Windows

# The patterns, which are this script's own spec. Must-match: re.fullmatch. Must-not: re.search.
RULES = {
    "kind": (
        "any",
        [(r"^(dependency|copied code|clone|download)$", 0)],
        [],
    ),
    "name": (
        "any",
        [
            (r"^[A-Za-z0-9_][A-Za-z0-9._+-]*$", 0),
            (r"^[A-Za-z0-9_][A-Za-z0-9._+-]*@@[A-Za-z0-9_][A-Za-z0-9._+-]*$", 0),
        ],
        [
            (r"\.\.", 0),
            (r"[. ]$", 0),
            (r"^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$", re.I),
            (r"^fields\.", re.I),
        ],
    ),
    "id": (
        "any",
        [
            (r"^sha256:[0-9a-f]{64}$", 0),
            (r"^pypi:[0-9][A-Za-z0-9.+-]*@sha256:[0-9a-f]{64}$", 0),
            (r"^git:[0-9a-f]{40}$", 0),
            (r"^npm:[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?@sha512-[A-Za-z0-9+/]{86}==$", 0),
            (r"^crate:[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?@[0-9a-f]{64}$", 0),
        ],
        [
            # a version ending like an archive makes pip and npm read the operand as a local path
            (r"\.(zip|whl|tar|tgz|tbz|txz|tlz|lz|lzma|gz|bz2|xz)@", re.I),
        ],
    ),
    "source": (
        "all",
        [
            (r"^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~:+-]+)*/?$", 0),
            (r"^https://([A-Za-z0-9-]+\.)+[A-Za-z][A-Za-z0-9-]*(:[0-9]+)?(/.*)?$", 0),
        ],
        [
            (r"/\.\.?(/|$)", 0),
            # curl sends any *.localhost straight to loopback
            (r"^https://([^/:.]+\.)*localhost([/:.]|$)", re.I),
        ],
    ),
    "purpose": (
        "any",
        [(r"^[A-Za-z0-9 ,.()-]{1,80}$", 0)],
        [],
    ),
}

# kind -> the <id> forms it may carry
PAIRINGS = {
    "dependency": ("pypi", "npm", "crate"),
    "clone": ("git",),
    "download": ("sha256",),
    "copied code": ("sha256",),
}

# Python patch floors for tarfile's filter='data' and the tarfile fix for CVE-2025-8194 (gh-130577,
# "tarfile now validates archives to ensure member offsets are non-negative"). Minor line -> first
# patched micro, which must be a final release; each is the first release on its line with that
# fix. CPython's changelogs list it under Library by issue number, not under the CVE. A later minor
# or major line passes only as a final release.
TAR_FLOORS = {(3, 9): 24, (3, 10): 19, (3, 11): 14, (3, 12): 12, (3, 13): 6, (3, 14): 0}

# CPython's ntpath._isreservedname device list (3.13), written out because the floor is 3.9, plus
# COM0 and LPT0, which Microsoft's naming documentation also reserves. One list for field names
# and archive components.
RESERVED_NAMES = frozenset(
    ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]
    + ["COM" + c for c in "0123456789\u00b9\u00b2\u00b3"]
    + ["LPT" + c for c in "0123456789\u00b9\u00b2\u00b3"]
)
UNSAFE_CHARS = frozenset('<>"|?*:/\\')
BAD_CATEGORIES = ("Cc", "Cf", "Cs")  # controls (C0, DEL, C1), format characters, lone surrogates
SHORT_GIT = re.compile(r"^git~[0-9]+", re.I)
# what git needs beside a HEAD file before it treats a folder as a repository (objects and refs, or
# commondir); any one of them here is enough to refuse the HEAD
HEAD_SIBLINGS = ("objects", "refs", "commondir")

# the tarfile.TarInfo hooks BoundedTarInfo relies on; absent in a future tarfile, the call is refused
TARINFO_HOOKS = ("_proc_member", "_proc_sparse", "_proc_gnusparse_00", "_proc_gnusparse_01", "_proc_gnusparse_10")


class Refused(Exception):
    pass


def refuse():
    raise Refused()


def is_reserved_name(name):
    """CPython's ntpath._isreservedname device rule: nul, "nul .txt", COM1, COM\u00b9, CONIN$ ..."""
    return name.partition(".")[0].rstrip(" ").upper() in RESERVED_NAMES


def no_duplicate_keys(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            refuse()
        d[k] = v
    return d


# ---- files and folders -------------------------------------------------------------------


def is_link(st):
    if stat.S_ISLNK(st.st_mode):
        return True
    return bool(getattr(st, "st_file_attributes", 0) & REPARSE_POINT)


def check_plain_dir(path):
    st = os.lstat(path)
    if is_link(st) or not stat.S_ISDIR(st.st_mode):
        refuse()


def check_plain_file(st):
    if is_link(st) or not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
        refuse()


def read_limited(path, limit):
    """A regular, unlinked, link-count-1 file's bytes; refuses over `limit`."""
    check_plain_file(os.lstat(path))
    with open(path, "rb") as f:
        check_plain_file(os.fstat(f.fileno()))
        data = f.read(limit + 1)
    if len(data) > limit:
        refuse()
    return data


def parse_line(data):
    if data.endswith(b"\n"):
        data = data[:-1]
    # printable ASCII only: this also refuses a second line, a CR, a NUL, a BOM and a tab
    if re.fullmatch(rb"[\x20-\x7e]*", data) is None:
        refuse()
    return data.decode("ascii")


def check_closed_set(folder, expected):
    check_plain_dir(folder)
    names = os.listdir(folder)
    if sorted(names) != sorted(expected):
        refuse()
    for n in names:
        check_plain_file(os.lstat(os.path.join(folder, n)))


# ---- the field checks ---------------------------------------------------------------------


def check_field(field, value):
    mode, musts, mustnots = RULES[field]
    hits = [re.fullmatch(p, value, fl) is not None for p, fl in musts]
    if mode == "any":
        if not any(hits):
            refuse()
    elif not all(hits):
        refuse()
    for p, fl in mustnots:
        if re.search(p, value, fl) is not None:
            refuse()
    # defence in depth: the name patterns above already keep every device name out, so this cannot
    # fire today; it stays so that a loosened pattern still meets the one device list
    if field == "name" and is_reserved_name(value):
        refuse()


def parse_id(idv):
    """The parts of a checked <id>."""
    form, rest = idv.split(":", 1)
    p = {"form": form}
    if form == "sha256":
        p["hex"] = rest
    elif form == "git":
        p["sha"] = rest
    elif form == "npm":
        p["version"], p["integrity"] = rest.split("@", 1)
    else:  # pypi, crate
        p["version"], tail = rest.split("@", 1)
        p["hex"] = tail[len("sha256:"):] if form == "pypi" else tail
    return p


def validate(vals, staging):
    """Run every field check and pairing; returns the id's parts (None when staging)."""
    for field in STAGING_FILES if staging else FIELD_FILES:
        check_field(field, vals[field])
    name = vals["name"]
    if staging:
        # a dependency always has a published <id>, so it never stages (which also keeps scope@@name
        # out of a staging line)
        if "@@" in name or vals["kind"] == "dependency":
            refuse()
        return None
    p = parse_id(vals["id"])
    if p["form"] not in PAIRINGS[vals["kind"]]:
        refuse()
    if "@@" in name and p["form"] != "npm":
        refuse()
    if p["form"] == "crate" and vals["source"] != CRATE_SOURCE:
        refuse()
    return p


def crate_url(name):
    n = name.lower()
    if len(n) == 1:
        prefix = "1/"
    elif len(n) == 2:
        prefix = "2/"
    elif len(n) == 3:
        prefix = "3/" + n[0] + "/"
    else:
        prefix = n[0:2] + "/" + n[2:4] + "/"
    return CRATE_SOURCE + "/" + prefix + n


def osv_query(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def fields_digest(raws):
    """sha256 hex over the five field files' exact bytes, in FIELD_FILES order, each length-prefixed."""
    h = hashlib.sha256()
    for n in FIELD_FILES:
        h.update(len(raws[n]).to_bytes(8, "big"))
        h.update(raws[n])
    return h.hexdigest()


def derive(vals, p, raws):
    """Every output file, from the checked fields: {file name: bytes}."""
    idv, name = vals["id"], vals["name"]
    out = {"id8": hashlib.sha256(idv.encode("ascii")).hexdigest()[:8], "digest": fields_digest(raws)}
    form = p["form"]
    if form == "sha256":
        out["hex"] = p["hex"]
    elif form == "git":
        out["sha"] = p["sha"]
        out["osv.json"] = osv_query({"commit": p["sha"]})
    elif form == "pypi":
        out["hex"] = p["hex"]
        out["version"] = p["version"]
        out["pipspec"] = name + "==" + p["version"]
        out["osv.json"] = osv_query(
            {"package": {"ecosystem": "PyPI", "name": name}, "version": p["version"]}
        )
        out["pip-audit.txt"] = out["pipspec"] + " --hash=sha256:" + p["hex"]
    elif form == "npm":
        npmname = name
        if "@@" in name:
            scope, sub = name.split("@@", 1)
            npmname = "@" + scope + "/" + sub
            out["npmname"] = npmname
        out["integrity"] = p["integrity"]
        out["version"] = p["version"]
        out["npmspec"] = npmname + "@" + p["version"]
        out["osv.json"] = osv_query(
            {"package": {"ecosystem": "npm", "name": npmname}, "version": p["version"]}
        )
    else:  # crate
        out["hex"] = p["hex"]
        out["version"] = p["version"]
        out["url"] = crate_url(name)
        out["osv.json"] = osv_query(
            {"package": {"ecosystem": "crates.io", "name": name}, "version": p["version"]}
        )
    return dict((k, v.encode("ascii")) for k, v in out.items())


def load_fields(folder, names):
    """({field: checked text}, {field: exact bytes})."""
    raws = dict((n, read_limited(os.path.join(folder, n), MAX_FIELD)) for n in names)
    return dict((n, parse_line(raws[n])) for n in names), raws


# ---- the modes -----------------------------------------------------------------------------


def mode_staging(folder):
    check_closed_set(folder, STAGING_FILES)
    validate(load_fields(folder, STAGING_FILES)[0], True)
    return PASS


def mode_default(folder):
    check_closed_set(folder, FIELD_FILES)
    vals, raws = load_fields(folder, FIELD_FILES)
    outs = derive(vals, validate(vals, False), raws)
    check_plain_dir(folder)
    # exclusive and binary, so nothing existing is followed or overwritten; the result line
    # is printed by the caller, after every write
    for n in sorted(outs):
        with open(os.path.join(folder, n), "xb") as f:
            f.write(outs[n])
    return PASS


def mode_check(folder):
    """Re-run every check and compare every derived file; returns (values, parts)."""
    check_plain_dir(folder)
    vals, raws = load_fields(folder, FIELD_FILES)
    p = validate(vals, False)
    outs = derive(vals, p, raws)
    check_closed_set(folder, list(FIELD_FILES) + sorted(outs))
    for n in outs:
        if read_limited(os.path.join(folder, n), MAX_DERIVED) != outs[n]:
            refuse()
    return vals, p


def mode_crate_index(index_file, folder):
    vals, p = mode_check(folder)
    if p["form"] != "crate":
        refuse()
    version, hexsum, name = p["version"], p["hex"], vals["name"]
    text = read_limited(index_file, MAX_INDEX).decode("utf-8")
    matches = []
    for line in text.split("\n"):
        if line.strip() == "":
            continue
        entry = json.loads(line, object_pairs_hook=no_duplicate_keys)
        if not isinstance(entry, dict):
            refuse()
        if entry.get("vers") == version:
            matches.append(entry)
    if len(matches) != 1:
        refuse()
    entry = matches[0]
    if entry.get("name") != name:
        refuse()
    if entry.get("cksum") != hexsum:
        refuse()
    yanked = entry.get("yanked", False)
    if not isinstance(yanked, bool):
        refuse()
    return PASS_YANKED if yanked else PASS


# ---- archives ------------------------------------------------------------------------------


def tar_floor_ok(version_info):
    major, minor, micro, level = version_info[0], version_info[1], version_info[2], version_info[3]
    if (major, minor) > (3, 14):
        # a later minor or major line is unchecked, so only a final release of it counts
        return level == "final"
    floor = TAR_FLOORS.get((major, minor))
    return floor is not None and (micro > floor or (micro == floor and level == "final"))


def component_ok(comp):
    # both the name as written and its NFKC form: fullwidth dots, slashes and colons fold to ASCII
    # ones in some APIs, and a file system may fold case or drop format characters
    for form in (comp, unicodedata.normalize("NFKC", comp)):
        if len(form.encode("utf-16-le", "surrogatepass")) // 2 > MAX_COMPONENT_UNITS:
            return False
        if form[-1:] in (".", " "):
            return False
        for c in form:
            if c in UNSAFE_CHARS or unicodedata.category(c) in BAD_CATEGORIES:
                return False
        if is_reserved_name(form) or SHORT_GIT.match(form):
            return False
        folded = form.casefold()
        if folded == ".git" or SHORT_GIT.match(folded):
            return False
    return True


def member_name_ok(name):
    if name == "" or "\\" in name or ":" in name or name.startswith("/"):
        return False
    if any(ord(c) < 0x20 or ord(c) == 0x7F for c in name):
        return False
    for comp in name.split("/"):
        if comp in ("", "."):
            continue
        if comp == ".." or not component_ok(comp):
            return False
    return True


def name_key(name):
    """Equal for two names that one file system would treat as the same file."""
    comps = [c for c in name.split("/") if c not in ("", ".")]
    return "/".join(unicodedata.normalize("NFC", c).casefold() for c in comps)


def head_key(name):
    """name_key with the wider NFKC fold, for the HEAD rule: fullwidth and compatibility forms of
    `HEAD`, `objects`, `refs` and `commondir` fold to the plain ones."""
    comps = [c for c in name.split("/") if c not in ("", ".")]
    return "/".join(unicodedata.normalize("NFKC", c).casefold() for c in comps)


class MemberGate:
    """The name, type and cap check, run on every member by the listing pass and again by the
    extraction pass, and on every entry of a --tree walk (through entry()).

    The listing pass refuses any repeated name. The extraction pass (second_look=True) refuses a
    repeated file name, but lets a folder come round again: extractall filters each folder a
    second time, to set its attributes, and that second look is not counted.
    """

    def __init__(self, second_look=False, max_members=None, max_name_chars=None):
        self.max_members = MAX_ARCHIVE_MEMBERS if max_members is None else max_members
        self.max_name_chars = MAX_NAME_CHARS if max_name_chars is None else max_name_chars
        self.count = 0
        self.total = 0
        self.name_chars = 0
        self.header_bytes = 0
        self.chain = 0  # header blocks since the last member
        self.pax_entries = 0
        self.pax_chars = 0
        self.seen = {}  # name_key -> True for a file, False for a folder
        self.hkeys = []  # head_key of every name, for the HEAD rule in finish()
        self.heads = []  # head_key of every regular file whose last component folds to `head`
        self.second_look = second_look

    def header(self, size, copied=0):
        """A pax, long-name or global header block, before tarfile reads its body. `copied` is the
        number of entries of the global pax dict an extended block copies."""
        self.chain += 1
        self.header_bytes += size
        self.pax_entries += copied
        if (
            self.chain > MAX_HEADER_CHAIN
            or size < 0
            or size > MAX_HEADER_BYTES
            or self.header_bytes > MAX_HEADER_TOTAL
            or self.pax_entries > MAX_PAX_ENTRIES
        ):
            refuse()

    def entry(self, name, isdir):
        """The name rules and the count and character caps, for one member or tree entry. False
        when it is the extraction pass's second look at a folder (counted as nothing)."""
        if not member_name_ok(name):
            refuse()
        key = name_key(name)
        # extraction would fail or differ for these, part way: an empty name, or a trailing / or /.
        if not isdir and (key == "" or name.endswith("/") or name.endswith("/.")):
            refuse()
        prev = self.seen.get(key)
        if prev is not None:
            if self.second_look and isdir and prev is False:
                return False
            if key:
                refuse()
        self.seen[key] = not isdir
        self.count += 1
        if self.count > self.max_members:
            refuse()
        self.name_chars += len(name)
        if self.name_chars > self.max_name_chars:
            refuse()
        if key:
            hk = head_key(name)
            self.hkeys.append(hk)
            if not isdir and (hk == "head" or hk.endswith("/head")):
                self.heads.append(hk)
        return True

    def __call__(self, member):
        self.chain = 0
        if member.issym() or member.islnk() or not (member.isreg() or member.isdir()):
            refuse()
        if getattr(member, "sparse", None) is not None or member.size < 0:
            refuse()
        if not self.entry(member.name, member.isdir()):
            return
        if member.isreg():
            self.total += member.size
            if self.total > MAX_ARCHIVE_BYTES:
                refuse()
        # tarfile gives each member its own copy of the pax headers in force, so count the copies
        pax = getattr(member, "pax_headers", None)
        if pax:
            self.pax_entries += len(pax)
            self.pax_chars += sum(len(k) + len(v) for k, v in pax.items())
            if self.pax_entries > MAX_PAX_ENTRIES or self.pax_chars > MAX_PAX_CHARS:
                refuse()

    def finish(self):
        """After the last name, before anything is written: a file `a` together with `a/b`, in
        either order; and a regular file called HEAD beside an `objects`, `refs` or `commondir`."""
        # with "/" as NUL every name under k sorts directly after k itself
        ordered = sorted((k.replace("/", "\0"), isfile) for k, isfile in self.seen.items() if k)
        for i in range(len(ordered) - 1):
            k, isfile = ordered[i]
            if isfile and ordered[i + 1][0].startswith(k + "\0"):
                refuse()
        # A HEAD file next to those is what makes a folder a bare git repository. A sibling counts
        # as a file or a folder, and when only a deeper name implies it (x/objects/info/.keep), so
        # look for the sibling's own name or any name under it, by bisect over every name.
        if self.heads:
            names = sorted(h.replace("/", "\0") for h in self.hkeys)
            for hk in self.heads:
                prefix = hk[: len(hk) - len("head")].replace("/", "\0")
                for sib in HEAD_SIBLINGS:
                    target = prefix + sib
                    i = bisect.bisect_left(names, target)
                    if i < len(names) and (names[i] == target or names[i].startswith(target + "\0")):
                        refuse()


def bounded_tarinfo(tarfile, gate):
    """A TarInfo class that gates every header block before tarfile reads its body."""
    for hook in TARINFO_HOOKS:
        if not hasattr(tarfile.TarInfo, hook):
            refuse()
    header_types = (
        tarfile.GNUTYPE_LONGNAME,
        tarfile.GNUTYPE_LONGLINK,
        tarfile.XHDTYPE,
        tarfile.XGLTYPE,
        tarfile.SOLARIS_XHDTYPE,
    )
    extended_types = (tarfile.XHDTYPE, tarfile.SOLARIS_XHDTYPE)

    class BoundedTarInfo(tarfile.TarInfo):
        def _proc_member(self, tf):
            if self.type in header_types:
                # an extended block copies the global pax dict, and a chain of them keeps one copy
                # per level alive: charge the entries copied (a count, not a walk of the dict)
                copied = len(tf.pax_headers) if self.type in extended_types else 0
                gate.header(self.size, copied)
            return super()._proc_member(tf)

        # sparse members: their maps are read from the data, with no bound of tarfile's own
        def _proc_sparse(self, tf):
            refuse()

        def _proc_gnusparse_00(self, *args):
            refuse()

        def _proc_gnusparse_01(self, *args):
            refuse()

        def _proc_gnusparse_10(self, *args):
            refuse()

    return BoundedTarInfo


def escape_name(name):
    out = []
    for c in name:
        o = ord(c)
        if c == "\\":
            out.append("\\\\")
        elif 0x20 <= o <= 0x7E:
            out.append(c)
        elif o <= 0xFF:
            out.append("\\x%02x" % o)
        elif o <= 0xFFFF:
            out.append("\\u%04x" % o)
        else:
            out.append("\\U%08x" % o)
    return "".join(out)


def check_archive(archive):
    check_plain_file(os.lstat(archive))
    with open(archive, "rb") as f:
        if f.read(4) in ZIP_SIGNATURES:  # a zip (tarfile would not read it, but say so)
            refuse()


def limited_xz(f):
    """A buffered, seekable reader over the open .xz file `f` whose decoder may use at most
    XZ_MEMLIMIT bytes. A stream that wants more (a patched dictionary size) raises, as does a
    stream cut short, or bytes after a stream that are not another one, once tarfile reads that
    far. Concatenated streams read as one. Stricter than lzma.LZMAFile on purpose: the NUL
    padding the format allows between or after streams is refused too. That is a parser
    difference, not only strictness: LZMAFile takes the padding for trailing junk and silently
    stops, so a tar.xz padded between two streams reads as truncated (tarfile's r:xz lists only
    the first stream's members with no error) while the xz command decodes all of it. A check
    through plain tarfile would miss members that `tar -xJf` extracts."""
    import lzma

    def decoder():
        return lzma.LZMADecompressor(format=lzma.FORMAT_XZ, memlimit=XZ_MEMLIMIT)

    class Reader(io.RawIOBase):
        def __init__(self):
            self.rewind()

        def rewind(self):
            f.seek(0)
            self.dec = decoder()
            self.pos = 0

        def readable(self):
            return True

        def seekable(self):
            return True

        def tell(self):
            return self.pos

        def readinto(self, b):
            if len(b) == 0:
                return 0
            while True:
                if self.dec.eof:
                    raw = self.dec.unused_data or f.read(65536)
                    if not raw:
                        return 0
                    self.dec = decoder()
                    data = self.dec.decompress(raw, len(b))
                else:
                    if self.dec.needs_input:
                        raw = f.read(65536)
                        if not raw:
                            raise EOFError()
                    else:
                        raw = b""
                    data = self.dec.decompress(raw, len(b))
                if data:
                    b[: len(data)] = data
                    self.pos += len(data)
                    return len(data)

        def seek(self, offset, whence=io.SEEK_SET):
            if whence == io.SEEK_CUR:
                offset += self.pos
            elif whence != io.SEEK_SET or offset < 0:
                raise ValueError()
            if offset < self.pos:
                self.rewind()
            left = offset - self.pos
            while left > 0:
                data = self.read(min(1 << 20, left))
                if not data:
                    break
                left -= len(data)
            return self.pos

    return io.BufferedReader(Reader(), 1 << 18)


@contextlib.contextmanager
def open_tar(tarfile, archive, gate):
    """The archive as a TarFile whose headers go through `gate`. An .xz file is read by limited_xz.
    Otherwise tarfile's r:* order is kept, tar then gz then bz2, without its last try: that would
    read a legacy .lzma file, which carries a dictionary size with no memory limit either."""
    cls = bounded_tarinfo(tarfile, gate)
    with open(archive, "rb") as f:
        check_plain_file(os.fstat(f.fileno()))
        if f.read(len(XZ_MAGIC)) == XZ_MAGIC:
            with limited_xz(f) as reader:
                with tarfile.open(fileobj=reader, mode="r:", tarinfo=cls) as tf:
                    yield tf
            return
        for mode in ("r:", "r:gz", "r:bz2"):
            f.seek(0)
            try:
                tf = tarfile.open(fileobj=f, mode=mode, tarinfo=cls)
            except (tarfile.ReadError, tarfile.CompressionError):
                continue
            with tf:
                yield tf
            return
    refuse()


def list_members(tarfile, archive, want_lines):
    """The listing gate over every member; returns the --list lines (an empty list unless wanted)."""
    gate = MemberGate()
    lines = []
    with open_tar(tarfile, archive, gate) as tf:
        for member in tf:
            gate(member)
            if want_lines:
                lines.append("%s %d %s\n" % ("d" if member.isdir() else "f", member.size, escape_name(member.name)))
    gate.finish()
    return lines


def mode_list(archive, out_file):
    if not tar_floor_ok(sys.version_info):
        refuse()
    import tarfile

    check_archive(archive)
    lines = list_members(tarfile, archive, True)
    with open(out_file, "xb") as f:
        f.write("".join(lines).encode("ascii"))
    return PASS


def mode_extract(archive, dest):
    if not tar_floor_ok(sys.version_info):
        refuse()
    import tarfile

    check_archive(archive)
    check_plain_dir(dest)
    if os.listdir(dest) != []:
        refuse()

    list_members(tarfile, archive, False)

    # extractall filters each folder a second time, when it sets the folder's attributes: the gate
    # lets a folder come round again, counts every name once, and refuses a repeated file name
    gate2 = MemberGate(second_look=True)
    with open_tar(tarfile, archive, gate2) as tf:

        def data_filter(member, dest_path):
            gate2(member)
            return tarfile.data_filter(member, dest_path)

        tf.extractall(dest, filter=data_filter)

    for root, dirs, files in os.walk(dest):
        for n in dirs + files:
            st = os.lstat(os.path.join(root, n))
            if is_link(st) or (stat.S_ISREG(st.st_mode) and st.st_nlink != 1):
                refuse()
    return PASS


def tree_gate():
    return MemberGate(max_members=MAX_TREE_ENTRIES, max_name_chars=MAX_TREE_NAME_CHARS)


def mode_tree(folder):
    """A folder's entries against the --extract rules, nothing followed and nothing written. The one
    rule set for a clone's working tree: the top-level .git folder is the only entry skipped.
    Besides the name rules (through the one MemberGate.entry) it applies the tree's own count and
    name-character caps, the file/folder conflict and the HEAD rule (finish()), and refuses a
    regular file whose link count is not 1. It sums no sizes: --names does, before the checkout."""
    check_plain_dir(folder)
    gate = tree_gate()
    stack = [(folder, "")]
    while stack:
        path, rel = stack.pop()
        with os.scandir(path) as it:
            names = [e.name for e in it]
        for n in names:
            full = os.path.join(path, n)
            st = os.lstat(full)
            if is_link(st):
                refuse()
            isdir = stat.S_ISDIR(st.st_mode)
            if not (isdir or stat.S_ISREG(st.st_mode)):
                refuse()
            # a checkout never makes hard links, but a tool that writes where it runs could swap a
            # tracked file for a same-content hard link that `git status` calls clean
            if not isdir and st.st_nlink != 1:
                refuse()
            if isdir and rel == "" and n == ".git":
                continue
            name = rel + "/" + n if rel else n
            gate.entry(name, isdir)
            if isdir:
                stack.append((full, name))
    gate.finish()
    return PASS


def listing_records(stream):
    """The NUL-terminated records of a binary stream, one at a time, read a chunk at a time. A record
    over MAX_LISTING_RECORD, a last record with no NUL, or more than MAX_LISTING_BYTES in all
    refuses; the caller stops reading at the first refusal, so a stream that never ends is left."""
    seen = 0
    tail = b""
    while True:
        chunk = stream.read(1 << 20)
        if not chunk:
            break
        seen += len(chunk)
        if seen > MAX_LISTING_BYTES:
            refuse()
        parts = (tail + chunk).split(b"\0")
        tail = parts.pop()
        for rec in parts:
            if len(rec) > MAX_LISTING_RECORD:
                refuse()
            yield rec
        if len(tail) > MAX_LISTING_RECORD:
            refuse()
    if tail:
        refuse()


def mode_names(stream):
    """A clone's tree, judged from `git ls-tree -r -t -z -l` before the checkout, so no file of a
    refused tree is ever written. The listing is the stream, standard input: a pipe from git, never a
    file, so a tree whose listing is endless (a subtree reused at every level) fills no disk, and the
    refusal closes the pipe. Each record is `<mode> <type> <object> <size><TAB><path>`: a blob (a file, its
    size in digits), a tree (a folder) or a commit (a gitlink, which a checkout makes an empty
    folder), the last two with size `-`. The -l form, not --format: git C-quotes `%(path)` under
    --format even with -z, which would refuse every name with a non-ASCII or special character,
    while -z alone prints the raw path. The entries go through the same gate, and the same entries
    cap, as --tree (files and folders, counted alike); the blob sizes are summed against
    MAX_TREE_BYTES. The top-level .git is not skipped here: a tree entry called .git is refused.
    Paths must be strict UTF-8."""
    gate = tree_gate()
    total = 0
    for rec in listing_records(stream):
        head, tab, path = rec.partition(b"\t")
        m = LISTING_HEAD.fullmatch(head)
        if not tab or m is None:
            refuse()
        mode, kind, size = m.group(1), m.group(2), m.group(4)
        if mode not in LISTING_MODES[kind]:
            refuse()
        if kind == b"blob":
            if size == b"-":
                refuse()
            total += int(size)
            if total > MAX_TREE_BYTES:
                refuse()
            isdir = False
        else:
            if size != b"-":
                refuse()
            isdir = True
        try:
            name = path.decode("utf-8")
        except UnicodeDecodeError:
            refuse()
        gate.entry(name, isdir)
    gate.finish()
    return PASS


# ---- entry ---------------------------------------------------------------------------------


def run(argv):
    a = argv[1:]
    if len(a) == 2 and a[0] == "--staging":
        return mode_staging(a[1])
    if len(a) == 2 and a[0] == "--check":
        mode_check(a[1])
        return PASS
    if len(a) == 3 and a[0] == "--crate-index":
        return mode_crate_index(a[1], a[2])
    if len(a) == 3 and a[0] == "--extract":
        return mode_extract(a[1], a[2])
    if len(a) == 3 and a[0] == "--list":
        return mode_list(a[1], a[2])
    if len(a) == 2 and a[0] == "--tree":
        return mode_tree(a[1])
    if a == ["--names", "-"]:
        return mode_names(sys.stdin.buffer)
    if len(a) == 1 and not a[0].startswith("-"):
        return mode_default(a[0])
    return REFUSED


def main():
    try:
        result = run(sys.argv)
    except BaseException:  # includes SystemExit: no traceback, no usage text, nothing on stderr
        result = REFUSED
    try:
        sys.stdout.buffer.write(result.encode("ascii") + b"\n")
        sys.stdout.buffer.flush()
    except BaseException:
        pass
    sys.exit(0 if result in (PASS, PASS_YANKED) else 1)


if __name__ == "__main__":
    main()
