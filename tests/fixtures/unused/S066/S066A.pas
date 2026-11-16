unit S066A;
interface
implementation
const
  CBase = 10;
  CTable: array[0..1] of Integer = (CBase, CBase * 2);
  CLive: Integer = 5;
initialization
  if CLive <> 5 then Halt(3);
end.
