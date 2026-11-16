unit S084B;
interface
uses Vcl.Forms, S084A;
type
  TS084Child = class(TS084Base)
  end;
implementation
{$R *.dfm}
var F: TS084Child;
initialization
  F := TS084Child.Create(nil);
  F.Btn.Click;
  F.Free;
  if not GClicked then Halt(3);
end.
