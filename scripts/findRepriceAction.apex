// Find invokable actions related to pricing/reprice
List<String> keywords = new List<String>{ 'price', 'reprice', 'pricing', 'calculate', 'waterfall' };
String output = '';
for (ConnectApi.InvocableAction action : ConnectApi.InvocableAction.getStandardInvocableActions()) {
    String name = action.name.toLowerCase();
    for (String kw : keywords) {
        if (name.contains(kw)) {
            output += action.name + ' | ' + action.label + '\n';
            break;
        }
    }
}
System.debug(output);
