# manage-pr: feedback

Work through the reviewer feedback on **your own** open PR, comment by comment, with
the user driving every decision. This is an interactive walk: you never batch-decide
or auto-resolve. For each unresolved thread you surface the comment, propose a few
ways to handle it, get the user's call, make any agreed code change, and draft the
reply. Replies are collected and posted together at the very end, after the user
approves the batch.

The shared rules in `SKILL.md` apply here — no generated-by footer, no attribution
tag, never post without the user's go-ahead.

## Resolve the PR

Detect the PR for the current branch: `gh pr view --json number,url,baseRefName`.
If there is no PR, stop and tell the user. Report which PR you resolved before
starting.

## Gather unresolved threads

Gather in a subagent, not on the main thread. The GraphQL response carries every
thread including the resolved ones, and the walk then needs the code around each
comment on top of that. All of it stays in context for the rest of the walk, and
none of it is what you reply from. Dispatch one Agent tool call,
`subagent_type: Explore`, `model: sonnet`. `Explore` is read-only, so the
gathering pass cannot touch the code the walk is about to change.

Give the agent the PR number from the resolve step, plus the owner and repo,
which that step does not return
(`gh repo view --json owner,name -q '.owner.login + " " + .name'`). Substitute
all three rather than passing the placeholders through, and tell it to run:

```
gh api graphql -f query='
  query($owner:String!,$repo:String!,$pr:Int!){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        reviewThreads(first:100){
          nodes{ isResolved comments(first:50){ nodes{
            id databaseId path line body author{login}
          }}}
        }
      }
    }
  }' -F owner=<owner> -F repo=<repo> -F pr=<number>
```

Tell it to keep only the **unresolved** threads (skip threads already marked
resolved), and to return them in order, one block each:

- File path and line.
- The reviewer's comment text, verbatim. This is what you reply to, so it must not
  be summarized.
- The comment id to reply to.
- The code around that line, enough for the user to judge the comment without
  opening the file, and no more.

Tell it to propose nothing and to judge nothing. It gathers; the walk decides.

If there are no unresolved threads, tell the user and stop. If the agent fails,
run the query on the main thread and continue.

## Walk each comment with the user

Track the threads as todos and go through them **one at a time, in order**. For each:

1. Show the user the thread: file:line, the reviewer's text, and the surrounding code
   the gather step returned, so they have context without hunting for it. Do not
   re-read the file just to show that context again. Reading it is still required
   before step 5 edits it.
2. State your read of what the reviewer is asking for.
3. Propose **a few options** for handling it, concretely, not generically. Typical
   shapes:
   - make the requested code change (describe exactly what you'd change),
   - push back / explain why the current code is intentional,
   - ask the reviewer a clarifying question,
   - acknowledge and defer to a follow-up.
   Recommend one and say why, but let the user choose.
4. Wait for the user's input. Do not move on until they decide.
5. If the decision involves a code change, **make the change now**, then draft a reply
   that references what you changed. Otherwise just draft the reply.
6. Build the reply per the reply-style rules and store it as a draft against this
   thread's comment id. Do not ask the user to tighten, edit, or sign off on this
   individual draft, and do not ask whether to respond now — every reply stays a
   draft until the batch approval at the end. Mark whether this thread involved a
   code change, so you can attach the commit link when posting. Do **not** post yet.

## Reply style

Few words. Cut filler, articles, and pleasantries. Why speak many word when few word
do trick.

- One sentence is ideal. Say it in one sentence where possible.
- Lists are fine. Prefer a bullet list over a paragraph when listing things.
- Lead with the answer to the point raised.
- If you changed code, name what you changed and link the commit that fixed it. No
  code change means no commit link.
- If you disagree, give the reason, not just the verdict.
- No em-dashes. Use a period, comma, or parentheses instead.
- No Conventional-Commits formatting, no headers, no boilerplate, no generated-by
  footers, no robot emoji.
- **Never sign a reply with an attribution tag.** No "Addressed by Claude Code", no
  variation of it, in any position. The hook denies these.

## Approve the batch, then post

Once every unresolved thread has a drafted reply (or was explicitly skipped):

1. If any thread involved a code change, commit and push the work first, so the commit
   exists on the remote before you link it. Get the commit URL for the change:
   `gh browse --no-browser --commit <sha>` prints it, or build it as
   `<repo-url>/commit/<sha>`. One commit can resolve several threads; reuse its link.
2. For each thread whose reply cites a code change, append the commit link to the
   stored reply. Threads with no code change stay link-free.
3. **Show the user every drafted reply together**, each against its file:line, and
   wait for an explicit go-ahead. This is the one sign-off in the walk. Seeing the
   replies side by side is when tone inconsistencies across them become visible, so
   present them as a set, not one at a time. If the user wants changes, make them and
   show the revised set again.
4. Only after the user approves, post the replies in one batch. Reply on each thread
   to the stored comment id:

```
gh api repos/<owner>/<repo>/pulls/<number>/comments/<comment-id>/replies \
  -f body='<approved reply>'
```

Report which threads you replied to. Do not resolve threads yourself unless the user
asks. Leave that to the reviewer.

## Rules

- One comment at a time during the walk. Never present a bulk plan for all comments
  and ask for a single approval on the decisions. The user decides each one.
- Always offer options and a recommendation; never just pick an action silently.
- Make the agreed code change before drafting the reply that describes it, so the
  reply is accurate.
- **Per thread**, do not prompt the user to tighten, edit, or sign off on the draft,
  and do not ask whether to respond now. Build it from the reviewer's point and the
  reply-style rules, and keep it a draft.
- **On the assembled batch**, always get one explicit approval before posting. These
  two rules are not in tension: no sign-off on each draft as it is written, one
  sign-off on the whole set before anything reaches GitHub.
- Post all replies only at the end, never before, and never without that approval.
- Gather the threads in a subagent. The reviewer's comment text comes back
  verbatim; a summarized comment is one you cannot reply to accurately.
- Only touch unresolved threads. Do not reply on or reopen resolved ones.
- Never resolve or dismiss a reviewer's thread on their behalf unless asked.
- If a code change is large or risky, flag it and confirm scope before editing rather
  than charging ahead.
