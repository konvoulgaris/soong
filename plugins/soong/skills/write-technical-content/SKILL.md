---
name: write-technical-content
description: Applies ASD-STE100 Simplified Technical English to technical documentation. Use when writing or editing READMEs, API docs, runbooks, ADRs, migration guides, code comments, and error or log messages. Enforces one instruction per sentence, active voice, present tense, and consistent terminology. Does not cover commit messages, PR descriptions, or Notion content.
---

# write-technical-content

Rules for writing technical documentation, derived from ASD-STE100 Simplified
Technical English and adapted for software.

## Rules

1. One instruction per sentence.
2. Procedural sentence: 20 words maximum. Descriptive sentence: 25 words
   maximum.
3. Active voice. Imperative mood for instructions. Write "Run the migration",
   not "The migration should be run".
4. Present tense. Do not write "will".
5. One word, one meaning. Choose one term for each concept and repeat it. Never
   vary a term for style.
6. Keep articles and complete sentence structure. Simplified Technical English
   is not terse-speak.
7. No ambiguous pronouns. If more than one noun could be the referent, repeat
   the noun instead of writing "it" or "this".
8. A warning or a caution comes before the step it applies to, never after.
9. Six items maximum in one procedure step list. Split a longer list.
10. No gerund as a noun. Write "To configure the server, edit the file", not
    "Configuring the server is done by editing the file".
11. No slang, no idioms, no humour, no jargon used for flavour.
12. Procedural paragraph: six sentences maximum. Descriptive paragraph: ten
    sentences maximum.

## Word choice

Before you choose a verb or a noun that has a shorter equivalent, read
`reference/approved-words.md` and use the approved column.

## Scope

This skill covers documentation. Three kinds of text belong elsewhere:

* PR titles and descriptions: use `manage-pr`.
* Notion content: use `write-notion-content`.
* Commit messages: follow the Conventional Commits rule in the repository
  `CLAUDE.md`. No skill governs commit message style, and `manage-pr` does not:
  it owns the PR title, which borrows Conventional Commit syntax.

The Notion boundary matters because the two skills give opposite instructions.
`write-notion-content` cuts articles and filler. This skill keeps articles and
complete sentences. The destination decides: content going into Notion follows
`write-notion-content`, and this skill does not apply.

These rules govern the documentation this skill produces, and nothing more. The
skill claims no precedence over other active modes or skills.
