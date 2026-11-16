unit S032A;
interface
uses System.SysUtils;
implementation
var GHook: TProc;
procedure Install; begin GHook := procedure begin end; end;
initialization
  Install;
end.
