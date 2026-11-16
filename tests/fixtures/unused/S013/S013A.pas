unit S013A;
interface
type
  TBase = class
    procedure Go; virtual;
  end;
  TDerived = class(TBase)
    procedure Go; override;
  end;
implementation
var G: Integer;
procedure TBase.Go; begin G := 1; end;
procedure TDerived.Go; begin G := 2; end;
var B: TBase;
initialization
  B := TDerived.Create; B.Go; B.Free;
  if G <> 2 then Halt(3);
end.
