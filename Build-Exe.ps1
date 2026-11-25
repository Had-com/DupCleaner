# Builds DupCleaner.exe from DupCleaner.ps1 with the C# compiler that ships with Windows (nothing to download).
# Run this again after every change to DupCleaner.ps1; the exe holds its own copy of the script.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$sma = (Get-ChildItem (Join-Path $env:windir 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation') -Recurse -Filter System.Management.Automation.dll | Select-Object -First 1).FullName
$out = Join-Path $here 'DupCleaner.exe'
& $csc /nologo /target:winexe /platform:anycpu /optimize+ "/win32icon:$(Join-Path $here 'DupCleaner.ico')" "/out:$out" "/resource:$(Join-Path $here 'DupCleaner.ps1'),DupCleaner.ps1" "/reference:$sma" /reference:System.Windows.Forms.dll (Join-Path $here 'DupCleanerHost.cs')
if ($LASTEXITCODE -eq 0) { "Built $out ($([math]::Round((Get-Item $out).Length / 1KB)) KB)" } else { "Build failed" }


