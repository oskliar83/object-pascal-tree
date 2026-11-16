unit S115A;
interface
implementation
const
  CLen = 8;
var S: string[CLen];
initialization
  S := '123456789';
  if Length(S) <> 8 then Halt(3);
end.
