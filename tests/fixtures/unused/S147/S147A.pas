unit S147A;
interface
type
  TConn = class
    constructor Create; overload;
    constructor Create(const AHost: string); overload;
  end;
implementation
constructor TConn.Create; begin end;
constructor TConn.Create(const AHost: string); begin end;
initialization
  TConn.Create.Free;
end.
