unit S139A;
interface
type
  INamed = interface
    ['{4D3A0B5E-1C2F-4E6A-9B70-0A1B2C3D4E0A}']
    function GetName: string;
    property Name: string read GetName;
  end;
  TThing = class(TInterfacedObject, INamed)
    function GetName: string;
  end;
implementation
function TThing.GetName: string; begin Result := 'thing'; end;
var N: INamed;
initialization
  N := TThing.Create;
  if N.Name <> 'thing' then Halt(3);
end.
