unit S053A;
interface
type
  TCfg = class
    Level: Integer;
    Spare: Integer;
  end;
implementation
var C: TCfg; L: Integer;
initialization
  C := TCfg.Create;
  with C do L := Level;
  if L <> 0 then Halt(3);
  C.Free;
end.
