Param (
    [parameter(Mandatory = $true)] [String] $PbixFilePath,
    [parameter(Mandatory = $true)] [String] $PbiPremiumWorkspaceId,
    [parameter(Mandatory = $true)] [String] $TabularEditorRootPath,
	[parameter(Mandatory = $true)] [String] $LoginInfo,
	[parameter(Mandatory = $true)] [String] [ValidateSet("FOLDER", "FILE")] $OutputType
)
# halt on first error
$ErrorActionPreference = "Stop"
# print Information stream to not mix with the regular output-stream
$InformationPreference = "Continue"

$ind = "`t"

$workspace = Get-PowerBIWorkspace -Id $PbiPremiumWorkspaceId -Scope Individual
Write-Information "Power BI Workspace: `n$($workspace | ConvertTo-Json)"
if (-not $workspace.IsOnDedicatedCapacity) {
    Write-Error "The provided Workspace ID ($($workspace.id)) is not on Premium Capacity!"
}

$pbix_file = Get-Item -Path $PbixFilePath

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

$serialization_options | Out-File (Join-Path $TabularEditorRootPath "TabularEditor_SerializeOptions.json")

"Model.SetAnnotation(""TabularEditor_SerializeOptions"", ReadFile(@""$(Join-Path $TabularEditorRootPath "TabularEditor_SerializeOptions.json")""));" `
	| Out-File (Join-Path $TabularEditorrootPath "ApplySerializeOptionsAnnotation.csx")

$report = $null
$dataset = $null
try {
    Write-Information "Processing  $($pbix_file.FullName) ... "
    Write-Information "$ind Checking if PBIX file contains a datamodel ..."
    $zip_entries = [IO.Compression.ZipFile]::OpenRead($pbix_file.FullName).Entries.Name;
    if ("DataModel" -notin $zip_entries) {
        Write-Information "$ind No datamodel found in $($pbix_file.Name) - skipping further processing of this file!"
        continue
    }
    else {
        Write-Information "$ind Datamodel found!"
    }
    $temp_name = "$($pbix_file.BaseName)-$(Get-Date -Format 'yyyyMMddTHHmmss')"
    Write-Information "$ind Uploading $($pbix_file.FullName) to $($workspace.Name)/$temp_name ... "
    $report = New-PowerBIReport -Path $pbix_file.FullName -Name $temp_name -WorkspaceId $workspace.Id
    Start-Sleep -Seconds 5
    Write-Information "$ind$ind Done!"

    Write-Information "$ind Getting PowerBI dataset ..."
    $dataset = Get-PowerBIDataset -WorkspaceId $workspace.Id | Where-Object { $_.Name -eq $temp_name }
    $connection_string = "powerbi://api.powerbi.com/v1.0/myorg/$($workspace.Name);initial catalog=$($dataset.Name)"

    Write-Information "$ind Extracting metadata ..."
    $executable = Join-Path $TabularEditorRootPath "TabularEditor.exe"   
    $params = @(
        """Provider=MSOLAP;Data Source=$connection_string;$LoginInfo"""
        """$($dataset.Name)"""
	)

	if($OutputType -eq "FOLDER")
	{
		$output_path = "$(Join-Path $pbix_file.DirectoryName $pbix_file.BaseName)"
		$params += @(
			"-SCRIPT ""$(Join-Path $TabularEditorRootPath 'ApplySerializeOptionsAnnotation.csx')"""
			"-FOLDER ""$output_path"" ""$($pbix_file.BaseName)"""
		)
	}
	else {
		$output_path = "$(Join-Path $pbix_file.DirectoryName $pbix_file.BaseName).database.json"
		$params += ("-BIM ""$output_path""")
	}
        
    Write-Debug "$ind $executable $params".Replace('"', "'")
    $p = Start-Process -FilePath $executable -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$temp_name.log" -ArgumentList $params
    if ($p.ExitCode -ne 0) {
        Write-Error "$ind Failed to extract metadata from $($dataset.WebUrl)! `n $($p.StandardError)"
    }
    Write-Information "$ind Extracted metadata to $OutputType '$output_path'"
	Write-Information "$ind Overwriting 'name' and 'id' properties now ..."

    # need to overwrite id and name as they are taken from the temporary dataset
	if($OutputType -eq "FOLDER")
	{
		$bim_json = Get-Content (Join-Path $output_path "database.json") | ConvertFrom-Json
	}
	else
	{
		$bim_json = Get-Content $output_path | ConvertFrom-Json
	}
    $bim_json.name = $pbix_file.BaseName
    $bim_json.id = $pbix_file.BaseName
    $bim_json | ConvertTo-Json -Depth 50 | Out-File (Join-Path $output_path "database.json")
    Write-Information "$ind Metadata written to '$output_path'!"
}
catch {
    Write-Warning "An error occurred:"
    Write-Error $_
}
finally {
    if ($report -ne $null) {
        Write-Information "$ind Removing temporary PowerBI report ..."
        Remove-PowerBIReport -WorkspaceId $workspace.Id -Id $report.Id
    }
    if ($dataset -ne $null) {
        Write-Information "$ind Removing temporary PowerBI dataset ..."
        Invoke-PowerBIRestMethod -Url https://api.powerbi.com/v1.0/myorg/groups/$($workspace.Id)/datasets/$($dataset.Id) -Method Delete
    }
}

Write-Information "Finished!"
