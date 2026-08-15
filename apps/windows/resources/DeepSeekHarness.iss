#define MyAppVersion GetEnv("DSH_DESKTOP_VERSION")
#define MyBuildDir GetEnv("DSH_WINDOWS_BUILD_DIR")
#define MyOutputDir GetEnv("DSH_WINDOWS_OUTPUT_DIR")

[Setup]
AppId={{A0F6C991-5AB4-43F1-B772-D1D06E25C83A}
AppName=DeepSeek Harness
AppVersion={#MyAppVersion}
AppPublisher=julescore community distribution
AppPublisherURL=https://github.com/julescore/dsh-with-plugin-market
AppSupportURL=https://github.com/julescore/dsh-with-plugin-market/issues
DefaultDirName={autopf}\DeepSeek Harness
DefaultGroupName=DeepSeek Harness
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#MyOutputDir}
OutputBaseFilename=DeepSeek-Harness-{#MyAppVersion}-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\DeepSeek Harness.exe

[Files]
Source: "{#MyBuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\DeepSeek Harness"; Filename: "{app}\DeepSeek Harness.exe"
Name: "{autodesktop}\DeepSeek Harness"; Filename: "{app}\DeepSeek Harness.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Run]
Filename: "{app}\DeepSeek Harness.exe"; Description: "Launch DeepSeek Harness"; Flags: nowait postinstall skipifsilent
