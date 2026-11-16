unit S052A;
interface
type
  TRow = class
  private
    FCells: array[0..3] of Integer;
    function GetCell(I: Integer): Integer;
    procedure SetCell(I, V: Integer);
  public
    property Cells[I: Integer]: Integer read GetCell write SetCell; default;
  end;
implementation
function TRow.GetCell(I: Integer): Integer; begin Result := FCells[I]; end;
procedure TRow.SetCell(I, V: Integer); begin FCells[I] := V; end;
var R: TRow;
initialization
  R := TRow.Create;
  R[1] := 7;
  if R[1] <> 7 then Halt(3);
  R.Free;
end.
