unit S062A;
interface
type
  TCell = record
    A: Integer;
    B: Integer;
  end;
  TOther = record
    C: Integer;
    D: Integer;
  end;
implementation
initialization
  if SizeOf(TCell) <> 8 then Halt(3);
end.
