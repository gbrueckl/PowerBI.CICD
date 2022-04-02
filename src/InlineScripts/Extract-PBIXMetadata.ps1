# halt on first error
$ErrorActionPreference = "Stop"
# print Information stream
$InformationPreference = "Continue"

$root_path = (Get-Location).Path
$tabular_editor_root_path = $root_path
Write-Information "Working Directory: $root_path"

Set-PSRepository PSGallery -InstallationPolicy Trusted
Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser

Import-Module -Name MicrosoftPowerBIMgmt

$ind = "`t"

$git_event_before = $env:GIT_EVENT_BEFORE
$git_event_after = $env:GIT_EVENT_AFTER
# to work with Github and Azure DevOps we combine both environment variables (only one will be populated)
$triggered_by = $env:BUILD_REASON + $env:GIT_TRIGGER_NAME
$workspace_id = $env:PBI_PREMIUM_WORKSPACE_ID
$manual_trigger_path_filter = $env:MANUAL_TRIGGER_PATH_FILTER

if ($env:PBI_TENANT_ID -and $env:PBI_CLIENT_ID -and $env:PBI_CLIENT_SECRET) {
	Write-Information "Using Service Principal authentication!"
	$tenant_id = $env:PBI_TENANT_ID
	$client_id = $env:PBI_CLIENT_ID
	$client_secret = $env:PBI_CLIENT_SECRET
	$login_info = "User ID=app:$client_id@$tenant_id;Password=$client_secret"

	[securestring]$sec_client_secret = ConvertTo-SecureString $client_secret -AsPlainText -Force
	[pscredential]$credential = New-Object System.Management.Automation.PSCredential ($client_id, $sec_client_secret)

	Connect-PowerBIServiceAccount -Credential $credential -ServicePrincipal -TenantId $tenant_id
}
else {
	Write-Information "Using Username/Password authentication!"
	$user_name = $env:PBI_USER_NAME
	$user_password = $env:PBI_USER_PASSWORD
	$login_info = "User ID=$user_name;Password=$user_password"

	[securestring]$sec_user_password = ConvertTo-SecureString $user_password -AsPlainText -Force
	[pscredential]$credential = New-Object System.Management.Automation.PSCredential ($user_name, $sec_user_password)

	Connect-PowerBIServiceAccount -Credential $credential
}

$workspace = Get-PowerBIWorkspace -Id $workspace_id
Write-Information "Power BI Workspace: `n$($workspace | ConvertTo-Json)"

if (-not $workspace.IsOnDedicatedCapacity) {
	Write-Error "The provided Workspace ID ($($workspace.id)) is not on Premium Capacity!"
}

Write-Information "Triggered By: $triggered_by"
Write-Information "Getting changed .pbix files ..."
if ($triggered_by -like "*CI" -or $triggered_by -eq "push") {
	# get the changed .pbix files in the current push
	Write-Information "git diff --name-only $git_event_before $git_event_after --diff-filter=ACM ""*.pbix"""
	$pbix_files = @($(git diff --name-only $git_event_before $git_event_after --diff-filter=ACM "*.pbix"))
	$pbix_files = $pbix_files | ForEach-Object { Join-Path $root_path $_ | Get-Item }

	if ($pbix_files.Count -eq 0) {
		Write-Warning "Something went wrong! Could not find any changed .pbix files using the above 'git diff' command!"
		Write-Information "Getting all .pbix files in the repo to be sure to get all changes!"
		# get all .pbix files in the current repository
		$pbix_files = Get-ChildItem -Path (Join-Path $root_path $manual_trigger_path_filter) -Recurse -Filter "*.pbix" -File
	}
}
elseif ($triggered_by -eq "Manual" -or $triggered_by -eq "workflow_dispatch") {
	# get all .pbix files in the current repository
	$pbix_files = Get-ChildItem -Path (Join-Path $root_path $manual_trigger_path_filter) -Recurse -Filter "*.pbix" -File
}
else {
	Write-Error "Invalid Trigger!"
}

Write-Information "Changed .pbix files ($($pbix_files.Count)):"
$pbix_files | ForEach-Object { Write-Information "$ind$($_.FullName)" }

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

$serialization_options | Out-File (Join-Path $tabular_editor_root_path "TabularEditor_SerializeOptions.json")

"Model.SetAnnotation(""TabularEditor_SerializeOptions"", ReadFile(@""$(Join-Path $tabular_editor_root_path "TabularEditor_SerializeOptions.json")""));" `
	| Out-File (Join-Path $tabular_editor_root_path "ApplySerializeOptionsAnnotation.csx")

foreach ($pbix_file in $pbix_files) {
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
		Write-Information "$ind Uploading $($pbix_file.FullName.Replace($root_path, '')) to $($workspace.Name)/$temp_name ... "
		$report = New-PowerBIReport -Path $pbix_file.FullName -Name $temp_name -WorkspaceId $workspace.Id
		Start-Sleep -Seconds 5
		Write-Information "$ind$ind Done!"

		Write-Information "$ind Getting PowerBI dataset ..."
		$dataset = Get-PowerBIDataset -WorkspaceId $workspace.Id | Where-Object { $_.Name -eq $temp_name }
		$connection_string = "powerbi://api.powerbi.com/v1.0/myorg/$($workspace.Name);initial catalog=$($dataset.Name)"

		Write-Information "$ind Extracting metadata ..."
		$executable = Join-Path $tabular_editor_root_path TabularEditor.exe
		$output_path = "$(Join-Path $pbix_file.DirectoryName $pbix_file.BaseName)"
		$params = @(
			"""Provider=MSOLAP;Data Source=$connection_string;$login_info"""
			"""$($dataset.Name)"""
			"-SCRIPT ""$(Join-Path $tabular_editor_root_path 'ApplySerializeOptionsAnnotation.csx')"""
			"-FOLDER ""$output_path"" ""$($pbix_file.BaseName)"""
		)

		Write-Debug "$ind $executable $params"
		$p = Start-Process -FilePath $executable -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$temp_name.log" -ArgumentList $params

		if ($p.ExitCode -ne 0) {
			Write-Error "$ind Failed to extract PBIX metadata from $($dataset.WebUrl)!"
		}

		Write-Information "$ind Extracted PBIX metadata to FOLDER '($output_path)'!"
		Write-Information "$ind Overwriting 'name' and 'id' properties now ..."
		# need to overwrite id and name as they are taken from the temporary dataset
		$bim_json = Get-Content (Join-Path $output_path "database.json") | ConvertFrom-Json
		$bim_json.name = $pbix_file.BaseName
		$bim_json.id = $pbix_file.BaseName
		$bim_json | ConvertTo-Json -Depth 50 | Out-File (Join-Path $output_path "database.json")
		Write-Information "$ind PBIX metadata written to FOLDER '$output_path'!"
	}
	catch {
		Write-Warning "An error occurred:"
		Write-Warning $_
	}
	finally {
		if ($report -ne $null) {
			Write-Information "$ind Removing temporary PowerBI report ..."
			Remove-PowerBIReport -WorkspaceId $workspace.Id -Id $report.Id
		}
		if ($dataset -ne $null) {
			Write-Information "$ind Removing temporary PowerBI dataset ..."
			Invoke-PowerBIRestMethod -Url "https://api.powerbi.com/v1.0/myorg/groups/$($workspace.Id)/datasets/$($dataset.Id)" -Method Delete
		}
	}
}

Write-Information "Finished!"