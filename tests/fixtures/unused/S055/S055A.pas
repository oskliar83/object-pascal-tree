unit S055A;
interface
type
  THeader = packed record
    Magic: Word;
    Version: Word;
    Size: Cardinal;
  end;
implementation
var H: THeader; Buf: array[0..7] of Byte;
initialization
  FillChar(Buf, SizeOf(Buf), 1);
  Move(Buf, H, SizeOf(H));
  if H.Magic <> $0101 then Halt(3);
  if SizeOf(THeader) <> 8 then Halt(4);
end.
