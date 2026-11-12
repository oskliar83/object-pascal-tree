# The formatter

`source/PasTree.Format.pas` lays out a unit by a style: indentation, line
breaks, spacing, case, wrapping and alignment. It is built in stages; this
document says what each stage does, what it keeps as written, and how it
is proven safe. Done in the library: F1 (indentation and line breaks), F2
(spacing inside a line, case), F3 (the default tuned against the RTL), F5
(wrapping at a right margin, alignment - both off by default), F6 (range
mode, include files, the compile-compare mode) and F7 (the generated .dcu
source); the stages are listed at the end.

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
  removes a line break the author wrote (but blank lines over the cap), and
  forces none before a token whose line holds only comments before it and
  starts with one (`{class} function F;`: the line is already the token's).
  The spacing inside a line is F2's.
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
  author's alignment (`toEOF     = Char(0);`), and so are two or more
  spaces before a `:` (`Name    : Type`) - alignment (F5, sec. 2b), when
  on, owns those gaps. Where none is asked for, the gap shrinks to nothing only
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

## 2b. What F5 decides (off by default)

**Wrapping** (`WrapLongLines`, `RightMargin`). A line whose CODE ends right
of the margin - a comment after it is not measured: breaking code because
of its comment moves the comment, not the problem - is broken at its best
point, and what is left of it again, until it fits or no point is left:

- the points: after a `,` of a list (an argument, parameter, index, set,
  enumeration, uses, case-label, variable-name, attribute list) or a `;` of
  a parameter list; after a binary operator; after `:=`;
- the best one: of the points that leave the line before them inside the
  margin, the shallowest (fewest open `(` / `[`), then a list's separator
  before an operator and a relational operator before an additive before a
  multiplicative one, then the rightmost; `:=` only when nothing else will
  do. When no point fits, the leftmost of the best - the first piece is as
  short as it gets;
- the new line: one `IndentStep` right of the line its statement or
  declaration starts on (never left of the line being broken, an author's
  continuation aligned under its `(`); a uses item at its uses list's
  column.

Read off the Studio RTL and VCL (1.7M lines, crude census): of the lines
that end in `,` inside an open `(`, the next line is one step (2) right of
the line 2,866 times, under the `(` 271, four right 55 - so a step. And a
broken expression keeps its operator at the END of the line 4,041 times, at
the start of the next 795 - so the break goes after the operator (the brief
of the stage had asked for before; the corpus decided). Measured over the
same corpus, 91% of the lines are within 80 columns and 2.3% beyond 120:
`RightMargin` is 0 (no wrapping) by default and 120 is the margin the tools
use when wrapping is on.

Never wrapped: a line with a directive, an inactive branch, asm, a flagged
unit, a caret character (`^M`, spec B.6.2), an item over several lines
(a block comment, a multiline string) or a tab in it; inside a literal, type arguments or generic parameters, an
anonymous method written on one line; before a caret. Wrapping only ADDS
line breaks: F1's rule that an author's break is kept stays, and a line no
point can shorten is left long.

Idempotence is by construction: the column a wrapped line gets is the one a
later format reads back for it (a continuation keeps its offset from its
unit's first token, CodeCol), the breaks are added until a pass adds none
(a wrap can move what follows - an anonymous method's body), and the margin
is measured with every gap alignment owns at its rule width - so a format
of the result, whose gaps hold the padding, finds the same lines too long.

**Alignment**, each option alone, over GROUPS: consecutive output lines, each
holding one unit of one kind under one parent, written on that line alone
(its `;` and comments after it allowed); a blank line, a comment line, a
unit over several lines or another kind ends a group. In a group of two or
more the aligned token goes one column right of the longest text before it
on the group's lines; a unit in no group keeps F2's rule (several spaces
the author wrote stay).

- `AlignAssignments`: the `:=` of assignments in one statement list.
- `AlignDeclColons`: the `:` of variable and field declarations and typed
  constants, the `=` of constants and types, down one section or member
  list (`=` and `:` never in one group). A `:` touches the longest name
  when every name of the group is as long - `X: Integer` / `Y: string` stay
  - and otherwise stands one right of it, the RTL's own aligned shape
  (`time_zone_minutes : int16_t` / `year              : uint16_t`).
- `AlignTrailingComments`: the comment after the last code of a line, on
  consecutive code lines of one indentation - a line with no comment of its
  own keeps the group going - one column right of the longest code that
  carries one. A trailing comment alone keeps its gap.

Measured (Win64 defines; `tools\PasTreeFormat <dir> -wrap -align`, and
`-wrap:80 -align`): G-tok, G-idem, G-tree 0 failures over the self-host
(33 clean files), Studio `rtl` (559), `vcl` (118), `fmx` (324), each with
wrapping alone, alignment alone, both, and both at margin 80. Lines longer
than 120 before / after `-wrap` (comments counted, which wrapping does not
measure): self-host 3 / 3, rtl 36,260 / 19,638, vcl 712 / 228, fmx 14,064
/ 827. What stays long (sampled over the rtl): comment text - a long
`//` line, code commented out inside a block comment -, a literal, a line
with a tab, and declarations with no point to break at: a routine header
with one parameter (the generated WinRT units), `class(TGeneric<A, B>)`
(type arguments are never broken). Alignment alone adds 9,282 spacing
edits over the self-host's 115,470 lines and 102,234 over the rtl's
1,230,840. With the default
options the edits are those of 0.178 to the edit.

Not aligned: the lines wrapping never touches (above). Alignment may push
a line past the margin; wrapping does not chase it
(see idempotence).

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
B.2.2: a directive's name). F5 inserts a line break into a gap between two
code tokens of different nodes, never next to a comment or a directive,
never inside a literal, never before a caret - B.2's "line breaks between
tokens" - and alignment widens a gap that is already one between two
tokens of different nodes (before `:=`, `:`, `=`, a trailing comment) on
a line with no caret character.

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

Measured after F3 (default options, Win64 defines):

| corpus | clean files | lines | edits | of them: indentation / break added / blank lines / spacing / case | G-tok, G-idem, G-tree |
|---|---|---|---|---|---|
| self-host `source\` | 33 | 114,893 | 2,154 (1.9%) | 1,686 / 310 / 1 / 157 / 0 | 0, 0, 0 |
| Studio `rtl` | 559 | 1,230,840 | 52,964 (4.3%) | 24,372 / 2,372 / 349 / 25,368 / 503 | 0, 0, 0 |
| Studio `vcl` | 118 | 329,132 | 18,576 (5.6%) | 9,620 / 4,209 / 26 / 3,867 / 854 | 0, 0, 0 |
| Studio `fmx` | 324 | 472,882 | 9,664 (2.0%) | 7,017 / 468 / 80 / 1,985 / 114 | 0, 0, 0 |

**F3, the default tuned against the RTL and VCL.** `tools\PasTreeFormat
-hist` counts every edit by its kind and the words around it; the rules a
large count pointed at, and what each turned out to be:

- 43,146 line breaks before a member after a comment that starts its line
  (`{class} function F;`, `{class} property P` - the RTL's generated WinRT
  units mark each member so): a forced break is not inserted when only
  comments stand before the token on its line and the line starts with one
  of them - the line is already the token's. The RTL's added breaks fell
  from 46,896 to 2,372, its edit rate from 8.2% to 4.6%.
- 3,287 spaces removed before a `:` aligned down a declaration list
  (`Name    : Type`): two or more spaces before a `:` are kept, as several
  are where one is asked for.
- Anonymous-method bodies written under their `procedure` when it does not
  start its line (`EnumByCategory(procedure(...)` with `begin` below
  `procedure`): the body stays under it; otherwise one step in from the
  line.
- A directive less than one step off the code it introduces snaps to the
  code's column (a one-space slip, not a nesting).

What remains is the default style itself: one-line `if C then Exit;` split
(about 11% of the RTL's `then` have their statement on the same line), a
space after the `,` of a hex list in a generated GUID, `var X: T;` on one
line split, and the RTL's own unevenness - a `for` under an `if` with no
indent, a one-space indent in a Windows header - put right.
**G-dcc** (stage F6): a formatted unit must compile to the same code. Not
to a byte-identical `.dcu` - a `.dcu` records each routine's line under
every switch (spec B.2, probed) - so the compile-compare harness judges the
formatter by the dump: `tools\fidelity.ps1 -Mode tf` compiles the original
and the copy `PasTreeXform -mode:tf` writes under `-$O- -$D- -$L- -$Y-
-$C-` - assertions off, because `Assert` passes its line as a constant and
so its code follows the lines too (spec B.2) - and a raw difference with
equal dumps (every routine's code and data bytes, its fixups, the
declarations) is `OK  lines`. Over the self-host 33 of 33 units, over the
Studio RTL's Win64 units (`BuildWinRTL.dpk`) 309 of 309 that compile on
their own are OK; with assertions on, 15 RTL units differed - each in a
routine holding an `assert`, which is what found the rule. With the F5 options
on (`fidelity.ps1 -Mode tf -FmtOpts wrap=80,align`, and `wrap,align`) the
self-host is again 33 of 33 OK (spec B.2, 99400e7).

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

F5, all off by default: `RightMargin` (0: none; 120 the tools' margin when
on) with `WrapLongLines` (False), `AlignAssignments`, `AlignDeclColons`,
`AlignTrailingComments` (False).

## 6a. The style of a project (F9)

`PasFormatTally` and `PasInferFormatOptions` read the options a set of files
is written in - what sec. 5 did by hand for the RTL, for any project.

**The formatter is the judge.** Counting the edits each value would make
cannot decide most options: their "off" keeps the text as written and always
costs nothing. So a tally run formats a file with every rule on, and at each
place a rule decides - a break `ForcedUnit` / `ForcedCloser` forces, a gap
`SpaceRule` sets, a word `ItemText` spells, a group alignment would line up -
notes the rule and whether the text already reads that way. A sample is
therefore exactly the rules the formatter applies, and a rule added later is
measured the same way. A break no option decides (`case` selectors, `except`
parts) is no site; asm, skipped regions and flagged units count nothing.
Alignment counts only a group whose texts end at different columns (a group
already even says nothing), agreeing when its tokens stand at one column.

**The decision.** A rule on at 90% of its sites or more, off at 10% or less;
between, off and marked mixed - the formatter then keeps the text, the one
choice that is right for both halves. A word class lower or upper at 90%,
else as written; alignment on at 60%. The indent step (2, 3, 4) and nested
routines' indentation are measured black-box: the pair that re-indents the
fewest lines when nothing else changes. The blank-line cap is the smallest
that 99% of the runs of blank lines fit under; the right margin the smallest
of 80, 100, 120 that 99.5% of the lines fit in, wrapping on with it. Fewer
than 20 sites (alignment 10) keep the default; `TabWidth` and the column-1
options keep theirs, since they keep text and never change it.

**Read against sec. 5** (`tools\PasTreeFormat -infer`, which prints each
option with its evidence and the default it differs from):

| corpus | differs from the default | evidence |
|---|---|---|
| Studio RTL (559 units) | `ElseOnNewLine`, `StatementAfterThenDo` off, mixed | each agrees at 89.8% - just under the bar |
| Studio VCL (118 units) | `StatementAfterThenDo` off, mixed; `MaxBlankLines` 1; margin 120 with wrapping | 83.5%; 274 of 28,188 blank runs longer; 712 of 300,096 lines over 120 |
| this repository (33 units) | `MaxBlankLines` 1; margin 80 with wrapping; trailing comments aligned | 15 of 4,222 runs longer; 548 of 111,369 lines over 80 |

Everything else - step 2, nested routines indented, `begin` alone, one
statement and one declaration per line, every space rule, lower-case words
and upper-case directive names, no alignment of `:=` or `:` - comes out as
the hand-read default. A tally formats a file seven times (the tally run and
three steps by nested routines on and off): the RTL's 1.1M lines in a
minute, so a host samples a large project (pastree-lsp samples within a
time budget).

## 7. The stages

- F1 - indentation and line breaks (done).
- F2 - spacing inside a line and case (done).
- F3 - the default tuned against the RTL and VCL (done, sec. 4).
- F4 - the demo: Format (Ctrl+D) and Format Selection (Ctrl+Shift+D) in the
  editor's context menu, through the editor's undo, the options in its
  settings (`[Format]`). Done in 0.175.1, merged in 0.178.1 -
  `docs/editor-features.md` sec. 14.
- F5 - wrapping at a right margin and alignment, off by default (done in
  0.179.0, sec. 2b). `tools\PasTreeFormat -wrap[:N] -align` runs the gates
  with them on, `PasTreeXform -fmtopts:wrap[=N],align` (`fidelity.ps1
  -FmtOpts`) the compile-compare mode.
- F6 - range mode, include files, the compile-compare gate. Done in the
  library: `PasFormatRangeEdits` keeps the edits of a selection - a gap's
  by the token after it - computed over the whole file, so a range formats
  exactly as a whole-file format would there; `PasFormatEdits` with an
  include's file id formats that file as itself, laid out by the
  includer's tree (its first line keeps its column - the includer decides
  where it stands); `tf` is the compile-compare mode (sec. 4).
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
