unit S101A;
interface
implementation
{$DEFINE S101_ON}
var G: Integer;
procedure Trace; begin G := 1; end;
initialization
{$IFDEF S101_ON}
  Trace;
{$ENDIF}
  if G <> 1 then Halt(3);
end.
