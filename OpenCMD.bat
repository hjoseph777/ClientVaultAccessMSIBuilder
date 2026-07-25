@echo off
set TARGETDIR=ClientVaultAccessMSIBuilder

if exist "%USERPROFILE%\Desktop\%TARGETDIR%" (
    cd /d "%USERPROFILE%\Desktop\%TARGETDIR%"
) else if exist "%USERPROFILE%\OneDrive\Desktop\%TARGETDIR%" (
    cd /d "%USERPROFILE%\OneDrive\Desktop\%TARGETDIR%"
) else (
    echo Directory not found.
    exit /b
)

cmd.exe /k
