unit S014B;
interface
uses S014A;
type
  TDerived = class(TBase)
    procedure Run;
  end;
implementation
procedure TDerived.Run; begin Help; end;
initialization
  with TDerived.Create do begin Run; Free; end;
end.
