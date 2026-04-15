#define AppName "winghostty"
#define AppId "io.github.amanthanvi.winghostty"
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0-dev"
#endif
#ifndef StageDir
  #error StageDir must be defined on the ISCC command line.
#endif
#ifndef OutputDir
  #error OutputDir must be defined on the ISCC command line.
#endif
#ifndef SourceDir
  #define SourceDir "."
#endif

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#MyAppVersion}
AppPublisher=Aman Thanvi
AppPublisherURL=https://github.com/amanthanvi/winghostty
AppSupportURL=https://github.com/amanthanvi/winghostty/issues
AppUpdatesURL=https://github.com/amanthanvi/winghostty/releases
DefaultDirName={autopf}\winghostty
DefaultGroupName=winghostty
DisableProgramGroupPage=yes
LicenseFile={#StageDir}\LICENSE
OutputDir={#OutputDir}
OutputBaseFilename=winghostty-{#MyAppVersion}-windows-x64-setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ChangesAssociations=no
UninstallDisplayIcon={app}\winghostty.exe
SetupIconFile={#SourceDir}\dist\windows\winghostty.ico

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\winghostty"; Filename: "{app}\winghostty.exe"
Name: "{group}\Uninstall winghostty"; Filename: "{uninstallexe}"
Name: "{autodesktop}\winghostty"; Filename: "{app}\winghostty.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\winghostty.exe"; Description: "Launch winghostty"; Flags: nowait postinstall skipifsilent
