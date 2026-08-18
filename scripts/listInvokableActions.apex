List<ConnectApi.InvocableAction> actions = ConnectApi.InvocableAction.getStandardInvocableActions();
String output = '';
for (ConnectApi.InvocableAction a : actions) {
    if (a.name.containsIgnoreCase('amend') || a.name.containsIgnoreCase('quote')
        || a.name.containsIgnoreCase('order') || a.name.containsIgnoreCase('asset')
        || a.name.containsIgnoreCase('transaction') || a.name.containsIgnoreCase('revenue')) {
        output += a.name + ' | ' + a.label + '\n';
    }
}
System.debug(output);
