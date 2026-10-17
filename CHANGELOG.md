# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned

- Detect the `0x80073D26` variant ("a different version of the service is already
  installed") without requiring `-ServiceName`.
- Optional `-WhatIf` dry run for phase 1, showing the exact registry keys that
  would be removed.
- Support for repairing registrations whose executable still exists but whose
  `PackageFullName` names a removed version.

## [1.0.0] - 2026-10-17

First public release.

### Added

- `Fix-PackagedAppService.ps1` with three modes:
  - `-Diagnose` (default): read-only report of every `WIN32_PACKAGED_PROCESS`
    service, its target path, its security descriptor, the newest staged package
    version, and the recent AppX deployment errors.
  - `-Fix`: phase 1 -- stop and remove service registrations whose executable
    path no longer exists, save the affected package families to a state file,
    and schedule phase 2 for the next logon.
  - `-Phase2`: re-register the affected packages and verify the result; invoked
    automatically by the scheduled task, or manually as a fallback.
- Registry-based removal of orphaned service registrations. This works where
  `sc.exe delete`, `sc.exe config`, `sc.exe sdset` and `Set-Service` all fail
  with `Access is denied`, because the service object's security descriptor does
  not grant `BUILTIN\Administrators` or `NT AUTHORITY\SYSTEM`, while its
  registry key does grant Administrators Full Control.
- Phase 2 registration fallbacks, tried in order:
  `Add-AppxPackage -Register <manifest>`, the same with
  `-DisableDevelopmentMode`, `Add-AppxPackage -RegisterByFamilyName`, and
  `Add-AppxPackage -Path <file>` when `-MsixPath` was supplied.
- Automatic self-elevation, so the script can be started from a normal prompt.
- Scoping parameters `-PackageFamilyName` and `-ServiceName`, plus `-Reboot` and
  `-Yes` for unattended use.
- Self-deleting one-shot scheduled task, so no permanent elevated logon task is
  left behind.
- `run-fix.cmd`: ASCII-only launcher, safe to double-click.
- `docs/TECHNICAL-NOTES.md`: event chain, SDDL decoding, why the common
  workarounds do not help, and the open question about which access check fails
  during reconciliation.
- Bilingual documentation: `README.md` in English and `README.zh-CN.md` in
  Simplified Chinese, with a language line at the top of both files.

### Notes

- The script is deliberately written in pure ASCII. Windows PowerShell 5.1
  decodes a BOM-less `.ps1` with the system ANSI code page, so non-ASCII text in
  a script produces misleading `Missing closing '}'` parser errors on
  non-English systems.
- No network access, no telemetry, no credentials are read or stored.

### Known issues

- Reproducing the failure requires an affected machine; the destructive phase 1
  path was validated against a real incident, but not in an automated test.
- The repair is not permanent: later package updates can recreate the same
  condition, in which case the tool simply has to be run again.

[Unreleased]: https://github.com/Zhang-0721/fix-packaged-app-service/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Zhang-0721/fix-packaged-app-service/releases/tag/v1.0.0
