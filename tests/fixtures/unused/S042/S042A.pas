unit S042A;
interface
type
  TPair<T> = record
    A, B: T;
    class operator Equal(const L, R: TPair<T>): Boolean;
    class operator NotEqual(const L, R: TPair<T>): Boolean;
  end;
implementation
uses System.Generics.Defaults;
class operator TPair<T>.Equal(const L, R: TPair<T>): Boolean;
begin
  Result := TEqualityComparer<T>.Default.Equals(L.A, R.A) and TEqualityComparer<T>.Default.Equals(L.B, R.B);
end;
class operator TPair<T>.NotEqual(const L, R: TPair<T>): Boolean; begin Result := not (L = R); end;
var X, Y: TPair<Integer>;
initialization
  X.A := 1; X.B := 2; Y := X;
  if not (X = Y) then Halt(3);
end.
