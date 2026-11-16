unit S063A;
interface
type
  TShape = class end;
  TCircle = class(TShape) end;
implementation
var S: TShape;
initialization
  S := TShape.Create;
  if S is TCircle then Halt(3);
  S.Free;
end.
