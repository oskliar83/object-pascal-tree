unit S027A;
interface
uses System.SysUtils;
type
  IPrint = interface
    ['{4D3A0B5E-1C2F-4E6A-9B70-0A1B2C3D4E05}']
    procedure Print;
  end;
  TPage = class(TInterfacedObject, IPrint)
    procedure Print;
  end;
var GPrinted: Boolean;
implementation
procedure TPage.Print; begin GPrinted := True; end;
var U: IInterface; P: IPrint;
initialization
  U := TPage.Create;
  if Supports(U, IPrint, P) then P.Print;
  if not GPrinted then Halt(3);
end.
