unit S015A;
interface
type
  TReg = class
  private
    class var FCount: Integer;
    class var FSpare: Integer;
  public
    class procedure Bump; static;
  end;
implementation
class procedure TReg.Bump; begin Inc(FCount); end;
initialization
  TReg.Bump;
end.
