unit S102A;
interface
implementation
var G: Integer;
procedure Trace; begin G := 1; end;
initialization
  {$I S102.inc}
  if G <> 1 then Halt(3);
end.
