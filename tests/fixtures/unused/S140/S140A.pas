unit S140A;
interface
implementation
const
  CBase = 100;
  CTop = CBase * 2;
initialization
  if CTop <> 200 then Halt(3);
end.
