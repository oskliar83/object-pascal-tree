unit S040A;
interface
uses System.Generics.Collections;
type
  TIntListHelper = class helper for TList<Integer>
    function Sum: Integer;
    function Product: Integer;
  end;
implementation
function TIntListHelper.Sum: Integer; var I: Integer; begin Result := 0; for I in Self do Inc(Result, I); end;
function TIntListHelper.Product: Integer; var I: Integer; begin Result := 1; for I in Self do Result := Result * I; end;
var L: TList<Integer>;
initialization
  L := TList<Integer>.Create;
  L.AddRange([1, 2, 3]);
  if L.Sum <> 6 then Halt(3);
  L.Free;
end.
