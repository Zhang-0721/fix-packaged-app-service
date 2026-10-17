# Fix-PackagedAppService

**English** | [简体中文](README.zh-CN.md)

Repair tool for MSIX / Microsoft Store apps that stop installing or updating with

```
0x80073CF6   AppX deployment of package ... failed
             Underlying error: 0x80070005 -- Access is denied while registering
             the windows.service extension
```

It fixes the **orphaned packaged-service registration** that causes it, using a
route that does not depend on the service's own (broken) security descriptor.

Windows PowerShell 5.1 · no dependencies · no network access · no telemetry

---

## TL;DR

```powershell
# 1. Look, change nothing
.\Fix-PackagedAppService.ps1 -Diagnose

# 2. Remove the orphaned service registrations (self-elevates)
.\Fix-PackagedAppService.ps1 -Fix

# 3. Reboot. Phase 2 runs automatically at logon and re-registers the package.
```

Or double-click `run-fix.cmd`, or `run-fix.cmd -Fix`.

---

## The symptom

A store app updates, or a fresh install is attempted, and deployment dies:

| Deployment event | Text |
| --- | --- |
| 306 / 316 | `0x80070005 ... failed to register the windows.service extension: Access is denied` |
| 331 | `0x8007139F ... the state is not correct for the requested operation` while rolling back |
| 300 / 401 / 404 | `0x80073CF6 ... could not register the package` (whole deployment rolls back) |
| 855 | `updateList: <Name>_<oldVersion> is updating to <Name>_<newVersion>` |

The app usually still opens, but each launch triggers the pending update, the
update fails again, and eventually nothing starts any more. `Get-AppxPackage`
may show the package as `Status = Servicing` / `Staged`, and

```powershell
Add-AppxPackage -Register ...
Add-AppxPackage -Path .\App.msix
```

fail with the same `0x80070005`.

## Root cause

An MSIX package may declare a Windows service:

```xml
<desktop6:Extension Category="windows.service" Executable="app\resources\agent.exe">
  <desktop6:Service Name="Vendor.Agent" StartupType="auto" StartAccount="localSystem" />
</desktop6:Extension>
```

Deployment materialises that as a real registration under

```
HKLM\SYSTEM\CurrentControlSet\Services\Vendor.Agent
```

with `Type = 0x210` (`WIN32_PACKAGED_PROCESS`) and an `ImagePath` pointing into
the package directory:

```
...\WindowsApps\Vendor.App_1.2.3.0_x64__abcdefghijk\app\resources\agent.exe
```

When a newer version is staged, deployment is supposed to re-point that
registration at the new version directory. **When that step fails, the
registration keeps pointing at a directory that no longer exists**, and every
later registration attempt aborts on the same service extension.

Two things then make it unrecoverable through the normal tools:

1. **The service security descriptor does not include `BUILTIN\Administrators`
   or `NT AUTHORITY\SYSTEM`.** Typical shape:

   ```
   D:(A;;CCLCSWRPWPDTLOCRRC;;;AU)
     (A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;S-1-5-80-1949724575-2387902436-65106593-1201171665-3967308604)
   ```

   Only `Authenticated Users` (query/start/stop rights) and one service SID (full
   rights) are granted. This is the *normal* shape for packaged services --
   unrelated Microsoft-owned services on the same machine carry a byte-identical
   descriptor -- so it is not something a vendor broke. Its consequence is still
   hard: nobody else, not even an elevated administrator, can use the SCM on that
   object.

   ```
   > sc.exe delete Vendor.Agent
   [SC] OpenService FAILED 5:
   Access is denied.
   ```

   The same applies to `sc.exe config`, `sc.exe sdset`, `Set-Service`, and to
   writing `...\Services\<name>\Security` (that subkey does not persist the
   descriptor either).

2. **The service registry key is fine.** That key is owned by
   `BUILTIN\Administrators` and grants them Full Control. The registration can
   therefore be deleted straight from the registry, and only the SCM's in-memory
   cache has to be dropped afterwards -- which is exactly what a reboot does.

That asymmetry is the whole trick this tool uses.

## How it works

### Phase 1 (`-Fix`)

1. Enumerate services with `Type = 0x210` under
   `HKLM\SYSTEM\CurrentControlSet\Services`.
2. Keep the ones whose `ImagePath` **does not exist** (optionally filtered by
   `-PackageFamilyName` or `-ServiceName`).
3. `Stop-Service`, then delete the registry key
   (`Remove-Item -Recurse`, with `reg.exe delete /f` as a fallback).
4. Save the affected package families to
   `%ProgramData%\PackagedServiceRepair\state.json`.
5. Register a one-shot scheduled task that runs phase 2 at the next logon with
   `RunLevel Highest`.
6. Ask for a reboot.

The reboot is not optional: the service manager caches service records in
memory, so a registration attempted before the restart still fails.

### Phase 2 (`-Phase2`, automatic after logon)

1. Wait for the shell and the state repository to settle.
2. Re-register the package, trying in order:
   - `Add-AppxPackage -Register <newest staged AppxManifest.xml>`
   - the same with `-DisableDevelopmentMode`
   - `Add-AppxPackage -RegisterByFamilyName -MainPackage <PFN>`
   - `Add-AppxPackage -Path <your .msix>` if you passed `-MsixPath`
3. Verify the service registration now resolves, and start the service.
4. Send a launch request for the app.
5. Show the newest deployment errors and delete the scheduled task.

## Verification

```powershell
# the registration points at a file that exists again
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Vendor.Agent' | Select-Object ImagePath, Start
Test-Path ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Vendor.Agent').ImagePath.Trim('"'))

# and the deployment succeeded
Get-WinEvent -FilterHashtable @{
  LogName   = 'Microsoft-Windows-AppXDeploymentServer/Operational'
  StartTime = (Get-Date).AddHours(-1)
} | Where-Object Id -in 400,404 | Format-Table TimeCreated, Id, Message -Wrap
```

A successful outcome is event **400** (`... operation completed successfully`)
with no following 404/300.

The first launch after a cross-version update can take a long time -- tens of
seconds, sometimes minutes -- while the renderer cache is rebuilt and the new
binary is scanned by the antivirus. It is easy to mistake that for a hang.

## Safety

- `-Diagnose` is strictly read-only.
- `-Fix` only deletes service registrations whose executable path is already
  gone. If a registration still resolves, it is left alone unless you name it
  with `-ServiceName`.
- Scope it further with `-PackageFamilyName`.
- The tool makes **no network calls**, collects **no telemetry**, and reads **no
  credentials**.
- Read the source before running it. It is a few hundred lines of plain
  PowerShell.

## Known limitations

- **The fix is not permanent.** Every package update has to reconcile the
  service registration again, and the same failure can return. If it does, run
  the tool again -- it is idempotent.
- **Variant `0x80073D26`** ("the windows.service extension cannot be registered
  because a different version of the service is already installed"): here the
  stale registration may still point at an existing file, so auto-detection
  skips it. Name it explicitly:

  ```powershell
  .\Fix-PackagedAppService.ps1 -Fix -ServiceName 'Vendor.Agent'
  ```

- **Never-installed packages**: if no version ever registered successfully,
  phase 2 has nothing staged to register. Pass the package file:

  ```powershell
  .\Fix-PackagedAppService.ps1 -Fix -MsixPath .\App-x64.msix -Reboot
  ```

- Some hardened environments deny the registry delete as well. `-Fix` reports
  that instead of pretending it worked.

## Troubleshooting

| Observation | Meaning |
| --- | --- |
| `-Diagnose` lists nothing | No `windows.service` extension, or the installed version registered cleanly. Check the filters, and look at the deployment log it prints. |
| Phase 1 says "Access is denied" on delete | The registry key is read-only for you. Run from a genuinely elevated session (the process token, not just an admin account). |
| Phase 2 still reports `0x80070005` | The service cache was not flushed: the machine was not rebooted, or the old process came back. Reboot, then run `-Phase2` by hand. |
| Phase 2 reports `0x80073CF6` for another extension | A different manifest extension is failing. The deployment log names it; `windows.fileTypeAssociation` is a known sibling. |
| Everything succeeds but the app is slow to open | Expected on the first start after an update. Wait it out instead of killing the process. |

## Related upstream reports

Same defect, different vendors -- all of them packaged services:

- `openai/codex` #53132, #45511, #25770
- `anthropics/claude-code` #57035, #78873, #76357, #92141
- `microsoft/msix-packaging` #558

Note that the widely-shared `icacls` recipes in those threads repair the
**package directory** ACLs. That is not where the failure lives: registration
dies on the **service object's** security descriptor, which is why those recipes
report success and change nothing.

## Compatibility

- Windows 10 1809+ / Windows 11
- Windows PowerShell 5.1 (the inbox one). PowerShell 7 is not required.
- The script is written in pure ASCII on purpose: Windows PowerShell 5.1 decodes
  a BOM-less `.ps1` with the system ANSI code page, so non-ASCII text inside a
  script can produce bogus `Missing closing '}'` parser errors on non-English
  systems.

## License

MIT. Not affiliated with Microsoft, OpenAI, or Anthropic.

See [CHANGELOG.md](CHANGELOG.md) for the version history.
