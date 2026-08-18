// Find the active Pricing Procedure configured in this org
String output = 'PricingProcedure records:\n';
try {
    List<SObject> procs = Database.query('SELECT Id, Name, IsActive FROM PricingProcedure WHERE IsActive = true ORDER BY Name LIMIT 10');
    for (SObject p : procs) {
        output += p.get('Id') + ' | ' + p.get('Name') + '\n';
    }
} catch (Exception e) {
    output += 'Error: ' + e.getMessage() + '\n';
}

// Also check the Quote's PricingContractId and related pricing fields
output += '\nQuote pricing-related fields check:\n';
List<Quote> quotes = [
    SELECT Id, LastPricedDate, PricingContractId, RatingDate, CalculationStatus
    FROM Quote
    WHERE Id = '0Q0Ka000003ajN5KAI'
];
for (Quote q : quotes) {
    output += 'LastPricedDate: ' + q.LastPricedDate + '\n';
    output += 'PricingContractId: ' + q.PricingContractId + '\n';
    output += 'RatingDate: ' + q.RatingDate + '\n';
    output += 'CalculationStatus: ' + q.CalculationStatus + '\n';
}
System.debug(output);
