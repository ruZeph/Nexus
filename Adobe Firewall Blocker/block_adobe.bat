@REM Author: https://github.com/ph33nx
@Rem Description: This script blocks or unblocks Adobe-related executables in Windows Firewall.
@Rem Usage:
@Rem - To block executables: adobe_block.bat
@Rem - To unblock (delete) existing rules: adobe_block.bat -delete

@echo off
setlocal enabledelayedexpansion

:choicepart
set choice=
set /p choice=Type C to create or D for delete firewall blocks:
if not '%choice%'=='' set choice=%choice:~0,1%
if '%choice%'=='C' goto createpart
if '%choice%'=='D' goto deletepart
if '%choice%'=='c' goto createpart
if '%choice%'=='d' goto deletepart
goto choicepart

REM Check if the script should delete existing rules
if /i "%1"=="-delete" (
:deletepart
echo Deleting existing firewall rules...
for /f "tokens=*" %%r in ('powershell -command "(Get-NetFirewallRule | where {$_.DisplayName -like '*adobe-block'}).DisplayName"') do (
netsh advfirewall firewall delete rule name="%%r"
)
echo Firewall rules deleted successfully.
pause
goto :eof
)

:createpart
REM Process each folder and block executables
if exist "C:\Program Files\Adobe" (
for /R "C:\Program Files\Adobe" %%X in (*.exe) do (
echo Blocking: %%~nX
netsh advfirewall firewall add rule name="%%~nX adobe-block" dir=out program="%%X" action=block
netsh advfirewall firewall add rule name="%%~nX adobe-block" dir=in program="%%X" action=block
)
)

if exist "C:\Program Files\Common Files\Adobe" (
for /R "C:\Program Files\Common Files\Adobe" %%X in (*.exe) do (
echo Blocking: %%~nX
netsh advfirewall firewall add rule name="%%~nX adobe-block" dir=out program="%%X" action=block
netsh advfirewall firewall add rule name="%%~nX adobe-block" dir=in program="%%X" action=block
)
)

if exist "C:\Program Files\Maxon Cinema 4D R25" (
for /R "C:\Program Files\Maxon Cinema 4D R25" %%X in (*.exe) do (
echo Blocking: %%~nX
netsh advfirewall firewall add rule name="%%~nX adobe-block" dir=out program="%%X" action=block
netsh advfirewall firewall add rule name="%%~nX adobe-block" dir=in program="%%X" action=block
)
)

if exist "C:\Program Files\Red Giant" (
for /R "C:\Program Files\Red Giant" %%X in (*.exe) do (
echo Blocking: %%~nX
netsh advfirewall firewall add rule name="%%~nX adobe-block" dir=out program="%%X" action=block
netsh advfirewall firewall add rule name="%%~nX adobe-block" dir=in program="%%X" action=block
)
)

if exist "C:\Program Files (x86)\Adobe" (
for /R "C:\Program Files (x86)\Adobe" %%X in (*.exe) do (
echo Blocking: %%~nX
netsh advfirewall firewall add rule name="%%~nX adobe-block" dir=out program="%%X" action=block
netsh advfirewall firewall add rule name="%%~nX adobe-block" dir=in program="%%X" action=block
)
)

if exist "C:\Program Files (x86)\Common Files\Adobe" (
for /R "C:\Program Files (x86)\Common Files\Adobe" %%X in (*.exe) do (
echo Blocking: %%~nX
netsh advfirewall firewall add rule name="%%~nX adobe-block" dir=out program="%%X" action=block
netsh advfirewall firewall add rule name="%%~nX adobe-block" dir=in program="%%X" action=block
)
)

echo Blocking completed.
pause
endlocal
