public without sharing class AmendQuoteEndDateController {

    private static final String API_VERSION = 'v66.0';

    public class QuoteContext {
        @AuraEnabled public Id quoteId;
        @AuraEnabled public String quoteName;
        @AuraEnabled public String startDate;
        @AuraEnabled public String endDate;
        @AuraEnabled public String assetEndDate;   // Asset.LifecycleEndDate — delta base for term extension
        @AuraEnabled public String calculationStatus;
        @AuraEnabled public List<LineContext> lines;
    }

    public class LineContext {
        @AuraEnabled public Id lineId;
        @AuraEnabled public String productName;
        @AuraEnabled public String startDate;
        @AuraEnabled public String endDate;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Decimal salesPrice;
    }

    @AuraEnabled(cacheable=false)
    public static QuoteContext getQuoteContext(Id quoteId) {
        Quote q = [
            SELECT Id, Name, StartDate, EndDate, CalculationStatus
            FROM Quote
            WHERE Id = :quoteId
            LIMIT 1
        ];

        List<QuoteLineItem> qlis = [
            SELECT Id, Product2.Name, UnitPrice, TotalPrice, StartDate, EndDate
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            ORDER BY LineNumber
        ];

        // Resolve the source asset's lifecycle end date for delta term computation.
        QuoteAction qa = null;
        List<QuoteAction> qaList = [SELECT SourceAssetId FROM QuoteAction WHERE QuoteId = :quoteId LIMIT 1];
        if (!qaList.isEmpty() && qaList[0].SourceAssetId != null) {
            qa = qaList[0];
        }
        Date assetLifecycleEndDate = null;
        if (qa != null) {
            List<Asset> assets = [SELECT LifecycleEndDate FROM Asset WHERE Id = :qa.SourceAssetId LIMIT 1];
            if (!assets.isEmpty() && assets[0].LifecycleEndDate != null) {
                assetLifecycleEndDate = assets[0].LifecycleEndDate.date();
            }
        }

        QuoteContext ctx = new QuoteContext();
        ctx.quoteId           = q.Id;
        ctx.quoteName         = q.Name;
        ctx.startDate         = q.StartDate != null ? String.valueOf(q.StartDate) : null;
        ctx.assetEndDate      = assetLifecycleEndDate != null ? String.valueOf(assetLifecycleEndDate) : null;
        ctx.calculationStatus = q.CalculationStatus;
        ctx.lines             = new List<LineContext>();

        for (QuoteLineItem qli : qlis) {
            LineContext lc  = new LineContext();
            lc.lineId       = qli.Id;
            lc.productName  = qli.Product2.Name;
            lc.startDate    = qli.StartDate != null ? String.valueOf(qli.StartDate).substring(0,10) : null;
            lc.endDate      = qli.EndDate   != null ? String.valueOf(qli.EndDate).substring(0,10)   : null;
            lc.unitPrice    = qli.UnitPrice;
            lc.salesPrice   = qli.TotalPrice;
            ctx.lines.add(lc);
        }

        // Quote.EndDate is null on fresh amendment quotes — date lives on QSI.
        // Fall back to first QSI EndDate so the modal has a sensible default.
        if (q.EndDate != null) {
            ctx.endDate = String.valueOf(q.EndDate);
        } else if (!ctx.lines.isEmpty() && ctx.lines[0].endDate != null) {
            ctx.endDate = ctx.lines[0].endDate;
        }

        return ctx;
    }

    // Step 1: PST PATCH — write EndDate + SubscriptionTerm on quote and all lines,
    // triggering pricing with pricingPref=Force.
    // Same pattern as patchQuoteAndPrice in AmendmentQuoteController.
    @AuraEnabled
    public static String patchEndDate(String sessionId, Id quoteId, String newEndDate) {
        try {
            Quote q = [SELECT StartDate FROM Quote WHERE Id = :quoteId LIMIT 1];

            // Resolve asset lifecycle end date — this is the delta base for SubscriptionTerm.
            // For a term-extension amendment the engine needs the months from current asset end
            // to the new end, not total months from quote start.
            Date assetLifecycleEnd = null;
            List<QuoteAction> qaList = [SELECT SourceAssetId FROM QuoteAction WHERE QuoteId = :quoteId LIMIT 1];
            if (!qaList.isEmpty() && qaList[0].SourceAssetId != null) {
                List<Asset> assets = [SELECT LifecycleEndDate FROM Asset WHERE Id = :qaList[0].SourceAssetId LIMIT 1];
                if (!assets.isEmpty() && assets[0].LifecycleEndDate != null) {
                    assetLifecycleEnd = assets[0].LifecycleEndDate.date();
                }
            }

            Date termBase = assetLifecycleEnd != null ? assetLifecycleEnd : q.StartDate;
            if (termBase == null) {
                return JSON.serialize(new Map<String, Object>{
                    'ok' => false, 'message' => 'Cannot determine term base — asset has no LifecycleEndDate and quote has no StartDate.'
                });
            }

            Integer newTermMonths = monthsBetweenRoundUp(termBase, Date.valueOf(newEndDate));

            List<QuoteLineItem> lines = [
                SELECT Id FROM QuoteLineItem WHERE QuoteId = :quoteId ORDER BY LineNumber
            ];
            if (lines.isEmpty()) {
                return JSON.serialize(new Map<String, Object>{
                    'ok' => false, 'message' => 'No quote line items found on quote ' + quoteId
                });
            }

            List<Object> records = new List<Object>();

            records.add(new Map<String, Object>{
                'referenceId' => 'refQuote',
                'record' => new Map<String, Object>{
                    'attributes' => new Map<String, Object>{
                        'type' => 'Quote', 'method' => 'PATCH', 'id' => (String) quoteId
                    },
                    'EndDate' => newEndDate
                }
            });

            Integer idx = 0;
            for (QuoteLineItem qli : lines) {
                records.add(new Map<String, Object>{
                    'referenceId' => 'refLine' + idx++,
                    'record' => new Map<String, Object>{
                        'attributes' => new Map<String, Object>{
                            'type' => 'QuoteLineItem', 'method' => 'PATCH', 'id' => (String) qli.Id
                        },
                        'EndDate'          => newEndDate,
                        'SubscriptionTerm' => newTermMonths
                    }
                });
            }

            Map<String, Object> payload = new Map<String, Object>{
                'pricingPref'       => 'Force',
                'catalogRatesPref'  => 'Skip',
                'configurationPref' => new Map<String, Object>{
                    'configurationMethod'  => 'Skip',
                    'configurationOptions' => new Map<String, Object>{
                        'validateProductCatalog'    => true,
                        'validateAmendRenewCancel'  => true,
                        'executeConfigurationRules' => true,
                        'addDefaultConfiguration'   => true
                    }
                },
                'taxPref' => 'Skip',
                'graph'   => new Map<String, Object>{
                    'graphId' => 'patchEndDate',
                    'records' => records
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

            HttpResponse res = new Http().send(req);
            Integer sc = res.getStatusCode();

            if (sc >= 200 && sc < 300) {
                return JSON.serialize(new Map<String, Object>{
                    'ok'            => true,
                    'newEndDate'    => newEndDate,
                    'newTermMonths' => newTermMonths
                });
            }
            return JSON.serialize(new Map<String, Object>{
                'ok' => false, 'statusCode' => sc, 'body' => res.getBody()
            });

        } catch (Exception ex) {
            return JSON.serialize(new Map<String, Object>{
                'ok' => false, 'message' => ex.getMessage() + ' | ' + ex.getStackTraceString().left(300)
            });
        }
    }

    // Step 2: Fix QuoteAction — same workaround as AmendmentQuoteController.fixQuoteAction.
    // PST PATCH leaves QuoteAction.Type = No Change which blocks amendment pricing.
    // Look up the assetId from the existing QuoteAction so the caller doesn't need to supply it.
    @AuraEnabled
    public static String fixQuoteAction(Id quoteId) {
        try {
            List<QuoteAction> existing = [
                SELECT Id, SourceAssetId, Type FROM QuoteAction WHERE QuoteId = :quoteId
            ];

            Id assetId = null;
            for (QuoteAction qa : existing) {
                if (qa.SourceAssetId != null) {
                    assetId = qa.SourceAssetId;
                    break;
                }
            }

            if (!existing.isEmpty()) delete existing;

            if (assetId == null) {
                return JSON.serialize(new Map<String, Object>{
                    'ok' => false, 'message' => 'No SourceAssetId found on existing QuoteAction — cannot re-insert Amend action.'
                });
            }

            insert new QuoteAction(
                QuoteId       = quoteId,
                Type          = 'Amend',
                SourceAssetId = assetId
            );

            return JSON.serialize(new Map<String, Object>{ 'ok' => true });

        } catch (Exception ex) {
            return JSON.serialize(new Map<String, Object>{
                'ok' => false, 'message' => ex.getMessage()
            });
        }
    }

    @AuraEnabled(cacheable=false)
    public static String getCalculationStatus(Id quoteId) {
        List<Quote> quotes = [SELECT CalculationStatus FROM Quote WHERE Id = :quoteId LIMIT 1];
        if (quotes.isEmpty()) return 'NotFound';
        String s = quotes[0].CalculationStatus;
        return s != null ? s : 'Completed';
    }

    private static Integer monthsBetweenRoundUp(Date startDate, Date endDate) {
        Integer total = (endDate.year() - startDate.year()) * 12
                      + (endDate.month() - startDate.month());
        if (endDate.day() < startDate.day()) total += 1;
        return Math.max(1, total);
    }
}
