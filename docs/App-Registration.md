# Unattended authentication

Interactive scripts sign in as you with `Connect-MgGraph -Scopes`. For scheduled or unattended runs, use app-only authentication. Never store passwords or client secrets in a script.

## Option 1: Managed identity (preferred, Azure Automation)

1. Create an Azure Automation account and turn on its **system-assigned managed identity**.
2. Grant the identity the Microsoft Graph application permissions the runbook needs.
3. In the runbook, connect with no secrets at all:

```powershell
Connect-MgGraph -Identity
```

The Sync-CompanyDirectoryContacts runbook uses this pattern, and limits mailbox access with **Exchange RBAC for Applications** so the identity can only reach the mailboxes in a management scope.

## Option 2: Certificate (servers and scheduled tasks)

1. In Entra ID, create an **App registration** and note the tenant ID and client ID.
2. Create a certificate, upload the public key (.cer) to the app registration, and keep the private key in the machine's certificate store.
3. Grant the Graph application permissions and give admin consent.
4. Connect with the certificate thumbprint:

```powershell
Connect-MgGraph -TenantId "<tenant-id>" -ClientId "<client-id>" -CertificateThumbprint "<thumbprint>"
```

Never commit certificates (.pfx, .cer) or keys to a repository. This repo's `.gitignore` blocks them.

---

[Back to the toolkit](../README.md)
