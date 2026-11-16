unit S030A;
interface
uses System.Classes;
type
  TSource = class
  private
    FOnChange: TNotifyEvent;
  public
    procedure Fire;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;
  TSink = class
    procedure Changed(Sender: TObject);
    procedure Unhooked(Sender: TObject);
  end;
var GChanged: Boolean;
implementation
procedure TSource.Fire; begin if Assigned(FOnChange) then FOnChange(Self); end;
procedure TSink.Changed(Sender: TObject); begin GChanged := True; end;
procedure TSink.Unhooked(Sender: TObject); begin end;
var Src: TSource; Snk: TSink;
initialization
  Src := TSource.Create; Snk := TSink.Create;
  Src.OnChange := Snk.Changed;
  Src.Fire;
  if not GChanged then Halt(3);
  Src.Free; Snk.Free;
end.
