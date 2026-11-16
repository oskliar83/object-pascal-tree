unit S068A;
interface
implementation
threadvar
  TCount: Integer;
  TLive: Integer;
initialization
  TLive := 1;
  if TLive <> 1 then Halt(3);
end.
