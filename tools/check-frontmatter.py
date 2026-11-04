"""Check the frontmatter of the plugin's agents, skills and command.

Run from the repository root:
    python -I tools/check-frontmatter.py [files...]
With no arguments it globs agents/*.md, skills/*/SKILL.md and commands/*.md under plugins/devhouse.
Output: "ok <file> ..." or "FAIL <file>: <reason>" per file, then "<n> checked, <m> failed".
Exit 0 when nothing failed, 1 on any FAIL, 2 when Python is older than 3.12 or PyYAML cannot be imported.
Why it exists: subsystems/plugin-packaging.md section 9.
"""
import glob
import json
import os
import re
import sys
from pathlib import PurePath

if sys.version_info < (3, 12):
    print("Python 3.12 or later is needed (os.path.isjunction)")
    sys.exit(2)

try:
    import yaml
except Exception:
    print("yaml import failed (PyYAML is needed; -I ignores user site-packages)")
    sys.exit(2)

PLUGIN = "plugins/devhouse"
DEFAULT_GLOBS = [
    PLUGIN + "/agents/*.md",
    PLUGIN + "/skills/*/SKILL.md",
    PLUGIN + "/commands/*.md",
]
# The runtime's own pattern: it ends the block at the first '---' anywhere.
RUNTIME = re.compile(r"^---\s*\n([\s\S]*?)---\s*\n?")
MERGE_TAG = "tag:yaml.org,2002:merge"
AGENT_KEYS = {"name", "description", "model", "tools"}
# The only characters an agent's tools value may hold; anything else could split differently in the runtime.
TOOLS_CHARS = re.compile(r"[^A-Za-z0-9_(),:*. -]")


class StrictLoader(yaml.SafeLoader):
    def compose_node(self, parent, index):
        if self.check_event(yaml.AliasEvent):
            raise yaml.YAMLError("alias")
        if self.peek_event().anchor is not None:
            raise yaml.YAMLError("anchor")
        return super().compose_node(parent, index)

    def construct_mapping(self, node, deep=False):
        seen = set()
        for key_node, _ in node.value:
            if key_node.tag == MERGE_TAG:
                raise yaml.YAMLError("merge key")
            key = self.construct_object(key_node, deep=True)
            try:
                dup = key in seen
            except TypeError:
                raise yaml.YAMLError("unhashable key")
            if dup:
                raise yaml.YAMLError("duplicate key %r" % (key,))
            seen.add(key)
        return super().construct_mapping(node, deep)


def kind_of(path):
    p = PurePath(path)
    if p.parent.name == "agents":
        return "agent"
    if p.name == "SKILL.md" and p.parent.parent.name == "skills":
        return "skill"
    if p.parent.name == "commands":
        return "command"
    return None


def nonempty_str(v):
    return isinstance(v, str) and v.strip() != ""


def yaml_reason(e):
    """PyYAML's message without its snippet of the offending line."""
    if isinstance(e, yaml.MarkedYAMLError):
        text = " ".join(x for x in (e.context, e.problem) if x)
        if e.problem_mark is not None:
            text += " (frontmatter line %d)" % (e.problem_mark.line + 1)
        return text.replace("\n", " ")
    return str(e).replace("\n", " ")


def tools_problem(value):
    """Why an agent's tools value is refused, or None. Strict, so no splitter difference can hide a *."""
    if TOOLS_CHARS.search(value):
        return "tools holds a character outside A-Z a-z 0-9 _ ( ) , : * . - and the space"
    depth = 0
    for ch in value:
        if ch == "(":
            depth += 1
            if depth > 1:
                return "tools has nested parentheses"
        elif ch == ")":
            depth -= 1
            if depth < 0:
                return "tools has unbalanced parentheses"
    if depth:
        return "tools has unbalanced parentheses"
    return None


def split_tools(value):
    """Split on commas and spaces outside parentheses."""
    out, cur, inside = [], "", False
    for ch in value:
        if ch == "(":
            inside = True
        elif ch == ")":
            inside = False
        if not inside and ch in ", ":
            if cur:
                out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur:
        out.append(cur)
    return out


def is_link(path):
    """A symlink, or a Windows junction, which the runtime's folder walk also treats as a link."""
    return os.path.islink(path) or os.path.isjunction(path)


def symlinked(path):
    """True when the path or any folder in it is a symlink."""
    parts = PurePath(path).parts
    return any(is_link(os.path.join(*parts[: i + 1])) for i in range(len(parts)))


def check(path):
    """Return (None, info) when fine, or (reason, None)."""
    kind = kind_of(path)
    if kind is None:
        return "not under agents/, skills/<folder>/SKILL.md or commands/", None
    if symlinked(path):
        return "the path is or goes through a symlink", None
    try:
        with open(path, encoding="utf-8", newline="") as f:
            raw = f.read()
    except (OSError, UnicodeDecodeError) as e:
        return "cannot read: %s" % e, None
    if re.search(r"\r(?!\n)", raw):
        return "a CR not followed by LF (CR-only line endings)", None
    text = raw.replace("\r\n", "\n")
    lines = text.split("\n")
    if lines[0] != "---":
        return "first line is not ---", None
    try:
        close = lines.index("---", 1)
    except ValueError:
        return "no closing --- line", None
    between = lines[1:close]
    m = RUNTIME.match(raw)
    if not m:
        return "the runtime's frontmatter pattern does not match", None
    if m.group(1).replace("\r\n", "\n") != "\n".join(between) + "\n":
        return "the runtime ends the block early (a --- inside the frontmatter)", None
    try:
        data = yaml.load("\n".join(between) + "\n", Loader=StrictLoader)
    except yaml.YAMLError as e:
        return "not strict YAML: %s" % yaml_reason(e), None
    if not isinstance(data, dict):
        return "frontmatter is not a mapping", None

    p = PurePath(path)
    if kind == "agent":
        if set(data) != AGENT_KEYS:
            return "keys are %s, expected exactly %s" % (sorted(map(str, data)), sorted(AGENT_KEYS)), None
        if data["name"] != p.stem:
            return "name %r is not the file stem %r" % (data["name"], p.stem), None
        if not nonempty_str(data["description"]):
            return "description is not a non-empty string", None
        for key in ("model", "tools"):
            raws = [ln[len(key) + 2:] for ln in between if ln.startswith(key + ": ")]
            if len(raws) != 1 or data[key] != raws[0]:
                return "%s does not equal the raw text of its line" % key, None
        problem = tools_problem(data["tools"])
        if problem:
            return problem, None
        tools = split_tools(data["tools"])
        if not tools:
            return "tools is an empty list", None
        if "*" in tools:
            return "tools has an element *, which gives the agent every tool", None
        return None, "%s %s %s" % (data["name"], data["model"], data["tools"])
    if kind == "skill":
        if set(data) != {"name", "description", "disable-model-invocation"}:
            return "keys are %s, expected name, description, disable-model-invocation" % sorted(map(str, data)), None
        if data["name"] != p.parent.name:
            return "name %r is not the folder %r" % (data["name"], p.parent.name), None
        if not nonempty_str(data["description"]):
            return "description is not a non-empty string", None
        if data["disable-model-invocation"] is not True:
            return "disable-model-invocation is not true", None
        return None, ""
    if set(data) != {"description"} or not nonempty_str(data["description"]):
        return "a command holds only a non-empty description", None
    return None, ""


def hidden(parts):
    return any(x.startswith(".") for x in parts)


def walk_unexpected(folder, allowed, expected):
    """Every file under folder whose path (split into parts, relative to folder) is not allowed."""
    bad = []
    for root, dirs, files in os.walk(folder):
        for d in sorted(dirs):
            full = os.path.join(root, d)
            if is_link(full):
                bad.append((full.replace(os.sep, "/"), "a symlinked folder; the check would not follow it"))
        for name in sorted(files):
            full = os.path.join(root, name)
            parts = PurePath(os.path.relpath(full, folder)).parts
            if not allowed(parts):
                bad.append((full.replace(os.sep, "/"), "not %s; the check would not see it" % expected))
    return bad


def missed_files():
    """Things the glob would miss but the runtime might load."""
    bad = []
    agents = PLUGIN + "/agents"
    if not os.path.isdir(agents):
        bad.append((agents, "not found (run from the repository root)"))
    else:
        for entry in sorted(os.listdir(agents)):
            full = os.path.join(agents, entry)
            if not (os.path.isfile(full) and entry.endswith(".md") and not entry.startswith(".")):
                bad.append((full.replace(os.sep, "/"), "not an agents/*.md file; the check would not see it"))
    skills = PLUGIN + "/skills"
    if os.path.isdir(skills):
        bad += walk_unexpected(skills, lambda p: len(p) == 2 and p[1] == "SKILL.md" and not hidden(p), "skills/<folder>/SKILL.md, with no name starting with a dot")
    commands = PLUGIN + "/commands"
    if os.path.isdir(commands):
        bad += walk_unexpected(commands, lambda p: len(p) == 1 and p[0].endswith(".md") and not hidden(p), "commands/*.md, with no name starting with a dot")
    manifest = PLUGIN + "/.claude-plugin/plugin.json"
    if os.path.isfile(manifest):
        try:
            with open(manifest, encoding="utf-8") as f:
                keys = json.load(f)
        except (OSError, ValueError) as e:
            bad.append((manifest, "cannot read: %s" % e))
        else:
            for k in ("agents", "skills", "commands"):
                if isinstance(keys, dict) and k in keys:
                    bad.append((manifest, "has a %r key, which could load files the check never sees" % k))
    return bad


def main(argv):
    sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")
    files = argv or [f.replace(os.sep, "/") for g in DEFAULT_GLOBS for f in sorted(glob.glob(g))]
    failed = 0
    checked = 0
    saw_agent = False
    for path in files:
        checked += 1
        reason, info = check(path)
        if kind_of(path) == "agent":
            saw_agent = True
        if reason:
            failed += 1
            print("FAIL %s: %s" % (path, reason))
        else:
            print(("ok %s %s" % (path, info)).rstrip())
    for path, reason in missed_files():
        failed += 1
        print("FAIL %s: %s" % (path, reason))
    if checked == 0:
        failed += 1
        print("FAIL: no files to check")
    elif not saw_agent:
        failed += 1
        print("FAIL: no file under agents/ was checked")
    print("%d checked, %d failed" % (checked, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
