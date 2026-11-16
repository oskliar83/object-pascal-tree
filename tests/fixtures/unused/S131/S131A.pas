unit S131A;
interface
type
  PHeader = ^THeader;
  THeader = packed record
    Kind: Byte;
    Len: Byte;
  end;
implementation
var Buf: array[0..1] of Byte;
initialization
  Buf[0] := 7; Buf[1] := 9;
  if PHeader(@Buf)^.Len <> 9 then Halt(3);
end.
