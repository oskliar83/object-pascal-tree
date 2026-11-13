unit PasTree.Sema.Complete;

{
  PasTree editor features - code completion, stage A: the caret primitive.

  Everything the completion engine will do starts with one question the
  existing navigator deliberately refuses to answer: "where does this caret
  SIT, lexically and semantically, in a buffer that is mid-keystroke?"
  TPasNavigator.IdentAt requires an exact identifier hit (the right contract
  for ctrl+click, the wrong one for typing), and nothing anywhere maps a
  position to the innermost AST NODE - NodeOfVis covers nkIdent nodes only.

  This unit answers it. Given (line, col) over ONE analyzed model, CaretAt
  classifies the position (a prefix being typed / right after a dot / a fresh
  empty-prefix spot / no completion here) and anchors it to a raw token, a
  visible token, the innermost node whose span contains it, and the scope in
  effect there (NodeScope, parent-climbed). Later stages build the candidate
  collection on top; nothing here decides WHAT to offer.

  Contract, same as the navigator's: positions refer to the model's text AS
  ANALYZED. The completion pipeline satisfies it by parsing the CURRENT
  buffer into a fresh overlay model per request (the demo highlighter's
  proven per-keystroke path), so "as analyzed" and "as typed" are the same
  text; a caller that aims this at a stale project model gets stale answers,
  not errors. Main file only (FileId 0), like IdentAt - a caret inside an
  opened $I include is the same GAP navigation already has.

  Two parser facts this unit leans on (see PasTree.Parser):

  - `Foo.` always yields a LIVE nkMember node whose FirstToken is the DOT and
    whose first child is the base expression, even when the member name is
    missing - so the base of a dot-completion is FirstChild, never a text
    scan backward.
  - That same recovery will happily adopt an identifier from the NEXT LINE as
    the member name (`Foo.` + newline + `Bar := 1;` parses as `Foo.Bar`).
    Harmless here by construction: the base is still FirstChild, and a
    stolen name can never become the PREFIX because a prefix requires the
    caret to sit inside its own token.
}

interface

uses
  System.Generics.Collections,
  PasTree.Types,
  PasTree.Preprocessor,
  PasTree.Ast,
  PasTree.Sema.Model,
  PasTree.Sema.Project;

type
  TPasCaretKind = (
    ckNone,      // no completion at this position: dead ($IFDEF'd-out) code,
                 // the interior of a comment/string/number literal/asm chunk,
                 // or nothing before the caret at all
    ckIdent,     // caret inside or at the right edge of an identifier or
                 // reserved word - a prefix being typed
    ckAfterDot,  // nearest visible token at/before the caret is a `.` and no
                 // prefix has been typed yet - member position, empty prefix
    ckFresh      // any other token precedes the caret - an empty-prefix
                 // position (statement start, after `:=`, after `uses`, ...)
  );

  TPasCaretInfo = record
    Kind: TPasCaretKind;
    { The lexical anchor: for ckIdent the prefix token itself; for ckAfterDot
      the dot; for ckFresh the nearest visible token at or before the caret.
      Raw index into Files[0]; -1 for ckNone. }
    RawToken: Integer;
    VisToken: Integer;   // the anchor's visible-stream index; -1 for ckNone
    Node: Integer;       // innermost node whose span contains VisToken
    Scope: Integer;      // scope in effect at Node; NIL_SCOPE for ckNone
    Routine: Integer;    // innermost enclosing nkRoutine node; NIL_NODE
    { The typed prefix: the anchor identifier's text UP TO the caret (so
      `Foo.Ba|zzz` filters on 'Ba'). '' unless ckIdent. }
    Prefix: string;
    { 1-based columns of the WHOLE anchor identifier on the caret's line -
      the range a host's completion replaces (mid-word invocation replaces
      the full word, the clangd behavior). For an empty prefix both equal
      the caret column. }
    PrefixColFrom: Integer;
    PrefixColTo: Integer;   // column AFTER the identifier's last character
    { The member-access BASE for a dot completion: the nkMember node's first
      child when the caret is after a dot (ckAfterDot), or when the ckIdent
      prefix's left visible neighbor is a dot (`Foo.Ba|`). NIL_NODE when the
      position is not a member access (including `end.` - the dot there
      belongs to no nkMember). }
    DotBase: Integer;
  end;

  { What kind of candidate list the position calls for. Decided from TOKENS
    and the (fresh) overlay AST around the caret, before any scope work. }
  TPasComplContext = (
    ccNone,        // no completion here
    ccMember,      // after a dot: members of the base designator's type
    ccUses,        // inside a uses clause: unit names
    ccType,        // a type is expected (after `:` in a decl, `= ` in a type
                   // decl, `class(`, `is`/`as`, `array of`, ...)
    ccStatement,   // statement/declaration head: names in scope + keywords
    ccExpression,  // inside an expression: names in scope + expr keywords
    ccRecField,    // a FIELD NAME in a record aggregate initializer (3.2.2):
                   // the record type's fields, nothing else
    ccInherited,   // right after `inherited `: the ancestor's members
    ccLabel,       // right after `goto `: the labels in scope
    // A property ACCESSOR position (13.1.1): after `read` / `write` in a
    // property declaration only a field or a method of this class (or an
    // ancestor) may stand - the collection is the struct chain alone, and
    // AddSym filters by SHAPE (fields always; functions for read,
    // procedures for write). Type compatibility is not filtered: a member
    // of the right shape and a wrong type stays listed, ranked last
    // (AccessorFit) - hiding near-misses helps nobody, and pastree-lsp's
    // class completion asks this list whether a name is already a member.
    ccPropRead,
    ccPropWrite,
    // After `stored`: the same struct chain, fields and functions, and
    // `True` / `False`.
    ccPropStored);

  { Where a candidate came from - the ranking bucket (sortText prefix in the
    LSP mapping; display grouping in the demo). Declaration order IS priority
    order: dedup keeps the first hit, so the enum mirrors resolution
    precedence (with > locals/struct > unit > uses > System > builtins). }
  TPasComplBucket = (
    cbMember,       // member completion (after a dot)
    cbWithMember,   // member of an enclosing with target
    cbLocal,        // params/locals of the enclosing routine chain
    cbStructMember, // Self context: own + inherited struct members
    cbUnitSym,      // this unit's interface/implementation names
    cbUses,         // used units' interface names
    cbSystem,       // the implicit System/SysInit units
    cbBuiltin,      // compiler-seeded names
    cbKeyword,
    cbUnitName);    // uses-clause candidates

  { How a candidate fits the type the position EXPECTS - the right side of
    `X := |` and of a comparison `X = |` (`<>`, `<`, `>`, `<=`, `>=`), whose
    left side is a designator the engine can type. Declaration order is the
    rank a host sorts by, ahead of the bucket: a value of the left side's
    own type first, then one assignable to it, then what may still lead to
    a fitting value through `.` `[` `(`, then what is proven wrong. Every
    item is cmOther where nothing is expected. }
  TPasComplMatch = (
    cmExact,        // the same type (after aliases)
    cmCompatible,   // assignable with evidence: a descendant class, a wider
                    // number, a Char for a string, `nil` for a reference
    cmLeads,        // may lead to it: a value with members (class, record,
                    // interface, a class reference), an array, a pointer, a
                    // procedural value, a type (`TFoo.Create`, a cast), a
                    // unit name, a function the engine cannot type
                    // (`Ord`, `Copy`, `GetValue<T>`)
    cmOther);       // proven wrong - a scalar, a string, an enumeration or
                    // a set of no fit - or nothing expected

  { LIFETIME: Name/Kind/Bucket/Overloads are plain values, but Mid/Sym/Ctx
    (and everything derived from them - ItemHeadWord, a host's SymDeclTypeX
    detail) are only meaningful while BOTH the overlay model (Mid = -1) and
    the project GENERATION this request ran against are alive. A host doing
    deferred resolution (LSP completionItem/resolve) must materialize what it
    needs before the next analysis swap, not hold (Mid, Sym) across it. }
  TPasComplItem = record
    Name: string;              // original spelling
    Kind: TSemaSymbolKind;     // skKeyword when Bucket = cbKeyword
    Bucket: TPasComplBucket;
    Mid: Integer;              // declaring model id; -1 = the overlay model
    Sym: Integer;              // NIL_SYM for keywords/unit names
    Ctx: Integer;              // instantiation frame (project members)
    Overloads: Integer;        // same-name routines collapsed into this item
    Match: TPasComplMatch;     // fit to the expected type; cmOther if none
    // Inside cmCompatible: how far the item's value converts to the
    // expected type, 0 nearest (TPasSemaProject.XConvDistX - a Double before
    // a Single before an Integer for a TDateTime; in an exception handler
    // and after `raise` Exception's nearer descendant) - and the context's
    // sub-rules (RankItems). A host orders by it after Match.
    Conv: Byte;
  end;

  { A type answer that may live in either space: the last-good PROJECT
    (X, a TSemaXType) or the OVERLAY being typed (OvSym, a type symbol of
    the fresh model) - or name a UNIT qualifier (UnitMid). IsTypeRef says
    the designator named the TYPE itself (class-side members) rather than
    a value of it. }
  TPasComplTypeRef = record
    X: TSemaXType;
    OvSym: Integer;
    UnitMid: Integer;
    IsTypeRef: Boolean;
    { A dotted-qualifier PREFIX that is not a unit YET: `Winapi` of
      `Winapi.CommonTypes.IBackgroundTaskInstance` names no unit and no
      symbol, but the next segment may complete a unit name - greedy
      longest-match, accumulated segment by segment (the same rule
      navigation's QualifierUnitAt applies). Not a "valid" ref by itself. }
    PendingUnit: string;
    { An ANONYMOUS array type, which no symbol names: its nkArrayType node
      (`var A: array of TRec`, an open-array parameter, the row of `array of
      array of T`) in model ArrMid (-1 = the overlay), with ArrSkip of its
      index types already consumed (`M[I]` over `array[0..1, 0..1] of T` is
      a row), closed over the frame ArrCtx. A named array keeps its symbol
      until a bracket leaves a row of it. }
    ArrMid: Integer;
    ArrNode: Integer;
    ArrSkip: Integer;
    ArrCtx: Integer;
    { The value is a POINTER to the type the other fields name: an inline
      `^T` resolves to T for the implicit deref (`P.X`), and this keeps the
      level an explicit `P^` or a `P[I]` takes. }
    ViaPointer: Boolean;
  end;

  { The display signature of a routine or a procedural value - see
    TPasCompletion.SymSignature. }
  TPasSymSignature = record
    HeadWord: string;     // 'function' / 'procedure' / ...; '' for no routine
    ParamsText: string;   // '(...)'; '' when parameterless
    HasParams: Boolean;
    ResultText: string;   // '' for a procedure
  end;

  { One resolved target of a located call (CallAt): a routine its designator
    may bind to - one entry PER OVERLOAD, unlike completion rows, which
    collapse the family (a host renders each as its own signature). The
    display fields are materialized eagerly; Mid/Sym/Ctx follow the same
    LIFETIME rule as TPasComplItem's. }
  TPasCallTarget = record
    Mid: Integer;         // declaring model id; -1 = the overlay model
    Sym: Integer;
    Ctx: Integer;         // instantiation frame (project members); NIL_INST
    Name: string;         // original spelling
    HeadWord: string;     // 'function'/'procedure'/'constructor'/... ; ''
    ParamsText: string;   // '(...)' display text; '' when parameterless
    HasParams: Boolean;   // same semantics as ItemHasParams
    ResultText: string;   // result type display text; '' for procedures
  end;

  { CallAt's answer: where the enclosing call opens, which argument the caret
    is in, and what the callee resolves to. Targets may be EMPTY with CallAt
    still True - a real call whose name nothing can resolve is an honest
    empty, the same contract as CompleteAt's empty list. }
  { A type position a context ranks (pastree-lsp COMPLETION.md, "Type
    positions"): the right side of `is` / `is not` / `as`, an exception
    handler's class (`on E: |`, `on |`), a generic argument (`TList<|>`,
    `Foo<|>(`), a generic constraint (`<T: |>`) and an attribute's name
    (`[|]` before a declaration). Each lists types alone - and the
    categories that can stand there - and ranks them (TypePosFit). The
    declaration contexts too: a property's `implements |`, a helper's
    `class helper for |` / `record helper for |`, a type declaration's
    right side (`T = |`, `T = type |`; a subrange's low bound stays
    listed there), `class of |` (a class) and `set of |` (an ordinal of at
    most 256 values, 0..255). }
  TPasComplTypePos = (tpNone, tpIsAs, tpHandler, tpGenArg, tpConstraint,
    tpAttribute, tpImplements, tpHelper, tpTypeDecl, tpClassOf, tpSetOf);

  TPasCallInfo = record
    OpenLine: Integer;    // 1-based position of the call's '('
    OpenCol: Integer;
    ArgIndex: Integer;    // active argument: top-level commas before caret
    Targets: TArray<TPasCallTarget>;
    { The nkCall node the caret is inside, NIL_NODE when the call was
      recovered from a broken parse (the `ident(` shape). A host that wants
      the ARGUMENT nodes - to annotate them, to count them - reads the
      tree from here rather than re-walking tokens (0.29.0). }
    CallNode: Integer;
    { The overload the RESOLVER bound the call to - SelectOverload's arity
      and type-score winner (or the RefMap/ExtRefMap binding of the name) -
      as one of Targets' (Mid, Sym) pairs; BoundSym = NIL_SYM when nothing
      bound. Targets lists the whole family, this says which member of it
      the call is a call OF - the one question a family cannot answer. }
    BoundMid: Integer;
    BoundSym: Integer;
    { True when (BoundMid, BoundSym) is the resolver's CallTarget for
      CallNode - a choice made over the ARGUMENTS. False when the name was
      bound by lookup alone (a bridged cross-unit name, a member found by
      name): then BoundSym is the family's head, not a selection, and a
      host that must pick one overload has to do its own arity match. }
    BoundExact: Boolean;
  end;

  { Per-model caret queries and candidate collection. Build one per model
    SNAPSHOT - the constructor precomputes the raw->visible map (the same
    shape TPasNavigator caches per model); a host that keeps a model across
    requests keeps this with it, and the overlay pipeline creates both fresh
    per request.

    Two modes, one class: standalone (AProject = nil - the caret primitive
    and intra-model collection only) and BRIDGED (AProject + AProjectMid =
    the last-good analysis and this file's model id in it), where every name
    that leaves the overlay resolves through the project - see
    local/COMPLETION-PLAN.md sec. 3 and the stage-B spike. }
  TPasCompletion = class
  private
    FModel: TPasSemaModel;
    FProj: TPasSemaProject;        // may be nil (standalone)
    FProjMid: Integer;             // this file's model id in FProj; -1
    FVisOfRaw: TArray<Integer>;    // Files[0] raw idx -> visible idx | -1
    // collection state (valid during one CompleteAt)
    FItems: TArray<TPasComplItem>;
    FCount: Integer;
    FSeen: TDictionary<string, Integer>;   // NameLower -> item index
    // Per item: the `override`s listed under its name whose ancestor slot
    // the walk has not met yet (AddItem's overload count).
    FPendingOverrides: TArray<Integer>;
    // SplitOverloads: per item, the next item of the same name (-1 ends the
    // chain), and its parameter list lower-cased, read when first compared.
    FSplitOverloads: Boolean;
    FNextSame: TArray<Integer>;
    FParamsOf: TArray<string>;
    FParamsKnown: TArray<Boolean>;
    FUnitMids:TDictionary<string, Integer>;  // lazy: unit basename -> mid
    FContext: TPasComplContext;
    FCaretVis: Integer;            // block-scope positional visibility
    FClassSide: Boolean;           // member completion on a TYPE reference
    FFieldsOnly: Boolean;          // ccRecField: aggregate wants skField only
    // True when FModel IS the project's own model of this file (the oracle /
    // any completion over unedited text): overlay symbol indices are then
    // project symbol indices, so overlay-space dead ends (a generic
    // parameter's constraints) can hop straight into project machinery.
    FIsProjectModel: Boolean;
    // The member walk's BASE type is declared in this unit - which is what
    // legalizes NON-STRICT protected members of its ancestors (11 sec. 11.2.1's
    // module rule, and the whole point of the same-unit protected-access
    // cast idiom: `TProtectedAccess = class(TComponent)` here makes
    // `TProtectedAccess(C).UpdateRegistry` compile).
    FBaseOwnUnit: Boolean;
    FAncestry: TArray<TPasExtRef>; // caret struct's bridged ancestor chain
    // The caret's enclosing struct NEST, innermost first: the method's own
    // class, then each class it is nested IN (overlay symbols). Same-class
    // strict-private access and a nested method's reach into the OUTER
    // class's inherited members both key off this.
    FCaretStructs: TArray<Integer>;
    // Overlay-space ancestors of the caret structs - see OverlayMemberVisible.
    FOverlayAncestry: TArray<Integer>;
    FAncestryBuilt: Boolean;
    // The caret is inside a method body - a struct's routine, or a routine or
    // anonymous method nested in one (11.2.1: a GENERIC class's plain
    // protected is reachable there, and only there).
    FInMethodBody: Boolean;
    // ccType where only a type IDENTIFIER may stand - a parameter's, a
    // result's, a property's type (6.2 ParamType = TypeRef): no subrange
    // bounds, so no constants and no enum values.
    FTypeNameOnly: Boolean;
    // ccType after a declaration's colon - a variable's, a field's, a typed
    // constant's type as well as FTypeNameOnly's: types alone, the constants
    // and enum values a subrange's bounds could name left out (pastree-lsp,
    // 2026-10-22: the list there is for picking a type; a subrange typed
    // inline after a colon is written by hand).
    FColonType: Boolean;
    // ccType in a heritage list: nkClassType after `class(`, nkInterfaceType
    // after `interface(`, nkError anywhere else. A class's list takes a class
    // and interfaces, an interface's interfaces alone.
    FHeritage: TPasNodeKind;
    // The heritage list's first entry (`class(|`), where a class stands -
    // an interface there is E2021; after a comma the interfaces (a class is
    // E2205).
    FHeritageFirst: Boolean;
    // The nkTypeDecl that heritage list belongs to - the type being declared,
    // which cannot be its own ancestor; NIL_NODE outside one. Also the type
    // declared at `T = |` and `TH = class helper for |`: dcc 37 rejects
    // `T = T` (E2086) and a helper for itself (E2021 / E2474) - a type names
    // itself only through `^` or `class of`, which leave this NIL_NODE.
    FHeritageDecl: Integer;
    // A type position that takes a helper: a generic argument, a pointer's
    // base, a type declaration's right side (`T = THelper`, `T = type
    // THelper`). Everywhere else a type is named a helper is E2527 (a
    // declaration), E2021 / E2474 (a heritage list, a helper's type), E2015
    // (`is`, `as`) - dcc 37, pastree-lsp audit 2026-11-09.
    FHelperOk: Boolean;
    // A type position where the compiler's own simple types (Integer,
    // Boolean, string, Double, ...) are named most: a declaration's type,
    // an array's element, a pointer's base, a generic argument. They take
    // Conv 0 (the ones written most; the other builtins 1, System's aliases
    // of them 2), every other item Conv 3
    // (BuiltinTypesFirst).
    FBuiltinFirst: Boolean;
    // The type the caret's operand must fit (ExpectedTypeAt), canonical, in
    // project space; XNil when the position expects nothing knowable. Its
    // category, read once. A type only the overlay knows (declared since the
    // last analysis) is FExpectOv instead.
    FExpect: TSemaXType;
    FExpectCat: TSemaTypeCat;
    FExpectOv: Integer;
    // The operand of `:=` / a comparison whose left side is known and of no
    // procedural type: a procedure cannot stand there, and is not listed.
    FNoProcedures: Boolean;
    // A call argument (ArgExpectAt): FArgNoProcs - a value stands there
    // though no type is expected (an untyped, generic or open-array
    // parameter, an intrinsic's); FArgByRef - a `var` / `out` parameter,
    // which takes a variable alone, of exactly its type.
    FArgNoProcs: Boolean;
    FArgByRef: Boolean;
    // An intrinsic's first `var` parameter with a shape but no type:
    // `Inc(|` / `Dec(|` an ordinal or a typed pointer, `SetLength(|` a
    // string or a dynamic array (ArgVarShapeFit). `Assigned(|` a reference
    // of any kind (its parameter is untyped in the table).
    FArgIncDec: Boolean;
    FArgSetLen: Boolean;
    FArgAssigned: Boolean;
    // A `case` selector (`case | of`): any ordinal fits - a category, not
    // one type, so FExpect stays XNil and MatchOf asks OrdinalFit. A `case`
    // label (`case K of |:`, after `,` / `..` in its list, on a later label
    // line): a constant expression stands there - no variable, function or
    // procedure (CaseLabelOf); FExpect is the selector's type, if known.
    FExpectOrdinal: Boolean;
    // FConstOnly holds in every constant expression - besides a `case` label,
    // a bound, a typed constant's value (set by the operator before the
    // caret) also anywhere inside a constant's, an initialized global's, a
    // parameter default's or a type declaration's expression
    // (ConstExprSiteAt), after an operator too: `C = A + |`.
    FConstOnly: Boolean;
    // `Exit(|` in a routine with no result - a procedure, a constructor, a
    // destructor, an anonymous procedure: `Exit(X)` is E2025 there, so
    // nothing is listed (ExitExpect).
    FExitNoValue: Boolean;
    // A static array's bound where a whole range may stand (`array[|]`,
    // `array[TKind, |]`, not after `..`): an ordinal TYPE is what is
    // written there, so it is fit 0 and an ordinal constant fit 1.
    FBoundType: Boolean;
    // A `case` selector (`case | of`): a string leads there - `case S[I]`
    // selects by a Char - where a cast or a type's bound finds it wrong.
    FCaseSel: Boolean;
    // A condition or an operand of `and` / `or` / `xor` / `not`: any value
    // may make the Boolean there, and `True` / `False` are seldom written -
    // elsewhere a Boolean's literals lead its fit (RankItems).
    FCondLike: Boolean;
    // The right side of a comparison (`=` `<>` `<` `>` `<=` `>=`): what is
    // compared with is mostly a constant (`X = nil`, `K = kOne`), so a
    // constant leads its fit there (RankItems).
    FCompare: Boolean;
    // A for-in collection (`for X in |`): what can be enumerated fits - a
    // category again, FExpect stays XNil and MatchOf asks EnumFit.
    // FEnumElem is the loop variable's type when it has a declared one
    // (`for var X in` has none): a collection whose element is that type
    // ranks first, one whose element only converts next.
    FExpectEnum: Boolean;
    FEnumElem: TSemaXType;
    // A value typecast to a class, an interface, a pointer, a class
    // reference or a procedural type (`TFoo(|`, `PChar(|`): that category,
    // tcUnknown otherwise - a family, FExpect stays XNil and MatchOf asks
    // RefCastFit. A cast to an ordinal type sets FExpectOrdinal instead.
    FCastRef: TSemaTypeCat;
    // A value typecast to a float or a record (`Double(|`, `TRec(|`):
    // tcFloat / tcRecord, tcUnknown otherwise; FCastX the type cast to,
    // FCastSize its SizeOf (-1 unknown). MatchOf asks ValueCastFit: dcc 37
    // casts a number or a Variant to a float, and a value of exactly the
    // target's size to a float or a record (E2089 otherwise). FSizes caches
    // CastSizeOf's answers for one ranking.
    FCastValue: TSemaTypeCat;
    FCastX: TSemaXType;
    FCastSize: Int64;
    FSizes: TDictionary<TSemaXType, Int64>;
    // `raise X at |`: an address - a pointer value (dcc 37: E2017 for
    // anything else, an object and an integer included). MatchOf asks
    // AddrFit.
    FExpectAddr: Boolean;
    // A `with` item (`with | do`, `with A, |`): a value with members fits -
    // a class, a record, an interface, a class reference; a scalar is
    // wrong. A category, FExpect stays XNil and MatchOf asks WithFit.
    FExpectWith: Boolean;
    // A raised object (`raise |`): an instance of a class, FRaiseBase's
    // descendants (Exception, when the caret's unit can name it) fitting
    // and any other class leading. A category again (RaiseFit).
    FExpectRaise: Boolean;
    FRaiseBase: TSemaXType;
    // An arithmetic operand (`X := A + |`, `-|`) where any number fits:
    // FExpect is the left operand's number type, the same type is fit 0,
    // any other integer or float fit 1 (NumberFit). `div` / `mod` / `shl`
    // / `shr` want an integer and leave this off: FExpect's own ranking
    // makes a float wrong there.
    FExpectNumber: Boolean;
    // A type position (TypePosAt): FTypeAs - `as` rather than `is`;
    // FTypeAfterIs - the caret right after `is` (`not` may follow);
    // FTypeLeft / FTypeLeftCat - the static type of `is` / `as`'s left side;
    // FTypeBase - Exception for a handler, TCustomAttribute for an
    // attribute; FTypeRank - something to rank by. A generic argument's
    // constraints: FGenClass / FGenRecord / FGenCtor the keywords, FGenBases
    // the class and interface types, FGenOpenBase one that did not resolve.
    FTypePos: TPasComplTypePos;
    FTypeAs: Boolean;
    FTypeAfterIs: Boolean;
    FTypeLeft: TSemaXType;
    FTypeLeftCat: TSemaTypeCat;
    FTypeBase: TSemaXType;
    FTypeRank: Boolean;
    FGenClass: Boolean;
    FGenRecord: Boolean;
    FGenCtor: Boolean;
    FGenBases: TArray<TSemaXType>;
    FGenOpenBase: Boolean;
    // The declaration contexts: FImplFirst - the interfaces an `implements`
    // ranks first (the class's own heritage list, the property's type);
    // FHelperRecord - `record helper for`, not `class helper for`;
    // FTypeAfterType - `T = type |`, a type identifier alone.
    FImplFirst: TArray<TSemaXType>;
    FHelperRecord: Boolean;
    FTypeAfterType: Boolean;
    // `Self`, listed in a method body: the overlay's enclosing struct of
    // that method (NIL_SYM where nothing lists Self) and whether the method
    // is a class method, where Self is a class reference. MatchOf types the
    // row by them, SelfTypeText shows the type.
    FSelfOv: Integer;
    FSelfClass: Boolean;
    // A property accessor's position (ccPropRead / ccPropWrite /
    // ccPropStored, PropAccessorOf): the property's type (FPropX, or FPropOv
    // for a type only the buffer declares), its index parameters' types and
    // modes, whether it has an `index N` specifier and whether it is a
    // `class property`. FPropRank: AccessorFit ranks the list.
    FPropRank: Boolean;
    FPropX: TSemaXType;
    FPropOv: Integer;
    FPropIdxX: TArray<TSemaXType>;
    FPropIdxOv: TArray<Integer>;
    FPropIdxMode: TArray<Integer>;
    FPropIndexed: Boolean;
    FPropClass: Boolean;
    // `inherited |`: the enclosing method's name, lowercase - what a bare
    // `inherited` calls, ranked first (FInhRank).
    FInhName: string;
    FInhRank: Boolean;
    // `inherited |` in a class method (FInhClass): an ancestor's instance
    // method or property is wrong there (dcc 37: E2076, E2233).
    FInhClass: Boolean;
    // `inherited |` in a constructor: an ancestor's constructor is what is
    // called there (`inherited Create(AOwner)` from `CreateNew`), fit 0.
    FInhCtor: Boolean;
    // ArgExpectAt's answer for an open-array parameter (`Foo([|])`): its
    // element, which the parameter's own type cannot carry.
    FArgOpenElem: TPasComplTypeRef;
    // The operand of `:=` or of a call's value parameter (OperandExpect sets
    // FFlatRootPos). FFlatRoot when the type expected there is exactly
    // TObject or IInterface: every class, or every interface, that converts
    // is fit 1 alike - the exact root gains nothing over a descendant, and
    // proximity decides (`Test(Ac|` for `Test(AObj: TObject)`: a local
    // `Acc: TAccount` above System's `AcquireExceptionObject: TObject`).
    FFlatRootPos: Boolean;
    FFlatRoot: Boolean;
    // `X := AObj as |`, `Foo(AObj as |)`: the type the whole `as` expression
    // must be assignable to (FAsTarget, a class or an interface - never
    // TObject or IInterface, which narrow nothing), its category. The cast's
    // type is ranked against it (TypePosFit) rather than the left operand.
    FAsTarget: TSemaXType;
    FAsTargetCat: TSemaTypeCat;
    // A call argument whose overloads tie on the arguments written and take
    // different types at the caret (`SetValue('Name', |` over Char, Byte,
    // Boolean, string ...): each of those types (ArgExpectAt). An item
    // takes its best fit over them (RankItems). FArgTied holds the tied
    // overloads, ArgTypedOverload's answer for a call being written.
    FArgTied: TArray<Integer>;
    FExpectAlts: TArray<TSemaXType>;
    // A value typecast to an ordinal type (`Longword(|`): its SizeOf - a
    // set of exactly that size casts to it (dcc 37; E2089 for another).
    FCastOrdSize: Int64;
    // The expected type is a generic parameter constrained to a class
    // (`class` or a class type) or an interface: `nil` fits it (dcc 37;
    // E2010 for an unconstrained or a `record` one). GenericNilFits.
    FExpectGenNil: Boolean;
    // ValueReaches' answers per record type for one ranking (RankItems):
    // 0 being walked, 1 reaches nothing, 2 may reach. FReachCycle: a walk
    // met a record still being walked, so what it found is not final.
    FReach: TDictionary<TSemaXType, Byte>;
    FReachCycle: Boolean;
    // MatchOf's second answer: the item's Conv (TPasComplItem.Conv), set
    // where a value is judged cmCompatible against FExpect.
    FConvOut: Byte;
    // The same inside cmLeads: a `case` selector's string (`case S[I]`)
    // after the values that lead through a member or an element.
    FLeadConvOut: Byte;
    // The value graded by FConvOut is of the expected type's category (an
    // integer for an integer): a true constant adapts there and is not
    // graded.
    FConvSameCat: Boolean;

    function RawTokenAt(AOffset: Integer): Integer;
    function CaretOffset(ALine, ACol: Integer; out AOffset: Integer): Boolean;
    function PrevVisibleRaw(ARaw: Integer): Integer;
    function InnermostNodeAt(AVis: Integer): Integer;
    function MemberBaseOfDot(ADotRaw: Integer): Integer;
    // typing (mixed overlay/project space)
    function ProjModel(AMid: Integer; const AWhere: string): TPasSemaModel;
    function BridgeName(const AKey: string; out AMid, ASym: Integer): Boolean;
    function BridgeUnitMid(const AName: string): Integer;
    function UnitRefFullName(AModel: TPasSemaModel; AMid, ASym: Integer):
      string;
    procedure CollectNamespaceChildren(const ANamespace: string);
    function OwnModelTypeX(AOvSym: Integer;
      ADepth: Integer = 0): TSemaXType;
    function OwnModelParamX(AOvSym: Integer): TSemaXType;
    function MethodBodyScope(AScope: Integer): Integer;
    function IsOverrideSym(AMid, ASym: Integer): Boolean;
    function MethodHasSelf(AMethodScope: Integer): Boolean;
    function SelfTypeX: TSemaXType;
    function TypeNameOnlyAt(const AInfo: TPasCaretInfo): Boolean;
    function ColonTypeAt(const AInfo: TPasCaretInfo): Boolean;
    function HeritageAt(const AInfo: TPasCaretInfo): TPasNodeKind;
    function IsStructMemberStart(const AInfo: TPasCaretInfo): Boolean;
    function StatementSiteKind(const AInfo: TPasCaretInfo): TPasNodeKind;
    function TypeOfOverlaySym(ASym, ADepth: Integer): TPasComplTypeRef;
    function TypeOfProjectSym(AMid, ASym, ACtx, ADepth: Integer):
      TPasComplTypeRef;
    function ResolveTypeRefNode(ANode, ADepth: Integer): TPasComplTypeRef;
    function DesignatorType(ANode, ADepth: Integer): TPasComplTypeRef;
    function MemberOf(const ABase: TPasComplTypeRef; const AKey: string;
      ADepth: Integer): TPasComplTypeRef;
    function MemberSymOf(const ABase: TPasComplTypeRef; const AKey: string;
      ADepth: Integer; out AMid, ASym, ACtx: Integer): Boolean;
    // accessors' shared core (AMid = -1 means the overlay model)
    function SymModelOf(AMid: Integer; const AWhere: string;
      out AModel: TPasSemaModel; AHydrate: Boolean = True): Boolean;
    function SymHeadWord(AModel: TPasSemaModel; ASym: Integer): string;
    function SymParamsNode(AModel: TPasSemaModel; ASym: Integer): Integer;
    function SymSignature(AMid, ASym: Integer;
      ATexts: Boolean = True): TPasSymSignature;
    procedure ParamsOf(AModel: TPasSemaModel; AParams: Integer;
      var ASig: TPasSymSignature; ATexts: Boolean = True);
    function IsTypeSym(AMid, ASym: Integer): Boolean;
    procedure ExtendUsesPrefix(ALine: Integer; var AInfo: TPasCaretInfo);
    // CallAt internals
    function DesignatorNodeAtVis(AVis: Integer): Integer;
    function CalleeSyms(ANode, ACallNode: Integer;
      out AMid, ASym, ACtx: Integer): Boolean;
    procedure AddCallTargets(AMid, ASym, ACtx: Integer;
      var AInfo: TPasCallInfo);
    procedure AppendCallTarget(AMid, ASym, ACtx: Integer;
      var AInfo: TPasCallInfo; ASkipSameSig: Boolean = False);
    function IsDescendantNode(ANode, AAncestor: Integer): Boolean;
    function UpChainNode(ANode: Integer; AKind: TPasNodeKind): Integer;
    function ForwardTypeAbove(ASym, ATypeSec: Integer): Boolean;
    function UpChainKind(ANode: Integer;
      const AKinds: array of TPasNodeKind): TPasNodeKind;
    function AggregateTypeOf(AAggNode, ADepth: Integer): TPasComplTypeRef;
    function OverlayStructDef(AOvSym: Integer): Integer;
    function OverlayHeritageRef(AOvSym, ADepth: Integer): TPasComplTypeRef;
    function ProjectTypeDef(const AX: TSemaXType): Integer;
    function ArrayElemRef(AMid, ADef, ACtx,
      ADepth: Integer): TPasComplTypeRef;
    function ElementTypeOf(const ABase: TPasComplTypeRef;
      ACount, ADepth: Integer): TPasComplTypeRef;
    function DesignatorSymOf(ANode, ADepth: Integer;
      out AMid, ASym: Integer): Boolean;
    function IsArrayPropertyDesignator(ANode, ADepth: Integer): Boolean;
    function ScopeOfNode(ANode: Integer): Integer;
    function IsUnitLevelSym(ASym: Integer): Boolean;
    function StructNestMember(ANode: Integer; const AKey: string;
      ADepth: Integer; out AMid, ASym, ACtx: Integer): Boolean;
    function BareNameSym(ANode, ADepth: Integer;
      out AMid, ASym, ACtx: Integer): Boolean;
    function IsResultRoutine(AMid, ASym: Integer): Boolean;
    function ArgTypedOverload(AMid, ASym, ACtx, ACall,
      ADepth: Integer; ACaretArg: Integer = -1): Integer;
    function ArgValueX(const ARef: TPasComplTypeRef): TSemaXType;
    function ArrayArgOf(ACore: Integer; const ARef: TPasComplTypeRef;
      ADepth: Integer): TPasArrayArg;
    function OverlayParams(ASym: Integer): TArray<Integer>;
    function IsProcedureValue(ACore, ADepth: Integer): Boolean;
    function IsConstValue(ANode, ADepth: Integer): Boolean;
    function OwnModelRoutine(AOvSym: Integer): Integer;
    function WrittenCallType(AMid, ASym, ACtx, ACallee,
      ADepth: Integer): TPasComplTypeRef;
    function WrittenMethodFrame(AMid, ASym, ACtx, ATypeArgs,
      ADepth: Integer): Integer;
    function IsInheritedHead(ANode: Integer): Boolean;
    function WithMemberSym(ANode: Integer; const AKey: string;
      ADepth: Integer; out AMid, ASym, ACtx: Integer): Boolean;
    function ValueOfTypeRef(const ARef: TPasComplTypeRef;
      ADepth: Integer): TPasComplTypeRef;
    function ForInElementRef(ACollNode, ADepth: Integer): TPasComplTypeRef;
    function PointeeTypeOf(const ABase: TPasComplTypeRef;
      ADepth: Integer): TPasComplTypeRef;
    // collection
    procedure AddItem(const AName, AKey: string; AKind: TSemaSymbolKind;
      ABucket: TPasComplBucket; AMid, ASym, ACtx: Integer);
    procedure AppendItem(const AName: string; AKind: TSemaSymbolKind;
      ABucket: TPasComplBucket; AMid, ASym, ACtx: Integer);
    function RowParams(ARow: Integer): string;
    procedure AddSym(AMid, ASym, ACtx: Integer; ABucket: TPasComplBucket);
    procedure AddKeywords(const AWords: array of string);
    procedure EnsureAncestry(ACaretScope: Integer);
    function MemberVisible(AMid, ASym: Integer): Boolean;
    function OverlayMemberVisible(ASym: Integer): Boolean;
    function ClassSideMember(AModel: TPasSemaModel; ASym: Integer): Boolean;
    function RoutineNodeOf(AModel: TPasSemaModel; ASym: Integer): Integer;
    procedure CollectMembers(const ABase: TPasComplTypeRef;
      ABucket: TPasComplBucket = cbMember);
    procedure AddSeeds;
    function IsDynArrayRef(const ARef: TPasComplTypeRef;
      ADepth: Integer): Boolean;
    function HeaderQualifierStruct(const AInfo: TPasCaretInfo): Integer;
    function IsRecordAggregate(AAggNode: Integer;
      AAnchor: TPasTokenKind): Boolean;
    procedure CollectOverlayChain(AOvSym: Integer; AIncludeOwn: Boolean;
      ABucket: TPasComplBucket);
    procedure CollectProjectMembers(const AX: TSemaXType;
      ABucket: TPasComplBucket);
    procedure CollectScope(const AInfo: TPasCaretInfo);
    procedure CollectLabels(const AInfo: TPasCaretInfo);
    procedure CollectUsesImports(AInterfaceOnly: Boolean);
    procedure CollectUnitInterface(AUid: Integer; ABucket: TPasComplBucket);
    procedure CollectUnitNames;
    procedure AddContextKeywords(const AInfo: TPasCaretInfo);
    // expected-type ranking
    procedure ResetOperandState;
    function IsRootTypeX(const AX: TSemaXType): Boolean;
    procedure AsTargetOf(AOp, AScope: Integer);
    function GroupIsRelation(AOpen, AClose: Integer): Boolean;
    function SetConstElemRef(AOp: Integer): TPasComplTypeRef;
    function GenericNilFits(const AX: TSemaXType;
      out AIsParam: Boolean): Boolean;
    function ExpectedTypeAt(const AInfo: TPasCaretInfo): TPasComplTypeRef;
    function OperandExpect(AOp, AScope, ADepth: Integer): TPasComplTypeRef;
    function NotOperandExpect(const AOuter: TPasComplTypeRef): TPasComplTypeRef;
    function LogicalOperandExpect(AOp: Integer): TPasComplTypeRef;
    function ArithOperandExpect(AOp: Integer): TPasComplTypeRef;
    function SignOperandExpect(AOp, AScope, ADepth: Integer): TPasComplTypeRef;
    function IsUnarySign(ASign: Integer): Boolean;
    function LeftOperandType(AOp: Integer): TPasComplTypeRef;
    function ExprTypeEndingAt(AEndRaw, AMinPrec, ADepth: Integer;
      out ABeforeRaw: Integer): TPasComplTypeRef;
    function OperandEndingAt(AEndRaw, ADepth: Integer;
      out ABeforeRaw: Integer): TPasComplTypeRef;
    function IsGroupingParen(AParen: Integer): Boolean;
    function IsWithListComma(AComma: Integer): Boolean;
    function ProcValueFit(const AItem: TPasComplItem): Integer;
    function RefCatOf(const ARef: TPasComplTypeRef): TSemaTypeCat;
    function ArgExpectAt(ARaw, AScope: Integer): TPasComplTypeRef;
    procedure ArgTiedAlts(AModel: TPasSemaModel; AMid, ACtx, AArg: Integer;
      const AFirst: TSemaXType);
    procedure RankPass;
    function ArgVarShapeFit(const AX: TSemaXType;
      AOv: Integer): TPasComplMatch;
    procedure CastExpect(AMid, ASym: Integer);
    function CastSizeOf(const AX: TSemaXType): Int64;
    function RaiseAtStart(AAt: Integer): Boolean;
    function DirectiveWordBefore(const AInfo: TPasCaretInfo;
      APrev: Integer): string;
    function ConstExprSiteAt(const AInfo: TPasCaretInfo): Boolean;
    function DeclTypeIsProc(ADecl, ACaretVis: Integer): Boolean;
    function ExitExpect(AScope: Integer): TPasComplTypeRef;
    function CaseLabelOf(ARaw: Integer): Integer;
    function CaseOfStart(AOf: Integer): Integer;
    function CaseSelectorType(AOf: Integer): TPasComplTypeRef;
    function ForAssignOf(ATo: Integer): Integer;
    function ForInStart(AIn: Integer; out AVarRaw: Integer;
      out AInline: Boolean): Boolean;
    function RawDesignatorType(ARaw: Integer): TPasComplTypeRef;
    function DesignatorEndingAt(AEndRaw: Integer;
      out ABeforeRaw: Integer): Integer;
    function OperatorLeftType(AOp: Integer;
      AAllowIn: Boolean): TPasComplTypeRef;
    function BracketOpenOf(ARaw: Integer; out AIndex: Integer): Integer;
    function BracketExpect(AOpen, AIndex, AScope: Integer): TPasComplTypeRef;
    function IndexTypeOf(const ABase: TPasComplTypeRef;
      AIndex: Integer): TPasComplTypeRef;
    function ArrayPropIndexType(ANode, AIndex: Integer): TPasComplTypeRef;
    function SetElementRef(const ASet: TPasComplTypeRef;
      out AIsSet: Boolean): TPasComplTypeRef;
    function RefValueX(const ARef: TPasComplTypeRef;
      out AOvSym: Integer): TSemaXType;
    function MatchOf(const AItem: TPasComplItem): TPasComplMatch;
    function ValueReaches(const AX: TSemaXType; ADepth: Integer): Boolean;
    function ElementValueX(ARef: TPasComplTypeRef): TSemaXType;
    function MemberValueX(AMid, ASym, ACtx: Integer;
      out AX: TSemaXType): Boolean;
    procedure RankItems;
    function IsConstantItem(const AItem: TPasComplItem): Boolean;
    function IsTrueConstItem(const AItem: TPasComplItem): Boolean;
    // type positions
    function TypePosAt(const AInfo: TPasCaretInfo;
      ACaretOff: Integer): TPasComplTypePos;
    procedure IsAsLeftOf(AOp: Integer);
    function IsConstraintAt(const AInfo: TPasCaretInfo;
      APrev: Integer): Boolean;
    function GenericArgAt(const AInfo: TPasCaretInfo; APrev,
      ACaretOff: Integer): Boolean;
    procedure GenericConstraintsOf(AMid, ASym, AIndex: Integer);
    function NamedClassX(const AKey: string): TSemaXType;
    function TypePosAdmits(ACat: TSemaTypeCat): Boolean;
    function IsClassRefValue(AMid, ASym, ACtx: Integer): Boolean;
    function TypeItemX(const AItem: TPasComplItem;
      out ACat: TSemaTypeCat): TSemaXType;
    function TypePosFit(const AItem: TPasComplItem): TPasComplMatch;
    function PrevTokenKindAt(const AInfo: TPasCaretInfo): TPasTokenKind;
    function HeritageFit(const AItem: TPasComplItem): TPasComplMatch;
    function IsHelperSym(AModel: TPasSemaModel; ASym: Integer): Boolean;
    function AliasCatOf(AMid, ASym: Integer): TSemaTypeCat;
    function BuiltinTypeRank(const AItem: TPasComplItem): Integer;
    procedure BuiltinTypesFirst;
    // declaration contexts
    function ImplementsAt(const AInfo: TPasCaretInfo; APrev: Integer): Boolean;
    procedure ImplementsFirstOf(const AInfo: TPasCaretInfo);
    function TypeNodeX(ANode: Integer): TSemaXType;
    function HelperAt(APrev: Integer): Boolean;
    function IsArrayBoundOp(ARaw: Integer): Boolean;
    function IsSubrangeHighOp(ARaw: Integer): Boolean;
    function BoundLeftType(ADotDot: Integer): TPasComplTypeRef;
    // property accessors and `inherited`
    function PropSpecWordAt(ANode: Integer): string;
    procedure PropAccessorOf(const AInfo: TPasCaretInfo);
    procedure InheritedPropType(const AInfo: TPasCaretInfo; AProp: Integer);
    procedure TypeNodeXOv(ANode: Integer; out AX: TSemaXType;
      out AOv: Integer);
    function ItemValueX(AMid, ASym, ACtx: Integer;
      out AOv: Integer): TSemaXType;
    function SameAccType(const AX: TSemaXType; AOv: Integer;
      const BX: TSemaXType; BOv: Integer): Integer;
    function IsStaticRoutine(AModel: TPasSemaModel; ASym: Integer): Boolean;
    function AccessorSigFit(AMid, ASym, ACtx: Integer): Integer;
    function AccessorFit(const AItem: TPasComplItem): TPasComplMatch;
    function InheritedMethodName(AScope: Integer): string;
  public
    constructor Create(AModel: TPasSemaModel;
      AProject: TPasSemaProject = nil; AProjectMid: Integer = -1);
    destructor Destroy; override;
    { The text a host parses the completion overlay from, for a caret at
      1-based (line, col) of AText: AText itself, except that a caret between
      a dot and a `)` gets a space there. `.)` is the legacy `]` (spec B.5.2)
      and lexes as one token, so `Assigned(Decl.|)` - the closing paren the
      editor typed with the opening one - had no dot at all and listed the
      scope instead of Decl's members (pastree-lsp, 2026-10-22). Nobody
      invokes completion inside a `.)` written as a bracket; positions left of
      the caret, the caret's own included, are unchanged.
      A caret between a `^` and a `;`, `)` or `,` gets a space there too: `^;`
      lexes as one caret character literal (`P: ^|;`, `T = ^|;`, `(A: ^|)`),
      and a caret inside a literal lists nothing (pastree-lsp audit,
      2026-11-09). A caret character written as `^;` is never completed.
      A caret PAST the line's end (an editor's virtual space) gets the blanks
      the editor shows there: RAD Studio keeps no trailing blank by default,
      so after `inherited ` the buffer holds `inherited` with the caret one
      column right of it, and that read as the prefix `inherited` - the whole
      statement list, not the ancestors' methods (an IDE test, 2026-11-08). }
    class function CaretSource(const AText: string;
      ALine, ACol: Integer): string; static;
    { Classifies the caret at 1-based (line, col) of the model's main file.
      False = ckNone (AInfo.Kind still says so); True fills every field. A
      column past the end of its line clamps to the line end - hosts report
      such carets (SynEdit's virtual space) and they mean "at the end". }
    function CaretAt(ALine, ACol: Integer; out AInfo: TPasCaretInfo): Boolean;
    { The completion context the caret position calls for - token-first, with
      the (fresh) AST consulted to split the ambiguous tokens (`:` in a decl
      vs a case label, `of` in `array of` vs `case of`, ...). }
    function ClassifyAt(const AInfo: TPasCaretInfo): TPasComplContext;
    { The whole pipeline: caret -> context -> candidate list, deduplicated
      by name (first hit wins - buckets are enumerated in resolution
      precedence) with overloads collapsed. False only when the position
      offers nothing (ckNone). An empty list with True is a real answer
      (e.g. a dot whose base cannot be typed). The first overload also hands
      back the caret classification - a host building textEdits needs the
      REPLACE SPAN (ACaret.PrefixColFrom/PrefixColTo) the engine already
      computed, and must not re-derive tokenization. }
    function CompleteAt(ALine, ACol: Integer; out ACaret: TPasCaretInfo;
      out AContext: TPasComplContext;
      out AItems: TArray<TPasComplItem>): Boolean; overload;
    function CompleteAt(ALine, ACol: Integer; out AContext: TPasComplContext;
      out AItems: TArray<TPasComplItem>): Boolean; overload;
    { The head keyword of a ROUTINE item ('procedure', 'function',
      'constructor', 'destructor', 'operator'), '' for anything else - what
      separates an LSP Constructor kind from a Function, and what a display
      column shows instead of the generic "routine". }
    function ItemHeadWord(const AItem: TPasComplItem): string;
    { One item per overload instead of one per name: a same-name routine
      whose parameter list differs from every one listed under the name gets
      a row of its own, as the RAD Studio Code Completion list shows them;
      one whose list is the same - an `override` or a redeclaration met on
      the walk up the ancestors - is the same signature and stays out.
      Overloads is then always 0. Default False: one row per name, the
      others counted in Overloads. Set before CompleteAt. }
    property SplitOverloads: Boolean read FSplitOverloads
      write FSplitOverloads;
    { The declaration's parameter list as display text - '(const AName:
      string; ACount: Integer)' - whitespace runs collapsed to one space
      (a multi-line list must read as one line; any length cap is the
      host's). '' for parameterless routines and non-routines. Builtins
      answer from the curated seed-table signatures (PasBuiltinSignature). }
    function ItemParamsText(const AItem: TPasComplItem): string;
    { Is this the `Self` row - the one item with no symbol that names a
      value (11.3.3: Self is declared nowhere)? }
    function IsSelfItem(const AItem: TPasComplItem): Boolean;
    { Self's type as display text, for the `Self` row's detail: the
      enclosing type of the method whose body holds the caret - a helper's
      extended type - or `class of T` in a class method. '' outside a
      method with Self. }
    function SelfTypeText: string;
    { Does calling this routine take at least one argument? SEMANTICS: an
      empty `()` declaration answers False - this drives a host's auto-
      parenthesis, and a parameterless routine must stay bare (which is why
      RoutineHasParams's "has an nkParams" definition is the wrong one
      here). Builtins answer the seed table's takes-arguments flag: names
      whose every argument is optional (Exit, Halt, Writeln) are False. }
    function ItemHasParams(const AItem: TPasComplItem): Boolean;
    { The `///` doc-comment block above the item's declaration (plan sec. 8D) -
      TPasTree.DeclDocComment over the item's Mid/Sym, for
      completionItem.documentation and the RAD client's Help Insight. '' for
      keywords, unit names, builtins (no source) and undocumented
      declarations. Raw text: XML-tag rendering is the host's. }
    function ItemDocComment(const AItem: TPasComplItem): string;
    { The call context for signature help: locates the innermost call whose
      ARGUMENT LIST encloses the caret (backward token walk - nesting over
      ()/[] respected, strings/comments are single tokens and cannot fool
      it; an enclosing indexer or grouping paren is stepped over to the
      call outside it, and a designator that names a TYPE is a cast, also
      stepped over), counts the active argument (top-level commas), and
      resolves the designator through the overlay+bridge - the same
      DesignatorType/MemberOf machinery member completion uses, so
      `Obj.Method(|` and freshly typed cross-unit calls both answer.
      False when the caret sits in no call's arguments (including a
      DECLARATION's parameter list). True with empty Targets is a real
      answer: a call whose name nothing resolves. }
    function CallAt(ALine, ACol: Integer; out AInfo: TPasCallInfo): Boolean;
    { The innermost struct type symbol whose member scope encloses AScope -
      the `Self` context: NodeScope's chain carries it both inside a struct
      DECLARATION (the sckStruct scope's own StructSym) and inside a method
      IMPLEMENTATION (stamped on the routine scope by the resolver).
      NIL_SYM outside any struct. }
    function EnclosingStructSym(AScope: Integer): Integer;
    property Model: TPasSemaModel read FModel;
  end;

implementation

uses
  System.SysUtils,
  PasTree.Sema.Builtins,
  PasTree.Sema.Types;

{ TPasCompletion }

constructor TPasCompletion.Create(AModel: TPasSemaModel;
  AProject: TPasSemaProject; AProjectMid: Integer);
var
  LIdx: Integer;
begin
  inherited Create;
  FModel := AModel;
  FProj := AProject;
  FProjMid := AProjectMid;

  FIsProjectModel := (FProj <> nil) and (FProjMid >= 0) and
    (FProjMid < FProj.ModelCount) and (FProj.Model(FProjMid) = FModel);
  // FSeen is CompleteAt's alone, created there per request at the size its
  // context needs (audit C1-36): CallAt, CaretAt and the hosts' probes never
  // read it, and a 4096 table zero-fills 16K slots.
  SetLength(FVisOfRaw, Length(FModel.Tree.Source.Files[0].Tokens));
  for LIdx := 0 to High(FVisOfRaw) do
    FVisOfRaw[LIdx] := -1;
  for LIdx := 0 to High(FModel.Tree.Source.Visible) do
    if FModel.Tree.Source.Visible[LIdx].FileId = 0 then
      FVisOfRaw[FModel.Tree.Source.Visible[LIdx].TokenIndex] := LIdx;
end;

destructor TPasCompletion.Destroy;
begin
  FUnitMids.Free;
  FSeen.Free;
  FReach.Free;
  FSizes.Free;
  inherited;
end;

class function TPasCompletion.CaretSource(const AText: string;
  ALine, ACol: Integer): string;
var
  LPos, LLine, LEnd, LStart: Integer;
begin
  Result := AText;
  if (ALine < 1) or (ACol < 2) then
    Exit;
  LPos := 1;
  for LLine := 2 to ALine do
  begin
    LPos := Pos(#10, AText, LPos);
    if LPos = 0 then
      Exit;
    Inc(LPos);
  end;
  // LPos: the line's first character; the caret stands before LPos + ACol - 1.
  // LEnd: the line's end, before its break (a CR included).
  LStart := LPos;
  LEnd := Pos(#10, AText, LPos);
  if LEnd = 0 then
    LEnd := Length(AText) + 1;
  if (LEnd > LStart) and (AText[LEnd - 1] = #13) then
    Dec(LEnd);
  LPos := LPos + ACol - 1;
  // Virtual space: the blanks the editor shows and does not keep.
  if LPos > LEnd then
    Exit(Copy(AText, 1, LEnd - 1) + StringOfChar(' ', LPos - LEnd) +
      Copy(AText, LEnd, MaxInt));
  if (LPos < LEnd) and
     (((AText[LPos] = ')') and (AText[LPos - 1] = '.')) or
      (CharInSet(AText[LPos], [';', ')', ',']) and
       (AText[LPos - 1] = '^'))) then
    Result := Copy(AText, 1, LPos - 1) + ' ' + Copy(AText, LPos, MaxInt);
end;

// The raw token of Files[0] covering AOffset (Start <= AOffset < EndPos), or
// -1.
function TPasCompletion.RawTokenAt(AOffset: Integer): Integer;
begin
  Result := FModel.Tree.Source.Files[0].RawTokenAt(AOffset);
end;

// 1-based (line, col) -> character offset into Files[0], clamped to the line
// end the way every host position is read (SynEdit's virtual space means "at
// the end"). False when the line itself is out of range.
function TPasCompletion.CaretOffset(ALine, ACol: Integer;
  out AOffset: Integer): Boolean;
begin
  // Clamped to the line end, before its break - landing ON the break is
  // fine too, the trivia walk-back reads both the same way.
  Result := FModel.Tree.Source.Files[0].OffsetOf(ALine, ACol, AOffset);
end;

// Nearest raw token at or before ARaw that has a visible mapping (skips
// trivia backward - a caret in trailing whitespace still belongs to whatever
// came before it, the same reading VisAt established). -1 when nothing
// visible precedes.
function TPasCompletion.PrevVisibleRaw(ARaw: Integer): Integer;
begin
  Result := ARaw;
  if Result > High(FVisOfRaw) then
    Result := High(FVisOfRaw);
  while (Result >= 0) and (FVisOfRaw[Result] < 0) do
    Dec(Result);
end;

// A node's TRUE leftmost visible token. Nodes whose FirstToken is not their
// left edge exist by design (nkMember's FirstToken is the DOT; consumers
// everywhere walk to the leftmost descendant), so take the smaller of the
// node's own FirstToken and its deepest-first-child's.
// Innermost node whose [leftmost visible .. LastToken] span contains AVis: a
// descent from the root, taking the first child that covers the position at
// each level. The arena cannot be binary-searched for this (Adopt re-parents
// an already-built expression under a LATER-created operator node, so node
// index order is not source order) - but child spans are source-ordered
// within a parent, so the descent is linear in tree depth times fan-out.
function TPasCompletion.InnermostNodeAt(AVis: Integer): Integer;
var
  LChild, LFirst: Integer;
  LFound: Boolean;
begin
  Result := NIL_NODE;
  if (AVis < 0) or (Length(FModel.Tree.Nodes) = 0) then
    Exit;
  Result := 0;
  repeat
    LFound := False;
    LChild := FModel.Tree.Nodes[Result].FirstChild;
    while LChild <> NIL_NODE do
    begin
      // Pre-gate on the O(1) LastToken before paying for the leftmost
      // descent: siblings are source-ordered, so everything ending before
      // AVis is skipped with one field read, and the FIRST sibling ending at
      // or after it is the only containment candidate - if its left edge is
      // past AVis, the position sits between siblings and the walk stops.
      // (Scanning thousands of unit-level declarations with a LeftmostVis
      // each was the review's finding #3.)
      if FModel.Tree.Nodes[LChild].LastToken >= AVis then
      begin
        LFirst := FModel.Tree.NodeLeftmostVis(LChild);
        if (LFirst >= 0) and (LFirst <= AVis) then
        begin
          Result := LChild;
          LFound := True;
        end;
        Break;
      end;
      LChild := FModel.Tree.Nodes[LChild].NextSibling;
    end;
  until not LFound;
end;

// The member-access base for the dot at raw index ADotRaw: the innermost node
// containing the dot is the nkMember that OWNS it (the dot is inside no
// child's span - the base ends before it, the name starts after it), and the
// base is that node's first child. NIL_NODE when the dot belongs to no member
// access (`end.`, a float's dot never gets here - `1.5` is one raw token).
function TPasCompletion.MemberBaseOfDot(ADotRaw: Integer): Integer;
var
  LVis, LNode: Integer;
begin
  Result := NIL_NODE;
  if (ADotRaw < 0) or (ADotRaw > High(FVisOfRaw)) then
    Exit;
  LVis := FVisOfRaw[ADotRaw];
  if LVis < 0 then
    Exit;
  LNode := InnermostNodeAt(LVis);
  if (LNode <> NIL_NODE) and (FModel.Tree.Nodes[LNode].Kind = nkMember) then
    Result := FModel.Tree.Nodes[LNode].FirstChild;
end;

function TPasCompletion.CaretAt(ALine, ACol: Integer;
  out AInfo: TPasCaretInfo): Boolean;
var
  LTS: TPasTokenStream;
  LOffset, LAnchorOff: Integer;
  LRaw, LPrevRaw: Integer;
  LKind: TPasTokenKind;
  LTok: TPasToken;
  LNode, LScope, LLine: Integer;
begin
  Result := False;
  AInfo := Default(TPasCaretInfo);
  AInfo.Kind := ckNone;
  AInfo.RawToken := -1;
  AInfo.VisToken := -1;
  AInfo.Node := NIL_NODE;
  AInfo.Scope := NIL_SCOPE;
  AInfo.Routine := NIL_NODE;
  AInfo.DotBase := NIL_NODE;

  LTS := FModel.Tree.Source.Files[0];
  if not CaretOffset(ALine, ACol, LOffset) then
    Exit;

  // Everything below reasons about the character position just LEFT of the
  // caret - that is where the text being completed attaches. A caret at the
  // very start of the file has nothing to attach to.
  if LOffset = 0 then
    Exit;
  LAnchorOff := LOffset - 1;

  // Dead code: a position inside a Skipped ($IFDEF'd-out) region has no
  // visible mapping at all, and walking backward from it would cross the
  // entire inactive region onto unrelated active code - refuse outright,
  // exactly as VisAt does for navigation.
  if FModel.Tree.Source.IsSkipped(0, LAnchorOff) then
    Exit;

  LRaw := RawTokenAt(LAnchorOff);
  if LRaw < 0 then
    Exit;
  LKind := LTS.Tokens[LRaw].Kind;

  // A prefix being typed: the caret sits inside (or at the right edge of) an
  // identifier or reserved word. Reserved words count - `begi|n` and a
  // half-typed `f|or` lex as what they are, and the host is filtering a
  // list that legitimately contains keywords.
  if (LKind = tkIdentifier) or (LKind >= tkAnd) then
  begin
    LTok := LTS.Tokens[LRaw];
    AInfo.Kind := ckIdent;
    AInfo.RawToken := LRaw;
    AInfo.VisToken := FVisOfRaw[LRaw];
    if AInfo.VisToken < 0 then
    begin
      // An active-region word with no visible mapping does not exist today
      // (trivia is never a word; dead regions were refused above) - treat a
      // future exception as "no completion" rather than guessing a scope.
      AInfo.Kind := ckNone;
      Exit;
    end;
    AInfo.Prefix := Copy(LTS.Source, LTok.Start + 1, LOffset - LTok.Start);
    LTS.OffsetToLineCol(LTok.Start, LLine, AInfo.PrefixColFrom);
    AInfo.PrefixColTo := AInfo.PrefixColFrom + LTok.Len;
    // `Foo.Ba|` - the prefix continues a member access when its left visible
    // neighbor is a dot.
    LPrevRaw := PrevVisibleRaw(LRaw - 1);
    if (LPrevRaw >= 0) and (LTS.Tokens[LPrevRaw].Kind = tkDot) then
      AInfo.DotBase := MemberBaseOfDot(LPrevRaw);
  end
  // Strictly INSIDE a literal, comment, directive or asm text: no completion
  // (matches the IDE). Whitespace interior falls through instead - that is
  // the ordinary "caret in trivia" case the walk-back below reads as "after
  // whatever came before". An unterminated string/comment extends to the
  // line end, so its right EDGE still counts as inside.
  // A `//` comment always runs to the line end, so its right edge - where
  // typing in it happens - is inside it too (audit A1-34).
  else if ((LOffset < LTS.Tokens[LRaw].EndPos) or
           (tfUnterminated in LTS.Tokens[LRaw].Flags) or
           (LKind = tkCommentLine)) and
          (LKind in [tkCommentLine, tkCommentBrace, tkCommentParen,
            tkDirective, tkStringLiteral, tkMultilineString, tkControlChar,
            tkCaretChar, tkIntLiteral, tkRealLiteral, tkAsmChunk, tkUnknown]) then
    Exit;

  if AInfo.Kind = ckNone then
  begin
    // Empty prefix: anchor to the nearest visible token at or before the
    // caret and classify by what it is.
    LRaw := PrevVisibleRaw(LRaw);
    if LRaw < 0 then
      Exit;
    AInfo.RawToken := LRaw;
    AInfo.VisToken := FVisOfRaw[LRaw];
    if LTS.Tokens[LRaw].Kind = tkDot then
    begin
      AInfo.Kind := ckAfterDot;
      AInfo.DotBase := MemberBaseOfDot(LRaw);
    end
    else
      AInfo.Kind := ckFresh;
    LTS.OffsetToLineCol(LOffset, LLine, AInfo.PrefixColFrom);
    AInfo.PrefixColTo := AInfo.PrefixColFrom;
  end;

  // Semantic anchors: innermost node, scope in effect, enclosing routine.
  AInfo.Node := InnermostNodeAt(AInfo.VisToken);
  // A prefix that lexes as a reserved word right after an accessor word -
  // `read FOr|` is `read for`, since words are case-insensitive - breaks
  // the property's parse there: the accessor is the `read` / `write` /
  // `stored` specifier before it, whatever the prefix spells (the audit's
  // `read FOriginalValue` with three letters typed was an expression).
  if (AInfo.Kind = ckIdent) and (LTS.Tokens[AInfo.RawToken].Kind >= tkAnd) then
  begin
    LPrevRaw := PrevVisibleRaw(AInfo.RawToken - 1);
    if (LPrevRaw >= 0) and (LTS.Tokens[LPrevRaw].Kind = tkIdentifier) and
       (FVisOfRaw[LPrevRaw] >= 0) then
    begin
      LNode := InnermostNodeAt(FVisOfRaw[LPrevRaw]);
      while (LNode <> NIL_NODE) and
            not (FModel.Tree.Nodes[LNode].Kind in [nkPropSpec, nkPropertyDecl,
              nkBlock, nkInterfaceSec, nkImplementationSec, nkUnit]) do
        LNode := FModel.Tree.Nodes[LNode].Parent;
      if (LNode <> NIL_NODE) and
         (FModel.Tree.Nodes[LNode].Kind = nkPropSpec) and
         (FModel.Tree.Nodes[LNode].FirstToken = FVisOfRaw[LPrevRaw]) and
         (FModel.Tree.Source.VisibleTextEquals(FVisOfRaw[LPrevRaw], 'read') or
          FModel.Tree.Source.VisibleTextEquals(FVisOfRaw[LPrevRaw], 'write') or
          FModel.Tree.Source.VisibleTextEquals(FVisOfRaw[LPrevRaw],
            'stored')) then
        AInfo.Node := LNode;
    end;
  end;
  LNode := AInfo.Node;
  while LNode <> NIL_NODE do
  begin
    if LNode <= High(FModel.NodeScope) then
    begin
      LScope := FModel.NodeScope[LNode];
      if LScope <> NIL_SCOPE then
      begin
        AInfo.Scope := LScope;
        Break;
      end;
    end;
    LNode := FModel.Tree.Nodes[LNode].Parent;
  end;
  LNode := AInfo.Node;
  while (LNode <> NIL_NODE) and (FModel.Tree.Nodes[LNode].Kind <> nkRoutine) do
    LNode := FModel.Tree.Nodes[LNode].Parent;
  AInfo.Routine := LNode;

  Result := True;
end;

{ ---- mixed-space typing ---------------------------------------------------
  The overlay is fresh but alone; the project is complete but stale. A
  designator's type is derived by walking the overlay's own bindings (RefMap,
  member scopes) until a name leaves the buffer, then BRIDGING into the
  project - the resolution order mirrored is CrossResolve's (uses last-wins,
  then System/SysInit, then the compiler seeds). Everything project-side is
  a TSemaXType, so FindMemberX/EnumMembersX/SubstX apply unchanged. }

function ComplNilRef: TPasComplTypeRef;
begin
  Result.X := XNil;
  Result.OvSym := NIL_SYM;
  Result.UnitMid := -1;
  Result.IsTypeRef := False;
  Result.PendingUnit := '';
  Result.ArrMid := -1;
  Result.ArrNode := NIL_NODE;
  Result.ArrSkip := 0;
  Result.ArrCtx := NIL_INST;
  Result.ViaPointer := False;
end;

function ComplValid(const ARef: TPasComplTypeRef): Boolean;
begin
  Result := XValid(ARef.X) or (ARef.OvSym <> NIL_SYM) or (ARef.UnitMid >= 0) or
    (ARef.ArrNode <> NIL_NODE);
end;

// An anonymous array definition as a type reference (see ArrNode).
function ComplArrRef(AMid, ANode, ASkip, ACtx: Integer): TPasComplTypeRef;
begin
  Result := ComplNilRef;
  Result.ArrMid := AMid;
  Result.ArrNode := ANode;
  Result.ArrSkip := ASkip;
  Result.ArrCtx := ACtx;
end;

// Every project-model access in this engine goes through here, so a wrong
// model id raises NAMING ITS SITE instead of a bare list-range error three
// frames deeper. Kept after the bug that motivated it was fixed: this engine
// hand-builds cross-space identities, a wrong one navigates somewhere
// plausible-but-wrong (the hardest bug class this project has), and two
// integer compares per call is not a hot-path cost.
function TPasCompletion.ProjModel(AMid: Integer;
  const AWhere: string): TPasSemaModel;
begin
  if (AMid < 0) or (AMid >= FProj.ModelCount) then
    raise Exception.CreateFmt('bad model id %d at %s', [AMid, AWhere]);
  Result := FProj.Model(AMid);
end;

// Resolve AKey as if written in this unit but NOT declared in it: the
// project-side half of unqualified resolution. Real declarations first
// (uses, last-wins, then the implicit System unit), then the compiler seeds
// of this file's own project model - the same effective order the analysis
// produces (a seed BINDS first intra-unit but is redirected to its real
// declaration; asking for the real one directly collapses the two steps).
function TPasCompletion.BridgeName(const AKey: string;
  out AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
begin
  Result := False;
  if (FProj = nil) or (FProjMid < 0) then
    Exit;
  if FProj.ResolveRealDecl(FProjMid, AKey, AMid, ASym) then
    Exit(True);
  LM := ProjModel(FProjMid, 'BridgeName');
  if LM.SystemScope <> NIL_SCOPE then
  begin
    ASym := LM.Resolve(LM.SystemScope, AKey);
    if ASym <> NIL_SYM then
    begin
      AMid := FProjMid;
      Exit(True);
    end;
  end;
end;

// Project model id of a unit named AName (as written in a uses clause or as
// a qualifier), in three steps: the unit's own name, then the resolved uses
// list by the spelling it was imported under, then an exact file-basename
// index. No namespace-prefix or suffix step - see the comment above the
// index for the false match one caused. Only names the project has ALREADY
// loaded, which is the only kind a bridge can answer anyway.
function TPasCompletion.BridgeUnitMid(const AName: string): Integer;
var
  LIdx: Integer;
  LPM: TPasSemaModel;
begin
  Result := -1;
  if (FProj = nil) or (AName = '') then
    Exit;
  if FProjMid >= 0 then
  begin
    // The unit's OWN name first - a unit may qualify its own exports
    // (`ctX = REST.Types.ctX` inside REST.Types itself)...
    if SameText(ChangeFileExt(ExtractFileName(FProj.ModelFile(FProjMid)), ''),
       AName) then
      Exit(FProjMid);
    // ...then the RESOLVED uses list of this file's project model: a unit is
    // qualified by the name it was IMPORTED under, and the resolution there
    // already applied unit ALIASES and namespace prefixes (`Classes.
    // MakeObjectInstance` means System.Classes through the default -A list -
    // a plain file-name scan cannot know that).
    LPM := ProjModel(FProjMid, 'BridgeUnitMid');
    for LIdx := 0 to High(LPM.UsesList) do
      if (LPM.UsesList[LIdx].UnitId >= 0) and
         PasSameName(LPM.UsesList[LIdx].NameFull, AName) then
        Exit(LPM.UsesList[LIdx].UnitId);
  end;
  // Exact full-dotted spellings last, via a lazily built basename index -
  // the linear scan allocated two strings per model per lookup, and a
  // dotted-qualifier chain does several lookups. No suffix guessing:
  // qualifying a unit requires having USED it, so the uses-list pass above
  // already covers every namespace-shortened or aliased form dcc accepts -
  // and a suffix guess false-matched `REST` (of a self-qualified REST.Types)
  // onto an unrelated `*.REST` unit on the reference project.
  if FUnitMids = nil then
  begin
    FUnitMids := TDictionary<string, Integer>.Create(FProj.ModelCount * 2);
    for LIdx := 0 to FProj.ModelCount - 1 do
      FUnitMids.AddOrSetValue(PasNameKey(
        ChangeFileExt(ExtractFileName(FProj.ModelFile(LIdx)), '')), LIdx);
  end;
  if not FUnitMids.TryGetValue(PasNameKey(AName), Result) then
    Result := -1;
end;

{ The last-good PROJECT identity of an OVERLAY-declared TYPE, by name: the
  overlay is an edit of FProjMid's file, so a type it declares usually still
  exists in the last-good model - which gives an instantiation frame a
  project-space argument where the overlay symbol alone has none
  (`TList<TMyOwnClass>` used to stay an OPEN generic; plan sec. 5.C). Resolved
  from the implementation scope so implementation-section types bridge too
  (its parent chain covers the interface). A freshly typed type that the
  last-good analysis never saw still answers XNil - the frame then stays
  open, exactly the old behavior. When this model IS the project's, the
  symbol needs no bridging at all. A NESTED type is found through its outer
  type's twin (`TServicePair` declared in a class and written bare in its
  methods, `TList<TServicePair>`), ADepth bounding the nest. }
function TPasCompletion.OwnModelTypeX(AOvSym: Integer;
  ADepth: Integer): TSemaXType;
var
  LM: TPasSemaModel;
  LScope, LSym: Integer;
  LOuter: TSemaXType;
begin
  Result := XNil;
  if (AOvSym = NIL_SYM) or (FProj = nil) or (FProjMid < 0) or
     (ADepth > 16) then
    Exit;
  if not (FModel.Symbols[AOvSym].Kind in [skType, skBuiltinType]) then
    Exit;
  if FIsProjectModel then
    Exit(XPlain(FProjMid, AOvSym));
  LM := ProjModel(FProjMid, 'OwnModelTypeX');
  LScope := FModel.Symbols[AOvSym].Scope;
  if (LScope <> NIL_SCOPE) and (FModel.Scopes[LScope].Kind = sckStruct) then
  begin
    LOuter := OwnModelTypeX(FModel.Scopes[LScope].StructSym, ADepth + 1);
    if not XValid(LOuter) or (LOuter.UnitId <> FProjMid) or
       (LM.Symbols[LOuter.Sym].MemberScope = NIL_SCOPE) then
      Exit;
    LSym := LM.FindLocal(LM.Symbols[LOuter.Sym].MemberScope,
      FModel.Symbols[AOvSym].NameLower);
    if (LSym <> NIL_SYM) and (LM.Symbols[LSym].Kind = skType) then
      Result := XPlain(FProjMid, LSym);
    Exit;
  end;
  // Implementation-section types bridge too.
  LScope := LM.OwnDeclScope;
  if LScope = NIL_SCOPE then
    Exit;
  LSym := LM.Resolve(LScope, FModel.Symbols[AOvSym].NameLower);
  if (LSym <> NIL_SYM) and
     (LM.Symbols[LSym].Kind in [skType, skBuiltinType]) then
    Result := XPlain(FProjMid, LSym);
end;

// The declared type of an OVERLAY value/type symbol, as a mixed-space ref.
function TPasCompletion.TypeOfOverlaySym(ASym, ADepth: Integer):
  TPasComplTypeRef;
var
  LMid, LSym, LIdx, LDecl, LInit, LOwner, LCtx: Integer;
begin
  Result := ComplNilRef;
  if (ASym = NIL_SYM) or (ADepth > 16) then
    Exit;
  case FModel.Symbols[ASym].Kind of
    skType:
      begin
        Result.OvSym := ASym;
        Result.IsTypeRef := True;
      end;
    skBuiltinType:
      if BridgeName(FModel.Symbols[ASym].NameLower, LMid, LSym) then
      begin
        Result.X := XPlain(LMid, LSym);
        Result.IsTypeRef := True;
      end;
    skUnitRef:
      for LIdx := 0 to High(FModel.UsesList) do
        if FModel.UsesList[LIdx].Sym = ASym then
        begin
          Result.UnitMid := BridgeUnitMid(FModel.UsesList[LIdx].NameFull);
          Break;
        end;
    skVar, skParam, skField, skConst, skProperty:
      begin
        // The analysis's own answer first when this model IS the project's:
        // SymDeclTypeX already handles the type-slot quirks a node walk
        // re-trips over (a member named like its own type, `TouchInput:
        // TouchInput` - its TypeSlotByNameX fallback exists for exactly
        // this).
        if FIsProjectModel then
        begin
          Result.X := FProj.SymDeclTypeX(FProjMid, ASym);
          if XValid(Result.X) then
            Exit(ValueOfTypeRef(Result, ADepth + 1));
          // An inferred one - a true constant, a resourcestring (always a
          // string, 3.2.3) - as the analysis recorded it.
          if FModel.Symbols[ASym].TypeNode = NIL_NODE then
          begin
            Result.X := FProj.DeclTypeX(FProjMid, ASym);
            if XValid(Result.X) then
              Exit;
          end;
        end;
        if FModel.Symbols[ASym].TypeNode <> NIL_NODE then
          Result := ValueOfTypeRef(ResolveTypeRefNode(
            FModel.Symbols[ASym].TypeNode, ADepth + 1), ADepth + 1)
        else if (FModel.Symbols[ASym].Kind = skProperty) and
                (FModel.Symbols[ASym].Scope <> NIL_SCOPE) then
        begin
          // A typeless REDECLARATION (`property Font;`, 13.1.1) is the
          // property it republishes: one link up the owner's heritage
          // (audit A1-28 - the analysis's SymDeclTypeX climb, which only the
          // project model reached).
          LOwner := FModel.Scopes[FModel.Symbols[ASym].Scope].StructSym;
          if (LOwner <> NIL_SYM) and MemberSymOf(OverlayHeritageRef(LOwner,
               ADepth + 1), FModel.Symbols[ASym].NameLower, ADepth + 1, LMid,
               LSym, LCtx) and ((LMid >= 0) or (LSym <> ASym)) then
          begin
            if LMid < 0 then
              Result := TypeOfOverlaySym(LSym, ADepth + 1)
            else
              Result := TypeOfProjectSym(LMid, LSym, LCtx, ADepth + 1);
          end;
        end
        else
        begin
          // `for var X in Coll` (5.5.2): the inline var is the for-in's
          // first child with no initializer - its type is the collection's
          // element (audit A1-29).
          LDecl := FModel.Symbols[ASym].DeclNode;
          if (LDecl <> NIL_NODE) and
             (FModel.Tree.Nodes[LDecl].Parent <> NIL_NODE) then
          begin
            LInit := FModel.Tree.Nodes[LDecl].Parent;
            if (FModel.Tree.Nodes[LInit].Kind = nkInlineVar) and
               (FModel.Tree.Nodes[LInit].Parent <> NIL_NODE) and
               (FModel.Tree.Nodes[FModel.Tree.Nodes[LInit].Parent].Kind =
                 nkForInStmt) and
               (FModel.Tree.Nodes[FModel.Tree.Nodes[LInit].Parent].
                 FirstChild = LInit) then
              Exit(ForInElementRef(FModel.Tree.Nodes[LInit].NextSibling,
                ADepth + 1));
          end;
          // `var X := expr` - an inline var with an inferred type: the
          // initializer is the last child of the nkInlineVar (3.1.3). A true
          // constant with no type (`C = 'abc'`, 3.2.1) has the same shape,
          // and its type is its initializer's: `C.Substring(` binds through
          // the string helper only once C types as a string.
          LDecl := FModel.Symbols[ASym].DeclNode;
          if (LDecl <> NIL_NODE) and
             (FModel.Tree.Nodes[LDecl].Parent <> NIL_NODE) and
             (FModel.Tree.Nodes[FModel.Tree.Nodes[LDecl].Parent].Kind
               in [nkInlineVar, nkInlineConst, nkConstDecl]) then
          begin
            // The last child short of a constant's trailing hints (`C =
            // 'abc' deprecated;` - nkDirective children).
            var LCh := FModel.Tree.Nodes[
              FModel.Tree.Nodes[LDecl].Parent].FirstChild;
            LInit := NIL_NODE;
            while LCh <> NIL_NODE do
            begin
              if FModel.Tree.Nodes[LCh].Kind <> nkDirective then
                LInit := LCh;
              LCh := FModel.Tree.Nodes[LCh].NextSibling;
            end;
            if (LInit <> NIL_NODE) and (LInit <> LDecl) and
               (FModel.Tree.Nodes[LInit].Kind <> nkAttrGroup) then
            begin
              Result := DesignatorType(LInit, ADepth + 1);
              Result.IsTypeRef := False;
            end;
          end;
        end;
      end;
    skRoutine:
      // Writing a parameterless function's name is a CALL; its type for a
      // trailing dot is the RESULT type (the routine symbol's TypeNode).
      if FModel.Symbols[ASym].TypeNode <> NIL_NODE then
        Result := ValueOfTypeRef(ResolveTypeRefNode(
          FModel.Symbols[ASym].TypeNode, ADepth + 1), ADepth + 1);
    skEnumValue:
      if FModel.Symbols[ASym].TypeSym <> NIL_SYM then
        Result.OvSym := FModel.Symbols[ASym].TypeSym;   // value, not type ref
    skGenericParam:
      // A value typed as an unbound parameter has its CONSTRAINTS' members
      // (16 sec. 16.4.1) - the walk lives in EnumMembersX/FindMemberX, which
      // need a project-space identity: the symbol itself when this model IS
      // the project's, else its twin in the last-good model.
      if FIsProjectModel then
        Result.X := XPlain(FProjMid, ASym)
      else
        Result.X := OwnModelParamX(ASym);
  end;
end;

{ An overlay generic parameter's twin in the last-good model of this file,
  where ConstraintsOfParamX can read its constraints: the same-named
  parameter of the project twin of the type or method that declares it.
  A method body's `<T>` repeats no constraint (16.4.1: they are written once,
  on the declaration), so the body's T is looked up on its struct - the
  struct's own parameters, then a generic method of the segment's name
  (`TArray.BinarySearch<T>`). XNil when nothing matches. }
function TPasCompletion.OwnModelParamX(AOvSym: Integer): TSemaXType;
var
  LM: TPasSemaModel;
  LDecl, LList, LOwner, LChild, LSegment, LScope, LOvStruct, LCand: Integer;
  LStructX: TSemaXType;
  LKey, LSegKey: string;

  function MatchIn(ASym: Integer): TSemaXType;
  var
    LIdent, LParam: Integer;
  begin
    Result := XNil;
    for LIdent in TPasSemaProject.GenericParamIdentsOf(LM, ASym) do
      if LM.Tree.NodeNameLower(LIdent) = LKey then
      begin
        LParam := LM.RefMap[LIdent];
        if (LParam <> NIL_SYM) and (LM.Symbols[LParam].Kind = skGenericParam)
        then
          Exit(XPlain(FProjMid, LParam));
      end;
  end;

begin
  Result := XNil;
  if (FProj = nil) or (FProjMid < 0) then
    Exit;
  // ident -> nkGenericParam -> nkGenericParams -> the declaring node
  LDecl := FModel.Symbols[AOvSym].DeclNode;
  if (LDecl = NIL_NODE) or (FModel.Tree.Nodes[LDecl].Parent = NIL_NODE) then
    Exit;
  LList := FModel.Tree.Nodes[FModel.Tree.Nodes[LDecl].Parent].Parent;
  if (LList = NIL_NODE) or
     (FModel.Tree.Nodes[LList].Kind <> nkGenericParams) then
    Exit;
  LOwner := FModel.Tree.Nodes[LList].Parent;
  if LOwner = NIL_NODE then
    Exit;
  LKey := FModel.Symbols[AOvSym].NameLower;
  LM := ProjModel(FProjMid, 'OwnModelParamX');
  // A type's own `<T>`: the nkTypeDecl's name is the type.
  if FModel.Tree.Nodes[LOwner].Kind = nkTypeDecl then
  begin
    LChild := FModel.Tree.Nodes[LOwner].FirstChild;
    while (LChild <> NIL_NODE) and
          (FModel.Tree.Nodes[LChild].Kind <> nkIdent) do
      LChild := FModel.Tree.Nodes[LChild].NextSibling;
    if LChild = NIL_NODE then
      Exit;
    LStructX := OwnModelTypeX(FModel.RefMap[LChild]);
    if XValid(LStructX) and (LStructX.UnitId = FProjMid) then
      Result := MatchIn(LStructX.Sym);
    Exit;
  end;
  if FModel.Tree.Nodes[LOwner].Kind <> nkRoutine then
    Exit;
  // A routine header: the name segment the list follows says whose it is.
  LSegment := NIL_NODE;
  LChild := FModel.Tree.Nodes[LOwner].FirstChild;
  while (LChild <> NIL_NODE) and (LChild <> LList) do
  begin
    if nfName in FModel.Tree.Nodes[LChild].Flags then
      LSegment := LChild;
    LChild := FModel.Tree.Nodes[LChild].NextSibling;
  end;
  if LSegment = NIL_NODE then
    Exit;
  LSegKey := FModel.Tree.NodeNameLower(LSegment);
  LOvStruct := NIL_SYM;
  LScope := FModel.Symbols[AOvSym].Scope;
  while LScope <> NIL_SCOPE do
  begin
    if FModel.Scopes[LScope].StructSym <> NIL_SYM then
    begin
      LOvStruct := FModel.Scopes[LScope].StructSym;
      Break;
    end;
    LScope := FModel.Scopes[LScope].Parent;
  end;
  if LOvStruct = NIL_SYM then
    Exit;
  LStructX := OwnModelTypeX(LOvStruct);
  if not XValid(LStructX) or (LStructX.UnitId <> FProjMid) then
    Exit;
  if LM.Symbols[LStructX.Sym].NameLower = LSegKey then
    Exit(MatchIn(LStructX.Sym));
  if LM.Symbols[LStructX.Sym].MemberScope = NIL_SCOPE then
    Exit;
  LCand := LM.FindLocal(LM.Symbols[LStructX.Sym].MemberScope, LSegKey);
  while LCand <> NIL_SYM do
  begin
    if LM.Symbols[LCand].Kind = skRoutine then
    begin
      Result := MatchIn(LCand);
      if XValid(Result) then
        Exit;
    end;
    LCand := LM.Symbols[LCand].NextOverload;
  end;
end;

// The same, for a PROJECT symbol found through the bridge or a member walk.
function TPasCompletion.TypeOfProjectSym(AMid, ASym, ACtx, ADepth: Integer):
  TPasComplTypeRef;
var
  LM: TPasSemaModel;
  LIdx, LNode: Integer;
begin
  Result := ComplNilRef;
  if (FProj = nil) or (AMid < 0) or (ASym = NIL_SYM) or (ADepth > 16) then
    Exit;
  LM := ProjModel(AMid, 'TypeOfProjectSym');
  case LM.Symbols[ASym].Kind of
    skType, skBuiltinType:
      begin
        Result.X := XPlain(AMid, ASym);
        if ACtx <> NIL_INST then
          Result.X := FProj.SubstX(Result.X, ACtx, 0);
        Result.IsTypeRef := True;
      end;
    skUnitRef:
      for LIdx := 0 to High(LM.UsesList) do
        if LM.UsesList[LIdx].Sym = ASym then
        begin
          Result.UnitMid := LM.UsesList[LIdx].UnitId;
          Break;
        end;
    // An enumeration value has no declared type to read: its enumeration's.
    // Without it an argument naming another unit's value (`Put(shRound, |`)
    // picked no overload (ArgTypedOverload).
    skEnumValue:
      if LM.Symbols[ASym].TypeSym <> NIL_SYM then
        Result.X := FProj.CanonTypeX(XPlain(AMid, LM.Symbols[ASym].TypeSym));
  else
    begin
      Result.X := FProj.SymDeclTypeX(AMid, ASym);
      // A true constant (`SECTION_WORDS = [tkA, tkB]`) has no declared
      // type: the analysis recorded its initializer's - `S + [|` ranks the
      // set's elements by it.
      if not XValid(Result.X) and (LM.Symbols[ASym].Kind = skConst) and
         (LM.Symbols[ASym].TypeNode = NIL_NODE) then
      begin
        Result.X := FProj.DeclTypeX(AMid, ASym);
        if XValid(Result.X) then
          Exit;
      end;
      // An inline `array ... of T` or `^T` slot names no type: the
      // declaration's own node is the type (audit A1-22, A1-24).
      LNode := LM.Symbols[ASym].TypeNode;
      if not XValid(Result.X) and (LNode <> NIL_NODE) then
        case LM.Tree.Nodes[LNode].Kind of
          nkArrayType:
            Exit(ComplArrRef(AMid, LNode, 0, ACtx));
          nkPointerType:
            begin
              Result.X := FProj.ResolveTypeExpr(AMid,
                LM.Tree.Nodes[LNode].FirstChild);
              Result.ViaPointer := True;
            end;
        end;
      if (ACtx <> NIL_INST) and XValid(Result.X) then
        Result.X := FProj.SubstX(Result.X, ACtx, 0);
      Result := ValueOfTypeRef(Result, ADepth + 1);
    end;
  end;
end;

// A TYPE EXPRESSION node of the overlay (a declared type, a heritage entry,
// a generic argument) resolved to a mixed-space TYPE reference.
function TPasCompletion.ResolveTypeRefNode(ANode, ADepth: Integer):
  TPasComplTypeRef;
var
  LSym, LMid, LChild, LCount, LArgNode, LNameNode: Integer;
  LKey: string;
  LBase, LArg, LOvGeneric: TPasComplTypeRef;
  LArgs: TArray<TSemaXType>;
  LAllProject: Boolean;
begin
  Result := ComplNilRef;
  if (ANode = NIL_NODE) or (ADepth > 16) then
    Exit;
  case FModel.Tree.Nodes[ANode].Kind of
    nkIdent:
      begin
        LSym := FModel.RefMap[ANode];
        // A TYPE SLOT that phase 1 bound to a NON-TYPE is the self-shadow
        // shape (`TouchInput: TouchInput` - the parameter shadows its own
        // type's name): only a type can stand here, so fall through to the
        // cross-unit lookup instead of chasing the value in a circle.
        if (LSym <> NIL_SYM) and
           (FModel.Symbols[LSym].Kind in [skType, skBuiltinType, skUnitRef,
             skGenericParam]) then
        begin
          // A BARE name Phase 1 bound to a generic of this unit names the
          // arity-0 declaration when there is one (16.1.2): `class(
          // TdxBarAccessibilityHelper)` beside an own `TdxBarAccessibility
          // Helper<T>` is the used unit's plain class. Not for the base of
          // `Name<Args>`, whose own branch picks the arity.
          LChild := FModel.Tree.Nodes[ANode].Parent;
          if (FModel.Symbols[LSym].Kind = skType) and
             (sfGeneric in FModel.Symbols[LSym].Flags) and
             (FProj <> nil) and (FProjMid >= 0) and
             not ((LChild <> NIL_NODE) and
                  (FModel.Tree.Nodes[LChild].Kind = nkTypeArgs) and
                  (FModel.Tree.Nodes[LChild].FirstChild = ANode)) then
          begin
            Result.X := OwnModelTypeX(LSym);
            if XValid(Result.X) then
            begin
              Result.X := FProj.PreferNonGenericByName(FProjMid,
                Result.X.UnitId, Result.X.Sym,
                FModel.Tree.NodeNameLower(ANode));
              if XValid(Result.X) and not (sfGeneric in ProjModel(
                 Result.X.UnitId, 'ResolveTypeRefIdent').Symbols[
                 Result.X.Sym].Flags) then
              begin
                Result.IsTypeRef := True;
                Exit;
              end;
            end;
            Result := ComplNilRef;
          end;
          Exit(TypeOfOverlaySym(LSym, ADepth + 1));
        end;
        LKey := FModel.Tree.NodeNameLower(ANode);
        if BridgeName(LKey, LMid, LSym) and
           (ProjModel(LMid, 'ResolveTypeRefIdent').Symbols[LSym].Kind in
             [skType, skBuiltinType])
        then
        begin
          Result.X := XPlain(LMid, LSym);
          // A name with no type arguments names the arity-0 declaration
          // (16.1.2) - the bridge's last-uses-wins lookup may land on a
          // generic of that name (`TList` with Classes listed before
          // Generics.Collections; audit A1-21).
          if sfGeneric in ProjModel(LMid, 'ResolveTypeRefIdent').
             Symbols[LSym].Flags then
            Result.X := FProj.PreferNonGenericByName(FProjMid, LMid, LSym,
              LKey);
          Result.IsTypeRef := True;
        end;
      end;
    nkMember:
      begin
        // Qualified type name: Unit.Type or Outer.Nested.
        LBase := DesignatorType(FModel.Tree.Nodes[ANode].FirstChild,
          ADepth + 1);
        LChild := FModel.Tree.Nodes[ANode].FirstChild;
        if LChild <> NIL_NODE then
          LChild := FModel.Tree.Nodes[LChild].NextSibling;
        if LChild <> NIL_NODE then
          Result := MemberOf(LBase, FModel.Tree.NodeNameLower(LChild),
            ADepth + 1);
      end;
    nkTypeArgs:
      begin
        LChild := FModel.Tree.Nodes[ANode].FirstChild;
        LBase := ResolveTypeRefNode(LChild, ADepth + 1);
        // A NON-generic type of the edited unit bound by name is the wrong
        // arity (`TList<TCollectionItem>` inside System.Classes, which
        // declares a plain TList): its last-good twin starts the arity
        // search below.
        if (LBase.OvSym <> NIL_SYM) and
           not (sfGeneric in FModel.Symbols[LBase.OvSym].Flags) then
        begin
          LBase.X := OwnModelTypeX(LBase.OvSym);
          LBase.OvSym := NIL_SYM;
        end;
        // An overlay GENERIC written with arguments: its last-good twin,
        // instantiated below, carries the frame - `TObjectList<T: class> =
        // class(TList<T>)` in one unit types TList's `First: T` as
        // TObjectList's T, constraint and all. Only when every argument lands
        // in project space; otherwise the overlay generic itself, whose
        // members are enumerable but whose parameters stay open.
        LOvGeneric := ComplNilRef;
        if LBase.OvSym <> NIL_SYM then
        begin
          LOvGeneric := LBase;
          LBase.X := OwnModelTypeX(LBase.OvSym);
          LBase.OvSym := NIL_SYM;
          if not XValid(LBase.X) then
            Exit(LOvGeneric);
        end;
        if not XValid(LBase.X) or (FProj = nil) or (FProjMid < 0) then
          Exit;
        // The declaration of the WRITTEN arity (16.1.2) - the by-name bridge
        // took whichever `TArray` was imported last, and System.Generics.
        // Collections' non-generic TArray class is not `TArray<T>` (audit
        // A1-21). The project's own rule, TypeAtArityX.
        LCount := 0;
        LArgNode := FModel.Tree.Nodes[LChild].NextSibling;
        while LArgNode <> NIL_NODE do
        begin
          Inc(LCount);
          LArgNode := FModel.Tree.Nodes[LArgNode].NextSibling;
        end;
        LNameNode := LChild;
        if FModel.Tree.Nodes[LNameNode].Kind = nkMember then
        begin
          LNameNode := FModel.Tree.LastChild(LNameNode);
        end;
        if LNameNode <> NIL_NODE then
          LBase.X := FProj.TypeAtArityX(FProjMid, LBase.X, LCount, NIL_NODE,
            FModel.Tree.NodeNameLower(LNameNode));
        // Build the instantiation frame when EVERY argument lands in project
        // space. An OVERLAY-declared argument type is bridged by NAME into
        // this file's own last-good model first (OwnModelTypeX) - the
        // `TList<TMyOwnClass>` frame closes that way; only a type the
        // last-good analysis never saw falls back to the open generic
        // (members still complete, parameter types stay open).
        LArgs := nil;
        LAllProject := True;
        LChild := FModel.Tree.Nodes[LChild].NextSibling;
        while LChild <> NIL_NODE do
        begin
          LArg := ResolveTypeRefNode(LChild, ADepth + 1);
          if not XValid(LArg.X) then
            LArg.X := OwnModelTypeX(LArg.OvSym);
          if XValid(LArg.X) then
            LArgs := LArgs + [LArg.X]
          else
            LAllProject := False;
          LChild := FModel.Tree.Nodes[LChild].NextSibling;
        end;
        if (LOvGeneric.OvSym <> NIL_SYM) and
           not (LAllProject and (Length(LArgs) > 0)) then
          Exit(LOvGeneric);
        Result := LBase;
        if LAllProject and (Length(LArgs) > 0) then
          Result.X.Inst := FProj.Instantiate(LBase.X, LArgs);
      end;
    nkPointerType:
      begin
        // A value of an inline `^T` reaches T's members through the implicit
        // deref - resolve to the pointee directly (the same hop FindMemberX
        // makes for a NAMED pointer type), marked so `P^` and `P[I]` still
        // take the level (audit A1-24).
        Result := ResolveTypeRefNode(FModel.Tree.Nodes[ANode].FirstChild,
          ADepth + 1);
        Result.IsTypeRef := False;
        Result.ViaPointer := True;
      end;
    // An inline `array ... of T`: the node is the type (audit A1-22).
    nkArrayType:
      Result := ComplArrRef(-1, ANode, 0, NIL_INST);
    // An anonymous struct written inline (`var R: record X: T; end`): the
    // symbol DeclareAnonStruct gave it (audit B2-31).
    nkRecordType, nkClassType, nkInterfaceType, nkObjectType:
      begin
        Result.OvSym := FModel.StructSymAtNode(ANode);
        Result.IsTypeRef := True;
      end;
    // `string[N]` is a ShortString (7.1.3).
    nkStringType:
      if BridgeName('shortstring', LMid, LSym) then
      begin
        Result.X := XPlain(LMid, LSym);
        Result.IsTypeRef := True;
      end;
    nkClassOf:
      begin
        Result := ResolveTypeRefNode(FModel.Tree.Nodes[ANode].FirstChild,
          ADepth + 1);
        Result.IsTypeRef := True;   // a class-reference value is class-side
      end;
  end;
end;

// The type of an EXPRESSION (designator) node of the overlay - what a dot
// after it completes on.
function TPasCompletion.DesignatorType(ANode, ADepth: Integer):
  TPasComplTypeRef;
var
  LSym, LMid, LChild, LScope, LNode, LCtx, LFirst: Integer;
  LKind: TPasNodeKind;
  LKey: string;
  LCallee: TPasComplTypeRef;
  LRes, LCached: TSemaXType;
begin
  Result := ComplNilRef;
  if (ANode = NIL_NODE) or (ADepth > 16) then
    Exit;
  // The node's kind and first child, read once: the branches below asked
  // for them twelve times.
  LKind := FModel.Tree.Nodes[ANode].Kind;
  LFirst := FModel.Tree.Nodes[ANode].FirstChild;
  // An ANALYZED model already typed its expressions (the cross passes fill
  // ExprTypeX, frames closed) - for VALUE-shaped nodes that answer beats any
  // re-derivation, and covers what the walk below does not (indexing and
  // derefs). Only value shapes: a bare type designator may also carry its
  // type here, and treating THAT as a value would offer instance members on
  // `TFoo.`. An overlay model has no cache and falls through everywhere.
  if LKind in [nkCall, nkParen, nkIndex, nkDeref] then
    if FModel.ExprTypeX.TryGetValue(ANode, LCached) and XValid(LCached) then
    begin
      Result.X := LCached;
      Exit(ValueOfTypeRef(Result, ADepth + 1));
    end;
  case LKind of
    nkParen:
      Result := DesignatorType(LFirst, ADepth + 1);
    nkIntLit, nkRealLit, nkStrLit, nkCaretChar:
      // A literal - `'abc'.Substring(`, or the initializer of an untyped
      // constant - types as dcc types it: `'x'` is a Char, `'xy'` a string,
      // which decides the helper (TCharHelper or TStringHelper).
      if FProj <> nil then
      begin
        LKey := FProj.LiteralTypeName(FModel.Tree, ANode, False);
        if (LKey <> '') and BridgeName(LKey, LMid, LSym) then
          Result.X := XPlain(LMid, LSym);
      end;
    nkUnaryOp, nkBinaryOp:
      begin
        // `X as T` is a T (12.4.1) - the type, wherever it is declared,
        // which the intra-unit typer cannot reach across units.
        LChild := LFirst;
        if (LKind = nkBinaryOp) and
           (LChild <> NIL_NODE) and
           (FModel.Tree.Nodes[LChild].NextSibling <> NIL_NODE) and
           (FModel.Tree.Source.VisibleToken(
             FModel.Tree.Nodes[ANode].Aux).Kind = tkAs) then
        begin
          Result := ResolveTypeRefNode(FModel.Tree.Nodes[LChild].NextSibling,
            ADepth + 1);
          Result.IsTypeRef := False;
          Exit;
        end;
        // `C = 'AB' + 'CD'`, `-1`: the intra-unit typer's answer, which is
        // category-level (a sum of Chars is a string, any integer Integer) -
        // right for choosing a helper, which is all this is asked for.
        if FModel.ExprType[ANode] <> NIL_SYM then
        begin
          Result := TypeOfOverlaySym(FModel.ExprType[ANode], ADepth + 1);
          Result.IsTypeRef := False;
        end;
      end;
    nkIdent:
      begin
        LKey := FModel.Tree.NodeNameLower(ANode);
        // `Self` has no symbol anywhere (11.3.3) - answered structurally,
        // the same way the analysis answers it (StructSymOfNode). In a
        // CLASS method it is the class reference: class-side members only
        // (audit B2-28; dcc: an instance field there is E2124).
        if (LKey = 'self') and (FModel.RefMap[ANode] = NIL_SYM) then
        begin
          Result.OvSym := EnclosingStructSym(ScopeOfNode(ANode));
          LNode := ANode;
          while (LNode <> NIL_NODE) and
                (FModel.Tree.Nodes[LNode].Kind <> nkRoutine) do
            LNode := FModel.Tree.Nodes[LNode].Parent;
          Result.IsTypeRef := (LNode <> NIL_NODE) and
            (FModel.Tree.Nodes[LNode].Aux = 1);
          Exit;
        end;
        if BareNameSym(ANode, ADepth, LMid, LSym, LCtx) then
        begin
          if LMid < 0 then
            Exit(TypeOfOverlaySym(LSym, ADepth + 1));
          if FProj = nil then
            Exit;
          if ProjModel(LMid, 'DesignatorExtRef').Symbols[LSym].Kind
             in [skType, skBuiltinType, skUnitRef] then
            Exit(TypeOfProjectSym(LMid, LSym, NIL_INST, ADepth + 1));
          // The analysis's own CROSS-UNIT binding (an analyzed model only;
          // overlays have an empty ExtRefMap) comes with a cached expression
          // type for a VALUE, which also carries the closed instantiation
          // frame - `Statics` on a WinRT import class is typed as the bound
          // ARGUMENT, which nothing downstream can recover from the symbol
          // alone (the corpus oracle's whole `Statics.*` bucket).
          if FModel.ExprTypeX.TryGetValue(ANode, LCached) and
             XValid(LCached) then
          begin
            Result.X := LCached;
            Exit(ValueOfTypeRef(Result, ADepth + 1));
          end;
          Exit(TypeOfProjectSym(LMid, LSym, LCtx, ADepth + 1));
        end;
        Result.UnitMid := BridgeUnitMid(FModel.Tree.NodeText(ANode));
        // No unit either - maybe the FIRST SEGMENT of a longer dotted unit
        // name (`Winapi` of Winapi.CommonTypes.X): keep it pending.
        if Result.UnitMid < 0 then
          Result.PendingUnit := FModel.Tree.NodeText(ANode);
      end;
    nkMember:
      begin
        LCallee := DesignatorType(LFirst, ADepth + 1);
        LChild := LFirst;
        if LChild <> NIL_NODE then
          LChild := FModel.Tree.Nodes[LChild].NextSibling;
        if LChild <> NIL_NODE then
          Result := MemberOf(LCallee, FModel.Tree.NodeNameLower(LChild),
            ADepth + 1);
      end;
    nkCall:
      begin
        // The routine the call binds to - the analysis's choice
        // (CallTargetX), else the overload its arguments' types pick
        // (ArgTypedOverload) - types it by its result: the overload chain's
        // head, which the callee's name alone gives, is another overload's
        // result (audit A1-26). A constructor keeps the walk below (its
        // value is the NAMED class), and so does a cast.
        if CalleeSyms(LFirst, ANode, LMid, LSym, LCtx) and
           IsResultRoutine(LMid, LSym) then
        begin
          LSym := ArgTypedOverload(LMid, LSym, LCtx, ANode, ADepth + 1);
          // `Name<...>(...)`: in the frame of its written type arguments.
          Result := WrittenCallType(LMid, LSym, LCtx, LFirst, ADepth + 1);
          if ComplValid(Result) then
            Exit;
          // Both answer a routine by its result as a VALUE (ValueOfTypeRef:
          // a class reference stays class side).
          if LMid < 0 then
            Result := TypeOfOverlaySym(LSym, ADepth + 1)
          else
            Result := TypeOfProjectSym(LMid, LSym, LCtx, ADepth + 1);
          if ComplValid(Result) then
            Exit;
        end;
        LCallee := DesignatorType(LFirst, ADepth + 1);
        if not ComplValid(LCallee) then
        begin
          // A compiler intrinsic has no declared result - `Copy(S, 1, 2).`,
          // `Chr(65).`: the intra-unit typer's answer, a seeded type bridged
          // to its real declaration (audit A1-27).
          if FModel.ExprType[ANode] <> NIL_SYM then
          begin
            Result := TypeOfOverlaySym(FModel.ExprType[ANode], ADepth + 1);
            Result.IsTypeRef := False;
          end;
          Exit;
        end;
        if LCallee.IsTypeRef then
        begin
          // A cast - T(expr) - or a value-typed use of a constructor's
          // class (T.Create is already an instance by MemberOf's ctor rule).
          // A cast to a class-reference type is class side.
          Exit(ValueOfTypeRef(LCallee, ADepth + 1));
        end;
        Result := LCallee;
        // A callee that is a VALUE of a procedural type: calling it takes
        // the result type (parameterless-func values were already unwrapped
        // at the symbol, so this only fires for real proc-type values).
        if XValid(Result.X) and (FProj <> nil) then
        begin
          LRes := FProj.ProcResultX(Result.X);
          if XValid(LRes) then
            Result.X := LRes;
        end;
      end;
    nkTypeArgs:
      begin
        // `Node.GetData<TItem>.`: a generic METHOD written with its type
        // arguments and no parentheses is a call (6.6.1) - of the overload
        // declaring that many (16.5.1) - typed in their frame; a generic
        // TYPE stays a type reference.
        if CalleeSyms(ANode, NIL_NODE, LMid, LSym, LCtx) and
           IsResultRoutine(LMid, LSym) then
        begin
          Result := WrittenCallType(LMid, LSym, LCtx, ANode, ADepth + 1);
          if ComplValid(Result) then
            Exit;
        end;
        Result := ResolveTypeRefNode(ANode, ADepth);
      end;
    nkDeref:
      begin
        Result := PointeeTypeOf(DesignatorType(LFirst, ADepth + 1),
          ADepth + 1);
        Result.IsTypeRef := False;   // a dereferenced value is an INSTANCE
      end;
    nkIndex:
      begin
        LChild := LFirst;
        Result := DesignatorType(LChild, ADepth + 1);
        // An array property's declared type is already the element's: the
        // brackets consume its parameters and peel nothing (13.1.2; audit
        // A1-20, E2-45 - `Components[0].` indexed TComponent again).
        if not IsArrayPropertyDesignator(LChild, ADepth + 1) then
        begin
          // One dimension per index expression (8.1.2; audit A1-25).
          LScope := 0;
          LNode := FModel.Tree.Nodes[LChild].NextSibling;
          while LNode <> NIL_NODE do
          begin
            Inc(LScope);
            LNode := FModel.Tree.Nodes[LNode].NextSibling;
          end;
          Result := ElementTypeOf(Result, LScope, ADepth + 1);
        end;
        // An indexed value - a value already, as both answers give it
        // (class side for a class reference).
      end;
  end;
end;

// The scope in effect at ANode: the innermost NodeScope up its parents.
function TPasCompletion.ScopeOfNode(ANode: Integer): Integer;
begin
  Result := NIL_SCOPE;
  while ANode <> NIL_NODE do
  begin
    if (ANode <= High(FModel.NodeScope)) and
       (FModel.NodeScope[ANode] <> NIL_SCOPE) then
      Exit(FModel.NodeScope[ANode]);
    ANode := FModel.Tree.Nodes[ANode].Parent;
  end;
end;

// Is an overlay symbol declared at UNIT level (a unit's interface or
// implementation, or the compiler seeds) - a binding a member of the
// caret's class nest outranks (3.3.2)?
function TPasCompletion.IsUnitLevelSym(ASym: Integer): Boolean;
var
  LScope: Integer;
begin
  LScope := FModel.Symbols[ASym].Scope;
  Result := (LScope <> NIL_SCOPE) and (FModel.Scopes[LScope].Kind in
    [sckSystem, sckUnit, sckImplementation]);
end;

{ A bare name inside a method looked up as dcc looks it up there (3.3.2):
  the class scope - the method's class and its ancestors, the cross-unit
  ones included - and then each class the method's class is nested in,
  before anything at unit level. MemberSymOf over each nest level: overlay
  heritage, then the bridged ancestry (FindMemberX). False outside a
  struct, or when no member carries the name. }
function TPasCompletion.StructNestMember(ANode: Integer; const AKey: string;
  ADepth: Integer; out AMid, ASym, ACtx: Integer): Boolean;
var
  LOv, LNext, LHop, LUp: Integer;
  LBase: TPasComplTypeRef;
begin
  Result := False;
  AMid := -1;
  ASym := NIL_SYM;
  ACtx := NIL_INST;
  if (AKey = '') or (ADepth > 16) then
    Exit;
  // Inside a routine's BODY only - its declarations and statements. In a
  // type's declaration and in a routine heading, a method's implementation
  // heading included, a member named like a unit does not hide it:
  // `F: ImageEnView.TIEMouseInteractItems` beside an inherited property
  // ImageEnView qualifies by the unit (3.3.2; dcc64 37.0, probe-b48 P1-P4).
  LUp := ANode;
  while (LUp <> NIL_NODE) and
        (FModel.Tree.Nodes[LUp].Kind <> nkRoutineBody) do
    LUp := FModel.Tree.Nodes[LUp].Parent;
  if LUp = NIL_NODE then
    Exit;
  LOv := EnclosingStructSym(ScopeOfNode(ANode));
  for LHop := 1 to 8 do
  begin
    if LOv = NIL_SYM then
      Break;
    LBase := ComplNilRef;
    LBase.OvSym := LOv;
    // A private member of another unit is passed over (3.3.2's filter: the
    // search goes on outward).
    if MemberSymOf(LBase, AKey, ADepth + 1, AMid, ASym, ACtx) and
       ((AMid < 0) or (AMid = FProjMid) or not (ProjModel(AMid,
         'StructNestMember').Symbols[ASym].Visibility in
         [svPrivate, svStrictPrivate])) then
      Exit(True);
    if FModel.Symbols[LOv].Scope = NIL_SCOPE then
      Break;
    LNext := FModel.Scopes[FModel.Symbols[LOv].Scope].StructSym;
    if LNext = LOv then
      Break;
    LOv := LNext;
  end;
  AMid := -1;
  ASym := NIL_SYM;
  ACtx := NIL_INST;
end;

{ What a bare identifier binds to (AMid = -1: an overlay symbol): a local, a
  parameter or a member the overlay bound; the analysis's cross-unit
  binding; a member of the caret's class nest - the inherited members of a
  class in another unit, which Phase 1 cannot see (`Canvas.`, `Owner.` in a
  form's method; audit A1-18) - before a unit-level binding or a name the
  bridge finds in the used units. On an analyzed model the analysis has
  already moved a unit-level binding a member outranks, so its RefMap is
  taken as it stands. }
function TPasCompletion.BareNameSym(ANode, ADepth: Integer;
  out AMid, ASym, ACtx: Integer): Boolean;
var
  LSym, LOv: Integer;
  LExt: TPasExtRef;
  LKey: string;
begin
  Result := True;
  AMid := -1;
  ASym := NIL_SYM;
  ACtx := NIL_INST;
  LKey := FModel.Tree.NodeNameLower(ANode);
  // `inherited Name` (12.1.2): the search starts at the ancestor of the
  // method's class - Phase 1 cannot follow an ancestry into another unit and
  // may have bound the class's own method of that name (`inherited
  // Remove(` in TObjectList is TList.Remove, not TObjectList.Remove).
  if not FIsProjectModel and IsInheritedHead(ANode) then
  begin
    LOv := EnclosingStructSym(ScopeOfNode(ANode));
    if (LOv <> NIL_SYM) and MemberSymOf(OverlayHeritageRef(LOv, ADepth + 1),
       LKey, ADepth + 1, AMid, ASym, ACtx) then
      Exit;
    AMid := -1;
    ASym := NIL_SYM;
    ACtx := NIL_INST;
    Exit(False);
  end;
  // An enclosing UNOPENED with (5.7) shadows everything: Phase 1 could not
  // open a target typed in another unit (`with InAddr do S_un_b.s_b1 :=`),
  // so its members are looked up here, innermost statement first and the
  // last target of one statement first. An analyzed model's with pass has
  // bound them already.
  if not FIsProjectModel and WithMemberSym(ANode, LKey, ADepth, AMid, ASym,
     ACtx) then
    Exit;
  LSym := FModel.RefMap[ANode];
  if (LSym <> NIL_SYM) and (FIsProjectModel or not IsUnitLevelSym(LSym)) then
  begin
    AMid := -1;
    ASym := LSym;
    ACtx := NIL_INST;
    Exit;
  end;
  if (FProj <> nil) and FModel.ExtRefMap.TryGetValue(ANode, LExt) then
  begin
    AMid := LExt.UnitId;
    ASym := LExt.Sym;
    ACtx := NIL_INST;
    Exit;
  end;
  if StructNestMember(ANode, LKey, ADepth, AMid, ASym, ACtx) then
    Exit;
  if LSym <> NIL_SYM then
  begin
    ASym := LSym;
    Exit;
  end;
  if (LKey <> '') and BridgeName(LKey, AMid, ASym) then
    Exit;
  AMid := -1;
  ASym := NIL_SYM;
  Result := False;
end;

// Is ANode the name `inherited` names - `inherited Foo`, the callee of
// `inherited Foo(...)`, the head of `inherited Foo.Bar`?
function TPasCompletion.IsInheritedHead(ANode: Integer): Boolean;
var
  LUp: Integer;
begin
  Result := False;
  for var LHop := 1 to 16 do
  begin
    LUp := FModel.Tree.Nodes[ANode].Parent;
    if LUp = NIL_NODE then
      Exit;
    if FModel.Tree.Nodes[LUp].Kind = nkInherited then
      Exit(True);
    if not (FModel.Tree.Nodes[LUp].Kind in [nkCall, nkMember, nkIndex]) or
       (FModel.Tree.Nodes[LUp].FirstChild <> ANode) then
      Exit;
    ANode := LUp;
  end;
end;

// A member of an enclosing UNOPENED with's target that ANode names - see
// BareNameSym.
function TPasCompletion.WithMemberSym(ANode: Integer; const AKey: string;
  ADepth: Integer; out AMid, ASym, ACtx: Integer): Boolean;
var
  LIdx, LBody, LTarget: Integer;
  LTargets: TArray<Integer>;
  LRef: TPasComplTypeRef;
begin
  Result := False;
  AMid := -1;
  ASym := NIL_SYM;
  ACtx := NIL_INST;
  if (AKey = '') or (ADepth > 16) then
    Exit;
  for LIdx := High(FModel.WithUnopened) downto 0 do
  begin
    LBody := FModel.Tree.WithBody(FModel.WithUnopened[LIdx]);
    if LBody = NIL_NODE then
      Continue;
    if not IsDescendantNode(ANode, LBody) then
      Continue;
    LTargets := nil;
    LTarget := FModel.Tree.Nodes[FModel.WithUnopened[LIdx]].FirstChild;
    while (LTarget <> NIL_NODE) and (LTarget <> LBody) do
    begin
      LTargets := LTargets + [LTarget];
      LTarget := FModel.Tree.Nodes[LTarget].NextSibling;
    end;
    for var LTi := High(LTargets) downto 0 do
    begin
      LRef := DesignatorType(LTargets[LTi], ADepth + 1);
      LRef.IsTypeRef := False;
      if ComplValid(LRef) and
         MemberSymOf(LRef, AKey, ADepth + 1, AMid, ASym, ACtx) then
        Exit(True);
    end;
  end;
  AMid := -1;
  ASym := NIL_SYM;
  ACtx := NIL_INST;
end;

{ The overload of a call's family that the call binds to, by ARGUMENT TYPE
  as the analysis picks it (6.3.1): of the routines the argument count
  admits (6.2.5; TPasSemaTyper.ArityFits) and, after `Name<...>`, of those
  declaring that many type parameters (16.5.1), the one whose arguments fit
  its parameters best - each pair scored in project space by the cross-type
  pass's own rule (TPasSemaProject.ArgFitX), RANKED as dcc ranks the
  conversion (6.3.1: a Byte takes F(Integer) over F(Int64), `5` F(Byte)
  over F(Integer), a class its nearer ancestor; a `var` parameter refuses
  a literal; an untyped one ranks above Variant) from the argument's facts
  read off the buffer (BufferArgConvX), the first declared winning a tie. The callee comes with less: a project family found by NAME is its
  head (`B.GetObj(1).` must be the overload with a parameter), and Phase 1's
  choice in a family of the buffer's own was made without any type of
  another unit - an argument typed TCust scored nothing, and one typed by an
  alias the buffer declares (`TCustListB = TList<TCust>`) had no category,
  which the unit typer counts as assignable to anything: `Pick(LB).` took
  `Pick(const S: string)` over `Pick(const L: TList<TCust>)` (audit C1).
  The analysis's own choice (CallTargetX) is kept, and so is the callee when
  nothing fits or an argument is a comparison still undecided (16.3.1).

  ACaretArg >= 0 asks for the overload of a call still being written, whose
  argument ACaretArg holds the caret (ArgExpectAt): that argument is not
  scored, nor one the parse left missing or ambiguous; a candidate must take
  at least as many arguments as are written - more may follow - and the
  analysis's own choice, made over the unfinished call, is not kept. ACall
  may then be NIL_NODE (a parse broken around the caret): nothing is scored
  and the first overload taking ACaretArg + 1 arguments wins. }
function TPasCompletion.ArgTypedOverload(AMid, ASym, ACtx, ACall,
  ADepth: Integer; ACaretArg: Integer): Integer;
var
  LM: TPasSemaModel;
  LCands, LParams, LCores: TArray<Integer>;
  LArgXs: TArray<TSemaXType>;
  LArrs: TArray<TPasArrayArg>;
  LProcs, LRefs, LSkip: TArray<Boolean>;
  LArgs, LCount, LTypeArgs, LCur, LHop, LIdx, LPass, LReq, LTot, LScore,
    LFit, LBestScore: Integer;
  LTrailing, LVariadic, LOpenArr, LOfConst: Boolean;
  LRef: TPasComplTypeRef;
  LParX: TSemaXType;
  LNode, LTypeNode, LVarRecMid, LVarRecSym: Integer;
  LTied: TArray<Integer>;
  LConvs: TArray<TSemaArgConv>;
  LHeads: TArray<TSemaSymbolKind>;
  LTyper: TPasSemaTyper;

  // What the argument ACore names or calls, by the buffer's own binding
  // (ByRefShapeRejects' AHeadKind); skKeyword: not known - a name of
  // another unit, which the shape rules then leave alone.
  function ArgHeadKind(ACore: Integer): TSemaSymbolKind;
  var
    LName, LSym: Integer;
  begin
    Result := skKeyword;
    LName := ACore;
    if (LName <> NIL_NODE) and (FModel.Tree.Nodes[LName].Kind = nkCall) then
      LName := PeelParens(FModel.Tree, FModel.Tree.Nodes[LName].FirstChild);
    if (LName <> NIL_NODE) and (FModel.Tree.Nodes[LName].Kind = nkMember) then
      LName := FModel.Tree.LastChild(LName);
    if (LName = NIL_NODE) or (FModel.Tree.Nodes[LName].Kind <> nkIdent) then
      Exit;
    LSym := FModel.RefMap[LName];
    if LSym <> NIL_SYM then
      Result := PasTree.Sema.Types.ArgHeadKind(FModel.Symbols[LSym]);
  end;

begin
  Result := ASym;
  if (FProj = nil) or (ASym = NIL_SYM) or (ADepth > 16) or
     not SymModelOf(AMid, 'ArgTypedOverload', LM, False) or
     (LM.Symbols[ASym].Kind <> skRoutine) then
    Exit;
  if ACall = NIL_NODE then
  begin
    if ACaretArg < 0 then
      Exit;
  end
  else if (FModel.Tree.Nodes[ACall].Kind <> nkCall) or
          ((ACaretArg < 0) and FModel.CallTargetX.ContainsKey(ACall)) then
    Exit;
  LTrailing := False;
  if ACall <> NIL_NODE then
    LArgs := CallArgCount(FModel, ACall, LTrailing)
  else
    LArgs := 0;
  if LArgs < 0 then
    Exit;
  // A call being written whose `(` is not closed: the parse runs on into
  // the next statement, which comes back as trailing nkError arguments -
  // `Foo([|` counted two and ruled out `Foo(const A: array of T)`.
  if (ACaretArg >= 0) and (ACall <> NIL_NODE) then
  begin
    var LReal := 0;
    var LAt := 0;
    LNode := CallFirstArg(FModel.Tree, ACall);
    while LNode <> NIL_NODE do
    begin
      Inc(LAt);
      if FModel.Tree.Nodes[LNode].Kind <> nkError then
        LReal := LAt;
      LNode := FModel.Tree.Nodes[LNode].NextSibling;
    end;
    if LReal < LArgs then
      LArgs := LReal;
  end;
  if LArgs < ACaretArg + 1 then
    LArgs := ACaretArg + 1;
  // The designator called, read by both walks below.
  var LCallee: Integer := NIL_NODE;
  if ACall <> NIL_NODE then
    LCallee := FModel.Tree.Nodes[ACall].FirstChild;
  // The family in declaration order. A routine of the buffer's own: the
  // chain its NAME heads in the buffer - the callee's binding, which Phase 1
  // chose an overload of - and, after an implementation-section head, the
  // interface section's set, which joins it (6.3.1; Phase 1's
  // InterfaceCounterpart).
  LCur := ASym;
  if AMid < 0 then
  begin
    LNode := LCallee;
    while (LNode <> NIL_NODE) and
          (FModel.Tree.Nodes[LNode].Kind in [nkParen, nkTypeArgs]) do
      LNode := FModel.Tree.Nodes[LNode].FirstChild;
    if (LNode <> NIL_NODE) and (FModel.Tree.Nodes[LNode].Kind = nkMember) then
      LNode := FModel.Tree.LastChild(LNode);
    // The name's binding, and ASym's name and scope, read once each.
    var LBound: Integer := NIL_SYM;
    if (LNode <> NIL_NODE) and (FModel.Tree.Nodes[LNode].Kind = nkIdent) then
      LBound := FModel.RefMap[LNode];
    var LName := FModel.Symbols[ASym].NameLower;
    var LScope := FModel.Symbols[ASym].Scope;
    if (LBound <> NIL_SYM) and (FModel.Symbols[LBound].Kind = skRoutine) and
       (FModel.Symbols[LBound].NameLower = LName) then
      LCur := LBound
    else if LScope <> NIL_SCOPE then
      LCur := FModel.FindLocal(LScope, LName);
  end;
  LCands := nil;
  for LPass := 0 to 1 do
  begin
    for LHop := 1 to 64 do
    begin
      if (LCur = NIL_SYM) or (LM.Symbols[LCur].Kind <> skRoutine) then
        Break;
      LCands := LCands + [LCur];
      LCur := LM.Symbols[LCur].NextOverload;
    end;
    if (AMid >= 0) or (Length(LCands) = 0) or
       (LM.Symbols[LCands[0]].Scope = NIL_SCOPE) or
       (LM.Scopes[LM.Symbols[LCands[0]].Scope].Kind <> sckImplementation) or
       (LM.InterfaceScope = NIL_SCOPE) then
      Break;
    LCur := LM.FindLocal(LM.InterfaceScope, LM.Symbols[ASym].NameLower);
  end;
  if Length(LCands) < 2 then
    Exit;
  // The arguments, each typed once: its type in project space, what it
  // brings an array parameter besides (ArrayArgOf), whether it is a class
  // REFERENCE (a type name, a class-side value) and whether it names a
  // procedure, and its node under the parentheses.
  SetLength(LArgXs, LArgs);
  SetLength(LArrs, LArgs);
  SetLength(LCores, LArgs);
  SetLength(LProcs, LArgs);
  SetLength(LRefs, LArgs);
  SetLength(LConvs, LArgs);
  SetLength(LHeads, LArgs);
  SetLength(LSkip, LArgs);
  LCount := 0;
  // The conversion facts of each argument (6.3.1's ranking: a literal's
  // value, a constant folded) are read off the buffer's nodes by a typer
  // over it - the buffer is no unit of the closure (BufferArgConvX).
  LTyper := TPasSemaTyper.Over(FModel, FProj.Platform);
  try
    LNode := NIL_NODE;
    if ACall <> NIL_NODE then
      LNode := CallFirstArg(FModel.Tree, ACall);
    while (LNode <> NIL_NODE) and (LCount < LArgs) do
    begin
      // A call being written: the caret's own argument, and one the parse
      // left missing or ambiguous, is not scored.
      if (ACaretArg >= 0) and ((LCount = ACaretArg) or
         (FModel.Tree.Nodes[LNode].Kind in [nkMissing, nkAmbiguous])) then
      begin
        LSkip[LCount] := True;
        Inc(LCount);
        LNode := FModel.Tree.Nodes[LNode].NextSibling;
        Continue;
      end;
      if FModel.Tree.Nodes[LNode].Kind = nkMissing then
        Break;
      if FModel.Tree.Nodes[LNode].Kind = nkAmbiguous then
        Exit;
      LCores[LCount] := PeelParens(FModel.Tree, LNode);
      LRef := DesignatorType(LNode, ADepth + 1);
      LArgXs[LCount] := ArgValueX(LRef);
      LArrs[LCount] := ArrayArgOf(LCores[LCount], LRef, ADepth + 1);
      LRefs[LCount] := LRef.IsTypeRef;
      LProcs[LCount] := IsProcedureValue(LCores[LCount], ADepth + 1);
      LConvs[LCount] := FProj.BufferArgConvX(LTyper, LCores[LCount],
        LArgXs[LCount]);
      LHeads[LCount] := ArgHeadKind(LCores[LCount]);
      Inc(LCount);
      LNode := FModel.Tree.Nodes[LNode].NextSibling;
    end;
  finally
    LTyper.Free;
  end;
  // The written type arguments' count, the 16.5.1 filter; when it leaves no
  // candidate the choice runs again without it, as SelectCallTarget's does.
  LTypeArgs := -1;
  LNode := NIL_NODE;
  if LCallee <> NIL_NODE then
    LNode := PeelParens(FModel.Tree, LCallee);
  if (LNode <> NIL_NODE) and (FModel.Tree.Nodes[LNode].Kind = nkTypeArgs) then
    // The first child is the name they follow.
    LTypeArgs := PasChildCount(FModel.Tree, LNode) - 1;
  for LPass := 0 to 1 do
  begin
    LBestScore := -1;
    LTied := nil;
    for LCur in LCands do
    begin
      if (LPass = 0) and (LTypeArgs >= 0) and
         (TPasSemaProject.GenericParamCountOf(LM, LCur) <> LTypeArgs) then
        Continue;
      if AMid >= 0 then
      begin
        if not FProj.RoutineArity(AMid, LCur, LReq, LTot, LVariadic) then
          Continue;
        LParams := FProj.XParamSyms(AMid, LCur);
      end
      else
      begin
        // The unit typer's arity (SelectOverload): parameters up to the
        // first default are required; one with no parameter scope - a
        // seeded intrinsic - is no candidate.
        if LM.Symbols[LCur].MemberScope = NIL_SCOPE then
          Continue;
        LParams := OverlayParams(LCur);
        LTot := Length(LParams);
        LReq := 0;
        while (LReq < LTot) and
              not (sfHasDefault in LM.Symbols[LParams[LReq]].Flags) do
          Inc(LReq);
        LVariadic := sfVarArgs in LM.Symbols[LCur].Flags;
      end;
      if ACaretArg >= 0 then
      begin
        // More arguments may follow the caret's: enough parameters is all.
        if not (LVariadic or (LTot >= LArgs)) then
          Continue;
      end
      else if not (LVariadic or TPasSemaTyper.ArityFits(LArgs, LReq, LTot,
         LTrailing)) then
        Continue;
      LScore := 0;
      for LIdx := 0 to LCount - 1 do
      begin
        if LSkip[LIdx] then
          Continue;
        if LIdx > High(LParams) then
          Break;
        if AMid >= 0 then
          LParX := FProj.ParamFitTypeX(AMid, LParams[LIdx], ACtx, LOpenArr,
            LOfConst)
        else
        begin
          // ParamFitTypeX over the buffer's own nodes: an open array is
          // scored by its element type, `array of const` by System.TVarRec.
          LParX := XNil;
          LTypeNode := LM.Symbols[LParams[LIdx]].TypeNode;
          LOpenArr := (LTypeNode <> NIL_NODE) and
            (LM.Tree.Nodes[LTypeNode].Kind = nkArrayType);
          LOfConst := LOpenArr and (LM.Tree.Nodes[LTypeNode].Aux = 1);
          if LOpenArr then
          begin
            if LOfConst and BridgeName('tvarrec', LVarRecMid, LVarRecSym) then
              LParX := XPlain(LVarRecMid, LVarRecSym);
            LTypeNode := PasArrayElemNode(LM.Tree, LTypeNode);
          end;
          if LTypeNode <> NIL_NODE then
          begin
            LRef := ResolveTypeRefNode(LTypeNode, ADepth + 1);
            if not LRef.ViaPointer then
            begin
              LParX := LRef.X;
              if not XValid(LParX) then
                LParX := OwnModelTypeX(LRef.OvSym);
            end;
          end;
        end;
        if LOpenArr then
          LFit := FProj.OpenArgFitX(LArgXs[LIdx], LParX, LOfConst, FModel.Tree,
            LCores[LIdx], LRefs[LIdx], LArrs[LIdx])
        else
          LFit := FProj.ArgFitX(LArgXs[LIdx], LParX, FModel.Tree, LCores[LIdx],
            LProcs[LIdx], LRefs[LIdx], LArrs[LIdx], FModel, @LConvs[LIdx],
            ParamIsByRef(LM, LParams[LIdx]), ParamIsUntyped(LM, LParams[LIdx]),
            LHeads[LIdx]);
        if LFit < 0 then
        begin
          LScore := -1;
          Break;
        end;
        Inc(LScore, LFit);
      end;
      if LScore > LBestScore then
      begin
        LBestScore := LScore;
        Result := LCur;
        LTied := [LCur];
      end
      else if (LScore >= 0) and (LScore = LBestScore) then
        LTied := LTied + [LCur];
    end;
    if (LBestScore >= 0) or (LTypeArgs < 0) then
    begin
      // A call being written: the overloads the written arguments cannot
      // tell apart (ArgExpectAt ranks by each one's parameter).
      if (ACaretArg >= 0) and (LBestScore >= 0) then
        FArgTied := LTied;
      Exit;
    end;
  end;
end;

// The project-space type of the value ARef types: its XType, a buffer
// type's project twin (OwnModelTypeX), or nothing for a value of an inline
// `^T`, which comes typed as T (ResolveTypeRefNode) while its own type is
// the pointer, which has no name to score.
function TPasCompletion.ArgValueX(const ARef: TPasComplTypeRef): TSemaXType;
begin
  Result := XNil;
  if ARef.ViaPointer then
    Exit;
  Result := ARef.X;
  if not XValid(Result) then
    Result := OwnModelTypeX(ARef.OvSym);
end;

{ What the argument ACore, typed ARef, brings an ARRAY parameter besides
  its type (TPasSemaProject.OpenArgFitX, ArgFitX): a `[...]`'s elements,
  each typed here - a type name a class reference, a constant told apart
  (IsConstValue) - or the element of the one-dimensional inline array type
  it is declared with (ARef's ArrNode: `var A: array of string`, an
  open-array parameter, `array of const`'s TVarRec). }
function TPasCompletion.ArrayArgOf(ACore: Integer;
  const ARef: TPasComplTypeRef; ADepth: Integer): TPasArrayArg;
var
  LKid, LIdx: Integer;
  LM: TPasSemaModel;
  LElem: TPasComplTypeRef;
  LKind: TPasCtorElemKind;
begin
  Result.Elems := nil;
  Result.InlineElemX := XNil;
  Result.IsVar := False;
  Result.Mid := -1;   // the buffer model: no conversion facts read
  if FModel.Tree.Nodes[ACore].Kind = nkSetCtor then
  begin
    SetLength(Result.Elems, PasChildCount(FModel.Tree, ACore));
    LIdx := 0;
    LKid := FModel.Tree.Nodes[ACore].FirstChild;
    while LKid <> NIL_NODE do
    begin
      LElem := DesignatorType(LKid, ADepth + 1);
      LKind := cekValue;
      if LElem.IsTypeRef then
        LKind := cekClassRef
      else if IsConstValue(LKid, ADepth + 1) then
        LKind := cekConstant;
      Result.Elems[LIdx] := FProj.CtorElemX(ArgValueX(LElem), LKind,
        FModel.Tree, LKid);
      Inc(LIdx);
      LKid := FModel.Tree.Nodes[LKid].NextSibling;
    end;
    Exit;
  end;
  if (ARef.ArrNode = NIL_NODE) or (ARef.ArrSkip <> 0) or ARef.ViaPointer or
     not SymModelOf(ARef.ArrMid, 'ArrayArgOf', LM) or
     (LM.Tree.Nodes[ARef.ArrNode].Aux <> 1) and
     (PasArrayDims(LM.Tree, ARef.ArrNode) <> 1) then
    Exit;
  LElem := ArrayElemRef(ARef.ArrMid, ARef.ArrNode, ARef.ArrCtx, ADepth + 1);
  if LElem.ArrNode = NIL_NODE then
    Result.InlineElemX := ArgValueX(LElem);
end;

// The parameters of the buffer's routine ASym in declaration order (its
// parameter scope, the project's XParamSyms over the buffer).
function TPasCompletion.OverlayParams(ASym: Integer): TArray<Integer>;
var
  LScope, LIdx: Integer;
begin
  Result := nil;
  LScope := FModel.Symbols[ASym].MemberScope;
  if LScope = NIL_SCOPE then
    Exit;
  for LIdx := 0 to FModel.Scopes[LScope].Symbols.Count - 1 do
    if FModel.Symbols[FModel.Scopes[LScope].Symbols[LIdx]].Kind = skParam then
      Result := Result + [FModel.Scopes[LScope].Symbols[LIdx]];
end;

// Does the argument node ACore (under its parentheses) name a PROCEDURE - a
// routine with no result, a method value and nothing else (the unit typer's
// IsProcDesignator, the project's IsProcedureDesignator)?
function TPasCompletion.IsProcedureValue(ACore, ADepth: Integer): Boolean;
var
  LM: TPasSemaModel;
  LMid, LSym: Integer;
  LKind: TPasNodeKind;
begin
  Result := False;
  if ACore = NIL_NODE then
    Exit;
  LKind := FModel.Tree.Nodes[ACore].Kind;
  if not (LKind in [nkIdent, nkMember, nkTypeArgs]) then
    Exit;
  // `DoIt<Integer>` is its head's routine.
  if LKind = nkTypeArgs then
    ACore := FModel.Tree.Nodes[ACore].FirstChild;
  if not DesignatorSymOf(ACore, ADepth, LMid, LSym) or (LSym = NIL_SYM) or
     not SymModelOf(LMid, 'IsProcedureValue', LM, False) then
    Exit;
  Result := (LM.Symbols[LSym].Kind = skRoutine) and
    (LM.Symbols[LSym].TypeNode = NIL_NODE) and
    not (sfBuiltin in LM.Symbols[LSym].Flags) and
    (LM.RoutineHead(LSym) <> rhConstructor);
end;

// Is the value node ANode a constant dcc reads by value - by its shape: a
// literal but `nil`, a true constant, an enumeration value or an operator
// over constants? The typers ask ConstExprKind (IsConstExpr, IsConstExprX),
// whose facts this buffer cannot give, so an intrinsic call is a value here
// and a true constant initialized by a typecast a constant (docs/coverage.md
// 6.3.1). A typed constant is a variable.
function TPasCompletion.IsConstValue(ANode, ADepth: Integer): Boolean;
var
  LM: TPasSemaModel;
  LMid, LSym, LKid: Integer;
begin
  Result := False;
  ANode := PeelParens(FModel.Tree, ANode);
  if ANode = NIL_NODE then
    Exit;
  case FModel.Tree.Nodes[ANode].Kind of
    nkIntLit, nkRealLit, nkStrLit, nkCaretChar:
      Result := True;
    nkBinaryOp, nkUnaryOp:
      begin
        LKid := FModel.Tree.Nodes[ANode].FirstChild;
        Result := LKid <> NIL_NODE;
        while Result and (LKid <> NIL_NODE) do
        begin
          Result := IsConstValue(LKid, ADepth);
          LKid := FModel.Tree.Nodes[LKid].NextSibling;
        end;
      end;
    nkIdent, nkMember:
      if DesignatorSymOf(ANode, ADepth, LMid, LSym) and (LSym <> NIL_SYM) and
         SymModelOf(LMid, 'IsConstValue', LM, False) then
        Result := (LM.Symbols[LSym].Kind = skEnumValue) or
          ((LM.Symbols[LSym].Kind = skConst) and
           (LM.Symbols[LSym].TypeNode = NIL_NODE));
  end;
end;

{ The last-good PROJECT twin of a routine the buffer declares - OwnModelType
  X's sibling for routines: the same-named routine of the twin of its
  struct, or of this file's own scopes, the first of its overload chain
  declaring as many type parameters and parameters. NIL_SYM for a routine
  the last-good analysis never saw. }
function TPasCompletion.OwnModelRoutine(AOvSym: Integer): Integer;
var
  LM: TPasSemaModel;
  LScope, LMembers, LCand, LHop, LTypeParams, LParams: Integer;
  LOwner: TSemaXType;
begin
  Result := NIL_SYM;
  if (AOvSym = NIL_SYM) or (FProj = nil) or (FProjMid < 0) or
     (FModel.Symbols[AOvSym].Kind <> skRoutine) then
    Exit;
  if FIsProjectModel then
    Exit(AOvSym);
  LM := ProjModel(FProjMid, 'OwnModelRoutine');
  LScope := FModel.Symbols[AOvSym].Scope;
  if (LScope <> NIL_SCOPE) and (FModel.Scopes[LScope].Kind = sckStruct) then
  begin
    LOwner := OwnModelTypeX(FModel.Scopes[LScope].StructSym);
    if not XValid(LOwner) or (LOwner.UnitId <> FProjMid) then
      Exit;
    LMembers := LM.Symbols[LOwner.Sym].MemberScope;
    if LMembers = NIL_SCOPE then
      Exit;
    LCand := LM.FindLocal(LMembers, FModel.Symbols[AOvSym].NameLower);
  end
  else
  begin
    if LM.OwnDeclScope = NIL_SCOPE then
      Exit;
    LCand := LM.Resolve(LM.OwnDeclScope, FModel.Symbols[AOvSym].NameLower);
  end;
  LTypeParams := TPasSemaProject.GenericParamCountOf(FModel, AOvSym);
  LParams := Length(OverlayParams(AOvSym));
  for LHop := 1 to 64 do
  begin
    if (LCand = NIL_SYM) or (LM.Symbols[LCand].Kind <> skRoutine) then
      Exit;
    if (FProj.GenericParamCount(FProjMid, LCand) = LTypeParams) and
       (Length(FProj.XParamSyms(FProjMid, LCand)) = LParams) then
      Exit(LCand);
    LCand := LM.Symbols[LCand].NextOverload;
  end;
end;

{ A generic method called with its type arguments WRITTEN - `TUtil.FirstOf<
  TCust>(AD)`, `Node.GetData<TItem>`: they are the answer and nothing is
  inferred (16.5.1), so the call types in the frame they make - the routine
  of the family declaring that many type parameters, ASym's own first; one
  the buffer declares through its last-good twin, which the frame is keyed
  on. Without it the result stayed the open T, whose members are its
  constraints' - none for a bare `<T>` (audit C2). ACallee: the designator
  called. A nil ref when it is not written so or no frame can be made. }
function TPasCompletion.WrittenCallType(AMid, ASym, ACtx, ACallee,
  ADepth: Integer): TPasComplTypeRef;
var
  LM: TPasSemaModel;
  LCount, LCur, LHop, LFrame, LClimb, LHead, LOwner, LAMid, LASym,
    LACtx: Integer;
  LHit: Boolean;
  LX: TSemaXType;
begin
  Result := ComplNilRef;
  if (FProj = nil) or (ADepth > 16) then
    Exit;
  ACallee := PeelParens(FModel.Tree, ACallee);
  if (ACallee = NIL_NODE) or
     (FModel.Tree.Nodes[ACallee].Kind <> nkTypeArgs) or
     not SymModelOf(AMid, 'WrittenCallType', LM, False) then
    Exit;
  // The first child is the name they follow.
  LCount := PasChildCount(FModel.Tree, ACallee) - 1;
  LCur := ASym;
  LHit := False;
  for LClimb := 0 to 16 do
  begin
    LHead := LCur;
    for LHop := 1 to 64 do
    begin
      if (LCur = NIL_SYM) or (LM.Symbols[LCur].Kind <> skRoutine) then
        Break;
      if TPasSemaProject.GenericParamCountOf(LM, LCur) = LCount then
      begin
        LHit := True;
        Break;
      end;
      LCur := LM.Symbols[LCur].NextOverload;
    end;
    if LHit or (AMid < 0) or (LHead = NIL_SYM) or
       (LM.Symbols[LHead].Scope = NIL_SCOPE) then
      Break;
    // A method set spans the ancestry (16.5.1, 6.3.1): a derived `GetV;
    // overload;` beside an ancestor's `GetV<T>` - the set the analysis's
    // SelectCallTarget walks through ConsiderAncestors.
    LOwner := LM.Scopes[LM.Symbols[LHead].Scope].StructSym;
    if (LOwner = NIL_SYM) or not FProj.FindMemberX(AMid,
       FProj.AncestorOfX(XPlain(AMid, LOwner)), LM.Symbols[LHead].NameLower,
       LAMid, LASym, LACtx) or
       not SymModelOf(LAMid, 'WrittenCallType', LM, False) or
       (LM.Symbols[LASym].Kind <> skRoutine) then
      Break;
    AMid := LAMid;
    LCur := LASym;
    if LACtx <> NIL_INST then
      ACtx := LACtx;
  end;
  if not LHit then
    Exit;
  if AMid < 0 then
  begin
    AMid := FProjMid;
    LCur := OwnModelRoutine(LCur);
  end;
  LFrame := WrittenMethodFrame(AMid, LCur, ACtx, ACallee, ADepth + 1);
  if LFrame = NIL_INST then
    Exit;
  LX := FProj.SubstX(FProj.SubstX(FProj.SymDeclTypeX(AMid, LCur), ACtx, 0),
    LFrame, 0);
  if XValid(LX) then
  begin
    Result.X := LX;
    Result := ValueOfTypeRef(Result, ADepth + 1);
  end;
end;

{ The substitution frame the type arguments written in ATypeArgs (an
  nkTypeArgs over the routine's name) make for the project routine
  AMid.ASym - the project's ExplicitMethodFrame over the buffer's nodes,
  each argument closed over ACtx first. NIL_INST when an argument does not
  resolve or their count is not the routine's. }
function TPasCompletion.WrittenMethodFrame(AMid, ASym, ACtx, ATypeArgs,
  ADepth: Integer): Integer;
var
  LArg: Integer;
  LRef: TPasComplTypeRef;
  LX: TSemaXType;
  LArgs: TArray<TSemaXType>;
begin
  Result := NIL_INST;
  if (FProj = nil) or (AMid < 0) or (ASym = NIL_SYM) or
     (ATypeArgs = NIL_NODE) or (ADepth > 16) or
     (FModel.Tree.Nodes[ATypeArgs].FirstChild = NIL_NODE) then
    Exit;
  LArgs := nil;
  LArg := FModel.Tree.Nodes[FModel.Tree.Nodes[ATypeArgs].FirstChild].
    NextSibling;
  while LArg <> NIL_NODE do
  begin
    LRef := ResolveTypeRefNode(LArg, ADepth + 1);
    LX := LRef.X;
    if not XValid(LX) then
      LX := OwnModelTypeX(LRef.OvSym);
    if not XValid(LX) then
      Exit;
    LArgs := LArgs + [FProj.SubstX(LX, ACtx, 0)];
    LArg := FModel.Tree.Nodes[LArg].NextSibling;
  end;
  if (Length(LArgs) = 0) or
     (Length(LArgs) <> FProj.GenericParamCount(AMid, ASym)) then
    Exit;
  Result := FProj.Instantiate(XPlain(AMid, ASym), LArgs);
end;

// A routine whose call is typed by its declared result - not a constructor,
// whose value is the class it is called on (MemberOf's rule).
function TPasCompletion.IsResultRoutine(AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LRoutine: Integer;
begin
  Result := False;
  if (ASym = NIL_SYM) or not SymModelOf(AMid, 'IsResultRoutine', LM) or
     (LM.Symbols[ASym].Kind <> skRoutine) then
    Exit;
  if AMid >= 0 then
    Exit(not FProj.IsConstructorSym(AMid, ASym));
  LRoutine := RoutineNodeOf(FModel, ASym);
  Result := (LRoutine = NIL_NODE) or (FModel.Tree.Source.VisibleToken(
    FModel.Tree.Nodes[LRoutine].FirstToken).Kind <> tkConstructor);
end;

{ A VALUE of the type ARef names. A class-reference type's value is the
  class it refers to, class side (15.2.1): `C: TFooClass; C.` lists what
  `TFoo.` lists, not instance members (audit B2-27; dcc: an instance field
  through C is E2124). }
function TPasCompletion.ValueOfTypeRef(const ARef: TPasComplTypeRef;
  ADepth: Integer): TPasComplTypeRef;
var
  LDef: Integer;
  LX: TSemaXType;
begin
  Result := ARef;
  Result.IsTypeRef := False;
  if ADepth > 16 then
    Exit;
  if ARef.OvSym <> NIL_SYM then
  begin
    LDef := OverlayStructDef(ARef.OvSym);
    if (LDef <> NIL_NODE) and
       (FModel.Tree.Nodes[LDef].Kind = nkClassOf) then
    begin
      Result := ResolveTypeRefNode(FModel.Tree.Nodes[LDef].FirstChild,
        ADepth + 1);
      Result.IsTypeRef := True;
    end;
    Exit;
  end;
  if (FProj <> nil) and XValid(ARef.X) then
  begin
    LX := FProj.ClassRefTargetX(ARef.X);
    if XValid(LX) then
    begin
      Result := ComplNilRef;
      Result.X := LX;
      Result.IsTypeRef := True;
    end;
  end;
end;

{ The element of a `for var X in Coll` loop (5.5.2), as the project's
  ForInElementX reads it: a struct's enumerator - GetEnumerator's result,
  then its Current - and otherwise the collection's element (an array, a
  string; audit A1-29). }
function TPasCompletion.ForInElementRef(ACollNode,
  ADepth: Integer): TPasComplTypeRef;
var
  LColl, LEnum: TPasComplTypeRef;
begin
  Result := ComplNilRef;
  if (ACollNode = NIL_NODE) or (ADepth > 16) then
    Exit;
  LColl := DesignatorType(ACollNode, ADepth + 1);
  if not ComplValid(LColl) then
    Exit;
  LColl.IsTypeRef := False;
  LEnum := MemberOf(LColl, 'getenumerator', ADepth + 1);
  if ComplValid(LEnum) then
  begin
    Result := MemberOf(LEnum, 'current', ADepth + 1);
    if ComplValid(Result) then
    begin
      Result.IsTypeRef := False;
      Exit;
    end;
  end;
  Result := ElementTypeOf(LColl, 1, ADepth + 1);
end;

{ The member SYMBOL one dot-hop names - the SEARCH half of MemberOf, shared
  with CallAt (which reports the symbol as a signature-help target where
  MemberOf converts it to a TYPE for the next hop). Three spaces, in order:
  a unit qualifier's exports (Resolve, not FindLocal - the deep lookup also
  reaches the compiler seeds joined into the interface scope, which is what
  makes `System.Delete` mean the intrinsic; a unit's own USES items live
  there too but are not exports, so skUnitRef never chains), the overlay's
  member scopes walking overlay heritage (64 hops, not 16 - same-unit
  interface chains really run past 16, see EnsureAncestry), then the bridged
  project ancestry (FindMemberX). False when nothing is found - including
  the longer-dotted-unit-name and pending-qualifier shapes, which are
  MemberOf's own business. }
function TPasCompletion.MemberSymOf(const ABase: TPasComplTypeRef;
  const AKey: string; ADepth: Integer;
  out AMid, ASym, ACtx: Integer): Boolean;
var
  LM: TPasSemaModel;
  LSym, LScope, LHop: Integer;
  LCur, LHeritage: TPasComplTypeRef;
begin
  Result := False;
  AMid := -1;
  ASym := NIL_SYM;
  ACtx := NIL_INST;
  if (ADepth > 16) or (AKey = '') then
    Exit;
  if ABase.UnitMid >= 0 then
  begin
    if FProj = nil then
      Exit;
    LM := ProjModel(ABase.UnitMid, 'MemberSymOfUnit');
    if LM.InterfaceScope = NIL_SCOPE then
      Exit;
    LSym := LM.Resolve(LM.InterfaceScope, AKey);
    if (LSym <> NIL_SYM) and (LM.Symbols[LSym].Kind = skUnitRef) then
      LSym := NIL_SYM;
    if LSym = NIL_SYM then
      Exit;
    AMid := ABase.UnitMid;
    ASym := LSym;
    Exit(True);
  end;
  if ABase.PendingUnit <> '' then
    Exit;
  LCur := ABase;
  for LHop := 1 to 64 do
  begin
    if LCur.OvSym = NIL_SYM then
      Break;
    LScope := FModel.Symbols[LCur.OvSym].MemberScope;
    if LScope <> NIL_SCOPE then
    begin
      LSym := FModel.FindLocalDeep(LScope, AKey);
      // The deep walk follows Phase 1's join into a same-unit ancestor; a
      // GENERIC one's member is reached through the heritage instead, whose
      // frame types its T (`Items[0].` in TObjectList<T: class> =
      // class(TList<T>) is TObjectList's T, not TList's open one).
      if (LSym <> NIL_SYM) and (FModel.Symbols[LSym].Scope <> NIL_SCOPE) then
      begin
        var LOwner := FModel.Scopes[FModel.Symbols[LSym].Scope].StructSym;
        if (LOwner <> NIL_SYM) and (LOwner <> LCur.OvSym) and
           (sfGeneric in FModel.Symbols[LOwner].Flags) then
          LSym := NIL_SYM;
      end;
      if LSym <> NIL_SYM then
      begin
        ASym := LSym;   // AMid stays -1: an overlay symbol
        Exit(True);
      end;
    end;
    LHeritage := OverlayHeritageRef(LCur.OvSym, ADepth + 1);
    if LHeritage.OvSym <> NIL_SYM then
    begin
      LCur.OvSym := LHeritage.OvSym;
      Continue;
    end;
    LCur.OvSym := NIL_SYM;
    LCur.X := LHeritage.X;
    Break;
  end;
  if XValid(LCur.X) and (FProj <> nil) then
    Result := FProj.FindMemberX(FProjMid, LCur.X, AKey, AMid, ASym, ACtx);
end;

// One member hop by NAME, for typing intermediate designator segments
// (`A.B.` needs typeof(A.B), which needs member B of typeof(A)).
function TPasCompletion.MemberOf(const ABase: TPasComplTypeRef;
  const AKey: string; ADepth: Integer): TPasComplTypeRef;
var
  LMemMid, LMemSym, LCtx, LRoutine: Integer;
  LFull: string;
begin
  Result := ComplNilRef;
  if (ADepth > 16) or (AKey = '') then
    Exit;
  if MemberSymOf(ABase, AKey, ADepth, LMemMid, LMemSym, LCtx) then
  begin
    // A constructor names the CONSTRUCTED type: T.Create is a T value - and
    // the NAMED base, not the hop the walk had reached when the constructor
    // was found: `TFoo.Create` constructs TFoo even when Create itself is
    // inherited from another unit's TBar - returning the hop typed the
    // value as TBar and silently lost TFoo's own members (the review's
    // finding #1).
    if LMemMid < 0 then
    begin
      LRoutine := RoutineNodeOf(FModel, LMemSym);
      if (LRoutine <> NIL_NODE) and
         (FModel.Tree.Source.VisibleToken(
            FModel.Tree.Nodes[LRoutine].FirstToken).Kind = tkConstructor)
      then
      begin
        Result := ABase;
        Result.IsTypeRef := False;
        Exit;
      end;
      Exit(TypeOfOverlaySym(LMemSym, ADepth + 1));
    end;
    if (FProj <> nil) and FProj.IsConstructorSym(LMemMid, LMemSym) then
    begin
      Result := ABase;
      Result.IsTypeRef := False;
      Exit;
    end;
    Exit(TypeOfProjectSym(LMemMid, LMemSym, LCtx, ADepth + 1));
  end;
  // No member - the qualifier may be the PREFIX of a longer dotted UNIT
  // name (`System.AnsiStrings.FloatToText`: `System` resolved as a unit,
  // but the real qualifier is System.AnsiStrings). Greedy longest-match;
  // when even the longer name is no unit yet, it stays PENDING for the
  // next segment (`System.Win.ComObj` needs two hops).
  if ABase.UnitMid >= 0 then
  begin
    if FProj = nil then
      Exit;
    LFull := ChangeFileExt(ExtractFileName(FProj.ModelFile(ABase.UnitMid)),
      '') + '.' + AKey;
    Result.UnitMid := BridgeUnitMid(LFull);
    if Result.UnitMid < 0 then
      Result.PendingUnit := LFull;
  end
  else if ABase.PendingUnit <> '' then
  begin
    LFull := ABase.PendingUnit + '.' + AKey;
    Result.UnitMid := BridgeUnitMid(LFull);
    if Result.UnitMid < 0 then
      Result.PendingUnit := LFull;
  end;
end;

// The type-definition node of a PROJECT type symbol - OverlayStructDef's
// cross-model twin; both read TPasSemaProject.TypeDefNodeIn (audit D1-33).
function TPasCompletion.ProjectTypeDef(const AX: TSemaXType): Integer;
begin
  Result := NIL_NODE;
  if (FProj = nil) or not XValid(AX) then
    Exit;
  Result := TPasSemaProject.TypeDefNodeIn(ProjModel(AX.UnitId,
    'ProjectTypeDef'), AX.Sym);
end;

{ The type of an array's ELEMENT node, read in the model that holds it
  (AMid = -1: the overlay), closed over ACtx: another anonymous array (the
  row of `array of array of T`), an inline pointer, `array of const`'s
  TVarRec (6.2.6), or a type reference. }
function TPasCompletion.ArrayElemRef(AMid, ADef, ACtx,
  ADepth: Integer): TPasComplTypeRef;
var
  LM: TPasSemaModel;
  LElem, LMid, LSym: Integer;
begin
  Result := ComplNilRef;
  if not SymModelOf(AMid, 'ArrayElemRef', LM) then
    Exit;
  if LM.Tree.Nodes[ADef].Aux = 1 then
  begin
    if BridgeName('tvarrec', LMid, LSym) then
      Result.X := XPlain(LMid, LSym);
    Exit;
  end;
  LElem := PasArrayElemNode(LM.Tree, ADef);
  if LElem = NIL_NODE then
    Exit;
  if LM.Tree.Nodes[LElem].Kind = nkArrayType then
    Exit(ComplArrRef(AMid, LElem, 0, ACtx));
  // The element as a VALUE (ValueOfTypeRef: an array of class references
  // indexes to a class reference, class side).
  if AMid < 0 then
    Exit(ValueOfTypeRef(ResolveTypeRefNode(LElem, ADepth + 1), ADepth + 1));
  if LM.Tree.Nodes[LElem].Kind = nkPointerType then
  begin
    Result.X := FProj.ResolveTypeExpr(AMid, LM.Tree.Nodes[LElem].FirstChild);
    Result.ViaPointer := True;
  end
  else
    Result.X := FProj.ResolveTypeExpr(AMid, LElem);
  if (ACtx <> NIL_INST) and XValid(Result.X) then
    Result.X := FProj.SubstX(Result.X, ACtx, 0);
  if not Result.ViaPointer then
    Result := ValueOfTypeRef(Result, ADepth + 1);
end;

{ typeof(base[i1, .., iN]) - ACount index expressions applied to ABase, one
  DIMENSION each (8.1.2: `M[I, J]` is `M[I][J]`): an array consumes as many
  as it has index types and hands the rest to its element - a row of a
  multi-dimensional array, which has no type of its own, stays an ArrNode
  with ArrSkip dimensions consumed (audit A1-25); a string yields its
  character (AnsiChar for the 1-byte kinds, the project's StringElementX); a
  pointer its pointee (`P[I]`); a struct with a DEFAULT array property that
  property's type (13.1.2; the property takes the bracket's indices). Alias
  links are chased on both sides - an own-unit `TFooArray = TArray<TFoo>`
  was the everyday shape the overlay half missed (audit A1-23); an overlay
  struct's default property is asked of its last-good project twin. Where
  no ExprTypeX cache exists - every live overlay - this is the only answer. }
function TPasCompletion.ElementTypeOf(const ABase: TPasComplTypeRef;
  ACount, ADepth: Integer): TPasComplTypeRef;
var
  LCur, LNext: TPasComplTypeRef;
  LM: TPasSemaModel;
  LRem, LHop, LDef, LDims, LPropMid, LPropSym: Integer;
  LX: TSemaXType;
  LOwner: TSemaXType;
begin
  Result := ComplNilRef;
  if ADepth > 16 then
    Exit;
  LCur := ABase;
  LCur.IsTypeRef := False;
  LRem := ACount;
  for LHop := 1 to 64 do
  begin
    if LRem <= 0 then
      Exit(LCur);   // a value - class side when it is a class reference
    // An anonymous array definition in hand: consume its dimensions.
    if LCur.ArrNode <> NIL_NODE then
    begin
      if not SymModelOf(LCur.ArrMid, 'ElementTypeOf', LM) then
        Exit;
      LDims := PasArrayDims(LM.Tree, LCur.ArrNode) - LCur.ArrSkip;
      if LRem < LDims then
      begin
        Result := LCur;
        Inc(Result.ArrSkip, LRem);
        Exit;
      end;
      Dec(LRem, LDims);
      LCur := ArrayElemRef(LCur.ArrMid, LCur.ArrNode, LCur.ArrCtx, ADepth);
      Continue;
    end;
    // An inline `^T` value is resolved to T (the implicit deref); indexing
    // it is pointer indexing, which takes that level.
    if LCur.ViaPointer then
    begin
      LCur.ViaPointer := False;
      Dec(LRem);
      Continue;
    end;
    if LCur.OvSym <> NIL_SYM then
    begin
      LDef := OverlayStructDef(LCur.OvSym);
      if LDef = NIL_NODE then
        Exit;
      case FModel.Tree.Nodes[LDef].Kind of
        nkArrayType:
          LCur := ComplArrRef(-1, LDef, 0, NIL_INST);
        nkPointerType:
          begin
            LCur := ResolveTypeRefNode(FModel.Tree.Nodes[LDef].FirstChild,
              ADepth + 1);
            LCur.IsTypeRef := False;
            Dec(LRem);
          end;
        nkIdent, nkMember, nkTypeArgs:
          begin
            // An alias - chase it and index THAT.
            LNext := ResolveTypeRefNode(LDef, ADepth + 1);
            if LNext.OvSym = LCur.OvSym then
              Exit;
            LCur := LNext;
          end;
        nkClassType, nkRecordType, nkObjectType, nkInterfaceType:
          begin
            // A default array property: asked of the last-good twin.
            LX := OwnModelTypeX(LCur.OvSym);
            if not XValid(LX) then
              Exit;
            LCur := ComplNilRef;
            LCur.X := LX;
          end;
      else
        Exit;
      end;
      Continue;
    end;
    if (FProj = nil) or not XValid(LCur.X) then
      Exit;
    LM := ProjModel(LCur.X.UnitId, 'ElementTypeOf');
    // Indexing a STRING yields its character type - AnsiChar for the 1-byte
    // kinds, `string[N]` and the code-page strings included (7.2.1).
    LX := FProj.StringElementX(LCur.X.UnitId, LCur.X);
    if XValid(LX) then
    begin
      LCur := ComplNilRef;
      LCur.X := LX;
      Dec(LRem);
      Continue;
    end;
    // A character pointer's element is its character (no declaration node).
    if LM.Symbols[LCur.X.Sym].Kind = skBuiltinType then
    begin
      LX := FProj.PointeeX(LCur.X);
      LCur := ComplNilRef;
      LCur.X := LX;
      Dec(LRem);
      Continue;
    end;
    LDef := ProjectTypeDef(LCur.X);
    if LDef = NIL_NODE then
      Exit;
    case LM.Tree.Nodes[LDef].Kind of
      nkArrayType:
        LCur := ComplArrRef(LCur.X.UnitId, LDef, 0, LCur.X.Inst);
      nkPointerType:
        begin
          LX := FProj.PointeeX(LCur.X);   // P[I] - pointer indexing
          LCur := ComplNilRef;
          LCur.X := LX;
          Dec(LRem);
        end;
      nkIdent, nkMember, nkTypeArgs:
        begin
          // An alias - chase it and index THAT.
          LX := FProj.ResolveTypeExpr(LCur.X.UnitId, LDef);
          if (LCur.X.Inst <> NIL_INST) and XValid(LX) then
            LX := FProj.SubstX(LX, LCur.X.Inst, 0);
          if not XValid(LX) or ((LX.UnitId = LCur.X.UnitId) and
             (LX.Sym = LCur.X.Sym)) then
            Exit;
          LCur := ComplNilRef;
          LCur.X := LX;
        end;
      nkClassType, nkRecordType, nkObjectType, nkInterfaceType:
        begin
          // `L[I]` reads L.Items[I]: the default property's declared type is
          // the element's, closed over the frame it was found in; the
          // property takes the bracket's indices (a comma list read on past
          // it is dcc's E2016 - typed leniently, as the project typer does).
          if not FProj.DefaultArrayPropX(LCur.X, LPropMid, LPropSym,
             LOwner) then
            Exit;
          LCur := TypeOfProjectSym(LPropMid, LPropSym, LOwner.Inst,
            ADepth + 1);
          LRem := 0;
        end;
    else
      Exit;
    end;
  end;
end;

// typeof(base^): the pointee - project pointers via PointeeX, overlay
// pointer types via their definition node, alias links chased on both
// sides (`PRecAlias = PRec`, audit A1-23), and an inline `^T` value, which
// is resolved to T already, just loses its pointer mark (audit A1-24).
function TPasCompletion.PointeeTypeOf(const ABase: TPasComplTypeRef;
  ADepth: Integer): TPasComplTypeRef;
var
  LDef: Integer;
  LNext: TPasComplTypeRef;
begin
  Result := ComplNilRef;
  if ADepth > 16 then
    Exit;
  if ABase.ViaPointer then
  begin
    Result := ABase;
    Result.ViaPointer := False;
    Exit;
  end;
  if ABase.OvSym <> NIL_SYM then
  begin
    LDef := OverlayStructDef(ABase.OvSym);
    if LDef = NIL_NODE then
      Exit;
    case FModel.Tree.Nodes[LDef].Kind of
      nkPointerType:
        Result := ResolveTypeRefNode(FModel.Tree.Nodes[LDef].FirstChild,
          ADepth + 1);
      nkIdent, nkMember, nkTypeArgs:
        begin
          LNext := ResolveTypeRefNode(LDef, ADepth + 1);
          if LNext.OvSym <> ABase.OvSym then
            Result := PointeeTypeOf(LNext, ADepth + 1);
        end;
    end;
    Exit;
  end;
  if (FProj <> nil) and XValid(ABase.X) then
    Result.X := FProj.PointeeX(ABase.X);
end;

// The type-definition node of an overlay type symbol (TypeDefNodeIn: the
// child after the name and the generic parameters; an anonymous struct's own
// node).
function TPasCompletion.OverlayStructDef(AOvSym: Integer): Integer;
begin
  Result := TPasSemaProject.TypeDefNodeIn(FModel, AOvSym);
end;

{ The symbol a designator names, for the nkIndex rule below: an overlay
  binding (AMid = -1), the analysis's cross-unit one, or the member a dot
  hop finds. False when nothing names it. }
function TPasCompletion.DesignatorSymOf(ANode, ADepth: Integer;
  out AMid, ASym: Integer): Boolean;
var
  LExt: TPasExtRef;
  LChild, LCtx: Integer;
begin
  Result := False;
  AMid := -1;
  ASym := NIL_SYM;
  if (ANode = NIL_NODE) or (ADepth > 16) then
    Exit;
  case FModel.Tree.Nodes[ANode].Kind of
    nkIdent:
      begin
        ASym := FModel.RefMap[ANode];
        if ASym <> NIL_SYM then
          Exit(True);
        if FModel.ExtRefMap.TryGetValue(ANode, LExt) then
        begin
          AMid := LExt.UnitId;
          ASym := LExt.Sym;
          Exit(True);
        end;
        // Unbound on the overlay - an inherited member Phase 1 could not
        // reach (`Items[0]` through a generic ancestor): the same lookup
        // DesignatorType typed it by.
        Result := BareNameSym(ANode, ADepth + 1, AMid, ASym, LCtx);
      end;
    nkMember:
      begin
        LChild := FModel.Tree.Nodes[ANode].FirstChild;
        if LChild = NIL_NODE then
          Exit;
        Result := MemberSymOf(DesignatorType(LChild, ADepth + 1),
          FModel.Tree.NodeNameLower(FModel.Tree.Nodes[LChild].NextSibling),
          ADepth + 1, AMid, ASym, LCtx);
      end;
    nkParen:
      Result := DesignatorSymOf(FModel.Tree.Nodes[ANode].FirstChild,
        ADepth + 1, AMid, ASym);
  end;
end;

{ Does the designator ANode name an ARRAY property (13.1.2)? Then the
  brackets after it consume the property's parameters and the property's
  declared type IS the result - the rule CrossType's nkIndex applies
  (TPasSemaProject.IsArrayPropertySym); an overlay property reads its own
  declaration. }
function TPasCompletion.IsArrayPropertyDesignator(ANode,
  ADepth: Integer): Boolean;
var
  LMid, LSym: Integer;
begin
  Result := False;
  if not DesignatorSymOf(ANode, ADepth, LMid, LSym) then
    Exit;
  if LMid >= 0 then
    Exit((FProj <> nil) and FProj.IsArrayPropertySym(LMid, LSym));
  if FModel.Symbols[LSym].Kind <> skProperty then
    Exit;
  // `property Items;` - typeless: the parameters are the republished
  // declaration's, which only the analysis links.
  if FIsProjectModel then
    Exit(FProj.IsArrayPropertySym(FProjMid, LSym));
  Result := PasPropertyHasParams(FModel.Tree, FModel.Symbols[LSym].DeclNode);
end;

// Where an overlay type's member walk goes NEXT: the first heritage entry
// (which may itself be another overlay type, or bridge into the project),
// the implicit TObject/IInterface/IDispatch root for a heritage-less
// class/interface, or the target of a type alias. Invalid = walk ends.
function TPasCompletion.OverlayHeritageRef(AOvSym, ADepth: Integer):
  TPasComplTypeRef;
var
  LDef, LChild, LMid, LSym: Integer;
  LRootName: string;
begin
  Result := ComplNilRef;
  if ADepth > 16 then
    Exit;
  LDef := OverlayStructDef(AOvSym);
  if LDef = NIL_NODE then
    Exit;
  case FModel.Tree.Nodes[LDef].Kind of
    nkClassType, nkInterfaceType, nkRecordType, nkObjectType, nkHelperType:
      begin
        // A struct's ancestor is its FIRST child when that is a type
        // reference (PasHeritageRef - never a record's `end align`
        // operand); a helper's leading run ends with its extended type.
        if FModel.Tree.Nodes[LDef].Kind = nkHelperType then
        begin
          LChild := FModel.Tree.Nodes[LDef].FirstChild;
          if (LChild <> NIL_NODE) and not (FModel.Tree.Nodes[LChild].Kind in
             [nkIdent, nkMember, nkTypeArgs]) then
            LChild := NIL_NODE;
        end
        else
          LChild := PasHeritageRef(FModel.Tree, LDef);
        if LChild <> NIL_NODE then
        begin
          // For a helper, walk to the last leading ref.
          if FModel.Tree.Nodes[LDef].Kind = nkHelperType then
            while (FModel.Tree.Nodes[LChild].NextSibling <> NIL_NODE) and
                  (FModel.Tree.Nodes[
                    FModel.Tree.Nodes[LChild].NextSibling].Kind in
                    [nkIdent, nkMember, nkTypeArgs]) do
              LChild := FModel.Tree.Nodes[LChild].NextSibling;
          Exit(ResolveTypeRefNode(LChild, ADepth + 1));
        end;
        LRootName := '';
        case FModel.Tree.Nodes[LDef].Kind of
          nkClassType:
            LRootName := 'tobject';
          nkInterfaceType:
            if FModel.Tree.Nodes[LDef].Aux = 1 then
              LRootName := 'idispatch'
            else
              LRootName := 'iinterface';
        end;
        // System's root, as the project's heritage hop (11.1.1): a TObject
        // the uses clause names is not it.
        if (LRootName <> '') and (FProj <> nil) and (FProjMid >= 0) and
           (FProj.ImplicitRootX(FProjMid, LRootName, LMid, LSym) or
            BridgeName(LRootName, LMid, LSym)) then
        begin
          Result.X := XPlain(LMid, LSym);
          Result.IsTypeRef := True;
        end;
      end;
    nkIdent, nkMember, nkTypeArgs:
      Result := ResolveTypeRefNode(LDef, ADepth + 1);   // type alias
    nkPointerType, nkClassOf:
      // `PFoo = ^TFoo` / `TFooClass = class of TFoo`: member access walks
      // into the pointee / referenced class, the same implicit hop
      // FindMemberX makes for these kinds.
      Result := ResolveTypeRefNode(FModel.Tree.Nodes[LDef].FirstChild,
        ADepth + 1);
  end;
end;

{ ---- collection ----------------------------------------------------------- }

{ AKey is the caller's ALREADY-NORMALIZED dedup key (a symbol's NameLower, a
  keyword's own lowercase spelling). Not derived here from AName on purpose:
  this runs once per CANDIDATE, thousands of times per request, and PasNameKey
  allocates - the exact "cheap-looking normalization on a shared hot path"
  this codebase has paid for three times (see FindLocal's own comment). }
// Is the routine ASym declared `override`? A flag the resolver stamps from
// either heading - kept by a text-demoted model, so no text is read.
function TPasCompletion.IsOverrideSym(AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
begin
  if ASym = NIL_SYM then
    Exit(False);
  if AMid < 0 then
    LM := FModel
  else
    LM := ProjModel(AMid, 'IsOverrideSym');
  Result := sfOverrideDirective in LM.Symbols[ASym].Flags;
end;

procedure TPasCompletion.AddItem(const AName, AKey: string;
  AKind: TSemaSymbolKind; ABucket: TPasComplBucket; AMid, ASym, ACtx: Integer);
var
  LIdx, LRow: Integer;
  LParams: string;
begin
  if AName = '' then
    Exit;
  if FSeen = nil then   // CompleteAt creates it; any other caller here
    FSeen := TDictionary<string, Integer>.Create;
  if FSeen.TryGetValue(AKey, LIdx) then
  begin
    // First hit wins (buckets run in precedence order); a same-name routine
    // is an overload of the one already listed, not a new row - unless it is
    // the ancestor slot an `override` already listed redeclares: the walks
    // go from the type to its ancestors, so each override met earlier stands
    // for one declaration met later, and `Destroy` over TList, TEnumerable
    // and TObject is one signature, not three.
    if (AKind = skRoutine) and (FItems[LIdx].Kind = skRoutine) and
       (FItems[LIdx].Bucket <> cbKeyword) then
    begin
      if FSplitOverloads then
      begin
        // A row per signature: the same parameter list as a row already
        // under this name is that row's override or redeclaration. By the
        // list, not by the override count above - an override met before
        // ANOTHER overload of its ancestor would cancel the wrong one.
        // Read only on a collision, which is a same-name routine.
        LParams := '';
        if ASym <> NIL_SYM then
          LParams := LowerCase(SymSignature(AMid, ASym).ParamsText);
        LRow := LIdx;
        while True do
        begin
          if RowParams(LRow) = LParams then
            Exit;
          if FNextSame[LRow] < 0 then
            Break;
          LRow := FNextSame[LRow];
        end;
        AppendItem(AName, AKind, ABucket, AMid, ASym, ACtx);
        FNextSame[LRow] := FCount - 1;
        FParamsOf[FCount - 1] := LParams;
        FParamsKnown[FCount - 1] := True;
        Exit;
      end;
      if FPendingOverrides[LIdx] > 0 then
        Dec(FPendingOverrides[LIdx])
      else
        Inc(FItems[LIdx].Overloads);
      if IsOverrideSym(AMid, ASym) then
        Inc(FPendingOverrides[LIdx]);
    end;
    Exit;
  end;
  AppendItem(AName, AKind, ABucket, AMid, ASym, ACtx);
  FSeen.Add(AKey, FCount - 1);
end;

procedure TPasCompletion.AppendItem(const AName: string;
  AKind: TSemaSymbolKind; ABucket: TPasComplBucket; AMid, ASym, ACtx: Integer);
begin
  if FCount = Length(FItems) then
  begin
    if FCount = 0 then
      SetLength(FItems, 64)
    else
      SetLength(FItems, FCount * 2);
    SetLength(FPendingOverrides, Length(FItems));
    if FSplitOverloads then
    begin
      SetLength(FNextSame, Length(FItems));
      SetLength(FParamsOf, Length(FItems));
      SetLength(FParamsKnown, Length(FItems));
    end;
  end;
  FPendingOverrides[FCount] := Ord((AKind = skRoutine) and
    IsOverrideSym(AMid, ASym));
  if FSplitOverloads then
  begin
    FNextSame[FCount] := -1;
    FParamsKnown[FCount] := False;
  end;
  FItems[FCount].Name := AName;
  FItems[FCount].Kind := AKind;
  FItems[FCount].Bucket := ABucket;
  FItems[FCount].Mid := AMid;
  FItems[FCount].Sym := ASym;
  FItems[FCount].Ctx := ACtx;
  FItems[FCount].Overloads := 0;
  FItems[FCount].Match := cmOther;
  FItems[FCount].Conv := 0;
  Inc(FCount);
end;

// SplitOverloads: row ARow's parameter list, lower-cased, read once.
function TPasCompletion.RowParams(ARow: Integer): string;
begin
  if not FParamsKnown[ARow] then
  begin
    FParamsOf[ARow] := '';
    if FItems[ARow].Sym <> NIL_SYM then
      FParamsOf[ARow] := LowerCase(
        SymSignature(FItems[ARow].Mid, FItems[ARow].Sym).ParamsText);
    FParamsKnown[ARow] := True;
  end;
  Result := FParamsOf[ARow];
end;

{ The intrinsics a constant expression may call (dcc's list: Abs, Chr, Hi,
  High, Length, Lo, Low, Odd, Ord, Pred, Ptr, Round, SizeOf, Succ, Swap,
  Trunc) - the routines a `case` label may name. }
function IsConstIntrinsic(const ANameLower: string): Boolean;
const
  NAMES: array[0..15] of string = ('abs', 'chr', 'hi', 'high', 'length',
    'lo', 'low', 'odd', 'ord', 'pred', 'ptr', 'round', 'sizeof', 'succ',
    'swap', 'trunc');
begin
  for var LName in NAMES do
    if LName = ANameLower then
      Exit(True);
  Result := False;
end;

procedure TPasCompletion.AddSym(AMid, ASym, ACtx: Integer;
  ABucket: TPasComplBucket);
var
  LM: TPasSemaModel;
begin
  if AMid < 0 then
    LM := FModel
  else
    LM := ProjModel(AMid, 'AddSym');
  // Labels complete after `goto` and NOWHERE else - and after `goto`,
  // nothing but a label means anything.
  if (LM.Symbols[ASym].Kind = skLabel) <> (FContext = ccLabel) then
    Exit;
  // A `class operator` is never reachable by name (9.3.1: `V.Add`,
  // `TVec.Add(V, V)` are E2003; audit E2-47), and a class constructor or
  // destructor can never be named (15.1.5; audit B2-29).
  if (LM.Symbols[ASym].Kind = skRoutine) and
     ((LM.RoutineHead(ASym) = rhOperator) or LM.IsClassCtorDtor(ASym)) then
    Exit;
  // The right side of `:=` or a comparison takes a value: a procedure (or
  // a destructor) is none, unless the left side is procedural - then it is
  // the value assigned, and FNoProcedures is off (pastree-lsp, 2026-11-04).
  if FNoProcedures and (LM.Symbols[ASym].Kind = skRoutine) then
  begin
    if LM.RoutineHead(ASym) in [rhProcedure, rhDestructor] then
      Exit;
    // A seed has no head token: the table says whether it is a function
    // (Str, Inc, Exit are procedures; High, Copy, Abs functions).
    if sfBuiltin in LM.Symbols[ASym].Flags then
    begin
      var LSig: TPasBuiltinSig;
      if PasBuiltinSignature(LM.Symbols[ASym].NameLower, LSig) and
         not LSig.IsFunction then
        Exit;
    end;
  end;
  // A `var` / `out` argument takes a variable: no constant, no function,
  // no procedure (a type or a unit name may still start one: `TFoo.Count`).
  if FArgByRef and
     (LM.Symbols[ASym].Kind in [skConst, skEnumValue, skRoutine]) then
    Exit;
  // A `case` label is a constant expression: no variable, no typed
  // constant (E2026), no routine but the intrinsics a constant expression
  // may call (`Ord('A')`, `High(TKind)`).
  if FConstOnly then
    case LM.Symbols[ASym].Kind of
      skVar, skParam, skField, skProperty:
        Exit;
      skConst:
        if LM.Symbols[ASym].TypeNode <> NIL_NODE then
          Exit;
      skRoutine:
        if not (sfBuiltin in LM.Symbols[ASym].Flags) or
           not IsConstIntrinsic(LM.Symbols[ASym].NameLower) then
          Exit;
    end;
  // Type positions take what can name a type - consts and enum values
  // included, because a SUBRANGE type's bounds are constant expressions
  // (`TVCLElements = teCategoryButtons..teTextLabel`, 2.2.5).
  if (FContext = ccType) and not (LM.Symbols[ASym].Kind in
    [skType, skBuiltinType, skUnitRef, skGenericParam, skConst,
     skEnumValue]) and
     // ... and on the right of `is` / `as`, a class-reference value
     // (`O is AClass`, a function returning one) - dcc takes it there.
     not ((FTypePos = tpIsAs) and (LM.Symbols[ASym].Kind in [skVar, skParam,
       skField, skProperty, skConst, skRoutine]) and
       IsClassRefValue(AMid, ASym, ACtx)) then
    Exit;
  // A ranked type position (TypePosAt) names a type - no subrange bound -
  // of the categories that can stand there (TypePosAdmits): a class or an
  // interface after `is` / `as` and in a constraint, a class in a handler
  // and an attribute (pastree-lsp COMPLETION.md, "Type positions").
  // A type declaration's right side (`T = |`) keeps a subrange's low bound:
  // an enumeration value, a true constant - no typed one (E2026); not after
  // `= type`, which names a type (E2029).
  if FTypePos <> tpNone then
    case LM.Symbols[ASym].Kind of
      skEnumValue:
        if (FTypePos <> tpTypeDecl) or FTypeAfterType then
          Exit;
      skConst:
        if FTypePos = tpTypeDecl then
        begin
          if FTypeAfterType or (LM.Symbols[ASym].TypeNode <> NIL_NODE) then
            Exit;
        end
        // After `is` / `as` a constant only of a class-reference type: the
        // filter above passes every constant for a subrange's sake, and a
        // unit's string constant reached `O is |` (0.169.0).
        else if (FTypePos <> tpIsAs) or
           not IsClassRefValue(AMid, ASym, ACtx) then
          Exit;
      skType, skBuiltinType:
        begin
          if not TypePosAdmits(LM.Symbols[ASym].TypeCat) then
            Exit;
          // A position that takes one category or a few: an alias the
          // symbol does not categorize (`TCanvasDC = HDC`, `HDC = type
          // UINT_PTR`, `EListError = System.SysUtils.EListError`,
          // `TFoos = TArray<TFoo>`) is judged by the type it names, through
          // a distinct alias too (an IDE test: `if Self is t|` listed
          // both), the buffer's own included (a constraint listed a
          // `TArray<>` alias of its unit). A helper is dropped below.
          if FTypePos in [tpIsAs, tpHandler, tpAttribute, tpConstraint,
             tpImplements, tpClassOf, tpSetOf, tpHelper] then
            if LM.Symbols[ASym].TypeCat = tcUnknown then
            begin
              var LCatT := AliasCatOf(AMid, ASym);
              if (LCatT <> tcUnknown) and not TypePosAdmits(LCatT) then
                Exit;
            end;
          // A record helper extends a dynamic array, never a static one
          // (E2474).
          if (FTypePos = tpHelper) and FHelperRecord and
             (LM.Symbols[ASym].TypeCat = tcArray) and (FProj <> nil) then
          begin
            var LArrX: TSemaXType;
            if AMid >= 0 then
              LArrX := FProj.CanonTypeX(XPlain(AMid, ASym))
            else
              LArrX := OwnModelTypeX(ASym);
            if XValid(LArrX) and not FProj.IsDynArrayTypeX(LArrX) then
              Exit;
          end;
        end;
    end;
  // A helper is named as a type only in a generic argument, a pointer's
  // base and a type declaration's right side (FHelperOk); everywhere else
  // dcc 37 rejects it - E2527 in a declaration, E2021 / E2474 in a
  // heritage list and as a helper's type, E2015 after `is` / `as`.
  if (FContext = ccType) and not FHelperOk and IsHelperSym(LM, ASym) then
    Exit;
  // ... except where the type must be NAMED: `procedure P(A: 1..2)` and
  // `function F: 1..2` are E2029, `(A: K)` E2005 (local/probe-cc P5a-P5e).
  if FTypeNameOnly and (LM.Symbols[ASym].Kind in [skConst, skEnumValue]) then
    Exit;
  // A declaration's `Name: |` lists types alone (pastree-lsp, 2026-10-22) -
  // a subrange there is legal but written by hand.
  if FColonType and (LM.Symbols[ASym].Kind in [skConst, skEnumValue]) then
    Exit;
  // A heritage list names a class and interfaces (`class(`) or interfaces
  // (`interface(`), a type of any other category does not compile there
  // (pastree-lsp, 2026-10-22). A type whose category is not known - an alias
  // the typer could not follow - stays listed rather than be wrongly hidden;
  // a unit name stays as the qualifier of one. A generic parameter cannot be
  // an ancestor.
  if FHeritage <> nkError then
    case LM.Symbols[ASym].Kind of
      skUnitRef:
        ;
      skType, skBuiltinType:
        begin
          var LCatH := LM.Symbols[ASym].TypeCat;
          // An alias by the type it names (TBytes, PByte, `TLocaleID =
          // LCID`, a record through an alias: the audit found one in 79% of
          // heritage lists).
          if (LCatH = tcUnknown) and (LM.Symbols[ASym].Kind = skType) then
            LCatH := AliasCatOf(AMid, ASym);
          if not (LCatH in [tcUnknown, tcInterface]) and
             ((FHeritage = nkInterfaceType) or (LCatH <> tcClass)) then
            Exit;
        end;
    else
      Exit;
    end;
  // ... and never the type whose list it is - nor the type `T = |` and
  // `TH = class helper for |` declare (FHeritageDecl).
  if (FHeritageDecl <> NIL_NODE) and (AMid < 0) and
     (LM.Symbols[ASym].DeclNode <> NIL_NODE) and
     ((LM.Symbols[ASym].DeclNode = FHeritageDecl) or
      IsDescendantNode(LM.Symbols[ASym].DeclNode, FHeritageDecl)) then
    Exit;
  // `inherited X` names a method or a property of an ancestor; a field, a
  // class var, a nested type or a const there is E2096 Method identifier
  // expected (12.1.2; local/probe-cc P7).
  if (FContext = ccInherited) and
     not (LM.Symbols[ASym].Kind in [skRoutine, skProperty]) then
    Exit;
  // Property accessor positions take members of the right SHAPE only:
  // fields always, routines split by head - a function can stand after
  // `read` and `stored`, a procedure after `write`, nothing else (13.1.1).
  if FContext in [ccPropRead, ccPropWrite, ccPropStored] then
    case LM.Symbols[ASym].Kind of
      skField, skVar:
        ;
      skRoutine:
        if ((FContext in [ccPropRead, ccPropStored]) and
            (SymHeadWord(LM, ASym) <> 'function')) or
           ((FContext = ccPropWrite) and
            (SymHeadWord(LM, ASym) <> 'procedure')) then
          Exit;
    else
      Exit;
    end;
  // A used unit is listed under its FULL name (`System.SysUtils` for a
  // `uses SysUtils` the unit scope names completed) - the row is how a
  // qualified name gets written, and the short one is what was typed
  // already. Keyed by the written name, so the dedup is unchanged.
  if LM.Symbols[ASym].Kind = skUnitRef then
    AddItem(UnitRefFullName(LM, AMid, ASym), LM.Symbols[ASym].NameLower,
      skUnitRef, ABucket, AMid, ASym, ACtx)
  else
    AddItem(LM.Symbols[ASym].Name, LM.Symbols[ASym].NameLower,
      LM.Symbols[ASym].Kind, ABucket, AMid, ASym, ACtx);
end;

{ The name a unit-ref symbol's unit is FILED under - the resolved model's
  file name, which carries the namespace the unit scope names (-NS) or a
  namespace-prefix lookup added to the written name. Only a namespace
  completion counts: an ALIAS (-A, `WinTypes` for Winapi.Windows) is not a
  qualifier dcc accepts in place of the written name, so anything but
  `<namespace>.<written>` keeps the written name, as does an unresolved
  unit. }
function TPasCompletion.UnitRefFullName(AModel: TPasSemaModel;
  AMid, ASym: Integer): string;
var
  LIdx, LUid: Integer;
  LFull: string;
begin
  Result := AModel.Symbols[ASym].Name;
  if FProj = nil then
    Exit;
  for LIdx := 0 to High(AModel.UsesList) do
    if AModel.UsesList[LIdx].Sym = ASym then
    begin
      Result := AModel.UsesList[LIdx].NameFull;
      if AMid < 0 then
        LUid := BridgeUnitMid(Result)
      else
        LUid := AModel.UsesList[LIdx].UnitId;
      if (LUid >= 0) and (LUid < FProj.ModelCount) then
      begin
        LFull := ChangeFileExt(ExtractFileName(FProj.ModelFile(LUid)), '');
        if (Length(LFull) > Length(Result)) and
           SameText(Copy(LFull, Length(LFull) - Length(Result), MaxInt),
             '.' + Result) then
          Result := LFull;
      end;
      Exit;
    end;
end;

{ `System.|`, `Winapi.|`: the next SEGMENTS of the longer dotted unit names
  under ANamespace - `SysUtils`, `Classes`, `Win` (of System.Win.ComObj) -
  that MemberOf would resolve the qualifier to. Only units this file USES
  above the caret, and the file's own name: qualifying a unit requires
  having used it (BridgeUnitMid), so a namespace child nobody imported
  would be E2003 the moment it was written. First hit wins against the
  unit's own exports, as in MemberOf. }
procedure TPasCompletion.CollectNamespaceChildren(const ANamespace: string);

  procedure AddFrom(const AFull: string);
  var
    LRest: string;
    LDot, LUid: Integer;
  begin
    if (Length(AFull) <= Length(ANamespace) + 1) or
       not SameText(Copy(AFull, 1, Length(ANamespace) + 1),
         ANamespace + '.') then
      Exit;
    LRest := Copy(AFull, Length(ANamespace) + 2, MaxInt);
    LDot := Pos('.', LRest);
    if LDot > 0 then
    begin
      SetLength(LRest, LDot - 1);
      LUid := -1;
    end
    else
      LUid := BridgeUnitMid(AFull);
    if LRest <> '' then
      AddItem(LRest, PasNameKey(LRest), skUnitRef, cbUnitName, LUid,
        NIL_SYM, NIL_INST);
  end;

var
  LIdx, LTok: Integer;
begin
  if (FProj = nil) or (ANamespace = '') then
    Exit;
  for LIdx := 0 to High(FModel.UsesList) do
  begin
    if FModel.UsesList[LIdx].NameNode <> NIL_NODE then
    begin
      LTok := FModel.Tree.Nodes[FModel.UsesList[LIdx].NameNode].FirstToken;
      if (FCaretVis >= 0) and (LTok > FCaretVis) then
        Continue;
    end;
    if FModel.UsesList[LIdx].Sym <> NIL_SYM then
      AddFrom(UnitRefFullName(FModel, -1, FModel.UsesList[LIdx].Sym))
    else
      AddFrom(FModel.UsesList[LIdx].NameFull);
  end;
  if FProjMid >= 0 then
    AddFrom(ChangeFileExt(ExtractFileName(FProj.ModelFile(FProjMid)), ''));
end;

procedure TPasCompletion.AddKeywords(const AWords: array of string);
var
  LIdx: Integer;
begin
  // The word lists are lowercase already - they are their own keys.
  for LIdx := 0 to High(AWords) do
    AddItem(AWords[LIdx], AWords[LIdx], skKeyword, cbKeyword, -1, NIL_SYM,
      NIL_INST);
end;

function TPasCompletion.RoutineNodeOf(AModel: TPasSemaModel;
  ASym: Integer): Integer;
begin
  Result := AModel.Symbols[ASym].DeclNode;
  while (Result <> NIL_NODE) and
        (AModel.Tree.Nodes[Result].Kind <> nkRoutine) do
    Result := AModel.Tree.Nodes[Result].Parent;
end;

// Can this member be named on the TYPE itself (TFoo.X)? Constructors, class
// methods (nkRoutine.Aux = 1), class properties (nkPropertyDecl.Aux = 1),
// class vars (their nkVarSec's Aux = 1), nested types, consts, enum values.
function TPasCompletion.ClassSideMember(AModel: TPasSemaModel;
  ASym: Integer): Boolean;
var
  LNode: Integer;
begin
  case AModel.Symbols[ASym].Kind of
    skType, skConst, skEnumValue:
      Result := True;
    skVar, skField:
      Result := AModel.IsClassVar(ASym);
    skRoutine:
      begin
        // RoutineHead, not a raw VisibleToken read: this runs during member
        // LIST BUILDING over foreign models, which may be text-demoted - the
        // head word is exactly what DemoteText snapshots per symbol.
        LNode := RoutineNodeOf(AModel, ASym);
        Result := (LNode <> NIL_NODE) and
          ((AModel.Tree.Nodes[LNode].Aux = 1) and
             (AModel.RoutineHead(ASym) <> rhDestructor) or
           (AModel.RoutineHead(ASym) = rhConstructor));
      end;
    skProperty:
      begin
        LNode := AModel.Symbols[ASym].DeclNode;
        if LNode <> NIL_NODE then
          LNode := AModel.Tree.Nodes[LNode].Parent;
        Result := (LNode <> NIL_NODE) and
          (AModel.Tree.Nodes[LNode].Kind = nkPropertyDecl) and
          (AModel.Tree.Nodes[LNode].Aux = 1);
      end;
  else
    Result := False;
  end;
end;

// The caret struct's bridged ancestor chain, for the protected-visibility
// test - built once per request, only when a member list needs it.
procedure TPasCompletion.EnsureAncestry(ACaretScope: Integer);
var
  LOv, LDepth: Integer;
  LRef: TPasComplTypeRef;
  LX: TSemaXType;
  LEntry: TPasExtRef;
begin
  if FAncestryBuilt then
    Exit;
  FAncestryBuilt := True;
  FAncestry := nil;
  FCaretStructs := nil;
  FOverlayAncestry := nil;
  LOv := EnclosingStructSym(ACaretScope);
  if LOv = NIL_SYM then
    Exit;
  // The struct NEST: the innermost class, then each class it is declared
  // inside (a nested class's DeclNode sits in the outer's member scope,
  // whose StructSym names the outer). Winapi-scale code nests freely.
  LDepth := 0;
  while (LOv <> NIL_SYM) and (LDepth < 8) do
  begin
    FCaretStructs := FCaretStructs + [LOv];
    Inc(LDepth);
    if FModel.Symbols[LOv].Scope = NIL_SCOPE then
      Break;
    LOv := FModel.Scopes[FModel.Symbols[LOv].Scope].StructSym;
    if (Length(FCaretStructs) > 0) and
       (LOv = FCaretStructs[High(FCaretStructs)]) then
      Break;
  end;
  // The bridged ancestry of EVERY nest level (a nested class's method also
  // reaches the OUTER class's inherited members - the corpus's
  // TWinGestureEngine.TRealTimeStylus method calling the engine's inherited
  // IsGesture bare).
  //
  // LX starts INVALID and stays so when a walk never leaves the overlay -
  // the corpus oracle caught exactly that as stack garbage flowing into
  // AncestorOfX when a same-unit interface chain ran past the old cap of 16
  // (Winapi.WebView2 chains ICoreWebView2_18 down to ICoreWebView2, all in
  // one unit). 64 covers any sane declaration chain; past it the bridged
  // half of the ancestry is simply absent, never garbage.
  for var LSIdx := 0 to High(FCaretStructs) do
  begin
    LOv := FCaretStructs[LSIdx];
    LX := XNil;
    for LDepth := 1 to 64 do
    begin
      LRef := OverlayHeritageRef(LOv, 0);
      if LRef.OvSym <> NIL_SYM then
      begin
        LOv := LRef.OvSym;
        // The OVERLAY half of the same chain, kept for the overlay-side
        // visibility rule (see OverlayMemberVisible): strict protected is
        // legal from a descendant, and in the buffer's own space FAncestry's
        // project ids cannot express that.
        FOverlayAncestry := FOverlayAncestry + [LOv];
        Continue;
      end;
      LX := LRef.X;
      Break;
    end;
    // The overlay half needs no project - a standalone request still sees
    // an ancestor's strict protected members (audit B2-38).
    if FProj = nil then
      Continue;
    for LDepth := 1 to 32 do
    begin
      if not XValid(LX) then
        Break;
      LEntry.UnitId := LX.UnitId;
      LEntry.Sym := LX.Sym;
      FAncestry := FAncestry + [LEntry];
      LX := FProj.AncestorOfX(LX);
    end;
  end;
end;

// Visibility of a PROJECT member from this caret (11 sec. 11.2.1): private and
// protected are same-unit-friendly - the member's unit, or (protected) a base
// whose type this unit declares; a generic's protected is open in a method
// body; strict protected needs the caret's struct to descend from the
// declaring one, and the strict variants drop the friend rule. svDefault
// means "no section stated" and stays visible - hiding on a guess is the
// wrong failure mode for a list.
function TPasCompletion.MemberVisible(AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LDeclStruct, LIdx: Integer;
begin
  LM := ProjModel(AMid, 'MemberVisible');
  case LM.Symbols[ASym].Visibility of
    svStrictPrivate:
      begin
        // Visible ONLY inside the declaring class itself (or a class the
        // caret's is nested in - the asymmetric nesting rule, 11 sec. 11.2.1).
        // Testable only when overlay indices ARE project indices.
        Result := False;
        if FIsProjectModel and (AMid = FProjMid) and
           (LM.Symbols[ASym].Scope <> NIL_SCOPE) then
        begin
          LDeclStruct := LM.Scopes[LM.Symbols[ASym].Scope].StructSym;
          for LIdx := 0 to High(FCaretStructs) do
            if FCaretStructs[LIdx] = LDeclStruct then
              Exit(True);
        end;
      end;
    svPrivate:
      Result := AMid = FProjMid;
    svProtected, svStrictProtected:
      begin
        Result := (LM.Symbols[ASym].Visibility = svProtected) and
          ((AMid = FProjMid) or FBaseOwnUnit);
        if Result then
          Exit;
        // dcc enforces a GENERIC class's plain `protected` only outside
        // method bodies (spec 11.2.1) - spring4d's collections depend on the
        // access being legal there. From a unit-level routine, a main block
        // or an anonymous method in one it is E2362 (local/probe-cc P2a,
        // P2f, P2j): `L.Notify` in a program's main block is no candidate.
        if FInMethodBody and (LM.Symbols[ASym].Visibility = svProtected) and
           (LM.Symbols[ASym].Scope <> NIL_SCOPE) then
        begin
          LDeclStruct := LM.Scopes[LM.Symbols[ASym].Scope].StructSym;
          if (LDeclStruct <> NIL_SYM) and
             (sfGeneric in LM.Symbols[LDeclStruct].Flags) then
            Exit(True);
        end;
        // Plain `protected` has no descendant rule of its own: in a
        // descendant's method in another unit, TA's protected P is legal
        // through Self or a value of a class declared in that unit (the
        // friend rule above) and E2362 through a TA, a sibling or even a
        // further descendant declared elsewhere (local/probe-cc UB, UE).
        if LM.Symbols[ASym].Visibility = svProtected then
          Exit(False);
        if LM.Symbols[ASym].Scope = NIL_SCOPE then
          Exit(True);
        LDeclStruct := LM.Scopes[LM.Symbols[ASym].Scope].StructSym;
        if LDeclStruct = NIL_SYM then
          Exit(True);
        for LIdx := 0 to High(FAncestry) do
          if (FAncestry[LIdx].UnitId = AMid) and
             (FAncestry[LIdx].Sym = LDeclStruct) then
            Exit(True);
        // The declaring class IS one of the caret's own nest (same-class
        // strict-protected access) - overlay indices are project indices
        // only in project-model mode.
        if FIsProjectModel and (AMid = FProjMid) then
          for LIdx := 0 to High(FCaretStructs) do
            if FCaretStructs[LIdx] = LDeclStruct then
              Exit(True);
        Result := False;
      end;
  else
    Result := True;
  end;
end;

{ The visibility rule for an OVERLAY-declared member (11.2.1), the half
  MemberVisible cannot answer: overlay symbol indices are not project indices,
  so that function's model lookup does not apply here.

  Everything in the overlay is the edited unit's own, so `private` and plain
  `protected` are visible by the friend rule. The STRICT forms are not, and
  used to be offered anyway - a strict private member of a same-unit class was
  listed outside its declaring class, which is precisely what strict means. }
function TPasCompletion.OverlayMemberVisible(ASym: Integer): Boolean;
var
  LDeclStruct, LIdx: Integer;
begin
  if not (FModel.Symbols[ASym].Visibility in
     [svStrictPrivate, svStrictProtected]) then
    Exit(True);
  Result := False;
  if FModel.Symbols[ASym].Scope = NIL_SCOPE then
    Exit(True);   // not a struct member after all
  LDeclStruct := FModel.Scopes[FModel.Symbols[ASym].Scope].StructSym;
  if LDeclStruct = NIL_SYM then
    Exit(True);
  // The caret's own class, or one it is nested in.
  for LIdx := 0 to High(FCaretStructs) do
    if FCaretStructs[LIdx] = LDeclStruct then
      Exit(True);
  // strict protected additionally reaches DESCENDANTS - the caret's ancestry,
  // recorded in overlay space by EnsureAncestry.
  if FModel.Symbols[ASym].Visibility = svStrictProtected then
    for LIdx := 0 to High(FOverlayAncestry) do
      if FOverlayAncestry[LIdx] = LDeclStruct then
        Exit(True);
end;

procedure TPasCompletion.CollectProjectMembers(const AX: TSemaXType;
  ABucket: TPasComplBucket);
var
  LSaveOwn: Boolean;
begin
  if (FProj = nil) or not XValid(AX) then
    Exit;
  // The flag is PER BASE, not per request. Left set, the first own-unit base
  // walk legalized plain `protected` on every unrelated foreign base walked
  // after it in the same request.
  LSaveOwn := FBaseOwnUnit;
  try
    // A type parameter of this unit is no type of it: `V.GetDisposed` on a
    // `T: class` value is E2362 in its own generic (local/probe-cc P1a).
    if (AX.UnitId = FProjMid) and (ProjModel(AX.UnitId,
       'CollectProjMembers').Symbols[AX.Sym].Kind <> skGenericParam) then
      FBaseOwnUnit := True;
    FProj.EnumMembersX(FProjMid, AX,
      procedure(AMid, ASym, ACtx: Integer)
      begin
        if FFieldsOnly and
           (ProjModel(AMid, 'FieldsOnly').Symbols[ASym].Kind <> skField) then
          Exit;
        if MemberVisible(AMid, ASym) and
           (not FClassSide or
            ClassSideMember(ProjModel(AMid, 'CollectProjMembers'), ASym)) then
          AddSym(AMid, ASym, ACtx, ABucket);
      end);
  finally
    FBaseOwnUnit := LSaveOwn;
  end;
end;

// Members of an OVERLAY-declared type: its own scope (deep - nested enums
// and intra-unit joins included), then each overlay ancestor's, then the
// first hop that leaves the buffer continues in project space.
// AIncludeOwn = False skips the FIRST scope - the caller already enumerated
// it through the caret's scope chain (a method body's joined member scope).
procedure TPasCompletion.CollectOverlayChain(AOvSym: Integer;
  AIncludeOwn: Boolean; ABucket: TPasComplBucket);
var
  LDepth, LScope: Integer;
  LRef: TPasComplTypeRef;
  LInclude, LSaveOwn: Boolean;
begin
  // An overlay-declared base IS a type of this unit - its bridged ancestors'
  // non-strict protected members are reachable (the module rule above).
  // Saved and restored, like CollectProjectMembers: the flag is per BASE.
  LSaveOwn := FBaseOwnUnit;
  try
  FBaseOwnUnit := True;
  LInclude := AIncludeOwn;
  for LDepth := 1 to 64 do
  begin
    if AOvSym = NIL_SYM then
      Exit;
    if LInclude then
    begin
      LScope := FModel.Symbols[AOvSym].MemberScope;
      if LScope <> NIL_SCOPE then
        FModel.EnumScopeDeep(LScope,
          procedure(ASym, AScopeOfSym: Integer)
          begin
            // Class constructors / destructors and class operators are
            // AddSym's to refuse, as for every other walk.
            if FFieldsOnly and (FModel.Symbols[ASym].Kind <> skField) then
              Exit;
            if not OverlayMemberVisible(ASym) then
              Exit;
            if not FClassSide or ClassSideMember(FModel, ASym) then
              AddSym(-1, ASym, NIL_INST, ABucket);
          end);
    end;
    LInclude := True;
    LRef := OverlayHeritageRef(AOvSym, 0);
    if LRef.OvSym <> NIL_SYM then
    begin
      AOvSym := LRef.OvSym;
      Continue;
    end;
    CollectProjectMembers(LRef.X, ABucket);
    Exit;
  end;
  finally
    FBaseOwnUnit := LSaveOwn;
  end;
end;

procedure TPasCompletion.CollectUnitInterface(AUid: Integer;
  ABucket: TPasComplBucket);
var
  LM: TPasSemaModel;
  LScope, LIdx, LSym: Integer;
begin
  if (FProj = nil) or (AUid < 0) then
    Exit;
  LM := ProjModel(AUid, 'CollectUnitInterface');
  LScope := LM.InterfaceScope;
  if (LScope = NIL_SCOPE) or (LM.Scopes[LScope].Symbols.Count = 0) then
    Exit;
  // OWN symbols, not a blind deep walk - the interface scope's Additional
  // joins hold that unit's builtin seeds (a per-model copy every unit has;
  // offering them as THIS unit's exports would be wrong), and its own uses'
  // unit refs are not importable names either, so skUnitRef is skipped.
  for LIdx := 0 to LM.Scopes[LScope].Symbols.Count - 1 do
  begin
    LSym := LM.Scopes[LScope].Symbols[LIdx];
    if LM.Symbols[LSym].Kind <> skUnitRef then
      AddSym(AUid, LSym, NIL_INST, ABucket);
  end;
  // The one Additional join that IS the unit's own export: an unscoped
  // enum's value scope ({$SCOPEDENUMS OFF}, the default) - `ffFixed` is
  // importable from System.SysUtils exactly like TFloatFormat itself. The
  // corpus oracle caught these missing from every used-unit list.
  for LIdx := 0 to High(LM.Scopes[LScope].Additional) do
    if LM.Scopes[LM.Scopes[LScope].Additional[LIdx]].Kind = sckEnum then
      LM.EnumScopeDeep(LM.Scopes[LScope].Additional[LIdx],
        procedure(ASym, AScopeOfSym: Integer)
        begin
          AddSym(AUid, ASym, NIL_INST, ABucket);
        end);
end;

procedure TPasCompletion.CollectMembers(const ABase: TPasComplTypeRef;
  ABucket: TPasComplBucket);
var
  LScope, LIdx, LSym: Integer;
begin
  if ABase.UnitMid >= 0 then
  begin
    // The edited unit qualifying ITSELF (`u4.`) reaches its unit-level
    // declarations of either section made so far (3.3.2 step 4) - the
    // overlay's own, typed since the last analysis included (audit B2-32).
    if (ABase.UnitMid = FProjMid) and (FModel.InterfaceScope <> NIL_SCOPE) then
    begin
      for LScope := 0 to FModel.Scopes.Count - 1 do
        if (LScope = FModel.InterfaceScope) or
           (FModel.Scopes[LScope].Kind = sckImplementation) then
          for LIdx := 0 to FModel.Scopes[LScope].Symbols.Count - 1 do
          begin
            LSym := FModel.Scopes[LScope].Symbols[LIdx];
            if (FModel.Symbols[LSym].Kind <> skUnitRef) and
               ((FCaretVis < 0) or
                not FModel.DeclaredAfter(LSym, FCaretVis)) then
              AddSym(-1, LSym, NIL_INST, ABucket);
          end;
    end
    else
    begin
      CollectUnitInterface(ABase.UnitMid, ABucket);
      // dcc lets `System.` qualify EVERY compiler-provided name
      // (System.Delete, System.PAnsiChar), so the System unit's list carries
      // the seeds too - and only System's: seeds are per-model copies, not
      // anyone's exports.
      if (FProj <> nil) and (ABase.UnitMid = FProj.EnsureSystemUnit) then
        AddSeeds;
    end;
    // A unit qualifier may also be the head of a longer unit name -
    // `System.` continues to System.SysUtils as well as naming System. The
    // unit's own exports went first (AddItem: first hit wins), as MemberOf
    // tries them first.
    if (FContext = ccMember) and (FProj <> nil) then
      CollectNamespaceChildren(ChangeFileExt(ExtractFileName(
        FProj.ModelFile(ABase.UnitMid)), ''));
  end
  else
  begin
    if ABase.OvSym <> NIL_SYM then
      CollectOverlayChain(ABase.OvSym, True, ABucket)
    else if XValid(ABase.X) then
      CollectProjectMembers(ABase.X, ABucket);
    // `TBytes.Create(...)`: a dynamic array TYPE has the pseudo-constructor
    // (8.2.3), which no declaration carries (audit E2-48).
    if ABase.IsTypeRef and IsDynArrayRef(ABase, 0) then
      AddItem('Create', 'create', skRoutine, ABucket, -1, NIL_SYM,
        NIL_INST);
  end;
end;

// Does ARef name a DYNAMIC array type - an own-unit `array of T`, through
// aliases, or a project type (TPasSemaProject.IsDynArrayTypeX)?
function TPasCompletion.IsDynArrayRef(const ARef: TPasComplTypeRef;
  ADepth: Integer): Boolean;
var
  LDef: Integer;
  LNext: TPasComplTypeRef;
begin
  Result := False;
  if ADepth > 16 then
    Exit;
  if ARef.OvSym <> NIL_SYM then
  begin
    LDef := OverlayStructDef(ARef.OvSym);
    if LDef = NIL_NODE then
      Exit;
    case FModel.Tree.Nodes[LDef].Kind of
      nkArrayType:
        Result := (FModel.Tree.Nodes[LDef].Aux <> 1) and
          (FModel.Tree.Nodes[LDef].FirstChild <> NIL_NODE) and
          (FModel.Tree.Nodes[FModel.Tree.Nodes[LDef].FirstChild].NextSibling =
            NIL_NODE);
      nkIdent, nkMember, nkTypeArgs:
        begin
          LNext := ResolveTypeRefNode(LDef, ADepth + 1);
          if LNext.OvSym <> ARef.OvSym then
            Result := IsDynArrayRef(LNext, ADepth + 1);
        end;
    end;
  end
  else if XValid(ARef.X) and (FProj <> nil) then
    Result := FProj.IsDynArrayTypeX(ARef.X);
end;

// The compiler seeds of this model's System scope, as cbBuiltin rows.
procedure TPasCompletion.AddSeeds;
begin
  if FModel.SystemScope <> NIL_SCOPE then
    FModel.EnumScopeDeep(FModel.SystemScope,
      procedure(ASym, AScopeOfSym: Integer)
      begin
        AddSym(-1, ASym, NIL_INST, cbBuiltin);
      end);
end;

{ The struct an implementation heading's qualifier names, when the caret
  is the dot after it (`procedure TFoo.|Bar;`, `procedure TOuter.TInner.|`):
  the header's name segments are no bound designator (the resolver binds no
  qualifier segment), so they are looked up here - the first in the unit's
  scope, each next one among the previous struct's members. NIL_SYM when
  the caret is no such dot. }
function TPasCompletion.HeaderQualifierStruct(
  const AInfo: TPasCaretInfo): Integer;
var
  LTS: TPasTokenStream;
  LDot, LPrev, LVis, LNode, LRoutine, LSeg, LSym, LScope: Integer;
begin
  Result := NIL_SYM;
  LTS := FModel.Tree.Source.Files[0];
  if AInfo.Kind = ckAfterDot then
    LDot := AInfo.RawToken
  else if AInfo.Kind = ckIdent then
    LDot := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    Exit;
  if (LDot < 0) or (LTS.Tokens[LDot].Kind <> tkDot) then
    Exit;
  LPrev := PrevVisibleRaw(LDot - 1);
  if (LPrev < 0) or (LPrev > High(FVisOfRaw)) then
    Exit;
  LVis := FVisOfRaw[LPrev];
  if LVis < 0 then
    Exit;
  LNode := InnermostNodeAt(LVis);
  if (LNode = NIL_NODE) or (FModel.Tree.Nodes[LNode].Kind <> nkIdent) or
     not (nfName in FModel.Tree.Nodes[LNode].Flags) then
    Exit;
  LRoutine := FModel.Tree.Nodes[LNode].Parent;
  if (LRoutine = NIL_NODE) or
     (FModel.Tree.Nodes[LRoutine].Kind <> nkRoutine) then
    Exit;
  LScope := ScopeOfNode(FModel.Tree.Nodes[LRoutine].Parent);
  LSeg := FModel.Tree.Nodes[LRoutine].FirstChild;
  LSym := NIL_SYM;
  while LSeg <> NIL_NODE do
  begin
    if (FModel.Tree.Nodes[LSeg].Kind = nkIdent) and
       (nfName in FModel.Tree.Nodes[LSeg].Flags) then
    begin
      if LSym = NIL_SYM then
      begin
        if LScope = NIL_SCOPE then
          Exit;
        LSym := FModel.Resolve(LScope, FModel.Tree.NodeNameLower(LSeg));
      end
      else if FModel.Symbols[LSym].MemberScope <> NIL_SCOPE then
        LSym := FModel.FindLocal(FModel.Symbols[LSym].MemberScope,
          FModel.Tree.NodeNameLower(LSeg))
      else
        LSym := NIL_SYM;
      if (LSym = NIL_SYM) or (FModel.Symbols[LSym].Kind <> skType) then
        Exit(NIL_SYM);
      if LSeg = LNode then
        Exit(LSym);
    end;
    LSeg := FModel.Tree.Nodes[LSeg].NextSibling;
  end;
end;

{ Is the aggregate a RECORD's (3.2.2), so that a fresh spot after its `(`
  or `;` is a field-name position? A `;` separates fields, a `,` array
  elements; after the `(` it is a record when a field is already written or
  the declared type is a record. An array constant's `(1, |` is an
  expression (audit A1-35). }
function TPasCompletion.IsRecordAggregate(AAggNode: Integer;
  AAnchor: TPasTokenKind): Boolean;
var
  LChild, LDef: Integer;
  LRef: TPasComplTypeRef;
  LM: TPasSemaModel;
begin
  case AAnchor of
    tkSemicolon:
      Exit(True);
    tkLParen:
      ;
  else
    Exit(False);
  end;
  LChild := FModel.Tree.Nodes[AAggNode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if FModel.Tree.Nodes[LChild].Kind = nkAggregateField then
      Exit(True);
    LChild := FModel.Tree.Nodes[LChild].NextSibling;
  end;
  Result := False;
  LRef := AggregateTypeOf(AAggNode, 0);
  if LRef.OvSym <> NIL_SYM then
  begin
    LDef := OverlayStructDef(LRef.OvSym);
    Result := (LDef <> NIL_NODE) and
      (FModel.Tree.Nodes[LDef].Kind = nkRecordType);
  end
  else if XValid(LRef.X) and (FProj <> nil) then
  begin
    LM := ProjModel(LRef.X.UnitId, 'IsRecordAggregate');
    LDef := ProjectTypeDef(LRef.X);
    Result := (LDef <> NIL_NODE) and
      (LM.Tree.Nodes[LDef].Kind = nkRecordType);
  end;
end;

function TPasCompletion.IsDescendantNode(ANode, AAncestor: Integer): Boolean;
begin
  while ANode <> NIL_NODE do
  begin
    if ANode = AAncestor then
      Exit(True);
    ANode := FModel.Tree.Nodes[ANode].Parent;
  end;
  Result := False;
end;

// Used units' interface names + the implicit System/SysInit, through the
// PROJECT model of this same file - its UsesList already carries resolved
// model ids with namespaces and aliases applied (stage-B spike note). When
// the caret sits in the INTERFACE section, implementation-section uses are
// excluded (the overlay's own symbols say which section each item is in).
procedure TPasCompletion.CollectUsesImports(AInterfaceOnly: Boolean);
var
  PM: TPasSemaModel;
  LIdx, LUid, LJdx: Integer;
  LAllowed: TDictionary<string, Boolean>;
  LOk: Boolean;
begin
  if (FProj = nil) or (FProjMid < 0) then
    Exit;
  LAllowed := nil;
  try
    if AInterfaceOnly then
    begin
      LAllowed := TDictionary<string, Boolean>.Create;
      for LJdx := 0 to High(FModel.UsesList) do
        if (FModel.UsesList[LJdx].Sym <> NIL_SYM) and
           (FModel.Symbols[FModel.UsesList[LJdx].Sym].Scope =
             FModel.InterfaceScope) then
          LAllowed.AddOrSetValue(
            PasNameKey(FModel.UsesList[LJdx].NameFull), True);
    end;
    PM := ProjModel(FProjMid, 'CollectUsesImports');
    for LIdx := High(PM.UsesList) downto 0 do
    begin
      LUid := PM.UsesList[LIdx].UnitId;
      if LUid < 0 then
        Continue;
      if LAllowed <> nil then
      begin
        LOk := LAllowed.ContainsKey(PasNameKey(PM.UsesList[LIdx].NameFull));
        if not LOk then
          Continue;
      end;
      CollectUnitInterface(LUid, cbUses);
    end;
  finally
    LAllowed.Free;
  end;
  CollectUnitInterface(FProj.EnsureSystemUnit, cbSystem);
  CollectUnitInterface(FProj.EnsureSysInitUnit, cbSystem);
end;

procedure TPasCompletion.CollectScope(const AInfo: TPasCaretInfo);
var
  LScope, LIdx, LTarget, LBody, LWith: Integer;
  LTargets, LJoins: TArray<Integer>;
  LStructDone: TArray<Boolean>;
  LOnSym: TPasSymEnumProc;
  LInterfaceOnly: Boolean;
  LRef: TPasComplTypeRef;
  LChainBucket: TPasComplBucket;
  LCaretTypeSec: Integer;
  // The caret is a slot that may name a type declared later in its own
  // section: a pointer's target (`^|`) or a class reference's (`class of |`).
  LEarlySlot: Boolean;

  // The inherited members of the caret struct whose own member scope AScope
  // is - once per struct.
  procedure CollectInheritedAt(AScope: Integer);
  var
    LI: Integer;
  begin
    if FModel.Scopes[AScope].StructSym = NIL_SYM then
      Exit;
    for LI := 0 to High(FCaretStructs) do
      if not LStructDone[LI] and
         (FModel.Scopes[AScope].StructSym = FCaretStructs[LI]) then
      begin
        LStructDone[LI] := True;
        CollectOverlayChain(FCaretStructs[LI], False, cbStructMember);
      end;
  end;

begin
  FCaretVis := AInfo.VisToken;
  // 1. The enclosing WITH statements (5.7), one walk: innermost statement
  // first and, within one statement, the LAST target first - the shadowing
  // order, and AddItem keeps the FIRST hit for a name. Opened (same-unit)
  // and unopened targets alike: an outer unopened with must not beat an
  // inner opened one, and an opened with's join is Phase 1's guess (audit
  // B2-34, D1-32). Each target through the with pass's own typer on an
  // analyzed model (an INDEXED target - `with Palette.palPalEntry[I] do` -
  // is typed by nothing else), DesignatorType on an overlay; its own members
  // before its ancestors, as cbWithMember rows.
  LWith := AInfo.Node;
  while LWith <> NIL_NODE do
  begin
    if FModel.Tree.Nodes[LWith].Kind = nkWithStmt then
    begin
      LBody := FModel.Tree.WithBody(LWith);
      if (LBody <> NIL_NODE) and
         (LBody <> FModel.Tree.Nodes[LWith].FirstChild) and
         IsDescendantNode(AInfo.Node, LBody) then
      begin
        LTargets := nil;
        LTarget := FModel.Tree.Nodes[LWith].FirstChild;
        while (LTarget <> NIL_NODE) and (LTarget <> LBody) do
        begin
          LTargets := LTargets + [LTarget];
          LTarget := FModel.Tree.Nodes[LTarget].NextSibling;
        end;
        for var LTi := High(LTargets) downto 0 do
        begin
          LRef := ComplNilRef;
          if FIsProjectModel then
          begin
            LRef.X := FProj.WithTargetTypeX(FProjMid, LTargets[LTi]);
            // A target of no struct type opens nothing (5.7, E2018).
            if not FProj.WithOpensX(LRef.X) then
              Continue;
          end;
          if not ComplValid(LRef) then
          begin
            LRef := DesignatorType(LTargets[LTi], 0);
            LRef.IsTypeRef := False;
          end;
          if ComplValid(LRef) then
          begin
            FClassSide := False;
            CollectMembers(LRef, cbWithMember);
          end;
        end;
      end;
    end;
    LWith := FModel.Tree.Nodes[LWith].Parent;
  end;
  FClassSide := False;
  // `Self` has no symbol (11.3.3), so no scope lists it: a method body with
  // one names it beside its parameters (3.3.2 step 2). Its type is the
  // method's struct, kept for MatchOf and the row's detail - without it the
  // row was untyped, fit 3, and `if self|` listed it after every `SELF...`
  // constant (an IDE test, 2026-11-08).
  LScope := MethodBodyScope(AInfo.Scope);
  // Not in a constant expression (E2026). A `var` argument keeps it: dcc 37
  // passes Self to a `var` parameter of its type, in a class and a record.
  if (FContext in [ccStatement, ccExpression]) and (LScope <> NIL_SCOPE) and
     not FConstOnly and MethodHasSelf(LScope) then
  begin
    FSelfOv := FModel.Scopes[LScope].StructSym;
    LTarget := FModel.Scopes[LScope].OwnerNode;
    FSelfClass := (LTarget <> NIL_NODE) and
      (FModel.Tree.Nodes[LTarget].Kind = nkRoutine) and
      (FModel.Tree.Nodes[LTarget].Aux = 1);
    AddItem('Self', 'self', skParam, cbLocal, -1, NIL_SYM, NIL_INST);
  end;
  // 2. The lexical scope chain, deep (joined scopes included) - this is
  // exactly what unqualified lookup sees intra-unit: locals, params, the
  // enclosing struct's own members through the method-body join, enum
  // values, and the unit's own names; a with scope was step 1's. The
  // builtin seeds joined into the interface scope are skipped here and
  // added LAST (a real name must win the dedup against a seed).
  //
  // The BUCKET is the chain scope's (audit B2-36): a unit's own enum values
  // are unit symbols, not locals; a struct member joined into a method body
  // stays a struct member.
  EnsureAncestry(AInfo.Scope);
  SetLength(LStructDone, Length(FCaretStructs));
  LChainBucket := cbLocal;
  LCaretTypeSec := UpChainNode(AInfo.Node, nkTypeSec);
  if AInfo.Kind = ckIdent then
    LIdx := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    LIdx := AInfo.RawToken;
  LEarlySlot := (LIdx >= 0) and
    ((FModel.Tree.Source.Files[0].Tokens[LIdx].Kind = tkCaret) or
     ((FModel.Tree.Source.Files[0].Tokens[LIdx].Kind = tkOf) and
      (UpChainKind(AInfo.Node, [nkClassOf, nkArrayType, nkSetType,
        nkFileType, nkCaseStmt]) = nkClassOf)));
  LOnSym :=
    procedure(ASym, AScopeOfSym: Integer)
    var
      LBucket: TPasComplBucket;
    begin
      case FModel.Scopes[AScopeOfSym].Kind of
        sckSystem:
          Exit;   // seeds come last, as cbBuiltin
        sckStruct:
          LBucket := cbStructMember;
      else
        LBucket := LChainBucket;
      end;
      // A declaration is visible only BELOW itself (3.3.2, "position
      // counts"): an inline var or const (3.1.3), and a unit-level or a
      // routine's own declaration alike - an implementation-section const,
      // type or routine under the caret is E2003 there, and so is a local
      // declared after a nested routine that names it (local/probe-cc
      // U3a-U3d). A struct's members are the exception: every method body
      // sees all of them. So is a type the caret's own `type` section
      // completes below it, where the language allows naming it early: a
      // pointer's target (`P = ^T; T = record`, 10.1.1), a class reference's
      // (`TC = class of T; T = class`, P10d), and a class whose
      // forward `TFoo = class;` stands above the caret (11.1.1; the
      // symbol's DeclNode is the completing declaration) - nothing else,
      // `TA = record X: TB; end; TB = Integer;` is E2003 (local/probe-cc
      // P10a-P10c).
      // (The section holding the caret, or one around it: a class's nested
      // `public type` section sits inside the unit's.)
      if not (FModel.Scopes[AScopeOfSym].Kind in [sckStruct, sckSystem]) and
         FModel.DeclaredAfter(ASym, FCaretVis) then
      begin
        if (LCaretTypeSec = NIL_NODE) or
           (FModel.Symbols[ASym].Kind <> skType) then
          Exit;
        var LSymSec := UpChainNode(FModel.Symbols[ASym].DeclNode, nkTypeSec);
        if (LSymSec = NIL_NODE) or not IsDescendantNode(AInfo.Node, LSymSec)
           or not (LEarlySlot or ForwardTypeAbove(ASym, LSymSec)) then
          Exit;
      end;
      AddSym(-1, ASym, NIL_INST, LBucket);
    end;
  LScope := AInfo.Scope;
  LInterfaceOnly := True;
  while LScope <> NIL_SCOPE do
  begin
    case FModel.Scopes[LScope].Kind of
      sckImplementation:
        begin
          LInterfaceOnly := False;
          LChainBucket := cbUnitSym;
        end;
      sckUnit:
        LChainBucket := cbUnitSym;
      sckStruct:
        LChainBucket := cbStructMember;
    else
      LChainBucket := cbLocal;
    end;
    if FModel.Scopes[LScope].Kind = sckWith then
    begin
      LScope := FModel.Scopes[LScope].Parent;
      Continue;
    end;
    // EnumScopeDeep's order, one join at a time: the shadowing joins, the
    // scope's own names, then its additional joins innermost first - and
    // after a caret struct's own member scope, that struct's INHERITED
    // members. The class scope, ancestors included, comes before any
    // enclosing scope (3.3.2): a unit global or an outer class's member of
    // the same name must not take the row of the inherited member the name
    // binds to (audit A1-19). A method body joins its class's member scope
    // and the outer classes' (innermost last); a struct declaration is its
    // own member scope.
    LJoins := FModel.Scopes[LScope].Shadowing;
    for LIdx := High(LJoins) downto 0 do
      FModel.EnumScopeDeep(LJoins[LIdx], LOnSym, 1);
    for LIdx := 0 to FModel.Scopes[LScope].Symbols.Count - 1 do
      LOnSym(FModel.Scopes[LScope].Symbols[LIdx], LScope);
    CollectInheritedAt(LScope);
    LJoins := FModel.Scopes[LScope].Additional;
    for LIdx := High(LJoins) downto 0 do
    begin
      FModel.EnumScopeDeep(LJoins[LIdx], LOnSym, 1);
      CollectInheritedAt(LJoins[LIdx]);
    end;
    LScope := FModel.Scopes[LScope].Parent;
  end;
  // 3. A nest level the chain never named (a scope shape the walk above does
  // not recognize) still gets its ancestors, last.
  for LIdx := 0 to High(FCaretStructs) do
    if not LStructDone[LIdx] then
      CollectOverlayChain(FCaretStructs[LIdx], False, cbStructMember);
  // 4. Cross-unit names: uses (reverse, last-wins), System, SysInit.
  CollectUsesImports(LInterfaceOnly);
  // 5. Compiler seeds, last - every real declaration outranks a seed.
  AddSeeds;
end;

// `goto |`: labels live in `label` sections of the lexical chain and nowhere
// else - running the full CollectScope pipeline (with typing, ancestry
// bridging, every used unit's interface) only for AddSym to reject all of it
// was measured waste (the review's finding #1).
procedure TPasCompletion.CollectLabels(const AInfo: TPasCaretInfo);
var
  LScope: Integer;
begin
  FCaretVis := AInfo.VisToken;
  LScope := AInfo.Scope;
  while LScope <> NIL_SCOPE do
  begin
    FModel.EnumScopeDeep(LScope,
      procedure(ASym, AScopeOfSym: Integer)
      begin
        AddSym(-1, ASym, NIL_INST, cbLocal);   // AddSym keeps only skLabel
      end);
    LScope := FModel.Scopes[LScope].Parent;
  end;
end;

{ ccUses: unit names are DOTTED, but the lexical anchor is one SEGMENT - a
  client filtering candidates ('System.SysUtils') against the bare segment
  prefix ('Sys' of `System.Sys|`) matches nothing, and its textEdit would
  replace half a name. So the prefix and replace-span are extended LEFT
  across the `ident . ident` chain (same line only - a replace span covers
  one line) before the caret leaves the engine: the prefix reads
  'System.Sys' and the span covers the whole dotted name typed so far.
  (Plan sec. 5.C's "dotted uses prefixes filter per segment", solved engine-side
  so every client gets it.) }
procedure TPasCompletion.ExtendUsesPrefix(ALine: Integer;
  var AInfo: TPasCaretInfo);
var
  LTS: TPasTokenStream;
  LCur, LPrev, LLine, LCol, LFrom: Integer;
  LHead: string;
begin
  LTS := FModel.Tree.Source.Files[0];
  if AInfo.RawToken < 0 then
    Exit;
  LCur := AInfo.RawToken;   // ckIdent: the segment; ckAfterDot: the dot
  if AInfo.Kind = ckIdent then
  begin
    LPrev := PrevVisibleRaw(LCur - 1);
    if (LPrev < 0) or (LTS.Tokens[LPrev].Kind <> tkDot) then
      Exit;
    LCur := LPrev;
  end
  else if (AInfo.Kind <> ckAfterDot) or
          (LTS.Tokens[LCur].Kind <> tkDot) then
    Exit;
  // Accumulate whole `ident .` pairs leftward; apply only what stayed
  // consistent (a chain continuing on an earlier line stops the walk with
  // the same-line part intact).
  LHead := '';
  LFrom := -1;
  while (LCur >= 0) and (LTS.Tokens[LCur].Kind = tkDot) do
  begin
    LPrev := PrevVisibleRaw(LCur - 1);
    if (LPrev < 0) or (LTS.Tokens[LPrev].Kind <> tkIdentifier) then
      Break;
    LTS.OffsetToLineCol(LTS.Tokens[LPrev].Start, LLine, LCol);
    if LLine <> ALine then
      Break;
    LHead := Copy(LTS.Source, LTS.Tokens[LPrev].Start + 1,
      LTS.Tokens[LPrev].Len) + '.' + LHead;
    LFrom := LCol;
    LCur := PrevVisibleRaw(LPrev - 1);
  end;
  if LFrom < 0 then
    Exit;
  AInfo.Prefix := LHead + AInfo.Prefix;
  AInfo.PrefixColFrom := LFrom;
end;

// Uses-clause candidates: the units the last-good project knows about, plus
// the units the search paths could REACH - a `uses` may legitimately name a
// unit nothing has analyzed yet (that is what typing a new uses item IS), so
// the project's cached search-path scan fills in the rest. Both name sets
// are full dotted names; loaded models win the dedup (they carry a real
// model id where a path-scanned name has none).
procedure TPasCompletion.CollectUnitNames;
var
  LIdx, LRoot: Integer;
  LName, LKey, LOwn: string;
  LM: TPasSemaModel;
begin
  if FProj = nil then
    Exit;
  // Never a candidate (audit B2-30): the edited unit itself (F2092), the
  // implicit System and SysInit (`uses System` is E2004), and a program,
  // library or package (F2047) - only units can be used.
  LOwn := FModel.UnitNameLower;
  for LIdx := 0 to FProj.ModelCount - 1 do
    if LIdx <> FProjMid then
    begin
      LM := FProj.Model(LIdx);
      if (LM = nil) or (LM.Tree.Nodes = nil) then
        Continue;
      LRoot := LM.Tree.Nodes[0].FirstChild;
      if (LRoot <> NIL_NODE) and (LM.Tree.Nodes[LRoot].Kind in
         [nkProgram, nkLibrary, nkPackage]) then
        Continue;
      LName := ChangeFileExt(ExtractFileName(FProj.ModelFile(LIdx)), '');
      LKey := PasNameKey(LName);
      if (LKey = LOwn) or (LKey = 'system') or (LKey = 'sysinit') then
        Continue;
      AddItem(LName, LKey, skUnitRef, cbUnitName, LIdx, NIL_SYM, NIL_INST);
    end;
  // Mid = -1 for a path-scanned name: there is no model to point at. A
  // cbUnitName item's identity is its NAME either way - nothing resolves
  // these rows further.
  for LName in FProj.SearchPathUnitNames do
  begin
    LKey := PasNameKey(LName);
    if (LKey = LOwn) or (LKey = 'system') or (LKey = 'sysinit') then
      Continue;
    AddItem(LName, LKey, skUnitRef, cbUnitName, -1, NIL_SYM, NIL_INST);
  end;
end;

// The record type an aggregate initializer fills: the declared type of the
// typed const/var whose initializer this is, or - for a NESTED aggregate -
// the type of the field the enclosing aggregate assigns it to
// (`uguid: (guid: (D1: ...))`). Invalid for an ARRAY element aggregate
// (element types come off declaration nodes; a stage-E refinement).
function TPasCompletion.AggregateTypeOf(AAggNode, ADepth: Integer):
  TPasComplTypeRef;
var
  LParent, LChild, LName: Integer;
begin
  Result := ComplNilRef;
  if (AAggNode = NIL_NODE) or (ADepth > 16) then
    Exit;
  LParent := FModel.Tree.Nodes[AAggNode].Parent;
  if LParent = NIL_NODE then
    Exit;
  case FModel.Tree.Nodes[LParent].Kind of
    nkAggregateField:
      begin
        LName := FModel.Tree.Nodes[LParent].FirstChild;
        Result := MemberOf(
          AggregateTypeOf(FModel.Tree.Nodes[LParent].Parent, ADepth + 1),
          FModel.Tree.NodeNameLower(LName), ADepth + 1);
      end;
    nkConstDecl, nkVarDecl:
      begin
        // A typed const's shape is name, TYPE EXPR, initializer - the type
        // is the child between the name and this aggregate.
        LChild := FModel.Tree.Nodes[LParent].FirstChild;
        LChild := FModel.Tree.Nodes[LChild].NextSibling;   // past the name
        while (LChild <> NIL_NODE) and (LChild <> AAggNode) do
        begin
          Result := ResolveTypeRefNode(LChild, ADepth + 1);
          LChild := FModel.Tree.Nodes[LChild].NextSibling;
        end;
        Result.IsTypeRef := False;
      end;
  end;
end;

// The innermost node of the given kinds on ANode's parent chain, stopping at
// statement/section boundaries - the disambiguator for `:`/`=`/`of`/`(`.
// Does the `type` section ATypeSec declare ASym's FORWARD (`TFoo = class;`,
// `IFoo = interface;`) above the caret? The resolver moved the symbol's
// DeclNode to the completing declaration, so the section is read for it.
function TPasCompletion.ForwardTypeAbove(ASym, ATypeSec: Integer): Boolean;
var
  LDecl, LChild: Integer;
begin
  Result := False;
  LDecl := FModel.Tree.Nodes[ATypeSec].FirstChild;
  while (LDecl <> NIL_NODE) and
        (FModel.Tree.Nodes[LDecl].FirstToken <= FCaretVis) do
  begin
    if FModel.Tree.Nodes[LDecl].Kind = nkTypeDecl then
    begin
      LChild := FModel.Tree.Nodes[LDecl].FirstChild;
      while (LChild <> NIL_NODE) and
            (FModel.Tree.Nodes[LChild].Kind <> nkIdent) do
        LChild := FModel.Tree.Nodes[LChild].NextSibling;
      if (LChild <> NIL_NODE) and (FModel.RefMap[LChild] = ASym) then
        while LChild <> NIL_NODE do
        begin
          case FModel.Tree.Nodes[LChild].Kind of
            nkClassType:
              if FModel.Tree.Nodes[LChild].Aux = 1 then
                Exit(True);
            nkInterfaceType:
              if FModel.Tree.Nodes[LChild].Aux and 2 <> 0 then
                Exit(True);
          end;
          LChild := FModel.Tree.Nodes[LChild].NextSibling;
        end;
    end;
    LDecl := FModel.Tree.Nodes[LDecl].NextSibling;
  end;
end;

// The nearest node of AKind on ANode's parent chain (ANode included), or
// NIL_NODE.
function TPasCompletion.UpChainNode(ANode: Integer;
  AKind: TPasNodeKind): Integer;
begin
  Result := ANode;
  while (Result <> NIL_NODE) and (FModel.Tree.Nodes[Result].Kind <> AKind) do
    Result := FModel.Tree.Nodes[Result].Parent;
end;

function TPasCompletion.UpChainKind(ANode: Integer;
  const AKinds: array of TPasNodeKind): TPasNodeKind;
var
  LIdx: Integer;
  LKind: TPasNodeKind;
begin
  Result := nkError;
  while ANode <> NIL_NODE do
  begin
    LKind := FModel.Tree.Nodes[ANode].Kind;
    for LIdx := 0 to High(AKinds) do
      if LKind = AKinds[LIdx] then
        Exit(LKind);
    if LKind in [nkBlock, nkInterfaceSec, nkImplementationSec, nkUnit,
      nkProgram, nkLibrary, nkPackage] then
      Exit;
    ANode := FModel.Tree.Nodes[ANode].Parent;
  end;
end;

function TPasCompletion.ClassifyAt(const AInfo: TPasCaretInfo):
  TPasComplContext;
var
  LTS: TPasTokenStream;
  LPrev: Integer;
  LKind: TPasTokenKind;
begin
  if AInfo.Kind = ckNone then
    Exit(ccNone);
  LTS := FModel.Tree.Source.Files[0];
  // A uses clause first: any position inside one is a unit-name position -
  // but a caret whose anchor is a SEMICOLON sits after the clause's own
  // terminator (the `;` is the clause node's last token, so the node test
  // alone over-reaches by one token): that is the next declaration, not a
  // unit name.
  if LTS.Tokens[AInfo.RawToken].Kind <> tkSemicolon then
  begin
    if UpChainKind(AInfo.Node, [nkUsesClause, nkUsesItem]) <> nkError then
      Exit(ccUses);
    if LTS.Tokens[AInfo.RawToken].Kind = tkUses then
      Exit(ccUses);
  end;
  // The MODULE HEADER's own (possibly dotted) name is a naming position -
  // nothing to offer while the unit names itself. (AInfo.Node is never
  // NIL_NODE for a valid caret - the parser always allocates a root - but
  // the guard keeps this self-defending rather than resting on a parser
  // invariant stated two units away.)
  LPrev := AInfo.Node;
  while (LPrev <> NIL_NODE) and
        (FModel.Tree.Nodes[LPrev].Kind in [nkIdent, nkMember]) do
    LPrev := FModel.Tree.Nodes[LPrev].Parent;
  // So are a program's parameters (F17), names no scope has.
  if (LPrev <> NIL_NODE) and (FModel.Tree.Nodes[LPrev].Kind in
    [nkUnit, nkProgram, nkLibrary, nkPackage, nkProgramParams]) then
    Exit(ccNone);
  if (AInfo.DotBase <> NIL_NODE) or (AInfo.Kind = ckAfterDot) then
    Exit(ccMember);
  // A property ACCESSOR position: the caret sits inside an nkPropSpec whose
  // specifier word is `read`/`write`/`stored`. Checked before the generic
  // token rules below - the word left of the caret is an identifier-LEXED
  // directive word the token switch cannot tell from any other name. The
  // other specifiers (index, default, implements) keep the ordinary
  // expression treatment: their right sides really are expressions (`index`
  // and `default` constant ones - CompleteAt sets FConstOnly there).
  LPrev := AInfo.Node;
  while (LPrev <> NIL_NODE) and
        not (FModel.Tree.Nodes[LPrev].Kind in [nkPropSpec, nkPropertyDecl,
          nkBlock, nkInterfaceSec, nkImplementationSec, nkUnit]) do
    LPrev := FModel.Tree.Nodes[LPrev].Parent;
  if (LPrev <> NIL_NODE) and
     (FModel.Tree.Nodes[LPrev].Kind = nkPropSpec) then
  begin
    if FModel.Tree.Source.VisibleTextEquals(
         FModel.Tree.Nodes[LPrev].FirstToken, 'read') then
      Exit(ccPropRead);
    if FModel.Tree.Source.VisibleTextEquals(
         FModel.Tree.Nodes[LPrev].FirstToken, 'write') then
      Exit(ccPropWrite);
    if FModel.Tree.Source.VisibleTextEquals(
         FModel.Tree.Nodes[LPrev].FirstToken, 'stored') then
      Exit(ccPropStored);
  end;
  // A record aggregate's FIELD NAME (3.2.2, `(flDensity: 1.0; flDe|`): the
  // typed prefix that IS an nkAggregateField's name child, or a fresh spot
  // right after the aggregate's `(`/`;`/`,`.
  if AInfo.Kind = ckIdent then
  begin
    LPrev := FModel.Tree.Nodes[AInfo.Node].Parent;
    if (LPrev <> NIL_NODE) and
       (FModel.Tree.Nodes[LPrev].Kind = nkAggregateField) and
       (FModel.Tree.Nodes[LPrev].FirstChild = AInfo.Node) then
      Exit(ccRecField);
  end
  else if (AInfo.Node <> NIL_NODE) and
     (FModel.Tree.Nodes[AInfo.Node].Kind = nkAggregate) and
     (LTS.Tokens[AInfo.RawToken].Kind in [tkLParen, tkSemicolon]) and
     IsRecordAggregate(AInfo.Node, LTS.Tokens[AInfo.RawToken].Kind) then
    Exit(ccRecField);
  // The significant token LEFT of the (possibly empty) prefix decides.
  if AInfo.Kind = ckIdent then
    LPrev := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    LPrev := AInfo.RawToken;
  if LPrev < 0 then
    Exit(ccStatement);
  LKind := LTS.Tokens[LPrev].Kind;
  // A visibility section word is identifier-lexed (a directive, 11.2.1) -
  // inside a structured type the caret after it starts a member.
  if (LKind = tkIdentifier) and (UpChainKind(AInfo.Node, [nkClassType,
     nkRecordType, nkObjectType, nkInterfaceType, nkHelperType]) <> nkError)
  then
    for var LWord in ['private', 'protected', 'public', 'published',
      'automated', 'strict'] do
      if SameText(Copy(LTS.Source, LTS.Tokens[LPrev].Start + 1,
         LTS.Tokens[LPrev].Len), LWord) then
        Exit(ccStatement);
  case LKind of
    tkInherited:
      // `inherited |` - the ancestor's members (12.1.2).
      Result := ccInherited;
    tkGoto:
      Result := ccLabel;
    tkColon:
      // `x: |` is a TYPE in a declaration, a STATEMENT after a case/goto
      // label, an EXPRESSION in an aggregate initializer's `field: value`
      // or a Write width spec - the INNERMOST enclosing construct decides.
      case UpChainKind(AInfo.Node, [nkCaseSel, nkCaseLabels, nkLabeledStmt,
        nkAggregateField, nkFormattedArg]) of
        nkCaseSel, nkCaseLabels, nkLabeledStmt:
          Result := ccStatement;
        nkAggregateField, nkFormattedArg:
          Result := ccExpression;
      else
        Result := ccType;
      end;
    tkCaret:
      // A pointer type's `^` (`P: ^|`, `T = ^|`, `array of ^|`) names a
      // type. In an expression `^` follows a designator (`P^.`), and `^A`
      // written as a character is one tkCaretChar.
      begin
        LPrev := PrevVisibleRaw(LPrev - 1);
        if (LPrev >= 0) and (LTS.Tokens[LPrev].Kind in [tkColon, tkEqual,
           tkOf]) then
          Result := ccType
        else
          Result := ccExpression;
      end;
    tkEqual:
      // `TFoo = |` in a type decl is a type; `= |` anywhere else - a const
      // initializer, a parameter DEFAULT, an aggregate value, a comparison -
      // is an expression. The innermost construct decides again: a param
      // default sits lexically inside a type declaration, and the old
      // nkTypeDecl-anywhere test called `AEnabled: Boolean = |` a type
      // position (the oracle's 'False' [type] misses).
      case UpChainKind(AInfo.Node, [nkTypeDecl, nkConstDecl, nkVarDecl,
        nkInlineVar, nkInlineConst, nkParam, nkAggregateField, nkEnumValue,
        nkMethodResolution]) of
        nkTypeDecl:
          Result := ccType;
      else
        // nkEnumValue included above: `CURLINFO_X = CURLINFO_DOUBLE + 10` is
        // an ordinal EXPRESSION inside a type declaration. A METHOD
        // RESOLUTION's right side (14.2.2) names one of this class's own
        // methods - the scope chain has them, ccExpression lists them.
        Result := ccExpression;
      end;
    tkIs, tkAs:
      // Nominally a class type - but dcc accepts any class-REFERENCE
      // expression on the right (`if FModel is DefineModelClass then`, a
      // class FUNCTION - shipped in the FMX sources), so a hard types-only
      // filter hides legal names. ccExpression lists types too.
      Result := ccExpression;
    tkOf:
      // `array of |`/`set of |`/`class of |` want a type; `case x of |`
      // wants label EXPRESSIONS.
      if UpChainKind(AInfo.Node, [nkArrayType, nkSetType, nkFileType,
        nkClassOf, nkCaseStmt]) in [nkArrayType, nkSetType, nkFileType,
        nkClassOf] then
        Result := ccType
      else
        Result := ccExpression;
    tkLParen, tkComma:
      // A heritage list (`= class(|`, `class(A, |`) or a generic parameter
      // list is a type position; any other paren/comma is an argument - a
      // static array's next bound too (`F: array[TKind, |]` in a class).
      if (LKind = tkComma) and IsArrayBoundOp(LPrev) then
        Result := ccExpression
      else if UpChainKind(AInfo.Node, [nkClassType, nkInterfaceType,
        nkGenericParams, nkCall, nkParen, nkSetCtor]) in
        [nkClassType, nkInterfaceType, nkGenericParams] then
        Result := ccType
      else
        Result := ccExpression;
    tkLess:
      // `TList<|` - a generic argument/parameter list - but only when the
      // parse says so: a bare `x < |` is a COMPARISON (the oracle's
      // `Result := x < y` misses). A generic list mid-typing that has not
      // parsed as nkTypeArgs yet degrades to ccExpression, which still
      // lists every type - only the keyword set differs.
      if UpChainKind(AInfo.Node, [nkTypeArgs, nkGenericParams]) <> nkError then
        Result := ccType
      else
        Result := ccExpression;
    tkSemicolon, tkBegin, tkDo, tkRepeat, tkTry, tkFinally, tkExcept, tkEnd:
      // The `;` ending a case arm starts the next arm's label - an
      // expression (CaseLabelOf), not a statement.
      if (LKind = tkSemicolon) and (CaseLabelOf(LPrev) >= 0) then
        Result := ccExpression
      else
        Result := ccStatement;
    tkThen, tkElse:
      // The branches of an inline `if` are EXPRESSIONS (5.4.1).
      if UpChainKind(AInfo.Node, [nkInlineIf, nkIfStmt, nkCaseStmt]) =
         nkInlineIf then
        Result := ccExpression
      else
        Result := ccStatement;
    // Words that open or continue an EXPRESSION - a condition, a bound, a
    // selector, a raised object, a `with` item, an operand (audit A1-33: `if no|` never
    // offered `not`).
    tkIf, tkWhile, tkUntil, tkTo, tkDownto, tkCase, tkRaise, tkWith, tkAnd,
    tkOr, tkXor, tkNot, tkDiv, tkMod, tkShl, tkShr, tkIn:
      Result := ccExpression;
  else
    // A reserved word (interface/implementation/var/type/...) opens a
    // declaration head; anything else - an operator, `:=`, a bracket, a
    // literal - sits inside an expression.
    if LKind >= tkAnd then
      Result := ccStatement
    else
      Result := ccExpression;
  end;
end;

{ A ccType position after a colon that a heading owns - a parameter's type,
  a function's result, a property's type, those of a procedural type: the
  grammar takes a type identifier there and no other type expression (6.2
  ParamType = TypeRef). A var, field, const or type declaration's colon is
  not one of them (a subrange is legal there, `X: 1..9`). }
function TPasCompletion.TypeNameOnlyAt(const AInfo: TPasCaretInfo): Boolean;
var
  LPrev: Integer;
begin
  Result := False;
  if AInfo.Kind = ckIdent then
    LPrev := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    LPrev := AInfo.RawToken;
  if (LPrev < 0) or
     (FModel.Tree.Source.Files[0].Tokens[LPrev].Kind <> tkColon) then
    Exit;
  Result := UpChainKind(AInfo.Node, [nkParam, nkPropertyDecl, nkRoutine,
    nkProcType, nkVarDecl, nkVarSec, nkConstDecl, nkTypeDecl, nkInlineVar,
    nkInlineConst]) in [nkParam, nkPropertyDecl, nkRoutine, nkProcType];
end;

{ A ccType position right after a colon - every declaration's `Name: |`
  (ClassifyAt has already told those from a case label's and an aggregate
  field's colon) - and a type constructor's tail after `of` (`array of |`,
  `array[..] of |`, `set of |`, `class of |`, `file of |`; ClassifyAt made
  a `case`'s `of` an expression): the list there is for picking a type too
  (pastree-lsp, 2026-11-09: `arr: array of acc|` listed every ACCESS_
  constant), and `set of 0..9` is written by hand - and a pointer type's
  `^|` (ClassifyAt made it ccType after a `:`, `=` or `of`). }
function TPasCompletion.ColonTypeAt(const AInfo: TPasCaretInfo): Boolean;
var
  LPrev: Integer;
begin
  if AInfo.Kind = ckIdent then
    LPrev := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    LPrev := AInfo.RawToken;
  Result := (LPrev >= 0) and
    (FModel.Tree.Source.Files[0].Tokens[LPrev].Kind in [tkColon, tkOf,
     tkCaret]);
end;

{ The heritage list a ccType caret stands in: `= class(|`, `class(TA, |`
  give nkClassType, `= interface(|` nkInterfaceType, anything else nkError.
  The walk stops at a type-argument or generic-parameter list first - the
  comma in `class(TDictionary<string, |` separates type arguments, which
  take any type. }
function TPasCompletion.HeritageAt(const AInfo: TPasCaretInfo): TPasNodeKind;
var
  LPrev: Integer;
begin
  Result := nkError;
  if AInfo.Kind = ckIdent then
    LPrev := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    LPrev := AInfo.RawToken;
  if (LPrev < 0) or not (FModel.Tree.Source.Files[0].Tokens[LPrev].Kind in
     [tkLParen, tkComma]) then
    Exit;
  Result := UpChainKind(AInfo.Node, [nkClassType, nkInterfaceType,
    nkGenericParams, nkTypeArgs, nkCall, nkParen, nkSetCtor]);
  if not (Result in [nkClassType, nkInterfaceType]) then
    Result := nkError;
end;

{ The construct a statement-class caret (ccStatement) stands in: the
  innermost statement list, routine declaration part or structured type on
  the chain - a caret right after a construct's closing `;` / `end` is past
  that construct. nkError when none is (unit level). }
function TPasCompletion.StatementSiteKind(
  const AInfo: TPasCaretInfo): TPasNodeKind;
var
  LNode: Integer;
begin
  LNode := AInfo.Node;
  if (LNode <> NIL_NODE) and
     (FModel.Tree.Nodes[LNode].LastToken = AInfo.VisToken) and
     (FModel.Tree.Source.Files[0].Tokens[AInfo.RawToken].Kind in
       [tkSemicolon, tkEnd]) then
    LNode := FModel.Tree.Nodes[LNode].Parent;
  // A record's variant part is no member start: its labels are constant
  // expressions (`msAny: ();`, 9.1.3).
  Result := UpChainKind(LNode, [nkBlock, nkInitSec, nkFinalSec, nkRoutine,
    nkVariantPart, nkClassType, nkRecordType, nkObjectType, nkInterfaceType,
    nkHelperType]);
end;

{ The start of a member in a structured type's declaration (11.1): what can
  stand there is a keyword (a visibility, `procedure`, `property`, `class`,
  `type`, `const`, `var`, ...) or the NAME of a new field - nothing to
  complete - so no declared name is a candidate; a type stands only after
  the field's colon or inside an attribute's brackets, other contexts. }
function TPasCompletion.IsStructMemberStart(
  const AInfo: TPasCaretInfo): Boolean;
var
  LPrev: Integer;
begin
  Result := False;
  if FContext <> ccStatement then
    Exit;
  // Only where a member STARTS: after a `;`, a section word, the type's
  // opening word or its heritage / GUID bracket. After `procedure` or
  // `function` an interface's name may stand - a method resolution clause,
  // `procedure IFoo.M = DoM;` (14.2.2).
  if AInfo.Kind = ckIdent then
    LPrev := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    LPrev := AInfo.RawToken;
  if (LPrev < 0) or not (FModel.Tree.Source.Files[0].Tokens[LPrev].Kind in
     [tkSemicolon, tkIdentifier, tkClass, tkRecord, tkObject, tkInterface,
      tkDispinterface, tkRParen, tkRBracket, tkEnd]) then
    Exit;
  case StatementSiteKind(AInfo) of
    nkClassType, nkRecordType, nkObjectType, nkInterfaceType, nkHelperType:
      Result := True;
    nkError:
      Result := (AInfo.Scope <> NIL_SCOPE) and
        (FModel.Scopes[AInfo.Scope].Kind = sckStruct);
  end;
end;

procedure TPasCompletion.AddContextKeywords(const AInfo: TPasCaretInfo);
const
  // A statement's first word. Not `then`, `do`, `to`, `downto`, `of`:
  // they follow a part of a statement, never start one. `const` and `var`
  // open an inline declaration (dcc 37).
  STMT_WORDS: array[0..18] of string = ('begin', 'end', 'if', 'else',
    'case', 'while', 'repeat', 'until', 'for', 'with', 'try', 'finally',
    'except', 'raise', 'goto', 'asm', 'inherited', 'var', 'const');
  UNIT_WORDS: array[0..14] of string = ('type', 'var', 'const', 'uses',
    'procedure', 'function', 'implementation', 'initialization',
    'finalization', 'end', 'begin', 'resourcestring', 'threadvar', 'label',
    'class');
  STRUCT_WORDS: array[0..15] of string = ('private', 'protected', 'public',
    'published', 'strict', 'procedure', 'function', 'constructor',
    'destructor', 'property', 'class', 'var', 'const', 'type', 'end', 'case');
  // An operand's first word: `nil`, `not`, `inherited`, an anonymous
  // method, an if-expression (dcc 37).
  OPERAND_WORDS: array[0..5] of string = ('nil', 'not', 'inherited',
    'function', 'procedure', 'if');
  // After an operand: a binary operator (`not` of `is not` / `not in`).
  OPERATOR_WORDS: array[0..10] of string = ('and', 'or', 'xor', 'div', 'mod',
    'shl', 'shr', 'is', 'as', 'in', 'not');
  // A type declaration's right side (`T = |`): every type constructor, the
  // class-like ones only here (dcc 37: E2058 elsewhere), and `type`.
  TYPE_DECL_WORDS: array[0..13] of string = ('array', 'set', 'file',
    'record', 'class', 'interface', 'dispinterface', 'object', 'procedure',
    'function', 'packed', 'string', 'reference', 'type');
  // A variable's, a field's, a typed constant's type, an array's element:
  // no class-like type (E2058), no `reference to` (E2003 outside `T = `).
  VAR_TYPE_WORDS: array[0..7] of string = ('array', 'set', 'file', 'record',
    'packed', 'string', 'procedure', 'function');
  // A routine's declaration part, before its `begin` (6.1).
  ROUTINE_WORDS: array[0..7] of string = ('var', 'const', 'type', 'label',
    'procedure', 'function', 'begin', 'asm');
  // A parameter's type (TypeNameOnlyAt): `array of`, `string`, an untyped
  // `file`; a result's and a property's `string` alone (dcc 37: `array`
  // there is E2029, `file` E2024).
  PARAM_TYPE_WORDS: array[0..2] of string = ('array', 'string', 'file');
var
  LPrev: Integer;
  LPrevKind: TPasTokenKind;
  LTS: TPasTokenStream;
begin
  LTS := FModel.Tree.Source.Files[0];
  if AInfo.Kind = ckIdent then
    LPrev := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    LPrev := AInfo.RawToken;
  if LPrev >= 0 then
    LPrevKind := LTS.Tokens[LPrev].Kind
  else
    LPrevKind := tkUnknown;
  case FContext of
    ccExpression:
      // Right after an operand an operator continues the expression; an
      // operand's start takes none of them (an IDE test: keywords got
      // through where a value or a type was clearly expected). A directive
      // word in its directive position - `raise X at |`, a property's
      // `default |` / `index |`, `message |`, `dispid |` - is no operand:
      // the operand starts after it.
      if (LPrevKind in [tkIdentifier, tkIntLiteral, tkRealLiteral,
         tkStringLiteral, tkControlChar, tkCaretChar, tkRParen, tkRBracket,
         tkCaret, tkNil]) and
         ((LPrevKind <> tkIdentifier) or
          (DirectiveWordBefore(AInfo, LPrev) = '')) then
        AddKeywords(OPERATOR_WORDS)
      // A `var` / `out` argument is a variable: no keyword starts one.
      else if FArgByRef then
      // A constant expression: `nil` and `not` alone - `inherited`, an
      // anonymous method and an if-expression are E2026 there (dcc 37).
      else if FConstOnly then
        AddKeywords(['nil', 'not'])
      else
        AddKeywords(OPERAND_WORDS);
    ccType:
      // A ranked type position: `not` right after `is` (Delphi 13's
      // `is not`), the constraint keywords in a constraint, `string` in a
      // generic argument, nothing else - a type name stands there.
      if FTypePos <> tpNone then
      begin
        if (FTypePos = tpIsAs) and FTypeAfterIs then
          AddKeywords(['not'])
        else if FTypePos = tpConstraint then
          AddKeywords(['class', 'record', 'constructor'])
        else if FTypePos = tpGenArg then
          AddKeywords(['string'])
        // A type declaration's `T = |` takes a type constructor and the
        // `type` of a distinct type; `T = type |` a type identifier alone.
        else if (FTypePos = tpTypeDecl) and not FTypeAfterType then
          AddKeywords(TYPE_DECL_WORDS);
      end
      // A heritage list names declared types only - no type constructor.
      else if FHeritage <> nkError then
      // A pointer type's base: a type identifier or `string` (`^string`).
      else if LPrevKind = tkCaret then
        AddKeywords(['string'])
      else if LPrevKind = tkOf then
        case UpChainKind(AInfo.Node, [nkArrayType, nkFileType, nkParam]) of
          // An open array parameter's element: a type identifier, `const`.
          nkParam:
            AddKeywords(['const', 'string']);
          nkArrayType:
            if UpChainKind(AInfo.Node, [nkParam, nkVarDecl, nkTypeDecl,
               nkRoutine]) = nkParam then
              AddKeywords(['const', 'string'])
            else
              AddKeywords(VAR_TYPE_WORDS);
        end
      else if FTypeNameOnly then
      begin
        if UpChainKind(AInfo.Node, [nkParam, nkPropertyDecl, nkRoutine,
           nkProcType]) = nkParam then
          AddKeywords(PARAM_TYPE_WORDS)
        else
          AddKeywords(['string']);
      end
      else
        AddKeywords(VAR_TYPE_WORDS);
    ccStatement:
      begin
        // Decided by the NODE (audit A1-32): a statement list - a block, a
        // program's main block, an initialization or finalization section -
        // takes statement words; a routine's declaration part declaration
        // words; elsewhere the scope says unit level or a struct body.
        case StatementSiteKind(AInfo) of
          nkBlock, nkInitSec, nkFinalSec:
            AddKeywords(STMT_WORDS);
          nkRoutine:
            AddKeywords(ROUTINE_WORDS);
        else
          if AInfo.Scope <> NIL_SCOPE then
            case FModel.Scopes[AInfo.Scope].Kind of
              sckUnit, sckImplementation:
                AddKeywords(UNIT_WORDS);
              sckStruct:
                AddKeywords(STRUCT_WORDS);
            else
              AddKeywords(STMT_WORDS);
            end;
        end;
      end;
      else
        AddKeywords(STMT_WORDS);
  end;
end;

{ The type the operand at the caret must fit (the operand starts right after
  raw token AOp; OperandExpect, ExpectedTypeAt finds AOp): Boolean where it
  starts a condition (`if |`, `while |`, `until |`); after `not` what the
  `not` expression's own position makes of it (NotOperandExpect: Boolean or
  an integer type); the left operand's Boolean or integer type after `and`,
  `or`, `xor` (LogicalOperandExpect); after a grouping `(` what the
  parenthesized expression's position expects (`if (|`, `X := (|`); any ordinal after
  `case` (FExpectOrdinal, no one type); the selector's type in a `case`
  label (CaseLabelOf, FConstOnly); its parameter's
  where it starts a call's argument (`F(|`, `F(A, |`: ArgExpectAt), the
  routine's result in `Exit(|` (ExitExpect); an index's type or a set's
  element inside brackets (BracketExpect); otherwise the caret
  starts the right side of `:=` or of a comparison (`=`, `<>`, `<`, `>`,
  `<=`, `>=`), and the left side is a designator - a name, a member chain, a call, an index, a
  dereference - that the engine types. The right operand of an arithmetic
  operator is ranked by its left operand (ArithOperandExpect: `X := A + |`
  by A's family, not X's), a sign's by its own position
  (SignOperandExpect).

  The left side is found by tokens and the tree together: the designator
  node ending on the token before the operator, grown up its parents while
  they end there too. It must START the comparison: the token before it
  opens an expression or a statement (`if`, `(`, `,`, `;`, `then`, ...). A
  binary operator there means the left operand is longer than the
  designator - `A + B = |` compares the sum, `X and Y = |` the conjunction
  (`=` binds loosest, 5.2.1) - and nothing is expected rather than the
  wrong thing. A type name on the left after a colon is a declaration's
  type (`var X: Integer := |`, `const C: T = |`, a default parameter
  value), and that type is expected; any other type name (a type
  declaration) expects nothing. ComplNilRef when nothing is expected. }
function TPasCompletion.ExpectedTypeAt(
  const AInfo: TPasCaretInfo): TPasComplTypeRef;
const
  DESIGNATORS = [nkIdent, nkMember, nkCall, nkIndex, nkDeref, nkParen,
    nkTypeArgs];
var
  LOp, LNode, LParent, LLeft: Integer;
begin
  Result := ComplNilRef;
  if (FProj = nil) or (AInfo.Kind = ckNone) then
    Exit;
  if (FContext = ccMember) and (AInfo.DotBase <> NIL_NODE) then
  begin
    // `X := Obj.Sub.|`: the operator stands before the whole chain. Climb
    // from the dot's base while it is the base of a longer designator (the
    // same leftmost token) - not an argument (`F(A.|`), whose call starts
    // elsewhere and is no value of the left side's type.
    LNode := AInfo.DotBase;
    LLeft := FModel.Tree.NodeLeftmostVis(LNode);
    while True do
    begin
      LParent := FModel.Tree.Nodes[LNode].Parent;
      if (LParent = NIL_NODE) or
         not (FModel.Tree.Nodes[LParent].Kind in DESIGNATORS) or
         (FModel.Tree.NodeLeftmostVis(LParent) <> LLeft) then
        Break;
      LNode := LParent;
    end;
    if (LLeft < 0) or (LLeft > High(FModel.Tree.Source.Visible)) or
       (FModel.Tree.Source.Visible[LLeft].FileId <> 0) then
      Exit;
    LOp := PrevVisibleRaw(FModel.Tree.Source.Visible[LLeft].TokenIndex - 1);
  end
  else if AInfo.Kind = ckIdent then
    LOp := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    LOp := AInfo.RawToken;
  Result := OperandExpect(LOp, AInfo.Scope, 0);
end;

{ ExpectedTypeAt's answer for the operand starting right after raw token
  AOp. ADepth bounds the recursion through `not` and grouping parens. }
function TPasCompletion.OperandExpect(AOp, AScope,
  ADepth: Integer): TPasComplTypeRef;
var
  LTS: TPasTokenStream;
  LOp, LEnd, LVis, LLeft, LBefore: Integer;
  LInline: Boolean;
begin
  Result := ComplNilRef;
  LOp := AOp;
  if (LOp < 1) or (ADepth > 32) then
    Exit;
  LTS := FModel.Tree.Source.Files[0];
  // `not |` (`if not |`, `X := not |`, `Foo(not |)`): the `not` expression
  // stands where its own position puts it, and its operand is what makes
  // that - a Boolean, or an integer for a bitwise not (NotOperandExpect).
  if LTS.Tokens[LOp].Kind = tkNot then
  begin
    FCondLike := True;
    Exit(NotOperandExpect(
      OperandExpect(PrevVisibleRaw(LOp - 1), AScope, ADepth + 1)));
  end;
  // A condition - right after `if`, `while`, `until` - is a Boolean: the
  // operand starting there is the whole condition or its first operand,
  // which a relational operator would still make Boolean of any value.
  if LTS.Tokens[LOp].Kind in [tkIf, tkWhile, tkUntil] then
  begin
    FCondLike := True;
    if BridgeName('boolean', LLeft, LEnd) then
      Result.X := XPlain(LLeft, LEnd);
    Exit;
  end;
  // The right operand of `and` / `or` / `xor`: the left one's type, a
  // Boolean or an integer (LogicalOperandExpect).
  if LTS.Tokens[LOp].Kind in [tkAnd, tkOr, tkXor] then
  begin
    FCondLike := True;
    Exit(LogicalOperandExpect(LOp));
  end;
  // A sign (`X := -|`, `Foo(-|`) stands for what its own position expects
  // (SignOperandExpect); the right operand of an arithmetic operator
  // (`X := A + |`, `A div |`) is ranked by the left operand's family
  // (ArithOperandExpect).
  if (LTS.Tokens[LOp].Kind in [tkPlus, tkMinus]) and IsUnarySign(LOp) then
    Exit(SignOperandExpect(LOp, AScope, ADepth));
  if LTS.Tokens[LOp].Kind in [tkPlus, tkMinus, tkStar, tkSlash, tkDiv, tkMod,
     tkShl, tkShr] then
    Exit(ArithOperandExpect(LOp));
  // A grouping paren (`if (|`, `if (A) and (|`, `X := (|`): the
  // parenthesized expression - whose first operand starts at the caret -
  // stands where the `(` does. A call's or a cast's `(` is ArgExpectAt's.
  // Not where that is a Boolean (`if (|`, `A and (|`, `not (|`): there the
  // paren holds a comparison, whose left side - what is typed right after
  // the `(` - is a value of any type; ranking the Boolean values first
  // buried it (decided by Alex, 2026-11-09). Nothing is expected, and no
  // procedure is a value.
  if (LTS.Tokens[LOp].Kind = tkLParen) and IsGroupingParen(LOp) then
  begin
    Result := OperandExpect(PrevVisibleRaw(LOp - 1), AScope, ADepth + 1);
    if RefCatOf(Result) = tcBoolean then
    begin
      // FCondLike stays: `(not |` makes its own Boolean again, a condition's.
      Result := ComplNilRef;
      FArgNoProcs := True;
    end;
    Exit;
  end;
  // A `case` selector takes any ordinal: a category, FExpectOrdinal.
  if LTS.Tokens[LOp].Kind = tkCase then
  begin
    FExpectOrdinal := True;
    FCaseSel := True;
    Exit;
  end;
  // A `with` item - right after `with`, or a `,` of its list - is a value
  // whose members the body names: a category, FExpectWith.
  if (LTS.Tokens[LOp].Kind = tkWith) or
     ((LTS.Tokens[LOp].Kind = tkComma) and IsWithListComma(LOp)) then
  begin
    FExpectWith := True;
    Exit;
  end;
  // A raised object: a class instance, an Exception's above the rest
  // (FExpectRaise; FRaiseBase is Exception when the caret's unit names a
  // class of that name, as it does through SysUtils).
  // `raise X at |`: an address, a pointer value (FExpectAddr).
  if RaiseAtStart(LOp) then
  begin
    FExpectAddr := True;
    Exit;
  end;
  if LTS.Tokens[LOp].Kind = tkRaise then
  begin
    FExpectRaise := True;
    if BridgeName('exception', LLeft, LEnd) then
    begin
      FRaiseBase := FProj.CanonTypeX(XPlain(LLeft, LEnd));
      if not XValid(FRaiseBase) or (FProj.XCatOf(FRaiseBase) <> tcClass) then
        FRaiseBase := XNil;
    end;
    Exit;
  end;
  // Inside brackets - right after `[`, or a `,` or `..` of their list - an
  // index (`A[|]`, `M[I, |]`) or a set or array constructor's element
  // (`S := [|]`, `K in [A, |`): BracketExpect.
  if LTS.Tokens[LOp].Kind in [tkLBracket, tkComma, tkDotDot] then
  begin
    // A static array's bound (`array[|]`, `array[TKind, |]`, `array[0..|]`)
    // is a constant expression of an ordinal type, as a `case` label is:
    // any ordinal, after `..` the low bound's type (FConstOnly).
    if IsArrayBoundOp(LOp) then
    begin
      FConstOnly := True;
      FBoundType := LTS.Tokens[LOp].Kind <> tkDotDot;
      if LTS.Tokens[LOp].Kind = tkDotDot then
        Result := BoundLeftType(LOp);
      if not ComplValid(Result) then
        FExpectOrdinal := True;
      Exit;
    end;
    LBefore := BracketOpenOf(LOp, LVis);
    if LBefore >= 0 then
      Exit(BracketExpect(LBefore, LVis, AScope));
  end;
  // A `case` label - right after `of`, a `,` or `..` of a label list, or the
  // `;` ending an arm - is a constant of the selector's type (CaseLabelOf).
  if LTS.Tokens[LOp].Kind in [tkOf, tkComma, tkDotDot, tkSemicolon] then
  begin
    LBefore := CaseLabelOf(LOp);
    if LBefore >= 0 then
    begin
      FConstOnly := True;
      Exit(CaseSelectorType(LBefore));
    end;
  end;
  // A subrange type's high bound (`T = clRed..|`, `var X: 0..|`): a
  // constant of the low bound's type, else any ordinal.
  if IsSubrangeHighOp(LOp) then
  begin
    FConstOnly := True;
    Result := BoundLeftType(LOp);
    if not ComplValid(Result) then
      FExpectOrdinal := True;
    Exit;
  end;
  // A for-in collection (`for X in |`): what can be enumerated, its element
  // ranked against X's declared type (ForInStart, MatchOf's EnumFit).
  if (LTS.Tokens[LOp].Kind = tkIn) and ForInStart(LOp, LBefore, LInline) then
  begin
    FExpectEnum := True;
    if not LInline then
    begin
      FEnumElem := RefValueX(RawDesignatorType(LBefore), LEnd);
      if XValid(FEnumElem) then
        FEnumElem := FProj.CanonTypeX(FEnumElem);
    end;
    Exit;
  end;
  // A `for` bound after `to` / `downto` expects the counter's type, as the
  // first bound does: typed through the loop's `:=` (ForAssignOf).
  if LTS.Tokens[LOp].Kind in [tkTo, tkDownto] then
  begin
    LOp := ForAssignOf(LOp);
    if LOp < 0 then
      Exit;
  end;
  // An inline variable or counter with no declared type (`var X := |`,
  // `for var I := |`) is typed by its initializer: nothing to expect, but a
  // value stands there - no procedure. (dcc 37 compiles `var X := Proc`,
  // into a variable of type 'Procedure' that cannot be called: never what
  // is meant.) An inline constant's `const C = |` likewise.
  if LTS.Tokens[LOp].Kind in [tkAssign, tkEqual] then
  begin
    LBefore := PrevVisibleRaw(LOp - 1);
    if (LBefore >= 1) and (LTS.Tokens[LBefore].Kind = tkIdentifier) then
    begin
      LBefore := PrevVisibleRaw(LBefore - 1);
      if (LBefore >= 0) and
         ((LTS.Tokens[LOp].Kind = tkAssign) and
          (LTS.Tokens[LBefore].Kind = tkVar) or
          (LTS.Tokens[LOp].Kind = tkEqual) and
          (LTS.Tokens[LBefore].Kind = tkConst)) then
      begin
        FArgNoProcs := True;
        Exit;
      end;
    end;
  end;
  // A call's argument - the operand right after its `(` or a `,` of its
  // list - expects its parameter's type (ArgExpectAt).
  // A value parameter and `:=` take every descendant of a root type alike
  // (FFlatRoot).
  if LTS.Tokens[LOp].Kind in [tkLParen, tkComma] then
  begin
    Result := ArgExpectAt(LOp, AScope);
    FFlatRootPos := not FArgByRef;
    Exit;
  end;
  FCompare := LTS.Tokens[LOp].Kind in [tkEqual, tkNotEqual, tkLess, tkGreater,
    tkLessEqual, tkGreaterEqual];
  FFlatRootPos := LTS.Tokens[LOp].Kind = tkAssign;
  Result := OperatorLeftType(LOp, False);
end;

{ The category of the value an expected-type reference stands for -
  tcUnknown when it is none or untyped. }
function TPasCompletion.RefCatOf(const ARef: TPasComplTypeRef): TSemaTypeCat;
var
  LX: TSemaXType;
  LOv: Integer;
begin
  Result := tcUnknown;
  if not ComplValid(ARef) then
    Exit;
  LX := RefValueX(ARef, LOv);
  if XValid(LX) then
    Result := FProj.XCatOf(LX)
  else if LOv <> NIL_SYM then
    Result := FModel.Symbols[LOv].TypeCat;
end;

{ The operand of a `not` whose own position expects AOuter. `not` makes a
  Boolean of a Boolean and an integer of an integer (5.3): where an integer
  is expected the operand is that integer (a bitwise not), where a Boolean
  or nothing is expected a Boolean - `X := not |` with X untyped, `Foo(not
  |)` with an untyped parameter. Where something else is expected (a
  string) no `not` fits, and nothing is ranked. A `not` expression is never
  a variable (FArgByRef off) and never a procedure (FArgNoProcs). A category
  context (`case not |`: FExpectOrdinal) is kept as it is. }
function TPasCompletion.NotOperandExpect(
  const AOuter: TPasComplTypeRef): TPasComplTypeRef;
var
  LMid, LSym: Integer;
begin
  Result := ComplNilRef;
  FArgNoProcs := True;
  FArgByRef := False;
  FArgOpenElem := ComplNilRef;
  if FExpectOrdinal or FExpectEnum or (FCastRef <> tcUnknown) or
     (FCastValue <> tcUnknown) or FExpectAddr then
    Exit;
  case RefCatOf(AOuter) of
    tcInteger, tcBoolean:
      begin
        Result := AOuter;
        Result.IsTypeRef := False;
      end;
    tcUnknown:
      if not ComplValid(AOuter) and BridgeName('boolean', LMid, LSym) then
        Result.X := XPlain(LMid, LSym);
  end;
end;

{ The right operand of the `and` / `or` / `xor` at raw token AOp: the left
  operand's type (LeftOperandType) when that is a Boolean (a logical
  operator) or an integer (a bitwise one), else nothing. `and` is
  multiplicative (5.2.1): in `if A = B and |` B decides, in `X * Y and |`
  the product does. Never a procedure, typed or not (FArgNoProcs). }
function TPasCompletion.LogicalOperandExpect(AOp: Integer): TPasComplTypeRef;
begin
  FArgNoProcs := True;
  Result := LeftOperandType(AOp);
  if not (RefCatOf(Result) in [tcBoolean, tcInteger]) then
    Result := ComplNilRef;
end;

{ The precedence of binary operator AKind (5.2.1): 2 multiplicative (`*`
  `/` `div` `mod` `and` `shl` `shr`), 1 additive (`+` `-` `or` `xor`), 0
  relational (`=` `<>` `<` `>` `<=` `>=` `in` `is`); -1 for anything else -
  `as` too, whose right side is a type the operand walk does not type. }
function BinaryOpPrec(AKind: TPasTokenKind): Integer;
begin
  case AKind of
    tkStar, tkSlash, tkDiv, tkMod, tkAnd, tkShl, tkShr:
      Result := 2;
    tkPlus, tkMinus, tkOr, tkXor:
      Result := 1;
    tkEqual, tkNotEqual, tkLess, tkGreater, tkLessEqual, tkGreaterEqual,
    tkIn, tkIs:
      Result := 0;
  else
    Result := -1;
  end;
end;

{ Is the `+` / `-` at raw token ASign a sign rather than a binary operator?
  A binary one follows an operand's last token - a name, a literal, `)`,
  `]`, `^`, `nil`; anything else (an opener, an operator, `:=`) makes it a
  sign. }
function TPasCompletion.IsUnarySign(ASign: Integer): Boolean;
var
  LPrev: Integer;
begin
  LPrev := PrevVisibleRaw(ASign - 1);
  Result := (LPrev < 0) or not (FModel.Tree.Source.Files[0].Tokens[LPrev].Kind
    in [tkIdentifier, tkIntLiteral, tkRealLiteral, tkStringLiteral,
        tkControlChar, tkCaretChar, tkRParen, tkRBracket, tkCaret, tkNil,
        tkString]);
end;

{ The operand of the sign at raw token AOp (`X := -|`, `Foo(-|`, `A * -|`):
  the sign stands where its position puts it, so that position's number
  type is expected - an integer as it is, a float with any number fitting
  (FExpectNumber). Where nothing or a category is expected that is kept;
  where something else is (a string), no sign fits and nothing is ranked.
  A signed value is never a variable (FArgByRef off) nor a procedure. }
function TPasCompletion.SignOperandExpect(AOp, AScope,
  ADepth: Integer): TPasComplTypeRef;
var
  LOuter: TPasComplTypeRef;
begin
  Result := ComplNilRef;
  LOuter := OperandExpect(PrevVisibleRaw(AOp - 1), AScope, ADepth + 1);
  FArgNoProcs := True;
  FArgByRef := False;
  FArgOpenElem := ComplNilRef;
  case RefCatOf(LOuter) of
    tcInteger:
      Result := LOuter;
    tcFloat:
      begin
        Result := LOuter;
        FExpectNumber := True;
      end;
    tcUnknown:
      Result := LOuter;
  end;
  Result.IsTypeRef := False;
end;

{ The right operand of the arithmetic operator at raw token AOp (`+` `-`
  `*` `/` `div` `mod` `shl` `shr`), by the left operand's family
  (LeftOperandType - precedence applied, `A + B * |` is B's):
  - a number: after `+` `-` `*` `/` any integer or float fits, the left
    operand's own type first (FExpectNumber); `div` `mod` `shl` `shr` want
    an integer - the left one's type, a float is wrong there;
  - a string or a Char after `+`: a string (the left one's string type) -
    a Char converts;
  - a set after `+` `-` `*`: the set's type;
  - a typed pointer after `+` `-`: an integer (pointer arithmetic, dcc 37
    takes `P + I` / `P - I` for PChar and PByte and under the POINTERMATH
    directive; whether the type allows it is not told apart - PInteger ranks the
    same, though `PI + 1` is E2015 without POINTERMATH); an untyped Pointer
    nothing (`Q + 1` is E2015);
  - a dynamic array after `+`: its own type (concatenation);
  - a record: its `class operator`'s right parameter, when the left
    operand is its first and one type is taken there (several overloads
    taking different types rank nothing).
  Never a procedure, whatever the left side is (FArgNoProcs). }
function TPasCompletion.ArithOperandExpect(AOp: Integer): TPasComplTypeRef;
var
  LKind: TPasTokenKind;
  LLeft: TPasComplTypeRef;
  LX: TSemaXType;
  LOv, LMid, LSym: Integer;
  LRights: TArray<TSemaXType>;
begin
  Result := ComplNilRef;
  FArgNoProcs := True;
  LKind := FModel.Tree.Source.Files[0].Tokens[AOp].Kind;
  LLeft := LeftOperandType(AOp);
  if not ComplValid(LLeft) then
    Exit;
  LLeft.IsTypeRef := False;
  case RefCatOf(LLeft) of
    tcInteger:
      begin
        Result := LLeft;
        FExpectNumber := LKind in [tkPlus, tkMinus, tkStar, tkSlash];
      end;
    tcFloat:
      if LKind in [tkPlus, tkMinus, tkStar, tkSlash] then
      begin
        Result := LLeft;
        FExpectNumber := True;
      end;
    tcString:
      if LKind = tkPlus then
        Result := LLeft;
    tcChar:
      if (LKind = tkPlus) and BridgeName('string', LMid, LSym) then
        Result.X := XPlain(LMid, LSym);
    tcSet:
      if LKind in [tkPlus, tkMinus, tkStar] then
        Result := LLeft;
    tcPointer:
      begin
        // An untyped Pointer takes no arithmetic (dcc 37: `Q + 1` is E2015).
        LX := RefValueX(LLeft, LOv);
        if (LKind in [tkPlus, tkMinus]) and XValid(LX) and
           not (BridgeName('pointer', LMid, LSym) and
                FProj.XSameType(FProj.CanonTypeX(LX),
                  FProj.CanonTypeX(XPlain(LMid, LSym)))) and
           BridgeName('integer', LMid, LSym) then
          Result.X := XPlain(LMid, LSym);
      end;
    tcArray:
      begin
        LX := RefValueX(LLeft, LOv);
        if (LKind = tkPlus) and XValid(LX) and FProj.IsDynArrayTypeX(LX) then
          Result := LLeft;
      end;
    tcRecord:
      begin
        LX := RefValueX(LLeft, LOv);
        if XValid(LX) then
        begin
          LRights := FProj.RecordOperatorRightsX(LKind, LX);
          if Length(LRights) = 1 then
            Result.X := LRights[0];
        end;
      end;
  end;
end;

{ The type of the left operand of the binary operator at raw token AOp:
  the expression ending before it, of the operators binding at least as
  tightly (left-associative, 5.2.1) - `A - B + |` is the difference, in
  `A + B * |` it is B, in `if A = B + |` B. It must start where an
  expression does: after an opener or an operator binding more loosely.
  ComplNilRef when it cannot be typed (ExprTypeEndingAt). }
function TPasCompletion.LeftOperandType(AOp: Integer): TPasComplTypeRef;
const
  OPENERS = [tkIf, tkWhile, tkUntil, tkLParen, tkLBracket, tkComma,
    tkSemicolon, tkColon, tkAssign, tkBegin, tkThen, tkElse, tkDo,
    tkRepeat, tkTry, tkFinally, tkExcept, tkOf, tkFor, tkTo, tkDownto,
    tkCase, tkDotDot];
var
  LTS: TPasTokenStream;
  LPrec, LBefore: Integer;
begin
  Result := ComplNilRef;
  LTS := FModel.Tree.Source.Files[0];
  if (FProj = nil) or (AOp < 1) then
    Exit;
  LPrec := BinaryOpPrec(LTS.Tokens[AOp].Kind);
  if LPrec < 0 then
    Exit;
  Result := ExprTypeEndingAt(PrevVisibleRaw(AOp - 1), LPrec, 0, LBefore);
  if (LBefore < 0) or
     not ((LTS.Tokens[LBefore].Kind in OPENERS) or
          (BinaryOpPrec(LTS.Tokens[LBefore].Kind) >= 0)) or
     Result.IsTypeRef then
    Result := ComplNilRef;
end;

{ The type of the expression ending on raw token AEndRaw that chains
  operands with binary operators of precedence AMinPrec or tighter
  (BinaryOpPrec), walked back from its end; ABeforeRaw is the token before
  it. Each operand is OperandEndingAt's; the chain is folded by precedence,
  left to right within a level, through the analysis's operator table
  (TPasSemaProject.BinaryResultX - 4.2.1, a record's `class operator`).
  ComplNilRef when an operand or a step cannot be typed. }
function TPasCompletion.ExprTypeEndingAt(AEndRaw, AMinPrec, ADepth: Integer;
  out ABeforeRaw: Integer): TPasComplTypeRef;
var
  LTS: TPasTokenStream;
  LRefs: TArray<TPasComplTypeRef>;
  LOps: TArray<TPasTokenKind>;
  LXs: TArray<TSemaXType>;
  LRef: TPasComplTypeRef;
  LRaw, LBefore, LI, LOv, LLevel: Integer;
  LKind: TPasTokenKind;
begin
  Result := ComplNilRef;
  ABeforeRaw := -1;
  if (FProj = nil) or (ADepth > 8) then
    Exit;
  LTS := FModel.Tree.Source.Files[0];
  LRefs := nil;
  LOps := nil;
  LRaw := AEndRaw;
  while True do
  begin
    LRef := OperandEndingAt(LRaw, ADepth, LBefore);
    if not ComplValid(LRef) or LRef.IsTypeRef or (Length(LRefs) > 64) then
      Exit;
    LRefs := [LRef] + LRefs;
    if LBefore < 0 then
      Exit;
    LKind := LTS.Tokens[LBefore].Kind;
    if BinaryOpPrec(LKind) < AMinPrec then
      Break;
    LOps := [LKind] + LOps;
    LRaw := PrevVisibleRaw(LBefore - 1);
  end;
  ABeforeRaw := LBefore;
  if LOps = nil then
    Exit(LRefs[0]);
  SetLength(LXs, Length(LRefs));
  for LI := 0 to High(LRefs) do
  begin
    LXs[LI] := RefValueX(LRefs[LI], LOv);
    if not XValid(LXs[LI]) then
      Exit;
  end;
  for LLevel := 2 downto AMinPrec do
  begin
    LI := 0;
    while LI <= High(LOps) do
      if BinaryOpPrec(LOps[LI]) = LLevel then
      begin
        LXs[LI] := FProj.BinaryResultX(FProjMid, LOps[LI], LXs[LI],
          LXs[LI + 1]);
        if not XValid(LXs[LI]) then
          Exit;
        Delete(LXs, LI + 1, 1);
        Delete(LOps, LI, 1);
      end
      else
        Inc(LI);
  end;
  Result.X := LXs[0];
end;

{ The type of the one operand ending on raw token AEndRaw - a literal (an
  integer one Integer, a real one Extended, a text one a Char when it is
  one character, else a string; adjacent ones `'a'#13` are one), a grouping
  paren (its expression, ExprTypeEndingAt), or a designator (DesignatorType)
  - with the `not` and the signs before it, which change no type. A type
  (`TFoo` alone) is answered as one: the caller declines it. ABeforeRaw is
  the token before the operand. }
function TPasCompletion.OperandEndingAt(AEndRaw, ADepth: Integer;
  out ABeforeRaw: Integer): TPasComplTypeRef;
var
  LTS: TPasTokenStream;
  LBefore, LMid, LSym, LCount, LOpen, LLevel, LInner, LNode: Integer;
  LChar: Boolean;
begin
  Result := ComplNilRef;
  ABeforeRaw := -1;
  if AEndRaw < 0 then
    Exit;
  LTS := FModel.Tree.Source.Files[0];
  LBefore := -1;
  case LTS.Tokens[AEndRaw].Kind of
    tkIntLiteral:
      begin
        if BridgeName('integer', LMid, LSym) then
          Result.X := XPlain(LMid, LSym);
        LBefore := PrevVisibleRaw(AEndRaw - 1);
      end;
    tkRealLiteral:
      begin
        if BridgeName('extended', LMid, LSym) then
          Result.X := XPlain(LMid, LSym);
        LBefore := PrevVisibleRaw(AEndRaw - 1);
      end;
    tkStringLiteral, tkControlChar, tkCaretChar:
      begin
        LCount := 0;
        LChar := True;
        LBefore := AEndRaw;
        while (LBefore >= 0) and (LTS.Tokens[LBefore].Kind in
          [tkStringLiteral, tkControlChar, tkCaretChar]) do
        begin
          if (LTS.Tokens[LBefore].Kind = tkStringLiteral) and
             (LTS.Tokens[LBefore].Len <> 3) then
            LChar := False;
          Inc(LCount);
          LBefore := PrevVisibleRaw(LBefore - 1);
        end;
        if LChar and (LCount = 1) then
        begin
          if BridgeName('char', LMid, LSym) then
            Result.X := XPlain(LMid, LSym);
        end
        else if BridgeName('string', LMid, LSym) then
          Result.X := XPlain(LMid, LSym);
      end;
  else
    // A grouping paren: the expression inside, whole.
    LOpen := -1;
    if LTS.Tokens[AEndRaw].Kind = tkRParen then
    begin
      LLevel := 0;
      LOpen := AEndRaw;
      while LOpen >= 0 do
      begin
        case LTS.Tokens[LOpen].Kind of
          tkRParen, tkRBracket:
            Inc(LLevel);
          tkLParen, tkLBracket:
            begin
              Dec(LLevel);
              if LLevel = 0 then
                Break;
            end;
        end;
        LOpen := PrevVisibleRaw(LOpen - 1);
      end;
      if (LOpen >= 0) and ((LTS.Tokens[LOpen].Kind <> tkLParen) or
         not IsGroupingParen(LOpen)) then
        LOpen := -1;
    end;
    if LOpen >= 0 then
    begin
      Result := ExprTypeEndingAt(PrevVisibleRaw(AEndRaw - 1), 0, ADepth + 1,
        LInner);
      if (LInner <> LOpen) or not ComplValid(Result) then
      begin
        // A comparison or a membership test is a Boolean whatever its
        // operands are - `(X = nil)`, `(A <> B.C[I])`, operands the walk
        // cannot type (`nil`, a call's result) included.
        Result := ComplNilRef;
        if not GroupIsRelation(LOpen, AEndRaw) or
           not BridgeName('boolean', LMid, LSym) then
          Exit;
        Result.X := XPlain(LMid, LSym);
      end;
      LBefore := PrevVisibleRaw(LOpen - 1);
    end
    else
    begin
      LNode := DesignatorEndingAt(AEndRaw, LBefore);
      if LNode = NIL_NODE then
        Exit;
      Result := DesignatorType(LNode, 0);
    end;
  end;
  // A prefix `not` or sign keeps the operand's type.
  while LBefore >= 0 do
    if (LTS.Tokens[LBefore].Kind = tkNot) or
       ((LTS.Tokens[LBefore].Kind in [tkPlus, tkMinus]) and
        IsUnarySign(LBefore)) then
      LBefore := PrevVisibleRaw(LBefore - 1)
    else
      Break;
  ABeforeRaw := LBefore;
end;

{ Does the grouping paren from raw token AOpen to AClose hold a relation at
  its own level - `=` `<>` `<` `>` `<=` `>=` `in` `is` outside any nested
  bracket? Relational operators bind loosest (5.2.1), so one there makes the
  whole content a Boolean. A `<` / `>` of type arguments (`TList<T>.Create`)
  would count too: only asked when the content could not be typed. }
function TPasCompletion.GroupIsRelation(AOpen, AClose: Integer): Boolean;
var
  LTS: TPasTokenStream;
  LRaw, LDepth: Integer;
begin
  Result := False;
  LTS := FModel.Tree.Source.Files[0];
  LDepth := 0;
  LRaw := PrevVisibleRaw(AClose - 1);
  while (LRaw > AOpen) and (LRaw >= 0) do
  begin
    case LTS.Tokens[LRaw].Kind of
      tkRParen, tkRBracket:
        Inc(LDepth);
      tkLParen, tkLBracket:
        Dec(LDepth);
    else
      if (LDepth = 0) and (BinaryOpPrec(LTS.Tokens[LRaw].Kind) = 0) then
        Exit(True);
    end;
    LRaw := PrevVisibleRaw(LRaw - 1);
  end;
end;

{ Is the `(` at raw token AParen a grouping paren rather than a call's or a
  value typecast's? A call or a cast follows a designator - a name, `)`,
  `]`, `^`, the `string` keyword; a `>` is a generic's type arguments
  (`Foo<T>(`) or a comparison (`A > (`), told apart by the tree. Anything
  else - a keyword, an operator, another `(` - opens a grouping. A typed
  constant's or variable's initializer (`const R: TRec = (`, an array
  constant) is a record or array constant, no grouping. }
function TPasCompletion.IsGroupingParen(AParen: Integer): Boolean;
var
  LTS: TPasTokenStream;
  LPrev, LVis, LNode, LBefore: Integer;
begin
  Result := False;
  LTS := FModel.Tree.Source.Files[0];
  LPrev := PrevVisibleRaw(AParen - 1);
  if LPrev < 0 then
    Exit;
  case LTS.Tokens[LPrev].Kind of
    tkIdentifier, tkRParen, tkRBracket, tkCaret, tkString:
      Exit;
    tkGreater:
      begin
        LVis := FVisOfRaw[AParen];
        if LVis < 0 then
          Exit;
        LNode := InnermostNodeAt(LVis);
        Exit((LNode <> NIL_NODE) and
          (FModel.Tree.Nodes[LNode].Kind = nkParen));
      end;
    tkEqual:
      begin
        if (DesignatorEndingAt(PrevVisibleRaw(LPrev - 1), LBefore) <>
            NIL_NODE) and (LBefore >= 0) and
           (LTS.Tokens[LBefore].Kind = tkColon) then
          Exit;
      end;
  end;
  Result := True;
end;

{ Does the `,` at raw token AComma separate the items of a `with` list
  (`with A, |`)? The walk goes back over nested `()` / `[]`; a `with` at
  the outer level says yes, a `(` or `[` there (an argument list, a set) or
  a statement boundary first says no. }
function TPasCompletion.IsWithListComma(AComma: Integer): Boolean;
var
  LTS: TPasTokenStream;
  LRaw, LDepth, LSteps: Integer;
begin
  Result := False;
  LTS := FModel.Tree.Source.Files[0];
  LDepth := 0;
  LSteps := 0;
  LRaw := PrevVisibleRaw(AComma - 1);
  while (LRaw >= 0) and (LSteps < 4096) do
  begin
    case LTS.Tokens[LRaw].Kind of
      tkRParen, tkRBracket:
        Inc(LDepth);
      tkLParen, tkLBracket:
        if LDepth = 0 then
          Exit
        else
          Dec(LDepth);
      tkWith:
        if LDepth = 0 then
          Exit(True);
      tkSemicolon, tkBegin, tkEnd, tkThen, tkDo, tkElse, tkOf, tkIf,
      tkWhile, tkUntil, tkRepeat, tkAssign, tkTry, tkFinally, tkExcept,
      tkColon:
        if LDepth = 0 then
          Exit;
    end;
    LRaw := PrevVisibleRaw(LRaw - 1);
    Inc(LSteps);
  end;
end;

{ The designator node that ends on raw token AEndRaw, grown up its parents
  while they end there too (a member chain, a call, an index) - NIL_NODE
  when no designator ends there. ABeforeRaw is the raw token before its
  leftmost token (-1 when that is in another file). }
function TPasCompletion.DesignatorEndingAt(AEndRaw: Integer;
  out ABeforeRaw: Integer): Integer;
const
  DESIGNATORS = [nkIdent, nkMember, nkCall, nkIndex, nkDeref, nkParen,
    nkTypeArgs];
var
  LVis, LParent, LLeft: Integer;
begin
  Result := NIL_NODE;
  ABeforeRaw := -1;
  if AEndRaw < 0 then
    Exit;
  LVis := FVisOfRaw[AEndRaw];
  if LVis < 0 then
    Exit;
  Result := InnermostNodeAt(LVis);
  if (Result = NIL_NODE) or
     not (FModel.Tree.Nodes[Result].Kind in DESIGNATORS) then
    Exit(NIL_NODE);
  while True do
  begin
    LParent := FModel.Tree.Nodes[Result].Parent;
    if (LParent = NIL_NODE) or
       (FModel.Tree.Nodes[LParent].LastToken <> LVis) or
       not (FModel.Tree.Nodes[LParent].Kind in DESIGNATORS) then
      Break;
    Result := LParent;
  end;
  LLeft := FModel.Tree.NodeLeftmostVis(Result);
  if (LLeft < 0) or (LLeft > High(FModel.Tree.Source.Visible)) or
     (FModel.Tree.Source.Visible[LLeft].FileId <> 0) then
    Exit(NIL_NODE);
  ABeforeRaw := PrevVisibleRaw(
    FModel.Tree.Source.Visible[LLeft].TokenIndex - 1);
end;

{ The type of the left side of the operator at raw token AOp - `:=` or a
  comparison, and `in` when AAllowIn (`K in [|`: K's type) - when that left
  side is a designator starting the expression (ExpectedTypeAt's comment).
  ComplNilRef otherwise. }
function TPasCompletion.OperatorLeftType(AOp: Integer;
  AAllowIn: Boolean): TPasComplTypeRef;
const
  OPERATORS = [tkAssign, tkEqual, tkNotEqual, tkLess, tkGreater,
    tkLessEqual, tkGreaterEqual];
  // What may stand before an operand that starts its expression.
  OPENERS = [tkIf, tkWhile, tkUntil, tkLParen, tkLBracket, tkComma,
    tkSemicolon, tkColon, tkAssign, tkBegin, tkThen, tkElse, tkDo,
    tkRepeat, tkTry, tkFinally, tkExcept, tkOf, tkFor];
var
  LTS: TPasTokenStream;
  LNode, LBefore: Integer;
begin
  Result := ComplNilRef;
  LTS := FModel.Tree.Source.Files[0];
  if (AOp < 1) or not ((LTS.Tokens[AOp].Kind in OPERATORS) or
     AAllowIn and (LTS.Tokens[AOp].Kind = tkIn)) then
    Exit;
  LNode := DesignatorEndingAt(PrevVisibleRaw(AOp - 1), LBefore);
  if (LNode = NIL_NODE) or (LBefore < 0) or
     not (LTS.Tokens[LBefore].Kind in OPENERS) then
  begin
    // A comparison's longer left side - `I + 1 = |`, `X and Y = |`, a
    // literal - is typed as the expression it is (`=` binds loosest).
    if LTS.Tokens[AOp].Kind <> tkAssign then
      Result := LeftOperandType(AOp);
    Exit;
  end;
  Result := DesignatorType(LNode, 0);
  if Result.IsTypeRef then
  begin
    // A declaration's type before its initializer - `var X: T := |`,
    // `const C: T = |`, a default `(A: T = |)` - is the type expected, as
    // the variable's would be in `X := |`. Any other type name (a type
    // declaration's `T = |`) expects nothing.
    if LTS.Tokens[LBefore].Kind = tkColon then
    begin
      Result.IsTypeRef := False;
      // After `=` it is a typed constant's value, a parameter's default or
      // an initialized global's: a constant expression - no variable, no
      // function (FConstOnly, as a `case` label). Except of a procedural
      // type, whose constant is a routine (`const P: TProc = Foo`).
      if (LTS.Tokens[AOp].Kind = tkEqual) and (RefCatOf(Result) <> tcProc) then
        FConstOnly := True;
    end
    else
      Result := ComplNilRef;
  end;
end;

{ The `[` whose list the operand after raw token ARaw (a `[`, `,` or `..`)
  stands in, and in AIndex its position there (the commas before it at the
  list's level). The walk goes back as ArgExpectAt's does - nested `()` /
  `[]` skipped - and a `(` or a statement boundary first means it is no
  bracket's (a call's argument, a case label); -1 then. }
function TPasCompletion.BracketOpenOf(ARaw: Integer;
  out AIndex: Integer): Integer;
var
  LTS: TPasTokenStream;
  LDepth, LSteps: Integer;
begin
  Result := -1;
  AIndex := 0;
  LTS := FModel.Tree.Source.Files[0];
  LDepth := 0;
  LSteps := 0;
  while (ARaw >= 0) and (LSteps < 4096) do
  begin
    case LTS.Tokens[ARaw].Kind of
      tkRParen, tkRBracket:
        Inc(LDepth);
      tkLBracket:
        if LDepth = 0 then
          Exit(ARaw)
        else
          Dec(LDepth);
      tkLParen:
        if LDepth = 0 then
          Exit
        else
          Dec(LDepth);
      tkComma:
        if LDepth = 0 then
          Inc(AIndex);
      tkSemicolon, tkBegin, tkEnd, tkThen, tkDo, tkElse, tkOf, tkIf,
      tkWhile, tkUntil, tkRepeat, tkAssign:
        if LDepth = 0 then
          Exit;
    end;
    ARaw := PrevVisibleRaw(ARaw - 1);
    Inc(LSteps);
  end;
end;

{ What the operand at position AIndex of the brackets opened at raw token
  AOpen expects. After a designator (a name, `)`, `]`, `^`) they index it:
  the index type (IndexTypeOf; an array property's parameter,
  ArrayPropIndexType). Otherwise they construct a set or an array: after
  `:=` or a comparison its element, of the left side's type (a set's base, a
  dynamic array's element - SetElementRef); after `in` the left operand's
  own type (`K in [|`); as a call's argument the parameter's (an open
  array's element, a set's base, ArgExpectAt). An index and a set's element
  never take a procedure, typed or not (FArgNoProcs); an array's element
  may (an array of procedural values), so it is left to the type. Any other
  `[` - an attribute - expects nothing. }
function TPasCompletion.BracketExpect(AOpen, AIndex,
  AScope: Integer): TPasComplTypeRef;
var
  LTS: TPasTokenStream;
  LPrev, LNode, LBefore: Integer;
  LBase: TPasComplTypeRef;
  LIsSet: Boolean;
begin
  Result := ComplNilRef;
  LTS := FModel.Tree.Source.Files[0];
  LPrev := PrevVisibleRaw(AOpen - 1);
  if LPrev < 1 then
    Exit;
  case LTS.Tokens[LPrev].Kind of
    tkIdentifier, tkRParen, tkRBracket, tkCaret:
      begin
        LNode := DesignatorEndingAt(LPrev, LBefore);
        if LNode = NIL_NODE then
          Exit;
        FArgNoProcs := True;
        if IsArrayPropertyDesignator(LNode, 0) then
          Exit(ArrayPropIndexType(LNode, AIndex));
        LBase := DesignatorType(LNode, 0);
        if ComplValid(LBase) and not LBase.IsTypeRef then
          Result := IndexTypeOf(LBase, AIndex);
      end;
    tkIn:
      begin
        FArgNoProcs := True;
        Result := OperatorLeftType(LPrev, True);
      end;
    tkAssign, tkEqual, tkNotEqual, tkLessEqual, tkGreaterEqual:
      begin
        Result := SetElementRef(OperatorLeftType(LPrev, False), LIsSet);
        FArgNoProcs := LIsSet;
        if not ComplValid(Result) then
        begin
          Result := SetConstElemRef(LPrev);
          if ComplValid(Result) then
            FArgNoProcs := True;
        end;
      end;
    // An operand of a set operator (`S + [|`, `S - [A, |`, `S * [|`) or of
    // an array concatenation (`Arr + [|`): the left operand's element.
    tkPlus, tkMinus, tkStar:
      if not IsUnarySign(LPrev) then
      begin
        Result := SetElementRef(LeftOperandType(LPrev), LIsSet);
        FArgNoProcs := LIsSet;
        if not ComplValid(Result) then
        begin
          Result := SetConstElemRef(LPrev);
          if ComplValid(Result) then
            FArgNoProcs := True;
        end;
      end;
    tkLParen, tkComma:
      begin
        FArgOpenElem := ComplNilRef;
        LBase := ArgExpectAt(LPrev, AScope);
        // The brackets are the argument, never a variable of a `var` one,
        // nor a cast's operand itself (`TColors([|` is the set's element).
        FArgByRef := False;
        FExpectOrdinal := False;
        FCastRef := tcUnknown;
        FCastValue := tcUnknown;
        if ComplValid(FArgOpenElem) then
          Result := FArgOpenElem
        else
        begin
          Result := SetElementRef(LBase, LIsSet);
          if LIsSet then
            FArgNoProcs := True;
        end;
      end;
  end;
end;

{ The element of a true set constant left of the set operator at raw token
  AOp - `SECTION_WORDS + [|` with `SECTION_WORDS = [tkA, tkB]`: such a
  constant has no declared type, and the analysis records none for a set
  constructor, so its first element names the element type - an
  enumeration value's enumeration. Also a field or variable typed `set of T`
  inline (`F.Flags := [|`, `F.Flags + [|`): T. ComplNilRef for anything
  else. }
function TPasCompletion.SetConstElemRef(AOp: Integer): TPasComplTypeRef;
var
  LNode, LBefore, LMid, LSym, LDecl, LInit, LCh, LBound: Integer;
  LM: TPasSemaModel;
  LExt: TPasExtRef;
begin
  Result := ComplNilRef;
  LNode := DesignatorEndingAt(PrevVisibleRaw(AOp - 1), LBefore);
  if (LNode = NIL_NODE) or not DesignatorSymOf(LNode, 0, LMid, LSym) or
     not SymModelOf(LMid, 'SetConstElemRef', LM) then
    Exit;
  // A field or variable typed `set of T` inline (`Flags: set of TKind`)
  // names no set type to take the element from: T is the element.
  LInit := LM.Symbols[LSym].TypeNode;
  if (LInit <> NIL_NODE) and (LM.Tree.Nodes[LInit].Kind = nkSetType) and
     (LM.Symbols[LSym].Kind in [skVar, skField, skParam, skProperty]) then
  begin
    LCh := LM.Tree.Nodes[LInit].FirstChild;
    if (LCh = NIL_NODE) or
       not (LM.Tree.Nodes[LCh].Kind in [nkIdent, nkMember]) then
      Exit;
    if LMid >= 0 then
    begin
      Result.X := FProj.ResolveTypeExpr(LMid, LCh);
      if XValid(Result.X) then
        Result.X := FProj.CanonTypeX(Result.X);
    end
    else
    begin
      Result := ResolveTypeRefNode(LCh, 0);
      Result.IsTypeRef := False;
    end;
    Exit;
  end;
  if (LM.Symbols[LSym].Kind <> skConst) or
     (LM.Symbols[LSym].TypeNode <> NIL_NODE) then
    Exit;
  LDecl := LM.Symbols[LSym].DeclNode;
  if (LDecl = NIL_NODE) or (LM.Tree.Nodes[LDecl].Parent = NIL_NODE) or
     (LM.Tree.Nodes[LM.Tree.Nodes[LDecl].Parent].Kind <> nkConstDecl) then
    Exit;
  // The initializer: the declaration's last child short of its hints.
  LInit := NIL_NODE;
  LCh := LM.Tree.Nodes[LM.Tree.Nodes[LDecl].Parent].FirstChild;
  while LCh <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LCh].Kind <> nkDirective then
      LInit := LCh;
    LCh := LM.Tree.Nodes[LCh].NextSibling;
  end;
  if (LInit = NIL_NODE) or (LInit = LDecl) or
     (LM.Tree.Nodes[LInit].Kind <> nkSetCtor) then
    Exit;
  LCh := LM.Tree.Nodes[LInit].FirstChild;
  if (LCh <> NIL_NODE) and (LM.Tree.Nodes[LCh].Kind = nkRange) then
    LCh := LM.Tree.Nodes[LCh].FirstChild;
  if (LCh = NIL_NODE) or (LM.Tree.Nodes[LCh].Kind <> nkIdent) then
    Exit;
  // The buffer's own constant: its element typed as any operand of the
  // buffer is - another unit's enumeration value included.
  if LMid < 0 then
  begin
    Result := DesignatorType(LCh, 0);
    if Result.IsTypeRef or (RefCatOf(Result) <> tcEnum) and
       (Result.OvSym = NIL_SYM) then
      Result := ComplNilRef;
    Exit;
  end;
  LBound := NIL_SYM;
  if LCh < Length(LM.RefMap) then
    LBound := LM.RefMap[LCh];
  if LBound <> NIL_SYM then
  begin
    if (LM.Symbols[LBound].Kind <> skEnumValue) or
       (LM.Symbols[LBound].TypeSym = NIL_SYM) then
      Exit;
    if LMid >= 0 then
      Result.X := FProj.CanonTypeX(XPlain(LMid, LM.Symbols[LBound].TypeSym))
    else
      Result.OvSym := LM.Symbols[LBound].TypeSym;
  end
  else if LM.ExtRefMap.TryGetValue(LCh, LExt) and (LExt.UnitId >= 0) then
  begin
    LM := ProjModel(LExt.UnitId, 'SetConstElemRef');
    if (LM.Symbols[LExt.Sym].Kind = skEnumValue) and
       (LM.Symbols[LExt.Sym].TypeSym <> NIL_SYM) then
      Result.X := FProj.CanonTypeX(XPlain(LExt.UnitId,
        LM.Symbols[LExt.Sym].TypeSym));
  end;
end;

{ The type index AIndex (0-based) of brackets applied to a value of type
  ABase takes - ElementTypeOf's walk, one dimension per index: an array's
  index type for that dimension, Integer for a dynamic or open one (and the
  dimensions past it to its element's); Integer for a string and a pointer;
  a class or record with a default array property its parameter. }
function TPasCompletion.IndexTypeOf(const ABase: TPasComplTypeRef;
  AIndex: Integer): TPasComplTypeRef;
var
  LCur, LNext: TPasComplTypeRef;
  LM: TPasSemaModel;
  LHop, LDef, LKid, LIdxCount, LDims, LStep, LMid, LSym, LBound: Integer;
  LX, LOwner: TSemaXType;

  function IntegerRef: TPasComplTypeRef;
  var
    LIMid, LISym: Integer;
  begin
    Result := ComplNilRef;
    if BridgeName('integer', LIMid, LISym) then
      Result.X := XPlain(LIMid, LISym);
  end;

  // The type of the overlay's index type node ANode.
  function OverlayIndexRef(ANode: Integer): TPasComplTypeRef;
  var
    LBMid, LBSym: Integer;
  begin
    Result := ComplNilRef;
    case FModel.Tree.Nodes[ANode].Kind of
      nkIdent, nkMember, nkTypeArgs:
        begin
          Result := ResolveTypeRefNode(ANode, 1);
          Result.IsTypeRef := False;
        end;
      nkSubrange:
        begin
          LBound := FModel.Tree.Nodes[ANode].FirstChild;
          if LBound = NIL_NODE then
            Exit;
          if IsCharLiteralExpr(FModel.Tree, LBound) then
          begin
            if BridgeName('char', LBMid, LBSym) then
              Result.X := XPlain(LBMid, LBSym);
          end
          else if FModel.Tree.Nodes[LBound].Kind in [nkIdent, nkMember] then
          begin
            Result := DesignatorType(LBound, 1);
            if Result.IsTypeRef then
              Result := ComplNilRef;
          end
          else
            Result := IntegerRef;
        end;
    end;
  end;

begin
  Result := ComplNilRef;
  if AIndex < 0 then
    Exit;
  LCur := ABase;
  LCur.IsTypeRef := False;
  for LHop := 1 to 64 do
  begin
    // An array definition in hand: AIndex within its dimensions is one of
    // its index types, past them its element's.
    if LCur.ArrNode <> NIL_NODE then
    begin
      if not SymModelOf(LCur.ArrMid, 'IndexTypeOf', LM) then
        Exit;
      LIdxCount := 0;
      if LM.Tree.Nodes[LCur.ArrNode].Aux <> 1 then
        LIdxCount := PasArrayDims(LM.Tree, LCur.ArrNode);
      // `array of T` writes no index type: one dimension, Integer.
      if (LIdxCount = 1) and
         (LM.Tree.Nodes[LM.Tree.Nodes[LCur.ArrNode].FirstChild].NextSibling =
          NIL_NODE) then
        LIdxCount := 0;
      LDims := LIdxCount;
      if LDims = 0 then
        LDims := 1;
      Dec(LDims, LCur.ArrSkip);
      if AIndex >= LDims then
      begin
        Dec(AIndex, LDims);
        LCur := ArrayElemRef(LCur.ArrMid, LCur.ArrNode, LCur.ArrCtx, 1);
        Continue;
      end;
      if LIdxCount = 0 then
        Exit(IntegerRef);
      LKid := LM.Tree.Nodes[LCur.ArrNode].FirstChild;
      for LStep := 1 to LCur.ArrSkip + AIndex do
        if LKid <> NIL_NODE then
          LKid := LM.Tree.Nodes[LKid].NextSibling;
      if LKid = NIL_NODE then
        Exit;
      if LCur.ArrMid < 0 then
        Exit(OverlayIndexRef(LKid));
      Result.X := FProj.IndexTypeNodeX(LCur.ArrMid, LKid, LCur.ArrCtx);
      Exit;
    end;
    // An inline `^T` value: indexing it is pointer indexing.
    if LCur.ViaPointer then
    begin
      if AIndex = 0 then
        Exit(IntegerRef);
      LCur.ViaPointer := False;
      Dec(AIndex);
      Continue;
    end;
    if LCur.OvSym <> NIL_SYM then
    begin
      LDef := OverlayStructDef(LCur.OvSym);
      if LDef = NIL_NODE then
        Exit;
      case FModel.Tree.Nodes[LDef].Kind of
        nkArrayType:
          LCur := ComplArrRef(-1, LDef, 0, NIL_INST);
        nkPointerType:
          begin
            if AIndex = 0 then
              Exit(IntegerRef);
            LCur := ResolveTypeRefNode(FModel.Tree.Nodes[LDef].FirstChild, 1);
            LCur.IsTypeRef := False;
            Dec(AIndex);
          end;
        nkIdent, nkMember, nkTypeArgs:
          begin
            LNext := ResolveTypeRefNode(LDef, 1);
            if LNext.OvSym = LCur.OvSym then
              Exit;
            LCur := LNext;
          end;
        nkClassType, nkRecordType, nkObjectType, nkInterfaceType:
          begin
            // A default array property: asked of the last-good twin.
            LX := OwnModelTypeX(LCur.OvSym);
            if not XValid(LX) then
              Exit;
            LCur := ComplNilRef;
            LCur.X := LX;
          end;
      else
        Exit;
      end;
      Continue;
    end;
    if (FProj = nil) or not XValid(LCur.X) then
      Exit;
    LM := ProjModel(LCur.X.UnitId, 'IndexTypeOf');
    // A string, a character pointer: indexed by an Integer, one level.
    if XValid(FProj.StringElementX(LCur.X.UnitId, LCur.X)) or
       (LM.Symbols[LCur.X.Sym].Kind = skBuiltinType) then
    begin
      if AIndex = 0 then
        Exit(IntegerRef);
      Exit;
    end;
    LDef := ProjectTypeDef(LCur.X);
    if LDef = NIL_NODE then
      Exit;
    case LM.Tree.Nodes[LDef].Kind of
      nkArrayType:
        LCur := ComplArrRef(LCur.X.UnitId, LDef, 0, LCur.X.Inst);
      nkPointerType:
        begin
          if AIndex = 0 then
            Exit(IntegerRef);
          LX := FProj.PointeeX(LCur.X);
          LCur := ComplNilRef;
          LCur.X := LX;
          Dec(AIndex);
        end;
      nkIdent, nkMember, nkTypeArgs:
        begin
          LX := FProj.ResolveTypeExpr(LCur.X.UnitId, LDef);
          if (LCur.X.Inst <> NIL_INST) and XValid(LX) then
            LX := FProj.SubstX(LX, LCur.X.Inst, 0);
          if not XValid(LX) or ((LX.UnitId = LCur.X.UnitId) and
             (LX.Sym = LCur.X.Sym)) then
            Exit;
          LCur := ComplNilRef;
          LCur.X := LX;
        end;
      nkClassType, nkRecordType, nkObjectType, nkInterfaceType:
        begin
          // `L[I]` is L.Items[I]: the default property's parameter, in the
          // frame it was found in (a dictionary's TKey).
          if FProj.DefaultArrayPropX(LCur.X, LMid, LSym, LOwner) then
            Result.X := FProj.ArrayPropParamX(LMid, LSym, AIndex, LOwner.Inst);
          Exit;
        end;
    else
      Exit;
    end;
  end;
end;

{ The type of index AIndex of the array property the designator ANode
  names (`Obj.Items[|`): its parameter, closed over the frame of the value
  it is read from (`Dict.Items[|` - a dictionary's TKey). }
function TPasCompletion.ArrayPropIndexType(ANode,
  AIndex: Integer): TPasComplTypeRef;
var
  LMid, LSym, LInst, LType: Integer;
  LOwner: TPasComplTypeRef;
begin
  Result := ComplNilRef;
  if not DesignatorSymOf(ANode, 0, LMid, LSym) then
    Exit;
  if LMid >= 0 then
  begin
    LInst := NIL_INST;
    if FModel.Tree.Nodes[ANode].Kind = nkMember then
    begin
      LOwner := DesignatorType(FModel.Tree.Nodes[ANode].FirstChild, 0);
      if XValid(LOwner.X) then
        LInst := LOwner.X.Inst;
    end;
    Result.X := FProj.ArrayPropParamX(LMid, LSym, AIndex, LInst);
  end
  else if FIsProjectModel then
    Result.X := FProj.ArrayPropParamX(FProjMid, LSym, AIndex, NIL_INST)
  else
  begin
    LType := PasPropertyParamTypeNode(FModel.Tree,
      FModel.Symbols[LSym].DeclNode, AIndex);
    if LType = NIL_NODE then
      Exit;
    Result := ResolveTypeRefNode(LType, 1);
    Result.IsTypeRef := False;
  end;
end;

{ The element a `[...]` constructs for a slot of type ASet: a set's base
  (AIsSet), a dynamic array's element; ComplNilRef for anything else. }
function TPasCompletion.SetElementRef(const ASet: TPasComplTypeRef;
  out AIsSet: Boolean): TPasComplTypeRef;
var
  LX, LElem: TSemaXType;
  LOv, LFrom: Integer;
begin
  Result := ComplNilRef;
  AIsSet := False;
  if not ComplValid(ASet) or (FProj = nil) then
    Exit;
  LX := RefValueX(ASet, LOv);
  if not XValid(LX) then
    Exit;
  case FProj.XCatOf(LX) of
    tcSet:
      begin
        AIsSet := True;
        LFrom := FProjMid;
        if LFrom < 0 then
          LFrom := LX.UnitId;
        LElem := FProj.ForInElementOfX(LFrom, LX);
      end;
    tcArray:
      LElem := FProj.DynArrayElemX(LX);
  else
    Exit;
  end;
  if XValid(LElem) then
    Result.X := LElem;
end;

{ Parameter AIndex of an intrinsic's display signature (TPasBuiltinSig.
  Params, `(var X[; N])`): whether it is `var` / `out`, and its type's name
  - '' for an untyped one or a shape the text describes (`<ordinal>`).
  False where the text is no plain list: a leading optional parameter
  (`([var F: Text;] Args)`, Exit's `([ExitValue])`) shifts every index, an
  optional piece inside one (`X[: Width]`) or a `...` has no fixed place. }
function BuiltinParamAt(const AParams: string; AIndex: Integer;
  out AByRef: Boolean; out AType: string): Boolean;
var
  LText, LGroup, LNames, LType: string;
  LIdx, LAt, LColon: Integer;
begin
  Result := False;
  AByRef := False;
  AType := '';
  LText := Trim(AParams);
  if (Length(LText) < 2) or (LText[1] <> '(') or
     (LText[Length(LText)] <> ')') or (Pos('...', LText) > 0) then
    Exit;
  LText := Copy(LText, 2, Length(LText) - 2);
  // An optional tail (`[; N]`, `[, Count]`) loses its brackets; a bracket
  // opening anything else makes the text no list.
  LGroup := '';
  for LIdx := 1 to Length(LText) do
    case LText[LIdx] of
      '[':
        if (LIdx = Length(LText)) or not CharInSet(LText[LIdx + 1], [';', ',']) then
          Exit;
      ']':
        ;
    else
      LGroup := LGroup + LText[LIdx];
    end;
  LAt := 0;
  for LText in LGroup.Split([';']) do
  begin
    LNames := Trim(LText);
    LType := '';
    LColon := Pos(':', LNames);
    if LColon > 0 then
    begin
      LType := Trim(Copy(LNames, LColon + 1, MaxInt));
      LNames := Trim(Copy(LNames, 1, LColon - 1));
    end;
    var LByRef := False;
    if SameText(Copy(LNames, 1, 4), 'var ') or
       SameText(Copy(LNames, 1, 4), 'out ') then
    begin
      LByRef := True;
      LNames := Trim(Copy(LNames, 5, MaxInt));
    end
    else if SameText(Copy(LNames, 1, 6), 'const ') then
      LNames := Trim(Copy(LNames, 7, MaxInt));
    var LCount := Length(LNames.Split([',']));
    if AIndex < LAt + LCount then
    begin
      AByRef := LByRef;
      if (LType <> '') and (LType[1] <> '<') then
        AType := LType;
      Exit(True);
    end;
    Inc(LAt, LCount);
  end;
end;

{ A variable for an intrinsic's first `var` parameter that has a shape and
  no type (ArgExpectAt: FArgIncDec, FArgSetLen), by its type AX (or the
  overlay's AOv): `Inc(|` / `Dec(|` take an ordinal - an integer, a Char,
  a Boolean, an enumeration - or a typed pointer (dcc 37: an untyped Pointer
  is E2001); `SetLength(|` a string (any kind) or a dynamic array;
  `Assigned(|` (FArgAssigned) a reference - a class, an interface, a
  pointer, a dynamic array, a procedural value, a class reference (dcc 37:
  a string is E2008). Those fit; a value with members leads; any other is
  wrong. }
function TPasCompletion.ArgVarShapeFit(const AX: TSemaXType;
  AOv: Integer): TPasComplMatch;
var
  LCat: TSemaTypeCat;
  LX: TSemaXType;
  LMid, LSym: Integer;
begin
  LX := XNil;
  if XValid(AX) then
  begin
    LX := FProj.CanonTypeX(AX);
    LCat := FProj.XCatThroughX(LX);
  end
  else if AOv <> NIL_SYM then
    LCat := FModel.Symbols[AOv].TypeCat
  else
    LCat := tcUnknown;
  if LCat = tcUnknown then
    Exit(cmLeads);
  if FArgAssigned then
  begin
    if LCat in [tcClass, tcInterface, tcPointer, tcProc, tcClassOf] then
      Exit(cmCompatible);
    if (LCat = tcArray) and XValid(LX) and FProj.IsDynArrayTypeX(LX) then
      Exit(cmCompatible);
  end
  else if FArgIncDec then
  begin
    if LCat in [tcInteger, tcChar, tcBoolean, tcEnum] then
      Exit(cmCompatible);
    if LCat = tcPointer then
    begin
      if XValid(LX) and BridgeName('pointer', LMid, LSym) and
         FProj.XSameType(LX, FProj.CanonTypeX(XPlain(LMid, LSym))) then
        Exit(cmOther);
      Exit(cmCompatible);
    end;
  end
  else
  begin
    if LCat = tcString then
      Exit(cmCompatible);
    if (LCat = tcArray) and XValid(LX) and FProj.IsDynArrayTypeX(LX) then
      Exit(cmCompatible);
  end;
  // NOTHING_TO_REACH, declared further down.
  if LCat in [tcInteger, tcFloat, tcBoolean, tcChar, tcString, tcEnum, tcSet,
     tcNil, tcFile] then
    Result := cmOther
  else
    Result := cmLeads;
end;

{ The type a call's argument expects: ARaw is the `(` or `,` the operand at
  the caret follows. The walk goes back over the argument list - nested
  `()` / `[]` skipped, commas at its level counted - to the `(` that opens
  it; a `[` (a set or an index element), a grouping paren, a cast (a later
  context of its own) or a statement boundary on the way means no call.

  The overload is the one the arguments already written fit best, among
  those taking at least this many (ArgTypedOverload with the caret's
  argument left out); the parameter at the caret's index decides: its type,
  ranked as the right side of `:=` would be. A `var` / `out` parameter sets
  FArgByRef - a variable alone, of exactly its type, may stand there. An
  untyped, an open-array or a generic parameter (`FillChar(X, |`,
  `Max<T>(|`) expects no type, and sets FArgNoProcs: a procedure is still
  no argument. A type name before the `(` makes it a value typecast
  (CastExpect), not a call; a constructor (`TFoo.Create(|`) is a call. An
  intrinsic has no declaration: its display signature
  (PasBuiltinSignature) gives the shape - `var`, a named type for a value
  parameter (`Assert(|` a Boolean), else none; a `var` one's type there is
  a pseudo-type (`New(var P: Pointer)` takes any typed pointer) and is not
  used. ComplNilRef when nothing is expected. }
function TPasCompletion.ArgExpectAt(ARaw, AScope: Integer): TPasComplTypeRef;
var
  LTS: TPasTokenStream;
  LDepth, LArgs, LSteps, LVis, LNode, LDesig, LCallNode, LPrev: Integer;
  LMid, LSym, LCtx, LSel, LPar, LTypeNode, LBound: Integer;
  LM: TPasSemaModel;
  LParams: TArray<Integer>;
  LOpenArr, LOfConst: Boolean;
  LX: TSemaXType;
  LCommaRaw: Integer;
begin
  Result := ComplNilRef;
  LTS := FModel.Tree.Source.Files[0];
  LCommaRaw := ARaw;
  LDepth := 0;
  LArgs := 0;
  LSteps := 0;
  while True do
  begin
    if (ARaw < 0) or (LSteps >= 4096) then
      Exit;
    case LTS.Tokens[ARaw].Kind of
      tkRParen, tkRBracket:
        Inc(LDepth);
      tkLBracket:
        if LDepth = 0 then
          Exit
        else
          Dec(LDepth);
      tkLParen:
        if LDepth = 0 then
          Break
        else
          Dec(LDepth);
      tkComma:
        if LDepth = 0 then
          Inc(LArgs);
      tkSemicolon, tkBegin, tkEnd, tkThen, tkDo, tkElse, tkOf, tkIf,
      tkWhile, tkUntil, tkRepeat, tkAssign:
        if LDepth = 0 then
          Exit;
    end;
    ARaw := PrevVisibleRaw(ARaw - 1);
    Inc(LSteps);
  end;
  // The `(` opens a call: CallAt's two shapes - the nkCall owning it, or
  // `ident(` in a parse broken around the caret.
  LVis := FVisOfRaw[ARaw];
  if LVis < 0 then
    Exit;
  LNode := InnermostNodeAt(LVis);
  LDesig := NIL_NODE;
  LCallNode := NIL_NODE;
  if (LNode <> NIL_NODE) and (FModel.Tree.Nodes[LNode].Kind = nkCall) then
  begin
    LCallNode := LNode;
    LDesig := FModel.Tree.Nodes[LNode].FirstChild;
  end
  else if (LNode = NIL_NODE) or
          not (FModel.Tree.Nodes[LNode].Kind in [nkParen, nkParams]) then
  begin
    LPrev := PrevVisibleRaw(ARaw - 1);
    if (LPrev >= 0) and (LTS.Tokens[LPrev].Kind = tkIdentifier) then
      LDesig := DesignatorNodeAtVis(FVisOfRaw[LPrev]);
  end;
  if (LDesig = NIL_NODE) or
     not CalleeSyms(LDesig, LCallNode, LMid, LSym, LCtx) then
    Exit;
  // A type name before the `(` is a value typecast (`Int64(|`, `TFoo(|`):
  // its one operand is ranked by the cast's family (CastExpect).
  if IsTypeSym(LMid, LSym) then
  begin
    if LArgs = 0 then
      CastExpect(LMid, LSym);
    Exit;
  end;
  if not SymModelOf(LMid, 'ArgExpectAt', LM) or
     (LM.Symbols[LSym].Kind <> skRoutine) then
    Exit;
  if sfBuiltin in LM.Symbols[LSym].Flags then
  begin
    var LSig: TPasBuiltinSig;
    var LByRef: Boolean;
    var LType: string;
    // `Exit(|` returns the enclosing routine's result (ExitExpect).
    if LM.Symbols[LSym].NameLower = 'exit' then
    begin
      if LArgs = 0 then
        Result := ExitExpect(AScope);
      Exit;
    end;
    // `Include(S, |)`, `Exclude(S, |)`: an element of S's set type - the
    // table's `Element` is untyped.
    if ((LM.Symbols[LSym].NameLower = 'include') or
        (LM.Symbols[LSym].NameLower = 'exclude')) and (LArgs = 1) then
    begin
      var LIsSet: Boolean;
      var LBefore: Integer;
      FArgNoProcs := True;
      LNode := DesignatorEndingAt(PrevVisibleRaw(LCommaRaw - 1), LBefore);
      if (LNode <> NIL_NODE) and (LBefore = ARaw) then
      begin
        Result := DesignatorType(LNode, 0);
        if Result.IsTypeRef then
          Result := ComplNilRef
        else
          Result := SetElementRef(Result, LIsSet);
      end;
      Exit;
    end;
    if not PasBuiltinSignature(LM.Symbols[LSym].NameLower, LSig) or
       not BuiltinParamAt(LSig.Params, LArgs, LByRef, LType) then
      Exit;
    FArgNoProcs := True;
    FArgByRef := LByRef;
    if LByRef and (LArgs = 0) then
    begin
      FArgIncDec := (LM.Symbols[LSym].NameLower = 'inc') or
        (LM.Symbols[LSym].NameLower = 'dec');
      FArgSetLen := LM.Symbols[LSym].NameLower = 'setlength';
    end;
    FArgAssigned := (LArgs = 0) and
      (LM.Symbols[LSym].NameLower = 'assigned');
    if not LByRef and (LType <> '') and
       BridgeName(LowerCase(LType), LMid, LSym) then
      Result.X := XPlain(LMid, LSym);
    Exit;
  end;
  FArgTied := nil;
  LSel := ArgTypedOverload(LMid, LSym, LCtx, LCallNode, 0, LArgs);
  if LMid >= 0 then
    LParams := FProj.XParamSyms(LMid, LSel)
  else
    LParams := OverlayParams(LSel);
  if LArgs > High(LParams) then
    Exit;
  LPar := LParams[LArgs];
  FArgByRef := ParamIsByRef(LM, LPar);
  if ParamIsUntyped(LM, LPar) then
  begin
    FArgNoProcs := True;
    Exit;
  end;
  LTypeNode := LM.Symbols[LPar].TypeNode;
  if (LTypeNode <> NIL_NODE) and
     (LM.Tree.Nodes[LTypeNode].Kind = nkArrayType) then
  begin
    FArgNoProcs := True;
    // `Foo([|])`: the open array's element (`array of const` none).
    if LM.Tree.Nodes[LTypeNode].Aux <> 1 then
      FArgOpenElem := ArrayElemRef(LMid, LTypeNode, LCtx, 1);
    Exit;
  end;
  if LMid >= 0 then
  begin
    LX := FProj.ParamFitTypeX(LMid, LPar, LCtx, LOpenArr, LOfConst);
    if XValid(LX) and
       (ProjModel(LX.UnitId, 'ArgExpectAt').Symbols[LX.Sym].Kind <>
        skGenericParam) then
    begin
      Result.X := LX;
      ArgTiedAlts(LM, LMid, LCtx, LArgs, LX);
      Exit;
    end;
  end
  else
  begin
    // The buffer's own routine (CalleeSyms gives Mid -1 for a routine of
    // the unit being edited): its parameter's type node resolves to a TYPE
    // reference - a value of that type is what the argument is, as for a
    // variable of it (ValueOfTypeRef). Left a type reference, the slot
    // expected a type name, and nothing was ranked.
    Result := ResolveTypeRefNode(LTypeNode, 0);
    if ComplValid(Result) and ((Result.OvSym = NIL_SYM) or
       (FModel.Symbols[Result.OvSym].Kind <> skGenericParam)) then
      Exit(ValueOfTypeRef(Result, 0));
    Result := ComplNilRef;
  end;
  // A generic parameter's type (`Max<T>(|`) is none to rank by; anything
  // else the engine cannot type keeps the procedures, as an unknown left
  // side of `:=` does - it may be a procedural type.
  if (LTypeNode <> NIL_NODE) and
     (LM.Tree.Nodes[LTypeNode].Kind = nkIdent) then
  begin
    LBound := NIL_SYM;
    if LTypeNode < Length(LM.RefMap) then
      LBound := LM.RefMap[LTypeNode];
    if (LBound <> NIL_SYM) and (LM.Symbols[LBound].Kind = skGenericParam) then
      FArgNoProcs := True;
  end;
end;

{ The overloads ArgTypedOverload left tied (FArgTied) for argument AArg of a
  project routine family of AModel (AMid; ACtx its instantiation): when they
  take different types there - `SetValue('Name', |` over Char, Byte,
  Boolean, string, Double ... - each type into FExpectAlts, AFirst (the
  chosen overload's) first, and RankItems gives an item its best fit over
  them; the first one alone made every Byte and Boolean wrong. Only where
  each takes the argument alike - by value or each by reference, a typed
  parameter, no open array, no generic parameter's type; at most 16. }
procedure TPasCompletion.ArgTiedAlts(AModel: TPasSemaModel;
  AMid, ACtx, AArg: Integer; const AFirst: TSemaXType);
const
  MAX_ALTS = 16;
var
  LAlts: TArray<TSemaXType>;
  LParams: TArray<Integer>;
  LPar, LTypeNode: Integer;
  LX: TSemaXType;
  LOpenArr, LOfConst, LSeen: Boolean;
begin
  FExpectAlts := nil;
  if Length(FArgTied) < 2 then
    Exit;
  LAlts := [FProj.CanonTypeX(AFirst)];
  for var LCand in FArgTied do
  begin
    LParams := FProj.XParamSyms(AMid, LCand);
    if AArg > High(LParams) then
      Exit;
    LPar := LParams[AArg];
    if (ParamIsByRef(AModel, LPar) <> FArgByRef) or
       ParamIsUntyped(AModel, LPar) then
      Exit;
    LTypeNode := AModel.Symbols[LPar].TypeNode;
    if (LTypeNode = NIL_NODE) or
       (AModel.Tree.Nodes[LTypeNode].Kind = nkArrayType) then
      Exit;
    LX := FProj.ParamFitTypeX(AMid, LPar, ACtx, LOpenArr, LOfConst);
    if not XValid(LX) or LOpenArr or
       (ProjModel(LX.UnitId, 'ArgTiedAlts').Symbols[LX.Sym].Kind =
        skGenericParam) then
      Exit;
    LX := FProj.CanonTypeX(LX);
    if not XValid(LX) then
      Exit;
    LSeen := False;
    for var LHad in LAlts do
      if FProj.XSameType(LHad, LX) then
      begin
        LSeen := True;
        Break;
      end;
    if not LSeen then
    begin
      if Length(LAlts) >= MAX_ALTS then
        Exit;
      LAlts := LAlts + [LX];
    end;
  end;
  if Length(LAlts) > 1 then
    FExpectAlts := LAlts;
end;

{ The operand of a value typecast to the type (AMid, ASym) - `Int64(|`,
  `TKind(|`, `TFoo(|`, `PChar(|` - is ranked by the cast's family, not by
  the type itself, since a cast's whole point is a value of another type: a
  cast to an ordinal type (integer, enumeration, Char, Boolean) takes any
  ordinal (FExpectOrdinal, as a `case` selector); one to a class, an
  interface, a pointer, a class reference or a procedural type any such
  reference, `nil` included (FCastRef, MatchOf's RefCastFit). A cast to a
  float or a record (FCastValue, MatchOf's ValueCastFit) takes what dcc 37
  takes: a float any number, a Variant, and a value of exactly its size; a
  record a value of exactly its size (`TRec4(I)`, `TRec4(S)` for a Single),
  E2089 for any other - the size is the analysis's own SizeOf
  (TPasSemaProject.TypeSizeOf); a record the ranking cannot measure ranks
  nothing. Anything else ranks nothing. A procedure is never the operand. }
procedure TPasCompletion.CastExpect(AMid, ASym: Integer);
var
  LCat: TSemaTypeCat;
  LX: TSemaXType;
  LMid, LSym: Integer;
begin
  FArgNoProcs := True;
  LCat := tcUnknown;
  LX := XNil;
  if AMid >= 0 then
    LX := FProj.CanonTypeX(XPlain(AMid, ASym))
  else if FModel.Symbols[ASym].Kind = skBuiltinType then
  begin
    // A builtin type the overlay seeds (`Byte`) is judged as its System twin.
    if BridgeName(FModel.Symbols[ASym].NameLower, LMid, LSym) then
      LX := FProj.CanonTypeX(XPlain(LMid, LSym));
  end
  else
    LCat := FModel.Symbols[ASym].TypeCat;
  if XValid(LX) then
    LCat := FProj.XCatOf(LX);
  case LCat of
    // A set of exactly the ordinal's size casts to it (`Longword(S)` for a
    // set of 0..31, `Byte(S)` for one of an enumeration of up to 8 values;
    // dcc 37 - E2089 for another size).
    tcInteger, tcChar, tcBoolean, tcEnum:
      begin
        FExpectOrdinal := True;
        if XValid(LX) then
          FCastOrdSize := CastSizeOf(LX);
      end;
    tcClass, tcInterface, tcPointer, tcClassOf, tcProc:
      FCastRef := LCat;
    tcFloat, tcRecord:
      if XValid(LX) then
      begin
        FCastSize := CastSizeOf(LX);
        if (LCat = tcFloat) or (FCastSize > 0) then
        begin
          FCastValue := LCat;
          FCastX := LX;
        end;
      end;
  end;
end;

{ SizeOf of a value of type AX on the analyzed platform
  (TPasSemaProject.TypeSizeOf, the `$IF SizeOf` oracle's layout walk), -1
  where the walk refuses or the type is an instance of a generic. Cached for
  the ranking in FSizes: a cast asks it of every item. }
function TPasCompletion.CastSizeOf(const AX: TSemaXType): Int64;
var
  LX: TSemaXType;
begin
  Result := -1;
  if (FProj = nil) or not XValid(AX) then
    Exit;
  LX := FProj.CanonTypeX(AX);
  if not XValid(LX) or (LX.Inst <> NIL_INST) then
    Exit;
  if FSizes = nil then
    FSizes := TDictionary<TSemaXType, Int64>.Create;
  if FSizes.TryGetValue(LX, Result) then
    Exit;
  try
    if not FProj.TypeSizeOf(LX.UnitId, LX.Sym, Result) then
      Result := -1;
  except
    // A layout walk failing costs the rank, never the list.
    Result := -1;
  end;
  FSizes.Add(LX, Result);
end;

{ Whether the identifier AAt is the `at` of `raise X at |` (12.6.1): a word
  `at` after a `raise` of the same statement, at the same bracket depth. }
function TPasCompletion.RaiseAtStart(AAt: Integer): Boolean;
var
  LTS: TPasTokenStream;
  LRaw, LDepth, LSteps: Integer;
begin
  Result := False;
  LTS := FModel.Tree.Source.Files[0];
  if (AAt < 1) or (LTS.Tokens[AAt].Kind <> tkIdentifier) or
     not SameText(Copy(LTS.Source, LTS.Tokens[AAt].Start + 1,
       LTS.Tokens[AAt].Len), 'at') then
    Exit;
  LDepth := 0;
  LRaw := AAt;
  for LSteps := 1 to 512 do
  begin
    LRaw := PrevVisibleRaw(LRaw - 1);
    if LRaw < 0 then
      Exit;
    case LTS.Tokens[LRaw].Kind of
      tkRaise:
        Exit(LDepth = 0);
      tkRParen, tkRBracket:
        Inc(LDepth);
      tkLParen, tkLBracket:
        begin
          Dec(LDepth);
          if LDepth < 0 then
            Exit;
        end;
      tkSemicolon, tkBegin, tkEnd, tkThen, tkElse, tkDo, tkTry, tkExcept,
      tkFinally, tkAssign, tkColon, tkOf, tkRepeat, tkUntil:
        Exit;
    end;
  end;
end;

{ The directive word, lowercase, that raw token APrev (the token before the
  operand at the caret) is in its directive position - 'at' of `raise X at
  |` (RaiseAtStart), a property specifier's 'default' or 'index' (the
  specifier holding the caret starts with it), 'message' or 'dispid' in a
  type declaration - or '' when APrev is an operand (an identifier of that
  spelling anywhere else). }
function TPasCompletion.DirectiveWordBefore(const AInfo: TPasCaretInfo;
  APrev: Integer): string;
var
  LTS: TPasTokenStream;
begin
  Result := '';
  LTS := FModel.Tree.Source.Files[0];
  if (APrev < 1) or (LTS.Tokens[APrev].Kind <> tkIdentifier) then
    Exit;
  Result := LowerCase(Copy(LTS.Source, LTS.Tokens[APrev].Start + 1,
    LTS.Tokens[APrev].Len));
  if Result = 'at' then
  begin
    if not RaiseAtStart(APrev) then
      Result := '';
  end
  else if (Result = 'default') or (Result = 'index') then
  begin
    if PropSpecWordAt(AInfo.Node) <> Result then
      Result := '';
  end
  else if (Result = 'message') or (Result = 'dispid') then
  begin
    if UpChainKind(AInfo.Node, [nkTypeDecl, nkBlock]) <> nkTypeDecl then
      Result := '';
  end
  else
    Result := '';
end;

{ Whether the declaration ADecl (an nkConstDecl or nkVarDecl) declares a
  type of the procedural category, its `:` before visible token ACaretVis:
  `const P: TProc = Foo` takes a routine, whatever constant rules hold for
  any other typed constant. }
function TPasCompletion.DeclTypeIsProc(ADecl, ACaretVis: Integer): Boolean;
var
  LVis, LDepth, LColon, LKid, LOv: Integer;
  LX: TSemaXType;
begin
  Result := False;
  LColon := -1;
  LDepth := 0;
  LVis := FModel.Tree.Nodes[ADecl].FirstToken;
  if LVis < 0 then
    Exit;
  while (LVis <= ACaretVis) and (LVis <= High(FModel.Tree.Source.Visible)) do
  begin
    case FModel.Tree.Source.VisibleKind(LVis) of
      tkLParen, tkLBracket:
        Inc(LDepth);
      tkRParen, tkRBracket:
        Dec(LDepth);
      tkColon:
        if LDepth = 0 then
        begin
          LColon := LVis;
          Break;
        end;
      tkEqual:
        if LDepth = 0 then
          Break;
    end;
    Inc(LVis);
  end;
  if LColon < 0 then
    Exit;
  LKid := FModel.Tree.Nodes[ADecl].FirstChild;
  while (LKid <> NIL_NODE) and
        (FModel.Tree.Nodes[LKid].FirstToken <= LColon) do
    LKid := FModel.Tree.Nodes[LKid].NextSibling;
  if LKid = NIL_NODE then
    Exit;
  if FModel.Tree.Nodes[LKid].Kind = nkProcType then
    Exit(True);
  if FProj = nil then
    Exit;
  TypeNodeXOv(LKid, LX, LOv);
  if XValid(LX) then
    Result := FProj.XCatOf(LX) = tcProc
  else if LOv <> NIL_SYM then
    Result := FModel.Symbols[LOv].TypeCat = tcProc;
end;

{ Whether the operand at the caret stands in a constant expression by the
  declaration holding it, whatever operator precedes it: a constant's value
  (`const C = |`, `C = A + |`, a typed one's too), a parameter's default, a
  type declaration's expressions (an enumeration's values, a subrange, an
  array's bounds), an initialized global's value and its type's bounds -
  never an inline `const` / `var` (dcc 37 initializes those at run time),
  nor a procedural constant or global, whose value is a routine. }
function TPasCompletion.ConstExprSiteAt(const AInfo: TPasCaretInfo): Boolean;
var
  LNode, LRaw, LCaretVis, LVis, LDepth: Integer;
  LEq: Boolean;
  LSpec: string;
begin
  Result := False;
  if AInfo.Kind = ckIdent then
    LRaw := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    LRaw := AInfo.RawToken;
  if (LRaw < 0) or (LRaw > High(FVisOfRaw)) then
    Exit;
  LCaretVis := FVisOfRaw[LRaw];
  if LCaretVis < 0 then
    Exit;
  // A property accessor's word before the operand: a member stands there,
  // even where a half-typed line left the property out of the tree (`read
  // FOr|` with nothing after it was read as an expression, and a field
  // vanished from a large project's list).
  if FModel.Tree.Source.Files[0].Tokens[LRaw].Kind = tkIdentifier then
  begin
    LSpec := LowerCase(Copy(FModel.Tree.Source.Files[0].Source,
      FModel.Tree.Source.Files[0].Tokens[LRaw].Start + 1,
      FModel.Tree.Source.Files[0].Tokens[LRaw].Len));
    if (LSpec = 'read') or (LSpec = 'write') or (LSpec = 'stored') or
       (LSpec = 'add') or (LSpec = 'remove') or (LSpec = 'implements') then
      Exit;
  end;
  LNode := AInfo.Node;
  while LNode <> NIL_NODE do
  begin
    case FModel.Tree.Nodes[LNode].Kind of
      nkParam, nkTypeDecl:
        Exit(True);
      // A property's `default` and `index` take a constant; its accessors
      // name members (a `read FOri|` taken for an expression listed no
      // field once a type declaration made every expression constant).
      nkPropSpec:
        begin
          LSpec := PropSpecWordAt(LNode);
          Exit((LSpec = 'default') or (LSpec = 'index'));
        end;
      nkPropertyDecl:
        Exit;
      nkConstDecl:
        Exit(not DeclTypeIsProc(LNode, LCaretVis));
      nkVarDecl:
        begin
          // A global's initializer (`G: T = |`) or a bound of its type
          // (`[`), not an `absolute` target (a variable).
          LEq := False;
          LDepth := 0;
          LVis := FModel.Tree.Nodes[LNode].FirstToken;
          while (LVis >= 0) and (LVis <= LCaretVis) and
                (LVis <= High(FModel.Tree.Source.Visible)) do
          begin
            case FModel.Tree.Source.VisibleKind(LVis) of
              tkLBracket:
                Inc(LDepth);
              tkRBracket:
                Dec(LDepth);
              tkEqual:
                if LDepth = 0 then
                  LEq := True;
            end;
            Inc(LVis);
          end;
          Exit((LEq or (LDepth > 0)) and not DeclTypeIsProc(LNode, LCaretVis));
        end;
      nkInlineVar, nkInlineConst, nkBlock, nkRoutine, nkInterfaceSec,
      nkImplementationSec, nkUnit, nkProgram, nkLibrary, nkPackage:
        Exit;
    end;
    LNode := FModel.Tree.Nodes[LNode].Parent;
  end;
end;

{ What `Exit(|` returns: the result type of the innermost routine holding
  AScope - its implicit Result, a symbol of the routine's own scope with
  no declaration (DeclareImplicitResult), whose type node is the heading's
  result. A nested procedure inside a function has none of its own, and
  neither has an anonymous procedure: no context there. In a routine whose
  heading is a procedure's, a constructor's or a destructor's, `Exit(X)` is
  E2025 (dcc 37): FExitNoValue, and nothing is listed. }
function TPasCompletion.ExitExpect(AScope: Integer): TPasComplTypeRef;
var
  LRes, LHead: Integer;
begin
  Result := ComplNilRef;
  while (AScope <> NIL_SCOPE) and
        (FModel.Scopes[AScope].Kind <> sckRoutine) do
  begin
    if FModel.Scopes[AScope].Kind in [sckStruct, sckUnit,
       sckImplementation, sckSystem] then
      Exit;
    AScope := FModel.Scopes[AScope].Parent;
  end;
  if AScope = NIL_SCOPE then
    Exit;
  LHead := FModel.Scopes[AScope].OwnerNode;
  if LHead <> NIL_NODE then
    LHead := FModel.Tree.Nodes[LHead].FirstToken;
  if (LHead >= 0) and (LHead < High(FModel.Tree.Source.Visible)) and
     (FModel.Tree.Source.VisibleKind(LHead) = tkClass) then
    Inc(LHead);
  if (LHead >= 0) and (LHead <= High(FModel.Tree.Source.Visible)) and
     (FModel.Tree.Source.VisibleKind(LHead) in [tkProcedure, tkConstructor,
      tkDestructor]) then
  begin
    FExitNoValue := True;
    Exit;
  end;
  LRes := FModel.FindLocal(AScope, 'result');
  if (LRes = NIL_SYM) or (FModel.Symbols[LRes].Kind <> skVar) or
     (FModel.Symbols[LRes].DeclNode <> NIL_NODE) or
     (FModel.Symbols[LRes].TypeNode = NIL_NODE) then
    Exit;
  Result := TypeOfOverlaySym(LRes, 0);
  if Result.IsTypeRef then
    Result := ComplNilRef;
end;

{ The `case` whose label the operand after ARaw starts: the raw index of
  that case's `of`, or -1. ARaw is the token before the operand: `of`
  itself (the first label line), a `,` or `..` of a label list - walked
  back over the constant expressions before it to the `of` or the `;` the
  list follows - or a `;` ending an arm. From a `;` the walk goes back over
  the arm's statement, a nested `begin`/`case`/`try`/`asm` ... `end` and
  `repeat` ... `until` skipped whole, to the case's `of`; a `begin`, a
  `repeat`, a `try` it opens first means a statement list, not labels. An
  `else` right after a `;`, or one no `then` before it takes, is the case's
  own `else`: its statements are no labels either. }
function TPasCompletion.CaseLabelOf(ARaw: Integer): Integer;
const
  // What a label's constant expression is made of, outside parentheses.
  LABEL_TOKENS = [tkIdentifier, tkIntLiteral, tkRealLiteral, tkStringLiteral,
    tkMultilineString, tkControlChar, tkCaretChar, tkComma, tkDotDot, tkDot,
    tkPlus, tkMinus, tkStar, tkSlash, tkDiv, tkMod, tkShl, tkShr, tkAnd,
    tkOr, tkXor, tkNot, tkNil];
  // Where a walk back from an arm's `;` leaves statement code at its level.
  NOT_ARMS = [tkBegin, tkRepeat, tkTry, tkAsm, tkExcept, tkFinally,
    tkImplementation, tkInterface, tkInitialization, tkFinalization,
    tkType, tkVar, tkConst, tkLabel, tkRecord, tkClass, tkObject, tkUnit,
    tkProgram, tkLibrary, tkUses, tkThreadvar, tkResourcestring];
var
  LTS: TPasTokenStream;
  LDepth, LSteps, LElse: Integer;
begin
  Result := -1;
  LTS := FModel.Tree.Source.Files[0];
  LSteps := 0;
  if LTS.Tokens[ARaw].Kind in [tkComma, tkDotDot] then
  begin
    LDepth := 0;
    while True do
    begin
      ARaw := PrevVisibleRaw(ARaw - 1);
      Inc(LSteps);
      if (ARaw < 0) or (LSteps > 4096) then
        Exit;
      case LTS.Tokens[ARaw].Kind of
        tkRParen, tkRBracket:
          Inc(LDepth);
        tkLParen, tkLBracket:
          if LDepth = 0 then
            Exit
          else
            Dec(LDepth);
        tkOf, tkSemicolon:
          if LDepth = 0 then
            Break;
      else
        if (LDepth = 0) and not (LTS.Tokens[ARaw].Kind in LABEL_TOKENS) then
          Exit;
      end;
    end;
  end;
  if LTS.Tokens[ARaw].Kind = tkOf then
  begin
    if CaseOfStart(ARaw) >= 0 then
      Result := ARaw;
    Exit;
  end;
  if LTS.Tokens[ARaw].Kind <> tkSemicolon then
    Exit;
  LDepth := 0;
  LElse := 0;
  LSteps := 0;
  while True do
  begin
    ARaw := PrevVisibleRaw(ARaw - 1);
    Inc(LSteps);
    if (ARaw < 0) or (LSteps > 65536) then
      Exit;
    case LTS.Tokens[ARaw].Kind of
      tkEnd, tkUntil:
        Inc(LDepth);
      tkCase:
        if LDepth = 0 then
          Exit
        else
          Dec(LDepth);
      tkElse:
        if LDepth = 0 then
        begin
          var LBack := PrevVisibleRaw(ARaw - 1);
          if (LBack < 0) or (LTS.Tokens[LBack].Kind = tkSemicolon) then
            Exit;
          Inc(LElse);
        end;
      tkThen:
        if (LDepth = 0) and (LElse > 0) then
          Dec(LElse);
      tkOf:
        if LDepth = 0 then
        begin
          if (LElse = 0) and (CaseOfStart(ARaw) >= 0) then
            Result := ARaw;
          Exit;
        end;
    else
      if LTS.Tokens[ARaw].Kind in NOT_ARMS then
      begin
        if LDepth = 0 then
          Exit;
        // `begin`, `try`, `asm`, `repeat` close a nested block the walk
        // entered at its `end` / `until`; `record` / `class` / `object`
        // (an `end` of no statement) do too. The rest - `except` and
        // `finally` inside a `try`, an inline `var` / `const` inside a
        // `begin` - close nothing.
        if LTS.Tokens[ARaw].Kind in [tkBegin, tkRepeat, tkTry, tkAsm,
           tkRecord, tkClass, tkObject] then
          Dec(LDepth);
      end;
    end;
  end;
end;

{ The `case` token whose selector AOf (an `of`) ends: walked back over the
  selector, nested `()` / `[]` skipped, to a `case`; anything that ends an
  expression on the way (`array of`, `set of`, `class of`) means none: -1. }
function TPasCompletion.CaseOfStart(AOf: Integer): Integer;
var
  LTS: TPasTokenStream;
  LRaw, LDepth, LSteps: Integer;
begin
  Result := -1;
  LTS := FModel.Tree.Source.Files[0];
  LRaw := AOf;
  LDepth := 0;
  LSteps := 0;
  while True do
  begin
    LRaw := PrevVisibleRaw(LRaw - 1);
    Inc(LSteps);
    if (LRaw < 0) or (LSteps > 4096) then
      Exit;
    case LTS.Tokens[LRaw].Kind of
      tkRParen, tkRBracket:
        Inc(LDepth);
      tkLParen, tkLBracket:
        if LDepth = 0 then
          Exit
        else
          Dec(LDepth);
      tkCase:
        if LDepth = 0 then
          Exit(LRaw);
      tkIdentifier, tkIntLiteral, tkStringLiteral, tkControlChar,
      tkCaretChar, tkDot, tkCaret, tkPlus, tkMinus, tkStar, tkSlash, tkDiv,
      tkMod, tkShl, tkShr, tkAnd, tkOr, tkXor, tkNot, tkAt, tkComma, tkNil,
      tkInherited, tkEqual, tkNotEqual, tkLess, tkGreater, tkLessEqual,
      tkGreaterEqual, tkIn, tkIs, tkAs, tkDotDot:
        ;
    else
      if LDepth = 0 then
        Exit;
    end;
  end;
end;

{ The type of the selector of the `case` whose `of` is AOf: the designator
  between `case` and `of` (a name, a member chain, a call, an index), typed
  as the left side of `:=` is. A selector of any other shape (`case A + 1
  of`) or a type name gives ComplNilRef - the labels are still constants. }
function TPasCompletion.CaseSelectorType(AOf: Integer): TPasComplTypeRef;
const
  DESIGNATORS = [nkIdent, nkMember, nkCall, nkIndex, nkDeref, nkParen,
    nkTypeArgs];
var
  LCase, LEnd, LVis, LNode, LParent, LLeft: Integer;
begin
  Result := ComplNilRef;
  LCase := CaseOfStart(AOf);
  LEnd := PrevVisibleRaw(AOf - 1);
  if (LCase < 0) or (LEnd <= LCase) then
    Exit;
  LVis := FVisOfRaw[LEnd];
  if LVis < 0 then
    Exit;
  LNode := InnermostNodeAt(LVis);
  if (LNode = NIL_NODE) or
     not (FModel.Tree.Nodes[LNode].Kind in DESIGNATORS) then
    Exit;
  while True do
  begin
    LParent := FModel.Tree.Nodes[LNode].Parent;
    if (LParent = NIL_NODE) or
       (FModel.Tree.Nodes[LParent].LastToken <> LVis) or
       not (FModel.Tree.Nodes[LParent].Kind in DESIGNATORS) then
      Break;
    LNode := LParent;
  end;
  LLeft := FModel.Tree.NodeLeftmostVis(LNode);
  if (LLeft < 0) or (LLeft > High(FModel.Tree.Source.Visible)) or
     (FModel.Tree.Source.Visible[LLeft].FileId <> 0) or
     (PrevVisibleRaw(FModel.Tree.Source.Visible[LLeft].TokenIndex - 1) <>
      LCase) then
    Exit;
  Result := DesignatorType(LNode, 0);
  if Result.IsTypeRef then
    Result := ComplNilRef;
end;

{ The `:=` of the `for` loop whose `to` / `downto` is ATo: walked back over
  the first bound, nested `()` / `[]` skipped, to a `:=` at its level, and
  from there over the counter (`I`, `var I`, `var I: T`) to the `for`.
  -1 when the walk meets anything else - a statement boundary first. }
function TPasCompletion.ForAssignOf(ATo: Integer): Integer;
const
  // What may stand between `for` and `:=`.
  COUNTER = [tkIdentifier, tkVar, tkColon, tkDot, tkLess, tkGreater,
    tkComma];
  // Where a first bound cannot reach past.
  STOPS = [tkSemicolon, tkBegin, tkEnd, tkDo, tkThen, tkElse, tkOf, tkTo,
    tkDownto, tkFor, tkRepeat, tkUntil, tkTry, tkExcept, tkFinally, tkIn];
var
  LTS: TPasTokenStream;
  LRaw, LDepth, LSteps: Integer;
begin
  Result := -1;
  LTS := FModel.Tree.Source.Files[0];
  LRaw := ATo;
  LDepth := 0;
  LSteps := 0;
  while True do
  begin
    LRaw := PrevVisibleRaw(LRaw - 1);
    Inc(LSteps);
    if (LRaw < 0) or (LSteps > 4096) then
      Exit;
    case LTS.Tokens[LRaw].Kind of
      tkRParen, tkRBracket:
        Inc(LDepth);
      tkLParen, tkLBracket:
        if LDepth = 0 then
          Exit
        else
          Dec(LDepth);
      tkAssign:
        if LDepth = 0 then
          Break;
    else
      if (LDepth = 0) and (LTS.Tokens[LRaw].Kind in STOPS) then
        Exit;
    end;
  end;
  Result := LRaw;
  LSteps := 0;
  while True do
  begin
    LRaw := PrevVisibleRaw(LRaw - 1);
    Inc(LSteps);
    if (LRaw < 0) or (LSteps > 32) then
      Exit(-1);
    if LTS.Tokens[LRaw].Kind = tkFor then
      Exit;
    if not (LTS.Tokens[LRaw].Kind in COUNTER) then
      Exit(-1);
  end;
end;

{ Whether the `in` AIn is a for-in's (`for X in`, `for var X in`) rather
  than the set membership operator: AVarRaw the loop variable's token,
  AInline for an inline `var` (no declared type). }
function TPasCompletion.ForInStart(AIn: Integer; out AVarRaw: Integer;
  out AInline: Boolean): Boolean;
var
  LTS: TPasTokenStream;
  LRaw: Integer;
begin
  Result := False;
  AInline := False;
  LTS := FModel.Tree.Source.Files[0];
  AVarRaw := PrevVisibleRaw(AIn - 1);
  if (AVarRaw < 1) or (LTS.Tokens[AVarRaw].Kind <> tkIdentifier) then
    Exit;
  LRaw := PrevVisibleRaw(AVarRaw - 1);
  if (LRaw >= 1) and (LTS.Tokens[LRaw].Kind = tkVar) then
  begin
    AInline := True;
    LRaw := PrevVisibleRaw(LRaw - 1);
  end;
  Result := (LRaw >= 0) and (LTS.Tokens[LRaw].Kind = tkFor);
end;

{ The value type of the plain name at raw token ARaw (a for-in's loop
  variable): ComplNilRef for a type name or what the engine cannot type. }
function TPasCompletion.RawDesignatorType(ARaw: Integer): TPasComplTypeRef;
var
  LVis, LNode: Integer;
begin
  Result := ComplNilRef;
  LVis := FVisOfRaw[ARaw];
  if LVis < 0 then
    Exit;
  LNode := InnermostNodeAt(LVis);
  if (LNode = NIL_NODE) or (FModel.Tree.Nodes[LNode].Kind <> nkIdent) then
    Exit;
  Result := DesignatorType(LNode, 0);
  if Result.IsTypeRef then
    Result := ComplNilRef;
end;

{ A value's type as one canonical project-space type (CanonTypeX: aliases
  followed), for comparing two of them - XNil for what has no such name: a
  type reference, a unit, an inline array, a pointer the slot spells `^T`.
  A type only the overlay knows (declared since the last analysis) comes
  back in AOvSym instead. }
function TPasCompletion.RefValueX(const ARef: TPasComplTypeRef;
  out AOvSym: Integer): TSemaXType;
begin
  Result := XNil;
  AOvSym := NIL_SYM;
  if ARef.IsTypeRef or (ARef.UnitMid >= 0) or (ARef.ArrNode <> NIL_NODE) or
     ARef.ViaPointer or (FProj = nil) then
    Exit;
  if XValid(ARef.X) then
    Result := ARef.X
  else if ARef.OvSym <> NIL_SYM then
  begin
    Result := OwnModelTypeX(ARef.OvSym);
    if not XValid(Result) then
    begin
      AOvSym := ARef.OvSym;
      Exit;
    end;
  end;
  if XValid(Result) then
    Result := FProj.CanonTypeX(Result);
end;

{ One candidate against the expected type (FExpect / FExpectOv). A value -
  a variable, a field, a parameter, a constant, a property, an enumeration
  value, a function by its result - is typed as completion types a
  designator and asked TPasSemaProject.XConvX, the one conversion test:
  identical is cmExact, an implicit conversion cmCompatible. Beyond it what
  completion alone needs: what may still LEAD to a fitting value through
  `.` `[` `(` `^` is cmLeads, and only a value proven not to convert that
  has nothing to reach through (a number, a string, a Char, an
  enumeration, a set; a record, an array or a typed pointer whose members
  or elements are each such - ValueReaches) is cmOther. A comparison makes a Boolean of any
  value (`B := I > 0`), so nothing is cmOther where a Boolean is expected.
  A scalar's record helper (`I.ToString`) is the one way out this ignores. }
const
  NOTHING_TO_REACH = [tcInteger, tcFloat, tcBoolean, tcChar, tcString,
    tcEnum, tcSet, tcNil, tcFile];

{ A type answer as the one value type ValueReaches walks: an anonymous
  array as its element (each dimension consumed), an inline `^T` as T, a
  type reference as a value of the type. XNil where no type names it. }
function TPasCompletion.ElementValueX(ARef: TPasComplTypeRef): TSemaXType;
var
  LOv, LHop: Integer;
begin
  ARef.IsTypeRef := False;
  for LHop := 1 to 8 do
    if ARef.ArrNode <> NIL_NODE then
      ARef := ElementTypeOf(ARef, 1, 0)
    else
      Break;
  ARef.ViaPointer := False;
  Result := RefValueX(ARef, LOv);
end;

{ The value type of a member met by ValueReaches' walk: a field, a property
  (an array property's element), a constant, a function's result, a nested
  type as the value a cast or a constructor of it makes. An inline array
  slot (`D4: array[0..7] of Byte`) gives its element, an inline `^T` its
  T. False for what no walk should follow - a procedure, a destructor, an
  operator, a class constructor - and AX is XNil (with True) for a member
  whose type the engine cannot name, which the walk takes as leading
  somewhere. }
function TPasCompletion.MemberValueX(AMid, ASym, ACtx: Integer;
  out AX: TSemaXType): Boolean;
var
  LM: TPasSemaModel;
begin
  AX := XNil;
  LM := ProjModel(AMid, 'MemberValueX');
  case LM.Symbols[ASym].Kind of
    skRoutine:
      if (LM.RoutineHead(ASym) in [rhProcedure, rhDestructor, rhOperator]) or
         LM.IsClassCtorDtor(ASym) then
        Exit(False);
    skField, skVar, skConst, skProperty, skType:
      ;
  else
    Exit(False);
  end;
  Result := True;
  AX := ElementValueX(TypeOfProjectSym(AMid, ASym, ACtx, 0));
  if not XValid(AX) and (LM.Symbols[ASym].Kind = skConst) and
     (LM.Symbols[ASym].TypeNode = NIL_NODE) then
  begin
    AX := FProj.DeclTypeX(AMid, ASym);
    if XValid(AX) then
      AX := FProj.CanonTypeX(AX);
  end;
end;

{ Whether a value of type AX may lead to a value of the expected type
  through `.` `[` `^` - what makes a value of no fit cmLeads rather than
  cmOther. Proven not only for a scalar (NOTHING_TO_REACH) but for a RECORD
  whose members, its helper's included, are each proven not to (`TGUID`
  for an enumeration: integers, an array of Byte, a string, Boolean, TGUID
  again), and for an array or a typed pointer by its element. A class, an
  interface, a class reference, a procedural value, a Variant may lead
  anywhere and are not walked: their member graphs are the whole library,
  walked again for every expected type. Records are walked four levels
  deep, each record once per ranking (FReach). }
function TPasCompletion.ValueReaches(const AX: TSemaXType;
  ADepth: Integer): Boolean;
var
  LX, LEl: TSemaXType;
  LRef: TPasComplTypeRef;
  LState: Byte;
  LFound, LSaveCycle: Boolean;
begin
  if not XValid(AX) or (FProj = nil) then
    Exit(True);
  LX := FProj.CanonTypeX(AX);
  if not XValid(LX) then
    Exit(True);
  if FProj.XConvX(FExpect, LX) <> scNone then
    Exit(True);
  case FProj.XCatOf(LX) of
    // A string reaches a Char through `[`: `CharInSet(S[I], ...)`.
    tcString:
      Exit(FExpectCat = tcChar);
    tcInteger, tcFloat, tcBoolean, tcChar, tcEnum, tcSet, tcNil, tcFile:
      Exit(False);
    tcArray:
      begin
        if ADepth >= 4 then
          Exit(True);
        LRef := ComplNilRef;
        LRef.X := LX;
        LEl := ElementValueX(ElementTypeOf(LRef, 1, 0));
        Exit(not XValid(LEl) or ValueReaches(LEl, ADepth + 1));
      end;
    tcPointer:
      begin
        if ADepth >= 4 then
          Exit(True);
        LEl := FProj.PointeeX(LX);
        Exit(not XValid(LEl) or ValueReaches(LEl, ADepth + 1));
      end;
    tcRecord:
      ;
  else
    Exit(True);
  end;
  if ADepth >= 4 then
    Exit(True);
  if FReach = nil then
    FReach := TDictionary<TSemaXType, Byte>.Create;
  if FReach.TryGetValue(LX, LState) then
  begin
    // A record met again while it is being walked adds nothing the walk
    // in progress will not find; what this walk concludes is not final.
    if LState = 0 then
    begin
      FReachCycle := True;
      Exit(False);
    end;
    Exit(LState = 2);
  end;
  FReach.Add(LX, 0);
  LSaveCycle := FReachCycle;
  FReachCycle := False;
  LFound := False;
  FProj.EnumMembersX(FProjMid, LX,
    procedure(AMid, ASym, ACtx: Integer)
    var
      LMX: TSemaXType;
    begin
      if LFound or not MemberValueX(AMid, ASym, ACtx, LMX) then
        Exit;
      if not XValid(LMX) or ValueReaches(LMX, ADepth + 1) then
        LFound := True;
    end);
  Result := LFound;
  if Result or not FReachCycle then
    FReach[LX] := 1 + Ord(Result)
  else
    FReach.Remove(LX);
  FReachCycle := LSaveCycle or (FReachCycle and not Result);
end;

function TPasCompletion.MatchOf(const AItem: TPasComplItem): TPasComplMatch;
var
  LRef: TPasComplTypeRef;
  LX: TSemaXType;
  LOv, LBridged: Integer;
  LCat: TSemaTypeCat;
  LM: TPasSemaModel;
  LSelf: Boolean;
  LSelfItem: TPasComplItem;

  // An implicit conversion of a value of type AX: cmCompatible, except an
  // untyped Pointer where a class, an interface, a class reference, a
  // procedural value or a dynamic array is expected - dcc takes `O := P`,
  // but nobody writes it, and since the conversion rules admit it every
  // System Pointer (`__ImageBase`, `_ClassCreate`) ranked above the class
  // name of `L := TFoo.Create`. It may still be cast there: cmLeads.
  function ImplicitFit(const AX: TSemaXType): TPasComplMatch;
  begin
    // A `var` / `out` argument takes its own type alone: a value that
    // converts is wrong there - a scalar has nothing to reach one through.
    if FArgByRef then
    begin
      if FProj.XCatOf(FProj.CanonTypeX(AX)) in NOTHING_TO_REACH then
        Exit(cmOther);
      Exit(cmLeads);
    end;
    Result := cmCompatible;
    if (FExpectCat in [tcClass, tcInterface, tcClassOf, tcProc, tcArray]) and
       (FProj.XCatOf(FProj.CanonTypeX(AX)) = tcPointer) then
      Result := cmLeads
    else
    begin
      FConvOut := FProj.XConvDistX(FExpect, AX);
      FConvSameCat := FProj.XCatOf(FProj.CanonTypeX(AX)) =
        FProj.XCatOf(FProj.CanonTypeX(FExpect));
    end;
  end;

  // A value of type AX against the expected type: AIdentical when it is
  // that type, cmCompatible when it converts, cmOther when it provably does
  // not and has nothing to reach through, cmLeads otherwise.
  function FitOf(const AX: TSemaXType; AIdentical: TPasComplMatch):
    TPasComplMatch;
  begin
    case FProj.XConvX(FExpect, AX) of
      scIdentical:
        Result := AIdentical;
      scImplicit:
        Result := ImplicitFit(AX);
      scNone:
        if (FExpectCat <> tcBoolean) and not ValueReaches(AX, 0) then
          Result := cmOther
        else
          Result := cmLeads;
    else
      Result := cmLeads;
    end;
  end;

  // A `case` selector's fit (FExpectOrdinal): an ordinal is one, a scalar
  // of any other kind (a string, a float, a set) is wrong, a value with
  // members or elements may lead to one; an untyped value leads.
  function OrdinalFit(const AX: TSemaXType;
    AValue: Boolean = True): TPasComplMatch;
  var
    LOrd: TSemaTypeCat;
  begin
    if not XValid(AX) then
      Exit(cmLeads);
    LOrd := FProj.XCatOf(FProj.CanonTypeX(AX));
    if LOrd in [tcInteger, tcChar, tcBoolean, tcEnum] then
      Result := cmCompatible
    // A string variable leads through `[`: `case S[I] of` selects by a
    // Char (FCaseSel).
    else if (LOrd = tcString) and FCaseSel and AValue then
    begin
      Result := cmLeads;
      FLeadConvOut := 1;
    end
    else if LOrd in NOTHING_TO_REACH then
      Result := cmOther
    else
      Result := cmLeads;
  end;

  // A reference cast's operand (FCastRef) of category ACat: a class, an
  // interface, a pointer, a class reference or a procedural value fits; so
  // does a string or a dynamic array where a pointer is the cast
  // (`PChar(S)`, `Pointer(Arr)`); an integer leads (`TObject(Tag)`, a
  // pointer kept as a number); any other scalar is wrong, a record or an
  // array may hold one.
  function RefCastFit(ACat: TSemaTypeCat; ADynArray: Boolean): TPasComplMatch;
  begin
    if ACat in [tcClass, tcInterface, tcPointer, tcClassOf, tcProc, tcNil] then
      Result := cmCompatible
    else if (FCastRef = tcPointer) and
       ((ACat = tcString) or ((ACat = tcArray) and ADynArray)) then
      Result := cmCompatible
    else if ACat = tcInteger then
      Result := cmLeads
    else if ACat in NOTHING_TO_REACH then
      Result := cmOther
    else
      Result := cmLeads;
  end;

  // A for-in collection's fit (FExpectEnum): what a for-in walks fits - its
  // element of the loop variable's type first, one that converts to it
  // next, any element where the variable has no declared type; one whose
  // element does not convert, or no collection but a value with members
  // (an object holding a list), leads; a scalar is wrong.
  function EnumFit(const AX: TSemaXType): TPasComplMatch;
  var
    LC, LElem: TSemaXType;
    LFrom: Integer;
  begin
    if not XValid(AX) then
      Exit(cmLeads);
    LC := FProj.CanonTypeX(AX);
    LFrom := FProjMid;
    if LFrom < 0 then
      LFrom := LC.UnitId;
    LElem := FProj.ForInElementOfX(LFrom, LC);
    if XValid(LElem) then
    begin
      if not XValid(FEnumElem) then
        Exit(cmCompatible);
      case FProj.XConvX(FEnumElem, FProj.CanonTypeX(LElem)) of
        scIdentical:
          Result := cmExact;
        scImplicit:
          Result := cmCompatible;
      else
        Result := cmLeads;
      end;
      Exit;
    end;
    if FProj.XCatOf(LC) in NOTHING_TO_REACH then
      Result := cmOther
    else
      Result := cmLeads;
  end;

  // A `with` item's fit (FExpectWith) for a value or a type of category
  // ACat: one with members - a class, a record, an interface, a class
  // reference - fits; a scalar is wrong; a pointer or an array leads (`P^`,
  // `A[I]`), as does what cannot be typed.
  function WithFit(ACat: TSemaTypeCat): TPasComplMatch;
  begin
    if ACat in [tcClass, tcRecord, tcInterface, tcClassOf] then
      Result := cmCompatible
    else if ACat in NOTHING_TO_REACH then
      Result := cmOther
    else
      Result := cmLeads;
  end;

  // A raised object's fit (FExpectRaise) for a value, or a type name, of
  // category ACat and type AX: a class descending from FRaiseBase fits (an
  // exception variable; `EFoo.Create` through its class), any class where
  // no Exception is known or the ancestry cannot be followed; another
  // class leads (it may be raised, and it may hold an exception); a scalar
  // is wrong.
  function RaiseFit(ACat: TSemaTypeCat; const AX: TSemaXType): TPasComplMatch;
  var
    LDist: Integer;
  begin
    if ACat = tcClass then
    begin
      Result := cmCompatible;
      if XValid(FRaiseBase) and XValid(AX) then
        case FProj.XDescentDistX(FProj.CanonTypeX(AX), FRaiseBase, LDist) of
          xdNo:
            Result := cmLeads;
          // The nearer descendant of Exception first, Exception itself 0.
          xdYes:
            if LDist < CConvDistVariant then
              FConvOut := LDist
            else
              FConvOut := CConvDistVariant - 1;
        end;
    end
    else if ACat in NOTHING_TO_REACH then
      Result := cmOther
    else
      Result := cmLeads;
  end;

  // A float or record cast's operand (FCastValue) of category ACat and
  // type AX, as dcc 37 takes it: a number or a Variant for a float; a value
  // of exactly the target's size for either (`Single(R4)`, `TRec4(I)`,
  // `Single(P)` on Win32, `Double(S)` on Win64) - E2089 otherwise, so a
  // scalar of another size is wrong, and so is a true constant or an
  // enumeration value for a record (`TRec4(K)` is E2089 too: it has no
  // storage to reinterpret); a value with members of another size leads
  // (one of its members may fit), as does what cannot be measured.
  function ValueCastFit(ACat: TSemaTypeCat; const AX: TSemaXType;
    AConstant: Boolean): TPasComplMatch;
  var
    LSize: Int64;
  begin
    if (FCastValue = tcFloat) and (ACat in [tcInteger, tcFloat, tcVariant]) then
      Exit(cmCompatible);
    if (FCastValue = tcRecord) and AConstant then
      Exit(cmOther);
    LSize := -1;
    if XValid(AX) then
      LSize := CastSizeOf(AX);
    if (LSize > 0) and (LSize = FCastSize) then
      Result := cmCompatible
    else if (LSize > 0) and (ACat in NOTHING_TO_REACH) then
      Result := cmOther
    else
      Result := cmLeads;
  end;

  // An address's fit (FExpectAddr, `raise X at |`): a pointer fits; any
  // other scalar is wrong (E2017 - an integer too); a value with members
  // leads.
  function AddrFit(ACat: TSemaTypeCat): TPasComplMatch;
  begin
    if ACat = tcPointer then
      Result := cmCompatible
    else if ACat in NOTHING_TO_REACH then
      Result := cmOther
    else
      Result := cmLeads;
  end;

  // A record type's name after `with`: dcc 37 rejects the bare name
  // (`with TRec do` is E2029, a class member or none), so it only leads -
  // through a member the type itself names (`with TRec.Make do`): a class
  // var, a class or static method, a constructor, a class property. With
  // none it is wrong. AModel / ASym: the record's declaration.
  function RecordNameWithFit(AModel: TPasSemaModel;
    ASym: Integer): TPasComplMatch;
  var
    LScope, LMem, LI: Integer;
  begin
    Result := cmOther;
    if (AModel = nil) or (ASym = NIL_SYM) then
      Exit(cmLeads);
    LScope := AModel.Symbols[ASym].MemberScope;
    if LScope = NIL_SCOPE then
      Exit(cmLeads);
    for LI := 0 to AModel.Scopes[LScope].Symbols.Count - 1 do
    begin
      LMem := AModel.Scopes[LScope].Symbols[LI];
      if (AModel.Symbols[LMem].Kind in [skVar, skField, skRoutine,
         skProperty]) and ClassSideMember(AModel, LMem) then
        Exit(cmLeads);
    end;
  end;

  // An arithmetic operand's fit (FExpectNumber) for a value of category
  // ACat and type AX: the left operand's own type is fit 0, any other
  // integer or float fits, a Variant converts; any other scalar is wrong;
  // a value with members may hold a number (ValueReaches), one that cannot
  // be typed leads.
  function NumberFit(ACat: TSemaTypeCat; const AX: TSemaXType): TPasComplMatch;
  begin
    if ACat in [tcInteger, tcFloat] then
    begin
      Result := cmCompatible;
      if XValid(AX) and XValid(FExpect) and
         FProj.XSameType(FProj.CanonTypeX(AX), FProj.CanonTypeX(FExpect)) then
        Result := cmExact
      else if XValid(AX) and XValid(FExpect) then
      begin
        FConvOut := FProj.XConvDistX(FExpect, AX);
        FConvSameCat := FProj.XCatOf(FProj.CanonTypeX(AX)) =
          FProj.XCatOf(FProj.CanonTypeX(FExpect));
      end;
    end
    else if ACat = tcVariant then
    begin
      Result := cmCompatible;
      FConvOut := CConvDistVariant;
    end
    else if ACat in NOTHING_TO_REACH then
      Result := cmOther
    else if (ACat <> tcUnknown) and XValid(AX) and not ValueReaches(AX, 0) then
      Result := cmOther
    else
      Result := cmLeads;
  end;

begin
  // A type position ranks its types by rules of its own.
  if FTypePos <> tpNone then
    Exit(TypePosFit(AItem));
  if FHeritage <> nkError then
    Exit(HeritageFit(AItem));
  // A property accessor ranks by the accessor's signature.
  if FPropRank then
    Exit(AccessorFit(AItem));
  // `inherited |`: the enclosing method's own name is what a bare
  // `inherited` calls - the commonest use, `inherited Create(...)` in a
  // constructor included; any other method or property of an ancestor
  // fits. In a class method an instance method or property is wrong
  // (dcc 37: E2076, E2233) - a class method, a static one, a class
  // property and a constructor stay.
  if FInhRank then
  begin
    if FInhClass and (AItem.Sym <> NIL_SYM) and
       SymModelOf(AItem.Mid, 'MatchOf', LM, False) and
       (LM.Symbols[AItem.Sym].Kind in [skRoutine, skProperty]) and
       not ClassSideMember(LM, AItem.Sym) then
      Exit(cmOther);
    if (FInhName <> '') and SameText(AItem.Name, FInhName) then
      Exit(cmExact);
    // In a constructor any ancestor's constructor is what is called.
    if FInhCtor and (AItem.Sym <> NIL_SYM) and
       SymModelOf(AItem.Mid, 'MatchOf', LM, False) and
       (LM.RoutineHead(AItem.Sym) = rhConstructor) then
      Exit(cmExact);
    Exit(cmCompatible);
  end;
  Result := cmOther;
  // `nil` - a keyword or a seeded constant, whichever list it came from -
  // fits every reference.
  if SameText(AItem.Name, 'nil') then
  begin
    if FArgByRef then
      Exit;
    if (FCastRef <> tcUnknown) or FExpectAddr then
      Exit(cmCompatible);
    if FCastValue <> tcUnknown then
      Exit;
    if (FExpectCat in [tcClass, tcInterface, tcPointer, tcProc, tcClassOf])
       or ((FExpectCat = tcArray) and XValid(FExpect) and
           FProj.IsDynArrayTypeX(FExpect)) or FExpectGenNil then
      Result := cmCompatible;
    Exit;
  end;
  // The seeded True and False carry no type the overlay can read.
  if (AItem.Sym <> NIL_SYM) and (AItem.Kind = skConst) and
     (SameText(AItem.Name, 'True') or SameText(AItem.Name, 'False')) then
  begin
    if AItem.Mid < 0 then
      LM := FModel
    else
      LM := ProjModel(AItem.Mid, 'MatchOf');
    if sfBuiltin in LM.Symbols[AItem.Sym].Flags then
    begin
      if FExpectCat = tcBoolean then
        Result := cmExact
      else if FExpectOrdinal then
        Result := cmCompatible;
      Exit;
    end;
  end;
  if AItem.Bucket = cbKeyword then
    Exit;
  // A unit name (`Unit.Name`) produces no value itself but starts one.
  if (AItem.Bucket = cbUnitName) or
     (AItem.Kind in [skGenericParam, skUnitRef]) then
    Exit(cmLeads);
  // A type name is judged as a value of its type would be - the expected
  // type itself is a cast (`TKind(5)`), `string(X)` is no enumeration, a
  // class leads (`TFoo.Create`).
  if AItem.Kind in [skType, skBuiltinType] then
  begin
    Result := cmLeads;
    // An ordinal type's name is a cast to it (`Ord` aside, `Integer(X)`).
    if FExpectOrdinal and (AItem.Sym <> NIL_SYM) then
    begin
      if AItem.Mid >= 0 then
        Result := OrdinalFit(FProj.CanonTypeX(XPlain(AItem.Mid, AItem.Sym)),
          False)
      else if (AItem.Kind = skBuiltinType) and
         BridgeName(FModel.Symbols[AItem.Sym].NameLower, LOv, LBridged) then
        Result := OrdinalFit(FProj.CanonTypeX(XPlain(LOv, LBridged)), False)
      else if FModel.Symbols[AItem.Sym].TypeCat in [tcInteger, tcChar,
         tcBoolean, tcEnum] then
        Result := cmCompatible;
      // `array[|]`: the ordinal type is the commonest bound (FBoundType).
      if FBoundType and (Result = cmCompatible) then
        Result := cmExact;
      Exit;
    end;
    // A type is no collection (`for X in TColors` does not compile); a
    // class name still leads (`TFoo.Create.Items`), a scalar's is wrong.
    if FExpectEnum then
    begin
      if (AItem.Sym <> NIL_SYM) and (AItem.Mid >= 0) and
         (FProj.XCatOf(FProj.CanonTypeX(XPlain(AItem.Mid, AItem.Sym))) in
          NOTHING_TO_REACH) then
        Result := cmOther;
      Exit;
    end;
    // A `with` item or a raised object through a type name: a class's
    // (`with TFoo do` names its class members, `raise EFoo.Create`)
    // judged by its category, a scalar type's is wrong.
    if (FExpectWith or FExpectRaise or FExpectNumber) and
       (AItem.Sym <> NIL_SYM) then
    begin
      LX := XNil;
      if AItem.Mid >= 0 then
        LX := FProj.CanonTypeX(XPlain(AItem.Mid, AItem.Sym))
      else if (AItem.Kind = skBuiltinType) and
         BridgeName(FModel.Symbols[AItem.Sym].NameLower, LOv, LBridged) then
        LX := FProj.CanonTypeX(XPlain(LOv, LBridged));
      if XValid(LX) then
        LCat := FProj.XCatOf(LX)
      else
        LCat := FModel.Symbols[AItem.Sym].TypeCat;
      if LCat = tcUnknown then
        Exit;
      if FExpectRaise then
        Exit(RaiseFit(LCat, LX));
      // A number type's name is a cast to it (`I + Integer(P)`); another
      // scalar type's is wrong, a class's leads (`TFoo.Count`).
      if FExpectNumber then
      begin
        if LCat in [tcInteger, tcFloat] then
          Result := cmCompatible
        else if LCat in NOTHING_TO_REACH then
          Result := cmOther;
        Exit;
      end;
      // A class's name is a class reference (`with TFoo do` compiles,
      // class members or none); a record's leads only through a member the
      // type names (RecordNameWithFit); a scalar's is wrong.
      if LCat = tcClass then
        Result := cmCompatible
      else if LCat = tcRecord then
      begin
        if XValid(LX) then
          Result := RecordNameWithFit(ProjModel(LX.UnitId, 'MatchOf'), LX.Sym)
        else if AItem.Mid < 0 then
          Result := RecordNameWithFit(FModel, AItem.Sym);
      end
      else if LCat in NOTHING_TO_REACH then
        Result := cmOther;
      Exit;
    end;
    if (AItem.Sym = NIL_SYM) or not XValid(FExpect) then
      Exit;
    // A builtin type the overlay seeds (`string`, `Integer`) is judged as
    // its System twin; a type the overlay itself declares has none.
    if AItem.Mid < 0 then
    begin
      if (AItem.Kind <> skBuiltinType) or
         not BridgeName(FModel.Symbols[AItem.Sym].NameLower, LOv, LBridged) then
        Exit;
      LX := FProj.CanonTypeX(XPlain(LOv, LBridged));
    end
    else
      LX := FProj.CanonTypeX(XPlain(AItem.Mid, AItem.Sym));
    if XValid(LX) then
      Result := FitOf(LX, cmCompatible);
    Exit;
  end;
  // `Self` in a class method is a class reference: judged as the class's
  // name is, which names the same reference (`TFoo.Create`, `with TFoo`).
  LSelf := IsSelfItem(AItem);
  if LSelf and FSelfClass then
  begin
    LX := OwnModelTypeX(FSelfOv);
    if not XValid(LX) then
      Exit(cmLeads);
    LSelfItem := AItem;
    LSelfItem.Kind := skType;
    LSelfItem.Mid := LX.UnitId;
    LSelfItem.Sym := LX.Sym;
    LSelfItem.Ctx := NIL_INST;
    Exit(MatchOf(LSelfItem));
  end;
  if not LSelf and ((AItem.Sym = NIL_SYM) or
     not (AItem.Kind in [skVar, skParam, skField, skConst, skProperty,
       skEnumValue, skRoutine])) then
    Exit;
  // A routine where a procedural value is expected (`OnClick := |`, a
  // procedural parameter): its own signature decides - one that the type
  // takes (ProcValueFit: `of object` a method, a plain type a plain
  // routine, `reference to` both) is the value meant; a procedure that
  // does not fit is wrong; a function that does not may still return one.
  if (AItem.Kind = skRoutine) and (FExpectCat = tcProc) and
     XValid(FExpect) and not FArgByRef then
    case ProcValueFit(AItem) of
      1:
        Exit(cmExact);
      -1:
        begin
          if AItem.Mid < 0 then
            LM := FModel
          else
            LM := ProjModel(AItem.Mid, 'MatchOf');
          if sfBuiltin in LM.Symbols[AItem.Sym].Flags then
          begin
            var LSig: TPasBuiltinSig;
            if not PasBuiltinSignature(LM.Symbols[AItem.Sym].NameLower,
               LSig) or not LSig.IsFunction then
              Exit(cmOther);
          end
          else if LM.RoutineHead(AItem.Sym) <> rhFunction then
            Exit(cmOther);
        end;
    end;
  // From here a value; one the engine cannot type leads somewhere.
  Result := cmLeads;
  LOv := NIL_SYM;
  LX := XNil;
  if LSelf then
  begin
    // An instance method's Self: a value of the enclosing type (a
    // helper's extended type), judged as any variable of it.
    LX := SelfTypeX;
    if not XValid(LX) then
      LOv := FSelfOv;
  end
  else if AItem.Mid < 0 then
    LX := RefValueX(TypeOfOverlaySym(AItem.Sym, 0), LOv)
  else
  begin
    LM := ProjModel(AItem.Mid, 'MatchOf');
    // An enumeration value of another unit is typed by its enumeration,
    // an untyped constant (`CRed = clRed`) by its initializer - neither
    // has a declared type for TypeOfProjectSym to read.
    if AItem.Kind = skEnumValue then
    begin
      if LM.Symbols[AItem.Sym].TypeSym <> NIL_SYM then
        LX := FProj.CanonTypeX(XPlain(AItem.Mid, LM.Symbols[AItem.Sym].TypeSym));
    end
    else
    begin
      LRef := TypeOfProjectSym(AItem.Mid, AItem.Sym, AItem.Ctx, 0);
      LX := RefValueX(LRef, LOv);
      if not XValid(LX) and (AItem.Kind = skConst) and
         (LM.Symbols[AItem.Sym].TypeNode = NIL_NODE) then
      begin
        LX := FProj.DeclTypeX(AItem.Mid, AItem.Sym);
        if XValid(LX) then
          LX := FProj.CanonTypeX(LX);
      end;
    end;
  end;
  // An intrinsic has no declaration to type it: its result is the table's
  // fixed one (`Assigned` a Boolean, `SizeOf` an Integer), if any.
  if not XValid(LX) and (LOv = NIL_SYM) and (AItem.Kind = skRoutine) then
  begin
    if AItem.Mid < 0 then
      LM := FModel
    else
      LM := ProjModel(AItem.Mid, 'MatchOf');
    if sfBuiltin in LM.Symbols[AItem.Sym].Flags then
    begin
      var LText := LowerCase(PasIntrinsicResultText(
        PasIntrinsicResult(LM.Symbols[AItem.Sym].NameLower)));
      if (LText <> '') and BridgeName(LText, LOv, LBridged) then
        LX := FProj.CanonTypeX(XPlain(LOv, LBridged));
      LOv := NIL_SYM;
      // `High` / `Low` / `Pred` / `Succ` return their argument's ordinal
      // type - which the argument decides, so the table has none; where an
      // ordinal or a number is read they are what is written (`for I := 0
      // to High(A)`: an Integer), fit 1 rather than "leads" below every
      // typed integer. Not for a `var` / `out` argument, which no function
      // result is.
      if not XValid(LX) and not FArgByRef and
         ((LM.Symbols[AItem.Sym].NameLower = 'high') or
          (LM.Symbols[AItem.Sym].NameLower = 'low') or
          (LM.Symbols[AItem.Sym].NameLower = 'pred') or
          (LM.Symbols[AItem.Sym].NameLower = 'succ')) and
         (FExpectOrdinal or FExpectNumber or
          ((FCastValue = tcUnknown) and (FCastRef = tcUnknown) and
           not FExpectAddr and not FExpectWith and not FExpectRaise and
           not FExpectEnum and
           (FExpectCat in [tcInteger, tcChar, tcEnum, tcFloat]))) then
        Exit(cmCompatible);
    end;
  end;
  // A property is no variable a `var` / `out` argument takes (E2197); it
  // may still reach one through a member.
  if FArgByRef and (AItem.Kind = skProperty) then
  begin
    if XValid(LX) and
       (FProj.XCatOf(FProj.CanonTypeX(LX)) in NOTHING_TO_REACH) then
      Exit(cmOther);
    Exit(cmLeads);
  end;
  if FArgIncDec or FArgSetLen or FArgAssigned then
    Exit(ArgVarShapeFit(LX, LOv));
  if (FCastValue <> tcUnknown) or FExpectAddr then
  begin
    // A type the overlay alone declares has no project type: its category.
    if XValid(LX) then
      LCat := FProj.XCatOf(FProj.CanonTypeX(LX))
    else if LOv <> NIL_SYM then
      LCat := FModel.Symbols[LOv].TypeCat
    else
      LCat := tcUnknown;
    if LCat = tcUnknown then
      Exit(cmLeads);
    if FExpectAddr then
      Exit(AddrFit(LCat));
    if AItem.Mid < 0 then
      LM := FModel
    else
      LM := ProjModel(AItem.Mid, 'MatchOf');
    Exit(ValueCastFit(LCat, LX, (AItem.Kind = skEnumValue) or
      ((AItem.Kind = skConst) and (LM.Symbols[AItem.Sym].TypeNode = NIL_NODE))));
  end;
  if FExpectWith or FExpectRaise then
  begin
    // A type the overlay alone declares has no project type: its category.
    if XValid(LX) then
      LCat := FProj.XCatOf(FProj.CanonTypeX(LX))
    else if LOv <> NIL_SYM then
      LCat := FModel.Symbols[LOv].TypeCat
    else
      LCat := tcUnknown;
    if LCat = tcUnknown then
      Exit(cmLeads);
    if FExpectWith then
      Exit(WithFit(LCat));
    Exit(RaiseFit(LCat, LX));
  end;
  if FExpectNumber then
  begin
    // A type the overlay alone declares has no project type: its category.
    if XValid(LX) then
      LCat := FProj.XCatOf(FProj.CanonTypeX(LX))
    else if LOv <> NIL_SYM then
      LCat := FModel.Symbols[LOv].TypeCat
    else
      LCat := tcUnknown;
    Exit(NumberFit(LCat, LX));
  end;
  if FExpectEnum then
  begin
    // A type the overlay alone declares has no project type: its category.
    if not XValid(LX) and (LOv <> NIL_SYM) and
       (FModel.Symbols[LOv].TypeCat <> tcUnknown) then
    begin
      if FModel.Symbols[LOv].TypeCat in [tcString, tcSet, tcArray] then
        Exit(cmCompatible);
      if FModel.Symbols[LOv].TypeCat in NOTHING_TO_REACH then
        Exit(cmOther);
    end;
    Exit(EnumFit(LX));
  end;
  if FExpectOrdinal then
  begin
    // A type the overlay alone declares has no project type: its category.
    if not XValid(LX) and (LOv <> NIL_SYM) and
       (FModel.Symbols[LOv].TypeCat <> tcUnknown) then
    begin
      if FModel.Symbols[LOv].TypeCat in [tcInteger, tcChar, tcBoolean,
         tcEnum] then
        Exit(cmCompatible);
      if (FModel.Symbols[LOv].TypeCat = tcString) and FCaseSel then
      begin
        FLeadConvOut := 1;
        Exit(cmLeads);
      end;
      if FModel.Symbols[LOv].TypeCat in NOTHING_TO_REACH then
        Exit(cmOther);
    end;
    // A set of the ordinal cast's size (CastExpect's FCastOrdSize).
    if (FCastOrdSize > 0) and XValid(LX) and
       (FProj.XCatOf(FProj.CanonTypeX(LX)) = tcSet) and
       (CastSizeOf(LX) = FCastOrdSize) then
      Exit(cmCompatible);
    Exit(OrdinalFit(LX));
  end;
  if FCastRef <> tcUnknown then
  begin
    // A type the overlay alone declares has no project type: its category.
    if not XValid(LX) and (LOv <> NIL_SYM) and
       (FModel.Symbols[LOv].TypeCat <> tcUnknown) then
      Exit(RefCastFit(FModel.Symbols[LOv].TypeCat, False));
    if not XValid(LX) then
      Exit(cmLeads);
    LX := FProj.CanonTypeX(LX);
    Exit(RefCastFit(FProj.XCatOf(LX), FProj.IsDynArrayTypeX(LX)));
  end;
  // A type only the overlay knows (declared since the last analysis) has
  // no project type to convert to: its own values by identity, a scalar of
  // a project type is wrong for it.
  if FExpectOv <> NIL_SYM then
  begin
    if LOv = FExpectOv then
      Result := cmExact
    else if XValid(LX) and (FExpectCat <> tcBoolean) and
       (FProj.XCatOf(FProj.CanonTypeX(LX)) in NOTHING_TO_REACH) then
      Result := cmOther;
    Exit;
  end;
  if not XValid(LX) or not XValid(FExpect) then
    Exit;
  case FProj.XConvX(FExpect, LX) of
    // TObject / IInterface itself gains nothing over a descendant there.
    scIdentical:
      if FFlatRoot then
        Exit(cmCompatible)
      else
        Exit(cmExact);
    scImplicit:
      Exit(ImplicitFit(LX));
  end;
  LCat := FProj.XCatOf(FProj.CanonTypeX(LX));
  // A dynamic array whose element fits is the start of `A[I]` - the most
  // common way such a value is read (`LSym := FModel.RefMap[N]`). Not where
  // the left side is an array itself: there the array is the value.
  if (LCat = tcArray) and (FExpectCat <> tcArray) and
     FProj.IsDynArrayTypeX(LX) then
  begin
    LX := FProj.DynArrayElemX(LX);
    if XValid(LX) then
      Result := FitOf(FProj.CanonTypeX(LX), cmCompatible);
    Exit;
  end;
  // A pointer leads through `^` to what it points at - nowhere when that is
  // a scalar of no fit (`StrAlloc`'s PChar for an enumeration).
  if (LCat = tcPointer) and (FExpectCat <> tcPointer) then
  begin
    LX := FProj.PointeeX(LX);
    if XValid(LX) then
    begin
      Result := FitOf(FProj.CanonTypeX(LX), cmLeads);
      if Result = cmCompatible then
        Result := cmLeads;
    end;
    Exit;
  end;
  Result := FitOf(LX, cmExact);
end;

{ Does a routine item - any overload of its family - fit the procedural
  type FExpect (6.6.1: the same parameters, result and calling convention;
  `of object` a method, a plain type a plain routine or a static class
  method, `reference to` either - TPasSemaProject.ProcSigFitX)? 1 one
  does, -1 none does, 0 when nothing could be compared: no signature of
  FExpect, or an overlay routine the last analysis does not know yet. An
  intrinsic has no address to take: -1. }
function TPasCompletion.ProcValueFit(const AItem: TPasComplItem): Integer;
var
  LDst, LSrc: TPasProcSig;
  LM: TPasSemaModel;
  LSym, LProj, LRank, LHop: Integer;
begin
  Result := 0;
  if (FProj = nil) or (AItem.Sym = NIL_SYM) or
     not FProj.ProcTypeSigX(FExpect, LDst) then
    Exit;
  if AItem.Mid < 0 then
    LM := FModel
  else
    LM := ProjModel(AItem.Mid, 'ProcValueFit');
  if sfBuiltin in LM.Symbols[AItem.Sym].Flags then
    Exit(-1);
  LSym := AItem.Sym;
  for LHop := 1 to 64 do
  begin
    if (LSym = NIL_SYM) or (LM.Symbols[LSym].Kind <> skRoutine) then
      Break;
    if AItem.Mid >= 0 then
    begin
      if FProj.RoutineSigX(AItem.Mid, LSym, LSrc) then
      begin
        if FProj.ProcSigFitX(LDst, LSrc, LRank) > 0 then
          Exit(1);
        Result := -1;
      end;
    end
    else
    begin
      LProj := OwnModelRoutine(LSym);
      if (LProj <> NIL_SYM) and FProj.RoutineSigX(FProjMid, LProj, LSrc) then
      begin
        if FProj.ProcSigFitX(LDst, LSrc, LRank) > 0 then
          Exit(1);
        Result := -1;
      end;
    end;
    LSym := LM.Symbols[LSym].NextOverload;
  end;
end;

{ Every collected item against the expected type (see MatchOf) - against
  each of FExpectAlts when a call's tied overloads take different types
  there (ArgTiedAlts), an item keeping its best fit and, within it, its
  nearest Conv. }
procedure TPasCompletion.RankItems;
var
  LBest: TArray<TPasComplMatch>;
  LBestConv: TArray<Integer>;
  LSaveX: TSemaXType;
  LSaveCat: TSemaTypeCat;
  LIdx, LAlt: Integer;
begin
  if Length(FExpectAlts) < 2 then
  begin
    RankPass;
    Exit;
  end;
  LSaveX := FExpect;
  LSaveCat := FExpectCat;
  SetLength(LBest, FCount);
  SetLength(LBestConv, FCount);
  try
    for LAlt := 0 to High(FExpectAlts) do
    begin
      FExpect := FExpectAlts[LAlt];
      FExpectCat := FProj.XCatOf(FExpect);
      RankPass;
      for LIdx := 0 to FCount - 1 do
        if (LAlt = 0) or (Ord(FItems[LIdx].Match) < Ord(LBest[LIdx])) or
           ((FItems[LIdx].Match = LBest[LIdx]) and
            (FItems[LIdx].Conv < LBestConv[LIdx])) then
        begin
          LBest[LIdx] := FItems[LIdx].Match;
          LBestConv[LIdx] := FItems[LIdx].Conv;
        end;
    end;
    for LIdx := 0 to FCount - 1 do
    begin
      FItems[LIdx].Match := LBest[LIdx];
      FItems[LIdx].Conv := LBestConv[LIdx];
    end;
  finally
    FExpect := LSaveX;
    FExpectCat := LSaveCat;
  end;
end;

// One ranking of every item against FExpect (RankItems).
procedure TPasCompletion.RankPass;
var
  LIdx, LConv: Integer;
  LBoolLits: Boolean;
begin
  // ValueReaches' answers hold for one expected type.
  if FReach <> nil then
    FReach.Clear;
  FReachCycle := False;
  LBoolLits := (FExpectCat = tcBoolean) and not FCondLike and not FCompare;
  for LIdx := 0 to FCount - 1 do
  begin
    FConvOut := 0;
    FLeadConvOut := 0;
    FConvSameCat := False;
    FItems[LIdx].Match := MatchOf(FItems[LIdx]);
    LConv := 0;
    // A true constant (`C = 37.0` for a Double, `N = 5` for an Int64) takes
    // the type it meets in its own category: no conversion to grade there.
    // An integer one for a float is still an integer (`NOERROR` after
    // `Norm` for a TDateTime).
    if (FItems[LIdx].Match = cmCompatible) and
       not (FConvSameCat and IsTrueConstItem(FItems[LIdx])) then
      LConv := FConvOut
    else if FItems[LIdx].Match = cmLeads then
      LConv := FLeadConvOut;
    if FItems[LIdx].Match in [cmExact, cmCompatible] then
    begin
      // A Boolean's literals before every other Boolean, outside a
      // condition (`Exit(True)`, `B := False`, `= False` as a default).
      if LBoolLits and not (SameText(FItems[LIdx].Name, 'True') or
         SameText(FItems[LIdx].Name, 'False')) then
        Inc(LConv);
      // A comparison's constant before a variable or a function.
      // Not over the routine's own locals and parameters, which are as
      // often what is compared with (`Status <> AStatus`).
      if FCompare and not IsConstantItem(FItems[LIdx]) and
         (FItems[LIdx].Bucket <> cbLocal) then
        Inc(LConv);
    end;
    // A type declaration's right side (`T = |`, not `= type |`): a type
    // constructor (`class`, `record`, `array`, ...) is what is written
    // there most, and over a thousand type names share its fit - the
    // keywords before them.
    if (FTypePos = tpTypeDecl) and not FTypeAfterType and
       (FItems[LIdx].Bucket <> cbKeyword) then
      Inc(LConv);
    // After `is` / `as` a class-reference value (`ClassType`, a
    // `Default*Class` function) leads, below the types of its fit: the
    // types are what is written there.
    if (FTypePos = tpIsAs) and
       not (FItems[LIdx].Kind in [skType, skBuiltinType, skUnitRef,
         skGenericParam]) and (FItems[LIdx].Bucket <> cbUnitName) and
       (FItems[LIdx].Bucket <> cbKeyword) then
      Inc(LConv);
    if LConv >= CConvDistVariant then
      LConv := CConvDistVariant;
    FItems[LIdx].Conv := LConv;
  end;
end;

{ A true constant: a `const` with no declared type, whose value takes the
  type it is used as. }
function TPasCompletion.IsTrueConstItem(const AItem: TPasComplItem): Boolean;
var
  LM: TPasSemaModel;
begin
  Result := (AItem.Kind = skConst) and (AItem.Sym <> NIL_SYM) and
    SymModelOf(AItem.Mid, 'IsTrueConstItem', LM, False) and
    (LM.Symbols[AItem.Sym].TypeNode = NIL_NODE);
end;

{ A constant as a comparison's right side means one (FCompare): a true or
  typed constant, an enumeration value, `nil`, `True`, `False`. }
function TPasCompletion.IsConstantItem(const AItem: TPasComplItem): Boolean;
begin
  Result := (AItem.Kind in [skConst, skEnumValue]) or
    SameText(AItem.Name, 'nil') or SameText(AItem.Name, 'True') or
    SameText(AItem.Name, 'False');
end;

function TPasCompletion.CompleteAt(ALine, ACol: Integer;
  out AContext: TPasComplContext; out AItems: TArray<TPasComplItem>): Boolean;
var
  LCaret: TPasCaretInfo;
begin
  Result := CompleteAt(ALine, ACol, LCaret, AContext, AItems);
end;

// The model a (Mid, Sym) identity lives in: the overlay for -1, the project
// model otherwise. False only for a project id with no project attached.
// AHydrate rehydrates a text-demoted model, for a caller that reads its text
// (a parameter list, a result type, a doc comment); on failure that caller
// degrades through its bounds guards. A caller that reads symbols and nodes
// only passes False: a host asks the head word and has-params of EVERY row
// (pastree-lsp's completion does), and a rehydration per row re-preprocessed
// a changed library file once per row and accessor (audit C1-35).
function TPasCompletion.SymModelOf(AMid: Integer; const AWhere: string;
  out AModel: TPasSemaModel; AHydrate: Boolean): Boolean;
begin
  if AMid < 0 then
  begin
    AModel := FModel;
    Exit(True);
  end;
  Result := FProj <> nil;
  if Result then
  begin
    AModel := ProjModel(AMid, AWhere);
    if AHydrate and (AModel <> nil) and AModel.Demoted then
      FProj.EnsureHydrated(AMid);
  end
  else
    AModel := nil;
end;

function TPasCompletion.SymHeadWord(AModel: TPasSemaModel;
  ASym: Integer): string;
begin
  // Through the model's RoutineHead (this runs per display row): it answers
  // from the head token on a live model and from DemoteText's snapshot on a
  // text-demoted one - no raw token read either way.
  case AModel.RoutineHead(ASym) of
    rhProcedure:
      Result := 'procedure';
    rhFunction:
      Result := 'function';
    rhConstructor:
      Result := 'constructor';
    rhDestructor:
      Result := 'destructor';
    rhOperator:
      Result := 'operator';
  else
    Result := '';
  end;
end;

function TPasCompletion.ItemHeadWord(const AItem: TPasComplItem): string;
begin
  Result := '';
  if (AItem.Kind <> skRoutine) or (AItem.Sym = NIL_SYM) or
     (AItem.Bucket = cbKeyword) then
    Exit;
  Result := SymSignature(AItem.Mid, AItem.Sym, {ATexts} False).HeadWord;
end;

// The nkParams child of a routine symbol's declaration; NIL_NODE when the
// routine declares none (and for builtins, whose DeclNode is NIL_NODE).
function TPasCompletion.SymParamsNode(AModel: TPasSemaModel;
  ASym: Integer): Integer;
var
  LRoutine: Integer;
begin
  LRoutine := RoutineNodeOf(AModel, ASym);
  if LRoutine = NIL_NODE then
    Exit(NIL_NODE);
  Result := AModel.Tree.Nodes[LRoutine].FirstChild;
  while (Result <> NIL_NODE) and
        (AModel.Tree.Nodes[Result].Kind <> nkParams) do
    Result := AModel.Tree.Nodes[Result].NextSibling;
end;

// Whitespace runs collapsed to a single space - a multi-line parameter list
// must read as one display line. Interior comments survive as their own
// text; a declaration that comments its parameters is rare enough that
// stripping them is not worth a token-wise rebuild here.
function CollapseSpaces(const AText: string): string;
var
  LIdx, LOut: Integer;
  LCh: Char;
  LWasSpace: Boolean;
begin
  SetLength(Result, Length(AText));
  LOut := 0;
  LWasSpace := False;
  for LIdx := 1 to Length(AText) do
  begin
    LCh := AText[LIdx];
    if CharInSet(LCh, [#9, #10, #13, ' ']) then
      LWasSpace := True
    else
    begin
      if LWasSpace and (LOut > 0) then
      begin
        Inc(LOut);
        Result[LOut] := ' ';
      end;
      LWasSpace := False;
      Inc(LOut);
      Result[LOut] := LCh;
    end;
  end;
  SetLength(Result, LOut);
end;

{ The signature of a routine - or of a procedural VALUE, through its type -
  as display text: one place for the builtin table, the declared routine and
  the procedural type, so a completion row and a signature-help target say
  the same (audit B2-37: a builtin row had no head word while its call
  target was a 'function'; B2-35: a procedural value showed no parameters
  and its type's name as the result). The model is resolved once. ATexts
  False answers HeadWord and HasParams alone, from symbols and nodes, with
  no rehydration of a text-demoted model (SymModelOf, audit C1-35). }
function TPasCompletion.SymSignature(AMid, ASym: Integer;
  ATexts: Boolean): TPasSymSignature;
var
  LM, LDefM: TPasSemaModel;
  LSig: TPasBuiltinSig;
  LParams, LChild, LDef, LResult: Integer;
  LX: TSemaXType;
  LRef: TPasComplTypeRef;
begin
  Result := Default(TPasSymSignature);
  if (ASym = NIL_SYM) or not SymModelOf(AMid, 'SymSignature', LM, ATexts) then
    Exit;
  if sfBuiltin in LM.Symbols[ASym].Flags then
  begin
    if LM.Symbols[ASym].Kind <> skRoutine then
      Exit;
    if PasBuiltinSignature(LM.Symbols[ASym].NameLower, LSig) then
    begin
      Result.ParamsText := LSig.Params;
      Result.HasParams := LSig.HasArgs;
      Result.ResultText := LSig.ResultType;
    end;
    // The seeds have no head token; the table says which head fits - a
    // function whose result depends on its arguments (High, Copy, Abs) has
    // no result text but is a function all the same (audit D1-16).
    if LSig.IsFunction then
      Result.HeadWord := 'function'
    else
      Result.HeadWord := 'procedure';
    Exit;
  end;
  if LM.Symbols[ASym].Kind = skRoutine then
  begin
    Result.HeadWord := SymHeadWord(LM, ASym);
    LParams := SymParamsNode(LM, ASym);
    ParamsOf(LM, LParams, Result, ATexts);
    if not ATexts then
      Exit;
    if AMid >= 0 then
    begin
      LX := FProj.SymDeclTypeX(AMid, ASym);
      if XValid(LX) then
        Result.ResultText := FProj.XTypeText(LX);
    end
    else if LM.Symbols[ASym].TypeNode <> NIL_NODE then
    begin
      // The overlay's own routine: its result type bridged as the project
      // types it (HINST, not ''), else the written text.
      LRef := ResolveTypeRefNode(LM.Symbols[ASym].TypeNode, 0);
      if XValid(LRef.X) and (FProj <> nil) then
        Result.ResultText := FProj.XTypeText(LRef.X)
      else if LRef.OvSym <> NIL_SYM then
        Result.ResultText := LM.Symbols[LRef.OvSym].Name
      else
        Result.ResultText := CollapseSpaces(
          LM.Tree.NodeSpanText(LM.Symbols[ASym].TypeNode));
    end;
    Exit;
  end;
  if not (LM.Symbols[ASym].Kind in [skVar, skParam, skField, skProperty,
     skConst]) then
    Exit;
  // A procedural value: the nkProcType its declared type is (6.6.1),
  // written inline or named.
  LDefM := LM;
  LDef := LM.Symbols[ASym].TypeNode;
  if (LDef = NIL_NODE) or (LM.Tree.Nodes[LDef].Kind <> nkProcType) then
  begin
    LDef := NIL_NODE;
    if AMid >= 0 then
      LX := FProj.SymDeclTypeX(AMid, ASym)
    else
    begin
      LX := XNil;
      if LM.Symbols[ASym].TypeNode <> NIL_NODE then
      begin
        LRef := ResolveTypeRefNode(LM.Symbols[ASym].TypeNode, 0);
        if LRef.OvSym <> NIL_SYM then
          LDef := OverlayStructDef(LRef.OvSym)
        else
          LX := LRef.X;
      end;
    end;
    if XValid(LX) and (FProj <> nil) then
    begin
      LDefM := ProjModel(LX.UnitId, 'SymSignature');
      LDef := TPasSemaProject.TypeDefNodeIn(LDefM, LX.Sym);
    end;
    if (LDef = NIL_NODE) or (LDefM.Tree.Nodes[LDef].Kind <> nkProcType) then
      Exit;
  end;
  LParams := NIL_NODE;
  LResult := NIL_NODE;
  LChild := LDefM.Tree.Nodes[LDef].FirstChild;
  while LChild <> NIL_NODE do
  begin
    case LDefM.Tree.Nodes[LChild].Kind of
      nkParams:
        LParams := LChild;
      nkDirective, nkAttrGroup:
        ;
    else
      if LResult = NIL_NODE then
        LResult := LChild;
    end;
    LChild := LDefM.Tree.Nodes[LChild].NextSibling;
  end;
  ParamsOf(LDefM, LParams, Result, ATexts);
  if LResult <> NIL_NODE then
  begin
    Result.HeadWord := 'function';
    if ATexts then
      Result.ResultText := CollapseSpaces(LDefM.Tree.NodeSpanText(LResult));
  end
  else
    Result.HeadWord := 'procedure';
end;

// The display text of a parameter list node and whether it declares any
// parameter - an empty `()` renders as '' and takes none. ATexts False:
// whether, alone (nodes only).
procedure TPasCompletion.ParamsOf(AModel: TPasSemaModel; AParams: Integer;
  var ASig: TPasSymSignature; ATexts: Boolean);
var
  LChild: Integer;
begin
  ASig.ParamsText := '';
  ASig.HasParams := False;
  if AParams = NIL_NODE then
    Exit;
  LChild := AModel.Tree.Nodes[AParams].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if AModel.Tree.Nodes[LChild].Kind = nkParam then
    begin
      ASig.HasParams := True;
      if ATexts then
        ASig.ParamsText := CollapseSpaces(AModel.Tree.NodeSpanText(AParams));
      Exit;
    end;
    LChild := AModel.Tree.Nodes[LChild].NextSibling;
  end;
end;

function TPasCompletion.ItemParamsText(const AItem: TPasComplItem): string;
begin
  Result := '';
  if (AItem.Kind = skRoutine) and (AItem.Sym <> NIL_SYM) and
     (AItem.Bucket <> cbKeyword) then
    Result := SymSignature(AItem.Mid, AItem.Sym).ParamsText;
end;

function TPasCompletion.ItemHasParams(const AItem: TPasComplItem): Boolean;
begin
  Result := (AItem.Kind = skRoutine) and (AItem.Sym <> NIL_SYM) and
    (AItem.Bucket <> cbKeyword) and
    SymSignature(AItem.Mid, AItem.Sym, {ATexts} False).HasParams;
end;

function TPasCompletion.ItemDocComment(const AItem: TPasComplItem): string;
var
  LM: TPasSemaModel;
begin
  Result := '';
  if (AItem.Sym = NIL_SYM) or (AItem.Bucket in [cbKeyword, cbUnitName]) or
     not SymModelOf(AItem.Mid, 'ItemDocComment', LM) then
    Exit;
  Result := LM.Tree.DeclDocComment(LM.Symbols[AItem.Sym].DeclNode);
end;

{ ---- signature help (CallAt) ---------------------------------------------- }

function TPasCompletion.IsTypeSym(AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
begin
  Result := (ASym <> NIL_SYM) and SymModelOf(AMid, 'IsTypeSym', LM, False) and
    (LM.Symbols[ASym].Kind in [skType, skBuiltinType]);
end;

// The largest designator-shaped node ending exactly at AVis - the callee of
// a call whose nkCall node a broken parse did not produce. Climbs from the
// innermost node while the parent is still designator-shaped AND still ends
// at AVis (an nkCall parent ends past the '(', so the climb stops below it).
function TPasCompletion.DesignatorNodeAtVis(AVis: Integer): Integer;
var
  LParent: Integer;
begin
  Result := NIL_NODE;
  if AVis < 0 then
    Exit;
  Result := InnermostNodeAt(AVis);
  while Result <> NIL_NODE do
  begin
    LParent := FModel.Tree.Nodes[Result].Parent;
    if (LParent = NIL_NODE) or
       not (FModel.Tree.Nodes[LParent].Kind in
         [nkIdent, nkMember, nkParen, nkTypeArgs, nkIndex, nkDeref]) or
       (FModel.Tree.Nodes[LParent].LastToken > AVis) then
      Break;
    Result := LParent;
  end;
end;

{ The (Mid, Sym, Ctx) the call designator binds to - the analysis's own
  arbitration first (CallTargetX/CallTarget on the nkCall node, filled on
  analyzed models and for the overlay's intra-buffer calls), then the
  structural walk the member-completion path uses: RefMap/ExtRefMap on a
  plain name, BridgeName for one that leaves the buffer, DesignatorType +
  MemberSymOf for a dotted one - which is exactly the bridged-designator
  resolution the LSP's interim locator cannot do (`Obj.Method(|`, freshly
  typed cross-unit calls). ACallNode is the nkCall when the AST produced
  one; NIL_NODE from the broken-parse fallback. }
function TPasCompletion.CalleeSyms(ANode, ACallNode: Integer;
  out AMid, ASym, ACtx: Integer): Boolean;
var
  LExt: TPasExtRef;
  LSym: Integer;
  LBase: TPasComplTypeRef;
  LName, LPeel: Integer;
begin
  Result := False;
  AMid := -1;
  ASym := NIL_SYM;
  ACtx := NIL_INST;
  if ACallNode <> NIL_NODE then
  begin
    if (FProj <> nil) and
       FModel.CallTargetX.TryGetValue(ACallNode, LExt) then
    begin
      AMid := LExt.UnitId;
      ASym := LExt.Sym;
      Exit(True);
    end;
    // Phase 1's choice - unless, on an overlay, it is a unit-level routine
    // a bare name in a method reaches only when no member of the class nest
    // carries that name (BareNameSym: a TStream descendant's `Write(` is the
    // inherited method, not the intrinsic), or the name `inherited` calls,
    // which Phase 1 cannot follow into another unit's ancestor.
    if FModel.CallTarget.TryGetValue(ACallNode, LSym) and
       (LSym <> NIL_SYM) then
    begin
      if (FModel.Tree.Nodes[ANode].Kind = nkIdent) and not FIsProjectModel then
        if IsInheritedHead(ANode) then
        begin
          if BareNameSym(ANode, 0, AMid, ASym, ACtx) then
            Exit(True);
        end
        else if IsUnitLevelSym(LSym) and
                StructNestMember(ANode, FModel.Tree.NodeNameLower(ANode), 0,
                  AMid, ASym, ACtx) then
          Exit(True);
      AMid := -1;
      ASym := LSym;
      ACtx := NIL_INST;
      Exit(True);
    end;
  end;
  // Peel grouping parens and a generic-arguments wrapper down to the name.
  LPeel := 0;
  while (ANode <> NIL_NODE) and (LPeel < 8) and
        (FModel.Tree.Nodes[ANode].Kind in [nkParen, nkTypeArgs]) do
  begin
    ANode := FModel.Tree.Nodes[ANode].FirstChild;
    Inc(LPeel);
  end;
  if ANode = NIL_NODE then
    Exit;
  case FModel.Tree.Nodes[ANode].Kind of
    nkIdent:
      Result := BareNameSym(ANode, 0, AMid, ASym, ACtx);
    nkMember:
      begin
        LName := FModel.Tree.Nodes[ANode].FirstChild;
        LBase := DesignatorType(LName, 0);
        if LName <> NIL_NODE then
          LName := FModel.Tree.Nodes[LName].NextSibling;
        if (LName <> NIL_NODE) and ComplValid(LBase) then
          Result := MemberSymOf(LBase, FModel.Tree.NodeNameLower(LName), 0,
            AMid, ASym, ACtx);
      end;
  end;
end;

procedure TPasCompletion.AppendCallTarget(AMid, ASym, ACtx: Integer;
  var AInfo: TPasCallInfo; ASkipSameSig: Boolean);
var
  LM: TPasSemaModel;
  LSig: TPasSymSignature;
  LT: TPasCallTarget;
begin
  if not SymModelOf(AMid, 'AppendCallTarget', LM, False) then
    Exit;   // SymSignature below rehydrates for the texts
  // Each identity once: the family walks below may meet a member twice.
  for var LIdx := 0 to High(AInfo.Targets) do
    if (AInfo.Targets[LIdx].Mid = AMid) and (AInfo.Targets[LIdx].Sym = ASym) then
      Exit;
  LSig := SymSignature(AMid, ASym);
  // An ancestor's member with a signature already listed is the one an
  // override redeclares - one signature, shown once.
  if ASkipSameSig then
    for var LIdx := 0 to High(AInfo.Targets) do
      if SameText(AInfo.Targets[LIdx].ParamsText, LSig.ParamsText) and
         SameText(AInfo.Targets[LIdx].ResultText, LSig.ResultText) then
        Exit;
  LT := Default(TPasCallTarget);
  LT.Mid := AMid;
  LT.Sym := ASym;
  LT.Ctx := ACtx;
  LT.Name := LM.Symbols[ASym].Name;
  LT.HeadWord := LSig.HeadWord;
  LT.ParamsText := LSig.ParamsText;
  LT.HasParams := LSig.HasParams;
  LT.ResultText := LSig.ResultText;
  AInfo.Targets := AInfo.Targets + [LT];
end;

{ Expands one bound callee into targets: a routine reports its WHOLE overload
  family - the chain from its scope's HEAD, because the bound symbol may sit
  mid-chain (resolution binds the arity match) and each collapsed overload is
  its own signature here, unlike completion rows. A procedural VALUE (proc-
  type variable/parameter/field) reports itself alone. }
procedure TPasCompletion.AddCallTargets(AMid, ASym, ACtx: Integer;
  var AInfo: TPasCallInfo);
var
  LM, LAM: TPasSemaModel;
  LHead, LScope, LOther, LStruct, LHop: Integer;
  LKey: string;
  LX: TSemaXType;
  LRef: TPasComplTypeRef;
  LOverload: Boolean;

  // One overload chain from its head - every member, however long (audit
  // A1-31: a cap of 16 dropped TStringBuilder.Append's multi-parameter
  // forms; the chain cannot loop, the count only guards a corrupt graph).
  procedure AddChain(AChainMid, AHead: Integer;
    AAncestor: Boolean = False);
  var
    LCM: TPasSemaModel;
    LNext, LCount: Integer;
  begin
    if (AHead = NIL_SYM) or not SymModelOf(AChainMid, 'AddChain', LCM) then
      Exit;
    LNext := AHead;
    LCount := 0;
    while (LNext <> NIL_SYM) and (LCount <= LCM.SymCount) do
    begin
      if LCM.Symbols[LNext].Kind = skRoutine then
        AppendCallTarget(AChainMid, LNext, ACtx, AInfo, AAncestor);
      LNext := LCM.Symbols[LNext].NextOverload;
      Inc(LCount);
    end;
  end;

  // Does the set headed by AHead let the family go on into the ancestors?
  // A member saying `overload` does, and so does an `override` -
  // overriding is not hiding (the project's candidate rule, audit B33).
  function GoesOn(AModel: TPasSemaModel; AHead: Integer): Boolean;
  var
    LNext, LCount: Integer;
  begin
    Result := False;
    LNext := AHead;
    LCount := 0;
    while (LNext <> NIL_SYM) and (LCount <= AModel.SymCount) do
    begin
      if AModel.RoutineSaysOverload(LNext) or
         (sfOverrideDirective in AModel.Symbols[LNext].Flags) then
        Exit(True);
      LNext := AModel.Symbols[LNext].NextOverload;
      Inc(LCount);
    end;
  end;

begin
  if (ASym = NIL_SYM) or not SymModelOf(AMid, 'AddCallTargets', LM) then
    Exit;
  if LM.Symbols[ASym].Kind <> skRoutine then
  begin
    if LM.Symbols[ASym].Kind in [skVar, skParam, skField, skProperty,
       skConst] then
      AppendCallTarget(AMid, ASym, ACtx, AInfo);
    Exit;   // units, labels, enum values offer nothing to call
  end;
  LKey := LM.Symbols[ASym].NameLower;
  LHead := ASym;
  LScope := LM.Symbols[ASym].Scope;
  if LScope <> NIL_SCOPE then
  begin
    LHead := LM.FindLocal(LScope, LKey);
    if LHead = NIL_SYM then
      LHead := ASym;
  end;
  AddChain(AMid, LHead);
  if LScope <> NIL_SCOPE then
  begin
    // A unit routine's interface overloads and its implementation-only ones
    // are two chains in two scopes, and a call scores both (6.3.1; audit
    // B2-33).
    LOther := NIL_SCOPE;
    if LScope = LM.InterfaceScope then
      LOther := LM.ImplementationScope
    else if LScope = LM.ImplementationScope then
      LOther := LM.InterfaceScope;
    if LOther <> NIL_SCOPE then
      AddChain(AMid, LM.FindLocal(LOther, LKey));
    // A method's family goes on into the ancestors while each set says
    // `overload` (6.3.1, 12.1.1): the overloads a base class declares are
    // callable through the descendant.
    LStruct := NIL_SYM;
    if LM.Scopes[LScope].Kind = sckStruct then
      LStruct := LM.Scopes[LScope].StructSym;
    LOverload := GoesOn(LM, LHead);
    LX := XNil;
    if (LStruct <> NIL_SYM) and LOverload then
    begin
      if AMid >= 0 then
        LX := XPlain(AMid, LStruct)
      else
      begin
        // The overlay's own ancestors first, then the bridged ones.
        LRef := ComplNilRef;
        LRef.OvSym := LStruct;
        for LHop := 1 to 64 do
        begin
          LRef := OverlayHeritageRef(LRef.OvSym, 0);
          if LRef.OvSym = NIL_SYM then
            Break;
          if FModel.Symbols[LRef.OvSym].MemberScope = NIL_SCOPE then
            Break;
          LHead := FModel.FindLocal(FModel.Symbols[LRef.OvSym].MemberScope,
            LKey);
          if LHead <> NIL_SYM then
          begin
            AddChain(-1, LHead, True);
            if not GoesOn(FModel, LHead) then
            begin
              LOverload := False;
              Break;
            end;
          end;
        end;
        if LOverload and XValid(LRef.X) then
          LX := LRef.X
        else
          LX := XNil;
        // Walk the bridged part from LX itself (the overlay chain ended
        // AT it), not from its ancestor.
        if XValid(LX) and (FProj <> nil) then
        begin
          if not SymModelOf(LX.UnitId, 'AddCallTargets', LAM) then
            LX := XNil
          else if LAM.Symbols[LX.Sym].MemberScope <> NIL_SCOPE then
          begin
            LHead := LAM.FindLocal(LAM.Symbols[LX.Sym].MemberScope, LKey);
            if LHead <> NIL_SYM then
            begin
              AddChain(LX.UnitId, LHead, True);
              if not GoesOn(LAM, LHead) then
                LX := XNil;
            end;
          end;
        end;
      end;
      for LHop := 1 to 64 do
      begin
        if not XValid(LX) or (FProj = nil) then
          Break;
        LX := FProj.AncestorOfX(LX);
        if not XValid(LX) then
          Break;
        if not SymModelOf(LX.UnitId, 'AddCallTargets', LAM) then
          Break;
        if LAM.Symbols[LX.Sym].MemberScope = NIL_SCOPE then
          Continue;
        LHead := LAM.FindLocal(LAM.Symbols[LX.Sym].MemberScope, LKey);
        if LHead = NIL_SYM then
          Continue;
        AddChain(LX.UnitId, LHead, True);
        if not GoesOn(LAM, LHead) then
          Break;
      end;
    end;
  end;
  // The bound overload is one of Targets, whatever the walks met (the
  // TPasCallInfo contract; audit A1-31).
  AppendCallTarget(AMid, ASym, ACtx, AInfo);
end;

function TPasCompletion.CallAt(ALine, ACol: Integer;
  out AInfo: TPasCallInfo): Boolean;
var
  LTS: TPasTokenStream;
  LOffset, LRaw, LPrev, LArgs, LDepth, LSteps, LCaretRaw: Integer;
  LVis, LNode, LDesig, LOpen: Integer;
  LMid, LSym, LCtx, LCallNode: Integer;
  LResolved, LFound: Boolean;
begin
  Result := False;
  AInfo := Default(TPasCallInfo);
  AInfo.CallNode := NIL_NODE;
  AInfo.BoundMid := -1;
  AInfo.BoundSym := NIL_SYM;
  if not CaretOffset(ALine, ACol, LOffset) then
    Exit;
  if LOffset = 0 then
    Exit;
  // Dead ($IFDEF'd-out) positions refuse outright, as CaretAt does: walking
  // backward from one would cross the whole inactive region onto unrelated
  // active code.
  if FModel.Tree.Source.IsSkipped(0, LOffset - 1) then
    Exit;
  LTS := FModel.Tree.Source.Files[0];
  LRaw := RawTokenAt(LOffset - 1);
  if LRaw < 0 then
    Exit;
  LRaw := PrevVisibleRaw(LRaw);
  LCaretRaw := LRaw;

  // Backward over VISIBLE tokens: nesting over ()/[], top-level commas count
  // arguments, a statement boundary at depth 0 means no call at all. Trivia
  // never appears here, and a string or number is a single token, so parens
  // and commas inside either cannot fool the walk.
  LDepth := 0;
  LArgs := 0;
  LSteps := 0;
  LOpen := -1;
  LMid := -1;
  LSym := NIL_SYM;
  LCtx := NIL_INST;
  LResolved := False;
  LFound := False;
  LCallNode := NIL_NODE;
  while (LRaw >= 0) and (LSteps < 4096) and not LFound do
  begin
    case LTS.Tokens[LRaw].Kind of
      tkRParen, tkRBracket:
        Inc(LDepth);
      tkLBracket:
        if LDepth = 0 then
          // The caret sits inside an INDEXER (or set constructor): the
          // innermost CALL is further out, and the commas counted so far
          // were the bracket's own, not the call's.
          LArgs := 0
        else
          Dec(LDepth);
      tkLParen:
        if LDepth = 0 then
        begin
          LVis := FVisOfRaw[LRaw];
          LNode := NIL_NODE;
          if LVis >= 0 then
            LNode := InnermostNodeAt(LVis);
          // The '(' of a DECLARATION's parameter list: not a call, and
          // walking out of a declaration head helps nobody.
          if (LNode <> NIL_NODE) and
             (FModel.Tree.Nodes[LNode].Kind = nkParams) then
            Exit;
          LDesig := NIL_NODE;
          LCallNode := NIL_NODE;
          if (LNode <> NIL_NODE) and
             (FModel.Tree.Nodes[LNode].Kind = nkCall) then
          begin
            // A well-formed call owns its '(' directly: the callee child
            // ends before it, the arguments start after it.
            LCallNode := LNode;
            LDesig := FModel.Tree.Nodes[LNode].FirstChild;
          end
          else if (LNode = NIL_NODE) or
                  (FModel.Tree.Nodes[LNode].Kind <> nkParen) then
          begin
            // A parse broken around the caret: accept the `ident(` shape,
            // recovering the designator from the token to the left.
            LPrev := PrevVisibleRaw(LRaw - 1);
            if (LPrev >= 0) and
               (LTS.Tokens[LPrev].Kind = tkIdentifier) then
              LDesig := DesignatorNodeAtVis(FVisOfRaw[LPrev]);
          end;
          if LDesig <> NIL_NODE then
          begin
            LResolved := CalleeSyms(LDesig, LCallNode, LMid, LSym, LCtx);
            // A designator that names a TYPE is a cast, not a call - step
            // over it to the enclosing call, which is what a caret inside
            // `CheckResult(HRESULT(x|` wants to see.
            if LResolved and IsTypeSym(LMid, LSym) then
              LResolved := False
            else
            begin
              LOpen := LRaw;
              LFound := True;
            end;
          end;
          if not LFound then
            // Grouping paren (or a cast): the commas counted so far were
            // its own - reset and keep walking.
            LArgs := 0;
        end
        else
          Dec(LDepth);
      tkComma:
        if LDepth = 0 then
          Inc(LArgs);
      tkSemicolon, tkBegin, tkEnd, tkThen, tkDo, tkElse:
        if LDepth = 0 then
        begin
          // An ARGUMENT can hold these at depth 0 - an inline `if C then 1
          // else 2` (5.4.1) or an anonymous method's `begin ... end`
          // (17.2.1): the whole construct is one opaque argument, so the
          // walk resumes before it (audit A1-30). Anything else left the
          // statement without meeting an open paren.
          LNode := NIL_NODE;
          if FVisOfRaw[LRaw] >= 0 then
            LNode := InnermostNodeAt(FVisOfRaw[LRaw]);
          while (LNode <> NIL_NODE) and not (FModel.Tree.Nodes[LNode].Kind
                in [nkInlineIf, nkAnonMethod, nkCall, nkBlock,
                  nkRoutine]) do
            LNode := FModel.Tree.Nodes[LNode].Parent;
          // An anonymous method's own body block sits under it.
          if (LNode <> NIL_NODE) and
             (FModel.Tree.Nodes[LNode].Kind = nkBlock) then
          begin
            LDesig := LNode;
            while (LDesig <> NIL_NODE) and not (FModel.Tree.Nodes[LDesig].Kind
                  in [nkAnonMethod, nkRoutine, nkCall]) do
              LDesig := FModel.Tree.Nodes[LDesig].Parent;
            if (LDesig <> NIL_NODE) and
               (FModel.Tree.Nodes[LDesig].Kind = nkAnonMethod) then
              LNode := LDesig;
          end;
          if (LNode = NIL_NODE) or not (FModel.Tree.Nodes[LNode].Kind in
             [nkInlineIf, nkAnonMethod]) then
            Exit;
          // A caret INSIDE an anonymous method is in its own statements,
          // not in the outer call's argument list.
          if (FModel.Tree.Nodes[LNode].Kind = nkAnonMethod) and
             (FModel.Tree.Source.Visible[
               FModel.Tree.Nodes[LNode].LastToken].TokenIndex >= LCaretRaw)
          then
            Exit;
          LVis := FModel.Tree.NodeLeftmostVis(LNode);
          if (LVis < 0) or (FModel.Tree.Source.Visible[LVis].FileId <> 0) then
            Exit;
          LRaw := PrevVisibleRaw(
            FModel.Tree.Source.Visible[LVis].TokenIndex - 1);
          Inc(LSteps);
          Continue;
        end;
    end;
    if not LFound then
    begin
      LRaw := PrevVisibleRaw(LRaw - 1);
      Inc(LSteps);
    end;
  end;
  if LOpen < 0 then
    Exit;

  LTS.OffsetToLineCol(LTS.Tokens[LOpen].Start, AInfo.OpenLine, AInfo.OpenCol);
  AInfo.ArgIndex := LArgs;
  AInfo.CallNode := LCallNode;
  AInfo.BoundExact := (LCallNode <> NIL_NODE) and
    (FModel.CallTarget.ContainsKey(LCallNode) or
     FModel.CallTargetX.ContainsKey(LCallNode));
  if LResolved then
  begin
    AInfo.BoundMid := LMid;
    AInfo.BoundSym := LSym;
    AddCallTargets(LMid, LSym, LCtx, AInfo);
  end;
  Result := True;
end;

{ ---- type positions (pastree-lsp COMPLETION.md, "Type positions") ---- }

{ Which ranked type position the caret stands in, its context set up (the
  fields TypePosFit reads); tpNone for any other position. Token-first, the
  overlay tree consulted where a token is ambiguous - a `[` or `,` of an
  attribute against a set constructor's or an index's, a `,` of a
  constraint list against one of a parameter's names. ACaretOff is the
  caret's offset into Files[0] (-1 when unknown). }
function TPasCompletion.TypePosAt(const AInfo: TPasCaretInfo;
  ACaretOff: Integer): TPasComplTypePos;
var
  LTS: TPasTokenStream;
  LPrev, LOp, LNode: Integer;
  LKind: TPasTokenKind;
  LAttr: Boolean;
begin
  Result := tpNone;
  if AInfo.Kind = ckIdent then
    LPrev := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    LPrev := AInfo.RawToken;
  if LPrev < 0 then
    Exit;
  LTS := FModel.Tree.Source.Files[0];
  LKind := LTS.Tokens[LPrev].Kind;
  // `X is |`, `X as |`, and Delphi 13's `X is not |`.
  LOp := -1;
  if LKind in [tkIs, tkAs] then
    LOp := LPrev
  else if LKind = tkNot then
  begin
    LOp := PrevVisibleRaw(LPrev - 1);
    if (LOp >= 0) and (LTS.Tokens[LOp].Kind <> tkIs) then
      LOp := -1;
  end;
  if LOp >= 0 then
  begin
    FTypeAs := LTS.Tokens[LOp].Kind = tkAs;
    FTypeAfterIs := LKind = tkIs;
    IsAsLeftOf(LOp);
    if FTypeAs then
      AsTargetOf(LOp, AInfo.Scope);
    Exit(tpIsAs);
  end;
  // A property's `implements |`, `implements IA, |`: an interface.
  if ImplementsAt(AInfo, LPrev) then
  begin
    ImplementsFirstOf(AInfo);
    FTypeRank := True;
    Exit(tpImplements);
  end;
  // `class helper for |`, `record helper for |` (FHelperRecord).
  if (LKind = tkFor) and HelperAt(LPrev) then
  begin
    FTypeRank := True;
    Exit(tpHelper);
  end;
  // A type declaration's right side: `T = |` (ClassifyAt made it ccType),
  // `T = type |` (a reserved word: ccStatement) - a type identifier there.
  if (LKind = tkEqual) and (FContext = ccType) then
  begin
    FTypeRank := True;
    Exit(tpTypeDecl);
  end;
  if (LKind = tkType) and (LPrev > 0) then
  begin
    LOp := PrevVisibleRaw(LPrev - 1);
    if (LOp >= 0) and (LTS.Tokens[LOp].Kind = tkEqual) and
       (UpChainKind(AInfo.Node, [nkTypeDecl, nkConstDecl, nkVarDecl,
         nkParam, nkBlock]) in [nkTypeDecl, nkError]) then
    begin
      LOp := PrevVisibleRaw(LOp - 1);
      if (LOp >= 0) and (LTS.Tokens[LOp].Kind in [tkIdentifier, tkGreater])
      then
      begin
        FTypeAfterType := True;
        FTypeRank := True;
        Exit(tpTypeDecl);
      end;
    end;
  end;
  // `class of |` names a class (E2021 otherwise), `set of |` an ordinal
  // of at most 256 values in 0..255 (E2028, E2001) - ClassifyAt made both
  // ccType.
  if (LKind = tkOf) and (FContext = ccType) then
    case UpChainKind(AInfo.Node, [nkClassOf, nkSetType, nkArrayType,
      nkFileType]) of
      nkClassOf:
        begin
          FTypeRank := True;
          Exit(tpClassOf);
        end;
      nkSetType:
        begin
          FTypeRank := True;
          Exit(tpSetOf);
        end;
    end;
  // An attribute's name: right after the group's `[` or a `,` of it - the
  // parser made the brackets an nkAttrGroup (before a declaration), not a
  // set constructor or an index; a name being typed is the nkAttribute's
  // first child (its arguments follow it, and are expressions).
  if LKind in [tkLBracket, tkComma] then
  begin
    if AInfo.Kind = ckIdent then
    begin
      LNode := FModel.Tree.Nodes[AInfo.Node].Parent;
      LAttr := (LNode <> NIL_NODE) and
        (FModel.Tree.Nodes[LNode].Kind = nkAttribute) and
        (FModel.Tree.Nodes[LNode].FirstChild = AInfo.Node);
    end
    else
      LAttr := UpChainKind(AInfo.Node, [nkAttrGroup, nkAttribute, nkSetCtor,
        nkIndex, nkCall, nkParen, nkGuid]) = nkAttrGroup;
    if LAttr then
    begin
      FTypeBase := NamedClassX('tcustomattribute');
      FTypeRank := XValid(FTypeBase);
      Exit(tpAttribute);
    end;
  end;
  // An exception handler's class: `on E: |`, or `on |` with no name.
  if ((LKind = tkColon) and (FContext = ccType) and
      (UpChainKind(AInfo.Node, [nkExceptOn, nkInlineVar, nkInlineConst,
        nkVarDecl, nkConstDecl, nkParam, nkAnonMethod, nkRoutine,
        nkTypeDecl]) = nkExceptOn)) or
     ((LKind = tkIdentifier) and
      SameText(Copy(LTS.Source, LTS.Tokens[LPrev].Start + 1,
        LTS.Tokens[LPrev].Len), 'on') and
      (UpChainKind(AInfo.Node, [nkExceptOn, nkExceptPart, nkTryStmt]) =
       nkExceptOn)) then
  begin
    FTypeBase := NamedClassX('exception');
    FTypeRank := XValid(FTypeBase);
    Exit(tpHandler);
  end;
  if IsConstraintAt(AInfo, LPrev) then
  begin
    FTypeRank := True;   // the keywords first
    Exit(tpConstraint);
  end;
  if (LKind in [tkLess, tkNotEqual, tkComma]) and
     GenericArgAt(AInfo, LPrev, ACaretOff) then
    Result := tpGenArg;
end;

{ The static type of `is` / `as`'s left side at the raw operator AOp - the
  designator ending before it - into FTypeLeft / FTypeLeftCat; ranked only
  when it is a class or an interface. }
procedure TPasCompletion.IsAsLeftOf(AOp: Integer);
var
  LNode, LBefore, LOv: Integer;
  LRef: TPasComplTypeRef;
  LX: TSemaXType;
begin
  if FProj = nil then
    Exit;
  LNode := DesignatorEndingAt(PrevVisibleRaw(AOp - 1), LBefore);
  if LNode = NIL_NODE then
    Exit;
  LRef := DesignatorType(LNode, 0);
  if not ComplValid(LRef) or LRef.IsTypeRef then
    Exit;
  LX := RefValueX(LRef, LOv);
  if XValid(LX) then
  begin
    FTypeLeft := FProj.CanonTypeX(LX);
    FTypeLeftCat := FProj.XCatOf(FTypeLeft);
  end
  else if LOv <> NIL_SYM then
    FTypeLeftCat := FModel.Symbols[LOv].TypeCat;
  FTypeRank := FTypeLeftCat in [tcClass, tcInterface];
end;

{ The type an `as` expression at raw operator AOp must be assignable to -
  `Acc := AObj as |` Acc's, `Foo(AObj as |)` the parameter's - into
  FAsTarget / FAsTargetCat, when it is a class or an interface other than
  TObject and IInterface (which every class, every interface, is): dcc 37
  rejects a cast whose type does not convert to it (E2010 for an ancestor
  and an unrelated class alike), so TypePosFit ranks the types against it.
  Only for `:=` and a value parameter, the positions FFlatRootPos marks; the
  probe's other answers are about that outer operand and are dropped
  (ResetOperandState). }
procedure TPasCompletion.AsTargetOf(AOp, AScope: Integer);
var
  LNode, LBefore, LOv: Integer;
  LRef: TPasComplTypeRef;
  LX: TSemaXType;
  LAt: Boolean;
begin
  if FProj = nil then
    Exit;
  LNode := DesignatorEndingAt(PrevVisibleRaw(AOp - 1), LBefore);
  if (LNode = NIL_NODE) or (LBefore < 1) then
    Exit;
  // `X := (Y as |).Member`: a cast in a grouping paren is mostly read
  // through - its own type is not what is assigned (the frozen audit's
  // `(AForm as TFooForm).Items`, the `)` not yet typed).
  if (FModel.Tree.Source.Files[0].Tokens[LBefore].Kind = tkLParen) and
     IsGroupingParen(LBefore) then
    Exit;
  LRef := OperandExpect(LBefore, AScope, 0);
  LAt := FFlatRootPos and not FArgByRef;
  LX := RefValueX(LRef, LOv);
  ResetOperandState;
  if not LAt or not XValid(LX) then
    Exit;
  LX := FProj.CanonTypeX(LX);
  if not XValid(LX) or IsRootTypeX(LX) or
     not (FProj.XCatOf(LX) in [tcClass, tcInterface]) then
    Exit;
  FAsTarget := LX;
  FAsTargetCat := FProj.XCatOf(LX);
  FTypeRank := True;
end;

{ Is AX a generic parameter (AIsParam), and one `nil` is assignable to - its
  constraints name a class or an interface, or `class` (which
  ConstraintsOfParamX answers as TObject)? dcc 37: `Result := nil` compiles
  for `<I: IInterface>` and `<C: class>`, is E2010 for `<T>` and
  `<T: record>`. }
function TPasCompletion.GenericNilFits(const AX: TSemaXType;
  out AIsParam: Boolean): Boolean;
var
  LM: TPasSemaModel;
begin
  Result := False;
  AIsParam := False;
  if (FProj = nil) or not XValid(AX) or (AX.UnitId < 0) then
    Exit;
  LM := FProj.Model(AX.UnitId);
  if (LM = nil) or (AX.Sym = NIL_SYM) or
     (LM.Symbols[AX.Sym].Kind <> skGenericParam) then
    Exit;
  AIsParam := True;
  for var LC in FProj.ParamConstraintTypesX(AX) do
    if XValid(LC) and
       (FProj.XCatOf(FProj.CanonTypeX(LC)) in [tcClass, tcInterface]) then
      Exit(True);
end;

{ Is AX (canonical or not) System's TObject or IInterface - the roots every
  class, every interface converts to? }
function TPasCompletion.IsRootTypeX(const AX: TSemaXType): Boolean;
var
  LX: TSemaXType;
  LM: TPasSemaModel;
begin
  Result := False;
  if (FProj = nil) or not XValid(AX) then
    Exit;
  LX := FProj.CanonTypeX(AX);
  if not XValid(LX) or (LX.Inst <> NIL_INST) then
    Exit;
  LM := FProj.Model(LX.UnitId);
  if (LM = nil) or (LM.UnitNameLower <> 'system') then
    Exit;
  Result := (LM.Symbols[LX.Sym].NameLower = 'tobject') or
    (LM.Symbols[LX.Sym].NameLower = 'iinterface');
end;

{ A generic constraint: the caret after a type parameter's `:` (`<T: |>`),
  inside a constraint being typed, or after a `,` of a constraint list
  (`<T: class, |>`) - not a `,` between the parameters' names (`<A, |>`),
  which names a new one. }
function TPasCompletion.IsConstraintAt(const AInfo: TPasCaretInfo;
  APrev: Integer): Boolean;
var
  LTS: TPasTokenStream;
  LRaw, LDepth: Integer;
begin
  Result := False;
  if FContext <> ccType then
    Exit;
  case UpChainKind(AInfo.Node, [nkConstraint, nkGenericParam, nkGenericParams,
    nkTypeArgs, nkParams]) of
    nkConstraint:
      Exit(True);
    nkGenericParam:
      ;
  else
    Exit;
  end;
  LTS := FModel.Tree.Source.Files[0];
  case LTS.Tokens[APrev].Kind of
    tkColon:
      Exit(True);
    tkComma:
      ;
  else
    Exit;
  end;
  // Back to the group's `:` (a constraint list) or its start (a name list).
  LDepth := 0;
  LRaw := PrevVisibleRaw(APrev - 1);
  while LRaw >= 0 do
  begin
    case LTS.Tokens[LRaw].Kind of
      tkColon:
        Exit(LDepth = 0);
      tkGreater:
        Inc(LDepth);
      tkLess:
        if LDepth = 0 then
          Exit
        else
          Dec(LDepth);
      tkSemicolon:
        if LDepth = 0 then
          Exit;
      tkIdentifier, tkDot, tkComma, tkClass, tkRecord, tkConstructor,
      tkString:
        ;
    else
      Exit;
    end;
    LRaw := PrevVisibleRaw(LRaw - 1);
  end;
end;

{ A generic argument: the caret right after a type argument list's `<` - or
  inside an empty `<>`, which the lexer reads as one token - or after a `,`
  of the list, whose `<` a walk back finds. The name before the `<` must
  name a generic (a type, or a routine: `Foo<|>(`) unless the parse already
  made the list type arguments (a declaration's `TList<|`); a plain
  `X < |` is a comparison. Sets the constraints of the parameter the caret
  stands for (GenericConstraintsOf). }
function TPasCompletion.GenericArgAt(const AInfo: TPasCaretInfo; APrev,
  ACaretOff: Integer): Boolean;
var
  LTS: TPasTokenStream;
  LOpen, LIdx, LDepth, LRaw, LHead, LNode, LBefore, LMid, LSym, LArity,
    LLast: Integer;
  LKey: string;
  LM: TPasSemaModel;
  LParsed: Boolean;
  LX: TSemaXType;
begin
  Result := False;
  // A type declaration's own parameter list (`TB<A, |`) names parameters.
  if UpChainKind(AInfo.Node, [nkGenericParams, nkTypeArgs]) = nkGenericParams
  then
    Exit;
  LTS := FModel.Tree.Source.Files[0];
  LOpen := -1;
  LIdx := 0;
  case LTS.Tokens[APrev].Kind of
    tkLess:
      LOpen := APrev;
    tkNotEqual:
      if (AInfo.Kind = ckFresh) and
         (ACaretOff = LTS.Tokens[APrev].Start + 1) then
        LOpen := APrev;
    tkComma:
      begin
        LDepth := 0;
        LIdx := 1;
        LRaw := PrevVisibleRaw(APrev - 1);
        while (LRaw >= 0) and (LOpen < 0) do
        begin
          case LTS.Tokens[LRaw].Kind of
            tkGreater:
              Inc(LDepth);
            tkLess:
              if LDepth = 0 then
                LOpen := LRaw
              else
                Dec(LDepth);
            tkComma:
              if LDepth = 0 then
                Inc(LIdx);
            tkIdentifier, tkDot, tkString:
              ;
          else
            Exit;
          end;
          if LOpen < 0 then
            LRaw := PrevVisibleRaw(LRaw - 1);
        end;
      end;
  end;
  if LOpen < 0 then
    Exit;
  LHead := PrevVisibleRaw(LOpen - 1);
  if (LHead < 0) or (LTS.Tokens[LHead].Kind <> tkIdentifier) then
    Exit;
  LParsed := UpChainKind(AInfo.Node, [nkTypeArgs, nkCall, nkParen, nkSetCtor,
    nkIndex, nkBinaryOp]) = nkTypeArgs;
  // The arguments written after the caret count for the arity (16.1.2).
  LArity := LIdx + 1;
  if LTS.Tokens[APrev].Kind <> tkNotEqual then
  begin
    LDepth := 0;
    LLast := High(FVisOfRaw);
    LRaw := APrev + 1;
    if AInfo.Kind = ckIdent then
      LRaw := AInfo.RawToken + 1;
    while LRaw <= LLast do
    begin
      if FVisOfRaw[LRaw] >= 0 then
      begin
        case LTS.Tokens[LRaw].Kind of
          tkLess:
            Inc(LDepth);
          tkGreater:
            if LDepth = 0 then
              Break
            else
              Dec(LDepth);
          tkComma:
            if LDepth = 0 then
              Inc(LArity);
          tkIdentifier, tkDot, tkString:
            ;
        else
          Break;
        end;
      end;
      Inc(LRaw);
    end;
  end;
  // The generic the name before `<` names: the tree's binding, else the
  // name looked up from the caret's scope, then through the project.
  LKey := LowerCase(Copy(LTS.Source, LTS.Tokens[LHead].Start + 1,
    LTS.Tokens[LHead].Len));
  LNode := DesignatorEndingAt(LHead, LBefore);
  if (LNode = NIL_NODE) or not DesignatorSymOf(LNode, 0, LMid, LSym) then
  begin
    LMid := -1;
    LSym := FModel.ResolveAt(AInfo.Scope, LKey, -1);
  end;
  // An overlay type that is not this generic (`TList` beside `TList<T>`),
  // or none: the project's declaration of the written arity.
  if (LMid < 0) and ((LSym = NIL_SYM) or
     ((FModel.Symbols[LSym].Kind in [skType, skBuiltinType]) and
      (TPasSemaProject.GenericParamCountOf(FModel, LSym) <> LArity))) then
  begin
    LMid := -1;
    if not BridgeName(LKey, LMid, LSym) then
    begin
      LMid := -1;
      LSym := NIL_SYM;
    end;
  end;
  if (LSym <> NIL_SYM) and (LMid >= 0) and (FProjMid >= 0) and
     (ProjModel(LMid, 'GenericArgAt').Symbols[LSym].Kind = skType) then
  begin
    LX := FProj.TypeAtArityX(FProjMid, XPlain(LMid, LSym), LArity, NIL_NODE,
      LKey);
    if XValid(LX) then
    begin
      LMid := LX.UnitId;
      LSym := LX.Sym;
    end;
  end;
  if LSym = NIL_SYM then
    Exit(LParsed);
  if LMid < 0 then
    LM := FModel
  else
    LM := ProjModel(LMid, 'GenericArgAt');
  if TPasSemaProject.GenericParamCountOf(LM, LSym) = 0 then
    Exit(LParsed);
  Result := True;
  GenericConstraintsOf(LMid, LSym, LIdx);
end;

{ The constraints of type parameter AIndex of the generic (AMid, ASym) -
  AMid -1 for one the overlay declares - into FGenClass / FGenRecord /
  FGenCtor (the keywords) and FGenBases (the class and interface types);
  FGenOpenBase when a constraint type does not resolve. Constraints are
  declared per group (`<K; V: class, constructor>`). }
procedure TPasCompletion.GenericConstraintsOf(AMid, ASym, AIndex: Integer);
var
  LM: TPasSemaModel;
  LGen, LParam, LP, LCount, LBase, LChild: Integer;
  LWord: Byte;
  LX: TSemaXType;
  LRef: TPasComplTypeRef;
begin
  if AMid < 0 then
    LM := FModel
  else
    LM := ProjModel(AMid, 'GenericConstraintsOf');
  LGen := TPasSemaProject.GenericParamsNodeOf(LM, ASym);
  if LGen = NIL_NODE then
    Exit;
  LBase := 0;
  LParam := LM.Tree.Nodes[LGen].FirstChild;
  while LParam <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LParam].Kind = nkGenericParam then
    begin
      // Leading idents are the names; the nkConstraint nodes follow them.
      LCount := 0;
      LP := PasSkipAttrGroups(LM.Tree, LM.Tree.Nodes[LParam].FirstChild);
      while (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].Kind = nkIdent) do
      begin
        Inc(LCount);
        LP := PasSkipAttrGroups(LM.Tree, LM.Tree.Nodes[LP].NextSibling);
      end;
      if AIndex < LBase + LCount then
      begin
        while LP <> NIL_NODE do
        begin
          if LM.Tree.Nodes[LP].Kind = nkConstraint then
          begin
            LChild := LM.Tree.Nodes[LP].FirstChild;
            if LChild <> NIL_NODE then
            begin
              LX := XNil;
              if FProj <> nil then
                if AMid >= 0 then
                  LX := FProj.ResolveTypeExpr(AMid, LChild)
                else
                begin
                  LRef := ResolveTypeRefNode(LChild, 0);
                  LX := LRef.X;
                  if not XValid(LX) and (LRef.OvSym <> NIL_SYM) then
                    LX := OwnModelTypeX(LRef.OvSym);
                end;
              if XValid(LX) then
                FGenBases := FGenBases + [FProj.CanonTypeX(LX)]
              else
                FGenOpenBase := True;
            end
            else if LM.KeywordConstraints.TryGetValue(LP, LWord) then
              case TPasTokenKind(LWord) of
                tkClass:
                  FGenClass := True;
                tkRecord:
                  FGenRecord := True;
                tkConstructor:
                  FGenCtor := True;
              end;
          end;
          LP := LM.Tree.Nodes[LP].NextSibling;
        end;
        Break;
      end;
      Inc(LBase, LCount);
    end;
    LParam := LM.Tree.Nodes[LParam].NextSibling;
  end;
  FTypeRank := FGenClass or FGenRecord or FGenCtor or FGenOpenBase or
    (Length(FGenBases) > 0);
end;

// The class the caret's unit can name AKey (Exception, TCustomAttribute),
// canonical; XNil when it names none, or not a class.
function TPasCompletion.NamedClassX(const AKey: string): TSemaXType;
var
  LMid, LSym: Integer;
begin
  Result := XNil;
  if (FProj = nil) or not BridgeName(AKey, LMid, LSym) then
    Exit;
  Result := FProj.CanonTypeX(XPlain(LMid, LSym));
  if not XValid(Result) or (FProj.XCatOf(Result) <> tcClass) then
    Result := XNil;
end;

{ The kind of the token before the caret's identifier (before the caret
  where no identifier is under it); tkUnknown at the file's start. }
function TPasCompletion.PrevTokenKindAt(
  const AInfo: TPasCaretInfo): TPasTokenKind;
var
  LPrev: Integer;
begin
  if AInfo.Kind = ckIdent then
    LPrev := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    LPrev := AInfo.RawToken;
  if LPrev < 0 then
    Result := tkUnknown
  else
    Result := FModel.Tree.Source.Files[0].Tokens[LPrev].Kind;
end;

{ A helper type (`class helper for`, `record helper for`). }
function TPasCompletion.IsHelperSym(AModel: TPasSemaModel;
  ASym: Integer): Boolean;
var
  LDef: Integer;
begin
  Result := False;
  if AModel.Symbols[ASym].Kind <> skType then
    Exit;
  LDef := TPasSemaProject.TypeDefNodeIn(AModel, ASym);
  Result := (LDef <> NIL_NODE) and
    (AModel.Tree.Nodes[LDef].Kind = nkHelperType);
end;

{ The category of the type a type symbol names, followed through aliases -
  a qualified one (`EListError = System.SysUtils.EListError`), a distinct
  one (`HDC = type UINT_PTR`), a generic instance (`TFoos = TArray<TFoo>`) -
  for a project's symbol and for one of the buffer's own; tcUnknown when no
  project can tell. }
function TPasCompletion.AliasCatOf(AMid, ASym: Integer): TSemaTypeCat;
var
  LX: TSemaXType;
begin
  Result := tcUnknown;
  if FProj = nil then
    Exit;
  if AMid >= 0 then
    LX := XPlain(AMid, ASym)
  else
    LX := OwnModelTypeX(ASym);
  if XValid(LX) then
    Result := FProj.XCatThroughX(LX);
end;

{ How near an item is to the compiler's own simple types, as completion
  lists it: 0 for the ones written most (Integer, Boolean, string, Char,
  Byte, Word, Cardinal, Double, Single, Extended, Currency, Pointer,
  Variant), the keyword `string` included; 1 for every other seeded builtin
  of a scalar, string, pointer or variant category (Int64, SmallInt,
  ShortInt, UInt64, NativeInt, AnsiChar, WideString, ... - not TObject,
  TClass, TArray, a file); 2 for System's fixed-size aliases of them (Int8
  .. UInt32, FixedInt, FixedUInt, IntPtr, UIntPtr) and its TDateTime,
  TDate, TTime; 3 for anything else. Graded because the name decides
  within a grade: `Int|` meant Integer far more often than Int64 or Int16
  (Integer is 59 of the 100 built-in types written in the audit's corpora,
  Boolean 23). }
function TPasCompletion.BuiltinTypeRank(const AItem: TPasComplItem): Integer;
const
  MOST_WRITTEN: array[0..12] of string = ('integer', 'boolean', 'string',
    'char', 'byte', 'word', 'cardinal', 'double', 'single', 'extended',
    'currency', 'pointer', 'variant');
  SYSTEM_SIMPLE: array[0..12] of string = ('int8', 'int16', 'int32',
    'uint8', 'uint16', 'uint32', 'fixedint', 'fixeduint', 'intptr',
    'uintptr', 'tdatetime', 'tdate', 'ttime');
var
  LM: TPasSemaModel;
  LKey: string;
begin
  Result := 3;
  if AItem.Bucket = cbKeyword then
  begin
    if SameText(AItem.Name, 'string') then
      Result := 0;
    Exit;
  end;
  if AItem.Sym = NIL_SYM then
    Exit;
  if AItem.Kind = skBuiltinType then
  begin
    if SymModelOf(AItem.Mid, 'BuiltinTypeRank', LM, False) and
       (LM.Symbols[AItem.Sym].TypeCat in [tcInteger, tcFloat, tcBoolean,
        tcChar, tcString, tcPointer, tcVariant]) then
    begin
      Result := 1;
      LKey := LowerCase(AItem.Name);
      for var LName in MOST_WRITTEN do
        if LName = LKey then
          Exit(0);
    end;
    Exit;
  end;
  if (AItem.Kind <> skType) or (AItem.Mid < 0) or (FProj = nil) then
    Exit;
  LM := FProj.Model(AItem.Mid);
  if (LM = nil) or (LM.UnitNameLower <> 'system') then
    Exit;
  LKey := LowerCase(AItem.Name);
  for var LName in SYSTEM_SIMPLE do
    if LName = LKey then
      Exit(2);
end;

{ A declaration's type, an array's element, a pointer's base, a generic
  argument (FBuiltinFirst): the compiler's own simple types first. Over a
  thousand types share the list there, ranked by nothing (or by a generic
  parameter's constraint), and sorted by the bucket and the name every
  used unit's `Int*` type (Int64Rec, INIT_ONCE) came before `Integer` -
  the pastree-lsp audit (2026-11-09) found a built-in type the author
  wrote at row 1 in 26% of the requests with 2-3 letters typed. Each item
  takes its BuiltinTypeRank in steps of Conv: within a fit, the simple
  types written most lead, the other builtins and System's aliases of
  them next. }
procedure TPasCompletion.BuiltinTypesFirst;
var
  LIdx: Integer;
begin
  for LIdx := 0 to FCount - 1 do
  begin
    Inc(FItems[LIdx].Conv, BuiltinTypeRank(FItems[LIdx]));
    if FItems[LIdx].Conv > CConvDistVariant then
      FItems[LIdx].Conv := CConvDistVariant;
  end;
end;

{ A heritage list's entry (FHeritage): `class(|` takes a class (an
  interface there is E2021), `class(TBase, |` and `interface(|` an
  interface (a class after the comma is E2205) - dcc 37. A unit name and a
  type whose category is not known lead. }
function TPasCompletion.HeritageFit(
  const AItem: TPasComplItem): TPasComplMatch;
var
  LCat: TSemaTypeCat;
begin
  if (AItem.Bucket = cbUnitName) or (AItem.Kind = skUnitRef) then
    Exit(cmLeads);
  if not (AItem.Kind in [skType, skBuiltinType]) then
    Exit(cmOther);
  TypeItemX(AItem, LCat);
  if (LCat = tcUnknown) and (AItem.Kind = skType) then
    LCat := AliasCatOf(AItem.Mid, AItem.Sym);
  if LCat = tcUnknown then
    Exit(cmLeads);
  if (FHeritage = nkClassType) and FHeritageFirst then
  begin
    if LCat = tcClass then
      Result := cmCompatible
    else
      Result := cmOther;
  end
  else if LCat = tcInterface then
    Result := cmCompatible
  else
    Result := cmOther;
end;

{ Whether a type of category ACat can stand in the type position at all: a
  class or an interface on the right of `is` / `as` and in a constraint, a
  class in a handler and an attribute; anything in a generic argument. A
  category not known stays listed rather than be wrongly hidden. }
function TPasCompletion.TypePosAdmits(ACat: TSemaTypeCat): Boolean;
begin
  case FTypePos of
    tpIsAs, tpConstraint:
      Result := ACat in [tcUnknown, tcClass, tcInterface];
    tpHandler, tpAttribute, tpClassOf:
      Result := ACat in [tcUnknown, tcClass];
    // A set's base: an ordinal type (TypePosFit ranks its size).
    tpSetOf:
      Result := ACat in [tcUnknown, tcInteger, tcBoolean, tcChar, tcEnum];
    // `implements` names an interface (E2205 for a class).
    tpImplements:
      Result := ACat in [tcUnknown, tcInterface];
    // A class helper a class (E2021); a record helper a record or a simple
    // type (E2474 for a procedural type, an interface, a class, a class
    // reference; a static array AddSym drops).
    tpHelper:
      if FHelperRecord then
        Result := not (ACat in [tcClass, tcInterface, tcClassOf, tcProc,
          tcFile])
      else
        Result := ACat in [tcUnknown, tcClass];
  else
    Result := True;
  end;
end;

// A value whose type is a class reference (`O is AClass`, `O as AClass`;
// a function returning one too).
function TPasCompletion.IsClassRefValue(AMid, ASym, ACtx: Integer): Boolean;
var
  LRef: TPasComplTypeRef;
  LX: TSemaXType;
  LOv: Integer;
begin
  Result := False;
  if FProj = nil then
    Exit;
  if AMid < 0 then
    LRef := TypeOfOverlaySym(ASym, 0)
  else
    LRef := TypeOfProjectSym(AMid, ASym, ACtx, 0);
  // A class-reference value is typed as its class, class-side.
  if LRef.IsTypeRef then
  begin
    if XValid(LRef.X) then
      Exit(FProj.XCatOf(FProj.CanonTypeX(LRef.X)) = tcClass);
    Exit((LRef.OvSym <> NIL_SYM) and
      (FModel.Symbols[LRef.OvSym].TypeCat = tcClass));
  end;
  LX := RefValueX(LRef, LOv);
  if XValid(LX) then
    Result := FProj.XCatOf(FProj.CanonTypeX(LX)) = tcClassOf
  else if LOv <> NIL_SYM then
    Result := FModel.Symbols[LOv].TypeCat = tcClassOf;
end;

// A type item's own type, canonical, and its category: a project type, a
// builtin through its System twin, an overlay type through its last-good
// twin - or, declared since the last analysis, its category alone.
function TPasCompletion.TypeItemX(const AItem: TPasComplItem;
  out ACat: TSemaTypeCat): TSemaXType;
var
  LMid, LSym: Integer;
begin
  Result := XNil;
  ACat := tcUnknown;
  if AItem.Sym = NIL_SYM then
    Exit;
  if FProj <> nil then
  begin
    if AItem.Mid >= 0 then
      Result := XPlain(AItem.Mid, AItem.Sym)
    else if AItem.Kind = skBuiltinType then
    begin
      if BridgeName(FModel.Symbols[AItem.Sym].NameLower, LMid, LSym) then
        Result := XPlain(LMid, LSym);
    end
    else
      Result := OwnModelTypeX(AItem.Sym);
    if XValid(Result) then
      Result := FProj.CanonTypeX(Result);
  end;
  if XValid(Result) then
    ACat := FProj.XCatOf(Result)
  else if AItem.Mid < 0 then
    ACat := FModel.Symbols[AItem.Sym].TypeCat;
end;

{ An item's fit in a type position (MatchOf's answer there):
  - `is` / `as` after a class: a descendant of the left side's type fits,
    the type itself and its ancestors lead (the test is true of any
    non-nil value), an unrelated class is wrong (E2010); after an
    interface any class fits. An interface fits after `as` and is wrong
    after `is` (dcc 37: E2015 whatever the left side). A class-reference
    value leads.
  - a handler, an attribute: a descendant of Exception / TCustomAttribute
    fits, another class is wrong.
  - a generic argument: what every constraint of its parameter admits fits
    - `class` a class, `record` a value type (a record, an ordinal, a float,
    a set), `constructor` a class (dcc 37 accepts every class, whatever its
    own Create takes), a class type its descendants, an interface type the
    classes listing it (others lead: an interface they implement may
    descend from it) and its descendants; what one rejects is wrong.
  - a constraint: the keywords first (fit 0), then the classes and the
    interfaces.
  A generic parameter, a unit name and a type whose category is not known
  lead. }
function TPasCompletion.TypePosFit(const AItem: TPasComplItem): TPasComplMatch;
const
  // dcc-verified accepted categories for `T: record` (CheckConstraints).
  VALUE_CATS = [tcRecord, tcInteger, tcFloat, tcBoolean, tcChar, tcEnum,
    tcSet];
var
  LX: TSemaXType;
  LCat: TSemaTypeCat;
  LDist: Integer;

  function Worse(A, B: TPasComplMatch): TPasComplMatch;
  begin
    if Ord(B) > Ord(A) then
      Result := B
    else
      Result := A;
  end;

  function DescentFit(const ADesc, ABase: TSemaXType): TPasComplMatch;
  begin
    case FProj.XDescentDistX(ADesc, ABase, LDist) of
      xdYes:
        begin
          Result := cmCompatible;
          // In a handler the nearer descendant first: Exception itself. Not
          // in an attribute or a generic argument, where the class meant is
          // a project's own, however deep.
          if FTypePos = tpHandler then
            if LDist < CConvDistVariant then
              FConvOut := LDist
            else
              FConvOut := CConvDistVariant - 1;
        end;
      xdNo:
        Result := cmOther;
    else
      Result := cmLeads;
    end;
  end;

  // The item against one constraint type ABase.
  function BaseFit(const ABase: TSemaXType): TPasComplMatch;
  begin
    if not XValid(LX) then
      Exit(cmLeads);
    case FProj.XCatOf(ABase) of
      tcClass:
        if LCat <> tcClass then
          Result := cmOther
        else
          Result := DescentFit(LX, ABase);
      tcInterface:
        if LCat = tcClass then
        begin
          if FProj.XImplementsX(LX, ABase) = xdYes then
            Result := cmCompatible
          else
            Result := cmLeads;
        end
        else if LCat = tcInterface then
          Result := DescentFit(LX, ABase)
        else
          Result := cmOther;
    else
      Result := cmLeads;
    end;
  end;

begin
  Result := cmOther;
  if AItem.Bucket = cbKeyword then
  begin
    // A constraint's keywords first; a type declaration's words introduce
    // a type as a name does.
    if FTypePos = tpConstraint then
      Result := cmExact
    else if FTypePos = tpTypeDecl then
      Result := cmCompatible;
    Exit;
  end;
  if (AItem.Bucket = cbUnitName) or
     (AItem.Kind in [skGenericParam, skUnitRef]) then
    Exit(cmLeads);
  if not (AItem.Kind in [skType, skBuiltinType]) then
  begin
    // A class-reference value after `is` / `as` - AddSym lets no other
    // value into a type position. dcc 37 takes it (`O is C`, `O is
    // ClassType`), but it leads: the types come first - a method's own
    // inherited `ClassType` / `ClassParent` topped the list otherwise.
    if FTypePos = tpIsAs then
      Result := cmLeads
    // A type declaration's subrange bound (`T = clRed..clBlue`): an
    // ordinal constant leads to a type, another is wrong - judged as a
    // `case` selector judges a value (OrdinalFit), the fit taken down one.
    else if FTypePos = tpTypeDecl then
    begin
      FTypePos := tpNone;
      FExpectOrdinal := True;
      try
        Result := MatchOf(AItem);
      finally
        FExpectOrdinal := False;
        FTypePos := tpTypeDecl;
      end;
      if Result in [cmExact, cmCompatible] then
        Result := cmLeads;
    end;
    Exit;
  end;
  LX := TypeItemX(AItem, LCat);
  if LCat = tcUnknown then
    Exit(cmLeads);
  case FTypePos of
    // `implements`: the class's heritage list and the property's type
    // first, any other interface after them.
    tpImplements:
      begin
        Result := cmCompatible;
        if XValid(LX) then
          for var LFirst in FImplFirst do
            if FProj.XSameType(LX, LFirst) then
              Exit(cmExact);
      end;
    tpHelper, tpTypeDecl, tpClassOf:
      Result := cmCompatible;
    // A set's base: one whose values lie in 0..255 fits; a wider one
    // (Integer, Word, a 16-bit Char - W1050 reduces that one to a byte)
    // is wrong; a range the analysis cannot tell leads. A builtin with no
    // System twin to read the range from goes by its name: Byte, Boolean
    // and AnsiChar are the ones of 0..255 (TPasSemaTyper.CheckSetCardinality).
    tpSetOf:
      begin
        var LLo, LHi: Int64;
        if XValid(LX) and FProj.XOrdRangeX(LX, LLo, LHi) then
        begin
          if (LLo >= 0) and (LHi <= 255) then
            Result := cmCompatible
          else
            Result := cmOther;
        end
        else if AItem.Kind = skBuiltinType then
        begin
          if SameText(AItem.Name, 'Byte') or SameText(AItem.Name, 'Boolean')
             or SameText(AItem.Name, 'AnsiChar') then
            Result := cmCompatible
          else
            Result := cmOther;
        end
        else
          Result := cmLeads;
      end;
    tpConstraint:
      Result := cmCompatible;
    tpHandler, tpAttribute:
      if LCat <> tcClass then
        Result := cmOther
      else if not XValid(LX) then
        Result := cmLeads
      else
        Result := DescentFit(LX, FTypeBase);
    // `as` with a target (AsTargetOf): the cast's type must convert to it -
    // the target itself fit 0, a descendant (an interface's: an interface
    // descending from it, a class implementing it) fit 1, anything else
    // wrong (E2010; a class to an interface target or the other way E2010 /
    // E2015). What the left operand rules out stays wrong.
    tpIsAs:
      if XValid(FAsTarget) then
      begin
        if not XValid(LX) then
          Exit(cmLeads);
        if FAsTargetCat = tcClass then
        begin
          if LCat <> tcClass then
            Exit(cmOther);
          case FProj.XDescentDistX(LX, FAsTarget, LDist) of
            xdYes:
              if LDist = 0 then
                Result := cmExact
              else
                Result := cmCompatible;
            xdNo:
              Exit(cmOther);
          else
            Exit(cmLeads);
          end;
        end
        else if LCat = tcInterface then
          case FProj.XDescentDistX(LX, FAsTarget, LDist) of
            xdYes:
              if LDist = 0 then
                Result := cmExact
              else
                Result := cmCompatible;
            xdNo:
              Exit(cmOther);
          else
            Exit(cmLeads);
          end
        else if LCat = tcClass then
          case FProj.XImplementsX(LX, FAsTarget) of
            xdYes:
              Result := cmCompatible;
            xdNo:
              Exit(cmOther);
          else
            Exit(cmLeads);
          end
        else
          Exit(cmOther);
        // An unrelated class on the left: `O as T` itself is E2010.
        if (LCat = tcClass) and (FTypeLeftCat = tcClass) and
           XValid(FTypeLeft) and
           (FProj.XDescentDistX(LX, FTypeLeft, LDist) = xdNo) and
           (FProj.XDescentDistX(FTypeLeft, LX, LDist) = xdNo) then
          Result := cmOther;
      end
      else if LCat = tcInterface then
      begin
        if FTypeAs then
          Result := cmCompatible;
      end
      else if LCat <> tcClass then
        Result := cmOther
      else if FTypeLeftCat = tcInterface then
        Result := cmCompatible
      else if not XValid(LX) or not XValid(FTypeLeft) then
        Result := cmLeads
      else
        case FProj.XDescentDistX(LX, FTypeLeft, LDist) of
          xdYes:
            if LDist > 0 then
              Result := cmCompatible
            else
              Result := cmLeads;
          xdNo:
            if FProj.XDescentDistX(FTypeLeft, LX, LDist) = xdNo then
              Result := cmOther
            else
              Result := cmLeads;
        else
          Result := cmLeads;
        end;
    tpGenArg:
      begin
        Result := cmCompatible;
        if (FGenClass or FGenCtor) and (LCat <> tcClass) then
          Result := cmOther;
        if FGenRecord and not (LCat in VALUE_CATS) then
          Result := cmOther;
        if FGenOpenBase then
          Result := Worse(Result, cmLeads);
        for var LBaseX in FGenBases do
          Result := Worse(Result, BaseFit(LBaseX));
      end;
  end;
end;

{ ---- declaration contexts (pastree-lsp COMPLETION.md) ---- }

{ A property's `implements` list: the caret right after the word, or after
  a `,` of its list (`implements IA, |`), in a `property` declaration - the
  tokens decide, a half-typed property parses in pieces. }
function TPasCompletion.ImplementsAt(const AInfo: TPasCaretInfo;
  APrev: Integer): Boolean;
var
  LTS: TPasTokenStream;
  LRaw, LSteps: Integer;

  function IsWordAt(ARaw: Integer; const AWord: string): Boolean;
  begin
    Result := (LTS.Tokens[ARaw].Kind = tkIdentifier) and
      SameText(Copy(LTS.Source, LTS.Tokens[ARaw].Start + 1,
        LTS.Tokens[ARaw].Len), AWord);
  end;

begin
  Result := False;
  LTS := FModel.Tree.Source.Files[0];
  LRaw := APrev;
  LSteps := 0;
  // Back over the list written so far to the word.
  if LTS.Tokens[LRaw].Kind = tkComma then
    while True do
    begin
      LRaw := PrevVisibleRaw(LRaw - 1);
      Inc(LSteps);
      if (LRaw < 0) or (LSteps > 256) then
        Exit;
      if IsWordAt(LRaw, 'implements') then
        Break;
      if not (LTS.Tokens[LRaw].Kind in [tkIdentifier, tkDot, tkComma, tkLess,
         tkGreater]) then
        Exit;
    end
  else if not IsWordAt(LRaw, 'implements') then
    Exit;
  // ... and back from the word to its `property`, inside one declaration.
  LSteps := 0;
  while True do
  begin
    LRaw := PrevVisibleRaw(LRaw - 1);
    Inc(LSteps);
    if (LRaw < 0) or (LSteps > 1024) then
      Exit;
    case LTS.Tokens[LRaw].Kind of
      tkProperty:
        Exit(True);
      tkSemicolon, tkBegin, tkEnd, tkAssign, tkClass, tkRecord,
      tkInterface, tkImplementation:
        Exit;
    end;
  end;
end;

{ The interfaces an `implements` ranks first: those the class's own
  heritage list names (dcc reports E2265 for any other) and the property's
  own type, into FImplFirst. }
procedure TPasCompletion.ImplementsFirstOf(const AInfo: TPasCaretInfo);
var
  LProp, LClass, LKid: Integer;
  LX: TSemaXType;
begin
  if FProj = nil then
    Exit;
  LProp := UpChainNode(AInfo.Node, nkPropertyDecl);
  if LProp = NIL_NODE then
    Exit;
  // The property's type: the child after its name and index parameters
  // that is no specifier.
  LKid := FModel.Tree.Nodes[LProp].FirstChild;
  if LKid <> NIL_NODE then
    LKid := FModel.Tree.Nodes[LKid].NextSibling;
  if (LKid <> NIL_NODE) and (FModel.Tree.Nodes[LKid].Kind = nkParams) then
    LKid := FModel.Tree.Nodes[LKid].NextSibling;
  if (LKid <> NIL_NODE) and (FModel.Tree.Nodes[LKid].Kind <> nkPropSpec) then
  begin
    LX := TypeNodeX(LKid);
    if XValid(LX) and (FProj.XCatOf(LX) = tcInterface) then
      FImplFirst := FImplFirst + [LX];
  end;
  // The class's heritage list: its leading type references.
  LClass := UpChainNode(LProp, nkClassType);
  if LClass = NIL_NODE then
    Exit;
  LKid := FModel.Tree.Nodes[LClass].FirstChild;
  while (LKid <> NIL_NODE) and
        (FModel.Tree.Nodes[LKid].Kind in [nkIdent, nkMember, nkTypeArgs]) do
  begin
    LX := TypeNodeX(LKid);
    if XValid(LX) and (FProj.XCatOf(LX) = tcInterface) then
      FImplFirst := FImplFirst + [LX];
    LKid := FModel.Tree.Nodes[LKid].NextSibling;
  end;
end;

// The type an overlay type reference ANode names, canonical; XNil when
// it does not resolve (one declared since the last analysis included).
function TPasCompletion.TypeNodeX(ANode: Integer): TSemaXType;
var
  LRef: TPasComplTypeRef;
begin
  Result := XNil;
  if FProj = nil then
    Exit;
  LRef := ResolveTypeRefNode(ANode, 0);
  Result := LRef.X;
  if not XValid(Result) and (LRef.OvSym <> NIL_SYM) then
    Result := OwnModelTypeX(LRef.OvSym);
  if XValid(Result) then
    Result := FProj.CanonTypeX(Result);
end;

{ A helper's extended type: APrev is the `for` of `class helper for |` or
  `record helper for |` (an ancestor helper between: `helper(THlp) for`).
  Sets FHelperRecord. }
function TPasCompletion.HelperAt(APrev: Integer): Boolean;
var
  LTS: TPasTokenStream;
  LRaw, LSteps: Integer;
begin
  Result := False;
  LTS := FModel.Tree.Source.Files[0];
  LRaw := PrevVisibleRaw(APrev - 1);
  if (LRaw >= 0) and (LTS.Tokens[LRaw].Kind = tkRParen) then
  begin
    LSteps := 0;
    repeat
      LRaw := PrevVisibleRaw(LRaw - 1);
      Inc(LSteps);
      if (LRaw < 0) or (LSteps > 64) then
        Exit;
    until LTS.Tokens[LRaw].Kind = tkLParen;
    LRaw := PrevVisibleRaw(LRaw - 1);
  end;
  if (LRaw < 1) or (LTS.Tokens[LRaw].Kind <> tkIdentifier) or
     not SameText(Copy(LTS.Source, LTS.Tokens[LRaw].Start + 1,
       LTS.Tokens[LRaw].Len), 'helper') then
    Exit;
  LRaw := PrevVisibleRaw(LRaw - 1);
  if (LRaw < 0) or not (LTS.Tokens[LRaw].Kind in [tkClass, tkRecord]) then
    Exit;
  FHelperRecord := LTS.Tokens[LRaw].Kind = tkRecord;
  Result := True;
end;

{ A static array's bound: the operand after raw token ARaw - a `[`, `,`
  or `..` - stands in the brackets of `array[...]` (`packed array` too),
  not a value's index or a set constructor. }
function TPasCompletion.IsArrayBoundOp(ARaw: Integer): Boolean;
var
  LOpen, LIdx: Integer;
begin
  Result := False;
  if (ARaw < 1) or not (FModel.Tree.Source.Files[0].Tokens[ARaw].Kind in
     [tkLBracket, tkComma, tkDotDot]) then
    Exit;
  LOpen := BracketOpenOf(ARaw, LIdx);
  if LOpen < 1 then
    Exit;
  LOpen := PrevVisibleRaw(LOpen - 1);
  Result := (LOpen >= 0) and
    (FModel.Tree.Source.Files[0].Tokens[LOpen].Kind = tkArray);
end;

{ A subrange type's high bound: raw token ARaw is the `..` of a subrange
  written as a declaration's type - after a type declaration's `=` or a
  declaration's `:` (`T = clRed..|`, `var X: 0..|`). }
function TPasCompletion.IsSubrangeHighOp(ARaw: Integer): Boolean;
var
  LTS: TPasTokenStream;
  LPrev, LBefore: Integer;
begin
  Result := False;
  LTS := FModel.Tree.Source.Files[0];
  if (ARaw < 1) or (LTS.Tokens[ARaw].Kind <> tkDotDot) then
    Exit;
  LPrev := PrevVisibleRaw(ARaw - 1);
  if LPrev < 0 then
    Exit;
  if LTS.Tokens[LPrev].Kind in [tkIntLiteral, tkStringLiteral, tkControlChar,
    tkCaretChar] then
  begin
    LBefore := PrevVisibleRaw(LPrev - 1);
    if (LBefore >= 0) and (LTS.Tokens[LBefore].Kind in [tkMinus, tkPlus]) then
      LBefore := PrevVisibleRaw(LBefore - 1);
  end
  else if DesignatorEndingAt(LPrev, LBefore) = NIL_NODE then
    Exit;
  Result := (LBefore >= 0) and (LTS.Tokens[LBefore].Kind in [tkEqual, tkColon]);
end;

{ The type of a bound's low side, before the `..` at raw token ADotDot: an
  integer literal's Integer, a one-character literal's Char, a designator's
  type (a constant, an enumeration value, `Ord('A')`). ComplNilRef when it
  is none of them - the caller then expects any ordinal. }
function TPasCompletion.BoundLeftType(ADotDot: Integer): TPasComplTypeRef;
var
  LTS: TPasTokenStream;
  LPrev, LNode, LBefore, LMid, LSym: Integer;
  LM: TPasSemaModel;
begin
  Result := ComplNilRef;
  if FProj = nil then
    Exit;
  LTS := FModel.Tree.Source.Files[0];
  LPrev := PrevVisibleRaw(ADotDot - 1);
  if LPrev < 0 then
    Exit;
  case LTS.Tokens[LPrev].Kind of
    tkIntLiteral:
      if BridgeName('integer', LMid, LSym) then
        Result.X := XPlain(LMid, LSym);
    tkControlChar, tkCaretChar, tkStringLiteral:
      if ((LTS.Tokens[LPrev].Kind <> tkStringLiteral) or
          (LTS.Tokens[LPrev].Len = 3)) and BridgeName('char', LMid, LSym) then
        Result.X := XPlain(LMid, LSym);
  else
    LNode := DesignatorEndingAt(LPrev, LBefore);
    if LNode <> NIL_NODE then
    begin
      Result := DesignatorType(LNode, 0);
      if Result.IsTypeRef then
        Result := ComplNilRef;
    end;
    // A declaration's bound has no binding of its own in the overlay: a
    // constant or an enumeration value of another unit, by its name.
    if not ComplValid(Result) and (LTS.Tokens[LPrev].Kind = tkIdentifier) and
       (LNode <> NIL_NODE) and (FModel.Tree.Nodes[LNode].Kind = nkIdent) and
       BridgeName(LowerCase(Copy(LTS.Source, LTS.Tokens[LPrev].Start + 1,
         LTS.Tokens[LPrev].Len)), LMid, LSym) then
    begin
      LM := ProjModel(LMid, 'BoundLeftType');
      case LM.Symbols[LSym].Kind of
        skEnumValue:
          if LM.Symbols[LSym].TypeSym <> NIL_SYM then
            Result.X := FProj.CanonTypeX(XPlain(LMid,
              LM.Symbols[LSym].TypeSym));
        skConst:
          begin
            Result := TypeOfProjectSym(LMid, LSym, -1, 0);
            if not ComplValid(Result) then
            begin
              Result := ComplNilRef;
              Result.X := FProj.DeclTypeX(LMid, LSym);
              if XValid(Result.X) then
                Result.X := FProj.CanonTypeX(Result.X);
            end;
          end;
      end;
    end;
  end;
end;

{ Everything OperandExpect and its helpers decide about the operand at the
  caret, back to "nothing expected": before a completion, and after the
  `as` target's probe (AsTargetOf), whose answer is about another operand. }
procedure TPasCompletion.ResetOperandState;
begin
  FExpect := XNil;
  FExpectCat := tcUnknown;
  FExpectOv := NIL_SYM;
  FNoProcedures := False;
  FArgNoProcs := False;
  FArgByRef := False;
  FArgIncDec := False;
  FArgSetLen := False;
  FArgAssigned := False;
  FExpectOrdinal := False;
  FConstOnly := False;
  FExitNoValue := False;
  FBoundType := False;
  FCaseSel := False;
  FCondLike := False;
  FCompare := False;
  FExpectEnum := False;
  FEnumElem := XNil;
  FCastRef := tcUnknown;
  FCastValue := tcUnknown;
  FCastX := XNil;
  FCastSize := -1;
  FCastOrdSize := -1;
  FExpectAddr := False;
  FExpectWith := False;
  FExpectRaise := False;
  FRaiseBase := XNil;
  FExpectNumber := False;
  FArgOpenElem := ComplNilRef;
  FFlatRootPos := False;
  FFlatRoot := False;
  FExpectGenNil := False;
  FArgTied := nil;
  FExpectAlts := nil;
end;

function TPasCompletion.CompleteAt(ALine, ACol: Integer;
  out ACaret: TPasCaretInfo; out AContext: TPasComplContext;
  out AItems: TArray<TPasComplItem>): Boolean;
var
  LInfo: TPasCaretInfo;
  LRef: TPasComplTypeRef;
  LNode, LOff, LOv, LBridged: Integer;
  LSpec: string;
begin
  AContext := ccNone;
  AItems := nil;
  Result := CaretAt(ALine, ACol, LInfo);
  ACaret := LInfo;
  if not Result then
    Exit;
  FCaretVis := LInfo.VisToken;
  FContext := ClassifyAt(LInfo);
  AContext := FContext;
  if FContext = ccUses then
  begin
    // Unit names are dotted; the caret's prefix/replace-span must be too.
    ExtendUsesPrefix(ALine, LInfo);
    ACaret := LInfo;
  end;
  FItems := nil;
  FPendingOverrides := nil;
  FNextSame := nil;
  FParamsOf := nil;
  FParamsKnown := nil;
  FCount := 0;
  // Not Clear: it discards the table's capacity AND virtual-notifies every
  // old entry - recreating is cheaper at list scale. Pre-sized where the list
  // runs to thousands of names (a statement list: 3,150 in the audit's
  // probe); a member list is about a hundred, and growing from the default
  // beats zero-filling 16K slots (C1-36).
  FSeen.Free;
  if FContext in [ccStatement, ccExpression, ccType, ccUses] then
    FSeen := TDictionary<string, Integer>.Create(4096)
  else
    FSeen := TDictionary<string, Integer>.Create;
  FAncestryBuilt := False;
  FClassSide := False;
  FSelfOv := NIL_SYM;
  FSelfClass := False;
  FFieldsOnly := False;
  FBaseOwnUnit := False;
  FInMethodBody := MethodBodyScope(LInfo.Scope) <> NIL_SCOPE;
  FTypeNameOnly := (FContext = ccType) and TypeNameOnlyAt(LInfo);
  FColonType := (FContext = ccType) and ColonTypeAt(LInfo);
  if FContext = ccType then
    FHeritage := HeritageAt(LInfo)
  else
    FHeritage := nkError;
  if FHeritage <> nkError then
    FHeritageDecl := UpChainNode(LInfo.Node, nkTypeDecl)
  else
    FHeritageDecl := NIL_NODE;
  FHeritageFirst := (FHeritage <> nkError) and
    (PrevTokenKindAt(LInfo) = tkLParen);
  // The right side of `:=` or a comparison: what the left side wants ranks
  // first (RankItems), and a procedure is no operand unless the left side
  // is of a procedural type - or of a type whose category is not known.
  // After a dot (`X := Obj.|`) the members are ranked the same way.
  ResetOperandState;
  FAsTarget := XNil;
  FAsTargetCat := tcUnknown;
  // A ranked type position (`is` / `as`, a handler, a generic argument or
  // constraint, an attribute) is a type position whatever the token rules
  // made of it: `O is |` and `[|]` read as expressions, `on |` too.
  FTypePos := tpNone;
  FTypeAs := False;
  FTypeAfterIs := False;
  FTypeLeft := XNil;
  FTypeLeftCat := tcUnknown;
  FTypeBase := XNil;
  FTypeRank := False;
  FGenClass := False;
  FGenRecord := False;
  FGenCtor := False;
  FGenBases := nil;
  FGenOpenBase := False;
  FImplFirst := nil;
  FHelperRecord := False;
  FTypeAfterType := False;
  FPropRank := False;
  FPropX := XNil;
  FPropOv := NIL_SYM;
  FPropIdxX := nil;
  FPropIdxOv := nil;
  FPropIdxMode := nil;
  FPropIndexed := False;
  FPropClass := False;
  FInhName := '';
  FInhRank := False;
  FInhClass := False;
  FInhCtor := False;
  if FContext in [ccPropRead, ccPropWrite, ccPropStored] then
    PropAccessorOf(LInfo);
  if FContext = ccInherited then
  begin
    // Outside a method body there is no ancestor to call: the collection
    // below lists nothing then.
    LNode := MethodBodyScope(LInfo.Scope);
    if LNode <> NIL_SCOPE then
    begin
      FInhName := InheritedMethodName(LNode);
      FInhRank := True;
      LOv := FModel.Scopes[LNode].OwnerNode;
      FInhClass := (LOv <> NIL_NODE) and
        (FModel.Tree.Nodes[LOv].Kind = nkRoutine) and
        (FModel.Tree.Nodes[LOv].Aux = 1);
      FInhCtor := (LOv <> NIL_NODE) and
        (FModel.Tree.Nodes[LOv].Kind = nkRoutine) and
        (FModel.Tree.Nodes[LOv].FirstToken >= 0) and
        (FModel.Tree.Nodes[LOv].FirstToken <=
         High(FModel.Tree.Source.Visible)) and
        (FModel.Tree.Source.VisibleKind(FModel.Tree.Nodes[LOv].FirstToken) =
         tkConstructor);
    end;
  end;
  if FContext in [ccExpression, ccType, ccStatement] then
  begin
    if not CaretOffset(ALine, ACol, LOff) then
      LOff := -1;
    FTypePos := TypePosAt(LInfo, LOff);
    if FTypePos <> tpNone then
    begin
      FContext := ccType;
      AContext := FContext;
      FTypeNameOnly := False;
      FHeritage := nkError;
      FHeritageDecl := NIL_NODE;
      FHeritageFirst := False;
      // `T = |`, `TH = class helper for |` never name the type declared.
      if FTypePos in [tpTypeDecl, tpHelper] then
        FHeritageDecl := UpChainNode(LInfo.Node, nkTypeDecl);
    end;
  end;
  FHelperOk := (FContext = ccType) and
    ((FTypePos in [tpGenArg, tpTypeDecl]) or
     ((FTypePos = tpNone) and (PrevTokenKindAt(LInfo) = tkCaret)));
  FBuiltinFirst := (FContext = ccType) and (FHeritage = nkError) and
    (FTypePos in [tpNone, tpGenArg]);
  if FContext in [ccExpression, ccMember] then
  begin
    // A property's `default |` and `index |` are constant expressions: of
    // the property's type, of Integer (13.1.1).
    LSpec := '';
    if (FContext = ccExpression) and (FProj <> nil) then
      LSpec := PropSpecWordAt(LInfo.Node);
    if LSpec = 'default' then
    begin
      PropAccessorOf(LInfo);
      FPropRank := False;
      FExpect := FPropX;
      FExpectOv := FPropOv;
      FConstOnly := True;
    end
    else if LSpec = 'index' then
    begin
      if BridgeName('integer', LOv, LBridged) then
        FExpect := FProj.CanonTypeX(XPlain(LOv, LBridged));
      FConstOnly := True;
    end
    else
      FExpect := RefValueX(ExpectedTypeAt(LInfo), FExpectOv);
    // The declaration decides a constant expression, not only the operator
    // before the caret: `const C = |`, `C = A + |` (ConstExprSiteAt). A
    // `message` / `dispid` index is an integer constant too.
    if not FConstOnly then
    begin
      if LInfo.Kind = ckIdent then
        LSpec := DirectiveWordBefore(LInfo, PrevVisibleRaw(LInfo.RawToken - 1))
      else
        LSpec := DirectiveWordBefore(LInfo, LInfo.RawToken);
      FConstOnly := (LSpec = 'message') or (LSpec = 'dispid') or
        ConstExprSiteAt(LInfo);
    end;
    if XValid(FExpect) then
      FExpectCat := FProj.XCatOf(FExpect)
    else if FExpectOv <> NIL_SYM then
      FExpectCat := FModel.Symbols[FExpectOv].TypeCat;
    FFlatRoot := FFlatRootPos and not FArgByRef and IsRootTypeX(FExpect);
    // A value of a generic parameter's type is never a procedure.
    // One only the buffer types is judged through its last-good twin.
    if FExpectCat = tcUnknown then
    begin
      var LGenParam: Boolean;
      var LGenX := FExpect;
      if not XValid(LGenX) and (FExpectOv <> NIL_SYM) and
         (FModel.Symbols[FExpectOv].Kind = skGenericParam) then
      begin
        LGenX := OwnModelParamX(FExpectOv);
        FArgNoProcs := True;
      end;
      FExpectGenNil := GenericNilFits(LGenX, LGenParam);
      if LGenParam then
        FArgNoProcs := True;
    end;
    FNoProcedures := not (FExpectCat in [tcUnknown, tcProc]) or FArgNoProcs or
      FExpectOrdinal or FConstOnly or FExpectEnum or (FCastRef <> tcUnknown) or
      (FCastValue <> tcUnknown) or FExpectAddr or FExpectWith or FExpectRaise;
  end;
  case FContext of
    ccNone:
      Exit(False);
    ccMember:
      if LInfo.DotBase = NIL_NODE then
      begin
        // `procedure TFoo.|Bar;` - an implementation heading's qualifier:
        // the struct's declared routines and nested types (audit E2-48).
        LNode := HeaderQualifierStruct(LInfo);
        if (LNode <> NIL_SYM) and
           (FModel.Symbols[LNode].MemberScope <> NIL_SCOPE) then
        begin
          var LMembers := FModel.Symbols[LNode].MemberScope;
          for var LI := 0 to FModel.Scopes[LMembers].Symbols.Count - 1 do
          begin
            var LMem := FModel.Scopes[LMembers].Symbols[LI];
            if FModel.Symbols[LMem].Kind in [skRoutine, skType] then
              AddSym(-1, LMem, NIL_INST, cbMember);
          end;
        end;
      end
      else
      begin
        LRef := DesignatorType(LInfo.DotBase, 0);
        if ComplValid(LRef) then
        begin
          FClassSide := LRef.IsTypeRef;
          // `@TClass.Method` takes an INSTANCE method's address through the
          // class name (the vtable-building idiom) - the class-side filter
          // stands down under an address-of.
          if FClassSide then
          begin
            LNode := FModel.Tree.NodeLeftmostVis(LInfo.DotBase);   // visible idx
            if (LNode >= 0) and (LNode <= High(FModel.Tree.Source.Visible))
               and (FModel.Tree.Source.Visible[LNode].FileId = 0) then
            begin
              LNode := PrevVisibleRaw(
                FModel.Tree.Source.Visible[LNode].TokenIndex - 1);
              if (LNode >= 0) and
                 (FModel.Tree.Source.Files[0].Tokens[LNode].Kind = tkAt) then
                FClassSide := False;
            end;
          end;
          EnsureAncestry(LInfo.Scope);
          CollectMembers(LRef);
        end
        // `Winapi.|`: a qualifier that is no unit YET, only the head of
        // longer unit names - its list is their next segments.
        else if LRef.PendingUnit <> '' then
          CollectNamespaceChildren(LRef.PendingUnit);
      end;
    ccUses:
      CollectUnitNames;
    ccInherited:
      begin
        // The ancestor of the innermost enclosing struct, instance side -
        // in a method body only (FInhRank).
        EnsureAncestry(LInfo.Scope);
        if FInhRank and (Length(FCaretStructs) > 0) then
        begin
          LRef := OverlayHeritageRef(FCaretStructs[0], 0);
          FBaseOwnUnit := True;
          if LRef.OvSym <> NIL_SYM then
            CollectOverlayChain(LRef.OvSym, True, cbMember)
          else
            CollectProjectMembers(LRef.X, cbMember);
        end;
      end;
    ccLabel:
      CollectLabels(LInfo);
    ccPropRead, ccPropWrite, ccPropStored:
      begin
        // Only this class's (and its ancestors') members are legal after
        // read/write/stored - the struct chain alone, no scope pipeline.
        // The shape filter (fields; functions vs procedures) lives in
        // AddSym, the ranking in AccessorFit.
        EnsureAncestry(LInfo.Scope);
        for LNode := 0 to High(FCaretStructs) do
          CollectOverlayChain(FCaretStructs[LNode], True, cbStructMember);
        if FContext = ccPropStored then
        begin
          AddItem('True', 'true', skKeyword, cbKeyword, -1, NIL_SYM,
            NIL_INST);
          AddItem('False', 'false', skKeyword, cbKeyword, -1, NIL_SYM,
            NIL_INST);
        end;
      end;
    ccRecField:
      begin
        // The enclosing aggregate's record type, fields only.
        LNode := LInfo.Node;
        while (LNode <> NIL_NODE) and
              (FModel.Tree.Nodes[LNode].Kind <> nkAggregate) do
          LNode := FModel.Tree.Nodes[LNode].Parent;
        LRef := AggregateTypeOf(LNode, 0);
        if ComplValid(LRef) then
        begin
          FFieldsOnly := True;
          EnsureAncestry(LInfo.Scope);
          CollectMembers(LRef);
        end;
      end;
  else
    begin
      // A member's start in a type declaration takes keywords alone.
      // `Exit(|` in a procedure takes nothing at all (E2025).
      if not FExitNoValue then
      begin
        if not IsStructMemberStart(LInfo) then
        begin
          EnsureAncestry(LInfo.Scope);
          CollectScope(LInfo);
        end;
        AddContextKeywords(LInfo);
      end;
    end;
  end;
  if XValid(FExpect) or (FExpectOv <> NIL_SYM) or FExpectOrdinal or
     FExpectEnum or (FCastRef <> tcUnknown) or (FCastValue <> tcUnknown) or
     FExpectAddr or FExpectWith or FExpectRaise or
     FTypeRank or FPropRank or FInhRank or FArgIncDec or FArgSetLen or
     FArgAssigned or (FHeritage <> nkError) then
    RankItems;
  if FBuiltinFirst then
    BuiltinTypesFirst;
  SetLength(FItems, FCount);
  AItems := FItems;
  FItems := nil;
  FPendingOverrides := nil;
  FNextSame := nil;
  FParamsOf := nil;
  FParamsKnown := nil;
  FCount := 0;
end;

{ The word of the property specifier (13.1.1) holding ANode, lowercase:
  'read', 'write', 'stored', 'default', 'index', ...; '' outside one. }
function TPasCompletion.PropSpecWordAt(ANode: Integer): string;
begin
  Result := '';
  while (ANode <> NIL_NODE) and
        not (FModel.Tree.Nodes[ANode].Kind in [nkPropSpec, nkPropertyDecl,
          nkBlock, nkInterfaceSec, nkImplementationSec, nkUnit]) do
    ANode := FModel.Tree.Nodes[ANode].Parent;
  if (ANode <> NIL_NODE) and (FModel.Tree.Nodes[ANode].Kind = nkPropSpec) then
    Result := LowerCase(FModel.Tree.Source.VisibleText(
      FModel.Tree.Nodes[ANode].FirstToken));
end;

// The type an overlay type reference ANode names, canonical - or, for a
// type only the buffer declares, its overlay symbol in AOv.
procedure TPasCompletion.TypeNodeXOv(ANode: Integer; out AX: TSemaXType;
  out AOv: Integer);
var
  LRef: TPasComplTypeRef;
begin
  AX := XNil;
  AOv := NIL_SYM;
  if (FProj = nil) or (ANode = NIL_NODE) then
    Exit;
  LRef := ResolveTypeRefNode(ANode, 0);
  AX := LRef.X;
  if not XValid(AX) and (LRef.OvSym <> NIL_SYM) then
  begin
    AX := OwnModelTypeX(LRef.OvSym);
    if not XValid(AX) then
      AOv := LRef.OvSym;
  end;
  if XValid(AX) then
    AX := FProj.CanonTypeX(AX);
end;

{ The property whose accessor the caret is at (13.1.1): its type, its index
  parameters (type and mode per name), `index N`, `class property` - into
  FPropX / FPropOv, FPropIdxX / FPropIdxOv / FPropIdxMode, FPropIndexed,
  FPropClass; FPropRank when a project can type them. A property that
  redeclares an inherited one without a type (`property Foo read |`, 13.1.1)
  takes the inherited property's type - the nearest ancestor's member of
  that name; an inherited ARRAY property leaves FPropX unknown (its index
  parameters are not read from there), as does an ancestor not found. }
procedure TPasCompletion.PropAccessorOf(const AInfo: TPasCaretInfo);
var
  LProp, LKid, LParam, LPart, LNames, LMode, LTypeNode: Integer;
  LX: TSemaXType;
  LOv: Integer;
  LTypeSeen: Boolean;
begin
  if FProj = nil then
    Exit;
  LProp := UpChainNode(AInfo.Node, nkPropertyDecl);
  if LProp = NIL_NODE then
    Exit;
  FPropClass := FModel.Tree.Nodes[LProp].Aux = 1;
  LTypeSeen := False;
  // The name first, then the index parameters, the type and the specifiers
  // (TPasParser.ParseProperty).
  LKid := FModel.Tree.Nodes[LProp].FirstChild;
  if LKid <> NIL_NODE then
    LKid := FModel.Tree.Nodes[LKid].NextSibling;
  while LKid <> NIL_NODE do
  begin
    case FModel.Tree.Nodes[LKid].Kind of
      nkParams:
        begin
          LParam := FModel.Tree.Nodes[LKid].FirstChild;
          while LParam <> NIL_NODE do
          begin
            if nfVar in FModel.Tree.Nodes[LParam].Flags then
              LMode := 2
            else if nfOut in FModel.Tree.Nodes[LParam].Flags then
              LMode := 3
            else if nfConst in FModel.Tree.Nodes[LParam].Flags then
              LMode := 1
            else
              LMode := 0;
            LNames := 0;
            LTypeNode := NIL_NODE;
            LPart := FModel.Tree.Nodes[LParam].FirstChild;
            while LPart <> NIL_NODE do
            begin
              if nfName in FModel.Tree.Nodes[LPart].Flags then
                Inc(LNames)
              else if (FModel.Tree.Nodes[LPart].Kind <> nkAttrGroup) and
                 (LTypeNode = NIL_NODE) then
                LTypeNode := LPart;
              LPart := FModel.Tree.Nodes[LPart].NextSibling;
            end;
            TypeNodeXOv(LTypeNode, LX, LOv);
            for var LI := 1 to LNames do
            begin
              FPropIdxX := FPropIdxX + [LX];
              FPropIdxOv := FPropIdxOv + [LOv];
              FPropIdxMode := FPropIdxMode + [LMode];
            end;
            LParam := FModel.Tree.Nodes[LParam].NextSibling;
          end;
        end;
      nkPropSpec:
        if FModel.Tree.Source.VisibleTextEquals(
             FModel.Tree.Nodes[LKid].FirstToken, 'index') then
          FPropIndexed := True;
    else
      if not LTypeSeen then
      begin
        LTypeSeen := True;
        TypeNodeXOv(LKid, FPropX, FPropOv);
      end;
    end;
    LKid := FModel.Tree.Nodes[LKid].NextSibling;
  end;
  if not LTypeSeen and (Length(FPropIdxX) = 0) then
    InheritedPropType(AInfo, LProp);
  FPropRank := True;
end;

{ The type of the property an ancestor of the caret's struct declares under
  the name of the typeless property declaration AProp - what a redeclaration
  (`property Foo read |`) keeps (13.1.1) - into FPropX / FPropOv. Nothing
  for an array property, nor when no ancestor declares one. }
procedure TPasCompletion.InheritedPropType(const AInfo: TPasCaretInfo;
  AProp: Integer);
var
  LStruct, LName, LMid, LSym, LCtx: Integer;
  LBase, LRef: TPasComplTypeRef;
  LM: TPasSemaModel;
begin
  LName := FModel.Tree.Nodes[AProp].FirstChild;
  if (LName = NIL_NODE) or (FModel.Tree.Nodes[LName].Kind <> nkIdent) then
    Exit;
  LStruct := EnclosingStructSym(AInfo.Scope);
  if LStruct = NIL_SYM then
    Exit;
  LBase := OverlayHeritageRef(LStruct, 0);
  if not ComplValid(LBase) or
     not MemberSymOf(LBase, FModel.Tree.NodeNameLower(LName), 0, LMid, LSym,
       LCtx) or not SymModelOf(LMid, 'InheritedPropType', LM, False) or
     (LM.Symbols[LSym].Kind <> skProperty) then
    Exit;
  if LMid < 0 then
  begin
    if PasPropertyHasParams(FModel.Tree, FModel.Symbols[LSym].DeclNode) then
      Exit;
    LRef := TypeOfOverlaySym(LSym, 0);
  end
  else
  begin
    if FProj.IsArrayPropertySym(LMid, LSym) then
      Exit;
    LRef := TypeOfProjectSym(LMid, LSym, LCtx, 0);
  end;
  FPropX := RefValueX(LRef, FPropOv);
end;

// The declared type of a value, a parameter or a routine's result (Mid -1:
// the overlay's), canonical; AOv for a type only the buffer declares.
function TPasCompletion.ItemValueX(AMid, ASym, ACtx: Integer;
  out AOv: Integer): TSemaXType;
begin
  AOv := NIL_SYM;
  if AMid < 0 then
    Result := RefValueX(TypeOfOverlaySym(ASym, 0), AOv)
  else
  begin
    Result := RefValueX(TypeOfProjectSym(AMid, ASym, ACtx, 0), AOv);
    if not XValid(Result) and (AOv = NIL_SYM) then
    begin
      Result := FProj.DeclTypeX(AMid, ASym);
      if XValid(Result) then
        Result := FProj.CanonTypeX(Result);
    end;
  end;
end;

{ Are two types (each a project type, or a type only the buffer declares)
  the same type - what a property accessor's field, parameter or result
  must be (13.1.1; dcc 37: Byte for Integer is E2010, a getter's E2008)? 1
  yes, -1 no, 0 when either is unknown. }
function TPasCompletion.SameAccType(const AX: TSemaXType; AOv: Integer;
  const BX: TSemaXType; BOv: Integer): Integer;
begin
  if XValid(AX) and XValid(BX) then
  begin
    if FProj.XConvX(BX, AX) = scIdentical then
      Exit(1);
    Exit(-1);
  end;
  if (AOv <> NIL_SYM) and (BOv <> NIL_SYM) then
  begin
    if AOv = BOv then
      Exit(1);
    Exit(-1);
  end;
  // A project type is never one only the buffer declares.
  if (XValid(AX) and (BOv <> NIL_SYM)) or (XValid(BX) and (AOv <> NIL_SYM))
  then
    Exit(-1);
  Result := 0;
end;

// Does a routine's declaration say `static`? A text-demoted model has no
// directive text left: no.
function TPasCompletion.IsStaticRoutine(AModel: TPasSemaModel;
  ASym: Integer): Boolean;
var
  LRoutine, LChild: Integer;
begin
  Result := False;
  if AModel.Demoted then
    Exit;
  LRoutine := RoutineNodeOf(AModel, ASym);
  if LRoutine = NIL_NODE then
    Exit;
  LChild := AModel.Tree.Nodes[LRoutine].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if (AModel.Tree.Nodes[LChild].Kind = nkDirective) and
       AModel.Tree.NodeTextEquals(LChild, 'static') then
      Exit(True);
    LChild := AModel.Tree.Nodes[LChild].NextSibling;
  end;
end;

{ One routine (no overload chain) against the accessor the caret is at
  (13.1.1, each rule dcc 37-probed): a getter takes the index parameters -
  the same types, the same modes - then the `index` specifier's Integer
  (value or const), and returns the property's type; a setter takes the
  same and then the value, of the property's type, by value or const (a
  `var` / `out` one is E2282); a `stored` function takes the `index`
  Integer alone and returns a Boolean. 1 fits, -1 does not, 0 unknown. }
function TPasCompletion.AccessorSigFit(AMid, ASym, ACtx: Integer): Integer;
var
  LM: TPasSemaModel;
  LParams: TArray<Integer>;
  LCount, LIdx, LMode, LOv, LIntMid, LIntSym, LSame: Integer;
  LX, LInt: TSemaXType;
  LUnknown: Boolean;

  procedure Judge(ASame: Integer);
  begin
    if ASame = 0 then
      LUnknown := True;
  end;

begin
  Result := -1;
  if not SymModelOf(AMid, 'AccessorSigFit', LM, False) then
    Exit(0);
  if AMid < 0 then
    LParams := OverlayParams(ASym)
  else
    LParams := FProj.XParamSyms(AMid, ASym);
  LCount := Ord(FPropIndexed);
  if FContext <> ccPropStored then
    Inc(LCount, Length(FPropIdxX));
  if FContext = ccPropWrite then
    Inc(LCount);
  if Length(LParams) <> LCount then
    Exit;
  LUnknown := False;
  LIdx := 0;
  if FContext <> ccPropStored then
    for var LI := 0 to High(FPropIdxX) do
    begin
      LMode := ParamModeOf(LM, LParams[LIdx]);
      if LMode < 0 then
        LUnknown := True
      else if LMode <> FPropIdxMode[LI] then
        Exit;
      LX := ItemValueX(AMid, LParams[LIdx], ACtx, LOv);
      LSame := SameAccType(LX, LOv, FPropIdxX[LI], FPropIdxOv[LI]);
      if LSame < 0 then
        Exit;
      Judge(LSame);
      Inc(LIdx);
    end;
  if FPropIndexed then
  begin
    LMode := ParamModeOf(LM, LParams[LIdx]);
    if LMode > 1 then
      Exit;
    LInt := XNil;
    if BridgeName('integer', LIntMid, LIntSym) then
      LInt := FProj.CanonTypeX(XPlain(LIntMid, LIntSym));
    LX := ItemValueX(AMid, LParams[LIdx], ACtx, LOv);
    LSame := SameAccType(LX, LOv, LInt, NIL_SYM);
    if LSame < 0 then
      Exit;
    Judge(LSame);
    Inc(LIdx);
  end;
  case FContext of
    ccPropWrite:
      begin
        LMode := ParamModeOf(LM, LParams[LIdx]);
        if LMode > 1 then
          Exit;
        LX := ItemValueX(AMid, LParams[LIdx], ACtx, LOv);
        LSame := SameAccType(LX, LOv, FPropX, FPropOv);
        if LSame < 0 then
          Exit;
        Judge(LSame);
      end;
    ccPropRead:
      begin
        LX := ItemValueX(AMid, ASym, ACtx, LOv);
        LSame := SameAccType(LX, LOv, FPropX, FPropOv);
        if LSame < 0 then
          Exit;
        Judge(LSame);
      end;
    ccPropStored:
      begin
        LX := ItemValueX(AMid, ASym, ACtx, LOv);
        if XValid(LX) then
        begin
          if FProj.XCatOf(LX) <> tcBoolean then
            Exit;
        end
        else if (LOv = NIL_SYM) or
           (FModel.Symbols[LOv].TypeCat <> tcBoolean) then
          LUnknown := True;
      end;
  end;
  if LUnknown then
    Result := 0
  else
    Result := 1;
end;

{ One member against the property accessor the caret is at: the accessor's
  exact signature is fit 0 (a field of the property's type, a getter, a
  setter, a Boolean for `stored`, `True` / `False` there); a record field
  leads (`read FRec.X` - dcc takes a path through records); a member of
  the right shape and another type, or one on the wrong side - a class var
  or a static class method for an instance property (E2356), anything but
  a class var or a static class method for a class property (E2355) - is
  fit 3. A member whose types cannot be read leads. }
function TPasCompletion.AccessorFit(const AItem: TPasComplItem):
  TPasComplMatch;
var
  LM: TPasSemaModel;
  LX: TSemaXType;
  LOv, LSym, LBest, LFit: Integer;
  LClass: Boolean;
  LCat: TSemaTypeCat;
begin
  if AItem.Bucket = cbKeyword then
  begin
    if (FContext = ccPropStored) and (SameText(AItem.Name, 'True') or
       SameText(AItem.Name, 'False')) then
      Exit(cmExact);
    Exit(cmOther);
  end;
  if (AItem.Sym = NIL_SYM) or
     not SymModelOf(AItem.Mid, 'AccessorFit', LM, False) then
    Exit(cmLeads);
  LClass := ClassSideMember(LM, AItem.Sym);
  case LM.Symbols[AItem.Sym].Kind of
    skField, skVar:
      begin
        if LClass <> FPropClass then
          Exit(cmOther);
        // An array property reads and writes through methods alone (E2008;
        // `index N` with a field compiles).
        if (Length(FPropIdxX) > 0) and (FContext <> ccPropStored) then
          Exit(cmOther);
        LX := ItemValueX(AItem.Mid, AItem.Sym, AItem.Ctx, LOv);
        if XValid(LX) then
          LCat := FProj.XCatOf(LX)
        else if LOv <> NIL_SYM then
          LCat := FModel.Symbols[LOv].TypeCat
        else
          Exit(cmLeads);
        if FContext = ccPropStored then
        begin
          if LCat = tcBoolean then
            Exit(cmExact);
          if LCat = tcRecord then
            Exit(cmLeads);
          Exit(cmOther);
        end;
        case SameAccType(LX, LOv, FPropX, FPropOv) of
          1:
            Exit(cmExact);
          0:
            Exit(cmLeads);
        end;
        if LCat = tcRecord then
          Exit(cmLeads);
        Exit(cmOther);
      end;
    skRoutine:
      begin
        // An instance property takes a non-static class method too (dcc 37
        // accepts `read CF` for a `class function CF`).
        if FPropClass <> (LClass and IsStaticRoutine(LM, AItem.Sym)) then
          Exit(cmOther);
        LBest := -1;
        LSym := AItem.Sym;
        for var LHop := 1 to 64 do
        begin
          if (LSym = NIL_SYM) or (LM.Symbols[LSym].Kind <> skRoutine) then
            Break;
          LFit := AccessorSigFit(AItem.Mid, LSym, AItem.Ctx);
          if LFit > 0 then
            Exit(cmExact);
          if LFit = 0 then
            LBest := 0;
          LSym := LM.Symbols[LSym].NextOverload;
        end;
        if LBest = 0 then
          Exit(cmLeads);
        Exit(cmOther);
      end;
  end;
  Result := cmOther;
end;

{ The name of the method whose body AScope (MethodBodyScope's answer) is,
  lowercase: `Create` of `constructor TFoo.Create`. }
function TPasCompletion.InheritedMethodName(AScope: Integer): string;
var
  LNode, LName: Integer;
begin
  Result := '';
  LNode := FModel.Scopes[AScope].OwnerNode;
  if (LNode = NIL_NODE) or (FModel.Tree.Nodes[LNode].Kind <> nkRoutine) then
    Exit;
  // Each segment of `TFoo.Bar` is a name child (TPasParser.ParseRoutine):
  // the last one is the method's.
  LNode := FModel.Tree.Nodes[LNode].FirstChild;
  LName := NIL_NODE;
  while LNode <> NIL_NODE do
  begin
    if nfName in FModel.Tree.Nodes[LNode].Flags then
      LName := LNode;
    LNode := FModel.Tree.Nodes[LNode].NextSibling;
  end;
  if (LName <> NIL_NODE) and (FModel.Tree.Nodes[LName].Kind = nkIdent) then
    Result := FModel.Tree.NodeNameLower(LName);
end;

function TPasCompletion.EnclosingStructSym(AScope: Integer): Integer;
begin
  Result := FModel.EnclosingStructSymOfScope(AScope);
end;

{ The routine scope of the method whose body holds AScope - the innermost
  routine scope on the chain that names its struct, past nested routines and
  anonymous methods - or NIL_SCOPE outside every method body: unit level, a
  main block, a struct's declaration. }
function TPasCompletion.MethodBodyScope(AScope: Integer): Integer;
begin
  while AScope <> NIL_SCOPE do
  begin
    case FModel.Scopes[AScope].Kind of
      sckRoutine:
        if FModel.Scopes[AScope].StructSym <> NIL_SYM then
          Exit(AScope);
      sckStruct, sckUnit, sckImplementation:
        Break;
    end;
    AScope := FModel.Scopes[AScope].Parent;
  end;
  Result := NIL_SCOPE;
end;

{ Does the method of AMethodScope have `Self` (3.3.2's body rule): an
  instance method, a constructor, a non-static class method do; a `class
  ... static` one does not, and only its declaration says `static` - the
  implementation heading never repeats it, so the struct's same-named class
  routine is asked. }
function TPasCompletion.MethodHasSelf(AMethodScope: Integer): Boolean;
var
  LRoutine, LChild, LName, LMembers, LDecl, LDeclRoutine: Integer;
begin
  Result := True;
  LRoutine := FModel.Scopes[AMethodScope].OwnerNode;
  if (LRoutine = NIL_NODE) or
     (FModel.Tree.Nodes[LRoutine].Kind <> nkRoutine) or
     (FModel.Tree.Nodes[LRoutine].Aux <> 1) then
    Exit;
  LName := NIL_NODE;
  LChild := FModel.Tree.Nodes[LRoutine].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if nfName in FModel.Tree.Nodes[LChild].Flags then
      LName := LChild
    else if FModel.Tree.Nodes[LChild].Kind = nkDirective then
      if FModel.Tree.NodeTextEquals(LChild, 'static') then
        Exit(False);
    LChild := FModel.Tree.Nodes[LChild].NextSibling;
  end;
  LMembers := FModel.Symbols[FModel.Scopes[AMethodScope].StructSym].MemberScope;
  if (LName = NIL_NODE) or (LMembers = NIL_SCOPE) then
    Exit;
  LDecl := FModel.FindLocal(LMembers, FModel.Tree.NodeNameLower(LName));
  while LDecl <> NIL_SYM do
  begin
    LDeclRoutine := RoutineNodeOf(FModel, LDecl);
    if (LDeclRoutine <> NIL_NODE) and (LDeclRoutine <> LRoutine) and
       (FModel.Tree.Nodes[LDeclRoutine].Aux = 1) then
    begin
      LChild := FModel.Tree.Nodes[LDeclRoutine].FirstChild;
      while LChild <> NIL_NODE do
      begin
        if (FModel.Tree.Nodes[LChild].Kind = nkDirective) and
           FModel.Tree.NodeTextEquals(LChild, 'static') then
          Exit(False);
        LChild := FModel.Tree.Nodes[LChild].NextSibling;
      end;
    end;
    LDecl := FModel.Symbols[LDecl].NextOverload;
  end;
end;

{ The type of an instance method's `Self` in the last-good project: the
  enclosing struct (FSelfOv), or a helper's extended type - Self in a
  `record helper for string` method is a string. XNil when the struct is
  one only the buffer declares. }
function TPasCompletion.SelfTypeX: TSemaXType;
var
  LExt: TSemaXType;
begin
  Result := OwnModelTypeX(FSelfOv);
  if not XValid(Result) then
    Exit;
  LExt := FProj.HelperTargetX(Result.UnitId, Result.Sym);
  if XValid(LExt) then
    Result := LExt;
  Result := FProj.CanonTypeX(Result);
end;

function TPasCompletion.IsSelfItem(const AItem: TPasComplItem): Boolean;
begin
  Result := (AItem.Sym = NIL_SYM) and (AItem.Bucket = cbLocal) and
    (AItem.Kind = skParam) and (FSelfOv <> NIL_SYM) and
    SameText(AItem.Name, 'Self');
end;

function TPasCompletion.SelfTypeText: string;
var
  LX: TSemaXType;
  LParams: TArray<Integer>;
  LIdent: Integer;
  LNames: string;
begin
  Result := '';
  if FSelfOv = NIL_SYM then
    Exit;
  if FSelfClass then
    LX := OwnModelTypeX(FSelfOv)
  else
    LX := SelfTypeX;
  if XValid(LX) then
    Result := FProj.XTypeText(LX);
  if Result = '' then
    Result := FModel.Symbols[FSelfOv].Name;
  // Inside a generic Self is the open type, `TBox<T>`: the declaration's
  // own parameters, which the project's text of the plain type leaves out.
  // (A helper, the one Self of another type, is never generic.)
  LParams := TPasSemaProject.GenericParamIdentsOf(FModel, FSelfOv);
  if (LParams <> nil) and not Result.Contains('<') then
  begin
    LNames := '';
    for LIdent in LParams do
    begin
      if LNames <> '' then
        LNames := LNames + ', ';
      LNames := LNames + FModel.Tree.NodeText(LIdent);
    end;
    Result := Result + '<' + LNames + '>';
  end;
  if FSelfClass then
    Result := 'class of ' + Result;
end;

end.
