unit S019A;
interface
uses Winapi.Messages;
const UM_PING = WM_USER + 1;
type
  TPinger = class
    procedure UMPing(var M: TMessage); message UM_PING;
  end;
var GPinged: Boolean;
implementation
procedure TPinger.UMPing(var M: TMessage); begin GPinged := True; end;
var M: TMessage;
initialization
  M.Msg := UM_PING;
  with TPinger.Create do begin Dispatch(M); Free; end;
  if not GPinged then Halt(3);
end.
