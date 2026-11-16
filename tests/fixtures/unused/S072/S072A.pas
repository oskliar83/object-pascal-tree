unit S072A;
interface
type
  TCounter = class
  private
    FHits: Integer;
  public
    procedure Hit;
  end;
implementation
procedure TCounter.Hit; begin Inc(FHits); end;
initialization
  with TCounter.Create do begin Hit; Free; end;
end.
