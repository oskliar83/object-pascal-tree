unit S022A;
interface
uses System.Generics.Defaults, System.Generics.Collections;
type
  TDesc = class(TInterfacedObject, IComparer<Integer>)
    function Compare(const L, R: Integer): Integer;
    function Spare: Integer;
  end;
implementation
function TDesc.Compare(const L, R: Integer): Integer; begin Result := R - L; end;
function TDesc.Spare: Integer; begin Result := 0; end;
var A: TArray<Integer>;
initialization
  A := [1, 3, 2];
  TArray.Sort<Integer>(A, TDesc.Create);
  if A[0] <> 3 then Halt(3);
end.
