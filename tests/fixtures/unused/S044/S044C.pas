unit S044C;
interface
implementation
uses S044A, S044B;
var T: TTemp;
initialization
  T.C := 100;
  if Round(T.F) <> 212 then Halt(3);
end.
