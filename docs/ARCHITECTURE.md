# v0.2.3 local recovery and SVG presentation

`selectedRecordID` selects within the current provider/model's recent records. `displayedRecord` uses that explicit selection, including failures, or defaults to the latest successful record. Row selection and the separate file-opening arrow have distinct actions. The large menu image has no file-opening action.

`annotatedSVGPath` references a derived vector file; raw `svgPath` remains unchanged. `presentationVersion = 2` records only that the thumbnail is clean; annotation is independent, with `annotationError` describing its failure. Legacy successful records rebuild their menu PNG locally from the original SVG once. Internal pruning removes both SVG variants, while external saved files stay outside retention. A canceled upgrade stops without calling providers. Explicit failed exports lacking an external SVG copy are held from pruning until recovered. A Settings list exposes these records beyond the four recent results. New exported SVGs carry the footer; exported PNGs and menu images do not.

## Unified app

The original `com.pelicansentinel.app` bundle and `PelicanSentinel` data directory now serve both languages and all five providers. `AppSettings.language` defaults to Chinese when absent; `AppLanguage` supplies runtime display text. `imageSavePath` is a separate optional user export destination, not a migration of the internal store. Switching language does not change provider configuration, schedule, prompt, model request or key scope.

After `GenerationService` persists a successful original result, `AppModel.finalizeImages` retains its clean PNG, calls `ImageExporter` to add a footer to a derived SVG, then saves SVG and an optional clean PNG in a unique folder. If dimensions cannot be safely annotated, the original SVG is exported with a separate labeling warning. Requested/returned-model distinction and local completion time plus UTC offset are explicit. External exports have no 30-day retention. An export failure is recorded separately from model success and never retries a request. No new model call, package dependency or provider abstraction is involved.

`recoverLocalResult` uses persisted source data and the current save destination. It serializes local recovery, rebuilds previews independently of annotation, and never constructs a provider. Generation is blocked during recovery; shutdown cancels owned recovery work. Interval and mode updates now save a settings copy before committing UI state and notification side effects.

## Core architecture

Pelican Sentinel is a native macOS 13+ menu-bar application built as a Swift package. It uses system frameworks only.

## Connections and requests

`ProviderID` and `ProviderDescriptor` form a fixed catalog of five connections. The catalog owns names, default model IDs, authentication guidance and configuration capabilities. `ProviderConfiguration` stores model, reasoning, output limit and, for compatible services, base URL and token-limit field. `AppSettings` keeps one configuration per provider. Its decoder accepts the previous settings format and keeps its schedule intact.

`ModelProvider` exposes `executionProfile(for:)` and `generate(_:)`. Protocol adapters perform one stateless request. Codex retains its fresh-session CLI isolation and strict first-turn event validation. The CLI command explicitly disables shell execution, browser use, computer use and image generation, in addition to hooks, plugins, apps, memories and multi-agent behavior. OpenAI uses Responses; Claude uses Messages; Gemini uses generateContent; compatible services use Chat Completions. The shared HTTP helper contains transport behavior only. There are no retries, provider fallbacks, quota polling, browser-cookie imports or generation tools.

Reasoning `default` means no API override. CLI output limit is recorded as zero (unavailable), rather than claiming enforcement. Providers return the model identifier supplied by the server when available. CLI version is stored in the execution profile, never substituted for the returned model.

## App state and credentials

`AppModel` constructs the selected provider and snapshots settings at generation start. Model/configuration editing and provider selection are locked during generation. A saved provider/configuration change clears the previous pending confirmation and starts a new schedule interval. Edits in Settings stay in a draft until saved; entering a key is a separate action against the saved connection.

Keys stay in macOS Keychain under provider namespaces, preserving the original OpenAI service name. Compatible credentials additionally use the normalized base URL as their scope. Changing the base URL clears the in-memory key and reloads only the new scope. Official API destinations are fixed. Custom URLs accept HTTPS or HTTP on literal loopback/localhost, without embedded credentials, query strings or fragments. The app does not access CodexBar credentials.

Bundle ID: `com.pelicansentinel.app`. Data folder: `Application Support/PelicanSentinel`. The same app, data and keys serve both interface languages.

## Storage, recovery and presentation

`GenerationService` validates the selected configuration and writes a `generating` record before sending any request. It copies the actual requested model, controls and configuration into the record. A pre-request callback commits schedule advancement before contacting the provider. A persisted attempt consumes that provider/schedule slot even if the result is uncertain.

Responses include known returned model, token usage, execution profile and terminal status. The raw response, extracted SVG and thumbnail are separate files. Sensitive credentials are excluded from error output. SVG validation retains unsafe originals but blocks rendering. No drawing repair occurs.

Startup marks unfinished records `interrupted`, reconciles consumed schedule slots, then starts scheduling. Quit cancels local waiting and waits for bounded cleanup. An uncertain remote request is not automatically resent. Corrupt individual records remain in place and are reported without hiding readable history.

The latest image and four recent requests are filtered by selected provider and requested model. They retain failures and identify changed configurations or server-returned models. A compatible endpoint change remains visible as a configuration change. Records retain the full configuration for inspection; there is no scoring or cross-provider equivalence claim.

`SVGExtractor`, `SVGValidator` and `SchedulePolicy` remain pure core components. The app target owns SwiftUI/AppKit, Keychain, notifications, login items, Quick Look and WebKit thumbnails. All riding-pelican branding continues to use the existing SVG assets.
