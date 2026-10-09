; FastGuard Windows 安装包脚本（Inno Setup 6.3+）
;
; 通常由仓库根目录的 build_installer.bat 调用，不建议直接双击编译。
; 打包输入是 build_windows.bat 产出的 dist\FastGuard 目录，输出为单文件安装程序
; dist\FastGuard-<版本>-Setup.exe。
;
; 可用 /D 覆盖下面的预处理变量，例如指定版本号：
;   ISCC.exe /DAppVersion=1.2.0 installer\FastGuard.iss

#define AppName "FastGuard"
#define AppExeName "FastGuard.exe"
#define AppPublisher "FastGuard"

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\FastGuard"
#endif
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif

[Setup]
; AppId 必须保持不变，否则覆盖安装会变成并存安装、旧版本无法被识别
AppId={{96B588D7-2E3B-40F8-A362-15F461CB097C}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
VersionInfoDescription={#AppName} Setup

; 应用会把 logs\ 与 data\fastguard.db 写在 exe 同目录（main.py 取 __file__ 所在目录，
; pyi_rth_fastguard.py 又把工作目录切到 exe 目录），所以只能装到当前用户可写的路径。
; 这里固定为按用户安装，不申请管理员权限，避免装到 Program Files 后写日志失败。
DefaultDirName={localappdata}\Programs\{#AppName}
PrivilegesRequired=lowest
DisableDirPage=no

DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
AllowNoIcons=yes

; 产物内含 python310.dll 与 OpenVINO 64 位原生绑定，仅支持 64 位 Windows 10 及以上
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

OutputDir={#OutputDir}
OutputBaseFilename={#AppName}-{#AppVersion}-Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

UninstallDisplayIcon={app}\{#AppExeName}
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
; Inno Setup 官方不带简体中文；把 ChineseSimplified.isl 放到本目录即自动启用中文向导
#if FileExists(AddBackslash(SourcePath) + "ChineseSimplified.isl")
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "logs\*,runs\*,data\fastguard.db,data\fastguard.db-wal,data\fastguard.db-shm"

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

; 运行期产生的日志与日志库不在 [Files] 中，卸载时单独清理
[UninstallDelete]
Type: filesandordirs; Name: "{app}\logs"
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}\runs"
