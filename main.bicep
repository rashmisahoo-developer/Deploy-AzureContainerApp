@description('Application suffix that will be applied to all resources')
param appSuffix string = uniqueString(resourceGroup().id)

@description('The location to deploy all resources')
param location string = resourceGroup().location

@description('The name of the Log Analytics workspace')
param logAnalyticsWorkspaceName string = 'log-${appSuffix}'

@description('The name of the Application Insights resource')
param appInsightsName string = 'appinsights-${appSuffix}'

@description('The name of the Container App Environment')
param containerAppEnvironmentName string = 'env${appSuffix}'

@description('Existing Microsoft Entra ID App Registration client/application ID')
param aadClientId string

@description('Microsoft Entra ID tenant ID')
param aadTenantId string

@description('Client secret of the existing Microsoft Entra ID App Registration')
@secure()
param aadClientSecret string

@description('Virtual network name')
param vnetName string = 'vnet-${appSuffix}'

@description('CIDR address space for the virtual network')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('CIDR address prefix for the Container Apps infrastructure subnet')
param containerAppsSubnetPrefix string = '10.0.0.0/23'

var containerAppName = 'hello-world'
var containerAppsSubnetName = 'containerapps-subnet'

// -----------------------------------------------------------------------------
// Virtual Network
// -----------------------------------------------------------------------------

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location

  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
  }
}

// -----------------------------------------------------------------------------
// Container Apps Infrastructure Subnet
// -----------------------------------------------------------------------------

resource containerAppsSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: containerAppsSubnetName

  properties: {
    addressPrefix: containerAppsSubnetPrefix

    delegations: [
      {
        name: 'containerapps-delegation'
        properties: {
          serviceName: 'Microsoft.App/environments'
        }
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Log Analytics
// -----------------------------------------------------------------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
name: logAnalyticsWorkspaceName
location: location
properties: {
sku: {
name: 'PerGB2018'
}
}
}

// -----------------------------------------------------------------------------
// Application Insights
// -----------------------------------------------------------------------------

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
name: appInsightsName
location: location
kind: 'web'
properties: {
Application_Type: 'web'
}
}

// -----------------------------------------------------------------------------
// Container App Environment
// -----------------------------------------------------------------------------

resource env 'Microsoft.App/managedEnvironments@2023-08-01-preview' = {
name: containerAppEnvironmentName
location: location

properties: {
// VNet integration
    vnetConfiguration: {
      infrastructureSubnetId: containerAppsSubnet.id
    }
appLogsConfiguration: {
destination: 'log-analytics'

  logAnalyticsConfiguration: {
    customerId: logAnalytics.properties.customerId
    sharedKey: logAnalytics.listKeys().primarySharedKey
  }
}

}
}

// -----------------------------------------------------------------------------
// Container App
// -----------------------------------------------------------------------------

resource containerApp 'Microsoft.App/containerApps@2026-01-01' = {
name: containerAppName
location: location

// System-assigned managed identity
identity: {
type: 'SystemAssigned'
}

properties: {
managedEnvironmentId: env.id
environmentId: env.id

configuration: {
  activeRevisionsMode: 'Single'

  // Secret used by Container Apps Authentication
  // to authenticate against the existing Entra ID App Registration.
  secrets: [
    {
      name: 'microsoft-provider-authentication-secret'
      value: aadClientSecret
    }
  ]

  ingress: {
    external: false
    targetPort: 80
    exposedPort: 0
    transport: 'Auto'
    allowInsecure: false

    traffic: [
      {
        weight: 100
        latestRevision: true
      }
    ]
  }
}

template: {
  containers: [
    {
      name: containerAppName
      image: 'mcr.microsoft.com/k8se/quickstart:latest'

      resources: {
        cpu: 1
        memory: '2Gi'
      }
    }
  ]

  scale: {
    minReplicas: 0
    maxReplicas: 3
    cooldownPeriod: 300
    pollingInterval: 30
  }
}

}
}

// -----------------------------------------------------------------------------
// Container Apps Authentication
// -----------------------------------------------------------------------------

resource containerAppAuth 'Microsoft.App/containerApps/authConfigs@2026-01-01' = {
parent: containerApp
name: 'current'

properties: {
platform: {
enabled: true
}

globalValidation: {
  // Users who are not authenticated are redirected to Microsoft Entra ID.
  unauthenticatedClientAction: 'RedirectToLoginPage'
  redirectToProvider: 'azureactivedirectory'

  excludedPaths: []
}

identityProviders: {
  azureActiveDirectory: {
    registration: {
      // Existing Microsoft Entra ID tenant
      openIdIssuer: 'https://sts.windows.net/${aadTenantId}/v2.0'

      // Existing App Registration
      clientId: aadClientId

      // Secret stored in Container App configuration
      clientSecretSettingName: 'microsoft-provider-authentication-secret'
    }

    validation: {
      // Token audience must be the existing App Registration.
      allowedAudiences: [
        aadClientId
      ]

      defaultAuthorizationPolicy: {
        allowedPrincipals: {}

        // Allow tokens issued for the existing application.
        allowedApplications: [
          aadClientId
        ]
      }
    }

    // We are explicitly configuring the existing App Registration.
    isAutoProvisioned: false
  }
}

login: {
  routes: {}
  preserveUrlFragmentsForLogins: false
  cookieExpiration: {}
  nonce: {}
}

encryptionSettings: {}

}
}
