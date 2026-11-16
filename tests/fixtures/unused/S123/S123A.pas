unit S123A;
interface
type
  TMath2 = class
    class function Twice(A: Integer): Integer; static;
  end;
implementation
class function TMath2.Twice(A: Integer): Integer; begin Result := A * 2; end;
var M: TMath2;
initialization
  M := nil;
  if M.Twice(2) <> 4 then Halt(3);
end.
