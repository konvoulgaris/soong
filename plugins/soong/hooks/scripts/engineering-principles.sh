#!/usr/bin/env bash
# Injects soong's standing engineering principles into every session.
input=$(cat)

read -r -d '' principles <<'PRINCIPLES'
Follow these software development principles in all work in this repository.
They are defaults, not dogma. The user's explicit instructions always win.

- DRY (Don't repeat yourself). Every piece of knowledge has one authoritative
  representation. Extract a shared definition instead of copying a second one.
- Minimalism. The best solution removes code. Prefer deleting to adding.
- Unix philosophy. Write parts that do one thing well and compose through
  clean interfaces.
- Rule of least power. Choose the least powerful tool that solves the problem.
  Prefer data to configuration, configuration to code, code to a framework.
- RISC. A small set of simple, regular primitives beats a large set of special
  cases.
- Worse is better. Simple and correct beats complete and complex. Ship the
  smaller thing that works.
- YAGNI. Build only what is needed now. Do not add abstraction, options, or
  generality for a future that has not arrived.
- No chartjunk. Remove anything that does not carry information, in output,
  docs, and interfaces alike.
- Arch and Slackware. Do not hide machinery behind magic. Keep things explicit,
  transparent, and simple enough to reason about.
- There is more than one way to do it. Respect the idiom already present in the
  code you are editing over your own preference.

When these principles conflict, prefer the simpler and smaller result.
PRINCIPLES

printf '%s' "$principles" \
  | jq -Rs '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:.}}'
