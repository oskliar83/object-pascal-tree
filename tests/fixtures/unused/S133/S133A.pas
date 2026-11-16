unit S133A;
interface
type
  TPoint2 = class
    X, Y: Integer;
    function ToString: string; override;
  end;
implementation
uses System.SysUtils;
function TPoint2.ToString: string; begin Result := Format('%d,%d', [X, Y]); end;
var O: TObject;
initialization
  O := TPoint2.Create;
  if O.ToString <> '0,0' then Halt(3);
  O.Free;
end.
