unit S026A;
interface
type
  ISave = interface
    ['{4D3A0B5E-1C2F-4E6A-9B70-0A1B2C3D4E04}']
    procedure Save;
  end;
  TSaver = class
    procedure Save;
  end;
  TDoc = class(TInterfacedObject, ISave)
  private
    FSaver: TSaver;
  public
    constructor Create;
    destructor Destroy; override;
    property Saver: TSaver read FSaver implements ISave;
  end;
var GSaved: Boolean;
implementation
procedure TSaver.Save; begin GSaved := True; end;
constructor TDoc.Create; begin inherited; FSaver := TSaver.Create; end;
destructor TDoc.Destroy; begin FSaver.Free; inherited; end;
var S: ISave;
initialization
  S := TDoc.Create;
  S.Save;
  if not GSaved then Halt(3);
  S := nil;
end.
