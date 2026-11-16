unit S149A;
interface
type
  TWorker = class
    function Ready: Boolean;
  end;
  TCheck = function: Boolean of object;
implementation
function TWorker.Ready: Boolean; begin Result := True; end;
var W: TWorker; C: TCheck;
initialization
  W := TWorker.Create;
  C := W.Ready;
  if not C() then Halt(3);
  W.Free;
end.
