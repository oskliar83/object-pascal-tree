unit S075A;
interface
type
  TItem = class
  private
    FName: string;
    function GetName: string;
  public
    property Name: string read GetName;
    procedure Touch;
  end;
implementation
function TItem.GetName: string; begin Result := FName; end;
procedure TItem.Touch; begin end;
initialization
  with TItem.Create do begin Touch; Free; end;
end.
