# 0002 — The omission sweep in Roxy's validation checklist

**Status:** Accepted

## Context

A maintenance task needed to read a service's log files. The Track 0 doc set for that
subsystem — one of several that share the same logging writer class — was complete,
human-gated and Roxy-validated. It could not answer the question.

The log layout was guessed wrong twice and found only by reading the source. The real answer
(the file naming, the record format and the retention) appeared in **none** of the five
subsystem docs that named the writer class. The format mattered materially: log messages
contain embedded newlines, so line-based `grep` mis-counts every record, and two extraction
scripts were wrong before the source was read.

**Every claim in every one of those docs was true.** Nothing needed correcting. The doc set
failed by omission.

The four original checks — sections present, claims grounded, commands run, subsystem map
matches the file set — all test whether *what is present* is true or consistent. None asks
whether anything load-bearing is *absent*. Omissions could not fail the gate. That is a
structural blind spot, and it recurs on any topic in any product's Track 0, not just logging.

## Decision

- Add a fifth check, an **omission sweep**, worded as an adversarial-for-absence pass: list
  the operational questions a maintenance task would ask on day one that the doc cannot
  answer. Every unanswerable question is a finding, even when every sentence is true.
- Add a required **Observability** section to `subsystems/<name>.md`, so the standard *asks*
  the logging question rather than relying on an author to volunteer it.
- Require `overview.md`'s **Cross-cutting concerns** section to name the logging **artefact**,
  not merely the library — satisfied by a link where the detail lives in a `reference/` page,
  never by the mechanism's name alone.
- Add the rule **"Grounded is not sufficient — truth is the floor, not the bar."**
- Where a canonical question does not apply to the kind of thing a subsystem is, an explicit
  **N/A** is required. Silence is not an answer; a stated N/A is a conscious assertion, the
  same discipline the `None` rule already established.
- Add a `reference/<name>.md` page type and the rule **"Shared infrastructure is documented
  once."** This addresses duplication rather than omission, so it needs its own justification:
  in the originating case, five subsystem docs each named the same writer class and **none** carried the
  artefact detail. Splitting one fact across five half-mentions is how the omission survived a
  clean gate — every doc looked like it had said something about logging. Documenting shared
  infrastructure once, in a page each subsystem links to, removes the ambiguity about whose
  job it was to carry the detail.

## Consequences

- **Check (5) is not redundant with check (2).** Check (2) asks "is this sentence true?";
  check (5) asks "what sentence is missing?" A doc can pass (2) perfectly and fail (5)
  completely — that is exactly what happened in the originating case. Do not collapse them.
- **Nor is it redundant with check (1).** Adding a required Observability section creates a
  new, more tempting collapse: "the section is present, therefore the sweep is satisfied."
  It is not. Check (1) counts headings against a closed schema; check (5) asks open questions.
  Three of the four canonical questions — is it running, where does config come from at
  runtime, what does failure look like from outside — have **no required section that asks
  them**, so a doc with all ten sections present still has three sweep questions no section
  is obligated to address; an author may still answer them somewhere, and ours do. The sweep
  retains independent work permanently.
- Roxy's audits get longer and will produce findings on docs that previously passed clean.
  That is the intended effect, not a regression.
- The sweep is deliberately a *question list*, not a fixed section schema: the canonical four
  are a floor, and the auditor is expected to add questions the specific system provokes.
- Retro-fitting existing doc sets to the revised standard is separate work, owned by each
  product's own dev-house, and is explicitly not blocked on or bundled with this change.
- **Not everything here is gate-checkable.** The canonical-home rule and the anti-restatement
  half of the shared-infrastructure rule map to no check in the five-check list — they rest on
  auditor judgement. Only the linked-from requirement is mechanically testable (check 4). This
  is a deliberate limit, not an oversight: a rule about which of several true homes a fact
  *should* occupy cannot be settled by counting.
