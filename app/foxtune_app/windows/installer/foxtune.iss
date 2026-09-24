; The Windows installer, built with Inno Setup 6. CI builds it from the release
; build, after copying the MSVC runtime DLLs in beside FoxTune.exe. To build
; one locally, do the same, then from app/foxtune_app:
;
;   flutter build windows
;   ISCC windows\installer\foxtune.iss /DAppVersion=0.1.0
;
; It installs for the current user by default, which needs no administrator
; rights, and offers an install for all users instead.

#ifndef AppVersion
#define AppVersion "0.0.0"
#endif
; Names the installer file: the version for a release, the commit otherwise.
#ifndef Label
#define Label "local"
#endif
; Relative to this script.
#ifndef BundleDir
#define BundleDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
#define OutputDir "..\..\build\windows\installer"
#endif

[Setup]
; Identifies FoxTune to Windows across versions, so that a newer installer
; upgrades the copy already there. It must never change.
AppId={{467E0362-F22B-47C1-AE9C-4E1A5F39EBEE}
AppName=FoxTune
AppVersion={#AppVersion}
AppPublisher=FoxTune contributors
AppPublisherURL=https://github.com/N1kO23/FoxTune
AppSupportURL=https://github.com/N1kO23/FoxTune/issues
DefaultDirName={autopf}\FoxTune
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=foxtune-windows-x64-{#Label}-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\FoxTune.exe
WizardStyle=modern
Compression=lzma2
SolidCompression=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\FoxTune"; Filename: "{app}\FoxTune.exe"
Name: "{autodesktop}\FoxTune"; Filename: "{app}\FoxTune.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\FoxTune.exe"; Description: "{cm:LaunchProgram,FoxTune}"; Flags: nowait postinstall skipifsilent
