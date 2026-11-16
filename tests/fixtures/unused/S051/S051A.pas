unit S051A;
interface
type
  TMoney = record
    Cents: Int64;
    class operator Implicit(A: Integer): TMoney;
    class operator Implicit(A: TMoney): Double;
    class operator Add(const A, B: TMoney): TMoney;
    class operator Subtract(const A, B: TMoney): TMoney;
  end;
implementation
class operator TMoney.Implicit(A: Integer): TMoney; begin Result.Cents := A * 100; end;
class operator TMoney.Implicit(A: TMoney): Double; begin Result := A.Cents / 100; end;
class operator TMoney.Add(const A, B: TMoney): TMoney; begin Result.Cents := A.Cents + B.Cents; end;
class operator TMoney.Subtract(const A, B: TMoney): TMoney; begin Result.Cents := A.Cents - B.Cents; end;
var M, N: TMoney;
initialization
  M := 5;
  N := M + M;
  if N.Cents <> 1000 then Halt(3);
end.
