unit S025A;
interface
type
  ILog = interface
    procedure Write(const S: string);
  end;
procedure Report(const L: ILog);
procedure Live;
implementation
procedure Report(const L: ILog); begin L.Write('x'); end;
procedure Live; begin end;
initialization
  Live;
end.
