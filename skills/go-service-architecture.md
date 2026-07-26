# Go Service Architecture

A pattern for a fleet of small Go microservices sharing one repo and
(usually) one database *instance* — never a shared database, never
shared domain code between services. Apply this shape to a new Go
service fleet unless the project's own README already documents a
different, deliberate convention — don't impose this over an existing,
working pattern. If a single deployable service is all you actually
need, see the simpler modular-monolith version of this pattern instead;
this doc is specifically for the microservices case.

---

## Highlights

- **Absolute code isolation between services, from day one.**
  `services/<name>/` never imports another `services/<other>/`'s
  packages — not `core`, not `repository`, not `actions`. The *only*
  way one service reaches another is a generated gRPC client. This
  holds even if every service is currently co-deployed in one process
  for convenience — see **Deploy Topology** below.
- **`framework/` is the one deliberate exception.** Genuinely
  domain-free infrastructure code (an idempotency-key interceptor, for
  example) can live in a shared root-level package every service
  imports — because it carries no business knowledge, unlike `core` or
  `repository` code, which must never be shared.
- **Table-per-service is enforced by convention, not database
  credentials**, unless the project's scale justifies the operational
  cost of separate per-service DB users/grants. State this choice
  explicitly rather than leaving it implicit.
- **No distributed transactions.** Hard preconditions (can this
  proceed at all?) go through a synchronous Try-Confirm-Cancel-style
  call to whichever service owns that precondition. Guaranteed
  follow-through after a local commit uses a transactional outbox, not
  a cross-service transaction.
- **Every mutating RPC carries an explicit idempotency field.** Retries
  are not an edge case in a service fleet — they're routine (client
  retries, outbox dispatch retries, plain network flakiness) — so every
  write path is designed for it from the start, not bolted on later.
- **Resource names are parsed for ownership.** Deliberately the
  opposite of a single-database design: with each entity's owning
  service fixed at creation, the name itself is the cheapest, always-
  available way to route to the right service — see **Resource Names
  and Ownership** for why this reverses the "never parse" rule a
  single-database version of this pattern would use.
- **A dedicated read-only composition service (BFF)** assembles
  cross-service views for a frontend — domain services stay narrow and
  never fan out to each other just to answer a read.

---

## Folder Structure

```
proto/                # every service's proto, at repo root — not nested
                       # under any one service — so it's trivial to sync
                       # into client repos independently of any one
                       # service's own release cadence

framework/             # the one exception to "no shared code" — see below
  idempotency/
    idempotency.go       # Store interface, Key, Outcome, interceptor

services/
  <name>/
    actions/
      <name>.go           # Server: thin orchestration, inline error-code mapping
      <name>_test.go
    repository/
      <entity>/
        interface.go       # Repository interface + this package's own error sentinels
        impl/
          store.go          # implementation; imports parent for errors
        module/
          module.go          # NewXXXRepository() lazy singleton
        <entity>_test.go
    core/
      <domain>/
        interface.go       # Manager interface + this package's own error sentinels
        impl/
          manager.go
        module/
          module.go
        <domain>_test.go
    validation/
      registry.go         # generic Registry + interceptor
      XxxRequestValidator.go
      XxxEntityValidator.go
    converters/
      <entity>.go         # hand-written internal <-> wire, batch/list helpers
      <entity>_fuzz_test.go
    main.go               # this service's own entry point
```

Everything under one `services/<name>/` follows the same internal
layering as a modular monolith (`repository/` → `core/` → `actions/`),
scoped to that one service. The difference is the outer boundary:
nothing under `services/<name>/` ever imports from
`services/<other-name>/`, full stop — where a modular monolith would
let `core/order` import `core/customer` directly, a microservice's
`services/order/core/order` instead calls `services/customer`'s
generated gRPC client.

---

## services/&lt;name&gt;/repository — Dumb Storage

- Accepts and returns **protos or basic Go types only** — never a
  custom Go struct.
- Verbs: `Get`, `Create`, `Update`, `Delete`, narrow `Add`/`Remove`
  patch-style mutators, `Find`-style lookups. No business logic.
- Every method takes `ctx context.Context` — genuinely used here, not
  just reserved: it's how a request-scoped DB transaction (for
  idempotency-safe writes — see **Cross-Service Consistency**) gets
  threaded down to the actual write.
- Defines and returns its own `ErrNotFound` / `ErrAlreadyExists` (etc.)
  in `interface.go` — no shared error package, and definitely no error
  package shared *across services*.
- Defensive copies on read/write so callers can't mutate a stored
  entity by mutating what they got back.

## services/&lt;name&gt;/core — All Business Logic

- Operates exclusively on this service's own internal proto entities.
  The public wire API's types are not imported anywhere under `core/`.
- Every cost formula, precondition check, and business rule lives here.
- When this domain needs something another *service* owns, it calls
  that service's generated gRPC client — never that service's Go
  packages directly, even if (for now) both processes happen to run in
  the same binary. A dependency on another service is a network call in
  the code, whether or not it's a network call at runtime today.
- Defines its own error sentinels in `interface.go`, same reasoning as
  `repository/` — see **Error Ownership** below, which now also covers
  errors coming back from another *service's* RPC, not just this
  service's own repository.
- A "special" or "admin-only" capability is not a dedicated service of
  its own. It's a normal capability on the domain it belongs to,
  exposed as a **private** RPC on that domain's own service — see
  **Private vs. Public RPC Visibility**.

## services/&lt;name&gt;/actions — Thin Orchestration Only

- An action file is ~5 lines: validate (automatic, via the
  interceptor), delegate to exactly one `core/` manager call, convert
  the result to the wire type, map errors.
- **Inline, duplicated error-code mapping per action** — no shared
  error-mapping package (and certainly none shared across services).
  Only map the specific sentinel errors this action actually expects;
  everything else falls through to the generic internal-error code.
  When unsure, leave it internal.
- Converters, validators, and the validation registry are **plain
  packages** — no `interface.go`/`impl/`/`module/` split.

---

## framework/ — The One Shared-Code Exception

Everything under `framework/` is, by definition, code with zero
business/domain knowledge — it doesn't know what an "order" or a
"customer" is, only that some request carries an idempotency key, or
needs a retry policy, or needs a tracing span. That's what makes it
safe to share: importing it doesn't create a hidden coupling between
two services' *business logic*, the thing the no-shared-code rule
actually protects against. Concretely:

- `framework/idempotency/` — see **Idempotency** below.
- Anything added later here (structured logging helpers, a tracing
  interceptor, a generic retry-with-backoff helper) needs to pass the
  same test: does it know anything about *this project's domain*? If
  yes, it doesn't belong in `framework/` — it belongs under whichever
  service actually owns that knowledge, duplicated per-service if more
  than one needs it (see the **duplication over sharing** stance
  throughout this doc — validators, error sentinels, and now this).

---

## Error Ownership (read this before writing a return statement)

**No interface propagates a dependency's error identity — whether that
dependency is a local repository, a local package, or now a *remote
service's RPC*.** A caller of `services/order/core/order.Manager`
should never need to inspect `services/customer`'s error types to
understand what it might get back — remote or local, the rule is the
same.

Two cases, decided at the call site where a dependency's error comes
back (a repository call, a local package call, or a gRPC call to
another service — treat all three identically):

1. **Caller-facing, on a resource named directly by the caller's own
   argument**: wrap it into this package's own declared sentinel so
   identity survives, but ownership doesn't:
   ```go
   o, err := m.orders.Get(ctx, orderID)
   if err != nil {
       return nil, fmt.Errorf("%w: %v", order.ErrNotFound, err)
   }
   ```
   The same applies when the dependency is a remote RPC — translate a
   `connect.CodeNotFound` from `customerClient.Get(...)` into this
   package's own `ErrNotFound` exactly the same way you'd translate a
   local repository's error.
2. **Internal invariant violation** — a lookup on something the caller
   never directly named. Wrap with `%v` only, no `%w`, no exported
   sentinel — deliberately breaking the chain so nothing upstream can
   match it to anything but the generic internal-error code:
   ```go
   owner, err := m.customers.FindOwner(ctx, orderID) // order already confirmed to exist
   if err != nil {
       return fmt.Errorf("order: owner of order %q: %v", orderID, err)
   }
   ```

**When genuinely unsure which case applies, treat it as case 2 —
internal is always a safe default.**

---

## interface.go / impl/ / module/ Split

Unchanged from the modular-monolith version of this pattern, just
nested one level deeper — under `services/<name>/core/<domain>/` and
`services/<name>/repository/<entity>/` instead of at the repo root:

- **`interface.go`** — the exported interface type and this package's
  own error sentinels. Imports nothing from `impl/` or `module/`.
- **`impl/`** — implements the interface, imports the parent package
  for its error sentinels and interface type.
- **`module/`** — its own subpackage (avoids the import cycle `impl`
  importing its parent would otherwise create with a DI constructor),
  exporting `NewXXX()` memoized with `sync.Once`.
- Tests live next to `interface.go`, use real in-memory implementations
  via `module.NewXXX()` for **this service's own** dependencies — never
  mocks for those. A dependency on *another service* is the one place
  mocking is the right call — see **Testing**.

---

## Proto Layout

- All proto lives at `proto/` in the repo root — not nested under any
  one service — specifically so it's trivial to sync into client repos
  (web/mobile) independent of which service's release this proto change
  actually shipped with.
- Each deployable service corresponds to one (or more) proto service
  definitions. Splitting a service later means splitting its proto
  too — the two boundaries move together.
- An internal-only proto namespace, scoped per service, holds whatever
  that service's own `repository/`/`core/` operate on internally; the
  public wire namespace is what every service's `actions/` layer
  speaks, both to its own clients and to other services calling it.

---

## Resource Names and Ownership

**Resource names are parsed to determine which service owns a
resource** — the opposite of a single-database design's "never parse"
rule, and worth stating that reversal explicitly so it doesn't read as
an oversight. The single-database version of this rule exists to avoid
staleness: a reverse-ownership index living in one shared database can
go stale relative to the data it indexes, so that design prefers a
repository-maintained index over parsing. None of that applies once
each entity's owning *service* is fixed at creation and never changes
without an explicit transfer operation — the name itself
(`accounts/{a}/orders/{o}`) already encodes routing information that's
permanently true, so parsing it costs nothing and avoids adding a
network hop (or a shared ownership index, which would itself violate
no-shared-tables) just to answer "which service do I ask about this."

If ownership can ever change after creation, that's an explicit
`Transfer` RPC on the owning service — never an implicit list update
somewhere else.

---

## Cross-Service Consistency (No Distributed Transactions)

There is no cross-service database transaction. A flow that used to be
two writes in one local transaction (debit a balance, create a
resource) is now two writes to two different services' own databases,
and a crash between them is a real possibility that has to be designed
for, not assumed away.

**For hard preconditions** (can this proceed at all — e.g. can they
afford it): use a synchronous **Try-Confirm-Cancel** call to whichever
service owns that precondition, never a fire-and-forget async queue
alone (a queue alone can't answer "yes/no, right now," which most hard
gates need). The owning service exposes three RPCs:
- `Hold(...) → hold_id` — reserves without committing, answered
  synchronously against that service's own single table.
- `Confirm(hold_id)` — finalizes.
- `Cancel(hold_id)` — releases, also called automatically by a
  background sweep for any hold whose TTL expired unconfirmed (the
  safety net for a caller that crashed and never confirmed).

**For guaranteed follow-through after a local commit** (e.g. "and once
that nest is created, tell the ledger service to confirm the hold"):
use a **transactional outbox** — a row written in the *same* local
transaction as the domain write, recording "call X once this commits."
A background dispatcher (ideally a managed queue like Cloud Tasks or
Pub/Sub rather than a hand-rolled poller, where the platform already
gives you retry-with-backoff and dedup by task name) reads the outbox
after commit and makes the call, retrying until it succeeds. This is
what makes the two writes (domain write + hold confirmation) eventually
consistent without ever needing them to be atomic with each other.

**Not every two-step flow needs this rigor.** Before reaching for
Hold/Confirm/Cancel, check whether ordering + idempotent operations
already solve it: e.g. "remove from container, then delete" is safe
without any saga machinery, because both steps are individually safe to
retry from wherever a crash left off — deleting an already-deleted
thing, or removing an already-removed reference, are both no-ops. Only
reach for the heavier pattern when a genuine hard gate (an
afford-it-or-not decision) is actually involved.

---

## Idempotency

Every mutating request proto carries an explicit `request_id` field —
not a header, not implicit — so any caller (a real client, or your own
outbox dispatcher) can retry safely.

**`framework/idempotency/`** provides this generically:

```go
type Key struct {
    Service   string
    Method    string // full RPC procedure name
    RequestID string
}

type Outcome int

const (
    OutcomeProceed  Outcome = iota // fresh claim (or reclaim) — run the handler
    OutcomeReplay                  // already done — return the stored response
    OutcomeBusy                    // still in progress, lease not expired — reject, retry later
    OutcomeConflict                // same request_id, different payload
)

type Store interface {
    Claim(ctx context.Context, key Key, requestHash string, leaseExpiresAt time.Time) (ClaimResult, error)
    Complete(ctx context.Context, key Key, response []byte) error
}
```

- **Extraction is fully generic**: any request message with a
  `request_id` field automatically satisfies a small structural
  interface (`interface{ GetRequestId() string }`, which protoc-gen-go
  generates for free) — no per-message registration needed to detect
  and read the key.
- **Replaying a stored response is not fully generic** — the
  interceptor needs to know the *type* to unmarshal into, which needs a
  small per-service `procedure → zero-value response` registration,
  the same shape as this pattern's own validation registry. Be upfront
  about this rather than promising a fully automatic mechanism.
- **Lease duration is `ctx.Deadline()`**, not a separately configured
  constant: well-behaved code respects context cancellation, so once a
  deadline passes, the original attempt should have already stopped on
  its own — making "past deadline" a principled definition of
  "abandoned," and keeping the lease automatically consistent with
  whatever timeout policy the call already uses. Fail closed (reject)
  if a caller has no deadline set at all — don't guess a fallback.
- **Reclaim is a compare-and-swap**, not a blind overwrite: a retry
  finding an expired lease updates the row with a `WHERE status =
  'IN_PROGRESS' AND lease_expires_at <= now()` clause and checks it
  actually affected a row, so two concurrent reclaim attempts can't
  both win.
- **A first iteration is allowed to be an in-memory `Store`** with no
  real database and no transactional atomicity between the domain
  write and marking `COMPLETED` — that's a known, explicitly accepted
  gap, not an oversight, until a real transactional store exists and
  the completion step is threaded through the same local transaction as
  the domain write (via `ctx`, the same mechanism repository writes use
  — see **repository — Dumb Storage** above). Keep the lease/reclaim
  mechanism even in this reduced version: without it, an abandoned
  request is stuck forever rather than eventually retryable, which is a
  worse failure mode than the rare double-execution this first version
  accepts.

---

## Private vs. Public RPC Visibility

There's no dedicated "admin" or "QA-only" service. Any service can mark
specific RPCs **private** — reachable only by other backend services,
never a normal client — instead of routing every system-only action
through one special-cased service. For a project without a full
auth/session layer yet, a shared-secret header checked by an
interceptor is enough to gate these for now; if a private RPC's service
is ever split into its own separately-deployed instance, the natural
upgrade is the platform's own access control (e.g. Cloud Run's IAM
invoker restriction on that deployment) rather than inventing more
application-level auth.

---

## Composition / BFF Service

A dedicated, read-only service assembles cross-service views a frontend
actually needs — e.g. merging one service's entity with another
service's related record into the shape a client renders. Keep this
strictly separate from any domain service and strictly read-only:
domain services never fan out to each other just to answer a read, and
mutating actions are never proxied through the composition service —
clients call the owning service directly for writes, and the
composition service only for assembled reads.

---

## Testing

- **A service's own dependencies** (its own `repository/`, its own
  `core/`) are tested for real, through `module.NewXXX()` — no mocks,
  same as the modular-monolith version of this pattern.
- **Another service's dependency** is the one place mocking the
  generated gRPC client is the right call, not a compromise: it's a
  stable, deliberately-versioned wire contract that changes rarely and
  on purpose, unlike an internal interface that might shift daily — the
  usual reason to avoid mocks doesn't apply here.

---

## Deploy Topology

Code-level isolation (no cross-service Go imports) is absolute from day
one, independent of deployment topology. Deployment can lag behind:
keeping every service in one process/one deploy pipeline for
convenience, and splitting into independently-deployed instances later
once real, measured scaling needs justify the operational cost (a
separate service account, deploy pipeline, and monitoring surface per
service). Because cross-service calls already go through a generated
client rather than a direct function call, splitting later is a
configuration change (point the client at a different URL) — not a
rewrite.
