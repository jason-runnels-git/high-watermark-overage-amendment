List<String> objects = new List<String>{ 'UsageRateCard', 'UsageBasePricingRate', 'ProductConsumptionSchedule', 'ConsumptionRate', 'ConsumptionSchedule' };
String output = '';
for (String obj : objects) {
    try {
        Map<String, Schema.SObjectField> fields = Schema.getGlobalDescribe().get(obj).getDescribe().fields.getMap();
        output += obj + ' EXISTS, fields: ';
        for (String f : fields.keySet()) { output += f + ', '; }
        output += '\n\n';
    } catch (Exception e) {
        output += obj + ' NOT FOUND\n';
    }
}
System.debug(output);
