unit S034A;
interface
type
  TAnimal = class
    function Name: string; virtual;
  end;
  TCat = class(TAnimal)
  end;
  TPen<T: TAnimal, constructor> = class
    function Make: T;
  end;
implementation
function TAnimal.Name: string; begin Result := 'a'; end;
function TPen<T>.Make: T; begin Result := T.Create; end;
initialization
  with TPen<TCat>.Create do begin Make.Free; Free; end;
end.
