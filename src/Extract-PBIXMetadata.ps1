# halt on first error
$ErrorActionPreference = "Stop"
# print Information stream
$InformationPreference = "Continue"

$root_path = (Get-Location).Path

Set-PSRepository PSGallery -InstallationPolicy Trusted
Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser

Import-Module -Name MicrosoftPowerBIMgmt

$git_event_before = $env:GIT_EVENT_BEFORE
$git_event_after = $env:GIT_EVENT_AFTER
$triggered_by = $env:GIT_TRIGGER_NAME
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

Write-Information "Triggered By: $triggered_by"
if ($triggered_by -eq "push") {
	# get the changed .pbix files in the current push
	$changed_files = Join-Path $root_path "_tmp_changed_files.txt"
	$x = Start-Process "git" -ArgumentList @("diff", "--name-only", $git_event_before, $git_event_after, "--diff-filter=ACM", """*.pbix""") -Wait -PassThru -NoNewWindow -RedirectStandardOutput $changed_files
	$pbix_files = Get-Content -Path $changed_files | ForEach-Object { Join-Path $root_path $_ | Get-Item }
	Remove-Item $changed_files
}
elseif ($triggered_by -eq "workflow_dispatch") {
	# get all .pbix files in the current repository
	$pbix_files = Get-ChildItem -Path (Join-Path $root_path $manual_trigger_path_filter) -Recurse -Filter "*.pbix" -File
}
else {
	Write-Error "Invalid Trigger!"
}

Write-Information "PBIX files to be processed: $($pbix_files.Length)"
$indention = "`t"
foreach ($pbix_file in $pbix_files) { 
	$report = $null
	$dataset = $null
	try {
		Write-Information "Processing  $($pbix_file.FullName) ... "

		Write-Information "$indention Checking if PBIX file contains a datamodel ..."
		$zip_entries = [IO.Compression.ZipFile]::OpenRead($pbix_file.FullName).Entries.Name; 
		if ("DataModel" -notin $zip_entries) {
			Write-Information "$indention No datamodel found in $($pbix_file.Name) - skipping further processing of this file!"
			continue
		}
		else {
			Write-Information "$indention Datamodel found!"
		}

		$temp_name = "$($pbix_file.BaseName)-$(Get-Date -Format 'yyyyMMddTHHmmss')"
		Write-Information "$indention Uploading $($pbix_file.FullName.Replace($root_path, '')) to $($workspace.Name)/$temp_name ... "
		$report = New-PowerBIReport -Path $pbix_file.FullName -Name $temp_name -WorkspaceId $workspace.Id
		Start-Sleep -Seconds 5
		Write-Information "$indention$indention Done!"

		Write-Information "$indention Getting PowerBI dataset ..."
		$dataset = Get-PowerBIDataset -WorkspaceId $workspace.Id | Where-Object { $_.Name -eq $temp_name }
		$connection_string = "powerbi://api.powerbi.com/v1.0/myorg/$($workspace.Name);initial catalog=$($dataset.Name)"

		$executable = Join-Path $root_path TabularEditor.exe

		$output_path = "$(Join-Path $pbix_file.DirectoryName $pbix_file.BaseName).database.json"
		$params = @(
			"""Provider=MSOLAP;Data Source=$connection_string;$login_info"""
			"""$($dataset.Name)"""
			"-BIM $output_path" 
		)

		Write-Information "$indention $executable $params"
		$p = Start-Process -FilePath $executable -Wait -NoNewWindow -PassThru -ArgumentList $params

		if ($p.ExitCode -ne 0) {
			Write-Error "$indention Failed to extract .bim file from $($dataset.WebUrl)!"
		}

		Write-Information "BIM-file written to $output_path"
	}
	catch {
		Write-Information "An error occurred:"
        Write-Warning $_
	}
	finally {
		if ($report -ne $null) {
			Write-Information "$indention Removing temporary PowerBI report ..."
			Remove-PowerBIReport -WorkspaceId $workspace.Id -Id $report.Id
		}
		if ($dataset -ne $null) {
			Write-Information "$indention Removing temporary PowerBI dataset ..."
			Invoke-PowerBIRestMethod -Url "https://api.powerbi.com/v1.0/myorg/groups/$($workspace.Id)/datasets/$($dataset.Id)" -Method Delete
		}
	}
}

Write-Information "Finished!"