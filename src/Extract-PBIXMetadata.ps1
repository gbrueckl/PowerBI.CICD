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

$tenant_id = $env:PBI_TENANT_ID
$client_id = $env:PBI_CLIENT_ID
$client_secret = $env:PBI_CLIENT_SECRET
$workspace_id = $env:PBI_WORKSPACE_ID


# Convert to SecureString
[securestring]$sec_client_secret = ConvertTo-SecureString $client_secret -AsPlainText -Force
[pscredential]$credential = New-Object System.Management.Automation.PSCredential ($client_id, $sec_client_secret)

Connect-PowerBIServiceAccount -Credential $credential -ServicePrincipal -TenantId $tenant_id

$workspace = Get-PowerBIWorkspace -Id $workspace_id

$pbixFiles = Get-ChildItem -Path $(Join-Path $root_path "content" "PBIX_Files")

foreach($pbixFile in $pbixFiles)
{
	$temp_name = "$($pbixFile.BaseName)-$(Get-Date -Format 'yyyyMMddTHHmmss')"
	Write-Information "Uploading $($pbixfile.FullName) to $($workspace.Id)/$temp_name ... "
	$report = New-PowerBIReport -Path $pbixfile.FullName -Name $temp_name -WorkspaceId $workspace.Id
	Start-Sleep -Seconds 5
	Write-Information "    Done!"

	Write-Information "Getting PowerBI dataset ..."
	$dataset = Get-PowerBIDataset -WorkspaceId $workspace.Id | Where-Object { $_.Name -eq $temp_name}
	$connection_string = "powerbi://api.powerbi.com/v1.0/myorg/$($workspace.Name);initial catalog=$($dataset.Name)"

	$executable = Join-Path $root_path tools TabularEditor2 TabularEditor.exe

	$params = @(
		"""Provider=MSOLAP;Data Source=$connection_string;User ID=app:$client_id@$tenant_id;Password=$client_secret"""
		"""$($dataset.Name)"""
		"-FOLDER $(Join-Path $pbixFile.DirectoryName $pbixFile.BaseName '')"
	)

	Write-Information "$executable $params"
	$p = Start-Process -FilePath $executable -Wait -NoNewWindow -PassThru -ArgumentList $params

	Write-Information $p.ExitCode

	Write-Information "Removing temporary PowerBI report ..."
	Remove-PowerBIReport -WorkspaceId $workspace.Id -Id $report.Id
	Write-Information "Removing temporary PowerBI dataset ..."
	Invoke-PowerBIRestMethod -Url "https://api.powerbi.com/v1.0/myorg/groups/$($workspace.Id)/datasets/$($dataset.Id)" -Method Delete
}
