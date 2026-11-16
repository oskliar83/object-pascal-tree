unit S011A;
interface
type
  TItem = class
    constructor Create; virtual;
  end;
  TItemClass = class of TItem;
  TBlue = class(TItem)
    constructor Create; override;
  end;
  TRed = class(TItem)
    constructor Create; override;
  end;
var GMade: string;
function Make(AC: TItemClass): TItem;
implementation
constructor TItem.Create; begin GMade := 'item'; end;
constructor TBlue.Create; begin GMade := 'blue'; end;
constructor TRed.Create; begin GMade := 'red'; end;
function Make(AC: TItemClass): TItem; begin Result := AC.Create; end;
initialization
  Make(TBlue).Free;
  if GMade <> 'blue' then Halt(3);
end.
