unit S093A;
interface
uses System.Classes, Vcl.Forms;
type
  TS093Form = class(TForm)
  private
    FLevel: Integer;
  published
    property Level: Integer read FLevel write FLevel;
  public
    function LevelValue: Integer;
  end;
implementation
{$R *.dfm}
function TS093Form.LevelValue: Integer; begin Result := FLevel; end;
var F: TS093Form;
initialization
  F := TS093Form.Create(nil);
  if F.LevelValue <> 3 then Halt(3);
  F.Free;
end.
