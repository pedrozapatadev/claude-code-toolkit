# five-gates

A Claude Code skill that installs a working discipline: five gates run in order, and the
model does not move to the next one until the current one survives an attack.

| Gate | Question it forces |
|---|---|
| **1. Scope** | What exactly is done, what is the riskiest step, and what would make this plan wrong? |
| **2. Evidence** | Is every load-bearing claim backed by something I read or ran *this session*? |
| **3. Attack** | Have I tried to falsify my hypothesis, and found the root cause rather than a symptom? |
| **4. Verify** | Is there a pass condition that could have failed, and did it run? |
| **5. Report** | Does the summary lead with the outcome, the evidence, and what was *not* verified? |

## Why

Most agent failures I see are discipline failures, not capability failures: a claim about
a file nobody opened, a fix for a symptom, "should work" in place of a test run, a
summary that hides what wasn't checked. A larger model makes these less often but still
makes them. A process makes them visible to any model.

Three ideas carry most of the weight:

- **OBSERVED / INFERRED / ASSUMED.** Only observed facts support a fix. Labeling the rest
  is what stops confident hallucinated debugging.
- **Failable verification.** If a check cannot go red, it is not verification. This is
  the prompt-side twin of the [verify-gate](../../hooks/verify-gate/) hook.
- **Ask what differs before asking what's broken.** Listing what actually varies between
  the working and broken case kills whole categories of wrong theories before any
  debugging starts. (Learned after three wasted debugging rounds on a theory the
  difference list would have ruled out.)

The skill also covers long unattended runs (never end a turn on a promise, checkpoint to
a plan file, retries must change something) and delegation (one writer per file, a
fixed handoff envelope, and treating a subagent's unproven claim as ASSUMED).

## Install

Included in the `verify-first` plugin, where it is invoked as `/verify-first:five-gates`. Or copy it by hand:

```bash
mkdir -p ~/.claude/skills && cp -r skills/five-gates ~/.claude/skills/
```

Claude loads it when a task matches the description (non-trivial, multi-step,
correctness over speed), or on request: "use five-gates".
