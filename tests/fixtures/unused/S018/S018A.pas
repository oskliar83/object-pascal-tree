unit S018A;
interface
type
  TOwner = class
  private
    FValue: Integer;
    function Peek: Integer;
  public
    procedure Live;
  end;
implementation
function TOwner.Peek: Integer; begin Result := FValue; end;
procedure TOwner.Live; begin end;
initialization
  with TOwner.Create do begin Live; Free; end;
end.
