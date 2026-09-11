@echo off
setlocal enabledelayedexpansion
rem -----------------------------------------------------------------------------
rem Synopsis:
rem   Launches ClientVaultAccessMSIBuilder.ps1 with a simple positional contract.
rem   - no args: language menu in PS script, then default 3-profile build
rem   - one lang arg (fr|fra|en|eng): build default 3 profiles in that language
rem   - two args: <profile> <lang>
rem
rem Author: Harry Joseph
rem Updated: 2026-07-19
rem -----------------------------------------------------------------------------
title M-Files MSI Builder
cls
cd /d "%~dp0"
set "KIT_ROOT=%~dp0"
set "PS1_PATH=%KIT_ROOT%ClientVaultAccessMSIBuilder.ps1"

set "ARG1=%~1"
set "ARG2=%~2"
set "ARG3=%~3"
set "PS_ARGS="
set "OVERRIDE_SERVER_ADDRESS=%SERVER_ADDRESS%"
if defined MFILES_SERVER_ADDRESS set "OVERRIDE_SERVER_ADDRESS=%MFILES_SERVER_ADDRESS%"

if not "%ARG1%"=="" (
    call :ValidateSafeValue "%ARG1%" "argument 1" || exit /b 1
)
if not "%ARG2%"=="" (
    call :ValidateSafeValue "%ARG2%" "argument 2" || exit /b 1
)
if defined OVERRIDE_SERVER_ADDRESS (
    call :ValidateSafeValue "%OVERRIDE_SERVER_ADDRESS%" "SERVER_ADDRESS" || exit /b 1
)

if not "%ARG3%"=="" (
    echo [ERROR] Too many arguments.
    echo Usage:
    echo   start.bat
    echo   start.bat fra^|eng
    echo   start.bat conformity^|approbation^|both fra^|eng
    exit /b 1
)

if not "%ARG1%"=="" (

    set "LANG1="
    if /i "%ARG1%"=="fr"  set "LANG1=fra"
    if /i "%ARG1%"=="fra" set "LANG1=fra"
    if /i "%ARG1%"=="en"  set "LANG1=eng"
    if /i "%ARG1%"=="eng" set "LANG1=eng"

    if defined LANG1 (
        rem One argument, recognized as a language token: menu bypassed, full 3-profile default set.
        set "PS_ARGS= -Lang ""!LANG1!"""
    ) else (
        rem First argument is not a language token: treat it as the profile name.
        set "PS_ARGS= -Profile ""%ARG1%"""

        if "%ARG2%"=="" (
            rem Profile given alone: still no menu: default silently to French, same as a bare Enter would.
            set "PS_ARGS=!PS_ARGS! -Lang fra"
        ) else (
            set "LANG2="
            if /i "%ARG2%"=="fr"  set "LANG2=fra"
            if /i "%ARG2%"=="fra" set "LANG2=fra"
            if /i "%ARG2%"=="en"  set "LANG2=eng"
            if /i "%ARG2%"=="eng" set "LANG2=eng"

            if defined LANG2 (
                set "PS_ARGS=!PS_ARGS! -Lang ""!LANG2!"""
            ) else (
                set "PS_ARGS=!PS_ARGS! -Lang ""%ARG2%"""
            )
        )
    )
)

if defined OVERRIDE_SERVER_ADDRESS (
    rem Optional override for generated client NetworkAddress while preserving positional arg contract.
    rem Accepts either DNS name/FQDN (e.g. mfiles-srv01.contoso.local) or IP address.
    set "PS_ARGS=!PS_ARGS! -ServerAddress ""%OVERRIDE_SERVER_ADDRESS%"""
)

if not exist "%PS1_PATH%" (
    echo [ERROR] Required script not found: "%PS1_PATH%"
    exit /b 1
)

rem Keep execution through COMSPEC/cmd for consistent behavior regardless of parent shell.
"%ComSpec%" /d /c powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1_PATH%" !PS_ARGS!
exit /b %ERRORLEVEL%

:ValidateSafeValue
set "RAW=%~1"
set "LABEL=%~2"
if not defined RAW exit /b 0

rem Reject any internal double quotes
set "TMP=!RAW:"=!"
if not "!RAW!"=="!TMP!" goto :UnsafeValue

rem Strict character whitelist: only alphanumeric, dot, hyphen, underscore, and colon
for /f "tokens=1 delims=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:" %%A in ("!RAW!") do goto :UnsafeValue
exit /b 0

:UnsafeValue
echo [ERROR] Unsafe characters detected in %LABEL%.
exit /b 1
