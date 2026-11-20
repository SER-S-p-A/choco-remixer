#Requires -Version 5.1
# Pester 5 tests of the -chocoExePath parameter of Invoke-InternalizeChocoPkg.
# The fixture lives under a folder whose name holds a space and a semicolon, the case the parameter exists for.
# Run: Invoke-Pester -Path <this file> -Output Detailed

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'choco-remixer\choco-remixer.psm1') -Force

    # A package id the fork lists as implemented; its recipe is replaced by a mock below.
    $pkgId = '010editor.install'
    $pkgVersion = '1.0.0'

    $root = Join-Path $TestDrive 'work a;1'
    $searchDir = Join-Path $root 'search'
    $workDir = Join-Path $root 'work'
    $null = New-Item -ItemType Directory -Path (Join-Path $searchDir $pkgId) -Force
    $null = New-Item -ItemType Directory -Path $workDir -Force

    # A file named choco.exe that exists but cannot start.
    $givenChoco = Join-Path $root 'pack-chocolatey\choco.exe'
    $null = New-Item -ItemType Directory -Path (Split-Path $givenChoco) -Force
    Set-Content -LiteralPath $givenChoco -Value 'not a program'

    # A choco found by name, for the case where the parameter is omitted.
    $byNameDir = Join-Path $TestDrive 'byname'
    $null = New-Item -ItemType Directory -Path $byNameDir -Force
    Set-Content -LiteralPath (Join-Path $byNameDir 'choco.cmd') -Value '@exit /b 0'

    function New-TestConfigXml {
        param([string]$Path, [string]$RepoMove = 'no', [string]$SkipRepack = 'no')
        $e = { param($v) [System.Security.SecurityElement]::Escape($v) }
        $xml = @"
<?xml version="1.0"?>
<options>
  <searchDir>$(& $e $searchDir)</searchDir>
  <workDir>$(& $e $workDir)</workDir>
  <useDropPath>no</useDropPath>
  <writePerPkgs>no</writePerPkgs>
  <pushPkgs>no</pushPkgs>
  <repoCheck>no</repoCheck>
  <skipRepack>$SkipRepack</skipRepack>
  <repoMove>$RepoMove</repoMove>
  <proxyRepoURL>https://proxy.invalid/repository/proxy/</proxyRepoURL>
  <moveToRepoURL>https://move.invalid/feed/</moveToRepoURL>
  <proxyRepoCreds>no</proxyRepoCreds>
  <privateRepoCreds>no</privateRepoCreds>
  <writeVersion>no</writeVersion>
</options>
"@
        Set-Content -LiteralPath $Path -Value $xml -Encoding UTF8
    }

    $configXML = Join-Path $root 'config.xml'
    $moveConfigXML = Join-Path $root 'config-move.xml'
    $internalizedXML = Join-Path $root 'internalized.xml'
    $repoCheckXML = Join-Path $root 'repo-check.xml'
    New-TestConfigXml -Path $configXML
    New-TestConfigXml -Path $moveConfigXML -RepoMove 'yes' -SkipRepack 'yes'
    Set-Content -LiteralPath $internalizedXML -Value '<?xml version="1.0"?><internalized></internalized>' -Encoding UTF8
    Set-Content -LiteralPath $repoCheckXML -Value '<?xml version="1.0"?><toInternalize></toInternalize>' -Encoding UTF8

    # A minimal package with a nuspec and an install script, entries written with forward slashes as NuGet does.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $nupkg = Join-Path $searchDir "$pkgId\$pkgId.$pkgVersion.nupkg"
    $archive = [System.IO.Compression.ZipFile]::Open($nupkg, 'Create')
    try {
        $entries = [ordered]@{
            "$pkgId.nuspec"               = @"
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
  <metadata>
    <id>$pkgId</id>
    <version>$pkgVersion</version>
    <title>test</title>
    <authors>test</authors>
    <description>test</description>
  </metadata>
</package>
"@
            'tools/chocolateyInstall.ps1' = "Write-Output 'test'"
        }
        foreach ($name in $entries.Keys) {
            $writer = New-Object System.IO.StreamWriter($archive.CreateEntry($name).Open())
            try { $writer.Write($entries[$name]) } finally { $writer.Dispose() }
        }
    } finally {
        $archive.Dispose()
    }

    $baseArgs = @{
        configXML       = $configXML
        internalizedXML = $internalizedXML
        repoCheckXML    = $repoCheckXML
        skipRepoCheck   = $true
        skipRepoMove    = $true
        noSave          = $true
    }
}

AfterAll {
    Remove-Module choco-remixer -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-InternalizeChocoPkg -chocoExePath' {
    BeforeEach {
        $savedPath = $env:PATH
        $savedChocolateyInstall = $env:ChocolateyInstall
        if (-not $env:ChocolateyInstall) { $env:ChocolateyInstall = Split-Path $givenChoco }
        Mock -ModuleName choco-remixer Convert-InstallChocolateyPackage { } -RemoveParameterType obj
    }

    AfterEach {
        $env:PATH = $savedPath
        $env:ChocolateyInstall = $savedChocolateyInstall
    }

    It 'starts choco by name when the parameter is omitted' {
        $env:PATH = "$byNameDir;$env:PATH"
        Mock -ModuleName choco-remixer Start-Process { [pscustomobject]@{ ExitCode = 0 } }

        Invoke-InternalizeChocoPkg @baseArgs

        Should -Invoke Start-Process -ModuleName choco-remixer -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'choco' }
        Should -Invoke Start-Process -ModuleName choco-remixer -Times 0 -Exactly -ParameterFilter { $FilePath -ne 'choco' }
    }

    It 'starts the given file for the package build' {
        Mock -ModuleName choco-remixer Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        # No choco on PATH: a given path must work without a lookup by name.
        Mock -ModuleName choco-remixer Get-Command { $null } -ParameterFilter { $Name -eq 'choco' }

        Invoke-InternalizeChocoPkg @baseArgs -chocoExePath $givenChoco

        Should -Invoke Get-Command -ModuleName choco-remixer -Times 0 -Exactly -ParameterFilter { $Name -eq 'choco' }
        Should -Invoke Start-Process -ModuleName choco-remixer -Times 1 -Exactly -ParameterFilter { $FilePath -eq $givenChoco -and $ArgumentList -eq 'pack -r' }
        Should -Invoke Start-Process -ModuleName choco-remixer -Times 0 -Exactly -ParameterFilter { $FilePath -ne $givenChoco }
    }

    It 'stops when the given file does not exist, and starts nothing' {
        Mock -ModuleName choco-remixer Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        $missing = Join-Path $root 'missing\choco.exe'

        { Invoke-InternalizeChocoPkg @baseArgs -chocoExePath $missing } | Should -Throw -ExpectedMessage '*chocoExePath names no existing file*'

        Should -Invoke Start-Process -ModuleName choco-remixer -Times 0 -Exactly
    }

    It 'stops when the given path is not a full path, and starts nothing' {
        Mock -ModuleName choco-remixer Start-Process { [pscustomobject]@{ ExitCode = 0 } }

        { Invoke-InternalizeChocoPkg @baseArgs -chocoExePath 'choco.exe' } | Should -Throw -ExpectedMessage '*must be the full path*'

        Should -Invoke Start-Process -ModuleName choco-remixer -Times 0 -Exactly
    }

    It 'stops with the start error when the given file cannot start, and tries no other program' {
        # The real Start-Process runs; -ErrorAction Stop stands for the function's own $ErrorActionPreference = 'Stop',
        # which does not reach a cmdlet called from the mock's scope.
        Mock -ModuleName choco-remixer Start-Process { Microsoft.PowerShell.Management\Start-Process @PesterBoundParameters -ErrorAction Stop }

        { Invoke-InternalizeChocoPkg @baseArgs -chocoExePath $givenChoco } | Should -Throw -ExpectedMessage '*This command cannot be run*'

        Should -Invoke Start-Process -ModuleName choco-remixer -Times 1 -Exactly -ParameterFilter { $FilePath -eq $givenChoco }
        Should -Invoke Start-Process -ModuleName choco-remixer -Times 0 -Exactly -ParameterFilter { $FilePath -ne $givenChoco }
    }

    It 'passes the given file to the configured repository move' {
        Mock -ModuleName choco-remixer Test-PushPackage { }
        Mock -ModuleName choco-remixer Invoke-RepoMove { }
        $moveArgs = $baseArgs.Clone()
        $moveArgs.configXML = $moveConfigXML
        $moveArgs.Remove('skipRepoMove')

        Invoke-InternalizeChocoPkg @moveArgs -chocoExePath $givenChoco

        Should -Invoke Invoke-RepoMove -ModuleName choco-remixer -Times 1 -Exactly -ParameterFilter { $chocoExePath -eq $givenChoco }
    }

    It 'passes no path to the configured repository move when the parameter is omitted' {
        $env:PATH = "$byNameDir;$env:PATH"
        Mock -ModuleName choco-remixer Test-PushPackage { }
        Mock -ModuleName choco-remixer Invoke-RepoMove { }
        $moveArgs = $baseArgs.Clone()
        $moveArgs.configXML = $moveConfigXML
        $moveArgs.Remove('skipRepoMove')

        Invoke-InternalizeChocoPkg @moveArgs

        Should -Invoke Invoke-RepoMove -ModuleName choco-remixer -Times 1 -Exactly -ParameterFilter { -not $chocoExePath }
    }
}
