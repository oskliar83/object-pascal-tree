unit S118A;
interface
uses System.SysUtils;
implementation
var G: Integer;
procedure Bump; begin Inc(G); end;
var P: TProc;
initialization
  P := procedure begin Bump; end;
  P();
  if G <> 1 then Halt(3);
end.
