# halt on first error
$ErrorActionPreference = "Stop"
# print Information stream to not mix with the regular output-stream
$InformationPreference = "Continue"

Function Write-InformationLog {
    [CmdletBinding()]
    Param(
        [string] $Message,
        [int] $Indentation = 0
    )
    Write-Information "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")$("`t" * ($Indentation + 1))$Message"
}

Function Setup-Environment {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory = $true)] [String] $RootPath
    )
    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module "MicrosoftPowerBIMgmt.Profile" -Scope CurrentUser
    Install-Module "MicrosoftPowerBIMgmt.Workspaces" -Scope CurrentUser
    Install-Module "MicrosoftPowerBIMgmt.Reports" -Scope CurrentUser

    Import-Module -Name "MicrosoftPowerBIMgmt.Profile"
    Import-Module -Name "MicrosoftPowerBIMgmt.Workspaces"
    Import-Module -Name "MicrosoftPowerBIMgmt.Reports"

    $script:RootPath = $RootPath
}

Function Download-TabularEditor {
    [CmdletBinding()]
    Param (
        [parameter(Mandatory = $true)] [String] $DownloadFolder
    )

    # Download URL for Tabular Editor portable:
    $TabularEditorUrl = "https://cdn.tabulareditor.com/files/te2/TabularEditor.Portable.zip" 

    # Download destination (root of PowerShell script execution path):
    $DownloadedFile = Join-Path ($DownloadFolder) "TabularEditor.zip"

    # Download from GitHub:
    Invoke-WebRequest -Uri $TabularEditorUrl -OutFile $DownloadedFile

    # Unzip Tabular Editor portable, and then delete the zip file:
    Expand-Archive -Path $DownloadedFile -DestinationPath $DownloadFolder -Force
    Remove-Item $DownloadedFile

    $script:TabularEditorRootPath = $Path
}

Function Prepare-TabulareEditorSerializationOptions {
    [CmdletBinding()]
    Param ()
    # we need to set Serialization Options to allow export to Folder via TE2
    $serialization_options = '{
        "IgnoreInferredObjects": true,
        "IgnoreInferredProperties": true,
        "IgnoreTimestamps": true,
        "SplitMultilineStrings": true,
        "PrefixFilenames": false,
        "LocalTranslations": false,
        "LocalPerspectives": false,
        "LocalRelationships": false,
        "Levels": [
            "Data Sources",
            "Perspectives",
            "Relationships",
            "Roles",
            "Tables",
            "Tables/Columns",
            "Tables/Measures",
            "Translations"
        ]
    }'

    $serialization_options | Out-File (Join-Path $script:TabularEditorRootPath "TabularEditor_SerializeOptions.json")

    "Model.SetAnnotation(""TabularEditor_SerializeOptions"", ReadFile(@""$(Join-Path $script:TabularEditorRootPath "TabularEditor_SerializeOptions.json")""));" `
    | Out-File (Join-Path $script:TabularEditorRootPath "ApplySerializeOptionsAnnotation.csx")

    return "-SCRIPT ""$(Join-Path $script:TabularEditorRootPath 'ApplySerializeOptionsAnnotation.csx')"""
}

Function Prepare-TabularEditor {
    [CmdletBinding()]
    Param (
        [parameter(Mandatory = $true)] [String] $Path
    )
    Download-TabularEditor -DownloadFolder $Path
    
    $script:TabularEditorSerializationOptionsScript = Prepare-TabulareEditorSerializationOptions
}

Function Set-PowerBIConnection {
    [CmdletBinding()]
    Param (
        [parameter(Mandatory = $true)] [String] $PremiumWorkspaceId,

        [parameter(ParameterSetName = "UsernamePassword", Mandatory = $true)] [String] $Username,
        [parameter(ParameterSetName = "UsernamePassword", Mandatory = $true)] [String] $Password,

        [parameter(ParameterSetName = "ServicePrincipal", Mandatory = $true)] [String] $ClientId,
        [parameter(ParameterSetName = "ServicePrincipal", Mandatory = $true)] [String] $ClientSecret,
        [parameter(ParameterSetName = "ServicePrincipal", Mandatory = $true)] [String] $TenantId
    )

    $script:WorkspaceId = $PremiumWorkspaceId

    if ($PSCmdlet.ParameterSetName -eq "ServicePrincipal") {
        Write-Information "Using Service Principal authentication!"
        $script:LoginInfo = "User ID=app:$ClientId@$TenantId;Password=$ClientSecret"

        [securestring]$sec_client_secret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
        [pscredential]$credential = New-Object System.Management.Automation.PSCredential ($ClientId, $sec_client_secret)

        Connect-PowerBIServiceAccount -Credential $credential -ServicePrincipal -TenantId $TenantId
    }
    if ($PSCmdlet.ParameterSetName -eq "UsernamePassword") {
        Write-Information "Using Username/Password authentication!"

        $script:LoginInfo = "User ID=$Username;Password=$Password"

        [securestring]$sec_user_password = ConvertTo-SecureString $Password -AsPlainText -Force
        [pscredential]$credential = New-Object System.Management.Automation.PSCredential ($Username, $sec_user_password)

        Connect-PowerBIServiceAccount -Credential $credential
    }

    $script:Workspace = Get-PowerBIPremiumWorkspace -WorkspaceId $script:WorkspaceId
}

Function Get-PowerBIPremiumWorkspace {
    [CmdletBinding()]
    Param (
        [parameter(Mandatory = $true)] [string] $WorkspaceId
    )
    
    $workspace = Get-PowerBIWorkspace -Id $WorkspaceId
    Write-InformationLog "Power BI Workspace: `n$($workspace | ConvertTo-Json)"
    if (-not $workspace) {
        Write-Error "The provided Workspace ID ($WorkspaceId) does not exist or you do not have permissions!"
    }

    if (-not $workspace.IsOnDedicatedCapacity) {
        Write-Error "The provided Workspace '$($workspace.Name)' ($WorkspaceId) is not on Premium Capacity!"
    }

    return $workspace
}

Function Run-TabularEditorMetadataExtraction {
    [CmdletBinding()]
    Param (
        [parameter(Mandatory = $true)] [String] $DatasetName,
        [parameter(Mandatory = $true)] [String] $OutputPath,
        [parameter(Mandatory = $false)] [String] [ValidateSet("FOLDER", "FILE")] $OutputType = "FOLDER"
    )

    $model_name = Get-ModelNameFromDataset -DatasetName $DatasetName
    
    Write-InformationLog "Extracting metadata ..." -Indentation 1
    $executable = Join-Path $script:TabularEditorRootPath "TabularEditor.exe"   
    $connection_string = "powerbi://api.powerbi.com/v1.0/myorg/$($script:workspace.Name);initial catalog=$DatasetName"
    $params = @(
        """Provider=MSOLAP;Data Source=$connection_string;$LoginInfo"""
        """$DatasetName"""
    )

    if ($OutputType -eq "FOLDER") {
        $OutputPath = "$(Join-Path $OutputPath $model_name)"
        $params += @(
            $script:TabularEditorSerializationOptionsScript
            "-FOLDER ""$OutputPath"" ""$model_name"""
        )
    }
    else {
        $OutputPath = "$(Join-Path $OutputPath $model_name).database.json"
        $params += ("-BIM ""$OutputPath""")
    }
        
    Write-Information "$executable $params".Replace('"', "'")
    $p = Start-Process -FilePath $executable -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$DatasetName.log" -ArgumentList $params
    if ($p.ExitCode -ne 0) {
        Write-Error "Failed to extract metadata from $($dataset.WebUrl)! `n $($p.StandardError)"
    }
    Write-InformationLog "Extracted metadata to $OutputType '$OutputPath'" -Indentation 1
    Write-InformationLog "Overwriting 'name' and 'id' properties now ..." -Indentation 1

    # need to overwrite id and name as they are taken from the temporary dataset
    
    if ($OutputType -eq "FOLDER") {
        $database_file = Join-Path $OutputPath "database.json"
    }
    else {
        $database_file = $OutputPath
    }
    $bim_json = Get-Content $database_file | ConvertFrom-Json
    $bim_json.name = $model_name
    $bim_json.id = $model_name
    $bim_json | ConvertTo-Json -Depth 50 | Out-File $database_file
    Write-InformationLog "Metadata written to $OutputType '$OutputPath'!" -Indentation 1
}

Function Get-TemporaryModelName {
    [CmdletBinding()]
    Param (
        [parameter(Mandatory = $true)] [String] $ModelName
    )
    return "$ModelName$(Get-Date -Format '-yyyyMMdd_HHmmss')"
}

Function Get-ModelNameFromDataset {
    [CmdletBinding()]
    Param (
        [parameter(Mandatory = $true)] [String] $DatasetName
    )
    return $DatasetName.Remove($DatasetName.Length - 16) # remove temporary suffix 
}

Function Get-MetadataFromDataset {
    [CmdletBinding()]
    Param (
        [parameter(ParameterSetName = "by ID", Mandatory = $true)] [String] $DatasetId,
        [parameter(ParameterSetName = "by Name", Mandatory = $true)] [String] $DatasetName,
        [parameter(Mandatory = $true)] [String] $OutputPath,
        [parameter(Mandatory = $false)] [String] [ValidateSet("FOLDER", "FILE")] $OutputType = "FOLDER"
    )

    if ($PSCmdlet.ParameterSetName -eq "by ID")
    {
        Write-InformationLog "Getting metadata from dataset '$DatasetId' in workspace $($script:Workspace.Name) ($($script:Workspace.Id)) ... "
        $dataset = Get-PowerBIDataset -WorkspaceId $script:Workspace.Id -Id $DatasetId
    }
    elseif ($PSCmdlet.ParameterSetName -eq "by Name")
    {
        Write-InformationLog "Getting metadata from dataset '$DatasetName' in workspace $($script:Workspace.Name) ($($script:Workspace.Id)) ... "
        $dataset = Get-PowerBIDataset -WorkspaceId $script:Workspace.Id -Name $DatasetName
    }

    Run-TabularEditorMetadataExtraction -DatasetName $dataset.Name -OutputPath $OutputPath -OutputType $OutputType
    
    Write-InformationLog "Metadata extraction Finished!"
}

Function Get-MetadataFromPBIXFile {
    [CmdletBinding()]
    Param (
        [parameter(Mandatory = $true)] [String] $PbixFilePath,
        [parameter(Mandatory = $false)] [String] [ValidateSet("FOLDER", "FILE")] $OutputType = "FOLDER"
    )

    $pbix_file = Get-Item -Path $PbixFilePath

    $report = $null
    $dataset = $null
    try {
        Write-InformationLog "Processing  $($pbix_file.FullName) ... "
        Write-InformationLog "Checking if PBIX file contains a datamodel ..." -Indentation 1
        $zip_entries = [IO.Compression.ZipFile]::OpenRead($pbix_file.FullName).Entries.Name;
        if ("DataModel" -notin $zip_entries) {
            Write-InformationLog "No datamodel found in $($pbix_file.Name) - skipping further processing of this file!" -Indentation 1
            continue
        }
        else {
            Write-InformationLog "Datamodel found!" -Indentation 1
        }
        $temp_name = Get-TemporaryModelName -ModelName $pbix_file.BaseName
        Write-InformationLog "Uploading '$($pbix_file.FullName)' to '$($workspace.Name)/$temp_name' ... " -Indentation 1
        $report = New-PowerBIReport -Path $pbix_file.FullName -Name $temp_name -WorkspaceId $workspace.Id
        Start-Sleep -Seconds 5
        Write-InformationLog "Done!" -Indentation 2

        Write-InformationLog "Getting PowerBI dataset ..." -Indentation 1
        $dataset = Get-PowerBIDataset -WorkspaceId $workspace.Id | Where-Object { $_.Name -eq $temp_name }
        
        Get-MetadataFromDataset -DatasetId $dataset.Id -OutputPath $pbix_file.DirectoryName -OutputType $OutputType
    }
    catch {
        Write-Warning "An error occurred:"
        Write-Error $_
    }
    finally {
        if ($report -ne $null) {
            Write-InformationLog "Removing temporary PowerBI report ..." -Indentation 1
            Remove-PowerBIReport -WorkspaceId $workspace.Id -Id $report.Id
        }
        if ($dataset -ne $null) {
            Write-InformationLog "Removing temporary PowerBI dataset ..." -Indentation 1
            Invoke-PowerBIRestMethod -Url "https://api.powerbi.com/v1.0/myorg/groups/$($workspace.Id)/datasets/$($dataset.Id)" -Method Delete
        }
    }

    Write-Information "Finished!"
}

Function Extract-ChangedPBIXMetadata {
    [CmdletBinding()]
    Param (
        [parameter(Mandatory = $true)] [String] $RootPath,
        [parameter(Mandatory = $true)] [String] $TriggeredBy,
        [parameter(Mandatory = $true)] [String] $GitEventBefore,
        [parameter(Mandatory = $true)] [String] $GitEventAfter,
        [parameter(Mandatory = $true)] [String] $PathFilter
    )
    Write-InformationLog "Extraction triggered by: $TriggeredBy"
    Write-InformationLog "Getting changed .pbix files ..."
    if ($TriggeredBy -like "*CI" -or $TriggeredBy -eq "push") {
        # get the changed .pbix files in the current push
        Write-InformationLog "git diff --name-only $GitEventBefore $GitEventAfter --diff-filter=ACM ""*.pbix"""
        $pbix_files = @($(git diff --name-only $GitEventBefore $GitEventAfter --diff-filter=ACM "*.pbix"))
        $pbix_files = $pbix_files | ForEach-Object { Join-Path $script:RootPath $_ | Get-Item }

        if ($pbix_files.Count -eq 0) {
            Write-Warning "Something went wrong! Could not find any changed .pbix files using the above 'git diff' command!"
            Write-Information "Getting all .pbix files in the repo to be sure to get all changes!"
            # get all .pbix files in the current repository
            $pbix_files = Get-ChildItem -Path (Join-Path $script:RootPath $PathFilter) -Recurse -Filter "*.pbix" -File
        }
    }
    elseif ($triggered_by -eq "Manual" -or $triggered_by -eq "workflow_dispatch") {
        # get all .pbix files in the current repository
        $pbix_files = Get-ChildItem -Path (Join-Path $script:RootPath $PathFilter) -Recurse -Filter "*.pbix" -File
    }
    else {
        Write-Error "Invalid Trigger!"
    }

    Write-InformationLog "Changed .pbix files ($($pbix_files.Count)):"
    $pbix_files | ForEach-Object { Write-Information "$ind$($_.FullName)" }

    foreach ($pbix_file in $pbix_files) {
        Write-InformationLog "Processing  $($pbix_file.FullName) ... "
        Get-MetadataFromPBIXFile -PbixFilePath $pbix_file.FullName
    }
}

Function Extract-DatasetMetadataAfterPush {
    [CmdletBinding()]
    Param (
        [parameter(Mandatory = $true)] [String] $RootPath
    )

    Setup-Environment -RootPath $RootPath

    if ($env:PBI_TENANT_ID -and $env:PBI_CLIENT_ID -and $env:PBI_CLIENT_SECRET) {
        Set-PowerBIConnection -PremiumWorkspaceId $env:PBI_PREMIUM_WORKSPACE_ID -ClientId $env:PBI_CLIENT_ID -ClientSecret $env:PBI_CLIENT_SECRET -TenantId $env:PBI_TENANT_ID
    }
    else {
        Write-Information "Using Username/Password authentication!"
        $user_name = $env:PBI_USER_NAME
        $user_password = $env:PBI_USER_PASSWORD
        $login_info = "User ID=$user_name;Password=$user_password"

        Set-PowerBIConnection -PremiumWorkspaceId $env:PBI_PREMIUM_WORKSPACE_ID -Username $env:PBI_USER_NAME -Password $env:PBI_USER_PASSWORD
    }

    Prepare-TabularEditor -Path "$root_path\temp\TabularEditor2"

    Extract-ChangedPBIXMetadata -RootPath $root_path
}


#region Export module functions
Export-ModuleMember -Function Write-InformationLog
Export-ModuleMember -Function Setup-Environment
Export-ModuleMember -Function Download-TabularEditor
Export-ModuleMember -Function Prepare-TabulareEditorSerializationOptions
Export-ModuleMember -Function Prepare-TabularEditor
Export-ModuleMember -Function Run-TabularEditorMetadataExtraction
Export-ModuleMember -Function Set-PowerBIConnection
Export-ModuleMember -Function Get-PowerBIPremiumWorkspace
Export-ModuleMember -Function Get-MetadataFromPBIXFile
Export-ModuleMember -Function Get-MetadataFromDataset
Export-ModuleMember -Function Get-TemporaryModelName
Export-ModuleMember -Function Get-ModelNameFromDataset
Export-ModuleMember -Function Get-PBIXFilesToProcess
Export-ModuleMember -Function Extract-ChangedPBIXMetadata
Export-ModuleMember -Function Extract-DatasetMetadataAfterPush
#endregion