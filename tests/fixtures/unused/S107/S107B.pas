unit S107B;
interface
implementation
uses S107A;
var G: Integer;
initialization
{$IF CFeature}
  G := 1;
{$IFEND}
  if G <> 1 then Halt(3);
end.
