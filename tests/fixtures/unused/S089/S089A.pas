unit S089A;
interface
uses System.Classes;
type
  TSetting = class(TPersistent)
  published
    procedure Reset;
  end;
implementation
procedure TSetting.Reset; begin end;
initialization
  TSetting.Create.Free;
end.
