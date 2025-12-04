// this is a template for deploying a container instance that uses SP credentials from Key Vault
// it includes the SP credential module, and shows how to reference the secrets in environment variables

param kvName string
param spName string

resource kv 'Microsoft.KeyVault/vaults@2022-07-01' existing = {
  name: kvName
}

module spCreds './sp-credentials.bicep' = {
  name: 'spCreds'
  params: {
    clientId: kv.getSecret('${spName}-client-id')
    clientSecret: kv.getSecret('${spName}-client-secret')
    tenantId: kv.getSecret('${spName}-tenant-id')
  }
}

resource containerGroup 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: '${spName}-container'
  location: resourceGroup().location
  properties: {
    containers: [
      {
        name: 'app'
        properties: {
          image: '<acr-name>.azurecr.io/myimage:latest'
          environmentVariables: [
            {
              name: 'AZURE_CLIENT_ID'
              value: spCreds.outputs.clientId
            }
            {
              name: 'AZURE_CLIENT_SECRET'
              secureValue: spCreds.outputs.clientSecret
            }
            {
              name: 'AZURE_TENANT_ID'
              value: spCreds.outputs.tenantId
            }
          ]
        }
      }
    ]
  }
}
