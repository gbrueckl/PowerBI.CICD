# halt on first error
$ErrorActionPreference = "Stop"
# print Information stream
$InformationPreference = "Continue"


$root_path = Switch ($Host.name) {
	'Visual Studio Code Host' { split-path $psEditor.GetEditorContext().CurrentFile.Path }
	'Windows PowerShell ISE Host' { Split-Path -Path $psISE.CurrentFile.FullPath }
	'ConsoleHost' { $PSScriptRoot }
}

$root_path = $root_path | Split-Path -Parent
Push-Location $root_path

Set-PSRepository PSGallery -InstallationPolicy Trusted
Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser

Import-Module -Name MicrosoftPowerBIMgmt

$git_event_before = $env:GIT_EVENT_BEFORE
$git_event_after = $env:GIT_EVENT_AFTER

$workspace_id = $env:PBI_PREMIUM_WORKSPACE_ID

if((Test-Path 'env:PBI_TENANT_ID') -and (Test-Path 'env:PBI_CLIENT_SECRET') -and (Test-Path 'env:PBI_CLIENT_ID')) {
	$tenant_id = $env:PBI_TENANT_ID
	$client_id = $env:PBI_CLIENT_ID
	$client_secret = $env:PBI_CLIENT_SECRET
	$login_info = "User ID=app:$client_id@$tenant_id;Password=$client_secret"

	[securestring]$sec_client_secret = ConvertTo-SecureString $client_secret -AsPlainText -Force
	[pscredential]$credential = New-Object System.Management.Automation.PSCredential ($client_id, $sec_client_secret)

	Connect-PowerBIServiceAccount -Credential $credential -ServicePrincipal -TenantId $tenant_id
}
else {
	$user_name = $env:PBI_USER_NAME
	$user_password = $env:PBI_USER_PASSWORD
	$login_info = "User ID=$user_name;Password=$user_password"

	[securestring]$sec_user_password = ConvertTo-SecureString $user_password -AsPlainText -Force
	[pscredential]$credential = New-Object System.Management.Automation.PSCredential ($user_name, $sec_user_password)

	Connect-PowerBIServiceAccount -Credential $credential
}

$workspace = Get-PowerBIWorkspace -Id $workspace_id

# get the changed .pbix files in the current push
$changed_files = Join-Path $root_path "_tmp_changed_files.txt"
$x = Start-Process "git" -ArgumentList @("diff", "--name-only", $git_event_before, $git_event_after, "--diff-filter=ACM", """*.pbix""") -Wait -PassThru -NoNewWindow -RedirectStandardOutput $changed_files
#$x = Start-Process "git" -ArgumentList @("diff", "--name-only", "HEAD~2", """*.pbix""") -Wait -PassThru -NoNewWindow -RedirectStandardOutput $changed_files
$pbix_files = Get-Content -Path $changed_files | ForEach-Object { Join-Path $root_path $_ | Get-Item}
Remove-Item $changed_files

Write-Information $pbix_files

foreach($pbix_file in $pbix_files)
{
	Write-Information "Processing  $($pbix_file.FullName) ... "
	$temp_name = "$($pbix_file.BaseName)-$(Get-Date -Format 'yyyyMMddTHHmmss')"
	Write-Information "Uploading $($pbix_file.FullName) to $($workspace.Name)/$temp_name ... "
	$report = New-PowerBIReport -Path $pbix_file.FullName -Name $temp_name -WorkspaceId $workspace.Id
	Start-Sleep -Seconds 5
	Write-Information "    Done!"

	Write-Information "Getting PowerBI dataset ..."
	$dataset = Get-PowerBIDataset -WorkspaceId $workspace.Id | Where-Object { $_.Name -eq $temp_name}
	$connection_string = "powerbi://api.powerbi.com/v1.0/myorg/$($workspace.Name);initial catalog=$($dataset.Name)"

	$executable = Join-Path $root_path tools TabularEditor2 TabularEditor.exe

	$params = @(
		"""Provider=MSOLAP;Data Source=$connection_string;$login_info"""
		"""$($dataset.Name)"""
		"-BIM $(Join-Path $pbix_file.DirectoryName $pbix_file.BaseName).database.json" 
	)

	Write-Information "$executable $params"
	$p = Start-Process -FilePath $executable -Wait -NoNewWindow -PassThru -ArgumentList $params

	Write-Information $p.ExitCode

	Write-Information "Removing temporary PowerBI report ..."
	Remove-PowerBIReport -WorkspaceId $workspace.Id -Id $report.Id
	Write-Information "Removing temporary PowerBI dataset ..."
	Invoke-PowerBIRestMethod -Url "https://api.powerbi.com/v1.0/myorg/groups/$($workspace.Id)/datasets/$($dataset.Id)" -Method Delete
}
