# Business hours and support availability

Owners and admins configure **Settings → Business hours**. Save the organization
schedule first, then select a support queue to customize its schedule or restore
inheritance. Each schedule has an editable IANA time zone, All Days / Per day
hours, enabled weekdays, and dated exceptions. Exceptions can close a day or
replace its opening hours. Times use 15-minute increments, including 24:00 as an
end-of-day boundary. Opening is inclusive; closing is exclusive. PostgreSQL
evaluates the named time zone, including daylight-saving transitions.

## Customer and agent behavior

- Unconfigured organizations retain their existing behavior.
- Saved enabled hours gate Round Robin assignment, direct service assignment and
  ordinary agent claims/takeover. Existing conversations are not closed or
  forcibly unassigned at closing time.
- Owner/admin/supervisor actions can explicitly cover after-hours support.
- Outside hours, or when no eligible agent has a fresh available heartbeat, a
  handoff stays queued and receives the configured availability notice. Notices
  supplement the existing handoff acknowledgment; keep that acknowledgment
  neutral (for example, "Your support request has been recorded"), not a promise
  that an agent is already online.
- There is no automatic promise of a response time. Pending queue work becomes
  eligible through the existing heartbeat/backlog processor after opening.
  Manual queues remain manual. Bot ownership and explicit-takeover rules are
  unchanged; saving hours never pauses normal chatbot execution.
- Agent availability uses the existing Available switch and two-minute
  heartbeat. Business hours being open does not imply an agent is online.
- Availability notices are durable outgoing messages using database timestamps,
  stable deduplication IDs, existing dispatch retries and the existing
  recipient. Blocked contacts, inactive organizations and expired 24-hour
  customer windows do not receive these notices.
- A manager can manually handle a direct-target request; the intended agent can
  claim it after opening without being a routing-queue member.

## Storage and access

Configuration remains in `organizations.extra.business_hours`; queue overrides
are keyed by tenant routing-queue UUID. A null override restores inheritance.
The JSON merge preserves unrelated organization settings. A database trigger
validates complete merged settings, time zones, dates, message limits and tenant
queue ownership. Owners/admins use existing organization-update permissions. The
tenant-authorized `get_business_hours_status` RPC provides the live preview.

The operational migration changes functions/triggers only; it does not copy
tenant data, modify Node, PHP or Main, or change immutable chatbot definitions.
Generated database types include the new RPC and are synchronized to the UI.

## Testing and limitations

Focused tests cover persistence and authorization, schedule boundaries,
weekends, holidays, daylight saving, queue overrides, fresh/stale availability,
assignment, manager override, takeover and notice deduplication/recipient
protection. Staging acceptance: configure a disposable tenant/queue, hand off
during open and closed hours, verify its notice in WhatsApp/Chat Center, make an
agent available, and verify the queued request can be handled.

This release supports one continuous opening interval per day. Overnight shifts,
split shifts, per-agent rosters, next-opening-time promises and
workload/capacity forecasting are not included. Represent 24-hour service as
00:00–24:00.
