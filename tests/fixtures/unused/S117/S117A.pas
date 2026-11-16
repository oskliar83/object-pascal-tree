unit S117A;
interface
type
  TagAttribute = class(TCustomAttribute)
    constructor Create(const S: string);
  end;
  SpareAttribute = class(TCustomAttribute)
  end;
  [Tag('x')]
  TTagged = class end;
implementation
uses System.Rtti;
constructor TagAttribute.Create(const S: string); begin end;
var Ctx: TRttiContext;
initialization
  if Length(Ctx.GetType(TTagged).GetAttributes) <> 1 then Halt(3);
end.
