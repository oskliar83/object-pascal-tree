unit S020A;
interface
uses Winapi.Messages;
type
  TPinger = class
    procedure DefaultHandler(var Message); override;
    procedure UMPing(var M: TMessage); message WM_USER + 7;
  end;
var GDefault, GHandled: Boolean;
implementation
procedure TPinger.DefaultHandler(var Message); begin GDefault := True; end;
procedure TPinger.UMPing(var M: TMessage); begin GHandled := True; inherited; end;
var M: TMessage;
initialization
  M.Msg := WM_USER + 7;
  with TPinger.Create do begin Dispatch(M); Free; end;
  if not (GDefault and GHandled) then Halt(3);
end.
