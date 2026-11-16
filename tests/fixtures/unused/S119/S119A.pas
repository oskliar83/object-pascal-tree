unit S119A;
interface
type
  TCounter = class
  public
    class var Count: Integer;
  end;
  TCounterClass = class of TCounter;
implementation
var C: TCounterClass;
initialization
  C := TCounter;
  C.Count := 2;
  if C.Count <> 2 then Halt(3);
end.
