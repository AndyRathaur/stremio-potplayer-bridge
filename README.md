# Stremio PotPlayer Bridge

A high-performance, transparent multi-layer bridge that integrates **Daum PotPlayer** as the external media player for **Stremio Desktop** on Windows.

---

## Overview

Stremio Desktop provides native options to offload playback to external media players such as VLC and MPV. However, Daum PotPlayer is not natively selectable in the Stremio 5 user interface.

Simply pointing Stremio to PotPlayer or attempting to edit internal configuration files fails due to fundamental differences in command-line syntax, argument handling, and client-server architecture.

**Stremio PotPlayer Bridge** provides a seamless, zero-latency interception shim. When you select **VLC** inside Stremio settings, the bridge intercepts execution, sanitizes POSIX arguments, translates subtitle and timestamp parameters into native PotPlayer switches, and hands off playback to PotPlayer without terminal flashes or playback delays.

---

## Architectural Challenges & Root Causes

### 1. Stremio 5 Architecture (Frontend vs Streaming Server)
Stremio 5 (`stremio-shell-ng`) uses a decoupled architecture:
* **Frontend**: An Electron / WebView2 user interface with a hardcoded, static client-side list of supported external players (`vlc`, `mpv`, `iina`, `mxplayer`, `justplayer`).
* **Streaming Engine**: A local Node.js streaming service (`server.js`) listening on `127.0.0.1:11470`.

Because the frontend player list is static and hardcoded into the compiled user interface bundle, modifying `server.js` alone is insufficient: the UI dropdown never exposes "PotPlayer" as an option.

### 2. POSIX Option Delimiter (`--`) Incompatibility
Stremio spawns external players adhering to POSIX command-line conventions:
```cmd
vlc.exe <options> -- "<stream_or_playlist_url>"
```
The double dash (`--`) informs POSIX-compliant parsers that all subsequent tokens are positional operands (URLs or files) rather than flags.
* VLC recognizes `--` and plays the URL that follows.
* PotPlayer's parser does **not** treat `--` as a delimiter; instead, it attempts to load `--` as a literal file path or playlist target, resulting in invalid path errors, hung processes, or aborted playback.

### 3. Argument & Parameter Translation
VLC and PotPlayer use entirely incompatible command-line switches:
* **Subtitles**: Stremio passes subtitles via `--sub-file="<path>"`. PotPlayer requires `/sub="<path>"`.
* **Seek / Start Time**: Stremio passes resume timestamps via `--start-time=<seconds>` or `-ss <seconds>`. PotPlayer expects `/seek=<time>`.
* **Instance Control**: PotPlayer defaults to spawning a new window instance for each invocation unless the `/current` flag is passed.
* **URL Scheme Headers**: Invocations triggered through OS protocol handlers receive `vlc://<url>` or `potplayer://<url>`, which must be stripped before being passed to the player binary.

### 4. Query Parameter Escaping & Windows Shell Execution
Stremio frequently passes streaming URLs with complex query strings (containing query parameters like `token=`, `from=`, or signature hashes). If an external player wrapper is spawned via intermediate command shells (`cmd.exe /c start`), unquoted or improperly escaped ampersands (`&`) cause the Windows shell to truncate arguments or attempt to execute subsequent parameters as separate commands.

---

## Interception Architecture

The bridge implements a defense-in-depth, multi-layer interception strategy across Windows execution surfaces:

```
+-----------------------------------------------------------+
|                      Stremio Desktop                      |
|       (Player Setting configured to "VLC Player")         |
+-----------------------------------------------------------+
        |                                   |
   Direct Process Spawn                URL Protocol / App Paths
        |                                   |
        v                                   v
+-------------------------------+   +-------------------------------+
|  Filesystem Shim              |   |  Windows Registry             |
|  - C:\Program Files\...\VLC\  |   |  - App Paths\vlc.exe          |
|    vlc.exe -> Bridge Binary   |   |  - Classes\Applications\...   |
+-------------------------------+   |  - Protocol: vlc://           |
        |                           +-------------------------------+
        |                                           |
        +-------------------+-----------------------+
                            |
                            v
+-----------------------------------------------------------+
|              potplayer-stremio-bridge.exe                 |
|  - Strips POSIX delimiters ('--', '-')                   |
|  - Translates --sub-file to /sub=                         |
|  - Translates --start-time to /seek=                      |
|  - Enforces /current window reuse                         |
|  - Discards incompatible VLC interface flags              |
|  - Resolves PotPlayerMini64.exe location dynamically      |
+-----------------------------------------------------------+
                            |
                            v
+-----------------------------------------------------------+
|                     Daum PotPlayer                        |
|  Active window playback with synchronized stream & subs   |
+-----------------------------------------------------------+
```

### Layer Details:
1. **Binary Shim (`potplayer-stremio-bridge.exe`)**:
   * Compiled as a native Win32 windowed application (`/target:winexe`), ensuring **zero console window flash**.
   * Written in C# with zero third-party dependencies, targeting the pre-installed .NET Framework 4.x runtime (`csc.exe`).
   * Dynamically resolves the PotPlayer executable across standard 64-bit and 32-bit directories, `LocalAppData`, the Windows `App Paths` registry, and system `PATH`.
   * Includes automated fallback logging to `%LOCALAPPDATA%\PotPlayerBridge\potplayer-bridge.log` if execution directory lacks write permissions.

2. **Filesystem Interception**:
   * Deploys the bridge binary into `C:\Program Files (x86)\VideoLAN\VLC\vlc.exe` and `C:\Program Files\VideoLAN\VLC\vlc.exe`.
   * If a real VLC installation is present, the setup script preserves the original binary as `vlc-original.exe`.
   * Satisfies hardcoded filesystem checks in Stremio's internal streaming server routines.

3. **Registry Redirection (`App Paths` & `Applications`)**:
   * Intercepts `HKLM` and `HKCU` entries for `SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\vlc.exe`.
   * Intercepts `SOFTWARE\Classes\Applications\vlc.exe\shell\open\command`.

4. **URL Protocol Scheme Interception**:
   * Registers protocol handlers for `vlc://` under `HKCU:\Software\Classes\vlc` and `HKLM:\SOFTWARE\Classes\vlc`.
   * Captures external play requests dispatched via Windows `ShellExecute`.

5. **VBScript Fallback (`potplayer-stremio-bridge.vbs`)**:
   * A standalone WSH VBScript engine fallback capable of identical sanitization without requiring binary compilation.

---

## File Structure

| File | Purpose |
| :--- | :--- |
| `potplayer-stremio-bridge.cs` | Source code for the high-performance argument sanitizing bridge binary. |
| `setup-potplayer-stremio-bridge.ps1` | Automated deployment, registry configuration, backup, and uninstallation manager. |
| `build.bat` | Command-line build script using Microsoft .NET Framework `csc.exe`. |
| `build.ps1` | PowerShell build script for the bridge executable. |
| `potplayer-stremio-bridge.vbs` | Standalone script-based fallback bridge. |
| `.gitignore` | Ignores generated binaries (`.exe`), log files, and build artifacts. |

---

## Installation & Setup

### Prerequisites
* Windows 10 or Windows 11 (64-bit or 32-bit).
* [Daum PotPlayer](https://potplayer.daum.net/) installed.
* [Stremio Desktop](https://www.stremio.com/) installed.
* Administrative privileges (for registry and `Program Files` access).

### Method 1: Automated One-Click Setup (Recommended)

1. Open PowerShell as **Administrator**.
2. Run the registration action:
   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process -Force
   .\setup-potplayer-stremio-bridge.ps1 -Action Register
   ```
3. The setup script will:
   * Compile `potplayer-stremio-bridge.exe` using Windows' built-in `csc.exe`.
   * Backup any existing `vlc.exe` installations.
   * Install the binary shims into the VideoLAN target paths.
   * Configure Windows App Paths and `vlc://` protocol handlers.
4. Verify the status:
   ```powershell
   .\setup-potplayer-stremio-bridge.ps1 -Action Status
   ```

### Method 2: Manual Compilation

If you prefer to compile the bridge binary independently:
```cmd
build.bat
```
or via PowerShell:
```powershell
.\build.ps1
```
The compiler will output `potplayer-stremio-bridge.exe` in the project root.

---

## Configuring Stremio

1. Launch **Stremio**.
2. Click the gear icon (**Settings**) in the upper right corner.
3. Navigate to **Player**.
4. Set **Play in external player** to **VLC**.
5. Select any video stream to start playback. PotPlayer will automatically launch with the media stream, proper seek position, and synchronized subtitles.

---

## Uninstallation & Rollback

To completely remove all shims, restore original registry settings, and restore any backed-up VLC binaries:

1. Open PowerShell as **Administrator**.
2. Run:
   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process -Force
   .\setup-potplayer-stremio-bridge.ps1 -Action Unregister
   ```
3. The script will:
   * Restore `vlc.exe` from `vlc-original.exe` (if VLC was originally installed).
   * Remove filesystem shims.
   * Remove custom `HKCU` and `HKLM` protocol and application registrations.

---

## Logging & Diagnostics

The bridge maintains a detailed diagnostic log capturing raw incoming arguments, sanitized arguments, and dispatched process calls.

* **Log Location**:
  * Alongside the executable: `potplayer-bridge.log`
  * Or user fallback: `%LOCALAPPDATA%\PotPlayerBridge\potplayer-bridge.log`

Example log output:
```text
[2026-11-20 04:05:12.184] Incoming raw args (3): -url | -- | http://127.0.0.1:11470/stream
[2026-11-20 04:05:12.185] Launching PotPlayer: C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe with args: /current "http://127.0.0.1:11470/stream"
```

---

## License

MIT License. See [LICENSE](LICENSE) for details.
