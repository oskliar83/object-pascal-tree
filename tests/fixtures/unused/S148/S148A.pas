unit S148A;
interface
implementation
type
  TPair2 = record A, B: Integer; end;
function Sum: Integer;
const CP: TPair2 = (A: 1; B: 2);
begin
  Result := CP.A + CP.B;
end;
initialization
  if Sum <> 3 then Halt(3);
end.
