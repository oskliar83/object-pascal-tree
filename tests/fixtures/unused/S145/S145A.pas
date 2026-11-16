unit S145A;
interface
type
  TOuter = class
  public type
    TInner = record
      Z: Integer;
    end;
  public
    procedure Go;
  end;
implementation
procedure TOuter.Go; begin end;
initialization
  with TOuter.Create do begin Go; Free; end;
end.
