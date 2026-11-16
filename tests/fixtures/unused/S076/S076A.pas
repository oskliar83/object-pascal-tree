unit S076A;
interface
type
  TJob = class
  private
    FStarted: TDateTime;
  public
    procedure Start;
  end;
implementation
uses System.SysUtils;
procedure TJob.Start; begin FStarted := Now; end;
initialization
  with TJob.Create do begin Start; Free; end;
end.
