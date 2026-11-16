unit S021A;
interface
type
  IFoo = interface
    ['{4D3A0B5E-1C2F-4E6A-9B70-0A1B2C3D4E01}']
    procedure Bar;
  end;
  TFooImpl = class(TInterfacedObject, IFoo)
    procedure Bar;
  end;
  TOuter = class(TInterfacedObject, IFoo)
  private
    FImpl: IFoo;
  public
    constructor Create;
    property Impl: IFoo read FImpl implements IFoo;
  end;
var GBar: Boolean;
implementation
procedure TFooImpl.Bar; begin GBar := True; end;
constructor TOuter.Create; begin inherited Create; FImpl := TFooImpl.Create; end;
var F: IFoo;
initialization
  F := TOuter.Create;
  F.Bar;
  if not GBar then Halt(3);
end.
