unit S086B;
interface
uses System.Classes, Vcl.Forms, Vcl.StdCtrls, S086A;
type
  TS086Child = class(TS086Base)
    Note: TLabel;
  end;
implementation
{$R *.dfm}
initialization
  TS086Child.Create(nil).Free;
end.
