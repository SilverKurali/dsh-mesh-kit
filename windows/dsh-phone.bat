@echo off
rem  dsh-phone.bat  ---  dsh-phone.ps1 的入口包装。双击即可，参数原样透传。
rem  Double-click to open the menu, or pass -Start / -Stop / -Status / -Check.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-phone.ps1" %*
if "%~1"=="" pause
