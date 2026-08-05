# Manage Billing Frequency Changes for Existing Customers

## Overview

ARM Billing cannot change billing frequency of assets with proper Asset Record Succession behavior. The supported workaround is a contract-based "cancel and replace" approach at renewal. This lets the original assets expire naturally and generates a new renewal transaction with a new PSM (higher billing frequency) and activates new assets on the new Renewal Contract.

> **Note:** The "fix" for standalone Billing in release 264 does not support "CPQ" use cases.

This asset offers a Wizard-like experience to Manage Billing Frequency changes for existing customers. The account-level Contract view of assets and obligation management offer additional visuals to help explain the trade-offs and benefits of this product gap.

---

## Asset Record Succession Pattern

When a customer wants to upgrade billing frequency (e.g. Monthly → Quarterly → Annual), the system does not modify the existing asset in-place. Instead it creates a **successor asset** on a new Renewal Contract with the upgraded PSM. The original and successor assets are linked via bi-directional custom lookup fields, providing a clear lineage chain for reporting and analytics.

**Upgrade path:** `Monthly < Quarterly < Semi-Annual < Annual`
**Constraint:** Upgrades must stay within the same SellingModelType (Term → Term, Evergreen → Evergreen).

---

## Components

### Lightning Web Components

| Component | Purpose |
|-----------|---------|
| `billingFrequencyTrigger` | Account page button — launches the billing frequency modal |
| `billingFrequencyModal` | Multi-step wizard: (1) Contract selection, (2) per-line PSM upgrade picker, (3) Confirm |

### Apex

| Class | Purpose |
|-------|---------|
| `BillingFrequencyController` | Orchestrates ARM REST calls: `/amend` endpoint, PSM swap via PricebookEntry, repricing, Renewal Contract + Obligation record creation |

### Custom Fields

| Object | Field | Type | Purpose |
|--------|-------|------|---------|
| `Asset` | `CanceledByAsset__c` | Lookup(Asset) | Original asset → successor asset |
| `Asset` | `ReplacesAsset__c` | Lookup(Asset) | Successor asset → original asset |
| `Contract` | `RenewalOf__c` | Lookup(Contract) | Renewal contract → original contract |

### Supporting Components

| Component | Purpose |
|-----------|---------|
| `BullhornSessionProvider.page` | Visualforce page — provides full session ID via `window.postMessage` for ARM REST API calls |
| `Bullhorn_Org` Remote Site Setting | Authorizes callouts to the org domain |

---

## Key Design Decisions

### `/amend` not `/renew`
The `/renew` endpoint produces quotes with `TransactionType = AdvancedConfigurator`. The PST (Place Sales Transaction) API cannot operate on these quotes. The `/amend` endpoint with `quantityChange=0` and `amendmentStartDate = renewal contract start date` generates a standard Amendment Quote that PST handles correctly.

### No cancel lines on the quote
Original assets expire naturally at `LifecycleEndDate` — no cancel QuoteAction is needed for the renewal use case. Cancel QuoteActions are for mid-term amendments only. Asset succession lineage is tracked via custom fields stamped post-activation.

### Obligation records
One Obligation record is created per frequency-changed product line on the renewal Contract, documenting the billing frequency change for compliance and reporting.

### Session ID
`UserInfo.getSessionId()` returns a restricted Lightning session (401 on REST calls from Apex). Session ID is obtained via the `BullhornSessionProvider` Visualforce page using `window.postMessage`.

---

## Prerequisites

- Salesforce Revenue Cloud (RLM/RCA) org
- ARM Billing enabled
- Products configured with multiple PSMs (Monthly, Quarterly, Semi-Annual, Annual)
- `BullhornSessionProvider` Visualforce page deployed and accessible
- Connected App with appropriate OAuth scopes for ARM REST API callouts
