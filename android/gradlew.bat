@echo off
set DIR=%~dp0
call gradle -p "%DIR%" %*
