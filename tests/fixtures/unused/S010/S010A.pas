unit S010A;
interface
type
  TMid = class
  end;
  TLeaf = class(TMid)
  end;
implementation
initialization
  TLeaf.Create.Free;
end.
