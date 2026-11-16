unit S067A;
interface
resourcestring
  SHello = 'hello';
  SBye = 'bye';
implementation
initialization
  if SHello <> 'hello' then Halt(3);
end.
