unit S065A;
interface
type
  TProbe = class end;
implementation
var G: Integer;
initialization
{$IF Declared(TProbe)}
  G := 1;
{$ELSE}
  G := 2;
{$IFEND}
  if G <> 1 then Halt(3);
end.
