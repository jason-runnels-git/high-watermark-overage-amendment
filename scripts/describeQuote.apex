String output = 'Quote fields:\n';
for (Schema.SObjectField f : Schema.getGlobalDescribe().get('Quote').getDescribe().fields.getMap().values()) {
    output += f.getDescribe().getName() + '\n';
}
System.debug(output);
