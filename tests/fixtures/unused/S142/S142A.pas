unit S142A;
interface
type
  TStats = record
    Hits: Integer;
    Misses: Integer;
  end;
implementation
var S: TStats;
initialization
  with S do
  begin
    Hits := 1;
    Misses := 2;
  end;
  if S.Misses <> 2 then Halt(3);
end.
