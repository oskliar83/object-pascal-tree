unit S028A;
interface
type
  IIdle = interface
    ['{4D3A0B5E-1C2F-4E6A-9B70-0A1B2C3D4E06}']
    procedure Idle;
  end;
  TWorker = class(TInterfacedObject, IIdle)
    procedure Idle;
    procedure Work;
  end;
implementation
procedure TWorker.Idle; begin end;
procedure TWorker.Work; begin end;
var W: TWorker;
initialization
  W := TWorker.Create; W.Work; W.Free;
end.
