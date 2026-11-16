unit S132A;
interface
type
  PNode = ^TNode;
  TNode = record
    Value: Integer;
  end;
implementation
var N: TNode; P: PNode;
initialization
  P := @N;
  P^.Value := 4;
  if N.Value <> 4 then Halt(3);
end.
