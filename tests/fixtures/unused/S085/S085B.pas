unit S085B;
interface
uses System.Classes, Vcl.Forms, S085A;
type
  TS085Child = class(TS085Base)
    procedure ChildClick(Sender: TObject);
  end;
var GClicked: Boolean;
implementation
{$R *.dfm}
procedure TS085Child.ChildClick(Sender: TObject); begin GClicked := True; end;
var F: TS085Child;
initialization
  F := TS085Child.Create(nil);
  F.Btn.Click;
  F.Free;
  if not GClicked then Halt(3);
end.
