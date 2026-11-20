#Requires -Version 5.0
Function Invoke-InternalizeChocoPkg {
    <#
    .SYNOPSIS
    Internalizes the downloaded Chocolatey packages in the configured search folder.

    .PARAMETER chocoExePath
    Full path of the Chocolatey program to start, for a caller that must not depend on which choco PATH finds first.
    When given, it is used for three things: the availability check of the configuration, the package build (choco pack) and the configured repository move (its choco push).
    The call stops when the file does not exist, and no other Chocolatey program is tried.
    The package push (pushPkgs) and the repository check (Invoke-RepoCheck) do not use it; they start choco by name.
    When omitted, every start is choco by name, as before.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'String needs to be in plain text when used for header')]
    param (
        [string]$configXML,
        [string]$internalizedXML,
        [string]$repoCheckXML,
        [string]$folderXML,
        [string]$privateRepoCreds,
        [string]$proxyRepoCreds,
        [switch]$thoroughList,
        [switch]$skipRepoCheck,
        [switch]$skipRepoMove,
        [switch]$noSave,
        [switch]$writeVersion,
        [switch]$noPack,
        [switch]$copyInternal,
        [string]$chocoExePath
    )
    $ErrorActionPreference = 'Stop'



    Try {
        . Get-RemixerConfig -upperFunctionBoundParameters $PSBoundParameters
    } Catch {
        Write-Error "Error details:`n$($PSItem.ToString())`n$($PSItem.InvocationInfo.Line)`n$($PSItem.ScriptStackTrace)"
    }

    if (($config.repoMove -eq "yes") -and (!($skipRepoMove))) {
        $invokeRepoMoveArgs = @{
            proxyRepoCreds   = $proxyRepoCreds
            configXML        = $configXML
            internalizedXML  = $internalizedXML
            repoCheckXML     = $repoCheckXML
            privateRepoCreds = $privateRepoCreds
            calledInternally = $true
        }
        if ($PSBoundParameters.ContainsKey('chocoExePath')) {
            $invokeRepoMoveArgs.chocoExePath = $chocoExePath
        }

        Try {
            Invoke-RepoMove @invokeRepoMoveArgs
        } Catch {
            Write-Error "Error details:`n$($PSItem.ToString())`n$($PSItem.InvocationInfo.Line)`n$($PSItem.ScriptStackTrace)"
        }
    }


    if (($config.repoCheck -eq "yes") -and (!($skipRepoCheck))) {
        $invokeRepoCheckArgs = @{
            privateRepoCreds = $privateRepoCreds
            configXML        = $configXML
            internalizedXML  = $internalizedXML
            repoCheckXML     = $repoCheckXML
            calledInternally = $true
        }

        Try {
            Invoke-RepoCheck @invokeRepoCheckArgs
        } Catch {
            Write-Error "Error details:`n$($PSItem.ToString())`n$($PSItem.InvocationInfo.Line)`n$($PSItem.ScriptStackTrace)"
        }
    }

    if (($null -eq $config.skipRepack) -or ($config.skipRepack -eq "no")) {
        # Import package specific functions
        if (!(Test-Path -Path Function:\Test-PkgFunctionsDefined)) {
            Get-ChildItem -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'pkgs') -Filter "*.ps1" | ForEach-Object {
                . $_.fullname
            }
        }

        #todo, add switch here to select from other options to get list of nupkgs
        Write-Verbose "Checking for packages in $($config.searchDir)"
        if ($thoroughList -or $copyInternal) {
            $nupkgArray = Get-ChildItem -File $config.searchDir -Filter "*.nupkg" -Recurse
        } else {
            #filters based on folder name, therefore less files to open later and therefore faster, but may not be useful in all circumstances.
            [System.Collections.ArrayList]$nupkgArray = @()
            [System.Collections.Generic.HashSet[String]]$internalIds = @($packagesXMLcontent.packages.internal.id)
            [System.Collections.Generic.HashSet[String]]$personalIds = @($config.personal.id)
            foreach ($file in (Get-ChildItem -File $config.searchDir -Filter "*.nupkg" -Recurse)) {
                if ((!$internalIds.Contains($file.directory.name)) -and (!$internalIds.Contains($file.directory.Parent.name)) `
                        -and (!$personalIds.Contains($file.directory.name)) -and (!$personalIds.Contains($file.directory.Parent.name))) {
                    $null = $nupkgArray.Add($file)
                }
            }
        }

        Write-Verbose "Repacking $($nupkgArray.Count) Packages"
        [System.Collections.ArrayList]$nupkgResultArray = @()
        $nupkgArrayDedup = $nupkgArray | Sort-Object -Unique
        Write-Verbose "Deduplicated packages"

        #unique needed to workaround a bug if accessing searchDir from a samba share where things show up twice if there are directories with the same name but different case.
        foreach ($package in $nupkgArrayDedup) {
            $parameters = $PSBoundParameters
            Try {
                if ($parameters['nupkgFile']) {
                    $parameters.nupkgFile = $package.fullname
                } else {
                    $parameters.Add("nupkgFile", $package.fullname)
                }
                if ($parameters['internalizedXML']) {
                    $parameters.internalizedXML = $internalizedXML
                } else {
                    $parameters.Add("internalizedXML", $internalizedXML)
                }
                $pkgResult = Invoke-InternalizeDownloadedChocoPkg @parameters
                if (![System.String]::IsNullOrWhiteSpace($pkgResult.id)) {
                    $null = $nupkgResultArray.Add($pkgResult)
                }
            } Catch {
                Write-Error "Error details:`n$($PSItem.ToString())`n$($PSItem.InvocationInfo.Line)`n$($PSItem.ScriptStackTrace)"
            }
        }

        if ($writeVersion) {
            Write-Output "`n"
            Foreach ($result in $nupkgResultArray) {
                Write-Output "$($result.ID) $($result.OldVersion) to $($result.Version)"
            }
        }
    }
}