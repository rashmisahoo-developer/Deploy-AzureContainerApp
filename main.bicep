// -----------------------------------------------------------------------------
// Microsoft Graph Bicep extension
// -----------------------------------------------------------------------------
//
// Requires Bicep CLI v0.36.1 or later.
//
// The identity deploying this template must have sufficient Microsoft Graph
// permissions to update the existing Entra ID application.
//
// IMPORTANT:
// The existing Entra application must have been onboarded to Microsoft Graph
// Bicep using its uniqueName.
// -----------------------------------------------------------------------------

extension 'br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:1.0.0'

// -----------------------------------------------------------------------------
// Parameters
// -----------------------------------------------------------------------------

@description('Application suffix that will be applied to all Azure resources')
param appSuffix string = uniqueString(resourceGroup().id)

@description('The location to deploy all Azure resources')
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

@description('The uniqueName assigned to the existing Microsoft Entra application for Microsoft Graph Bicep management')
param aadApplicationUniqueName string

// -----------------------------------------------------------------------------
// Variables
// -----------------------------------------------------------------------------

var containerAppName = 'hello-world'

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

      // -----------------------------------------------------------------------
      // Container Apps Authentication secret
      // -----------------------------------------------------------------------
      //
      // This secret contains the client secret belonging to the existing
      // Microsoft Entra application.
      //
      secrets: [
        {
          name: 'microsoft-provider-authentication-secret'
          value: aadClientSecret
        }
      ]

      // -----------------------------------------------------------------------
      // Ingress
      // -----------------------------------------------------------------------

      ingress: {
        external: true
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

    // -------------------------------------------------------------------------
    // Container template
    // -------------------------------------------------------------------------

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
// Container App FQDN
// -----------------------------------------------------------------------------
//
// Container Apps generates the FQDN after the application is created.
//
// Example:
//
// hello-world.bluesky-75ceef1c.centralus.azurecontainerapps.io
//
// The FQDN is used to construct the Microsoft Entra Easy Auth callback URI.
// -----------------------------------------------------------------------------

var containerAppFqdn = containerApp.properties.configuration.ingress.fqdn

var aadRedirectUri = 'https://${containerAppFqdn}/.auth/login/aad/callback'

// -----------------------------------------------------------------------------
// Existing Microsoft Entra Application
// -----------------------------------------------------------------------------
//
// This updates the EXISTING application registration.
//
// IMPORTANT:
// aadApplicationUniqueName is NOT the client/application ID.
//
// It is the immutable uniqueName used by Microsoft Graph Bicep to identify
// an existing application.
//
// The application must first be onboarded with that uniqueName.
// -----------------------------------------------------------------------------

resource aadApplication 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: aadApplicationUniqueName

  web: {
    redirectUris: [
      aadRedirectUri
    ]

    implicitGrantSettings: {
      // Required by Container Apps Easy Auth.
      enableIdTokenIssuance: true

      // Not required for this authentication flow.
      enableAccessTokenIssuance: false
    }
  }

  dependsOn: [
    containerApp
  ]
}

// -----------------------------------------------------------------------------
// Container Apps Authentication / Easy Auth
// -----------------------------------------------------------------------------

resource containerAppAuth 'Microsoft.App/containerApps/authConfigs@2026-01-01' = {
  parent: containerApp
  name: 'current'

  properties: {
    platform: {
      enabled: true
    }

    // -------------------------------------------------------------------------
    // Global authentication behavior
    // -------------------------------------------------------------------------

    globalValidation: {
      // Redirect unauthenticated users to Microsoft Entra ID.
      unauthenticatedClientAction: 'RedirectToLoginPage'

      redirectToProvider: 'azureactivedirectory'

      excludedPaths: []
    }

    // -------------------------------------------------------------------------
    // Microsoft Entra ID provider
    // -------------------------------------------------------------------------

    identityProviders: {
      azureActiveDirectory: {
        registration: {
          // Microsoft Entra ID v2.0 issuer.
          openIdIssuer: 'https://login.microsoftonline.com/${aadTenantId}/v2.0'

          // Existing Microsoft Entra application.
          clientId: aadClientId

          // Secret stored in Container App configuration.
          clientSecretSettingName: 'microsoft-provider-authentication-secret'
        }

        // ---------------------------------------------------------------------
        // Token validation
        // ---------------------------------------------------------------------

        validation: {
          // The application's client ID is the expected token audience.
          allowedAudiences: [
            aadClientId
          ]

          defaultAuthorizationPolicy: {
            allowedPrincipals: {}

            // Only tokens issued for this application are allowed.
            allowedApplications: [
              aadClientId
            ]
          }
        }

        // We are explicitly configuring an existing Entra application.
        isAutoProvisioned: false
      }
    }

    // -------------------------------------------------------------------------
    // Login settings
    // -------------------------------------------------------------------------

    login: {
      routes: {}

      preserveUrlFragmentsForLogins: false

      cookieExpiration: {}

      nonce: {}
    }

    // -------------------------------------------------------------------------
    // Encryption
    // -------------------------------------------------------------------------

    encryptionSettings: {}
  }

  // Ensure the Entra redirect URI has been configured before Easy Auth.
  dependsOn: [
    aadApplication
  ]
}

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------

@description('The URL of the deployed Container App')
output containerAppUrl string = 'https://${containerAppFqdn}'

@description('The Container Apps Easy Auth Microsoft Entra callback URI')
output aadRedirectUri string = aadRedirectUri

@description('The existing Microsoft Entra application client ID')
output aadClientIdOutput string = aadClientId

@description('The Microsoft Entra tenant ID')
output aadTenantIdOutput string = aadTenantId
