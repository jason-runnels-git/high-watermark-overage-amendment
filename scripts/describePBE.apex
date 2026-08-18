String output = 'PricebookEntry fields:\n';
for (Schema.SObjectField f : Schema.getGlobalDescribe().get('PricebookEntry').getDescribe().fields.getMap().values()) {
    output += f.getDescribe().getName() + '\n';
}
System.debug(output);
