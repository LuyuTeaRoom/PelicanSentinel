# Provider design reference

Reviewed on 2026-09-17 against [steipete/CodexBar](https://github.com/steipete/CodexBar), commit `0b7726ebe4a07074b1e93b8c404f7358fe39afe2` (MIT). Pelican Sentinel implements its own generation adapters and does not embed CodexBar code or read CodexBar credentials.

The useful architectural ideas are described in [Provider authoring guide](https://github.com/steipete/CodexBar/blob/0b7726ebe4a07074b1e93b8c404f7358fe39afe2/docs/provider.md): central provider metadata, implementation boundaries, explicit authentication sources, and per-provider identity isolation. CodexBar fetch strategies retrieve usage/quota/status, as its [provider guide](https://github.com/steipete/CodexBar/blob/0b7726ebe4a07074b1e93b8c404f7358fe39afe2/docs/providers.md) explains. Those strategies do not establish a generation API contract.

| Reference idea | Pelican implementation |
|---|---|
| Descriptor owns labels and capabilities | A fixed `ProviderID` catalog defines defaults, authentication help and relevant settings fields. |
| Core behavior separated from app UI | Native protocol adapters live in PelicanCore; AppModel constructs the selected adapter, Views edits saved settings. |
| Authentication isolated per provider | Keys are isolated by provider; both UI languages share the same app identity. Compatible keys additionally depend on the normalized base URL. CLI credentials remain owned by Codex. |
| Concrete strategy with explicit source | One chosen generation path per request. No automatic fallback, cookie import, token borrowing or quota scraping. |

The small fixed catalog is sufficient for five connections. Dynamic registration, plugin discovery, credential refresh brokers and fallback chains were not needed for this release.

## API sources

- [OpenAI text generation](https://developers.openai.com/api/docs/guides/text): Responses input/output and text aggregation. Reasoning `default` omits the override.
- [OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create): the compatible wire format; a third-party service must implement the selected fields.
- [Claude Messages](https://platform.claude.com/docs/en/build-with-claude/working-with-messages) and [stop reasons](https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons): message content and terminal outcome handling.
- [Claude model IDs](https://platform.claude.com/docs/en/models/overview): verify model availability before configuring a request.
- [Gemini API reference](https://ai.google.dev/api) and [generateContent](https://ai.google.dev/api/generate-content): the key header, content parts, finish reasons and usage metadata.
- [Gemini models](https://ai.google.dev/gemini-api/docs/models): verify model availability before configuring a request.

These links identify the protocol references used by the adapters. Hard-coded defaults are not a current model-availability guarantee. Account access, quota and third-party compatibility must be checked against the configured service.
