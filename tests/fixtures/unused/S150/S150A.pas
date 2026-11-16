unit S150A;
interface
type
  IStore = interface
    ['{4D3A0B5E-1C2F-4E6A-9B70-0A1B2C3D4E50}']
    function GetMoreStuff: Integer;
    procedure SetMoreStuff(V: Integer);
    property MoreStuff: Integer read GetMoreStuff write SetMoreStuff;
    procedure Load;
    procedure Save;
  end;
  TStore = class(TInterfacedObject, IStore)
    function GetMoreStuff: Integer;
    procedure SetMoreStuff(V: Integer);
    procedure IStore.Load = LoadIt;
    procedure LoadIt;
    procedure Save;
  end;
var GSaved: Boolean;
implementation
function TStore.GetMoreStuff: Integer; begin Result := 0; end;
procedure TStore.SetMoreStuff(V: Integer); begin end;
procedure TStore.LoadIt; begin end;
procedure TStore.Save; begin GSaved := True; end;
var S: IStore;
initialization
  S := TStore.Create;
  S.Save;
  if not GSaved then Halt(3);
end.
