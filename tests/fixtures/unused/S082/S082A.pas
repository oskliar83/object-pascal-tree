unit S082A;
interface
type
  TProbe = class
  private
    FCount: Integer;
  public
    procedure Run;
  end;
var GCalls: Integer;
function Tick: Integer;
implementation
function Tick: Integer; begin Inc(GCalls); Result := GCalls; end;
procedure TProbe.Run; begin FCount := Tick; end;
initialization
  with TProbe.Create do begin Run; Free; end;
  if GCalls <> 1 then Halt(3);
end.
