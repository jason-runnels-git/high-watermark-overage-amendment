# High Watermark Usage Model with Overage Amendment and Wallet Replenishment

## Overview

A Salesforce Revenue Cloud demo showing a **High Watermark consumption model**: when usage transactions exceed an anchor product's contracted quantity, an overage is detected and an Amendment Quote is automatically created, ordered, and activated — ratcheting the asset quantity to the new high watermark for future billing periods.

**Business story:**
- Anchor product (Bullhorn Core - Usage) starts at qty 5 ($100/mo per seat)
- Usage Transaction Journal records capture actual consumption via a linked Usage Resource ($120/unit overage rate)
- If Feb consumption = 8, overage = 3 → amendment delta = **3** (not cumulative)
- On activation: `Asset.CurrentQuantity` ratchets from 5 → 6, MRR updates, and the next renewal replenishes at the new baseline

---

## Demo Flow

1. Rep checks **Has Overage?** on the Account record — triggers the wizard
2. **Step 1 — Asset Picker:** Card view of all anchor assets showing subscription info, current period usage per resource, and overage warning pills
3. **Step 2 — Overage Detail Form:** Pre-populated usage resource, overage qty, billing period dates, and auto-calculated amendment line start date (first of next billing period)
4. Rep clicks **Submit** — the full chain runs automatically:
   - `/amend` endpoint creates Amendment Quote + QuoteAction + QLI
   - PST Place call patches quote name and QLI start date, triggers async pricing
   - Poll `Quote.CalculationStatus` until `Completed` or `CompletedWithPricing`
   - `createOrdersFromQuote` invocable action places the order
   - Order activated via DML → asset wallet replenishes
5. Toast confirmation + navigation to the asset record

---

## Components

### Lightning Web Components

| Component | Purpose |
|-----------|---------|
| `overageAmendmentTrigger` | Account page — wires to `Has_Overage__c`, opens the modal when checked |
| `overageAmendmentModal` | 2-step wizard: asset picker with usage/overage details → overage detail form |

### Apex

| Class | Purpose |
|-------|---------|
| `OverageAmendmentController` | Queries anchor assets, usage period items, and overage rates; orchestrates amendment creation, pricing poll, order creation, and activation |
| `AmendmentQuoteController` | Place Sales Transaction API helper |

### Custom Fields

| Object | Field | Type | Purpose |
|--------|-------|------|---------|
| `Account` | `Has_Overage__c` | Checkbox | Demo trigger — checked by rep to open the overage wizard |
| `Asset` | `CanceledByAsset__c` | Lookup(Asset) | Original asset → successor asset (billing frequency lineage) |
| `Asset` | `ReplacesAsset__c` | Lookup(Asset) | Successor asset → original asset |
| `Contract` | `RenewalOf__c` | Lookup(Contract) | Renewal contract → original contract |

### Supporting Components

| Component | Purpose |
|-----------|---------|
| `BullhornSessionProvider.page` | Visualforce page — provides full session ID via `window.postMessage` for ARM REST API calls |
| `Bullhorn_Org` Remote Site Setting | Authorizes callouts to the org domain |
| `RLM_CreateOrdersFromQuote` Flow | Standard Revenue Cloud flow for order creation from quote |

---

## Key Design Decisions

### Amendment quantity = overage delta only
The `/amend` endpoint receives only the delta (e.g. 3), not the new cumulative total. `StartQuantity` on the QuoteLineItem is calculated by the system from the current asset quantity — do not send it.

### Amendment line start date = first of next billing period
The QuoteLineItem `StartDate` is patched to the first day of the month following the billing period end date, not today. This ensures the ratcheted quantity takes effect at the correct boundary.

### `CompletedWithPricing` is a valid pricing exit state
Polling `Quote.CalculationStatus` must treat both `Completed` and `CompletedWithPricing` as done states. `CompletedWithPricing` is an undocumented variant indicating pricing ran successfully — omitting it causes an infinite poll loop.

### `createOrdersFromQuote` — quoteId must be typed as String
The invocable action binding rejects an Apex `Id` type parameter. Declare `quoteId` as `String` in Apex when calling this action.

### Grant replenishment cadence
A new additive `UsageEntitlementBucket` is created on amendment activation (by design — not a bug). Grant replenishment fires on the product's **Usage Grant Refresh Policy** renewal cadence, not on the amendment itself. The renewal uses the updated `CurrentQuantity` as the new baseline.

---

## Prerequisites

### Org Requirements
- Salesforce Revenue Cloud (RLM/RCA) org with ARM and Usage Management enabled
- Anchor product configured with `UsageModelType = Anchor` and an active Product Selling Model
- Usage Resource linked to the anchor product via a Rate Card with `RateCardType = Base`, `Status = Active`
- `BillingPeriodItem` records present for the asset's billing schedule to surface usage data in the modal
- `BullhornSessionProvider` Visualforce page deployed and accessible
- Remote Site Setting updated with **your org's My Domain URL** (see below)

### Remote Site Setting — Update Before Deploying
`remoteSiteSettings/Bullhorn_Org.remoteSite-meta.xml` contains the source org's My Domain URL. Before deploying to any other org, update line 6:

```xml
<url>https://YOUR-ORG-DOMAIN.my.salesforce.com</url>
```

Find your org's URL: **Setup → My Domain → Current My Domain URL**.

### Account Page Layout
The `RLM_Account_Record_Page` flexipage adds the **Has Overage?** trigger and the overage amendment button region to the Account Highlights Panel. Deploy the flexipage and assign it in Lightning App Builder.

### Demo Data (not deployable — load manually)

| Record | Required Fields |
|--------|----------------|
| Product2 (Anchor) | `UsageModelType = Anchor`, active PSM, active PricebookEntry |
| UsageResource | Linked to anchor product; active RateCardEntry with `RateCardType = Base` |
| Account | Any demo account |
| Asset | `Product2Id` → anchor product, `Status = Active`, `Quantity ≥ 1`, `LifecycleEndDate` in the future |
| BillingScheduleGroup | Linked to the asset via `ReferenceEntityId`; child BillingSchedule with `BillingMethod = OrderAmount` |
| BillingPeriodItem | At least one record with `OverageQuantity > 0` to pre-populate the wizard form |

---

## Deploying

### Deploy via manifest (recommended)
```bash
sf project deploy start --manifest manifest/package.xml --target-org <your-org-alias>
```

### Deploy source format
```bash
sf project deploy start --source-dir force-app --target-org <your-org-alias>
```

### Verify
```bash
sf project deploy report --target-org <your-org-alias>
```
