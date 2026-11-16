unit S138A;
interface
var
  GRetries: Integer = 3;
  GLive: Integer = 1;
implementation
initialization
  if GLive <> 1 then Halt(3);
end.
