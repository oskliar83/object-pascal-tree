unit S126A;
interface
uses System.SysUtils;
type
  EParse = class(Exception);
  EUnused = class(Exception);
implementation
initialization
  try
    raise EParse.Create('x');
  except
    on EParse do ;
  end;
end.
