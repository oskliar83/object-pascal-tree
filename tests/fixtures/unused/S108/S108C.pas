unit S108C;
interface
implementation
uses S108A, S108B;
initialization
  if Kind <> 2 then Halt(3);
end.
