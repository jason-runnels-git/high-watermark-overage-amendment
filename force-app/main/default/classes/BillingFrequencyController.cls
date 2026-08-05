public without sharing class BillingFrequencyController {

    private static final String API_VERSION = 'v66.0';

    // PSM frequency rank — higher = broader billing interval
    private static final Map<String, Integer> FREQ_RANK = new Map<String, Integer>{
        'Months'      => 1,
        'Quarterly'   => 2,
        'Semi-Annual' => 3,
        'Annual'      => 4
    };

    // BSG.BillingTermUnit → PSM.PricingTermUnit
    private static final Map<String, String> BSG_TO_PSM_UNIT = new Map<String, String>{
        'Month'        => 'Months',
        'Quarter'      => 'Quarterly',
        'Semi_Annual'  => 'Semi-Annual',
        'Year'         => 'Annual'
    };

    // PSM.PricingTermUnit → QSI.BillingFrequency (required on PST POST QSIs)
    private static final Map<String, String> PRICING_UNIT_TO_BILLING_FREQ = new Map<String, String>{
        'Months'      => 'Monthly',
        'Quarterly'   => 'Quarterly',
        'Semi-Annual' => 'SemiAnnual',
        'Annual'      => 'Annual'
    };

    // ─── Data types ───────────────────────────────────────────────────────────

    public class ContractWrapper {
        @AuraEnabled public Id contractId;
        @AuraEnabled public String contractNumber;
        @AuraEnabled public String startDate;
        @AuraEnabled public String endDate;
        @AuraEnabled public String status;
        @AuraEnabled public List<AssetWrapper> assets;
    }

    public class AssetWrapper {
        @AuraEnabled public Id assetId;
        @AuraEnabled public String productName;
        @AuraEnabled public Id product2Id;
        @AuraEnabled public Decimal currentQuantity;
        @AuraEnabled public String lifecycleStartDate;
        @AuraEnabled public String lifecycleEndDate;
        @AuraEnabled public String renewalTermUnit;      // current billing frequency
        @AuraEnabled public String renewalTerm;
        @AuraEnabled public String pricingSource;
        @AuraEnabled public Boolean needsAssetReview;    // true when renewal/pricing fields are null
        @AuraEnabled public String currentPsmId;
        @AuraEnabled public String currentPsmName;
        @AuraEnabled public String sellingModelType;
        @AuraEnabled public List<PsmOption> upgradeOptions;
        @AuraEnabled public Boolean hasUpgradeOptions;
    }

    public class PsmOption {
        @AuraEnabled public Id pricebookEntryId;
        @AuraEnabled public Id psmId;
        @AuraEnabled public String psmName;
        @AuraEnabled public String pricingTermUnit;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public String label;
    }

    public class ExistingContractOption {
        @AuraEnabled public Id contractId;
        @AuraEnabled public String contractNumber;
        @AuraEnabled public String startDate;
        @AuraEnabled public String label;
    }

    public class RenewalRequest {
        @AuraEnabled public Id contractId;          // source contract being renewed
        @AuraEnabled public Id renewalContractId;   // null = auto-create; set = use existing
        @AuraEnabled public List<LineChange> lines;
        @AuraEnabled public String renewalStartDate;
        @AuraEnabled public String renewalEndDate;
    }

    public class LineChange {
        @AuraEnabled public Id assetId;
        @AuraEnabled public Id product2Id;
        @AuraEnabled public Id targetPricebookEntryId;
        @AuraEnabled public Id targetPsmId;
        @AuraEnabled public String targetPricingTermUnit;
        @AuraEnabled public String targetPsmName;
        @AuraEnabled public String currentRenewalTermUnit;  // resolved from BSG; used to patch null assets
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public String productName;
        @AuraEnabled public Boolean frequencyChanged;
        @AuraEnabled public Boolean needsAssetReview;
    }

    public class RenewalResult {
        @AuraEnabled public Boolean ok;
        @AuraEnabled public String quoteId;
        @AuraEnabled public String quoteName;
        @AuraEnabled public String contractId;
        @AuraEnabled public String orderId;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public String message;
    }

    // ─── Step 1: Load contracts + assets for account ──────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<ContractWrapper> getContractsWithAssets(Id accountId) {
        // Load all active PBEs for Standard Pricebook upfront to avoid nested queries
        Id stdPbId = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;

        Map<Id, List<PricebookEntry>> pbesByProduct = new Map<Id, List<PricebookEntry>>();
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id, UnitPrice, ProductSellingModelId,
                   ProductSellingModel.Name, ProductSellingModel.PricingTermUnit,
                   ProductSellingModel.SellingModelType
            FROM PricebookEntry
            WHERE Pricebook2Id = :stdPbId AND IsActive = true
              AND ProductSellingModel.SellingModelType IN ('TermDefined', 'Evergreen')
            ORDER BY Product2Id, ProductSellingModel.PricingTermUnit
        ]) {
            if (!pbesByProduct.containsKey(pbe.Product2Id)) {
                pbesByProduct.put(pbe.Product2Id, new List<PricebookEntry>());
            }
            pbesByProduct.get(pbe.Product2Id).add(pbe);
        }

        // Load ACR records to get contract → asset mapping
        List<AssetContractRelationship> acrs = [
            SELECT AssetId, ContractId,
                   Asset.Name, Asset.Product2Id, Asset.Product2.Name,
                   Asset.CurrentQuantity, Asset.LifecycleStartDate, Asset.LifecycleEndDate,
                   Asset.RenewalTerm, Asset.RenewalTermUnit, Asset.PricingSource,
                   Contract.ContractNumber, Contract.StartDate, Contract.EndDate, Contract.Status
            FROM AssetContractRelationship
            WHERE Asset.AccountId = :accountId
              AND Contract.Status = 'Activated'
            ORDER BY Contract.ContractNumber, Asset.Name
        ];

        // Load BSG billing term units for all assets (fallback when RenewalTermUnit is null)
        Set<Id> assetIds = new Set<Id>();
        for (AssetContractRelationship acr : acrs) assetIds.add(acr.AssetId);
        Map<Id, String> bsgTermByAsset = new Map<Id, String>();
        for (BillingScheduleGroup bsg : [
            SELECT ReferenceEntityId, BillingTermUnit
            FROM BillingScheduleGroup
            WHERE ReferenceEntityId IN :assetIds
        ]) {
            if (!bsgTermByAsset.containsKey(bsg.ReferenceEntityId)) {
                bsgTermByAsset.put(bsg.ReferenceEntityId, bsg.BillingTermUnit);
            }
        }

        Map<Id, ContractWrapper> contractMap = new Map<Id, ContractWrapper>();
        for (AssetContractRelationship acr : acrs) {
            if (!contractMap.containsKey(acr.ContractId)) {
                ContractWrapper cw = new ContractWrapper();
                cw.contractId = acr.ContractId;
                cw.contractNumber = acr.Contract.ContractNumber;
                cw.startDate = acr.Contract.StartDate != null ? String.valueOf(acr.Contract.StartDate) : null;
                cw.endDate = acr.Contract.EndDate != null ? String.valueOf(acr.Contract.EndDate) : null;
                cw.status = acr.Contract.Status;
                cw.assets = new List<AssetWrapper>();
                contractMap.put(acr.ContractId, cw);
            }

            AssetWrapper aw = buildAssetWrapper(acr, pbesByProduct, bsgTermByAsset);
            contractMap.get(acr.ContractId).assets.add(aw);
        }

        return contractMap.values();
    }

    private static AssetWrapper buildAssetWrapper(
        AssetContractRelationship acr,
        Map<Id, List<PricebookEntry>> pbesByProduct,
        Map<Id, String> bsgTermByAsset
    ) {
        AssetWrapper aw = new AssetWrapper();
        aw.assetId = acr.AssetId;
        aw.productName = acr.Asset.Product2.Name;
        aw.product2Id = acr.Asset.Product2Id;
        aw.currentQuantity = acr.Asset.CurrentQuantity;
        aw.lifecycleStartDate = acr.Asset.LifecycleStartDate != null
            ? String.valueOf(acr.Asset.LifecycleStartDate).substring(0, 10) : null;
        aw.lifecycleEndDate = acr.Asset.LifecycleEndDate != null
            ? String.valueOf(acr.Asset.LifecycleEndDate).substring(0, 10) : null;
        aw.renewalTerm = acr.Asset.RenewalTerm != null ? String.valueOf(acr.Asset.RenewalTerm) : null;
        aw.pricingSource = acr.Asset.PricingSource;

        // Resolve current frequency: prefer RenewalTermUnit, fall back to BSG mapping
        String effectiveFreqUnit = acr.Asset.RenewalTermUnit;
        if (String.isBlank(effectiveFreqUnit)) {
            String bsgUnit = bsgTermByAsset.get(acr.AssetId);
            if (!String.isBlank(bsgUnit) && BSG_TO_PSM_UNIT.containsKey(bsgUnit)) {
                effectiveFreqUnit = BSG_TO_PSM_UNIT.get(bsgUnit);
            }
        }
        aw.renewalTermUnit = effectiveFreqUnit;

        // Flag assets that still have missing renewal/pricing fields
        aw.needsAssetReview = (acr.Asset.RenewalTerm == null
            || acr.Asset.RenewalTermUnit == null
            || acr.Asset.PricingSource == null);

        // Find current PSM by matching effective frequency → PricingTermUnit on PBEs for this product
        List<PricebookEntry> productPbes = pbesByProduct.get(acr.Asset.Product2Id);
        aw.upgradeOptions = new List<PsmOption>();
        aw.hasUpgradeOptions = false;

        if (productPbes == null || productPbes.isEmpty()) return aw;

        // Find the current PBE — prefer TermDefined over Evergreen when multiple match same unit
        PricebookEntry currentPbe = null;
        for (PricebookEntry pbe : productPbes) {
            if (pbe.ProductSellingModel.PricingTermUnit != effectiveFreqUnit) continue;
            if (currentPbe == null) {
                currentPbe = pbe;
            } else if (pbe.ProductSellingModel.SellingModelType == 'TermDefined'
                    && currentPbe.ProductSellingModel.SellingModelType != 'TermDefined') {
                currentPbe = pbe;
            }
        }

        if (currentPbe == null) return aw;

        aw.currentPsmId = currentPbe.ProductSellingModelId;
        aw.currentPsmName = currentPbe.ProductSellingModel.Name;
        aw.sellingModelType = currentPbe.ProductSellingModel.SellingModelType;

        Integer currentRank = FREQ_RANK.containsKey(effectiveFreqUnit)
            ? FREQ_RANK.get(effectiveFreqUnit) : 0;

        // Build upgrade options: same SellingModelType, higher frequency rank
        for (PricebookEntry pbe : productPbes) {
            if (pbe.ProductSellingModel.SellingModelType != aw.sellingModelType) continue;
            Integer optRank = FREQ_RANK.containsKey(pbe.ProductSellingModel.PricingTermUnit)
                ? FREQ_RANK.get(pbe.ProductSellingModel.PricingTermUnit) : 0;
            if (optRank <= currentRank) continue;

            PsmOption opt = new PsmOption();
            opt.pricebookEntryId = pbe.Id;
            opt.psmId = pbe.ProductSellingModelId;
            opt.psmName = pbe.ProductSellingModel.Name;
            opt.pricingTermUnit = pbe.ProductSellingModel.PricingTermUnit;
            opt.unitPrice = pbe.UnitPrice;
            opt.label = pbe.ProductSellingModel.Name + ' — $' + pbe.UnitPrice.format();
            aw.upgradeOptions.add(opt);
        }

        aw.hasUpgradeOptions = !aw.upgradeOptions.isEmpty();
        return aw;
    }

    // ─── Step 1b: Load existing renewal contract candidates for a source contract ──

    @AuraEnabled(cacheable=true)
    public static List<ExistingContractOption> getExistingRenewalContracts(Id sourceContractId, Id accountId) {
        List<ExistingContractOption> options = new List<ExistingContractOption>();

        // First priority: contracts explicitly linked as renewals of this contract
        for (Contract c : [
            SELECT Id, ContractNumber, StartDate, EndDate, Status
            FROM Contract
            WHERE RenewalOf__c = :sourceContractId
            ORDER BY StartDate DESC
        ]) {
            ExistingContractOption opt = new ExistingContractOption();
            opt.contractId = c.Id;
            opt.contractNumber = c.ContractNumber;
            opt.startDate = c.StartDate != null ? String.valueOf(c.StartDate) : null;
            opt.label = 'Contract ' + c.ContractNumber + ' (' + c.Status + ')'
                + (c.StartDate != null ? ' — starts ' + String.valueOf(c.StartDate) : '');
            options.add(opt);
        }

        // Second: any other active contracts on this account not already in the list
        Set<Id> seen = new Set<Id>{ sourceContractId };
        for (ExistingContractOption o : options) seen.add(o.contractId);

        for (Contract c : [
            SELECT Id, ContractNumber, StartDate, EndDate, Status
            FROM Contract
            WHERE AccountId = :accountId
              AND Id NOT IN :seen
              AND Status = 'Activated'
            ORDER BY StartDate DESC
        ]) {
            ExistingContractOption opt = new ExistingContractOption();
            opt.contractId = c.Id;
            opt.contractNumber = c.ContractNumber;
            opt.startDate = c.StartDate != null ? String.valueOf(c.StartDate) : null;
            opt.label = 'Contract ' + c.ContractNumber + ' (' + c.Status + ')'
                + (c.StartDate != null ? ' — starts ' + String.valueOf(c.StartDate) : '');
            options.add(opt);
        }

        return options;
    }

    // ─── Step 2a: DML only — create renewal contract + obligations ───────────
    // Must be separate from the callout (Step 2b) — Salesforce forbids DML + callout
    // in the same transaction.

    @AuraEnabled
    public static String createRenewalContract(String requestJson) {
        RenewalRequest req = (RenewalRequest) JSON.deserialize(requestJson, RenewalRequest.class);
        RenewalResult result = new RenewalResult();

        try {
            Id renewalContractId;

            if (req.renewalContractId != null) {
                // User selected an existing contract — verify it belongs to the same account
                Contract existing = [
                    SELECT Id, AccountId FROM Contract WHERE Id = :req.renewalContractId LIMIT 1
                ];
                Contract source = [SELECT AccountId FROM Contract WHERE Id = :req.contractId LIMIT 1];
                if (existing.AccountId != source.AccountId) {
                    result.ok = false;
                    result.message = 'Selected renewal contract does not belong to the same account.';
                    return JSON.serialize(result);
                }
                renewalContractId = existing.Id;
            } else {
                // Auto-create — but first check if one already exists (idempotent on retry)
                List<Contract> existing = [
                    SELECT Id FROM Contract
                    WHERE RenewalOf__c = :req.contractId
                      AND StartDate = :Date.valueOf(req.renewalStartDate)
                    LIMIT 1
                ];
                if (!existing.isEmpty()) {
                    renewalContractId = existing[0].Id;
                } else {
                    Contract originalContract = [
                        SELECT Id, AccountId, ContractTerm, CurrencyIsoCode
                        FROM Contract WHERE Id = :req.contractId LIMIT 1
                    ];
                    Contract renewalContract = new Contract(
                        AccountId = originalContract.AccountId,
                        StartDate = Date.valueOf(req.renewalStartDate),
                        ContractTerm = originalContract.ContractTerm,
                        CurrencyIsoCode = originalContract.CurrencyIsoCode,
                        RenewalOf__c = req.contractId
                    );
                    insert renewalContract;
                    renewalContract.Status = 'Activated';
                    update renewalContract;
                    renewalContractId = renewalContract.Id;

                    // Create AppUsageAssignment so the contract is recognized as an RLM contract.
                    // Without this, Order activation on assets linked to this contract will fail.
                    insert new AppUsageAssignment(
                        AppUsageType = 'RevenueLifecycleManagement',
                        RecordId = renewalContractId
                    );
                }
            }

            result.contractId = renewalContractId;
            // Asset renewal fields (RenewalTerm/RenewalTermUnit/PricingSource) are NOT patched here.
            // /amend does not require them — only /renew did.

            // Load obligation names already on this contract so we don't duplicate on retry
            Set<String> existingObligationNames = new Set<String>();
            for (Obligation o : [
                SELECT Name FROM Obligation WHERE ReferenceObjectId = :renewalContractId
            ]) {
                existingObligationNames.add(o.Name);
            }

            List<Obligation> obligations = new List<Obligation>();
            Id assigneeId = UserInfo.getUserId();
            for (LineChange lc : req.lines) {
                if (lc.frequencyChanged != true) continue;
                String oblName = lc.targetPricingTermUnit + ' Billing for ' + lc.productName;
                if (existingObligationNames.contains(oblName)) continue;
                obligations.add(new Obligation(
                    Name = oblName,
                    Description = lc.targetPricingTermUnit + ' Billing Supersedes Prior Billing Frequency',
                    ReferenceObjectId = renewalContractId,
                    AssigneeUserId = assigneeId,
                    Party = 'FIRST_PARTY',
                    State = 'Active',
                    Status = 'Compliant',
                    Type = 'Financial',
                    StartDate = Date.valueOf(req.renewalStartDate)
                ));
            }
            if (!obligations.isEmpty()) insert obligations;

            result.ok = true;
            return JSON.serialize(result);

        } catch (Exception ex) {
            result.ok = false;
            result.message = ex.getMessage() + ' | ' + ex.getStackTraceString();
            return JSON.serialize(result);
        }
    }

    // ─── Step 2b: POST /renew for UNCHANGED assets only ──────────────────────────
    // Frequency-changed assets are handled separately via buildFreqChangeQuote (Step 3b).
    // Returns null quoteId (ok=true, quoteId=null) if there are no unchanged assets.

    @AuraEnabled
    public static String callRenewEndpoint(String sessionId, String requestJson) {
        RenewalRequest req = (RenewalRequest) JSON.deserialize(requestJson, RenewalRequest.class);
        RenewalResult result = new RenewalResult();
        try {
            List<Id> unchangedAssetIds = new List<Id>();
            for (LineChange lc : req.lines) {
                if (lc.frequencyChanged != true) unchangedAssetIds.add(lc.assetId);
            }
            if (unchangedAssetIds.isEmpty()) {
                result.ok = true;
                result.quoteId = null;
                result.message = 'no_unchanged_assets';
                return JSON.serialize(result);
            }

            String renewResult = callRenewApi(sessionId, unchangedAssetIds, req.renewalStartDate, req.contractId);
            Map<String, Object> renewParsed = (Map<String, Object>) JSON.deserializeUntyped(renewResult);
            if (!(Boolean) renewParsed.get('ok')) {
                result.ok = false;
                result.message = 'Renew API failed: ' + renewParsed.get('body');
                return JSON.serialize(result);
            }
            Map<String, Object> renewBody = (Map<String, Object>)
                JSON.deserializeUntyped((String) renewParsed.get('body'));
            result.ok = true;
            result.quoteId = (String) renewBody.get('renewalRecordId');
            result.message = result.quoteId;
            return JSON.serialize(result);
        } catch (Exception ex) {
            result.ok = false;
            result.message = ex.getMessage() + ' | ' + ex.getStackTraceString();
            return JSON.serialize(result);
        }
    }

    // ─── Step 3a: Resolve renewal contract dates (no callout, no DML) ───────────

    @AuraEnabled
    public static String stampQuoteContract(String sessionId, String quoteId, String contractId, String requestJson) {
        RenewalRequest req = (RenewalRequest) JSON.deserialize(requestJson, RenewalRequest.class);
        try {
            Contract renewalContract = [
                SELECT StartDate, EndDate, ContractTerm FROM Contract WHERE Id = :contractId LIMIT 1
            ];
            String contractStartDate = renewalContract.StartDate != null
                ? String.valueOf(renewalContract.StartDate) : req.renewalStartDate;

            String contractEndDate;
            if (renewalContract.EndDate != null) {
                contractEndDate = String.valueOf(renewalContract.EndDate);
            } else if (renewalContract.ContractTerm != null && renewalContract.StartDate != null) {
                Date calcEnd = renewalContract.StartDate.addMonths((Integer) renewalContract.ContractTerm).addDays(-1);
                contractEndDate = String.valueOf(calcEnd);
            } else {
                contractEndDate = req.renewalEndDate;
            }

            return JSON.serialize(new Map<String, Object>{
                'ok'                => true,
                'contractStartDate' => contractStartDate,
                'contractEndDate'   => contractEndDate
            });
        } catch (Exception ex) {
            return JSON.serialize(new Map<String, Object>{ 'ok' => false, 'message' => ex.getMessage() });
        }
    }

    // ─── Step 3b: PST — build net-new quote for frequency-changed assets ──────────
    // Single PST POST graph creates the entire quote from scratch:
    //   Quote header (Name, ContractId, StartDate, EndDate, Pricebook2Id, QuoteAccountId)
    //   One QSI per frequency-changed asset using target PBE + Asset.CurrentQuantity + contract dates
    // No QuoteAction needed — this is a standard new subscription quote.
    // Both this quote and the renewal quote point to the same renewal contract.

    // ─── Step 3b: Single PST callout — create Quote + QSIs + pricing in one graph ─
    // Key fix: forward reference uses lowercase @{refQuote.id} — NOT @{refQuote.Id}
    // Uppercase .Id caused PST to append an extra .id producing @{refQuote.Id.id}.
    // Single graph: Quote POST → QSI POSTs referencing @{refQuote.id} → pricingPref:System
    // This is a pure callout method — no DML, no separate steps needed.

    @AuraEnabled
    public static String buildFreqChangeQuote(String sessionId, String contractId,
                                              String contractStartDate, String contractEndDate,
                                              String requestJson) {
        RenewalRequest req = (RenewalRequest) JSON.deserialize(requestJson, RenewalRequest.class);
        try {
            List<LineChange> changedLines = new List<LineChange>();
            for (LineChange lc : req.lines) {
                if (lc.frequencyChanged == true) changedLines.add(lc);
            }
            if (changedLines.isEmpty()) {
                return JSON.serialize(new Map<String, Object>{
                    'ok' => true, 'quoteId' => null, 'message' => 'no_changed_assets'
                });
            }

            Contract sourceContract = [SELECT AccountId FROM Contract WHERE Id = :req.contractId LIMIT 1];
            Id stdPbId = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;

            List<Object> records = new List<Object>();

            // Quote POST — billing fields populated from Account
            Account acct = [
                SELECT BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry
                FROM Account WHERE Id = :sourceContract.AccountId LIMIT 1
            ];
            List<Contact> contacts = [
                SELECT Id, Email FROM Contact
                WHERE AccountId = :sourceContract.AccountId LIMIT 1
            ];

            Map<String, Object> quoteRecord = new Map<String, Object>{
                'attributes'        => new Map<String, Object>{ 'type' => 'Quote', 'method' => 'POST' },
                'Name'              => 'Billing Frequency Renewal - ' + contractStartDate,
                'QuoteAccountId'    => (String) sourceContract.AccountId,
                'Pricebook2Id'      => (String) stdPbId,
                'StartDate'         => contractStartDate,
                'TransactionType'   => 'AdvancedConfigurator',
                'BillingStreet'     => acct.BillingStreet,
                'BillingCity'       => acct.BillingCity,
                'BillingState'      => acct.BillingState,
                'BillingPostalCode' => acct.BillingPostalCode,
                'BillingCountry'    => acct.BillingCountry,
                'ShippingStreet'    => acct.BillingStreet,
                'ShippingCity'      => acct.BillingCity,
                'ShippingState'     => acct.BillingState,
                'ShippingPostalCode'=> acct.BillingPostalCode,
                'ShippingCountry'   => acct.BillingCountry
            };
            if (!String.isBlank(contractEndDate)) quoteRecord.put('EndDate', contractEndDate);
            if (!contacts.isEmpty()) {
                quoteRecord.put('BillToContactId', (String) contacts[0].Id);
                quoteRecord.put('ContactId',       (String) contacts[0].Id);
                if (!String.isBlank(contacts[0].Email)) quoteRecord.put('Email', contacts[0].Email);
            }
            records.add(new Map<String, Object>{ 'referenceId' => 'refQuote', 'record' => quoteRecord });

            // QSI POSTs — QuoteId uses lowercase @{refQuote.id} (uppercase causes double .id error)
            Integer idx = 0;
            for (LineChange lc : changedLines) {
                String billingFreq = PRICING_UNIT_TO_BILLING_FREQ.containsKey(lc.targetPricingTermUnit)
                    ? PRICING_UNIT_TO_BILLING_FREQ.get(lc.targetPricingTermUnit) : 'Annual';
                Map<String, Object> qsiRecord = new Map<String, Object>{
                    'attributes'       => new Map<String, Object>{ 'type' => 'QuoteLineItem', 'method' => 'POST' },
                    'QuoteId'          => '@{refQuote.id}',
                    'Product2Id'       => (String) lc.product2Id,
                    'PricebookEntryId' => (String) lc.targetPricebookEntryId,
                    'Quantity'         => lc.quantity,
                    'StartDate'        => contractStartDate,
                    'PeriodBoundary'   => 'Anniversary',
                    'SubscriptionTerm' => 1,
                    'BillingFrequency' => billingFreq
                };
                if (!String.isBlank(contractEndDate)) qsiRecord.put('EndDate', contractEndDate);
                records.add(new Map<String, Object>{ 'referenceId' => 'refQsi' + idx++, 'record' => qsiRecord });
            }

            Map<String, Object> payload = new Map<String, Object>{
                'pricingPref'       => 'System',
                'catalogRatesPref'  => 'Skip',
                'configurationPref' => new Map<String, Object>{
                    'configurationMethod' => 'Skip',
                    'configurationOptions' => new Map<String, Object>{
                        'validateProductCatalog'    => true,
                        'validateAmendRenewCancel'  => true,
                        'executeConfigurationRules' => true,
                        'addDefaultConfiguration'   => true
                    }
                },
                'taxPref' => 'Skip',
                'graph'   => new Map<String, Object>{
                    'graphId' => 'freqChangeQuote',
                    'records' => records
                }
            };

            String pstResult = callPlaceSalesTransaction(sessionId, payload);
            Map<String, Object> pstParsed = (Map<String, Object>) JSON.deserializeUntyped(pstResult);
            if (!(Boolean) pstParsed.get('ok')) {
                return JSON.serialize(new Map<String, Object>{
                    'ok' => false, 'message' => 'Freq change quote failed: ' + pstParsed.get('body')
                });
            }

            // salesTransactionId = the new quoteId
            Map<String, Object> pstBody = (Map<String, Object>) JSON.deserializeUntyped((String) pstParsed.get('body'));
            String newQuoteId = (String) pstBody.get('salesTransactionId');

            return JSON.serialize(new Map<String, Object>{
                'ok' => true, 'quoteId' => newQuoteId
            });

        } catch (Exception ex) {
            return JSON.serialize(new Map<String, Object>{
                'ok' => false, 'message' => (ex.getMessage() != null ? ex.getMessage() : 'NPE') + ' | ' + ex.getStackTraceString().left(300)
            });
        }
    }

    // addFreqChangeLines and repriceFreqChangeQuote are no longer needed —
    // buildFreqChangeQuote now handles everything in one PST graph.
    // Keeping as stubs to avoid LWC deploy errors until LWC is updated.
    @AuraEnabled public static String addFreqChangeLines(String freqQuoteId, String contractStartDate, String contractEndDate, String requestJson) {
        return JSON.serialize(new Map<String, Object>{ 'ok' => true });
    }
    @AuraEnabled public static String repriceFreqChangeQuote(String sessionId, String freqQuoteId) {
        return JSON.serialize(new Map<String, Object>{ 'ok' => true });
    }

    // ─── Step 4: Poll quote calculation status ────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static String getQuoteCalculationStatus(String quoteId) {
        List<Quote> quotes = [SELECT CalculationStatus FROM Quote WHERE Id = :quoteId LIMIT 1];
        if (quotes.isEmpty()) return 'NotFound';
        String status = (String) quotes[0].get('CalculationStatus');
        return status != null ? status : 'Completed';
    }

    // ─── Step 5: Create order + activate ─────────────────────────────────────

    @AuraEnabled
    public static String createOrderFromQuote(String quoteId) {
        try {
            Invocable.Action action = Invocable.Action.createStandardAction('createOrdersFromQuote');
            action.setInvocationParameter('quoteId', quoteId);
            List<Invocable.Action.Result> results = action.invoke();

            if (results == null || results.isEmpty()) {
                return JSON.serialize(new Map<String, Object>{
                    'ok' => false, 'message' => 'No result from createOrdersFromQuote'
                });
            }
            Invocable.Action.Result r = results[0];
            if (!r.isSuccess()) {
                List<String> msgs = new List<String>();
                for (Invocable.Action.Error e : r.getErrors()) msgs.add(e.getMessage());
                return JSON.serialize(new Map<String, Object>{
                    'ok' => false, 'message' => String.join(msgs, '; ')
                });
            }
            Map<String, Object> outputs = r.getOutputParameters();
            String orderId = null;
            if (outputs.containsKey('orderIds')) {
                List<Object> orderIds = (List<Object>) outputs.get('orderIds');
                if (!orderIds.isEmpty()) orderId = String.valueOf(orderIds[0]);
            }
            return JSON.serialize(new Map<String, Object>{
                'ok' => true, 'orderId' => orderId
            });
        } catch (Exception ex) {
            return JSON.serialize(new Map<String, Object>{
                'ok' => false, 'message' => ex.getMessage()
            });
        }
    }

    @AuraEnabled
    public static String activateOrder(Id orderId, Id renewalContractId, String effectiveDate) {
        try {
            // Setting ContractId triggers ACR auto-creation for new assets → renewal contract.
            // Setting EffectiveDate to the renewal contract start date ensures asset lifecycle
            // dates align to the renewal period and the correct contract association is made.
            Order toUpdate = new Order(Id = orderId, Status = 'Activated');
            if (renewalContractId != null) toUpdate.ContractId = renewalContractId;
            if (!String.isBlank(effectiveDate)) toUpdate.EffectiveDate = Date.valueOf(effectiveDate);
            update toUpdate;
            Order o = [SELECT OrderNumber FROM Order WHERE Id = :orderId LIMIT 1];
            return JSON.serialize(new Map<String, Object>{
                'ok' => true, 'orderNumber' => o.OrderNumber
            });
        } catch (Exception ex) {
            return JSON.serialize(new Map<String, Object>{
                'ok' => false, 'message' => ex.getMessage()
            });
        }
    }

    // ─── Step 6: Post-activation cleanup — ACR + asset lineage ───────────────────
    // For unchanged (straight-renewal) assets: create a second ACR to the renewal contract
    // so they appear under both the original and renewal contract for demo clarity.
    // ACR StartDate/EndDate match the renewal contract period.
    // For freq-changed assets: stamp CanceledByAsset__c / ReplacesAsset__c lineage fields.

    @AuraEnabled
    public static String stampPostActivation(Id renewalContractId, String requestJson) {
        RenewalRequest req = (RenewalRequest) JSON.deserialize(requestJson, RenewalRequest.class);
        try {
            // Load renewal contract dates for ACR records
            Contract renewalContract = [
                SELECT StartDate, EndDate, ContractTerm FROM Contract WHERE Id = :renewalContractId LIMIT 1
            ];
            Date acrStart = renewalContract.StartDate;
            Date acrEnd = renewalContract.EndDate != null
                ? renewalContract.EndDate
                : (renewalContract.ContractTerm != null && renewalContract.StartDate != null
                    ? renewalContract.StartDate.addMonths((Integer) renewalContract.ContractTerm).addDays(-1)
                    : null);

            // Find unchanged asset IDs (no frequency change)
            List<Id> unchangedAssetIds = new List<Id>();
            for (LineChange lc : req.lines) {
                if (lc.frequencyChanged != true) unchangedAssetIds.add(lc.assetId);
            }

            // Create second ACR for each unchanged asset → renewal contract
            // (first ACR to source contract already exists from original order activation)
            if (!unchangedAssetIds.isEmpty()) {
                // Check which ACRs to renewal contract don't exist yet (idempotent)
                Set<Id> alreadyLinked = new Set<Id>();
                for (AssetContractRelationship existing : [
                    SELECT AssetId FROM AssetContractRelationship
                    WHERE ContractId = :renewalContractId AND AssetId IN :unchangedAssetIds
                ]) {
                    alreadyLinked.add(existing.AssetId);
                }

                List<AssetContractRelationship> newAcrs = new List<AssetContractRelationship>();
                for (Id assetId : unchangedAssetIds) {
                    if (alreadyLinked.contains(assetId)) continue;
                    AssetContractRelationship acr = new AssetContractRelationship(
                        AssetId    = assetId,
                        ContractId = renewalContractId
                    );
                    if (acrStart != null) acr.StartDate = DateTime.newInstance(acrStart, Time.newInstance(0,0,0,0));
                    if (acrEnd   != null) acr.EndDate   = DateTime.newInstance(acrEnd,   Time.newInstance(23,59,59,0));
                    newAcrs.add(acr);
                }
                if (!newAcrs.isEmpty()) insert newAcrs;
            }

            return JSON.serialize(new Map<String, Object>{ 'ok' => true });
        } catch (Exception ex) {
            return JSON.serialize(new Map<String, Object>{ 'ok' => false, 'message' => ex.getMessage() });
        }
    }

    @AuraEnabled
    public static void stampAssetLineage(List<Id> originalAssetIds, List<Id> replacementAssetIds) {
        if (originalAssetIds.size() != replacementAssetIds.size()) return;
        List<Asset> toUpdate = new List<Asset>();
        for (Integer i = 0; i < originalAssetIds.size(); i++) {
            toUpdate.add(new Asset(Id = originalAssetIds[i], CanceledByAsset__c = replacementAssetIds[i]));
            toUpdate.add(new Asset(Id = replacementAssetIds[i], ReplacesAsset__c = originalAssetIds[i]));
        }
        update toUpdate;
    }

    // ─── Private HTTP helpers ─────────────────────────────────────────────────

    private static String callRenewApi(String sessionId, List<Id> assetIds, String renewalStartDate, Id contractId) {
        Map<String, Object> payload = new Map<String, Object>{
            'assetIds' => assetIds,
            'renewalStartDate' => renewalStartDate + 'T00:00:00',
            'outputRecordType' => 'Quote'
        };
        if (contractId != null) payload.put('contractId', contractId);

        String endpoint = URL.getOrgDomainUrl().toExternalForm()
            + '/services/data/' + API_VERSION
            + '/connect/revenue-management/assets/actions/renew';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setTimeout(120000);
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + sessionId);
        req.setBody(JSON.serialize(payload));

        try {
            HttpResponse res = new Http().send(req);
            Integer sc = res.getStatusCode();
            if (sc >= 200 && sc < 300) {
                return JSON.serialize(new Map<String, Object>{ 'ok' => true, 'body' => res.getBody() });
            }
            return JSON.serialize(new Map<String, Object>{
                'ok' => false, 'statusCode' => sc, 'body' => res.getBody()
            });
        } catch (Exception ex) {
            return JSON.serialize(new Map<String, Object>{
                'ok' => false, 'message' => ex.getMessage()
            });
        }
    }

    private static String callPlaceSalesTransaction(String sessionId, Map<String, Object> payload) {
        String endpoint = URL.getOrgDomainUrl().toExternalForm()
            + '/services/data/' + API_VERSION
            + '/connect/rev/sales-transaction/actions/place';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setTimeout(120000);
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + sessionId);
        req.setBody(JSON.serialize(payload));

        try {
            HttpResponse res = new Http().send(req);
            Integer sc = res.getStatusCode();
            if (sc >= 200 && sc < 300) {
                return JSON.serialize(new Map<String, Object>{ 'ok' => true, 'body' => res.getBody() });
            }
            return JSON.serialize(new Map<String, Object>{
                'ok' => false, 'statusCode' => sc, 'body' => res.getBody()
            });
        } catch (Exception ex) {
            return JSON.serialize(new Map<String, Object>{
                'ok' => false, 'message' => ex.getMessage()
            });
        }
    }
}
