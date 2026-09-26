; A small real installer for sg-image's elevated-display gate (B56): NSIS,
; built at test time. It asks for administrator rights (its manifest says
; requireAdministrator), so running it from the session goes through the
; consent prompt; it installs to Program Files, adds an all-users Start menu
; shortcut and an Add/Remove Programs entry, and writes what was typed on its
; first page -- the proof the real keyboard reached it.
Unicode true
!include nsDialogs.nsh
!include LogicLib.nsh
Name "SG Test App"
Caption "SG Test App Setup"
OutFile "sg-test-setup.exe"
RequestExecutionLevel admin
InstallDir "$PROGRAMFILES64\SG Test App"
AutoCloseWindow true

Var Dialog
Var TypedBox
Var Typed

Page custom TypedPage TypedLeave
Page directory
Page instfiles

Function TypedPage
    nsDialogs::Create 1018
    Pop $Dialog
    ${NSD_CreateLabel} 0 0 100% 12u "Type the word you were given, then press Enter:"
    Pop $0
    ${NSD_CreateText} 0 16u 100% 12u ""
    Pop $TypedBox
    ${NSD_SetFocus} $TypedBox
    nsDialogs::Show
FunctionEnd

Function TypedLeave
    ${NSD_GetText} $TypedBox $Typed
FunctionEnd

Section "Install"
    SetShellVarContext all
    SetOutPath "$INSTDIR"
    File "sg-test-app.exe"
    FileOpen $0 "$INSTDIR\typed.txt" w
    FileWrite $0 "$Typed"
    FileClose $0
    WriteUninstaller "$INSTDIR\uninstall.exe"
    CreateDirectory "$SMPROGRAMS\SG Test App"
    CreateShortcut "$SMPROGRAMS\SG Test App\SG Test App.lnk" "$INSTDIR\sg-test-app.exe"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\SGTestApp" "DisplayName" "SG Test App"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\SGTestApp" "UninstallString" "$INSTDIR\uninstall.exe"
SectionEnd

Section "Uninstall"
    SetShellVarContext all
    Delete "$SMPROGRAMS\SG Test App\SG Test App.lnk"
    RMDir "$SMPROGRAMS\SG Test App"
    Delete "$INSTDIR\sg-test-app.exe"
    Delete "$INSTDIR\typed.txt"
    Delete "$INSTDIR\uninstall.exe"
    RMDir "$INSTDIR"
    DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\SGTestApp"
SectionEnd
