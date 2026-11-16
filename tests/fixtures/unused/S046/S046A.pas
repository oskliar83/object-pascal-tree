unit S046A;
interface
type
  TStrHelper = record helper for string
    function Twice: string;
    function Quad: string;
  end;
implementation
function TStrHelper.Twice: string; begin Result := Self + Self; end;
function TStrHelper.Quad: string; begin Result := Twice.Twice; end;
var S: string;
initialization
  S := 'a';
  if S.Quad <> 'aaaa' then Halt(3);
end.
