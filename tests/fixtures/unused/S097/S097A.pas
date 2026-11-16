unit S097A;
interface
uses System.Classes, Vcl.Forms;
type
  TS097Form = class(TForm)
    procedure Cmd_Save(Sender: TObject);
  end;
var GSaved: Boolean;
implementation
{$R *.dfm}
procedure TS097Form.Cmd_Save(Sender: TObject); begin GSaved := True; end;
var F: TS097Form; M: TMethod;
initialization
  F := TS097Form.Create(nil);
  M.Code := F.MethodAddress('Cmd_' + 'Save');
  M.Data := F;
  if M.Code <> nil then TNotifyEvent(M)(nil);
  F.Free;
  if not GSaved then Halt(3);
end.
