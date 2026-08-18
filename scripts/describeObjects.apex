String output = 'UsageEntitlementBucket fields:\n';
for (Schema.SObjectField f : Schema.getGlobalDescribe().get('UsageEntitlementBucket').getDescribe().fields.getMap().values()) {
    output += f.getDescribe().getName() + '\n';
}
output += '\nUsageBillingPeriodItem fields:\n';
for (Schema.SObjectField f : Schema.getGlobalDescribe().get('UsageBillingPeriodItem').getDescribe().fields.getMap().values()) {
    output += f.getDescribe().getName() + '\n';
}
System.debug(output);
