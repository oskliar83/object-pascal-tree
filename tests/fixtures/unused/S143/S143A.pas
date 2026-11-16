unit S143A;
interface
type
  TBase = class
    class function Tag: string; virtual;
  end;
  TChild = class(TBase)
    class function Describe: string;
  end;
implementation
class function TBase.Tag: string; begin Result := 'base'; end;
class function TChild.Describe: string; begin Result := Tag; end;
initialization
  if TChild.Describe <> 'base' then Halt(3);
end.
