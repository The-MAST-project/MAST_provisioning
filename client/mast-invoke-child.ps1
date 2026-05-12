# Dot-source from execute-mast-provisioning.ps1 / run-verify-only.ps1 (Windows PS 5.1).
# Invokes a full child process command line without routing through cmd.exe /c, so the
# ~8191 cmd.exe line limit does not apply. Uses CommandLineToArgvW for argv splitting.

${ErrorActionPreference} = 'Stop'

if (-not ([System.Management.Automation.PSTypeName]'MastProvisionCliSplit').Type) {
    ${csharp} = @'
using System;
using System.Runtime.InteropServices;
public class MastProvisionCliSplit {
  [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern IntPtr CommandLineToArgvW(string lpCmdLine, out int pNumArgs);

  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern IntPtr LocalFree(IntPtr hMem);

  public static string[] Split(string line) {
    int argc;
    IntPtr argv = CommandLineToArgvW(line, out argc);
    if (argv == IntPtr.Zero) {
      int err = Marshal.GetLastWin32Error();
      throw new System.ComponentModel.Win32Exception(err, "CommandLineToArgvW failed");
    }
    try {
      string[] args = new string[argc];
      for (int i = 0; i < argc; i++) {
        IntPtr p = Marshal.ReadIntPtr(argv, i * IntPtr.Size);
        args[i] = Marshal.PtrToStringUni(p);
      }
      return args;
    }
    finally {
      if (argv != IntPtr.Zero) {
        LocalFree(argv);
      }
    }
  }
}
'@
    Add-Type -TypeDefinition ${csharp} -ErrorAction Stop
}

function ConvertTo-MastSingleCommandString {
    param(${Value})
    if ($null -eq ${Value}) {
        return ''
    }
    if (${Value} -is [string]) {
        return (${Value} -replace "`r`n", ' ' -replace "`n", ' ').Trim()
    }
    ${parts} = @(${Value} | ForEach-Object { [string]$_ })
    return ([string]::Join(' ', ${parts}) -replace "`r`n", ' ' -replace "`n", ' ').Trim()
}

function ConvertTo-MastModuleLabel {
    param(${Value})
    if (${Value} -is [string]) {
        return ${Value}
    }
    if ($null -eq ${Value}) {
        return ''
    }
    ${arr} = @(${Value})
    if (${arr}.Length -ge 1) {
        return [string]${arr}[0]
    }
    return ''
}

function Import-MastCommandsFromJson {
    param([Parameter(Mandatory)][string]${CommandsJsonPath})
    # Do not use @( Get-Content ... | ConvertFrom-Json ): when the JSON root is an array,
    # ConvertFrom-Json returns Object[] and the outer @() nests it as a single element
    # (foreach would see one item: the whole Object[]), breaking cmd/module and filters.
    ${parsed} = Get-Content -LiteralPath ${CommandsJsonPath} -Raw | ConvertFrom-Json
    ${raw} = @()
    if ($null -eq ${parsed}) {
        ${raw} = @()
    }
    elseif (${parsed} -is [string]) {
        throw 'commands.json: root JSON value is a string; expected an array of command objects.'
    }
    elseif (${parsed} -is [System.Array]) {
        ${raw} = @(${parsed})
    }
    else {
        ${raw} = @(${parsed})
    }
    ${out} = @()
    foreach (${c} in ${raw}) {
        ${out} += [pscustomobject]@{
            order  = ${c}.order
            desc   = [string]${c}.desc
            cmd    = (ConvertTo-MastSingleCommandString -Value ${c}.cmd)
            module = (ConvertTo-MastModuleLabel -Value ${c}.module)
        }
    }
    return ,[object[]]${out}
}

function Invoke-MastChildCommandLine {
    param([Parameter(Mandatory)][string]${CommandLine})
    ${line} = (ConvertTo-MastSingleCommandString -Value ${CommandLine})
    if ([string]::IsNullOrWhiteSpace(${line})) {
        throw 'Empty command line'
    }

    ${argv} = [MastProvisionCliSplit]::Split(${line})
    if (${argv}.Length -lt 1) {
        throw 'CommandLineToArgvW returned no tokens'
    }

    ${exePath} = ${argv}[0]
    if (${exePath} -notmatch '[\\/]' -and ${exePath} -like '*.exe') {
        ${which} = Get-Command -Name ${exePath} -ErrorAction SilentlyContinue | Select-Object -First 1
        if (${which}) {
            ${exePath} = [string]${which}.Path
        }
    }

    ${argList} = @()
    if (${argv}.Length -gt 1) {
        ${argList} = ${argv}[1..(${argv}.Length - 1)]
    }

    ${so} = Join-Path ${env:TEMP} ("mast-child-out-{0}.txt" -f ([guid]::NewGuid().ToString('n')))
    ${se} = Join-Path ${env:TEMP} ("mast-child-err-{0}.txt" -f ([guid]::NewGuid().ToString('n')))
    try {
        ${p} = Start-Process -FilePath ${exePath} -ArgumentList ${argList} -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput ${so} -RedirectStandardError ${se}
        try { ${p}.Refresh() } catch {}
        ${merged} = New-Object System.Collections.ArrayList
        if (Test-Path -LiteralPath ${so}) {
            ${null} = ${merged}.AddRange(@(Get-Content -LiteralPath ${so}))
        }
        if (Test-Path -LiteralPath ${se}) {
            ${null} = ${merged}.AddRange(@(Get-Content -LiteralPath ${se}))
        }
        ${exit} = ${p}.ExitCode
        return [pscustomobject]@{
            Output   = @(${merged}.ToArray())
            ExitCode = ${exit}
        }
    }
    finally {
        Remove-Item -LiteralPath ${so} -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ${se} -Force -ErrorAction SilentlyContinue
    }
}
