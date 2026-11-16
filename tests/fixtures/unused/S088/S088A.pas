unit S088A;
interface
type
{$M+}
  TScript = class
    procedure Ping;
    procedure Pong;
  end;
{$M-}
var GPinged: Boolean;
implementation
procedure TScript.Ping; begin GPinged := True; end;
procedure TScript.Pong; begin end;
type TProc0 = procedure of object;
var S: TScript; M: TMethod;
initialization
  S := TScript.Create;
  M.Code := S.MethodAddress('Ping');
  M.Data := S;
  if M.Code <> nil then TProc0(M)();
  S.Free;
  if not GPinged then Halt(3);
end.
