List<String> objects = new List<String>{
    'UsageEntitlement', 'UsageEntitlementPolicy', 'UsageEntitlementPolicyBinding',
    'UsageGrantBinding', 'GrantBinding', 'UsageEntitlementAccount',
    'RateCard', 'RateCardEntry', 'BaseRate', 'PricingTier',
    'UsagePricingRate', 'UsageOverageRate'
};
String output = '';
for (String obj : objects) {
    try {
        Schema.getGlobalDescribe().get(obj).getDescribe().fields.getMap();
        output += obj + ' EXISTS\n';
    } catch (Exception e) {
        output += obj + ' NOT FOUND\n';
    }
}
System.debug(output);
