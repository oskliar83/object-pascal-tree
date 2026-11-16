unit S033A;
interface
type
  TIntFunc = reference to function: Integer;
  TConst = class(TInterfacedObject, TIntFunc)
    function Invoke: Integer;
  end;
implementation
function TConst.Invoke: Integer; begin Result := 7; end;
var F: TIntFunc; C: TConst;
initialization
  C := TConst.Create;
  F := C;
  if F() <> 7 then Halt(3);
end.
