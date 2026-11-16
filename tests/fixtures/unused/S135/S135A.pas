unit S135A;
interface
type
  TKey = class
    Id: Integer;
    constructor Create(AId: Integer);
    function Equals(Obj: TObject): Boolean; override;
    function GetHashCode: Integer; override;
  end;
implementation
uses System.Generics.Collections;
constructor TKey.Create(AId: Integer); begin Id := AId; end;
function TKey.Equals(Obj: TObject): Boolean; begin Result := (Obj is TKey) and (TKey(Obj).Id = Id); end;
function TKey.GetHashCode: Integer; begin Result := Id; end;
var D: TDictionary<TKey, Integer>; K1, K2: TKey;
initialization
  D := TDictionary<TKey, Integer>.Create;
  K1 := TKey.Create(1); K2 := TKey.Create(1);
  D.Add(K1, 5);
  if not D.ContainsKey(K2) then Halt(3);
  D.Free; K1.Free; K2.Free;
end.
