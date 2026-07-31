# Approved words

Use the approved column. This table is a guide to consistency in software
documentation, not the ASD-STE100 dictionary. The full approved word list holds
about 900 entries, and its publisher sets its own terms, so it stays out of
scope here.

A term belongs in the left column only if it carries no software meaning. Check
four senses: an identifier, a keyword, a protocol term, and a lifecycle state. A
term that carries one needs a sense-narrowing parenthetical, or it belongs in the
protected list at the end of this file.

The same test applies to the approved column. Never offer a replacement that the
reader could read as code. This is why `let` is absent from every approved cell,
and why `build`, `create`, and `support` appear there only as ordinary verbs.

| Not approved | Approved |
| --- | --- |
| utilize, make use of, leverage | use |
| commence, initiate (in the sense of begin), kick off | start |
| terminate (in the sense of end a task) | stop |
| prior to | before |
| subsequent to, following (as a time relation) | after |
| in order to | to |
| due to the fact that, owing to | because |
| in the event that | if |
| at this point in time | now |
| is able to, has the ability to | can |
| perform an update, do an update | update |
| provide support for | support |
| a number of, a variety of | some, many |
| facilitate | help |
| functionality | feature |
| methodology | approach |
| endeavour, attempt | try |
| ascertain, determine (in the sense of find out) | find |
| require (in the sense of necessitate), necessitate | need |
| modify, alter (in the sense of edit prose or configuration) | change |
| implement (as a synonym for write) | add, build, write |
| execute (a command) | run |
| obtain, acquire (in the sense of obtain a copy) | get |
| transmit (in the sense of send a message) | send |
| in the case of | for |
| with regard to, in terms of | for, about |
| a large number of | many |
| the majority of | most |
| approximately | about |
| additionally, furthermore | also |
| however | but |
| in conjunction with | with |
| by means of | with, by |
| in the vicinity of | near |
| subsequently | then |
| in advance of | before |
| spin up, stand up | start, create |
| reach out to | ask, contact |
| going forward | after this |

## How to read the table

A parenthetical narrows a row to one sense.

- `execute (a command)` becomes "run". `execute` in the sense of a program
  executing its own code stays.
- `implement (as a synonym for write)` becomes "add", "build", or "write".
  `implement` against an interface or a specification stays, as in "implement the
  `Reader` interface".
- `following (as a time relation)` becomes "after". `following` meaning the next
  thing shown stays, as in "see the following example".
- `terminate (in the sense of end a task)` becomes "stop". `terminate` as a
  lifecycle event stays, as in "the process terminated with exit code 1" or "the
  pod is terminating". A terminated thing has ended. A stopped thing can start
  again.
- `initiate (in the sense of begin)` becomes "start". `initiate` naming the
  initiating side of a two-party exchange stays, as in "the client initiates the
  TLS handshake".
- `determine (in the sense of find out)` becomes "find". `determine` meaning
  compute or decide stays, as in "the resolver determines the target host".
- `require (in the sense of necessitate)` becomes "need". `require` as a language
  construct stays, as in `require('fs')`, and the RFC 2119 sense stays, as in
  "this field is required".
- `alter (in the sense of edit prose or configuration)` becomes "change". `alter`
  as a SQL keyword stays, as in "the migration runs `ALTER TABLE orders`".
- `acquire (in the sense of obtain a copy)` becomes "get". `acquire` paired with
  release stays, as in "acquire the write lock" and `sem.acquire()`.
- `transmit (in the sense of send a message)` becomes "send". `transmit` as a
  protocol term stays, as in "TCP retransmits the segment" and "the transmit
  queue".

If you replace "however" with "but", change the punctuation. Write "..., but
...", not "...; but, ...".

## Terms the table must not touch

Some words look like filler and are not. These words carry a precise meaning in
software. Rule 5 of the skill, one word and one meaning, protects these terms
rather than replacing them.

- `verify` and `validate` are separate. Validation asks whether input satisfies
  the rules. Verification asks whether an artifact matches its specification.
  Neither is "check".
- `deprecate` is a lifecycle state, not a removal. It means the feature still
  works and still ships, its use is discouraged, and removal comes later.
  If you write "remove", the reader learns the feature is already gone.
- `enable` is standard for flags and configuration. Keep "enable TLS". Do not
  write "let TLS". For the same reason, never reach for `let` as a plain-language
  replacement: it is also a binding keyword in JavaScript and Rust.
- `currently` marks a state that holds now and is expected to change, which is
  how a known limitation is written. Keep "the API currently returns only the
  first 100 rows". If you write "now returns", you announce a change instead, and
  the note reads as a regression.
- `function` and `method` name language constructs. Never introduce either as a
  plain-language replacement for something else, because the reader looks for
  code. This is why `functionality` maps to "feature" and `methodology` maps to
  "approach".
