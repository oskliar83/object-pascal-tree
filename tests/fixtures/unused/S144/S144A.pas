unit S144A;
interface
uses System.Classes;
type
  TSrc = class
  private
    FOnDone: TNotifyEvent;
  public
    property OnDone: TNotifyEvent read FOnDone write FOnDone;
  end;
implementation
var S: TSrc;
initialization
  S := TSrc.Create;
  if Assigned(S.OnDone) then Halt(3);
  S.Free;
end.
