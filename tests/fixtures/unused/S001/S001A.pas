unit S001A;
interface
type
  TBase = class
    procedure Hidden;
    procedure Spare;
  end;
  TDerived = class(TBase)
    procedure Hidden;
  end;
implementation
var G: Integer;
procedure TBase.Hidden; begin Inc(G); end;
procedure TBase.Spare; begin end;
procedure TDerived.Hidden; begin inherited; end;
initialization
  with TDerived.Create do begin Hidden; Free; end;
  if G <> 1 then Halt(3);
end.
