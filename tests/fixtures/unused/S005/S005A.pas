unit S005A;
interface
type
  TBase = class
    procedure Go;
  end;
  TDerived = class(TBase)
    procedure Go(A: Integer); reintroduce;
  end;
implementation
var G: Integer;
procedure TBase.Go; begin G := 1; end;
procedure TDerived.Go(A: Integer); begin G := A; end;
initialization
  with TDerived.Create do begin Go(2); Free; end;
end.
