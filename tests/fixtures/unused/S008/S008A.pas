unit S008A;
interface
type
  TShape = class
    procedure Draw; virtual; abstract;
    function Area: Integer; virtual; abstract;
  end;
  TSquare = class(TShape)
    function Area: Integer; override;
  end;
implementation
function TSquare.Area: Integer; begin Result := 4; end;
initialization
  with TSquare.Create do begin if Area <> 4 then Halt(3); Free; end;
end.
