unit S047A;
interface
type
  TBox = class
    V: Integer;
  end;
  TBaseHelper = class helper for TBox
    function Plus1: Integer;
  end;
  TMoreHelper = class helper(TBaseHelper) for TBox
    function Plus2: Integer;
  end;
implementation
function TBaseHelper.Plus1: Integer; begin Result := V + 1; end;
function TMoreHelper.Plus2: Integer; begin Result := V + 2; end;
var B: TBox;
initialization
  B := TBox.Create;
  if B.Plus1 + B.Plus2 <> 3 then Halt(3);
  B.Free;
end.
