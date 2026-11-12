@echo off
rem Refresh PMC stream links in My_Playlist.m3u from public sources (no login).
rem   update_links.bat           run, then wait for a key
rem   update_links.bat /auto     run without pausing (Task Scheduler)
rem   update_links.bat /nopush   update the file but don't commit/push
setlocal
set "PSARGS="
if /i "%~1"=="/nopush" set "PSARGS=-NoPush"
if /i "%~2"=="/nopush" set "PSARGS=-NoPush"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update_links.ps1" %PSARGS%
set "ERR=%ERRORLEVEL%"

if /i not "%~1"=="/auto" if /i not "%~2"=="/auto" pause
exit /b %ERR%
