; VapourBox Windows installer (Inno Setup 6).
;
; Built by Scripts\build-windows-installer.ps1, which passes:
;   /DAppVersion=X.Y.Z   /DSourceDir=<assembled package dir>   /DOutputDir=<dist>
; SourceDir is the same tree the .zip is made from, so the two cannot drift.

#ifndef AppVersion
  #error AppVersion is not defined - build with Scripts\build-windows-installer.ps1
#endif
#ifndef SourceDir
  #error SourceDir is not defined - build with Scripts\build-windows-installer.ps1
#endif
#ifndef OutputDir
  #error OutputDir is not defined - build with Scripts\build-windows-installer.ps1
#endif

#define AppName "VapourBox"
#define AppExe "vapourbox.exe"
#define AppUrl "https://github.com/StuartCameronCode/VapourBox"

[Setup]
; Identifies the app to Windows across versions: an upgrade replaces the
; install with the same AppId. NEVER change it - a new one installs a second
; copy alongside, with its own uninstall entry.
AppId={{720387E0-A990-4A2A-AEE8-754B04E64620}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Stuart Cameron
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases

; Per-user, no elevation, and no option to install for all users. This is
; load-bearing, not a convenience: on Windows the app downloads its processing
; dependencies and add-ons into deps\ and addons\ NEXT TO THE EXECUTABLE, so
; the install directory has to stay writable by the user. Under Program Files
; the first-launch download would fail. With "lowest", {autopf} resolves to
; %LOCALAPPDATA%\Programs.
PrivilegesRequired=lowest
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
UsePreviousAppDir=yes

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

OutputDir={#OutputDir}
OutputBaseFilename={#AppName}-{#AppVersion}-windows-x64-setup
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes

; Text, not VersionInfoVersion: that one must be four integers, and a version
; like 1.2.3-rc1 would fail the compile.
VersionInfoCompany=Stuart Cameron
VersionInfoDescription={#AppName} Setup
VersionInfoProductName={#AppName}
VersionInfoTextVersion={#AppVersion}
VersionInfoProductTextVersion={#AppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; Inno only adds and overwrites, so a file dropped from a newer version would
; survive an upgrade. That matters most for templates\, the first place the
; worker looks: a stale module left there is a silent wrong-version bug.
; deps\ and addons\ are deliberately NOT here - they are the user's downloads
; and survive upgrades.
Type: filesandordirs; Name: "{app}\templates"
Type: filesandordirs; Name: "{app}\data"

[Files]
; The .bat launcher is for the zip; the installer makes real shortcuts.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "*.bat"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Downloaded by the app after install, so the uninstaller does not know about
; them and would otherwise leave several hundred MB behind. User presets
; (%USERPROFILE%\.vapourbox) are the user's own files and are left alone.
Type: filesandordirs; Name: "{app}\deps"
Type: filesandordirs; Name: "{app}\addons"
