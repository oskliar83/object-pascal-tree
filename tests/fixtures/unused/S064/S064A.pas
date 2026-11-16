unit S064A;
interface
const
  CLevel = 3;
implementation
var G: Integer;
initialization
{$IF CLevel < 2}
  G := 2;
{$ELSE}
  G := 1;
{$IFEND}
  if G <> 1 then Halt(3);
end.
