unit S109A;
interface
implementation
var G: Integer;
procedure Put(A: Integer); overload; begin G := 1; end;
procedure Put(A: Int64); overload; begin G := 2; end;
initialization
  Put(1);
  if G <> 1 then Halt(3);
end.
