unit S031A;
interface
implementation
var G: Integer;
procedure One; begin G := 1; end;
procedure Two; begin G := 2; end;
procedure Three; begin G := 3; end;
type TProc0 = procedure;
const CTable: array[0..1] of TProc0 = (One, Two);
initialization
  CTable[0];
  if G = 0 then Halt(3);
end.
