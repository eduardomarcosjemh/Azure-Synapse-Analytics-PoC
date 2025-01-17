#!/bin/bash
#
# This script finishes the database level configuration that cannot be done in Terraform. It should be executed after the Terraform 
# deployment because Terraform outputs several variables used by this script.
#
#   @Azure:~$ git clone https://github.com/shaneochotny/Azure-Synapse-Analytics-PoC
#   @Azure:~$ cd Azure-Synapse-Analytics-PoC
#   @Azure:~$ nano environment.tf
#   @Azure:~$ terraform init
#   @Azure:~$ terraform plan
#   @Azure:~$ terraform apply
#   @Azure:~$ bash configure.sh
#

# Make sure this configuration script hasn't been executed already
if [ -f "configure.complete" ]; then
    echo "ERROR: It appears this configuration has already been completed.";
    exit 1;
fi

# Make sure we have all the required artifacts
declare -A artifactFiles
artifactFiles[1]="artifacts/triggerPause.json.tmpl"
artifactFiles[2]="artifacts/triggerResume.json.tmpl"
artifactFiles[3]="artifacts/Auto_Pause_and_Resume.json.tmpl"
artifactFiles[4]="artifacts/Demo_Data_Serverless_DDL.sql"
artifactFiles[5]="artifacts/logging.AutoIngestion_DDL.sql"
artifactFiles[6]="artifacts/logging.DataProfile_DDL.sql"
for file in "${artifactFiles[@]}"; do
    if ! [ -f "$file" ]; then
        echo "ERROR: The required $file file does not exist. Please clone the git repo with the supporting artifacts and then execute this script.";
        exit 1;
    fi
done

# Try and determine if we're executing from within the Azure Cloud Shell
if [ ! "${AZUREPS_HOST_ENVIRONMENT}" = "cloud-shell/1.0" ]; then
    echo "ERROR: It doesn't appear like your executing this from the Azure Cloud Shell. Please use the Azure Cloud Shell at https://shell.azure.com";
    exit 1;
fi

# Try and get a token to validate that we're logged into Azure CLI
aadToken=$(az account get-access-token --resource=https://dev.azuresynapse.net --query accessToken --output tsv 2>&1)
if echo "$aadToken" | grep -q "ERROR"; then
    echo "ERROR: You don't appear to be logged in to Azure CLI. Please login to the Azure CLI using 'az login'";
    exit 1;
fi

# Make sure the Terraform deployment was completed by checking if the terraform.tfstate file exists
if ! [ -f "terraform.tfstate" ]; then
    echo "ERROR: It does not appear that the Terraform deployment was completed for the Synaspe Analytics environment. That must be completed before executing this script.";
    exit 1;
fi

# Get environment details
azureSubscriptionName=$(az account show --query "name" --output tsv 2>&1)
echo "Azure Subscription: ${azureSubscriptionName}"
azureSubscriptionID=$(az account show --query "id" --output tsv 2>&1)
echo "Azure Subscription ID: ${azureSubscriptionID}"
azureUsername=$(az account show --query "user.name" --output tsv 2>&1)
echo "Azure AD Username: ${azureUsername}"

# Get the output variables from Terraform
synapseAnalyticsWorkspaceResourceGroup=$(terraform output -raw synapse_analytics_workspace_resource_group 2>&1)
synapseAnalyticsWorkspaceName=$(terraform output -raw synapse_analytics_workspace_name 2>&1)
synapseAnalyticsSQLAdmin=$(terraform output -raw synapse_sql_administrator_login 2>&1)
synapseAnalyticsSQLAdminPassword=$(terraform output -raw synapse_sql_administrator_login_password 2>&1)
if echo "$synapseAnalyticsWorkspaceName" | grep -q "The output variable requested could not be found"; then
    echo "ERROR: It doesn't look like a 'terraform apply' was performed. This script needs to be executed after the Terraform deployment.";
    exit 1;
fi
echo "Synapse Analytics Workspace Resource Group: ${synapseAnalyticsWorkspaceResourceGroup}"
echo "Synapse Analytics Workspace: ${synapseAnalyticsWorkspaceName}"
echo "Synapse Analytics SQL Admin: ${synapseAnalyticsSQLAdmin}"

# Enable Result Set Cache
echo "Enabling Result Set Caching..."
sqlcmd -U sqladminuser -P ${synapseAnalyticsSQLAdminPassword} -S tcp:${synapseAnalyticsWorkspaceName}.sql.azuresynapse.net -d master -I -Q "ALTER DATABASE DataWarehouse SET RESULT_SET_CACHING ON;"

echo "Creating the auto pause/resume pipeline..."

# Copy the Auto_Pause_and_Resume Pipeline template and update the variables
cp artifacts/Auto_Pause_and_Resume.json.tmpl artifacts/Auto_Pause_and_Resume.json 2>&1
sed -i "s/REPLACE_SUBSCRIPTION/${azureSubscriptionID}/g" artifacts/Auto_Pause_and_Resume.json
sed -i "s/REPLACE_RESOURCE_GROUP/${synapseAnalyticsWorkspaceResourceGroup}/g" artifacts/Auto_Pause_and_Resume.json
sed -i "s/REPLACE_SYNAPSE_ANALYTICS_WORKSPACE_NAME/${synapseAnalyticsWorkspaceName}/g" artifacts/Auto_Pause_and_Resume.json

# Create the Auto_Pause_and_Resume Pipeline in the Synapse Analytics Workspace
az synapse pipeline create --only-show-errors -o none --workspace-name ${synapseAnalyticsWorkspaceName} --name "Auto Pause and Resume" --file @artifacts/Auto_Pause_and_Resume.json

# Create the Pause/Resume triggers in the Synapse Analytics Workspace
az synapse trigger create --only-show-errors -o none --workspace-name ${synapseAnalyticsWorkspaceName} --name Pause --file @artifacts/triggerPause.json.tmpl
az synapse trigger create --only-show-errors -o none --workspace-name ${synapseAnalyticsWorkspaceName} --name Resume --file @artifacts/triggerResume.json.tmpl

# Create the logging schema and tables for the Auto Ingestion pipeline
sqlcmd -U sqladminuser -P ${synapseAnalyticsSQLAdminPassword} -S tcp:${synapseAnalyticsWorkspaceName}.sql.azuresynapse.net -d DataWarehouse -I -Q "CREATE SCHEMA logging;"
sqlcmd -U sqladminuser -P ${synapseAnalyticsSQLAdminPassword} -S tcp:${synapseAnalyticsWorkspaceName}.sql.azuresynapse.net -d DataWarehouse -I -i artifacts/logging.AutoIngestion_DDL.sql
sqlcmd -U sqladminuser -P ${synapseAnalyticsSQLAdminPassword} -S tcp:${synapseAnalyticsWorkspaceName}.sql.azuresynapse.net -d DataWarehouse -I -i artifacts/logging.DataProfile_DDL.sql

# Create the Synapse_Managed_Identity Linked Service. This is primarily used for the Auto Ingestion pipeline.
cp artifacts/LS_Synapse_Managed_Identity.json.tmpl artifacts/LS_Synapse_Managed_Identity.json 2>&1
sed -i "s/REPLACE_SYNAPSE_ANALYTICS_WORKSPACE_NAME/${synapseAnalyticsWorkspaceName}/g" artifacts/LS_Synapse_Managed_Identity.json
az synapse linked-service set --only-show-errors -o none --workspace-name ${synapseAnalyticsWorkspaceName} --name LS_Synapse_Managed_Identity --file @artifacts/LS_Synapse_Managed_Identity.json

echo "Creating the Demo Data database using Synapse Serverless SQL..."

# Create a Demo Data database using Synapse Serverless SQL
sqlcmd -U sqladminuser -P ${synapseAnalyticsSQLAdminPassword} -S tcp:${synapseAnalyticsWorkspaceName}-ondemand.sql.azuresynapse.net -d master -I -Q "CREATE DATABASE [Demo Data (Serverless)];"

# Create the Views over the external data
sqlcmd -U sqladminuser -P ${synapseAnalyticsSQLAdminPassword} -S tcp:${synapseAnalyticsWorkspaceName}-ondemand.sql.azuresynapse.net -d "Demo Data (Serverless)" -I -i artifacts/Demo_Data_Serverless_DDL.sql

# Remove the "Allow Azure Services..." from the firewall rules on Azure Synapse Analytics. That was needed temporarily to apply these settings.
echo "Updating firewall rules..."
az synapse workspace firewall-rule delete --name AllowAllWindowsAzureIps --resource-group ${synapseAnalyticsWorkspaceResourceGroup} --workspace-name ${synapseAnalyticsWorkspaceName} --only-show-errors -o none --yes

echo "Deployment complete!"
touch configure.complete