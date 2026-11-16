unit S092A;
interface
type
  TS092Svc = class
  public
    procedure Run;
    procedure Idle;
  end;
var GRan: Boolean;
implementation
uses System.Rtti;
procedure TS092Svc.Run; begin GRan := True; end;
procedure TS092Svc.Idle; begin end;
var Ctx: TRttiContext; S: TS092Svc; M: TRttiMethod;
initialization
  S := TS092Svc.Create;
  M := Ctx.GetType(TS092Svc).GetMethod('Run');
  if M <> nil then M.Invoke(S, []);
  S.Free;
  if not GRan then Halt(3);
end.
