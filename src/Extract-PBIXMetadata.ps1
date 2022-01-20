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
	New-PowerBIReport -Path $pbixfile.FullName -Name $temp_name -WorkspaceId $workspace.Id

	$dataset = Get-PowerBIDataset -WorkspaceId $workspace.Id -Name $temp_name
	$connection_string = "powerbi://api.powerbi.com/v1.0/myorg/$($workspace.Name);initial catalog=$($dataset.Name)"

	#Provider=MSOLAP;Data Source=<xmla endpoint>;User ID=app:<application id>@<tenant id>;Password=<application secret>
	$executable = Join-Path $root_path tools TabularEditor2 TabularEditor.exe

	$params = @(
		"""Provider=MSOLAP;Data Source=$connection_string;User ID=app:$client_id@$tenant_id;Password=$client_secret"""
		"""$($dataset.Name)"""
		"-F"
		"""$(Join-Path $pbixFile.DirectoryName $pbixFile.BaseName '')"""
	)

	Write-Information "$executable $($params -replace $client_secret, "<REDACTED>")"
	Write-Information "$executable $params"
	& $executable $params

	$cmd = "& $executable $params"

	$result = Invoke-Expression $cmd

	Write-Host "ASDF"
}
