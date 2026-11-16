unit S120A;
interface
procedure Old; deprecated 'use New';
procedure New;
implementation
procedure Old; begin end;
procedure New; begin end;
initialization
  New;
end.
