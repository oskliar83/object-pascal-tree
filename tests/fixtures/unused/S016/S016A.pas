unit S016A;
interface
type
  TReg = class
  private
    class var FList: TObject;
    class constructor Create;
    class destructor Destroy;
  public
    class function List: TObject; static;
  end;
implementation
class constructor TReg.Create; begin FList := TObject.Create; end;
class destructor TReg.Destroy; begin FList.Free; if ExitCode = 5 then ExitCode := 0; end;
class function TReg.List: TObject; begin Result := FList; end;
initialization
  if TReg.List = nil then Halt(3);
  ExitCode := 5;
end.
