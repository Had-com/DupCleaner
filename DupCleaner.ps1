<#
  DupCleaner - Windows GUI (PowerShell + WinForms)
  - Content-based: same size -> SHA256 of full contents (never name-based)
  - Finds duplicate FILES and duplicate FOLDERS (identical tree contents)
  - Keep rule: oldest modified, tie -> shortest path, tie -> alphabetical (override per set)
  - Hardlinked paths are collapsed (not counted as reclaimable space)
  - Default action MOVES duplicates to a quarantine folder with a manifest (undoable)
#>
param([switch]$NoGui, [string]$ShotPath = '', [string]$TestScan = '', [string]$AutoScan = '')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic

if (-not ('FileId' -as [type])) {
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class FileId {
  [StructLayout(LayoutKind.Sequential)] struct FT { public uint lo; public uint hi; }
  [StructLayout(LayoutKind.Sequential)] struct BHFI { public uint Attr; public FT c; public FT a; public FT w; public uint Vol; public uint SizeHigh; public uint SizeLow; public uint Links; public uint IdHigh; public uint IdLow; }
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern SafeFileHandle CreateFileW(string n, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h, out BHFI i);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static int Links(string path) {
    string p = path.StartsWith(@"\\") ? path : @"\\?\" + path;
    using (SafeFileHandle h = CreateFileW(p, 0, 7, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
      if (h.IsInvalid) return 0;
      BHFI i; if (!GetFileInformationByHandle(h, out i)) return 0;
      return (int)i.Links;
    }
  }
  public static string Get(string path) {
    string p = path.StartsWith(@"\\") ? path : @"\\?\" + path;
    using (SafeFileHandle h = CreateFileW(p, 0, 7, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
      if (h.IsInvalid) return null;
      BHFI i; if (!GetFileInformationByHandle(h, out i)) return null;
      return i.Vol + ":" + i.IdHigh + ":" + i.IdLow;
    }
  }
}
"@
}

# Result items and sets are small compiled classes (fast to build, save and restore: 100,000+ sets of PowerShell objects were slow).
if (-not ('DupItem' -as [type])) {
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System; using System.Collections; using System.Collections.Generic; using System.IO; using System.Diagnostics;
using System.Drawing; using System.Runtime.InteropServices; using System.Windows.Forms;
public class DupItem {
  public string Path; public long Length; public DateTime Modified; public object Remove; public bool Nested;
  public static DupItem Make(string p, long len, DateTime mod, bool remove) { DupItem d = new DupItem(); d.Path = p; d.Length = len; d.Modified = mod; d.Remove = remove; return d; }
}
public class DupSet { public string Kind; public long Size; public List<object> Items; }
public static class SessionBuild {
  public static long Gone;
  // Turns the parsed session (dictionaries) into DupSet lists, dropping items that no longer exist. Names are looked up per folder
  // (one directory listing instead of one disk lookup per item - much faster on a slow USB disk) and the window is kept alive.
  public static List<object> Build(IList sets, string kind, bool nested, Action<int> progress, long total, bool check) {
    Stopwatch pump = Stopwatch.StartNew(); long done = 0;
    Dictionary<string, int> cnt = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
    if (check) foreach (object so in sets) foreach (object io in (IList)((IDictionary)so)["Items"]) {
      string d = System.IO.Path.GetDirectoryName((string)((IDictionary)io)["P"]) ?? "";
      int c; cnt.TryGetValue(d, out c); cnt[d] = c + 1;
    }
    Dictionary<string, HashSet<string>> listing = new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);
    List<object> result = new List<object>();
    foreach (object so in sets) {
      IDictionary sd = (IDictionary)so; List<object> items = new List<object>();
      foreach (object io in (IList)sd["Items"]) {
        IDictionary id = (IDictionary)io; string p = (string)id["P"]; bool exists;
        if (!check) exists = true;
        else {
          string dir = System.IO.Path.GetDirectoryName(p) ?? "";
          HashSet<string> names = null;
          if (cnt[dir] >= 3 && !listing.TryGetValue(dir, out names)) {
            try { names = new HashSet<string>(StringComparer.OrdinalIgnoreCase); foreach (string e in Directory.EnumerateFileSystemEntries(dir)) names.Add(System.IO.Path.GetFileName(e)); }
            catch (DirectoryNotFoundException) { names = new HashSet<string>(); }
            catch (Exception) { names = null; }
            listing[dir] = names;
          }
          if (names != null) exists = names.Contains(System.IO.Path.GetFileName(p)); else exists = File.Exists(p) || Directory.Exists(p);
        }
        if (exists) {
          long ticks = Convert.ToInt64(id["M"]);
          DupItem it = DupItem.Make(p, Convert.ToInt64(id["L"]), new DateTime(ticks, DateTimeKind.Utc), !nested && id["R"] != null && Convert.ToBoolean(id["R"]));
          it.Nested = nested; items.Add(it);
        } else Gone++;
        done++;
        if (pump.ElapsedMilliseconds > 150) { pump.Restart(); if (progress != null) progress((int)done); System.Windows.Forms.Application.DoEvents(); }
      }
      if (items.Count >= 2) { DupSet s = new DupSet(); s.Kind = nested ? "Folder" : kind; s.Size = Convert.ToInt64(sd["Size"]); s.Items = items; result.Add(s); }
    }
    return result;
  }
  public static List<object> ToDicts(IEnumerable sets) {
    List<object> list = new List<object>();
    if (sets == null) return list;
    foreach (object so in sets) {
      DupSet s = (DupSet)so; List<object> its = new List<object>();
      foreach (object io in s.Items) {
        DupItem it = (DupItem)io; Dictionary<string, object> d = new Dictionary<string, object>();
        d["P"] = it.Path; d["L"] = it.Length; d["M"] = it.Modified.Ticks; d["R"] = (it.Remove != null && Convert.ToBoolean(it.Remove));
        its.Add(d);
      }
      Dictionary<string, object> sd = new Dictionary<string, object>(); sd["Size"] = s.Size; sd["Items"] = its; list.Add(sd);
    }
    return list;
  }
}
// Folders tab: the duplicate folder sets, filtered by a word in any path and sorted (0 = space you free, 1 = name, 2 = number of copies, 3 = newest)
public static class SetUtil {
  public static string Name(DupSet s) { return System.IO.Path.GetFileName(((DupItem)s.Items[0]).Path.TrimEnd('\\')); }
  public static DupSet[] Sorted(IEnumerable sets, int mode, string filter) {
    List<DupSet> list = new List<DupSet>(); bool f = !string.IsNullOrEmpty(filter);
    if (sets != null) foreach (object o in sets) {
      DupSet s = (DupSet)o; if (s.Items == null || s.Items.Count == 0) continue;
      if (f) { bool hit = false; foreach (object io in s.Items) { if (((DupItem)io).Path.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0) { hit = true; break; } } if (!hit) continue; }
      list.Add(s);
    }
    DupSet[] arr = list.ToArray(); int n = arr.Length;
    if (mode == 1) { string[] k = new string[n]; for (int i = 0; i < n; i++) k[i] = Name(arr[i]).ToLowerInvariant(); Array.Sort(k, arr, StringComparer.Ordinal); }
    else {
      double[] k = new double[n];
      for (int i = 0; i < n; i++) k[i] = mode == 0 ? -((double)arr[i].Size * (arr[i].Items.Count - 1)) : mode == 2 ? -(double)arr[i].Items.Count : -(double)((DupItem)arr[i].Items[0]).Modified.Ticks;
      Array.Sort(k, arr);
    }
    return arr;
  }
}
public static class TreeUtil {
  [StructLayout(LayoutKind.Sequential)] struct TVITEM { public uint mask; public IntPtr hItem; public uint state; public uint stateMask; public IntPtr pszText; public int cchTextMax; public int iImage; public int iSelectedImage; public int cChildren; public IntPtr lParam; }
  [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, ref TVITEM l);
  [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
  // st: 0 = no tick box on this node, 1 = box unchecked, 2 = box checked (changing it does not raise AfterCheck)
  public static void SetCheck(TreeView tv, TreeNode n, int st) {
    if (!tv.IsHandleCreated) return;
    TVITEM i = new TVITEM(); i.mask = 0x8; i.hItem = n.Handle; i.stateMask = 0xF000; i.state = (uint)(st << 12);
    SendMessage(tv.Handle, 0x113F, IntPtr.Zero, ref i);
  }
  public static void DoubleBuffer(TreeView tv) { if (tv.IsHandleCreated) SendMessage(tv.Handle, 0x112C, (IntPtr)4, (IntPtr)4); }
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
  public static void NoHScroll(TreeView tv) { if (!tv.IsHandleCreated) return; int s = GetWindowLong(tv.Handle, -16); SetWindowLong(tv.Handle, -16, s | 0x8000); }
}
public static class ShellIcon {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)] struct SHFILEINFO { public IntPtr hIcon; public int iIcon; public uint dwAttributes; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName; }
  [DllImport("shell32.dll", CharSet = CharSet.Auto)] static extern IntPtr SHGetFileInfo(string path, uint attr, ref SHFILEINFO fi, uint size, uint flags);
  [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
  // the icon Windows shows for a folder or for a file name's extension (no disk access)
  public static Bitmap Get(string name, bool dir) {
    SHFILEINFO fi = new SHFILEINFO();
    SHGetFileInfo(name, dir ? 0x10u : 0x80u, ref fi, (uint)Marshal.SizeOf(fi), 0x100u | 0x10u | 0x1u);
    if (fi.hIcon == IntPtr.Zero) return null;
    Bitmap b;
    using (Icon ic = Icon.FromHandle(fi.hIcon)) { b = ic.ToBitmap(); }
    DestroyIcon(fi.hIcon);
    return b;
  }
}
"@
}

# ---------------------------------------------------------------- core
$script:Cancel = $false
$script:HashCache = @{}
$script:BytesDone = 0L
$script:BytesTotal = 0L
$script:Phase = ''
$script:OnProgress = { param($text, $pct) }
$script:OnGroup = { param($kind, $group) }   # called the moment a duplicate set is confirmed
$script:Clock = [Diagnostics.Stopwatch]::StartNew()
$script:LastTick = 0L

$script:DefaultExcludes = @('$RECYCLE.BIN', 'System Volume Information', 'WinSxS', 'AppData', 'node_modules',
    '.git', '.venv', 'venv', '__pycache__', 'site-packages', '.nuget', '.gradle', '.m2', '$WINDOWS.~BT')

$script:Paused = $false
$script:ActiveMs = 0L; $script:StepMs = 0L; $script:TickPrev = -1L
$script:RateMs0 = 0L; $script:RateWork0 = 0L; $script:RateRaw0 = 0L; $script:RateEwma = 0.0; $script:RawEwma = 0.0
$script:RawBytes = 0L; $script:EtaText = ''
$script:FileCost = 131072L   # each file counts as this many extra bytes of work (open + antivirus + seek)
# Better time estimate: while hashing, the app fits  time = bytes * x + files * y  to what it has really measured on this
# drive (x = seconds per byte, y = seconds of open/seek per file), so a step full of small files is not judged by MB/s.
$script:FilesDone = 0L; $script:StepRawTotal = 0.0; $script:StepFilesTotal = 0.0; $script:StepRawBase = 0L; $script:StepFilesBase = 0L
$script:RateFiles0 = 0L; $script:Fit = @{ bb = 0.0; bn = 0.0; nn = 0.0; bt = 0.0; nt = 0.0; sumT = 0.0; sumB = 0.0; win = 0 }
$script:WinBps = 0.0; $script:WinFps = 0.0
# Step list: every scan is a fixed list of steps, shown as "Step 3 of 6" and timed into crash.log
$script:StepDefs = @(
    @('Listing files', '^Listing'), @('Grouping by size', '^(Grouping|Preparing)'), @('Hashing files', '^Hashing'),
    @('Comparing folder structures', '^Comparing'), @('Verifying folder contents', '^Verifying'), @('Saving', '^Saving'))
$script:ScanSteps = @(); $script:StepName = ''; $script:StepNo = 0; $script:StepStartActive = 0L

function Set-ScanSteps([bool]$files, [bool]$folders) {
    $l = New-Object 'System.Collections.Generic.List[string]'
    $l.Add('Listing files')
    if ($files) { $l.Add('Grouping by size'); $l.Add('Hashing files') }
    if ($folders) { $l.Add('Comparing folder structures'); $l.Add('Verifying folder contents') }
    $l.Add('Saving')
    $script:ScanSteps = $l.ToArray(); $script:StepName = ''; $script:StepNo = 0; $script:StepStartActive = 0L
}
function Close-Step([string]$extra = '') {   # writes how long the step that just ended took (active time, pauses excluded)
    if (-not $script:StepName) { return }
    $d = ($script:ActiveMs - $script:StepStartActive) / 1000.0
    try { Write-CrashLog 'Timing' ("Step $($script:StepNo) of $($script:ScanSteps.Count) finished: $($script:StepName) took $(Format-Span $d) ($([int]$d) s)$extra") } catch { }
}
function Update-Step([string]$text) {
    $name = $null
    foreach ($d in $script:StepDefs) { if ($text -match $d[1]) { $name = $d[0]; break } }
    if (-not $name -or $name -eq $script:StepName) { return }
    $extra = ''
    if ($script:StepName -eq 'Hashing files' -or $script:StepName -eq 'Verifying folder contents') {
        $extra = "; read $(Format-Size $script:RawBytes) in total, $($script:FilesDone) files hashed so far, $($script:CacheHits) fingerprints reused"
    }
    Close-Step $extra
    $script:StepName = $name; $script:StepStartActive = $script:ActiveMs
    $i = [array]::IndexOf($script:ScanSteps, $name); if ($i -ge 0) { $script:StepNo = $i + 1 } else { $script:StepNo++ }
}
function Start-HashStep([double]$raw, [double]$files, [int64]$work) {   # called when the size of the next hashing step is known
    $script:BytesTotal = $work; $script:BytesDone = 0; $script:StepMs = 0L
    $script:StepRawTotal = $raw; $script:StepFilesTotal = $files
    $script:StepRawBase = $script:RawBytes; $script:StepFilesBase = $script:FilesDone
    $script:RateMs0 = 0L; $script:RateRaw0 = $script:RawBytes; $script:RateFiles0 = $script:FilesDone
    $script:Fit = @{ bb = 0.0; bn = 0.0; nn = 0.0; bt = 0.0; nt = 0.0; sumT = 0.0; sumB = 0.0; win = 0 }
    $script:RateEwma = 0.0; $script:RawEwma = 0.0; $script:WinBps = 0.0; $script:WinFps = 0.0
}

function Format-Span([double]$sec) {
    $sec = [math]::Max(0, [math]::Round($sec)); $t = [timespan]::FromSeconds($sec)
    if ($t.TotalHours -ge 1) { return '{0}h {1:00}m' -f [int][math]::Floor($t.TotalHours), $t.Minutes }
    if ($t.TotalMinutes -ge 1) { return '{0}m {1:00}s' -f [int]$t.Minutes, $t.Seconds }
    return "$([int]$t.TotalSeconds)s"
}

function Tick([string]$text, [bool]$force = $false) {
    $now = $script:Clock.ElapsedMilliseconds
    if ($script:TickPrev -ge 0) {   # active time only (pauses are not counted)
        $dt = $now - $script:TickPrev; $script:ActiveMs += $dt
        if ($script:BytesTotal -gt 0) { $script:StepMs += $dt }
    }
    $script:TickPrev = $now
    if ($script:Paused) {   # block right here; resuming continues from exactly this point
        [void](& $script:OnProgress "PAUSED - $text" -1)
        while ($script:Paused -and -not $script:Cancel) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }
        $script:LastTick = 0; $script:TickPrev = $script:Clock.ElapsedMilliseconds
    }
    if ($force -or ($script:Clock.ElapsedMilliseconds - $script:LastTick) -gt 150) {
        $script:LastTick = $script:Clock.ElapsedMilliseconds
        Save-CacheJournal
        if ($script:CanSavePartial) { Save-PartialSession; Write-Heartbeat }   # only defined once the GUI exists
        $pct = -1
        if ($script:BytesTotal -gt 0) { $pct = [int][math]::Min(100, 100.0 * $script:BytesDone / $script:BytesTotal) }
        # Measure the real speed as the scan runs (smoothed over recent seconds) and derive the time left from it.
        # Work is counted in bytes plus a fixed per-file cost, so thousands of tiny files are not underestimated.
        Update-Step $text
        $fit = $script:Fit
        if ($script:StepMs -lt $script:RateMs0) { $script:RateMs0 = 0L; $script:RateRaw0 = $script:RawBytes; $script:RateFiles0 = $script:FilesDone }
        $win = $script:StepMs - $script:RateMs0
        if ($script:BytesTotal -gt 0 -and $win -ge 3000) {   # one sample about every 3 s of working time
            $sec = $win / 1000.0
            $db = [double]($script:RawBytes - $script:RateRaw0); $dn = [double]($script:FilesDone - $script:RateFiles0)
            foreach ($k in 'bb', 'bn', 'nn', 'bt', 'nt', 'sumT', 'sumB') { $fit[$k] *= 0.985 }   # recent samples count more (the disk speed changes)
            $fit.bb += $db * $db; $fit.bn += $db * $dn; $fit.nn += $dn * $dn; $fit.bt += $db * $sec; $fit.nt += $dn * $sec
            $fit.sumT += $sec; $fit.sumB += $db; $fit.win++
            $script:WinBps = $db / $sec; $script:WinFps = $dn / $sec
            $script:RateMs0 = $script:StepMs; $script:RateRaw0 = $script:RawBytes; $script:RateFiles0 = $script:FilesDone
        }
        $el = Format-Span ($script:ActiveMs / 1000.0)
        $stepTxt = if ($script:ScanSteps.Count -and $script:StepNo -gt 0) { "Step $($script:StepNo) of $($script:ScanSteps.Count): $($script:StepName)" } else { '' }
        if ($script:BytesTotal -le 0) {
            $script:EtaText = "$stepTxt    Elapsed: $el    (a time estimate appears once a hashing step begins)"
        } elseif ($fit.win -ge 3 -and $fit.sumB -gt 0) {
            # seconds per byte (x) and per file (y): least squares over the recent samples, with a safe fallback
            $x = $fit.sumT / $fit.sumB; $y = $script:FileCost * $x
            $det = $fit.bb * $fit.nn - $fit.bn * $fit.bn
            if ($fit.win -ge 8 -and $det -gt 1e-6 * $fit.bb * $fit.nn) {
                $x2 = ($fit.bt * $fit.nn - $fit.nt * $fit.bn) / $det; $y2 = ($fit.nt * $fit.bb - $fit.bt * $fit.bn) / $det
                if ($x2 -gt 0 -and $y2 -ge 0) { $x = $x2; $y = $y2 }
            }
            $remB = [math]::Max(0.0, $script:StepRawTotal - ($script:RawBytes - $script:StepRawBase))
            $remN = [math]::Max(0.0, $script:StepFilesTotal - ($script:FilesDone - $script:StepFilesBase))
            $left = $remB * $x + $remN * $y
            $script:EtaText = "$stepTxt    Time left in this step: about $(Format-Span $left)    Elapsed: $el    Speed now: $([int]$script:WinFps) files/s, $(Format-Size $script:WinBps)/s    ($pct% of this step; later steps are not estimated)"
        } else {
            $script:EtaText = "$stepTxt    Time left: measuring disk speed...    Elapsed: $el"
        }
        $shown = $text; if ($stepTxt -and $text -notmatch '^(Waiting|PAUSED)') { $shown = "$stepTxt - $text" }
        [void](& $script:OnProgress $shown $pct)
        [Windows.Forms.Application]::DoEvents()
    }
}

function Format-Size([double]$b) {
    if ($b -ge 1GB) { return '{0:N2} GB' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:N1} MB' -f ($b / 1MB) }
    if ($b -ge 1KB) { return '{0:N0} KB' -f ($b / 1KB) }
    return "$([int64]$b) B"
}

# one-time move of the old data folder name (DupeFinder -> DupCleaner); the old folder is left in place as a backup
try { $o = Join-Path $env:LOCALAPPDATA 'DupeFinder'; $n = Join-Path $env:LOCALAPPDATA 'DupCleaner'; if ((Test-Path -LiteralPath $o) -and -not (Test-Path -LiteralPath $n)) { Copy-Item -LiteralPath $o -Destination $n -Recurse -Force } } catch { }
# ---- persistent fingerprint cache: path -> (size, modified ticks, SHA256). Valid only while size AND mtime match.
$script:CachePath = Join-Path $env:LOCALAPPDATA 'DupCleaner\hash-cache.tsv'
$script:PersistCache = @{}
$script:CacheLoaded = $false; $script:CacheDirty = $false; $script:CacheHits = 0; $script:UseCache = $true
# Hashes found during a scan are also appended to the cache file about once a minute (a cheap journal), so a crash,
# a kill or a closed window loses at most that minute. The full rewrite at the end of a scan compacts the file.
$script:CacheJournal = New-Object 'System.Collections.Generic.List[string]'
$script:CacheClock = [Diagnostics.Stopwatch]::StartNew(); $script:LastJournal = 0L

# "Last saved" indicator under the progress bar: when fingerprints and results were last written, or why a save failed.
$script:SavedAt = @{ fp = ''; res = '' }; $script:SaveErr = @{ fp = ''; res = '' }; $script:lblSaved = $null
function Set-Saved([string]$kind, [string]$note = '', [string]$err = '') {
    try {
        if ($err) { $script:SaveErr[$kind] = $err } else { $script:SaveErr[$kind] = ''; $script:SavedAt[$kind] = ((Get-Date).ToString('HH:mm:ss') + $note) }
        $l = $script:lblSaved; if (-not $l) { return }
        $fp = if ($script:SavedAt.fp) { $script:SavedAt.fp } else { 'not yet' }
        $rs = if ($script:SavedAt.res) { $script:SavedAt.res } else { 'not yet' }
        $e = (@($script:SaveErr.fp, $script:SaveErr.res) | Where-Object { $_ }) -join '; '
        if ($e) { $l.ForeColor = $script:UiDelFg; $l.Text = "SAVE PROBLEM: $e   (see crash.log)   Last good save - fingerprints: $fp, results: $rs" }
        else { $l.ForeColor = $script:UiMuted; $l.Text = "Last saved -  fingerprints: $fp    results: $rs" }
    } catch { }
}

function Save-CacheJournal([bool]$force = $false) {
    if ($script:CacheJournal.Count -eq 0) { return }
    if (-not $force -and ($script:CacheClock.ElapsedMilliseconds - $script:LastJournal) -lt 60000) { return }
    $script:LastJournal = $script:CacheClock.ElapsedMilliseconds
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path $script:CachePath))
        $n = $script:CacheJournal.Count
        [IO.File]::AppendAllLines($script:CachePath, $script:CacheJournal.ToArray(), (New-Object Text.UTF8Encoding($false)))
        $script:CacheJournal.Clear()
        Set-Saved 'fp' " ($n new)"
    } catch {   # best effort: the final full save still happens, but never fail silently
        Set-Saved 'fp' '' ('fingerprints: ' + $_.Exception.Message)
        try { Write-CrashLog 'Save-CacheJournal failed' $_.Exception } catch { }
    }
}

function Import-HashCache {
    if ($script:CacheLoaded) { return }
    $script:CacheLoaded = $true
    if (-not (Test-Path -LiteralPath $script:CachePath)) { return }
    $loaded = 0
    try {
        foreach ($line in [IO.File]::ReadLines($script:CachePath)) {
            $p = $line.Split("`t")
            if ($p.Count -eq 4) { $script:PersistCache[$p[0].ToLowerInvariant()] = @($p[1], $p[2], $p[3]) }
            if ((++$loaded % 15000) -eq 0) { $script:Phase = "Loading saved fingerprints... $loaded"; [void](& $script:OnProgress $script:Phase -1); [Windows.Forms.Application]::DoEvents() }   # keeps the window alive
        }
    } catch { }
}

function Export-HashCache([bool]$pump = $false) {
    if (-not $script:CacheDirty) { return }
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path $script:CachePath))
        $tmp = $script:CachePath + '.tmp'
        $w = New-Object IO.StreamWriter($tmp, $false, (New-Object Text.UTF8Encoding($false)))
        $seen = $script:SeenPaths; $i = 0; $total = $script:PersistCache.Count
        try {
            foreach ($k in $script:PersistCache.Keys) {
                # A file listed by the scan that just ran is known to exist: no disk lookup. Only other entries are checked
                # (one lookup per file took hours on a big external drive, with the window frozen).
                if (-not ($seen -and $seen.Contains($k)) -and -not [IO.File]::Exists($k)) { continue }   # drop entries for files that no longer exist
                $v = $script:PersistCache[$k]
                $w.WriteLine("$k`t$($v[0])`t$($v[1])`t$($v[2])")
                if ($pump -and ((++$i % 5000) -eq 0) -and -not $form.IsDisposed) {
                    $lblStatus.Text = "Saving fingerprints... $i of $total"; [Windows.Forms.Application]::DoEvents()
                }
            }
        } finally { $w.Dispose() }
        Move-Item -LiteralPath $tmp -Destination $script:CachePath -Force
        $script:CacheDirty = $false
        $script:CacheJournal.Clear()   # everything is in the rewritten file now
        Set-Saved 'fp' ' (full)'
    } catch {
        Set-Saved 'fp' '' ('fingerprints: ' + $_.Exception.Message)
        try { Write-CrashLog 'Export-HashCache failed' $_.Exception } catch { }
    }
}

function Get-CachedHash([string]$path, [int64]$len, [int64]$ticks) {
    if (-not $script:UseCache) { return $null }
    $e = $script:PersistCache[$path.ToLowerInvariant()]
    if ($e -and $e[0] -eq "$len" -and $e[1] -eq "$ticks") { return $e[2] }
    return $null
}

$script:Sha = [Security.Cryptography.SHA256]::Create()
$script:HashBuf = New-Object byte[] 1048576

function Get-Sha256([string]$path, [int64]$len, [int64]$ticks) {
    if ($script:HashCache.ContainsKey($path)) { return $script:HashCache[$path] }
    $cached = Get-CachedHash $path $len $ticks
    if ($cached) { $script:HashCache[$path] = $cached; $script:CacheHits++; return $cached }
    $result = $null; $fs = $null
    $script:BytesDone += $script:FileCost; $script:FilesDone++
    $sha = $script:Sha; $buf = $script:HashBuf   # reused: no per-file allocations
    try {
        $sha.Initialize()   # a reused hasher must be reset before every file
        $fs = New-Object IO.FileStream($path, 'Open', 'Read', 'ReadWrite', 65536)
        while ($true) {
            # Read in the background and keep the window alive while the disk answers: a slow or stalled drive
            # (or antivirus scan) then shows "waiting for the disk" instead of "Not Responding", and Cancel still works.
            $rt = $fs.ReadAsync($buf, 0, $buf.Length)
            if (-not $rt.Wait(40)) {
                $w0 = $script:Clock.ElapsedMilliseconds
                while (-not $rt.Wait(100)) {
                    [Windows.Forms.Application]::DoEvents()
                    $ws = [int](($script:Clock.ElapsedMilliseconds - $w0) / 1000)
                    if ($ws -ge 3) { [void](& $script:OnProgress "Waiting for the disk to answer ($ws s): $path" -1) }
                    if ($script:Cancel) { $fs = $null; return $null }   # abandon the stuck read; it may finish later
                }
                $script:TickPrev = $script:Clock.ElapsedMilliseconds   # waiting is not working time (keeps the ETA honest)
            }
            $n = $rt.Result
            if ($n -le 0) { break }
            [void]$sha.TransformBlock($buf, 0, $n, $null, 0)
            $script:BytesDone += $n; $script:RawBytes += $n
            Tick $script:Phase
            if ($script:Cancel) { [void]$sha.TransformFinalBlock($buf, 0, 0); return $null }   # also resets the hasher
        }
        [void]$sha.TransformFinalBlock($buf, 0, 0)
        $result = [BitConverter]::ToString($sha.Hash).Replace('-', '')
    } catch {
        $result = $null
        try { $sha.Initialize() } catch { }
    } finally { if ($fs) { $fs.Dispose() } }
    $script:HashCache[$path] = $result
    if ($result) {
        $key = $path.ToLowerInvariant()
        $script:PersistCache[$key] = @("$len", "$ticks", $result); $script:CacheDirty = $true
        $script:CacheJournal.Add("$key`t$len`t$ticks`t$result")
    }
    return $result
}

function Get-ScanFiles($roots, $excludeNames, [bool]$skipPlaceholders, $extraSkipPaths) {
    $files = New-Object 'System.Collections.Generic.List[object]'
    $taint = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $ex = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $excludeNames) { [void]$ex.Add($n) }
    $skipP = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $extraSkipPaths) { if ($p) { [void]$skipP.Add($p.TrimEnd('\')) } }
    $stats = @{ Excluded = 0; Placeholders = 0; Errors = 0; Links = 0 }
    $RECALL = 0x400000 -bor 0x40000 -bor 0x1000
    $count = 0
    foreach ($root in $roots) {
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push($root)
        while ($stack.Count -gt 0) {
            if ($script:Cancel) { return $null }
            $dir = $stack.Pop()
            try {
                $di = New-Object IO.DirectoryInfo $dir
                $subs = $di.GetDirectories(); $fs = $di.GetFiles()
            } catch { $stats.Errors++; [void]$taint.Add($dir); continue }
            foreach ($s in $subs) {
                if ($s.Attributes -band [IO.FileAttributes]::ReparsePoint) { $stats.Links++; [void]$taint.Add($dir); continue }
                if ($ex.Contains($s.Name) -or $skipP.Contains($s.FullName.TrimEnd('\'))) { $stats.Excluded++; [void]$taint.Add($dir); continue }
                $stack.Push($s.FullName)
            }
            foreach ($f in $fs) {
                $a = [int]$f.Attributes
                if ($skipPlaceholders -and ($a -band $RECALL)) { $stats.Placeholders++; [void]$taint.Add($dir); continue }
                if ($a -band [int][IO.FileAttributes]::ReparsePoint) { $stats.Links++; [void]$taint.Add($dir); continue }
                $files.Add([pscustomobject]@{ Path = $f.FullName; Dir = $dir; Root = $root; Name = $f.Name; Length = $f.Length; Modified = $f.LastWriteTimeUtc })
                $count++
            }
            if (($count % 300) -eq 0) { $script:Phase = "Listing files... $count found"; Tick $script:Phase }
        }
    }
    return [pscustomobject]@{ Files = $files; Taint = $taint; Stats = $stats }
}

function Compare-Keep($a, $b) {   # <0 when $a should be kept ahead of $b: oldest, then shortest path, then alphabetical
    if ($a.Modified -ne $b.Modified) { if ($a.Modified -lt $b.Modified) { return -1 } else { return 1 } }
    if ($a.Path.Length -ne $b.Path.Length) { if ($a.Path.Length -lt $b.Path.Length) { return -1 } else { return 1 } }
    return [string]::Compare($a.Path, $b.Path, [StringComparison]::OrdinalIgnoreCase)
}

function New-Group([string]$kind, $recs) {
    $arr = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $recs) { $arr.Add($r) }
    if ($arr.Count -le 40) {   # sets are tiny: a plain insertion sort is far cheaper than Sort-Object
        for ($i = 1; $i -lt $arr.Count; $i++) {
            $x = $arr[$i]; $j = $i - 1
            while ($j -ge 0 -and (Compare-Keep $arr[$j] $x) -gt 0) { $arr[$j + 1] = $arr[$j]; $j-- }
            $arr[$j + 1] = $x
        }
    } else {
        $sorted = @($arr | Sort-Object -Property @{ Expression = { $_.Modified } }, @{ Expression = { $_.Path.Length } }, @{ Expression = { $_.Path } })
        $arr = New-Object 'System.Collections.Generic.List[object]'; foreach ($r in $sorted) { $arr.Add($r) }
    }
    $items = New-Object 'System.Collections.Generic.List[object]'
    $i = 0
    foreach ($r in $arr) {
        $items.Add([DupItem]::Make([string]$r.Path, [int64]$r.Length, [DateTime]$r.Modified, ($i -gt 0))); $i++
    }
    $set = New-Object DupSet; $set.Kind = $kind; $set.Size = $items[0].Length; $set.Items = $items
    $set
}

function Find-DupFiles($files, [long]$minSize) {
    $script:Phase = 'Grouping by size...'; Tick $script:Phase $true
    $bySize = @{}
    $i = 0
    foreach ($f in $files) {
        if ((++$i % 2000) -eq 0) { Tick $script:Phase }
        if ($f.Length -le 0 -or $f.Length -lt $minSize) { continue }
        if (-not $bySize.ContainsKey($f.Length)) { $bySize[$f.Length] = New-Object 'System.Collections.Generic.List[object]' }
        $bySize[$f.Length].Add($f)
    }
    $cands = New-Object 'System.Collections.Generic.List[object]'
    $total = 0L; $hard = 0; $i = 0; $rawT = 0.0; $filesT = 0.0
    foreach ($k in @($bySize.Keys | Sort-Object -Descending)) {   # biggest first: best wins show up early
        $l = $bySize[$k]
        if ($l.Count -lt 2) { continue }
        $script:Phase = 'Preparing candidates...'
        if ((++$i % 500) -eq 0) { Tick $script:Phase; if ($script:Cancel) { return $null } }
        # Hardlinks are checked later, only inside confirmed duplicate sets: opening every same-size file here
        # took many minutes on a big drive (one open per file), and almost none of those files are duplicates.
        $cands.Add($l)
        foreach ($u in $l) { if (-not (Get-CachedHash $u.Path $u.Length $u.Modified.Ticks)) { $total += $u.Length + $script:FileCost; $rawT += $u.Length; $filesT++ } }   # cached files cost no time
    }
    Start-HashStep $rawT $filesT $total
    $groups = New-Object 'System.Collections.Generic.List[object]'
    $n = 0
    foreach ($u in $cands) {
        $byHash = @{}
        foreach ($f in $u) {
            $n++
            $script:Phase = "Hashing (SHA256) file $n..."
            $h = Get-Sha256 $f.Path $f.Length $f.Modified.Ticks
            if ($script:Cancel) { return $null }
            if ((($n) % 50) -eq 0) { Tick $script:Phase }
            if (-not $h) { continue }
            if (-not $byHash.ContainsKey($h)) { $byHash[$h] = New-Object 'System.Collections.Generic.List[object]' }
            $byHash[$h].Add($f)
        }
        foreach ($v in $byHash.Values) {
            if ($v.Count -ge 2) {
                $ids = @{}; $keep = New-Object 'System.Collections.Generic.List[object]'
                foreach ($f in $v) {
                    $id = [FileId]::Get($f.Path)
                    if ($id -and $ids.ContainsKey($id)) { $hard++; continue }   # hardlink to a file already in this set
                    if ($id) { $ids[$id] = $true }
                    $keep.Add($f)
                }
                if ($keep.Count -lt 2) { continue }
                $ng = New-Group 'File' $keep
                $groups.Add($ng)
                [void](& $script:OnGroup 'File' $ng)
            }
        }
        Tick $script:Phase
    }
    [pscustomobject]@{ Groups = $groups; HardlinksCollapsed = $hard }
}

$script:DigestAlg = [Security.Cryptography.SHA256]::Create()
function Get-Digest([string]$s) {
    [BitConverter]::ToString($script:DigestAlg.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))).Replace('-', '')
}

function Find-DupFolders($files, $taint) {
    # Bottom-up folder signatures: linear in files + folders (a folder's signature is built from its
    # direct entries and its sub-folders' signatures), instead of re-listing every file for every ancestor.
    $script:BytesTotal = 0L   # the hashing step before this one is over
    $script:Phase = 'Comparing folder structures...'; Tick $script:Phase $true
    $nodes = @{}
    $i = 0
    foreach ($f in $files) {
        if ((++$i % 2000) -eq 0) { Tick $script:Phase; if ($script:Cancel) { return $null } }
        $d = $f.Dir
        if (-not $nodes.ContainsKey($d)) {
            $chain = New-Object 'System.Collections.Generic.List[string]'; $cur = $d
            while ($cur -and -not $nodes.ContainsKey($cur)) {
                $nodes[$cur] = [pscustomobject]@{
                    Path = $cur; Depth = $cur.Split('\').Count
                    Files = (New-Object 'System.Collections.Generic.List[object]'); Subs = (New-Object 'System.Collections.Generic.List[string]')
                    Shape = $null; Content = $null; Count = 0; Size = 0L
                }
                $chain.Add($cur)
                if ([string]::Equals($cur, $f.Root, 'OrdinalIgnoreCase')) { break }
                $cur = [IO.Path]::GetDirectoryName($cur)
            }
            foreach ($c in $chain) {
                if ([string]::Equals($c, $f.Root, 'OrdinalIgnoreCase')) { continue }
                $p = [IO.Path]::GetDirectoryName($c)
                if ($p -and $nodes.ContainsKey($p)) { $nodes[$p].Subs.Add($c) }
            }
        }
        $nodes[$d].Files.Add($f)
    }
    # a folder is "tainted" if anything inside was skipped -> never compare it
    $bad = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $taint) { $d = $t; while ($d) { if (-not $bad.Add($d)) { break }; $d = [IO.Path]::GetDirectoryName($d) } }

    $order = @($nodes.Values | Sort-Object -Property Depth -Descending)   # deepest first
    $i = 0
    foreach ($n in $order) {
        if ((++$i % 1000) -eq 0) { Tick $script:Phase; if ($script:Cancel) { return $null } }
        if ($bad.Contains($n.Path)) { continue }
        $entries = New-Object 'System.Collections.Generic.List[string]'
        $cnt = 0; $size = 0L; $ok = $true
        foreach ($f in $n.Files) { $entries.Add("f|$($f.Name.ToLowerInvariant())|$($f.Length)"); $cnt++; $size += $f.Length }
        foreach ($sp in $n.Subs) {
            $sn = $nodes[$sp]
            if ($null -eq $sn.Shape) { $ok = $false; break }
            $entries.Add("d|$([IO.Path]::GetFileName($sp).ToLowerInvariant())|$($sn.Shape)"); $cnt += $sn.Count; $size += $sn.Size
        }
        if (-not $ok -or $cnt -eq 0) { continue }
        $arr = $entries.ToArray(); [Array]::Sort($arr, [StringComparer]::Ordinal)
        $n.Shape = Get-Digest ($arr -join "`n"); $n.Count = $cnt; $n.Size = $size
    }
    $byShape = @{}
    foreach ($n in $order) {
        if ($null -eq $n.Shape) { continue }
        if (-not $byShape.ContainsKey($n.Shape)) { $byShape[$n.Shape] = New-Object 'System.Collections.Generic.List[object]' }
        $byShape[$n.Shape].Add($n)
    }
    $candNodes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($g in $byShape.Values) { if ($g.Count -ge 2) { foreach ($n in $g) { $candNodes.Add($n) } } }

    $total = 0L; $rawT = 0.0; $filesT = 0.0
    foreach ($n in $candNodes) { foreach ($f in $n.Files) { if (-not $script:HashCache.ContainsKey($f.Path) -and -not (Get-CachedHash $f.Path $f.Length $f.Modified.Ticks)) { $total += $f.Length + $script:FileCost; $rawT += $f.Length; $filesT++ } } }
    Start-HashStep $rawT $filesT $total

    $nd = 0
    foreach ($n in $candNodes) {
        $nd++
        $script:Phase = "Verifying folder contents ($nd of $($candNodes.Count))..."
        foreach ($f in $n.Files) {
            [void](Get-Sha256 $f.Path $f.Length $f.Modified.Ticks)
            if ($script:Cancel) { return $null }
        }
        if (($nd % 50) -eq 0) { Tick $script:Phase }
    }
    $candSorted = @($candNodes | Sort-Object -Property Depth -Descending)
    $byContent = @{}
    foreach ($n in $candSorted) {
        $entries = New-Object 'System.Collections.Generic.List[string]'; $ok = $true
        foreach ($f in $n.Files) {
            $h = $script:HashCache[$f.Path]
            if (-not $h) { $ok = $false; break }
            $entries.Add("f|$($f.Name.ToLowerInvariant())|$h")
        }
        if ($ok) {
            foreach ($sp in $n.Subs) {
                $sn = $nodes[$sp]
                if ($null -eq $sn.Content) { $ok = $false; break }
                $entries.Add("d|$([IO.Path]::GetFileName($sp).ToLowerInvariant())|$($sn.Content)")
            }
        }
        if (-not $ok) { continue }
        $arr = $entries.ToArray(); [Array]::Sort($arr, [StringComparer]::Ordinal)
        $n.Content = Get-Digest ($arr -join "`n")
        if (-not $byContent.ContainsKey($n.Content)) { $byContent[$n.Content] = New-Object 'System.Collections.Generic.List[object]' }
        $byContent[$n.Content].Add([pscustomobject]@{ Path = $n.Path; Length = $n.Size; Modified = [IO.Directory]::GetCreationTimeUtc($n.Path) })
    }
    $dupDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $raw = @($byContent.Values | Where-Object { $_.Count -ge 2 })
    foreach ($g in $raw) { foreach ($m in $g) { [void]$dupDirs.Add($m.Path) } }
    $groups = New-Object 'System.Collections.Generic.List[object]'
    $nested = New-Object 'System.Collections.Generic.List[object]'
    foreach ($g in $raw) {
        # sub-folder matches that are simply explained by their duplicate parents are not offered for removal (the parent
        # set covers them) but are kept, read-only, so the list filter can still find them
        $explained = $true
        foreach ($m in $g) { $p = [IO.Path]::GetDirectoryName($m.Path); if (-not ($p -and $dupDirs.Contains($p))) { $explained = $false; break } }
        if ($explained) {
            $ng = New-Group 'Folder' $g
            foreach ($it in $ng.Items) { $it.Remove = $false; $it.Nested = $true }
            $nested.Add($ng)
            continue
        }
        $groups.Add((New-Group 'Folder' $g))
    }
    $sortedGroups = New-Object 'System.Collections.Generic.List[object]'
    foreach ($g in @($groups | Sort-Object -Property @{ Expression = { $_.Size * ($_.Items.Count - 1) } } -Descending)) { $sortedGroups.Add($g) }   # most space first
    [pscustomobject]@{ Groups = $sortedGroups; Nested = $nested }
}

# ---- force delete helpers: what usually blocks a folder is a read-only / hidden / system flag, a path longer than 260 characters, or a file in use
function Get-LongPath([string]$p) { if ($p.StartsWith('\\?\')) { $p } elseif ($p.StartsWith('\\')) { '\\?\UNC\' + $p.Substring(2) } else { '\\?\' + $p } }
function Clear-Locks([string]$path) {   # clears read-only / hidden / system on the item and everything inside it
    $lp = Get-LongPath $path; $n = 0
    try {
        if ([IO.Directory]::Exists($lp)) {
            foreach ($e in [IO.Directory]::EnumerateFileSystemEntries($lp, '*', [IO.SearchOption]::AllDirectories)) {
                try { $a = [IO.File]::GetAttributes($e); if (($a -band 7) -ne 0) { [IO.File]::SetAttributes($e, ($a -band (-bnot 7))); $n++ } } catch { }
            }
        }
        $a = [IO.File]::GetAttributes($lp); if (($a -band 7) -ne 0) { [IO.File]::SetAttributes($lp, ($a -band (-bnot 7))); $n++ }
    } catch { }
    $n
}
function Remove-ForceTree([string]$path) {   # permanent delete through the long-path form, then cmd's rd as a last try
    $lp = Get-LongPath $path
    try { [IO.Directory]::Delete($lp, $true) } catch { }
    if ([IO.Directory]::Exists($lp) -and $lp -notmatch '[%^&|<>!"]') { try { [void](Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', "rd /s /q `"$lp`"" -WindowStyle Hidden -Wait) } catch { } }
    -not [IO.Directory]::Exists($lp)
}
function Get-LockedFiles([string]$path, [int]$max = 3) {   # files another program still has open
    $lp = Get-LongPath $path; $out = New-Object System.Collections.Generic.List[string]
    $try = { param($f) try { $fs = [IO.File]::Open($f, 'Open', 'ReadWrite', 'None'); $fs.Dispose() } catch [System.IO.IOException] { $out.Add($f.Replace('\\?\', '')) } catch { } }
    try {
        if ([IO.File]::Exists($lp)) { & $try $lp }
        elseif ([IO.Directory]::Exists($lp)) { foreach ($f in [IO.Directory]::EnumerateFiles($lp, '*', [IO.SearchOption]::AllDirectories)) { & $try $f; if ($out.Count -ge $max) { break } } }
    } catch { }
    $out -join '; '
}
$script:ForceDelete = $true
# space saved so far: every copy that is really removed (or moved away) adds its size; Undo takes it back. Kept between runs.
$script:SavedFile = Join-Path $env:LOCALAPPDATA 'DupCleaner\saved-space.txt'
$script:SavedTotal = 0L
try { if (Test-Path -LiteralPath $script:SavedFile) { $script:SavedTotal = [int64]([IO.File]::ReadAllText($script:SavedFile).Trim()) } } catch { }
function Add-Saved([int64]$n) {
    $script:SavedTotal = [Math]::Max(0L, $script:SavedTotal + $n)
    try { [void][IO.Directory]::CreateDirectory((Split-Path $script:SavedFile)); [IO.File]::WriteAllText($script:SavedFile, [string]$script:SavedTotal) } catch { }
    try { if ($script:SP -and $script:SP.PvDonut) { $script:SP.PvDonut.Invalidate() } } catch { }
}
function Invoke-Removal($groups, [string]$mode, [string]$quarantine, [string]$kind) {
    # groups: only groups with checked (Remove) items. Returns log lines.
    $log = New-Object 'System.Collections.Generic.List[string]'
    $VB = [Microsoft.VisualBasic.FileIO.FileSystem]
    $run = $null; $manifest = $null; $idx = 0
    if ($mode -eq 'move') {
        $run = Join-Path $quarantine (Get-Date -Format 'yyyyMMdd-HHmmss')
        [void][IO.Directory]::CreateDirectory($run)
        $manifest = Join-Path $run 'manifest.csv'
    }
    foreach ($g in $groups) {
        $keepers = @($g.Items | Where-Object { -not $_.Remove })
        if ($keepers.Count -eq 0) { $log.Add("NOTE: every copy of this set was selected, none is kept: $($g.Items[0].Path)") }   # allowed on purpose (the user was warned)
        else {
            $keeperOk = $false
            foreach ($k in $keepers) { if (Test-Path -LiteralPath $k.Path) { $keeperOk = $true } }
            if (-not $keeperOk) { $log.Add("SKIP set: keeper missing - $($keepers[0].Path)"); continue }
        }
        foreach ($it in ($g.Items | Where-Object { $_.Remove })) {
            $p = $it.Path
            if (-not (Test-Path -LiteralPath $p)) {
                # already removed (outside the app, or an earlier run): the list entry is stale, so it is dropped, not reported as a failure. A disk that is not plugged in is different: that stays a skip.
                if ([IO.Directory]::Exists([IO.Path]::GetPathRoot($p))) { $log.Add("GONE (already removed, dropped from the list): $p"); $it.Remove = $null } else { $log.Add("SKIP (disk not connected): $p") }
                continue
            }
            if ($kind -eq 'File' -and (Get-Item -LiteralPath $p -Force).Length -ne $it.Length) { $log.Add("SKIP (changed since scan): $p"); continue }
            try {
                $dest = $null
                $op = {
                    if ($mode -eq 'move') { if ($kind -eq 'Folder') { $VB::MoveDirectory($p, $dest, $false) } else { $VB::MoveFile($p, $dest, $false) } }
                    elseif ($mode -eq 'recycle') { if ($kind -eq 'Folder') { $VB::DeleteDirectory($p, 'OnlyErrorDialogs', 'SendToRecycleBin') } else { $VB::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin') } }
                    else { if ($kind -eq 'Folder') { $VB::DeleteDirectory($p, 'OnlyErrorDialogs', 'DeletePermanently') } else { $VB::DeleteFile($p, 'OnlyErrorDialogs', 'DeletePermanently') } }
                }
                if ($mode -eq 'move') { $idx++; $dest = Join-Path $run ('{0:D4}_{1}' -f $idx, [IO.Path]::GetFileName($p)) }
                $forced = $false
                try { & $op }
                catch {
                    $why = $_.Exception.Message
                    if (-not $script:ForceDelete) { throw }
                    # force: a half-made copy in quarantine is never touched (it may hold the only complete data)
                    if ($mode -eq 'move' -and $dest -and (Test-Path -LiteralPath $dest)) { throw ("$why  [a partial copy is in the quarantine folder: $dest]") }
                    $cleared = Clear-Locks $p
                    try { & $op; $forced = $true }
                    catch {
                        $ok = $false
                        if ($mode -eq 'delete' -and $kind -eq 'Folder') { $ok = Remove-ForceTree $p }
                        if (-not $ok) { $lk = Get-LockedFiles $p; throw ($why + $(if ($lk) { "  [in use by another program: $lk]" } else { "  [no program is holding it: this is a permission problem - run DupCleaner as administrator, or take ownership of the folder in Explorer > Properties > Security]" }) + $(if ($mode -eq 'recycle') { '  [try the quarantine or permanent option]' } else { '' })) }
                        $forced = $true
                    }
                }
                if ($mode -eq 'move') {
                    [pscustomobject]@{ Original = $p; Moved = $dest; Kind = $kind } | Export-Csv -LiteralPath $manifest -Append -NoTypeInformation -Encoding UTF8
                    $log.Add("MOVED: $p")
                } elseif ($mode -eq 'recycle') { $log.Add("RECYCLED: $p") } else { $log.Add("DELETED: $p") }
                if ($forced) { $log.Add("  (forced: read-only / hidden flags cleared first)") }
                $it.Remove = $null   # mark done
                try { Add-Saved ([int64]$it.Length) } catch { }
            } catch { $log.Add("FAILED: $p  ($($_.Exception.Message))") }
        }
    }
    if ($run) { $log.Insert(0, "Moved items are in: $run (manifest.csv enables Undo)") }
    return $log
}

function Restore-Manifest([string]$manifestPath) {
    $VB = [Microsoft.VisualBasic.FileIO.FileSystem]
    $log = New-Object 'System.Collections.Generic.List[string]'
    foreach ($r in (Import-Csv -LiteralPath $manifestPath)) {
        try {
            if (-not (Test-Path -LiteralPath $r.Moved)) { $log.Add("MISSING in quarantine: $($r.Moved)"); continue }
            if (Test-Path -LiteralPath $r.Original) { $log.Add("SKIP (something already at original path): $($r.Original)"); continue }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($r.Original))
            $sz = 0L; try { if ($r.Kind -eq 'Folder') { $sz = [int64](Get-ChildItem -LiteralPath $r.Moved -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } else { $sz = (Get-Item -LiteralPath $r.Moved -Force).Length } } catch { }
            if ($r.Kind -eq 'Folder') { $VB::MoveDirectory($r.Moved, $r.Original, $false) } else { $VB::MoveFile($r.Moved, $r.Original, $false) }
            $log.Add("RESTORED: $($r.Original)"); Add-Saved (-$sz)
        } catch { $log.Add("FAILED: $($r.Original)  ($($_.Exception.Message))") }
    }
    return $log
}

if ($NoGui) { return }

# ---------------------------------------------------------------- GUI
[void][FileId]::SetProcessDPIAware()

# ---- crash log: nothing may close the window silently
$script:LogPath = Join-Path $env:LOCALAPPDATA 'DupCleaner\crash.log'
function Write-CrashLog([string]$where, $err) {
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path $script:LogPath))
        $msg = if ($err -is [Exception]) { $err.ToString() } else { "$err" }
        Add-Content -LiteralPath $script:LogPath -Value "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $where`r`n$msg`r`n"
    } catch { }
}
# every error that the program handles quietly (a file that vanished, a folder it may not read, ...) is recorded in errors.log as well: message, source line, and how often it happened
$script:ErrPath = Join-Path $env:LOCALAPPDATA 'DupCleaner\errors.log'; $script:ErrSeen = @{}
function Write-ErrLog($er) {
    try {
        $msg = $(if ($er -is [Management.Automation.ErrorRecord]) { $er.Exception.Message } else { "$er" }); $ln = $(if ($er -is [Management.Automation.ErrorRecord]) { $er.InvocationInfo.ScriptLineNumber } else { 0 })
        if ($script:ErrSeen.Count -gt 2000) { $script:ErrSeen.Clear() }   # messages that contain paths are all different; do not let the counter table grow without limit
        $key = "$ln|$msg"; $n = 1 + [int]$script:ErrSeen[$key]; $script:ErrSeen[$key] = $n
        if ($n -ne 1 -and $n -ne 10 -and $n -ne 100 -and $n -ne 1000 -and $n -ne 10000) { return }   # the first time, then at 10, 100, 1000 ...
        if ((Test-Path -LiteralPath $script:ErrPath) -and (Get-Item -LiteralPath $script:ErrPath).Length -gt 5MB) { return }
        [void][IO.Directory]::CreateDirectory((Split-Path $script:ErrPath))
        Add-Content -LiteralPath $script:ErrPath -Value "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] line $ln (seen $n x): $msg"
    } catch { }
}
[Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException)
[Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Write-CrashLog 'UI thread exception' $e.Exception
})
[AppDomain]::CurrentDomain.add_UnhandledException({
    param($s, $e)
    Write-CrashLog 'Unhandled exception' $e.ExceptionObject
})

# ---- flight recorder. A process that is killed or runs out of memory cannot write a log as it dies, so the app keeps a
# small "running.txt" up to date every few seconds and deletes it on a clean exit. If the file is still there at the
# next start, the last run died abnormally: its last known state (step, files, memory) goes into crash.log.
$script:RunFile = Join-Path $env:LOCALAPPDATA 'DupCleaner\running.txt'
$script:PrevCrash = $null
try {
    if (Test-Path -LiteralPath $script:RunFile) {
        $script:PrevCrash = [IO.File]::ReadAllText($script:RunFile)
        Write-CrashLog 'PREVIOUS RUN ENDED WITHOUT A CLEAN EXIT (killed, out of memory, or the PC shut down). Last known state:' $script:PrevCrash
    }
} catch { Write-ErrLog $_ }
$script:Started = Get-Date
$script:BeatClock = [Diagnostics.Stopwatch]::StartNew(); $script:LastBeat = -100000L
function Write-Heartbeat([bool]$force = $false) {
    if (-not $force -and ($script:BeatClock.ElapsedMilliseconds - $script:LastBeat) -lt 3000) { return }
    $script:LastBeat = $script:BeatClock.ElapsedMilliseconds
    try {
        $pr = [Diagnostics.Process]::GetCurrentProcess()
        $roots = ''; try { $roots = (@($lstRoots.Items) -join ' | ') } catch { Write-ErrLog $_ }
        $txt = @(
            "Started:        $($script:Started.ToString('yyyy-MM-dd HH:mm:ss'))",
            "Last heartbeat: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))",
            "Scanning:       $($script:Scanning)   Paused: $($script:Paused)",
            "Step:           $($script:Phase)",
            "Progress:       $($script:BytesDone) of $($script:BytesTotal) work units; active time $([int]($script:ActiveMs / 1000))s",
            "Memory:         working set $([int]($pr.WorkingSet64 / 1MB)) MB, private $([int]($pr.PrivateMemorySize64 / 1MB)) MB, managed $([int]([GC]::GetTotalMemory($false) / 1MB)) MB",
            "Folders:        $roots"
        ) -join "`r`n"
        [void][IO.Directory]::CreateDirectory((Split-Path $script:RunFile))
        [IO.File]::WriteAllText($script:RunFile, $txt)
    } catch { Write-ErrLog $_ }
}
function Remove-Heartbeat { try { [IO.File]::Delete($script:RunFile) } catch { Write-ErrLog $_ } }

# Flat tab strip that paints its own background (the native strip stays light grey in a dark window) and window-theme helpers for dark scroll bars / title bar
if (-not ('FlatTabs' -as [type])) {
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System; using System.Drawing; using System.Drawing.Drawing2D; using System.Runtime.InteropServices; using System.Windows.Forms;
public class FlatTabs : TabControl {
  public int Inset = 3; public int Radius = 10;
  // the native tab strip stays light grey right of the last tab: cut that part out of the control so the dark parent shows through
  public void Fit() {
    if (!IsHandleCreated || TabCount == 0) return;
    Rectangle d = DisplayRectangle;
    Region r = new Region(d);
    for (int i = 0; i < TabCount; i++) {
      Rectangle t = GetTabRect(i); Rectangle pr = new Rectangle(t.X + Inset, t.Y + Inset, t.Width - 2 * Inset - 1, t.Height - 2 * Inset);
      using (GraphicsPath gp = Dk.RoundPath(pr, Radius)) { r.Union(gp); }
    }
    Region = r;
  }
  protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Fit(); }
  protected override void OnResize(EventArgs e) { base.OnResize(e); Fit(); }
  protected override void OnSelectedIndexChanged(EventArgs e) { base.OnSelectedIndexChanged(e); Fit(); }
}
public static class Dk {
  public static GraphicsPath RoundPath(Rectangle rc, int r) { GraphicsPath p = new GraphicsPath(); int d = Math.Max(2, r * 2); p.AddArc(rc.X, rc.Y, d, d, 180, 90); p.AddArc(rc.Right - d, rc.Y, d, d, 270, 90); p.AddArc(rc.Right - d, rc.Bottom - d, d, d, 0, 90); p.AddArc(rc.X, rc.Bottom - d, d, d, 90, 90); p.CloseFigure(); return p; }
  public static void Round(Control c, int r) { if (c.Width < 4 || c.Height < 4) return; using (GraphicsPath p = RoundPath(new Rectangle(0, 0, c.Width, c.Height), r)) { c.Region = new Region(p); } }
  public static void Border(Graphics g, Control c, int r, Color col, float w) { g.SmoothingMode = SmoothingMode.AntiAlias; using (Pen pen = new Pen(col, w)) using (GraphicsPath p = RoundPath(new Rectangle(0, 0, c.Width - 1, c.Height - 1), r)) { g.DrawPath(pen, p); } }
  [DllImport("uxtheme.dll", CharSet=CharSet.Unicode)] static extern int SetWindowTheme(IntPtr h, string app, string list);
  [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int v, int size);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
  public static void Theme(IntPtr h, string name) { SetWindowTheme(h, name, null); }
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  public static int HeaderHeight(IntPtr lv) { IntPtr hd = SendMessage(lv, 0x101F, IntPtr.Zero, IntPtr.Zero); if (hd == IntPtr.Zero) return 0; RECT r; GetWindowRect(hd, out r); return r.B - r.T; }
  public static void Header(IntPtr lv) { IntPtr hd = SendMessage(lv, 0x101F, IntPtr.Zero, IntPtr.Zero); if (hd != IntPtr.Zero) SetWindowTheme(hd, "DarkMode_ItemsView", null); }
  public static void Title(IntPtr h) { int v = 1; DwmSetWindowAttribute(h, 20, ref v, 4); }
}
"@
}
[Windows.Forms.Application]::EnableVisualStyles()
$script:Quarantine = ($($qd = [Environment]::GetFolderPath('MyDocuments'); if (-not (Test-Path -LiteralPath (Join-Path $qd 'DupCleaner Quarantine')) -and (Test-Path -LiteralPath (Join-Path $qd 'DupeFinder Quarantine'))) { Join-Path $qd 'DupeFinder Quarantine' } else { Join-Path $qd 'DupCleaner Quarantine' }))
$script:Busy = $false
$script:Results = @{ File = $null; Folder = $null; Nested = $null }   # Nested: sub-folder sets inside duplicate parents (read-only, found by the filter)

$form = New-Object Windows.Forms.Form
$form.Text = 'DupCleaner 2.0'
$form.Font = New-Object Drawing.Font('Segoe UI', 11)
$form.AutoScaleMode = 'Font'
$form.StartPosition = 'Manual'
$form.ClientSize = New-Object Drawing.Size(1180, 800)
$form.MinimumSize = New-Object Drawing.Size(900, 640)
$form.Add_Load({
    $wa = [Windows.Forms.Screen]::FromControl($form).WorkingArea
    $form.Size = New-Object Drawing.Size([int][Math]::Min(1500, $wa.Width * 0.92), [int]($wa.Height * 0.92))
    $form.Location = New-Object Drawing.Point(($wa.X + [int](($wa.Width - $form.Width) / 2)), ($wa.Y + [int](($wa.Height - $form.Height) / 2)))
})
$form.Padding = New-Object Windows.Forms.Padding(10)
# colours of the whole window (same as the approved mock-up)
# dark or light follows the Windows app setting (dark when the setting is missing)
$script:Dark = $true
try { $lt = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop; if ($lt -eq 1) { $script:Dark = $false } } catch { Write-ErrLog $_ }
function C3($r, $g, $b) { [Drawing.Color]::FromArgb($r, $g, $b) }
# rounded corners: the control is clipped to a rounded shape and gets a thin smooth border (like the mock-up)
$script:RoundInfo = @{}
function Set-Round($c, [int]$radius = 12, $border = $null) {
    $g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); try { $k = $g.DpiY / 96.0 } finally { $g.Dispose() }
    $script:RoundInfo[$c.GetHashCode()] = @([int][Math]::Round($radius * $k), $border)
    $c.Add_SizeChanged({ param($s, $e) [Dk]::Round($s, $script:RoundInfo[$s.GetHashCode()][0]) })
    if ($border) { $c.Add_Paint({ param($s, $e) $i = $script:RoundInfo[$s.GetHashCode()]; [Dk]::Border($e.Graphics, $s, $i[0], $i[1], 1.5) }) }
    [Dk]::Round($c, $script:RoundInfo[$c.GetHashCode()][0])
}
# resizable panes: a split bar with a small grip; the position is a share of the pane size and is remembered between runs
$script:LayoutReady = $false
function Style-Split($s) {
    $sc = Get-Sc
    $s.BackColor = $script:UiBg; $s.SplitterWidth = [int](8 * $sc)
    $s.Add_Paint({ param($sx, $e)
        $r = $sx.SplitterRectangle; $k = Get-Sc; $e.Graphics.SmoothingMode = 'AntiAlias'
        $b = New-Object Drawing.SolidBrush $script:UiMuted; $d = [single](3 * $k); $cx = $r.X + $r.Width / 2.0; $cy = $r.Y + $r.Height / 2.0
        foreach ($i in -1, 0, 1) { if ($sx.Orientation -eq 'Vertical') { $e.Graphics.FillEllipse($b, [single]($cx - $d / 2), [single]($cy + $i * 7 * $k - $d / 2), $d, $d) } else { $e.Graphics.FillEllipse($b, [single]($cx + $i * 7 * $k - $d / 2), [single]($cy - $d / 2), $d, $d) } }
        $b.Dispose()
    })
    $s.Add_SplitterMoved({ param($sx, $e) $sx.Invalidate(); if ($script:LayoutReady) { Save-Layout } })
    try { $s.Panel1MinSize = [int](120 * $sc); $s.Panel2MinSize = [int](120 * $sc) } catch { Write-ErrLog $_ }
}
function Get-SplitTotal($s) { if ($s.Orientation -eq 'Vertical') { $s.Width } else { $s.Height } }
function Get-SplitShare($s) { if ($s.Tag -is [double] -and $s.Tag -gt 0) { return [double]$s.Tag }; $t = Get-SplitTotal $s; if ($t -gt 0) { [Math]::Round($s.SplitterDistance / $t, 4) } else { 0.5 } }
function Set-SplitShare($s, [double]$f) {
    if ($f -lt 0.05 -or $f -gt 0.95) { return }
    $t = Get-SplitTotal $s
    if ($t -gt 300) { try { $s.SplitterDistance = [int]($t * $f); $s.Tag = 0.0 } catch { $s.Tag = [double]$f } } else { $s.Tag = [double]$f }
}
function New-Split($orient, [double]$share) {
    $c = New-Object Windows.Forms.SplitContainer; $c.Dock = 'Fill'; $c.Orientation = $orient; $c.Tag = [double]$share
    $c.Add_SizeChanged({ param($s, $e) if ($s.Tag -is [double] -and $s.Tag -gt 0) { $t = Get-SplitTotal $s; if ($t -gt 300) { try { $s.SplitterDistance = [int]($t * $s.Tag); $s.Tag = 0.0 } catch { Write-ErrLog $_ } } } })
    Style-Split $c; $c
}
# master tick box (like the header box in Explorer): ticked = every duplicate is selected, dash = some, empty = none; a click selects all (keep oldest) or clears everything
$script:TickState = @{}; $script:Ticks = @(); $script:PossCache = @{}
function New-Tick {
    $sc = Get-Sc
    $t = New-Object Windows.Forms.Panel; $t.Size = New-Object Drawing.Size([int](15 * $sc), [int](15 * $sc)); $t.Cursor = [Windows.Forms.Cursors]::Hand; $t.Name = 'tick'
    $script:TickState[$t.GetHashCode()] = 0; $script:Ticks += $t
    $t.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'; $st = [int]$script:TickState[$s.GetHashCode()]; $k = (Get-Sc)
        $gp = [Dk]::RoundPath((New-Object Drawing.Rectangle(2, 2, ($s.Width - 5), ($s.Height - 5))), [int](3.2 * $k))
        if ($st -gt 0) { $b = New-Object Drawing.SolidBrush $script:UiAccent; $g.FillPath($b, $gp); $b.Dispose() }
        $pn = New-Object Drawing.Pen ($(if ($st -gt 0) { $script:UiAccent } else { $script:UiMuted })), ([single](1.6 * $k)); $g.DrawPath($pn, $gp); $pn.Dispose(); $gp.Dispose()
        $w = $s.Width; $h = $s.Height
        if ($st -gt 0) {
            $pw = New-Object Drawing.Pen $script:UiOnAccent, ([single](2.0 * $k)); $pw.StartCap = 'Round'; $pw.EndCap = 'Round'; $pw.LineJoin = 'Round'
            if ($st -eq 1) { $g.DrawLines($pw, @((New-Object Drawing.PointF(($w * 0.28), ($h * 0.52))), (New-Object Drawing.PointF(($w * 0.44), ($h * 0.68))), (New-Object Drawing.PointF(($w * 0.74), ($h * 0.34))))) }
            else { $g.DrawLine($pw, ($w * 0.30), ($h * 0.5), ($w * 0.70), ($h * 0.5)) }
            $pw.Dispose()
        }
    })
    $t.Add_Click({
        param($s, $e)
        $m = [Windows.Forms.Control].GetMethod('OnClick', [Reflection.BindingFlags]'NonPublic,Instance')
        if ([int]$script:TickState[$s.GetHashCode()] -eq 1) { [void]$m.Invoke($btnNone, @([EventArgs]::Empty)) } else { [void]$m.Invoke($btnAll, @([EventArgs]::Empty)) }
    })
    $t
}
function Update-Ticks($g, $n) {
    $st = 0
    if ($g -and $n -gt 0) {
        $pc = $script:PossCache[[string]$g.GetHashCode()]
        if (-not $pc -or $pc.Count -ne $g.Count) { $v = 0L; foreach ($s in $g) { if ($s.Items.Count -gt 1) { $v += $s.Items.Count - 1 } }; $pc = @{ Count = $g.Count; Val = $v }; $script:PossCache[[string]$g.GetHashCode()] = $pc }
        $st = $(if ($n -ge $pc.Val) { 1 } else { 2 })
    }
    foreach ($t in $script:Ticks) { if ([int]$script:TickState[$t.GetHashCode()] -ne $st) { $script:TickState[$t.GetHashCode()] = $st; $t.Invalidate() } }
}
if ($script:Dark) {
    $script:UiBg = C3 20 25 22; $script:UiPanel = C3 28 35 31; $script:UiLine = C3 46 56 50
    $script:UiText = C3 232 237 233; $script:UiMuted = C3 154 165 158
    $script:UiAccent = C3 126 162 255; $script:UiAccentDark = C3 160 186 255; $script:UiAccentBg = C3 27 39 69; $script:UiAccentLine = C3 63 93 168
    $script:UiKeepFg = C3 88 201 138; $script:UiKeepBg = C3 25 54 38; $script:UiDelFg = C3 255 138 128; $script:UiDelBg = C3 61 31 29
    $script:UiOnAccent = C3 20 25 22; $script:UiDisabled = C3 52 61 56
} else {
    $script:UiBg = C3 246 247 245; $script:UiPanel = C3 255 255 255; $script:UiLine = C3 221 226 221
    $script:UiText = C3 29 36 32; $script:UiMuted = C3 102 112 106
    $script:UiAccent = C3 43 95 217; $script:UiAccentDark = C3 30 74 180; $script:UiAccentBg = C3 230 237 251; $script:UiAccentLine = C3 143 171 238
    $script:UiKeepFg = C3 30 122 70; $script:UiKeepBg = C3 227 243 233; $script:UiDelFg = C3 179 38 30; $script:UiDelBg = C3 251 230 228
    $script:UiOnAccent = C3 255 255 255; $script:UiDisabled = C3 205 211 220
}
$form.BackColor = $script:UiBg; $form.ForeColor = $script:UiText
# window / taskbar icon: from the exe itself when run as DupCleaner.exe, otherwise from DupCleaner.ico beside the script
try {
    $ico = $null
    $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ([IO.Path]::GetFileNameWithoutExtension($exe) -in 'DupCleaner', 'DupeFinder') { $ico = [Drawing.Icon]::ExtractAssociatedIcon($exe) }
    elseif ($PSCommandPath) { $f = Join-Path (Split-Path $PSCommandPath) 'DupCleaner.ico'; if (Test-Path -LiteralPath $f) { $ico = New-Object Drawing.Icon $f } }
    if ($ico) { $form.Icon = $ico }
} catch { Write-ErrLog $_ }

function New-Btn($text, $primary = $false) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.AutoSize = $true; $b.AutoSizeMode = 'GrowAndShrink'
    $b.Padding = New-Object Windows.Forms.Padding(12, 5, 12, 5)
    $b.Margin = New-Object Windows.Forms.Padding(4)
    $b.MinimumSize = New-Object Drawing.Size(120, 0)
    # flat modern look: white buttons with a thin line, the main action in the accent colour
    $b.FlatStyle = 'Flat'; $b.UseVisualStyleBackColor = $false; $b.Cursor = [Windows.Forms.Cursors]::Hand
    $b.BackColor = $script:UiPanel; $b.ForeColor = $script:UiText
    $b.FlatAppearance.BorderColor = $script:UiLine; $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.MouseOverBackColor = $script:UiAccentBg; $b.FlatAppearance.MouseDownBackColor = $script:UiAccentLine
    Set-Round $b 8 $script:UiLine
    $b.Add_Paint({ param($s, $e) if (-not $s.Enabled) { $bb = New-Object Drawing.SolidBrush $s.BackColor; $e.Graphics.FillRectangle($bb, $s.ClientRectangle); $bb.Dispose(); [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $s.Text, $s.Font, $s.ClientRectangle, [Drawing.Color]::FromArgb(110, $script:UiMuted), [Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter, SingleLine, NoPrefix') } })
    if ($primary) {
        $b.Font = New-Object Drawing.Font($form.Font, [Drawing.FontStyle]::Bold)
        $b.BackColor = $script:UiAccent; $b.ForeColor = $script:UiOnAccent; $b.FlatAppearance.BorderColor = $script:UiAccent
        $b.FlatAppearance.MouseOverBackColor = $script:UiAccentDark; $b.FlatAppearance.MouseDownBackColor = $script:UiAccentDark
        $b.Add_EnabledChanged({ param($s, $e) $s.BackColor = if ($s.Enabled) { $script:UiAccent } else { $script:UiDisabled } })
    }
    $b
}
function New-Chk($text, $checked) {
    $c = New-Object Windows.Forms.CheckBox
    $c.Text = $text; $c.Checked = $checked; $c.AutoSize = $true
    $c.Margin = New-Object Windows.Forms.Padding(4, 3, 4, 3)
    $c
}
function New-Flow($dir) {
    $f = New-Object Windows.Forms.FlowLayoutPanel
    $f.FlowDirection = $dir; $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'; $f.WrapContents = $false
    $f.Margin = New-Object Windows.Forms.Padding(0)
    $f
}
function New-Table($cols, $rows) {
    $t = New-Object Windows.Forms.TableLayoutPanel
    $t.ColumnCount = $cols; $t.RowCount = $rows; $t.Dock = 'Fill'; $t.AutoSize = $false
    $t
}

# ---- root: top / tabs / bottom
$root = New-Table 1 3
$root.Dock = 'Fill'
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
[void]$root.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
$form.Controls.Add($root)

# ---- top: folders, options, scan
$top = New-Table 4 3
$top.Dock = 'Top'; $top.AutoSize = $true; $top.AutoSizeMode = 'GrowAndShrink'
[void]$top.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
foreach ($i in 1..3) { [void]$top.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize'))) }
foreach ($i in 1..3) { [void]$top.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))) }
$root.Controls.Add($top, 0, 0)

$lblRoots = New-Object Windows.Forms.Label
$lblRoots.Text = 'Folders to scan (drag folders onto the list):'; $lblRoots.AutoSize = $true
$lblRoots.Margin = New-Object Windows.Forms.Padding(4, 4, 4, 2)
$top.Controls.Add($lblRoots, 0, 0); $top.SetColumnSpan($lblRoots, 4)

$lstRoots = New-Object Windows.Forms.ListBox
$lstRoots.AllowDrop = $true; $lstRoots.Dock = 'Fill'; $lstRoots.Height = 85
$lstRoots.Margin = New-Object Windows.Forms.Padding(4)
$lstRoots.HorizontalScrollbar = $true
$top.Controls.Add($lstRoots, 0, 1)

$fBtns = New-Flow 'TopDown'
$btnAdd = New-Btn 'Add folder...'; $btnRem = New-Btn 'Remove'
$fBtns.Controls.Add($btnAdd); $fBtns.Controls.Add($btnRem)
$top.Controls.Add($fBtns, 1, 1)

$fOpt = New-Flow 'TopDown'
$chkFiles = New-Chk 'Find duplicate files' $true
$chkFolders = New-Chk 'Find duplicate folders' $true
$chkExcl = New-Chk 'Skip system / package locations' $true
$chkPlace = New-Chk 'Skip OneDrive online-only files' $true
$fMin = New-Flow 'LeftToRight'
$lblMin = New-Object Windows.Forms.Label
$lblMin.Text = 'Ignore files smaller than'; $lblMin.AutoSize = $true; $lblMin.Margin = New-Object Windows.Forms.Padding(4, 6, 2, 0)
$numMin = New-Object Windows.Forms.NumericUpDown
$numMin.Maximum = 10000000; $numMin.Value = 1; $numMin.Width = 90; $numMin.Margin = New-Object Windows.Forms.Padding(2, 2, 2, 2)
$lblKb = New-Object Windows.Forms.Label
$lblKb.Text = 'KB'; $lblKb.AutoSize = $true; $lblKb.Margin = New-Object Windows.Forms.Padding(2, 6, 4, 0)
$fMin.Controls.AddRange(@($lblMin, $numMin, $lblKb))
$chkCache = New-Chk 'Reuse saved fingerprints (faster rescans)' $true
$fOpt.Controls.AddRange(@($chkFiles, $chkFolders, $chkExcl, $chkPlace, $chkCache, $fMin))
$top.Controls.Add($fOpt, 2, 1)
$tip = New-Object Windows.Forms.ToolTip
$tip.SetToolTip($chkExcl, 'Skipped by name: ' + ($script:DefaultExcludes -join ', ') + "`nFolders containing skipped items are never offered as duplicate folders.")
$tip.SetToolTip($chkCache, "Remembers each file's SHA256 with its size and modified time. A file is only re-read if it is new or changed. Untick to force a full re-read.")
$tip.SetToolTip($chkPlace, 'Online-only placeholders would be downloaded just to be read.')

$fScan = New-Flow 'TopDown'
$btnScan = New-Btn 'Scan' $true; $btnScan.MinimumSize = New-Object Drawing.Size(140, 44)
$btnPause = New-Btn 'Pause'; $btnPause.Enabled = $false
$btnCancel = New-Btn 'Cancel'; $btnCancel.Enabled = $false
$fScan.Controls.Add($btnScan); $fScan.Controls.Add($btnPause); $fScan.Controls.Add($btnCancel)
$top.Controls.Add($fScan, 3, 1)

$prog = New-Object Windows.Forms.ProgressBar
$prog.Dock = 'Fill'; $prog.Height = 20; $prog.Margin = New-Object Windows.Forms.Padding(4)
$top.Controls.Add($prog, 0, 2); $top.SetColumnSpan($prog, 4)

$lblStatus = New-Object Windows.Forms.Label
$lblStatus.Text = 'Method: SHA256 of full file contents (same size first). Names are never used.'
$lblStatus.AutoSize = $true; $lblStatus.Margin = New-Object Windows.Forms.Padding(4, 2, 4, 6)
$lblEta = New-Object Windows.Forms.Label
$lblEta.Text = 'Time left: -'
$lblEta.AutoSize = $true; $lblEta.Margin = New-Object Windows.Forms.Padding(4, 2, 4, 2)
$lblEta.Font = New-Object Drawing.Font($form.Font, [Drawing.FontStyle]::Bold)
$top.Controls.Add($lblEta, 0, 3); $top.SetColumnSpan($lblEta, 4)
$top.Controls.Add($lblStatus, 0, 4); $top.SetColumnSpan($lblStatus, 4)
$lblSaved = New-Object Windows.Forms.Label
$lblSaved.Text = 'Last saved -  fingerprints: not yet    results: not yet'
$lblSaved.AutoSize = $true; $lblSaved.Margin = New-Object Windows.Forms.Padding(4, 0, 4, 6); $lblSaved.ForeColor = $script:UiMuted
$script:lblSaved = $lblSaved
$top.Controls.Add($lblSaved, 0, 5); $top.SetColumnSpan($lblSaved, 4)
$top.RowCount = 6; foreach ($i in 1..3) { [void]$top.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))) }
# keep long status text readable: wrap to the window width
$form.Add_Resize({ $lblStatus.MaximumSize = New-Object Drawing.Size([Math]::Max(300, $form.ClientSize.Width - [int](560 * (Get-Sc))), 0) })

# ---- tabs
$tabs = New-Object FlatTabs; $tabs.BackColor = $script:UiBg; $tabs.Dock = 'Fill'; $tabs.MinimumSize = New-Object Drawing.Size(300, 260)
# Easy to tell apart: "Duplicate files" is orange, "Duplicate folders" is cyan (the open tab is the stronger colour, in bold)
$script:TabColors = @(
    $(if ($script:Dark) {
    @(@{ Light = (C3 70 52 30); Strong = (C3 176 112 36); Page = (C3 36 30 22) }, @{ Light = (C3 26 62 68); Strong = (C3 34 140 154); Page = (C3 21 38 41) })
} else {
    @(@{ Light = (C3 255 227 191); Strong = (C3 255 179 92); Page = (C3 255 246 234) }, @{ Light = (C3 201 243 248); Strong = (C3 79 209 224); Page = (C3 234 251 253) })
}))
$tabs.DrawMode = 'OwnerDrawFixed'; $tabs.SizeMode = 'Fixed'
$tabs.ItemSize = New-Object Drawing.Size([int](260 * $form.DeviceDpi / 96.0), [int](36 * $form.DeviceDpi / 96.0))
$tabs.Add_DrawItem({
    param($s, $e)
    $c = $script:TabColors[[math]::Min($e.Index, 1)]; $sel = ($s.SelectedIndex -eq $e.Index)
    $r = $e.Bounds; if ($sel) { $r.Inflate(0, 0) }
    $g0 = New-Object Drawing.SolidBrush $script:UiBg; $e.Graphics.FillRectangle($g0, ($r.X - 3), ($r.Y - 3), ($r.Width + 6), ($r.Height + 6)); $g0.Dispose()
    $e.Graphics.SmoothingMode = 'AntiAlias'; $pr = New-Object Drawing.Rectangle(($r.X + 3), ($r.Y + 3), ($r.Width - 7), ($r.Height - 6)); $gp = [Dk]::RoundPath($pr, [int](10 * (Get-Sc)))
    $br = New-Object Drawing.SolidBrush ($(if ($sel) { $c.Strong } else { $c.Light })); $e.Graphics.FillPath($br, $gp); $br.Dispose(); $gp.Dispose()
    $f = if ($sel) { New-Object Drawing.Font($s.Font, [Drawing.FontStyle]::Bold) } else { $s.Font }
    $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $tb = New-Object Drawing.SolidBrush $script:UiText; $e.Graphics.DrawString($s.TabPages[$e.Index].Text, $f, $tb, [Drawing.RectangleF]$r, $sf); $tb.Dispose()
    if ($sel) { $f.Dispose() }
    $sf.Dispose()
})
$mid = New-Table 2 1
$mid.Dock = 'Fill'
[void]$mid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
[void]$mid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', [int](420 * $form.DeviceDpi / 96.0))))
[void]$mid.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
$mid.Controls.Add($tabs, 0, 0)
$root.Controls.Add($mid, 0, 1)

# ---- donut chart: space that can be freed
$script:ChartData = @()
$chart = New-Object Windows.Forms.Panel
$chart.Dock = 'Fill'; $chart.Margin = New-Object Windows.Forms.Padding(8, 4, 4, 4)
[void][Windows.Forms.Panel].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($chart, $true)
$mid.Controls.Add($chart, 1, 0)
$script:ChartPalette = @('#2E86AB', '#E4572E', '#76B041', '#F3A712', '#9B5DE5', '#00A6A6', '#8D99AE') | ForEach-Object { [Drawing.ColorTranslator]::FromHtml($_) }
$chart.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
    $pad = 8; $w = $s.ClientSize.Width
    $bold = New-Object Drawing.Font($s.Font, [Drawing.FontStyle]::Bold)
    $big = New-Object Drawing.Font($s.Font.FontFamily, ($s.Font.Size * 1.5), [Drawing.FontStyle]::Bold)
    $txt = New-Object Drawing.SolidBrush $script:UiText; $dim = New-Object Drawing.SolidBrush $script:UiMuted
    $g.DrawString('Space you can free', $bold, $txt, $pad, $pad)
    $g.DrawString($script:ChartTitle, $s.Font, $dim, $pad, ($pad + $bold.Height))
    $top = $pad + [int]($bold.Height * 2.4)
    $size = [Math]::Max(80, [Math]::Min($w - 2 * $pad, [int]($s.ClientSize.Height * 0.45)))
    $x = [int](($w - $size) / 2)
    $total = 0L; foreach ($d in $script:ChartData) { $total += $d.Bytes }
    if ($total -le 0) {
        $gb = New-Object Drawing.SolidBrush ($script:UiLine); $g.FillEllipse($gb, $x, $top, $size, $size); $gb.Dispose()
    } else {
        $angle = -90.0; $i = 0
        foreach ($d in $script:ChartData) {
            $sweep = 360.0 * $d.Bytes / $total
            $b = New-Object Drawing.SolidBrush ($script:ChartPalette[[Math]::Min($i, $script:ChartPalette.Count - 1)])
            if ($sweep -ge 359.9) { $g.FillEllipse($b, $x, $top, $size, $size) } else { $g.FillPie($b, $x, $top, $size, $size, [single]$angle, [single]$sweep) }
            $b.Dispose(); $angle += $sweep; $i++
        }
    }
    $hole = [int]($size * 0.58); $hx = $x + [int](($size - $hole) / 2); $hy = $top + [int](($size - $hole) / 2)
    $bg = New-Object Drawing.SolidBrush ($s.BackColor); $g.FillEllipse($bg, $hx, $hy, $hole, $hole); $bg.Dispose()
    $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $cy = $top + $size / 2
    $g.DrawString((Format-Size $total), $big, $txt, [single]($x + $size / 2), [single]($cy - $big.Height * 0.3), $sf)
    $g.DrawString('can be freed', $s.Font, $dim, [single]($x + $size / 2), [single]($cy + $big.Height * 0.45), $sf)
    $ly = $top + $size + 18; $i = 0
    foreach ($d in $script:ChartData) {
        $b = New-Object Drawing.SolidBrush ($script:ChartPalette[[Math]::Min($i, $script:ChartPalette.Count - 1)])
        $g.FillRectangle($b, $pad, $ly + 4, 14, 14); $b.Dispose()
        $pct = if ($total -gt 0) { [int][Math]::Round(100.0 * $d.Bytes / $total) } else { 0 }
        $vw = [int]($g.MeasureString('000.0 MB (100%)', $s.Font).Width)
        $lf = New-Object Drawing.StringFormat; $lf.Trimming = 'EllipsisCharacter'; $lf.FormatFlags = 'NoWrap'
        $rf = New-Object Drawing.StringFormat; $rf.Alignment = 'Far'; $rf.FormatFlags = 'NoWrap'
        $g.DrawString($d.Label, $s.Font, $txt, (New-Object Drawing.RectangleF([single]($pad + 22), [single]$ly, [single]([Math]::Max(20, $w - $pad * 2 - 22 - $vw)), [single]($s.Font.Height + 4))), $lf)
        $g.DrawString("$(Format-Size $d.Bytes) ($pct%)", $s.Font, $txt, (New-Object Drawing.RectangleF([single]($w - $pad - $vw), [single]$ly, [single]$vw, [single]($s.Font.Height + 4))), $rf)
        $lf.Dispose(); $rf.Dispose()
        $ly += [int]($s.Font.Height * 1.4); $i++
        if ($ly -gt $s.ClientSize.Height - $s.Font.Height) { break }
    }
    $bold.Dispose(); $big.Dispose(); $sf.Dispose(); $txt.Dispose(); $dim.Dispose()
})
$script:ChartTitle = 'by file type'
$script:ChartClock = [Diagnostics.Stopwatch]::StartNew(); $script:ChartLast = -1000
$views = @{}
function New-View($title, $kind) {
    $tp = New-Object Windows.Forms.TabPage $title
    $tp.UseVisualStyleBackColor = $false; $tp.BackColor = $script:TabColors[$(if ($kind -eq 'Folder') { 1 } else { 0 })].Page   # light tint in the tab's colour
    $lv = New-Object Windows.Forms.ListView
    $lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.ShowGroups = $true; $lv.HideSelection = $false
    $sc = $form.DeviceDpi / 96.0
    foreach ($c in @(@('Name', 230), @('Location', 330), @('Size', 100), @('Modified', 170), @('Action', 100), @('Type', 100))) { [void]$lv.Columns.Add($c[0], [int]($c[1] * $sc)) }
    $lv.Columns[5].DisplayIndex = 3   # file type (same groups as the chart) shown after Size; column indexes used by the code stay the same
    $lv.Tag = $kind
    if ($true) {
        $lv.OwnerDraw = $true
        $lv.Add_DrawColumnHeader({
            param($s, $e)
            $bb = New-Object Drawing.SolidBrush $script:UiPanel; $e.Graphics.FillRectangle($bb, $e.Bounds); $bb.Dispose()
            $pn = New-Object Drawing.Pen $script:UiLine; $e.Graphics.DrawLine($pn, $e.Bounds.Left, $e.Bounds.Bottom - 1, $e.Bounds.Right, $e.Bounds.Bottom - 1); $e.Graphics.DrawLine($pn, $e.Bounds.Right - 1, $e.Bounds.Top + 2, $e.Bounds.Right - 1, $e.Bounds.Bottom - 3); $pn.Dispose()
            $off = $(if ($e.ColumnIndex -eq 0 -and $s.Tag -eq 'File') { [int](26 * (Get-Sc)) } else { 4 })
            $rc = New-Object Drawing.Rectangle(($e.Bounds.X + $off), $e.Bounds.Y, ($e.Bounds.Width - $off - 4), $e.Bounds.Height)
            [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $s.Font, $rc, $script:UiMuted, [Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, NoPrefix')
        })
        $lv.Add_DrawItem({ param($s, $e) $e.DrawDefault = $true })
        $lv.Add_DrawSubItem({ param($s, $e) $e.DrawDefault = $true })
    }
    # ListView is not double-buffered by default: every batch of new rows (and every re-sort) repainted visibly = flicker
    [void][Windows.Forms.ListView].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($lv, $true)
    $lv.Add_SizeChanged({
        param($s, $e)
        $used = 0; foreach ($i in 0, 2, 3, 4, 5) { $used += $s.Columns[$i].Width }
        $w = $s.ClientSize.Width - $used - [Windows.Forms.SystemInformation]::VerticalScrollBarWidth
        if ($w -gt 150) { $s.Columns[1].Width = $w }
    })
    $cm = New-Object Windows.Forms.ContextMenuStrip
    # check a single file/folder by opening it: with its default program, or choose the program ("Open with")
    $miOpen = $cm.Items.Add('Open')
    $miOpen.Add_Click({
        $v = $tabs.SelectedTab.Controls[0]
        if ($v.SelectedItems.Count) {
            $pth = $v.SelectedItems[0].Tag.Path
            Open-File $pth
        }
    })
    $miWith = $cm.Items.Add('Open with...')
    $miWith.Add_Click({
        $v = $tabs.SelectedTab.Controls[0]
        if ($v.SelectedItems.Count) {
            $pth = $v.SelectedItems[0].Tag.Path
            if (Test-Path -LiteralPath $pth -PathType Container) { [void][Windows.Forms.MessageBox]::Show('"Open with" works on files. Use "Open" to open the folder.', 'DupCleaner'); return }
            try { Start-Process rundll32.exe -ArgumentList "shell32.dll,OpenAs_RunDLL `"$pth`"" } catch { [void][Windows.Forms.MessageBox]::Show("Could not show the program list:`n$($_.Exception.Message)", 'DupCleaner') }
        }
    })
    $mp = $cm.Items.Add('Preview'); $mp.Add_Click({ Show-PreviewSelected })
    $mi = $cm.Items.Add('Show in Explorer')
    $mi.Add_Click({ $v = $tabs.SelectedTab.Controls[0]; if ($v.SelectedItems.Count) { Start-Process explorer.exe -ArgumentList "/select,`"$($v.SelectedItems[0].Tag.Path)`"" } })
    $cm.Add_Opening({ param($s, $e) $v = $tabs.SelectedTab.Controls[0]; if (-not $v.SelectedItems.Count) { $e.Cancel = $true } })   # menu only on a selected row
    $lv.ContextMenuStrip = $cm
    # filter bar above the list: words (name or path / name only), file type and modified date; all conditions must hold
    $bar = New-Flow 'LeftToRight'; $bar.Dock = 'Top'; $bar.WrapContents = $true
    $mk = { param($t) $l = New-Object Windows.Forms.Label; $l.Text = $t; $l.AutoSize = $true; $l.Margin = New-Object Windows.Forms.Padding(8, 9, 2, 4); $l }
    $mkc = { param($items, $w) $c = New-Object Windows.Forms.ComboBox; $c.DropDownStyle = 'DropDownList'; $c.Width = [int]($w * $sc); $c.Margin = New-Object Windows.Forms.Padding(2, 5, 4, 4); $c.Tag = $kind; [void]$c.Items.AddRange($items); $c.SelectedIndex = 0; $c }
    $fl = & $mk $(if ($kind -eq 'Folder') { 'Filter folders:' } else { 'Filter files:' }); $fl.Margin = New-Object Windows.Forms.Padding(4, 9, 2, 4)
    $ft = New-Object Windows.Forms.TextBox; $ft.Width = [int](260 * $sc); $ft.Margin = New-Object Windows.Forms.Padding(4, 5, 4, 4); $ft.Tag = $kind
    $cbScope = & $mkc @('Name or path', 'Name only') 220
    $lblType = & $mk 'Type:'
    $cbType = & $mkc @('Any type', 'Images', 'Video', 'Audio', 'Documents', 'Archives', 'Other') 160
    if ($kind -eq 'Folder') { $lblType.Visible = $false; $cbType.Visible = $false }   # folders have no file type
    $lblWhen = & $mk 'Modified:'
    $cbWhen = & $mkc @('Any date', 'Today', 'Last 7 days', 'Last 30 days', 'Last 12 months', 'Older than 1 year', 'Older than 5 years', 'Custom range...') 170
    $dtFrom = New-Object Windows.Forms.DateTimePicker; $dtFrom.Format = 'Short'; $dtFrom.Width = [int](130 * $sc); $dtFrom.Margin = New-Object Windows.Forms.Padding(2, 5, 2, 4); $dtFrom.Tag = $kind
    $dtTo = New-Object Windows.Forms.DateTimePicker; $dtTo.Format = 'Short'; $dtTo.Width = [int](130 * $sc); $dtTo.Margin = New-Object Windows.Forms.Padding(2, 5, 2, 4); $dtTo.Tag = $kind
    $lblTo = & $mk 'to'
    foreach ($x in $dtFrom, $dtTo, $lblTo) { $x.Visible = $false }
    $fc = New-Btn 'Clear'; $fc.MinimumSize = New-Object Drawing.Size(0, 0); $fc.Tag = $kind
    $bSmall = New-Btn 'A-'; $bSmall.MinimumSize = New-Object Drawing.Size(0, 0); $bBig = New-Btn 'A+'; $bBig.MinimumSize = New-Object Drawing.Size(0, 0)
    $tip.SetToolTip($bSmall, 'Smaller list text (Ctrl + mouse wheel also works)'); $tip.SetToolTip($bBig, 'Bigger list text (Ctrl + mouse wheel also works)')
    $tip.SetToolTip($cbType, 'Shows the sets that contain at least one file of this type'); $tip.SetToolTip($cbWhen, 'Shows the sets that contain at least one item modified in this period')
    $bar.Controls.AddRange(@($fl, $ft, $cbScope, $lblType, $cbType, $lblWhen, $cbWhen, $dtFrom, $lblTo, $dtTo))
    $lvlCtl = @()
    $lvlVal = $null
    if ($kind -eq 'Folder') {
        # directory level: shows only the folder sets whose folders sit exactly this many levels deep (D:\a\b = level 3); - goes up, + goes down
        $lblLvl = & $mk 'Level:'
        $bMinus = New-Btn '-'; $bPlus = New-Btn '+'
        foreach ($b in $bMinus, $bPlus) { $b.MinimumSize = New-Object Drawing.Size([int](34 * $sc), 0); $b.Tag = $kind; $b.Margin = New-Object Windows.Forms.Padding(2, 4, 2, 4) }
        $lvlVal = & $mk 'All'; $lvlVal.AutoSize = $false; $lvlVal.Width = [int](48 * $sc); $lvlVal.TextAlign = 'MiddleCenter'; $lvlVal.Margin = New-Object Windows.Forms.Padding(0, 9, 0, 4); $lvlVal.Font = New-Object Drawing.Font($lvlVal.Font, [Drawing.FontStyle]::Bold)
        $tip.SetToolTip($bMinus, 'Go up: fewer levels below the root (back to All after level 1)'); $tip.SetToolTip($bPlus, 'Go down: from All start at the root (level 1), then one more level deeper each click')
        $tip.SetToolTip($lvlVal, 'Directory level: All, or only folders from the scanned root down to this level (level 1 = directly inside the root, 2 = one deeper...)')
        $bar.Controls.AddRange(@($lblLvl, $bMinus, $lvlVal, $bPlus))
        $bMinus.Add_Click({ param($s, $e) Step-Level $s.Tag -1 })
        $bPlus.Add_Click({ param($s, $e) Step-Level $s.Tag 1 })
        $lvlCtl = @($bMinus, $bPlus)
    }
    $bar.Controls.AddRange(@($fc, $bSmall, $bBig))
    $trig = { param($s, $e) $script:FilterKind = $s.Tag; $script:FilterTimer.Stop(); $script:FilterTimer.Start() }
    $ft.Add_TextChanged($trig); $cbScope.Add_SelectedIndexChanged($trig); $cbType.Add_SelectedIndexChanged($trig); $dtFrom.Add_ValueChanged($trig); $dtTo.Add_ValueChanged($trig)
    $cbWhen.Add_SelectedIndexChanged({
        param($s, $e)
        $c = $script:FilterCtl[$s.Tag]; $custom = ($s.SelectedIndex -eq 7)
        $c.From.Visible = $custom; $c.To.Visible = $custom; $c.ToLbl.Visible = $custom
        $script:FilterKind = $s.Tag; $script:FilterTimer.Stop(); $script:FilterTimer.Start()
    })
    $fc.Add_Click({ param($s, $e) Reset-FilterControls $s.Tag; $script:FilterText[$s.Tag] = [string][char]1; $script:FilterKind = $s.Tag; $script:FilterTimer.Stop(); $script:FilterTimer.Start(); $script:FilterCtl[$s.Tag].Text.Focus() })
    $bSmall.Add_Click({ Set-ListFont ($script:ListFontSize - 1) }); $bBig.Add_Click({ Set-ListFont ($script:ListFontSize + 1) })
    $script:FilterCtl[$kind] = @{ Text = $ft; Scope = $cbScope; Type = $cbType; When = $cbWhen; From = $dtFrom; To = $dtTo; ToLbl = $lblTo; Clear = $fc; LevelLbl = $lvlVal; All = (@($ft, $cbScope, $cbType, $cbWhen, $dtFrom, $dtTo, $fc) + $lvlCtl) }
    if ($kind -eq 'Folder') { $script:FolderBar = $bar; $script:FolderBarKeep = @($bSmall, $bBig) }
    $lv.Font = $script:ListFont
    $lv.Add_MouseWheel({
        param($s, $e)
        if ([Windows.Forms.Control]::ModifierKeys -band [Windows.Forms.Keys]::Control) {   # Ctrl + wheel changes the text size
            try { ([Windows.Forms.HandledMouseEventArgs]$e).Handled = $true } catch { Write-ErrLog $_ }
            Set-ListFont ($script:ListFontSize + [math]::Sign($e.Delta))
        }
    })
    $tp.Controls.Add($bar); $tp.Controls.Add($lv); $tp.Controls.SetChildIndex($lv, 0)   # the list stays Controls[0] (code relies on it)
    $tabs.TabPages.Add($tp)
    $views[$kind] = $lv
}
$script:FilterCtl = @{}; $script:FilterText = @{ File = ''; Folder = '' }; $script:Crit = @{ File = $null; Folder = $null }; $script:MatchCount = @{ File = 0; Folder = 0 }
$script:FilterKind = 'File'
$script:ListFontSize = 11.0
$script:OpenWith = @{}   # program used to open files: key = category (all, image, video, audio, document, text), value = path of an .exe
try {
    $sp = Join-Path $env:LOCALAPPDATA 'DupCleaner\settings.json'
    if (Test-Path -LiteralPath $sp) { $st = [IO.File]::ReadAllText($sp) | ConvertFrom-Json; if ($st.ListFont -ge 8 -and $st.ListFont -le 30) { $script:ListFontSize = [double]$st.ListFont }; if ($st.OpenWith) { foreach ($pr in $st.OpenWith.PSObject.Properties) { if ($pr.Value) { $script:OpenWith[[string]$pr.Name] = [string]$pr.Value } } } }
} catch { Write-ErrLog $_ }
$script:ListFont = New-Object Drawing.Font('Segoe UI', [single]$script:ListFontSize)
$script:ListBold = New-Object Drawing.Font($script:ListFont, [Drawing.FontStyle]::Bold)
$script:FilterTimer = New-Object Windows.Forms.Timer; $script:FilterTimer.Interval = 350
function Set-FilterEnabled([bool]$on) { foreach ($k in 'File', 'Folder') { if ($script:FilterCtl[$k]) { foreach ($c in $script:FilterCtl[$k].All) { $c.Enabled = $on } } } }
function Reset-FilterControls([string]$kind) {
    $c = $script:FilterCtl[$kind]; if (-not $c) { return }
    $c.Text.Text = ''; $c.Scope.SelectedIndex = 0; $c.Type.SelectedIndex = 0; $c.When.SelectedIndex = 0
    $script:FilterText[$kind] = ''; $script:Crit[$kind] = $null
    $script:Level[$kind] = 0; if ($c.LevelLbl) { $c.LevelLbl.Text = 'All' }
}
$script:Level = @{ File = 0; Folder = 0 }
# Level = how many folders below the scanned root: level 1 = directly inside the root, 2 = one deeper, ... A level filter shows everything from the root down to that level.
function Get-LevelRoots { @($lstRoots.Items | ForEach-Object { ([string]$_).TrimEnd('\') } | Sort-Object Length -Descending) }
function Get-RelDepth([string]$p, $roots) {
    $p = $p.TrimEnd('\'); $segs = @($p.Split('\')).Count
    foreach ($r in $roots) {
        if ($p.Length -gt $r.Length -and $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) { return $segs - @($r.Split('\')).Count }
    }
    return [math]::Max(1, $segs - 1)   # not under a known root: count from the drive
}
function Step-Level([string]$kind, [int]$dir) {
    $roots = Get-LevelRoots; $max = 0
    foreach ($k in 'Folder', 'Nested') { if ($script:Results[$k]) { foreach ($s in $script:Results[$k]) { foreach ($it in $s.Items) { $d = Get-RelDepth $it.Path $roots; if ($d -gt $max) { $max = $d } } } } }
    if ($max -eq 0) { return }
    $cur = [int]$script:Level[$kind]
    if ($dir -gt 0) { if ($cur -eq 0) { $cur = 1 } elseif ($cur -lt $max) { $cur++ } else { $cur = 0 } }   # All -> root level -> deeper ... -> All
    else { if ($cur -eq 0) { $cur = $max } elseif ($cur -gt 1) { $cur-- } else { $cur = 0 } }
    $script:Level[$kind] = $cur
    $script:FilterCtl[$kind].LevelLbl.Text = $(if ($cur) { [string]$cur } else { 'All' })
    $script:FilterKind = $kind; $script:FilterTimer.Stop(); $script:FilterTimer.Start()
}
function Get-FilterCrit([string]$kind) {   # what the filter bar currently asks for, plus a readable description
    $c = $script:FilterCtl[$kind]; $parts = @()
    $all = @($c.Text.Text.Trim().ToLowerInvariant() -split '\s+' | Where-Object { $_ })
    $nameOnly = ($c.Scope.SelectedIndex -eq 1)
    # a word with * or ? (like *.exe) is a wildcard that must fit a whole file name; other words are searched inside the name/path
    $terms = @($all | Where-Object { $_ -notmatch '[*?]' })
    $wild = @($all | Where-Object { $_ -match '[*?]' } | ForEach-Object { New-Object Text.RegularExpressions.Regex(('^' + [regex]::Escape($_).Replace('\*', '.*').Replace('\?', '.') + '$'), 'IgnoreCase, CultureInvariant') })
    if ($all.Count) { $parts += "$(if ($nameOnly) { 'name' } else { 'name/path' }) ""$($all -join ' ')""" }
    $type = ''; if ($kind -eq 'File' -and $c.Type.SelectedIndex -gt 0) { $type = [string]$c.Type.SelectedItem; $parts += "type $type" }
    $lvl = [int]$script:Level[$kind]; $lvlRoots = @(); if ($lvl) { $parts += "levels 1-$lvl"; $lvlRoots = Get-LevelRoots }
    $from = $null; $to = $null; $now = Get-Date; $w = $c.When.SelectedIndex
    switch ($w) {
        1 { $from = $now.Date }
        2 { $from = $now.Date.AddDays(-6) }
        3 { $from = $now.Date.AddDays(-29) }
        4 { $from = $now.AddYears(-1) }
        5 { $to = $now.AddYears(-1) }
        6 { $to = $now.AddYears(-5) }
        7 { $from = $c.From.Value.Date; $to = $c.To.Value.Date.AddDays(1).AddTicks(-1) }
    }
    if ($w -eq 7) { $parts += "modified $($from.ToString('yyyy-MM-dd')) to $($c.To.Value.ToString('yyyy-MM-dd'))" } elseif ($w -gt 0) { $parts += "modified: $($c.When.SelectedItem)" }
    [pscustomobject]@{ Terms = $terms; Wild = $wild; Level = $lvl; Roots = $lvlRoots; NameOnly = $nameOnly; Type = $type; From = $from; To = $to; Desc = ($parts -join ', ') }
}
function Test-SetMatch($set, $crit) {
    if ($crit.Level) {   # directory level: some folder of the set is at most this many levels below the root
        $ok = $false
        foreach ($it in $set.Items) { if ((Get-RelDepth $it.Path $crit.Roots) -le $crit.Level) { $ok = $true; break } }
        if (-not $ok) { return $false }
    }
    foreach ($rx in $crit.Wild) {   # wildcard word: some item's file name must fit it
        $hit = $false
        foreach ($it in $set.Items) { if ($rx.IsMatch([IO.Path]::GetFileName($it.Path))) { $hit = $true; break } }
        if (-not $hit) { return $false }
    }
    if ($crit.Terms.Count) {
        $sb = New-Object Text.StringBuilder
        foreach ($it in $set.Items) { if ($crit.NameOnly) { [void]$sb.Append([IO.Path]::GetFileName($it.Path).ToLowerInvariant()) } else { [void]$sb.Append($it.Path.ToLowerInvariant()) }; [void]$sb.Append('|') }
        $hay = $sb.ToString()
        foreach ($t in $crit.Terms) { if ($hay.IndexOf($t, [StringComparison]::Ordinal) -lt 0) { return $false } }
    }
    if ($crit.Type) {   # at least one file in the set has this type
        $ok = $false
        foreach ($it in $set.Items) { if ((Get-Category $it.Path) -eq $crit.Type) { $ok = $true; break } }
        if (-not $ok) { return $false }
    }
    if ($crit.From -or $crit.To) {   # at least one item in the set was modified in the period
        $ok = $false
        foreach ($it in $set.Items) {
            $m = $it.Modified.ToLocalTime()
            if ((-not $crit.From -or $m -ge $crit.From) -and (-not $crit.To -or $m -le $crit.To)) { $ok = $true; break }
        }
        if (-not $ok) { return $false }
    }
    return $true
}

# ---- list text size (A- / A+ / Ctrl+wheel), remembered between runs
$script:SettingsPath = Join-Path $env:LOCALAPPDATA 'DupCleaner\settings.json'
function Save-Settings { try { [void][IO.Directory]::CreateDirectory((Split-Path $script:SettingsPath)); [IO.File]::WriteAllText($script:SettingsPath, (@{ ListFont = $script:ListFontSize; OpenWith = $script:OpenWith } | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false))) } catch { Write-ErrLog $_ } }
# ---- which program opens a file (Open button, double-click, right-click Open): per type, else for all files, else the Windows default
$script:OpenCats = [ordered]@{ all = 'All files (default)'; image = 'Pictures'; video = 'Videos'; audio = 'Music'; document = 'Documents'; text = 'Text and data' }
function Get-OpenCategory([string]$path) {
    $e = [IO.Path]::GetExtension($path).ToLowerInvariant().TrimStart('.')
    if ('png jpg jpeg gif bmp webp tif tiff heic ico svg' -split ' ' -contains $e) { return 'image' }
    if ('mp4 mkv avi mov wmv webm m4v mpg mpeg' -split ' ' -contains $e) { return 'video' }
    if ('mp3 wav flac aac ogg m4a wma' -split ' ' -contains $e) { return 'audio' }
    if ('pdf doc docx xls xlsx ppt pptx odt ods rtf' -split ' ' -contains $e) { return 'document' }
    if ('txt csv log md json xml ini ps1 cmd bat html htm css js' -split ' ' -contains $e) { return 'text' }
    return 'other'
}
function Open-File([string]$path) {
    if (-not $path) { return }
    $prog = $null; $missing = $null
    if (-not [IO.Directory]::Exists($path)) {
        foreach ($k in @((Get-OpenCategory $path), 'all')) {
            if ($script:OpenWith.ContainsKey($k) -and $script:OpenWith[$k]) {
                if ([IO.File]::Exists($script:OpenWith[$k])) { $prog = $script:OpenWith[$k]; break } elseif (-not $missing) { $missing = $script:OpenWith[$k] }
            }
        }
    }
    if ($prog) {
        try { [void](Start-Process -FilePath $prog -ArgumentList ('"' + $path + '"')); return }
        catch { $missing = $prog }
    }
    if ($missing) { [void][Windows.Forms.MessageBox]::Show("The program chosen for opening files is not available:`n$missing`n`nOpening with the Windows default instead.", 'DupCleaner') }
    try { [void][Diagnostics.Process]::Start($path) } catch { [void][Windows.Forms.MessageBox]::Show("Could not open:`n$path`n`n$($_.Exception.Message)", 'DupCleaner') }
}
function Set-ListFont([double]$size) {
    $size = [math]::Max(8.0, [math]::Min(30.0, $size)); if ($size -eq $script:ListFontSize) { return }
    $ratio = $size / $script:ListFontSize; $script:ListFontSize = $size
    $script:ListFont = New-Object Drawing.Font('Segoe UI', [single]$size); $script:ListBold = New-Object Drawing.Font($script:ListFont, [Drawing.FontStyle]::Bold)
    foreach ($k in 'File', 'Folder') {
        $lv = $views[$k]; if (-not $lv) { continue }
        $lv.BeginUpdate(); $lv.Font = $script:ListFont
        foreach ($c in $lv.Columns) { $c.Width = [int]($c.Width * $ratio) }
        foreach ($lvi in $lv.Items) { Update-Row $lvi }   # rows keep their own font (bold KEEP rows), so refresh them
        $lv.EndUpdate()
    }
    if ($script:SP) { Set-SpFonts }
    Save-Settings
    $lblStatus.Text = "List text size: $size (A- / A+ or Ctrl + mouse wheel)"
}

New-View 'Duplicate files' 'File'
New-View 'Duplicate folders' 'Folder'

# ---- Folders tab in three panes.
#  Left:   the duplicate folder sets (search a word in any path, sort by space / name / copies / date).
#  Middle: the copies of the chosen set, each with KEEP / DELETE, and below them a blue panel with everything inside the folder (sub-folders and files).
#  Right:  a preview of the file chosen in the blue panel.
function Get-Sc { $g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); try { return $g.DpiY / 96.0 } finally { $g.Dispose() } }   # screen scale: fonts follow it (the form's own DeviceDpi can report 96 here)
$script:SP = $null; $script:SpSig = ''; $script:SpCur = $null; $script:SpBrowse = $null; $script:SpBusy = $false; $script:SpMaxKids = 3000
$script:Icons = New-Object Windows.Forms.ImageList; $script:Icons.ColorDepth = 'Depth32Bit'; $script:Icons.ImageSize = New-Object Drawing.Size([int](16 * (Get-Sc)), [int](16 * (Get-Sc)))
$script:SpBlue = $script:UiAccentBg; $script:SpBlueLine = $script:UiAccentLine
$script:SpKeepBg = $script:UiKeepBg; $script:SpDelBg = $script:UiDelBg
$script:SpKeepFg = $script:UiKeepFg; $script:SpDelFg = $script:UiDelFg

function Get-IconKey([string]$name, [bool]$isDir) {
    $key = if ($isDir) { '<dir>' } else { $e = [IO.Path]::GetExtension($name).ToLowerInvariant(); if ($e) { $e } else { '<file>' } }
    if (-not $script:Icons.Images.ContainsKey($key)) {
        $bmp = $null
        try { $bmp = [ShellIcon]::Get($(if ($isDir) { 'folder' } else { 'file' + [IO.Path]::GetExtension($name) }), $isDir) } catch { Write-ErrLog $_ }
        if (-not $bmp) { $bmp = New-Object Drawing.Bitmap 16, 16 }
        $script:Icons.Images.Add($key, $bmp)
    }
    return $key
}

function Get-SetLine($set) {
    $del = 0; foreach ($it in $set.Items) { if ($it.Remove) { $del++ } }
    $s = "$($set.Items.Count) copies  -  $(Format-Size $set.Size) each  -  "
    if ($del -eq 0) { return $s + 'none marked for delete' }
    return $s + "delete $del (frees $(Format-Size ($set.Size * $del)))"
}

# ---- left pane
$script:ResortAt = 0; $script:ResortPending = $false; $script:InvAt = 0; $script:BucketAt = 0; $script:Buckets = @(0L, 0L, 0L)
$script:SetKeys = @{}   # sort keys of the "largest and safest" order; only the set that was just investigated is recomputed
function Get-SetArray([bool]$fresh) {
    $sp = $script:SP; $f = $script:Results['Folder']
    $mode = [math]::Max(0, $sp.Sort.SelectedIndex)
    $arr = [SetUtil]::Sorted($f, $(if ($mode -eq 4) { 0 } else { $mode }), $sp.Search.Text.Trim())
    if ($mode -eq 4 -and $arr.Length -gt 1) {   # highest safety score first, then the most space to free; sets not yet investigated come after the investigated ones, largest first
        if ($fresh) { $script:SetKeys = @{} }
        $rows = foreach ($s in $arr) {
            $k = $script:SetKeys[$s]
            if (-not $k) { $q = Get-SetScore $s; $fr = [double]$s.Size * ($s.Items.Count - 1); $k = [pscustomobject]@{ Known = $(if ($q) { 0 } else { 1 }); Score = $(if ($q) { -$q.Score } else { 0 }); Fr = -$fr }; if ($q) { $script:SetKeys[$s] = $k } }
            [pscustomobject]@{ S = $s; Known = $k.Known; Score = $k.Score; Fr = $k.Fr }
        }
        $arr = @($rows | Sort-Object Known, Score, Fr | ForEach-Object { $_.S })
    }
    if ($script:SafetyFilter -gt 0) { $want = $(if ($script:SafetyFilter -le 5) { $script:SafetyClasses[$script:SafetyFilter - 1] } else { '' }); $arr = @($arr | Where-Object { (Get-SetBestClass $_) -eq $want }) }
    $arr
}
# re-sort after one more set got its score: same items, new order; the selected set stays selected and the scroll position is kept; nothing is reloaded
function Resort-SetList($changed) {
    $sp = $script:SP; if (-not $sp -or $script:SpBusy) { return }
    if ($changed) { $script:SetKeys.Remove($changed) }
    $now = [Environment]::TickCount
    if (($now - $script:ResortAt) -lt 2500 -and ($now - $script:ResortAt) -ge 0) { $script:ResortPending = $true; return }   # at most one re-order every 2.5 s, so the list does not flicker
    $script:ResortAt = $now; $script:ResortPending = $false
    $arr = @(Get-SetArray $false)
    $cur = $sp.Lb.Items; $same = ($cur.Count -eq $arr.Length); if ($same) { for ($i = 0; $i -lt $arr.Length; $i++) { if (-not [object]::ReferenceEquals($cur[$i], $arr[$i])) { $same = $false; break } } }
    if ($same) { return }   # same order: nothing to rebuild
    $sel = $sp.Lb.SelectedItem; $top = $sp.Lb.TopIndex
    $script:SpBusy = $true
    $sp.Lb.BeginUpdate()
    try {
        $sp.Lb.Items.Clear(); if ($arr.Length -gt 0) { $sp.Lb.Items.AddRange([object[]]$arr) }
        if ($sel) { $i = $sp.Lb.Items.IndexOf($sel); if ($i -ge 0) { $sp.Lb.SelectedIndex = $i } }
        if ($sp.Lb.Items.Count -gt 0) { $sp.Lb.TopIndex = [math]::Min($top, $sp.Lb.Items.Count - 1) }
    } finally { $sp.Lb.EndUpdate(); $script:SpBusy = $false }
}
function Rebuild-SetList {
    $sp = $script:SP; if (-not $sp) { return }
    $f = $script:Results['Folder']
    $arr = @(Get-SetArray $true)
    $prev = $script:SpCur
    $script:SpBusy = $true
    $sp.Lb.BeginUpdate()
    try { $sp.Lb.Items.Clear(); if ($arr.Length -gt 0) { $sp.Lb.Items.AddRange([object[]]$arr) } } finally { $sp.Lb.EndUpdate() }
    $total = $(if ($f) { $f.Count } else { 0 })
    $sp.Count.Text = $(if ($null -eq $f) { 'No scan yet.' } elseif ($script:SafetyFilter -gt 0) { "$($arr.Length) of $total sets: $($script:SafetyFilterNames[$script:SafetyFilter])" } elseif ($sp.Search.Text.Trim()) { "$($arr.Length) of $total sets match" } else { "$total duplicate folder sets" })
    $idx = -1; if ($prev) { $idx = $sp.Lb.Items.IndexOf($prev) }
    if ($idx -lt 0 -and $arr.Length -gt 0) { $idx = 0 }
    if ($idx -ge 0) { $sp.Lb.SelectedIndex = $idx }
    $script:SpBusy = $false
    Show-SetDetail $(if ($idx -ge 0) { $sp.Lb.Items[$idx] } else { $null })
}

# called after every change of the results: new results rebuild the list, other changes only refresh what is shown
function Update-SetsPanel {
    if (-not $script:SP -or $script:Scanning) { return }
    $f = $script:Results['Folder']
    $sig = "$(if ($f) { $f.GetHashCode() })|$(if ($f) { $f.Count })"
    if ($sig -ne $script:SpSig) { $script:SpSig = $sig; Rebuild-SetList; Start-AutoAssess }
    else { $script:SP.Lb.Invalidate(); Refresh-Cards }
}

# ---- middle pane: the copies
# a copy that is gone from the disk (removed outside the app, or by an earlier run) is dropped when its set is opened; copies on a disk that is not connected are never dropped
function Test-SetStale($set) {
    $keep = New-Object 'System.Collections.Generic.List[object]'; $dropped = 0
    foreach ($o in $set.Items) {
        $root = [IO.Path]::GetPathRoot($o.Path)
        if ([IO.Directory]::Exists($o.Path) -or -not [IO.Directory]::Exists($root)) { $keep.Add($o) } else { $dropped++ }
    }
    if ($dropped -eq 0) { return $false }
    $set.Items = $keep
    if ($keep.Count -lt 2) { [void]$script:Results['Folder'].Remove($set); return $true }
    $false
}
# ===================================================================================================
# Deletion-safety investigation and assessment (read-only, rule-based and deterministic: the same evidence
# and policy version always give the same result; nothing here deletes, renames, moves or changes anything)
# ===================================================================================================
$script:SafetyPolicy = '1.0'
$script:SafetyWeights = [ordered]@{ Runtime = 20; Ownership = 20; Config = 15; Data = 15; Duplicate = 15; Lifecycle = 10; Filesystem = 5 }
$script:SafetyDimNames = @{ Runtime = 'Running programs and services'; Ownership = 'Application ownership'; Config = 'Configuration and registry references'; Data = 'Data type and reconstructibility'; Duplicate = 'Duplicate equivalence'; Lifecycle = 'Version and lifecycle'; Filesystem = 'Filesystem links and integrity' }
$script:SafetyCache = @{}      # folder path (lower case) -> assessment
$script:SafetyCtx = $null      # system snapshot shared by all assessments (processes, services, tasks, registry paths, shortcuts)
$script:SafetyFilter = 0       # 0 all, 1..5 class, 6 not assessed
$script:SafetyClasses = @('Very likely safe', 'Likely safe', 'Uncertain', 'High risk', 'Unsafe')

function Get-SafetyClass([int]$s) { if ($s -ge 95) { 'Very likely safe' } elseif ($s -ge 85) { 'Likely safe' } elseif ($s -ge 65) { 'Uncertain' } elseif ($s -ge 35) { 'High risk' } else { 'Unsafe' } }
function Get-ConfClass([int]$c) { if ($c -ge 90) { 'Strong evidence' } elseif ($c -ge 75) { 'Good evidence' } elseif ($c -ge 50) { 'Limited evidence' } else { 'Insufficient evidence' } }

function Add-Ev($ev, [string]$cat, [string]$src, [string]$finding, [string]$result, [double]$rel, [string]$impact, [string]$expl) {
    [void]$ev.Add([pscustomobject]@{ Id = ('EV-{0:D3}' -f ($ev.Count + 1)); Category = $cat; Source = $src; Finding = $finding; Result = $result; Time = (Get-Date).ToString('s'); Reliability = $rel; Impact = $impact; Explanation = $expl })
}

# ---- path helpers
$script:NormMemo = @{}; $script:BadPathChars = [IO.Path]::GetInvalidPathChars()
function Get-NormPath([string]$p) {   # normalised, lower-case path; remembered, because the same install locations are looked up for every copy of every set
    if (-not $p) { return '' }
    $r = $script:NormMemo[$p]; if ($null -ne $r) { return $r }
    $q = $p
    if ($q.IndexOfAny($script:BadPathChars) -ge 0) { $q = $q.Trim('"', "'"); foreach ($c in $script:BadPathChars) { $q = $q.Replace([string]$c, '') } }   # e.g. a quoted registry value: clean it instead of letting GetFullPath throw
    try { $q = [IO.Path]::GetFullPath($q) } catch { Write-ErrLog $_ }
    $r = $q.TrimEnd('\').ToLowerInvariant()
    if ($script:NormMemo.Count -gt 40000) { $script:NormMemo.Clear() }
    $script:NormMemo[$p] = $r; $r
}
function Test-PathInside([string]$child, [string]$parent) {   # both normalised: child equals or is inside parent
    if (-not $child -or -not $parent) { return $false }
    $child -eq $parent -or $child.StartsWith($parent + '\', [StringComparison]::Ordinal)
}
function Find-PathRef([string]$text, [string]$folder) {   # 'direct' when the text names the folder or something inside it, 'parent' when it names a folder above it, else ''
    if (-not $text -or -not $folder) { return '' }
    $t = $text.ToLowerInvariant().Replace('"', ' ').Replace('/', '\')
    $i = $t.IndexOf($folder, [StringComparison]::Ordinal)
    while ($i -ge 0) {
        $end = $i + $folder.Length
        if ($end -ge $t.Length -or $t[$end] -eq '\' -or $t[$end] -eq ' ' -or $t[$end] -eq ';' -or $t[$end] -eq ',') { return 'direct' }
        $i = $t.IndexOf($folder, $i + 1, [StringComparison]::Ordinal)
    }
    ''
}
function Get-ExeDir([string]$text) {   # folder of the program named at the start of a path or command line (lower case), or ''
    if (-not $text) { return '' }
    $m = [regex]::Match($text, '^\s*"?([A-Za-z]:\\[^"]*?\.(exe|dll|sys|bat|cmd))', 'IgnoreCase'); if (-not $m.Success) { return '' }
    try { Get-NormPath ([IO.Path]::GetDirectoryName($m.Groups[1].Value)) } catch { '' }
}

# ---- one snapshot of the machine, reused by every assessment for a few minutes (read-only queries only)
function Read-RegPaths($hive, [string]$sub, [string]$kind, [int]$depth, $out) {
    try {
        $k = $hive.OpenSubKey($sub); if (-not $k) { return }
        try {
            foreach ($n in $k.GetValueNames()) { $v = $k.GetValue($n); if ($v -is [string] -and $v.Length -gt 3 -and $v -match '[A-Za-z]:\\') { [void]$out.Add([pscustomobject]@{ Kind = $kind; Key = ($hive.Name + '\' + $sub); Name = $n; Value = $v; App = '' }) } }
            if ($depth -gt 0) {
                foreach ($sk in $k.GetSubKeyNames()) {
                    $c = $null; try { $c = $k.OpenSubKey($sk) } catch { Write-ErrLog $_ }
                    if (-not $c) { continue }
                    try {
                        $app = [string]$c.GetValue('DisplayName')
                        foreach ($n in $c.GetValueNames()) { $v = $c.GetValue($n); if ($v -is [string] -and $v.Length -gt 3 -and $v -match '[A-Za-z]:\\') { [void]$out.Add([pscustomobject]@{ Kind = $kind; Key = ($hive.Name + '\' + $sub + '\' + $sk); Name = $(if ($n) { $n } else { '(Default)' }); Value = $v; App = $app }) } }
                    } finally { $c.Close() }
                }
            }
        } finally { $k.Close() }
    } catch { Write-ErrLog $_ }
}
function Get-SafetyContext([switch]$Force) {
    $ctx = $script:SafetyCtx
    if (-not $Force -and $ctx -and ((Get-Date) - $ctx.Time).TotalMinutes -lt 5) { return $ctx }
    $ctx = @{ Time = Get-Date; Proc = @(); Svc = @(); Tasks = @(); Reg = @(); Links = @(); Fail = @{}; Apps = @() }
    try { $ctx.Proc = @(Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Id = $_.ProcessId; Name = [string]$_.Name; Exe = [string]$_.ExecutablePath; Cmd = [string]$_.CommandLine } }) } catch { $ctx.Fail['Process'] = $_.Exception.Message }
    try { $ctx.Svc = @(Get-CimInstance Win32_Service -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; Path = [string]$_.PathName; State = [string]$_.State } }) } catch { $ctx.Fail['Service'] = $_.Exception.Message }
    try { $ctx.Tasks = @(Get-ScheduledTask -ErrorAction Stop | ForEach-Object { $tn = $_.TaskName; foreach ($a in $_.Actions) { [pscustomobject]@{ Name = $tn; Text = ([string]$a.Execute + ' ' + [string]$a.Arguments + ' ' + [string]$a.WorkingDirectory) } } }) } catch { $ctx.Fail['Tasks'] = $_.Exception.Message }
    $reg = New-Object System.Collections.ArrayList
    try {
        $lm = [Microsoft.Win32.Registry]::LocalMachine; $cu = [Microsoft.Win32.Registry]::CurrentUser
        foreach ($h in $lm, $cu) { Read-RegPaths $h 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' 'uninstall' 1 $reg }
        Read-RegPaths $lm 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' 'uninstall' 1 $reg
        foreach ($h in $lm, $cu) { foreach ($s in 'Run', 'RunOnce') { Read-RegPaths $h ('SOFTWARE\Microsoft\Windows\CurrentVersion\' + $s) 'startup' 0 $reg } }
        Read-RegPaths $lm 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths' 'apppath' 1 $reg
        Read-RegPaths $cu 'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' 'shell' 0 $reg
        Read-RegPaths $lm 'SYSTEM\CurrentControlSet\Services' 'service' 1 $reg
    } catch { $ctx.Fail['Registry'] = $_.Exception.Message }
    $ctx.Reg = @($reg)
    $apps = @{}; foreach ($r in $ctx.Reg) { if ($r.Kind -eq 'uninstall' -and $r.App -and $r.Name -eq 'InstallLocation') { $apps[$r.Value] = $r.App } }; $ctx.Apps = $apps
    $lnk = New-Object System.Collections.ArrayList
    try {
        $ws = New-Object -ComObject WScript.Shell; $n = 0
        $dirs = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('StartMenu'), [Environment]::GetFolderPath('CommonStartMenu'), [Environment]::GetFolderPath('Startup'))
        foreach ($dd in $dirs) {
            if (-not $dd -or -not [IO.Directory]::Exists($dd)) { continue }
            foreach ($f in [IO.Directory]::EnumerateFiles($dd, '*.lnk', [IO.SearchOption]::AllDirectories)) {
                if (++$n -gt 3000) { break }
                try { $s = $ws.CreateShortcut($f); [void]$lnk.Add([pscustomobject]@{ File = $f; Target = [string]$s.TargetPath; Dir = [string]$s.WorkingDirectory }) } catch { Write-ErrLog $_ }
            }
        }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ws)
    } catch { $ctx.Fail['Shortcuts'] = $_.Exception.Message }
    $ctx.Links = @($lnk)
    # search index: every text a folder path could be named in, normalised once; an assessment only runs the exact matching when its path occurs in the index
    try {
        $bb = New-Object Text.StringBuilder
        foreach ($p in $ctx.Proc) { [void]$bb.Append($p.Exe).Append(' ').Append($p.Cmd).Append("`n") }
        foreach ($s in $ctx.Svc) { [void]$bb.Append($s.Path).Append("`n") }
        foreach ($tk in $ctx.Tasks) { [void]$bb.Append($tk.Text).Append("`n") }
        foreach ($r in $ctx.Reg) { [void]$bb.Append($r.Value).Append("`n") }
        foreach ($l in $ctx.Links) { [void]$bb.Append($l.Target).Append(' ').Append($l.Dir).Append("`n") }
        $ctx.Blob = $bb.ToString().ToLowerInvariant().Replace('"', ' ').Replace('/', '\')
        $ed = @{}
        foreach ($p in $ctx.Proc) { $d = Get-ExeDir $p.Exe; if ($d.Length -gt 8 -and ($d.Split('\').Count -ge 3)) { if (-not $ed.ContainsKey($d)) { $ed[$d] = New-Object System.Collections.ArrayList }; [void]$ed[$d].Add("process $($p.Name)") } }
        foreach ($s in $ctx.Svc) { $d = Get-ExeDir $s.Path; if ($d.Length -gt 8 -and ($d.Split('\').Count -ge 3)) { if (-not $ed.ContainsKey($d)) { $ed[$d] = New-Object System.Collections.ArrayList }; [void]$ed[$d].Add("service $($s.Name)") } }
        $ctx.ExeDirs = $ed
    } catch { Write-ErrLog $_; $ctx.Blob = $null; $ctx.ExeDirs = $null }
    $script:SafetyCtx = $ctx
    $ctx
}

# ---- facts about one folder (bounded walk, never follows links, never writes)
$script:FactsMemo = @{}; $script:CfgMemo = @{}
function Get-FolderFacts([string]$path, [int]$cap = 3000) {   # remembered for two minutes: one set is assessed several times (every keeper choice) and the folder does not change meanwhile
    $m = $script:FactsMemo[$path]; if ($m -and ((Get-Date) - $m.T).TotalSeconds -lt 120) { return $m.F }
    $f = Get-FolderFactsRaw $path $cap; $script:FactsMemo[$path] = [pscustomobject]@{ T = (Get-Date); F = $f }; $f
}
function Get-FolderFactsRaw([string]$path, [int]$cap = 3000) {
    $f = @{ Files = 0; Dirs = 0; Bytes = 0L; Reparse = 0; Hard = 0; HardBytes = 0L; Hidden = 0; Exts = @{}; Root = (New-Object System.Collections.ArrayList); Sample = (New-Object System.Collections.ArrayList); Newest = [datetime]::MinValue; Capped = $false; RootReparse = $false; Error = '' }
    try {
        $di = New-Object IO.DirectoryInfo($path)
        if (-not $di.Exists) { $f.Error = 'folder not found'; return $f }
        if ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) { $f.RootReparse = $true; return $f }
        $stack = New-Object 'System.Collections.Generic.Stack[IO.DirectoryInfo]'; $stack.Push($di); $seen = 0; $hc = 0
        while ($stack.Count -gt 0 -and -not $f.Capped) {
            $d = $stack.Pop(); $atRoot = ($d.FullName.TrimEnd('\') -eq $di.FullName.TrimEnd('\'))
            $entries = $null; try { $entries = $d.GetFileSystemInfos() } catch { $f.Error = 'some folders could not be read'; continue }
            foreach ($x in $entries) {
                if (++$seen -gt $cap) { $f.Capped = $true; break }
                if ($x.Attributes -band [IO.FileAttributes]::ReparsePoint) { $f.Reparse++; continue }
                if ($x -is [IO.DirectoryInfo]) { $f.Dirs++; if ($atRoot) { [void]$f.Root.Add($x.Name) }; $stack.Push($x); continue }
                $f.Files++; $f.Bytes += $x.Length; if ($x.LastWriteTime -gt $f.Newest) { $f.Newest = $x.LastWriteTime }
                if ($atRoot) { [void]$f.Root.Add($x.Name) }
                if ($x.Attributes -band [IO.FileAttributes]::Hidden) { $f.Hidden++ }
                $e = $x.Extension.ToLowerInvariant(); if ($f.Exts.ContainsKey($e)) { $f.Exts[$e]++ } else { $f.Exts[$e] = 1 }
                if ($f.Sample.Count -lt 40) { [void]$f.Sample.Add($x.FullName) }
                if ($hc -lt 200) { $hc++; try { $l = [FileId]::Links($x.FullName); if ($l -gt 1) { $f.Hard++; $f.HardBytes += $x.Length } } catch { Write-ErrLog $_ } }
            }
        }
    } catch { $f.Error = $_.Exception.Message }
    $f
}

function Get-KnownRoots {
    $r = @{}
    $r.Win = Get-NormPath $env:windir
    $r.Prog = @(@($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) | Where-Object { $_ } | ForEach-Object { Get-NormPath $_ } | Select-Object -Unique)
    $r.Store = Get-NormPath (Join-Path $env:ProgramFiles 'WindowsApps')
    $r.AppData = @(@($env:LOCALAPPDATA, $env:APPDATA, $env:ProgramData, (Join-Path $env:USERPROFILE 'AppData\LocalLow')) | Where-Object { $_ } | ForEach-Object { Get-NormPath $_ })
    $prof = Get-NormPath $env:USERPROFILE
    $r.User = @('Documents', 'Desktop', 'Pictures', 'Videos', 'Music', 'Downloads') | ForEach-Object { $prof + '\' + $_.ToLowerInvariant() }
    $r.Cloud = @(@($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial, (Join-Path $env:USERPROFILE 'Dropbox'), (Join-Path $env:USERPROFILE 'Google Drive'), (Join-Path $env:USERPROFILE 'iCloudDrive'), (Join-Path $env:USERPROFILE 'MEGAsync'), (Join-Path $env:USERPROFILE 'Documents\MEGAsync'), (Join-Path $env:USERPROFILE 'MEGA'), (Join-Path $env:USERPROFILE 'Documents\Dropbox'), (Join-Path $env:USERPROFILE 'Documents\Google Drive')) | Where-Object { $_ } | ForEach-Object { Get-NormPath $_ })
    $r
}

# ---- the assessment of ONE candidate folder inside its duplicate set
function Get-SetSig($set) { (($set.Items | ForEach-Object { if ($_.Remove) { '1' } else { '0' } }) -join '') }   # which copies are marked: an assessment is only valid for the marks it was made with
function Get-CachedSafety($it, $set) { $a = $script:SafetyCache[(Get-NormPath $it.Path)]; if ($a -and $a.Sig -eq (Get-SetSig $set)) { $a } else { $null } }
function Get-SafetyAssessment($it, $set, [switch]$Force) {
    $key = Get-NormPath $it.Path; $sig = Get-SetSig $set
    if (-not $Force -and $script:SafetyCache.ContainsKey($key) -and $script:SafetyCache[$key].Sig -eq $sig) { return $script:SafetyCache[$key] }
    $ctx = Get-SafetyContext; $roots = Get-KnownRoots; $ev = New-Object System.Collections.ArrayList
    $path = $it.Path; $np = $key; $facts = Get-FolderFacts $path
    $dim = [ordered]@{}; $caps = New-Object System.Collections.ArrayList; $risks = New-Object System.Collections.ArrayList
    $relp = $np; $unknown = 0; $owner = ''; $ownerClass = 'Unknown'; $isApp = $false; $activeDep = $false
    $cap = { param($v, $why) [void]$caps.Add([pscustomobject]@{ Max = $v; Rule = $why }) }

    # ---------- 1 running programs and services
    $hits = New-Object System.Collections.ArrayList; $par = New-Object System.Collections.ArrayList
    $refPossible = ($null -eq $ctx.Blob) -or ($ctx.Blob.IndexOf($np, [StringComparison]::Ordinal) -ge 0)   # fast path: nothing anywhere names this folder
    if ($refPossible) {
        foreach ($p in $ctx.Proc) { $r = Find-PathRef ($p.Exe + ' ' + $p.Cmd) $np; if ($r -eq 'direct') { [void]$hits.Add("process $($p.Name) (PID $($p.Id))") } else { $ed = Get-ExeDir $p.Exe; if ($ed.Length -gt 8 -and ($ed.Split('\').Count -ge 3) -and (Test-PathInside $np $ed)) { [void]$par.Add("process $($p.Name)") } } }
        foreach ($s in $ctx.Svc) { $r = Find-PathRef $s.Path $np; if ($r -eq 'direct') { [void]$hits.Add("service $($s.Name)") } else { $ed = Get-ExeDir $s.Path; if ($ed.Length -gt 8 -and ($ed.Split('\').Count -ge 3) -and (Test-PathInside $np $ed)) { [void]$par.Add("service $($s.Name)") } } }
        foreach ($t in $ctx.Tasks) { $r = Find-PathRef $t.Text $np; if ($r -eq 'direct') { [void]$hits.Add("scheduled task $($t.Name)") } }
    }
    else {
        $anc = $np; while ($anc.Length -gt 8) { $lst = $ctx.ExeDirs[$anc]; if ($lst) { foreach ($nm in $lst) { [void]$par.Add($nm) } }; $ix = $anc.LastIndexOf('\'); if ($ix -lt 1) { break }; $anc = $anc.Substring(0, $ix) }
    }
    $locked = New-Object System.Collections.ArrayList
    foreach ($sf in $facts.Sample) {
        try { $fs = [IO.File]::Open($sf, 'Open', 'Read', 'None'); $fs.Dispose() } catch [System.IO.IOException] { if (($_.Exception.HResult -band 0xFFFF) -in @(32, 33)) { [void]$locked.Add($sf) } } catch { Write-ErrLog $_ }
        if ($locked.Count -ge 3) { break }
    }
    $rt = 95
    if ($ctx.Fail.ContainsKey('Process')) { Add-Ev $ev 'Runtime' 'Win32_Process' 'Process list could not be read' 'Unknown' 0 'lowers confidence' "The list of running programs was not available ($($ctx.Fail['Process'])), so a running program using this folder cannot be ruled out."; $rt = [math]::Min($rt, 50); $unknown++ }
    elseif ($hits.Count -eq 0 -and $par.Count -eq 0) { Add-Ev $ev 'Runtime' 'Running processes, services, scheduled tasks' 'No program, service or task refers to this folder' 'Negative' 0.85 'raises safety' 'None of the running programs, Windows services or scheduled tasks names this folder in its path or command line. This does not prove it is unused: a program may use it without naming it, or need it when it starts again.' }
    if ($hits.Count -gt 0) { Add-Ev $ev 'Runtime' 'Running processes, services, scheduled tasks' ('Referenced by ' + (($hits | Select-Object -First 4) -join ', ')) 'Positive' 0.95 'blocks deletion' ('Active dependency: ' + (($hits | Select-Object -First 4) -join ', ') + ' uses this folder.'); $rt = 0; $activeDep = $true }
    elseif ($par.Count -gt 0) { Add-Ev $ev 'Runtime' 'Running processes, services' ('A program in a parent folder is running: ' + (($par | Select-Object -First 3) -join ', ')) 'Positive' 0.6 'lowers safety' 'A running program or service is installed in a folder above this one, so this folder may belong to it (indirect association).'; $rt = [math]::Min($rt, 40) }
    if ($locked.Count -gt 0) { Add-Ev $ev 'Runtime' 'Exclusive-open test on sample files' ("$($locked.Count) file(s) are open in another program, e.g. " + [IO.Path]::GetFileName($locked[0])) 'Positive' 0.95 'blocks deletion' 'Files in this folder are open in another program right now.'; $rt = 0; $activeDep = $true }
    else { Add-Ev $ev 'Runtime' 'Exclusive-open test on sample files' "Up to $($facts.Sample.Count) sample files could be opened exclusively (none is locked)" 'Negative' 0.7 'raises safety' 'No sampled file is held open by another program.' }
    Add-Ev $ev 'Runtime' 'Open file handles' 'Open file handles of other programs cannot be listed without extra tools' 'Unknown' 0 'lowers confidence' 'Windows does not let this app list every open handle, so only the sample test above shows whether files are in use.'; $unknown++
    $dim.Runtime = $rt
    if ($activeDep) { & $cap 10 'Confirmed active dependency (program, service, task or open file)' }

    # ---------- 2 application ownership
    $own = 85; $ownDetail = ''
    if (Test-PathInside $np $roots.Win) { $isApp = $true; $own = 0; $owner = 'Windows'; $ownerClass = 'Confirmed'; $ownDetail = 'Inside the Windows folder'; & $cap 2 'Protected Windows directory' }
    elseif (Test-PathInside $np $roots.Store) { $isApp = $true; $own = 3; $owner = 'Microsoft Store app'; $ownerClass = 'Confirmed'; $ownDetail = 'Inside the WindowsApps package directory'; & $cap 5 'Application package or installation folder' }
    else {
        foreach ($pr in $roots.Prog) { if (Test-PathInside $np $pr) { $isApp = $true; $own = 5; $owner = 'Installed program'; $ownerClass = 'Confirmed'; $ownDetail = 'Inside a Program Files folder'; & $cap 5 'Application package or installation folder' } }
    }
    if (-not $isApp) {
        foreach ($loc in $ctx.Apps.Keys) {
            $nl = Get-NormPath $loc; if (-not $nl -or $nl.Length -lt 6) { continue }
            if ((Test-PathInside $np $nl) -or (Test-PathInside $nl $np)) { $isApp = $true; $own = 5; $owner = [string]$ctx.Apps[$loc]; $ownerClass = 'Confirmed'; $ownDetail = "Registered install location of $owner"; & $cap 5 'Application package or installation folder'; break }
        }
    }
    if (-not $isApp) {
        $ad = $null; foreach ($r2 in $roots.AppData) { if (Test-PathInside $np $r2) { $ad = $r2 } }; if ($ad) { $relp = $np.Substring($ad.Length) }
        if ($ad) {
            $rest = $np.Substring($ad.Length).TrimStart('\').Split('\'); $owner = (($rest | Select-Object -First 2) -join '\'); $ownerClass = 'Probable'; $own = 20
            $ownDetail = "Inside the application data folder, under '$owner'"
            if ($np -match '\\(extensions?|profiles?|user data)\\') { $own = 10; $ownDetail += ' (browser or application profile / extension storage)' }
        }
    }
    if (-not $isApp -and $ownerClass -eq 'Unknown') {
        $marker = $null
        foreach ($n in $facts.Root) { if ($n -in @('manifest.json', 'AppxManifest.xml', 'package.json', '.git', 'pom.xml', 'Cargo.toml', '.csproj') -or $n -match '\.(exe|dll|sln|csproj)$') { $marker = $n; break } }
        if ($marker) { $ownerClass = 'Probable'; $owner = 'application or project'; $own = 25; $ownDetail = "Contains '$marker', which marks an application or project" }
    }
    if ($ownerClass -eq 'Unknown') {
        $inUser = $false; foreach ($u in $roots.User) { if (Test-PathInside $np $u) { $inUser = $true } }
        if ($inUser) { $ownerClass = 'Personal'; $owner = 'you (personal files)'; $own = 100; $ownDetail = "In your own documents/media folders, with no program, project or install record attached - personal files, not a program or system folder" } else { $own = 70; $ownDetail = 'No application owner could be identified for this location' }
    }
    $ownRes = $(if ($ownerClass -eq 'Unknown') { 'Unknown' } else { 'Positive' })
    Add-Ev $ev 'Ownership' 'Location, install records, folder markers' ("$ownDetail. Ownership: $ownerClass" + $(if ($owner) { " ($owner)" } else { '' })) $ownRes $(if ($ownerClass -eq 'Confirmed') { 0.9 } elseif ($ownerClass -eq 'Probable') { 0.6 } elseif ($ownerClass -eq 'Personal') { 0.8 } else { 0.35 }) $(if ($own -le 25) { 'lowers safety' } else { 'raises safety' }) $(if ($ownerClass -eq 'Unknown') { 'The owner of this folder could not be established from its location, the install records or its contents.' } else { "$ownDetail." })
    if ($ownerClass -eq 'Unknown') { $unknown++ }
    $dim.Ownership = $own

    # ---------- 3 configuration, registry and shortcut references
    $cfg = 95; $active = New-Object System.Collections.ArrayList; $hist = New-Object System.Collections.ArrayList
    if ($refPossible) { foreach ($r in $ctx.Reg) {
        $m = Find-PathRef $r.Value $np
        if ($m -eq 'direct') { $d = "$($r.Key)\$($r.Name)"; if ($r.Name -eq 'InstallSource') { [void]$hist.Add($d) } else { [void]$active.Add($d) } }
    }
    foreach ($l in $ctx.Links) {
        $m = Find-PathRef ($l.Target + ' ' + $l.Dir) $np
        if ($m -eq 'direct') { [void]$active.Add('shortcut ' + [IO.Path]::GetFileName($l.File)) }
    } }
    $cf = New-Object System.Collections.ArrayList
    $parent = [IO.Path]::GetDirectoryName($path.TrimEnd('\'))
    if ($parent -and $parent.Length -gt 3 -and [IO.Directory]::Exists($parent)) {
        $pk = Get-NormPath $parent; $ce = $script:CfgMemo[$pk]
        if (-not $ce -or ((Get-Date) - $ce.T).TotalSeconds -gt 120) {   # the config files of a parent folder are read once and kept for two minutes
            $lst = New-Object System.Collections.ArrayList; $n = 0
            try {
                foreach ($f in [IO.Directory]::EnumerateFiles($parent)) {
                    if ($f -notmatch '\.(json|xml|ini|ya?ml|config|cfg|cmd|bat|ps1|toml|conf)$') { continue }
                    if (++$n -gt 150) { break }
                    $fi = New-Object IO.FileInfo($f); if ($fi.Length -gt 262144) { continue }
                    $txt = [IO.File]::ReadAllText($f); [void]$lst.Add([pscustomobject]@{ F = $f; T = $txt.ToLowerInvariant().Replace('"', ' ').Replace('/', '\') })
                }
            } catch { Write-ErrLog $_ }
            if ($script:CfgMemo.Count -gt 60) { $script:CfgMemo = @{} }
            $ce = [pscustomobject]@{ T = (Get-Date); L = $lst }; $script:CfgMemo[$pk] = $ce
        }
        foreach ($e5 in $ce.L) { if ($e5.T.IndexOf($np, [StringComparison]::Ordinal) -ge 0 -and (Find-PathRef $e5.T $np) -eq 'direct') { [void]$cf.Add($e5.F) } }
    }
    if ($ctx.Fail.ContainsKey('Registry')) { Add-Ev $ev 'Registry' 'Registry' 'The registry could not be read' 'Unknown' 0 'lowers confidence' "Registry access failed ($($ctx.Fail['Registry']))."; $cfg = [math]::Min($cfg, 50); $unknown++ }
    if ($active.Count -gt 0) { Add-Ev $ev 'Registry' 'Registry and shortcuts (read-only)' ('Active reference: ' + (($active | Select-Object -First 3) -join '; ')) 'Positive' 0.9 'blocks deletion' 'Windows registers or launches something from this folder (install record, startup entry, App Paths, shell folder, service or shortcut).'; $cfg = 10; $activeDep = $true; & $cap 10 'Confirmed active dependency (registry, startup entry or shortcut)' }
    if ($hist.Count -gt 0) { Add-Ev $ev 'Registry' 'Registry (read-only)' ('Historical reference: ' + (($hist | Select-Object -First 2) -join '; ')) 'Positive' 0.6 'lowers safety' 'An installer cache path points here. Such references are usually historical but are kept as a warning.'; $cfg = [math]::Min($cfg, 55) }
    if ($cf.Count -gt 0) { Add-Ev $ev 'Configuration' 'Config files next to the folder' ('Named in ' + (($cf | Select-Object -First 2 | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ', ')) 'Positive' 0.6 'lowers safety' 'A configuration file in the parent folder contains this folder path. It cannot be told whether the reference is still used.'; $cfg = [math]::Min($cfg, 30) }
    if ($active.Count -eq 0 -and $hist.Count -eq 0 -and $cf.Count -eq 0 -and -not $ctx.Fail.ContainsKey('Registry')) { Add-Ev $ev 'Registry' 'Install records, Run keys, App Paths, shell folders, service images, Start Menu, Desktop and Startup shortcuts, nearby config files' 'No reference found to this folder' 'Negative' 0.85 'raises safety' 'None of the investigated registry locations, shortcuts or nearby configuration files point to this folder.' }
    Add-Ev $ev 'Registry' 'Not inspected in this version' 'App package registrations, file associations and application databases are not searched' 'Unknown' 0 'lowers confidence' 'These sources are not covered, so a reference there would not be seen.'; $unknown++
    $dim.Config = $cfg

    # ---------- 4 data type and reconstructibility
    $total = [math]::Max(1, $facts.Files); $docExt = @('.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.pdf', '.txt', '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.heic', '.raw', '.cr2', '.nef', '.mp3', '.mp4', '.mov', '.avi', '.mkv', '.zip', '.7z', '.rar', '.odt', '.psd', '.csv', '.md')
    $dbExt = @('.db', '.sqlite', '.sqlite3', '.mdb', '.accdb', '.ldb', '.mdf', '.ndf', '.ibd', '.kdbx'); $docN = 0; $dbN = 0
    foreach ($k2 in $facts.Exts.Keys) { if ($docExt -contains $k2) { $docN += $facts.Exts[$k2] }; if ($dbExt -contains $k2) { $dbN += $facts.Exts[$k2] } }
    $stateNames = @('Local State', 'Preferences', 'Cookies', 'Login Data', 'ntuser.dat', 'Web Data', 'History'); $hasState = $false; foreach ($n in $facts.Root) { if ($stateNames -contains $n) { $hasState = $true } }
    $cacheSeg = ($relp -match '\\(cache|code cache|gpucache|shadercache|inetcache|temp|tmp|crashpad|crash reports)(\\|$)')
    $verified = $false; $keptOthers = @($set.Items | Where-Object { $_ -ne $it -and -not $_.Remove -and [IO.Directory]::Exists($_.Path) })
    if ($keptOthers.Count -gt 0) { $verified = $true }
    $cls = ''; $dat = 55
    if ($dbN -gt 0 -or $hasState) { $cls = 'application state or database'; $dat = 5; & $cap 10 'Required database or application state' }
    elseif ($cacheSeg -and ($ownerClass -in @('Confirmed', 'Probable'))) { $cls = "rebuildable cache of $owner"; $dat = 88 }
    elseif ($cacheSeg) { $cls = 'named like a cache/temp folder but no owning application was found'; $dat = 50 }
    elseif ($facts.Files -gt 0 -and ($docN / $total) -ge 0.6) {
        $cls = 'user-generated documents or media'
        if ($verified) { $dat = $(if ($ownerClass -eq 'Personal') { 100 } else { 65 }) } else { $dat = 25; & $cap 20 'Unique user data without a verified backup' }
        $codeExt = @('.ps1', '.psm1', '.py', '.js', '.ts', '.cs', '.java', '.cpp', '.c', '.h', '.json', '.xml', '.ini', '.cfg', '.conf', '.yml', '.yaml', '.bat', '.cmd', '.sh', '.sql', '.html', '.css', '.exe', '.dll', '.reg', '.lnk'); $codeN = 0
        foreach ($k5 in $facts.Exts.Keys) { if ($codeExt -contains $k5) { $codeN += $facts.Exts[$k5] } }
        if ($codeN -gt 0 -and ($codeN / $total) -ge 0.1) { $dat = [math]::Min($dat, 70); $cls += ' (with scripts, settings or program files)' }
    }
    elseif ($relp -match '\\(backup|backups|old|archive)(\\|$)') { $cls = 'backup or archive data'; $dat = 50 }
    elseif ($relp -match '\\(installer|installers|update|updates|setup|downloads)(\\|$)' -or ($facts.Exts.ContainsKey('.msi') -or $facts.Exts.ContainsKey('.cab'))) { $cls = 'installer or update package'; $dat = 60 }
    else { $cls = 'unclassified data'; $dat = 55 }
    $datRes = $(if ($cls -like 'unclassified*' -or $cls -like 'named like*') { 'Unknown' } else { 'Positive' })
    if ($datRes -eq 'Unknown') { $unknown++ }
    Add-Ev $ev 'Data' 'Folder contents and location' ("Looks like: $cls ($($facts.Files) files, $($facts.Dirs) folders)") $datRes $(if ($datRes -eq 'Unknown') { 0.3 } else { 0.7 }) $(if ($dat -ge 80) { 'raises safety' } else { 'lowers safety' }) $(if ($cls -like 'user-generated*') { "Most files are documents or media, which cannot be rebuilt$(if ($verified) { '; an identical kept copy exists, so the content itself is not unique' } else { ' and no other kept copy exists' })." } elseif ($cls -like 'application state*') { 'It holds databases or application settings, which an application needs and cannot recreate.' } elseif ($cls -like 'rebuildable*') { "It is a cache of $owner, which the application normally rebuilds. Confirm that application does so before cleaning." } elseif ($datRes -eq 'Unknown') { 'The kind of data could not be established; the folder name alone is not enough to call it safe.' } else { "Classified as $cls." })
    if ($facts.Capped) { Add-Ev $ev 'Data' 'Folder walk' 'Folder is large: only the first 3000 entries were examined' 'Unknown' 0 'lowers confidence' 'The classification is based on a sample of the folder.'; $unknown++ }
    if ($cls -like 'rebuildable*') { $own = [math]::Max($own, 60); $dim.Ownership = $own }
    $dim.Data = $dat

    # ---------- 5 duplicate equivalence and replacement
    $dup = 95
    $ownersDiffer = ''
    foreach ($o2 in $set.Items) {
        if ($o2 -eq $it) { continue }
        $n2 = Get-NormPath $o2.Path; $ow2 = ''
        foreach ($r2 in $roots.AppData) { if (Test-PathInside $n2 $r2) { $ow2 = (($n2.Substring($r2.Length).TrimStart('\').Split('\') | Select-Object -First 2) -join '\') } }
        if ($ow2 -and $owner -and $ownerClass -ne 'Unknown' -and $ow2 -ne $owner) { $ownersDiffer = $ow2 }
    }
    if ($keptOthers.Count -eq 0) { $dup = 10; Add-Ev $ev 'Duplicate' 'Duplicate set' 'No other copy would remain' 'Positive' 0.95 'blocks deletion' 'Every other copy is also marked for removal or missing, so deleting this one could leave no copy at all.'; & $cap 10 'Would remove the last remaining copy' }
    else {
        $k0 = $keptOthers[0]; $kn = Get-NormPath $k0.Path
        if ((Test-PathInside $kn $np) -or (Test-PathInside $np $kn)) { $dup = 30; Add-Ev $ev 'Duplicate' 'Folder layout' 'The kept copy and this folder are nested inside each other' 'Positive' 0.9 'lowers safety' 'One folder contains the other, so removing one removes part of the other.' }
        else {
            $kf = Get-FolderFacts $k0.Path
            if ($kf.RootReparse) { $dup = 20; Add-Ev $ev 'Duplicate' 'Kept copy' 'The kept copy is a link to another place' 'Positive' 0.9 'lowers safety' 'The copy that would remain is a junction or symbolic link, not an independent copy.' }
            elseif (-not $facts.Capped -and -not $kf.Capped -and ($kf.Files -ne $facts.Files -or $kf.Dirs -ne $facts.Dirs)) { $dup = 20; Add-Ev $ev 'Duplicate' 'Structural re-check' "Kept copy has $($kf.Files) files / $($kf.Dirs) folders, this folder $($facts.Files) / $($facts.Dirs)" 'Positive' 0.9 'lowers safety' 'The two folders no longer match the scan result (contents changed after the scan). Scan again before deleting.' }
            else {
                $sameDrive = ([IO.Path]::GetPathRoot($k0.Path) -eq [IO.Path]::GetPathRoot($path)); $dup = $(if ($sameDrive) { 72 } else { 95 })   # a copy on another drive survives a disk failure; one on the same drive does not
                $kCloud = $false; foreach ($c4 in $roots.Cloud) { if (Test-PathInside $kn $c4) { $kCloud = $true } }
                if ($kCloud -and $dup -gt 85) { $dup = 85 }   # the kept copy is a cloud-sync folder: a delete elsewhere can be mirrored onto it
                Add-Ev $ev 'Duplicate' 'Where the kept copy lives' $(if ($sameDrive) { 'Kept copy is on the same drive, so one disk failure would lose both' } elseif ($kCloud) { 'Kept copy is on another drive but inside a cloud-sync folder' } else { 'Kept copy is on a different drive, so it survives a failure of this one' }) $(if ($sameDrive -or $kCloud) { 'Positive' } else { 'Negative' }) 0.85 $(if ($sameDrive -or $kCloud) { 'lowers safety' } else { 'raises safety' }) $(if ($sameDrive) { 'Both copies share one physical drive; a failed drive, a mistake in a sync tool or ransomware can hit both at once.' } else { 'The remaining copy is stored apart from this one.' })
                Add-Ev $ev 'Duplicate' 'Scan result (SHA-256) and structure re-check' ("Identical to $($keptOthers.Count) kept cop$(if ($keptOthers.Count -eq 1) { 'y' } else { 'ies' }), e.g. $($k0.Path)") 'Negative' 0.9 'raises safety' 'The scanner found identical contents by SHA-256 and the file and folder counts still match, so no unique files were found here. Identical content does not mean the copies serve the same purpose.'
            }
        }
    }
    if ($ownersDiffer) { $dup = [math]::Min($dup, 10); Add-Ev $ev 'Duplicate' 'Ownership of the other copies' "Another copy belongs to a different application ($ownersDiffer)" 'Positive' 0.7 'blocks deletion' "Another copy sits in the data of '$ownersDiffer', not of '$owner'. Identical contents do not make them interchangeable: each application may need its own copy."; & $cap 25 'Independently owned copy (another application keeps its own)' }
    $dim.Duplicate = $dup

    # ---------- 6 version and lifecycle
    $leaf = [IO.Path]::GetFileName($path.TrimEnd('\')); $life = 95
    $ver = [regex]::Match($leaf, '(?<![\d.])v?(\d+(?:\.\d+){1,3})(?![\d.])')
    if ($ver.Success) {
        $mine = $null; try { $mine = [version]$ver.Groups[1].Value } catch { Write-ErrLog $_ }
        $newer = $false; $siblings = 0
        if ($parent -and [IO.Directory]::Exists($parent) -and $mine) {
            try { foreach ($sd in [IO.Directory]::EnumerateDirectories($parent)) { $sv = [regex]::Match([IO.Path]::GetFileName($sd), '(?<![\d.])v?(\d+(?:\.\d+){1,3})(?![\d.])'); if ($sv.Success -and $sd -ne $path) { $siblings++; try { if ([version]$sv.Groups[1].Value -gt $mine) { $newer = $true } } catch { Write-ErrLog $_ } } } } catch { Write-ErrLog $_ }
        }
        if ($newer) { $life = 50; Add-Ev $ev 'Lifecycle' 'Folder name and sibling versions' "Version $($ver.Groups[1].Value); a newer version exists next to it" 'Positive' 0.7 'lowers safety' 'This looks like an older version. Older versions can be kept for rollback or recovery, so being old does not make it unnecessary.' }
        else { $life = 30; Add-Ev $ev 'Lifecycle' 'Folder name and sibling versions' "Version $($ver.Groups[1].Value); no newer version found next to it" 'Positive' 0.7 'lowers safety' 'This looks like the newest or only version, which an application may be using.' }
    }
    elseif ($relp -match '\\(update|updates|rollback|previous|\.old|old versions?)(\\|$)') { $life = 55; Add-Ev $ev 'Lifecycle' 'Folder name' 'Name suggests update or rollback data' 'Positive' 0.5 'lowers safety' 'Update and rollback folders can be needed to recover an application.' }
    else {
        $ageDays = $(if ($facts.Newest -gt [datetime]::MinValue) { ((Get-Date) - $facts.Newest).TotalDays } else { 9999 })
        if ($ageDays -lt 30) { $life = 70; Add-Ev $ev 'Lifecycle' 'Last change' ("A file here changed $([int]$ageDays) day(s) ago") 'Positive' 0.7 'lowers safety' 'Recently changed content is more likely to be in use or still being edited, and the copies may not have been synchronised for long.' }
        elseif ($ageDays -lt 180) { $life = 85; Add-Ev $ev 'Lifecycle' 'Last change' ("Newest file changed about $([int]($ageDays / 30)) month(s) ago") 'Positive' 0.6 'lowers safety' 'The content changed within the last half year.' }
        else { Add-Ev $ev 'Lifecycle' 'Folder name and last change' 'No version number or update pattern, and nothing changed for over 6 months' 'Negative' 0.6 'raises safety' 'Nothing suggests this is a versioned, update-related or recently used folder.' }
    }
    $dim.Lifecycle = $life

    # ---------- 7 filesystem relationships and protected places
    $fsd = 95; $hardBytes = [int64]$facts.HardBytes
    if ($facts.RootReparse) { $fsd = 0; Add-Ev $ev 'Filesystem' 'Reparse point check' 'This folder is a junction or symbolic link' 'Positive' 0.95 'blocks deletion' 'It points to another place; what deleting it would affect cannot be safely resolved here.'; & $cap 30 'Filesystem relationship cannot be safely resolved (link)' }
    elseif ($facts.Reparse -gt 0) { $fsd = 45; Add-Ev $ev 'Filesystem' 'Reparse point check' "$($facts.Reparse) link(s) inside the folder (not followed)" 'Positive' 0.9 'lowers safety' 'Links inside the folder point elsewhere. They are not followed, but deleting may remove links others use.'; & $cap 30 'Filesystem relationship cannot be safely resolved (links inside)' }
    if ($facts.Hard -gt 0) { $fsd = [math]::Min($fsd, 60); Add-Ev $ev 'Filesystem' 'Hard link check' "$($facts.Hard) hard-linked file(s) found in the sample" 'Positive' 0.8 'lowers recoverable space' 'Hard-linked files share their storage with another path, so deleting them frees less space than the folder size.' }
    $cloud = $false; foreach ($c2 in $roots.Cloud) { if (Test-PathInside $np $c2) { $cloud = $true } }
    if ($cloud) { $fsd = [math]::Min($fsd, 55); Add-Ev $ev 'Filesystem' 'Cloud sync folder check' 'Inside a cloud-synchronised folder' 'Positive' 0.8 'lowers safety' 'Deleting here is usually mirrored to the cloud and other devices.'; & $cap 60 'Cloud synchronisation folder' }
    if ($facts.Error) { Add-Ev $ev 'Filesystem' 'Folder walk' $facts.Error 'Unknown' 0 'lowers confidence' 'Part of the folder could not be examined.'; $unknown++ }
    if ($fsd -eq 95 -and -not $facts.Error) { Add-Ev $ev 'Filesystem' 'Link and hard-link check' 'No junctions, symbolic links or hard links detected' 'Negative' 0.85 'raises safety' 'The folder is a plain folder with plain files.' }
    $dim.Filesystem = $fsd

    # ---------- critical sources
    $crit = @(); foreach ($k3 in 'Process', 'Registry') { if ($ctx.Fail.ContainsKey($k3)) { $crit += $k3 } }
    if ($crit.Count) { & $cap 60 ('Critical investigation source inaccessible: ' + ($crit -join ', ')) }

    # ---------- score, overrides, penalty
    $w = 0.0; foreach ($k4 in $script:SafetyWeights.Keys) { $w += $dim[$k4] * $script:SafetyWeights[$k4] / 100.0 }
    $pen = [math]::Min(10, 2 * [math]::Max(0, $unknown - 2))   # two standing gaps (open handles, uninspected sources) only lower confidence
    $raw = [math]::Round($w - $pen, 2); if ($raw -lt 0) { $raw = 0 }
    $final = $raw; $applied = $null
    foreach ($c3 in $caps) { if ($c3.Max -lt $final) { $final = $c3.Max; $applied = $c3 } }
    $safety = [int][math]::Round($final)
    $class = Get-SafetyClass $safety

    # ---------- assessment confidence (how complete and reliable the evidence is; not the safety score)
    $rsum = 0.0; foreach ($e2 in $ev) { $rsum += [double]$e2.Reliability }
    $coverage = $(if ($ev.Count) { $rsum / $ev.Count } else { 0 })
    $fresh = 1.0; $cons = $(if ($facts.Capped) { 0.8 } else { 1.0 }); if ($crit.Count) { $cons -= 0.1 }
    $conf = [int][math]::Round(100 * (0.7 * $coverage + 0.2 * $fresh + 0.1 * $cons)); $conf = [math]::Max(0, [math]::Min(100, $conf))
    $confClass = Get-ConfClass $conf

    # ---------- recommendation
    $rec = switch ($class) { 'Very likely safe' { 'Eligible for controlled cleanup' } 'Likely safe' { 'Eligible for backup and cleanup testing' } 'Uncertain' { 'Keep and investigate' } default { 'Keep' } }
    if ($conf -lt 50) { $rec = 'Not enough information to decide' }
    elseif ($conf -lt 75 -and ($class -eq 'Very likely safe' -or $class -eq 'Likely safe')) { $rec = 'Keep and investigate' }
    if ($caps.Count -gt 0 -and $safety -le 34) { $rec = 'Keep' }

    # ---------- risks
    if ($dim.Runtime -le 40) { [void]$risks.Add('Potential application failure: a running program, service or open file uses this folder.') }
    if ($cls -like 'user-generated*') { [void]$risks.Add('Potential user-data loss: documents or media that cannot be rebuilt.') }
    if ($cls -like 'application state*') { [void]$risks.Add('Potential profile or data corruption: databases or settings of an application.') }
    if (($ownerClass -in @('Confirmed', 'Probable')) -and $own -le 25) { [void]$risks.Add("Potential application failure: the folder belongs to $owner.") }
    if ($dim.Lifecycle -le 55) { [void]$risks.Add('Potential update or rollback failure: versioned or update-related folder.') }
    if ($ownersDiffer) { [void]$risks.Add('Potential shared-data disruption: other applications keep their own copies.') }
    if ($cloud) { [void]$risks.Add('Deleting here may also delete the files from the cloud and other devices.') }
    if ($risks.Count -eq 0) { [void]$risks.Add('No specific risk was identified in the investigated sources; unknown sources remain (see Missing information).') }

    # ---------- explanation (built only from recorded evidence)
    $why = New-Object System.Collections.ArrayList
    if ($applied) { [void]$why.Add('Safety cap applied: ' + $applied.Rule + " (maximum $($applied.Max)%).") }
    foreach ($e3 in ($ev | Where-Object { $_.Result -eq 'Positive' })) { [void]$why.Add($e3.Explanation) }
    foreach ($e3 in ($ev | Where-Object { $_.Result -eq 'Negative' })) { [void]$why.Add($e3.Explanation) }
    $missing = @($ev | Where-Object { $_.Result -eq 'Unknown' } | ForEach-Object { $_.Finding })
    $recovery = [int64]$set.Size; $unique = [int64]$set.Size - [math]::Min([int64]$set.Size, $hardBytes)

    $res = [pscustomobject]@{
        Path = $path; Key = $key; Sig = $sig; Policy = $script:SafetyPolicy; Time = (Get-Date).ToString('s'); Similarity = 100
        Files = $facts.Files; Dirs = $facts.Dirs; Modified = $it.Modified; Size = [int64]$set.Size
        Owner = $owner; OwnerClass = $ownerClass; Application = $(if ($owner) { $owner } else { 'Unknown' }); DataClass = $cls
        Dims = $dim; Weighted = [math]::Round($w, 2); Penalty = $pen; Caps = @($caps); Safety = $safety; Class = $class
        Confidence = $conf; ConfClass = $confClass; Recommendation = $rec; Evidence = @($ev); Risks = @($risks); Missing = $missing; Why = @($why)
        ApparentSize = [int64]$set.Size; UniquePhysical = $unique; Recoverable = $unique; SharedByLinks = [int64][math]::Min([int64]$set.Size, $hardBytes)
        Complete = ($ctx.Fail.Count -eq 0)
    }
    $script:SafetyCache[$key] = $res
    $res
}

function Get-SetSafety($set) {   # assessments already made for the copies of a set (no new investigation)
    $out = New-Object System.Collections.ArrayList
    foreach ($o in $set.Items) { $a = Get-CachedSafety $o $set; if ($a) { [void]$out.Add($a) } }
    $out.ToArray()
}
function Get-SetBestClass($set) {   # class of the copy that is safest to delete; '' when nothing is assessed yet
    $best = $null; foreach ($a in (Get-SetSafety $set)) { if (-not $best -or $a.Safety -gt $best.Safety) { $best = $a } }
    if ($best) { $best.Class } else { '' }
}
# Default action by safety: a copy judged below 80% starts as KEEP (even if that leaves every copy of the set on KEEP). Each copy is judged once, the first time it is assessed,
# so what the user ticks afterwards is never reverted; the judged paths are remembered between runs.
$script:LowKeepDone = New-Object 'System.Collections.Generic.HashSet[string]'
try { $jf = Join-Path $env:LOCALAPPDATA 'DupCleaner\safety-judged.txt'; if (Test-Path -LiteralPath $jf) { foreach ($ln in [IO.File]::ReadAllLines($jf)) { if ($ln) { [void]$script:LowKeepDone.Add($ln) } } } } catch { Write-ErrLog $_ }
function Get-RiskClass([int]$r) { if ($r -ge 80) { 'Very high' } elseif ($r -ge 60) { 'High' } elseif ($r -ge 35) { 'Moderate' } else { 'Low' } }
# The two scores of a folder set (they do not depend on what is ticked):
#  SAFE TO KEEP ONE  = how safe it is to delete the extra copies and live with exactly one (the weakest deleted copy, with the best copy kept)
#  RISK IF ALL GO    = how bad it would be to delete EVERY copy (documents lost, program broken, ...)
$script:SetPlan = @{}
function Get-SetPlan($set) {
    $p = $script:SetPlan[$set]; if ($p) { return $p }
    $live = @($set.Items | Where-Object { [IO.Directory]::Exists($_.Path) }); if ($live.Count -lt 2) { return $null }
    $orig = @($set.Items | ForEach-Object { [bool]$_.Remove })
    $ord = @(@($live | Where-Object { -not $_.Remove }) + @($live | Where-Object { $_.Remove })); $cand = $(if ($live.Count -le 3) { $ord } else { @($ord | Select-Object -First 1) })   # small sets: try every copy as the keeper; big sets: the currently kept one
    $best = $null
    try {
        foreach ($k in $cand) {
            foreach ($o in $set.Items) { $o.Remove = ($o -ne $k) }   # pretend: keep only this copy
            $worst = $null; $all = New-Object System.Collections.ArrayList
            foreach ($o in $live) { $a = Get-SafetyAssessment $o $set -Force; [void]$all.Add($a); if ($o -ne $k -and (-not $worst -or $a.Safety -lt $worst.Safety)) { $worst = $a } }
            if ($worst -and (-not $best -or $worst.Safety -gt $best.Worst.Safety)) { $best = [pscustomobject]@{ Keeper = $k; Worst = $worst; All = @($all) } }
        }
    } finally { for ($i = 0; $i -lt $set.Items.Count; $i++) { $set.Items[$i].Remove = $orig[$i] } }
    if (-not $best) { return $null }
    # risk of deleting every copy: the data/ownership/runtime checks without the "another copy remains" credit; unique documents are heavily penalised
    $daSafe = 100; $why = ''
    foreach ($a in $best.All) {
        $d = $a.Dims; $user = ($a.DataClass -like 'user-generated*')
        $dAll = $(if ($user) { 15 } else { $d.Data })
        $w = ($d.Runtime * 20 + $d.Ownership * 20 + $d.Config * 15 + $dAll * 15 + $d.Lifecycle * 10 + $d.Filesystem * 5) / 85.0
        $rule = ''
        foreach ($c in $a.Caps) { if ($c.Rule -notmatch 'last remaining|Independently owned|Unique user data') { if ($c.Max -lt $w) { $w = $c.Max; $rule = $c.Rule } } }
        if ($user -and $w -gt 20) { $w = 20; $rule = 'Your documents or media: deleting every copy would lose them for good' }
        if ($w -lt $daSafe) { $daSafe = $w; $why = $(if ($rule) { $rule } elseif ($a.DataClass) { "Contents: $($a.DataClass)" } else { '' }) }
    }
    $risk = [int](100 - [math]::Round($daSafe))
    $p = [pscustomobject]@{ Score = [int]$best.Worst.Safety; Class = $best.Worst.Class; Keeper = $best.Keeper.Path; Weakest = $best.Worst.Path; Risk = $risk; RiskClass = (Get-RiskClass $risk); RiskWhy = $why; Copies = $set.Items.Count; Assessed = $live.Count; Marked = $false }
    $script:SetPlan[$set] = $p
    $p
}
# Default action by safety: a set judged below 80% starts with every copy on KEEP (the user can still tick copies for deletion). Each set is judged once, the first time it is assessed,
# so what the user ticks afterwards is never reverted; the judged paths are remembered between runs.
$script:LowKeepDone = New-Object 'System.Collections.Generic.HashSet[string]'
try { $jf = Join-Path $env:LOCALAPPDATA 'DupCleaner\safety-judged2.txt'; if (Test-Path -LiteralPath $jf) { foreach ($ln in [IO.File]::ReadAllLines($jf)) { if ($ln) { [void]$script:LowKeepDone.Add($ln) } } } } catch { Write-ErrLog $_ }
function Apply-LowSafetyKeep($set) {   # returns $true when a mark was changed (the per-copy assessments then need a fresh pass, because they depend on the marks)
    $p = $script:SetPlan[$set]; if (-not $p) { return $false }
    $fresh = $false; foreach ($o in $set.Items) { $k = Get-NormPath $o.Path; if ($script:LowKeepDone.Add($k)) { $fresh = $true } }
    if (-not $fresh -or $p.Score -ge 80) { return $false }
    $changed = $false; foreach ($o in $set.Items) { if ($o.Remove) { $o.Remove = $false; $changed = $true } }
    $changed
}
function Assess-SetFully($set, [bool]$Full = $true) {   # score the set (keep-one plan + delete-all risk), apply the low-score default and, when $Full, assess every copy for the current marks (what the cards show)
    [void](Get-SetPlan $set)
    if (-not $Full) { [void](Apply-LowSafetyKeep $set); return }
    foreach ($pass in 1..2) {
        foreach ($o in $set.Items) { if ([IO.Directory]::Exists($o.Path) -and -not (Get-CachedSafety $o $set)) { [void](Get-SafetyAssessment $o $set) } }
        if (-not (Apply-LowSafetyKeep $set)) { break }
    }
}
function Get-SetScore($set) { $script:SetPlan[$set] }   # the keep-one plan of a set; $null until it has been investigated
function Get-ScoreColor($v) { if ($v -gt 90) { $script:UiKeepFg } elseif ($v -ge 80) { [Drawing.Color]::FromArgb(236, 156, 32) } else { $script:UiDelFg } }   # above 90 green, 80-90 orange, below 80 red
function Format-SafetyText($a) { "Safety $($a.Safety)% - $($a.Class)   |   Confidence $($a.Confidence)% ($($a.ConfClass))" }

function Format-SafetyReport($a) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Safety assessment: $($a.Safety)% - $($a.Class)")
    [void]$sb.AppendLine("Assessment confidence: $($a.Confidence)% - $($a.ConfClass)")
    [void]$sb.AppendLine("Folder: $($a.Path)")
    [void]$sb.AppendLine("Recommendation: $($a.Recommendation)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Why:'); foreach ($w in $a.Why) { [void]$sb.AppendLine(' - ' + $w) }
    [void]$sb.AppendLine(''); [void]$sb.AppendLine('Risks:'); foreach ($r in $a.Risks) { [void]$sb.AppendLine(' - ' + $r) }
    if ($a.Missing.Count) { [void]$sb.AppendLine(''); [void]$sb.AppendLine('Missing information:'); foreach ($m in $a.Missing) { [void]$sb.AppendLine(' - ' + $m) } }
    [void]$sb.AppendLine(''); [void]$sb.AppendLine('Disk space:')
    [void]$sb.AppendLine("  Apparent size: $(Format-Size $a.ApparentSize)   Estimated unique physical: $(Format-Size $a.UniquePhysical)   Estimated recoverable: $(Format-Size $a.Recoverable)   Shared through links: $(Format-Size $a.SharedByLinks)")
    [void]$sb.AppendLine(''); [void]$sb.AppendLine('Evidence:')
    foreach ($e in $a.Evidence) { [void]$sb.AppendLine("  [$($e.Id)] $($e.Category) / $($e.Result) / reliability $([int](100 * $e.Reliability))% / $($e.Impact)"); [void]$sb.AppendLine("      Source: $($e.Source)"); [void]$sb.AppendLine("      Finding: $($e.Finding)") }
    [void]$sb.AppendLine(''); [void]$sb.AppendLine("Policy version $($a.Policy), investigated $($a.Time). Read-only investigation: nothing was changed.")
    $sb.ToString()
}

function Save-SafetyReports {
    try {
        $dir = Join-Path $env:LOCALAPPDATA 'DupCleaner'; [void][IO.Directory]::CreateDirectory($dir)
        $items = @($script:SafetyCache.Values | ForEach-Object { $_ })
        $json = ($items | ConvertTo-Json -Depth 6 -Compress)
        [IO.File]::WriteAllText((Join-Path $dir 'safety-reports.json'), $json, (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllLines((Join-Path $dir 'safety-judged2.txt'), [string[]]@($script:LowKeepDone), (New-Object Text.UTF8Encoding($false)))
    } catch { Write-ErrLog $_ }
}

$script:SafetyFilterNames = @('All safety levels', 'Very likely safe', 'Likely safe', 'Uncertain', 'High risk', 'Unsafe', 'Not assessed yet')
function Place-SetButtons {
    $sp = $script:SP; if (-not $sp -or -not $sp.SetHd) { return }
    $s = $sp.SetHd; $b = $sp.BtnMarked; $r = $sp.BtnSafety
    $b.Location = New-Object Drawing.Point(($s.ClientSize.Width - $b.Width - 8), 0)
    $x = $s.ClientSize.Width - 8; if ($b.Visible) { $x = $b.Left - 8 }
    $r.Location = New-Object Drawing.Point(($x - $r.Width), 0)
}
function Update-SafeLine {
    $sp = $script:SP; if (-not $sp -or -not $sp.SafeLine) { return }
    $set = $script:SpCur
    if (-not $set) { $sp.SafeLine.Text = ''; return }
    $as = @(Get-SetSafety $set)
    if ($as.Count -lt $set.Items.Count -and $script:SafetyTimer -and -not $script:Scanning) { $script:SafetyTimer.Stop(); $script:SafetyTimer.Start() }
    if ($as.Count -eq 0) { $sp.SafeLine.Text = 'Safety: investigating this set...'; return }
    $cnt = @{}; foreach ($c in $script:SafetyClasses) { $cnt[$c] = 0 }; $rec = 0L
    foreach ($a in $as) { $cnt[$a.Class]++ }
    foreach ($o in $set.Items) { if ($o.Remove) { $a2 = Get-CachedSafety $o $set; if ($a2) { $rec += $a2.Recoverable } } }
    $ts = Get-SetScore $set
    if (-not $ts) { $sp.SafeLine.Text = 'Safety: investigating this set...'; return }
    $keepName = $(if ($ts.Keeper) { $ts.Keeper } else { '' }); $rec2 = [int64]$set.Size * ($set.Items.Count - 1)
    $sp.SafeLine.Text = "SAFE TO KEEP ONLY ONE: $($ts.Score)% $($ts.Class) (keeping $keepName)   |   RISK IF YOU DELETE ALL COPIES: $($ts.Risk)% $($ts.RiskClass)$(if ($ts.RiskWhy) { ' - ' + $ts.RiskWhy })   |   keeping one frees about $(Format-Size $rec2)"
}
function Invoke-SetAssess {   # investigate the copies of the open set that have no assessment yet (read-only)
    $set = $script:SpCur; if (-not $set -or $script:Scanning) { return }
    $todo = @($set.Items | Where-Object { -not (Get-CachedSafety $_ $set) -and [IO.Directory]::Exists($_.Path) }); if ($todo.Count -eq 0) { return }
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    $before = Get-SetSig $set
    try { if ($script:SpCur -ne $set) { return }; Assess-SetFully $set } finally { $form.Cursor = [Windows.Forms.Cursors]::Default }
    Save-SafetyReports
    if ($before -ne (Get-SetSig $set)) { Request-Summary }
    Resort-SetList $set
    if ($script:SpCur -eq $set) { Refresh-Cards; $script:SP.Lb.Invalidate() }
}
function Start-AutoAssess {   # investigate every duplicate-folder set in the background, the set that frees most space first; the list updates as each one ends
    $sp = $script:SP; if (-not $sp -or $script:Scanning) { return }
    $f = $script:Results['Folder']; if (-not $f -or -not $script:AaTimer) { return }
    $script:AaTimer.Stop()
    $q = [SetUtil]::Sorted($f, 0, '')
    $script:AaQueue = @($q | Where-Object { $s = $_; -not $script:SetPlan[$s] -and @($s.Items | Where-Object { [IO.Directory]::Exists($_.Path) }).Count -ge 2 })
    $script:AaIdx = 0; $script:AaTotal = $script:AaQueue.Count
    if ($script:AaTotal -gt 0) { $script:AaTimer.Start() }
}
function Step-AutoAssess {
    $sp = $script:SP
    if (-not $sp -or $script:Scanning) { $script:AaTimer.Stop(); return }
    if ([ClickWatch]::EscDown()) { $script:AaTimer.Stop(); Save-SafetyReports; Rebuild-SetList; $sp.Count.Text = "Safety investigation stopped at $($script:AaIdx) of $($script:AaTotal) sets"; return }
    if ($script:AaIdx -ge $script:AaQueue.Count) { $script:AaTimer.Stop(); Save-SafetyReports; Rebuild-SetList; return }
    $s = $script:AaQueue[$script:AaIdx]; $script:AaIdx++
    $script:AaTimer.Stop()
    $moved = $false; try { $before = Get-SetSig $s; Assess-SetFully $s $false; $moved = ($before -ne (Get-SetSig $s)) } catch { Write-ErrLog $_ }
    $script:AaTimer.Start()
    Resort-SetList $s   # the new score may move this set; the selected set stays selected
    $nowT = [Environment]::TickCount; if (($nowT - $script:InvAt) -gt 1000 -or ($nowT - $script:InvAt) -lt 0) { $script:InvAt = $nowT; $sp.Lb.Invalidate(); try { $sp.PvDonut.Invalidate() } catch { Write-ErrLog $_ } }
    if ($moved) { Request-Summary }
    if ($script:SpCur -eq $s) { Refresh-Cards }
    $sp.Count.Text = "Investigating safety: $($script:AaIdx) of $($script:AaTotal) sets, largest first - press Esc to stop"
}
function Invoke-AssessAll { Start-AutoAssess }
function Invoke-AssessAll-Old {   # (kept for reference) investigate every listed set (Esc stops)
    $sp = $script:SP; if (-not $sp -or $script:Scanning) { return }
    $sets = @($sp.Lb.Items); if ($sets.Count -eq 0) { return }
    $max = 500; $total = [math]::Min($sets.Count, $max)
    if ($sets.Count -gt $max) { if ([Windows.Forms.MessageBox]::Show("$($sets.Count) sets are listed. Investigate the first $max (largest first by the current sort)? Each set takes a moment.", 'DupCleaner', 'YesNo', 'Question') -ne 'Yes') { return } }
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor; $n = 0
    try {
        foreach ($s in ($sets | Select-Object -First $total)) {
            if ([ClickWatch]::EscDown()) { break }
            foreach ($o in $s.Items) { if ([IO.Directory]::Exists($o.Path)) { [void](Get-SafetyAssessment $o $s) } }
            $n++; $sp.Count.Text = "Investigating safety: $n of $total  -  press Esc to stop"; [Windows.Forms.Application]::DoEvents()
        }
    } finally { $form.Cursor = [Windows.Forms.Cursors]::Default }
    Save-SafetyReports
    $script:SpTimer.Stop(); $script:SpTimer.Start()
}
function Get-RiskyRemovals($items, $set) {   # copies about to be removed that were assessed as uncertain-or-worse (for the current marks)
    @($items | ForEach-Object { $a = Get-CachedSafety $_ $set; if ($a -and $a.Safety -lt 65) { $a } })
}
function Confirm-RiskyRemovals($risky) {
    if (-not $risky -or $risky.Count -eq 0) { return $true }
    $lines = ($risky | Select-Object -First 8 | ForEach-Object { "$($_.Safety)% $($_.Class): $($_.Path)" }) -join "`n"
    $more = $(if ($risky.Count -gt 8) { "`n... and $($risky.Count - 8) more" } else { '' })
    [Windows.Forms.MessageBox]::Show("The safety investigation rated $($risky.Count) of these folders as uncertain, high risk or unsafe to delete:`n`n$lines$more`n`nIdentical contents do not mean a folder is unused. Remove them anyway?", 'Safety warning', 'YesNo', 'Warning', 'Button2') -eq 'Yes'
}

function Show-SafetyReview {
    $set = $script:SpCur; if (-not $set) { return }
    $sc = Get-Sc
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try { foreach ($o in $set.Items) { if ([IO.Directory]::Exists($o.Path)) { [void](Get-SafetyAssessment $o $set) } } } finally { $form.Cursor = [Windows.Forms.Cursors]::Default }
    $script:SfDlg = New-Object Windows.Forms.Form; $script:SfDlg.Text = 'Safety review  -  ' + [SetUtil]::Name($set); $script:SfDlg.StartPosition = 'CenterParent'; $script:SfDlg.ShowInTaskbar = $false
    $script:SfDlg.BackColor = $script:UiBg; $script:SfDlg.ForeColor = $script:UiText; $script:SfDlg.Font = $form.Font; $script:SfDlg.Icon = $form.Icon
    $script:SfDlg.Size = New-Object Drawing.Size([int]([math]::Min($form.Width * 0.92, 2400)), [int]([math]::Min($form.Height * 0.9, 1500)))
    $t = New-Object Windows.Forms.TableLayoutPanel; $t.Dock = 'Fill'; $t.ColumnCount = 1; $t.RowCount = 4; $t.Padding = New-Object Windows.Forms.Padding([int](12 * $sc))
    [void]$t.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    foreach ($rs in @(@('AutoSize', 0), @('Percent', 34), @('Percent', 66), @('AutoSize', 0))) { [void]$t.RowStyles.Add($(if ($rs[0] -eq 'AutoSize') { New-Object Windows.Forms.RowStyle('AutoSize') } else { New-Object Windows.Forms.RowStyle('Percent', $rs[1]) })) }
    $script:SfOver = New-Object Windows.Forms.Label; $script:SfOver.AutoSize = $true; $script:SfOver.MaximumSize = New-Object Drawing.Size([int]($script:SfDlg.Width - 60 * $sc), 0); $script:SfOver.Margin = New-Object Windows.Forms.Padding(0, 0, 0, [int](8 * $sc)); $script:SfOver.UseMnemonic = $false
    $script:SfLv = New-Object Windows.Forms.ListView; $script:SfLv.Dock = 'Fill'; $script:SfLv.View = 'Details'; $script:SfLv.FullRowSelect = $true; $script:SfLv.HideSelection = $false; $script:SfLv.MultiSelect = $false; $script:SfLv.BorderStyle = 'None'; $script:SfLv.BackColor = $script:UiPanel; $script:SfLv.ForeColor = $script:UiText; $script:SfLv.Font = $script:ListFont; $script:SfLv.OwnerDraw = $true
    foreach ($c in @(@('Folder path', 300), @('Application', 130), @('Size', 70), @('Similarity', 80), @('Safety', 70), @('Confidence', 90), @('Status', 120), @('Recommendation', 200))) { [void]$script:SfLv.Columns.Add($c[0], [int]($c[1] * $sc)) }
    $script:SfLv.Add_DrawColumnHeader({ param($s, $e) $b = New-Object Drawing.SolidBrush $script:UiBg; $e.Graphics.FillRectangle($b, $e.Bounds); $b.Dispose(); [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $s.Font, (New-Object Drawing.Rectangle(($e.Bounds.X + 6), $e.Bounds.Y, ($e.Bounds.Width - 8), $e.Bounds.Height)), $script:UiMuted, [Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, NoPrefix'); $pn = New-Object Drawing.Pen $script:UiLine; $e.Graphics.DrawLine($pn, $e.Bounds.Left, ($e.Bounds.Bottom - 1), $e.Bounds.Right, ($e.Bounds.Bottom - 1)); $pn.Dispose() })
    $script:SfLv.Add_DrawItem({ param($s, $e) $e.DrawDefault = $false })
    $script:SfLv.Add_DrawSubItem({
        param($s, $e)
        $sel = $e.Item.Selected
        $bg = New-Object Drawing.SolidBrush $(if ($sel) { $script:UiAccentBg } else { $script:UiPanel }); $e.Graphics.FillRectangle($bg, $e.Bounds); $bg.Dispose()
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.SubItem.Text, $s.Font, (New-Object Drawing.Rectangle(($e.Bounds.X + 6), $e.Bounds.Y, ($e.Bounds.Width - 8), $e.Bounds.Height)), $e.Item.ForeColor, [Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, NoPrefix')
    })
    $script:SfLv2 = New-Object Windows.Forms.ListView; $script:SfLv2.Dock = 'Fill'; $script:SfLv2.View = 'Details'; $script:SfLv2.FullRowSelect = $true; $script:SfLv2.BorderStyle = 'None'; $script:SfLv2.BackColor = $script:UiPanel; $script:SfLv2.ForeColor = $script:UiText; $script:SfLv2.Font = $script:ListFont; $script:SfLv2.OwnerDraw = $true
    foreach ($c in @(@('Assessment dimension', 250), @('Weight', 60), @('Score', 60), @('Adds', 60))) { [void]$script:SfLv2.Columns.Add($c[0], [int]($c[1] * $sc)) }
    $script:SfLv2.Add_DrawColumnHeader({ param($s, $e) $b = New-Object Drawing.SolidBrush $script:UiBg; $e.Graphics.FillRectangle($b, $e.Bounds); $b.Dispose(); [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $s.Font, (New-Object Drawing.Rectangle(($e.Bounds.X + 6), $e.Bounds.Y, ($e.Bounds.Width - 8), $e.Bounds.Height)), $script:UiMuted, [Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, NoPrefix') })
    $script:SfLv2.Add_DrawItem({ param($s, $e) $e.DrawDefault = $false })
    $script:SfLv2.Add_DrawSubItem({ param($s, $e) $bg = New-Object Drawing.SolidBrush $script:UiPanel; $e.Graphics.FillRectangle($bg, $e.Bounds); $bg.Dispose(); [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.SubItem.Text, $s.Font, (New-Object Drawing.Rectangle(($e.Bounds.X + 6), $e.Bounds.Y, ($e.Bounds.Width - 8), $e.Bounds.Height)), $e.Item.ForeColor, [Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, NoPrefix') })
    $script:SfTxt = New-Object Windows.Forms.TextBox; $script:SfTxt.Dock = 'Fill'; $script:SfTxt.Multiline = $true; $script:SfTxt.ReadOnly = $true; $script:SfTxt.ScrollBars = 'Both'; $script:SfTxt.WordWrap = $false; $script:SfTxt.BorderStyle = 'None'; $script:SfTxt.BackColor = $script:UiPanel; $script:SfTxt.ForeColor = $script:UiText; $script:SfTxt.Font = New-Object Drawing.Font('Consolas', 10)
    $script:SfBot = New-Object Windows.Forms.SplitContainer; $script:SfBot.Dock = 'Fill'; $script:SfBot.Orientation = 'Vertical'; $script:SfBot.BackColor = $script:UiBg; $script:SfBot.Panel1.BackColor = $script:UiBg; $script:SfBot.Panel2.BackColor = $script:UiBg; $script:SfBot.SplitterWidth = [int](6 * $sc)
    $script:SfBot.Panel1.Controls.Add($script:SfLv2); $script:SfBot.Panel2.Controls.Add($script:SfTxt)
    $fl = New-Object Windows.Forms.FlowLayoutPanel; $fl.AutoSize = $true; $fl.FlowDirection = 'LeftToRight'; $fl.Dock = 'Fill'
    $bAgain = New-Btn 'Investigate again'; $bSave = New-Btn 'Save report...'; $bClose = New-Btn 'Close' $true
    foreach ($b in $bAgain, $bSave, $bClose) { $b.MinimumSize = New-Object Drawing.Size(0, 0) }
    $fl.Controls.AddRange(@($bAgain, $bSave, $bClose))
    $t.Controls.Add($script:SfOver, 0, 0); $t.Controls.Add($script:SfLv, 0, 1); $t.Controls.Add($script:SfBot, 0, 2); $t.Controls.Add($fl, 0, 3)
    $script:SfDlg.Controls.Add($t)
    $script:SfState = @{ Set = $set }
    $script:SfFill = {
        $script:SfLv.BeginUpdate(); $script:SfLv.Items.Clear()
        $cnt = @{}; foreach ($c in $script:SafetyClasses) { $cnt[$c] = 0 }; $rec = 0L; $app = 0L
        foreach ($o in $script:SfState.Set.Items) {
            $a = Get-CachedSafety $o $script:SfState.Set; if (-not $a) { continue }
            $cnt[$a.Class]++; $app += $a.ApparentSize; if ($o.Remove) { $rec += $a.Recoverable }
            $li = New-Object Windows.Forms.ListViewItem($a.Path); $li.Tag = $a
            foreach ($v in @($a.Application, (Format-Size $a.ApparentSize), "$($a.Similarity)%", "$($a.Safety)%", "$($a.Confidence)%", $a.Class, $a.Recommendation)) { [void]$li.SubItems.Add([string]$v) }
            $li.ForeColor = $(if ($a.Safety -ge 85) { $script:UiKeepFg } elseif ($a.Safety -ge 65) { $script:UiText } else { $script:UiDelFg })
            [void]$script:SfLv.Items.Add($li)
        }
        $script:SfLv.EndUpdate()
        $script:SfOver.Text = "$($script:SfState.Set.Items.Count) copies  -  total apparent storage $(Format-Size $app)  -  recoverable from the marked copies about $(Format-Size $rec)`r`n$($cnt['Very likely safe']) very likely safe,  $($cnt['Likely safe']) likely safe,  $($cnt['Uncertain']) uncertain,  $($cnt['High risk']) high risk,  $($cnt['Unsafe']) unsafe.   Deletion safety and assessment confidence are different measures: similarity (100% here) never raises the safety score."
        if ($script:SfLv.Items.Count) { $script:SfLv.Items[0].Selected = $true }
    }
    $script:SfLv.Add_SelectedIndexChanged({
        if ($script:SfLv.SelectedItems.Count -eq 0) { return }
        $a = $script:SfLv.SelectedItems[0].Tag
        $script:SfLv2.BeginUpdate(); $script:SfLv2.Items.Clear()
        foreach ($k in $script:SafetyWeights.Keys) {
            $li = New-Object Windows.Forms.ListViewItem($script:SafetyDimNames[$k]); foreach ($v in @("$($script:SafetyWeights[$k])%", [string]$a.Dims[$k], ('{0:N1}' -f ($a.Dims[$k] * $script:SafetyWeights[$k] / 100.0)))) { [void]$li.SubItems.Add($v) }
            $li.ForeColor = $(if ($a.Dims[$k] -ge 85) { $script:UiKeepFg } elseif ($a.Dims[$k] -ge 55) { $script:UiText } else { $script:UiDelFg }); [void]$script:SfLv2.Items.Add($li)
        }
        $rows = @(@('Weighted score', '', '', ('{0:N1}' -f $a.Weighted), $script:UiText), @('Missing-evidence penalty', '', '', ('-{0:N1}' -f $a.Penalty), $script:UiMuted))
        foreach ($c in $a.Caps) { $rows += , @("Safety cap: $($c.Rule)", '', '', "max $($c.Max)", $script:UiDelFg) }
        $rows += , @('Final deletion safety', '', '', "$($a.Safety)%", $script:UiAccent)
        $rows += , @("Assessment confidence ($($a.ConfClass))", '', '', "$($a.Confidence)%", $script:UiAccent)
        foreach ($r in $rows) { $li = New-Object Windows.Forms.ListViewItem([string]$r[0]); foreach ($v in $r[1..3]) { [void]$li.SubItems.Add([string]$v) }; $li.ForeColor = $r[4]; [void]$script:SfLv2.Items.Add($li) }
        $script:SfLv2.EndUpdate()
        $script:SfTxt.Text = (Format-SafetyReport $a)
    })
    $bAgain.Add_Click({
        $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
        try { [void](Get-SafetyContext -Force); foreach ($o in $script:SfState.Set.Items) { if ([IO.Directory]::Exists($o.Path)) { [void](Get-SafetyAssessment $o $script:SfState.Set -Force) } } } finally { $form.Cursor = [Windows.Forms.Cursors]::Default }
        & $script:SfFill
    })
    $bSave.Add_Click({
        $sd = New-Object Windows.Forms.SaveFileDialog; $sd.Filter = 'Text report (*.txt)|*.txt'; $sd.FileName = 'safety-report-' + [SetUtil]::Name($script:SfState.Set) + '.txt'
        if ($sd.ShowDialog() -eq 'OK') {
            $sb = New-Object Text.StringBuilder
            foreach ($o in $script:SfState.Set.Items) { $a = Get-CachedSafety $o $script:SfState.Set; if ($a) { [void]$sb.AppendLine((Format-SafetyReport $a)); [void]$sb.AppendLine(('=' * 100)) } }
            [IO.File]::WriteAllText($sd.FileName, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
        }
    })
    $bClose.Add_Click({ $script:SfDlg.Close() })
    $script:SfDlg.Add_Shown({ & $script:SfFill; $script:SfBot.SplitterDistance = [int]($script:SfBot.Width * 0.48); $script:SfLv.Columns[7].Width = -2 })
    $script:SafetyDlg = $script:SfDlg
    [void]$script:SfDlg.ShowDialog($form)
    Save-SafetyReports; $script:SafetyDlg = $null
    Refresh-Cards; $script:SP.Lb.Invalidate()
}
$script:SpPruning = $false
function Show-SetDetail($set) {
    if ($set -and -not $script:SpPruning) {
        $script:SpPruning = $true
        try { if (Test-SetStale $set) { $script:SpSig = ''; Show-Results 'Folder'; Update-SetsPanel; return } } finally { $script:SpPruning = $false }
    }
    $script:SpCur = $set; $script:SpBrowse = $null
    if ($set) {
        foreach ($it in $set.Items) { if (-not $it.Remove -and [IO.Directory]::Exists($it.Path)) { $script:SpBrowse = $it; break } }
        if (-not $script:SpBrowse) { foreach ($it in $set.Items) { if ([IO.Directory]::Exists($it.Path)) { $script:SpBrowse = $it; break } } }
        if (-not $script:SpBrowse) { $script:SpBrowse = $set.Items[0] }
    }
    Refresh-Cards
    Show-Inside
    if ($set -and -not $script:Scanning -and $script:SafetyTimer) { $script:SafetyTimer.Stop(); $script:SafetyTimer.Start() }
}

function Refresh-Cards {
    $sp = $script:SP; if (-not $sp) { return }
    $pn = $sp.Cards; $set = $script:SpCur; $sc = (Get-Sc)
    $pn.SuspendLayout()
    try {
        $keepY = -$pn.AutoScrollPosition.Y
        foreach ($c in @($pn.Controls)) { $pn.Controls.Remove($c); $c.Dispose() }
        if (-not $set) {
            $sp.BtnMarked.Visible = $false; $sp.BtnSafety.Visible = $false; $sp.SafeLine.Text = ''
            $sp.SetHd.Text = 'No set chosen'
            $sp.SetHint.Text = $(if ($script:Results['Folder']) { 'Choose a duplicate folder set on the left.' } else { 'Scan some folders: the duplicate folders appear on the left.' })
            return
        }
        $sp.SetHd.Text = "$([SetUtil]::Name($set))  -  $($set.Items.Count) identical folders, $(Format-Size $set.Size) each"
        $sp.SetHint.Text = 'Tick "Delete this copy" to mark copies, "Keep only this one" to keep one, or "Delete now" to remove a folder at once. Click a copy to see what is inside it.'
        $nm = 0; foreach ($o in $set.Items) { if ($o.Remove) { $nm++ } }
        $sp.BtnMarked.Text = "Delete the $nm marked cop$(if ($nm -eq 1) { 'y' } else { 'ies' }) now"; $sp.BtnMarked.Visible = ($nm -gt 0); $sp.BtnSafety.Visible = $true
        $w = [math]::Max($pn.ClientSize.Width - [int](10 * $sc), [int](560 * $sc)); $y = [int](4 * $sc)
        foreach ($it in $set.Items) {
            $rem = [bool]$it.Remove; $isB = ($it -eq $script:SpBrowse)
            $card = New-Object Windows.Forms.Panel
            $card.Location = New-Object Drawing.Point([int](4 * $sc), $y); $card.Size = New-Object Drawing.Size($w, [int](48 * $sc)); $card.Anchor = 'Top, Left, Right'
            $card.BackColor = $(if ($rem) { $script:SpDelBg } else { $script:SpKeepBg }); $card.Tag = $it; $card.Cursor = [Windows.Forms.Cursors]::Hand; Set-Round $card 10 $(if ($rem) { $script:SpDelFg } else { $script:SpKeepFg })
            $pill = New-Object Windows.Forms.Label; $pill.AutoSize = $false; $pill.Size = New-Object Drawing.Size([int](72 * $sc), [int](24 * $sc)); $pill.Location = New-Object Drawing.Point([int](8 * $sc), [int](11 * $sc))
            $pill.Text = $(if ($rem) { 'DELETE' } else { 'KEEP' }); $pill.TextAlign = 'MiddleCenter'; $pill.ForeColor = $script:UiOnAccent; Set-Round $pill 7; $pill.BackColor = $(if ($rem) { $script:SpDelFg } else { $script:SpKeepFg })
            $pill.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold); $pill.Tag = $it
            $rx = [int](492 * $sc)
            $pth = New-Object Windows.Forms.Label; $pth.AutoSize = $false; $pth.AutoEllipsis = $true; $pth.UseMnemonic = $false
            $pth.Location = New-Object Drawing.Point([int](88 * $sc), [int](2 * $sc)); $pth.Size = New-Object Drawing.Size(($w - [int](88 * $sc) - $rx), [int](24 * $sc)); $pth.Anchor = 'Top, Left, Right'
            $pth.Font = New-Object Drawing.Font('Consolas', 10.5, $(if ($isB) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular })); $pth.Text = $it.Path; $pth.Tag = $it; $pth.TextAlign = 'MiddleLeft'
            $inf = New-Object Windows.Forms.Label; $inf.AutoSize = $false; $inf.AutoEllipsis = $true; $inf.UseMnemonic = $false
            $inf.Location = New-Object Drawing.Point([int](88 * $sc), [int](26 * $sc)); $inf.Size = New-Object Drawing.Size(($w - [int](88 * $sc) - $rx), [int](20 * $sc)); $inf.Anchor = 'Top, Left, Right'
            $inf.ForeColor = $script:UiMuted; $inf.Tag = $it; $inf.TextAlign = 'MiddleLeft'
            $sa = $script:SafetyCache[(Get-NormPath $it.Path)]
            $inf.Text = $(if ($sa) { "Safety $($sa.Safety)% $($sa.Class)  |  confidence $($sa.Confidence)%  |  " } else { 'Safety: checking...  |  ' }) + "modified $($it.Modified.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))$(if ($isB) { '  |  contents shown below' })"
            if ($sa) { $inf.ForeColor = (Get-ScoreColor $sa.Safety) }
            if (-not $rem -and @($set.Items | Where-Object { $_.Remove }).Count -gt 0) { $inf.Text = "This copy stays - only the marked copies are scored  |  modified $($it.Modified.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))$(if ($isB) { '  |  contents shown below' })"; $inf.ForeColor = $script:UiMuted }
            $chk = New-Object Windows.Forms.CheckBox; $chk.Text = 'Delete this copy'; $chk.AutoSize = $false; $chk.Size = New-Object Drawing.Size([int](150 * $sc), [int](24 * $sc))
            $chk.Location = New-Object Drawing.Point(($w - $rx + [int](4 * $sc)), [int](12 * $sc)); $chk.Anchor = 'Top, Right'; $chk.Checked = $rem; $chk.Tag = $it; $chk.BackColor = $card.BackColor
            $btn = New-Btn 'Keep only this one'; $btn.MinimumSize = New-Object Drawing.Size(0, 0); $btn.AutoSize = $false; $btn.Size = New-Object Drawing.Size([int](184 * $sc), [int](30 * $sc))
            $btn.Location = New-Object Drawing.Point(($w - $rx + [int](160 * $sc)), [int](9 * $sc)); $btn.Anchor = 'Top, Right'; $btn.Tag = $it
            $bdel = New-Btn 'Delete now'; $bdel.MinimumSize = New-Object Drawing.Size(0, 0); $bdel.AutoSize = $false; $bdel.Size = New-Object Drawing.Size([int](124 * $sc), [int](30 * $sc))
            $bdel.Location = New-Object Drawing.Point(($w - $rx + [int](350 * $sc)), [int](9 * $sc)); $bdel.Anchor = 'Top, Right'; $bdel.Tag = $it; $bdel.ForeColor = $script:SpDelFg
            $tip.SetToolTip($bdel, 'Delete this folder right now, using the action chosen at the bottom (quarantine, Recycle Bin or permanent delete)')
            $chk.Add_CheckedChanged({ param($s, $e) Set-CopyRemove $s.Tag $s.Checked })
            $btn.Add_Click({ param($s, $e) Set-OnlyKeep $s.Tag })
            $bdel.Add_Click({ param($s, $e) Remove-CopiesNow @($s.Tag) })
            foreach ($x in $card, $pill, $pth, $inf) { $x.Add_Click({ param($s, $e) Set-Browse $s.Tag }) }
            $card.Controls.AddRange(@($pill, $pth, $inf, $chk, $btn, $bdel))
            $pn.Controls.Add($card)
            $y += [int](54 * $sc)
        }
        $pn.AutoScrollMinSize = New-Object Drawing.Size(0, ($y + [int](4 * $sc)))
        $pn.AutoScrollPosition = New-Object Drawing.Point(0, $keepY)
        Update-SafeLine; Place-SetButtons
    } finally { $pn.ResumeLayout() }
}

function Set-Browse($it) { if ($it -eq $script:SpBrowse) { return }; $script:SpBrowse = $it; Refresh-Cards; Show-Inside }

function Set-CopyRemove($it, [bool]$on) {
    if ($script:SpBusy -or -not $script:SpCur) { return }
    $it.Remove = $on
    $all = $true; foreach ($o in $script:SpCur.Items) { if (-not $o.Remove) { $all = $false } }
    if ($all) {   # every copy of the set would go: allowed, but only after an explicit warning
        $a = [Windows.Forms.MessageBox]::Show("WARNING: this ticks the LAST remaining copy of this folder.`n`nIf you apply, NO copy will be left - it is gone from every location.`n`nKeep it ticked?", 'Delete every copy?', 'YesNo', 'Warning', 'Button2')
        if ($a -ne 'Yes') { $it.Remove = $false }
    }
    Refresh-Cards; $script:SP.Lb.Invalidate(); Request-Summary
}
# delete the given copies of the chosen set right now, with the action chosen at the bottom (quarantine / Recycle Bin / permanent)
function Remove-CopiesNow($items) {
    $set = $script:SpCur
    if (-not $set -or $script:Scanning -or -not $items -or $items.Count -eq 0) { if ($script:Scanning) { $lblStatus.Text = 'Wait for the scan to finish before deleting.' }; return }
    foreach ($o in $items) { if ([IO.Directory]::Exists($o.Path)) { [void](Get-SafetyAssessment $o $set) } }
    if (-not (Confirm-RiskyRemovals (Get-RiskyRemovals $items $set))) { return }
    $mode = if ($rbMove.Checked) { 'move' } elseif ($rbRecycle.Checked) { 'recycle' } else { 'delete' }
    $what = switch ($mode) { 'move' { "MOVED to the quarantine folder:`n$($txtQ.Text)  (undoable)" } 'recycle' { 'sent to the RECYCLE BIN' } default { 'PERMANENTLY DELETED (cannot be undone)' } }
    $left = 0; foreach ($o in $set.Items) { if ($items -notcontains $o) { $left++ } }
    $list = ($items | ForEach-Object { $_.Path }) -join "`n"
    $msg = "$($items.Count) folder(s), about $(Format-Size ($set.Size * $items.Count)), will be $what`n`n$list"
    if ($left -eq 0) {
        $a = [Windows.Forms.MessageBox]::Show("WARNING: this removes EVERY copy of this folder. Nothing of it will be left anywhere.`n`n$msg`n`nReally remove every copy?", 'Delete every copy?', 'YesNo', 'Warning', 'Button2')
    } else {
        $a = [Windows.Forms.MessageBox]::Show("$msg`n`n$left cop$(if ($left -eq 1) { 'y stays' } else { 'ies stay' }). Continue?", 'Delete folder', 'YesNo', 'Question', 'Button2')
    }
    if ($a -ne 'Yes') { return }
    if ($mode -eq 'delete') { if ([Windows.Forms.MessageBox]::Show('Permanent delete skips the Recycle Bin. Are you really sure?', 'Permanent delete', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { return } }
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try {
        $orig = @{}; foreach ($o in $set.Items) { $orig[$o] = $o.Remove; $o.Remove = ($items -contains $o) }
        $log = $null
        try { $log = Invoke-Removal @($set) $mode $txtQ.Text 'Folder' }
        finally {
            $keep = New-Object 'System.Collections.Generic.List[object]'
            foreach ($o in $set.Items) { if ($null -eq $o.Remove) { continue }; $o.Remove = $orig[$o]; $keep.Add($o) }   # handled folders are gone from the set
            $set.Items = $keep
        }
        if ($keep.Count -lt 2) { [void]$script:Results['Folder'].Remove($set) }
        if ($script:Results['Nested']) {   # sub-folder sets inside folders that were just removed are gone too
            $keepN = New-Object 'System.Collections.Generic.List[object]'
            foreach ($ns in $script:Results['Nested']) {
                $ex = New-Object 'System.Collections.Generic.List[object]'
                foreach ($it in $ns.Items) { if ([IO.Directory]::Exists($it.Path)) { $ex.Add($it) } }
                if ($ex.Count -ge 2) { $ns.Items = $ex; $keepN.Add($ns) }
            }
            $script:Results['Nested'] = $keepN
        }
        $script:SpCur = $(if ($keep.Count -ge 2) { $set } else { $null })
        Show-Results 'Folder'; Save-Session
        $script:SpSig = ''; Update-SetsPanel
        $lf = Join-Path ([IO.Path]::GetTempPath()) 'DupCleaner-last-run.txt'; $log | Set-Content -LiteralPath $lf -Encoding UTF8
        $fail = @($log | Where-Object { $_ -like 'FAILED*' -or $_ -like 'SKIP*' })
        if ($fail.Count) { [void][Windows.Forms.MessageBox]::Show("Some folders could not be removed:`n`n$(($fail | Select-Object -First 6) -join "`n")`n`nFull log: $lf", 'DupCleaner') }
        else { $lblStatus.Text = "Done: $($items.Count) folder(s) removed. Log: $lf" }
    } catch { [void][Windows.Forms.MessageBox]::Show("Failed: $($_.Exception.Message)", 'DupCleaner', 'OK', 'Error') }
    finally { $form.Cursor = [Windows.Forms.Cursors]::Default }
}
function Set-OnlyKeep($it) {
    if (-not $script:SpCur) { return }
    foreach ($o in $script:SpCur.Items) { $o.Remove = ($o -ne $it) }
    $script:SpBrowse = $it
    Refresh-Cards; Show-Inside; $script:SP.Lb.Invalidate(); Request-Summary
}

# column widths of the blue panel (Size and Modified sit at the right; Name takes the rest). Fitted to the text size until a divider is dragged.
$script:TvUserW = $null
function Get-TvCols($tv) {
    $k = Get-Sc; $f = $tv.Font
    if ($script:TvUserW) { return @([int]($script:TvUserW[0] * $k), [int]($script:TvUserW[1] * $k)) }
    @(([Windows.Forms.TextRenderer]::MeasureText('000.0 MB', $f).Width + [int](26 * $k)), ([Windows.Forms.TextRenderer]::MeasureText('0000-00-00 00:00', $f).Width + [int](26 * $k)))
}
# ---- the blue panel: sub-folders and files of the chosen copy, read from disk when a folder is opened
function Add-FsKids($nodes, [string]$dir) {
    $dirs = New-Object 'System.Collections.Generic.List[object]'; $files = New-Object 'System.Collections.Generic.List[object]'
    try {
        $di = New-Object IO.DirectoryInfo($dir)
        foreach ($d in $di.EnumerateDirectories()) { $dirs.Add($d) }
        foreach ($f in $di.EnumerateFiles()) { $files.Add($f) }
    } catch {
        $n = New-Object Windows.Forms.TreeNode("Cannot read this folder: $($_.Exception.Message)"); $n.ForeColor = $script:UiMuted; [void]$nodes.Add($n); return
    }
    $sd = @($dirs | Sort-Object Name); $sf = @($files | Sort-Object Name)
    $cap = $script:SpMaxKids; $added = 0
    foreach ($d in $sd) {
        if ($added -ge $cap) { break }
        $n = New-Object Windows.Forms.TreeNode($d.Name); $n.Tag = [pscustomobject]@{ Path = $d.FullName; Dir = $true; Loaded = $false; Size = ''; Mod = $d.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
        $k = Get-IconKey $d.Name $true; $n.ImageKey = $k; $n.SelectedImageKey = $k
        [void]$n.Nodes.Add((New-Object Windows.Forms.TreeNode('...')))
        [void]$nodes.Add($n); $added++
    }
    foreach ($f in $sf) {
        if ($added -ge $cap) { break }
        $n = New-Object Windows.Forms.TreeNode($f.Name); $n.Tag = [pscustomobject]@{ Path = $f.FullName; Dir = $false; Loaded = $true; Size = (Format-Size $f.Length); Mod = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
        $k = Get-IconKey $f.Name $false; $n.ImageKey = $k; $n.SelectedImageKey = $k
        [void]$nodes.Add($n); $added++
    }
    $left = $sd.Count + $sf.Count - $added
    if ($left -gt 0) { $n = New-Object Windows.Forms.TreeNode("... $left more items not shown (open the folder in Explorer to see all)"); $n.ForeColor = $script:UiMuted; [void]$nodes.Add($n) }
}

# total files and folders below a folder (stops after 2.5 s on huge folders and then says "or more")
function Get-InsideCount([string]$root) {
    $files = 0; $dirs = 0; $done = $true; $sw = [Diagnostics.Stopwatch]::StartNew()
    $stack = New-Object 'System.Collections.Generic.Stack[string]'; $stack.Push($root)
    while ($stack.Count -gt 0) {
        if ($sw.ElapsedMilliseconds -gt 2500) { $done = $false; break }
        $d = $stack.Pop()
        try {
            $files += [IO.Directory]::GetFiles($d).Length
            foreach ($s in [IO.Directory]::GetDirectories($d)) {
                if (([IO.File]::GetAttributes($s) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $dirs++; $stack.Push($s)
            }
        } catch { Write-ErrLog $_ }
    }
    return [pscustomobject]@{ Files = $files; Dirs = $dirs; Done = $done }
}

function Show-Inside {
    $sp = $script:SP; if (-not $sp) { return }
    $tv = $sp.Tv; $it = $script:SpBrowse
    Show-Embedded $null $false
    $tv.BeginUpdate()
    try {
        $tv.Nodes.Clear()
        if (-not $it) { $sp.InsideHd.Text = ' INSIDE'; return }
        $sp.InsideHd.Text = " INSIDE  -  shown from the copy at $($it.Path)"
        if (-not [IO.Directory]::Exists($it.Path)) { $n = New-Object Windows.Forms.TreeNode('This folder is not there any more.'); $n.ForeColor = $script:UiMuted; [void]$tv.Nodes.Add($n); return }
        Add-FsKids $tv.Nodes $it.Path
        $cnt = Get-InsideCount $it.Path
        $more = $(if ($cnt.Done) { '' } else { ' or more' })
        $sp.InsideHd.Text = " INSIDE  -  {0:N0}{1} files in {2:N0}{1} folders  -  shown from the copy at {3}" -f $cnt.Files, $more, $cnt.Dirs, $it.Path
    } finally { $tv.EndUpdate() }
}

# ---- right pane: preview of the file chosen in the blue panel
function Set-PvPane([string]$mode, [string]$msg = '') {
    $sp = $script:SP
    $sp.Pic.Visible = ($mode -eq 'image'); $sp.PvTxt.Visible = ($mode -eq 'text'); $sp.PvNote.Visible = ($mode -eq 'note'); $sp.PvDonut.Visible = ($mode -eq 'empty'); if ($mode -eq 'empty') { $sp.PvDonut.Invalidate() }
    if ($mode -eq 'note') { $sp.PvNote.Text = $msg }
}
function Clear-Embedded {
    $sp = $script:SP; if (-not $sp) { return }
    $sp.Pic.Image = $null
    if ($sp.PvBmp) { $sp.PvBmp.Dispose(); $sp.PvBmp = $null }
    $sp.PvTxt.Text = ''; $sp.PvPath = ''
}
function Show-Embedded($path, [bool]$isDir) {
    $sp = $script:SP; if (-not $sp) { return }
    Clear-Embedded
    if (-not $path) { $sp.PvHead.Text = 'Preview'; $sp.PvMeta.Text = ''; $sp.PvBtns.Visible = $false; Set-PvPane 'empty'; return }
    $sp.PvPath = $path; $sp.PvIsDir = $isDir; $sp.PvBtns.Visible = $true
    $sp.PvHead.Text = [IO.Path]::GetFileName($path.TrimEnd('\'))
    $meta = ''
    try {
        if ($isDir) { $meta = "Folder, changed $((New-Object IO.DirectoryInfo($path)).LastWriteTime.ToString('yyyy-MM-dd HH:mm'))" }
        else { $fi = New-Object IO.FileInfo($path); $meta = "$(Format-Size $fi.Length)  -  modified $($fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))" }
    } catch { Write-ErrLog $_ }
    $set = $script:SpCur
    if ($set) { $kept = $null; foreach ($o in $set.Items) { if (-not $o.Remove) { $kept = $o; break } }; $meta += "`r`nIdentical in all $($set.Items.Count) copies.`r`n" + $(if ($kept) { "Kept at: $($kept.Path)" } else { 'No copy is marked to keep.' }) }
    $sp.PvMeta.Text = ''; $sp.PvMeta.Visible = $false   # the date now shows in the blue panel; this text block is gone
    $sp.Form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try {
        if (-not ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path))) { Set-PvPane 'note' 'This file is not there any more.'; return }
        $kind = $(if ($isDir) { 'folder' } else { Get-PvKind $path $false })
        if ($kind -eq 'sniff') { $t = ''; $isT = $false; try { $t = Read-PvText $path ([ref]$isT) } catch { Write-ErrLog $_ }; if ($isT) { $sp.PvTxt.Text = $t; Set-PvPane 'text'; return } else { $kind = 'binary' } }
        switch ($kind) {
            'folder' { Set-PvPane 'note' 'Folder. Open it in the blue panel to see what is inside.' }
            'image' {
                $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
                if ($ext -in '.webp', '.heic') { Set-PvPane 'note' "This picture format ($ext) cannot be shown here.`r`nUse Bigger preview or Open."; return }
                if (([IO.FileInfo]$path).Length -gt 120MB) { Set-PvPane 'note' 'This picture is too large to preview here. Use Open.'; return }
                $bytes = [IO.File]::ReadAllBytes($path); $ms = New-Object IO.MemoryStream(, $bytes)
                $img = [Drawing.Image]::FromStream($ms, $true, $false); $sp.PvBmp = New-Object Drawing.Bitmap($img); $img.Dispose(); $ms.Dispose()
                $sp.Pic.Image = $sp.PvBmp; Set-PvPane 'image'
            }
            'pdf' {
                if (-not (Initialize-PvPdf)) { Set-PvPane 'note' 'PDF preview is not available on this computer.'; return }
                $sf = Await-PvOp ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
                $doc = Await-PvOp ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($sf)) ([Windows.Data.Pdf.PdfDocument])
                $page = $doc.GetPage([uint32]0)
                $opt = New-Object Windows.Data.Pdf.PdfPageRenderOptions; $opt.DestinationWidth = [uint32][math]::Max(500, [math]::Min(1400, $sp.PvArea.ClientSize.Width * 2))
                $st = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
                Await-PvAction ($page.RenderToStreamAsync($st, $opt))
                $rs = [IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($st); $img = [Drawing.Image]::FromStream($rs)
                $sp.PvBmp = New-Object Drawing.Bitmap($img); $img.Dispose(); $rs.Dispose(); $st.Dispose(); $page.Dispose()
                $sp.Pic.Image = $sp.PvBmp; Set-PvPane 'image'
                $sp.PvMeta.Text = "Page 1 of $([int]$doc.PageCount) (Bigger preview shows all pages)"; $sp.PvMeta.Visible = $true
            }
            'text' { $isT = $false; $sp.PvTxt.Text = (Read-PvText $path ([ref]$isT)); Set-PvPane 'text' }
            'media' { Set-PvPane 'note' "Video or audio.`r`nPress Bigger preview to play it." }
            default { Set-PvPane 'note' "No preview for this kind of file.`r`nUse Open to see it." }
        }
    } catch { Set-PvPane 'note' "This file could not be previewed:`r`n$($_.Exception.Message)" }
    finally { $sp.Form.Cursor = [Windows.Forms.Cursors]::Default }
}

function Set-SpFonts {
    $sp = $script:SP; if (-not $sp) { return }
    $sp.SubFont = New-Object Drawing.Font('Segoe UI', [single][math]::Max(8.0, $script:ListFontSize - 2.0))
    $sp.Lb.Font = $script:ListFont; $sp.Lb.ItemHeight = [int][math]::Ceiling($script:ListFont.GetHeight() + $sp.SubFont.GetHeight()) + [int](10 * (Get-Sc))
    $sp.Tv.Font = $script:ListFont
    Refresh-Cards
}

function Add-SetsPanel {
    $lvF = $views['Folder']; $tp = $lvF.Parent; $sc = (Get-Sc)
    $sp = @{ PvBmp = $null; PvPath = ''; PvIsDir = $false; Form = $form }
    $script:SP = $sp
    $sizeInit = { param($s, $e)   # first time the pane has a real size: place the splitter at its planned share
        if ($s.Tag -is [double] -and $s.Tag -gt 0) {
            $total = $(if ($s.Orientation -eq 'Vertical') { $s.Width } else { $s.Height })
            if ($total -gt 300) { try { $s.SplitterDistance = [int]($total * $s.Tag); $s.Tag = 0.0 } catch { Write-ErrLog $_ } }
        }
    }
    $mkSplit = { param($orient, $share) $c = New-Object Windows.Forms.SplitContainer; $c.Dock = 'Fill'; $c.Orientation = $orient; $c.SplitterWidth = [int](6 * $sc); $c.Tag = [double]$share; $c.Add_SizeChanged($sizeInit); Style-Split $c; $c }
    $root = & $mkSplit 'Vertical' 0.26
    $split2 = & $mkSplit 'Horizontal' 0.42
    $split3 = & $mkSplit 'Vertical' 0.5
    $root.Panel2.Controls.Add($split2); $split2.Panel2.Controls.Add($split3); $sp.Splits = @($root, $split2, $split3)

    # left: header + list
    $lb = New-Object Windows.Forms.ListBox; $lb.Dock = 'Fill'; $lb.DrawMode = 'OwnerDrawFixed'; $lb.IntegralHeight = $false; $lb.BorderStyle = 'None'; [void][Windows.Forms.Control].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($lb, $true)
    $lbHost = New-Object Windows.Forms.Panel; $lbHost.Dock = 'Fill'; $lbHost.BackColor = $script:UiPanel; $lbHost.Padding = New-Object Windows.Forms.Padding([int](5 * $sc)); $lbHost.Controls.Add($lb); Set-Round $lbHost 12 $script:UiLine
    $mkHost = { param($ctl, $y) $h = New-Object Windows.Forms.Panel; $h.Name = 'rh'; $h.BackColor = $script:UiPanel; $h.Location = New-Object Drawing.Point([int](2 * $sc), [int]($y * $sc)); $h.Size = New-Object Drawing.Size([int](100 * $sc), [int](36 * $sc)); $h.Anchor = 'Top, Left, Right'; $h.Padding = New-Object Windows.Forms.Padding([int](10 * $sc), [int](7 * $sc), [int](8 * $sc), [int](4 * $sc)); $ctl.Dock = 'Fill'; $h.Controls.Add($ctl); Set-Round $h 9 $script:UiLine; $h }
    $sp.Lb = $lb
    $hd = New-Object Windows.Forms.Panel; $hd.Dock = 'Top'; $hd.Height = [int](216 * $sc)
    $mkl = { param($t, $y, $h, $bold) $l = New-Object Windows.Forms.Label; $l.Text = $t; $l.AutoSize = $false; $l.Location = New-Object Drawing.Point([int](2 * $sc), [int]($y * $sc)); $l.Size = New-Object Drawing.Size([int](100 * $sc), [int]($h * $sc)); $l.Anchor = 'Top, Left, Right'; $l.UseMnemonic = $false; if ($bold) { $l.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold) }; $l }
    $l1 = & $mkl 'Duplicate folder sets' 2 24 $true
    $tkF = New-Tick; $tkF.Location = New-Object Drawing.Point([int](2 * $sc), [int](4 * $sc)); $l1.Location = New-Object Drawing.Point([int](24 * $sc), [int](2 * $sc)); $tip.SetToolTip($tkF, 'Select all duplicates (the oldest copy of each is kept). Click again to clear every selection.')
    $l2 = & $mkl 'One row per folder that exists in several places.' 28 38 $false; $l2.ForeColor = $script:UiMuted
    $l3 = & $mkl 'Search a word in the path' 30 20 $false
    $sp.Search = New-Object Windows.Forms.TextBox; $sp.Search.BorderStyle = 'None'; $sp.Search.Width = [int](100 * $sc)
    $l4 = & $mkl 'Sort by' 92 20 $false
    $sp.Sort = New-Object Windows.Forms.ComboBox; $sp.Sort.DropDownStyle = 'DropDownList'; $sp.Sort.FlatStyle = 'Flat'; $sp.Sort.Width = [int](100 * $sc)
    [void]$sp.Sort.Items.AddRange(@('Space you free (largest first)', 'Name (A to Z)', 'Number of copies', 'Date modified (newest first)', 'Safest first, then largest')); $sp.Sort.SelectedIndex = 4
    # the sort box is drawn by hand (round, flat, same colours as the rest); the combo box above only keeps the value and fires the change event
    $sortHost = New-Object Windows.Forms.Panel; $sortHost.Name = 'rh'; $sortHost.BackColor = $script:UiPanel; $sortHost.Location = New-Object Drawing.Point([int](2 * $sc), [int](114 * $sc)); $sortHost.Size = New-Object Drawing.Size([int](100 * $sc), [int](36 * $sc)); $sortHost.Anchor = 'Top, Left, Right'; $sortHost.Cursor = [Windows.Forms.Cursors]::Hand
    Set-Round $sortHost 9 $script:UiLine
    $sortHost.Add_Paint({ param($s, $e)
        $sc2 = (Get-Sc); $txt = [string]$script:SP.Sort.SelectedItem
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $txt, $s.Font, (New-Object Drawing.Rectangle([int](10 * $sc2), 0, ($s.Width - [int](40 * $sc2)), $s.Height)), $script:UiText, [Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, NoPrefix')
        $e.Graphics.SmoothingMode = 'AntiAlias'; $pn = New-Object Drawing.Pen $script:UiMuted, ([single](1.8 * $sc2 / 1.5)); $cx = $s.Width - [int](20 * $sc2); $cy = [int]($s.Height / 2); $d = [int](4 * $sc2)
        $e.Graphics.DrawLines($pn, @((New-Object Drawing.Point(($cx - $d), ($cy - [int]($d / 2)))), (New-Object Drawing.Point($cx, ($cy + [int]($d / 2)))), (New-Object Drawing.Point(($cx + $d), ($cy - [int]($d / 2)))))); $pn.Dispose()
    })
    $sortMenu = New-Object Windows.Forms.ContextMenuStrip; $sortMenu.BackColor = $script:UiPanel; $sortMenu.ForeColor = $script:UiText; $sortMenu.ShowImageMargin = $false; $sortMenu.Font = $script:ListFont
    foreach ($si in 4, 0, 1, 2, 3) { $mi = $sortMenu.Items.Add([string]$sp.Sort.Items[$si]); $mi.Tag = $si; $mi.BackColor = $script:UiPanel; $mi.ForeColor = $script:UiText; $mi.Add_Click({ param($s, $e) $script:SP.Sort.SelectedIndex = [int]$s.Tag }) }
    $script:SortMenu = $sortMenu; $sortHost.Add_Click({ param($s, $e) $script:SortMenu.Width = $s.Width; $script:SortMenu.Show($s, (New-Object Drawing.Point(0, $s.Height))) })
    $sp.Sort.Add_SelectedIndexChanged({ $script:SP.SortHost.Invalidate() }); $sp.SortHost = $sortHost
    $sp.Count = New-Object Windows.Forms.Label; $sp.Count.AutoSize = $false; $sp.Count.Dock = 'Bottom'; $sp.Count.Height = [int](22 * $sc); $sp.Count.ForeColor = $script:UiMuted; $sp.Count.Text = 'No scan yet.'
    $l5 = & $mkl 'Deletion safety' 156 20 $false
    $safeHost = New-Object Windows.Forms.Panel; $safeHost.Name = 'rh'; $safeHost.BackColor = $script:UiPanel; $safeHost.Location = New-Object Drawing.Point([int](2 * $sc), [int](178 * $sc)); $safeHost.Size = New-Object Drawing.Size([int](100 * $sc), [int](36 * $sc)); $safeHost.Anchor = 'Top, Left, Right'; $safeHost.Cursor = [Windows.Forms.Cursors]::Hand
    Set-Round $safeHost 9 $script:UiLine
    $safeHost.Add_Paint({ param($s, $e)
        $sc2 = (Get-Sc); $txt = [string]$script:SafetyFilterNames[$script:SafetyFilter]
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $txt, $s.Font, (New-Object Drawing.Rectangle([int](10 * $sc2), 0, ($s.Width - [int](40 * $sc2)), $s.Height)), $script:UiText, [Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, NoPrefix')
        $e.Graphics.SmoothingMode = 'AntiAlias'; $pn = New-Object Drawing.Pen $script:UiMuted, ([single](1.8 * $sc2 / 1.5)); $cx = $s.Width - [int](20 * $sc2); $cy = [int]($s.Height / 2); $d = [int](4 * $sc2)
        $e.Graphics.DrawLines($pn, @((New-Object Drawing.Point(($cx - $d), ($cy - [int]($d / 2)))), (New-Object Drawing.Point($cx, ($cy + [int]($d / 2)))), (New-Object Drawing.Point(($cx + $d), ($cy - [int]($d / 2)))))); $pn.Dispose()
    })
    $safeMenu = New-Object Windows.Forms.ContextMenuStrip; $safeMenu.BackColor = $script:UiPanel; $safeMenu.ForeColor = $script:UiText; $safeMenu.ShowImageMargin = $false; $safeMenu.Font = $script:ListFont
    foreach ($si in 0..6) { $mi = $safeMenu.Items.Add([string]$script:SafetyFilterNames[$si]); $mi.Tag = $si; $mi.BackColor = $script:UiPanel; $mi.ForeColor = $script:UiText; $mi.Add_Click({ param($s, $e) $script:SafetyFilter = [int]$s.Tag; $script:SP.SafeHost.Invalidate(); $script:SpTimer.Stop(); $script:SpTimer.Start() }) }
    [void]$safeMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $miAll = $safeMenu.Items.Add('Investigate all sets now, largest first (Esc stops)'); $miAll.BackColor = $script:UiPanel; $miAll.ForeColor = $script:UiText; $miAll.Add_Click({ Invoke-AssessAll })
    $script:SafeMenu = $safeMenu; $safeHost.Add_Click({ param($s, $e) $script:SafeMenu.Width = $s.Width; $script:SafeMenu.Show($s, (New-Object Drawing.Point(0, $s.Height))) }); $sp.SafeHost = $safeHost
    $hd.Controls.Add($tkF); $hd.Controls.AddRange(@($l1, $l3, (& $mkHost $sp.Search 52), $l4, $sortHost, $l5, $safeHost))
    # column headline over the list: the safety score is named once here, rows only show the number
    $lbHead = New-Object Windows.Forms.Panel; $lbHead.Dock = 'Top'; $lbHead.Height = [int](26 * $sc); $lbHead.BackColor = $script:UiPanel
    $lbHead.Add_Paint({ param($s, $e)
        $sc2 = (Get-Sc); $sw2 = [int](118 * $sc2); $f2 = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, 'Folder set', $f2, (New-Object Drawing.Rectangle([int](6 * $sc2), 0, ($s.Width - $sw2 - [int](14 * $sc2)), $s.Height)), $script:UiMuted, [Windows.Forms.TextFormatFlags]'Left, VerticalCenter, NoPrefix')
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, 'Safe to keep one', $f2, (New-Object Drawing.Rectangle(($s.Width - $sw2 - [int](4 * $sc2)), 0, $sw2, $s.Height)), $script:UiMuted, [Windows.Forms.TextFormatFlags]'Right, VerticalCenter, NoPrefix')
        $pn2 = New-Object Drawing.Pen $script:UiLine; $e.Graphics.DrawLine($pn2, 0, ($s.Height - 1), $s.Width, ($s.Height - 1)); $pn2.Dispose(); $f2.Dispose()
    })
    $lbHost.Controls.Add($lbHead)
    $root.Panel1.Controls.Add($lbHost); $root.Panel1.Controls.Add($sp.Count); $root.Panel1.Controls.Add($hd)
    $hd.Add_SizeChanged({ param($s, $e) foreach ($c in $s.Controls) { if ($c.Name -ne 'tick') { $c.Width = $s.ClientSize.Width - [int](4 * (Get-Sc)) } } })
    $lb.Add_DrawItem({
        param($s, $e)
        if ($e.Index -lt 0 -or $e.Index -ge $s.Items.Count) { return }
        $set = $s.Items[$e.Index]
        $sel = (($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0)
        $pb = New-Object Drawing.SolidBrush $script:UiPanel; $e.Graphics.FillRectangle($pb, $e.Bounds); $pb.Dispose()
        if ($sel) {
            $e.Graphics.SmoothingMode = 'AntiAlias'; $gp = [Dk]::RoundPath((New-Object Drawing.Rectangle(($e.Bounds.X + 3), ($e.Bounds.Y + 2), ($e.Bounds.Width - 7), ($e.Bounds.Height - 4))), [int](8 * (Get-Sc)))
            $ab = New-Object Drawing.SolidBrush $script:UiAccent; $e.Graphics.FillPath($ab, $gp); $ab.Dispose(); $gp.Dispose()
        }
        $c1 = $(if ($sel) { $script:UiOnAccent } else { $script:UiText })
        $c2 = $(if ($sel) { $script:UiOnAccent } else { $script:UiMuted })
        $b = $e.Bounds; $h1 = [int]($script:ListBold.GetHeight()) + 4; $fl = [Windows.Forms.TextFormatFlags]'EndEllipsis, NoPrefix, Left, VerticalCenter'
        $ts = Get-SetScore $set; $sw = [int](118 * (Get-Sc))
        if ($ts -and -not $sel) { $c1 = Get-ScoreColor $ts.Score; $c2 = $c1 }   # an investigated folder: the whole line takes the score colour (selected rows stay blue)
        $stxt = $(if ($ts) { "$($ts.Score)%" } else { '--' })
        $scol = $(if ($sel) { $script:UiOnAccent } elseif ($ts) { Get-ScoreColor $ts.Score } else { $script:UiMuted })
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $stxt, $script:ListBold, (New-Object Drawing.Rectangle(($b.Right - $sw - 4), ($b.Y + 3), $sw, $h1)), $scol, [Windows.Forms.TextFormatFlags]'NoPrefix, Right, VerticalCenter')
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, [SetUtil]::Name($set), $script:ListBold, (New-Object Drawing.Rectangle(($b.X + 6), ($b.Y + 3), ($b.Width - 14 - $sw), $h1)), $c1, $fl)
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, (Get-SetLine $set), $script:SP.SubFont, (New-Object Drawing.Rectangle(($b.X + 6), ($b.Y + 3 + $h1), ($b.Width - 10), ($b.Height - $h1 - 4))), $c2, $fl)
    })
    $lb.Add_SelectedIndexChanged({ param($s, $e) if ($script:SpBusy) { return }; if ($s.SelectedItem) { Show-SetDetail $s.SelectedItem } })
    $script:SpTimer = New-Object Windows.Forms.Timer; $script:SpTimer.Interval = 350
    $script:SpTimer.Add_Tick({ $script:SpTimer.Stop(); $form.Cursor = [Windows.Forms.Cursors]::WaitCursor; try { Rebuild-SetList } finally { $form.Cursor = [Windows.Forms.Cursors]::Default } })
    $sp.Search.Add_TextChanged({ if ($script:Scanning) { return }; $script:SpTimer.Stop(); $script:SpTimer.Start() })
    $sp.Sort.Add_SelectedIndexChanged({ if ($script:Scanning) { return }; $script:SpTimer.Stop(); $script:SpTimer.Start() })

    # middle top: set title + copies
    $sp.Cards = New-Object Windows.Forms.Panel; $sp.Cards.Dock = 'Fill'; $sp.Cards.AutoScroll = $true
    $sp.SetHd = New-Object Windows.Forms.Label; $sp.SetHd.Dock = 'Top'; $sp.SetHd.AutoSize = $false; $sp.SetHd.Height = [int](28 * $sc); $sp.SetHd.UseMnemonic = $false; $sp.SetHd.AutoEllipsis = $true
    $sp.SetHd.Font = New-Object Drawing.Font('Segoe UI', 12, [Drawing.FontStyle]::Bold); $sp.SetHd.TextAlign = 'MiddleLeft'
    $sp.BtnMarked = New-Btn 'Delete the marked copies now'; $sp.BtnMarked.MinimumSize = New-Object Drawing.Size(0, 0); $sp.BtnMarked.AutoSize = $false
    $sp.BtnMarked.Size = New-Object Drawing.Size([int](300 * $sc), [int](28 * $sc)); $sp.BtnMarked.ForeColor = $script:SpDelFg; $sp.BtnMarked.Visible = $false; $sp.BtnMarked.Font = New-Object Drawing.Font('Segoe UI', 9)
    $tip.SetToolTip($sp.BtnMarked, 'Delete every copy of this set that is marked DELETE, right now, using the action chosen at the bottom')
    $sp.SetHd.Controls.Add($sp.BtnMarked)
    $sp.BtnSafety = New-Btn 'Safety review...'; $sp.BtnSafety.MinimumSize = New-Object Drawing.Size(0, 0); $sp.BtnSafety.AutoSize = $false; $sp.BtnSafety.Size = New-Object Drawing.Size([int](190 * $sc), [int](28 * $sc)); $sp.BtnSafety.Font = New-Object Drawing.Font('Segoe UI', 9)
    $tip.SetToolTip($sp.BtnSafety, 'How safe is it to delete each copy? Shows the evidence, the score and what could go wrong. Read-only: nothing is changed.')
    $sp.SetHd.Controls.Add($sp.BtnSafety); $sp.BtnSafety.Add_Click({ Show-SafetyReview })
    $script:AaTimer = New-Object Windows.Forms.Timer; $script:AaTimer.Interval = 30; $script:AaTimer.Add_Tick({ Step-AutoAssess })
    $script:SafetyTimer = New-Object Windows.Forms.Timer; $script:SafetyTimer.Interval = 700
    $script:SafetyTimer.Add_Tick({ $script:SafetyTimer.Stop(); try { Invoke-SetAssess } catch { Write-ErrLog $_ } })
    $sp.SetHd.Add_SizeChanged({ Place-SetButtons })
    $sp.BtnMarked.Add_Click({ $set = $script:SpCur; if (-not $set) { return }; $m = New-Object 'System.Collections.Generic.List[object]'; foreach ($o in $set.Items) { if ($o.Remove) { $m.Add($o) } }; if ($m.Count) { Remove-CopiesNow $m.ToArray() } })
    $sp.SetHint = New-Object Windows.Forms.Label; $sp.SetHint.Dock = 'Top'; $sp.SetHint.AutoSize = $false; $sp.SetHint.Height = [int](24 * $sc); $sp.SetHint.ForeColor = $script:UiMuted; $sp.SetHint.TextAlign = 'MiddleLeft'
    $sp.SafeLine = New-Object Windows.Forms.Label; $sp.SafeLine.Dock = 'Top'; $sp.SafeLine.AutoSize = $false; $sp.SafeLine.Height = [int](24 * $sc); $sp.SafeLine.ForeColor = $script:UiAccent; $sp.SafeLine.TextAlign = 'MiddleLeft'; $sp.SafeLine.AutoEllipsis = $true; $sp.SafeLine.UseMnemonic = $false
    $split2.Panel1.Controls.Add($sp.Cards); $split2.Panel1.Controls.Add($sp.SafeLine); $split2.Panel1.Controls.Add($sp.SetHint); $split2.Panel1.Controls.Add($sp.SetHd)

    # middle bottom: the blue "inside" panel
    $outer = New-Object Windows.Forms.Panel; $outer.Dock = 'Fill'; $outer.BackColor = $script:SpBlueLine; $outer.Padding = New-Object Windows.Forms.Padding([int](2 * $sc))
    $inner = New-Object Windows.Forms.Panel; $inner.Dock = 'Fill'; $inner.BackColor = $script:SpBlue; Set-Round $inner 12; Set-Round $outer 14
    $tv = New-Object Windows.Forms.TreeView; $tv.Dock = 'Fill'; $tv.BorderStyle = 'None'; $tv.BackColor = $script:SpBlue; $tv.ForeColor = $script:UiText; $tv.ShowLines = $true; $tv.ShowPlusMinus = $true; $tv.ShowRootLines = $true; $tv.HideSelection = $false
    $tv.LineColor = $script:SpBlueLine; $tv.ImageList = $script:Icons; $tv.Font = $script:ListFont
    $sp.Tv = $tv
    $sp.InsideHd = New-Object Windows.Forms.Label; $sp.InsideHd.Dock = 'Top'; $sp.InsideHd.AutoSize = $false; $sp.InsideHd.Height = [int](26 * $sc); $sp.InsideHd.UseMnemonic = $false; $sp.InsideHd.AutoEllipsis = $true
    $sp.InsideHd.TextAlign = 'MiddleLeft'; $sp.InsideHd.ForeColor = $script:UiAccent; $sp.InsideHd.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold); $sp.InsideHd.Text = ' INSIDE'
    $tv.DrawMode = 'OwnerDrawText'; $tv.Scrollable = $true
    $hdr = New-Object Windows.Forms.Panel; $hdr.Dock = 'Top'; $hdr.Height = [int](28 * $sc); $hdr.BackColor = $script:SpBlue; $hdr.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
    [void][Windows.Forms.Panel].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($hdr, $true)
    $sp.TvHdr = $hdr; $script:TvDrag = 0
    $hdr.Add_Paint({
        param($s, $e)
        $tv = $script:SP.Tv; $c = Get-TvCols $tv; $cw = $tv.ClientSize.Width; $k = Get-Sc; $x2 = $cw - $c[1]; $x1 = $x2 - $c[0]; $h = $s.Height
        $pn = New-Object Drawing.Pen $script:SpBlueLine; $e.Graphics.DrawLine($pn, 0, ($h - 1), $s.Width, ($h - 1))
        foreach ($x in $x1, $x2) { $e.Graphics.DrawLine($pn, $x, [int](5 * $k), $x, ($h - [int](5 * $k))) }; $pn.Dispose()
        $fl = [Windows.Forms.TextFormatFlags]'VerticalCenter, EndEllipsis, NoPrefix'
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, 'Name', $s.Font, (New-Object Drawing.Rectangle([int](10 * $k), 0, ($x1 - [int](14 * $k)), $h)), $script:UiMuted, ($fl -bor [Windows.Forms.TextFormatFlags]::Left))
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, 'Size', $s.Font, (New-Object Drawing.Rectangle($x1, 0, ($c[0] - [int](10 * $k)), $h)), $script:UiMuted, ($fl -bor [Windows.Forms.TextFormatFlags]::Right))
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, 'Modified', $s.Font, (New-Object Drawing.Rectangle(($x2 + [int](10 * $k)), 0, ($c[1] - [int](10 * $k)), $h)), $script:UiMuted, ($fl -bor [Windows.Forms.TextFormatFlags]::Left))
    })
    $hdr.Add_MouseMove({
        param($s, $e)
        $tv = $script:SP.Tv; $c = Get-TvCols $tv; $cw = $tv.ClientSize.Width; $k = Get-Sc; $x2 = $cw - $c[1]; $x1 = $x2 - $c[0]; $g = [int](4 * $k)
        if ($script:TvDrag -eq 0) { $s.Cursor = $(if ([Math]::Abs($e.X - $x1) -le $g -or [Math]::Abs($e.X - $x2) -le $g) { [Windows.Forms.Cursors]::SizeWE } else { [Windows.Forms.Cursors]::Default }); return }
        $minW = [int](50 * $k); $minName = [int](120 * $k)
        if ($script:TvDrag -eq 1) { $sw = [Math]::Max($minW, [Math]::Min($x2 - $e.X, $cw - $c[1] - $minName)); $script:TvUserW = @(($sw / $k), ($c[1] / $k)) }
        else { $mw = [Math]::Max($minW, [Math]::Min($cw - $e.X, $cw - $c[0] - $minName)); $script:TvUserW = @(($c[0] / $k), ($mw / $k)) }
        $s.Invalidate(); $tv.Invalidate()
    })
    $hdr.Add_MouseDown({
        param($s, $e)
        $tv = $script:SP.Tv; $c = Get-TvCols $tv; $cw = $tv.ClientSize.Width; $k = Get-Sc; $x2 = $cw - $c[1]; $x1 = $x2 - $c[0]; $g = [int](4 * $k)
        if ($e.Button -ne 'Left') { return }
        if ([Math]::Abs($e.X - $x1) -le $g) { $script:TvDrag = 1; $s.Capture = $true } elseif ([Math]::Abs($e.X - $x2) -le $g) { $script:TvDrag = 2; $s.Capture = $true }
    })
    $hdr.Add_MouseUp({ param($s, $e) $script:TvDrag = 0; $s.Capture = $false })
    $tv.Add_DrawNode({
        param($s, $e)
        $e.DrawDefault = $false
        $n = $e.Node; $t = $n.Tag; $b = $e.Bounds; if ($b.Width -le 0 -or $b.Height -le 0) { return }
        $k = Get-Sc; $c = Get-TvCols $s; $cw = $s.ClientSize.Width; $x2 = $cw - $c[1]; $x1 = $x2 - $c[0]
        $sel = (($e.State -band [Windows.Forms.TreeNodeStates]::Selected) -ne 0)
        $rx = $b.X - 2
        $bg = New-Object Drawing.SolidBrush ($(if ($sel) { $script:UiAccent } else { $s.BackColor })); $e.Graphics.FillRectangle($bg, $rx, $b.Y, ($cw - $rx), $b.Height); $bg.Dispose()
        $fc = $(if ($sel) { $script:UiOnAccent } elseif ($n.ForeColor -ne [Drawing.Color]::Empty) { $n.ForeColor } else { $script:UiText })
        $dc = $(if ($sel) { $script:UiOnAccent } else { $script:UiMuted })
        $fl = [Windows.Forms.TextFormatFlags]'VerticalCenter, EndEllipsis, NoPrefix'
        $nameW = [Math]::Max([int](20 * $k), ($x1 - [int](8 * $k) - $b.X))
        $nm = $n.Text; $nf = $s.Font
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $nm, $nf, (New-Object Drawing.Rectangle($b.X, $b.Y, $nameW, $b.Height)), $fc, ($fl -bor [Windows.Forms.TextFormatFlags]::Left))
        if ($t -and $t.Mod) {
            if ($t.Size) { [Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$t.Size, $nf, (New-Object Drawing.Rectangle($x1, $b.Y, ($c[0] - [int](10 * $k)), $b.Height)), $dc, ($fl -bor [Windows.Forms.TextFormatFlags]::Right)) }
            [Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$t.Mod, $nf, (New-Object Drawing.Rectangle(($x2 + [int](10 * $k)), $b.Y, ($c[1] - [int](10 * $k)), $b.Height)), $dc, ($fl -bor [Windows.Forms.TextFormatFlags]::Left))
        }
    })
    $tv.Add_AfterSelect({ param($s, $e) $s.Invalidate() }); $tv.Add_SizeChanged({ param($s, $e) $script:SP.TvHdr.Invalidate() })
    $inner.Controls.Add($tv); $inner.Controls.Add($hdr); $inner.Controls.Add($sp.InsideHd); $outer.Controls.Add($inner); $split3.Panel1.Controls.Add($outer)
    $tv.Add_HandleCreated({ param($s, $e) [TreeUtil]::DoubleBuffer($s); [TreeUtil]::NoHScroll($s) })
    $tv.Add_BeforeExpand({
        param($s, $e)
        $n = $e.Node
        if ($n.Tag -and $n.Tag.Dir -and -not $n.Tag.Loaded) {
            $n.Tag.Loaded = $true; $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
            try { $n.Nodes.Clear(); Add-FsKids $n.Nodes $n.Tag.Path } finally { $form.Cursor = [Windows.Forms.Cursors]::Default }
        }
    })
    $script:SpPvTimer = New-Object Windows.Forms.Timer; $script:SpPvTimer.Interval = 150
    $script:SpPvTimer.Add_Tick({
        $script:SpPvTimer.Stop()
        $n = $script:SP.Tv.SelectedNode
        if ($n -and $n.Tag) { Show-Embedded $n.Tag.Path ([bool]$n.Tag.Dir) }
    })
    $tv.Add_AfterSelect({ $script:SpPvTimer.Stop(); $script:SpPvTimer.Start(); if ($script:Pv -and $script:Pv.Form.Visible) { $script:PvTimer.Stop(); $script:PvTimer.Start() } })
    $tv.Add_NodeMouseDoubleClick({ param($s, $e) $t = $e.Node.Tag; if ($t -and -not $t.Dir) { Open-File $t.Path } })
    $tv.Add_MouseDown({ param($s, $e) if ($e.Button -eq 'Right') { $h = $s.GetNodeAt($e.X, $e.Y); if ($h) { $s.SelectedNode = $h } } })
    $tv.Add_MouseWheel({ param($s, $e) if ([Windows.Forms.Control]::ModifierKeys -band [Windows.Forms.Keys]::Control) { try { ([Windows.Forms.HandledMouseEventArgs]$e).Handled = $true } catch { Write-ErrLog $_ }; Set-ListFont ($script:ListFontSize + [math]::Sign($e.Delta)) } })
    $cm = New-Object Windows.Forms.ContextMenuStrip
    $mOpen = $cm.Items.Add('Open'); $mOpen.Add_Click({ $n = $script:SP.Tv.SelectedNode; if ($n -and $n.Tag) { Open-File $n.Tag.Path } })
    $mExp = $cm.Items.Add('Show in Explorer'); $mExp.Add_Click({ $n = $script:SP.Tv.SelectedNode; if ($n -and $n.Tag) { Start-Process explorer.exe -ArgumentList "/select,`"$($n.Tag.Path)`"" } })
    $mBig = $cm.Items.Add('Bigger preview'); $mBig.Add_Click({ Show-PreviewSelected })
    $cm.Add_Opening({ param($s, $e) $n = $script:SP.Tv.SelectedNode; if (-not $n -or -not $n.Tag) { $e.Cancel = $true } })
    $tv.ContextMenuStrip = $cm

    # right: preview
    $sp.PvArea = New-Object Windows.Forms.Panel; $sp.PvArea.Dock = 'Fill'; $sp.PvArea.BackColor = $script:UiPanel
    $sp.Pic = New-Object Windows.Forms.PictureBox; $sp.Pic.Dock = 'Fill'; $sp.Pic.SizeMode = 'Zoom'; $sp.Pic.Visible = $false
    $sp.PvTxt = New-Object Windows.Forms.TextBox; $sp.PvTxt.Dock = 'Fill'; $sp.PvTxt.Multiline = $true; $sp.PvTxt.ReadOnly = $true; $sp.PvTxt.ScrollBars = 'Both'; $sp.PvTxt.WordWrap = $false; $sp.PvTxt.BackColor = $script:UiPanel; $sp.PvTxt.ForeColor = $script:UiText; $sp.PvTxt.Font = New-Object Drawing.Font('Consolas', 10); $sp.PvTxt.Visible = $false
    $sp.PvNote = New-Object Windows.Forms.Label; $sp.PvNote.Dock = 'Fill'; $sp.PvNote.TextAlign = 'MiddleCenter'; $sp.PvNote.ForeColor = $script:UiMuted; $sp.PvNote.UseMnemonic = $false; $sp.PvNote.Text = 'Click a file in the blue panel to see it here.'
    $sp.PvNote.Visible = $false
    # nothing to preview: show how much space has been saved so far, next to what can still be freed
    $sp.PvDonut = New-Object Windows.Forms.Panel; $sp.PvDonut.Dock = 'Fill'; $sp.PvDonut.BackColor = $script:UiPanel
    [void][Windows.Forms.Panel].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($sp.PvDonut, $true)
    $sp.PvDonut.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
        $w = $s.ClientSize.Width; $h = $s.ClientSize.Height; if ($w -lt 60 -or $h -lt 100) { return }
        $k = Get-Sc; $pad = [int](10 * $k)
        $bold = New-Object Drawing.Font($s.Font, [Drawing.FontStyle]::Bold); $big = New-Object Drawing.Font($s.Font.FontFamily, ($s.Font.Size * 1.05), [Drawing.FontStyle]::Bold)
        $txt = New-Object Drawing.SolidBrush $script:UiText; $dim = New-Object Drawing.SolidBrush $script:UiMuted
        $saved = [int64]$script:SavedTotal; $rest = 0L; foreach ($d in $script:ChartData) { $rest += $d.Bytes }
        $g.DrawString('Space saved', $bold, $txt, $pad, $pad)
        $top = $pad + [int]($bold.Height * 1.6)
        $size = [Math]::Max(60, [Math]::Min($w - 2 * $pad, [int](($h - $top) * 0.5))); $x = [int](($w - $size) / 2)
        $nowT = [Environment]::TickCount
        if (($nowT - $script:BucketAt) -gt 1000 -or ($nowT - $script:BucketAt) -lt 0) {   # space that keeping one copy frees, by score colour of the set
            $script:BucketAt = $nowT; $bk = @(0L, 0L, 0L)
            foreach ($st in $script:Results['Folder']) { $q = $script:SetPlan[$st]; if ($q) { $fr = [int64]$st.Size * ($st.Items.Count - 1); if ($q.Score -gt 90) { $bk[0] += $fr } elseif ($q.Score -ge 80) { $bk[1] += $fr } else { $bk[2] += $fr } } }
            $script:Buckets = $bk
        }
        $bk = $script:Buckets; $scored = $bk[0] + $bk[1] + $bk[2]; $unscored = [Math]::Max(0L, $rest - $scored)
        $cSaved = [Drawing.Color]::FromArgb(140, 110, 190)
        $parts = @(@($cSaved, 'Saved (removed so far)', $saved), @((Get-ScoreColor 95), 'Safe to free (above 90%)', $bk[0]), @((Get-ScoreColor 85), 'Check first (80-90%)', $bk[1]), @((Get-ScoreColor 50), 'Risky (below 80%)', $bk[2]), @($script:UiAccent, 'Not yet scored', $unscored))
        $tot = 0L; foreach ($pt in $parts) { $tot += [int64]$pt[2] }
        if ($tot -le 0) { $gb = New-Object Drawing.SolidBrush $script:UiLine; $g.FillEllipse($gb, $x, $top, $size, $size); $gb.Dispose() }
        else {
            $ang = -90.0; $nz = @($parts | Where-Object { [int64]$_[2] -gt 0 })
            foreach ($pt in $nz) {
                $pb = New-Object Drawing.SolidBrush $pt[0]
                if ($nz.Count -eq 1) { $g.FillEllipse($pb, $x, $top, $size, $size) } else { $sw = 360.0 * [int64]$pt[2] / $tot; $g.FillPie($pb, $x, $top, $size, $size, [single]$ang, [single]$sw); $ang += $sw }
                $pb.Dispose()
            }
        }
        $hole = [int]($size * 0.72); $hb = New-Object Drawing.SolidBrush $s.BackColor; $g.FillEllipse($hb, ($x + [int](($size - $hole) / 2)), ($top + [int](($size - $hole) / 2)), $hole, $hole); $hb.Dispose()
        $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'; $cy = $top + $size / 2
        $g.DrawString((Format-Size $saved), $big, $txt, [single]($x + $size / 2), [single]($cy - $big.Height * 0.3), $sf)
        $sm = New-Object Drawing.Font($s.Font.FontFamily, ($s.Font.Size * 0.8)); $g.DrawString('saved so far', $sm, $dim, [single]($x + $size / 2), [single]($cy + $big.Height * 0.55), $sf); $sm.Dispose()
        $ly = $top + $size + [int](14 * $k)
        foreach ($row in $parts) {
            if ($ly -gt $h - $s.Font.Height) { break }
            $lb = New-Object Drawing.SolidBrush $row[0]; $g.FillRectangle($lb, $pad, $ly + 4, [int](12 * $k), [int](12 * $k)); $lb.Dispose()
            $g.DrawString([string]$row[1], $s.Font, $txt, [single]($pad + 20 * $k), [single]$ly)
            $rf = New-Object Drawing.StringFormat; $rf.Alignment = 'Far'; $g.DrawString((Format-Size ([int64]$row[2])), $s.Font, $txt, (New-Object Drawing.RectangleF(0, [single]$ly, [single]($w - $pad), [single]($s.Font.Height + 4))), $rf); $rf.Dispose()
            $ly += [int]($s.Font.Height * 1.5)
        }
        if ($ly -le $h - $s.Font.Height) { $g.DrawString('Click a file in the blue panel to preview it here.', $s.Font, $dim, [single]$pad, [single]($ly + 6 * $k)) }
        $bold.Dispose(); $big.Dispose(); $txt.Dispose(); $dim.Dispose(); $sf.Dispose()
    })
    $sp.PvArea.Controls.AddRange(@($sp.Pic, $sp.PvTxt, $sp.PvNote, $sp.PvDonut))
    $sp.PvBtns = New-Object Windows.Forms.FlowLayoutPanel; $sp.PvBtns.Dock = 'Bottom'; $sp.PvBtns.AutoSize = $true; $sp.PvBtns.Visible = $false
    foreach ($def in @(@('Open', 'o'), @('Show in Explorer', 'e'), @('Bigger preview', 'b'))) {
        $b = New-Btn $def[0]; $b.MinimumSize = New-Object Drawing.Size(0, 0); $b.Tag = $def[1]; $sp.PvBtns.Controls.Add($b)
        $b.Add_Click({
            param($s, $e) $p = $script:SP.PvPath; if (-not $p) { return }
            switch ($s.Tag) {
                'o' { Open-File $p }
                'e' { Start-Process explorer.exe -ArgumentList "/select,`"$p`"" }
                'b' { Show-Preview $p ([bool]$script:SP.PvIsDir) '' }
            }
        })
    }
    $sp.PvMeta = New-Object Windows.Forms.Label; $sp.PvMeta.Dock = 'Top'; $sp.PvMeta.AutoSize = $false; $sp.PvMeta.Height = [int](26 * $sc); $sp.PvMeta.ForeColor = $script:UiMuted; $sp.PvMeta.UseMnemonic = $false
    $sp.PvHead = New-Object Windows.Forms.Label; $sp.PvHead.Dock = 'Top'; $sp.PvHead.AutoSize = $false; $sp.PvHead.Height = [int](28 * $sc); $sp.PvHead.AutoEllipsis = $true; $sp.PvHead.UseMnemonic = $false; $sp.PvHead.TextAlign = 'MiddleLeft'
    $sp.PvHead.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold); $sp.PvHead.Text = 'Preview'; $sp.PvHead.Visible = $false   # the selected file is already highlighted in the blue panel
    $split3.Panel2.Controls.Add($sp.PvArea); $split3.Panel2.Controls.Add($sp.PvBtns); $split3.Panel2.Controls.Add($sp.PvMeta); $split3.Panel2.Controls.Add($sp.PvHead)
    $sp.PvArea.Add_Click({ })

    # the filter bar of the old list stays hidden (its search and sort live in the left pane); only full screen and text size remain
    foreach ($c in $script:FolderBar.Controls) { if ($script:FolderBarKeep -notcontains $c) { $c.Visible = $false } }
    $lvF.Visible = $false
    $tp.Controls.Add($root); $tp.Controls.SetChildIndex($root, 1)   # the hidden list stays Controls[0] (code relies on it)
    Set-SpFonts
}
Add-SetsPanel
# a click anywhere outside the files panel (the blue INSIDE panel) unselects the file and clears its preview; its own buttons and the preview pane do not count as outside
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Windows.Forms;
public class ClickWatch : IMessageFilter {
    public Action<IntPtr> Down;
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern short GetAsyncKeyState(int k);
    public static bool EscDown() { return (GetAsyncKeyState(0x1B) & 0x8000) != 0; }
    public bool PreFilterMessage(ref Message m) { if (m.Msg == 0x201 && Down != null) { try { Down(m.HWnd); } catch { } } return false; }
}
"@
function Invoke-OutsideClick($h) {
    $sp = $script:SP; if (-not $sp -or -not $sp.Tv -or -not $sp.Tv.SelectedNode -or -not $sp.Tv.Visible) { return }
    $c = [Windows.Forms.Control]::FromHandle($h); if (-not $c) { return }
    $panel = $sp.Tv.Parent.Parent
    for ($x = $c; $x; $x = $x.Parent) { if ($x -eq $form) { break }; if (-not $x.Parent -and $x -ne $form) { return } }   # menus and other windows are not outside
    for ($x = $c; $x; $x = $x.Parent) { if ($x -eq $panel -or $x -eq $sp.PvArea -or $x -eq $sp.PvBtns) { return } }
    $script:SpPvTimer.Stop(); $sp.Tv.SelectedNode = $null; Show-Embedded $null $false
}
$script:ClickWatch = New-Object ClickWatch
$script:ClickWatch.Down = [Action[IntPtr]]{ param($h) Invoke-OutsideClick $h }
[Windows.Forms.Application]::AddMessageFilter($script:ClickWatch)

# ---- bottom: summary, keep buttons, action, apply/undo
$bottom = New-Table 2 3
$bottom.Dock = 'Top'; $bottom.AutoSize = $true; $bottom.AutoSizeMode = 'GrowAndShrink'
[void]$bottom.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
[void]$bottom.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
foreach ($i in 1..3) { [void]$bottom.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))) }
$root.Controls.Add($bottom, 0, 2)

$lblSum = New-Object Windows.Forms.Label
$lblSum.Text = 'No scan yet.'; $lblSum.AutoSize = $true; $lblSum.Margin = New-Object Windows.Forms.Padding(4, 8, 4, 4)
$bottom.Controls.Add($lblSum, 0, 0); $bottom.SetColumnSpan($lblSum, 2)

$fKeep = New-Flow 'LeftToRight'; $fKeep.WrapContents = $true
$btnKeep = New-Btn 'Keep selected (remove others in set)'
$btnAuto = New-Btn 'Reset to auto rule'
$btnAll = New-Btn 'Select all duplicates (keep oldest)' $true
$btnMore = New-Btn 'Show more sets'; $btnMore.Enabled = $false
$btnShowAll = New-Btn 'Show all sets'; $btnShowAll.Enabled = $false
$btnNone = New-Btn 'Select none (uncheck all)'
$btnVerify = New-Btn 'Verify duplicates...'
$btnPreview = New-Btn 'Preview (F3)'
$btnEvery = New-Btn 'Select EVERY copy (keep none)...'; $btnEvery.ForeColor = $script:UiDelFg
$fKeep.Controls.Add($btnEvery); $fKeep.Controls.Add($btnVerify); $fKeep.Controls.Add($btnPreview); $fKeep.Controls.Add($btnKeep); $fKeep.Controls.Add($btnAuto); $fKeep.Controls.Add($btnMore); $fKeep.Controls.Add($btnShowAll)
$script:ViewStep = 400
$script:ViewLimit = @{ File = $script:ViewStep; Folder = $script:ViewStep }
$script:SortBy = @{ File = $null; Folder = $null }   # @(column, ascending) once a header was clicked
$script:ColNames = @('Name', 'Location', 'Size', 'Modified', 'Action', 'Type')
$bottom.Controls.Add($fKeep, 0, 1); $bottom.SetColumnSpan($fKeep, 2)

$grp = New-Object Windows.Forms.GroupBox
$grp.Text = 'Action for checked items'; $grp.AutoSize = $true; $grp.AutoSizeMode = 'GrowAndShrink'
$grp.Dock = 'Fill'; $grp.Margin = New-Object Windows.Forms.Padding(4); $grp.Padding = New-Object Windows.Forms.Padding(8, 4, 8, 8)
$gt = New-Table 2 2
$gt.Dock = 'Fill'; $gt.AutoSize = $true; $gt.AutoSizeMode = 'GrowAndShrink'
[void]$gt.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
[void]$gt.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
[void]$gt.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
[void]$gt.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
$fRad = New-Flow 'LeftToRight'; $fRad.WrapContents = $true
$rbMove = New-Object Windows.Forms.RadioButton; $rbMove.Text = 'Move to quarantine folder (default, undoable)'; $rbMove.Checked = $true; $rbMove.AutoSize = $true
$rbRecycle = New-Object Windows.Forms.RadioButton; $rbRecycle.Text = 'Recycle Bin'; $rbRecycle.AutoSize = $true
$rbPerm = New-Object Windows.Forms.RadioButton; $rbPerm.Text = 'Permanent delete'; $rbPerm.AutoSize = $true
$fRad.Controls.AddRange(@($rbMove, $rbRecycle, $rbPerm))
$gt.Controls.Add($fRad, 0, 0); $gt.SetColumnSpan($fRad, 2)
$txtQ = New-Object Windows.Forms.TextBox; $txtQ.Text = $script:Quarantine; $txtQ.Dock = 'Fill'; $txtQ.Margin = New-Object Windows.Forms.Padding(4, 6, 4, 4)
$btnQ = New-Btn 'Browse...'
$gt.Controls.Add($txtQ, 0, 1); $gt.Controls.Add($btnQ, 1, 1)
[void]$gt.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))); $gt.RowCount = 3
$chkForce = New-Object Windows.Forms.CheckBox; $chkForce.Text = 'If a folder or file cannot be removed, force it (clear read-only / hidden flags, retry, long-path delete)'; $chkForce.AutoSize = $true; $chkForce.Checked = $true; $chkForce.Margin = New-Object Windows.Forms.Padding(4, 8, 4, 2)
$chkForce.Add_CheckedChanged({ $script:ForceDelete = $chkForce.Checked })
$gt.Controls.Add($chkForce, 0, 2); $gt.SetColumnSpan($chkForce, 2)
$grp.Controls.Add($gt)
$bottom.Controls.Add($grp, 0, 2)

$fGo = New-Flow 'TopDown'
$btnApply = New-Btn 'Apply...' $true; $btnApply.MinimumSize = New-Object Drawing.Size(150, 48); $btnApply.Enabled = $false
$btnUndo = New-Btn 'Undo a move...'; $btnUndo.MinimumSize = New-Object Drawing.Size(150, 0)
$btnRestoreList = New-Btn 'Restore list...'; $btnRestoreList.MinimumSize = New-Object Drawing.Size(150, 0)
$fGo.Controls.Add($btnApply); $fGo.Controls.Add($btnUndo); $fGo.Controls.Add($btnRestoreList)
$bottom.Controls.Add($fGo, 1, 2)

$script:BoldFont = New-Object Drawing.Font($form.Font, [Drawing.FontStyle]::Bold)   # created once, not per row

function Update-Row($lvi) {
    $it = $lvi.Tag
    if ($it.Nested) { $lvi.SubItems[4].Text = 'in parent'; $lvi.ForeColor = $script:UiMuted; $lvi.Font = $script:ListFont; return }
    if ($it.Remove) { $lvi.SubItems[4].Text = 'remove'; $lvi.ForeColor = $script:UiDelFg; $lvi.Font = $script:ListFont }
    else { $lvi.SubItems[4].Text = 'KEEP'; $lvi.ForeColor = $script:UiKeepFg; $lvi.Font = $script:ListBold }
}

$script:CatCache = @{}
function Get-Category([string]$path) {
    $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
    $hit = $script:CatCache[$ext]
    if ($hit) { return $hit }   # one regex pass per extension, not per file
    $cat = switch -Regex ($ext) {
        '^\.(jpe?g|png|gif|bmp|heic|webp|tiff?|raw|cr2|nef|arw|dng|psd)$' { 'Images'; break }
        '^\.(mp4|mov|avi|mkv|wmv|m4v|webm|mts)$' { 'Video'; break }
        '^\.(mp3|wav|flac|m4a|aac|ogg|wma)$' { 'Audio'; break }
        '^\.(pdf|docx?|xlsx?|pptx?|txt|odt|csv|rtf|md)$' { 'Documents'; break }
        '^\.(zip|rar|7z|gz|tar|iso|exe|msi|apk|jar)$' { 'Archives'; break }
        default { 'Other' }
    }
    $script:CatCache[$ext] = $cat
    return $cat
}

$script:ChartGap = 500L
$script:SumCache = @{}   # per tab: totals + chart, so switching tabs does not re-add up every item
function Update-Chart($kind, $g) {
    if ($script:Scanning -and ($script:ChartClock.ElapsedMilliseconds - $script:ChartLast) -lt $script:ChartGap) { return }
    $script:ChartLast = $script:ChartClock.ElapsedMilliseconds
    $chartStart = $script:ChartLast
    $rows = @{}
    $per = New-Object 'System.Collections.Generic.List[object]'
    $n = 0; $tn = 0; $tb = 0L
    $isFile = ($kind -eq 'File'); $cc = $script:CatCache
    foreach ($set in $g) {
        $n++; $sum = 0L
        foreach ($it in $set.Items) {
            if (-not $it.Remove) { continue }
            $len = $it.Length; $sum += $len; $tn++; $tb += $len
            if ($isFile) {
                $c = $cc[[IO.Path]::GetExtension($it.Path).ToLowerInvariant()]
                if (-not $c) { $c = Get-Category $it.Path }
                $rows[$c] = [int64]$rows[$c] + $len
            }
        }
        if ($kind -eq 'Folder' -and $sum -gt 0) { $per.Add([pscustomobject]@{ Label = "Set $n  ($([IO.Path]::GetFileName($set.Items[0].Path)))"; Bytes = $sum }) }
    }
    $data = @()
    if ($kind -eq 'File') {
        $data = @($rows.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [pscustomobject]@{ Label = $_.Key; Bytes = [int64]$_.Value } })
        $script:ChartTitle = 'by file type'
    } else {
        $sorted = @($per | Sort-Object Bytes -Descending)
        $data = @($sorted | Select-Object -First 6)
        $rest = 0L; foreach ($x in ($sorted | Select-Object -Skip 6)) { $rest += $x.Bytes }
        if ($rest -gt 0) { $data += [pscustomobject]@{ Label = "$($sorted.Count - 6) other sets"; Bytes = $rest } }
        $script:ChartTitle = 'by folder set'
    }
    $script:ChartData = $data; try { if ($script:SP -and $script:SP.PvDonut) { $script:SP.PvDonut.Invalidate() } } catch { Write-ErrLog $_ }
    $script:SumCache[$kind] = @{ N = $tn; B = $tb; Data = $data; Title = $script:ChartTitle }
    $chart.Invalidate()
    $script:ChartGap = [math]::Max(500L, 8L * ($script:ChartClock.ElapsedMilliseconds - $chartStart))   # back off as results grow
}

# The totals and the chart add up every item of every set (100,000 sets take seconds), so a burst of clicks asks for ONE refresh.
$script:SumTimer = New-Object Windows.Forms.Timer; $script:SumTimer.Interval = 300
$script:SumReuse = $true
$script:SumTimer.Add_Tick({ $script:SumTimer.Stop(); $r = $script:SumReuse; $script:SumReuse = $true; Update-Summary $r })
# $changed = something was checked/unchecked, so the saved totals are out of date; a plain tab switch reuses them
function Request-Summary([bool]$changed = $true) { if ($changed) { $script:SumReuse = $false }; $script:SumTimer.Stop(); $script:SumTimer.Start() }

function Update-Summary([bool]$reuse = $false) {
    $lv = $tabs.SelectedTab.Controls[0]; $kind = $lv.Tag
    $g = $script:Results[$kind]
    if ($kind -eq 'Folder') { Update-SetsPanel }   # the three-pane Folders tab shows the same KEEP/delete marks
    if ($null -eq $g) { Update-Ticks $null 0; $lblSum.Text = 'No scan yet.'; $btnApply.Enabled = $false; $script:ChartData = @(); $chart.Invalidate(); return }
    if (-not ($reuse -and $script:SumCache[$kind] -and -not $script:Scanning)) { Update-Chart $kind $g }
    $c = $script:SumCache[$kind]
    if ($c) { $script:ChartData = $c.Data; $script:ChartTitle = $c.Title; $chart.Invalidate(); try { if ($script:SP -and $script:SP.PvDonut) { $script:SP.PvDonut.Invalidate() } } catch { Write-ErrLog $_ }; $n = $c.N; $bytes = $c.B }
    else { $n = 0; $bytes = 0L }
    $live = if ($script:Scanning) { ' (scan still running - results update live)' } else { '' }
    $flt = $script:FilterText[$kind]
    $matched = $g.Count; if ($flt) { $matched = $script:MatchCount[$kind] }
    $fltNote = if ($flt) { " Filter ""$flt"": $matched set(s) match." } else { '' }
    $lblSum.Text = "$($g.Count) duplicate set(s).$fltNote Checked for removal: $n item(s) in all sets, frees about $(Format-Size $bytes).$live"
    $btnApply.Enabled = ($n -gt 0 -and -not $script:Scanning)
    Update-Ticks $g $n
    $lim = $script:ViewLimit[$kind]
    if ($matched -gt $lim) {
        $order = 'largest first'
        if ($script:SortBy[$kind]) { $order = "sorted by $($script:ColNames[$script:SortBy[$kind][0]]), $(if ($script:SortBy[$kind][1]) { 'ascending' } else { 'descending' })" }
        $lblSum.Text += "  Showing the first $lim of $matched sets ($order); selection and Apply still cover all sets."
        $btnMore.Enabled = $true; $btnMore.Text = "Show $([math]::Min($script:ViewStep, $matched - $lim)) more sets"
        $btnShowAll.Enabled = $true; $btnShowAll.Text = "Show all $matched sets"
    } else { $btnMore.Enabled = $false; $btnMore.Text = 'Show more sets'; $btnShowAll.Enabled = $false; $btnShowAll.Text = 'Show all sets' }
}

$script:Pending = New-Object 'System.Collections.Generic.List[object]'
$script:LastFlush = 0L; $script:FlushGap = 800L
function Send-Pending([bool]$force = $false) {
    # newly found sets are shown in batches: one list refresh per batch instead of one per set
    if ($script:Pending.Count -eq 0) { return }
    if (-not $force -and ($script:Clock.ElapsedMilliseconds - $script:LastFlush) -lt $script:FlushGap) { return }
    $script:LastFlush = $script:Clock.ElapsedMilliseconds
    $flushStart = $script:LastFlush
    $batch = $script:Pending.ToArray(); $script:Pending.Clear()
    foreach ($k in 'File', 'Folder') { $views[$k].BeginUpdate() }
    try { foreach ($b in $batch) { if ($b[2] -le $script:ViewLimit[$b[0]]) { Add-GroupToView $b[0] $b[1] $b[2] } } }
    finally { foreach ($k in 'File', 'Folder') { $views[$k].EndUpdate() } }
    Update-Summary
    $script:FlushGap = [math]::Max(800L, 8L * ($script:Clock.ElapsedMilliseconds - $flushStart))   # never spend more than ~1/9 of the time refreshing
}

function Add-GroupToView($kind, $set, [int]$i, [bool]$nested = $false) {
    $lv = $views[$kind]
    $wasBusy = $script:Busy; $script:Busy = $true
    $lv.BeginUpdate()
    $title = "Set $i  -  $($set.Items.Count) identical $($kind.ToLower())s, $(Format-Size $set.Size) each"
    if ($nested) { $title = "Sub-folder set $i  -  $($set.Items.Count) identical folders, $(Format-Size $set.Size) each  (inside duplicate parent folders - handled by the parent set, shown for searching only)" }
    $lg = New-Object Windows.Forms.ListViewGroup($title)
    $lg.Tag = New-Object 'System.Collections.Generic.List[object]'
    [void]$lv.Groups.Add($lg)
    foreach ($it in $set.Items) {
        $lvi = New-Object Windows.Forms.ListViewItem([IO.Path]::GetFileName($it.Path))
        [void]$lvi.SubItems.Add([IO.Path]::GetDirectoryName($it.Path))
        [void]$lvi.SubItems.Add((Format-Size $it.Length))
        [void]$lvi.SubItems.Add($it.Modified.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))
        [void]$lvi.SubItems.Add('')
        [void]$lvi.SubItems.Add($(if ($kind -eq 'Folder') { 'Folder' } else { Get-Category $it.Path }))   # same file types as the chart
        $lvi.Tag = $it; $lvi.Group = $lg; $lvi.Checked = [bool]$it.Remove
        [void]$lv.Items.Add($lvi); $lg.Tag.Add($lvi)
        Update-Row $lvi
    }
    $lv.EndUpdate()
    $script:Busy = $wasBusy
}

function Show-Results($kind) {
    $lv = $views[$kind]; $g = $script:Results[$kind]
    $script:Busy = $true
    $lv.BeginUpdate(); $lv.Items.Clear(); $lv.Groups.Clear(); $lv.EndUpdate()
    $i = 0
    $lim = $script:ViewLimit[$kind]
    $crit = $script:Crit[$kind]; $active = [bool]($script:FilterText[$kind] -and $crit)
    $shown = 0; $matched = 0
    $lv.BeginUpdate()
    $script:FilterAbort = $false; if ($active) { $script:Filtering = $true }
    foreach ($set in $g) {
        $i++
        if ($active) {
            # searching 100,000 sets takes a while: keep the window alive, and stop early when the filter was changed again
            if (($i % 1000) -eq 0) {
                [Windows.Forms.Application]::DoEvents()
                if ($script:FilterAbort -or $form.IsDisposed) { $script:FilterText[$kind] = '~aborted'; break }
            }
            if (-not (Test-SetMatch $set $crit)) { continue }
            $matched++
        } elseif ($i -gt $lim) { break }
        if ($shown -lt $lim) { Add-GroupToView $kind $set $i; $shown++ }   # "Set N" keeps the number from the full list
    }
    if ($active -and $kind -eq 'Folder' -and $script:Results['Nested']) {
        # with a filter active, also list the matching sub-folder sets that sit inside duplicate parent folders
        $j = 0; $nShown = 0
        foreach ($set in $script:Results['Nested']) {
            $j++
            if (-not (Test-SetMatch $set $crit)) { continue }
            $matched++
            if ($nShown -lt $lim) { Add-GroupToView $kind $set $j $true; $nShown++ }
        }
    }
    $lv.EndUpdate()
    $script:Filtering = $false
    $script:MatchCount[$kind] = if ($active) { $matched } else { if ($g) { $g.Count } else { 0 } }
    $script:Busy = $false
    Update-Summary
}

$script:FilterTimer.Add_Tick({
    $script:FilterTimer.Stop()
    $kind = $script:FilterKind
    if ($script:Scanning) { return }
    if ($script:Filtering) { $script:FilterAbort = $true; $script:FilterTimer.Start(); return }   # a search is still running: stop it, then search again
    $crit = Get-FilterCrit $kind
    if ($crit.Desc -eq $script:FilterText[$kind]) { return }
    $script:FilterText[$kind] = $crit.Desc; $script:Crit[$kind] = $crit
    $script:ViewLimit[$kind] = $script:ViewStep
    if ($script:Results[$kind]) {
        $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
        try { Show-Results $kind } finally { $script:Filtering = $false; $form.Cursor = [Windows.Forms.Cursors]::Default }
    }
})

function Set-SortHeaders($kind) {
    $st = $script:SortBy[$kind]
    for ($c = 0; $c -lt $script:ColNames.Count; $c++) {
        $t = $script:ColNames[$c]
        if ($st -and $st[0] -eq $c) { $t += $(if ($st[1]) { '  ' + [char]0x25B2 } else { '  ' + [char]0x25BC }) }
        $views[$kind].Columns[$c].Text = $t
    }
}
function Reset-Sort($kind) { $script:SortBy[$kind] = $null; Set-SortHeaders $kind }

function Sort-Results($kind, [int]$col) {
    # sorts whole duplicate SETS by their first (kept) copy; files inside a set keep the keep-rule order
    $g = $script:Results[$kind]
    if (-not $g -or $g.Count -lt 2) { return }
    $asc = $true
    $st = $script:SortBy[$kind]
    if ($st -and $st[0] -eq $col) { $asc = -not $st[1] }
    $script:SortBy[$kind] = @($col, $asc)
    $keyed = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $g) {
        $f = $s.Items[0]
        $k = switch ($col) {
            0 { [IO.Path]::GetFileName($f.Path).ToLowerInvariant() }
            1 { ([IO.Path]::GetDirectoryName($f.Path) + '').ToLowerInvariant() }
            2 { [int64]$s.Size }
            3 { $f.Modified }
            5 { if ($kind -eq 'Folder') { 'folder' } else { (Get-Category $f.Path).ToLowerInvariant() } }
            default { $n = 0; foreach ($it in $s.Items) { if ($it.Remove) { $n++ } }; $n }
        }
        $keyed.Add([pscustomobject]@{ K = $k; S = $s })
    }
    $sorted = @($keyed | Sort-Object -Property K -Descending:(-not $asc))
    $g.Clear()
    foreach ($x in $sorted) { $g.Add($x.S) }
    Set-SortHeaders $kind
    Show-Results $kind
}

function Set-Keeper($lvi) {
    if ($lvi.Tag.Nested) { $lblStatus.Text = 'Sub-folder sets are read-only: choose the keeper in the parent set.'; return }
    $script:Busy = $true
    foreach ($o in $lvi.Group.Tag) { $o.Tag.Remove = ($o -ne $lvi); $o.Checked = [bool]$o.Tag.Remove; Update-Row $o }
    $script:Busy = $false
    Request-Summary
}

foreach ($kind in 'File', 'Folder') {
    $lv = $views[$kind]
    $lv.Add_ItemChecked({
        param($s, $e)
        if ($script:Busy) { return }
        $lvi = $e.Item
        if ($lvi.Tag.Nested) {   # sub-folder sets are read-only: removing the parent set already covers them
            if ($lvi.Checked) { $script:Busy = $true; $lvi.Checked = $false; $script:Busy = $false; $lblStatus.Text = 'Sub-folder sets cannot be selected: they are removed with their parent folder (see the parent set).' }
            return
        }
        $lvi.Tag.Remove = $lvi.Checked
        $all = $true; foreach ($o in $lvi.Group.Tag) { if (-not $o.Tag.Remove) { $all = $false } }
        if ($all) {   # every copy of the set would go: allowed, but only after an explicit warning
            $a = [Windows.Forms.MessageBox]::Show("WARNING: this ticks the LAST remaining copy of this set.`n`nIf you apply, NO copy of this $($lvi.ListView.Tag.ToLower()) will be left - it is gone from every location.`n`nKeep it ticked?", 'Delete every copy?', 'YesNo', 'Warning', 'Button2')
            if ($a -ne 'Yes') { $script:Busy = $true; $lvi.Checked = $false; $lvi.Tag.Remove = $false; $script:Busy = $false }
        }
        Update-Row $lvi; Request-Summary
    })
    $lv.Add_SelectedIndexChanged({ if ($script:Pv -and $script:Pv.Form.Visible) { $script:PvTimer.Stop(); $script:PvTimer.Start() } })
    $lv.Add_DoubleClick({ param($s, $e) if ($s.SelectedItems.Count) { Set-Keeper $s.SelectedItems[0] } })
    $lv.Add_ColumnClick({
        param($s, $e)
        if ($script:Scanning) { $lblStatus.Text = 'Sorting is available when the scan has finished (or is cancelled).'; return }
        $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
        try { Sort-Results $s.Tag $e.Column } finally { $form.Cursor = [Windows.Forms.Cursors]::Default }
    })
}
$tabs.Add_SelectedIndexChanged({ Request-Summary $false })
$btnKeep.Add_Click({
    $lv = $tabs.SelectedTab.Controls[0]
    if ($script:SP -and $lv.Tag -eq 'Folder') { if ($script:SpBrowse) { Set-OnlyKeep $script:SpBrowse }; return }   # Folders tab: keep the copy whose contents are shown
    if ($lv.SelectedItems.Count) { Set-Keeper $lv.SelectedItems[0] }
})
# the sets a selection button works on: all sets, or only the ones the filter shows when a filter is active
function Get-TargetSets($kind) {
    $g = $script:Results[$kind]; $crit = $script:Crit[$kind]
    if ($g -and $script:FilterText[$kind] -and $crit) {
        $o = New-Object 'System.Collections.Generic.List[object]'
        foreach ($s in $g) { if (Test-SetMatch $s $crit) { $o.Add($s) } }
        return ,$o
    }
    return ,$g
}
function Get-ScopeNote($kind, $target) {
    $g = $script:Results[$kind]; if ($g -and $target -and $target.Count -ne $g.Count) { return " (filter active: only the $($target.Count) matching set(s) of $($g.Count) were changed)" }
    return ''
}
$btnAuto.Add_Click({
    $kind = $tabs.SelectedTab.Controls[0].Tag
    if ($script:Results[$kind]) {
        $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
        try {
            $target = Get-TargetSets $kind
            foreach ($g in $target) { $i = 0; foreach ($it in $g.Items) { $it.Remove = ($i -gt 0); $i++ } }
            Show-Results $kind
            $lblStatus.Text = "Reset to the auto rule$(Get-ScopeNote $kind $target)."
        } finally { $form.Cursor = [Windows.Forms.Cursors]::Default }
    }
})

function Add-Root($p) { if ($p -and (Test-Path -LiteralPath $p -PathType Container) -and -not $lstRoots.Items.Contains($p)) { [void]$lstRoots.Items.Add($p) } }
$btnAdd.Add_Click({ $d = New-Object Windows.Forms.FolderBrowserDialog; if ($d.ShowDialog() -eq 'OK') { Add-Root $d.SelectedPath } })
$btnRem.Add_Click({ if ($lstRoots.SelectedIndex -ge 0) { $lstRoots.Items.RemoveAt($lstRoots.SelectedIndex) } })
$lstRoots.Add_DragEnter({ param($s, $e) if ($e.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $e.Effect = 'Copy' } })
$lstRoots.Add_DragDrop({ param($s, $e) foreach ($p in $e.Data.GetData([Windows.Forms.DataFormats]::FileDrop)) { Add-Root $p } })
$btnQ.Add_Click({ $d = New-Object Windows.Forms.FolderBrowserDialog; $d.SelectedPath = $txtQ.Text; if ($d.ShowDialog() -eq 'OK') { $txtQ.Text = $d.SelectedPath } })
$btnAll.Add_Click({
    if ($script:Scanning) { [void][Windows.Forms.MessageBox]::Show('Wait for the scan to finish (or cancel it) first.', 'DupCleaner'); return }
    $folders = $script:Results['Folder']; $files = $script:Results['File']
    if (-not $folders -and -not $files) { return }
    $removed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $nFolders = 0; $nFiles = 0
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try {
    $tFolders = Get-TargetSets 'Folder'; $tFiles = Get-TargetSets 'File'
    # 1) folders: keep the oldest folder in every set, select the rest (only the sets the Folders filter shows)
    foreach ($g in $tFolders) {
        $i = 0
        foreach ($it in $g.Items) { $it.Remove = ($i -gt 0); if ($i -gt 0) { $nFolders++ }; $i++ }
    }
    foreach ($g in $folders) { foreach ($it in $g.Items) { if ($it.Remove) { [void]$removed.Add($it.Path.TrimEnd('\')) } } }   # every selected folder, also from earlier selections
    # 2) files: everything inside a selected folder goes with it; of the rest keep only the oldest (only the sets the Files filter shows)
    foreach ($g in $tFiles) {
        $keeper = $null
        foreach ($it in $g.Items) {
            $doomed = $false
            $d = [IO.Path]::GetDirectoryName($it.Path)
            while ($d) { if ($removed.Contains($d)) { $doomed = $true; break }; $d = [IO.Path]::GetDirectoryName($d) }
            if ($doomed -or $keeper) { $it.Remove = $true; $nFiles++ } else { $it.Remove = $false; $keeper = $it }
        }
        if (-not $keeper) { $g.Items[0].Remove = $false; $nFiles-- }
    }
    foreach ($k in 'File', 'Folder') { if ($script:Results[$k]) { Show-Results $k } }
    $note = ''
    if ($tFolders.Count -ne $folders.Count -or $tFiles.Count -ne $files.Count) { $note = " Filter active: only the matching sets were changed (Folders $($tFolders.Count) of $($folders.Count), Files $($tFiles.Count) of $($files.Count))." }
    $lblStatus.Text = "Selected $nFolders duplicate folder(s) and $nFiles file(s). The oldest copy of every set stays unselected.$note Tip: apply the Folders tab first, then the Files tab."
    } finally { $form.Cursor = [Windows.Forms.Cursors]::Default }
})
$btnNone.Add_Click({
    if ($script:Scanning) { [void][Windows.Forms.MessageBox]::Show('Wait for the scan to finish (or cancel it) first.', 'DupCleaner'); return }
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try {
        $note = ''
        foreach ($k in 'File', 'Folder') {
            if ($script:Results[$k]) {
                $target = Get-TargetSets $k
                foreach ($g in $target) { foreach ($it in $g.Items) { $it.Remove = $false } }
                Show-Results $k
                if ($target.Count -ne $script:Results[$k].Count) { $note += " $k tab: only the $($target.Count) matching set(s) of $($script:Results[$k].Count) were cleared." }
            }
        }
        $lblStatus.Text = $(if ($note) { "Filter active:$note" } else { 'Nothing is selected now: no file or folder will be moved. Tick items yourself, or use "Select all duplicates" / "Reset to auto rule".' })
    } finally { $form.Cursor = [Windows.Forms.Cursors]::Default }
})
$btnEvery.Add_Click({
    if ($script:Scanning) { [void][Windows.Forms.MessageBox]::Show('Wait for the scan to finish (or cancel it) first.', 'DupCleaner'); return }
    $kind = $tabs.SelectedTab.Controls[0].Tag
    if (-not $script:Results[$kind]) { return }
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try {
        $target = Get-TargetSets $kind
        $nSets = $target.Count; $nItems = 0; foreach ($g in $target) { foreach ($it in $g.Items) { $nItems++ } }
        if ($nSets -eq 0) { return }
        $scope = if ($nSets -ne $script:Results[$kind].Count) { "the $nSets set(s) the filter shows" } else { "ALL $nSets set(s)" }
        $form.Cursor = [Windows.Forms.Cursors]::Default
        $a = [Windows.Forms.MessageBox]::Show("WARNING: this ticks EVERY copy ($nItems $($kind.ToLower())(s)) in $scope - no copy will be kept.`n`nIf you then press Apply, these $($kind.ToLower())s are gone from every location (use 'Move' mode if you want to be able to undo).`n`nTick every copy?", 'Delete every copy?', 'YesNo', 'Warning', 'Button2')
        if ($a -ne 'Yes') { return }
        $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
        foreach ($g in $target) { foreach ($it in $g.Items) { if (-not $it.Nested) { $it.Remove = $true } } }
        Show-Results $kind
        $lblStatus.Text = "EVERY copy is ticked in $scope. Nothing of these sets will be left after Apply. Use 'Select none' or 'Reset to auto rule' to undo."
    } finally { $form.Cursor = [Windows.Forms.Cursors]::Default }
})
$btnCancel.Add_Click({ $script:Cancel = $true; $script:Paused = $false; $btnPause.Text = 'Pause' })
$btnMore.Add_Click({
    $kind = $tabs.SelectedTab.Controls[0].Tag
    $script:ViewLimit[$kind] += $script:ViewStep
    Show-Results $kind
})
$btnShowAll.Add_Click({
    $kind = $tabs.SelectedTab.Controls[0].Tag
    $g = $script:Results[$kind]; if (-not $g) { return }
    $cnt = $g.Count; if ($script:FilterText[$kind]) { $cnt = $script:MatchCount[$kind] }
    if ($cnt -gt 3000) {
        $a = [Windows.Forms.MessageBox]::Show("Showing all $cnt sets can take a while and make the list slow. Continue?", 'DupCleaner', 'YesNo', 'Question')
        if ($a -ne 'Yes') { return }
    }
    $script:ViewLimit[$kind] = [int]$g.Count
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try { Show-Results $kind } finally { $form.Cursor = [Windows.Forms.Cursors]::Default }
})
$btnPause.Add_Click({
    $script:Paused = -not $script:Paused
    $btnPause.Text = if ($script:Paused) { 'Resume' } else { 'Pause' }
    if ($script:Paused) { $lblStatus.Text = 'Pausing...' }
})

$script:SessionFile = Join-Path $env:LOCALAPPDATA 'DupCleaner\last-session.json'

function Save-Session {
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path $script:SessionFile))
        $o = [ordered]@{
            Saved = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Partial = [bool]$script:Scanning
            Roots = @($lstRoots.Items)
            Opts = @{ Files = $chkFiles.Checked; Folders = $chkFolders.Checked; Excl = $chkExcl.Checked; Place = $chkPlace.Checked; MinKB = [int]$numMin.Value; Quarantine = $txtQ.Text }
            Results = @{}
        }
        foreach ($k in 'File', 'Folder', 'Nested') {
            # plain .NET collections and explicit casts: PowerShell-wrapped objects confuse JavaScriptSerializer
            $o.Results[$k] = [SessionBuild]::ToDicts($script:Results[$k])
        }
        Add-Type -AssemblyName System.Web.Extensions
        $ser = New-Object Web.Script.Serialization.JavaScriptSerializer; $ser.MaxJsonLength = [int]::MaxValue; $ser.RecursionLimit = 100
        $tmp = $script:SessionFile + '.tmp'   # write beside, then swap: a kill mid-write never corrupts the saved session
        [IO.File]::WriteAllText($tmp, $ser.Serialize($o), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $script:SessionFile -Force
        Set-Saved 'res' $(if ($script:Scanning) { ' (partial)' } else { '' })
    } catch { Write-CrashLog 'Save-Session failed' $_.Exception; Set-Saved 'res' '' ('results: ' + $_.Exception.Message) }
}

# While a scan runs, the duplicates found so far are saved every couple of minutes (marked "partial"), so a crash
# or kill loses little. The gap grows with the cost of a save so a huge result list never slows the scan down.
$script:LastSessionSave = 0L; $script:SessionGap = 120000L; $script:CanSavePartial = $true
function Save-PartialSession {
    if (-not $script:Scanning -or $script:Paused) { return }
    if (($script:CacheClock.ElapsedMilliseconds - $script:LastSessionSave) -lt $script:SessionGap) { return }
    $t0 = $script:CacheClock.ElapsedMilliseconds
    $script:LastSessionSave = $t0
    $n = 0; foreach ($k in 'File', 'Folder') { if ($script:Results[$k]) { $n += $script:Results[$k].Count } }
    if ($n -eq 0) { return }   # nothing found yet: keep the previous session file untouched
    Save-Session
    $script:SessionGap = [math]::Max(120000L, 20L * ($script:CacheClock.ElapsedMilliseconds - $t0))
}

# ---- saved lists: every finished scan keeps a dated copy of its results, so an older list can be brought back later
$script:ListDir = Join-Path $env:LOCALAPPDATA 'DupCleaner\saved-lists'
$script:KeepLists = 8
function Get-ListInfo([string]$path) {   # reads only the first few KB: lists can be tens of MB
    $fi = Get-Item -LiteralPath $path; $head = ''
    try { $fs = [IO.File]::OpenRead($path); try { $b = New-Object byte[] 4096; $n = $fs.Read($b, 0, 4096); $head = [Text.Encoding]::UTF8.GetString($b, 0, $n) } finally { $fs.Dispose() } } catch { Write-ErrLog $_ }
    $saved = if ($head -match '"Saved":"([^"]+)"') { $Matches[1] } else { $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
    $roots = ''; if ($head -match '"Roots":\[(.*?)\]') { $roots = (($Matches[1] -replace '"', '') -replace '\\\\', '\') -replace ',', '  |  ' }
    [pscustomobject]@{ Path = $fi.FullName; Name = $fi.Name; Saved = $saved; Partial = [bool]($head -match '"Partial":true'); Roots = $roots; SizeMB = [math]::Round($fi.Length / 1MB, 1) }
}
function Save-ListArchive([string]$src) {
    try {
        if (-not (Test-Path -LiteralPath $src)) { return }
        $i = Get-ListInfo $src
        if ($i.Partial) { return }
        [void][IO.Directory]::CreateDirectory($script:ListDir)
        $first = ($i.Roots -split '\s+\|\s+')[0]; $leaf = if ($first) { Split-Path $first -Leaf } else { 'list' }
        if (-not $leaf) { $leaf = 'drive' }
        $leaf = ($leaf -replace '[\\/:*?"<>|]', '_')
        $dest = Join-Path $script:ListDir ((($i.Saved -replace ':', '-') -replace ' ', '_') + ' ' + $leaf + '.json')
        if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $src -Destination $dest }
        $old = @(Get-ChildItem -LiteralPath $script:ListDir -Filter '*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -Skip $script:KeepLists)
        foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    } catch { Write-CrashLog 'Save-ListArchive failed' $_.Exception }
}

function Select-ResultsTab {   # open the sub-tab that has duplicates: folders first when both have some
    try {
        $nF = 0; if ($script:Results['Folder']) { $nF = $script:Results['Folder'].Count }
        $nI = 0; if ($script:Results['File']) { $nI = $script:Results['File'].Count }
        $i = $(if ($nF -gt 0) { 1 } elseif ($nI -gt 0) { 0 } else { -1 })
        if ($i -ge 0 -and $tabs.SelectedIndex -ne $i) { $tabs.SelectedIndex = $i }
    } catch { Write-ErrLog $_ }
}function Restore-Session([string]$file = '', [bool]$manual = $false) {
    if (-not $file) { $file = $script:SessionFile }
    if (-not (Test-Path -LiteralPath $file)) { return }
    $what = if ($manual) { 'saved list' } else { 'last session' }
    # Everything is switched off while a list is restored: the window must keep repainting (DoEvents), and a click on a tab,
    # a checkbox or a button in the middle of the restore started heavy work on half-built lists and froze the window.
    $root.Enabled = $false
    try {
        $lblStatus.Text = "Restoring your $what... please wait, the window is locked until it is done"; [Windows.Forms.Application]::DoEvents()
        $checked = 0; $allItems = 0; $swR = [Diagnostics.Stopwatch]::StartNew(); $tm = @{}
        # JavaScriptSerializer parses a multi-MB session in well under a second; ConvertFrom-Json takes many seconds
        Add-Type -AssemblyName System.Web.Extensions
        $ser = New-Object Web.Script.Serialization.JavaScriptSerializer; $ser.MaxJsonLength = [int]::MaxValue; $ser.RecursionLimit = 100
        $txt = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8); $tm.Read = $swR.Elapsed.TotalSeconds
        $o = $ser.DeserializeObject($txt); $txt = $null; $tm.Parse = $swR.Elapsed.TotalSeconds
        foreach ($k in 'File', 'Folder', 'Nested') { foreach ($g in $o.Results.$k) { $allItems += $g.Items.Count } }
        if ($manual) { $lstRoots.Items.Clear() }
        foreach ($r in $o.Roots) { Add-Root $r }
        $chkFiles.Checked = [bool]$o.Opts.Files; $chkFolders.Checked = [bool]$o.Opts.Folders
        $chkExcl.Checked = [bool]$o.Opts.Excl; $chkPlace.Checked = [bool]$o.Opts.Place
        $numMin.Value = [int]$o.Opts.MinKB; if ($o.Opts.Quarantine) { $txtQ.Text = $o.Opts.Quarantine }
        $script:Results = @{ File = (New-Object 'System.Collections.Generic.List[object]'); Folder = (New-Object 'System.Collections.Generic.List[object]'); Nested = (New-Object 'System.Collections.Generic.List[object]') }
        Reset-Sort 'File'; Reset-Sort 'Folder'
        $gone = 0; $sets = 0; $tm.Prep = $swR.Elapsed.TotalSeconds; $tShow = 0.0
        [SessionBuild]::Gone = 0
        $script:RsBase = 0L; $script:RsTotal = [math]::Max(1, $allItems); $script:RsWhat = $what
        $cb = [Action[int]]{ param($n) $c = [int64]$n + $script:RsBase; $lblStatus.Text = "Restoring your $($script:RsWhat)... checked $c of $($script:RsTotal) items ($([int](100.0 * $c / $script:RsTotal))%) - please wait" }
        foreach ($k in 'File', 'Folder', 'Nested') {
            $built = [SessionBuild]::Build($o.Results.$k, $k, ($k -eq 'Nested'), $cb, [int64]$allItems, $false)
            $script:Results[$k] = $built
            if ($k -ne 'Nested') { $sets += $built.Count }
            foreach ($g0 in $o.Results.$k) { $script:RsBase += $g0.Items.Count }
            $gone = [SessionBuild]::Gone
            if ($k -ne 'Nested') { $t0 = $swR.Elapsed.TotalSeconds; Show-Results $k; $tShow += ($swR.Elapsed.TotalSeconds - $t0) }
        }
        Write-CrashLog 'Timing' ("Restore of $what ($allItems items): read file {0:N1}s, parse {1:N1}s, prepare {2:N1}s, check+build {3:N1}s (showing the lists {4:N1}s), total {5:N1}s" -f $tm.Read, ($tm.Parse - $tm.Read), ($tm.Prep - $tm.Parse), ($swR.Elapsed.TotalSeconds - $tm.Prep - $tShow), $tShow, $swR.Elapsed.TotalSeconds)
        $note = if ($o.Partial) { ' That scan was interrupted, so results are partial - press Scan to complete them.' } else { '' }
        $lblStatus.Text = "Restored your $what ($($o.Saved)): $sets set(s). Files are not re-checked on loading (that took minutes on the USB disk): Apply and 'Verify duplicates' check every file first.$note"
        Update-Summary; Select-ResultsTab
    } catch {
        Write-CrashLog 'Restore-Session failed' ("$($_.Exception.ToString())`r`n$($_.InvocationInfo.PositionMessage)")
        try { Copy-Item -LiteralPath $file -Destination ($script:SessionFile + '.failed') -Force } catch { Write-ErrLog $_ }   # keep the file for diagnosis
        $lblStatus.Text = "Could not restore the $what. Details are in $script:LogPath"
    } finally { $root.Enabled = $true }
}

function Show-RestoreListDialog {
    if ($script:Scanning) { [void][Windows.Forms.MessageBox]::Show('Wait until the scan has finished (or cancel it) before restoring a list.', 'DupCleaner'); return }
    $cands = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in (Split-Path $script:SessionFile), $script:ListDir) {
        if (Test-Path -LiteralPath $d) {
            foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter '*.json' -File -ErrorAction SilentlyContinue)) { try { $cands.Add((Get-ListInfo $f.FullName)) } catch { Write-ErrLog $_ } }
        }
    }
    $sc = $form.DeviceDpi / 96.0
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'Restore a saved list'; $dlg.StartPosition = 'CenterParent'; $dlg.Font = $form.Font
    $dlg.ClientSize = New-Object Drawing.Size([int](1100 * $sc), [int](460 * $sc)); $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false; $dlg.ShowInTaskbar = $false
    $hint = New-Object Windows.Forms.Label; $hint.Dock = 'Top'; $hint.AutoSize = $false; $hint.Height = [int](84 * $sc); $hint.Padding = New-Object Windows.Forms.Padding(8, 8, 8, 0)
    $hint.Text = "A list is saved after every finished scan (the newest $($script:KeepLists) are kept). Pick one and press Restore: it replaces the lists on screen."
    $lv2 = New-Object Windows.Forms.ListView; $lv2.Dock = 'Fill'; $lv2.View = 'Details'; $lv2.FullRowSelect = $true; $lv2.MultiSelect = $false; $lv2.HideSelection = $false
    foreach ($c in @(@('Saved', 200), @('State', 120), @('Folders scanned', 360), @('Size', 100), @('File', 280))) { [void]$lv2.Columns.Add($c[0], [int]($c[1] * $sc)) }
    foreach ($c in @($cands | Sort-Object Saved -Descending)) {
        $it = New-Object Windows.Forms.ListViewItem($c.Saved)
        [void]$it.SubItems.Add($(if ($c.Partial) { 'partial' } else { 'complete' })); [void]$it.SubItems.Add($c.Roots)
        [void]$it.SubItems.Add("$($c.SizeMB) MB"); [void]$it.SubItems.Add($c.Name)
        $it.Tag = $c.Path; [void]$lv2.Items.Add($it)
    }
    if ($lv2.Items.Count) { $lv2.Items[0].Selected = $true }
    $pnl = New-Object Windows.Forms.FlowLayoutPanel; $pnl.Dock = 'Bottom'; $pnl.FlowDirection = 'RightToLeft'; $pnl.Height = [int](56 * $sc); $pnl.Padding = New-Object Windows.Forms.Padding(8)
    $bCancel = New-Btn 'Cancel'; $bCancel.DialogResult = 'Cancel'
    $bOk = New-Btn 'Restore selected list' $true; $bOk.DialogResult = 'OK'
    $bBrowse = New-Btn 'Other file...'
    $pnl.Controls.Add($bCancel); $pnl.Controls.Add($bOk); $pnl.Controls.Add($bBrowse)
    $dlg.Controls.Add($lv2); $dlg.Controls.Add($pnl); $dlg.Controls.Add($hint)
    $dlg.AcceptButton = $bOk; $dlg.CancelButton = $bCancel
    $script:PickedList = $null
    $lv2.Add_DoubleClick({ if ($lv2.SelectedItems.Count) { $script:PickedList = $lv2.SelectedItems[0].Tag; $dlg.DialogResult = 'OK'; $dlg.Close() } }.GetNewClosure())
    $bBrowse.Add_Click({
        $od = New-Object Windows.Forms.OpenFileDialog; $od.Filter = 'Saved lists (*.json)|*.json'; $od.InitialDirectory = $script:ListDir
        if ($od.ShowDialog() -eq 'OK') { $script:PickedList = $od.FileName; $dlg.DialogResult = 'OK'; $dlg.Close() }
    }.GetNewClosure())
    $res = $dlg.ShowDialog($form)
    if ($res -eq 'OK' -and -not $script:PickedList -and $lv2.SelectedItems.Count) { $script:PickedList = $lv2.SelectedItems[0].Tag }
    $dlg.Dispose()
    if ($res -ne 'OK' -or -not $script:PickedList) { return }
    $pick = $script:PickedList
    if (-not (Test-Path -LiteralPath $pick)) { [void][Windows.Forms.MessageBox]::Show("That file no longer exists:`n$pick", 'DupCleaner'); return }
    # keep the list that is on screen now (as last saved) before replacing it
    try { if ((Resolve-Path -LiteralPath $pick).Path -ne (Resolve-Path -LiteralPath $script:SessionFile).Path) { Save-ListArchive $script:SessionFile } } catch { Write-ErrLog $_ }   # the file on disk, never the (possibly empty) screen
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try { Restore-Session $pick $true } finally { $form.Cursor = [Windows.Forms.Cursors]::Default }
}

function Show-PreviousCrash {
    if (-not $script:PrevCrash) { return }
    $short = (($script:PrevCrash -split "`r?`n") | Select-Object -First 7) -join "`n"
    [void][Windows.Forms.MessageBox]::Show("The last run of DupCleaner ended unexpectedly (it did not close normally).`n`nLast known state:`n$short`n`nThe full report was added to:`n$script:LogPath`n`nYour saved session and fingerprints are kept; the saved fingerprints make a rescan much faster.", 'DupCleaner', 'OK', 'Warning')
}

$form.Add_FormClosing({
    $script:Cancel = $true; $script:Paused = $false   # let a running scan unwind
    Save-Session
    Export-HashCache
    Remove-Heartbeat   # last: its absence at the next start means "closed cleanly"
})

$script:OnProgress = {
    param($text, $pct)
    if ($form.IsDisposed) { return }
    $lblStatus.Text = $text
    if ($script:Paused) { $lblEta.Text = 'Paused. The time left resumes when you press Resume.' } elseif ($script:EtaText) { $lblEta.Text = $script:EtaText }
    if ($pct -ge 0) { $prog.Style = 'Continuous'; $prog.Value = [math]::Min(100, $pct) } else { $prog.Style = 'Marquee' }
}

$btnScan.Add_Click({
    if ($lstRoots.Items.Count -eq 0) { [void][Windows.Forms.MessageBox]::Show('Add at least one folder first.', 'DupCleaner'); return }
    if (-not ($chkFiles.Checked -or $chkFolders.Checked)) { return }
    foreach ($r in $lstRoots.Items) {
        $u = $r.TrimEnd('\').ToUpper()
        if ($u -match '^[A-Z]:$' -or $u -eq "$env:USERPROFILE".ToUpper() -or $u -eq 'C:\WINDOWS') {
            $a = [Windows.Forms.MessageBox]::Show("'$r' is very broad (whole drive / user profile / Windows). Results can include system and program files.`n`nContinue anyway?", 'DupCleaner', 'YesNo', 'Warning', 'Button2')
            if ($a -ne 'Yes') { return }
        }
    }
    try {
        $script:Cancel = $false; $script:Paused = $false; $btnPause.Text = 'Pause'; $btnPause.Enabled = $true; $script:HashCache = @{}; $script:UseCache = $chkCache.Checked; $script:CacheHits = 0; Import-HashCache; $script:BytesDone = 0; $script:BytesTotal = 0; $script:StepMs = 0L; $script:ActiveMs = 0L; $script:TickPrev = -1L; $script:RateMs0 = 0L; $script:RateWork0 = 0L; $script:RateRaw0 = 0L; $script:RateEwma = 0.0; $script:RawEwma = 0.0; $script:RawBytes = 0L; $script:EtaText = ''; $lblEta.Text = 'Time left: calculating...'
        $btnScan.Enabled = $false; $btnCancel.Enabled = $true; $btnApply.Enabled = $false
        $script:Scanning = $true; $script:LastSessionSave = $script:CacheClock.ElapsedMilliseconds; $script:Pending.Clear(); $script:ViewLimit = @{ File = $script:ViewStep; Folder = $script:ViewStep }
        $script:Results = @{ File = (New-Object 'System.Collections.Generic.List[object]'); Folder = (New-Object 'System.Collections.Generic.List[object]'); Nested = (New-Object 'System.Collections.Generic.List[object]') }
        foreach ($k in 'File', 'Folder') { $views[$k].Items.Clear(); $views[$k].Groups.Clear(); Reset-Sort $k; Reset-FilterControls $k }
        Set-FilterEnabled $false   # filtering and sorting wait until the scan is over
        try { Update-Summary } catch { Write-ErrLog $_ }   # clear the totals and chart of the previous results
        $script:OnGroup = {
            param($kind, $group)
            if ($form.IsDisposed) { return }
            $script:Results[$kind].Add($group)
            $script:Pending.Add(@($kind, $group, $script:Results[$kind].Count))
            Send-Pending
        }
        $prog.Style = 'Marquee'
        Set-ScanSteps $chkFiles.Checked $chkFolders.Checked; $script:FilesDone = 0L
        Write-CrashLog 'Timing' "Scan started: $(@($lstRoots.Items) -join ' | ')   steps: $($script:ScanSteps -join ' > ')"
        $roots = @($lstRoots.Items | ForEach-Object { (New-Object IO.DirectoryInfo $_).FullName })
        $excl = if ($chkExcl.Checked) { $script:DefaultExcludes } else { @() }
        $scan = Get-ScanFiles $roots $excl $chkPlace.Checked @($txtQ.Text)
        if (-not $scan) { $lblStatus.Text = 'Cancelled.'; return }
        $script:SeenPaths = New-Object 'System.Collections.Generic.HashSet[string]'   # lets the fingerprint save skip per-file disk lookups
        foreach ($sf in $scan.Files) { [void]$script:SeenPaths.Add($sf.Path.ToLowerInvariant()) }
        $msg = "Scanned $($scan.Files.Count) files."
        if ($chkFiles.Checked) {
            $r = Find-DupFiles $scan.Files ([long]$numMin.Value * 1KB)
            if (-not $r) { $lblStatus.Text = 'Cancelled.'; return }
            $msg += " Hardlinked copies collapsed: $($r.HardlinksCollapsed)."
        }
        if ($chkFolders.Checked) {
            Send-Pending $true
            $r = Find-DupFolders $scan.Files $scan.Taint
            if (-not $r) { $lblStatus.Text = 'Cancelled.'; return }
            $script:Results['Folder'] = $r.Groups; $script:Results['Nested'] = $r.Nested; Reset-Sort 'Folder'; Show-Results 'Folder'
        }
        $s = $scan.Stats
        $msg += " Finished in $(Format-Span ($script:ActiveMs / 1000.0))."
        if ($script:CacheHits -gt 0) { $msg += " $($script:CacheHits) file(s) were not re-read (saved fingerprints)." }
        $msg +=" Skipped: $($s.Excluded) excluded folders, $($s.Placeholders) online-only files, $($s.Links) links, $($s.Errors) unreadable."
        $lblStatus.Text = $msg; $prog.Style = 'Continuous'; $prog.Value = 100
        $lblEta.Text = "Scan complete.    Total time: $(Format-Span ($script:ActiveMs / 1000.0))"
        Update-Summary
    } catch {
        Write-CrashLog 'Scan failed' ("$($_.Exception.ToString())`r`n$($_.InvocationInfo.PositionMessage)`r`n$($_.ScriptStackTrace)")
        if (-not $form.IsDisposed) { [void][Windows.Forms.MessageBox]::Show("Scan failed: $($_.Exception.Message)`n`nDetails were saved to:`n$script:LogPath", 'DupCleaner', 'OK', 'Error') }
    }
    finally {
        $script:Scanning = $false; $script:Paused = $false
        $keepStatus = $lblStatus.Text; $keepEta = $lblEta.Text
        Update-Step 'Saving results and fingerprints...'
        if (-not $form.IsDisposed) { $lblStatus.Text = "Step $($script:StepNo) of $($script:ScanSteps.Count): saving results and fingerprints (the window may pause briefly)..."; [Windows.Forms.Application]::DoEvents() }
        if (-not $form.IsDisposed) { Set-FilterEnabled $true }
        if (-not $form.IsDisposed) { Send-Pending $true }
        if (-not $form.IsDisposed) { Save-Session; Save-ListArchive $script:SessionFile }   # results first: they are what hurts most to lose; a dated copy is kept for "Restore list..."
        Export-HashCache (-not $form.IsDisposed)
        Close-Step; Write-CrashLog 'Timing' "Scan ended: total working time $(Format-Span ($script:ActiveMs / 1000.0))"
        if (-not $form.IsDisposed) { $lblStatus.Text = $keepStatus; $lblEta.Text = $keepEta }
        if (-not $form.IsDisposed) { $btnPause.Enabled = $false; $btnPause.Text = 'Pause'; $btnScan.Enabled = $true; $btnCancel.Enabled = $false; Update-Summary }
        if (-not $form.IsDisposed -and $main -and $lblEta.Text -like 'Scan complete*') { Select-ResultsTab; $main.SelectedTab = $pgProc }   # scan finished: show the results
        if (-not $form.IsDisposed) { if ($prog.Style -eq 'Marquee') { $prog.Style = 'Continuous'; $prog.Value = 0 } }
    }
})

$btnApply.Add_Click({
    $kind = $tabs.SelectedTab.Controls[0].Tag
    $g = $script:Results[$kind]; if (-not $g) { return }
    $mode = if ($rbMove.Checked) { 'move' } elseif ($rbRecycle.Checked) { 'recycle' } else { 'delete' }
    $n = 0; $bytes = 0L
    foreach ($s in $g) { foreach ($it in $s.Items) { if ($it.Remove) { $n++; $bytes += $it.Length } } }
    if ($n -eq 0) { return }
    if ($kind -eq 'Folder') { $rm = New-Object System.Collections.ArrayList; foreach ($s in $g) { foreach ($it in $s.Items) { if ($it.Remove) { $a3 = Get-CachedSafety $it $s; if ($a3 -and $a3.Safety -lt 65) { [void]$rm.Add($a3) } } } }; if (-not (Confirm-RiskyRemovals $rm.ToArray())) { return } }
    $what = switch ($mode) { 'move' { "MOVE to: $($txtQ.Text)" } 'recycle' { 'send to the RECYCLE BIN' } default { 'PERMANENTLY DELETE (cannot be undone)' } }
    $noKeep = 0
    foreach ($s in $g) { $any = $false; foreach ($it in $s.Items) { if (-not $it.Remove) { $any = $true; break } }; if (-not $any) { $noKeep++ } }
    if ($noKeep -gt 0) {
        $a = [Windows.Forms.MessageBox]::Show("WARNING: in $noKeep set(s) EVERY copy is selected.`n`nAfter this, NOTHING of those $noKeep $($kind.ToLower())(s) will be left anywhere.`n`n$n $($kind.ToLower())(s), about $(Format-Size $bytes), will be:`n$what`n`nDo you really want to remove every copy?", 'Delete every copy?', 'YesNo', 'Warning', 'Button2')
        if ($a -ne 'Yes') { return }
    } else {
        $a = [Windows.Forms.MessageBox]::Show("$n $($kind.ToLower())(s), about $(Format-Size $bytes), will be:`n$what`n`nOne copy in every set is kept (shown green). Continue?", 'Confirm', 'YesNo', 'Question', 'Button2')
        if ($a -ne 'Yes') { return }
    }
    if ($mode -eq 'delete') {
        $a = [Windows.Forms.MessageBox]::Show("Permanent delete skips the Recycle Bin. Are you really sure?", 'Permanent delete', 'YesNo', 'Warning', 'Button2')
        if ($a -ne 'Yes') { return }
    }
    try {
        $log = Invoke-Removal $g $mode $txtQ.Text $kind
        # drop handled items; drop sets with nothing left to decide
        $left = New-Object 'System.Collections.Generic.List[object]'
        foreach ($s in $g) {
            $items = @($s.Items | Where-Object { $null -ne $_.Remove })
            foreach ($it in $items) { }
            if ($items.Count -ge 2) { $s.Items = New-Object 'System.Collections.Generic.List[object]'; foreach ($it in $items) { $s.Items.Add($it) }; $left.Add($s) }
        }
        $script:Results[$kind] = $left
        if ($kind -eq 'Folder' -and $script:Results['Nested']) {   # sub-folder sets inside folders that were just removed are gone too
            $keepN = New-Object 'System.Collections.Generic.List[object]'
            foreach ($ns in $script:Results['Nested']) {
                $ex = New-Object 'System.Collections.Generic.List[object]'
                foreach ($it in $ns.Items) { if ([IO.Directory]::Exists($it.Path)) { $ex.Add($it) } }
                if ($ex.Count -ge 2) { $ns.Items = $ex; $keepN.Add($ns) }
            }
            $script:Results['Nested'] = $keepN
        }
        Show-Results $kind; Save-Session
        if ($kind -eq 'Folder') { $script:SpSig = ''; Update-SetsPanel }   # removed folders are gone from the sets list
        $lf = Join-Path ([IO.Path]::GetTempPath()) 'DupCleaner-last-run.txt'
        $log | Set-Content -LiteralPath $lf -Encoding UTF8
        $fail = @($log | Where-Object { $_ -like 'FAILED*' -or $_ -like 'SKIP*' }).Count
        $head = $log | Select-Object -First 1
        [void][Windows.Forms.MessageBox]::Show("Done. $($log.Count) log entries ($fail skipped/failed).`n$head`n`nFull log: $lf", 'DupCleaner')
    } catch { [void][Windows.Forms.MessageBox]::Show("Failed: $($_.Exception.Message)", 'DupCleaner', 'OK', 'Error') }
})

# ---- Verify duplicates: byte-for-byte comparison of every copy with the kept one, plus a health check of the kept file
if (-not ('ByteCmp' -as [type])) {
Add-Type -TypeDefinition @"
public static class ByteCmp { public static bool Eq(byte[] a, byte[] b, int n) { for (int i = 0; i < n; i++) { if (a[i] != b[i]) return false; } return true; } }
"@
}
try { Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem } catch { Write-ErrLog $_ }

$script:VerCancel = $false; $script:VerDone = 0L; $script:VerTotal = 1L; $script:VerText = ''; $script:VerLastUi = 0L
$script:VerClock = [Diagnostics.Stopwatch]::StartNew()

function Update-VerUi([bool]$force = $false) {
    if (-not $force -and ($script:VerClock.ElapsedMilliseconds - $script:VerLastUi) -lt 250) { return }
    $script:VerLastUi = $script:VerClock.ElapsedMilliseconds
    $d = $script:VerDlg
    if ($d -and -not $d.IsDisposed) {
        $d.Lbl.Text = $script:VerText
        $d.Bar.Value = [int][math]::Min(1000, [math]::Max(0, 1000.0 * $script:VerDone / [math]::Max(1L, $script:VerTotal)))
    }
    [Windows.Forms.Application]::DoEvents()
    if ($script:VerCancel) { throw 'cancelled' }
}

function Read-Full($fs, [byte[]]$buf, [int]$want) {   # reads exactly $want bytes (or up to the end of the file) without freezing the window
    $got = 0
    while ($got -lt $want) {
        $rt = $fs.ReadAsync($buf, $got, $want - $got)
        while (-not $rt.Wait(100)) { Update-VerUi $true }
        $n = $rt.Result
        if ($n -le 0) { break }
        $got += $n
    }
    return $got
}

function Compare-OneFile([string]$ref, [string[]]$others, [hashtable]$res) {
    # $res[path] = problem text for a copy that differs; $res['__ref'] = problem with the kept file itself
    $opts = [IO.FileOptions]::Asynchronous
    $fr = $null; $open = @{}
    try {
        try { $fr = New-Object IO.FileStream($ref, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite, 65536, $opts) } catch { $res['__ref'] = "cannot be read: $($_.Exception.Message)"; return }
        foreach ($o in $others) {
            try {
                $s = New-Object IO.FileStream($o, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite, 65536, $opts)
                if ($s.Length -ne $fr.Length) { $res[$o] = "different size ($($s.Length) vs $($fr.Length) bytes)"; $s.Dispose() } else { $open[$o] = $s }
            } catch { $res[$o] = "cannot be read: $($_.Exception.Message)" }
        }
        if (-not $open.Count) { return }
        $bufA = New-Object byte[] 1048576; $bufB = New-Object byte[] 1048576
        $pos = 0L
        while ($open.Count) {
            try { $n = Read-Full $fr $bufA $bufA.Length } catch { if ("$_" -eq 'cancelled') { throw }; $res['__ref'] = "read error at byte $pos : $($_.Exception.Message)"; return }
            if ($n -le 0) { break }
            foreach ($o in @($open.Keys)) {
                try { $m = Read-Full $open[$o] $bufB $n } catch { if ("$_" -eq 'cancelled') { throw }; $res[$o] = "read error at byte $pos : $($_.Exception.Message)"; $open[$o].Dispose(); $open.Remove($o); continue }
                if ($m -ne $n -or -not [ByteCmp]::Eq($bufA, $bufB, $n)) { $res[$o] = "content differs in the 1 MB block starting at byte $pos"; $open[$o].Dispose(); $open.Remove($o) }
            }
            $pos += $n; $script:VerDone += $n * (1 + $open.Count)
            Update-VerUi
        }
    } finally {
        if ($fr) { $fr.Dispose() }
        foreach ($s in $open.Values) { $s.Dispose() }
    }
}

function Test-Health([string]$path) {
    # returns @(status, note): OK / NOTE (could not be tested) / PROBLEM
    $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
    try {
        if ($ext -match '^\.(jpe?g|png|gif|bmp|tiff?)$') {
            $fs = [IO.File]::OpenRead($path)
            try { $img = [Drawing.Image]::FromStream($fs, $false, $true); $img.Dispose() } finally { $fs.Dispose() }
            return @('OK', 'image opens and decodes')
        }
        if ($ext -match '^\.(zip|docx|xlsx|pptx|odt|ods|odp|jar|apk)$') {
            $z = [IO.Compression.ZipFile]::OpenRead($path); $cnt = 0
            try {
                $b = New-Object byte[] 65536
                foreach ($e in $z.Entries) {
                    $s = $e.Open()
                    try { while ($s.Read($b, 0, $b.Length) -gt 0) { Update-VerUi } } finally { $s.Dispose() }
                    $cnt++
                }
            } finally { $z.Dispose() }
            return @('OK', "archive opens, all $cnt entries unpack")
        }
        if ($ext -eq '.pdf') {
            $fs = [IO.File]::OpenRead($path)
            try {
                $h = New-Object byte[] 5; [void]$fs.Read($h, 0, 5)
                if ([Text.Encoding]::ASCII.GetString($h) -ne '%PDF-') { return @('PROBLEM', 'does not start with %PDF-') }
                $len = [math]::Min(2048L, $fs.Length); [void]$fs.Seek(-$len, 'End'); $t = New-Object byte[] $len; [void]$fs.Read($t, 0, $len)
                if ([Text.Encoding]::ASCII.GetString($t) -notmatch '%%EOF') { return @('PROBLEM', 'no %%EOF at the end (file looks cut off)') }
            } finally { $fs.Dispose() }
            return @('OK', 'PDF header and end marker present')
        }
        if ($ext -match '^\.(mp4|mov|avi|mkv|wmv|m4v|webm|mts|mp3|wav|flac|m4a|aac|ogg|wma)$') { return @('NOTE', 'read completely without errors; playback not tested (needs ffmpeg)') }
        return @('NOTE', 'read completely without errors; this file type cannot be tested further')
    } catch { if ("$_" -eq 'cancelled') { throw }; return @('PROBLEM', "does not open: $($_.Exception.Message)") }
}

function Get-DirFiles([string]$dir) {
    $h = @{}
    foreach ($f in [IO.Directory]::EnumerateFiles($dir, '*', [IO.SearchOption]::AllDirectories)) { $h[$f.Substring($dir.TrimEnd('\').Length).TrimStart('\').ToLowerInvariant()] = $f }
    return $h
}

function Invoke-Verify($sets, [string]$kind, $rows) {
    $n = 0; $total = $sets.Count
    foreach ($set in $sets) {
        $n++
        $items = $set.Items
        $ref = $null; foreach ($it in $items) { if (-not $it.Remove) { $ref = $it; break } }
        $noKeeper = ($null -eq $ref); if ($noKeeper) { $ref = $items[0] }
        $script:VerText = "Set $n of $total : $([IO.Path]::GetFileName($ref.Path))"
        Update-VerUi
        $add = { param($status, $role, $it, $note) [void]$rows.Add([pscustomobject]@{ Set = $n; Status = $status; Role = $role; Path = $it.Path; Note = $note; Item = $it; Group = $set }) }
        $isFile = ($kind -eq 'File')
        $exists = { param($p) if ($isFile) { [IO.File]::Exists($p) } else { [IO.Directory]::Exists($p) } }
        if (-not (& $exists $ref.Path)) { & $add 'PROBLEM' 'kept' $ref 'the file/folder is gone'; continue }
        if ($isFile -and ([IO.FileInfo]$ref.Path).Length -ne $ref.Length) { & $add 'PROBLEM' 'kept' $ref 'changed since the scan (different size)'; continue }
        $res = @{}; $present = New-Object 'System.Collections.Generic.List[object]'
        foreach ($it in $items) {
            if ([object]::ReferenceEquals($it, $ref)) { continue }
            if (-not (& $exists $it.Path)) { & $add 'MISSING' 'copy' $it 'the file/folder is gone'; continue }
            if ($isFile -and ([IO.FileInfo]$it.Path).Length -ne $it.Length) { & $add 'CHANGED' 'copy' $it 'changed since the scan (different size)'; continue }
            $present.Add($it)
        }
        try {
            if ($isFile) {
                if ($present.Count) { Compare-OneFile $ref.Path @($present | ForEach-Object { $_.Path }) $res }
                if ($res['__ref']) { & $add 'PROBLEM' 'kept' $ref $res['__ref'] }
                else {
                    $h = Test-Health $ref.Path
                    & $add $h[0] 'kept' $ref $h[1]
                }
            } else {
                $rf = Get-DirFiles $ref.Path
                $dirRes = @{}
                $cf = @{}
                foreach ($it in $present) {
                    $f = Get-DirFiles $it.Path; $cf[$it.Path] = $f
                    $missing = @($rf.Keys | Where-Object { -not $f.ContainsKey($_) }).Count; $extra = @($f.Keys | Where-Object { -not $rf.ContainsKey($_) }).Count
                    if ($missing -or $extra) { $dirRes[$it.Path] = "file lists differ ($missing missing, $extra extra)" }
                }
                $good = @($present | Where-Object { -not $dirRes.ContainsKey($_.Path) })
                $refBad = $null
                foreach ($k in $rf.Keys) {
                    $script:VerText = "Set $n of $total : $k"
                    $r2 = @{}
                    $others = @($good | Where-Object { -not $dirRes.ContainsKey($_.Path) } | ForEach-Object { $cf[$_.Path][$k] })
                    if ($others.Count) { Compare-OneFile $rf[$k] $others $r2 }
                    if ($r2['__ref']) { $refBad = "$k : $($r2['__ref'])"; break }
                    foreach ($it in $good) { $op = $cf[$it.Path][$k]; if ($r2.ContainsKey($op) -and -not $dirRes.ContainsKey($it.Path)) { $dirRes[$it.Path] = "$k : $($r2[$op])" } }
                }
                foreach ($it in $present) { $res[$it.Path] = $dirRes[$it.Path] }
                if ($refBad) { $res['__ref'] = $refBad }
                if ($res['__ref']) { & $add 'PROBLEM' 'kept' $ref $res['__ref'] }
                else {
                    $bad = @(); $cnt = 0
                    foreach ($k in $rf.Keys) { $h = Test-Health $rf[$k]; $cnt++; if ($h[0] -eq 'PROBLEM') { $bad += "$k : $($h[1])" } }
                    if ($bad.Count) { & $add 'PROBLEM' 'kept' $ref ("$($bad.Count) of $cnt files have problems, first: $($bad[0])") } else { & $add 'OK' 'kept' $ref "all $cnt files read and tested" }
                }
            }
        } catch { if ("$_" -eq 'cancelled') { throw }; & $add 'PROBLEM' 'kept' $ref "check failed: $($_.Exception.Message)"; continue }
        if ($res['__ref']) { continue }   # the kept file itself is unreadable: the comparison says nothing about the copies
        foreach ($it in $present) {
            if ($res[$it.Path]) { & $add 'DIFFERENT' 'copy' $it $res[$it.Path] } else { & $add 'OK' 'copy' $it 'identical to the kept one (byte for byte)' }
        }
    }
}

function Show-VerifyDialog {
    if ($script:Scanning) { [void][Windows.Forms.MessageBox]::Show('Wait for the scan to finish (or cancel it) first.', 'DupCleaner'); return }
    $kind = $tabs.SelectedTab.Controls[0].Tag
    if (-not $script:Results[$kind]) { return }
    $target = Get-TargetSets $kind
    $sets = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $target) { foreach ($it in $s.Items) { if ($it.Remove) { $sets.Add($s); break } } }
    $what = 'the sets with ticked copies'
    if (-not $sets.Count) { foreach ($s in $target) { $sets.Add($s) }; $what = 'all shown sets (nothing is ticked)' }
    if (-not $sets.Count) { return }
    $bytes = 0L; foreach ($s in $sets) { if ($kind -eq 'File') { foreach ($it in $s.Items) { $bytes += $it.Length } } else { $bytes += [int64]$s.Size * $s.Items.Count } }
    $a = [Windows.Forms.MessageBox]::Show("Check $($sets.Count) set(s) ($what)?`n`nEvery copy is compared byte for byte with the file that is kept, and the kept file is tested (images, zip/Office files and PDFs are opened; other types are read completely).`n`nThis reads about $(Format-Size $bytes) again - on a slow disk that can take a long time. You can cancel at any moment.", 'Verify duplicates', 'YesNo', 'Question')
    if ($a -ne 'Yes') { return }
    $sc = $form.DeviceDpi / 96.0
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'Verify duplicates'; $dlg.StartPosition = 'CenterParent'; $dlg.Font = $form.Font; $dlg.ShowInTaskbar = $false; $dlg.MinimizeBox = $false
    $dlg.ClientSize = New-Object Drawing.Size([int](1200 * $sc), [int](620 * $sc))
    $lbl = New-Object Windows.Forms.Label; $lbl.Dock = 'Top'; $lbl.Height = [int](34 * $sc); $lbl.Padding = New-Object Windows.Forms.Padding(8, 8, 8, 0); $lbl.AutoEllipsis = $true; $lbl.Text = 'Starting...'
    $bar = New-Object Windows.Forms.ProgressBar; $bar.Dock = 'Top'; $bar.Height = [int](22 * $sc); $bar.Maximum = 1000
    $lv2 = New-Object Windows.Forms.ListView; $lv2.Dock = 'Fill'; $lv2.View = 'Details'; $lv2.FullRowSelect = $true; $lv2.HideSelection = $false
    foreach ($c in @(@('Result', 110), @('Set', 70), @('Role', 70), @('Details', 420), @('Path', 520))) { [void]$lv2.Columns.Add($c[0], [int]($c[1] * $sc)) }
    $pnl = New-Object Windows.Forms.FlowLayoutPanel; $pnl.Dock = 'Bottom'; $pnl.FlowDirection = 'RightToLeft'; $pnl.Height = [int](56 * $sc); $pnl.Padding = New-Object Windows.Forms.Padding(8)
    $bClose = New-Btn 'Cancel'; $bUntick = New-Btn 'Untick problem items'; $bSave = New-Btn 'Save report'; $bUntick.Enabled = $false; $bSave.Enabled = $false
    $pnl.Controls.Add($bClose); $pnl.Controls.Add($bUntick); $pnl.Controls.Add($bSave)
    $dlg.Controls.Add($lv2); $dlg.Controls.Add($pnl); $dlg.Controls.Add($bar); $dlg.Controls.Add($lbl)
    $dlg | Add-Member -NotePropertyName Lbl -NotePropertyValue $lbl; $dlg | Add-Member -NotePropertyName Bar -NotePropertyValue $bar
    $script:VerDlg = $dlg; $script:VerCancel = $false; $script:VerDone = 0L; $script:VerTotal = [math]::Max(1L, $bytes); $script:VerRunning = $true; $script:VerClosing = $false
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $script:VerRows = $rows; $script:VerLv = $lv2; $script:VerBClose = $bClose; $script:VerBSave = $bSave; $script:VerBUntick = $bUntick; $script:VerSets = $sets; $script:VerKind = $kind
    $bClose.Add_Click({ if ($script:VerRunning) { $script:VerCancel = $true; $script:VerClosing = $false } else { $script:VerDlg.Close() } })
    $dlg.Add_FormClosing({ param($s, $e) if ($script:VerRunning) { $script:VerCancel = $true; $script:VerClosing = $true; $e.Cancel = $true } })
    $bSave.Add_Click({
        $f = Join-Path ([IO.Path]::GetTempPath()) 'DupCleaner-verify-report.txt'
        $out = foreach ($r in $script:VerRows) { "{0,-10} set {1,-6} {2,-5} {3}  --  {4}" -f $r.Status, $r.Set, $r.Role, $r.Path, $r.Note }
        $out | Set-Content -LiteralPath $f -Encoding UTF8
        [void][Diagnostics.Process]::Start($f)
    })
    $bUntick.Add_Click({
        # a copy that differs / is gone is not a real duplicate: it must not be removed. A kept file that is broken: keep every copy of that set.
        $script:Busy = $true; $nUn = 0
        foreach ($r in $script:VerRows) {
            if ($r.Status -in 'DIFFERENT', 'MISSING', 'CHANGED') { if ($r.Item.Remove) { $r.Item.Remove = $false; $nUn++ } }
            elseif ($r.Role -eq 'kept' -and $r.Status -eq 'PROBLEM') { foreach ($x in $r.Group.Items) { if ($x.Remove) { $x.Remove = $false; $nUn++ } } }
        }
        $script:Busy = $false
        $k = $tabs.SelectedTab.Controls[0].Tag; Show-Results $k
        $script:VerDlg.Lbl.Text = "Unticked $nUn item(s): they stay where they are."
        $script:VerBUntick.Enabled = $false
    })
    $dlg.Add_Shown({
      try {
        $form.Cursor = [Windows.Forms.Cursors]::Default
        $cancelled = $false; $stopMsg = ''; $rows = $script:VerRows
        try { Invoke-Verify $script:VerSets $script:VerKind $script:VerRows } catch { if ("$_" -eq 'cancelled') { $cancelled = $true } else { $stopMsg = "STOPPED BY AN ERROR: $($_.Exception.Message)"; Write-CrashLog 'Verify error' ($_.Exception.ToString() + "`r`n" + $_.ScriptStackTrace) } }
        $script:VerRunning = $false
        $rows = $script:VerRows; $lv2 = $script:VerLv; $bClose = $script:VerBClose; $bSave = $script:VerBSave; $bUntick = $script:VerBUntick
        $nOk = 0; $nBad = 0; $nNote = 0
        foreach ($r in $rows) {
            if ($r.Status -eq 'OK') { $nOk++ } elseif ($r.Status -eq 'NOTE') { $nNote++ } else { $nBad++ }
        }
        $lv2.BeginUpdate()
        foreach ($r in $rows) {
            if ($r.Status -eq 'OK') { continue }
            $li = New-Object Windows.Forms.ListViewItem($r.Status)
            [void]$li.SubItems.Add([string]$r.Set); [void]$li.SubItems.Add($r.Role); [void]$li.SubItems.Add($r.Note); [void]$li.SubItems.Add($r.Path)
            if ($r.Status -in 'PROBLEM', 'DIFFERENT', 'MISSING', 'CHANGED') { $li.ForeColor = $script:UiDelFg }
            [void]$lv2.Items.Add($li)
            if ($lv2.Items.Count -ge 5000) { break }
        }
        $lv2.EndUpdate()
        $script:VerDlg.Bar.Value = if ($cancelled) { $script:VerDlg.Bar.Value } else { 1000 }
        $head = $(if ($stopMsg) { "$stopMsg  " } elseif ($cancelled) { 'CANCELLED - partial result.  ' } else { 'Finished.  ' })
        $script:VerDlg.Lbl.Text = "$head$nOk check(s) passed, $nBad PROBLEM(S), $nNote could not be tested further (listed below with the problems; the full list is in the report)."
        $bClose.Text = 'Close'; $bSave.Enabled = $true; $bUntick.Enabled = ($nBad -gt 0)
        if ($script:VerClosing) { $script:VerDlg.Close() }
      } catch { $script:VerRunning = $false; Write-CrashLog 'Verify failed' $_.Exception; $script:VerDlg.Lbl.Text = "Verification failed: $($_.Exception.Message)"; $script:VerBClose.Text = 'Close' }
    })
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try { [void]$dlg.ShowDialog($form) } finally { $form.Cursor = [Windows.Forms.Cursors]::Default; $script:VerRunning = $false; $dlg.Dispose(); $script:VerDlg = $null }
}

# ---- Preview window: shows the file/folder selected in the list (image, text, PDF, video/audio), with zoom, scroll bars and pages
$script:Pv = $null
$script:PvExt = @{
    Image = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.ico', '.webp', '.heic')
    Media = @('.mp4', '.mov', '.avi', '.wmv', '.m4v', '.mkv', '.webm', '.mts', '.mp3', '.wav', '.m4a', '.wma', '.aac', '.flac', '.ogg')
    Text  = @('.txt', '.md', '.csv', '.log', '.json', '.xml', '.ini', '.cfg', '.conf', '.html', '.htm', '.css', '.js', '.ps1', '.psm1', '.py', '.cmd', '.bat', '.sql', '.yml', '.yaml', '.tsv', '.reg', '.inf', '.srt', '.vtt', '.java', '.cs', '.cpp', '.h', '.c', '.php', '.sh', '.gradle', '.properties', '.gitignore')
}
$script:PvPdfReady = $null; $script:PvAsTaskOp = $null; $script:PvAsTaskAct = $null

function Initialize-PvPdf {
    if ($null -ne $script:PvPdfReady) { return $script:PvPdfReady }
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        [void][Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
        [void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
        [void][Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
        $m = [System.WindowsRuntimeSystemExtensions].GetMethods()
        $script:PvAsTaskOp = @($m | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
        $script:PvAsTaskAct = @($m | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
        $script:PvPdfReady = $true
    } catch { $script:PvPdfReady = $false }
    return $script:PvPdfReady
}
function Wait-PvTask($task) {
    while (-not $task.Wait(40)) { [Windows.Forms.Application]::DoEvents() }
    if ($task.IsFaulted) { throw $task.Exception.InnerException }
}
function Await-PvOp($op, [Type]$type) { $t = $script:PvAsTaskOp.MakeGenericMethod($type).Invoke($null, @($op)); Wait-PvTask $t; return $t.Result }
function Await-PvAction($act) { $t = $script:PvAsTaskAct.Invoke($null, @($act)); Wait-PvTask $t }

function Get-PvKind([string]$path, [bool]$isDir) {
    if ($isDir) { return 'folder' }
    $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($script:PvExt.Image -contains $ext) { return 'image' }
    if ($ext -eq '.pdf') { return 'pdf' }
    if ($script:PvExt.Media -contains $ext) { return 'media' }
    if ($script:PvExt.Text -contains $ext) { return 'text' }
    return 'sniff'
}

function Read-PvText([string]$path, [ref]$isText) {
    # first 256 KB as text; $isText false when the file looks binary
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $n = [int][math]::Min(262144L, $fs.Length); $b = New-Object byte[] $n; $got = 0
        while ($got -lt $n) { $r = $fs.Read($b, $got, $n - $got); if ($r -le 0) { break }; $got += $r }
        $probe = [math]::Min($got, 4096); $nul = 0; for ($i = 0; $i -lt $probe; $i++) { if ($b[$i] -eq 0) { $nul++ } }
        $bom16 = ($got -ge 2 -and (($b[0] -eq 0xFF -and $b[1] -eq 0xFE) -or ($b[0] -eq 0xFE -and $b[1] -eq 0xFF)))
        $isText.Value = ($nul -eq 0 -or $bom16)
        if (-not $isText.Value) { return '' }
        $enc = New-Object Text.UTF8Encoding($false, $false)
        if ($bom16) { $enc = if ($b[0] -eq 0xFF) { [Text.Encoding]::Unicode } else { [Text.Encoding]::BigEndianUnicode } }
        $t = $enc.GetString($b, 0, $got)
        if ($fs.Length -gt $got) { $t += "`r`n`r`n... (preview shows the first 256 KB of $(Format-Size $fs.Length))" }
        return ($t -replace "(?<!\r)\n", "`r`n")
    } finally { $fs.Dispose() }
}

function New-PvWindow {
    $sc = $form.DeviceDpi / 96.0
    $f = New-Object Windows.Forms.Form
    $f.Text = 'Preview'; $f.Font = $form.Font; $f.ShowInTaskbar = $true; $f.KeyPreview = $true
    $f.StartPosition = 'Manual'
    $wa = [Windows.Forms.Screen]::FromControl($form).WorkingArea
    $f.Size = New-Object Drawing.Size([int][math]::Min(1000 * $sc, $wa.Width * 0.6), [int]($wa.Height * 0.85))
    $f.Location = New-Object Drawing.Point([int]($wa.Right - $f.Width - 10), [int]($wa.Top + 20))
    $pv = @{ Form = $f; Mode = ''; Zoom = 1.0; Fit = $true; Page = 0; Pages = 0; Bmp = $null; Doc = $null; Img = $null; Path = ''; IsDir = $false; TextSize = 11.0 }
    # toolbar
    $tb = New-Object Windows.Forms.FlowLayoutPanel; $tb.Dock = 'Top'; $tb.AutoSize = $true; $tb.AutoSizeMode = 'GrowAndShrink'; $tb.WrapContents = $true; $tb.Padding = New-Object Windows.Forms.Padding(4)
    $mkb = { param($t, $w) $b = New-Btn $t; $b.MinimumSize = New-Object Drawing.Size([int]($w * $sc), 0); $b.Margin = New-Object Windows.Forms.Padding(2); $b }
    $pv.BPrev = & $mkb '<  Prev' 70; $pv.LPage = New-Object Windows.Forms.Label; $pv.LPage.AutoSize = $true; $pv.LPage.Margin = New-Object Windows.Forms.Padding(4, 9, 4, 4); $pv.BNext = & $mkb 'Next  >' 70
    $pv.BMinus = & $mkb '-' 34; $pv.LZoom = New-Object Windows.Forms.Label; $pv.LZoom.AutoSize = $false; $pv.LZoom.Width = [int](100 * $sc); $pv.LZoom.Height = [int](26 * $sc); $pv.LZoom.TextAlign = 'MiddleCenter'; $pv.LZoom.Margin = New-Object Windows.Forms.Padding(0, 9, 0, 4); $pv.BPlus = & $mkb '+' 34
    $pv.BFit = & $mkb 'Fit' 50; $pv.B100 = & $mkb '100%' 60; $pv.BOpen = & $mkb 'Open with default app' 160
    $pv.BPlay = & $mkb 'Play' 70; $pv.Seek = New-Object Windows.Forms.TrackBar; $pv.Seek.Width = [int](260 * $sc); $pv.Seek.TickStyle = 'None'; $pv.Seek.Maximum = 1000; $pv.Seek.Margin = New-Object Windows.Forms.Padding(4, 2, 4, 2)
    $pv.LTime = New-Object Windows.Forms.Label; $pv.LTime.AutoSize = $true; $pv.LTime.Margin = New-Object Windows.Forms.Padding(4, 9, 4, 4)
    $tb.Controls.AddRange(@($pv.BPrev, $pv.LPage, $pv.BNext, $pv.BMinus, $pv.LZoom, $pv.BPlus, $pv.BFit, $pv.B100, $pv.BPlay, $pv.Seek, $pv.LTime, $pv.BOpen))
    $pv.Title = New-Object Windows.Forms.Label; $pv.Title.Dock = 'Top'; $pv.Title.AutoSize = $false; $pv.Title.Height = [int](58 * $sc); $pv.Title.Padding = New-Object Windows.Forms.Padding(8, 6, 8, 0); $pv.Title.UseMnemonic = $false; $pv.Title.BackColor = [Drawing.Color]::FromArgb(235, 240, 250); $pv.Title.Font = New-Object Drawing.Font($form.Font, [Drawing.FontStyle]::Bold)
    # image / PDF page: a scrolling panel holding a picture box
    $pv.PnlImg = New-Object Windows.Forms.Panel; $pv.PnlImg.Dock = 'Fill'; $pv.PnlImg.AutoScroll = $true; $pv.PnlImg.BackColor = [Drawing.Color]::FromArgb(60, 60, 60)
    $pv.Pic = New-Object Windows.Forms.PictureBox; $pv.Pic.SizeMode = 'StretchImage'; $pv.Pic.Location = New-Object Drawing.Point(0, 0); $pv.PnlImg.Controls.Add($pv.Pic)
    # text
    $pv.Txt = New-Object Windows.Forms.TextBox; $pv.Txt.Multiline = $true; $pv.Txt.ReadOnly = $true; $pv.Txt.ScrollBars = 'Both'; $pv.Txt.WordWrap = $false; $pv.Txt.Dock = 'Fill'; $pv.Txt.BackColor = [Drawing.Color]::White
    $pv.Txt.Font = New-Object Drawing.Font('Consolas', [single]$pv.TextSize); $pv.Txt.Visible = $false
    # video / audio
    $pv.MediaPanel = New-Object Windows.Forms.Panel; $pv.MediaPanel.Dock = 'Fill'; $pv.MediaPanel.BackColor = [Drawing.Color]::Black; $pv.MediaPanel.Visible = $false
    $pv.Media = $null; $pv.Host = $null
    $f.Controls.Add($pv.PnlImg); $f.Controls.Add($pv.Txt); $f.Controls.Add($pv.MediaPanel); $f.Controls.Add($pv.Title); $f.Controls.Add($tb)
    # docking is done back to front: the toolbar is docked first (last index), then the title, then the content panels fill the rest
    $f.Controls.SetChildIndex($tb, 4); $f.Controls.SetChildIndex($pv.Title, 3)
    $f.Controls.SetChildIndex($pv.MediaPanel, 2); $f.Controls.SetChildIndex($pv.Txt, 1); $f.Controls.SetChildIndex($pv.PnlImg, 0)
    $pv.Timer = New-Object Windows.Forms.Timer; $pv.Timer.Interval = 400
    $script:Pv = $pv
    $pv.BPrev.Add_Click({ Step-PvPage -1 }); $pv.BNext.Add_Click({ Step-PvPage 1 })
    $pv.BMinus.Add_Click({ Set-PvZoom ($script:Pv.Zoom / 1.25) }); $pv.BPlus.Add_Click({ Set-PvZoom ($script:Pv.Zoom * 1.25) })
    $pv.BFit.Add_Click({ $script:Pv.Fit = $true; Set-PvZoom 0 }); $pv.B100.Add_Click({ Set-PvZoom 1.0 })
    $pv.BOpen.Add_Click({ if ($script:Pv.Path) { try { [void][Diagnostics.Process]::Start($script:Pv.Path) } catch { Write-ErrLog $_ } } })
    $pv.BPlay.Add_Click({
        $p = $script:Pv; if (-not $p.Media) { return }
        if ($p.Playing) { $p.Media.Pause(); $p.Playing = $false; $p.BPlay.Text = 'Play' } else { $p.Media.Play(); $p.Playing = $true; $p.BPlay.Text = 'Pause' }
    })
    $pv.Seek.Add_Scroll({
        $p = $script:Pv; if ($p.Media -and $p.Media.NaturalDuration.HasTimeSpan) { $p.Media.Position = [TimeSpan]::FromSeconds($p.Media.NaturalDuration.TimeSpan.TotalSeconds * $p.Seek.Value / 1000.0) }
    })
    $pv.Timer.Add_Tick({
        $p = $script:Pv; if (-not $p.Media -or $p.Mode -ne 'media') { return }
        try {
            if ($p.Media.NaturalDuration.HasTimeSpan) {
                $tot = $p.Media.NaturalDuration.TimeSpan.TotalSeconds; $cur = $p.Media.Position.TotalSeconds
                if (-not $p.Seek.Capture) { $p.Seek.Value = [int][math]::Min(1000, 1000.0 * $cur / [math]::Max(0.1, $tot)) }
                $p.LTime.Text = ('{0:mm\:ss} / {1:mm\:ss}' -f [TimeSpan]::FromSeconds($cur), [TimeSpan]::FromSeconds($tot))
            }
        } catch { Write-ErrLog $_ }
    })
    $wheel = { param($s, $e) if ([Windows.Forms.Control]::ModifierKeys -band [Windows.Forms.Keys]::Control) { try { ([Windows.Forms.HandledMouseEventArgs]$e).Handled = $true } catch { Write-ErrLog $_ }; $p = $script:Pv; if ($e.Delta -gt 0) { Set-PvZoom ($p.Zoom * 1.15) } else { Set-PvZoom ($p.Zoom / 1.15) } } }
    $pv.PnlImg.Add_MouseWheel($wheel); $pv.Pic.Add_MouseWheel($wheel); $pv.Txt.Add_MouseWheel($wheel)
    $pv.PnlImg.Add_Resize({ $p = $script:Pv; if ($p -and $p.Fit -and ($p.Mode -in 'image', 'pdf')) { Set-PvZoom 0 } })
    $pv.PnlImg.Add_MouseEnter({ $script:Pv.PnlImg.Focus() })
    $f.Add_KeyDown({ param($s, $e) $p = $script:Pv
        if ($e.KeyCode -eq 'Escape') { $p.Form.Hide() }
        elseif ($e.KeyCode -eq 'PageDown' -or ($e.KeyCode -eq 'Right' -and $p.Mode -eq 'pdf')) { Step-PvPage 1 }
        elseif ($e.KeyCode -eq 'PageUp' -or ($e.KeyCode -eq 'Left' -and $p.Mode -eq 'pdf')) { Step-PvPage -1 }
        elseif ($e.KeyCode -in 'Add', 'Oemplus') { Set-PvZoom ($p.Zoom * 1.25) } elseif ($e.KeyCode -in 'Subtract', 'OemMinus') { Set-PvZoom ($p.Zoom / 1.25) } })
    $f.Add_FormClosing({ param($s, $e) $p = $script:Pv; if ($e.CloseReason -eq 'UserClosing') { $e.Cancel = $true; Clear-PvContent; $p.Form.Hide() } })   # hide, keep the window for next time
    return $pv
}

function Clear-PvContent {
    $p = $script:Pv; if (-not $p) { return }
    try { if ($p.Media) { $p.Media.Stop(); $p.Media.Source = $null; $p.Playing = $false } } catch { Write-ErrLog $_ }
    $p.Timer.Stop()
    $p.Pic.Image = $null
    if ($p.Bmp) { $p.Bmp.Dispose(); $p.Bmp = $null }
    if ($p.Img) { $p.Img.Dispose(); $p.Img = $null }
    $p.Doc = $null; $p.Txt.Text = ''
}

function Set-PvMode([string]$mode, [string]$msg = '') {
    $p = $script:Pv; $p.Mode = $mode
    $isPic = ($mode -in 'image', 'pdf')
    $p.PnlImg.Visible = $isPic; $p.Txt.Visible = ($mode -in 'text', 'folder', 'info'); $p.MediaPanel.Visible = ($mode -eq 'media')
    $p.BMinus.Visible = $p.LZoom.Visible = $p.BPlus.Visible = $p.BFit.Visible = $p.B100.Visible = ($isPic -or $mode -eq 'text')
    $p.BPrev.Visible = $p.LPage.Visible = $p.BNext.Visible = (($mode -eq 'pdf') -or ($mode -eq 'image' -and $p.Pages -gt 1))
    $p.BPlay.Visible = $p.Seek.Visible = $p.LTime.Visible = ($mode -eq 'media')
    if ($mode -in 'info') { $p.Txt.Font = New-Object Drawing.Font('Segoe UI', [single]12) }
    if ($mode -in 'text', 'folder') { $p.Txt.Font = New-Object Drawing.Font('Consolas', [single]$p.TextSize) }
    if ($msg) { $p.Txt.Text = $msg }
}

function Set-PvZoom([double]$z) {
    $p = $script:Pv; if (-not $p) { return }
    if ($p.Mode -eq 'text') {
        if ($z -le 0) { $z = 1.0 }
        $p.TextSize = [math]::Max(6.0, [math]::Min(40.0, 11.0 * $z)); $p.Zoom = $z
        $p.Txt.Font = New-Object Drawing.Font('Consolas', [single]$p.TextSize); $p.LZoom.Text = "$([int]($z * 100))%"
        return
    }
    if ($p.Mode -eq 'pdf') {
        if ($z -le 0) {   # fit the page width
            $pw = [math]::Max(100, $p.PnlImg.ClientSize.Width - 24); $z = $pw / [math]::Max(1.0, $p.PageW96)   # 24 px leaves room for the vertical scroll bar
        } else { $p.Fit = $false }
        $p.Zoom = [math]::Max(0.1, [math]::Min(6.0, $z)); $p.LZoom.Text = "$([int]($p.Zoom * 100))%"
        Show-PvPdfPage; return
    }
    if (-not $p.Bmp) { return }
    if ($z -le 0) {
        $zw = ($p.PnlImg.ClientSize.Width - 4) / [double]$p.Bmp.Width; $zh = ($p.PnlImg.ClientSize.Height - 4) / [double]$p.Bmp.Height
        $z = [math]::Min([math]::Min($zw, $zh), 1.0)
    } else { $p.Fit = $false }
    $p.Zoom = [math]::Max(0.02, [math]::Min(16.0, $z)); $p.LZoom.Text = "$([int]($p.Zoom * 100))%"
    $p.Pic.Size = New-Object Drawing.Size([int][math]::Max(1, $p.Bmp.Width * $p.Zoom), [int][math]::Max(1, $p.Bmp.Height * $p.Zoom))
    $p.Pic.Image = $p.Bmp
}

function Show-PvPdfPage {
    $p = $script:Pv; if (-not $p.Doc) { return }
    # showing the page can resize the panel (scroll bars), which asks for another render: never nest, the bitmap would be disposed under our feet
    if ($p.Rendering) { return }
    $p.Rendering = $true
    $p.Form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try {
        $page = $p.Doc.GetPage([uint32]$p.Page)
        $w = [uint32][math]::Max(50, [math]::Min(7000, $p.PageW96 * $p.Zoom))
        $opt = New-Object Windows.Data.Pdf.PdfPageRenderOptions; $opt.DestinationWidth = $w
        $ms = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
        Await-PvAction ($page.RenderToStreamAsync($ms, $opt))
        $st = [IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($ms)
        $img = [Drawing.Image]::FromStream($st)
        $bmp = New-Object Drawing.Bitmap($img); $img.Dispose(); $st.Dispose(); $ms.Dispose(); $page.Dispose()
        $p.Pic.Image = $null   # the picture box must let go of the old bitmap before it is disposed
        if ($p.Bmp) { $p.Bmp.Dispose() }
        $p.Bmp = $bmp; $p.Pic.Size = New-Object Drawing.Size([int]$w, [int]($w * $bmp.Height / [math]::Max(1, $bmp.Width))); $p.Pic.Image = $bmp   # shown at the asked width, whatever pixel size Windows rendered
        $p.LPage.Text = "Page $($p.Page + 1) of $($p.Pages)"
    } catch { $p.Txt.Text = "This page could not be shown: $($_.Exception.Message)"; Set-PvMode 'info' } finally { $p.Rendering = $false; $p.Form.Cursor = [Windows.Forms.Cursors]::Default }
}

function Step-PvPage([int]$d) {
    $p = $script:Pv; if (-not $p -or $p.Pages -lt 2) { return }
    $n = $p.Page + $d; if ($n -lt 0 -or $n -ge $p.Pages) { return }
    $p.Page = $n
    if ($p.Mode -eq 'pdf') { Show-PvPdfPage }
    elseif ($p.Mode -eq 'image' -and $p.Img) {   # multi-page TIFF
        [void]$p.Img.SelectActiveFrame([Drawing.Imaging.FrameDimension]::Page, $n)
        $p.Pic.Image = $null
        if ($p.Bmp) { $p.Bmp.Dispose() }
        $p.Bmp = New-Object Drawing.Bitmap($p.Img); $p.LPage.Text = "Page $($n + 1) of $($p.Pages)"
        Set-PvZoom $(if ($p.Fit) { 0 } else { $p.Zoom })
    }
}

function Show-Preview([string]$path, [bool]$isDir, [string]$note = '') {
    if (-not $script:Pv) { [void](New-PvWindow) }
    $p = $script:Pv
    if (-not $p.Form.Visible) { $p.Form.Show($form) }
    Clear-PvContent
    $p.Path = $path; $p.IsDir = $isDir; $p.Page = 0; $p.Pages = 0; $p.Fit = $true
    $meta = ''
    try {
        if ($isDir) { $di = New-Object IO.DirectoryInfo($path); $meta = "folder, changed $($di.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))" }
        else { $fi = New-Object IO.FileInfo($path); $meta = "$(Format-Size $fi.Length), modified $($fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))" }
    } catch { Write-ErrLog $_ }
    $p.Title.Text = "$note$path`r`n$meta"
    $p.Form.Text = "Preview - $([IO.Path]::GetFileName($path.TrimEnd('\')))"
    $p.Form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try {
        if (-not ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path))) { Set-PvMode 'info' 'This file is not there any more.'; return }
        $kind = Get-PvKind $path $isDir
        if ($kind -eq 'sniff') { $t = ''; $isT = $false; try { $t = Read-PvText $path ([ref]$isT) } catch { Write-ErrLog $_ }; if ($isT) { $kind = 'text'; $p.SniffText = $t } else { $kind = 'binary' } } else { $p.SniffText = $null }
        switch ($kind) {
            'folder' {
                $lines = New-Object 'System.Collections.Generic.List[string]'; $n = 0
                foreach ($e in [IO.Directory]::EnumerateFileSystemEntries($path, '*', [IO.SearchOption]::AllDirectories)) {
                    $n++; if ($n -gt 400) { $lines.Add('... (more entries not listed)'); break }
                    $rel = $e.Substring($path.TrimEnd('\').Length + 1)
                    if ([IO.Directory]::Exists($e)) { $lines.Add("[folder]  $rel") } else { $lines.Add(("{0,12}  {1}" -f (Format-Size ([IO.FileInfo]$e).Length), $rel)) }
                }
                Set-PvMode 'folder' ("Contents of this folder:`r`n`r`n" + ($lines -join "`r`n"))
            }
            'image' {
                $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
                if ($ext -in '.webp', '.heic') { Set-PvMode 'info' "This picture format ($ext) cannot be shown here.`r`nUse 'Open with default app'."; return }
                if (([IO.FileInfo]$path).Length -gt 300MB) { Set-PvMode 'info' 'This picture is too large to preview.'; return }
                $bytes = [IO.File]::ReadAllBytes($path); $ms = New-Object IO.MemoryStream(, $bytes)
                $p.Img = [Drawing.Image]::FromStream($ms, $true, $false)
                $p.Pages = try { $p.Img.GetFrameCount([Drawing.Imaging.FrameDimension]::Page) } catch { 1 }
                $p.Bmp = New-Object Drawing.Bitmap($p.Img)
                if ($p.Pages -le 1) { $p.Img.Dispose(); $p.Img = $null } else { $p.LPage.Text = "Page 1 of $($p.Pages)" }
                Set-PvMode 'image'; Set-PvZoom 0
            }
            'pdf' {
                if (-not (Initialize-PvPdf)) { Set-PvMode 'info' 'PDF preview is not available on this computer.'; return }
                $sf = Await-PvOp ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
                $p.Doc = Await-PvOp ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($sf)) ([Windows.Data.Pdf.PdfDocument])
                $p.Pages = [int]$p.Doc.PageCount
                $pg = $p.Doc.GetPage([uint32]0); $p.PageW96 = [double]$pg.Size.Width * 96.0 / 72.0; $pg.Dispose()
                Set-PvMode 'pdf'; Set-PvZoom 0
            }
            'text' {
                $t = $p.SniffText; if ($null -eq $t) { $isT = $false; $t = Read-PvText $path ([ref]$isT) }
                Set-PvMode 'text' $t; $p.Zoom = 1.0; $p.LZoom.Text = '100%'
            }
            'media' {
                if (-not $p.Media) {
                    try {
                        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, WindowsFormsIntegration
                        $p.Host = New-Object Windows.Forms.Integration.ElementHost; $p.Host.Dock = 'Fill'
                        $p.Media = New-Object Windows.Controls.MediaElement; $p.Media.LoadedBehavior = 'Manual'; $p.Media.UnloadedBehavior = 'Manual'; $p.Media.Stretch = 'Uniform'
                        $p.Host.Child = $p.Media; $p.MediaPanel.Controls.Add($p.Host)
                    } catch { Set-PvMode 'info' 'Video/audio preview is not available on this computer.'; return }
                }
                Set-PvMode 'media'
                $p.Media.Source = New-Object Uri($path); $p.Media.Play(); $p.Playing = $true; $p.BPlay.Text = 'Pause'; $p.LTime.Text = ''; $p.Seek.Value = 0
                $p.Timer.Start()
            }
            default { Set-PvMode 'info' "No preview for this kind of file.`r`n`r`nUse 'Open with default app' to see it." }
        }
    } catch {
        $msg = $_.Exception.Message
        Set-PvMode 'info' "This file could not be previewed:`r`n$msg"
    } finally { $p.Form.Cursor = [Windows.Forms.Cursors]::Default }
}

$script:PvTimer = New-Object Windows.Forms.Timer; $script:PvTimer.Interval = 200
$script:PvTimer.Add_Tick({
    $script:PvTimer.Stop()
    if (-not $script:Pv -or -not $script:Pv.Form.Visible) { return }
    Show-PreviewSelected
})
function Show-PreviewSelected {
    if ($script:SP -and $tabs.SelectedTab.Controls[0].Tag -eq 'Folder') {   # three-pane Folders tab: big preview window for the file chosen in the blue panel
        $n = $script:SP.Tv.SelectedNode
        if ($n -and $n.Tag -and $n.Tag.Path) { Show-Preview $n.Tag.Path ([bool]$n.Tag.Dir) '' }
        elseif ($script:SpBrowse) { Show-Preview $script:SpBrowse.Path $true '' }
        return
    }
    $lv = $tabs.SelectedTab.Controls[0]
    if (-not $lv.SelectedItems.Count) { return }
    $lvi = $lv.SelectedItems[0]; $it = $lvi.Tag
    $note = ''
    try { if ($lvi.SubItems[4].Text) { $note = "[$($lvi.SubItems[4].Text)]  " } } catch { Write-ErrLog $_ }
    Show-Preview $it.Path ($lv.Tag -eq 'Folder') $note
}

$btnRestoreList.Add_Click({ Show-RestoreListDialog })
$btnPreview.Add_Click({ Show-PreviewSelected })
$btnVerify.Add_Click({ Show-VerifyDialog })
# ---- three main tabs: 1 Scanning, 2 Processing, 3 Settings (the controls above are moved into them)
function New-Card([string]$title, [string]$hint = '') {
    $sc = Get-Sc
    $c = New-Object Windows.Forms.TableLayoutPanel
    $c.Name = 'card'; $c.Tag = $title; $c.ColumnCount = 1; $c.AutoSize = $true; $c.AutoSizeMode = 'GrowAndShrink'; $c.Dock = 'Fill'; $c.BackColor = $script:UiPanel
    $c.Padding = New-Object Windows.Forms.Padding([int](16 * $sc), [int](12 * $sc), [int](16 * $sc), [int](14 * $sc))
    $c.Margin = New-Object Windows.Forms.Padding(0, 0, 0, [int](12 * $sc))
    [void]$c.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    $t = New-Object Windows.Forms.Label; $t.Text = $title; $t.AutoSize = $true; $t.ForeColor = $script:UiText
    $t.Font = New-Object Drawing.Font('Segoe UI', 12.5, [Drawing.FontStyle]::Bold); $t.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 2)
    [void]$c.Controls.Add($t)
    if ($hint) {
        $h = New-Object Windows.Forms.Label; $h.Text = $hint; $h.AutoSize = $true; $h.ForeColor = $script:UiMuted; $h.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 8)
        [void]$c.Controls.Add($h)
    }
    Enable-CardDrag $c
    Set-Round $c 14 $script:UiLine
    $c
}
function New-MainPage([string]$title) {
    $tp = New-Object Windows.Forms.TabPage $title
    $tp.UseVisualStyleBackColor = $false; $tp.BackColor = $script:UiBg
    $tp.Padding = New-Object Windows.Forms.Padding([int](14 * (Get-Sc)))
    $tp
}
# cards can be moved: drag a card by its title up or down; the order is remembered
$script:DragCard = $null; $script:DragTo = -1; $script:DragPaint = @{}
function Get-Cards($tbl) { @($tbl.Controls | Where-Object { $_.Name -eq 'card' } | Sort-Object { $tbl.GetRow($_) }) }
function Get-CardOrder($tbl) { @(Get-Cards $tbl | ForEach-Object { [string]$_.Tag }) }
function Set-CardOrder($tbl, $order) {
    $cards = @(Get-Cards $tbl); $new = New-Object System.Collections.ArrayList
    foreach ($t in $order) { foreach ($c in $cards) { if ([string]$c.Tag -eq [string]$t -and -not $new.Contains($c)) { [void]$new.Add($c) } } }
    foreach ($c in $cards) { if (-not $new.Contains($c)) { [void]$new.Add($c) } }
    $tbl.SuspendLayout(); foreach ($c in $cards) { $tbl.Controls.Remove($c) }
    $i = 0; foreach ($c in $new) { [void]$tbl.Controls.Add($c, 0, $i); $i++ }
    $tbl.ResumeLayout($true)
}
function Move-Card($card, [int]$to) {   # $to = the slot (0..count) the card is dropped in front of
    $tbl = $card.Parent; $cards = @(Get-Cards $tbl); $old = [array]::IndexOf($cards, $card)
    $rest = New-Object System.Collections.ArrayList; foreach ($c in $cards) { if ($c -ne $card) { [void]$rest.Add($c) } }
    $pos = $to; if ($old -lt $to) { $pos-- }; $pos = [Math]::Max(0, [Math]::Min($rest.Count, $pos)); $rest.Insert($pos, $card)
    Set-CardOrder $tbl @($rest | ForEach-Object { [string]$_.Tag })
}
function Enable-CardDrag($card) {
    $h = $card.Controls[0]; $h.Cursor = [Windows.Forms.Cursors]::SizeAll; $tip.SetToolTip($h, 'Drag this title up or down to move the card')
    $h.Add_MouseDown({ param($s, $e)
        if ($e.Button -ne 'Left') { return }
        $script:DragCard = $s.Parent; $script:DragTo = -1; $s.Capture = $true
        $tbl = $s.Parent.Parent
        if ($tbl -and -not $script:DragPaint[$tbl.GetHashCode()]) {
            $script:DragPaint[$tbl.GetHashCode()] = $true
            $tbl.Add_Paint({ param($tx, $pe) $y = $tx.Tag; if ($y -is [int] -and $y -ge 0) { $pn = New-Object Drawing.Pen $script:UiAccent, ([single](3 * (Get-Sc))); $pe.Graphics.DrawLine($pn, 8, $y, ($tx.Width - 8), $y); $pn.Dispose() } })
        }
    })
    $h.Add_MouseMove({ param($s, $e)
        $c = $script:DragCard; if (-not $c -or -not $s.Capture) { return }
        $tbl = $c.Parent; $y = $tbl.PointToClient([Windows.Forms.Cursor]::Position).Y
        $cards = @(Get-Cards $tbl); $to = $cards.Count
        for ($i = 0; $i -lt $cards.Count; $i++) { if ($y -lt ($cards[$i].Top + $cards[$i].Height / 2)) { $to = $i; break } }
        $script:DragTo = $to
        $ly = if ($to -lt $cards.Count) { $cards[$to].Top - [int](6 * (Get-Sc)) } else { $cards[$cards.Count - 1].Bottom + [int](6 * (Get-Sc)) }
        $tbl.Tag = [int]$ly; $tbl.Invalidate()
    })
    $h.Add_MouseUp({ param($s, $e)
        $c = $script:DragCard; $script:DragCard = $null; $s.Capture = $false
        if (-not $c) { return }
        $tbl = $c.Parent; $tbl.Tag = $null; $tbl.Invalidate()
        if ($script:DragTo -ge 0) { Move-Card $c $script:DragTo; if ($script:LayoutReady) { Save-Layout } }
    })
}
$msc = Get-Sc
$main = New-Object FlatTabs; $main.BackColor = $script:UiBg
$main.Dock = 'Fill'; $main.DrawMode = 'OwnerDrawFixed'; $main.SizeMode = 'Fixed'
$main.Inset = 3; $main.Radius = [int](12 * $msc); $main.ItemSize = New-Object Drawing.Size([int](230 * $msc), [int](46 * $msc)); $main.Font = New-Object Drawing.Font('Segoe UI', 12)
$main.Add_DrawItem({
    param($s, $e)
    $sel = ($s.SelectedIndex -eq $e.Index); $r = $e.Bounds
    $bg = New-Object Drawing.SolidBrush $script:UiBg; $e.Graphics.FillRectangle($bg, ($r.X - 3), ($r.Y - 3), ($r.Width + 6), ($r.Height + 6)); $bg.Dispose()
    $e.Graphics.SmoothingMode = 'AntiAlias'; $pr = New-Object Drawing.Rectangle(($r.X + 4), ($r.Y + 4), ($r.Width - 9), ($r.Height - 8)); $gp = [Dk]::RoundPath($pr, [int](12 * (Get-Sc)))
    $pf = New-Object Drawing.SolidBrush ($(if ($sel) { $script:UiAccentBg } else { $script:UiPanel })); $e.Graphics.FillPath($pf, $gp); $pf.Dispose()
    $pp = New-Object Drawing.Pen ($(if ($sel) { $script:UiAccentLine } else { $script:UiLine })), 1.5; $e.Graphics.DrawPath($pp, $gp); $pp.Dispose(); $gp.Dispose()
    $f = if ($sel) { New-Object Drawing.Font($s.Font, [Drawing.FontStyle]::Bold) } else { $s.Font }
    $br = New-Object Drawing.SolidBrush ($(if ($sel) { $script:UiAccent } else { $script:UiMuted }))
    $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $e.Graphics.DrawString($s.TabPages[$e.Index].Text, $f, $br, [Drawing.RectangleF]$r, $sf)
    if ($sel) { $f.Dispose() }
    $br.Dispose(); $sf.Dispose()
})

# ---- 1. Scanning: folders, scan buttons, progress, and the space chart
$pgScan = New-MainPage '1   Scanning'
$scanS = New-Split 'Vertical' 0.66
$scL = New-Table 1 3
[void]$scL.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
[void]$scL.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))); [void]$scL.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))); [void]$scL.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
$cardRoots = New-Card 'Folders to scan' 'Drag folders onto the list, or press Add folder.'
$bodyRoots = New-Table 2 1; $bodyRoots.AutoSize = $true; $bodyRoots.AutoSizeMode = 'GrowAndShrink'
[void]$bodyRoots.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100))); [void]$bodyRoots.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize'))); [void]$bodyRoots.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
$lstRoots.ForeColor = $script:UiText
$lstRoots.BorderStyle = 'None'; $lstRoots.Dock = 'Fill'; $lstRoots.BackColor = $script:UiBg
$hostRoots = New-Object Windows.Forms.Panel; $hostRoots.Name = 'rh'; $hostRoots.Dock = 'Fill'; $hostRoots.Height = [int](150 * $msc); $hostRoots.BackColor = $script:UiBg; $hostRoots.Padding = New-Object Windows.Forms.Padding([int](10 * $msc), [int](8 * $msc), [int](6 * $msc), [int](6 * $msc)); $hostRoots.Margin = New-Object Windows.Forms.Padding(4)
$hostRoots.Controls.Add($lstRoots); Set-Round $hostRoots 10 $script:UiLine
[void]$bodyRoots.Controls.Add($hostRoots, 0, 0); [void]$bodyRoots.Controls.Add($fBtns, 1, 0)
[void]$cardRoots.Controls.Add($bodyRoots)
$cardScan = New-Card 'Scan'
$fScan.FlowDirection = 'LeftToRight'; $fScan.WrapContents = $true
$btnSee = New-Btn 'See the results  >'
$btnSee.Add_Click({ $main.SelectedTab = $pgProc })
$fScan.Controls.Add($btnSee)
$btnScan.Text = 'Start scan'
[void]$cardScan.Controls.Add($fScan)
$prog.Dock = 'Fill'; $prog.Height = [int](14 * $msc); $prog.Margin = New-Object Windows.Forms.Padding(4, 10, 4, 6)
[void]$cardScan.Controls.Add($prog); [void]$cardScan.Controls.Add($lblEta); [void]$cardScan.Controls.Add($lblStatus); [void]$cardScan.Controls.Add($lblSaved)
$lblStatus.ForeColor = $script:UiMuted
[void]$scL.Controls.Add($cardRoots, 0, 0); [void]$scL.Controls.Add($cardScan, 0, 1)
$cardChart = New-Object Windows.Forms.Panel
$cardChart.Dock = 'Fill'; $cardChart.BackColor = $script:UiPanel; $cardChart.Padding = New-Object Windows.Forms.Padding([int](8 * $msc))
$cardChart.Margin = New-Object Windows.Forms.Padding([int](14 * $msc), 0, 0, [int](12 * $msc))
Set-Round $cardChart 14 $script:UiLine
$chart.BackColor = $script:UiPanel; $chart.Margin = New-Object Windows.Forms.Padding(0)
$cardChart.Controls.Add($chart)
$scL.Dock = 'Fill'; $scanS.Panel1.Controls.Add($scL)
$cardChart.Dock = 'Fill'; $cardChart.Margin = New-Object Windows.Forms.Padding(0); $scanS.Panel2.Padding = New-Object Windows.Forms.Padding(0, 0, 0, [int](12 * $msc)); $scanS.Panel2.Controls.Add($cardChart)
$pgScan.Controls.Add($scanS)

# ---- 2. Processing: the duplicate lists, the keep / select buttons and Apply
$pgProc = New-MainPage '2   Processing'
# the lists above, the buttons below, with a draggable bar between them (the bottom part keeps its height when the window is resized)
$procS = New-Object Windows.Forms.SplitContainer; $procS.Dock = 'Fill'; $procS.Orientation = 'Horizontal'; $procS.FixedPanel = 'Panel2'
Style-Split $procS
try { $procS.Panel2MinSize = [int](70 * $msc) } catch { Write-ErrLog $_ }
$procS.Tag = 'default'
$script:ProcS = $procS; $script:Bottom = $bottom
$tabs.Dock = 'Fill'; $procS.Panel1.Controls.Add($tabs)
$bottom.Controls.Remove($grp)
$lnkAct = New-Object Windows.Forms.LinkLabel
$lnkAct.AutoSize = $true; $lnkAct.Margin = New-Object Windows.Forms.Padding(4, 6, 4, 8); $lnkAct.LinkColor = $script:UiAccent; $lnkAct.ActiveLinkColor = $script:UiAccentDark
$bottom.Controls.Add($lnkAct, 0, 2); $bottom.SetColumnSpan($lnkAct, 2)
# Apply / Undo / Restore join the keep buttons on one row, and the section gets shorter
$bottom.Controls.Remove($fGo); $fGo.FlowDirection = 'LeftToRight'; $fGo.WrapContents = $false; $fGo.AutoSize = $true; $fGo.Margin = New-Object Windows.Forms.Padding(0)
foreach ($bx in $btnApply, $btnUndo, $btnRestoreList) { $bx.MinimumSize = New-Object Drawing.Size(0, 0) }
$bottom.SetColumnSpan($fKeep, 1); $bottom.Controls.Add($fGo, 1, 1)
function Update-ActionNote {
    $m = if ($rbRecycle.Checked) { 'send to the Recycle Bin' } elseif ($rbPerm.Checked) { 'delete permanently (cannot be undone)' } else { 'move to the quarantine folder (undoable)' }
    $lnkAct.Text = "Checked items will: $m.   Change in Settings"
    $lnkAct.LinkArea = New-Object Windows.Forms.LinkArea(($lnkAct.Text.Length - 'Change in Settings'.Length), 'Change in Settings'.Length)
}
foreach ($rb in $rbMove, $rbRecycle, $rbPerm) { $rb.Add_CheckedChanged({ Update-ActionNote }) }
$lnkAct.Add_LinkClicked({ $main.SelectedTab = $pgSet })
Update-ActionNote
$bottom.Dock = 'Top'; $procS.Panel2.AutoScroll = $true; $procS.Panel2.Controls.Add($bottom)
$pgProc.Controls.Add($procS)
function Set-ProcBottom($v) {   # height of the bottom section in 96-dpi pixels; $null = its natural height
    $s = $script:ProcS; $k = Get-Sc
    $script:ProcAuto = ($null -eq $v)
    if ($s.Height -lt 400) { $s.Tag = $(if ($null -eq $v) { 'default' } else { [double]$v }); return }
    $s.Tag = $null; $script:ProcSetting = $true
    $h = if ($null -eq $v) { $script:Bottom.GetPreferredSize((New-Object Drawing.Size([Math]::Max(300, $s.Width), 0))).Height + [int](8 * $k) } else { [int]($v * $k) }
    try { $s.SplitterDistance = [Math]::Max(120, $s.Height - $h - $s.SplitterWidth) } catch { Write-ErrLog $_ }
    $script:ProcSetting = $false
}
$script:ProcAuto = $true; $script:ProcSetting = $false
# only a real mouse drag of the bar fixes the height; until then it follows the natural height of the buttons
$procS.Add_MouseDown({ param($s, $e) $script:ProcDrag = ($e.Button -eq 'Left' -and $s.SplitterRectangle.Contains($e.Location)) })
$procS.Add_MouseUp({ param($s, $e) if ($script:ProcDrag) { $script:ProcDrag = $false; $script:ProcAuto = $false; if ($script:LayoutReady) { Save-Layout } } })
$procS.Add_SizeChanged({ param($s, $e) if ($script:ProcAuto -and $null -eq $s.Tag -and $s.Height -ge 400) { Set-ProcBottom $null } elseif ($null -ne $s.Tag) { Set-ProcBottom $(if ($s.Tag -is [double]) { $s.Tag } else { $null }) } })

# ---- 3. Settings: what to look for, what to skip, what happens to checked items, text size
$pgSet = New-MainPage '3   Settings'
$setT = New-Object Windows.Forms.TableLayoutPanel
$setT.Dock = 'Fill'; $setT.AutoScroll = $true; $setT.ColumnCount = 1
[void]$setT.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
$setS = New-Split 'Vertical' 0.6
$c1 = New-Card 'What to look for' 'Both are searched in one scan. Files and folders are compared by SHA256 of their contents, never by name.'
$f1 = New-Flow 'TopDown'; $f1.Controls.AddRange(@($chkFiles, $chkFolders, $fMin)); [void]$c1.Controls.Add($f1)
$c2 = New-Card 'What to skip' 'Skipped items are never offered as duplicates.'
$f2 = New-Flow 'TopDown'; $f2.Controls.AddRange(@($chkExcl, $chkPlace)); [void]$c2.Controls.Add($f2)
$c3 = New-Card 'Speed'
$f3 = New-Flow 'TopDown'; $f3.Controls.Add($chkCache); [void]$c3.Controls.Add($f3)
$c4 = New-Card 'When you press Apply or Delete now' 'What happens to the checked copies.'
$gt.Dock = 'Fill'; [void]$c4.Controls.Add($gt)
$c5 = New-Card 'List text size' 'Also works with Ctrl + mouse wheel on a list.'
$f5 = New-Flow 'LeftToRight'
$bTs = New-Btn 'A-  Smaller'; $bTb = New-Btn 'A+  Bigger'
foreach ($b in $bTs, $bTb) { $b.MinimumSize = New-Object Drawing.Size(0, 0) }
$bTs.Add_Click({ Set-ListFont ($script:ListFontSize - 1) }); $bTb.Add_Click({ Set-ListFont ($script:ListFontSize + 1) })
$f5.Controls.AddRange(@($bTs, $bTb)); [void]$c5.Controls.Add($f5)
$c6 = New-Card 'Layout' 'Drag the bars between panes to resize them, and drag a card by its title to move it. Your layout is remembered.'
$f6 = New-Flow 'LeftToRight'
$bReset = New-Btn 'Reset layout'; $bReset.MinimumSize = New-Object Drawing.Size(0, 0)
$bReset.Add_Click({ Reset-Layout })
$f6.Controls.Add($bReset); [void]$c6.Controls.Add($f6)
$c7 = New-Card 'Open files with' 'The program used by the Open button, double-click and right-click Open. Pick a type, then choose a program; types without their own program use "All files", then the Windows default.'
$f7 = New-Flow 'LeftToRight'
$cbOw = New-Object Windows.Forms.ComboBox; $cbOw.DropDownStyle = 'DropDownList'; $cbOw.Width = [int](220 * $msc); [void]$cbOw.Items.AddRange(@($script:OpenCats.Values)); $cbOw.SelectedIndex = 0
$lblOw = New-Object Windows.Forms.Label; $lblOw.AutoSize = $true; $lblOw.Margin = New-Object Windows.Forms.Padding(8, 10, 8, 4); $lblOw.ForeColor = $script:UiMuted
$bOwPick = New-Btn 'Choose program...'; $bOwReset = New-Btn 'Use Windows default'
foreach ($b in $bOwPick, $bOwReset) { $b.MinimumSize = New-Object Drawing.Size(0, 0) }
$script:OwCombo = $cbOw; $script:OwLabel = $lblOw
function Update-OwLabel { $k = @($script:OpenCats.Keys)[$script:OwCombo.SelectedIndex]; $v = $script:OpenWith[$k]; $script:OwLabel.Text = $(if ($v) { $v } else { 'Windows default' }) }
$cbOw.Add_SelectedIndexChanged({ Update-OwLabel })
$bOwPick.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog; $dlg.Title = 'Choose the program that opens these files'; $dlg.Filter = 'Programs (*.exe)|*.exe'; $dlg.CheckFileExists = $true
    if ($dlg.ShowDialog() -eq 'OK') { $k = @($script:OpenCats.Keys)[$script:OwCombo.SelectedIndex]; $script:OpenWith[$k] = $dlg.FileName; Update-OwLabel; Save-Settings }
})
$bOwReset.Add_Click({ $k = @($script:OpenCats.Keys)[$script:OwCombo.SelectedIndex]; [void]$script:OpenWith.Remove($k); Update-OwLabel; Save-Settings })
Update-OwLabel
$f7.Controls.AddRange(@($cbOw, $bOwPick, $bOwReset)); [void]$c7.Controls.Add($f7); [void]$c7.Controls.Add($lblOw)
$i = 0; foreach ($c in $c1, $c2, $c3, $c4, $c5, $c6, $c7) { [void]$setT.Controls.Add($c, 0, $i); $i++ }
foreach ($k in 1..7) { [void]$setT.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))) }
$setT.RowCount = 8; [void]$setT.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))   # empty last row keeps the cards at their own height
$setS.Panel1.Controls.Add($setT); $pgSet.Controls.Add($setS)
$hintS = New-Object Windows.Forms.Label; $hintS.Text = 'Drag the bar on the left to make the cards wider or narrower.'; $hintS.AutoSize = $true; $hintS.ForeColor = $script:UiMuted; $hintS.AutoSize = $false; $hintS.Dock = 'Top'; $hintS.Height = [int](60 * $msc); $hintS.Padding = New-Object Windows.Forms.Padding(12); $setS.Panel2.Controls.Add($hintS)

# remembered layout: pane sizes and card order, saved when anything is moved; "Reset layout" brings back the defaults
$script:LayoutFile = Join-Path $env:LOCALAPPDATA 'DupCleaner\layout.json'
$script:LayoutDefault = @{ ProcBottom = 0; ScanSplit = 0.66; SetSplit = 0.6; Sets = @(0.26, 0.42, 0.5); ScanOrder = @(Get-CardOrder $scL); SetOrder = @(Get-CardOrder $setT) }
function Get-LayoutState {
    $pt = $script:ProcS.Tag; $pb = $(if ($script:ProcAuto) { 0 } elseif ($pt -is [double]) { $pt } elseif ($pt) { 0 } else { [Math]::Round($script:ProcS.Panel2.Height / (Get-Sc)) })
    @{ ProcBottom = $pb; ScanSplit = (Get-SplitShare $scanS); SetSplit = (Get-SplitShare $setS); ScanOrder = @(Get-CardOrder $scL); SetOrder = @(Get-CardOrder $setT); Sets = @($script:SP.Splits | ForEach-Object { Get-SplitShare $_ }) }
}
function Set-LayoutState($o) {
    try {
        Set-ProcBottom $(if ($o.ProcBottom -and [double]$o.ProcBottom -gt 20) { [double]$o.ProcBottom } else { $null })
        Set-SplitShare $scanS ([double]$o.ScanSplit); Set-SplitShare $setS ([double]$o.SetSplit)
        $i = 0; foreach ($v in @($o.Sets)) { if ($i -lt $script:SP.Splits.Count) { Set-SplitShare $script:SP.Splits[$i] ([double]$v) }; $i++ }
        Set-CardOrder $scL @($o.ScanOrder); Set-CardOrder $setT @($o.SetOrder)
    } catch { Write-CrashLog 'Set-LayoutState failed' $_.Exception }
}
function Save-Layout {
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path $script:LayoutFile))
        Add-Type -AssemblyName System.Web.Extensions
        $ser = New-Object Web.Script.Serialization.JavaScriptSerializer
        [IO.File]::WriteAllText($script:LayoutFile, $ser.Serialize((Get-LayoutState)), (New-Object Text.UTF8Encoding($false)))
    } catch { Write-CrashLog 'Save-Layout failed' $_.Exception }
}
function Load-Layout {
    try {
        if (-not (Test-Path -LiteralPath $script:LayoutFile)) { return }
        Add-Type -AssemblyName System.Web.Extensions
        $ser = New-Object Web.Script.Serialization.JavaScriptSerializer
        Set-LayoutState ($ser.DeserializeObject([IO.File]::ReadAllText($script:LayoutFile, [Text.Encoding]::UTF8)))
    } catch { Write-CrashLog 'Load-Layout failed' $_.Exception }
}
function Reset-Layout { Set-LayoutState $script:LayoutDefault; Save-Layout }
$form.Add_Shown({ if (Test-Path -LiteralPath $script:LayoutFile) { Load-Layout } else { Set-ProcBottom $null }; $script:LayoutReady = $true })

$main.TabPages.AddRange(@($pgScan, $pgProc, $pgSet))
$form.Controls.Remove($root); $form.Controls.Add($main)
# round the rest: lists, progress bar, preview area, date pickers, the bulk-delete button
Set-Round $prog 6
foreach ($lvx in $views.Values) { $lvx.BorderStyle = 'None'; Set-Round $lvx 12 }
Set-Round $script:SP.PvArea 12
Set-Round $script:SP.BtnMarked 8 $script:UiDelFg
foreach ($fcx in $script:FilterCtl.Values) { Set-Round $fcx.From 8; Set-Round $fcx.To 8 }
# tick box in the header of the file list
$tkL = New-Tick; $lvFile = $views['File']; $lvFile.Controls.Add($tkL); $tip.SetToolTip($tkL, 'Select all duplicates (the oldest copy of each is kept). Click again to clear every selection.')
$script:TickLv = $lvFile; $script:TickCtl = $tkL
$placeTick = { $lv = $script:TickLv; $tk = $script:TickCtl; if (-not $lv.IsHandleCreated) { return }; $hh = [Dk]::HeaderHeight($lv.Handle); if ($hh -lt 8) { $hh = [int](30 * (Get-Sc)) }; $tk.Location = New-Object Drawing.Point([int](5 * (Get-Sc)), [int](($hh - $tk.Height) / 2)); $tk.BringToFront() }
$lvFile.Add_SizeChanged($placeTick); $lvFile.Add_HandleCreated($placeTick); $lvFile.Add_ColumnWidthChanged($placeTick); $lvFile.Add_VisibleChanged($placeTick)
# every text box, number box and drop-down gets the same rounded, flat frame (drop-downs are drawn by hand and open a menu)
$script:DropMap = @{}
function New-DropHost($combo) {
    $sc = Get-Sc
    $h = New-Object Windows.Forms.Panel; $h.Name = 'rh'; $h.BackColor = $script:UiPanel; $h.Height = [int](36 * $sc); $mw = 0; foreach ($it in $combo.Items) { $mw = [Math]::Max($mw, [Windows.Forms.TextRenderer]::MeasureText([string]$it, $combo.Font).Width) }; $h.Width = [Math]::Max($combo.Width, $mw + [int](50 * $sc)); $h.Cursor = [Windows.Forms.Cursors]::Hand; $h.Font = $combo.Font
    Set-Round $h 9 $script:UiLine
    $script:DropMap[$h.GetHashCode()] = $combo; $script:DropMap[$combo.GetHashCode()] = $h
    $h.Add_Paint({
        param($s, $e)
        $sc2 = (Get-Sc); $cb = $script:DropMap[$s.GetHashCode()]
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$cb.SelectedItem, $s.Font, (New-Object Drawing.Rectangle([int](10 * $sc2), 0, ($s.Width - [int](36 * $sc2)), $s.Height)), $(if ($cb.Enabled) { $script:UiText } else { $script:UiMuted }), [Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, NoPrefix')
        $e.Graphics.SmoothingMode = 'AntiAlias'; $pn = New-Object Drawing.Pen $script:UiMuted, ([single](1.2 * $sc2)); $cx = $s.Width - [int](18 * $sc2); $cy = [int]($s.Height / 2); $d = [int](4 * $sc2)
        $e.Graphics.DrawLines($pn, @((New-Object Drawing.Point(($cx - $d), ($cy - [int]($d / 2)))), (New-Object Drawing.Point($cx, ($cy + [int]($d / 2)))), (New-Object Drawing.Point(($cx + $d), ($cy - [int]($d / 2)))))); $pn.Dispose()
    })
    $h.Add_Click({
        param($s, $e)
        $cb = $script:DropMap[$s.GetHashCode()]; if (-not $cb.Enabled) { return }
        $m = New-Object Windows.Forms.ContextMenuStrip; $m.BackColor = $script:UiPanel; $m.ForeColor = $script:UiText; $m.ShowImageMargin = $false; $m.Font = $s.Font
        for ($i = 0; $i -lt $cb.Items.Count; $i++) { $mi = $m.Items.Add([string]$cb.Items[$i]); $mi.Tag = @($cb, $i); $mi.BackColor = $script:UiPanel; $mi.ForeColor = $script:UiText; $mi.Add_Click({ param($s2, $e2) $s2.Tag[0].SelectedIndex = [int]$s2.Tag[1] }) }
        $m.MinimumSize = New-Object Drawing.Size($s.Width, 0); $m.Show($s, (New-Object Drawing.Point(0, $s.Height)))
    })
    $combo.Add_SelectedIndexChanged({ param($s, $e) $script:DropMap[$s.GetHashCode()].Invalidate() })
    $combo.Add_EnabledChanged({ param($s, $e) $script:DropMap[$s.GetHashCode()].Invalidate() })
    $h
}
function Wrap-Field($x) {
    $par = $x.Parent; if (-not $par -or $par.Name -eq 'rh') { return }
    $sc = Get-Sc
    $isCombo = $x -is [Windows.Forms.ComboBox]
    $pos = $null; $span = 1; $idx = $par.Controls.GetChildIndex($x); $loc = $x.Location; $dock = $x.Dock; $anchor = $x.Anchor; $margin = $x.Margin; $vis = [bool][Windows.Forms.Control].GetMethod('GetState', [Reflection.BindingFlags]'NonPublic,Instance', $null, [Type[]]@([int]), $null).Invoke($x, @(2))   # the control's own Visible flag (.Visible is false while its tab is not on screen)
    if ($par -is [Windows.Forms.TableLayoutPanel]) { $pos = $par.GetPositionFromControl($x); $span = $par.GetColumnSpan($x) }
    if ($isCombo) { $h = New-DropHost $x; $par.Controls.Remove($x) }
    else {
        $h = New-Object Windows.Forms.Panel; $h.Name = 'rh'; $h.BackColor = $script:UiPanel; $h.Height = [int](36 * $sc); $h.Width = $(if ($x -is [Windows.Forms.NumericUpDown]) { [int](110 * $sc) } else { [int]($x.Width * $sc) })
        $h.Padding = New-Object Windows.Forms.Padding([int](10 * $sc), [int](7 * $sc), [int](8 * $sc), [int](4 * $sc))
        try { $x.BorderStyle = 'None' } catch { Write-ErrLog $_ }
        $x.Dock = 'Fill'; $h.Controls.Add($x); Set-Round $h 9 $script:UiLine
    }
    $h.Margin = $margin; $h.Visible = $vis
    if ($dock -ne 'None') { $h.Dock = $dock } else { $h.Anchor = $anchor }
    if ($pos) { $par.Controls.Add($h, $pos.Column, $pos.Row); if ($span -gt 1) { $par.SetColumnSpan($h, $span) } }
    else { $par.Controls.Add($h); $par.Controls.SetChildIndex($h, $idx); $h.Location = $loc }
}
function Get-Fields($c) { foreach ($x in $c.Controls) { if ($x -is [Windows.Forms.TextBox] -or $x -is [Windows.Forms.ComboBox] -or $x -is [Windows.Forms.NumericUpDown]) { $x }; if ($x.Controls.Count -and $x.Name -ne 'rh') { Get-Fields $x } } }
foreach ($fx in @(Get-Fields $form)) { if (-not ($fx -is [Windows.Forms.TextBox] -and $fx.Multiline)) { Wrap-Field $fx } }
# colours and dark scroll bars for the lists, boxes and fields (everything created above)
function Set-Themed($c) {
    foreach ($x in $c.Controls) {
        $kind = $x.GetType().Name
        if ($kind -in 'TextBox', 'ComboBox', 'NumericUpDown', 'DateTimePicker', 'ListBox', 'ListView') {
            if ($x -ne $lstRoots) { $x.BackColor = $script:UiPanel }
            $x.ForeColor = $script:UiText
        }
        if ($script:Dark -and $kind -in 'TextBox', 'ComboBox', 'NumericUpDown', 'DateTimePicker', 'ListBox', 'ListView', 'TreeView') {
            $th = $(if ($kind -in 'ComboBox', 'NumericUpDown', 'DateTimePicker') { 'DarkMode_CFD' } elseif ($kind -eq 'ListView') { 'DarkMode_ItemsView' } else { 'DarkMode_Explorer' })
            $x.Add_HandleCreated({ param($s, $e) [Dk]::Theme($s.Handle, $(if ($s -is [Windows.Forms.ComboBox] -or $s -is [Windows.Forms.NumericUpDown] -or $s -is [Windows.Forms.DateTimePicker]) { 'DarkMode_CFD' } elseif ($s -is [Windows.Forms.ListView]) { 'DarkMode_ItemsView' } else { 'DarkMode_Explorer' })); if ($s -is [Windows.Forms.ListView]) { [Dk]::Header($s.Handle) } })
            if ($x.IsHandleCreated) { [Dk]::Theme($x.Handle, $th); if ($kind -eq 'ListView') { [Dk]::Header($x.Handle) } }
        }
        if ($x.Controls.Count) { Set-Themed $x }
    }
}
Set-Themed $form
if ($script:Dark) { $form.Add_HandleCreated({ [Dk]::Title($form.Handle) }) }foreach ($t in $tabs, $main) { [void]$t.Handle }   # a list tab that is not on screen yet must still know its selected page ($tabs.SelectedTab is used all over)
$tabs.SelectedIndex = 0; $main.SelectedTab = $pgProc   # the duplicates tab is the one that opens first
$tabs.Inset = 2; $tabs.Radius = [int](10 * $msc); $tabs.ItemSize = New-Object Drawing.Size([int](260 * $msc), [int](36 * $msc))
$tabs.Fit(); $main.Fit()
$tip.SetToolTip($btnSee,'Go to the Processing tab to look at the duplicates found so far')

$form.KeyPreview = $true
$form.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'F3') { Show-PreviewSelected; $e.Handled = $true }
})
$btnUndo.Add_Click({
    $d = New-Object Windows.Forms.OpenFileDialog
    $d.Title = 'Choose the manifest.csv of the move you want to undo'; $d.Filter = 'manifest.csv|manifest.csv'
    if (Test-Path -LiteralPath $txtQ.Text) { $d.InitialDirectory = $txtQ.Text }
    if ($d.ShowDialog() -ne 'OK') { return }
    $log = Restore-Manifest $d.FileName
    $lf = Join-Path ([IO.Path]::GetTempPath()) 'DupCleaner-last-undo.txt'
    $log | Set-Content -LiteralPath $lf -Encoding UTF8
    [void][Windows.Forms.MessageBox]::Show("Restore finished: $(@($log | Where-Object { $_ -like 'RESTORED*' }).Count) of $($log.Count) restored.`nLog: $lf", 'DupCleaner')
})

$form.Add_Shown({ Write-Heartbeat $true; Save-ListArchive $script:SessionFile; Restore-Session; Show-PreviousCrash })   # the archive step keeps a dated copy of the last finished list
if ($TestScan) {   # developer hook: add a folder, scan it, log the outcome, exit
    $form.Add_Shown({
        try {
            $lstRoots.Items.Clear(); Add-Root $TestScan
            $btnScan.PerformClick()
            Write-CrashLog 'TestScan finished' "status: $($lblStatus.Text)"
        } catch { Write-CrashLog 'TestScan failed' $_.Exception }
        $form.Close()
    })
}
if ($AutoScan) {   # start-up helper: replace the folder list with this folder and begin scanning (the window stays open)
    $form.Add_Shown({
        try { $lstRoots.Items.Clear(); Add-Root $AutoScan; $btnScan.PerformClick() } catch { Write-CrashLog 'AutoScan failed' $_.Exception }
    })
}
if ($ShotPath) {
    $form.Add_Shown({
        $form.Refresh(); [Windows.Forms.Application]::DoEvents()
        $bmp = New-Object Drawing.Bitmap $form.Width, $form.Height
        $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $bmp.Save($ShotPath); $form.Close()
    })
}
[void]$form.ShowDialog()















