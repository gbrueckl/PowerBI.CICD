# PowerBI.CICD
Template for Github/YAML action to extract metadata (.bim) from Power BI .pbix files on push automatically.

# Environment Variables
`PBI_PREMIUM_WORKSPACE_ID`: the unique ID of Power BI Premium workspace to use when uploading the `.pbix` files.
The identity that you use (see below) has to have at least `Contributor` permissions on the workspace to upload the `.pbix` files.

It supports two authentication methods, via a service principal or using username/password.
Depending on the environment variables that are set up, one or the other is used where service principal authentication has precedence in case both are specified:

## Service Principal Authentication
- `PBI_TENANT_ID`: The unique ID of the Azure Active Directory tenant
- `PBI_CLIENT_ID`: The unique client/application ID of the service principal to use for authentcation
- `PBI_CLIENT_SECRET`: The password of the service principal to use for authentcation

## User Authentication
- `PBI_USER_NAME`: The username/email of the user to use for authentcation
- `PBI_USER_PASSWORD`: The password of the user to use for authentcation

# Specifying the environment
As every workflow also this one does support multiple environment configurations. The environment you want to use must at least contain the variables as defined above and its name needs to be set in the `.yaml` file. Please see tag `environment:` and change it accordingly (line 12).

# Triggers
The workflow will be triggered whenever you push changes to the repository that contain at least one `.pbix` file.
This change can be a newly added file or a modified/moved existing file.

However, you can also manually trigger the workflow to extract the dataset metadata file from all `.pbix` files in the current repository.

# Job Steps
## Download Tabular Editor 2
Tabular Editor 2 is used to extract the BIM file from a Power BI dataset deployed to a Power BI Premium workspace with XMLA endpoint enable. So we need to download the executable file before we can use it.
The script was originally taken from https://github.com/TabularEditor/DevOps/blob/main/Scripts/DownloadTE2.ps1

The PowerShell code resides in the YAML file directly but is also present under `/src/Download-TabularEditor.ps1` for local testing and development.

## Extract BIM from PBIX
Thats the heart of the action. It first gets all add/modified/moved `.pbix` files in the current push and iterates over them.
For each file it is checked whether it contains a datamodel or not (e.g thin reports connected to a AAS instance or PBI dataset). If a datamodel is present, it will be uploaded to the PBI workspace defined by the environment variable `PBI_PREMIUM_WORKSPACE_ID`. To make sure there are no conflicts, a unique, temporary name for the report/dataset to be uploaded is created. Once the file is uploaded, the dataset that was deployed is retrieved again to get all its details. Based on them the connection string for the XMLA endpoint is generated and then passed to Tabular Editor which connects to it and downloads the definition of the data model into `*.database.json` file. Afterwards all artifacts are removed again from the PBI workspace.

The PowerShell code resides in the YAML file directly but is also present under `/src/Extract-PBIXMetadata.ps1` for local testing and development.

## Push BIM Files
The last step is to push the current changes - the modified or added `*.database.json` files - back to the repository. The changes are pushed in the name of the author who did the intial push that triggered the action. The comment also gives some information about the workflow and the author.



# Other references 
- https://docs.microsoft.com/en-us/power-bi/admin/service-premium-service-principal
- https://docs.tabulareditor.com/te2/Getting-Started.html
- https://tabulareditor.github.io/2020/06/02/PBI-SP-Access.html
- https://docs.tabulareditor.com/te2/Command-line-Options.html