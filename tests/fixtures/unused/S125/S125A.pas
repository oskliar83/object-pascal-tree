unit S125A;
interface
uses System.Classes;
type
  TUnits = (uMm, uIn);
  TS125Ruler = class(TPersistent)
  private
    FUnits: TUnits;
  published
    property Units: TUnits read FUnits write FUnits;
  end;
implementation
end.
