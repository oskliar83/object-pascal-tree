unit S002A;
interface
type
  TBase = class
    procedure Hidden;
  end;
  TDerived = class(TBase)
    procedure Hidden;
  end;
implementation
procedure TBase.Hidden; begin end;
procedure TDerived.Hidden; begin inherited; end;
initialization
  TBase.Create.Free;
end.
