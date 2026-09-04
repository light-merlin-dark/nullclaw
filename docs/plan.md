# Nullclaw fork — active integration

## Native tool transport, 4 September 2026

Source is accepted locally: full Zig gate 7,419 passed / 9 skipped, 59.73 s.
Granis's joined fixture proves a native call through its gateway adapter, the
real AI Guard route and OpenRouter adapter, an in-memory proposal commit, and
the matching `tool_call_id` back to the runner. Scripted provider, no quality or
live-billing claim. Granis owns the deployment/behavioral acceptance receipt.

Changes: zero streaming threshold reports non-streaming capability; compatible
providers preserve assistant calls and tool-result IDs in active history;
wrappers advertise this only when every potential delegate supports it;
redaction, token estimates and compaction retain the additional history fields.
Other provider serializers keep the legacy history path. Structural tool
allowlist is ported from Agent Central's pinned patch (hardening norm N3), after
MCP registration and tool customization. Unconfigured/empty lists preserve the
upstream default; Granis supplies its explicit nonempty governed head list.

Native transport was deployed with AI Guard 2.0.74 and Granis `2efb96c72`.
The production canary exposed first-wrapper connection ownership: filtering
out a discovered sibling closed the retained MCP tool's shared connection.
Granis's expanded two-tool fixture reproduces locally (117 ms, exit 138, no
dispatch). The fix replaces first-wrapper ownership with per-wrapper references;
last removal closes the connection exactly once, independent of removal order.
Full Zig acceptance: 7,420 pass / 9 skip, 13/13 build steps; main test body 38 s
with a cold two-minute compile. ReleaseSmall build passes. No tool authority
is widened. Next: Granis's real-binary multi-tool proof, canonical two-target
vendor ceremony, one correction deployment and one draft-only wiring canary.
Preserve foreign worktrees and their unique commits.
