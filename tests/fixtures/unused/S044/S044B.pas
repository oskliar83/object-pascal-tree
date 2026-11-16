unit S044B;
interface
uses S044A;
type
  TTempHelper = record helper for TTemp
    function F: Double;
    function K: Double;
  end;
implementation
function TTempHelper.F: Double; begin Result := C * 9 / 5 + 32; end;
function TTempHelper.K: Double; begin Result := C + 273.15; end;
end.
