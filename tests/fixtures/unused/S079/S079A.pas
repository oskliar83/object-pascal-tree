unit S079A;
interface
implementation
const
  CSize = 4;
type
  TBuf = array[0..CSize - 1] of Byte;
procedure Fill(var B: TBuf); begin FillChar(B, SizeOf(B), 0); end;
end.
