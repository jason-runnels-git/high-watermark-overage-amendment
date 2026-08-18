// Look for any invokable Apex methods related to pricing in the org
List<ApexClass> classes = [
    SELECT Name, Body
    FROM ApexClass
    WHERE (Name LIKE '%Price%' OR Name LIKE '%Pricing%' OR Name LIKE '%Reprice%')
    AND NamespacePrefix = null
    ORDER BY Name
    LIMIT 20
];
String output = 'Custom pricing classes:\n';
for (ApexClass c : classes) {
    output += c.Name + '\n';
}

// Also check standard invokable actions via Action metadata
List<FlowDefinitionView> flows2 = [
    SELECT ApiName, Label, ProcessType
    FROM FlowDefinitionView
    WHERE (ApiName LIKE '%calcul%' OR ApiName LIKE '%Calcul%' OR ApiName LIKE '%quote%' OR ApiName LIKE '%Quote%')
    AND IsActive = true
    AND ProcessType = 'InvocableProcess'
    ORDER BY ApiName
    LIMIT 20
];
output += '\nInvocable processes (quote/calculate):\n';
for (FlowDefinitionView f : flows2) {
    output += f.ApiName + ' | ' + f.Label + '\n';
}
System.debug(output);
