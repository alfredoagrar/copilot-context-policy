@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Set-CopilotIgnore.ps1 is an interactive rollout tool: its summary table targets the console.
        'PSAvoidUsingWriteHost'
    )
}
