unit S081A;
interface
type
  TBox = class
  private
    FSize: Integer;
    procedure SetSize(V: Integer);
  public
    property Size: Integer write SetSize;
  end;
var GChanges: Integer;
implementation
procedure TBox.SetSize(V: Integer); begin if FSize <> V then begin FSize := V; Inc(GChanges); end; end;
initialization
  with TBox.Create do begin Size := 2; Size := 2; Free; end;
  if GChanges <> 1 then Halt(3);
end.
