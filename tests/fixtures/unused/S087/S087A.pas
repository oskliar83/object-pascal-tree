unit S087A;
interface
uses Vcl.Forms;
type
  TS087Form = class(TForm)
  end;
  TOptions = class
    Width: Integer;
    procedure Apply;
    procedure Load;
  end;
implementation
{$R *.dfm}
procedure TOptions.Apply; begin end;
procedure TOptions.Load; begin end;
initialization
  TS087Form.Create(nil).Free;
  with TOptions.Create do begin Load; Free; end;
end.
