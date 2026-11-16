unit S121A;
interface
function Sq(A: Integer): Integer; inline;
function Cube(A: Integer): Integer; inline;
implementation
function Sq(A: Integer): Integer; begin Result := A * A; end;
function Cube(A: Integer): Integer; begin Result := A * A * A; end;
initialization
  if Sq(3) <> 9 then Halt(3);
end.
