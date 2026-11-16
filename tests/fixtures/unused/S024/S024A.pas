unit S024A;
interface
type
  IShape = interface
    ['{4D3A0B5E-1C2F-4E6A-9B70-0A1B2C3D4E03}']
    procedure Draw;
    procedure Erase;
  end;
  TBox = class(TInterfacedObject, IShape)
    procedure Draw;
    procedure Erase;
  end;
var GDrawn: Boolean;
implementation
procedure TBox.Draw; begin GDrawn := True; end;
procedure TBox.Erase; begin end;
var S: IShape;
initialization
  S := TBox.Create;
  S.Draw;
  if not GDrawn then Halt(3);
end.
