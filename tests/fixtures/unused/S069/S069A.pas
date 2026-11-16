unit S069A;
interface
procedure Outer;
implementation
procedure Outer;
  procedure Inner; begin end;
  procedure Used; begin end;
begin
  Used;
end;
initialization
  Outer;
end.
