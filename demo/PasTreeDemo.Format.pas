unit PasTreeDemo.Format;

{
  PasTree demo - the text arithmetic behind Format and Format Selection.

  PasFormatEdits (PasTree.Format) returns a minimal edit list over the
  buffer's text: ascending, non-overlapping, each one replacing a whitespace
  gap between two tokens. The form applies that list to the SynEdit buffer;
  what it needs around that - which edits a selection keeps, where the caret
  goes, offset <-> line/column - is here, apart from SynEdit, so that
  DemoSettingsSmoke can check it without a window.
}

interface

uses
  PasTree.Format;

{ The 0-based offset of the first character of each line of ASource (line 1
  at index 0). A line ends after #13#10, a lone #10 or a lone #13 - the
  breaks SynEdit splits a buffer on. }
function LineStartsOf(const ASource: string): TArray<Integer>;

{ AOffset (0-based) as a 1-based line and a 1-based character column. }
procedure OffsetToLineCol(const AStarts: TArray<Integer>; AOffset: Integer;
  out ALine, ACol: Integer);

{ The edits of AEdits that lay out lines AFirstLine..ALastLine (1-based) of
  the text AStarts was taken from. F1 has no range mode in the library, so
  Format Selection filters the whole file's list here.

  An edit is kept when the token AFTER its gap - offset Start + Len - lies on
  a selected line, not when the gap starts there: the indentation of a line
  is the tail of the gap that starts at the end of the line above, so the
  first selected line is laid out and the line after the selection is not.
  The kept gap may begin above the selection (trailing blanks, blank lines
  over the cap) - whitespace only, never a token outside it. }
function EditsForLines(const AStarts: TArray<Integer>;
  const AEdits: TPasTextEdits; AFirstLine, ALastLine: Integer): TPasTextEdits;

{ Where offset AOffset of the text before AEdits lands after them: shifted by
  every edit before it; inside a gap, onto the token that follows the gap (a
  caret in a line's indentation stays in front of the line's first token). }
function OffsetAfterEdits(const AEdits: TPasTextEdits;
  AOffset: Integer): Integer;

implementation

function LineStartsOf(const ASource: string): TArray<Integer>;
var
  LCount, LIdx, LLen: Integer;
begin
  LLen := Length(ASource);
  SetLength(Result, 16);
  Result[0] := 0;
  LCount := 1;
  LIdx := 1;
  while LIdx <= LLen do
  begin
    if (ASource[LIdx] = #13) or (ASource[LIdx] = #10) then
    begin
      if (ASource[LIdx] = #13) and (LIdx < LLen) and
         (ASource[LIdx + 1] = #10) then
        Inc(LIdx);
      if LCount = Length(Result) then
        SetLength(Result, LCount * 2);
      Result[LCount] := LIdx;   // 0-based offset of the next character
      Inc(LCount);
    end;
    Inc(LIdx);
  end;
  SetLength(Result, LCount);
end;

procedure OffsetToLineCol(const AStarts: TArray<Integer>; AOffset: Integer;
  out ALine, ACol: Integer);
var
  LLo, LHi, LMid: Integer;
begin
  // The last line start at or before AOffset.
  LLo := 0;
  LHi := High(AStarts);
  while LLo < LHi do
  begin
    LMid := (LLo + LHi + 1) div 2;
    if AStarts[LMid] <= AOffset then
      LLo := LMid
    else
      LHi := LMid - 1;
  end;
  ALine := LLo + 1;
  ACol := AOffset - AStarts[LLo] + 1;
end;

function EditsForLines(const AStarts: TArray<Integer>;
  const AEdits: TPasTextEdits; AFirstLine, ALastLine: Integer): TPasTextEdits;
var
  LIdx, LCount, LLine, LCol: Integer;
begin
  SetLength(Result, Length(AEdits));
  LCount := 0;
  for LIdx := 0 to High(AEdits) do
  begin
    OffsetToLineCol(AStarts, AEdits[LIdx].Start + AEdits[LIdx].Len, LLine,
      LCol);
    if (LLine >= AFirstLine) and (LLine <= ALastLine) then
    begin
      Result[LCount] := AEdits[LIdx];
      Inc(LCount);
    end;
  end;
  SetLength(Result, LCount);
end;

function OffsetAfterEdits(const AEdits: TPasTextEdits;
  AOffset: Integer): Integer;
var
  LDelta, LIdx: Integer;
begin
  LDelta := 0;
  for LIdx := 0 to High(AEdits) do
  begin
    if AEdits[LIdx].Start + AEdits[LIdx].Len <= AOffset then
      Inc(LDelta, Length(AEdits[LIdx].Text) - AEdits[LIdx].Len)
    else if AEdits[LIdx].Start < AOffset then
      Exit(AEdits[LIdx].Start + LDelta + Length(AEdits[LIdx].Text))
    else
      Break;
  end;
  Result := AOffset + LDelta;
end;

end.
