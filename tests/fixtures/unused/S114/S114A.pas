unit S114A;
interface
type
  TCount = Integer;
  TId = type Integer;
  TAge = type Integer;
implementation
var A: TAge;
initialization
  A := 3;
  if A <> 3 then Halt(3);
end.
