unit S129A;
interface
implementation
type
  TTmp = record A: Integer; end;
procedure Work; var T: TTmp; begin T.A := 1; if T.A <> 1 then Halt(3); end;
initialization
  Work;
end.
