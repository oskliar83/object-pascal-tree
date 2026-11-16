unit S048A;
interface
type
  TIdle = class end;
  TIdleHelper = class helper for TIdle
    procedure Nothing;
  end;
implementation
procedure TIdleHelper.Nothing; begin end;
end.
