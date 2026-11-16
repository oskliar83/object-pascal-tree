unit S136A;
interface
type
  TLeaky = class
  public
    destructor Destroy;
  end;
var GDestroyed: Boolean;
implementation
destructor TLeaky.Destroy; begin GDestroyed := True; inherited; end;
initialization
  TLeaky.Create.Free;
  if GDestroyed then Halt(3);
end.
