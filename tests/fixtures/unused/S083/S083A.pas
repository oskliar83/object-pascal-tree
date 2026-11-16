unit S083A;
interface
implementation
var GLast: string;
procedure Note(const S: string); begin GLast := S; end;
function Last: string; begin Result := GLast; end;
initialization
  Note('x');
end.
