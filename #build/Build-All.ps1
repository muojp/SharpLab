Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = "SilentlyContinue" # https://www.amido.com/powershell-win32-error-handle-invalid-0x6/

# This mostly uses Write-Output because it was an Azure WebJob before, and Write-Warning/etc
# didn't work properly in WebJobs
$BuildRoslynBranchIfModified = Resolve-Path "$PSScriptRoot\Build-RoslynBranchIfModified.ps1"
."$PSScriptRoot\Setup-Build.ps1"

function Update-RoslynSource($directoryPath, $repositoryUrl) {
    Write-Output "Updating $directoryPath"
    if (Test-Path "$directoryPath\.git") {
        Invoke-Git $directoryPath config user.email "sharplab@github.test"
        Invoke-Git $directoryPath config user.name "SharpLab"
        Invoke-Git $directoryPath fetch --prune origin
        Invoke-Git $directoryPath checkout master
        @(Invoke-Git $directoryPath branch -vv) |
            ? { $_ -match '\s*(\S+)\s.*: gone\]' } |
            % { $matches[1] } |
            % { Invoke-Git $directoryPath branch -D $_ }
        Invoke-Git $directoryPath gc --auto
    }
    else {
        Invoke-Git . clone $repositoryUrl $directoryPath
    }
}

function Ensure-ResolvedPath($path) {
    if (-not (Test-Path $path)) {
        New-Item -ItemType directory -Path $path | Out-Null
    }
    return Resolve-Path $path
}

function ConvertTo-Hashtable([PSCustomObject] $object) {
    $result = @{}
    $object.PSObject.Properties | % { $result[$_.Name] = $_.Value }
    return $result
}

function Write-Success($object) {
    $saved = $Host.UI.RawUI.ForegroundColor
    try {
        $Host.UI.RawUI.ForegroundColor = 'Green'
        Write-Output "SUCCESS: $object"
    }
    finally {
        $Host.UI.RawUI.ForegroundColor = $saved
    }
}

# Code ------
try {
    $Host.UI.RawUI.WindowTitle = "SharpLab Build" # prevents title > 1024 char errors

    #Write-Output "Killing VBCSCompiler instances"
    #taskkill /IM VBCSCompiler.exe /F

    Write-Output "Environment:"
    Write-Output "  Current Path:          $(Get-Location)"
    Write-Output "  Script Root:           $PSScriptRoot"

    $root = Resolve-Path "$PSScriptRoot\.."
    Write-Output "  Root:                  $root"

    $sourceRoot = Resolve-Path "$root\source"
    Write-Output "  Source Root:           $sourceRoot"

    $roslynSourcesRoot = Ensure-ResolvedPath "$root\!roslyn\sources"
    Write-Output "  Roslyn Sources Root:   $roslynSourcesRoot"
    
    $roslynArtifactsRoot = Ensure-ResolvedPath "$root\!roslyn\artifacts"
    Write-Output "  Roslyn Artifacts Root: $roslynArtifactsRoot"

    $sitesRoot = Ensure-ResolvedPath "$root\!sites"
    Write-Output "  Sites Root:            $sitesRoot"

    $buildConfig = ConvertFrom-Json (Get-Content "$root\Build.config.json" -Raw)

    ${env:$HOME} = $PSScriptRoot
    Invoke-Git . --version

    $buildConfig.RoslynRepositories | % {
        Write-Output "Building repository '$($_.Name)' ($($_.Url))..."
        $repositorySourceRoot = Ensure-ResolvedPath "$roslynSourcesRoot\$($_.Name)"
        Write-Output "  Repository Source Root: $repositorySourceRoot"

        Write-Output "Updating..."
        Update-RoslynSource -DirectoryPath $repositorySourceRoot -RepositoryUrl $($_.Url)

        Write-Output "Getting branches..."
        $branchesRaw = @(Invoke-Git $repositorySourceRoot branch --remote)
        $branches = $branchesRaw |
            ? { $_ -notmatch '^\s+origin/HEAD' } |
            % { ($_ -match 'origin/(.+)$') | Out-Null; $matches[1] }

        $repositoryConfig = ConvertTo-Hashtable $_
        $repositoryName = $repositoryConfig.Name
        $include = $repositoryConfig['Include']
        $exclude = $repositoryConfig['Exclude']

        Write-Output "  $branches"
        $branches | % {
            Write-Output ''
            Write-Output "*** $repositoryName`: $_"
            if ($include -and $_ -notmatch $include) {
                Write-Output "Does not match inclusion rules, skipped."
                return
            }
            if ($exclude -and $_ -match $exclude) {
                Write-Output "Matches exclusion rule, skipped."
                return
            }

            $branchFsName = $repositoryName + "-" + ($_ -replace '[/\\:_]', '-')

            $siteRoot            = Ensure-ResolvedPath "$sitesRoot\$branchFsName"
            $branchArtifactsRoot = Ensure-ResolvedPath "$roslynArtifactsRoot\$branchFsName"

            $branchBuildFailed = $false
            try {
                Write-Output "Getting branch info..."
                $branchInfo = @{
                    name       = $_
                    repository = $repositoryConfig.Name
                    commits = @(@{
                        hash    =  (Invoke-Git $repositorySourceRoot log "origin/$_" -n 1 --pretty=format:"%H" )
                        date    =  (Invoke-Git $repositorySourceRoot log "origin/$_" -n 1 --pretty=format:"%aI")
                        author  =  (Invoke-Git $repositorySourceRoot log "origin/$_" -n 1 --pretty=format:"%aN")
                        message = @(Invoke-Git $repositorySourceRoot log "origin/$_" -n 1 --pretty=format:"%B" ) -join "`r`n"
                    })
                }
                Set-Content "$branchArtifactsRoot\BranchInfo.json" (ConvertTo-Json $branchInfo -Depth 100)
            }
            catch {
                $ex = $_.Exception
                if ($ex -isnot [BranchBuildException]) {
                    throw
                }

                $branchBuildFailed = $true
                Write-Warning "$($ex.Message)"
                Add-Content $failedListPath @("$branchFsName ($repositoryName)", $ex.Message, '')
            }

            $branchBinariesPath = "$branchArtifactsRoot\Binaries"
        }
    }
}
catch {
    Write-Output "[ERROR] $_"
    Write-Output 'Returning exit code 1'
    exit 1
}
