unit S124A;
interface
type
  TBase = class
  protected
    function GetText: string; virtual;
  public
    property Text: string read GetText;
  end;
  TDerived = class(TBase)
  protected
    function GetText: string; override;
  end;
implementation
function TBase.GetText: string; begin Result := 'b'; end;
function TDerived.GetText: string; begin Result := inherited GetText + 'd'; end;
var B: TBase;
initialization
  B := TDerived.Create;
  if B.Text <> 'bd' then Halt(3);
  B.Free;
end.
