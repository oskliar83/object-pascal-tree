unit S134A;
interface
type
  TTracked = class
  public
    procedure AfterConstruction; override;
  end;
var GLive: Integer;
implementation
procedure TTracked.AfterConstruction; begin inherited; Inc(GLive); end;
initialization
  TTracked.Create.Free;
  if GLive <> 1 then Halt(3);
end.
