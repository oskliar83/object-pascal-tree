unit S100A;
interface
implementation
procedure Trace; begin end;
initialization
{$IFDEF S100_NEVER}
  Trace;
{$ENDIF}
end.
