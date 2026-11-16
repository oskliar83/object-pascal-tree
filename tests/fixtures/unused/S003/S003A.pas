unit S003A;
interface
type
  TBase = class
    procedure Foo(A: Integer);
    procedure Bar;
  end;
  TDerived = class(TBase)
    procedure Run;
  end;
implementation
procedure TBase.Foo(A: Integer); begin end;
procedure TBase.Bar; begin end;
procedure TDerived.Run; begin inherited Foo(1); end;
initialization
  with TDerived.Create do begin Run; Free; end;
end.
