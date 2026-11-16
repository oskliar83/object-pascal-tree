unit S137A;
interface
implementation
const
  CVowels = ['a', 'e', 'i', 'o', 'u'];
  CDigits = ['0'..'9'];
var C: Char;
initialization
  C := 'e';
  if not (C in CVowels) then Halt(3);
end.
