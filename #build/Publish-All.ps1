param (
    [switch] [boolean] $azure
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = "SilentlyContinue" # https://www.amido.com/powershell-win32-error-handle-invalid-0x6/

# Write-Host, Write-Error and Write-Warning didn't function properly in Azure, so this mostly used Write-Output
# However new code can use other ones

$LangugageFeatureMapUrl = 'https://raw.githubusercontent.com/dotnet/roslyn/master/docs/Language%20Feature%20Status.md'

$PublishToIIS = Resolve-Path "$PSScriptRoot\Publish-ToIIS.ps1"
$PublishToAzure = Resolve-Path "$PSScriptRoot\Publish-ToAzure.ps1"

function ConvertTo-Hashtable([PSCustomObject] $object) {
    $result = @{}
    $object.PSObject.Properties | % { $result[$_.Name] = $_.Value }
    return $result
}

function Get-RoslynBranchFeatureMap($artifactsRoot) {
    $markdown = (Invoke-WebRequest $LangugageFeatureMapUrl -UseBasicParsing)
    $languageVersions = [regex]::Matches($markdown, '#\s*(?<language>.+)\s*$\s*(?<table>(?:^\|.+$\s*)+)', 'Multiline')

    $mapPath = "$artifactsRoot/RoslynFeatureMap.json"
    $map = @{}
    if (Test-Path $mapPath) {
        $map = ConvertTo-Hashtable (ConvertFrom-Json (Get-Content $mapPath -Raw))
    }
    $languageVersions | % {
        $language = $_.Groups['language'].Value
        $table = $_.Groups['table'].Value
        [regex]::Matches($table, '^\|(?<rawname>[^|]+)\|.+roslyn/tree/(?<branch>[A-Za-z\d\-/]+)', 'Multiline') | % {
            $name = $_.Groups['rawname'].Value.Trim()
            $branch = $_.Groups['branch'].Value
            $url = ''
            if ($name -match '\[([^\]]+)\]\(([^)]+)\)') {
                $name = $matches[1]
                $url = $matches[2]
            }
            
            $map[$branch] = [PSCustomObject]@{
                language = $language
                name = $name
                url = $url
            }
        }
    } | Out-Null
    
    Set-Content $mapPath (ConvertTo-Json $map)
    return $map
}

function Login-ToAzure($azureConfig) {
    $passwordKey = $env:TR_AZURE_PASSWORD_KEY
    if (!$passwordKey) {
        throw "Azure credentials require TR_AZURE_PASSWORD_KEY to be set."
    }
    $passwordKey = [Convert]::FromBase64String($passwordKey)
    $password = $azureConfig.Password | ConvertTo-SecureString -Key $passwordKey
    $credential = New-Object Management.Automation.PSCredential($azureConfig.UserName, $password)

    "Logging to Azure as $($azureConfig.UserName)..." | Out-Default
    Login-AzureRmAccount -Credential $credential | Out-Null
}

function Get-PredefinedBranches() {
    $x64Url = "http://sl-a-x64.sharplab.local"
    if ($azure) {
        $x64Url = "https://sl-a-x64.azurewebsites.net"
    }
    
    return @([ordered]@{
        id = 'x64'
        name = 'x64'
        url = $x64Url
    })
}

# Code ------
try {
    $Host.UI.RawUI.WindowTitle = "Deploy SharpLab" # prevents title > 1024 char errors
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    Write-Output "Environment:"
    Write-Output "  Current Path:          $(Get-Location)"    
    Write-Output "  Script Root:           $PSScriptRoot"

    $sourceRoot = Resolve-Path "$PSScriptRoot\..\source"
    Write-Output "  Source Root:           $sourceRoot"

    $roslynArtifactsRoot = Resolve-Path "$PSScriptRoot\..\!roslyn\artifacts"
    Write-Output "  Roslyn Artifacts Root: $roslynArtifactsRoot"

    $sitesRoot = Resolve-Path "$PSScriptRoot\..\!sites"
    Write-Output "  Sites Root:            $sitesRoot"

    Write-Output "Getting Roslyn feature map..."
    $roslynBranchFeatureMap = Get-RoslynBranchFeatureMap -ArtifactsRoot $roslynArtifactsRoot

    if ($azure) {
        $azureConfigPath = ".\!Azure.config.json"
        if (!(Test-Path $azureConfigPath)) {
            throw "Path '$azureConfigPath' was not found."
        }
        $azureConfig = ConvertFrom-Json (Get-Content $azureConfigPath -Raw)
        Login-ToAzure $azureConfig
    }

    $branchesJson = @(Get-PredefinedBranches)
    Get-ChildItem $sitesRoot | ? { $_ -is [IO.DirectoryInfo] } | % {
        $branchFsName = $_.Name

        $siteRoot = $_.FullName

        Write-Output ''
        Write-Output "*** $_"

        $siteRoslynArtifactsRoot = Resolve-Path "$roslynArtifactsRoot\$($_.Name)"
        $branchInfo = ConvertFrom-Json ([IO.File]::ReadAllText("$siteRoslynArtifactsRoot\BranchInfo.json"))

        $webAppName = "sl-b-$($branchFsName.ToLowerInvariant())"
        if ($webAppName.Length -gt 60) {
             $webAppName = $webAppName.Substring(0, 57) + "-01"; # no uniqueness check at the moment, we can add later
             Write-Output "[WARNING] Name is too long, using '$webAppName'."
        }

        # Success!
        $branchJson = [ordered]@{
            id = $branchFsName -replace '^dotnet-',''
            name = $branchInfo.name
            group = $branchInfo.repository
            feature = $roslynBranchFeatureMap[$branchInfo.name]
            commits = $branchInfo.commits
        }
        if (!$branchJson.feature) {
            $branchJson.Remove('feature')
        }

        $branchesJson += $branchJson
    }

    $branchesFileName = "!branches.json"
    Write-Output "Updating $branchesFileName..."
    Set-Content "$sitesRoot\$branchesFileName" -Encoding Byte ([Text.Encoding]::UTF8.GetBytes($(ConvertTo-Json $branchesJson -Depth 100)))

    $brachesJsLocalRoot = "$sourceRoot\WebApp\wwwroot"
    if (!(Test-Path $brachesJsLocalRoot)) {
        New-Item -ItemType Directory -Path $brachesJsLocalRoot | Out-Null    
    }
    Copy-Item "$sitesRoot\$branchesFileName" "$brachesJsLocalRoot\$branchesFileName" -Force

    if ($azure) {
        &$PublishToAzure `
            -FtpushExe $ftpushExe `
            -ResourceGroupName $($azureConfig.ResourceGroupName) `
            -AppServicePlanName $($azureConfig.AppServicePlanName) `
            -WebAppName "sharplab" `
            -SourcePath "$sitesRoot\$branchesFileName" `
            -TargetPath "wwwroot/$branchesFileName"
    }
}
catch {
    Write-Output "[ERROR] $_"
    Write-Output 'Returning exit code 1'
    exit 1
}
