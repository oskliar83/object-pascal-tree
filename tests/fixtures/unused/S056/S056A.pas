unit S056A;
interface
type
  TValue4 = record
    case Integer of
      0: (I: Integer);
      1: (B: array[0..3] of Byte);
      2: (W: Word);
  end;
implementation
var V: TValue4;
initialization
  V.I := $01020304;
  if V.B[0] <> 4 then Halt(3);
end.
