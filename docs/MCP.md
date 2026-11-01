# AI access (MCP)

Whisp includes a local Streamable HTTP MCP server. No separate server installation or hosted backend is needed.

1. Complete **Tools & setup** in Whisp and download the transcription models you want.
2. Enable **Settings → AI access**.
3. Configure a local MCP client with the displayed address and Bearer token: `Authorization: Bearer YOUR_TOKEN`.
4. Keep Whisp and its main window open.

The default endpoint is `http://127.0.0.1:7422/mcp`. Change the port if it is in use. Clients must support local HTTP MCP with custom headers; cloud-only connectors cannot reach this Mac. A stdio bridge and OAuth are not provided.

| Tool | Action |
| --- | --- |
| `get_status` | Read audio, job ID/state, progress, formats and setup status. |
| `open_audio` | Open one audio or video file with sound, replacing the previous file and temporary transcript. |
| `start_transcription` | Start a job immediately; poll `get_status` until completion. |
| `read_transcript` | Read a page of the completed plain-text transcript. |
| `export_transcript` | Save TXT, JSON, SRT, VTT or TSV to a new path. |
| `check_tools` | Test installed tools and the configured environment; installs nothing. |
| `cancel_operation` | Request cancellation of the current operation. |
| `clear_temporary_data` | Discard the unexported transcript, keeping installed models and audio. |

Example detailed transcription:

```json
{"preset":"detailed","language":"hi","align":true,"output_format":"json"}
```

`output_format` accepts `json`, `txt`, `srt`, `vtt`, `tsv` or `all`. The Detailed preset selects JSON; pass `all` for every format. Only the chosen formats are available for export.

`start_transcription` returns a job ID without waiting for completion. Poll `get_status` until `job_state` is `completed`, `failed` or `cancelled`. Downloads and long transcription jobs remain visible in the app. Once complete, export JSON to retain word timestamps:

```json
{"format":"json","destination":"/Users/YOUR_USER/Documents/transcript.json"}
```

AI paths must be absolute and inside your home folder, including after resolving symbolic links. Exports never overwrite existing files. Input is limited to 200 MB per file / four hours, and processing to six hours. Transcript reads are paginated; full results are available through export. The transcription model must already be downloaded in Tools & setup; `get_status` lists available models. Language alignment and speech-detection resources may download into the configured folder on first use. Environment installation and folder selection remain manual app actions.

The listener binds only to `127.0.0.1`. Every request requires authentication; foreign browser origins are rejected. Tokens and enabled/port preferences persist across launches. The token is stored in `~/Library/Application Support/Whisp/Automation/token` with owner-only permissions. New token or disabling AI access revokes sessions and cancels their owned operations. Sessions expire after 30 minutes of inactivity; continue polling during a long job.

MCP uses JSON-RPC 2.0, JSON responses and `MCP-Session-Id`. Supported protocol versions: `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05` (all over the current HTTP transport). GET returns 405; there is no persistent notification stream. Requests are limited to 64 KiB and responses time out after 120 seconds. Use a longer client timeout for tool checks. The HTTP server never waits for an entire transcription job.

Audio processing is local. Your AI client's provider may receive transcript text or tool results according to its settings. Original media files and saved exports are preserved; closing the main window cancels processing and deletes temporary results.
