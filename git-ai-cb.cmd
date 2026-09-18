@echo off
REM git-ai-cb Windows CMD wrapper.
REM Lets PowerShell / cmd.exe run: git-ai-cb <subcommand>
REM It locates Git Bash's bash.exe, then calls the sibling bash script.
setlocal enabledelayedexpansion

set "SELF=%~dp0git-ai-cb"
set "BASH="

REM 1) bash already in PATH
where bash.exe >nul 2>nul && set "BASH=bash.exe"

REM 2) common Git install paths
if not defined BASH if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"

REM 3) derive from git.exe location. git.exe is at <GitRoot>\cmd\git.exe
REM    so bash.exe is at <GitRoot>\bin\bash.exe (or usr\bin\bash.exe)
if not defined BASH (
    for /f "delims=" %%F in ('where git.exe 2^>nul') do (
        if not defined BASH (
            set "GITCMDDIR=%%~dpF"
            REM strip trailing backslash of cmd dir
            set "GITCMDDIR=!GITCMDDIR:~0,-1!"
            REM cmd dir's parent == Git root (e.g. D:\Software\Git\cmd -> D:\Software\Git)
            for %%D in ("!GITCMDDIR!\..") do set "ROOT=%%~fD"
            if exist "!ROOT!\bin\bash.exe" set "BASH=!ROOT!\bin\bash.exe"
            if not defined BASH if exist "!ROOT!\usr\bin\bash.exe" set "BASH=!ROOT!\usr\bin\bash.exe"
        )
    )
)

if not defined BASH (
    echo [git-ai-cb] Git Bash ^(bash.exe^) not found. Install Git for Windows first. 1>&2
    exit /b 1
)

if not exist "%SELF%" (
    echo [git-ai-cb] main script not found: %SELF% 1>&2
    exit /b 1
)

"%BASH%" "%SELF%" %*
exit /b %ERRORLEVEL%
