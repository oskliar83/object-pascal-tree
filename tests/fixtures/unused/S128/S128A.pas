unit S128A;
interface
uses System.Classes;
type
  THost = class
    procedure Handler(Sender: TObject);
  end;
implementation
procedure THost.Handler(Sender: TObject); begin end;
var H: THost; E: TNotifyEvent;
initialization
  H := THost.Create;
  E := nil;
  if TMethod(E).Code = @THost.Handler then Halt(3);
  H.Free;
end.
