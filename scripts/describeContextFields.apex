String output = 'ContextDefinition fields:\n';
for (Schema.SObjectField f : Schema.getGlobalDescribe().get('ContextDefinition').getDescribe().fields.getMap().values()) {
    output += f.getDescribe().getName() + '\n';
}
output += '\nSalesTransactionType fields:\n';
for (Schema.SObjectField f : Schema.getGlobalDescribe().get('SalesTransactionType').getDescribe().fields.getMap().values()) {
    output += f.getDescribe().getName() + '\n';
}
output += '\nTransactionProcessingType fields:\n';
for (Schema.SObjectField f : Schema.getGlobalDescribe().get('TransactionProcessingType').getDescribe().fields.getMap().values()) {
    output += f.getDescribe().getName() + '\n';
}
System.debug(output);
