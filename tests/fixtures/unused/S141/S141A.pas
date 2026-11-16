unit S141A;
interface
uses System.Classes;
type
  TS141Item = class(TComponent)
  private
    FTag2: Integer;
    function Tag2Stored: Boolean;
  published
    property Tag2: Integer read FTag2 write FTag2 stored Tag2Stored;
  end;
implementation
function TS141Item.Tag2Stored: Boolean; begin Result := FTag2 <> 0; end;
initialization
  TS141Item.Create(nil).Free;
end.
