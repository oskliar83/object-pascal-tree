unit S041A;
interface
type
  TTree<T> = class
  public type
    TNode = class
      Value: T;
      Next: TNode;
    end;
  public
    Root: TNode;
    function Add(const V: T): TNode;
  end;
implementation
function TTree<T>.Add(const V: T): TNode; begin Result := TNode.Create; Result.Value := V; end;
var T: TTree<Integer>; N: TTree<Integer>.TNode;
initialization
  T := TTree<Integer>.Create;
  N := T.Add(5);
  if N.Value <> 5 then Halt(3);
  N.Free; T.Free;
end.
