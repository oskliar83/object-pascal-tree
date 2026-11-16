unit S023A;
interface
type
  IRun = interface
    ['{4D3A0B5E-1C2F-4E6A-9B70-0A1B2C3D4E02}']
    procedure Run;
  end;
  TJob = class(TInterfacedObject, IRun)
    procedure IRun.Run = DoRun;
    procedure DoRun;
    procedure Run;
  end;
var GRan: Integer;
implementation
procedure TJob.DoRun; begin GRan := 1; end;
procedure TJob.Run; begin GRan := 2; end;
var R: IRun;
initialization
  R := TJob.Create;
  R.Run;
  if GRan <> 1 then Halt(3);
end.
