unit S084A;
interface
uses System.Classes, Vcl.Forms, Vcl.StdCtrls;
type
  TS084Base = class(TForm)
    Btn: TButton;
    procedure BtnClick(Sender: TObject);
    procedure Unbound(Sender: TObject);
  end;
var GClicked: Boolean;
implementation
{$R *.dfm}
procedure TS084Base.BtnClick(Sender: TObject); begin GClicked := True; end;
procedure TS084Base.Unbound(Sender: TObject); begin end;
end.
