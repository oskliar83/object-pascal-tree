unit S054A;
interface
implementation
var
  Raw: Cardinal;
  Signed: Integer absolute Raw;
initialization
  Signed := -1;
  if Signed <> -1 then Halt(3);
end.
