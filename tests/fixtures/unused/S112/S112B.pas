unit S112B;
interface
implementation
uses S112A;
function Value: Integer; begin Result := 2; end;
initialization
  if S112A.Value <> 1 then Halt(3);
end.
