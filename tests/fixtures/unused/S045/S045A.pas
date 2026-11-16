unit S045A;
interface
type
  TLight = (lRed, lAmber, lGreen);
  TLightHelper = record helper for TLight
    function Next: TLight;
    function Name: string;
  end;
implementation
function TLightHelper.Next: TLight; begin if Self = High(TLight) then Result := Low(TLight) else Result := Succ(Self); end;
function TLightHelper.Name: string; begin Result := ''; end;
var L: TLight;
initialization
  L := lGreen;
  if L.Next <> lRed then Halt(3);
end.
