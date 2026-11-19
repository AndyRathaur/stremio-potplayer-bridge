using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using Microsoft.Win32;

namespace PotPlayerBridge
{
    class Program
    {
        static void Main(string[] args)
        {
            try
            {
                Log("Incoming raw args (" + (args != null ? args.Length : 0) + "): " + (args != null ? string.Join(" | ", args) : "null"));

                string potplayer = FindPotPlayer();
                if (string.IsNullOrEmpty(potplayer))
                {
                    Log("PotPlayer executable not found in registry, standard paths, or PATH.");
                    return;
                }

                bool hasInstanceFlag = false;
                string seekArg = null;
                string subArg = null;
                List<string> targetItems = new List<string>();
                List<string> extraPotPlayerFlags = new List<string>();

                if (args != null)
                {
                    for (int i = 0; i < args.Length; i++)
                    {
                        string rawArg = args[i];
                        if (string.IsNullOrWhiteSpace(rawArg)) continue;

                        string arg = rawArg.Trim();

                        // 1. POSIX option delimiters / stdin indicators: Discard!
                        // Stremio passes "--" before media URLs which breaks PotPlayer CLI parsing.
                        if (arg == "--" || arg == "-")
                        {
                            continue;
                        }

                        // 2. Existing PotPlayer native switches (/current, /new, /sub=, /seek=, etc.)
                        if (arg.StartsWith("/", StringComparison.OrdinalIgnoreCase))
                        {
                            if (arg.Equals("/current", StringComparison.OrdinalIgnoreCase) ||
                                arg.Equals("/new", StringComparison.OrdinalIgnoreCase))
                            {
                                hasInstanceFlag = true;
                                extraPotPlayerFlags.Add(arg);
                            }
                            else if (arg.StartsWith("/seek=", StringComparison.OrdinalIgnoreCase))
                            {
                                seekArg = arg;
                            }
                            else if (arg.StartsWith("/sub=", StringComparison.OrdinalIgnoreCase))
                            {
                                subArg = arg;
                            }
                            else
                            {
                                extraPotPlayerFlags.Add(arg);
                            }
                            continue;
                        }

                        // 3. Subtitle options (--sub-file=... or --sub-file <path>)
                        if (arg.StartsWith("--sub-file=", StringComparison.OrdinalIgnoreCase))
                        {
                            string sub = arg.Substring(11).Trim('"', '\'');
                            subArg = "/sub=\"" + sub + "\"";
                            continue;
                        }
                        if (arg.Equals("--sub-file", StringComparison.OrdinalIgnoreCase) ||
                            arg.Equals("-sub", StringComparison.OrdinalIgnoreCase))
                        {
                            if (i + 1 < args.Length && !args[i + 1].StartsWith("-"))
                            {
                                i++;
                                string sub = args[i].Trim('"', '\'');
                                subArg = "/sub=\"" + sub + "\"";
                            }
                            continue;
                        }

                        // 4. Start time / seek options (--start-time=... or --start-time <val>)
                        if (arg.StartsWith("--start-time=", StringComparison.OrdinalIgnoreCase))
                        {
                            string time = arg.Substring(13).Trim('"', '\'');
                            seekArg = "/seek=" + time;
                            continue;
                        }
                        if (arg.StartsWith("--start=", StringComparison.OrdinalIgnoreCase))
                        {
                            string time = arg.Substring(8).Trim('"', '\'');
                            seekArg = "/seek=" + time;
                            continue;
                        }
                        if (arg.Equals("--start-time", StringComparison.OrdinalIgnoreCase) ||
                            arg.Equals("--start", StringComparison.OrdinalIgnoreCase) ||
                            arg.Equals("-ss", StringComparison.OrdinalIgnoreCase))
                        {
                            if (i + 1 < args.Length && !args[i + 1].StartsWith("-"))
                            {
                                i++;
                                string time = args[i].Trim('"', '\'');
                                seekArg = "/seek=" + time;
                            }
                            continue;
                        }

                        // 5. VLC interface options with separate argument values to discard (e.g. -I dummy)
                        if (arg.Equals("-I", StringComparison.OrdinalIgnoreCase) ||
                            arg.Equals("--intf", StringComparison.OrdinalIgnoreCase) ||
                            arg.Equals("--extraintf", StringComparison.OrdinalIgnoreCase))
                        {
                            if (i + 1 < args.Length && !args[i + 1].StartsWith("-"))
                            {
                                i++;
                            }
                            continue;
                        }

                        // 6. Generic VLC / POSIX flags starting with -- or -
                        if (arg.StartsWith("--", StringComparison.OrdinalIgnoreCase))
                        {
                            // Discard any VLC long flag (e.g. --no-video-title-show, --play-and-exit, --started-from-file, etc.)
                            continue;
                        }
                        if (arg.StartsWith("-", StringComparison.OrdinalIgnoreCase))
                        {
                            // Discard -url if by itself (the actual URL follows as next arg)
                            if (arg.Equals("-url", StringComparison.OrdinalIgnoreCase))
                            {
                                continue;
                            }
                            // Discard any short flag (e.g. -f, -v, etc.)
                            continue;
                        }

                        // 7. Strip custom URL protocol prefixes (vlc://, potplayer://)
                        if (arg.StartsWith("vlc://", StringComparison.OrdinalIgnoreCase))
                        {
                            arg = arg.Substring(6);
                        }
                        else if (arg.StartsWith("vlc:", StringComparison.OrdinalIgnoreCase))
                        {
                            arg = arg.Substring(4);
                        }
                        else if (arg.StartsWith("potplayer://", StringComparison.OrdinalIgnoreCase))
                        {
                            arg = arg.Substring(12);
                        }

                        arg = arg.Trim('"', '\'');
                        if (string.IsNullOrWhiteSpace(arg)) continue;

                        // 8. Media target (cleanly quoted URL or file path)
                        targetItems.Add("\"" + arg.Replace("\"", "\\\"") + "\"");
                    }
                }

                List<string> cleanArgs = new List<string>();

                // Default to /current if neither /current nor /new was explicitly requested
                // This ensures playing a stream opens in the current PotPlayer window rather than creating a duplicate
                if (!hasInstanceFlag)
                {
                    cleanArgs.Add("/current");
                }

                foreach (string flag in extraPotPlayerFlags)
                {
                    cleanArgs.Add(flag);
                }

                if (!string.IsNullOrEmpty(seekArg))
                {
                    cleanArgs.Add(seekArg);
                }

                if (!string.IsNullOrEmpty(subArg))
                {
                    cleanArgs.Add(subArg);
                }

                foreach (string target in targetItems)
                {
                    cleanArgs.Add(target);
                }

                string argLine = string.Join(" ", cleanArgs.ToArray());
                Log("Launching PotPlayer: " + potplayer + " with args: " + argLine);

                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = potplayer;
                psi.Arguments = argLine;
                psi.UseShellExecute = false;
                Process.Start(psi);
            }
            catch (Exception ex)
            {
                Log("Error: " + ex.ToString());
            }
        }

        static string FindPotPlayer()
        {
            // 1. Standard filesystem locations
            List<string> candidates = new List<string>
            {
                @"C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe",
                @"C:\Program Files\DAUM\PotPlayer\PotPlayer64.exe",
                @"C:\Program Files (x86)\DAUM\PotPlayer\PotPlayerMini.exe",
                @"C:\Program Files (x86)\DAUM\PotPlayer\PotPlayer.exe",
                @"C:\Program Files\DAUM\PotPlayer\PotPlayerMini.exe"
            };

            string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (!string.IsNullOrEmpty(localAppData))
            {
                candidates.Add(Path.Combine(localAppData, @"DAUM\PotPlayer\PotPlayerMini64.exe"));
                candidates.Add(Path.Combine(localAppData, @"DAUM\PotPlayer\PotPlayerMini.exe"));
            }

            foreach (string p in candidates)
            {
                if (File.Exists(p)) return p;
            }

            // 2. Windows App Paths registry
            string[] regKeys = new string[]
            {
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\PotPlayerMini64.exe",
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\PotPlayer64.exe",
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\PotPlayerMini.exe",
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\PotPlayer.exe"
            };

            foreach (string rk in regKeys)
            {
                // Check HKLM 64-bit and 32-bit
                string path = ReadRegistryAppPath(Registry.LocalMachine, rk);
                if (!string.IsNullOrEmpty(path)) return path;

                // Check HKCU
                path = ReadRegistryAppPath(Registry.CurrentUser, rk);
                if (!string.IsNullOrEmpty(path)) return path;
            }

            // 3. Check system PATH
            string pathEnv = Environment.GetEnvironmentVariable("PATH");
            if (!string.IsNullOrEmpty(pathEnv))
            {
                string[] exes = new string[] { "PotPlayerMini64.exe", "PotPlayer64.exe", "PotPlayerMini.exe", "PotPlayer.exe" };
                foreach (string dir in pathEnv.Split(new char[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    try
                    {
                        foreach (string exe in exes)
                        {
                            string full = Path.Combine(dir.Trim(), exe);
                            if (File.Exists(full)) return full;
                        }
                    }
                    catch { }
                }
            }

            return null;
        }

        static string ReadRegistryAppPath(RegistryKey rootKey, string subKey)
        {
            try
            {
                using (var key = rootKey.OpenSubKey(subKey))
                {
                    if (key != null)
                    {
                        string val = key.GetValue("") as string;
                        if (!string.IsNullOrEmpty(val))
                        {
                            val = val.Trim('"', '\'');
                            if (File.Exists(val)) return val;
                        }
                    }
                }
            }
            catch { }
            return null;
        }

        static void Log(string msg)
        {
            try
            {
                string dir = Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
                string logPath = Path.Combine(dir, "potplayer-bridge.log");
                string line = "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + "] " + msg + Environment.NewLine;

                try
                {
                    File.AppendAllText(logPath, line);
                }
                catch
                {
                    // Fallback to LocalAppData when running from Program Files without write permissions
                    string appData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PotPlayerBridge");
                    if (!Directory.Exists(appData)) Directory.CreateDirectory(appData);
                    string fallbackLog = Path.Combine(appData, "potplayer-bridge.log");
                    File.AppendAllText(fallbackLog, line);
                }
            }
            catch { }
        }
    }
}
