String output = 'ContextNode fields:\n';
for (Schema.SObjectField f : Schema.getGlobalDescribe().get('ContextNode').getDescribe().fields.getMap().values()) {
    output += f.getDescribe().getName() + '\n';
}
System.debug(output);
