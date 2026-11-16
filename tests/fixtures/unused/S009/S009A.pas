unit S009A;
interface
type
  TKeep = class end;
  TMid = class
    procedure M;
  end;
  TLeaf = class(TMid)
  end;
implementation
procedure TMid.M; begin end;
end.
