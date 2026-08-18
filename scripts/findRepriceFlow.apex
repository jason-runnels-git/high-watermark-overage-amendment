List<FlowDefinitionView> flows = [
    SELECT ApiName, Label, ProcessType
    FROM FlowDefinitionView
    WHERE (ApiName LIKE '%price%' OR ApiName LIKE '%reprice%' OR ApiName LIKE '%Price%' OR ApiName LIKE '%Reprice%')
    AND IsActive = true
    ORDER BY ApiName
];
String output = '';
for (FlowDefinitionView f : flows) {
    output += f.ApiName + ' | ' + f.Label + ' | ' + f.ProcessType + '\n';
}
System.debug(output);
