# claude-code-toolkit

[![test](https://github.com/pedrozapatadev/claude-code-toolkit/actions/workflows/test.yml/badge.svg)](https://github.com/pedrozapatadev/claude-code-toolkit/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Deterministic guardrails for Claude Code, built around one rule: an agent's "done"
has to be proven, not claimed.**

This is a small, curated extract from the configuration I use every day to run Claude
Code on long, mostly unattended builds. It holds four hooks, one script, one skill and one rule. Each piece
is self-contained, has its own README explaining the design, and is covered by
fixture tests that run in CI on Linux and macOS.

| Piece | Type | What it does | Tests |
|---|---|---|---|
| [**verify-gate**](hooks/verify-gate/) | `Stop` hook | Blocks the agent from ending its turn on a broken build, and is engineered never to trap the session. | 22 |
| [**commit-guard**](hooks/commit-guard/) | `PreToolUse` hooks | Blocks commits that would include secrets or credential files, even through chained commands like `git add .env && git commit`. Also guards `.env`, lock files and `.git/` from edits. | 33 |
| [**context-nudge**](hooks/context-nudge/) | `UserPromptSubmit` hook | Tells the model, once, at a prompt boundary, when the context is large enough that a fresh session would be cheaper and sharper. | 10 |
| [**stub-grep**](scripts/stub-grep/) | script | Fails on `TODO` / `FIXME` / `not implemented` in *added* lines only, so placeholder "finished" code can't slip through. | 11 |
| [**five-gates**](skills/five-gates/) | skill | A working discipline: Scope, Evidence, Attack, Verify, Report. The prompt-side twin of the hooks. | n/a |
| [**model-routing**](rules/model-routing/) | rule | Which model tier and effort level runs which kind of step, and how to keep routing from silently breaking. | n/a |

## How the pieces fit

```mermaid
flowchart LR
    P([user prompt]) --> CN[context-nudge<br/><i>context too large?</i>]
    CN --> M{{Claude works}}
    M -- Edit / Write --> PF[protected-files<br/><i>.env, locks, .git?</i>]
    M -- git commit --> CG[pre-commit-gate<br/><i>secrets in the chain?</i>]
    M -- tries to stop --> VG[verify-gate<br/><i>verify.sh green?</i>]
    VG -- red: reason fed back --> M
    VG -- green / released --> D([turn ends])
    S[[five-gates skill]] -. shapes how .-> M
```

Hooks enforce the parts that must never be skipped. The skill shapes the judgment that
hooks can't reach. The [Claude Code best practices](https://code.claude.com/docs/en/best-practices)
draw the same line: `CLAUDE.md` instructions are advisory, hooks are deterministic.

## Design principles

1. **Deterministic over advisory.** If skipping a step is expensive, it is a hook, not a
   sentence in a prompt.
2. **Block only when the block is useful.** A guardrail that loops forever, hangs on a slow
   build, or blames the agent for pre-existing errors gets disabled within a week.
   verify-gate releases on timeout and after three identical failures, and scopes out
   errors in files the agent didn't touch. Claude Code's built-in cap (8 consecutive
   Stop-hook continuations) resets whenever Claude calls a tool, so an agent that keeps
   attempting fixes never reaches it. The release has to live in the hook.
3. **Fail open on the unparseable, closed on the dangerous.** When a hook can't parse
   its input, it allows the action, so an exotic command never wedges a session. A known
   secret pattern or credential path always blocks.
4. **Model the agent, not a human.** Agents chain commands, commit from other
   directories and never pause between `add` and `commit`. commit-guard parses the whole
   command line because a git `pre-commit` hook sees an empty index at that moment.
5. **Every piece has failable tests.** Sandboxed `HOME`, temporary git repos, no network.

## Install

As a Claude Code plugin (installs the hooks and the skill):

```text
/plugin marketplace add pedrozapatadev/claude-code-toolkit
/plugin install verify-first@pedrozapatadev
```

Then opt a repo into the verification gate by copying the template:

```bash
mkdir -p .claude && curl -fsSL https://raw.githubusercontent.com/pedrozapatadev/claude-code-toolkit/main/hooks/verify-gate/verify.sh -o .claude/verify.sh
```

Or pick pieces by hand: clone to `~/.claude/toolkit` and merge the entries you want from
[`settings.example.json`](settings.example.json) into `~/.claude/settings.json`. The rule
is plain Markdown; see [its README](rules/model-routing/).

> Hooks run shell commands with your permissions. Read them before enabling them. They
> are short and commented for that reason.

Requirements: `bash`, `git`, `jq`, `perl`, `python3`. All are preinstalled on macOS and
most Linux distributions, except `jq`.

## Tests

```bash
./run-tests.sh
```

```text
hooks/commit-guard/test.sh       commit-guard: 33 passed
hooks/context-nudge/test.sh      context-nudge: 10 passed, 0 failed
hooks/verify-gate/test.sh        verify-gate: 22 passed, 0 failed
scripts/stub-grep/test.sh        stub-grep: 11 passed, 0 failed
```

## Background reading

- [Best practices for Claude Code](https://code.claude.com/docs/en/best-practices): give Claude a way to verify its work, and use hooks for anything that must happen every time.
- [Hooks reference](https://code.claude.com/docs/en/hooks): the event and JSON contracts these hooks implement.
- [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents): context as a finite resource, the premise of context-nudge.
- [Equipping agents for the real world with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills): the skill format five-gates uses.

## About

I'm Pedro Zapata Medal. I build with coding agents daily and treat the harness around the
model as the real engineering surface: what gets verified, what gets blocked, which model
runs which step. Everything here was extracted from my working setup, generalized,
and given tests before publishing.

MIT licensed.
