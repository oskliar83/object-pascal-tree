unit S043A;
interface
type
  TBox = class
    V: Integer;
  end;
  TBoxHelper1 = class helper for TBox
    function Twice: Integer;
  end;
  TBoxHelper2 = class helper for TBox
    function Twice: Integer;
  end;
implementation
function TBoxHelper1.Twice: Integer; begin Result := V * 3; end;
function TBoxHelper2.Twice: Integer; begin Result := V * 2; end;
var B: TBox;
initialization
  B := TBox.Create; B.V := 2;
  if B.Twice <> 4 then Halt(3);
  B.Free;
end.
