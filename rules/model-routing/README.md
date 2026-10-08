# model-routing

A rule file that tells the orchestrating session which model and effort level to use for
each kind of step, instead of running everything on the session model.

The idea: **match the model to the step, not to the job.** A job mixes hard steps
(planning, root-causing, final judgment) with easy ones (search, extraction, boilerplate).
Run the orchestrator on a strong model, fan scouts out to the cheapest tier, give coding
to the middle tier, and escalate a step only after it fails verification.

What it encodes beyond "use the cheap model for easy things":

- **Reviewers run on a different model than the author**, pinned in agent frontmatter, so
  a review can't silently inherit the session model and grade its own work.
- **Precedence is spelled out** (explicit param > frontmatter > env var > parent), because
  a misplaced `model:` parameter is the usual way routing silently breaks.
- **Every `agent()` in a workflow script sets `model:` and `effort:`.** An unset model
  inherits the session's, which is how an expensive session leaks into mechanical
  fan-out.
- **Effort is orthogonal to model**, and `max` is not "better": it can overthink a
  settled step. It is reserved for hard, latency-insensitive judgment.
- **Taste is the exception.** Output a human judges by eye gets the strongest-taste
  model, whatever the token cost.

## Install

Rule files are plain Markdown. Reference it from your `CLAUDE.md`:

```markdown
Model routing: @~/.claude/rules/model-routing.md
```

```bash
mkdir -p ~/.claude/rules && cp rules/model-routing/model-routing.md ~/.claude/rules/
```

Prices and model names reflect October 2026; update the table when the lineup changes.
