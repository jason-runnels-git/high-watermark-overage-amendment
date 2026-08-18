String output = 'QuoteAction fields:\n';
for (Schema.SObjectField f : Schema.getGlobalDescribe().get('QuoteAction').getDescribe().fields.getMap().values()) {
    output += f.getDescribe().getName() + '\n';
}
System.debug(output);
