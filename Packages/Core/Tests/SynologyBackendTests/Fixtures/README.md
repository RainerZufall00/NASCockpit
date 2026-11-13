# DSM fixtures

These responses are **synthetic**, written from public knowledge of the DSM Web API
(Synology's official API guides for Auth/File Station, the DSM web UI, and the
open-source `synology-api` library).

Exception: `dsm_notify.json` is a response captured from a real DSM 7 (2026-11), anonymized
(host, addresses, task, user and container names replaced). Its last item is synthetic and only
exercises the fallback for unknown event tags.

Before release, replace each file with an anonymized response captured from a real
DSM 7.2+ (browser dev tools → Network → `entry.cgi`). Remove serial numbers, MAC
addresses, IPs, host names, user names and paths.
