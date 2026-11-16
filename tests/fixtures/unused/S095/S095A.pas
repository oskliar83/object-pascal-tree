unit S095A;
interface
uses System.Classes, Vcl.Forms, Vcl.StdCtrls;
type
  TS095Form = class(TForm)
    Edit1: TEdit;
    Edit2: TEdit;
    Lbl: TLabel;
  end;
implementation
{$R *.dfm}
var F: TS095Form;
initialization
  F := TS095Form.Create(nil);
  if F.Lbl.FocusControl = nil then Halt(3);
  if F.Edit2 = nil then Halt(4);
  F.Free;
end.
