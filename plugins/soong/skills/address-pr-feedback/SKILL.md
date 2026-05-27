---
name: address-pr-feedback
description: Use when responding to reviewers on your own open pull request, working through review comments, deciding what to change, and replying on the threads. Walks every unresolved review thread one-by-one with you, proposes a few options per comment, makes any agreed code change, drafts the reply, and posts all replies in one batch at the end. Triggers on "address the PR feedback", "reply to the reviewers", "go through the review comments", "respond to the PR comments".
---

# address-pr-feedback

Work through the reviewer feedback on **your own** open PR, comment by comment, with
the user driving every decision. This is an interactive walk: you never batch-decide
or auto-resolve. For each unresolved thread you surface the comment, propose a few
ways to handle it, get the user's call, make any agreed code change, and draft the
reply. Replies are collected and posted together at the very end.

## Resolve the PR

Detect the PR for the current branch: `gh pr view --json number,url,baseRefName`.
If there is no PR, stop and tell the user. Report which PR you resolved before
starting.

## Gather unresolved threads

Pull the review threads and keep only the **unresolved** ones (skip threads already
marked resolved). Use the GraphQL API, since the REST comments endpoint does not carry
resolution state:

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

Collect, in order, each unresolved thread: file path, line, the reviewer's comment(s),
and the comment id you will reply to. If there are none, tell the user and stop.

## Walk each comment with the user

Track the threads as todos and go through them **one at a time, in order**. For each:

1. Show the user the thread: file:line, the reviewer's text, and the surrounding code
   so they have context without hunting for it.
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
6. Show the drafted reply, get the user's sign-off (or edit it), and store it against
   this thread's comment id. Mark whether this thread involved a code change, so you
   can attach the commit link when posting. Do **not** post yet.

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

## Post at the end

Once every unresolved thread has an approved reply (or was explicitly skipped):

1. If any thread involved a code change, commit and push the work first, so the commit
   exists on the remote before you link it. Get the commit URL for the change:
   `gh browse --no-browser --commit <sha>` prints it, or build it as
   `<repo-url>/commit/<sha>`. One commit can resolve several threads; reuse its link.
2. For each thread whose reply cites a code change, append the commit link to the
   stored reply. Threads with no code change stay link-free.
3. Post the replies in one batch. Reply on each thread to the stored comment id:

```
gh api repos/<owner>/<repo>/pulls/<number>/comments/<comment-id>/replies \
  -f body='<approved reply>'
```

Report which threads you replied to. Do not resolve threads yourself unless the user
asks. Leave that to the reviewer.

## Rules

- One comment at a time. Never present a bulk plan for all comments and ask for a
  single approval. The user decides each one.
- Always offer options and a recommendation; never just pick an action silently.
- Make the agreed code change before drafting the reply that describes it, so the
  reply is accurate.
- Never post a reply before the user has signed off on it. Post all replies only at
  the end.
- Only touch unresolved threads. Do not reply on or reopen resolved ones.
- Never resolve or dismiss a reviewer's thread on their behalf unless asked.
- If a code change is large or risky, flag it and confirm scope before editing rather
  than charging ahead.
