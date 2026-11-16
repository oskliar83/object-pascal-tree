unit S090A;
interface
uses System.Classes;
type
  TS090Widget = class(TComponent)
  public
    constructor Create(AOwner: TComponent); override;
  end;
var GMade: Boolean;
implementation
constructor TS090Widget.Create(AOwner: TComponent); begin inherited; GMade := True; end;
var C: TComponent;
initialization
  RegisterClass(TS090Widget);
  C := TComponentClass(FindClass('TS090Widget')).Create(nil);
  C.Free;
  if not GMade then Halt(3);
end.
