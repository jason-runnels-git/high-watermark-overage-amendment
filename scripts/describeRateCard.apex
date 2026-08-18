String output = 'RateCard fields:\n';
for (Schema.SObjectField f : Schema.getGlobalDescribe().get('RateCard').getDescribe().fields.getMap().values()) {
    output += f.getDescribe().getName() + '\n';
}
output += '\nRateCardEntry fields:\n';
for (Schema.SObjectField f : Schema.getGlobalDescribe().get('RateCardEntry').getDescribe().fields.getMap().values()) {
    output += f.getDescribe().getName() + '\n';
}
System.debug(output);
