String output = 'UsageResource fields:\n';
for (Schema.SObjectField f : Schema.getGlobalDescribe().get('UsageResource').getDescribe().fields.getMap().values()) {
    output += f.getDescribe().getName() + '\n';
}
System.debug(output);
