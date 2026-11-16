unit S036A;
interface
type
  TBox<T> = class
  private
    FValue: T;
  public
    procedure Put(const V: T);
    function Get: T;
    procedure Clear;
  end;
implementation
procedure TBox<T>.Put(const V: T); begin FValue := V; end;
function TBox<T>.Get: T; begin Result := FValue; end;
procedure TBox<T>.Clear; begin FValue := Default(T); end;
var B: TBox<Integer>;
initialization
  B := TBox<Integer>.Create;
  B.Put(4);
  if B.Get <> 4 then Halt(3);
  B.Free;
end.
