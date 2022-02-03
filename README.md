# PowerBI.CICD
This repository provides sampe YAML pipelines for Github and Azure DevOps which automatically extract the metadata (`.bim`, [TOM](https://docs.microsoft.com/en-us/analysis-services/tom/introduction-to-the-tabular-object-model-tom-in-analysis-services-amo?view=asallproducts-allversions) whenever a Power BI Desktop file (`.pbix`) is pushed to the repository.
The `.bim` file is stored next to the `.pbix` file but with the file extension `.database.json`.

This solves these very common problems with Power BI Desktop files `.pbix` and CI/CD pipelines:
- automated tracking of what was changed in the data model
- easy deployment to a Power BI Premium workspace using other tools like [Tabular Editor](https://tabulareditor.com/) or [ALM Toolkit](http://alm-toolkit.com/) from the created BIM file.
- uses officially supported tools and interfaces only

The idea is to have a single YAML file that you can simply copy&paste to your repository and run in CI/CD pipeline without any external dependencies. The only things that need to be configured are the credentials for connecting to the Power BI Service.

# General workflow and steps
The repository contains a [.yml file for Github Actions and a YAML](.github/workflows/pbix_to_bim.yml) and a [.yaml file for Azure DevOps pipelines](Azure%20DevOps/pbix_to_bim.yaml) which are slightly different but in general contain the same setps:

### Triggers
The pipeline is currently designed to extract the metadata on every push. So you can track every change that you do in your `.pbix` file also in the corresponding `.database.json` file and also to have a collection of all changes when creating the final pull request (PR).

To avoid unnecessary executions we only run the pipeline when the changes contain at least one `.pbix` file by using the path-filter `'**/*.pbix'`.

In addition to the automated trigger on push, the pipeline can also be executed manually. In this case you get prompted for a sub-path so you can decide for which `.pbix` you want to extract the metadata. (Default value is `/`)

### Checkout Repository
Check-out the latest version of the repository after the current push.

### Download Tabular Editor
The free versino of Tabular Editor 2 is used to extract the metadata from the deployed dataset so we need to download the tool first. It will be downloaded to the root-path of the repository.

The script was originally taken from https://github.com/TabularEditor/DevOps/blob/main/Scripts/DownloadTE2.ps1

The PowerShell code resides in the YAML file directly but is also present under `/src/Download-TabularEditor.ps1` as a reference and for local testing and development.

### Get Commit IDs (Azure DevOps only)
Azure DevOps does not provide built-in environment variables to get the commit ids before and after this git push so we need to get them via the Azure DevOps REST API [Get Build Changes)](ttps://docs.microsoft.com/en-us/rest/api/azure/devops/build/builds/get-build-changes?view=azure-devops-rest-7.19). The oldest commit id is then stored as `GIT_EVENT_BEFORE` and the newest/current as `GIT_EVENT_AFTER` into the environment to be used by the next step.

**Note:** We are using the same environment variables that are also set in the Github pipeline so we can use the very same PowerShell script for both engines.

### Extract BIM from PBIX
This is the root of the whole pipeline. The script downloads and installs the latest [MicrosoftPowerBIMgmt](https://docs.microsoft.com/en-us/powershell/power-bi/overview?view=powerbi-ps9) PowerShell module and reads all relevant environment variables into local variables for easier use. Based on the set environment variables it connects to the Power BI service and the Premiums Workspace (`PBI_PREMIUM_WORKSPACE_ID`) either using Service Principal authentciation (`PBI_TENANT_ID`, `PBI_CLIENT_ID`, `PBI_CLIENT_SECRET`) or Username/Password authentication (`PBI_USER_NAME`, `PBI_USER_PASSWORD`).
It then gets all changed `.pbix` files in the current push and iterates over them. For each file the following operations are executed:
- Checks if the current `.pbix` file actually contains a datamodel. This is not the case for thin reports which simply connect to a remote dataset. If no datamodel was found, the script continues with the next `.pbix` file.
- Create a temporary, unique name to be used when uploading the dataset to the PBI service
- Upload the dataset to the PBI service
- Get the metadata of the uploaded dataset (also ensuring it was uploaded successfully)
- Run `TabularEditor.exe` and extract the metadata of the datamodel and store it in a local file `.database.json`
- Update `name` and `id` of the `.database.json` file and replace the temporary values generated during the upload with the name of the original `.pbix` file

The PowerShell code resides in the YAML file directly as inline script but is also present under `/src/Extract-PBIXMetadata.ps1` for reference and local testing and development.

### Push BIM Files to Git repo
The last step is to push the new/updated `.database.json` files back to the repositories current branch. 

# Github Action
The final YAML file for the Github Action can be found here: [pbix_to_bim.yaml](GitHub/pbix_to_bim.yaml)

The mandatory (environment)[#environment_variables] variables can be specified using Github Secrets and/or Environments: (Set up Secrets in GitHub Action workflows)[https://github.com/Azure/actions-workflow-samples/blob/master/assets/create-secrets-for-GitHub-workflows.md]

The reference to the secrets/environment has to be updated in the YAML file (line 17) then:
```
jobs:
  extract_pbix_metadata:
    runs-on: windows-latest
    environment: PowerBI UsernamePassword    # <-- change this to match your library/variable group
```

# Azure DevOps Pipeline
The final YAML file for the Azure DevOps Pipeline can be found here: [pbix_to_bim.yaml](Azure%20DevOps/pbix_to_bim.yaml)

The mandatory [environment variables](#environment_variables) can be specified using Github Secrets and/or Environments: 
- [Set up Secrets in GitHub Action workflows](https://github.com/Azure/actions-workflow-samples/blob/master/assets/create-secrets-for-GitHub-workflows.md)
- [Add & use variable groups](https://docs.microsoft.com/en-us/azure/devops/pipelines/library/variable-groups?view=azure-devops&tabs=yaml#create-a-variable-group)

The reference to the secrets/environment has to be updated in the YAML file (line 22) then:
```
variables:
- group: PowerBI ServicePrincipal    # <-- change this to match your library/variable group
```

To allow the pipeline to also push changes to the git repository, the service user executing the pipeline needs to be added as a contributor of the repo:
- [Grant version control permissions to the build service](https://docs.microsoft.com/en-us/azure/devops/pipelines/scripts/git-commands?view=azure-devops&tabs=yaml#grant-version-control-permissions-to-the-build-service)
- [Stack Overflow: Azure pipeline does't allow to git push throwing 'GenericContribute' permission is needed](https://stackoverflow.com/questions/56541458/azure-pipeline-doest-allow-to-git-push-throwing-genericcontribute-permission)


# Environment Variables
`PBI_PREMIUM_WORKSPACE_ID`: the unique ID of Power BI Premium workspace to use when uploading the `.pbix` files.
The identity that you use (service principal or user - see below) has to have at least `Contributor` permissions on the workspace to upload the `.pbix` files.

It supports two authentication methods, via a service principal or using username/password.
Depending on the environment variables that are set up, one or the other is used where service principal authentication has precedence in case both are specified:

## Service Principal Authentication
- `PBI_TENANT_ID`: The unique ID of the Azure Active Directory tenant
- `PBI_CLIENT_ID`: The unique client/application ID of the service principal to use for authentcation
- `PBI_CLIENT_SECRET`: The password of the service principal to use for authentcation

## User Authentication
- `PBI_USER_NAME`: The username/email of the user to use for authentcation
- `PBI_USER_PASSWORD`: The password of the user to use for authentcation


# Other references 
**Power BI and Service Principals**
- https://docs.microsoft.com/en-us/power-bi/admin/service-premium-service-principal
- https://tabulareditor.github.io/2020/06/02/PBI-SP-Access.html

**Tabular Editor 2**
- https://docs.tabulareditor.com/te2/Getting-Started.html
- https://docs.tabulareditor.com/te2/Command-line-Options.html