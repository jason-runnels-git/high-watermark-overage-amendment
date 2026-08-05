# Manage Billing Frequency Changes for Existing Customers

![Billing Frequency Management](BillingFrequencyManagement.jpg)

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

### Org Requirements
- Salesforce Revenue Cloud (RLM/RCA) org with ARM Billing enabled
- Products configured with multiple PSMs (Monthly, Quarterly, Semi-Annual, Annual) sharing the same PricebookEntry structure
- `BullhornSessionProvider` Visualforce page deployed and accessible
- Remote Site Setting authorizing callouts to the org domain

### Asset Renewal Fields
Each active Asset must have `RenewalTermUnit` and `RenewalTerm` populated before the `/renew` endpoint can be called. If these are null, the solution patches them automatically from the asset's BillingScheduleGroup at submission time. If no BSG exists for an asset, set these fields manually on the Asset record:
- `RenewalTermUnit` — match the asset's current billing frequency (e.g. `Months`, `Quarterly`, `Annual`)
- `RenewalTerm` — typically `1`

### Billing Treatment Configuration
The `/renew` API path requires that your Billing Treatment have **Change Billing Frequency** enabled. This is a data configuration step — not deployable as metadata.

**Setup path:** Revenue Cloud App → Billing Policies → select your Billing Policy → Billing Treatments → open the relevant treatment → check **Change Billing Frequency = true**

If this flag is not set, the `/renew` endpoint will generate assets on the renewal contract but billing schedule continuity will not be maintained correctly across the frequency change.

### Account Page Layout
The `RLM_Account_Record_Page` flexipage is included in this repo and adds:
- **Contracts tab** — lists active contracts with start/end dates directly on the Account record
- **Billing Frequency Management button** — launches the wizard from the Account Highlights Panel
- **Billing Schedule Groups tab** — shows BSG records for billing frequency diagnostics

Deploy the flexipage and assign it to the Account object in Lightning App Builder to activate.
