@echo off
title Opydigital - Laptop Optimizer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0LaptopOptimizer.ps1" %*
if errorlevel 1 pause
