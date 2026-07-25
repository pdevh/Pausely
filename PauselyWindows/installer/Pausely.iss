#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#ifndef SourceDir
  #define SourceDir "..\..\out"
#endif

#ifndef OutputDir
  #define OutputDir "..\..\installer-out"
#endif

[Setup]
AppId={{B11BB514-5C60-4D64-BCB6-046F49AC2F92}
AppName=Pausely
AppVersion={#AppVersion}
AppPublisher=Pausely
AppPublisherURL=https://github.com/pdevh/Pausely
AppSupportURL=https://github.com/pdevh/Pausely/issues
AppUpdatesURL=https://github.com/pdevh/Pausely/releases
DefaultDirName={localappdata}\Programs\Pausely
DefaultGroupName=Pausely
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=Pausely-Windows-Setup
SetupIconFile=..\Pausely.ico
UninstallDisplayIcon={app}\PauselyWindows.exe
WizardStyle=modern
Compression=lzma2/ultra64
SolidCompression=yes
CloseApplications=yes
RestartApplications=no
#ifdef SignedBuild
SignTool=PauselySign
SignedUninstaller=yes
SignedUninstallerDir={#OutputDir}\signed-uninstallers
#endif
VersionInfoVersion={#AppVersion}
VersionInfoCompany=Pausely
VersionInfoDescription=Pausely installer
VersionInfoProductName=Pausely
VersionInfoProductVersion={#AppVersion}

[Files]
Source: "{#SourceDir}\PauselyWindows.exe"; DestDir: "{app}"; Flags: ignoreversion

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Icons]
Name: "{autoprograms}\Pausely"; Filename: "{app}\PauselyWindows.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Pausely"; Filename: "{app}\PauselyWindows.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\PauselyWindows.exe"; Description: "{cm:LaunchProgram,Pausely}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\PauselyWindows.exe"; WorkingDir: "{app}"; Flags: nowait runasoriginaluser; Check: IsAutomaticUpdate

[UninstallRun]
Filename: "{cmd}"; Parameters: "/C reg delete ""HKCU\Software\Microsoft\Windows\CurrentVersion\Run"" /v ""Pausely"" /f"; Flags: runhidden; RunOnceId: "RemoveStartupEntry"

[Code]
function IsAutomaticUpdate: Boolean;
begin
  Result := ExpandConstant('{param:PAUSELYAUTOUPDATE|0}') = '1';
end;

procedure RegisterExtraCloseApplicationsResources();
var
  RunningExecutable: String;
begin
  if not IsAutomaticUpdate then
    exit;

  RunningExecutable := ExpandConstant('{param:PAUSELYRUNNINGEXE|}');
  if (RunningExecutable = '') or
     (CompareText(ExtractFileName(RunningExecutable), 'PauselyWindows.exe') <> 0) or
     (CompareText(ExpandFileName(RunningExecutable), RunningExecutable) <> 0) or
     not FileExists(RunningExecutable) then
  begin
    RaiseException('The automatic update did not provide a valid running Pausely executable.');
  end;

  { Inno 6.7.3 takes DisableFsRedir first; Inno 7 removes that argument. }
  if not RegisterExtraCloseApplicationsResource(False, RunningExecutable) then
  begin
    RaiseException('Could not register the running Pausely executable with Restart Manager.');
  end;
end;
