/// AI lives here behind a provider protocol (ADR 0003, 0015). Everything runs on-device.
///
/// - `Providers.swift`: the protocols and shared types.
/// - `VisionProvider`, `NaturalLanguageProvider`: layer 3, no model download, nothing to set up.
/// - `FoundationModelsProvider`: layer 4 and natural-language query translation, through Apple's on-device model.
/// - `AIJobs.swift`: the job handlers and `AIPipeline`, which the app and the CLI use to run it all.
public enum MilesAI {
    public static let name = "MilesAI"
}
