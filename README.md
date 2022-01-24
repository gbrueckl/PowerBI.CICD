# PowerBI.CICD
Template for Github/YAML action to extract metadata (.bim) from Power BI .pbix files on push.

# Mandatory Environment Variables
`PBI_PREMIUM_WORKSPACE_ID`: the unique ID of Power BI Premium workspace to use when uploading the `.pbix` files.
The identity that you use (see below) has to have at least `Contributor` permissions on the workspace to upload the `.pbix` files.

## Service Principal Authentication
- `PBI_TENANT_ID`: The unique ID of the Azure Active Directory tenant
- `PBI_CLIENT_ID`: The unique client/application ID of the service principal to use for authentcation
- `PBI_CLIENT_SECRET`: The password of the service principal to use for authentcation

## User Authentication
- `PBI_USER_NAME`: The username/email of the user to use for authentcation
- `PBI_USER_PASSWORD`: The password of the user to use for authentcation



https://docs.microsoft.com/en-us/power-bi/admin/service-premium-service-principal
https://docs.tabulareditor.com/te2/Getting-Started.html
https://tabulareditor.github.io/2020/06/02/PBI-SP-Access.html

https://docs.tabulareditor.com/te2/Command-line-Options.html