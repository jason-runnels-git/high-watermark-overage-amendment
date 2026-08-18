public without sharing class AmendmentQuoteController {

    private static final String API_VERSION = 'v66.0';

    @AuraEnabled
    public static String createAmendmentQuote(String sessionId, String amendPayloadJson) {
        String endpoint = URL.getOrgDomainUrl().toExternalForm()
            + '/services/data/' + API_VERSION
            + '/connect/revenue-management/assets/actions/amend';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setTimeout(120000);
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + sessionId);
        req.setBody(amendPayloadJson);

        try {
            HttpResponse res = new Http().send(req);
            Integer sc = res.getStatusCode();
            String rawBody = res.getBody();
            if (sc >= 200 && sc < 300) {
                return JSON.serialize(new Map<String, Object>{ 'ok' => true, 'body' => rawBody });
            }
            return JSON.serialize(new Map<String, Object>{
                'statusCode' => sc, 'status' => res.getStatus(), 'body' => rawBody
            });
        } catch (Exception ex) {
            return JSON.serialize(new Map<String, Object>{
                'statusCode' => 0, 'status' => 'Exception', 'message' => ex.getMessage()
            });
        }
    }

    // Step 2: Patch quote name + line StartDate via Place Sales Transaction API, triggering pricing
    @AuraEnabled
    public static String patchQuoteAndPrice(String sessionId, Id quoteId, String quoteName, String lineStartDate) {
        // Find the QuoteLineItem created by the amend API
        List<QuoteLineItem> lines = [
            SELECT Id FROM QuoteLineItem WHERE QuoteId = :quoteId LIMIT 1
        ];
        if (lines.isEmpty()) {
            return JSON.serialize(new Map<String, Object>{ 'ok' => false, 'message' => 'No quote line items found on quote ' + quoteId });
        }
        Id lineId = lines[0].Id;

        Map<String, Object> payload = new Map<String, Object>{
            'pricingPref' => 'Force',
            'catalogRatesPref' => 'Skip',
            'configurationPref' => new Map<String, Object>{
                'configurationMethod' => 'Skip',
                'configurationOptions' => new Map<String, Object>{
                    'validateProductCatalog' => true,
                    'validateAmendRenewCancel' => true,
                    'executeConfigurationRules' => true,
                    'addDefaultConfiguration' => true
                }
            },
            'taxPref' => 'Skip',
            'graph' => new Map<String, Object>{
                'graphId' => 'patchQuote',
                'records' => new List<Object>{
                    new Map<String, Object>{
                        'referenceId' => 'refQuote',
                        'record' => new Map<String, Object>{
                            'attributes' => new Map<String, Object>{ 'type' => 'Quote', 'method' => 'PATCH', 'id' => quoteId },
                            'Name' => quoteName
                        }
                    },
                    new Map<String, Object>{
                        'referenceId' => 'refLine',
                        'record' => new Map<String, Object>{
                            'attributes' => new Map<String, Object>{ 'type' => 'QuoteLineItem', 'method' => 'PATCH', 'id' => lineId },
                            'StartDate' => lineStartDate
                        }
                    }
                }
            }
        };

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
            String rawBody = res.getBody();
            if (sc >= 200 && sc < 300) {
                return JSON.serialize(new Map<String, Object>{ 'ok' => true, 'body' => rawBody });
            }
            return JSON.serialize(new Map<String, Object>{ 'ok' => false, 'statusCode' => sc, 'body' => rawBody });
        } catch (Exception ex) {
            return JSON.serialize(new Map<String, Object>{ 'ok' => false, 'message' => ex.getMessage() });
        }
    }

    // Workaround: PST PATCH bypasses ARS, leaving QuoteAction as No Change.
    // Delete the No Change action and re-insert as Amend so pricing fires correctly.
    @AuraEnabled
    public static String fixQuoteAction(String quoteId, String assetId) {
        try {
            List<QuoteAction> toDelete = [
                SELECT Id FROM QuoteAction
                WHERE QuoteId = :quoteId AND Type = 'No Change'
            ];
            if (!toDelete.isEmpty()) {
                delete toDelete;
            }
            insert new QuoteAction(
                QuoteId = quoteId,
                Type = 'Amend',
                SourceAssetId = assetId
            );
            return JSON.serialize(new Map<String, Object>{ 'ok' => true });
        } catch (Exception ex) {
            return JSON.serialize(new Map<String, Object>{ 'ok' => false, 'message' => ex.getMessage() });
        }
    }

    @AuraEnabled(cacheable=false)
    public static String getQuoteCalculationStatus(String quoteId) {
        List<Quote> quotes = [SELECT CalculationStatus FROM Quote WHERE Id = :quoteId LIMIT 1];
        if (quotes.isEmpty()) return 'NotFound';
        String status = (String) quotes[0].get('CalculationStatus');
        return status != null ? status : 'Completed';
    }

    @AuraEnabled
    public static String createOrderFromQuote(String quoteId) {
        try {
            Invocable.Action action = Invocable.Action.createStandardAction('createOrdersFromQuote');
            action.setInvocationParameter('quoteId', quoteId);
            List<Invocable.Action.Result> results = action.invoke();

            if (results == null || results.isEmpty()) {
                return JSON.serialize(new Map<String, Object>{ 'ok' => false, 'message' => 'No result returned from createOrdersFromQuote action' });
            }

            Invocable.Action.Result r = results[0];
            if (!r.isSuccess()) {
                List<String> msgs = new List<String>();
                for (Invocable.Action.Error e : r.getErrors()) msgs.add(e.getMessage());
                return JSON.serialize(new Map<String, Object>{ 'ok' => false, 'message' => String.join(msgs, '; ') });
            }

            Map<String, Object> outputs = r.getOutputParameters();
            String orderId = null;
            if (outputs.containsKey('orderIds')) {
                List<Object> orderIds = (List<Object>) outputs.get('orderIds');
                if (!orderIds.isEmpty()) orderId = String.valueOf(orderIds[0]);
            }
            return JSON.serialize(new Map<String, Object>{ 'ok' => true, 'orderId' => orderId, 'outputs' => JSON.serialize(outputs) });
        } catch (Exception ex) {
            return JSON.serialize(new Map<String, Object>{ 'ok' => false, 'message' => ex.getMessage() });
        }
    }

    @AuraEnabled
    public static String activateOrder(Id orderId) {
        try {
            update new Order(Id = orderId, Status = 'Activated');
            Order o = [SELECT OrderNumber FROM Order WHERE Id = :orderId LIMIT 1];
            return JSON.serialize(new Map<String, Object>{ 'ok' => true, 'orderNumber' => o.OrderNumber });
        } catch (Exception ex) {
            return JSON.serialize(new Map<String, Object>{ 'ok' => false, 'message' => ex.getMessage() });
        }
    }

    @AuraEnabled
    public static void resetHasOverage(Id accountId) {
        update new Account(Id = accountId, Has_Overage__c = false);
    }

    @AuraEnabled(cacheable=true)
    public static AmendmentContext getAmendmentContext(Id assetId) {
        Asset a = [
            SELECT Id, AccountId, Product2Id, LifecycleEndDate, CurrentQuantity
            FROM Asset WHERE Id = :assetId
        ];

        // contractId — will be null; API treats it as optional
        Id contractId = null;

        AmendmentContext ctx = new AmendmentContext();
        ctx.accountId = a.AccountId;
        ctx.assetId = assetId;
        ctx.contractId = contractId;
        ctx.currentQuantity = a.CurrentQuantity;
        ctx.assetLifecycleEndDate = a.LifecycleEndDate != null
            ? String.valueOf(a.LifecycleEndDate).substring(0, 10) : null;
        return ctx;
    }

    public class AmendmentContext {
        @AuraEnabled public Id accountId;
        @AuraEnabled public Id assetId;
        @AuraEnabled public Id contractId;
        @AuraEnabled public Decimal currentQuantity;
        @AuraEnabled public String assetLifecycleEndDate;
    }
}
