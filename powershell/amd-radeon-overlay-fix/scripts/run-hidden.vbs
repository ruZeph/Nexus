' run-hidden.vbs - launch a PowerShell script with a genuinely hidden window.
' WshShell.Run with window style 0 uses STARTUPINFO/SW_HIDE, so no console window
' is ever shown. (powershell.exe -WindowStyle Hidden still creates a conhost and
' therefore flashes on screen.)
'
' Usage: wscript.exe run-hidden.vbs "<script.ps1>" [extra args...]
Option Explicit
Dim args, script, extra, i, cmd
Set args = WScript.Arguments
If args.Count = 0 Then
    WScript.Quit 1
End If
script = args(0)
extra = ""
For i = 1 To args.Count - 1
    extra = extra & " " & args(i)
Next
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & script & """" & extra
CreateObject("WScript.Shell").Run cmd, 0, False
