# 0017 — Threat model: accidents first, hostile members later

**Status:** Accepted. It governs the security reviews of security-relevant changes until a hostile-member order is
done, and is the model ADR 0015 works under. ADR 0016 (research intake) was built before it and is not
re-opened by it.

## Decision

Devhouse's checks are written in the same shell the members use. In the session form every member holds the full
Bash tool, as the user, on one filesystem; nothing the plugin ships can stop one of them writing to `.git`, the
plugin cache, the shell profile or the home on purpose. Reviews of the git tripwire kept finding exotic ways such
a member could get past a check: a criss-cross merge base, an NTFS stream name with `protectNTFS` off, a replace
ref in a submodule's git dir, a legacy sparse trick, a lock made at the right instant. Each was real, each cost a
build iteration, and none needed anything but a member deliberately writing exotic config into `.git`. The
decision: **accidents first, hostile members later.**

- **The statement,** canonical in the protocol's *The git tripwire* (*What it protects against, and what it does
  not*) and repeated by the README (*What devhouse protects against, and what it does not*) for the human, because
  no shipped text relies on an ADR. The shipped text is time-independent:
  - Devhouse defends against **accidents:** a member, or something she read, adding a hook, link, filter,
    submodule or config value by mistake.
  - It does not defend against a **hostile member,** and a hostile-member order is planned. In the session form a
    member already has full Bash; whatever needs someone to tamper with `.git` on purpose is a stated limit, not a
    defect.
  - **Prompt injection falls on the hostile side.** A member that follows injected text (a web page, a file, a
    dependency's README) and acts on it deliberately is the same as a hostile member, and is deferred with it. The
    checks catch what such text makes a member add by accident, and do not catch what it makes her do on purpose.
  - **Defence in depth is labelled as such.** Pieces that watch for tampering (the `submodule dir` hash, the
    `commondir` stop, the include hits, the re-checks for a junction made late, the call form's scrubbing) stay,
    because they cost nothing to keep and make accidents and clumsy tampering visible, but they are not guarantees
    and are not to be extended.
- **What a review asks.** Under this model a finding blocks only if it is a defect for an accident: an ordinary
  environment setting, a common tool, an honest mistake (a global clean filter skipped and a live key committed;
  an 8.3 name; a stray junction; a member committing `.claude/` or a hook). A finding that needs deliberate
  tampering is written down as a stated limit in the protocol (*Limits, and what they cost*) and ADR 0015's
  *Consequences*, with its reason (the README carries the costs, not the list of limits), and does not block.
  Method and the protocol are unchanged; Shiro still reports a real flaw as one, and the human still waives only
  what a gate blocks. A reviewer who is unsure which side a finding falls on says so and asks the human.
- **What is deferred, not dropped.** A later "hostile member" order, which will decide how far to go. Its likely shape is checks and merges in a fresh throwaway clone with no hooks or config.
  The stated limits it would start from are the protocol's *Limits, and what they cost*, ADR 0015's
  *Consequences* and, for the release, the charter's *The stated limit, in a mode that does not prompt*.

## Consequences

- Some checks are stronger than the model needs. They stay, labelled; removing them is a change with its own risk.
- **A release in the subagent form runs in any permission mode** (ADR 0013, *Amendment: a release runs in any permission
  mode*). Where the mode does not prompt, nobody checks `@remi`'s, `@shiro`'s or `@dahlia`'s calls one by one; a subagent that has read
  untrusted R holds `Bash` and `Write`. This is a hostile-member limit, covered in part after the fact by the baseline, the
  orchestrator's own checks, the security pass and the push.
- A project handling sensitive data should read the README's statement before trusting the team with it, and not
  rely on the tripwire against a compromised member.
- **Revisit** when the hostile-member order is taken up, or earlier on the human's say, or if a deployment puts
  members other than the user's own models on the checkout.
