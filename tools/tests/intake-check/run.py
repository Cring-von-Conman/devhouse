"""Tests for plugins/devhouse/team/intake-check.py (see ADR 0016). Not installed with the plugin.

    python -I -S -B tools/tests/intake-check/run.py [<script path>]

With no argument it tests the working tree's script; give a path to test another copy (the
installed one, after a reinstall). Every case runs the script as `python -I -S -B '<script>' ...`
and asserts: exactly one stdout line, an empty stderr, exit 0 or 1, and the expected result.
Output: one line per case, `pass` or `FAIL` (and a `note` line where a control cannot run on this
machine; it is also recorded as a passing case that says so, so the count is the same everywhere),
then a counts line. Exit 0 only with no FAIL.
Everything it writes is inside one tempfile.mkdtemp() folder, removed at the end.
"""
import gzip
import hashlib
import io
import lzma
import os
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SCRIPT = os.path.normpath(
    os.path.join(HERE, "..", "..", "..", "plugins", "devhouse", "team", "intake-check.py")
)
if len(sys.argv) > 2:
    print("FAIL usage: run.py [<script path>]")
    sys.exit(1)
SCRIPT = os.path.abspath(sys.argv[1]) if len(sys.argv) == 2 else DEFAULT_SCRIPT

ROOT = os.path.realpath(tempfile.mkdtemp(prefix="intake-run-"))
_TMP = os.path.realpath(tempfile.gettempdir())
try:
    _inside = os.path.normcase(os.path.commonpath([ROOT, _TMP])) == os.path.normcase(_TMP)
except ValueError:
    _inside = False
if not _inside or os.path.normcase(ROOT) == os.path.normcase(_TMP):
    print("FAIL the work folder is not under the temp folder")
    sys.exit(1)
WORK = os.path.join(ROOT, "w")
os.mkdir(WORK)

OUT = {
    "pass": b"intake-check: pass\n",
    "yanked": b"intake-check: pass, yanked\n",
    "refused": b"intake-check: refused\n",
}

RESULTS = []
NAMES = []
LINKS = []  # (path, is_dir): links made, removed first so rmtree never follows one
_counter = [0]


def run_script(args, cwd=WORK, stdin=b""):
    p = subprocess.run(
        [sys.executable, "-I", "-S", "-B", SCRIPT] + list(args),
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=cwd,
        timeout=300,
    )
    return p.returncode, p.stdout, p.stderr


def record(name, problems):
    ok = not problems
    RESULTS.append(ok)
    line = ("pass  " if ok else "FAIL  ") + ascii(name)
    if problems:
        line += "  -- " + "; ".join(problems)
    print(line)
    sys.stdout.flush()


def run_case(name, expected, args, post=None, stdin=b""):
    NAMES.append(name)
    problems = []
    try:
        rc, out, err = run_script(args, stdin=stdin)
        if out.count(b"\n") != 1 or not out.endswith(b"\n"):
            problems.append("stdout is not exactly one line: " + ascii(out[:200]))
        if err != b"":
            problems.append("stderr is not empty: " + ascii(err[:200]))
        if rc not in (0, 1):
            problems.append("exit code " + str(rc))
        if out != OUT[expected]:
            problems.append("stdout " + ascii(out[:200]) + " wanted " + ascii(OUT[expected]))
        if rc != (1 if expected == "refused" else 0):
            problems.append("exit " + str(rc) + " for " + expected)
        if post is not None:
            msg = post()
            if msg:
                problems.append(msg)
    except Exception as e:
        problems.append("harness error: " + ascii(repr(e)))
    record(name, problems)


def run_unit(name, code, args, expected, timeout=60, stdin=b""):
    """A function-level case: a child loads the script as a module and prints one result line."""
    NAMES.append(name)
    problems = []
    try:
        p = subprocess.run(
            [sys.executable, "-I", "-S", "-B", "-c", code, SCRIPT] + list(args),
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=WORK,
            timeout=timeout,
        )
        want = OUT[expected]
        if p.stdout != want or p.stderr != b"" or p.returncode != (1 if expected == "refused" else 0):
            problems.append("got " + ascii(p.stdout[:100]) + ascii(p.stderr[:200]) + " rc " + str(p.returncode))
    except Exception as e:
        problems.append("harness error: " + ascii(repr(e)))
    record(name, problems)


# ---- profiles: a valid set per id form, and the independently written expected outputs --------

H = hashlib.sha256(b"intake-test").hexdigest()
SHA = hashlib.sha1(b"intake-test").hexdigest()
INTEG = "sha512-" + ("AbC+/0" * 15)[:86] + "=="


def sha8(s):
    return hashlib.sha256(s.encode("ascii")).hexdigest()[:8]


PROFILES = {
    "pypi": dict(
        kind="dependency",
        name="requests",
        id="pypi:2.32.3@sha256:" + H,
        source="https://pypi.org/simple/",
        purpose="HTTP client for the exporter",
    ),
    "git": dict(
        kind="clone",
        name="requests",
        id="git:" + SHA,
        source="https://github.com/psf/requests.git",
        purpose="Read the HTTP client source",
    ),
    "npm": dict(
        kind="dependency",
        name="left-pad",
        id="npm:1.3.0@" + INTEG,
        source="https://registry.npmjs.org",
        purpose="Pad strings",
    ),
    "crate": dict(
        kind="dependency",
        name="serde",
        id="crate:1.0.200@" + H,
        source="https://index.crates.io",
        purpose="Serialise records",
    ),
    "download": dict(
        kind="download",
        name="tool",
        id="sha256:" + H,
        source="https://files.example.com:8443/a/b.tar.gz",
        purpose="Fixture archive",
    ),
    "copied": dict(
        kind="copied code",
        name="snippet",
        id="sha256:" + H,
        source="https://docs.example.org/guide",
        purpose="Parse the header (example from the docs)",
    ),
}


def digest_hex(fields):
    """The `digest` file: sha256 over the five field files' bytes, in order, each with an 8-byte length."""
    h = hashlib.sha256()
    for k in ("kind", "name", "id", "source", "purpose"):
        b = fields[k] if isinstance(fields[k], bytes) else fields[k].encode("ascii")
        h.update(len(b).to_bytes(8, "big") + b)
    return h.hexdigest()


def expected_outputs(prof, over=None):
    p = dict(PROFILES[prof])
    p.update(over or {})
    idv, name = p["id"], p["name"]
    out = {"id8": sha8(idv), "digest": digest_hex(p)}
    if prof in ("download", "copied"):
        out["hex"] = idv[7:]
    elif prof == "git":
        out["sha"] = idv[4:]
        out["osv.json"] = '{"commit":"' + idv[4:] + '"}'
    elif prof == "pypi":
        ver = idv[5:].split("@")[0]
        out["hex"] = idv.split("sha256:")[1]
        out["version"] = ver
        out["pipspec"] = name + "==" + ver
        out["osv.json"] = '{"package":{"ecosystem":"PyPI","name":"' + name + '"},"version":"' + ver + '"}'
        out["pip-audit.txt"] = name + "==" + ver + " --hash=sha256:" + out["hex"]
    elif prof == "npm":
        ver = idv[4:].split("@", 1)[0]
        npmname = name
        if "@@" in name:
            a, b = name.split("@@")
            npmname = "@" + a + "/" + b
            out["npmname"] = npmname
        out["integrity"] = idv.split("@", 1)[1]
        out["version"] = ver
        out["npmspec"] = npmname + "@" + ver
        out["osv.json"] = '{"package":{"ecosystem":"npm","name":"' + npmname + '"},"version":"' + ver + '"}'
    elif prof == "crate":
        ver = idv[6:].split("@")[0]
        out["hex"] = idv.split("@")[1]
        out["version"] = ver
        if name == "serde":
            out["url"] = "https://index.crates.io/se/rd/serde"
        out["osv.json"] = '{"package":{"ecosystem":"crates.io","name":"' + name + '"},"version":"' + ver + '"}'
    return out


def to_bytes(v):
    return v if isinstance(v, bytes) else v.encode("ascii")


def fresh(prof, over=None, drop=(), staging=False):
    """A new field folder holding a profile's files, with `over` replacing values (str or bytes)."""
    f = dict(PROFILES[prof])
    f.update(over or {})
    if staging:
        f.pop("id")
    for d in drop:
        f.pop(d, None)
    _counter[0] += 1
    folder = os.path.join(WORK, "f%04d" % _counter[0])
    os.mkdir(folder)
    for k, v in f.items():
        with open(os.path.join(folder, k), "wb") as fh:
            fh.write(to_bytes(v))
    return folder


def prepared(prof, over=None):
    """A folder after a successful default run."""
    d = fresh(prof, over)
    rc, out, err = run_script([d])
    if out != OUT["pass"] or rc != 0 or err:
        raise RuntimeError("preparing " + prof + " failed: " + ascii(out))
    return d


def files_match(folder, prof, over=None):
    want = expected_outputs(prof, over)
    fields = dict(PROFILES[prof])
    fields.update(over or {})
    names = sorted(os.listdir(folder))
    wantnames = sorted(list(fields) + list(want))
    if names != wantnames:
        return "files " + ascii(names) + " wanted " + ascii(wantnames)
    for k, v in want.items():
        with open(os.path.join(folder, k), "rb") as fh:
            got = fh.read()
        if got != v.encode("ascii"):
            return k + " holds " + ascii(got) + " wanted " + ascii(v)
    return None


def make_link(target, link, is_dir):
    """A junction (Windows) or symlink to a folder; None when this machine cannot make one."""
    try:
        if os.name == "nt":
            if not is_dir:
                return False
            r = subprocess.run(
                ["cmd", "/c", "mklink", "/J", link, target], stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )
            ok = r.returncode == 0
        else:
            os.symlink(target, link, target_is_directory=is_dir)
            ok = True
    except OSError:
        ok = False
    if ok:
        LINKS.append((link, is_dir))
    return ok


# ---- 1. the real sources that must pass, and the outputs ---------------------------------------

REAL_SOURCES = [
    ("git", "https://github.com/psf/requests.git"),
    ("pypi", "https://pypi.org/simple/"),
    ("npm", "https://registry.npmjs.org"),
    ("download", "https://files.example.com:8443/a/b.tar.gz"),
    ("crate", "https://index.crates.io"),
]
for prof, src in REAL_SOURCES:
    d = fresh(prof, {"source": src})
    run_case("real source " + src, "pass", [d])

for prof in PROFILES:
    d = fresh(prof)
    run_case("outputs of the " + prof + " profile", "pass", [d], post=lambda d=d, prof=prof: files_match(d, prof))

d = fresh("npm", {"name": "scope@@name"})
run_case(
    "scope@@name with an npm: id passes, with its outputs",
    "pass",
    [d],
    post=lambda d=d: files_match(d, "npm", {"name": "scope@@name"}),
)

CRATE_URLS = [
    ("a", "1/a"),
    ("ab", "2/ab"),
    ("abc", "3/a/abc"),
    ("a+b", "3/a/a+b"),
    ("abcd", "ab/cd/abcd"),
    ("ab.c", "ab/.c/ab.c"),
    ("a.bc", "a./bc/a.bc"),
    ("A_B-c", "a_/b-/a_b-c"),
    ("_ab", "3/_/_ab"),
    ("a-b", "3/a/a-b"),
    ("serde", "se/rd/serde"),
]


def url_check(folder, want):
    p = os.path.join(folder, "url")
    if not os.path.exists(p):
        return "no url file"
    with open(p, "rb") as fh:
        got = fh.read()
    if got != want.encode("ascii"):
        return "url " + ascii(got) + " wanted " + ascii(want)
    return None


for cname, prefix in CRATE_URLS:
    d = fresh("crate", {"name": cname})
    run_case(
        "crate name " + ascii(cname),
        "pass",
        [d],
        post=lambda d=d, w="https://index.crates.io/" + prefix: url_check(d, w),
    )

# ---- 2. hostile and edge field values -------------------------------------------------------------


def field_case(field, value, expected="refused", prof="download", label=None):
    d = fresh(prof, {field: value})
    run_case((label or field) + " " + ascii(value), expected, [d])


SOURCE_REFUSED = [
    "https://example.com/a/../b",
    "https://example.com/./b",
    "https://example.com/a/..",
    "https://example.com/..",
    "https://example.com/.",
    "https://example.com/a/./",
    "http://example.com/",
    "HTTPS://example.com/",
    "ftp://example.com/",
    "file:///etc/passwd",
    "https://user@example.com/",
    "https://user:pw@example.com/",
    "https://example.com/%2e%2e/",
    "https://example.com/a%20b",
    "https://example.com\\a",
    "https://example.com/a?x=1",
    "https://example.com/a#f",
    "https://example.com/a'b",
    "https://example.com//b",
    "https://example.com/a//b",
    "https://127.0.0.1/",
    "https://2130706433/",
    "https://0x7f.1/",
    "https://[::1]/",
    "https://[::1]:8080/",
    "https://1.2.3.4/",
    "https://localhost/",
    "https://localhost:8000/x",
    "https://LOCALHOST/",
    "https://foo.localhost:1/",
    "https://a.localhost.example.com/",
    "https://example.com./",
    "https://example.com.",
    "https://a..com",
    "https://example.com:/x",
    "https://example.com:443:80/",
    " https://example.com",
    "https://example.com/a b",
    "https://example.com/$(id)",
    "https://example.com/;ls",
    "-https://example.com",
    "--upload-pack=x",
    "https://",
    "https:///x",
    "https://127.0.0.1:1?.legit.example/pkg",
    "https://%31%32%37.0.0.1:1/",
    "https://github.com@evil.example/x",
    "",
]
for v in SOURCE_REFUSED:
    field_case("source", v)

SOURCE_PASSED = [
    "https://example.com",
    "https://example.com/",
    "https://example.com/a/...",
    "https://example.com/.well-known/x",
    "https://example.com/.../b",
    "https://notlocalhost.com/",
    "https://localhost-info.example.com/x",
    "https://sub.example.com:8443/a/b.tar.gz",
    "https://github.com/psf/requests.git",
]
for v in SOURCE_PASSED:
    field_case("source", v, "pass")

NAME_REFUSED = [
    "a..b",
    "abc.",
    "CON",
    "con.txt",
    "lpt9",
    "Com1.tar.gz",
    "nul",
    "PRN",
    "aux.x",
    "com0",
    "LPT1.txt",
    "fields.x",
    "Fields.x",
    "-rf",
    ".hidden",
    "$(id)",
    "a/b",
    "a b",
    "a;b",
    "a'b",
    "a\\b",
    "a@b",
    "../x",
    "a/../b",
    "..",
    ".git",
    "a.",
    "a ",
    "nul.",
    "conin$",
    "conout$",
    "nul .txt",
    "git~1",
    "",
]
for v in NAME_REFUSED:
    field_case("name", v)
for v in ["scope@@@name", "@@name", "scope@@", "a@@b@@c", "scope@@name.", "scope@@..", "scope@@a..b", "con@@name.", "scope@@nul."]:
    field_case("name", v, prof="npm", label="npm name")
for prof in ("pypi", "download", "git", "crate"):
    field_case("name", "a@@b", prof=prof, label=prof + " name")
NAME_PASSED = ["a", "A_b-c.d+e", "A_b+c.d-e", "_x", "com", "console", "fieldset", "a.b"]
for v in NAME_PASSED:
    field_case("name", v, "pass")
field_case("name", "a.@@b", "pass", prof="npm", label="npm name")
field_case("name", "scope@@name", "pass", prof="npm", label="npm name")
field_case("name", b"a\x00/x", label="name raw")
field_case("name", b"a\x00", label="name raw")

for v in ["Dependency", "dependency ", "deps", "", "copied  code", "copied-code", "dependency\nclone", "DOWNLOAD"]:
    field_case("kind", v, prof="download")

ID_REFUSED = {
    "pypi": [
        "pypi:>=1.0@sha256:" + H,
        "pypi:1.0",
        "pypi:2.32.3@sha256:" + H.upper(),
        "pypi:2.32.3@sha256:" + H[:-1],
        "pypi:2.32.3@sha1:" + H[:40],
        "pypi:1.zip@sha256:" + H,
        "pypi:1.0.tar.gz@sha256:" + H,
        "pypi:1.whl@sha256:" + H,
        "pypi:1.0.TGZ@sha256:" + H,
        "pypi:1.tbz@sha256:" + H,
        "pypi:1.txz@sha256:" + H,
        "pypi:1.tlz@sha256:" + H,
        "pypi:1.0.TBZ@sha256:" + H,
        "pypi:1.0.tar.lz@sha256:" + H,
        "pypi:1.0.tar.lzma@sha256:" + H,
        "pypi:1.lz@sha256:" + H,
        "pypi:A_b+c.d-e@sha256:" + H,
        "pypi:~1.2.3@sha256:" + H,
        "pypi:v1.0.0@sha256:" + H,
        "pypi:1.0.0 || 2@sha256:" + H,
        "pypi:1.0.xz@sha256:" + H,
        "pypi:1.0.bz2@sha256:" + H,
        "pypi:1.0.tar@sha256:" + H,
        "pypi:latest@sha256:" + H,
    ],
    "git": [
        "git:main",
        "git:v1.0",
        "git:" + SHA[:39],
        "git:" + SHA + "0",
        "git:" + H,
        "git:" + SHA.upper(),
    ],
    "npm": [
        "npm:^1.0.0@" + INTEG,
        "npm:1.0@" + INTEG,
        "npm:1.0.0@sha1-abc",
        "npm:1.3.0@" + INTEG[:-3] + "==",
        "npm:1.3.0@" + INTEG[:-2],
        "npm:1.0.0-a.tgz@" + INTEG,
        "npm:1.0.0-a.tar.gz@" + INTEG,
        "npm:1.0.0+x.tar@" + INTEG,
        "npm:1.0.0-a.zip@" + INTEG,
        "npm:1.0.0-a.tbz@" + INTEG,
        "npm:1.0.0-a.tar.lzma@" + INTEG,
        "npm:1.3.x@" + INTEG,
        "npm:~1.2.3@" + INTEG,
        "npm:v1.0.0@" + INTEG,
        "npm:1.0.0 || 2@" + INTEG,
        "npm:^1.2.3@" + INTEG,
        "npm:>=1.0.0@" + INTEG,
        "npm:1.0.0-@@" + INTEG,
    ],
    "crate": [
        "crate:1@" + H,
        "crate:1.0.0@" + H.upper(),
        "crate:1.0.0-a.xz@" + H,
        "crate:1.0.0-a.txz@" + H,
        "crate:1.0.x@" + H,
        "crate:v1.0.0@" + H,
        "crate:1.0.0@" + H[:-1],
        "crate:1.0.0",
    ],
    "download": [
        "sha256:" + H + "0",
        H,
        "SHA256:" + H,
        "sha256:" + H[:-1],
        "sha256:" + H.upper(),
        "latest",
        "",
        "sha256:" + H + "\nsha256:" + H,
    ],
}
for prof, vals in ID_REFUSED.items():
    for v in vals:
        field_case("id", v, prof=prof, label=prof + " id")
ID_PASSED = [
    ("npm", "npm:1.0.0-rc.1+b.5@" + INTEG),
    ("npm", "npm:10.20.30@" + INTEG),
    ("pypi", "pypi:1.0.0-rc.1+b.5@sha256:" + H),
    ("pypi", "pypi:2.0.0.post1@sha256:" + H),
    ("pypi", "pypi:1.0.gzip@sha256:" + H),
    ("crate", "crate:1.0.0-rc.1+b.5@" + H),
]
for prof, v in ID_PASSED:
    field_case("id", v, "pass", prof=prof, label=prof + " id")

PAIR_REFUSED = [
    ("dependency", "git", "git:" + SHA),
    ("dependency", "download", "sha256:" + H),
    ("clone", "download", "sha256:" + H),
    ("clone", "pypi", "pypi:2.32.3@sha256:" + H),
    ("download", "pypi", "pypi:2.32.3@sha256:" + H),
    ("download", "git", "git:" + SHA),
    ("copied code", "git", "git:" + SHA),
    ("copied code", "npm", "npm:1.3.0@" + INTEG),
    ("download", "crate", "crate:1.0.0@" + H),
    ("clone", "npm", "npm:1.3.0@" + INTEG),
]
for kind, base, idv in PAIR_REFUSED:
    d = fresh(base, {"kind": kind, "id": idv})
    run_case("pairing refused: " + kind + " with " + idv.split(":")[0] + ":", "refused", [d])
for kind, base in [("copied code", "download"), ("download", "copied")]:
    d = fresh(base, {"kind": kind})
    run_case("pairing passes: " + kind + " with sha256:", "pass", [d])

for src in ["https://crates.io", "https://index.crates.io/", "https://index.crates.io/x", "https://example.com"]:
    field_case("source", src, prof="crate", label="crate source")

PURPOSE_REFUSED = [
    "x" * 81,
    "has: colon",
    "it's",
    "$(id)",
    "a;b",
    'say "hi"',
    "a/b",
    "`ls`",
    "a|b",
    "a@b",
    "Intake: pass: x 12345678",
    "",
    "line one\nline two",
]
for v in PURPOSE_REFUSED:
    field_case("purpose", v, label="purpose")
field_case("purpose", "x" * 80, "pass", label="purpose")
field_case("purpose", "tests", "pass", label="purpose")

# raw bytes: the file's shape
RAW = [
    ("no final LF", b"download", "pass"),
    ("one final LF", b"download\n", "pass"),
    ("two lines", b"download\nclone", "refused"),
    ("two final LFs", b"download\n\n", "refused"),
    ("a CR before the LF", b"download\r\n", "refused"),
    ("a CR in the line", b"down\rload", "refused"),
    ("a BOM", b"\xef\xbb\xbfdownload", "refused"),
    ("a NUL", b"download\x00", "refused"),
    ("a NUL inside", b"down\x00load", "refused"),
    ("non-ASCII", b"downl\xc3\xb3ad", "refused"),
    ("a tab", b"download\t", "refused"),
    ("an empty file", b"", "refused"),
    ("only an LF", b"\n", "refused"),
    ("over the size cap", b"x" * 5000, "refused"),
]
for label, raw, exp in RAW:
    d = fresh("download", {"kind": raw})
    run_case("kind file: " + label, exp, [d])
for field in ("name", "id", "source", "purpose"):
    for label, raw in [("two lines", None), ("a CR", None), ("a BOM", None), ("a NUL", None)]:
        base = to_bytes(PROFILES["download"][field])
        raw = {
            "two lines": base + b"\n" + base,
            "a CR": base + b"\r\n",
            "a BOM": b"\xef\xbb\xbf" + base,
            "a NUL": base + b"\x00",
        }[label]
        d = fresh("download", {field: raw})
        run_case(field + " file: " + label, "refused", [d])

# ---- 3. the folder: a closed set, no links -------------------------------------------------------

d = fresh("download")
open(os.path.join(d, "extra"), "wb").close()
run_case("folder: an extra file", "refused", [d])

d = fresh("download")
os.mkdir(os.path.join(d, "sub"))
run_case("folder: an extra directory", "refused", [d])

for missing in ("kind", "name", "id", "source", "purpose"):
    d = fresh("download", drop=(missing,))
    run_case("folder: missing " + missing, "refused", [d])

d = fresh("download")
os.remove(os.path.join(d, "purpose"))
os.mkdir(os.path.join(d, "purpose"))
run_case("folder: a directory where a field file should be", "refused", [d])

d = fresh("download")
os.rename(os.path.join(d, "kind"), os.path.join(d, "Kind"))
run_case("folder: a field file in the wrong case", "refused", [d])

d = fresh("download")
os.link(os.path.join(d, "kind"), os.path.join(WORK, "hardlink-of-kind-%d" % _counter[0]))
run_case("folder: a field file with link count 2", "refused", [d])

d = fresh("download")
# a link in a field file's place: a junction on Windows, a symlink elsewhere
tgt = os.path.join(WORK, "tgt%d" % _counter[0])
os.mkdir(tgt)
os.remove(os.path.join(d, "purpose"))
if make_link(tgt, os.path.join(d, "purpose"), True):
    run_case("folder: a link where a field file should be", "refused", [d])
else:
    NAMES.append("folder: a link where a field file should be")
    record("folder: a link where a field file should be", ["skipped: cannot make a link here"])

real = fresh("download")
lnk = os.path.join(WORK, "folder-link-%d" % _counter[0])
if make_link(real, lnk, True):
    run_case("folder: the field folder itself is a link or junction", "refused", [lnk])
else:
    NAMES.append("folder: the field folder itself is a link or junction")
    record("folder: the field folder itself is a link or junction", ["skipped: cannot make a link here"])

run_case("folder: does not exist", "refused", [os.path.join(WORK, "no-such-folder")])
empty = os.path.join(WORK, "empty-folder")
os.mkdir(empty)
run_case("folder: empty", "refused", [empty])
regular = os.path.join(WORK, "a-file")
open(regular, "wb").close()
run_case("folder: is a file", "refused", [regular])

# ---- 4. --staging --------------------------------------------------------------------------------

for prof in PROFILES:
    d = fresh(prof, staging=True)
    if PROFILES[prof]["kind"] == "dependency":
        # a dependency always has a published <id>, so it never stages
        run_case("--staging refuses a dependency: " + prof + " profile", "refused", ["--staging", d])
    else:
        run_case("--staging passes: " + prof + " profile", "pass", ["--staging", d])
d = fresh("copied", staging=True)
run_case(
    "--staging leaves the folder as it was",
    "pass",
    ["--staging", d],
    post=lambda d=d: None if sorted(os.listdir(d)) == ["kind", "name", "purpose", "source"] else "folder changed",
)
run_case("--staging refuses a folder holding id", "refused", ["--staging", fresh("copied")])
d = fresh("copied", staging=True)
open(os.path.join(d, "extra"), "wb").close()
run_case("--staging refuses an extra file", "refused", ["--staging", d])
run_case("--staging refuses scope@@name (no npm: id to pair)", "refused", ["--staging", fresh("npm", {"name": "scope@@name"}, staging=True)])
run_case("--staging refuses a bad name", "refused", ["--staging", fresh("copied", {"name": "a..b"}, staging=True)])
run_case("--staging refuses a bad source", "refused", ["--staging", fresh("copied", {"source": "https://127.0.0.1/"}, staging=True)])
run_case("--staging refuses a missing source", "refused", ["--staging", fresh("copied", drop=("source",), staging=True)])
run_case("--staging refuses a bad kind", "refused", ["--staging", fresh("copied", {"kind": "Clone"}, staging=True)])
run_case("--staging refuses a bad purpose", "refused", ["--staging", fresh("copied", {"purpose": "a: b"}, staging=True)])
run_case("default mode refuses four files (no id)", "refused", [fresh("copied", staging=True)])

# ---- 5. the mode sequence and --check ---------------------------------------------------------

d = fresh("pypi")
run_case("default mode on a fresh folder", "pass", [d])
run_case("default mode a second time is refused (its outputs exist)", "refused", [d])
run_case("--check after default mode passes", "pass", ["--check", d])
run_case("--check a second time passes", "pass", ["--check", d])
run_case("--staging after default mode is refused", "refused", ["--staging", d])
run_case("--check on a folder with no derived parts is refused", "refused", ["--check", fresh("pypi")])
run_case("--check on a staging folder is refused", "refused", ["--check", fresh("pypi", staging=True)])

for prof in PROFILES:
    base_over = {"name": "scope@@name"} if prof == "npm" else None
    derived = sorted(expected_outputs(prof, base_over))
    for fname in derived:
        d = prepared(prof, base_over)
        p = os.path.join(d, fname)
        with open(p, "rb") as fh:
            data = fh.read()
        with open(p, "wb") as fh:
            fh.write(data[:-1] + (b"0" if data[-1:] != b"0" else b"1"))
        run_case("--check refuses a changed " + fname + " (" + prof + ")", "refused", ["--check", d])
        d = prepared(prof, base_over)
        os.remove(os.path.join(d, fname))
        run_case("--check refuses a missing " + fname + " (" + prof + ")", "refused", ["--check", d])
        d = prepared(prof, base_over)
        with open(os.path.join(d, fname), "ab") as fh:
            fh.write(b"\n")
        run_case("--check refuses " + fname + " with an added LF (" + prof + ")", "refused", ["--check", d])
    d = prepared(prof, base_over)
    open(os.path.join(d, "extra"), "wb").close()
    run_case("--check refuses an extra file (" + prof + ")", "refused", ["--check", d])
    d = prepared(prof, base_over)
    os.mkdir(os.path.join(d, "sub"))
    run_case("--check refuses an extra directory (" + prof + ")", "refused", ["--check", d])

# a derived part that the id does not call for
d = prepared("download")
open(os.path.join(d, "pipspec"), "wb").write(b"x==1")
run_case("--check refuses a part the id does not produce", "refused", ["--check", d])

d = prepared("pypi")
with open(os.path.join(d, "name"), "wb") as fh:
    fh.write(b"other")
run_case("--check refuses a changed name (its parts no longer derive)", "refused", ["--check", d])
d = prepared("pypi")
with open(os.path.join(d, "id"), "wb") as fh:
    fh.write(b"pypi:2.32.4@sha256:" + H.encode("ascii"))
run_case("--check refuses a changed id", "refused", ["--check", d])
d = prepared("pypi")
with open(os.path.join(d, "source"), "wb") as fh:
    fh.write(b"https://127.0.0.1/")
run_case("--check re-runs the field checks (a bad source)", "refused", ["--check", d])
# every field file is bound by `digest`: a changed value that is itself valid still fails --check
for fld, newval in [
    ("purpose", b"A different, valid purpose"),
    ("source", b"https://example.org/other"),
    ("kind", None),
    ("purpose", PROFILES["pypi"]["purpose"].encode("ascii") + b"\n"),
    ("source", PROFILES["pypi"]["source"].encode("ascii") + b"\n"),
]:
    prof = "download" if fld == "kind" else "pypi"
    d = prepared(prof)
    if fld == "kind":
        newval = b"copied code"
    with open(os.path.join(d, fld), "wb") as fh:
        fh.write(newval)
    label = "a trailing LF added to " + fld if newval.endswith(b"\n") else "a changed, still valid " + fld
    run_case("--check refuses (the digest file binds all five) " + label, "refused", ["--check", d])
d = prepared("pypi")
with open(os.path.join(d, "source"), "wb") as fh:
    fh.write(b"https://example.org/other")
with open(os.path.join(d, "digest"), "wb") as fh:
    fh.write(b"0" * 64)
run_case("--check refuses a changed source with a forged digest file", "refused", ["--check", d])
d = prepared("pypi")
run_case("--check passes the untouched folder (the digest file matches)", "pass", ["--check", d])
d = prepared("pypi")
os.link(os.path.join(d, "hex"), os.path.join(WORK, "hardlink-of-hex-%d" % _counter[0]))
run_case("--check refuses a derived file with link count 2", "refused", ["--check", d])
d = prepared("pypi")
chk_link = os.path.join(WORK, "checklink%d" % _counter[0])
if make_link(d, chk_link, True):
    run_case("--check refuses a linked folder", "refused", ["--check", chk_link])
else:
    NAMES.append("--check refuses a linked folder")
    record("--check refuses a linked folder", ["skipped: cannot make a link here"])

# ---- 6. --crate-index -----------------------------------------------------------------------------


def index_file(lines):
    _counter[0] += 1
    p = os.path.join(WORK, "index%04d" % _counter[0])
    with open(p, "wb") as fh:
        fh.write(("\n".join(lines) + "\n").encode("utf-8"))
    return p


def entry(vers="1.0.200", cksum=H, yanked=False, name="serde"):
    import json

    return json.dumps({"name": name, "vers": vers, "deps": [], "cksum": cksum, "yanked": yanked})


other = entry(vers="1.0.199", cksum="0" * 64)
d = prepared("crate")
run_case("--crate-index: a matching line passes", "pass", ["--crate-index", index_file([other, entry()]), d])
run_case("--crate-index: a matching line, name in other case is refused (exact compare)", "refused", ["--crate-index", index_file([entry(name="Serde")]), d])
run_case("--crate-index: the Kelvin sign does not fold to k", "refused",
         ["--crate-index", index_file([entry(name="\N{KELVIN SIGN}iwi")]), prepared("crate", {"name": "kiwi"})])
run_case("--crate-index: the same name with an ASCII k passes", "pass",
         ["--crate-index", index_file([entry(name="kiwi")]), prepared("crate", {"name": "kiwi"})])

run_case("--crate-index: yanked passes as yanked", "yanked", ["--crate-index", index_file([other, entry(yanked=True)]), d])
run_case("--crate-index: a vers miss", "refused", ["--crate-index", index_file([other, entry(vers="1.0.201")]), d])
run_case("--crate-index: a cksum miss", "refused", ["--crate-index", index_file([entry(cksum="f" * 64)]), d])
run_case("--crate-index: a duplicate vers", "refused", ["--crate-index", index_file([entry(), entry()]), d])
run_case("--crate-index: a duplicate vers, one with another cksum", "refused", ["--crate-index", index_file([entry(cksum="f" * 64), entry()]), d])
run_case("--crate-index: malformed JSON", "refused", ["--crate-index", index_file([entry(), "{not json"]), d])
run_case("--crate-index: malformed JSON as the only line", "refused", ["--crate-index", index_file(["{not json"]), d])
run_case("--crate-index: an empty index file", "refused", ["--crate-index", index_file([]), d])
run_case("--crate-index: a line that is not an object", "refused", ["--crate-index", index_file(["[1,2]", entry()]), d])
run_case("--crate-index: another crate's name on the line", "refused", ["--crate-index", index_file([entry(name="serde_json")]), d])
run_case("--crate-index: yanked that is not a boolean", "refused", ["--crate-index", index_file([entry(yanked="no")]), d])
run_case("--crate-index: a missing index file", "refused", ["--crate-index", os.path.join(WORK, "no-such-index"), d])
run_case("--crate-index: the index file is a folder", "refused", ["--crate-index", WORK, d])
d2 = prepared("crate")
open(os.path.join(d2, "extra"), "wb").close()
run_case("--crate-index: an extra file in the folder", "refused", ["--crate-index", index_file([entry()]), d2])
d3 = prepared("crate")
with open(os.path.join(d3, "version"), "wb") as fh:
    fh.write(b"1.0.201")
run_case("--crate-index: a tampered version part", "refused", ["--crate-index", index_file([entry(vers="1.0.201")]), d3])
d4 = prepared("crate")
with open(os.path.join(d4, "hex"), "wb") as fh:
    fh.write(b"f" * 64)
run_case("--crate-index: a tampered hex part", "refused", ["--crate-index", index_file([entry(cksum="f" * 64)]), d4])
run_case("--crate-index: a pypi folder", "refused", ["--crate-index", index_file([entry()]), prepared("pypi")])
run_case("--crate-index: a folder with no derived parts", "refused", ["--crate-index", index_file([entry()]), fresh("crate")])
run_case("--crate-index: one argument short", "refused", ["--crate-index", index_file([entry()])])


def raw_index(data):
    _counter[0] += 1
    p = os.path.join(WORK, "index%04d" % _counter[0])
    with open(p, "wb") as fh:
        fh.write(data)
    return p


good_line = entry()
no_name = '{"vers":"1.0.200","cksum":"' + H + '","yanked":false}'
no_yanked = '{"name":"serde","vers":"1.0.200","cksum":"' + H + '"}'
run_case("--crate-index: a line with no name is refused", "refused", ["--crate-index", index_file([no_name]), d])
run_case("--crate-index: a line with no yanked passes as not yanked", "pass", ["--crate-index", index_file([no_yanked]), d])
run_case("--crate-index: a line with no cksum is refused", "refused",
         ["--crate-index", index_file(['{"name":"serde","vers":"1.0.200","yanked":false}']), d])
run_case("--crate-index: a name that is not a string is refused", "refused",
         ["--crate-index", index_file([entry(name=5)]), d])
run_case("--crate-index: invalid UTF-8 is refused", "refused",
         ["--crate-index", raw_index(good_line.encode("ascii") + b"\n" + b'{"name":"\xff"}\n'), d])
run_case("--crate-index: invalid UTF-8 as the whole file is refused", "refused", ["--crate-index", raw_index(b"\xff\xfe\n"), d])
run_case("--crate-index: blank lines between entries pass", "pass", ["--crate-index", raw_index(b"\n" + good_line.encode("ascii") + b"\n\n  \n"), d])
run_case("--crate-index: a duplicate cksum key is refused", "refused",
         ["--crate-index", index_file(['{"name":"serde","vers":"1.0.200","cksum":"' + "f" * 64 + '","cksum":"' + H + '","yanked":false}']), d])
run_case("--crate-index: a duplicate vers key is refused", "refused",
         ["--crate-index", index_file(['{"name":"serde","vers":"1.0.1","vers":"1.0.200","cksum":"' + H + '","yanked":false}']), d])
run_case("--crate-index: a duplicate yanked key is refused", "refused",
         ["--crate-index", index_file(['{"name":"serde","vers":"1.0.200","cksum":"' + H + '","yanked":true,"yanked":false}']), d])
run_case("--crate-index: a duplicate name key is refused", "refused",
         ["--crate-index", index_file(['{"name":"other","name":"serde","vers":"1.0.200","cksum":"' + H + '","yanked":false}']), d])
run_case("--crate-index: a duplicate key inside a nested object is refused", "refused",
         ["--crate-index", index_file(['{"name":"serde","vers":"1.0.200","cksum":"' + H + '","deps":[{"a":1,"a":2}],"yanked":false}']), d])

# ---- 7. --extract ---------------------------------------------------------------------------------


def make_archive(members, mode="w:gz", ext=".tar.gz", fmt=None):
    _counter[0] += 1
    path = os.path.join(WORK, "arc%04d%s" % (_counter[0], ext))
    with tarfile.open(path, mode, **({"format": fmt} if fmt is not None else {})) as tf:
        for name, kind, payload in members:
            ti = tarfile.TarInfo(name)
            if kind == "file":
                ti.size = len(payload)
                tf.addfile(ti, io.BytesIO(payload))
            elif kind == "dir":
                ti.type = tarfile.DIRTYPE
                ti.mode = 0o755
                tf.addfile(ti)
            elif kind == "sym":
                ti.type = tarfile.SYMTYPE
                ti.linkname = payload
                tf.addfile(ti)
            elif kind == "hard":
                ti.type = tarfile.LNKTYPE
                ti.linkname = payload
                tf.addfile(ti)
            elif kind in ("chr", "blk", "fifo"):
                # a device or FIFO member is only a header here; it is never extracted
                ti.type = {"chr": tarfile.CHRTYPE, "blk": tarfile.BLKTYPE, "fifo": tarfile.FIFOTYPE}[kind]
                tf.addfile(ti)
            elif kind == "paxfile":
                data, headers = payload
                ti.size = len(data)
                ti.pax_headers = headers
                tf.addfile(ti, io.BytesIO(data))
            elif kind == "paxdir":
                ti.type = tarfile.DIRTYPE
                ti.mode = 0o755
                ti.pax_headers = payload
                tf.addfile(ti)
    return path


def raw_archive(chunks, ext=".tar", gz_zero_blocks=None):
    """An archive from header blocks and bytes as given. gz_zero_blocks=(index, n): after chunk
    `index`, n bytes of zeros are streamed in (a gzip of them is small); the file is a tar.gz then."""
    _counter[0] += 1
    path = os.path.join(WORK, "raw%04d%s" % (_counter[0], ext))
    opener = (lambda: gzip.open(path, "wb", compresslevel=1)) if gz_zero_blocks else (lambda: open(path, "wb"))
    with opener() as out:
        for i, c in enumerate(chunks):
            out.write(c)
            if gz_zero_blocks and gz_zero_blocks[0] == i:
                left = gz_zero_blocks[1]
                zeros = bytes(1 << 20)
                while left > 0:
                    n = min(left, len(zeros))
                    out.write(zeros[:n])
                    left -= n
        out.write(bytes(1024))
    return path


def block(type_, size, name="././@LongLink"):
    ti = tarfile.TarInfo(name)
    ti.type = type_
    ti.size = size
    return ti.tobuf(tarfile.GNU_FORMAT)


def new_dest():
    _counter[0] += 1
    p = os.path.join(WORK, "dest%04d" % _counter[0])
    os.mkdir(p)
    return p


def tree(dest):
    found = {}
    for root, dirs, files in os.walk(dest):
        for n in files:
            full = os.path.join(root, n)
            with open(full, "rb") as fh:
                found[os.path.relpath(full, dest).replace(os.sep, "/")] = fh.read()
    return found


def extracted_ok(dest, want):
    got = tree(dest)
    return None if got == want else "extracted " + ascii(sorted(got)) + " wanted " + ascii(sorted(want))


def dest_empty(dest):
    left = os.listdir(dest)
    return None if left == [] else "dest not empty after a refusal: " + ascii(left)


GOOD = [("pkg", "dir", None), ("pkg/hello.txt", "file", b"hello"), ("pkg/sub/deep.txt", "file", b"deep")]
GOOD_WANT = {"pkg/hello.txt": b"hello", "pkg/sub/deep.txt": b"deep"}
_EMO = "\N{GRINNING FACE}"  # two UTF-16 units
_SAL = "\N{ARABIC LIGATURE SALLALLAHOU ALAYHE WASALLAM}"  # one character, 18 in NFKC
for label, mode, ext in [("tar.gz", "w:gz", ".tar.gz"), ("tar", "w", ".tar"), ("tar.xz", "w:xz", ".tar.xz"), ("tar.bz2", "w:bz2", ".tar.bz2")]:
    dest = new_dest()
    run_case("--extract passes a good " + label, "pass", ["--extract", make_archive(GOOD, mode, ext), dest],
             post=lambda dest=dest: extracted_ok(dest, GOOD_WANT))
dest = new_dest()
run_case("--extract passes names that begin ./", "pass",
         ["--extract", make_archive([("./", "dir", None), ("./pkg/a.txt", "file", b"a")]), dest],
         post=lambda dest=dest: extracted_ok(dest, {"pkg/a.txt": b"a"}))
dest = new_dest()
run_case("--extract passes names that merely look near the rules", "pass",
         ["--extract", make_archive([("git/a.txt", "file", b"1"), ("gitx~/b.txt", "file", b"2"), ("console/c.txt", "file", b"3"), ("a.b/d.txt", "file", b"4"), ("x...y/e.txt", "file", b"5")]), dest],
         post=lambda dest=dest: extracted_ok(dest, {"git/a.txt": b"1", "gitx~/b.txt": b"2", "console/c.txt": b"3", "a.b/d.txt": b"4", "x...y/e.txt": b"5"}))

dest = new_dest()
run_case("--extract passes a tar whose first member starts PK (PKG-INFO)", "pass",
         ["--extract", make_archive([("PKG-INFO", "file", b"meta"), ("PKGBUILD", "file", b"b")], "w", ".tar"), dest],
         post=lambda dest=dest: extracted_ok(dest, {"PKG-INFO": b"meta", "PKGBUILD": b"b"}))
dest = new_dest()
_uni = {"caf\N{LATIN SMALL LETTER E WITH ACUTE}/a b.txt": b"1", "\N{EURO SIGN}/\N{GRINNING FACE}.txt": b"2", "COM10/x": b"3"}
run_case("--extract passes names with non-ASCII letters, a space and COM10", "pass",
         ["--extract", make_archive([(k, "file", v) for k, v in _uni.items()]), dest],
         post=lambda dest=dest: extracted_ok(dest, _uni))
dest = new_dest()
run_case("--extract passes a 255-character component", "pass",
         ["--extract", make_archive([("d/" + "x" * 255, "file", b"1")]), dest],
         post=lambda dest=dest: extracted_ok(dest, {"d/" + "x" * 255: b"1"}))
dest = new_dest()
_u255 = "d/" + _EMO * 127 + "x"
run_case("--extract passes a component of exactly 255 UTF-16 units (astral characters)", "pass",
         ["--extract", make_archive([(_u255, "file", b"1")]), dest],
         post=lambda dest=dest: extracted_ok(dest, {_u255: b"1"}))
dest = new_dest()
_nf = _SAL * 14
run_case("--extract passes a component of 14 characters that is 252 long in NFKC", "pass",
         ["--extract", make_archive([(_nf, "file", b"1")]), dest],
         post=lambda dest=dest: extracted_ok(dest, {_nf: b"1"}))
dest = new_dest()
_near = {"a/b.txt": b"1", "a-b": b"2", "pkg/HEAD/x.txt": b"3", "pkg/HEADER": b"4", "pkg/heads": b"5"}
run_case("--extract passes HEAD as a folder, near names, and a folder after its content", "pass",
         ["--extract", make_archive([("a/b.txt", "file", b"1"), ("a", "dir", None), ("a-b", "file", b"2"), ("pkg/HEAD/x.txt", "file", b"3"), ("pkg/HEADER", "file", b"4"), ("pkg/heads", "file", b"5")]), dest],
         post=lambda dest=dest: extracted_ok(dest, _near))
dest = new_dest()
_headok = {"bin/head": b"1", "docs/HEAD": b"2", "docs/readme.txt": b"3", "x/HEAD": b"4", "y/objects/a": b"5", "x/sub/objects/b": b"6", "refs": b"7"}
run_case("--extract passes a head or HEAD file with no objects, refs or commondir beside it (bin/head, docs/HEAD)", "pass",
         ["--extract", make_archive([(k, "file", v) for k, v in _headok.items()]), dest],
         post=lambda dest=dest: extracted_ok(dest, _headok))
dest = new_dest()
_headdir = {"x/HEAD/a": b"1", "x/objects/b": b"2", "x/refs/c": b"3"}
run_case("--extract passes a folder called HEAD beside objects and refs (not a file)", "pass",
         ["--extract", make_archive([(k, "file", v) for k, v in _headdir.items()]), dest],
         post=lambda dest=dest: extracted_ok(dest, _headdir))
dest = new_dest()
run_case("--extract passes a pax header of about 900 KB", "pass",
         ["--extract", make_archive([("a.txt", "paxfile", (b"1", {"comment": "c" * 900000}))]), dest],
         post=lambda dest=dest: extracted_ok(dest, {"a.txt": b"1"}))
dest = new_dest()
run_case("--extract refuses a pax header of about 1.2 MB", "refused",
         ["--extract", make_archive([("a.txt", "paxfile", (b"1", {"comment": "c" * 1200000}))]), dest],
         post=lambda dest=dest: dest_empty(dest))

_BARE_REPO = [
    ("x/HEAD", "file", b"ref: refs/heads/main\n"),
    ("x/config", "file", b"[core]\n\tbare = false\n"),
    ("x/objects/info/.keep", "file", b""),
    ("x/refs/heads/.keep", "file", b""),
    ("readme.txt", "file", b"hello"),
]

BAD_MEMBERS = [
    ("a '..' member", [("ok.txt", "file", b"1"), ("../evil.txt", "file", b"x")]),
    ("a '..' inside a path", [("a/../../evil.txt", "file", b"x")]),
    ("a '..' that stays inside", [("a/../b.txt", "file", b"x")]),
    ("an absolute path", [("/etc/evil.txt", "file", b"x")]),
    ("a backslash-rooted path", [("\\evil.txt", "file", b"x")]),
    ("a backslash in a name", [("a\\b.txt", "file", b"x")]),
    ("a drive letter", [("C:evil.txt", "file", b"x")]),
    ("a colon in a name", [("a/b:stream", "file", b"x")]),
    ("a symlink", [("ln", "sym", "target")]),
    ("a symlink out of the tree", [("ln", "sym", "../../outside")]),
    ("a hard link", [("a.txt", "file", b"x"), ("hl", "hard", "a.txt")]),
    (".git/config", [(".git/config", "file", b"x")]),
    ("a .GIT folder deeper", [("a/.GIT/hooks/pre-commit", "file", b"x")]),
    ("a .git file", [("a/.git", "file", b"x")]),
    ("a .git folder entry", [(".git", "dir", None)]),
    ("GIT~1", [("GIT~1/config", "file", b"x")]),
    ("git~2 deeper", [("a/git~2", "file", b"x")]),
    (".git hidden by a zero-width joiner", [(".g\N{ZERO WIDTH JOINER}it/config", "file", b"x")]),
    ("a trailing dot", [("a./b.txt", "file", b"x")]),
    ("a trailing dot on the last component", [("b.", "file", b"x")]),
    ("a trailing space", [("b ", "file", b"x")]),
    ("a dot-only component", [("...", "file", b"x")]),
    ("a reserved name con.txt", [("con.txt", "file", b"x")]),
    ("a reserved name NUL inside a path", [("x/NUL", "file", b"x")]),
    ("a reserved name AUX", [("AUX", "file", b"x")]),
    ("a reserved name com1.log", [("d/com1.log", "file", b"x")]),
    ("a control character", [("a\x01b", "file", b"x")]),
    ("a '<' in a name", [("a<b", "file", b"x")]),
    ("a '>' in a name", [("a>b", "file", b"x")]),
    ("a double quote in a name", [('a"b', "file", b"x")]),
    ("a '|' in a name", [("a|b", "file", b"x")]),
    ("a '?' in a name", [("a?b", "file", b"x")]),
    ("a '*' in a name", [("a*b", "file", b"x")]),
    ("a 256-character component", [("d/" + "x" * 256, "file", b"x")]),
    ("a C1 control (NEL)", [("a\x85b", "file", b"x")]),
    ("a right-to-left override", [("evil\N{RIGHT-TO-LEFT OVERRIDE}txt.exe", "file", b"x")]),
    ("a soft hyphen (a format character)", [("a\N{SOFT HYPHEN}b", "file", b"x")]),
    ("fullwidth dots that fold to '..'", [("\N{FULLWIDTH FULL STOP}\N{FULLWIDTH FULL STOP}/x.txt", "file", b"x")]),
    ("a fullwidth backslash that folds to a backslash", [("a\N{FULLWIDTH REVERSE SOLIDUS}b", "file", b"x")]),
    ("a fullwidth solidus that folds to '/'", [("a\N{FULLWIDTH SOLIDUS}b", "file", b"x")]),
    ("a fullwidth colon that folds to ':'", [("a\N{FULLWIDTH COLON}b", "file", b"x")]),
    ("a one-dot leader that folds to a trailing dot", [("a\N{ONE DOT LEADER}", "file", b"x")]),
    ("a fullwidth .git that folds to .git", [("\N{FULLWIDTH FULL STOP}git/config", "file", b"x")]),
    ("a fullwidth GIT~1", [("\N{FULLWIDTH LATIN CAPITAL LETTER G}IT~1/x", "file", b"x")]),
    ("two names that differ only in case", [("pkg/A.txt", "file", b"1"), ("pkg/a.txt", "file", b"2")]),
    ("the same name twice", [("pkg/a.txt", "file", b"1"), ("pkg/a.txt", "file", b"2")]),
    ("two names equal after NFC", [("caf\N{LATIN SMALL LETTER E WITH ACUTE}.txt", "file", b"1"), ("cafe\N{COMBINING ACUTE ACCENT}.txt", "file", b"2")]),
    ("a name twice, once with ./", [("./pkg/a.txt", "file", b"1"), ("pkg/a.txt", "file", b"2")]),
    ("a character device after a good file", [("ok.txt", "file", b"1"), ("dev", "chr", None)]),
    ("a block device after a good file", [("ok.txt", "file", b"1"), ("dev", "blk", None)]),
    ("a FIFO after a good file", [("ok.txt", "file", b"1"), ("pipe", "fifo", None)]),
    ("a GNU.sparse 1.0 pax header", [("a.txt", "paxfile", (b"0\n" + bytes(510), {"GNU.sparse.major": "1", "GNU.sparse.minor": "0", "GNU.sparse.name": "a.txt", "GNU.sparse.realsize": "5"}))]),
    ("a GNU.sparse 0.0 pax header", [("a.txt", "paxfile", (b"hello", {"GNU.sparse.size": "5", "GNU.sparse.offset": "0", "GNU.sparse.numbytes": "5"}))]),
    ("a GNU.sparse 0.1 pax header", [("a.txt", "paxfile", (b"hello", {"GNU.sparse.map": "0,5"}))]),
    # a folder shaped like a bare git repository: git runs the config of a folder holding HEAD
    ("a bare-repository-shaped folder (x/HEAD)", _BARE_REPO),
    ("a bare-repository-shaped folder (x/Head)", [("x/Head", "file", b"ref: refs/heads/main\n")] + _BARE_REPO[1:]),
    ("a bare-repository-shaped folder, the HEAD last", _BARE_REPO[1:] + _BARE_REPO[:1]),
    ("a file called HEAD with a fullwidth letter, beside an implied objects", [("x/\N{FULLWIDTH LATIN CAPITAL LETTER H}EAD", "file", b"x"), ("x/objects/info/.keep", "file", b"")]),
    ("a file called HEAD at the top, beside files objects and refs", [("ok.txt", "file", b"1"), ("HEAD", "file", b"x"), ("objects", "file", b""), ("refs", "file", b"")]),
    ("a HEAD with only commondir beside it", [("x/HEAD", "file", b"x"), ("x/commondir", "file", b"../y")]),
    ("a HEAD beside empty files named objects and refs", [("x/HEAD", "file", b"x"), ("x/objects", "file", b""), ("x/refs", "file", b"")]),
    ("a HEAD beside an objects implied by a deeper name (no x/objects member)", [("x/HEAD", "file", b"x"), ("x/objects/info/.keep", "file", b"")]),
    ("a HEAD beside a refs implied by a deeper name", [("x/refs/heads/.keep", "file", b""), ("x/HEAD", "file", b"x")]),
    ("a HEAD beside a commondir implied by a deeper name", [("x/HEAD", "file", b"x"), ("x/commondir/a", "file", b"")]),
    ("a head in lower case beside OBJECTS", [("x/head", "file", b"x"), ("x/OBJECTS/a", "file", b"")]),
    ("a HEAD beside a sibling written with a fullwidth O", [("x/HEAD", "file", b"x"), ("x/\N{FULLWIDTH LATIN CAPITAL LETTER O}bjects/a", "file", b"")]),
    ("a HEAD beside a sibling written with a long s (refs)", [("x/HEAD", "file", b"x"), ("x/ref\N{LATIN SMALL LETTER LONG S}/a", "file", b"")]),
    ("a fullwidth HEAD beside a fullwidth sibling", [("x/\N{FULLWIDTH LATIN CAPITAL LETTER H}\N{FULLWIDTH LATIN CAPITAL LETTER E}\N{FULLWIDTH LATIN CAPITAL LETTER A}\N{FULLWIDTH LATIN CAPITAL LETTER D}", "file", b"x"), ("./x//\N{FULLWIDTH LATIN SMALL LETTER R}efs", "file", b"")]),
    ("a deeper HEAD beside its objects", [("a/b/HEAD", "file", b"x"), ("a/b/objects/x", "file", b"")]),
    # not a regular file, or no empty name or trailing slash: the names that extraction would treat differently
    ("a regular file with an empty name (./)", [("ok.txt", "file", b"1"), ("./", "file", b"x")]),
    ("a regular file named x/.", [("ok.txt", "file", b"1"), ("x/.", "file", b"x")]),
    ("a regular file named a/ (a trailing slash)", [("ok.txt", "file", b"1"), ("a/", "file", b"x")]),
    # a file and a folder cannot share a name: the listing pass must see it, not the extraction
    ("a file a, then a/b", [("a", "file", b"1"), ("a/b", "file", b"2")]),
    ("a/b, then a file a", [("a/b", "file", b"2"), ("a", "file", b"1")]),
    ("a file a/b, then a/b/c", [("a/b", "file", b"1"), ("a/b/c", "file", b"2")]),
    ("a file A, then a/b", [("A", "file", b"1"), ("a/b", "file", b"2")]),
    # NTFS counts UTF-16 code units, and an NFKC form can be longer than the name
    ("a component of 128 astral characters (256 UTF-16 units)", [("ok.txt", "file", b"1"), ("d/" + _EMO * 128, "file", b"x")]),
    ("a component that is 270 characters long in NFKC", [("ok.txt", "file", b"1"), (_SAL * 15, "file", b"x")]),
]
for label, members in BAD_MEMBERS:
    dest = new_dest()
    run_case("--extract refuses " + label, "refused", ["--extract", make_archive(members), dest],
             post=lambda dest=dest: dest_empty(dest))

# a zip, in two spellings
_counter[0] += 1
zpath = os.path.join(WORK, "z%04d.zip" % _counter[0])
with zipfile.ZipFile(zpath, "w") as zf:
    zf.writestr("a.txt", "x")
dest = new_dest()
run_case("--extract refuses a zip", "refused", ["--extract", zpath, dest], post=lambda dest=dest: dest_empty(dest))
_counter[0] += 1
zpath2 = os.path.join(WORK, "z%04d.tar.gz" % _counter[0])
shutil.copyfile(zpath, zpath2)
dest = new_dest()
run_case("--extract refuses a zip named .tar.gz", "refused", ["--extract", zpath2, dest], post=lambda dest=dest: dest_empty(dest))

# A header declaring 5 GiB with no data after it: refused whatever the cap, as the data is missing.
ti = tarfile.TarInfo("big.bin")
ti.size = 5 << 30
header = ti.tobuf(tarfile.GNU_FORMAT)
_counter[0] += 1
big = os.path.join(WORK, "big%04d.tar" % _counter[0])
with open(big, "wb") as fh:
    fh.write(header)
dest = new_dest()
run_case("--extract refuses a header declaring 5 GiB with no data", "refused", ["--extract", big, dest],
         post=lambda dest=dest: dest_empty(dest))

# Oversize for real: a gzip stream holding one member of 2 GiB + 1 byte of zeros (about 2 MB on disk).
# The cap is hit at the member's header, so nothing is decompressed for the listing and nothing is written.
CAP = 2 * 1024 * 1024 * 1024
ti = tarfile.TarInfo("zeros.bin")
ti.size = CAP + 1
_counter[0] += 1
bomb = os.path.join(WORK, "bomb%04d.tar.gz" % _counter[0])
with gzip.open(bomb, "wb", compresslevel=1) as gz:
    gz.write(ti.tobuf(tarfile.GNU_FORMAT))
    chunk = bytes(1 << 20)
    left = CAP + 1
    while left > 0:
        n = min(left, len(chunk))
        gz.write(chunk[:n])
        left -= n
    gz.write(bytes(512 - (CAP + 1) % 512) + bytes(1024))
dest = new_dest()
run_case("--extract refuses an oversize archive (a 2 GiB + 1 member in a tar.gz)", "refused",
         ["--extract", bomb, dest], post=lambda dest=dest: dest_empty(dest))
os.remove(bomb)

# other shapes
good = make_archive(GOOD)
nonempty = new_dest()
open(os.path.join(nonempty, "present"), "wb").close()
run_case("--extract refuses a non-empty dest", "refused", ["--extract", good, nonempty])
run_case("--extract refuses a dest that does not exist", "refused", ["--extract", good, os.path.join(WORK, "no-such-dest")])
run_case("--extract refuses a dest that is a file", "refused", ["--extract", good, regular])
realdest = new_dest()
lnkdest = os.path.join(WORK, "destlink%d" % _counter[0])
if make_link(realdest, lnkdest, True):
    run_case("--extract refuses a dest that is a link or junction", "refused", ["--extract", good, lnkdest],
             post=lambda: dest_empty(realdest))
else:
    NAMES.append("--extract refuses a dest that is a link or junction")
    record("--extract refuses a dest that is a link or junction", ["skipped: cannot make a link here"])
run_case("--extract refuses a missing archive", "refused", ["--extract", os.path.join(WORK, "no-such.tar"), new_dest()])
run_case("--extract refuses an archive that is a folder", "refused", ["--extract", WORK, new_dest()])
garbage = os.path.join(WORK, "garbage.tar")
with open(garbage, "wb") as fh:
    fh.write(b"this is not an archive" * 100)
run_case("--extract refuses a file that is not an archive", "refused", ["--extract", garbage, new_dest()])
emptyf = os.path.join(WORK, "empty.tar")
open(emptyf, "wb").close()
run_case("--extract refuses an empty file", "refused", ["--extract", emptyf, new_dest()])
with open(good, "rb") as fh:
    raw = fh.read()
trunc = os.path.join(WORK, "trunc.tar.gz")
with open(trunc, "wb") as fh:
    fh.write(raw[: len(raw) // 2])
run_case("--extract refuses a truncated archive", "refused", ["--extract", trunc, new_dest()])
run_case("--extract with one argument is refused", "refused", ["--extract", good])
run_case("--extract with three arguments is refused", "refused", ["--extract", good, new_dest(), "extra"])

# ---- 7b. header blocks: pax, long-name and sparse-map blocks are not members -------------------------

GIB = 1 << 30
HB = [
    # (label, archive, the declared size is real data in a tar.gz)
    ("a GNU long-name block declaring 1 GiB, with its data (tar.gz)", raw_archive([block(tarfile.GNUTYPE_LONGNAME, GIB)], ".tar.gz", (0, GIB))),
    ("a GNU long-link block declaring 1 GiB, with its data (tar.gz)", raw_archive([block(tarfile.GNUTYPE_LONGLINK, GIB)], ".tar.gz", (0, GIB))),
    ("a pax block declaring 1 GiB, with its data (tar.gz)", raw_archive([block(tarfile.XHDTYPE, GIB, "pax")], ".tar.gz", (0, GIB))),
    ("a global pax block declaring 1 GiB, with its data (tar.gz)", raw_archive([block(tarfile.XGLTYPE, GIB, "pax")], ".tar.gz", (0, GIB))),
    ("a Solaris pax block declaring 1 GiB, with its data (tar.gz)", raw_archive([block(tarfile.SOLARIS_XHDTYPE, GIB, "pax")], ".tar.gz", (0, GIB))),
    ("a pax block declaring 2.5 GiB in a 1.5 KB tar", raw_archive([block(tarfile.XHDTYPE, 5 * GIB // 2, "pax")])),
    ("a global pax block declaring 2.5 GiB in a 1.5 KB tar", raw_archive([block(tarfile.XGLTYPE, 5 * GIB // 2, "pax")])),
    ("a GNU long-name block declaring 2.5 GiB in a 1.5 KB tar", raw_archive([block(tarfile.GNUTYPE_LONGNAME, 5 * GIB // 2)])),
    ("a GNU long-name block just over the header cap", raw_archive([block(tarfile.GNUTYPE_LONGNAME, (1 << 20) + 1)], ".tar.gz", (0, (1 << 20) + 512))),
    ("a pax block with a negative size", raw_archive([block(tarfile.XHDTYPE, -1000, "pax")])),
    ("a GNU long-name block with a negative size", raw_archive([block(tarfile.GNUTYPE_LONGNAME, -1000)])),
    ("a regular member with a negative size", raw_archive([block(tarfile.REGTYPE, -1000, "a.txt")])),
    ("an old GNU sparse member", raw_archive([block(tarfile.GNUTYPE_SPARSE, 512, "a.txt"), bytes(512)])),
]
for label, path in HB:
    dest = new_dest()
    run_case("--extract refuses " + label, "refused", ["--extract", path, dest], post=lambda dest=dest: dest_empty(dest))
    os.remove(path)

# an ordinary long name, as a GNU long-name block and as a pax header, still extracts
dest = new_dest()
LONG = "d/" + "x" * 200
run_case("--extract passes an ordinary GNU long-name block", "pass",
         ["--extract", make_archive([(LONG, "file", b"1")], "w:gz", ".tar.gz", tarfile.GNU_FORMAT), dest],
         post=lambda dest=dest: extracted_ok(dest, {LONG: b"1"}))
dest = new_dest()
run_case("--extract passes an ordinary pax header", "pass",
         ["--extract", make_archive([(LONG, "file", b"1")], "w:gz", ".tar.gz", tarfile.PAX_FORMAT), dest],
         post=lambda dest=dest: extracted_ok(dest, {LONG: b"1"}))

# an empty zip is a zip too
_counter[0] += 1
ezip = os.path.join(WORK, "ez%04d.zip" % _counter[0])
with zipfile.ZipFile(ezip, "w"):
    pass
dest = new_dest()
run_case("--extract refuses an empty zip", "refused", ["--extract", ezip, dest], post=lambda dest=dest: dest_empty(dest))

# ---- 7c. --list --------------------------------------------------------------------------------------


def new_out():
    """A fresh folder for a --list file: (the folder, the path of an output file that does not exist yet)."""
    _counter[0] += 1
    folder = os.path.join(WORK, "lst%04d" % _counter[0])
    os.mkdir(folder)
    return folder, os.path.join(folder, "listing.txt")


def listed(folder, out, want):
    names = os.listdir(folder)
    if names != ["listing.txt"]:
        return "folder holds " + ascii(names)
    with open(out, "rb") as fh:
        got = fh.read()
    return None if got == want else "listing " + ascii(got) + " wanted " + ascii(want)


def not_listed(folder):
    names = os.listdir(folder)
    return None if names == [] else "a refused --list left " + ascii(names)


folder, out = new_out()
run_case("--list: a good tar.gz is listed, with type and size", "pass", ["--list", make_archive(GOOD), out],
         post=lambda folder=folder, out=out: listed(folder, out, b"d 0 pkg\nf 5 pkg/hello.txt\nf 4 pkg/sub/deep.txt\n"))
folder, out = new_out()
_names = ["caf\N{LATIN SMALL LETTER E WITH ACUTE}/\N{EURO SIGN}.txt", "a b/\N{GRINNING FACE}.txt"]
run_case("--list: names are written escaped to ASCII", "pass",
         ["--list", make_archive([(n, "file", b"1") for n in _names]), out],
         post=lambda folder=folder, out=out: listed(
             folder, out, b"f 1 caf\\xe9/\\u20ac.txt\nf 1 a b/\\U0001f600.txt\n"))
folder, out = new_out()
run_case("--list: an empty file is refused", "refused", ["--list", emptyf, out], post=lambda folder=folder: not_listed(folder))
folder, out = new_out()
with open(out, "wb") as fh:
    fh.write(b"keep")
run_case("--list: an existing output file is refused and left as it was", "refused", ["--list", good, out],
         post=lambda folder=folder, out=out: listed(folder, out, b"keep"))
folder, out = new_out()
run_case("--list: an output file in a folder that does not exist", "refused",
         ["--list", good, os.path.join(folder, "nope", "listing.txt")], post=lambda folder=folder: not_listed(folder))
folder, out = new_out()
run_case("--list: refuses a zip", "refused", ["--list", zpath, out], post=lambda folder=folder: not_listed(folder))
folder, out = new_out()
run_case("--list: refuses a missing archive", "refused", ["--list", os.path.join(WORK, "no-such.tar"), out],
         post=lambda folder=folder: not_listed(folder))
folder, out = new_out()
run_case("--list: one argument short", "refused", ["--list", good])
run_case("--list: three arguments", "refused", ["--list", good, out, "extra"])
for label, members in BAD_MEMBERS:
    folder, out = new_out()
    run_case("--list refuses " + label, "refused", ["--list", make_archive(members), out],
             post=lambda folder=folder: not_listed(folder))
folder, out = new_out()
run_case("--list refuses a pax block declaring 2.5 GiB", "refused",
         ["--list", raw_archive([block(tarfile.XHDTYPE, 5 * GIB // 2, "pax")]), out], post=lambda folder=folder: not_listed(folder))
folder, out = new_out()
run_case("--list extracts nothing", "pass", ["--list", make_archive(GOOD), out],
         post=lambda folder=folder: None if sorted(os.listdir(folder)) == ["listing.txt"] and not os.path.exists(os.path.join(WORK, "pkg")) else "extra files")

# ---- 7e. --tree ---------------------------------------------------------------------------------------


def new_tree(files, dirs=()):
    """A fresh folder holding `files` ({relative path: bytes}) and the empty folders `dirs`."""
    _counter[0] += 1
    root = os.path.join(WORK, "tree%04d" % _counter[0])
    os.mkdir(root)
    for rel in dirs:
        os.makedirs(os.path.join(root, *rel.split("/")), exist_ok=True)
    for rel, data in files.items():
        p = os.path.join(root, *rel.split("/"))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as fh:
            fh.write(data)
    return root


def snapshot(root):
    """Every entry under root with its size, links listed but never followed."""
    found = []
    stack = [root]
    while stack:
        cur = stack.pop()
        for n in sorted(os.listdir(cur)):
            p = os.path.join(cur, n)
            st = os.lstat(p)
            link = stat.S_ISLNK(st.st_mode) or bool(getattr(st, "st_file_attributes", 0) & 0x400)
            found.append((os.path.relpath(p, root), "l" if link else "d" if stat.S_ISDIR(st.st_mode) else st.st_size))
            if stat.S_ISDIR(st.st_mode) and not link:
                stack.append(p)
    return sorted(found)


def tree_case(label, want, root):
    """--tree on `root`: the verdict, and that the folder is exactly as it was."""
    before = snapshot(root)
    run_case("--tree " + label, want, ["--tree", root],
             post=lambda root=root, before=before: None if snapshot(root) == before else "--tree changed the folder")


_GITDIR = {".git/HEAD": b"ref: refs/heads/main\n", ".git/config": b"[core]\n", ".git/objects/aa/bb": b"x", ".git/refs/heads/main": b"0" * 40}
_CLEAN = {"README.md": b"x", "src/main.py": b"y", "src/sub/deep.txt": b"z", "bin/head": b"h", "docs/HEAD": b"H",
          "x/HEAD/a": b"1", "x/objects/b": b"2", "x/refs/c": b"3"}
tree_case("passes a clean tree, skipping the top-level .git folder (bin/head, docs/HEAD and a HEAD folder included)", "pass", new_tree(dict(_CLEAN, **_GITDIR)))
tree_case("passes a tree with no .git folder", "pass", new_tree(_CLEAN))
tree_case("passes an empty folder", "pass", new_tree({}))
tree_case("passes empty folders and one file", "pass", new_tree({"a.txt": b"1"}, ["e1", "e2/sub"]))
tree_case("passes names with non-ASCII letters, a space and COM10", "pass",
          new_tree({"caf\N{LATIN SMALL LETTER E WITH ACUTE}/a b.txt": b"1", "COM10/x": b"2", "\N{EURO SIGN}.txt": b"3"}))
_bare = {"HEAD": b"ref: refs/heads/main\n", "config": b"[core]\n\tbare = true\n", "objects/info/.keep": b"", "refs/heads/.keep": b""}
tree_case("refuses a committed bare-repository shape at the top (beside the clone's own .git)", "refused", new_tree(dict(_bare, **_GITDIR)))
tree_case("refuses a committed bare-repository shape in a subfolder", "refused", new_tree({"x/" + k: v for k, v in _bare.items()}))
tree_case("refuses a HEAD beside an empty folder objects", "refused", new_tree({"x/HEAD": b"h"}, ["x/objects"]))
tree_case("refuses a HEAD beside a file called refs", "refused", new_tree({"x/HEAD": b"h", "x/refs": b""}))
tree_case("refuses a HEAD with only commondir beside it", "refused", new_tree({"x/HEAD": b"h", "x/commondir": b"../y"}))
tree_case("refuses a head in lower case beside OBJECTS", "refused", new_tree({"x/head": b"h", "x/OBJECTS/a": b""}))
tree_case("refuses a HEAD beside a sibling written with a fullwidth O", "refused",
          new_tree({"x/HEAD": b"h", "x/\N{FULLWIDTH LATIN CAPITAL LETTER O}bjects/a": b""}))
tree_case("refuses a nested .git folder", "refused", new_tree(dict(_CLEAN, **{"sub/.git/config": b"[core]\n"})))
tree_case("refuses a nested .git file (a gitfile)", "refused", new_tree({"sub/.git": b"gitdir: ../elsewhere\n"}))
tree_case("refuses a top-level .git that is a file", "refused", new_tree({".git": b"gitdir: ../elsewhere\n"}))
tree_case("refuses a top-level .GIT folder (only the exact .git is skipped)", "refused", new_tree({".GIT/config": b"[core]\n"}))
tree_case("refuses a nested .Git folder", "refused", new_tree({"a/.Git/config": b"x"}))
tree_case("refuses a folder called git~1", "refused", new_tree({"git~1/config": b"x"}))
tree_case("refuses a zero-width joiner in a name", "refused", new_tree({"a\N{ZERO WIDTH JOINER}b.txt": b"x"}))
tree_case("refuses a soft hyphen in a name", "refused", new_tree({"a\N{SOFT HYPHEN}b.txt": b"x"}))
tree_case("refuses two names equal after NFC", "refused",
          new_tree({"caf\N{LATIN SMALL LETTER E WITH ACUTE}.txt": b"1", "cafe\N{COMBINING ACUTE ACCENT}.txt": b"2"}))
_tl = new_tree({"keep.txt": b"1"}, ["outside"])
_tlink = os.path.join(_tl, "linked")
_tout = os.path.join(WORK, "treeout%d" % _counter[0])
os.mkdir(_tout)
with open(os.path.join(_tout, "secret.txt"), "wb") as fh:
    fh.write(b"outside")
def skipped_case(label):
    """A link case that could not be built here: it is recorded as a failure, never passed vacuously."""
    NAMES.append("--tree " + label)
    record("--tree " + label, ["skipped: cannot make a link here"])


if make_link(_tout, _tlink, True):
    tree_case("refuses a junction or link to a folder", "refused", _tl)
else:
    skipped_case("refuses a junction or link to a folder")
_tl2 = new_tree({"keep.txt": b"1"})
if make_link(_tout, os.path.join(_tl2, ".git"), True):
    tree_case("refuses a top-level .git that is a junction or link (it is skipped only as a plain folder)", "refused", _tl2)
else:
    skipped_case("refuses a top-level .git that is a junction or link")
_tl3 = new_tree({"keep.txt": b"1"}, ["d"])
if make_link(_tout, os.path.join(_tl3, "d", "deep"), True):
    tree_case("refuses a junction or link nested in a folder", "refused", _tl3)
else:
    skipped_case("refuses a junction or link nested in a folder")
_tl4 = os.path.join(WORK, "treelink%d" % _counter[0])
if make_link(_tl, _tl4, True):
    run_case("--tree refuses a folder argument that is itself a junction or link", "refused", ["--tree", _tl4])
else:
    skipped_case("refuses a folder argument that is itself a junction or link")
run_case("--tree refuses a file as its argument", "refused", ["--tree", regular])
run_case("--tree refuses a folder that does not exist", "refused", ["--tree", os.path.join(WORK, "no-such-tree")])
run_case("--tree with no argument is refused", "refused", ["--tree"])
run_case("--tree with two arguments is refused", "refused", ["--tree", WORK, WORK])

# A regular file with a link count other than 1 (a tool that writes where it runs could swap a
# tracked file for a hard link to a same-content file outside the clone; `git status` calls that clean)
_th = new_tree({"README.md": b"same content", "src/a.txt": b"1"})
_th_out = os.path.join(WORK, "treehard-outside-%d" % _counter[0])
os.link(os.path.join(_th, "README.md"), _th_out)
tree_case("refuses a regular file that is a hard link to a file outside the folder (link count 2)", "refused", _th)
os.unlink(_th_out)
tree_case("passes the same folder once the other name is gone (link count 1 again: the control for the hard-link case)", "pass", _th)
_th2 = new_tree({"keep.txt": b"1", "a.txt": b"same"})
os.link(os.path.join(_th2, "a.txt"), os.path.join(_th2, "b.txt"))
tree_case("refuses two names for one file inside the folder (both have link count 2)", "refused", _th2)
_th3 = new_tree({"keep.txt": b"1"}, ["d"])
os.link(os.path.join(_th3, "keep.txt"), os.path.join(_th3, "d", "deep.txt"))
tree_case("refuses a hard link nested in a folder", "refused", _th3)

# The start of every function-level child: the script loaded as a module, and a fake archive member.
PRE = r"""
import importlib.util, sys
s = importlib.util.spec_from_file_location('ic', sys.argv[1])
m = importlib.util.module_from_spec(s)
s.loader.exec_module(m)


def out(ok):
    sys.stdout.buffer.write(b'intake-check: pass\n' if ok else b'intake-check: refused\n')
    sys.exit(0 if ok else 1)


class M:
    sparse = None
    size = 1

    def __init__(self, name):
        self.name = name

    def issym(self): return False
    def islnk(self): return False
    def isreg(self): return True
    def isdir(self): return False

"""

# --tree has its own caps, which mode_tree must use (the patched values prove the wiring)
TREE_WIRE_CODE = PRE + r"""
m.MAX_TREE_ENTRIES = int(sys.argv[3])
m.MAX_TREE_NAME_CHARS = int(sys.argv[4])
try:
    m.mode_tree(sys.argv[2])
    ok = True
except m.Refused:
    ok = False
out(ok)
"""
_big = 10 ** 9
_tw3 = new_tree({"a": b"1", "b": b"2", "c": b"3"})
_tw4 = new_tree({"a": b"1", "b": b"2", "c": b"3", "d": b"4"})
_tw_dir = new_tree({"a": b"1", "b": b"2"}, ["c"])
_tw_dir2 = new_tree({"a": b"1", "b": b"2"}, ["c", "d"])
_tw_git = new_tree(dict({"a": b"1", "b": b"2", "c": b"3"}, **{".git/o%d" % i: b"x" for i in range(10)}))
_tw_chars = new_tree({"aa": b"1", "bb": b"2", "cc": b"3"})
run_unit("tree cap wiring: a tree of exactly the entries cap passes (cap patched to 3)", TREE_WIRE_CODE, [_tw3, "3", str(_big)], "pass")
run_unit("tree cap wiring: one entry over the entries cap is refused (cap patched to 3)", TREE_WIRE_CODE, [_tw4, "3", str(_big)], "refused")
run_unit("tree cap wiring: a folder counts as an entry (two files and a folder pass at 3)", TREE_WIRE_CODE, [_tw_dir, "3", str(_big)], "pass")
run_unit("tree cap wiring: two files and two folders are over 3 and refused", TREE_WIRE_CODE, [_tw_dir2, "3", str(_big)], "refused")
run_unit("tree cap wiring: the top-level .git folder's contents are not counted", TREE_WIRE_CODE, [_tw_git, "3", str(_big)], "pass")
run_unit("tree cap wiring: name characters exactly at the cap pass (cap patched to 6)", TREE_WIRE_CODE, [_tw_chars, str(_big), "6"], "pass")
run_unit("tree cap wiring: one name character over the cap is refused (cap patched to 5)", TREE_WIRE_CODE, [_tw_chars, str(_big), "5"], "refused")

TREE_CAP_CODE = PRE + r"""
mode, delta = sys.argv[2], int(sys.argv[3])
if mode == 'values':
    out(m.MAX_TREE_ENTRIES == 500000 and m.MAX_TREE_NAME_CHARS == 64 * 1024 * 1024)
g = m.tree_gate()
try:
    if mode == 'count':
        for i in range(m.MAX_TREE_ENTRIES + delta):
            g.entry('n%d' % i, False)
    elif mode == 'chars':
        # 262,144 names of 256 characters are exactly 64 Mi characters; a count that stays under the entries cap
        n = m.MAX_TREE_NAME_CHARS // 256
        assert n * 256 == m.MAX_TREE_NAME_CHARS and n < m.MAX_TREE_ENTRIES
        for i in range(n):
            g.entry('%06d/' % i + 'b' * 249, False)
        if delta:
            g.entry('z', False)
    elif mode == 'archive-default':
        # the tree's caps do not loosen the archive gate's
        g = m.MemberGate()
        for i in range(m.MAX_ARCHIVE_MEMBERS + delta):
            g.entry('n%d' % i, False)
    ok = True
except m.Refused:
    ok = False
out(ok)
"""
run_unit("tree cap: the entries cap is 500,000 and the name-characters cap 64 Mi characters", TREE_CAP_CODE, ["values", "0"], "pass")
run_unit("tree cap: exactly 500,000 entries pass", TREE_CAP_CODE, ["count", "0"], "pass", timeout=240)
run_unit("tree cap: 500,001 entries are refused", TREE_CAP_CODE, ["count", "1"], "refused", timeout=240)
run_unit("tree cap: name characters exactly at 64 Mi pass", TREE_CAP_CODE, ["chars", "0"], "pass", timeout=240)
run_unit("tree cap: one name character over 64 Mi is refused", TREE_CAP_CODE, ["chars", "1"], "refused", timeout=240)
run_unit("tree cap: an archive gate still stops at 100,001 entries (the tree's caps are its own)", TREE_CAP_CODE, ["archive-default", "1"], "refused", timeout=240)
if os.name != "nt":
    _tp = new_tree({"keep.txt": b"1"})
    os.mkfifo(os.path.join(_tp, "pipe"))
    tree_case("refuses a FIFO (neither a regular file nor a folder)", "refused", _tp)
    _tq = new_tree({"keep.txt": b"1"})
    os.symlink("keep.txt", os.path.join(_tq, "ln"))
    tree_case("refuses a symlink to a file", "refused", _tq)
# (on Windows a FIFO and a file symlink cannot be made without privileges: those two cases are not run there)

# ---- 7f. --names ----------------------------------------------------------------------------------------
# The judgement of a clone's tree from `git ls-tree -r -t -z -l`, run before the checkout, on a pipe, so that
# no file of a refused tree and no listing is ever written. A listing is bytes, fed to the script's standard input. (Not
# `--format='%(objecttype) %(objectsize) %(path)'`: git 2.54 C-quotes the path under --format even with -z,
# so `caf\303\251` stands for a name that -z -l prints raw.)

OID = b"a" * 40


def rec(mode, typ, size, path, oid=OID):
    """One `git ls-tree -r -t -z -l` record: the size is padded on the left to 7 characters, then a TAB."""
    return mode + b" " + typ + b" " + oid + b" " + size.rjust(7) + b"\t" + path + b"\0"


def B(path, size=1, mode=b"100644"):
    return (mode, b"blob", str(size).encode("ascii"), path)


def T(path):
    return (b"040000", b"tree", b"-", path)


def G(path):
    return (b"160000", b"commit", b"-", path)


def raw_listing(data):
    return data


def listing(records):
    return b"".join(rec(m, t, sz, pa if isinstance(pa, bytes) else pa.encode("utf-8")) for m, t, sz, pa in records)


def names_case(label, want, data):
    """--names on a listing fed to standard input: the verdict, and that the script wrote no file."""
    before = sorted(os.listdir(WORK))

    def nothing_written():
        return None if sorted(os.listdir(WORK)) == before else "--names wrote into the work folder"

    run_case("--names " + label, want, ["--names", "-"], post=nothing_written, stdin=data)


# what git 2.54 printed for a tree with a non-ASCII folder and a space in a name (the gitlink record is written
# by hand in the same shape; the live case below has git make a real one)
REAL_LISTING = (
    b"100644 blob 5761abcfdf0c26a75374c945dfe366eaeee04285       4\t.gitignore\0"
    b"040000 tree ee7c41202adf50549accfa73da2e8ceda5b6420e       -\tbin\0"
    b"040000 tree cd3e15a4e334a1f62febfe0d6729562d7c608a0b       -\tcaf\xc3\xa9\0"
    b"100644 blob b68025345d5301abad4d9ec9166f455243a0d746       2\tcaf\xc3\xa9/a b.txt\0"
    b"160000 commit 1111111111111111111111111111111111111111       -\tsub/lib\0"
)
names_case("passes git's own output for a tree with a non-ASCII folder, a space in a name and a gitlink", "pass", raw_listing(REAL_LISTING))
_N_CLEAN = [
    T("src"), B("README.md"), B("src/main.py"), T("src/sub"), B("src/sub/deep.txt"), T("bin"), B("bin/head"), T("docs"),
    B("docs/HEAD"), T("x"), T("x/HEAD"), B("x/HEAD/a"), T("x/objects"), B("x/objects/b"), T("x/refs"), B("x/refs/c"),
    B(".gitignore"), B(".gitattributes"), T(".github"), B(".github/ci.yml"), T("vendor"), G("vendor/lib"),
    T("caf\N{LATIN SMALL LETTER E WITH ACUTE}"), B("caf\N{LATIN SMALL LETTER E WITH ACUTE}/a b.txt"), B("COM10"), B("\N{EURO SIGN}.txt"),
]
names_case("passes a clean tree (bin/head, docs/HEAD, a HEAD folder, a gitlink, a space, non-ASCII names)", "pass", listing(_N_CLEAN))
names_case("passes an empty listing (an empty tree)", "pass", raw_listing(b""))
names_case("passes a gitlink alone, as an empty folder", "pass", listing([T("vendor"), G("vendor/lib")]))
names_case("passes a gitlink called HEAD beside an objects folder (a gitlink is a folder, not the HEAD file)", "pass",
           listing([T("x"), G("x/HEAD"), T("x/objects"), B("x/objects/a")]))
names_case("refuses a gitlink called HEAD's twin, a file HEAD, beside the same objects folder (the control)", "refused",
           listing([T("x"), B("x/HEAD"), T("x/objects"), B("x/objects/a")]))

# the shapes the checkout must never be asked to write
_bare = [T("x"), B("x/HEAD"), B("x/config"), T("x/objects"), T("x/objects/info"), B("x/objects/info/.keep"), T("x/refs"), T("x/refs/heads"), B("x/refs/heads/.keep")]
names_case("refuses a committed bare-repository shape in a subfolder", "refused", listing(_bare))
names_case("refuses a committed bare-repository shape at the top", "refused",
           listing([B("HEAD"), B("config"), T("objects"), B("objects/info/.keep"), T("refs"), B("refs/heads/.keep")]))
names_case("refuses a HEAD whose objects sibling is only implied by a deeper name", "refused", listing([B("x/HEAD"), B("x/objects/info/.keep")]))
names_case("refuses a HEAD beside an empty folder objects", "refused", listing([B("x/HEAD"), T("x/objects")]))
names_case("refuses a HEAD beside a file called refs", "refused", listing([B("x/HEAD"), B("x/refs")]))
names_case("refuses a HEAD with only commondir beside it", "refused", listing([B("x/HEAD"), B("x/commondir")]))
names_case("refuses a head in lower case beside OBJECTS", "refused", listing([B("x/head"), B("x/OBJECTS/a")]))
names_case("refuses a HEAD beside a sibling written with a fullwidth O", "refused",
           listing([B("x/HEAD"), B("x/\N{FULLWIDTH LATIN CAPITAL LETTER O}bjects/a")]))

# .git and its spellings: nothing is skipped here, unlike --tree's own top-level .git
names_case("refuses a top-level .git folder (not skipped, unlike --tree's own)", "refused", listing([T(".git"), B(".git/config")]))
names_case("refuses a top-level .git file", "refused", listing([B(".git")]))
names_case("refuses a top-level .git gitlink", "refused", listing([G(".git")]))
names_case("refuses a nested .git folder", "refused", listing([T("sub"), T("sub/.git"), B("sub/.git/config")]))
names_case("refuses a nested .git file (a gitfile)", "refused", listing([T("sub"), B("sub/.git")]))
names_case("refuses a top-level .GIT folder", "refused", listing([T(".GIT"), B(".GIT/config")]))
names_case("refuses a nested .Git folder", "refused", listing([T("a"), T("a/.Git"), B("a/.Git/config")]))
names_case("refuses a folder called git~1", "refused", listing([T("git~1"), B("git~1/config")]))
names_case("refuses a gitlink called git~2", "refused", listing([G("git~2")]))

# names a file system or a shell would mishandle
for _label, _path in [
    ("a zero-width joiner", "a\N{ZERO WIDTH JOINER}b.txt"), ("a soft hyphen", "a\N{SOFT HYPHEN}b.txt"),
    ("a newline", "a\nb.txt"), ("a tab", "a\tb.txt"), ("a DEL", "a\x7fb"), ("a C1 control", "a\x85b"),
    ("a trailing dot", "a."), ("a trailing space", "a "), ("a device name", "nul.txt"), ("COM1", "COM1"),
    ("a device name with a space before the dot", "con .txt"), ("CONIN$", "CONIN$"), ("a colon", "a:b"), ("a backslash", "a\\b"),
    ("an angle bracket", "a<b"), ("a question mark", "a?b"), ("a dot-dot component", "a/../b"), ("a rooted path", "/etc/x"),
    ("a component of 256 characters", "x" * 256), ("a component of 128 emoji (256 UTF-16 units)", "\N{GRINNING FACE}" * 128),
]:
    names_case("refuses " + _label, "refused", listing([B(_path)]))
names_case("passes a component of exactly 255 characters", "pass", listing([B("x" * 255)]))
names_case("refuses two names equal after NFC", "refused",
           listing([B("caf\N{LATIN SMALL LETTER E WITH ACUTE}.txt"), B("cafe\N{COMBINING ACUTE ACCENT}.txt")]))
names_case("refuses two names that differ only in case", "refused", listing([B("A.txt"), B("a.txt")]))
names_case("refuses a name listed twice", "refused", listing([B("a.txt"), B("a.txt")]))
names_case("refuses a file a and a/b (the file/folder conflict)", "refused", listing([B("a"), B("a/b")]))
names_case("refuses a/b and then a file a (the conflict, either order)", "refused", listing([B("a/b"), B("a")]))
names_case("refuses a path that is not UTF-8", "refused", raw_listing(rec(b"100644", b"blob", b"1", b"\xff.txt")))
names_case("refuses a path that is a lone surrogate in UTF-8 clothing", "refused", raw_listing(rec(b"100644", b"blob", b"1", b"\xed\xa0\x80")))
names_case("refuses an empty path", "refused", raw_listing(rec(b"100644", b"blob", b"1", b"")))
names_case("refuses a path with a quote, judged as written (-z -l prints it raw; --format would have C-quoted it)", "refused",
           raw_listing(rec(b"100644", b"blob", b"1", b'q"uote')))
names_case("passes a non-ASCII path as git prints it with -z -l (raw UTF-8, not C-quoted)", "pass",
           raw_listing(rec(b"100644", b"blob", b"1", b"caf\xc3\xa9")))

# the record format
_ok = rec(b"100644", b"blob", b"1", b"a.txt")
names_case("passes one good record, the control for the malformed ones", "pass", raw_listing(_ok))
names_case("refuses a last record with no NUL", "refused", raw_listing(_ok[:-1]))
names_case("refuses a record with a space where the TAB belongs", "refused", raw_listing(_ok.replace(b"\t", b" ")))
names_case("refuses a record with no path field", "refused", raw_listing(b"100644 blob " + OID + b"       1\0"))
names_case("refuses a record with one field", "refused", raw_listing(b"a.txt\0"))
names_case("refuses an empty record between two good ones", "refused", raw_listing(_ok + b"\0" + _ok.replace(b"a.txt", b"b.txt")))
names_case("refuses a record ending in a newline instead of a NUL", "refused", raw_listing(_ok[:-1] + b"\n"))
names_case("refuses the format form (`blob 1 a.txt`, no mode and no object id)", "refused", raw_listing(b"blob 1 a.txt\0"))
for _t in (b"link", b"BLOB", b"blobx", b"object", b"tag", b""):
    names_case("refuses the type " + ascii(_t), "refused", raw_listing(rec(b"100644", _t, b"1", b"a")))
for _sz in (b"-", b"abc", b"-5", b"1.5", b"", b"1" * 16, b"0" * 15 + b"1", b"0x10"):
    names_case("refuses a blob of size " + ascii(_sz), "refused", raw_listing(b"100644 blob " + OID + b" " + _sz + b"\ta\0"))
names_case("refuses a blob size that is a number with a space inside it", "refused", raw_listing(b"100644 blob " + OID + b"  1 2\ta\0"))
names_case("passes a blob of size 0", "pass", listing([B("empty", 0)]))
names_case("passes a blob size of 15 digits with leading zeros", "pass", raw_listing(rec(b"100644", b"blob", b"000000000000001", b"a")))
for _sz in (b"1", b"0", b"abc", b""):
    names_case("refuses a tree of size " + ascii(_sz), "refused", raw_listing(b"040000 tree " + OID + b" " + _sz + b"\ta\0"))
    names_case("refuses a gitlink of size " + ascii(_sz), "refused", raw_listing(b"160000 commit " + OID + b" " + _sz + b"\ta\0"))
for _m, _t in ((b"040000", b"blob"), (b"100644", b"tree"), (b"160000", b"blob"), (b"100644", b"commit"), (b"000000", b"blob"),
               (b"100664", b"blob"), (b"1006444", b"blob"), (b"10064", b"blob")):
    names_case("refuses mode " + ascii(_m) + " on a " + _t.decode("ascii"), "refused",
               raw_listing(rec(_m, _t, b"-" if _t != b"blob" else b"1", b"a")))
for _m in (b"100755", b"120000"):
    names_case("passes a blob of mode " + ascii(_m) + " (an executable, a link that arrives as a plain file)", "pass",
               raw_listing(rec(_m, b"blob", b"1", b"a")))
for _oid in (b"a" * 39, b"a" * 41, b"A" * 40, b"g" * 40, b"", b"a" * 64):
    names_case("refuses an object id of " + ascii(_oid[:12]) + " (" + str(len(_oid)) + " characters)", "refused",
               raw_listing(rec(b"100644", b"blob", b"1", b"a", oid=_oid)))
_hl = len(rec(b"100644", b"blob", b"1", b"")) - 1  # a record's length before its NUL, with an empty path
_k = (65536 - _hl - 1) // 2
assert _hl + 2 * _k + 1 == 65536
names_case("a record of exactly 64 KiB passes", "pass", listing([B("a/" * _k + "a")]))
names_case("a record one byte over 64 KiB is refused", "refused", listing([B("a/" * _k + "bb")]))
names_case("a record of 80 KB made of short components is refused (the record cap, not the name rules)", "refused",
           listing([B("a/" * 40000 + "a")]))
names_case("refuses one 70,000-character name", "refused", raw_listing(rec(b"100644", b"blob", b"1", b"a" * 70000)))

# the byte cap: what the checkout would write, a blob counted once for each name that holds it
_GIB2 = 2 * 1024 ** 3
names_case("passes one blob of exactly 2 GiB", "pass", listing([B("big", _GIB2)]))
names_case("refuses one blob of 2 GiB + 1 byte", "refused", listing([B("big", _GIB2 + 1)]))
names_case("passes two blobs of 1 GiB each (exactly 2 GiB)", "pass", listing([B("a", _GIB2 // 2), B("b", _GIB2 // 2)]))
names_case("refuses 2 GiB and then one more byte", "refused", listing([B("a", _GIB2), B("b", 1)]))
names_case("refuses a 1 GiB blob and a 1 GiB + 1 byte blob", "refused", listing([B("a", _GIB2 // 2), B("b", _GIB2 // 2 + 1)]))
names_case("passes 2,048 names for one 1 MiB blob (exactly 2 GiB)", "pass", listing([B("f%d" % i, 1 << 20) for i in range(2048)]))
names_case("refuses 2,049 names for one 1 MiB blob (2 GiB + 1 MiB)", "refused", listing([B("f%d" % i, 1 << 20) for i in range(2049)]))
names_case("refuses the many-bytes shape: one 50 MB blob under 2,000 names (a 79 KB repo, 98 GiB checked out)", "refused",
           listing([B("f%d" % i, 50 * 10 ** 6) for i in range(2000)]))
names_case("refuses a blob size of 15 nines", "refused", raw_listing(rec(b"100644", b"blob", b"9" * 15, b"a")))

# the entry cap: files and folders count alike, as --tree counts them
names_case("passes exactly 500,000 entries (250,000 folders and 250,000 files)", "pass",
           listing([T("d%d" % i) for i in range(250000)] + [B("f%d" % i) for i in range(250000)]))
names_case("refuses 500,001 entries (250,000 folders and 250,001 files)", "refused",
           listing([T("d%d" % i) for i in range(250000)] + [B("f%d" % i) for i in range(250001)]))
names_case("refuses 500,001 folders and no file (a bound that counted files would see none)", "refused",
           listing([T("d%d" % i) for i in range(500001)]))
names_case("passes exactly 500,000 folders and no file", "pass", listing([T("d%d" % i) for i in range(500000)]))

NAMES_WIRE_CODE = PRE + r"""
m.MAX_TREE_ENTRIES = int(sys.argv[2])
m.MAX_TREE_NAME_CHARS = int(sys.argv[3])
m.MAX_TREE_BYTES = int(sys.argv[4])
if len(sys.argv) > 5:
    m.MAX_LISTING_BYTES = int(sys.argv[5])
try:
    m.mode_names(sys.stdin.buffer)
    ok = True
except m.Refused:
    ok = False
out(ok)
"""
_big = 10 ** 12
_nw3 = listing([B("a"), B("b"), B("c")])
_nw_dir = listing([B("a"), B("b"), T("c")])
_nw_dir2 = listing([B("a"), B("b"), T("c"), T("d")])
_nw_git = listing([B("a"), B("b"), G("c")])
_nw_chars = listing([B("aa"), B("bb"), B("cc")])
_nw_bytes = listing([B("a", 4), B("b", 6)])
def wire(label, data, entries, chars, blob_bytes, want, listing_bytes=None, timeout=60):
    """A child with the caps patched, the listing on its standard input."""
    args = [str(entries), str(chars), str(blob_bytes)] + ([] if listing_bytes is None else [str(listing_bytes)])
    run_unit("names wiring: " + label, NAMES_WIRE_CODE, args, want, timeout=timeout, stdin=data)


wire("exactly the entries cap passes (cap patched to 3)", _nw3, 3, _big, _big, "pass")
wire("one entry over the entries cap is refused (cap patched to 2)", _nw3, 2, _big, _big, "refused")
wire("a folder counts as an entry (two files and a folder pass at 3)", _nw_dir, 3, _big, _big, "pass")
wire("two files and two folders are over 3 and refused", _nw_dir2, 3, _big, _big, "refused")
wire("a gitlink counts as an entry (as the empty folder a checkout makes)", _nw_git, 2, _big, _big, "refused")
wire("name characters exactly at the cap pass (cap patched to 6)", _nw_chars, _big, 6, _big, "pass")
wire("one name character over the cap is refused (cap patched to 5)", _nw_chars, _big, 5, _big, "refused")
wire("blob bytes exactly at the cap pass (cap patched to 10)", _nw_bytes, _big, _big, 10, "pass")
wire("one byte over the byte cap is refused (cap patched to 9)", _nw_bytes, _big, _big, 9, "refused")
run_unit("names wiring: the byte cap is the archive gate's 2 GiB", PRE + r"""
out(m.MAX_TREE_BYTES == m.MAX_ARCHIVE_BYTES == 2 * 1024 ** 3)
""", [], "pass")

# the stream's own byte cap (MAX_LISTING_BYTES): exact at the cap, and checked as the stream is read
wire("a listing of exactly the stream cap passes (cap patched to its length)", _nw3, _big, _big, _big, "pass", listing_bytes=len(_nw3))
wire("a listing one byte over the stream cap is refused (cap patched to its length less one)", _nw3, _big, _big, _big, "refused",
     listing_bytes=len(_nw3) - 1)
_uniq = b"".join(rec(b"100644", b"blob", b"1", b"f%d" % i) for i in range(40000))
assert 2 * (1 << 20) < len(_uniq) < 3 * (1 << 20)
wire("a multi-chunk listing of clean unique names passes with the stream cap out of the way (the control)", _uniq, _big, _big, _big, "pass")
wire("a multi-chunk listing of clean unique names is refused at a 2 MiB stream cap (read across chunks; nothing else refuses it)", _uniq,
     _big, _big, _big, "refused", listing_bytes=2 * (1 << 20))
wire("a multi-chunk listing passes at a stream cap of exactly its length", _uniq, _big, _big, _big, "pass", listing_bytes=len(_uniq))
wire("a multi-chunk listing is refused at a stream cap of its length less one", _uniq, _big, _big, _big, "refused", listing_bytes=len(_uniq) - 1)
run_unit("names wiring: the stream cap is 320 MiB and covers the largest listing that passes the tree caps", PRE + r"""
head = 6 + 1 + 6 + 1 + 40 + 1 + 15 + 1 + 1  # mode, type, object id, a 15-digit size, a TAB and the NUL
worst = m.MAX_TREE_ENTRIES * head + m.MAX_TREE_NAME_CHARS * 4
out(m.MAX_LISTING_BYTES == 320 * 1024 * 1024 and worst < m.MAX_LISTING_BYTES)
""", [], "pass")

# the many-folders shape: 1,000 files, each at the end of its own chain of 49 folders (51,000 entries).
# A bound that counted files saw 1,000, while the checkout wrote 50,000 folders. The entries cap is patched so
# that the shape is over it.
_chains = []
for _i in range(1000):
    _p = "c%d" % _i
    _chains.append(T(_p))
    for _j in range(1, 50):
        _p += "/d%d" % _j
        _chains.append(T(_p))
    _chains.append(B(_p + "/f"))
_nw_chains = listing(_chains)
wire("the many-folders shape (51,000 entries, 1,000 of them files) is refused at a 50,999 cap", _nw_chains, 50999, _big, _big, "refused", timeout=120)
wire("the same many-folders shape passes at a 51,000 cap (the count is exact)", _nw_chains, 51000, _big, _big, "pass", timeout=120)
wire("the same many-folders shape is refused at a 1,000 cap, which is all a bound that counted files would allow", _nw_chains, 1000,
     _big, _big, "refused", timeout=120)

# an unterminated record is bounded as it is read, not only when it ends: a listing of 5 MiB with no NUL is
# refused after the first 1 MiB chunk (the output is the same either way; what differs is memory and time)
NAMES_TAIL_CODE = PRE + r"""
import io

reads = []


class Counting:
    def __init__(self, f):
        self.f = f

    def read(self, n=-1):
        d = self.f.read(n)
        reads.append(len(d))
        return d


data = sys.stdin.buffer.read()
try:
    for _ in m.listing_records(Counting(io.BytesIO(data))):
        pass
    refused = False
except m.Refused:
    refused = True
want = int(sys.argv[2])
out(refused == (want == 1 << 20) and sum(reads) == want)
"""
run_unit("names reading: a 5 MiB listing with no NUL is refused after its first 1 MiB (an unterminated record is bounded as it grows)",
         NAMES_TAIL_CODE, [str(1 << 20)], "pass", stdin=b"a" * (5 << 20))
_many = rec(b"100644", b"blob", b"1", b"f" * 10) * 20000
run_unit("names reading: 20,000 good records are read to their end, not stopped at 1 MiB (the control for the bound; the cap is on one record)",
         NAMES_TAIL_CODE.replace("refused == (want == 1 << 20) and", "(not refused) and"),
         [str(len(_many))], "pass", stdin=_many)

# the arguments: the listing is read from standard input and nowhere else
_nf = os.path.join(WORK, "a-good-listing.lst")
with open(_nf, "wb") as _fh:
    _fh.write(listing([B("a")]))
run_case("--names refuses a file path in the place of `-`, even one holding a good listing", "refused", ["--names", _nf], stdin=listing([B("a")]))
run_case("--names refuses a folder in the place of `-`", "refused", ["--names", WORK])
run_case("--names refuses a path that does not exist in the place of `-`", "refused", ["--names", os.path.join(WORK, "no-such-listing")])
run_case("--names with no argument is refused", "refused", ["--names"])
run_case("--names - with a third argument is refused", "refused", ["--names", "-", "-"], stdin=listing([B("a")]))
run_case("--names - passes the same good listing on standard input (the control)", "pass", ["--names", "-"], stdin=listing([B("a")]))

# a stream that never ends: the script refuses when a bound is reached and stops reading, so the writer
# gets a broken pipe. A real pipe to a live child, fed by a generator, which is cut off if it is never stopped.
def endless_case(label, chunks, limit):
    NAMES.append(label)
    problems = []
    proc = subprocess.Popen([sys.executable, "-I", "-S", "-B", SCRIPT, "--names", "-"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=WORK)
    sent = 0
    stopped_by_script = False
    before = sorted(os.listdir(WORK))
    try:
        for chunk in chunks():
            try:
                proc.stdin.write(chunk)
                proc.stdin.flush()
            except OSError:
                stopped_by_script = True
                break
            sent += len(chunk)
            if sent > 400 * (1 << 20):
                break
        try:
            proc.stdin.close()
        except OSError:
            pass
        proc.wait(timeout=120)
        out_, err_ = proc.stdout.read(), proc.stderr.read()
        if (proc.returncode, out_, err_) != (1, OUT["refused"], b""):
            problems.append("got " + ascii((proc.returncode, out_[:100], err_[:100])))
        if not stopped_by_script or sent > limit:
            problems.append("the writer was not stopped by the script: %d bytes sent (limit %d)" % (sent, limit))
        if sorted(os.listdir(WORK)) != before:
            problems.append("something was written into the work folder")
    except Exception as e:
        proc.kill()
        problems.append("harness error: " + ascii(repr(e)))
    finally:
        proc.stdout.close()
        proc.stderr.close()
    record(label, problems)


def endless_names():
    i = 0
    while True:
        yield b"".join(rec(b"100644", b"blob", b"1", b"f%d" % j) for j in range(i, i + 10000))
        i += 10000


def endless_no_nul():
    while True:
        yield b"x" * (1 << 16)


def endless_empty_records():
    while True:
        yield b"\0" * (1 << 16)


endless_case("--names: an endless stream of clean unique records is refused at the entries cap, and the writer is stopped (a pipe, never a file)",
             endless_names, 80 * (1 << 20))
endless_case("--names: an endless stream with no NUL is refused at the record cap, and the writer is stopped", endless_no_nul, 4 * (1 << 20))
endless_case("--names: an endless stream of empty records is refused at once, and the writer is stopped", endless_empty_records, 4 * (1 << 20))


def padded_over_cap():
    """A finite stream of 5,200 blob records of 65,000 bytes (338,000,000 in all, past the 320 MiB cap of 335,544,320), made
    by padding each record's size field with spaces, which the record's head pattern allows up to the 64 KiB record cap. Git
    never prints that padding, so this is no real listing. Every record is good and unique, the entries (5,200) and the name
    characters are far under their caps, and each blob is 1 byte: only the stream cap refuses it. Nothing is written to disk:
    the records are generated as they are sent."""
    head = b"100644 blob " + OID + b" "
    for i in range(5200):
        tail = b"1\t" + b"f%d" % i + b"\0"
        yield head + b" " * (65000 - len(head) - len(tail)) + tail


endless_case("--names: a finite stream of 5,200 records padded to 65,000 bytes (about 322 MiB, nothing else wrong with it) is refused by the stream cap alone, "
             "and the writer is stopped at the cap (end to end, through a pipe)", padded_over_cap, 322 * (1 << 20))

# ---- 7g. the same flow against real git: listing, names, checkout, tree, re-check -----------------------

EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
GITENV = dict(os.environ, HOME=WORK, USERPROFILE=WORK, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0")


def git(path, *args, env=None, data=None):
    p = subprocess.run(["git", "-C", path] + list(args), input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       env=env or GITENV, timeout=120)
    if p.returncode != 0:
        raise RuntimeError("git " + " ".join(args)[:60] + ": " + ascii(p.stderr[:200]))
    return p.stdout


def live_repo(files, gitlink=False):
    _counter[0] += 1
    r = os.path.join(WORK, "live%04d" % _counter[0])
    os.mkdir(r)
    git(r, "init", "-q", "-b", "main")
    for rel, data in files.items():
        fp = os.path.join(r, *rel.split("/"))
        os.makedirs(os.path.dirname(fp), exist_ok=True)
        with open(fp, "wb") as fh:
            fh.write(data)
    git(r, "add", "-A")
    if gitlink:
        git(r, "update-index", "--add", "--cacheinfo", "160000,%s,sub/lib" % ("1" * 40))
    git(r, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "m")
    return r, git(r, "rev-parse", "HEAD").decode("ascii").strip()


def live_repo_one_blob(data, count):
    """A repository whose one blob sits under `count` names, made with plumbing so that no working file is written."""
    _counter[0] += 1
    r = os.path.join(WORK, "live%04d" % _counter[0])
    os.mkdir(r)
    git(r, "init", "-q", "-b", "main")
    blob = git(r, "hash-object", "-w", "--stdin", data=data).decode("ascii").strip()
    tree = git(r, "mktree", data="".join("100644 blob %s\tf%d\n" % (blob, i) for i in range(count)).encode("ascii")).decode("ascii").strip()
    sha = git(r, "-c", "user.name=t", "-c", "user.email=t@t", "commit-tree", "-m", "m", tree).decode("ascii").strip()
    git(r, "update-ref", "refs/heads/main", sha)
    return r, sha


def live_clone(src, env=None, safe=True):
    """The protocol's clone line: no hooks (-c core.hooksPath) and no template. safe=False makes the control that shows what they prevent."""
    _counter[0] += 1
    dst = os.path.join(WORK, "clone%04d" % _counter[0])
    pre = ["-c", "core.hooksPath=" + os.devnull] if safe else []
    git(WORK, *(pre + ["clone", "-q"] + (["--template="] if safe else []) + ["--no-checkout", "--no-recurse-submodules", "--", src, dst]), env=env)
    return dst


def live_listing(clone, sha):
    return git(clone, "ls-tree", "-r", "-t", "-z", "-l", "--end-of-options", sha)


def live_checkout(clone, sha, attr_source=True, env=None, autocrlf=True, hooks=True):
    """The protocol's checkout: the empty-tree attribute source, symlinks and autocrlf off, no hooks.
    Each of the four can be left off to make a control that shows what it prevents."""
    pre = ["--attr-source=" + EMPTY_TREE] if attr_source else []
    flags = ["-c", "core.symlinks=false"] + (["-c", "core.autocrlf=false"] if autocrlf else []) + (
        ["-c", "core.hooksPath=" + os.devnull] if hooks else [])
    git(clone, *(pre + flags + ["checkout", "-q", "--detach", "--end-of-options", sha]), env=env)


def live_recheck(clone, env=None):
    """The protocol's re-check: a fresh index, then status under the empty-tree attribute source."""
    _counter[0] += 1
    idx = os.path.join(WORK, "idx%04d" % _counter[0])
    os.mkdir(idx)
    env = dict(env or GITENV, GIT_INDEX_FILE=os.path.join(idx, "index"))
    base = ["--attr-source=" + EMPTY_TREE, "-c", "core.hooksPath=" + os.devnull, "-c", "core.symlinks=false", "-c", "core.autocrlf=false",
            "--git-dir=.git", "--work-tree=."]
    git(clone, *(base + ["read-tree", "HEAD"]), env=env)
    return git(clone, *(base + ["status", "--porcelain", "--untracked-files=all", "--ignored", "--ignore-submodules=all"]), env=env)


def live_case(label, fn):
    NAMES.append(label)
    try:
        problem = fn()
    except Exception as e:
        problem = "live git case failed: " + ascii(repr(e))
    record(label, [problem] if problem else [])


def verdict(args, stdin=b""):
    rc, out, err = run_script(args, stdin=stdin)
    if err:
        return "stderr " + ascii(err[:100])
    return "pass" if (rc, out) == (0, OUT["pass"]) else "refused" if (rc, out) == (1, OUT["refused"]) else "odd " + ascii((rc, out))


def live_flow():
    src, sha = live_repo({
        "README.md": b"x\n", "src/main.py": b"y\n", "bin/head": b"h\n", "docs/HEAD": b"H\n", ".gitignore": b"*.o\n",
        "caf\N{LATIN SMALL LETTER E WITH ACUTE}/a b.txt": b"z\n", "x/HEAD/a": b"1\n",
    }, gitlink=True)
    clone = live_clone(src)
    v = verdict(["--names", "-"], stdin=live_listing(clone, sha))
    if v != "pass":
        return "--names on the real listing: " + v
    if sorted(os.listdir(clone)) != [".git"]:
        return "the clone holds more than .git before the checkout"
    live_checkout(clone, sha, True)
    lib = os.path.join(clone, "sub", "lib")
    if not os.path.isdir(lib) or os.listdir(lib) != []:
        return "the gitlink did not arrive as an empty folder"
    v = verdict(["--tree", clone])
    if v != "pass":
        return "--tree after the checkout: " + v
    left = live_recheck(clone)
    return None if left == b"" else "the re-check printed " + ascii(left[:200])


live_case("live git: --names passes the real ls-tree listing, the checkout then makes the gitlink an empty folder, and --tree and the re-check pass", live_flow)


def live_quoting():
    """Why --names reads `-z -l`: --format C-quotes a non-ASCII path even with -z, -l does not."""
    src, sha = live_repo({"caf\N{LATIN SMALL LETTER E WITH ACUTE}/a b.txt": b"z\n"})
    clone = live_clone(src)
    fmt = git(clone, "ls-tree", "-r", "-t", "-z", "--format=%(objecttype) %(objectsize) %(path)", "--end-of-options", sha)
    raw = git(clone, "ls-tree", "-r", "-t", "-z", "-l", "--end-of-options", sha)
    if b'"caf\\303\\251' not in fmt:
        return "this git no longer C-quotes %(path) under --format with -z: " + ascii(fmt[:120]) + " (revisit --names' record form)"
    if b"\tcaf\xc3\xa9\0" not in raw:
        return "-z -l did not print the raw path: " + ascii(raw[:160])
    return None


live_case("live git: --format C-quotes a non-ASCII path even with -z, and -z -l prints it raw (why --names reads -z -l)", live_quoting)


def live_bare():
    src, sha = live_repo({"readme.txt": b"r\n", "x/HEAD": b"ref: refs/heads/main\n", "x/config": b"[core]\n\tbare = true\n",
                          "x/objects/info/.keep": b"", "x/refs/heads/.keep": b""})
    clone = live_clone(src)
    v = verdict(["--names", "-"], stdin=live_listing(clone, sha))
    if v != "refused":
        return "--names on a committed bare shape: " + v
    return None if sorted(os.listdir(clone)) == [".git"] else "the clone holds more than .git: nothing should have been checked out"


live_case("live git: --names refuses the real listing of a committed bare-repository shape, and nothing was checked out", live_bare)


def live_bytes():
    # one 1 MiB blob under 2,049 names: a few KB of repository whose checkout would write 2 GiB + 1 MiB
    src, sha = live_repo_one_blob(b"z" * (1 << 20), 2049)
    clone = live_clone(src)
    v = verdict(["--names", "-"], stdin=live_listing(clone, sha))
    return None if v == "refused" else "--names on 2,049 names for one 1 MiB blob: " + v


live_case("live git: --names refuses the real listing of one 1 MiB blob under 2,049 names (a few KB of repository, 2 GiB of checkout)", live_bytes)


def live_attrs(attr_source):
    src, sha = live_repo({".gitattributes": b"* text eol=crlf\n", "a.txt": b"a\nb\n"})
    clone = live_clone(src)
    live_checkout(clone, sha, attr_source)
    with open(os.path.join(clone, "a.txt"), "rb") as fh:
        got = fh.read()
    left = live_recheck(clone)
    if attr_source:
        if got != b"a\nb\n":
            return "the checkout under the empty-tree attribute source wrote " + ascii(got)
        return None if left == b"" else "the re-check printed " + ascii(left[:200])
    # the control: without it the tree's own eol attribute acts, and the re-check cannot call the clone clean
    if got != b"a\r\nb\r\n":
        return "the control checkout wrote " + ascii(got) + ", so it proves nothing"
    return None if b"a.txt" in left else "the control's re-check printed " + ascii(left[:200])


live_case("live git: a clone whose tree sets `* text eol=crlf` re-checks clean when the checkout runs under the empty-tree attribute source",
          lambda: live_attrs(True))
live_case("live git: the control, a checkout without it, does not re-check clean", lambda: live_attrs(False))


def scratch_config(text):
    _counter[0] += 1
    p = os.path.join(WORK, "gitconfig%04d" % _counter[0])
    with open(p, "w", newline="\n") as fh:
        fh.write(text)
    return p


def live_autocrlf(env, autocrlf, want_crlf):
    """A blob a, LF, b, LF checked out under `env`, with or without -c core.autocrlf=false."""
    src, sha = live_repo({"a.txt": b"a\nb\n", "big.txt": b"x\n" * 1000})
    clone = live_clone(src, env=env)
    live_checkout(clone, sha, True, env=env, autocrlf=autocrlf)
    with open(os.path.join(clone, "a.txt"), "rb") as fh:
        got = fh.read()
    size = os.path.getsize(os.path.join(clone, "big.txt"))
    left = live_recheck(clone, env=env)
    if not want_crlf:
        if got != b"a\nb\n" or size != 2000:
            return "bytes did not arrive as stored: " + ascii(got) + ", big.txt " + str(size)
        return None if left == b"" else "the re-check printed " + ascii(left[:200])
    return None if got == b"a\r\nb\r\n" and size == 3000 else "the control did not convert: " + ascii(got) + ", big.txt " + str(size)


_ac_env = dict(GITENV, GIT_CONFIG_GLOBAL=scratch_config("[core]\n\tautocrlf = true\n"))
live_case("live git: with core.autocrlf=true in the global config, the checkout's -c core.autocrlf=false lands files as stored, and the re-check is clean",
          lambda: live_autocrlf(_ac_env, True, False))
live_case("live git: the control, the same config and no -c core.autocrlf=false, writes CRLF (a file grows by a byte a line)",
          lambda: live_autocrlf(_ac_env, False, True))

# the machine's own system config on (no GIT_CONFIG_NOSYSTEM, a scratch global only): whatever it holds, the checkout
# lands files as stored; the control runs only where the system config really sets autocrlf
_sys_env = dict(os.environ, HOME=WORK, USERPROFILE=WORK, GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0")
_sys_auto = subprocess.run(["git", "config", "--system", "--get", "core.autocrlf"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           env=_sys_env, timeout=60).stdout.strip().decode("ascii", "replace")
live_case("live git: with this machine's system config on (it sets core.autocrlf to %s), the checkout lands files as stored and the re-check is clean"
          % (_sys_auto or "nothing"), lambda: live_autocrlf(_sys_env, True, False))
if _sys_auto == "true":
    live_case("live git: the control under the system config, no -c core.autocrlf=false, writes CRLF", lambda: live_autocrlf(_sys_env, False, True))
else:
    # recorded as a passing case that says it did not run, so no case is silently skipped and the count is the same on every machine
    print("note  this machine's system config does not set core.autocrlf=true, so there is no system-config control; "
          "the scratch-global control above stands in for it")
    live_case("live git: the control under the system config is not run here (this machine's system config does not set core.autocrlf=true; "
              "the scratch-global control above stands in for it)", lambda: None)


def live_hook(hooks):
    """init.templateDir copies a post-checkout hook into every new clone; -c core.hooksPath keeps it from running."""
    _counter[0] += 1
    tpl = os.path.join(WORK, "tpl%04d" % _counter[0])
    os.makedirs(os.path.join(tpl, "hooks"))
    marker = os.path.join(WORK, "hook-ran-%d" % _counter[0])
    hook = os.path.join(tpl, "hooks", "post-checkout")
    with open(hook, "w", newline="\n") as fh:
        fh.write("#!/bin/sh\necho ran > '" + marker.replace("\\", "/") + "'\n")
    os.chmod(hook, 0o755)
    env = dict(GITENV, GIT_CONFIG_GLOBAL=scratch_config("[init]\n\ttemplateDir = " + tpl.replace("\\", "/") + "\n"))
    src, sha = live_repo({"a.txt": b"a\n"})
    clone = live_clone(src, env=env, safe=False)
    if not os.path.exists(os.path.join(clone, ".git", "hooks", "post-checkout")):
        return "the template hook was not copied into the clone, so the case proves nothing"
    live_checkout(clone, sha, True, env=env, hooks=hooks)
    ran = os.path.exists(marker)
    if hooks:
        return "the post-checkout hook ran under -c core.hooksPath" if ran else None
    return None if ran else "the control: the hook did not run without -c core.hooksPath, so the case proves nothing"


live_case("live git: a post-checkout hook copied in from the global template directory does not run under -c core.hooksPath", lambda: live_hook(True))
live_case("live git: the control, the same checkout without -c core.hooksPath, runs that hook", lambda: live_hook(False))


def live_clone_hooks(via, safe):
    """The clone line itself fires hooks (a reference-transaction hook, fed ref names the remote chose), and a template
    directory's info/attributes would convert the checkout. via is where the hook comes from: the global init.templateDir
    (which also carries an info/attributes of `* text eol=crlf`) or the global core.hooksPath."""
    _counter[0] += 1
    tpl = os.path.join(WORK, "ctpl%04d" % _counter[0])
    hooks = os.path.join(tpl, "hooks")
    os.makedirs(hooks)
    os.makedirs(os.path.join(tpl, "info"))
    marker = os.path.join(WORK, "clone-hook-ran-%d" % _counter[0])
    hook = os.path.join(hooks, "reference-transaction")
    with open(hook, "w", newline="\n") as fh:
        fh.write("#!/bin/sh\necho ran >> '" + marker.replace("\\", "/") + "'\n")
    os.chmod(hook, 0o755)
    with open(os.path.join(tpl, "info", "attributes"), "w", newline="\n") as fh:
        fh.write("* text eol=crlf\n")
    if via == "template":
        text = "[init]\n\ttemplateDir = " + tpl.replace("\\", "/") + "\n"
    else:
        text = "[core]\n\thooksPath = " + hooks.replace("\\", "/") + "\n"
    env = dict(GITENV, GIT_CONFIG_GLOBAL=scratch_config(text))
    src, sha = live_repo({"a.txt": b"a\nb\n"})
    clone = live_clone(src, env=env, safe=safe)
    ran = os.path.exists(marker)
    attrs = os.path.exists(os.path.join(clone, ".git", "info", "attributes"))
    if safe:
        if ran:
            return "a reference-transaction hook ran during the clone under -c core.hooksPath and --template="
        if os.path.exists(os.path.join(clone, ".git", "hooks", "reference-transaction")) or attrs:
            return "the clone holds a hook or an info/attributes from the template"
        live_checkout(clone, sha, True, env=env)
        with open(os.path.join(clone, "a.txt"), "rb") as fh:
            got = fh.read()
        left = live_recheck(clone, env=env)
        if got != b"a\nb\n":
            return "the checkout after the safe clone wrote " + ascii(got)
        return None if left == b"" else "the re-check printed " + ascii(left[:200])
    # the control: the clone with neither runs the hook, and (from the template) takes its attributes, which act at the checkout
    if not ran:
        return "the control: the hook did not run during the clone, so the case proves nothing"
    if via == "template":
        if not attrs:
            return "the control: the template's info/attributes was not copied into the clone, so the case proves nothing"
        live_checkout(clone, sha, True, env=env)
        with open(os.path.join(clone, "a.txt"), "rb") as fh:
            got = fh.read()
        if got != b"a\r\nb\r\n":
            return "the control: the checkout wrote " + ascii(got) + " (the template's attributes did not act)"
    return None


live_case("live git: the clone line, with -c core.hooksPath and --template=, runs no reference-transaction hook from the global template directory, "
          "copies no info/attributes from it, and the checkout and the re-check are clean", lambda: live_clone_hooks("template", True))
live_case("live git: the control, the same clone without them, runs the template's reference-transaction hook, and its info/attributes then "
          "converts the checkout to CRLF", lambda: live_clone_hooks("template", False))
live_case("live git: the clone line, with -c core.hooksPath and --template=, runs no reference-transaction hook from the global core.hooksPath",
          lambda: live_clone_hooks("hookspath", True))
live_case("live git: the control, the same clone without them, runs the reference-transaction hook from the global core.hooksPath",
          lambda: live_clone_hooks("hookspath", False))


def live_missing_file():
    """A blob-mode entry whose object is a tree: --names passes it (a size is printed), `checkout` reports an error and
    exits 0, so only the re-check shows the file missing."""
    _counter[0] += 1
    r = os.path.join(WORK, "live%04d" % _counter[0])
    os.mkdir(r)
    git(r, "init", "-q", "-b", "main")
    blob = git(r, "hash-object", "-w", "--stdin", data=b"x\n").decode("ascii").strip()
    sub = git(r, "mktree", data=("100644 blob %s\tinner\n" % blob).encode("ascii")).decode("ascii").strip()
    raw = b"100644 f\0" + bytes.fromhex(sub)
    bad = git(r, "hash-object", "-t", "tree", "--literally", "-w", "--stdin", data=raw).decode("ascii").strip()
    sha = git(r, "-c", "user.name=t", "-c", "user.email=t@t", "commit-tree", "-m", "m", bad).decode("ascii").strip()
    git(r, "update-ref", "refs/heads/main", sha)
    clone = live_clone(r)
    listing_bytes = live_listing(clone, sha)
    v = verdict(["--names", "-"], stdin=listing_bytes)
    if v != "pass":
        return "--names on the blob-mode entry whose object is a tree: " + v + " " + ascii(listing_bytes[:120])
    live_checkout(clone, sha, True)
    left = live_recheck(clone)
    return None if b" D f" in left else "the re-check did not show the missing file: " + ascii(left[:200])


live_case("live git: a blob-mode entry whose object is a tree passes --names, the checkout exits 0, and only the re-check shows the file missing",
          live_missing_file)


def live_bomb():
    """A tree that reuses one subtree at every level: 80 entries a level, three levels, 518,480 listed paths from a repository
    of a few KB. git's listing goes straight into the script on a pipe; the script refuses at its entries cap, and nothing
    is written. (The same shape one level deeper is 4 billion paths.)"""
    _counter[0] += 1
    r = os.path.join(WORK, "live%04d" % _counter[0])
    os.mkdir(r)
    git(r, "init", "-q", "-b", "main")
    blob = git(r, "hash-object", "-w", "--stdin", data=b"x\n").decode("ascii").strip()
    t = git(r, "mktree", data="".join("100644 blob %s\tf%d\n" % (blob, i) for i in range(80)).encode("ascii")).decode("ascii").strip()
    for _ in range(2):
        t = git(r, "mktree", data="".join("040000 tree %s\td%d\n" % (t, i) for i in range(80)).encode("ascii")).decode("ascii").strip()
    sha = git(r, "-c", "user.name=t", "-c", "user.email=t@t", "commit-tree", "-m", "m", t).decode("ascii").strip()
    git(r, "update-ref", "refs/heads/main", sha)
    clone = live_clone(r)
    before = sorted(os.listdir(WORK)) + sorted(os.listdir(clone))
    g = subprocess.Popen(["git", "-C", clone, "ls-tree", "-r", "-t", "-z", "-l", "--end-of-options", sha], stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=GITENV)
    s = subprocess.Popen([sys.executable, "-I", "-S", "-B", SCRIPT, "--names", "-"], stdin=g.stdout, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, cwd=WORK)
    g.stdout.close()
    try:
        out_, err_ = s.communicate(timeout=240)
        try:
            g.wait(timeout=120)
        except subprocess.TimeoutExpired:
            g.kill()
            g.wait()
        g.stderr.close()
    except Exception:
        s.kill()
        g.kill()
        raise
    if (s.returncode, out_, err_) != (1, OUT["refused"], b""):
        return "the pipe's verdict: " + ascii((s.returncode, out_[:100], err_[:100]))
    after = sorted(os.listdir(WORK)) + sorted(os.listdir(clone))
    return None if after == before and sorted(os.listdir(clone)) == [".git"] else "something was written: " + ascii(after[-6:])


live_case("live git: a real repository of a few KB that lists 518,480 paths (one subtree reused at every level) is refused on the pipe, and nothing is written",
          live_bomb)

# ---- 7d. the total header bound, retained pax headers, chained blocks, and .xz memory -----------------


def padded(b):
    return b + bytes(-len(b) % 512)


def pax_record(key, value):
    body = " %s=%s\n" % (key, value)
    n = len(body) + 1
    while len(str(n)) + len(body) != n:
        n = len(str(n)) + len(body)
    return ("%d%s" % (n, body)).encode("ascii")


def gz_archive(chunks, tail=bytes(1024)):
    _counter[0] += 1
    path = os.path.join(WORK, "gz%04d.tar.gz" % _counter[0])
    with gzip.open(path, "wb", compresslevel=1) as out:
        for c in chunks:
            out.write(c)
        out.write(tail)
    return path


# Total header bound, shape 1: many members, each with a pax header just under the per-block cap.
# (She used 2,000 members; the total cap fires at the 17th, so 40 show the same thing.)
shape1 = make_archive([("m%03d" % i, "paxfile", (b"1", {"comment": "c" * 999000})) for i in range(40)])
# shape 2: one global header of 80,000 small keys, then many empty members each after a small
# extended header, so each member keeps its own copy of the 80,000-entry dict
_g = b"".join(pax_record("k%05d" % i, "v") for i in range(80000))
_x = pax_record("comment", "c")
_chunks = [block(tarfile.XGLTYPE, len(_g), "pax"), padded(_g)]
for i in range(300):
    _chunks += [block(tarfile.XHDTYPE, len(_x), "pax"), padded(_x), tarfile.TarInfo("m%05d" % i).tobuf(tarfile.GNU_FORMAT)]
shape2 = gz_archive(_chunks)
# 16 global blocks of distinct keys (1.12 M entries) in a row, then one member: the chain cap stops it at the fifth
_chunks = []
for j in range(16):
    gj = b"".join(pax_record("k%02d%05d" % (j, i), "v") for i in range(70000))
    _chunks += [block(tarfile.XGLTYPE, len(gj), "pax"), padded(gj)]
_chunks += [block(tarfile.XHDTYPE, len(_x), "pax"), padded(_x), tarfile.TarInfo("m").tobuf(tarfile.GNU_FORMAT)]
shape3 = gz_archive(_chunks)
# Shape 4: 4 global blocks (4 x 90,000 = 360,000 distinct keys), then 200 chained zero-size extended blocks, then one
# empty member. Each level of the chain held a copy of the global dict (3 GB at her size).
_chunks = []
for j in range(4):
    gj = b"".join(pax_record(str(j * 100000 + i), "") for i in range(90000))
    _chunks += [block(tarfile.XGLTYPE, len(gj), "pax"), padded(gj)]
_chunks += [block(tarfile.XHDTYPE, 0, "pax")] * 200
_chunks += [tarfile.TarInfo("m").tobuf(tarfile.GNU_FORMAT)]
shape4 = gz_archive(_chunks)

# The gate and tarfile run in a child, which reports how many members tarfile still held when the
# gate refused (a spy on the work done) and its peak working set.
PEAK_CODE = PRE + r"""
import tarfile


def peak():
    if sys.platform == 'win32':
        import ctypes
        from ctypes import wintypes

        class C(ctypes.Structure):
            _fields_ = [('cb', wintypes.DWORD), ('faults', wintypes.DWORD)] + [
                (n, ctypes.c_size_t) for n in ('peak_ws', 'ws', 'a', 'b', 'c', 'd', 'pagefile', 'peak_pagefile')]

        c = C()
        c.cb = ctypes.sizeof(C)
        k = ctypes.WinDLL('kernel32')
        k.GetCurrentProcess.restype = wintypes.HANDLE
        p = ctypes.WinDLL('psapi')
        p.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(C), wintypes.DWORD]
        p.GetProcessMemoryInfo.restype = wintypes.BOOL
        return c.peak_ws if p.GetProcessMemoryInfo(k.GetCurrentProcess(), ctypes.byref(c), c.cb) else 0
    import resource
    r = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return r if sys.platform == 'darwin' else r * 1024


gate = m.MemberGate()
refused = False
retained = 10 ** 9
try:
    # the first member's header blocks are read when the archive is opened
    with m.open_tar(tarfile, sys.argv[2], gate) as tf:
        try:
            for mem in tf:
                gate(mem)
        except m.Refused:
            refused = True
        retained = len(tf.members)
except m.Refused:
    refused = True
    retained = 0
out(refused and retained <= int(sys.argv[3]) and peak() <= int(sys.argv[4]) * 2 ** 20)
"""
run_unit("total header bound: 40 members with a 999 KB pax header each are refused after at most 20 are held, under 300 MB", PEAK_CODE, [shape1, "20", "300"], "pass")
run_unit("total header bound: one global header of 80,000 keys copied into 300 members is refused after at most 20 are held, under 300 MB", PEAK_CODE, [shape2, "20", "300"], "pass")
run_unit("total header bound: 16 global blocks of 70,000 keys each in a row are refused (by the chain cap), under 300 MB", PEAK_CODE, [shape3, "5", "300"], "pass")
run_unit("header chain: 4 global blocks (360,000 keys) and 200 chained extended blocks are refused, under 400 MB", PEAK_CODE, [shape4, "5", "400"], "pass")
for label, path in [("shape 1", shape1), ("shape 2", shape2), ("the 16 global blocks", shape3), ("the 4 global blocks and 200 chained extended blocks", shape4)]:
    dest = new_dest()
    run_case("--extract refuses " + label + " of the total header bound", "refused", ["--extract", path, dest], post=lambda dest=dest: dest_empty(dest))
    folder, out = new_out()
    run_case("--list refuses " + label + " of the total header bound", "refused", ["--list", path, out], post=lambda folder=folder: not_listed(folder))
    os.remove(path)


def chain_archive(n, size, per=4):
    """n GNU long-name blocks of `size` bytes each, `per` in a row before each real member (named m0,
    m1, ... by the last block of its row). Returns the archive's path."""
    chunks = []
    members = []
    left = n
    k = 0
    while left > 0:
        row = min(per, left)
        left -= row
        name = ("m%d" % k).encode("ascii")
        for _ in range(row):
            chunks += [block(tarfile.GNUTYPE_LONGNAME, size), name + bytes(size - len(name))]
        ti = tarfile.TarInfo("ignored")
        ti.size = 1
        chunks += [ti.tobuf(tarfile.GNU_FORMAT), b"1" + bytes(511)]
        members.append("m%d" % k)
        k += 1
    chain_archive.names = members
    return gz_archive(chunks)


dest = new_dest()
_p = chain_archive(16, 1 << 20)
run_case("--extract passes 16 chained GNU long-name blocks of 1 MiB, four to a member (16 MiB of headers, exactly the total cap)", "pass",
         ["--extract", _p, dest], post=lambda dest=dest, w=dict((n, b"1") for n in chain_archive.names): extracted_ok(dest, w))
dest = new_dest()
run_case("--extract refuses 17 chained GNU long-name blocks of 1 MiB, four to a member (one block over the total cap)", "refused",
         ["--extract", chain_archive(17, 1 << 20), dest], post=lambda dest=dest: dest_empty(dest))
folder, out = new_out()
run_case("--list refuses 40 chained GNU long-name blocks of 1 MiB", "refused", ["--list", chain_archive(40, 1 << 20), out],
         post=lambda folder=folder: not_listed(folder))

# the chain cap: header blocks in a row before one member. Zero-size extended blocks have no
# data and no dict to copy, so only the chain cap can refuse them.
for n, want in [(1, "pass"), (4, "pass"), (5, "refused"), (200, "refused")]:
    _chunks = [block(tarfile.XHDTYPE, 0, "pax")] * n + [tarfile.TarInfo("m").tobuf(tarfile.GNU_FORMAT)]
    dest = new_dest()
    run_case("header chain: %d zero-size extended blocks in a row before a member %s" % (n, "extract" if want == "pass" else "are refused"), want,
             ["--extract", gz_archive(_chunks), dest],
             post=(lambda dest=dest: extracted_ok(dest, {"m": b""})) if want == "pass" else (lambda dest=dest: dest_empty(dest)))
# a row of four, a member, and a row of four again: the member resets the count
_chunks = []
for k in range(3):
    _chunks += [block(tarfile.XHDTYPE, 0, "pax")] * 4 + [tarfile.TarInfo("m%d" % k).tobuf(tarfile.GNU_FORMAT)]
dest = new_dest()
run_case("header chain: rows of four extended blocks, each followed by a member, pass (a member resets the count)", "pass",
         ["--extract", gz_archive(_chunks), dest], post=lambda dest=dest: extracted_ok(dest, dict(("m%d" % k, b"") for k in range(3))))
# four of mixed kinds (global, extended, long name, long link) before a member pass; five do not
_gx = pax_record("comment", "c")
_mix = [block(tarfile.XGLTYPE, len(_gx), "pax"), padded(_gx), block(tarfile.XHDTYPE, len(_gx), "pax"), padded(_gx),
        block(tarfile.GNUTYPE_LONGNAME, 512), b"m" + bytes(511), block(tarfile.GNUTYPE_LONGLINK, 512), b"t" + bytes(511)]
dest = new_dest()
run_case("header chain: a global, an extended, a long-name and a long-link block before a member pass", "pass",
         ["--extract", gz_archive(_mix + [tarfile.TarInfo("ignored").tobuf(tarfile.GNU_FORMAT)]), dest],
         post=lambda dest=dest: extracted_ok(dest, {"m": b""}))
dest = new_dest()
run_case("header chain: those four and one more extended block are refused", "refused",
         ["--extract", gz_archive(_mix + [block(tarfile.XHDTYPE, 0, "pax"), tarfile.TarInfo("ignored").tobuf(tarfile.GNU_FORMAT)]), dest],
         post=lambda dest=dest: dest_empty(dest))
folder, out = new_out()
run_case("header chain: --list refuses five zero-size extended blocks in a row", "refused",
         ["--list", gz_archive([block(tarfile.XHDTYPE, 0, "pax")] * 5 + [tarfile.TarInfo("m").tobuf(tarfile.GNU_FORMAT)]), out],
         post=lambda folder=folder: not_listed(folder))


def pax_member_stream(n):
    """n members m000000.., each with a pax header of its own (an `x` block), as a stream of chunks."""
    for i in range(n):
        ti = tarfile.TarInfo("m%06d" % i)
        ti.pax_headers = {"comment": "c"}
        yield ti.tobuf(tarfile.PAX_FORMAT)


def count_lines(out):
    with open(out, "rb") as fh:
        return fh.read().count(b"\n")


# header blocks do not count against the member cap: 100,000 members, one pax header each
_at_cap = gz_archive(pax_member_stream(100000))
folder, out = new_out()
run_case("member cap: 100,000 members each with a pax header (exactly the cap) are listed", "pass", ["--list", _at_cap, out],
         post=lambda out=out: None if count_lines(out) == 100000 else "listed %d lines" % count_lines(out))
os.remove(_at_cap)
_over_cap = gz_archive(pax_member_stream(100001))
folder, out = new_out()
run_case("member cap: 100,001 members each with a pax header (one over the cap) are refused", "refused", ["--list", _over_cap, out],
         post=lambda folder=folder: not_listed(folder))
os.remove(_over_cap)

# .xz: the decoder must have a memory limit. A tiny file can name a 4 GiB dictionary.
BIG = bytes((i * 7 + i // 256) % 251 for i in range(3 * 2 ** 20))


def plain_tar(members):
    path = make_archive(members, "w", ".tar")
    with open(path, "rb") as fh:
        data = fh.read()
    os.remove(path)
    return data


def xz_file(data, ext=".tar.xz"):
    _counter[0] += 1
    path = os.path.join(WORK, "xz%04d%s" % (_counter[0], ext))
    with open(path, "wb") as fh:
        fh.write(data)
    return path


def with_dict_byte(tar_data, prop):
    """The .xz of `tar_data` with its LZMA2 dictionary-size byte set to `prop` and the block-header CRC redone."""
    x = bytearray(lzma.compress(tar_data, format=lzma.FORMAT_XZ))
    if not (x[:6] == b"\xfd7zXZ\x00" and x[12] == 2 and x[14] == 0x21 and x[15] == 1):
        raise RuntimeError("this lzma module writes a block header the harness does not know")
    x[16] = prop
    x[20:24] = struct.pack("<I", zlib.crc32(bytes(x[12:20])))
    return bytes(x)


EMPTY_TAR = plain_tar([])
GOOD_TAR = plain_tar(GOOD)
# prop N is a dictionary of (2 | N & 1) << (N // 2 + 11) bytes: 40 is 4 GiB - 1, 36 is 1 GiB, 34 is 512 MiB,
# 32 is 256 MiB (over the 256 MiB limit once the decoder's own state is added), 31 is 192 MiB (3 << 26, under it),
# 30 is 128 MiB, 22 is 8 MiB
for prop, label in [(40, "4 GiB"), (36, "1 GiB"), (34, "512 MiB"), (32, "256 MiB")]:
    path = xz_file(with_dict_byte(EMPTY_TAR, prop), ".tar.xz")
    dest = new_dest()
    run_case("--extract refuses a tiny tar.xz (%d bytes) whose dictionary is %s" % (os.path.getsize(path), label), "refused",
             ["--extract", path, dest], post=lambda dest=dest: dest_empty(dest))
    folder, out = new_out()
    run_case("--list refuses a tiny tar.xz whose dictionary is " + label, "refused", ["--list", path, out],
             post=lambda folder=folder: not_listed(folder))
for prop, label in [(31, "192 MiB"), (30, "128 MiB"), (22, "8 MiB")]:
    path = xz_file(with_dict_byte(GOOD_TAR, prop))
    dest = new_dest()
    run_case("--extract passes a tar.xz whose dictionary is " + label, "pass", ["--extract", path, dest],
             post=lambda dest=dest: extracted_ok(dest, GOOD_WANT))

alone = bytearray(lzma.compress(EMPTY_TAR, format=lzma.FORMAT_ALONE))
alone[1:5] = struct.pack("<I", 512 << 20)
dest = new_dest()
run_case("--extract refuses a legacy .lzma file with a 512 MiB dictionary", "refused", ["--extract", xz_file(bytes(alone), ".tar.lzma"), dest],
         post=lambda dest=dest: dest_empty(dest))
dest = new_dest()
run_case("--extract refuses a legacy .lzma archive (the format is not read)", "refused",
         ["--extract", xz_file(lzma.compress(GOOD_TAR, format=lzma.FORMAT_ALONE), ".tar.lzma"), dest], post=lambda dest=dest: dest_empty(dest))

_big_members = [("big.bin", "file", BIG), ("after.txt", "file", b"after")]
dest = new_dest()
run_case("--extract passes a tar.xz with a 3 MB member (skipped by seeking in the listing pass)", "pass",
         ["--extract", make_archive(_big_members, "w:xz", ".tar.xz"), dest],
         post=lambda dest=dest: extracted_ok(dest, {"big.bin": BIG, "after.txt": b"after"}))
# split after 1536 bytes: the second stream starts at the last member's header, so tarfile must read it
# (a split in the zero blocks would never be read, as tarfile stops at the first end block)
_half = 1536
dest = new_dest()
run_case("--extract passes a tar.xz of two concatenated streams", "pass",
         ["--extract", xz_file(lzma.compress(GOOD_TAR[:_half], format=lzma.FORMAT_XZ) + lzma.compress(GOOD_TAR[_half:], format=lzma.FORMAT_XZ)), dest],
         post=lambda dest=dest: extracted_ok(dest, GOOD_WANT))
_bigxz = lzma.compress(plain_tar(_big_members), format=lzma.FORMAT_XZ)
dest = new_dest()
run_case("--extract refuses a tar.xz cut in half (inside its 3 MB member)", "refused",
         ["--extract", xz_file(_bigxz[: len(_bigxz) // 2]), dest], post=lambda dest=dest: dest_empty(dest))
# GOOD_TAR is five 512-byte blocks of members, then zeros: cut the zeros so tarfile reads on past the stream's end
_no_end = GOOD_TAR[:2560]
dest = new_dest()
run_case("--extract passes a tar.xz whose tar has no end blocks (the stream ends where the tar does)", "pass",
         ["--extract", xz_file(lzma.compress(_no_end, format=lzma.FORMAT_XZ)), dest], post=lambda dest=dest: extracted_ok(dest, GOOD_WANT))
dest = new_dest()
run_case("--extract refuses a tar.xz with trailing bytes that tarfile reads (they are not a stream)", "refused",
         ["--extract", xz_file(lzma.compress(_no_end, format=lzma.FORMAT_XZ) + b"trailing"), dest], post=lambda dest=dest: dest_empty(dest))
# The NUL padding the format allows between and after streams is refused. Python's own
# LZMAFile does not read past it either: it takes the padding for trailing junk and silently stops, so a
# tar.xz padded between two streams would be read as truncated. The control shows that; refusing is safer.
_s1 = lzma.compress(GOOD_TAR[:_half], format=lzma.FORMAT_XZ)
_s2 = lzma.compress(GOOD_TAR[_half:], format=lzma.FORMAT_XZ)
_padded = xz_file(_s1 + bytes(4) + _s2)
with lzma.open(_padded, "rb") as fh:
    _control = fh.read()
NAMES.append("control: lzma.LZMAFile stops silently at NUL padding between two streams")
record("control: lzma.LZMAFile stops silently at NUL padding between two streams",
       [] if _control == GOOD_TAR[:_half] else ["it read " + str(len(_control)) + " bytes"])
dest = new_dest()
run_case("--extract refuses a tar.xz of two streams with NUL padding between them (stricter than LZMAFile, by design)", "refused",
         ["--extract", _padded, dest], post=lambda dest=dest: dest_empty(dest))
dest = new_dest()
run_case("--extract refuses a tar.xz with NUL padding after its last stream, where tarfile reads that far", "refused",
         ["--extract", xz_file(lzma.compress(_no_end, format=lzma.FORMAT_XZ) + bytes(4)), dest], post=lambda dest=dest: dest_empty(dest))
dest = new_dest()
run_case("--extract passes an empty tar.xz at the default dictionary (the control for the refused dictionaries)", "pass",
         ["--extract", xz_file(lzma.compress(EMPTY_TAR, format=lzma.FORMAT_XZ)), dest], post=lambda dest=dest: dest_empty(dest))
folder, out = new_out()
run_case("--list passes an empty tar.xz at the default dictionary", "pass", ["--list", xz_file(lzma.compress(EMPTY_TAR, format=lzma.FORMAT_XZ)), out],
         post=lambda folder=folder, out=out: listed(folder, out, b""))
dest = new_dest()
run_case("--extract refuses a tar.xz that is only its magic", "refused", ["--extract", xz_file(b"\xfd7zXZ\x00"), dest], post=lambda dest=dest: dest_empty(dest))
dest = new_dest()
run_case("--extract passes a tar whose first member's name starts BZh (the bzip2 magic)", "pass",
         ["--extract", make_archive([("BZhello.txt", "file", b"1")], "w", ".tar"), dest], post=lambda dest=dest: extracted_ok(dest, {"BZhello.txt": b"1"}))

XZ_READER_CODE = PRE + r"""
import lzma
data = bytes((i * 7 + i // 256) % 251 for i in range(3 * 2 ** 20))
path = sys.argv[2]
with open(path, 'wb') as fh:
    fh.write(lzma.compress(data, format=lzma.FORMAT_XZ))
with open(path, 'rb') as f:
    r = m.limited_xz(f)
    ok = r.read(10) == data[:10] and r.tell() == 10
    r.seek(2000000)
    ok = ok and r.read(100) == data[2000000:2000100]
    r.seek(5)
    ok = ok and r.read(20) == data[5:25]
    r.seek(100, 1)
    ok = ok and r.tell() == 125 and r.read(5) == data[125:130]
    ok = ok and r.seek(len(data) + 1000) == len(data) and r.read(10) == b''
    r.seek(0)
    ok = ok and r.read() == data
    ok = ok and r.read(5) == b''
    r.close()
out(ok)
"""
_xr = os.path.join(WORK, "xzreader.xz")
run_unit("limited_xz: reads, seeks forward and back, seeks past the end, reads to the end", XZ_READER_CODE, [_xr], "pass")

# ---- 8. arguments ------------------------------------------------------------------------------

okf = fresh("download")
ARGS = [
    ("no arguments", []),
    ("an unknown flag", ["--bogus", okf]),
    ("--staging without a folder", ["--staging"]),
    ("--check without a folder", ["--check"]),
    ("--check with two folders", ["--check", okf, okf]),
    ("--staging --check", ["--staging", "--check", okf]),
    ("a leading-dash folder", ["-x"]),
    ("two positional arguments", [okf, okf]),
    ("-h", ["-h"]),
    ("--help", ["--help"]),
    ("-- alone", ["--"]),
    ("an empty argument", [""]),
]
for label, args in ARGS:
    run_case("arguments: " + label, "refused", args)

# ---- 9. function-level cases (the parts a child cannot reach by arguments) ---------------------------

FLOOR_CODE = PRE + r"""
out(m.tar_floor_ok(tuple(int(x) for x in sys.argv[2:5]) + (sys.argv[5], 0)))
"""
FLOORS = [
    ((3, 8, 20, "final"), False), ((3, 9, 23, "final"), False), ((3, 9, 24, "final"), True), ((3, 9, 24, "candidate"), False),
    ((3, 9, 25, "final"), True), ((3, 10, 18, "final"), False), ((3, 10, 19, "final"), True), ((3, 10, 19, "beta"), False),
    ((3, 11, 13, "final"), False), ((3, 11, 14, "final"), True), ((3, 12, 11, "final"), False), ((3, 12, 12, "final"), True),
    ((3, 13, 5, "final"), False), ((3, 13, 6, "final"), True), ((3, 13, 6, "candidate"), False), ((3, 13, 7, "final"), True),
    ((3, 14, 0, "alpha"), False), ((3, 14, 0, "beta"), False), ((3, 14, 0, "candidate"), False), ((3, 14, 0, "final"), True),
    ((3, 14, 1, "final"), True), ((3, 15, 0, "final"), True), ((4, 0, 0, "final"), True),
    ((3, 15, 0, "alpha"), False), ((3, 15, 0, "beta"), False), ((3, 15, 0, "candidate"), False), ((3, 16, 0, "beta"), False),
    ((4, 0, 0, "alpha"), False), ((4, 0, 0, "candidate"), False),
    ((3, 7, 99, "final"), False), ((2, 7, 18, "final"), False),
]
for v, want in FLOORS:
    run_unit("tar floor %d.%d.%d %s" % v, FLOOR_CODE, [str(v[0]), str(v[1]), str(v[2]), v[3]], "pass" if want else "refused")

CAP_CODE = PRE + r"""
g = m.MemberGate()
mode, delta = sys.argv[2], int(sys.argv[3])
try:
    if mode == 'size':
        x = M('x')
        x.size = m.MAX_ARCHIVE_BYTES + delta
        g(x)
    elif mode == 'count':
        for i in range(m.MAX_ARCHIVE_MEMBERS + delta):
            g(M('n%d' % i))
    elif mode == 'chain':
        # header blocks in a row before one member
        for i in range(m.MAX_HEADER_CHAIN + delta):
            g.header(1)
    elif mode == 'chain-reset':
        # a row at the cap, a member, and another row at the cap
        for k in range(3):
            for i in range(m.MAX_HEADER_CHAIN):
                g.header(1)
            g(M('n%d' % k))
    elif mode == 'chain-no-reset':
        # the control: with no member between them the two rows add up
        for i in range(2 * m.MAX_HEADER_CHAIN):
            g.header(1)
    elif mode == 'headercount':
        # header blocks do not count against the member cap: one block before each of the cap's members
        for i in range(m.MAX_ARCHIVE_MEMBERS + delta):
            g.header(1)
            g(M('n%d' % i))
    elif mode == 'headersize':
        g.header(m.MAX_HEADER_BYTES + delta)
    elif mode == 'htotal':
        # sixteen blocks at the per-block cap are exactly the total cap (a member after every
        # fourth, as the chain cap allows)
        for i in range(m.MAX_HEADER_TOTAL // m.MAX_HEADER_BYTES):
            g.header(m.MAX_HEADER_BYTES)
            if i % m.MAX_HEADER_CHAIN == m.MAX_HEADER_CHAIN - 1:
                g(M('n%d' % i))
        if delta:
            g.header(delta)
    elif mode == 'names':
        # distinct 407-character names: the total-characters cap is reached before the count cap
        for i in range(delta):
            g(M('%06d/' % i + 'b' * 200 + '/' + 'c' * 200))
    ok = True
except m.Refused:
    ok = False
out(ok)
"""
run_unit("archive cap: a member exactly at the byte cap passes", CAP_CODE, ["size", "0"], "pass")
run_unit("archive cap: a member one byte over the cap is refused", CAP_CODE, ["size", "1"], "refused")
run_unit("archive cap: exactly the member-count cap passes", CAP_CODE, ["count", "0"], "pass")
run_unit("archive cap: one member over the count cap is refused", CAP_CODE, ["count", "1"], "refused")
run_unit("header cap: a header block exactly at the size cap passes", CAP_CODE, ["headersize", "0"], "pass")
run_unit("header cap: a header block one byte over the size cap is refused", CAP_CODE, ["headersize", "1"], "refused")
run_unit("header cap: a negative header size is refused", CAP_CODE, ["headersize", "-2000000"], "refused")
run_unit("header chain: exactly four blocks in a row pass", CAP_CODE, ["chain", "0"], "pass")
run_unit("header chain: a fifth block in a row is refused", CAP_CODE, ["chain", "1"], "refused")
run_unit("header chain: a row of four, a member, and another row of four, three times, pass (a member resets the count)", CAP_CODE, ["chain-reset", "0"], "pass")
run_unit("header chain: eight blocks with no member between them are refused (the control for the reset)", CAP_CODE, ["chain-no-reset", "0"], "refused")
run_unit("header count: a block before each of exactly the cap's members passes (blocks are not counted as members)", CAP_CODE, ["headercount", "0"], "pass")
run_unit("header count: one member over the cap, each after a block, is refused", CAP_CODE, ["headercount", "1"], "refused")
run_unit("header cap: header blocks totalling exactly the total cap pass", CAP_CODE, ["htotal", "0"], "pass")
run_unit("header cap: one more byte of header blocks over the total cap is refused", CAP_CODE, ["htotal", "1"], "refused")
run_unit("name cap: 50,000 long names pass", CAP_CODE, ["names", "50000"], "pass")
run_unit("name cap: 99,000 long names exceed the total-characters cap", CAP_CODE, ["names", "99000"], "refused")

GATE_CODE = PRE + r"""
g = m.MemberGate()
case = sys.argv[2]
try:
    if case == 'negative':
        x = M('a'); x.size = -1; g(x)
    elif case == 'sparse':
        x = M('a'); x.sparse = [(0, 1)]; g(x)
    elif case == 'dup':
        g(M('a/b')); g(M('a/b'))
    elif case == 'dupcase':
        g(M('a/b')); g(M('A/B'))
    elif case == 'dupdot':
        g(M('./a/b')); g(M('a//b'))
    elif case == 'dupnfc':
        g(M('caf' + chr(0xe9))); g(M('cafe' + chr(0x301)))
    elif case == 'distinct':
        g(M('a/b')); g(M('a/b2')); g(M('a'))
    elif case == 'empty':
        g(M('./'))
    elif case == 'empty-dot':
        g(M('.'))
    elif case == 'slash':
        g(M('a/'))
    elif case == 'dotted':
        g(M('x/.'))
    elif case == 'slash-dot':
        g(M('x/./'))
    ok = True
except m.Refused:
    ok = False
out(ok)
"""
run_unit("gate: a negative size is refused", GATE_CODE, ["negative"], "refused")
run_unit("gate: a sparse member is refused", GATE_CODE, ["sparse"], "refused")
run_unit("gate: a duplicate name is refused", GATE_CODE, ["dup"], "refused")
run_unit("gate: a duplicate after case folding is refused", GATE_CODE, ["dupcase"], "refused")
run_unit("gate: a duplicate after dropping ./ and // is refused", GATE_CODE, ["dupdot"], "refused")
run_unit("gate: a duplicate after NFC is refused", GATE_CODE, ["dupnfc"], "refused")
run_unit("gate: distinct names pass", GATE_CODE, ["distinct"], "pass")
run_unit("gate: a regular file with an empty name (./) is refused", GATE_CODE, ["empty"], "refused")
run_unit("gate: a regular file named . is refused", GATE_CODE, ["empty-dot"], "refused")
run_unit("gate: a regular file whose name ends in / is refused", GATE_CODE, ["slash"], "refused")
run_unit("gate: a regular file whose name ends in /. is refused", GATE_CODE, ["dotted"], "refused")
run_unit("gate: a regular file whose name ends in /./ is refused", GATE_CODE, ["slash-dot"], "refused")

# the listing pass and the extraction pass (second_look), folders, and file-against-folder conflicts
GATE2_CODE = PRE + r"""
class D(M):
    size = 0

    def isreg(self): return False
    def isdir(self): return True


case = sys.argv[2]
g = m.MemberGate(second_look=case.startswith('second'))
ok = True
try:
    if case == 'listing-folder-twice':
        g(D('d')); g(D('d'))
    elif case == 'second-file-twice':
        g(M('a')); g(M('a'))
    elif case == 'second-folder-twice':
        g(D('d')); g(D('d'))
    elif case == 'second-folder-counts-once':
        g(D('p')); g(M('p/a')); g(D('p'))
        ok = g.count == 2 and g.name_chars == len('p') + len('p/a') and g.total == 1
    elif case == 'second-folder-then-file':
        g(D('d')); g(M('d'))
    elif case == 'second-file-then-folder':
        g(M('d')); g(D('d'))
    elif case == 'second-folder-case':
        g(D('d')); g(D('D'))
    elif case == 'file-then-child':
        g(M('a')); g(M('a/b')); g.finish()
    elif case == 'child-then-file':
        g(M('a/b')); g(M('a')); g.finish()
    elif case == 'deep':
        g(M('a/b')); g(M('a/b/c/d')); g.finish()
    elif case == 'case':
        g(M('A')); g(M('a/b')); g.finish()
    elif case == 'dotted':
        g(M('./a')); g(M('a//b')); g.finish()
    elif case == 'folder-then-child':
        g(D('a')); g(M('a/b')); g.finish()
    elif case == 'child-then-folder':
        g(M('a/b')); g(D('a')); g.finish()
    elif case == 'sort-trap':
        g(D('a')); g(M('a-b')); g(M('a/b')); g.finish()
    elif case == 'sort-trap-file':
        g(M('a')); g(M('a-b')); g(M('a/b')); g.finish()
    elif case == 'near-names':
        g(M('a.b')); g(M('a')); g(M('a b')); g(M('ab/c')); g(M('a.c/c')); g.finish()
    elif case == 'many':
        for i in range(100000):
            g(M('d%d/f%d' % (i % 500, i)))
        g.finish()
    elif case == 'head-alone':
        g(M('x/HEAD')); g.finish()
    elif case == 'head-top-alone':
        g(M('HEAD')); g.finish()
    elif case == 'head-lower-alone':
        g(M('bin/head')); g(M('docs/HEAD')); g.finish()
    elif case == 'head-objects':
        g(M('x/HEAD')); g(M('x/objects')); g.finish()
    elif case == 'head-objects-first':
        g(M('x/objects')); g(M('x/HEAD')); g.finish()
    elif case == 'head-refs':
        g(M('x/HEAD')); g(D('x/refs')); g.finish()
    elif case == 'head-commondir':
        g(M('x/HEAD')); g(M('x/commondir')); g.finish()
    elif case == 'head-implied':
        g(M('x/HEAD')); g(M('x/objects/info/.keep')); g.finish()
    elif case == 'head-implied-first':
        g(M('x/refs/heads/.keep')); g(M('x/HEAD')); g.finish()
    elif case == 'head-implied-deep':
        g(M('a/b/c/objects/d/e/f')); g(M('a/b/c/HEAD')); g.finish()
    elif case == 'head-top-implied':
        g(M('HEAD')); g(M('refs/heads/x')); g.finish()
    elif case == 'head-mixed':
        g(M('x/Head')); g(M('x/Refs/a')); g.finish()
    elif case == 'head-fullwidth':
        g(M('x/' + chr(0xff28) + 'EAD')); g(M('x/commondir')); g.finish()
    elif case == 'head-fullwidth-sibling':
        g(M('x/HEAD')); g(M('x/' + chr(0xff4f) + 'bjects/a')); g.finish()
    elif case == 'head-long-s':
        g(M('x/HEAD')); g(M('x/ref' + chr(0x17f) + '/a')); g.finish()
    elif case == 'head-dotted':
        g(M('./x//HEAD')); g(M('x/./objects/a')); g.finish()
    elif case == 'head-slash':
        g(M('x/HEAD/'))
    elif case == 'head-dot':
        g(M('./HEAD')); g(M('objects/a')); g.finish()
    elif case == 'head-folder':
        g(D('x/HEAD')); g(M('x/HEAD/a')); g(M('x/objects/b')); g(M('x/refs/c')); g.finish()
    elif case == 'head-other-parent':
        g(M('x/HEAD')); g(M('y/objects/a')); g(M('refs')); g(M('x/sub/objects/a')); g(M('x/sub/commondir')); g.finish()
    elif case == 'head-near-sibling-names':
        g(M('x/HEAD')); g(M('x/objects2')); g(M('x/object')); g(M('x/ref')); g(M('x/refsx')); g(M('x/commondirs')); g(M('x/objects.d/a')); g.finish()
    elif case == 'head-near':
        g(M('x/HEADER')); g(M('x/heads')); g(M('x/HEA')); g(M('HEAD.txt')); g(M('x/HEAD d')); g(M('x/xhead')); g.finish()
    elif case == 'dir-dot-empty':
        g(D('./')); g.finish()
    elif case == 'dir-slash':
        g(D('a/')); g(M('a/b')); g.finish()
except m.Refused:
    ok = False
out(ok)
"""
for label, case, want in [
    ("the listing pass refuses a folder named twice", "listing-folder-twice", "refused"),
    ("the extraction pass refuses a file named twice", "second-file-twice", "refused"),
    ("the extraction pass lets a folder come round a second time", "second-folder-twice", "pass"),
    ("the extraction pass counts a folder's second look as nothing (member count, name characters)", "second-folder-counts-once", "pass"),
    ("the extraction pass refuses a file after a folder of that name", "second-folder-then-file", "refused"),
    ("the extraction pass refuses a folder after a file of that name", "second-file-then-folder", "refused"),
    ("the extraction pass takes a folder named again in another case as the same folder (the listing pass judged it)", "second-folder-case", "pass"),
    ("a file a, then a/b, is refused", "file-then-child", "refused"),
    ("a/b, then a file a, is refused", "child-then-file", "refused"),
    ("a file a/b, then a/b/c/d, is refused", "deep", "refused"),
    ("a file A, then a/b, is refused", "case", "refused"),
    ("a file ./a, then a//b, is refused", "dotted", "refused"),
    ("a folder a, then a/b, passes", "folder-then-child", "pass"),
    ("a/b, then a folder a, passes", "child-then-folder", "pass"),
    ("a folder a with a-b and a/b (the sort trap) passes", "sort-trap", "pass"),
    ("a file a with a-b and a/b is refused", "sort-trap-file", "refused"),
    ("files a.b, a and 'a b' with ab/c and a.c/c pass", "near-names", "pass"),
    ("100,000 names pass the conflict check", "many", "pass"),
    ("a file called HEAD with nothing beside it passes", "head-alone", "pass"),
    ("a file called HEAD at the top with nothing beside it passes", "head-top-alone", "pass"),
    ("bin/head and docs/HEAD, with nothing beside them, pass", "head-lower-alone", "pass"),
    ("a HEAD file beside a file called objects is refused", "head-objects", "refused"),
    ("an objects file, then a HEAD file (the order does not matter) is refused", "head-objects-first", "refused"),
    ("a HEAD file beside a folder called refs is refused", "head-refs", "refused"),
    ("a HEAD file beside commondir (alone) is refused", "head-commondir", "refused"),
    ("a HEAD file beside an objects implied by x/objects/info/.keep is refused", "head-implied", "refused"),
    ("a refs implied by a deeper name, then a HEAD file, is refused", "head-implied-first", "refused"),
    ("a deep HEAD file beside an implied objects is refused", "head-implied-deep", "refused"),
    ("a top-level HEAD file beside an implied refs is refused", "head-top-implied", "refused"),
    ("a file called Head beside Refs is refused", "head-mixed", "refused"),
    ("a file called HEAD with a fullwidth H beside commondir is refused", "head-fullwidth", "refused"),
    ("a HEAD file beside an objects written with a fullwidth O is refused", "head-fullwidth-sibling", "refused"),
    ("a HEAD file beside a refs written with a long s is refused", "head-long-s", "refused"),
    ("./x//HEAD beside x/./objects/a is refused", "head-dotted", "refused"),
    ("a file called HEAD/ (a trailing slash) is refused", "head-slash", "refused"),
    ("a file called ./HEAD beside objects/a is refused", "head-dot", "refused"),
    ("a folder called HEAD holding a file, beside objects and refs, passes", "head-folder", "pass"),
    ("a HEAD file whose objects, refs and commondir are in other folders passes", "head-other-parent", "pass"),
    ("a HEAD file beside names that only look like objects, refs and commondir passes", "head-near-sibling-names", "pass"),
    ("names near HEAD pass", "head-near", "pass"),
    ("a folder called ./ (the empty name) passes", "dir-dot-empty", "pass"),
    ("a folder named a/ with a/b passes", "dir-slash", "pass"),
]:
    run_unit("gate: " + label, GATE2_CODE, [case], want)

PAXCAP_CODE = PRE + r"""
case, delta = sys.argv[2], int(sys.argv[3])
g = m.MemberGate()
ok = True
try:
    x = M('x')
    if case == 'entries':
        x.pax_headers = dict((str(i), '') for i in range(m.MAX_PAX_ENTRIES + delta))
        g(x)
    elif case == 'chars':
        x.pax_headers = {'k': 'v' * (m.MAX_PAX_CHARS - 1 + delta)}
        g(x)
    elif case == 'entries-running':
        x.pax_headers = dict((str(i), '') for i in range(m.MAX_PAX_ENTRIES // 2 + delta))
        y = M('y')
        y.pax_headers = x.pax_headers
        g(x); g(y)
    elif case == 'chars-running':
        x.pax_headers = {'k': 'v' * (m.MAX_PAX_CHARS // 2 - 1 + delta)}
        y = M('y')
        y.pax_headers = x.pax_headers
        g(x); g(y)
    elif case == 'none':
        x.pax_headers = {}
        g(x)
        g(M('y'))
except m.Refused:
    ok = False
out(ok)
"""
run_unit("pax cap: exactly the entries cap in one member passes", PAXCAP_CODE, ["entries", "0"], "pass")
run_unit("pax cap: one entry over the entries cap is refused", PAXCAP_CODE, ["entries", "1"], "refused")
run_unit("pax cap: exactly the characters cap in one member passes", PAXCAP_CODE, ["chars", "0"], "pass")
run_unit("pax cap: one character over the characters cap is refused", PAXCAP_CODE, ["chars", "1"], "refused")
run_unit("pax cap: two members that together hold exactly the entries cap pass", PAXCAP_CODE, ["entries-running", "0"], "pass")
run_unit("pax cap: two members that together hold more than the entries cap are refused", PAXCAP_CODE, ["entries-running", "1"], "refused")
run_unit("pax cap: two members that together hold exactly the characters cap pass", PAXCAP_CODE, ["chars-running", "0"], "pass")
run_unit("pax cap: two members that together hold more than the characters cap are refused", PAXCAP_CODE, ["chars-running", "1"], "refused")
run_unit("pax cap: members with no pax headers pass", PAXCAP_CODE, ["none", "0"], "pass")

# mode_extract and mode_list with sys.version_info faked: the floor gate is wired in front of any reading or writing
WIRE_CODE = PRE + r"""
import tarfile
sys.version_info = tuple(int(x) for x in sys.argv[2:5]) + (sys.argv[5], 0)
try:
    getattr(m, 'mode_' + sys.argv[6])(sys.argv[7], sys.argv[8])
    ok = True
except BaseException:
    ok = False
out(ok)
"""
wire_dest = new_dest()
run_unit("--extract is gated by the floor: a Python 3.9.22 is refused", WIRE_CODE, ["3", "9", "22", "final", "extract", good, wire_dest], "refused")
NAMES.append("--extract is gated by the floor: it wrote nothing into dest")
record("--extract is gated by the floor: it wrote nothing into dest", [] if os.listdir(wire_dest) == [] else ["dest not empty"])
run_unit("--extract is gated by the floor: a Python 3.13.5 is refused", WIRE_CODE, ["3", "13", "5", "final", "extract", good, new_dest()], "refused")
run_unit("--extract is gated by the floor: a Python 3.13.6 release candidate is refused", WIRE_CODE, ["3", "13", "6", "candidate", "extract", good, new_dest()], "refused")
run_unit("--extract is gated by the floor: a Python 3.13.6 final extracts", WIRE_CODE, ["3", "13", "6", "final", "extract", good, new_dest()], "pass")
folder, out = new_out()
run_unit("--list is gated by the floor: a Python 3.13.5 is refused", WIRE_CODE, ["3", "13", "5", "final", "list", good, out], "refused")
NAMES.append("--list is gated by the floor: it wrote nothing")
record("--list is gated by the floor: it wrote nothing", [] if os.listdir(folder) == [] else ["a file was written"])
run_unit("--list is gated by the floor: a Python 3.13.6 final lists", WIRE_CODE, ["3", "13", "6", "final", "list", good, out], "pass")

# the header bound: tarfile reads a pax or long-name block whole before the gate sees a member, so the
# subclass must refuse by the declared size, before any read of it. A spy file records the biggest read
# asked of it; the same file through a plain TarInfo is the control (it does ask for the whole block).
SPY_CODE = PRE + r"""
import io, tarfile


class Spy(io.BytesIO):
    biggest = 0

    def read(self, n=-1):
        if n is not None and n > self.biggest:
            self.biggest = n
        return io.BytesIO.read(self, n)


ti = tarfile.TarInfo('x')
ti.type = {'x': tarfile.XHDTYPE, 'g': tarfile.XGLTYPE, 'L': tarfile.GNUTYPE_LONGNAME, 'K': tarfile.GNUTYPE_LONGLINK, 'X': tarfile.SOLARIS_XHDTYPE}[sys.argv[2]]
ti.size = 5 * 2 ** 30 // 2
data = ti.tobuf(tarfile.GNU_FORMAT) + bytes(1024)


def attempt(bounded):
    spy = Spy(data)
    kw = {'tarinfo': m.bounded_tarinfo(tarfile, m.MemberGate())} if bounded else {}
    try:
        with tarfile.open(fileobj=spy, mode='r:', **kw) as tf:
            for mem in tf:
                pass
    except m.Refused:
        return 'refused', spy.biggest
    except Exception:
        return 'other', spy.biggest
    return 'none', spy.biggest


r1, big1 = attempt(True)
r2, big2 = attempt(False)
out(r1 == 'refused' and big1 <= 2 * 2 ** 20 and r2 != 'refused' and big2 > 2 * 2 ** 30)
"""
for t in "xgLKX":
    run_unit("header bound: a '%s' block declaring 2.5 GiB is refused before a read of it (a plain TarInfo does read it)" % t, SPY_CODE, [t], "pass")

# A sparse map is read from the member's data, with no bound of tarfile's own: a 2 MB map must be refused
# after the header blocks alone (at most 64 KiB read), and a plain TarInfo reads all of it (the control).
SPARSE_SPY_CODE = PRE + r"""
import io, tarfile


class Spy(io.BytesIO):
    total = 0

    def read(self, n=-1):
        b = io.BytesIO.read(self, n)
        self.total += len(b)
        return b


if sys.argv[2] == 'pax10':
    ti = tarfile.TarInfo('a.txt')
    payload = b'1000000000\n' + b'1\n' * 1000000
    ti.size = len(payload)
    ti.pax_headers = {'GNU.sparse.major': '1', 'GNU.sparse.minor': '0', 'GNU.sparse.name': 'a.txt', 'GNU.sparse.realsize': '5'}
    data = ti.tobuf(tarfile.PAX_FORMAT) + payload + bytes(-len(payload) % 512) + bytes(1024)
else:
    ti = tarfile.TarInfo('a.txt')
    ti.type = tarfile.GNUTYPE_SPARSE
    ti.size = 512
    hb = bytearray(ti.tobuf(tarfile.GNU_FORMAT))
    hb[482] = 1
    hb[148:156] = b'        '
    hb[148:156] = ('%06o' % sum(hb)).encode() + b'\0 '
    ext = bytearray(512)
    ext[504] = 1
    data = bytes(hb) + bytes(ext) * 4000 + bytes(512) + bytes(1024)


def attempt(bounded):
    spy = Spy(data)
    kw = {'tarinfo': m.bounded_tarinfo(tarfile, m.MemberGate())} if bounded else {}
    try:
        with tarfile.open(fileobj=spy, mode='r:', **kw) as tf:
            for mem in tf:
                pass
    except m.Refused:
        return 'refused', spy.total
    except Exception:
        return 'other', spy.total
    return 'none', spy.total


r1, t1 = attempt(True)
r2, t2 = attempt(False)
out(r1 == 'refused' and t1 <= 65536 and t2 > 1000000)
"""
run_unit("header bound: a GNU.sparse 1.0 map is refused before it is read (a plain TarInfo reads it all)", SPARSE_SPY_CODE, ["pax10"], "pass")
run_unit("header bound: an old GNU sparse member's extension blocks are refused before they are read", SPARSE_SPY_CODE, ["old"], "pass")

HOOK_CODE = PRE + r"""
import tarfile


class FakeTarfile:
    class TarInfo:
        pass

    GNUTYPE_LONGNAME = GNUTYPE_LONGLINK = XHDTYPE = XGLTYPE = SOLARIS_XHDTYPE = b'x'


try:
    m.bounded_tarinfo(FakeTarfile if sys.argv[2] == 'fake' else tarfile, m.MemberGate())
    ok = True
except m.Refused:
    ok = False
out(ok)
"""
run_unit("header bound: a tarfile without the TarInfo hooks is refused (fails closed)", HOOK_CODE, ["fake"], "refused")
run_unit("header bound: this tarfile has the TarInfo hooks", HOOK_CODE, ["real"], "pass")

# a tarfile missing exactly one hook is refused, for each of the five: dropping a name from
# TARINFO_HOOKS leaves its case passing, which this list catches
ONE_HOOK_CODE = PRE + r"""
HOOKS = ['_proc_member', '_proc_sparse', '_proc_gnusparse_00', '_proc_gnusparse_01', '_proc_gnusparse_10']
missing = sys.argv[2]


class T:
    pass


for h in HOOKS:
    if h != missing:
        setattr(T, h, lambda self, *a: None)


class FakeTarfile:
    TarInfo = T
    GNUTYPE_LONGNAME = GNUTYPE_LONGLINK = XHDTYPE = XGLTYPE = SOLARIS_XHDTYPE = b'x'


try:
    m.bounded_tarinfo(FakeTarfile, m.MemberGate())
    ok = True
except m.Refused:
    ok = False
out(ok)
"""
for h in ["_proc_member", "_proc_sparse", "_proc_gnusparse_00", "_proc_gnusparse_01", "_proc_gnusparse_10"]:
    run_unit("header bound: a tarfile missing only " + h + " is refused", ONE_HOOK_CODE, [h], "refused")
run_unit("header bound: a tarfile with all five hooks and nothing else is accepted", ONE_HOOK_CODE, ["none"], "pass")

# An extended block copies the global pax dict (and a chain of them keeps one copy per level): the subclass
# charges each x or X block the entries it copies, before tarfile makes the copy. A fake tarfile whose
# global dict only reports a length, so the charge is seen without building a million entries.
CHARGE_CODE = PRE + r"""
class T:
    def _proc_member(self, tf):
        return 'inner'

    _proc_sparse = _proc_gnusparse_00 = _proc_gnusparse_01 = _proc_gnusparse_10 = _proc_member


class FakeTarfile:
    TarInfo = T
    GNUTYPE_LONGNAME = b'L'
    GNUTYPE_LONGLINK = b'K'
    XHDTYPE = b'x'
    XGLTYPE = b'g'
    SOLARIS_XHDTYPE = b'X'


class Big(dict):
    def __len__(self):
        return int(sys.argv[3])


class Tf:
    pax_headers = Big()


g = m.MemberGate()
cls = m.bounded_tarinfo(FakeTarfile, g)
ti = cls()
ti.type = sys.argv[2].encode()
ti.size = 0
ok = True
try:
    for i in range(int(sys.argv[4])):
        ti._proc_member(Tf())
    ok = g.pax_entries == (0 if sys.argv[2] in 'gLK' else int(sys.argv[3]) * int(sys.argv[4]))
except m.Refused:
    ok = False
out(ok)
"""
_E = 1024 * 1024
for kind, label, plural in [("x", "an extended block", "extended blocks"), ("X", "a Solaris extended block", "Solaris extended blocks")]:
    run_unit("header charge: %s that copies exactly the entries cap passes" % label, CHARGE_CODE, [kind, str(_E), "1"], "pass")
    run_unit("header charge: %s that copies one entry over the entries cap is refused" % label, CHARGE_CODE, [kind, str(_E + 1), "1"], "refused")
    run_unit("header charge: two %s that together copy exactly the entries cap pass" % plural, CHARGE_CODE, [kind, str(_E // 2), "2"], "pass")
    run_unit("header charge: two %s that together copy one entry over the entries cap are refused" % plural, CHARGE_CODE, [kind, str(_E // 2 + 1), "2"], "refused")
for kind, label in [("g", "a global block"), ("L", "a long-name block"), ("K", "a long-link block")]:
    run_unit("header charge: %s copies nothing, so three of them beside a 10 million entry dict pass" % label, CHARGE_CODE, [kind, "10000000", "3"], "pass")

# The sparse overrides refuse by themselves; the gate's own sparse check would refuse the same member
# later, so the member is read here with no gate call at all: a plain TarInfo reads it, BoundedTarInfo raises.
SPARSE_HOOK_CODE = PRE + r"""
import io, tarfile
ti = tarfile.TarInfo('a.txt')
ti.size = 5
if sys.argv[2] == '00':
    ti.pax_headers = {'GNU.sparse.size': '5', 'GNU.sparse.offset': '0', 'GNU.sparse.numbytes': '5'}
else:
    ti.pax_headers = {'GNU.sparse.map': '0,5'}
w = io.BytesIO()
with tarfile.open(fileobj=w, mode='w', format=tarfile.PAX_FORMAT) as tf:
    tf.addfile(ti, io.BytesIO(b'hello'))


def read(bounded):
    kw = {'tarinfo': m.bounded_tarinfo(tarfile, m.MemberGate())} if bounded else {}
    try:
        with tarfile.open(fileobj=io.BytesIO(w.getvalue()), mode='r:', **kw) as tf:
            for mem in tf:
                pass
    except m.Refused:
        return 'refused'
    except Exception:
        return 'other'
    return 'read'


out(read(True) == 'refused' and read(False) == 'read')
"""
run_unit("header bound: a GNU.sparse 0.0 member is refused by the subclass itself (a plain TarInfo reads it)", SPARSE_HOOK_CODE, ["00"], "pass")
run_unit("header bound: a GNU.sparse 0.1 member is refused by the subclass itself (a plain TarInfo reads it)", SPARSE_HOOK_CODE, ["01"], "pass")

# the field-level device check is defence in depth: with the name patterns loosened it still holds
FIELD_CODE = PRE + r"""
m.RULES['name'] = ('any', [(r'^.*$', 0)], [])
try:
    m.check_field('name', sys.argv[2])
    ok = True
except m.Refused:
    ok = False
out(ok)
"""
for v, want in [("CONIN$", "refused"), ("nul .txt", "refused"), ("COM0", "refused"), ("lpt0.x", "refused"), ("COM\N{SUPERSCRIPT ONE}", "refused"), ("console", "pass"), ("x$", "pass")]:
    run_unit("check_field keeps the device list when the name patterns are loosened: " + ascii(v), FIELD_CODE, [v], want)

# each pass of --extract counts a name once: the folder arriving a second time is not counted
COUNT_CODE = PRE + r"""
gates = []
orig = m.MemberGate


class G(orig):
    def __init__(self, *a, **k):
        orig.__init__(self, *a, **k)
        gates.append(self)


m.MemberGate = G
m.mode_extract(sys.argv[2], sys.argv[3])
g2 = gates[-1]
out(len(gates) == 2 and g2.second_look and g2.count == 3 and g2.name_chars == len('pkg') + len('pkg/hello.txt') + len('pkg/sub/deep.txt'))
"""
run_unit("--extract counts every member of the extraction pass once (a folder's second look is not counted)", COUNT_CODE, [good, new_dest()], "pass")

# the same with a pax header on every member, a folder included: the two passes must count
# the header blocks and the retained headers alike, so gate2.header is checked against the listing pass
COUNT_PAX_CODE = PRE + r"""
gates = []
orig = m.MemberGate


class G(orig):
    def __init__(self, *a, **k):
        orig.__init__(self, *a, **k)
        gates.append(self)


m.MemberGate = G
m.mode_extract(sys.argv[2], sys.argv[3])
g1, g2 = gates
fields = ('count', 'total', 'name_chars', 'header_bytes', 'pax_entries', 'pax_chars')
same = all(getattr(g1, f) == getattr(g2, f) for f in fields)
out(len(gates) == 2 and same and g1.count == 3 and g2.header_bytes > 0 and g2.pax_entries == 1 + 1 + 2 and g2.pax_chars > 0)
"""
_paxcount = make_archive([("pkg", "paxdir", {"comment": "c"}), ("pkg/a.txt", "paxfile", (b"a", {"comment": "cc"})),
                          ("pkg/b.txt", "paxfile", (b"b", {"comment": "ccc", "x": "y"}))])
run_unit("--extract counts header blocks and retained pax headers alike in both passes (a pax header on every member)", COUNT_PAX_CODE, [_paxcount, new_dest()], "pass")

# --extract has no use for the listing lines, so it does not build them (escape_name is never called)
NOLINES_CODE = PRE + r"""
def boom(name):
    raise RuntimeError('a listing line was built')


m.escape_name = boom
if sys.argv[2] == 'extract':
    m.mode_extract(sys.argv[3], sys.argv[4])
else:
    try:
        m.mode_list(sys.argv[3], sys.argv[4])
    except RuntimeError:
        out(True)
    out(False)
out(True)
"""
run_unit("--extract builds no listing lines", NOLINES_CODE, ["extract", good, new_dest()], "pass")
folder, out = new_out()
run_unit("--list does build its listing lines (the control for the case above)", NOLINES_CODE, ["list", good, out], "pass")

ESC_CODE = PRE + r"""
bs = chr(92)
name = 'a' + bs + 'b' + chr(1) + chr(127) + chr(0x85) + chr(0xe9) + chr(0x202e) + chr(0x1f600) + chr(0xd800) + chr(10) + 'z'
want = 'a' + bs + bs + 'b' + bs + 'x01' + bs + 'x7f' + bs + 'x85' + bs + 'xe9' + bs + 'u202e' + bs + 'U0001f600' + bs + 'ud800' + bs + 'x0a' + 'z'
got = m.escape_name(name)
out(got == want and all(32 <= ord(c) <= 126 for c in got))
"""
run_unit("--list escape: backslash, controls, C1, format, astral and surrogate characters all become ASCII", ESC_CODE, [], "pass")

# component_ok, at function level, so no real device name is ever written
COMP_CODE = PRE + r"""
import ast
out(m.component_ok(ast.literal_eval(sys.argv[2])))
"""
COMP_REFUSED = [
    "nul", "NUL", "NuL.txt", "nul .txt", "con .txt", "NUL .tar.gz", "prn.log", "aux ", "CONIN$", "conin$.txt", "CONOUT$",
    "conout$.txt", "COM1", "com9.log", "LPT1.txt", "lpt9 .x", "COM0", "com0.txt", "LPT0", "lpt0 .x",
    "COM\N{SUPERSCRIPT ONE}", "com\N{SUPERSCRIPT TWO}.txt", "LPT\N{SUPERSCRIPT THREE}", "lpt\N{SUPERSCRIPT ONE} .x",
    "a<b", "a>b", 'a"b', "a|b", "a?b", "a*b", "a:b", "a/b", "a\\b",
    "x" * 256, "\x85", "a\x85b", "a\x01b", "a\x7fb",
    "a\N{RIGHT-TO-LEFT OVERRIDE}b", "a\N{ZERO WIDTH JOINER}b", "a\N{ZERO WIDTH NO-BREAK SPACE}b", "\N{SOFT HYPHEN}x",
    "\N{FULLWIDTH FULL STOP}\N{FULLWIDTH FULL STOP}", "a\N{FULLWIDTH REVERSE SOLIDUS}b", "a\N{FULLWIDTH SOLIDUS}b",
    "a\N{FULLWIDTH COLON}b", "a\N{ONE DOT LEADER}", "\N{TWO DOT LEADER}", "a" + chr(0xD800) + "b",
    ".git", ".GIT", ".Git", ".g\N{ZERO WIDTH JOINER}it", "\N{FULLWIDTH FULL STOP}git", "GIT~1", "git~12",
    "\N{FULLWIDTH LATIN CAPITAL LETTER G}IT~1", "a ", "a.", "..", "...", " ",
    _EMO * 128, "x" + _EMO * 127 + "y", _SAL * 15,  # 256, 256 and 270 UTF-16 units (the last in NFKC form)
]
COMP_PASSED = [
    "x" * 255, "a b", "COM10", "LPT10", "console", "comx", "nulx", "con1", "a.com1", "git", "gitx~1", ".gitignore", ".github",
    "x...y", "a.b", "caf\N{LATIN SMALL LETTER E WITH ACUTE}", "\N{EURO SIGN}", "~git", "\N{GRINNING FACE}",
    _EMO * 127 + "x", _SAL * 14,  # 255 UTF-16 units, and 252 in NFKC form
]
for c in COMP_REFUSED:
    run_unit("component_ok refuses " + ascii(c if len(c) < 40 else c[:20] + "..." + str(len(c))), COMP_CODE, [ascii(c)], "refused")
for c in COMP_PASSED:
    run_unit("component_ok passes " + ascii(c if len(c) < 40 else c[:20] + "..." + str(len(c))), COMP_CODE, [ascii(c)], "pass")

LINK_CODE = (
    "import importlib.util,stat,sys\n"
    "s=importlib.util.spec_from_file_location('ic',sys.argv[1])\n"
    "m=importlib.util.module_from_spec(s)\n"
    "s.loader.exec_module(m)\n"
    "class St:\n"
    "    pass\n"
    "st=St()\n"
    "st.st_mode=int(sys.argv[2])\n"
    "if sys.argv[3]!='-':\n"
    "    st.st_file_attributes=int(sys.argv[3])\n"
    "ok=m.is_link(st)\n"
    "sys.stdout.buffer.write(b'intake-check: pass\\n' if ok else b'intake-check: refused\\n')\n"
    "sys.exit(0 if ok else 1)\n"
)
run_unit("is_link: a symlink mode", LINK_CODE, [str(stat.S_IFLNK | 0o777), "-"], "pass")
run_unit("is_link: a reparse-point attribute (junction)", LINK_CODE, [str(stat.S_IFDIR | 0o777), "1040"], "pass")
run_unit("is_link: a plain file", LINK_CODE, [str(stat.S_IFREG | 0o644), "-"], "refused")
run_unit("is_link: a plain folder with attributes", LINK_CODE, [str(stat.S_IFDIR | 0o777), "16"], "refused")

PLAIN_CODE = PRE + r"""
import stat


class St:
    pass


st = St()
st.st_mode = stat.S_IFREG | 0o644
st.st_nlink = int(sys.argv[2])
if sys.argv[3] != '-':
    st.st_file_attributes = int(sys.argv[3])
try:
    m.check_plain_file(st)
    ok = True
except m.Refused:
    ok = False
out(ok)
"""
run_unit("check_plain_file: a regular file with one link passes", PLAIN_CODE, ["1", "32"], "pass")
run_unit("check_plain_file: a regular-mode stat with the reparse-point bit is refused (is_link is called)", PLAIN_CODE, ["1", "1056"], "refused")
run_unit("check_plain_file: a link count of 2 is refused", PLAIN_CODE, ["2", "-"], "refused")

# ---- coverage: every hostile input the checker is meant to refuse must have a case ------------------

REQUIRED = [
    "'https://example.com/a/../b'", "'https://example.com/./b'", "'https://example.com/a/..'",
    "'a..b'", "'abc.'", "'CON'", "'con.txt'", "'lpt9'", "'Com1.tar.gz'",
    "two lines", "a CR", "a BOM", "a NUL",
    "'https://user@example.com/'", "%2e%2e", "'https://example.com\\\\a'", "'https://example.com/a?x=1'", "'https://example.com/a#f'",
    "'https://127.0.0.1/'", "'https://2130706433/'", "'https://0x7f.1/'", "'https://[::1]/'",
    "'https://localhost/'", "'https://foo.localhost:1/'", "'https://example.com.'", "'https://a..com'",
    "'scope@@@name'", "'@@name'", "'scope@@'", "'a@@b@@c'", "pypi name 'a@@b'",
    "folder: an extra file", "folder: a link where a field file should be", "folder: the field folder itself is a link or junction",
    "--check refuses a changed",
    "crate name 'a'", "crate name 'ab'", "crate name 'abc'", "crate name 'a+b'", "crate name 'abcd'",
    "crate name 'ab.c'", "crate name 'a.bc'", "crate name 'A_B-c'", "crate name '_ab'", "crate name 'a-b'", "crate name 'serde'",
    "scope@@name with an npm: id passes",
    "real source https://github.com/psf/requests.git", "real source https://pypi.org/simple/",
    "real source https://registry.npmjs.org", "real source https://files.example.com:8443/a/b.tar.gz",
    "real source https://index.crates.io",
    "a vers miss", "a cksum miss", "a duplicate vers", "yanked passes as yanked", "malformed JSON",
    "a '..' member", "an absolute path", "a symlink", ".git/config", "a trailing dot", "a reserved name", "refuses a zip",
    "oversize archive", "2 GiB + 1", "one byte over the cap", "gated by the floor", "tar floor 3.13.6 final",
    "id 'pypi:1.zip@", "id 'npm:1.0.0-a.tgz@", "name 'fields.x'",
    # names, versions and sources
    "name '../x'", "name 'a/../b'", "name '..'", "name '.git'", "name 'a.'", "name 'a '", "name 'nul.'", "name 'conin$'", "name 'git~1'",
    "npm name 'scope@@name.'", "npm name 'scope@@..'", "name raw b'a\\x00/x'", "name 'A_b+c.d-e'", "npm name 'a.@@b'",
    "npm id 'npm:1.3.x@", "npm id 'npm:~1.2.3@", "npm id 'npm:v1.0.0@", "npm id 'npm:1.0.0 || 2@", "npm id 'npm:1.0.0-rc.1+b.5@",
    "pypi id 'pypi:A_b+c.d-e@", "pypi id 'pypi:1.0.0-rc.1+b.5@",
    "source 'https://127.0.0.1:1?.legit.example/pkg'", "source 'https://%31%32%37.0.0.1:1/'",
    "source 'https://github.com@evil.example/x'", "source 'https://example.com/.well-known/x'", "source 'https://example.com/.../b'",
    # more name shapes
    "a backslash in a name", "a drive letter", "a colon in a name", "refuses GIT~1", "a trailing space", "a hard link",
    "zero-width joiner", "a field file with link count 2",
    # pip's other archive extensions
    "id 'pypi:1.tbz@", "id 'pypi:1.txz@", "id 'pypi:1.tlz@", "id 'pypi:1.0.tar.lz@", "id 'pypi:1.0.tar.lzma@", "id 'pypi:1.0.TBZ@",
    "id 'npm:1.0.0-a.tbz@", "id 'crate:1.0.0-a.txz@",
    # the digest file, crate index lines and duplicate keys
    "name in other case is refused", "the Kelvin sign does not fold to k", "a line with no name", "a line with no yanked",
    "invalid UTF-8", "a duplicate cksum key", "a duplicate vers key", "a duplicate yanked key", "a duplicate name key", "inside a nested object",
    "(the digest file binds all five) a changed, still valid source", "(the digest file binds all five) a changed, still valid purpose",
    "(the digest file binds all five) a changed, still valid kind", "(the digest file binds all five) a trailing LF added to purpose",
    "a forged digest file", "--check refuses a changed digest", "--check refuses a missing digest",
    # header blocks
    "a GNU long-name block declaring 1 GiB", "a GNU long-link block declaring 1 GiB", "a pax block declaring 1 GiB",
    "a global pax block declaring 1 GiB", "a Solaris pax block declaring 1 GiB", "a pax block declaring 2.5 GiB",
    "a GNU long-name block declaring 2.5 GiB", "just over the header cap", "a pax block with a negative size",
    "a regular member with a negative size", "an old GNU sparse member", "a GNU.sparse 1.0 pax header",
    "a GNU.sparse 0.0 pax header", "a GNU.sparse 0.1 pax header", "an ordinary GNU long-name block", "an ordinary pax header",
    "a pax header of about 900 KB", "a pax header of about 1.2 MB",
    "header cap: a header block exactly at the size cap passes", "header cap: a header block one byte over",
    "name cap: 99,000", "header bound: a 'x' block", "header bound: a 'L' block",
    "a tarfile without the TarInfo hooks", "header bound: a GNU.sparse 1.0 map", "header bound: an old GNU sparse member's extension", "gate: a negative size", "gate: a sparse member", "gate: a duplicate name",
    "two names that differ only in case", "two names equal after NFC", "a character device", "a block device", "a FIFO",
    "starts PK (PKG-INFO)", "an empty zip",
    # names the file system or the API reads differently
    "a '<' in a name", "a '>' in a name", "a double quote in a name", "a '|' in a name", "a '?' in a name", "a '*' in a name",
    "a 256-character component", "a C1 control", "a right-to-left override", "a soft hyphen", "fullwidth dots",
    "a fullwidth backslash", "a fullwidth solidus", "a fullwidth colon", "a one-dot leader", "a fullwidth .git", "a fullwidth GIT~1",
    "component_ok refuses 'nul .txt'", "component_ok refuses 'CONIN$'", "component_ok refuses 'conout$.txt'",
    "component_ok refuses 'COM\\xb9'", "component_ok refuses 'LPT\\xb3'", "component_ok refuses 'COM0'", "component_ok refuses 'LPT0'",
    "component_ok refuses 'lpt0 .x'", "component_ok passes 'COM10'", "component_ok passes 'a.com1'",
    # --list
    "--list: a good tar.gz is listed", "--list: names are written escaped", "--list: an existing output file", "--list refuses a symlink",
    "--list refuses a '..' member", "--list: refuses a zip", "--list is gated by the floor", "--list escape", "--list extracts nothing",
    # is_link is wired into check_plain_file
    "check_plain_file: a regular-mode stat with the reparse-point bit",
    "tar floor 3.15.0 final", "tar floor 3.15.0 alpha", "tar floor 3.15.0 beta", "tar floor 3.15.0 candidate", "tar floor 4.0.0 alpha",
    "--staging refuses a dependency: pypi profile", "--staging refuses a dependency: npm profile", "--staging refuses a dependency: crate profile",
    "tar floor 3.14.0 final", "tar floor 3.14.0 beta", "tar floor 3.13.5 final", "tar floor 3.13.6 candidate",
    # the total header bound
    "header cap: header blocks totalling exactly the total cap pass", "header cap: one more byte of header blocks over the total cap",
    "total header bound: 40 members", "total header bound: one global header of 80,000 keys", "total header bound: 16 global blocks",
    "--extract refuses shape 1 of the total header bound", "--list refuses shape 2 of the total header bound",
    "--extract passes 16 chained GNU long-name blocks", "--extract refuses 17 chained GNU long-name blocks", "--list refuses 40 chained",
    "pax cap: exactly the entries cap in one member passes", "pax cap: one entry over the entries cap",
    "pax cap: exactly the characters cap in one member passes", "pax cap: one character over the characters cap",
    "pax cap: two members that together hold exactly the entries cap", "pax cap: two members that together hold more than the entries cap",
    "pax cap: two members that together hold exactly the characters cap", "pax cap: two members that together hold more than the characters cap",
    # .xz memory
    "whose dictionary is 4 GiB", "whose dictionary is 1 GiB", "whose dictionary is 512 MiB", "whose dictionary is 256 MiB",
    "tar.xz whose dictionary is 192 MiB", "tar.xz whose dictionary is 128 MiB", "tar.xz whose dictionary is 8 MiB", "a legacy .lzma file with a 512 MiB dictionary",
    "a legacy .lzma archive", "a tar.xz with a 3 MB member", "two concatenated streams", "a tar.xz cut in half", "a tar.xz whose tar has no end blocks",
    "a tar.xz with trailing bytes that tarfile reads",
    "a tar.xz that is only its magic", "starts BZh", "limited_xz: reads, seeks forward and back",
    # bare-repository shapes
    "a bare-repository-shaped folder (x/HEAD)", "a bare-repository-shaped folder (x/Head)", "a file called HEAD with a fullwidth letter",
    "a file called HEAD at the top, beside files objects and refs", "gate: names near HEAD pass", "HEAD as a folder, near names",
    # the narrow HEAD rule (conditions a, b, c) and what it must let through
    "a bare-repository-shaped folder, the HEAD last", "a HEAD with only commondir beside it", "a HEAD beside empty files named objects and refs",
    "beside an objects implied by a deeper name", "a HEAD beside a refs implied by a deeper name", "a HEAD beside a commondir implied by a deeper name",
    "a head in lower case beside OBJECTS", "a sibling written with a fullwidth O", "a sibling written with a long s", "a fullwidth HEAD beside a fullwidth sibling",
    "a deeper HEAD beside its objects",
    "gate: a file called HEAD with nothing beside it passes", "gate: bin/head and docs/HEAD", "gate: a HEAD file beside a file called objects is refused",
    "gate: an objects file, then a HEAD file", "gate: a HEAD file beside a folder called refs", "gate: a HEAD file beside commondir (alone)",
    "gate: a HEAD file beside an objects implied", "gate: a refs implied by a deeper name, then a HEAD file", "gate: a deep HEAD file beside an implied objects",
    "gate: a top-level HEAD file beside an implied refs", "gate: a file called Head beside Refs", "gate: a file called HEAD with a fullwidth H beside commondir",
    "gate: a HEAD file beside an objects written with a fullwidth O", "gate: a HEAD file beside a refs written with a long s", "gate: ./x//HEAD beside x/./objects/a",
    "gate: a file called HEAD/ (a trailing slash)", "gate: a file called ./HEAD beside objects/a",
    "gate: a folder called HEAD holding a file, beside objects and refs, passes", "gate: a HEAD file whose objects, refs and commondir are in other folders",
    "gate: a HEAD file beside names that only look like", "gate: a folder called ./ (the empty name) passes", "gate: a folder named a/ with a/b passes",
    "--extract passes a head or HEAD file with no objects, refs or commondir beside it", "--extract passes a folder called HEAD beside objects and refs",
    # the chain cap, the entries charge, and header blocks that are not members
    "header chain: exactly four blocks in a row pass", "header chain: a fifth block in a row is refused", "header chain: a row of four, a member, and another row",
    "header chain: eight blocks with no member between them", "header count: a block before each of exactly the cap's members passes",
    "header count: one member over the cap, each after a block", "header chain: 1 zero-size extended blocks", "header chain: 4 zero-size extended blocks",
    "header chain: 5 zero-size extended blocks", "header chain: 200 zero-size extended blocks", "header chain: rows of four extended blocks",
    "header chain: a global, an extended, a long-name and a long-link block before a member pass", "header chain: those four and one more extended block",
    "header chain: --list refuses five zero-size", "header chain: 4 global blocks (360,000 keys) and 200 chained extended blocks",
    "--extract refuses the 4 global blocks and 200 chained extended blocks", "--list refuses the 4 global blocks and 200 chained extended blocks",
    "member cap: 100,000 members each with a pax header (exactly the cap) are listed", "member cap: 100,001 members each with a pax header",
    "header charge: an extended block that copies exactly the entries cap passes", "header charge: an extended block that copies one entry over",
    "header charge: a Solaris extended block that copies exactly the entries cap passes", "header charge: a Solaris extended block that copies one entry over",
    "header charge: two extended blocks that together copy exactly the entries cap pass", "header charge: two extended blocks that together copy one entry over",
    "header charge: a global block copies nothing", "header charge: a long-name block copies nothing", "header charge: a long-link block copies nothing",
    "--extract counts header blocks and retained pax headers alike in both passes",
    # regular files with an empty or dotted name
    "gate: a regular file with an empty name (./) is refused", "gate: a regular file named . is refused", "gate: a regular file whose name ends in / is refused",
    "gate: a regular file whose name ends in /. is refused", "gate: a regular file whose name ends in /./ is refused",
    "a regular file with an empty name (./)", "a regular file named x/.", "a regular file named a/ (a trailing slash)",
    # limited_xz is strict about NUL padding, and an empty tar.xz passes
    "control: lzma.LZMAFile stops silently at NUL padding", "two streams with NUL padding between them", "NUL padding after its last stream",
    "--extract passes an empty tar.xz at the default dictionary", "--list passes an empty tar.xz at the default dictionary",
    # the tree mode
    "--tree passes a clean tree, skipping the top-level .git folder", "--tree passes a tree with no .git folder", "--tree passes an empty folder",
    "--tree passes empty folders and one file", "--tree passes names with non-ASCII letters",
    "--tree refuses a committed bare-repository shape at the top", "--tree refuses a committed bare-repository shape in a subfolder",
    "--tree refuses a HEAD beside an empty folder objects", "--tree refuses a HEAD beside a file called refs", "--tree refuses a HEAD with only commondir",
    "--tree refuses a head in lower case beside OBJECTS", "--tree refuses a HEAD beside a sibling written with a fullwidth O",
    "--tree refuses a nested .git folder", "--tree refuses a nested .git file", "--tree refuses a top-level .git that is a file",
    "--tree refuses a top-level .GIT folder", "--tree refuses a nested .Git folder", "--tree refuses a folder called git~1",
    "--tree refuses a zero-width joiner", "--tree refuses a soft hyphen", "--tree refuses two names equal after NFC",
    "--tree refuses a junction or link to a folder", "--tree refuses a top-level .git that is a junction or link",
    "--tree refuses a junction or link nested in a folder", "--tree refuses a folder argument that is itself a junction or link",
    "--tree refuses a file as its argument", "--tree refuses a folder that does not exist", "--tree with no argument is refused",
    "--tree with two arguments is refused",
    # link counts, the tree's own caps, links that could not be made
    "refuses a regular file that is a hard link to a file outside the folder", "passes the same folder once the other name is gone",
    "refuses two names for one file inside the folder", "refuses a hard link nested in a folder",
    "tree cap wiring: a tree of exactly the entries cap passes", "tree cap wiring: one entry over the entries cap is refused",
    "tree cap wiring: a folder counts as an entry", "tree cap wiring: two files and two folders are over 3",
    "tree cap wiring: the top-level .git folder's contents are not counted", "tree cap wiring: name characters exactly at the cap pass",
    "tree cap wiring: one name character over the cap is refused",
    "tree cap: the entries cap is 500,000", "tree cap: exactly 500,000 entries pass", "tree cap: 500,001 entries are refused",
    "tree cap: name characters exactly at 64 Mi pass", "tree cap: one name character over 64 Mi is refused", "tree cap: an archive gate still stops at 100,001",
    # device names, UTF-16 lengths, the file/folder conflict, and the two passes' counts
    "component_ok refuses 'COM0'", "component_ok refuses 'LPT0'", "component_ok refuses 'lpt0 .x'", "component_ok passes 'COM10'",
    "128 astral characters", "270 characters long in NFKC", "exactly 255 UTF-16 units", "252 long in NFKC",
    "a file a, then a/b, is refused", "a/b, then a file a, is refused", "a file a/b, then a/b/c/d", "a file A, then a/b", "the sort trap",
    "the listing pass refuses a folder named twice", "the extraction pass refuses a file named twice", "the extraction pass lets a folder come round",
    "counts a folder's second look as nothing", "counts every member of the extraction pass once",
    "header bound: a 'X' block", "a tarfile missing only _proc_member", "a tarfile missing only _proc_sparse",
    "a tarfile missing only _proc_gnusparse_00", "a tarfile missing only _proc_gnusparse_01", "a tarfile missing only _proc_gnusparse_10",
    "a GNU.sparse 0.0 member is refused by the subclass itself", "a GNU.sparse 0.1 member is refused by the subclass itself",
    "check_field keeps the device list when the name patterns are loosened: 'CONIN$'",
    "--extract builds no listing lines", "--list does build its listing lines",
    # --names (before the checkout, on a pipe), the checkout's attribute source, autocrlf and hooks, and the live-git flow
    "--names passes git's own output", "--names passes an empty listing", "--names passes a gitlink alone",
    "--names passes a gitlink called HEAD beside an objects folder",
    "--names refuses a committed bare-repository shape in a subfolder", "--names refuses a committed bare-repository shape at the top",
    "--names refuses a HEAD whose objects sibling is only implied", "--names refuses a top-level .git folder", "--names refuses a nested .git folder",
    "--names refuses a last record with no NUL", "--names refuses a path that is not UTF-8", "--names refuses two names equal after NFC",
    "--names refuses a file a and a/b", "--names refuses a trailing dot", "--names refuses a device name", "--names refuses a newline",
    "--names a record of exactly 64 KiB passes", "--names a record one byte over 64 KiB is refused", "--names a record of 80 KB",
    "--names passes one blob of exactly 2 GiB", "--names refuses one blob of 2 GiB + 1 byte", "--names refuses 2 GiB and then one more byte",
    "--names passes 2,048 names for one 1 MiB blob", "--names refuses 2,049 names for one 1 MiB blob",
    "the many-bytes shape", "--names passes exactly 500,000 entries", "--names refuses 500,001 entries",
    "--names refuses 500,001 folders and no file", "--names passes exactly 500,000 folders and no file",
    "names wiring: exactly the entries cap passes", "names wiring: one entry over the entries cap is refused",
    "names wiring: a folder counts as an entry", "names wiring: a gitlink counts as an entry",
    "names wiring: name characters exactly at the cap pass", "names wiring: one name character over the cap is refused",
    "names wiring: blob bytes exactly at the cap pass", "names wiring: one byte over the byte cap is refused",
    "names wiring: the byte cap is the archive gate's 2 GiB",
    "names reading: a 5 MiB listing with no NUL is refused after its first 1 MiB", "names reading: 20,000 good records are read to their end",
    "--names refuses a blob of size b'0000000000000001'",
    "names wiring: the many-folders shape", "names wiring: the same many-folders shape passes at a 51,000 cap",
    "names wiring: a listing of exactly the stream cap passes", "names wiring: a listing one byte over the stream cap is refused",
    "names wiring: a multi-chunk listing", "names wiring: the stream cap is 320 MiB",
    "--names refuses a file path in the place of `-`", "--names refuses a folder in the place of `-`",
    "--names refuses a path that does not exist in the place of `-`", "--names with no argument is refused",
    "--names - with a third argument is refused", "--names - passes the same good listing on standard input",
    "--names: an endless stream of clean unique records", "--names: an endless stream with no NUL", "--names: an endless stream of empty records",
    "--names: a finite stream of 5,200 records padded to 65,000 bytes",
    "live git: the clone line, with -c core.hooksPath and --template=, runs no reference-transaction hook from the global template directory",
    "live git: the control, the same clone without them, runs the template's reference-transaction hook",
    "live git: the clone line, with -c core.hooksPath and --template=, runs no reference-transaction hook from the global core.hooksPath",
    "live git: the control, the same clone without them, runs the reference-transaction hook from the global core.hooksPath",
    "live git: the control under the system config",
    "live git: with core.autocrlf=true in the global config", "live git: the control, the same config and no -c core.autocrlf=false",
    "live git: with this machine's system config on", "live git: a post-checkout hook copied in", "live git: the control, the same checkout without -c core.hooksPath",
    "live git: a blob-mode entry whose object is a tree", "live git: a real repository of a few KB that lists 518,480 paths",
    "live git: --names passes the real ls-tree listing", "live git: --names refuses the real listing of a committed bare-repository shape",
    "live git: --names refuses the real listing of one 1 MiB blob", "live git: a clone whose tree sets `* text eol=crlf` re-checks clean",
    "live git: the control", "live git: --format C-quotes a non-ASCII path",
    "--names refuses a path with a quote", "--names passes a non-ASCII path as git prints it", "--names refuses the format form", "--names passes git's own output for a tree with a non-ASCII folder",
]
for token in REQUIRED:
    if not any(token in n for n in NAMES):
        record("coverage: no case named for " + token, ["missing"])

# ---- clean up and report -----------------------------------------------------------------------------

for path, is_dir in LINKS:
    if os.path.lexists(path):
        try:
            os.rmdir(path) if is_dir else os.unlink(path)
        except OSError:
            pass
for _root, _dirs, _files in os.walk(ROOT):  # git writes its object files read-only
    for _f in _files:
        try:
            os.chmod(os.path.join(_root, _f), stat.S_IWRITE | stat.S_IREAD)
        except OSError:
            pass
shutil.rmtree(ROOT)
leftover = os.path.exists(ROOT)

failed = RESULTS.count(False)
total = len(RESULTS)
print("%d cases, %d pass, %d FAIL%s" % (total, total - failed, failed, "; work folder not removed" if leftover else ""))
sys.exit(0 if failed == 0 and total > 0 and not leftover else 1)
