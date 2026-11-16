unit S017A;
interface
type
  TRes = class
  public
    destructor Destroy; override;
  end;
var GFreed: Boolean;
implementation
destructor TRes.Destroy; begin GFreed := True; inherited; end;
initialization
  TRes.Create.Free;
  if not GFreed then Halt(3);
end.
