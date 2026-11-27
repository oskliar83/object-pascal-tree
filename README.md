# PasTree

**An error-tolerant, multithreaded Object Pascal parser and semantic analyzer -
source in, a full-fidelity syntax tree and a project-wide symbol model out -
and the editor services built on that model: navigation, the Find All family,
completion, rename, lint, a formatter.**

PasTree parses Delphi sources (`.pas`, `.dpr`, `.dpk`, with full `.inc`
support), resolves and type-checks a whole project's `uses` closure the way
`dcc` does, and answers editor questions over the result. It targets the
language as implemented by **Delphi 13.x Florence** and specified by
[object-pascal-spec](https://github.com/oskliar83/object-pascal-spec) - the
companion specification this parser is built from, every rule in it checked
against the compiler.

It is a library. Three hosts use it:

| Host | What it is |
|---|---|
| `demo/` (this repository) | `PasTreeDemo`, a VCL editor (SynEdit + VirtualTreeView) that behaves like a slice of the RAD Studio IDE - the place every feature is exercised first |
| [pastree-lsp](https://github.com/oskliar83/pastree-lsp) | a Win64 Language Server Protocol server, with a RAD Studio IDE package and a VS Code extension as its clients |
| [pastree-mcp](https://github.com/oskliar83/pastree-mcp) | an MCP server giving an AI coding agent a semantic index of a project group: references, callers, impact, rename, compile |

> **Status.** Lexer, preprocessor, parser and semantic layer work end to end
> over real projects - the Delphi RTL/VCL/FMX and applications of several
> thousand units - with **zero false diagnostics** on every corpus measured
> (see [How it is checked](#how-it-is-checked)). Analysis is asynchronous and
> incremental, and library code can be analyzed interface-only. Where PasTree
> knowingly follows the language less far than the spec describes is listed
> in [`docs/coverage.md`](docs/coverage.md); the work still open is in
> [Open work](#open-work).

## What it does

1. **Parses** a unit into a full-fidelity syntax tree. Every token and every
   piece of trivia (comments, whitespace, disabled `{$IFDEF}` regions) is
   kept, so tokens + trivia reconstruct the source byte for byte. Parsing
   never fails: malformed input produces error nodes and diagnostics.
2. **Resolves** a project's whole `uses` closure into a symbol model: scopes,
   cross-unit references, overload resolution as `dcc` ranks it, generic
   instantiation, helpers, `with`, `$IF Declared(...)`, the implicit `System`
   unit and the compiler intrinsics - closely enough to reproduce `dcc`'s
   precedence and its `E2xxx` diagnostics. Units that ship without source are
   read from their `.dcu`, or from inside a package's `.dcp`.
3. **Answers editor questions** over that model - go to declaration, the
   decl/impl toggle, references, overrides, implementations, completion,
   rename, unused code - from resolved symbol identity, never from text
   search or heuristics.
4. **Edits source** without changing the program: rename (form files
   included), the formatter, and removal of unused `uses` entries and
   declarations, each layout-preserving.

## Error-tolerant is the primary mode

An editor parses broken code all day, so PasTree's default is to analyze
whatever it is given and to report only what it can prove. Strict checks
that could only add diagnostics ship as **opt-in switches**, never as
replacements: `ReportUnresolvedMembers` (an unresolved member after a dot,
CLI `-members`) and `ReportVisibility` (`E2361`/`E2362`, CLI `-visibility`).
Off, the analysis is byte-identical. The demo turns them on, because its job
is to show what the analyzer still gets wrong; a library host inherits the
quiet default.

Every diagnostic PasTree emits is one `dcc` would give, with its code and its
wording. A `dcc` probe settles each rule, and a check ships only when it adds
no report across the corpora.

## Architecture

```
+--------------------------------------------------------------+
| 1. SourceManager  files, encodings, overlay buffers, .inc     |
|                   resolution, .dproj/.dpk, .dcu/.dcp reading  |
| 2. Lexer          text -> flat token array (with trivia)      |
| 3. Preprocessor   $IFDEF/$IF, $I splicing, option state       |
|                   -> visible token stream                     |
| 4. Parser         recursive descent + Pratt expressions       |
|                   -> homogeneous, index-based AST             |
| 5. Sema           per-unit scopes -> cross-unit resolution -> |
|                   typing -> overloads/generics -> diagnostics |
| 6. Services       Nav, Complete, Lint, ImportGraph, Format,   |
|                   UsesEdit, SymbolEdit; Workspace on top      |
+--------------------------------------------------------------+
```

Data model: tokens and nodes are records in contiguous per-unit arrays;
references are integer indices, not object pointers. A unit's tree is
immutable once built, which is what makes the parallelism below safe and
lets an unchanged unit's parse be reused across analyses.

## Multithreading

Parsing and analyzing a unit is a pure function `(text, defines) -> model`, so
a project's closure fans out across cores:

- **Parse + per-unit phase** run one worker per core over every file of the
  closure; results register back in input order, so model ids are
  deterministic.
- **Cross-unit passes** split into a parallel *compute* step (workers only
  read other units' finished maps) and a sequential *commit* step. The few
  structures that need a lock (the generic-instance cache, the hydration
  stripes) are guarded explicitly.
- **One model per grab** (`ForEachIndex`): workers take one index at a time
  from a shared counter. `TParallel.For`'s growing chunks left one worker
  with hundreds of consecutive models while the others idled.
- A `SingleThreaded` switch runs every stage on the calling thread, for
  timing baselines and debugging; results are identical.

### What every host must do

```pascal
System.NeverSleepOnMMThreadContention := True;   // before analyzing
{$MAXSTACKSIZE $01000000}                         // in the program's .dpr
```

- **`NeverSleepOnMMThreadContention`** is a process-wide memory-manager mode
  the application owns, so the library cannot set it. With the default, the
  memory manager *sleeps* on lock contention, and every pass here is
  allocation-heavy: measured on a 3,757-unit project, 15.4 s with the flag,
  70.3 s without - slower than a deliberately single-threaded run (44.7 s),
  with CPU time going *down*. A slowdown concentrated in the
  allocation-heavy stages with less CPU means this flag. The LSP server once
  shipped without it and lost 4.5x.
- **A 16 MB stack.** Pool workers get the stack size from the executable's
  header, so only the host's program file can raise it. Deep shapes
  (operator and `else if` chains) are walked in loops; the reserve is for a
  recursion nobody has met yet. An overflow is caught where a unit's load or
  a pass absorbs failures; a host that catches an analysis exception itself
  and lets its thread go on calls `PasRecoverStackOverflow`
  (`PasTree.Types`), because Windows does not restore the spent guard page.
- **Call analysis from outside the thread pool** - the main thread, a
  `TThread`, or through `TPasAsyncSession`. The pool's width is pinned
  (`ConfigureThreadPool`, logical cores, never below 2) because, left to
  grow, it mistakes allocation spinning for blocking and adds threads until
  the same work costs several times the CPU; a pinned pool cannot rescue a
  task that waits on another queued task. From a `TTask` or a
  `TParallel.For` body an `Analyze*` raises `EInvalidOperation` instead of
  hanging. The cancel predicate is called by pool workers concurrently and
  must be thread-safe.

## Analysis in a live editor

- **Asynchronous** (`TPasSemaProject.AnalyzeStaged`, `TPasAsyncSession`): the
  whole pipeline runs on a background thread, the host polls a progress
  snapshot (`phase done/total`) and swaps the finished project in on its own
  thread while the previous one stays usable. Cancellation is cooperative and
  lands mid-pass. Overlay buffers carry the host's version stamp, so a result
  computed from older text is recognizable. Nothing may read a project while
  a thread analyzes it.
- **Incremental** (`docs/incremental-analysis.md`): a rebuild adopts the
  previous project as a *parse donor* and reuses every unchanged unit's
  tree; an edit inside a module is reanalyzed alone
  (`AnalyzeModuleOnly`, `TPasAsyncSession.CreateForModule`) - tens of
  milliseconds against a multi-second rebuild - with name-level selection of
  the consumers that must be redone, and a guard that refuses the fast path
  whenever it cannot prove the result equals a full build. A differential
  harness (`tools\PasTreeDiffHarness`) is the proof.
- **Light library units** (`TPasSemaProject.LightPaths`,
  `docs/library-light-mode.md`): the host names the directory trees of
  somebody else's code (RTL, VCL, third-party), and those units are analyzed
  interface-only while the project's own units bind exactly as before - on a
  3,782-unit closure 3.1 -> 1.8 s and 2.3 -> 1.2 GB. Every query declares
  which library bodies its answer needs; a `TPasWorkspace`
  (`PasTree.Sema.Workspace`) promotes them (or rebuilds in full when that is
  cheaper) inside the query, so the answer is always the full analysis's.
- **Memory dial**: `DemoteText` frees the token layer of units a host does not
  keep open; they rehydrate on first touch in about a millisecond.

## Features

The library's services, each exercised in the demo and exposed by the LSP and
MCP servers. `docs/editor-features.md` is the per-feature specification.

**Navigation**
- Go to declaration: local and cross-unit names, members through
  inheritance, generics, aliases and helpers, intrinsics (routed to
  `System.pas`), `uses` names, unit namespaces and aliases, `$I` file names.
- Declaration/implementation toggle, overload-precise.
- Go To: a unit outline and a project-wide symbol picker (`PasTree.Outline`,
  `TPasNavigator.ProjectOutline`).
- Conditional symbols as a fourth identity beside symbols, units and
  builtins: references and definitions of a `$DEFINE` name, the defines and
  the compiler options in effect at the cursor.

**Find All** (`TPasNavigator`) - each from resolved identity, across the
closure:
- References (code and `.dfm`/`.fmx` form files), Overrides (a VMT slot from
  any of its links), Implementations (of an interface method, or the classes
  implementing an interface), Descendants, Assignments, Creations,
  Destructions.

**Completion** (`PasTree.Sema.Complete`): member and identifier completion
over the live text, signature help, visibility rules as `dcc` applies them
(the unit friend rule, `protected` by expression type).

**Rename** (`PlanRename`, `PlanUnitRename`): every reference project-wide,
with the method's family - overrides, implementing interface methods and the
methods a bare `inherited` ties together - and the form files' handler and
component lines. A library or read-only file, a compiler builtin, or an
ambiguous family is refused whole, with the reason.

**Semantic highlighting**: `SemanticTokens` drives a SynEdit highlighter
(`TPasTreeSynHighlighter`) from PasTree's own lexer and tree - context
keywords lit only where they are directives, types coloured as types,
inactive `$IFDEF` code greyed out.

**Lint and dead code** (`PasTree.Sema.Lint`):
- Unused `uses` entries, entries needed only in the implementation, and the
  project units nobody uses (`FindUnusedUses`, `FindUnreferencedUnits`) -
  with what may make a removal wrong said on the row.
- Unused declarations, interface members, parameters and locals, and a
  library's exported API no host uses (`FindUnusedSymbols`).
- The edits that remove both, layout kept (`PasTree.UsesEdit`,
  `PasTree.SymbolEdit`).

**Import graph** (`PasTree.Sema.ImportGraph`): through which units a program
takes a unit in, the units every path goes through, and the `uses` entries
whose removal alone drops it.

**Formatter** (`PasTree.Format`, `docs/formatter.md`): keeps every original
token and lays out only the whitespace between them - indentation, line
breaks, spacing, case, optional wrapping and alignment, a range mode, and
style inference from existing code. Proven not to change the program: the
same tokens, idempotent, the same tree, and the same code under `dcc`.

**Units without source** (`PasTree.Dcu`, `PasTree.Dcp`, `docs/dcu-reader.md`):
a unit with no `.pas` on any path is read from its `.dcu` (Delphi 11 to 13,
Win32 and Win64), or from the `.dcp` of a linked package, printed as an
interface-only unit and analyzed like any other; navigation lands in that
generated text.

**Project loading**: `.dpr`, `.dpk` or `.dproj` (a bare main source redirects
to its sibling `.dproj`). A `.dproj` is evaluated as MSBuild would -
environment variables and the reserved `MSBuildProject*` properties defined,
names case-insensitive, a package's `.dcp` references read as its
`Requires`. The IDE's own library and browsing paths come from the registry.

## How it is checked

**Definition of done (v1)** - all five reached:

1. Lexes and parses the entire Delphi 13 source tree with zero errors.
2. Round trip: tokens + trivia == the source, byte for byte.
3. Golden AST tests keyed to the spec's feature numbering.
4. **Zero false-positive diagnostics** - on the flattened RTL+VCL+FMX corpus,
   the `BuildWinRTL`/`VCL`/`FMX` packages, two real applications (about 3,750
   and 2,100 units) and a third-party library's packages, under the opt-in
   member check too.
5. **The tree is the compiler's.** Over the self-host and the Studio source,
   every rewrite computed from the tree - the preprocessor's decisions
   written out, every operator parenthesized, every statement wrapped in
   `begin`/`end`, the unit reprinted from its tree alone, every name written
   as the declaration the analysis bound - compiles under `dcc` to a
   byte-identical `.dcu`. Method, blind spots and open findings:
   `docs/parser-fidelity.md`; held by `tools\fidelity-gate.ps1`. What a
   consumer may read from the tree: `docs/tree-contract.md`.

Beyond that, oracles built on the real compiler: overload choice checked on a
`dcc` grid of over 25,000 argument cases, rename and completion oracles
(`tools\PasTreeRenameOracle`, `tools\PasTreeCompleteOracle`), and a corpus of
programs proven by `dcc` for the unused-code rows.

## Start from the spec

[object-pascal-spec](https://github.com/oskliar83/object-pascal-spec) is the
reference this parser is written against, not documentation written after
the fact. For every change to parser, resolver or typer behaviour:

1. **Read** the governing section first (a name lookup of any kind:
   sec. 3.3.2, name resolution order).
2. **Note** where it is silent or disagrees with the code.
3. **Probe `dcc`** for that gap or disagreement - not to rediscover what the
   spec already states.
4. **Write the code.**
5. **Write back** what the probes settled, with the probe's shape as the
   evidence.

The spec is evidence, not scripture: when it and `dcc` disagree, `dcc` wins
and the spec is corrected. A fix that needs more cases than the spec has
rules is patching symptoms - sec. 5.7 states one rule for a `with` target,
while the code once grew a case per shape.

## Performance discipline

Every change ships with a timing run, not only a correctness run. Diagnostic
counts do not detect a slowdown: a defensive call added to the hottest lookup
once cost 3.3x total analysis time and passed every test.

- Read the per-stage line (`stages:`), not the total.
- Best of several runs, against the *preceding commit* rebuilt in the same
  session - a number from yesterday may itself contain a regression.
- Measure **single-threaded** (`-st`, the CPU each stage costs) **and
  multi-threaded** (interleaved A/B runs on a frozen copy of a real closure).
  The two answer different questions: a global lock that serialized a
  parallel pass was invisible single-threaded and shipped for 25 versions.
- When a count moves, the full dump should be byte-identical unless the
  change was meant to alter resolutions.
- Build with range checks (`-$R+ -$Q+`) before believing a flaky number: an
  out-of-range index reading adjacent memory once presented as
  non-determinism.
- Say the honest size in the commit message, including "inside the noise".

## Versioning

`PasTreeVersion` lives in `source/PasTree.Version.pas`, a unit that pulls in
nothing else, so a consumer can report it without linking the analysis.

- **Every commit bumps the PATCH**, mechanically.
- **A new capability or public API bumps the MINOR** and resets the patch.

A version therefore identifies a build. The LSP server reports
`PasTreeVersion` in its `serverInfo`, and each consumer declares the oldest
version it works with (`cMinPasTreeVersion` in the server). Such a floor can
name a patch: a resolver fix is a patch here and still a hard requirement
there.

## Building and testing

- **`tests\build.bat`**, run from `tests\`, builds and runs every suite and
  must end with `all suites passed`. The suites are Win32 by design (unit
  suites over fixtures); three link demo units through relative paths and
  compile only with that working directory.
- **Everything else is Win64** (`dcc64`): `demo\build.bat` and the `tools\`.
  A real project's closure holds more than 3 GB, and a Win32
  `EOutOfMemory` masquerades as an analyzer defect - every unit that fails to
  load gates its importers' diagnostics.
- Every `.dcu` goes to `out\dcu\win32` or `out\dcu\win64`, never beside a
  source.
- A new demo unit goes into both `PasTreeDemo.dpr` and `PasTreeDemo.dproj`:
  the scripts and the IDE build from different files.

## Layout

| Path | Contents |
|---|---|
| `source/` | the library. Front end: `PasTree.Types`, `SourceManager`, `Lexer`, `Preprocessor`, `CondEval`, `Ast`, `Parser`, `Project`, `DProj`, `Platforms`, `Dcu`, `Dcu.Source`, `Dcp`, `Dfm`. Tree tools: `Ast.Json`, `Ast.Check` (tree invariants), `Printer` (the structural printer), `Outline`, `Format`, `UsesEdit`, `SymbolEdit`. Semantic layer: `PasTree.Sema.*` - `Model`, `Resolver`, `Types`, `Project`, `Builtins`, `Diagnostics`, `Nav`, `Complete`, `Lint`, `ImportGraph`, `Dfm`, `Workspace`, `Async`, `Dump`; `WordIndex`; `Version` |
| `demo/` | `PasTreeDemo`, the VCL host (Win64) |
| `tests/` | the smoke suites (`ParserSmoke`, `ResilienceSmoke`, `StagedParseSmoke`, `DProjSmoke`, `SemaSmoke`, `SemaTypeSmoke`, `SemaXTypeSmoke`, `SemaOverloadSmoke`, `ConvSmoke`, `SemaProjectSmoke`, `SemaNavSmoke`, `SemaCompleteSmoke`, `DfmSmoke`, `AsyncSmoke`, `DcuSmoke`, `FormatSmoke`, `UsesEditSmoke`, `SymbolEditSmoke`, `UnusedScenarioSmoke`, `UnitListSmoke`, `NavHistorySmoke`, `DemoSettingsSmoke`), golden JSON trees, `build.bat` |
| `tools/` | CLI drivers per stage (`PasTreeLex`, `PasTreePP`, `PasTreeParse`, `PasTreeJson`, `PasTreeSema`, `PasTreeSemaProject`); checks (`PasTreeTreeCheck`, `PasTreePrint`, `PasTreeFormat`, `PasTreeDcu`, `PasTreeDiffHarness`, `PasTreeLightSmoke`, `PasTreeNavSweep`, the rename and completion oracles, `KindsCheck`); the compile-compare harness (`PasTreeXform` rewrites, `fidelity.ps1`, `fidelity-gate.ps1`) |
| `docs/` | `editor-features.md` (the feature specification), `coverage.md` (where PasTree is narrower than the language), `incremental-analysis.md`, `library-light-mode.md`, `parser-fidelity.md`, `tree-contract.md`, `formatter.md`, `dcu-reader.md` |
| `out/` | build output (`.dcu` per platform); safe to delete |

### Line endings

`.pas`, `.dpr`, `.dpk`, `.inc`, `.dproj`, `.dfm` and `.bat` are **CRLF** in a
working copy; docs, shell scripts and JSON are LF (`.gitattributes`, the same
in `pastree-lsp`). An LF write - `sed -i` and `perl -pi` in Git Bash produce
one - goes unnoticed until RAD Studio re-saves the file and the next diff is
the whole file, and `cmd.exe` can misparse an LF-only `.bat`.
`.githooks/pre-commit` refuses such a commit
(`git config core.hooksPath .githooks`); check with `git ls-files --eol`.

## Open work

Language gaps are in [`docs/coverage.md`](docs/coverage.md), keyed by spec
section. Beyond them:

- **PasTree's own warnings.** Every diagnostic today is one `dcc` gives as an
  error. `dcc`'s warnings (`W10xx`), and checks of PasTree's own in a range
  that cannot be mistaken for `dcc`'s - a unit pinned `in` a file that does
  not exist, a unit found twice on the search path with the later copy
  shadowed, a `.dproj` and a `uses` clause that disagree - would be warnings
  and hints, never errors.
- **A package's `requires` closure for search paths.** A `.dpk` can reach
  units through the search paths of a package it requires, which `dcc`
  resolves through the required `.dcp`; reading the required project's paths
  would remove that last class of honest `F1027`.
- **Project groups in the demo.** `pastree-mcp` reads a `.groupproj`; the demo
  opens one project and shows its units as a flat list.
- **Live diagnostics in the demo editor** (underlines by severity as the
  analysis re-runs); the LSP clients have them.
- **Generate a method body from its declaration** (class completion).
- **The overload chain inverted** (`PrevOverload`, nearest declaration
  first) - fewer special cases where a name's meaning is "the nearest one",
  worth doing only if it is no slower and the special cases really go.

## Requirements

- Delphi 13.0 Florence or later (the parser is written in the language it
  parses).

## License

[MIT](LICENSE) © 2026 Oleksandr Skliar.

PasTree is an independent open-source project, not affiliated with or
endorsed by Embarcadero Technologies. "Delphi" is a trademark of Embarcadero
Technologies, Inc.
