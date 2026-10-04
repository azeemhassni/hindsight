import HindsightAgentKit

/// The whole executable. Everything it does lives in `HindsightAgentKit`, so
/// the app bundle's copy of the agent is the same code rather than a second one.
await AgentRuntime.run()
