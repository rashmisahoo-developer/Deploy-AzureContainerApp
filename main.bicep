@description('Application suffix that will be applied to all resources')
param appSuffix string = uniqueString(resourceGroup().id)

@description('The location to deploy all my resources')
param location string = resourceGroup().location

@description('The name of the log analytics workspace')
param logAnalyticsWorkspaceName string = 'log-${appSuffix}'

@description('The name of the Application Insights workspace')
param appInsightsName string = 'appinsights-${appSuffix}'

@description('The name of the Container App Environment')
param containerAppEnvironmentName string = 'env${appSuffix}'

@description('Azure AD Application (Client) ID')
param aadClientId string

@description('Azure AD Tenant ID')
param aadTenantId string

var containerAppName = 'hello-world'

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource appInsights 'microsoft.insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

resource env 'Microsoft.App/managedEnvironments@2023-08-01-preview' = {
  name: containerAppEnvironmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: containerAppName
  location: location
  identity: {
      type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: env.id
    template: {
      containers: [
        {
          name: containerAppName
          image: 'mcr.microsoft.com/k8se/quickstart:latest'
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 3
      }
    }
  }
}

resource authConfig 'Microsoft.App/containerApps/authConfigs@2024-10-02-preview' = {
name: 'current'
parent: containerApp

properties: {
  platform: {
    enabled: true
  }

  globalValidation: {
    redirectToProvider: 'azureactivedirectory'
    unauthenticatedClientAction: 'RedirectToLoginPage'
  }

  identityProviders: {
    azureActiveDirectory: {
      enabled: true

      registration: {
        clientId: aadClientId
        clientSecretSettingName: 'override-use-mi-fic-assertion-client-id'
        //openIdIssuer: 'https://login.microsoftonline.com/${aadTenantId}/v2.0'
      }
      validation: {
          defaultAuthorizationPolicy: {
            allowedApplications: []
          }
        }
    }
  }
    login: {
      // https://learn.microsoft.com/azure/container-apps/token-store
      tokenStore: {
        enabled: includeTokenStore
        azureBlobStorage: includeTokenStore ? {
          blobContainerUri: blobContainerUri
          managedIdentityResourceId: appIdentityResourceId
        } : {}
      }
    }
}
}
