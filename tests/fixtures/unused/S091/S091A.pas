unit S091A;
interface
uses System.Classes, System.TypInfo;
type
  TS091Gadget = class(TPersistent)
  private
    FLevel: Integer;
    FSpare: Integer;
  published
    property Level: Integer read FLevel write FLevel;
  end;
implementation
var G: TS091Gadget;
initialization
  RegisterClass(TS091Gadget);
  G := TS091Gadget.Create;
  SetOrdProp(G, 'Level', 5);
  if GetOrdProp(G, 'Level') <> 5 then Halt(3);
  G.Free;
end.
