unit S146A;
interface
type
  TBox = class
  private
    procedure SetSize(V: Integer);
  public
    property Size: Integer write SetSize;
  end;
var GSet: Integer;
implementation
procedure TBox.SetSize(V: Integer); begin GSet := V; end;
initialization
  with TBox.Create do begin Size := 3; Free; end;
  if GSet <> 3 then Halt(3);
end.
