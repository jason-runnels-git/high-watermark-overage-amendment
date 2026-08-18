public with sharing class OverageAmendmentController {

    @AuraEnabled(cacheable=true)
    public static List<AssetWrapper> getUsageAssets(Id accountId) {
        // Step 1: Get anchor assets
        List<Asset> assets = [
            SELECT Id, Name, Product2Id, Product2.Name, CurrentQuantity, CurrentMrr,
                   LifecycleStartDate, LifecycleEndDate
            FROM Asset
            WHERE AccountId = :accountId
              AND Product2.UsageModelType = 'Anchor'
            ORDER BY Name
        ];
        if (assets.isEmpty()) return new List<AssetWrapper>();

        Set<Id> assetIds = new Map<Id, Asset>(assets).keySet();

        // Step 2: Billing Schedule Groups + Schedules (subscription info)
        Map<Id, BsgInfo> bsgInfoByAsset = new Map<Id, BsgInfo>();
        for (BillingScheduleGroup bsg : [
            SELECT Id, ReferenceEntityId, BillingTermUnit,
                (SELECT Id, Status, NextBillingDate, Quantity, UnitPrice
                 FROM BillingScheduleGroupToBillingSchedule
                 WHERE Status = 'ReadyForInvoicing'
                 LIMIT 1)
            FROM BillingScheduleGroup
            WHERE ReferenceEntityId IN :assetIds
              AND BillingMethod = 'OrderAmount'
        ]) {
            if (!bsg.BillingScheduleGroupToBillingSchedule.isEmpty()) {
                BsgInfo info = new BsgInfo();
                info.billingTermUnit = bsg.BillingTermUnit;
                info.schedule = bsg.BillingScheduleGroupToBillingSchedule[0];
                bsgInfoByAsset.put(bsg.ReferenceEntityId, info);
            }
        }

        // Step 3: All UsageBillingPeriodItems with overage > 0 (OVERAGE INFO section)
        Map<Id, List<UsageBillingPeriodItem>> overageItemsByAsset = new Map<Id, List<UsageBillingPeriodItem>>();
        // Also current InProgress items to know active usage resources
        Map<Id, List<UsageBillingPeriodItem>> currentItemsByAsset = new Map<Id, List<UsageBillingPeriodItem>>();

        for (UsageBillingPeriodItem item : [
            SELECT Id, AssetId, UsageResourceId, StartDateTime, EndDateTime,
                   OverageQuantity, OverageAmount, TotalUsedQuantity, Status
            FROM UsageBillingPeriodItem
            WHERE AssetId IN :assetIds
            ORDER BY StartDateTime DESC
        ]) {
            // Overage history
            if (item.OverageQuantity != null && item.OverageQuantity > 0) {
                if (!overageItemsByAsset.containsKey(item.AssetId)) {
                    overageItemsByAsset.put(item.AssetId, new List<UsageBillingPeriodItem>());
                }
                overageItemsByAsset.get(item.AssetId).add(item);
            }
            // Current period (InProgress)
            if (item.Status == 'InProgress') {
                if (!currentItemsByAsset.containsKey(item.AssetId)) {
                    currentItemsByAsset.put(item.AssetId, new List<UsageBillingPeriodItem>());
                }
                currentItemsByAsset.get(item.AssetId).add(item);
            }
        }

        // Step 4: Collect all resource IDs across both sets
        Set<Id> resourceIds = new Set<Id>();
        for (List<UsageBillingPeriodItem> items : overageItemsByAsset.values()) {
            for (UsageBillingPeriodItem item : items) resourceIds.add(item.UsageResourceId);
        }
        for (List<UsageBillingPeriodItem> items : currentItemsByAsset.values()) {
            for (UsageBillingPeriodItem item : items) resourceIds.add(item.UsageResourceId);
        }

        Map<Id, Decimal> rateByResource = new Map<Id, Decimal>();
        Map<Id, String> resourceNameById = new Map<Id, String>();
        if (!resourceIds.isEmpty()) {
            for (RateCardEntry rce : [
                SELECT Id, UsageResourceId, Rate
                FROM RateCardEntry
                WHERE UsageResourceId IN :resourceIds
                  AND RateCardType = 'Base'
                  AND Status = 'Active'
                ORDER BY EffectiveFrom DESC
            ]) {
                if (!rateByResource.containsKey(rce.UsageResourceId)) {
                    rateByResource.put(rce.UsageResourceId, rce.Rate);
                }
            }
            for (UsageResource ur : [
                SELECT Id, Name FROM UsageResource WHERE Id IN :resourceIds
            ]) {
                resourceNameById.put(ur.Id, ur.Name);
            }
        }

        // Step 5: Assemble wrappers
        List<AssetWrapper> results = new List<AssetWrapper>();
        for (Asset a : assets) {
            AssetWrapper w = new AssetWrapper(a);

            // Subscription info
            if (bsgInfoByAsset.containsKey(a.Id)) {
                BsgInfo info = bsgInfoByAsset.get(a.Id);
                w.unitPrice = info.schedule.UnitPrice;
                w.billingQuantity = info.schedule.Quantity;
                w.nextBillingDate = info.schedule.NextBillingDate;
                w.billingTermUnit = info.billingTermUnit;
            }

            // Current period usage rates (distinct resources only)
            Set<Id> seenResources = new Set<Id>();
            if (currentItemsByAsset.containsKey(a.Id)) {
                for (UsageBillingPeriodItem item : currentItemsByAsset.get(a.Id)) {
                    if (!seenResources.contains(item.UsageResourceId)) {
                        seenResources.add(item.UsageResourceId);
                        UsageResourceWrapper urw = new UsageResourceWrapper();
                        urw.usageResourceId = item.UsageResourceId;
                        urw.resourceName = resourceNameById.get(item.UsageResourceId);
                        urw.overageRate = rateByResource.get(item.UsageResourceId);
                        w.usageResources.add(urw);
                    }
                }
            }

            // Overage history
            if (overageItemsByAsset.containsKey(a.Id)) {
                for (UsageBillingPeriodItem item : overageItemsByAsset.get(a.Id)) {
                    OverageHistoryWrapper ohw = new OverageHistoryWrapper();
                    ohw.usageResourceId = item.UsageResourceId;
                    ohw.resourceName = resourceNameById.get(item.UsageResourceId);
                    ohw.overageRate = rateByResource.get(item.UsageResourceId);
                    ohw.totalUsedQuantity = item.TotalUsedQuantity;
                    ohw.overageQuantity = item.OverageQuantity;
                    ohw.overageAmount = item.OverageAmount;
                    ohw.periodStart = item.StartDateTime;
                    ohw.periodEnd = item.EndDateTime;
                    ohw.status = item.Status;
                    w.overageHistory.add(ohw);
                }
            }

            results.add(w);
        }
        return results;
    }

    public class BsgInfo {
        public String billingTermUnit;
        public BillingSchedule schedule;
    }

    public class AssetWrapper {
        @AuraEnabled public Id assetId;
        @AuraEnabled public String assetName;
        @AuraEnabled public Id product2Id;
        @AuraEnabled public String productName;
        @AuraEnabled public Decimal currentQuantity;
        @AuraEnabled public Decimal currentMrr;
        @AuraEnabled public Datetime lifecycleStartDate;
        @AuraEnabled public Datetime lifecycleEndDate;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Decimal billingQuantity;
        @AuraEnabled public Date nextBillingDate;
        @AuraEnabled public String billingTermUnit;
        @AuraEnabled public List<UsageResourceWrapper> usageResources;
        @AuraEnabled public List<OverageHistoryWrapper> overageHistory;

        public AssetWrapper(Asset a) {
            this.assetId = a.Id;
            this.assetName = a.Name;
            this.product2Id = a.Product2Id;
            this.productName = a.Product2.Name;
            this.currentQuantity = a.CurrentQuantity;
            this.currentMrr = a.CurrentMrr;
            this.lifecycleStartDate = a.LifecycleStartDate;
            this.lifecycleEndDate = a.LifecycleEndDate;
            this.usageResources = new List<UsageResourceWrapper>();
            this.overageHistory = new List<OverageHistoryWrapper>();
        }
    }

    public class UsageResourceWrapper {
        @AuraEnabled public Id usageResourceId;
        @AuraEnabled public String resourceName;
        @AuraEnabled public Decimal overageRate;
    }

    public class OverageHistoryWrapper {
        @AuraEnabled public Id usageResourceId;
        @AuraEnabled public String resourceName;
        @AuraEnabled public Decimal overageRate;
        @AuraEnabled public Decimal totalUsedQuantity;
        @AuraEnabled public Decimal overageQuantity;
        @AuraEnabled public Decimal overageAmount;
        @AuraEnabled public Datetime periodStart;
        @AuraEnabled public Datetime periodEnd;
        @AuraEnabled public String status;
    }
}
