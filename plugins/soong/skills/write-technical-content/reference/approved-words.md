# Approved words

Use the approved column. This table is a guide to consistency in software
documentation, not the ASD-STE100 dictionary. The full approved word list holds
about 900 entries and is published under its own terms, so it is out of scope
here.

| Not approved | Approved |
| --- | --- |
| utilize, make use of, leverage | use |
| commence, initiate, kick off | start |
| terminate | stop |
| prior to | before |
| subsequent to, following (as a time relation) | after |
| in order to | to |
| due to the fact that, owing to | because |
| in the event that | if |
| at this point in time, currently | now |
| is able to, has the ability to | can |
| perform an update, do an update | update |
| provide support for | support |
| a number of, a variety of | some, many |
| facilitate | help, let |
| functionality | feature |
| methodology | approach, process |
| endeavour, attempt | try |
| ascertain, determine | find |
| require, necessitate | need |
| modify, alter | change |
| implement (as a synonym for write) | add, build, write |
| execute (a command) | run |
| obtain, acquire | get |
| transmit | send |
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

Replacing "however" with "but" changes the punctuation. Write "..., but ...",
not "...; but, ...".

## Terms the table must not touch

Some words look like filler and are not. They carry a precise meaning in
software. Rule 5 of the skill, one word and one meaning, protects these rather
than replacing them.

- `verify` and `validate` are separate. Validation asks whether input satisfies
  the rules. Verification asks whether an artifact matches its specification.
  Neither is "check".
- `deprecate` is a lifecycle state, not a removal. It means the feature still
  works and still ships, its use is discouraged, and removal comes later.
  Writing "remove" tells the reader the feature is already gone.
- `enable` is standard for flags and configuration. Keep "enable TLS". Do not
  write "let TLS".
- `function` and `method` name language constructs. Never introduce either as a
  plain-language replacement for something else, because the reader will look
  for code. This is why `functionality` maps to "feature" and `methodology` maps
  to "approach".
