unit S004A;
interface
type
  TBase = class
    procedure Go; virtual;
  end;
  TDerived = class(TBase)
    procedure Go(A: Integer); reintroduce;
  end;
implementation
var G: Integer;
procedure TBase.Go; begin G := 1; end;
procedure TDerived.Go(A: Integer); begin G := A; end;
var D: TDerived;
initialization
  D := TDerived.Create; TBase(D).Go; D.Free;
end.
