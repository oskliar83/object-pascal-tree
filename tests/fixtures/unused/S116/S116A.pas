unit S116A;
interface
implementation
var G: Integer;
procedure Mark; begin G := 1; end;
procedure Run; assembler;
asm
  call Mark
end;
initialization
  Run;
  if G <> 1 then Halt(3);
end.
