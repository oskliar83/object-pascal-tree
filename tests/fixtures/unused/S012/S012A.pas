unit S012A;
interface
type
  TItem = class end;
  TItemClass = class of TItem;
function Make(AC: TItemClass): TItem;
implementation
function Make(AC: TItemClass): TItem; begin Result := AC.Create; end;
initialization
  TItem.Create.Free;
end.
