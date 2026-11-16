unit S007A;
interface
type
  TBase = class
  private
    FCount: Integer;
  protected
    property Count: Integer read FCount;
  end;
  TDerived = class(TBase)
  public
    property Count;
  end;
implementation
initialization
  TBase.Create.Free;
end.
