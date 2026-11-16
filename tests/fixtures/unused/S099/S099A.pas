unit S099A;
interface
uses System.Classes;
type
  TS099Plugin = class(TPersistent)
  end;
  TS099Unreg = class(TPersistent)
  end;
implementation
initialization
  RegisterClasses([TS099Plugin]);
  if GetClass('TS099Plugin') = nil then Halt(3);
end.
