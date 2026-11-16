unit S098A;
interface
uses Vcl.Forms;
type
  TS098Form = class(TForm)
  private
    FDirty: Boolean;
    procedure Recalc;
  end;
implementation
{$R *.dfm}
procedure TS098Form.Recalc; begin end;
initialization
  TS098Form.Create(nil).Free;
end.
