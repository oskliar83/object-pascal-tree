unit S070A;
interface
function GetTickCount64Ext: UInt64; stdcall; external 'kernel32.dll' name 'GetTickCount64';
function GetTickCountExt: Cardinal; stdcall; external 'kernel32.dll' name 'GetTickCount';
implementation
initialization
  if GetTickCountExt = 0 then Halt(3);
end.
