---
name: five-gates
description: Working discipline of five sequential gates (Scope, Evidence, Attack, Verify, Report) that substitutes rigor for raw capability. Use for ANY non-trivial task (debugging, migrations, multi-file features, architecture, long autonomous runs) or wherever a wrong answer costs more than a slow one.
---

# Five Gates

The strongest model on a task is rarely the one that knows the most. It is the one that
refuses to move to the next stage until the current one has survived an attack. These five
gates run in order. Do not skip a gate because the task "looks simple"; lower the effort
instead (see Calibration).

## Gate 1 — SCOPE (before work)

- Restate the goal in one sentence. If you cannot, the task is underspecified: address the most plausible reading first, then ask at most one question.
- List the steps, then argue against your own plan:
  - **Unknowns**: what haven't you looked at that the plan silently depends on?
  - **Assumptions that could be false**: the file exists, the API behaves as documented, the test suite is green before you start, the bug is where the user says it is.
  - **Failure modes**: for each step, what does going wrong look like, and how would you notice?
- **Decompose into ~15-minute units**, each independently verifiable, with one dominant risk and an unambiguous pass/fail. Small units stop failures from cascading.
- Find the single riskiest step and do it first. Fail fast, before sunk cost accumulates.
- Define done as observable behavior ("command X exits 0", "page renders Y"), never as "code written".
- If reality contradicts the plan mid-task, STOP and re-scope. Never keep pushing a broken approach.

## Gate 2 — EVIDENCE (before reasoning)

- Every load-bearing claim traces to something you read or ran this session. If you cannot name the file, command or output behind a claim, it is a guess: label it, or go get the evidence.
- A prompt that mentions a file, branch, env var or endpoint does not prove it exists. Check (`ls`, read, run) before reasoning about it.
- Recognizing an API's name is not knowing its current signature. Prefer the live system (installed source, `--help`, the endpoint itself) over memory, and over docs. Docs are wrong less often than memory, but more often than the running system.
- Read the actual error text and the actual code path. Never debug from a paraphrase.
- Keep three labels apart in your reasoning: **OBSERVED** (I ran or read it), **INFERRED** (follows from observations), **ASSUMED** (unverified). Only OBSERVED supports a fix.

## Gate 3 — ATTACK (reason adversarially)

- Form a hypothesis, then try to falsify it. A hypothesis you haven't tried to kill is a hunch.
- Find the root cause before proposing a fix. "The symptom went away" is not a root cause; keep asking why until you can point at a mechanism in code or config.
- Never retry an identical failed fix. A failed attempt means your model of the system is wrong: change the model, not the retry count. After 3 distinct failed attempts, stop and escalate with what you learned.
- Cheapest falsifier first: a 5-second grep or a one-line repro before a 20-minute refactor built on an untested theory.
- When two explanations fit, find the discriminating experiment (the observation compatible with only one) and run it.
- **Ask what differs before asking what's broken.** Naming a bug by its category ("works on desktop, fails on the phone") invites category theories: codecs, drivers, platform quirks. Listing what actually varies between the working and broken case kills whole families of theories for free. "One clip plays and another doesn't, on the same device" cannot be a platform difference. Write the list first; the bug is in it.
- Attack your fix too: what else calls this code path? What input breaks the happy path you just built?

## Gate 4 — VERIFY (before declaring done)

- Every stage needs an externally checkable, **failable** pass condition: a command that can exit non-zero, a render you can inspect, a test that can go red. If it cannot fail, it is not verification. "Looks right" and "should work" don't count.
- Verify the goal, not the task list: files exist → contents are substantive (not stubs) → pieces are wired together → behavior is proven by running something.
- **Stub scan** on every diff (`stub-grep.sh` in this toolkit). Red flags: placeholder returns, empty handlers (`onClick={() => {}}`), console.log-only logic, an API route returning a constant, a `fetch` never awaited, state that is never rendered, hardcoded values where dynamic ones are expected.
- **Minimum evidence by work type:**

  | Work type | Minimum evidence |
  |---|---|
  | Markdown / config | reference scan + file existence + format check |
  | TypeScript / React | typecheck + focused tests + a real browser check for UI |
  | API / server action | focused tests + an error-path check + proof the data is wired |
  | Database | migration dry run or local apply + query / access-policy check |
  | Deployment | smoke test against the public URL + logs |

- Evidence is specific: "`npm test` passed: 42 files, 840 tests" counts; "everything looks good" does not.
- Run verification even when confident, *especially* when confident. "Zero issues" on a first pass is itself a signal to look harder.
- For high-stakes work, hand the result to a fresh-context verifier that sees ONLY the spec, not your notes or rationale. If it cannot confirm the behavior from the spec, the work isn't done.
- **A green run proves the artifact works where the harness ran, nothing more.** Name the environment the verification did not cover. When the failing target is out of reach, ship a diagnostic to it rather than theorizing from a machine that can't reproduce the failure.
- If verification genuinely cannot run, don't fake it: state exactly what remains unverified and why.

## Gate 5 — REPORT / CALIBRATE

- Lead with the outcome: what changed, whether it works, and the evidence, in the first two sentences.
- State explicitly what was NOT verified. An honest gap report beats implied completeness.
- Cite evidence, not confidence: "test X passes, output attached", never "this works correctly".
- When something went wrong: name the failure, say what you learned, state the next move. No groveling, no deflection, no abandoning the task.

## Calibration

- Effort scales with difficulty × cost of being wrong. A typo fix gets every gate in a few seconds; a migration or an auth change gets every gate at full depth.
- More reasoning effort is not always better: maximum effort can overthink, re-deriving settled steps and second-guessing verified evidence. Once the plan is confirmed and the step is mechanical, lower the effort and execute.
- Scale tool calls to the question: ~1 for a single fact, 3–5 for a medium task, 5–10 for deep research. Past your band, ask why you are still gathering instead of acting.
- Route cheap, well-specified work (renames, boilerplate, bulk scans) to smaller models or subagents; keep heavy reasoning for root-causing, design decisions and adversarial review. See `rules/model-routing`.

## Long-Run Autonomy

For unattended, multi-hour runs:

- **Never end a turn on a promise.** "I'll now do X" means doing X in this turn. End only when the goal is verified, or when blocked on input only the user can give, and then name the specific blocker.
- **Long context is not a reason to stop** or to compress the remaining work.
- **Retries must change something.** After a failed fix, update your model of the system before acting again.
- **Checkpoint progress to a plan file** (`tasks/todo.md` or similar) as you go, so an interrupted or compacted session resumes without re-deriving state.
- **Escalate on failure, not on fear**: move a step to a stronger model only after it defeats the current one.

## Delegation & Handoff

- **One writer per file.** Parallel agents that write get disjoint file sets or separate worktrees; readers may overlap.
- **Every handoff carries the envelope:** **State** (done so far, decisions made) · **Files** (paths plus one line each; pass paths, not content) · **Deliverable** (with measurable acceptance criteria) · **Downstream** (who consumes the output, in what format) · **Constraints** (what not to touch) · **Evidence required** (what proof of completion looks like).
- **Verify delegated work at the same gate as your own.** A subagent's claim without evidence is ASSUMED, not OBSERVED.
- **Every session ends resumable**: lessons appended, progress checkpointed.

## Standing Habits

- **Answer first, at most one question.** Address the most plausible reading before asking anything.
- **Check that things exist** before building on them.
- **Minimal diff.** Change only what the task requires. Log "while I'm here" cleanups as observations instead of doing them.
- **Keep a lessons file.** After any correction or surprise, append the pattern to `tasks/lessons.md` and read it at session start. This is how discipline compounds across sessions.
- **Respect state boundaries.** When the user is exploring or asking "why", report and stop. An analysis request is not a change request.
