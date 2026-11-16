unit S127A;
interface
type
  IClose = interface
    ['{4D3A0B5E-1C2F-4E6A-9B70-0A1B2C3D4E09}']
    procedure Close;
  end;
  TBaseFile = class(TInterfacedObject)
  public
    procedure Close;
  end;
  TFile2 = class(TBaseFile, IClose)
  end;
var GClosed: Boolean;
implementation
procedure TBaseFile.Close; begin GClosed := True; end;
var C: IClose;
initialization
  C := TFile2.Create;
  C.Close;
  if not GClosed then Halt(3);
end.
