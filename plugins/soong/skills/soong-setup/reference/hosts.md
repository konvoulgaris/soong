# Host operations

Use the active host's tools. Keep the workflow's inputs, approval gates,
parallelism, and failure handling. Read `principles.md` beside this file before
running a Soong workflow. User instructions take precedence.

## Scripts and resources

Resolve the absolute directory containing the installed `SKILL.md` from the
skill catalog. For shell examples, set `SOONG_SKILL_DIR` to that directory and
`SOONG_PLUGIN_ROOT` to its parent directory's parent. These are task variables,
not variables provided by the host. Quote both paths. Never infer an installed
path from the consumer repository or a plugin cache version.

For example, `soong-setup/scripts/soong-setup.sh` is
`"$SOONG_SKILL_DIR/scripts/soong-setup.sh"` when running `soong-setup`.
A sibling skill's scripts are under
`"$SOONG_PLUGIN_ROOT/skills/<skill-name>/scripts/"`.
Resolve named agent procedures under `"$SOONG_PLUGIN_ROOT/agents/"`.

## Dispatch

| Operation | Claude Code | Codex |
| --- | --- | --- |
| Named agent | Agent tool with the named `subagent_type` | Read `agents/<name>.md`; pass the procedure body and workflow inputs to the available subagent tool |
| Read-only exploration | Agent tool with `subagent_type: Explore`, `model: sonnet` | Spawn a subagent with explicit read-only instructions and the requested inputs; inherit the model |
| Parallel work | Dispatch independent Agent calls together | Dispatch independent subagents before waiting; observe the host's concurrency limit |
| Follow-up | Resume the agent with its identifier | Use the available follow-up or message tool with the agent identifier |
| Wait | Collect Agent results | Use the available subagent wait tool and collect each result |

Codex tools can be named `spawn_agent` and `wait`, or be exposed under
`collaboration` as `spawn_agent`, `wait_agent`, and `followup_task`. Use only
available tool schemas. Do not create user-owned chats to implement subtasks.
Do not translate Claude model names into guessed Codex models.

For a named agent, read the full Markdown file before dispatch. Pass its body,
excluding YAML frontmatter, and every input required by the calling workflow.
Carry read-only rules, prohibited actions, evidence requirements, and output
format into the prompt. Claude `tools:` metadata does not constrain Codex tools.
Use host-enforced tool restrictions when available. Tell the user when only
prompt instructions enforce a required access restriction.

Read-only exploration must not edit files, run mutating commands, write to
Notion, or post to GitHub. Named agents use their own procedure restrictions.
If no subagent capability exists, report that limitation and apply only the
calling workflow's stated fallback. Do not silently skip independent reviewers.

## Worktrees and branch names

Claude uses `claude/<slug>` and, for `develop`,
`.claude/worktrees/develop-<roadmap-item-id>` under the main checkout.
Codex uses `codex/<slug>` and a host-managed worktree when available.
For `develop`, set its name to `develop-<roadmap-item-id>` when creating the
managed worktree from `main`, and record its returned
path in the ledger. Inspect attached worktrees before creating another one.
If a crash precedes the ledger write, identify a candidate by its recorded
attachment and roadmap identity; never assume an unrelated worktree is reusable.

If Codex has no managed worktree tool, use
`.worktrees/develop-<roadmap-item-id>` under the main checkout with Git.
Verify a project-local directory is ignored before creating files there.
Keep one worktree for the whole stack. A resume uses ledger paths and branch
names even when another host created them. Never rename existing stack branches
because the active host changed.

## Hooks

Claude loads `hooks/hooks.json`. Codex loads the explicitly generated
`hooks/hooks.codex.json`, which includes the Bash convention guard, the Notion
content reminder, and SessionStart principles. Codex users must trust hooks
before the runtime executes them. Hook configuration alone does not prove
runtime enforcement.

Codex does not load Claude's Skill matcher or Claude's brainstorming prompt
reminder. Follow the installed `using-git-worktrees` skill for isolation before
brainstorming. The shared workflow instructions still apply when hooks are
unavailable. Some tool paths bypass hooks; hooks are guardrails rather than a
complete enforcement boundary.
