unit S039A;
interface
type
  ISource<T> = interface
    function Next: T;
  end;
  TCounter = class(TInterfacedObject, ISource<Integer>)
  private
    FN: Integer;
  public
    function Next: Integer;
  end;
implementation
function TCounter.Next: Integer; begin Inc(FN); Result := FN; end;
var S: ISource<Integer>;
initialization
  S := TCounter.Create;
  if S.Next <> 1 then Halt(3);
end.
