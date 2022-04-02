# Download URL for Tabular Editor portable:
$TabularEditorUrl = "https://cdn.tabulareditor.com/files/te2/TabularEditor.Portable.zip" 

# Download destination (root of PowerShell script execution path):
$DownloadDestination = Join-Path (Get-Location) "TabularEditor.zip"

# Download from GitHub:
Invoke-WebRequest -Uri $TabularEditorUrl -OutFile $DownloadDestination

# Unzip Tabular Editor portable, and then delete the zip file:
Expand-Archive -Path $DownloadDestination -DestinationPath (Get-Location).Path -Force
Remove-Item $DownloadDestination