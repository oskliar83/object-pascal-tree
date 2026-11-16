unit S029A;
interface
type
  IBase = interface
    ['{4D3A0B5E-1C2F-4E6A-9B70-0A1B2C3D4E07}']
    procedure Ping;
  end;
  IChild = interface(IBase)
    ['{4D3A0B5E-1C2F-4E6A-9B70-0A1B2C3D4E08}']
    procedure Pong;
  end;
  TBoth = class(TInterfacedObject, IChild)
    procedure Ping;
    procedure Pong;
  end;
var GPing: Boolean;
implementation
procedure TBoth.Ping; begin GPing := True; end;
procedure TBoth.Pong; begin end;
var C: IChild;
initialization
  C := TBoth.Create;
  C.Ping;
  C.Pong;
  if not GPing then Halt(3);
end.
