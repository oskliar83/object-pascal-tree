unit S110A;
interface
implementation
procedure Show(const S: string); overload; begin end;
procedure Show(A: Integer); overload; begin end;
initialization
  Show(1);
end.
