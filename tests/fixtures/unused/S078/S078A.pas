unit S078A;
interface
implementation
function Fact(N: Integer): Int64; begin if N < 2 then Result := 1 else Result := N * Fact(N - 1); end;
end.
