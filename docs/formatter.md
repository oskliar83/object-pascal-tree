# The formatter

`source/PasTree.Format.pas` lays out a unit by a style: indentation, line
breaks, and in later stages spacing, case, wrapping and alignment. It is
built in stages; this document says what each stage does, what it keeps as
written, and how it is proven safe. Stages F1 (indentation and line
breaks) and F2 (spacing inside a line, case) are done; the plan for the
rest is at the end.

## 1. The model: rewrite the gaps, never a token

The lexer is lossless - every character of a file is in exactly one token,
comments and directives included. The formatter keeps every non-whitespace
token of the ORIGINAL stream and recomputes only the whitespace between two
of them. So it cannot lose a comment, a directive, an inactive `$IF` branch
or an include's text, and it cannot rewrite the author's spelling of a
construct (the structural printer writes one canonical spelling -
`class(TBase);` as `class(TBase) end;`, `[A][B]` as `[A, B]` - which a
formatter must not do silently).

The tree DECIDES each gap. For the token after it the formatter knows the
node that owns it (`TPasOwnership`, the printer's own-token table), the
LINE UNIT it starts - a statement, a declaration, a member, a section, a
case selector, an exception handler - and how deep that unit sits.

The items of one file, in order: every code token (a visible token of this
file), every comment, every directive, and every skipped region (an
inactive branch, opaque as a whole). The gap between two items is pure
whitespace, and the only text an edit replaces. The result is a list of
edits (`PasFormatEdits`: offset, length, text), minimal - a gap that is
already right gives none - which is what an editor (undo, the caret,
bookmarks), an LSP `TextEdit[]` and the IDE plugin apply; `PasApplyEdits`
gives the text.

## 2. What F1 decides

Per gap:

- **Its line breaks.** The author's, with blank lines capped
  (`MaxBlankLines`), plus the FORCED ones the options ask for: one
  statement per line, `begin` on its own line, `end`, `else`, `until`,
  `except`, `finally` on their own lines, one declaration or member per
  line, the section word (`var`, `type`, `const`, `uses`) alone on its line,
  the statement after `then` / `do` / `else` on the next line. F1 never
  removes a line break the author wrote (but blank lines over the cap) and
  never changes the spacing inside a line.
- **The indentation of the next line**, when the gap ends a line:
  - a line that starts a unit takes the unit's column, from the tree: a
    section's declarations one step in, a struct's members one step in and
    its visibility words at the type's column, a block's statements one step
    in, a body after `then` / `do` one step in and a `begin` at its
    statement's column, case selectors one step in and their statements one
    more, a nested routine one step in (`IndentNestedRoutines`);
  - a closer takes its construct's column;
  - any other line is a CONTINUATION and keeps its offset from the first
    token of the unit it continues - a wrapped argument list aligned under
    its `(` stays aligned;
  - a unit that shares its line with what comes before it (`private type`,
    `1: begin`, `else if`) lays out what it holds from that line;
  - a comment or directive line takes the column of the code line it
    introduces, with four exceptions: a comment in column 1 above
    declarations stays there (`KeepCommentsAtColumn1`, the RTL's
    `{ TList class }` headings), a comment over several lines keeps its
    column (moving its first line would cut it from the rest), a comment
    line under a trailing comment and right of the code continues that
    comment and keeps its offset from it, and a comment above a closer goes
    one step in when the author wrote it right of the closer; a directive
    keeps its offset from the code line it introduces, and one in column 1
    stays there (`KeepDirectivesAtColumn1`).

## 2a. What F2 decides

- **The spaces of a gap inside a line**, between two code tokens
  (`NormalizeSpaces`). One space is asked for around `:=`, a binary
  operator (word operators included) and a declaration's `=`
  (`SpaceAroundOperators`), and after `,`, `;` and `:`
  (`SpaceAfterSeparators`); none inside `( )` and `[ ]`, before `,` `;` `:`
  `)` `]`, around `.` and `..`, before the `(` of a call or a parameter list
  and the `[` of an index, inside the `< >` of type arguments and generic
  parameters, after a unary `-` `+` `@`, before a dereference `^` and after
  a pointer type's (`RemoveSpaces`). Where one space is asked for, a gap
  with none gets one and a gap with several keeps them - that is the
  author's alignment (`toEOF     = Char(0);`), which wrapping and alignment
  (F5) will own. Where none is asked for, the gap shrinks to nothing only
  when the two tokens lex back as the same two (spec B.2: `( *` stays,
  `- -B` stays two operators); the check lexes them after an operand, as
  they stand. Kept as written: the gap inside one literal's elements
  (`'a'#13`, `^M^J` - spec B.6.1), the one after a caret that starts an
  operand (B.6.2), a `Write` argument's `:width:prec`, and every gap next to
  a comment or directive.
- **The case of a word**: reserved words (`ReservedWordCase`, lower), the
  directive words in their directive position (`DirectiveWordCase`, lower:
  `override`, `read`, `out`, `on`, `at`, `abstract`, `helper`, `reference` -
  the identifier tokens a node owns, read off the self-host and the Studio
  source with `tools\PasTreeFormat -words`; no other kind owns one in valid
  code, so the rule is a list of those kinds and a stray word error
  recovery hands elsewhere keeps its case), a compiler directive's name
  (`CompilerDirectiveCase`, upper: `{$ifdef X}` -> `{$IFDEF X}`, never its
  argument), and, when the caller passes a `TPasIdentCaseFunc`, every
  identifier a leaf holds - its declaration's spelling, for a caller that
  resolves names; the function may change the case only. A token in a
  flagged unit keeps its case.

## 3. What is kept as written

The gap is copied, untouched:

- next to a skipped region, inside `asm` (the whole body is BASM text, and
  its `end`), after the final `end.`;
- around a token the tree owns no node for;
- around a unit the parse flagged - `nfError`, or a made-up node (nkError,
  nkMissing) in it. Error-tolerant is the primary mode: the half-typed
  statement at the caret is left alone. A flagged unit's column is its
  original one, so what it contains is laid out from where it really is;
- anywhere in an anonymous method written on one line.

No break is FORCED next to a directive: a directive may cut across a
construct, and the author's layout is the only safe one there.

## 4. Why it cannot change the program

Spec B.2 lists where whitespace is significant: between touching string
elements, before and after a caret, inside a multiline string, after a `//`
comment, between two tokens that would lex as one. F1 only ever turns a gap
that holds a line break into another one that still does, or inserts a line
break into a gap between two tokens the tree places in different line units
- never inside a literal, never right after a caret in operand position -
so none of them applies. F2 adds a space only between tokens of different
nodes (never inside a literal or after an operand's caret) and removes one
only when the two tokens re-lex unchanged. A case change is a spelling of
the same word (B.3: identifiers and reserved words are case-insensitive;
B.2.2: a directive's name).

That is the argument; the gates are the proof, each total over a corpus:

- **G-tok** (`PasSameTokens`): the output holds the input's tokens,
  whitespace aside, a word's and a compiler directive's text compared but
  for case - every comment, literal and inactive branch byte for byte;
- **G-idem**: formatting the output again gives no edit;
- **G-tree**: the output parses clean to the same tree (`TreeFingerprint`,
  the printer's T3r machinery).

`tests\FormatSmoke.dpr` holds every rule to an expected text and to the
three gates; `tools\PasTreeFormat.exe <dir>` runs the gates over a corpus
and measures the style's distance from it.

Measured at F2 (default options, Win64 defines):

| corpus | clean files | lines | edits | of them: indentation / break added / blank lines / spacing / case | G-tok, G-idem, G-tree |
|---|---|---|---|---|---|
| self-host `source\` | 33 | 114,726 | 2,154 (1.9%) | 1,686 / 310 / 1 / 157 / 0 | 0, 0, 0 |
| Studio `rtl` | 559 | 1,230,840 | 100,786 (8.2%) | 24,383 / 46,896 / 349 / 28,655 / 503 | 0, 0, 0 |
| Studio `vcl` | 118 | 329,132 | 18,656 (5.7%) | 9,615 / 4,210 / 26 / 3,951 / 854 | 0, 0, 0 |
| Studio `fmx` | 324 | 472,882 | 9,721 (2.1%) | 7,016 / 469 / 80 / 2,042 / 114 | 0, 0, 0 |

Most of the RTL's added breaks are one-line `if C then Exit;` statements:
about 11% of the RTL's `then` are followed by their statement on the same
line, and the default (`StatementAfterThenDo = fbAlways`) follows the other
89%. Tuning the default against these numbers is stage F3.

A formatted unit compiles to the same code; to a byte-identical `.dcu` only
without line and reference records (`-$D- -$L- -$Y-`, spec B.2), which is
how the compile-compare gate (stage F6) will judge it.

## 5. The default style

Read off the Studio RTL and VCL (688 units, 1.2M lines; a crude census over
the text, comments and strings blanked):

| rule | evidence | default |
|---|---|---|
| indent step | +2: 213,026 of the indent increases, the next (+8) 3,797 | 2 spaces |
| `begin` | alone on its line 79,379; `then begin` 13, `do begin` 18 | own line, at its statement's column |
| `else` | alone 10,576; `end else` 647; `else if` 2,200 | `end` and `else` on separate lines, `else if` together |
| `then` / `do` | at the end of the line 39,533 / 6,580; a statement after them 4,731 / 792 | the statement on the next line |
| section word | `var` alone 3,851; `var X:` 263; `uses` alone 317, `uses A, B;` 33 | alone on its line |
| class layout | visibility at the type's column, members one step in | the same |

## 6. Options (`TPasFormatOptions`)

`IndentStep` (2), `TabWidth` (8, for reading a column the original wrote
with tabs), `MaxBlankLines` (2; -1 keeps all), `BeginOnNewLine`,
`ElseOnNewLine`, `StatementAfterThenDo` (`fbAlways` / `fbKeep`),
`OneStatementPerLine`, `OneDeclPerLine`, `IndentNestedRoutines`,
`KeepDirectivesAtColumn1`, `KeepCommentsAtColumn1`, `NormalizeSpaces`,
`SpaceAroundOperators`, `SpaceAfterSeparators`, `RemoveSpaces` (all True by
default); `ReservedWordCase` and `DirectiveWordCase` (`fcLower`),
`CompilerDirectiveCase` (`fcUpper`), each of them `fcLower` / `fcUpper` /
`fcKeep`. Identifier case is not an option but an argument of
`PasFormatEdits`: only a caller that resolves names knows a declaration's
spelling.

## 7. The stages

- F1 - indentation and line breaks (done).
- F2 - spacing inside a line and case (done).
- F3 - the default tuned against the RTL and VCL by the edit rate above.
- F4 - the demo: Format (Ctrl+D) and Format Selection through the editor's
  undo, the options in its settings.
- F5 - wrapping at a right margin and alignment; off by default.
- F6 - range mode, include files formatted as themselves, and the
  compile-compare gate over every corpus.
- F7 - the `.dcu` interface source formatted with the host's options
  (done in the library): `TPasSourceManager.DcuTextFilter` is what every
  generated text goes through before anything reads it - a host sets it to
  `PasFormatText` with its options - and `LoadFileTolerant`'s overload
  takes the same filter, so a tab that opens a compiled unit shows the text
  the analysis ran on and navigation lands where it should. `PasFormatText`
  formats a text of its own, parsed with no symbol defined: for generated
  code. Setting the filter forgets the texts generated before it; a filter
  that raises leaves the text as generated. The generator's own layout is
  already near the default (six Studio units: 5.4% of lines moved, all of
  it the indentation of types nested in a class), so the filter matters
  for a style of the user's.
- F8 - the LSP server (`textDocument/formatting`, `rangeFormatting`), the
  IDE plugin's options page, the MCP server.
