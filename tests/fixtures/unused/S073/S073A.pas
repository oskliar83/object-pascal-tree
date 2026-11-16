unit S073A;
interface
uses Vcl.Forms;
type
  TS073Form = class(TForm)
  end;
  TCacheItem = class
    Key: Integer;
  end;
  TCache = class
    Item: TCacheItem;
  end;
var S073Form: TS073Form;
implementation
{$R *.dfm}
initialization
  S073Form := TS073Form.Create(nil);
  S073Form.Free;
end.
