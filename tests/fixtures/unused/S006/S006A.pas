unit S006A;
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
  with TDerived.Create do begin if Count <> 0 then Halt(3); Free; end;
end.
