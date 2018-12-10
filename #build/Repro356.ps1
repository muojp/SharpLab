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
    $roslynArtifactsRoot = Resolve-Path "$PSScriptRoot\..\!roslyn\artifacts"

    $roslynBranchFeatureMap = Get-RoslynBranchFeatureMap -ArtifactsRoot $roslynArtifactsRoot

    $branchFsName = "dotnet-features-nullable-common"
    Write-Output ''
    Write-Output "*** $branchFsName"

    $siteRoslynArtifactsRoot = Resolve-Path "$roslynArtifactsRoot\$branchFsName"
    $branchInfo = ConvertFrom-Json ([IO.File]::ReadAllText("$siteRoslynArtifactsRoot\BranchInfo.json"))
    $committer = $branchInfo.commits[0].author
    Write-Output "committer: $committer"

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

    $branchesFileName = "!branches.json"
    Write-Output "Updating $branchesFileName..."
    Set-Content "$branchesFileName" $(ConvertTo-Json $committer -Depth 100)
    Set-Content "$branchesFileName-n" -Encoding Byte ([Text.Encoding]::UTF8.GetBytes($(ConvertTo-Json $committer -Depth 100)))

}
catch {
    Write-Output "[ERROR] $_"
    Write-Output 'Returning exit code 1'
    exit 1
}
