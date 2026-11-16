unit S074A;
interface
implementation
procedure Pong(N: Integer); forward;
procedure Ping(N: Integer); begin if N > 0 then Pong(N - 1); end;
procedure Pong(N: Integer); begin if N > 0 then Ping(N - 1); end;
end.
