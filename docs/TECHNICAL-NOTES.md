# Technical notes

Field notes from diagnosing this failure on a real machine. Everything below was
observed, not guessed; the error strings are copied verbatim from Windows event
logs and `sc.exe` output.

## 1. What the deployment log says

`Microsoft-Windows-AppXDeploymentServer/Operational` shows, in order:

| Id | Level | Message (trimmed) |
| --- | --- | --- |
| 855 | 4 | `updateList: Vendor.App_1.2.3.0_x64__abcdefghijk is updating to Vendor.App_1.4.0.0_x64__abcdefghijk` |
| 9626 / 9627 | 4 | `PackagedServiceDEH: analyzed the install manifest of the new version and the removal manifest of the old one` |
| 667 / 638 | 3 | `The package was not updated because an affected app is still running` |
| 9648 | 4 | `TerminateSingleService` succeeded |
| 679 | 4 | `OnDemandRegisterPackageList` |
| 821 | 2 | `Registration at login finished with result: 0x80073CF6` |
| 306 / 316 | 2 | `0x80070005` -- `failed to register the windows.service extension: Access is denied` |
| 331 | 2 | `0x8007139F` -- state is not correct for the requested operation (rollback path) |
| 300 / 401 / 404 | 2 | `0x80073CF6` -- could not register the package; operation on target volume failed |

Nothing else follows: every retry reproduces exactly this tail. The deployment
never gets past the service extension, so the package stays in a stale state and
`Status` reads `Servicing` / `Staged`.

## 2. What the package declares

`AppxManifest.xml`:

```xml
<desktop6:Extension Category="windows.service"
                       Executable="app\resources\agent.exe">
  <desktop6:Service Name="Vendor.Agent"
                     StartupType="auto"
                     StartAccount="localSystem" />
</desktop6:Extension>
```

`Package/Identity`: `Vendor.App`, publisher id `abcdefghijk`,
full name `Vendor.App_1.2.3.0_x64__abcdefghijk`.

## 3. What the orphaned registration looks like

```
HKLM\SYSTEM\CurrentControlSet\Services\Vendor.Agent

ImagePath        REG_EXPAND_SZ  "C:\Program Files\WindowsApps\Vendor.App_1.2.3.0_x64__abcdefghijk\app\resources\agent.exe"
Type             REG_DWORD      0x210   (WIN32_PACKAGED_PROCESS)
Start            REG_DWORD      3       (demand; was 2 = automatic in a healthy state)
ObjectName       REG_SZ         LocalSystem
ServiceSidType   REG_DWORD      1
PackageFullName  REG_SZ         Vendor.App_1.2.3.0_x64__abcdefghijk
AppUserModelId   REG_SZ         Vendor.App_abcdefghijk!App
PackageOrigin    REG_DWORD      3       (store)
DependOnService  REG_MULTI_SZ   staterepository
```

`Test-Path` on that `ImagePath` returns `False`, and there is no such directory
under any `WindowsApps` folder. This is the entire failure: the registration
points at a package version that has already been removed.

## 4. The security descriptor, decoded

```
D:(A;;CCLCSWRPWPDTLOCRRC;;;AU)
  (A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;S-1-5-80-1949724575-2387902436-65106593-1201171665-3967308604)
```

Two ACEs, both `Allow`:

| Trustee | Rights | Result |
| --- | --- | --- |
| `AU` (Authenticated Users) | `CC LC SW RP WP DT LO CR RC` | query config, query status, enumerate dependents, **start**, **stop**, pause/continue, interrogate, user control, read control |
| service SID `S-1-5-80-...` | `CC DC LC SW RP WP DT LO CR SD RC WD WO` | everything, including `DC` (change config) and `SD` (delete) |

This descriptor is **not** specific to the failing app. On the same machine two
unrelated Microsoft-owned packaged services reported a byte-identical
descriptor, including the same `S-1-5-80` SID, which makes that SID look like a
shared service SID rather than one derived from the service name. It is the
normal shape for `WIN32_PACKAGED_PROCESS` services, and it is the reason the SCM
route is unavailable -- not something a single vendor broke.

What is missing from `AU`: `DC` (SERVICE_CHANGE_CONFIG) and `SD` (DELETE). What
is missing entirely: `BA` (BUILTIN\Administrators) and `SY` (NT AUTHORITY\SYSTEM).

Consequences, all confirmed on the machine:

| Command | Outcome |
| --- | --- |
| `sc.exe query Vendor.Agent` | works (`RC` present) |
| `sc.exe sdshow Vendor.Agent` | works -- this is how the descriptor above was read |
| `Stop-Service Vendor.Agent -Force` | **works** (`WP` present) |
| `sc.exe delete Vendor.Agent` | `[SC] OpenService FAILED 5: Access is denied` |
| `sc.exe config Vendor.Agent start=auto` | `Access is denied` |
| `sc.exe sdset Vendor.Agent <sddl>` | `Access is denied` (needs `WD`) |
| `Set-Service -Name Vendor.Agent -StartupType Automatic` | `Access is denied` |
| writing `...\Services\Vendor.Agent\Security` | key exists but empty; setting it changes nothing |
| `Remove-AppxPackage` | does not run (package is not healthy) |

Elevation does not help, because the ACEs are not additive with your group
memberships in a way that matters here: the object grants `AU` and one package
SID, and an elevated administrator is still just `AU` for this object. There is
no `BA` ACE to be matched.

## 5. Why deleting the registry key works

The ACL of the *registry key* is a different object with different permissions:

```
HKLM\SYSTEM\CurrentControlSet\Services\Vendor.Agent
  Owner: BUILTIN\Administrators
  BUILTIN\Administrators : FullControl (Allow)
```

So `Remove-Item -Recurse -Force` (or `reg.exe delete /f`) removes the
registration even though the *service object* would refuse the equivalent
operation. The SCM never gets asked.

Right after the delete, `Get-Service Vendor.Agent` may still answer for a while --
the service record is cached in the services.exe process. That is why a
registration attempt before the reboot still fails with the same
`0x80070005`: the SCM tries to update a record whose backing key is gone or whose
cached security descriptor is still in force.

After a reboot the cache is gone, no service is registered, and package
registration creates a clean one pointing at the new version.

### An open question

Creating a registration from scratch succeeds, while reconciling an existing one
is denied with `0x80070005`. The most likely explanation is that creation only
needs access to the SCM database, whereas reconciliation opens the existing
service object and needs rights its descriptor does not grant -- `SY` is absent,
and deployment does not run as the service SID. This was not proven with a
debugger or an access trace, so treat it as the leading hypothesis.

It does not change the repair either way: remove the registration, let
deployment create a new one, and the update goes through.

## 6. Why the other popular fixes do not work

| Approach | Why it fails |
| --- | --- |
| `sc.exe delete` / `sdset` / `config` | the service object denies the operation (§4) |
| Editing the `Security` subkey | the SCM does not read the DACL from there for packaged services; the key is an empty artifact |
| `icacls` on `C:\Program Files\WindowsApps\<pkg>` | that repairs *filesystem* ACLs. The registration does not fail on the filesystem; it fails on the service object's descriptor. Deployment logs an unrelated-looking "ACLs repaired successfully" (event 649) and then fails anyway |
| Uninstall / reinstall | often impossible while the package is stuck in `Servicing`; and it recreates the same registration |
| `Reset-AppxPackage` / `Add-AppxPackage -ForceUpdateFromAnyVersion` | neither touches the service registration |
| Deleting `%LOCALAPPDATA%\Packages\<family>` | user data only |

## 7. Why the scheduled task in phase 2

Deployment registration has to happen in an interactive, elevated session after
the reboot. Two constraints shaped the design:

- Running it from the same elevated console that performed phase 1 is not
  possible, because the reboot intervenes.
- `AtLogOn` + `RunLevel Highest` is the only trigger available without asking
  the user to remember a command.

The task also has to be created *before* the reboot (it lives on disk), and it
deletes itself once the repair succeeds. This avoids leaving a permanent
elevated logon task on the machine.

## 8. Variants seen in the wild

- **`0x80073D26`** -- `The windows.service extension cannot be registered
  because a different version of the service is already installed.` Here the old
  registration may still resolve to an existing executable, typically because
  the previous version was never fully removed. Auto-detection cannot see it;
  pass `-ServiceName` explicitly. Same repair applies.
- **`0x80070424`** -- `The specified service does not exist as an installed
  service.` Reported after uninstall/reinstall cycles: the manifest still
  declares the service but the registration was removed by uninstall and
  deployment fails to recreate it. Also fixed by phase 1 + reboot.
- **`windows.fileTypeAssociation`** -- the same class of failure on a different
  extension. The log names the extension; this tool is specific to
  `windows.service`.

## 9. Why the app then looks hung on first launch

After a successful registration the first start of a cross-version update can
take minutes. On the machine this was written on, the new version directory held
about 3,600 files including a 329 MB `chrome.dll`; the new binary is scanned by
Defender on first execution and the renderer cache is rebuilt from scratch.

Symptoms during that window: several processes, tens of MB of working set, near
zero CPU, no application log output yet, and no window. Killing them restarts the
cycle. The reliable progress signal is the application's own log file under
`%LOCALAPPDATA%\Packages\<family>\LocalCache\Local\...\Logs`, which only starts
being written once the app is genuinely initialising.

`Get-Process ... MainWindowHandle` is **not** a reliable check: in restricted
environments it can read `0` for every process, including ones with visible
windows.
