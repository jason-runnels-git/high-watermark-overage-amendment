String output = 'QuoteLineItem fields:\n';
for (Schema.SObjectField f : Schema.getGlobalDescribe().get('QuoteLineItem').getDescribe().fields.getMap().values()) {
    output += f.getDescribe().getName() + '\n';
}
System.debug(output);
