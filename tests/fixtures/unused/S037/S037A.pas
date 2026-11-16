unit S037A;
interface
type
  TMake = class
    class function Twice<T>(const A: T): TArray<T>; static;
    class function Once<T>(const A: T): TArray<T>; static;
  end;
implementation
class function TMake.Twice<T>(const A: T): TArray<T>; begin Result := [A, A]; end;
class function TMake.Once<T>(const A: T): TArray<T>; begin Result := [A]; end;
initialization
  if Length(TMake.Twice<string>('x')) <> 2 then Halt(3);
end.
