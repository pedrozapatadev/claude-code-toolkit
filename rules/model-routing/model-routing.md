# Model Routing Rules

> The model isn't the moat; the process and the routing are. Keep the *orchestration*
> smart and push *execution* to the cheapest model that clears the quality bar. A strong
> orchestrator delegating to cheap workers produces near-identical output at a fraction
> of the cost.

## The toolkit

Higher **Cost** = cheaper (more runs per dollar). Intelligence and Taste are routing
heuristics, not benchmarks. Check current prices before relying on them.

| Model | Alias | In / Out $ per M tokens | Cost | Intelligence | Taste | Default role |
|---|---|---|---|---|---|---|
| Fable 5.1 | `fable` | $10 / $50 | ★☆☆☆☆ | ★★★★★ | ★★★★★ | Taste-critical authorship (design, prose), and the escalation for problems that defeat Opus |
| Opus 5.5 | `opus` | $4 / $20 | ★★☆☆☆ | ★★★★★ | ★★★★☆ | **Orchestrator**: planning, synthesis, judgment, adversarial review |
| Sonnet 5.5 | `sonnet` | $2 / $10 | ★★★★☆ | ★★★★☆ | ★★★★☆ | **Workers**: writing code, focused reasoning, one item through one stage |
| Haiku 5.5 | `haiku` | $0.10 / $0.50 (prompts ≤100k tokens; $0.50 / $2.50 above) | ★★★★★ | ★★★☆☆ | ★★★☆☆ | **Scouts**: search, extraction, classification, routing, first-pass reads |

## Routing heuristics

- **Match the tier to the step, not to the job.** A job is a mix of hard and easy steps.
  Orchestrate on Opus; fan execution out to Sonnet and Haiku.
- **Scouts = Haiku.** File finding, grep sweeps, "does X exist", extraction, labeling.
  Cheap enough to run many in parallel.
- **Workers = Sonnet.** Writing code, running a defined transform, focused reasoning.
- **Judge = Opus.** Planning, adversarial review, synthesis, final judgment: anything
  where a wrong call is expensive.
- **Reviewers run on a different model than the author.** A fresh-context review is
  stronger when the model differs too; otherwise a session quietly grades its own work.
  Pin reviewer agents explicitly (`model:` and `effort:` in the agent frontmatter) so
  they never silently inherit the session model.
- **Named agents: let the frontmatter route.** Precedence is: explicit `model` parameter
  > agent frontmatter > `CLAUDE_CODE_SUBAGENT_MODEL` > parent session. Pass an explicit
  model only to escalate on purpose.
- **In workflow scripts, set `model:` and `effort:` on every `agent()` call.** An agent
  with no `model:` inherits the session model, which is how expensive sessions leak into
  mechanical fan-out.
- **Escalate, don't default up.** Start cheap. Move a specific step to a bigger model
  only after it fails the verify gate, not preemptively.
- **Taste is the exception.** When the output is something a human will *judge by eye*
  (visual design, brand copy, art direction), quality outranks token cost: use the
  strongest-taste model at high effort. Mechanical subtasks inside that work (asset
  compression, file moves, config) still go to cheap models.

## Effort calibration (orthogonal to model choice)

Levels: `low · medium · high · xhigh · max`.

- **`high` by default.** The sweet spot for most judgment-sensitive work.
- **`xhigh`** for long coding and agentic tasks, where a mid-task error compounds.
- **`max` is not "better".** It can overthink a settled step into a worse answer. Reserve
  it for hard, latency-insensitive judgment: adversarial review, final verdicts.
- **`low` / `medium`** for Sonnet and Haiku fan-out. Raising effort on a mechanical step
  only burns tokens.
- **Scale tool calls to complexity:** ~1 for a single fact, 3–5 for a medium task, 5–10
  for deep research or comparison.

## When to spend up vs. down

| Signal | Route to |
|---|---|
| Fan-out over many independent items | Haiku scouts, in parallel |
| Write or refactor code, run a defined transform | Sonnet workers |
| Plan the work, decide what could go wrong | Opus orchestrator |
| Adversarially verify a finding | Opus, fresh context, high/max effort |
| One-shot the hardest unsolved problem (after Opus fails it) | Fable |
| Cheap, non-sensitive bulk work | Any cheaper local or open-source path |
