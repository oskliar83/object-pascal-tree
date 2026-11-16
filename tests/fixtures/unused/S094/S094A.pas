unit S094A;
interface
uses System.Classes, Vcl.Forms, Vcl.StdCtrls;
type
  TS094Form = class(TForm)
    Edit2: TEdit;
  private
    Edit1: TEdit;
  end;
implementation
{$R *.dfm}
var F: TS094Form;
initialization
  F := TS094Form.Create(nil);
  if F.Edit2 = nil then Halt(3);
  F.Free;
end.
