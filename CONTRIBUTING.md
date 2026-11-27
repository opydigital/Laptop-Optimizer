# Contributing to Laptop-Optimizer

Thank you for your interest in contributing to **Opydigital - Laptop Optimizer**!

## Guidelines

1. **Keep tweaks safe and reversible**: Every registry key, service, or system setting modified by `LaptopOptimizer.ps1` must have a corresponding backup and rollback path in `Invoke-Revert`.
2. **Avoid destructive or debloat-heavy changes**: This project focuses strictly on safe performance, responsiveness, and laptop battery-life optimizations.
3. **Language**: Keep all code, comments, commit messages, and documentation in **English**.
4. **Compatibility**: Target built-in **Windows PowerShell 5.1+** on Windows 11 with zero external module dependencies.

## Testing Your Changes

Before opening a pull request:

1. Validate PowerShell syntax with zero parse errors:
   ```powershell
   $t = $null; $e = $null
   [System.Management.Automation.Language.Parser]::ParseFile('.\LaptopOptimizer.ps1', [ref]$t, [ref]$e) | Out-Null
   $e
   ```
2. Run a non-destructive preview:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LaptopOptimizer.ps1 -DryRun
   ```
3. Verify apply and `-Revert` behavior on a test machine or VM.

## Pull Requests

- Fork the repository and create a feature branch from `main`.
- Update `docs/TWEAKS.md` and `CHANGELOG.md` when adding or modifying tweaks.
- Open a pull request describing the motivation, changes, and test results.
