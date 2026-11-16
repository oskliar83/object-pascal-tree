unit S111A;
interface
implementation
var G: Integer;
procedure Go; overload; begin G := 1; end;
procedure Go(A: Integer; B: Integer = 0); overload; begin G := 2; end;
initialization
  Go(5);
  if G <> 2 then Halt(3);
end.
