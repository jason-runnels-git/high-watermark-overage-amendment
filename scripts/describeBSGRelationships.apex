String output = 'BillingScheduleGroup child relationships:\n';
for (Schema.ChildRelationship cr : Schema.getGlobalDescribe().get('BillingScheduleGroup').getDescribe().getChildRelationships()) {
    output += cr.getRelationshipName() + ' -> ' + cr.getChildSObject() + '\n';
}
System.debug(output);
