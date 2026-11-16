unit S061A;
interface
type
  TMode = (mFast, mSlow);
implementation
var I: Integer;
initialization
  I := Ord(mSlow);
  if I <> 1 then Halt(3);
end.
