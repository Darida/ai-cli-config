# Go Service Architecture

A pattern for a fleet of small Go microservices sharing one repo and
(usually) one database *instance* — never a shared database, never
shared domain code between services. Apply this shape to a new Go
service fleet unless the project's own README already documents a
different, deliberate convention — don't impose this over an existing,
working pattern.

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
- **Resource names are parsed for ownership.** Each entity's owning
  service is fixed at creation, so the name itself is the cheapest,
  always-available way to route to the right service — see **Resource
  Names and Ownership**.
- **`repository/`/`core/` default to using the `v1` wire proto
  directly** — no internal proto namespace, no converters — unless a
  service's needs genuinely diverge from the wire shape, in which case
  moving to an internal-proto-plus-`converters/` pattern requires
  explicit human approval; see **Repository/Core Data Shape**.
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
    idempotency.go       # Store interface, Key, Outcome, ClaimResult
    interceptor.go        # the Connect interceptor itself
    impl/
      memory_store.go      # a concrete Store — impl/ still applies here,
                            # same as core/ and repository/, whenever a
                            # framework/ package has a concrete
                            # implementation behind its interface
  validation/
    registry.go          # generic Registry + Validator interface + interceptor
  randomid/
    interface.go         # Generator interface
    impl/
      generator.go
    module/
      module.go

clients/               # a binding to another service's own generated
                        # Connect client — one package per service
                        # *depended on*, shared by every service that
                        # calls it (e.g. clients/bank/ for BankService),
                        # never duplicated per consumer. A consuming
                        # service holds the generated
                        # critterv1connect.XServiceClient interface
                        # directly as its own dependency type and calls
                        # it directly — no hand-written interface wraps
                        # it. See **framework/inject** and **Testing**
                        # below for how production vs. test construction
                        # differs, and why an adapter exists at all.
  <dependency-name>/
    inproc/
      inproc_x_service_client.go  # Adapter{ critterv1connect.XServiceClient }
                                   # — anonymously embeds the generated
                                   # client interface so every method
                                   # forwards automatically once wired,
                                   # with zero hand-written per-RPC
                                   # forwarding code. Exists only to
                                   # satisfy the Go compiler when two
                                   # services depend on each other and a
                                   # test needs to hand out a real,
                                   # in-process implementation before
                                   # that implementation itself has
                                   # finished constructing — see
                                   # **framework/inject** below. Never
                                   # constructed in production.
    module/
      module.go             # registers critterv1connect.XServiceClient
                             # into framework/inject's registry (see
                             # **framework/inject** below) — production
                             # construct builds the real generated
                             # client against this dependency's own base
                             # URL; testing construct hands out an
                             # unwired inproc.Adapter immediately, and a
                             # RegisterFieldInjection call points its
                             # embedded field at the real,
                             # in-memory-backed *actions.Server the
                             # owning service registers for that same
                             # seed. Never the place any client logic
                             # lives — there is no logic here beyond
                             # wiring.

services/
  <name>/
    actions/
      server.go            # Server struct + NewServer(manager) constructor
      <rpc-name>.go          # one file per RPC — e.g. get_widget.go, create_widget.go
      <rpc-name>_test.go       # matching test file per RPC
    repository/
      interface.go        # Repository interface(s) + this package's own error sentinels —
                           # flat, not nested under a same-named subfolder: a service has
                           # exactly one repository package. If it owns several distinct
                           # entities, their interfaces (XxxRepository, YyyRepository) share
                           # this one interface.go and this one `repository` package —
                           # never a subfolder per entity.
      impl/
        store.go           # implementation; imports parent for errors
      module/
        module.go           # registers Repository into framework/inject's
                             # registry — production registers the real
                             # backing store, testing registers an
                             # in-memory one — see
                             # **interface.go / impl/ / module/ Split** below
      <entity>_test.go
    core/
      <domain>/
        interface.go       # Manager interface + this package's own error sentinels
        impl/
          manager.go         # NewIncompleteManager()/WireX(), split out
                              # only for the one field that's a genuine
                              # cross-service dependency-cycle edge — see
                              # **framework/inject** below
        module/
          module.go           # registers Manager into framework/inject's
                               # registry, same production/testing split
                               # as repository/module above
        <domain>_test.go
    register/
      register.go          # blank-imports this service's own
                            # repository/module, every core/<domain>/module,
                            # and actions/module packages for their init()
                            # registration side effects — see
                            # **framework/inject** below
    validation/
      XxxRequestValidator.go   # registered into a framework/validation.Registry
      XxxEntityValidator.go    # from this service's own service.go — see framework/ above
    converters/           # ONLY if this service is on the internal-proto pattern —
                           # see Repository/Core Data Shape below. Absent entirely
                           # for a service on the (default) v1-direct pattern.
      <entity>.go         # hand-written internal <-> v1, batch/list helpers
      <entity>_fuzz_test.go
    service.go            # wires this service's manager + Server + validators
                           # into a mountable handler; the one thing main.go calls
    main.go               # this service's own entry point
```

Nothing under one `services/<name>/` ever imports from
`services/<other-name>/`, full stop — the only way `services/order`
reaches `services/customer` is `services/customer`'s generated gRPC
client, never a direct package import.

---

## services/&lt;name&gt;/repository — Dumb Storage

- **Flat, one package per service** — `services/<name>/repository/`
  directly, never nested under a same-named subfolder
  (`repository/<name>/`). A service has exactly one repository package,
  even when it owns several distinct entities: their interfaces
  (`XxxRepository`, `YyyRepository`) all live together in that one
  `interface.go`, in that one `repository` package. This is unlike
  `core/`, which is genuinely nested per domain because a service
  commonly hosts several independent core packages (business logic for
  its own domain, plus small storage-free helper engines it doesn't
  share with any other service) — `repository/` has no equivalent
  reason to split.
- Accepts and returns **protos (v1 or internal — see Repository/Core
  Data Shape below) or basic Go types only, in `interface.go`'s method
  signatures** — never a custom Go struct there. (A private Go struct
  used only inside `impl/`, never crossing `interface.go`, is a
  different matter — see the same section.)
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

- Operates on whichever proto this service has chosen as its
  `repository/`/`core/` data shape — `v1` directly, or a separate
  internal proto — see **Repository/Core Data Shape** below. Under the
  internal-proto pattern, `v1` is not imported anywhere under `core/`.
- Every cost formula, precondition check, and business rule lives here.
- When this domain needs something another *service* owns, it calls
  that service's generated gRPC client — never that service's Go
  packages directly, even if (for now) both processes happen to run in
  the same binary. A dependency on another service is a network call in
  the code, whether or not it's a network call at runtime today.
- Defines its own error sentinels in `interface.go`, same reasoning as
  `repository/` — see **Error Ownership** below, which covers errors
  from a repository call, a local package call, and another *service's*
  RPC identically.
- A "special" or "admin-only" capability is not a dedicated service of
  its own. It's a normal capability on the domain it belongs to,
  exposed as a **private** RPC on that domain's own service — see
  **Private vs. Public RPC Visibility**.

## Repository/Core Data Shape: v1-Direct vs. Internal+Converters

Two patterns are acceptable for what `repository/` and `core/` use as
their own input/output types. **Pick one per service and never mix them
within that service** — every `repository/`/`core/` method in a given
service uses the same pattern, not a mix of `v1` here and internal
there.

- **Pattern 1 — v1-direct (the default; start here).** `repository/`
  and `core/` accept and return the same `v1` wire protos (plus basic
  Go types) that `actions/` sends over the network. There is no
  separate internal proto namespace, no `converters/` package, and
  nothing to keep in sync between two shapes — because there's only
  one shape.
- **Pattern 2 — internal protos + converters (a deliberate escape
  hatch, not a starting point).** `repository/` and `core/` accept and
  return a separate, service-scoped internal proto (plus basic Go
  types) instead. Under this pattern, **`actions/` is the only package
  in the service that ever references the `v1` type**, and it must
  immediately convert — via a hand-written `services/<name>/converters/`
  package — before a value crosses into `core/`, and again on the way
  back out to the wire. Neither `repository/` nor `core/` imports `v1`
  under this pattern.

**How to choose, and how to move between them:**

1. Design the `v1` wire proto as an API — shaped for what a client
   actually needs, without regard to how it will be stored or computed
   internally.
2. Default to Pattern 1: use `v1` directly in `repository/`/`core/` as
   long as that shape also works fine for storage and business logic.
   **Never reshape `v1` to suit an implementation convenience** — the
   wire contract is driven by the API it serves, not the other way
   around.
3. If `v1`'s shape genuinely stops working for internal needs, that's
   a real architectural change, not a routine refactor: **get explicit
   human approval first**, then migrate — introduce this service's own
   internal proto, move every `repository/`/`core/` usage over to it,
   and add `services/<name>/converters/` to bridge `actions/` between
   the two. Don't reach for Pattern 2 preemptively "just in case a
   field diverges later."

**Custom Go structs are still never allowed to cross an `interface.go`
boundary**, in either pattern — that rule (see **repository — Dumb
Storage** above) is about the interface, not about which proto
namespace is in play. A private Go struct used only *inside* an
`impl/` package is a different matter entirely and is completely fine,
as long as it:
- never appears in an `interface.go` method signature (parameter or
  return value), and
- never escapes the package (no exported field, no exported
  constructor returning it).

`services/bank/repository/impl/store.go`'s own `hold`/`holdStatus`
types are the model for this: real, private Go structs holding
bookkeeping (`status`, `expiresAt`) that never needs to cross
`Repository`'s interface — only a plain `hold_id` string does. That's
what keeps "protos or basic types only" satisfied at the boundary that
actually matters, while still allowing normal, idiomatic private Go
code inside an implementation.

## services/&lt;name&gt;/actions — Thin Orchestration Only

- **One file per RPC**, not one file per service — `actions/server.go`
  holds the `Server` struct and its `NewServer(manager)` constructor;
  every RPC method attaches to that same struct from its own file
  (`actions/<rpc-name>.go`). A service with ten RPCs has ten small
  method files plus `server.go`, never one large file accumulating all
  of them.
- Each RPC method is ~5 lines: validate (automatic, via the
  interceptor), delegate to exactly one `core/` manager call, convert
  the result to the wire type, map errors.
- **Inline, duplicated error-code mapping per action** — no shared
  error-mapping package (and certainly none shared across services).
  Only map the specific sentinel errors this action actually expects;
  everything else falls through to the generic internal-error code.
  When unsure, leave it internal.
- If this service is on the internal-proto pattern (see
  **Repository/Core Data Shape** above), `actions/` is the only package
  that references `v1`, and `converters/` — a **plain package**, no
  `interface.go`/`impl/`/`module/` split — is where the internal↔v1
  translation actually happens. On the default v1-direct pattern,
  there's no `converters/` package at all.
- This service's own `XxxRequestValidator` types are likewise a **plain
  package** — no `interface.go`/`impl/`/`module/` split. The generic
  `Registry`/`Interceptor` machinery they get registered into lives in
  `framework/validation` (see **framework/** above) — a service's own
  `validation/` package holds only its validator types, never a copy of
  the registry itself.
- `services/<name>/service.go` (one level up from `actions/`) is the
  single place that assembles this service end to end: build the
  `core/` manager via its `module.NewManager()`, construct
  `actions.NewServer(manager)`, register this service's validators into
  a `framework/validation.Registry`, and return the finished, mountable
  handler (procedure path + `http.Handler`). `main.go` calls exactly
  this and nothing else to stand the service up.

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
- `framework/validation/` — the generic `Registry`/`Validator`/
  `Interceptor` machinery described in **actions — Thin Orchestration
  Only** below. It only knows about a request's concrete Go type, never
  what that request means — each service still writes and owns its own
  `XxxRequestValidator` types in its own `services/<name>/validation`
  package; only the registry/interceptor plumbing is shared.
- `framework/randomid/` — mints a random opaque ID segment for a new
  resource name. Zero domain knowledge: it doesn't know whether the
  caller is about to name a creature, an order, or an idempotency key
  for an outgoing call — just "give me a random string."
- Anything added later here (structured logging helpers, a tracing
  interceptor, a generic retry-with-backoff helper) needs to pass the
  same test: does it know anything about *this project's domain*? If
  yes, it doesn't belong in `framework/` — it belongs under whichever
  service actually owns that knowledge, duplicated per-service if more
  than one needs it (see the **duplication over sharing** stance
  throughout this doc — validators, error sentinels, and business
  logic in general).

---

## Error Ownership (read this before writing a return statement)

**No interface propagates a dependency's error identity — whether that
dependency is a local repository, a local package, or a *remote
service's RPC*.** A caller of `services/order/core/order.Manager`
should never need to inspect `services/customer`'s error types to
understand what it might get back — remote or local, the rule is the
same.

Use `github.com/cockroachdb/errors` (aliased as `errors`, a drop-in for
the stdlib package — `errors.Is`/`errors.As` still work exactly the
same) instead of `fmt.Errorf`/stdlib `errors` in every `repository/impl`
and `core/*/impl` file, purely so every wrap captures a real stack frame
for free — nothing else about the call-site shape changes. **Never use
`errors.Mark` for this** — it's tempting for case 1 below since it looks
like it preserves both the new sentinel's identity and the original
error's stack, but it only satisfies *cockroachdb's own* `errors.Is`,
not stdlib's plain `Unwrap()`-walking one — and every `actions/*.go`
error-code mapping (see below) uses stdlib `errors.Is`. `errors.Wrapf`
(below) satisfies both.

Two cases, decided at the call site where a dependency's error comes
back (a repository call, a local package call, or a gRPC call to
another service — treat all three identically):

1. **Caller-facing, on a resource named directly by the caller's own
   argument**: wrap it into this package's own declared sentinel so
   identity survives, but ownership doesn't:
   ```go
   o, err := m.orders.Get(ctx, orderID)
   if err != nil {
       return nil, errors.Wrapf(order.ErrNotFound, "%v", err)
   }
   ```
   The same applies when the dependency is a remote RPC — translate a
   `connect.CodeNotFound` from `customerClient.Get(...)` into this
   package's own `ErrNotFound` exactly the same way you'd translate a
   local repository's error.
2. **Internal invariant violation** — a lookup on something the caller
   never directly named. Wrap the dependency's error as the cause, no
   exported sentinel — deliberately breaking the chain so nothing
   upstream can match it to anything but the generic internal-error
   code:
   ```go
   owner, err := m.customers.FindOwner(ctx, orderID) // order already confirmed to exist
   if err != nil {
       return errors.Wrapf(err, "order: owner of order %q", orderID)
   }
   ```

**When genuinely unsure which case applies, treat it as case 2 —
internal is always a safe default.**

**None of this internal chain ever reaches a normal caller directly.**
`actions/` never passes a `core/` error straight to `connect.NewError` —
every mapped case (and the generic fallback) builds a
`framework/debugtrace.CallerError{Message, Debug}` instead: `Message` is
the exact, complete string a normal caller sees, hand-written at the
call site, never derived from the internal chain; `Debug` is that full
internal error (sentinel identity plus every wrap's real stack frame).
`debugtrace.ServerInterceptor`, installed as the *outermost* interceptor
in `connect.WithInterceptors(...)` (first in the list — see **Idempotency**
below for why order matters), turns that into the final response: just
`Message` normally, plus the complete, unredacted `Debug` chain (via
`%+v`) on a response header when the request carried a shared debug
token — the same shared-secret-header idiom as **Private vs. Public RPC
Visibility** below, gating "show internal debug detail" instead of
"allow this private RPC." A validation- or idempotency-interceptor error
(already a direct, safe `connect.Error` of its own) passes through this
untouched — only a `CallerError` gets the `Message`/`Debug` split, and
only a genuinely unmapped error (not a `connect.Error` at all) falls
back to a generic internal message.

---

## framework/inject — Dependency Registry & Cycle-Breaking

`framework/inject` (production) and `framework/inject/testing` (tests)
are what every `module/` package registers a type into, replacing
hand-rolled `sync.Once` memoization and manual `Reset()` cascades with
one small, generic mechanism, both halves the same shape:

```go
// framework/inject — process-wide, production
func Register[T any](construct func() T) { ... }
func RegisterFieldInjection[T, T2 any](wire func(t T, dep T2)) { ... }
func Get[T any]() T { ... }

// framework/inject/testing — identical shape, keyed per seed
func Register[T any](construct func(seed string) T) { ... }
func RegisterFieldInjection[T, T2 any](wire func(t T, dep T2)) { ... }
func Get[T any](seed string) T { ... }
```

Each registered type gets a lazily-built, build-at-most-once value —
one process-wide instance in production, one independent instance per
test seed (`t.Name()` is the normal seed) in tests, so different tests,
even parallel ones, never observe each other's value. `construct`
produces a value other code can already hold a reference to; any step
registered via `RegisterFieldInjection` for that same type runs
immediately after, resolving one remaining dependency via a further
`Get` call. **This two-step split is what makes a real dependency cycle
resolvable without deadlocking**: the value is marked ready the instant
`construct` returns, strictly before any field-injection step starts
recursing — so if resolving one type's dependencies loops back around to
that same type (a genuine cycle among services, not a bug), the
recursive `Get` call finds the value already there and returns it
immediately instead of re-entering construction and deadlocking on
itself.

**`construct` should build everything it can directly — field injection
is a deliberate, narrowly-scoped exception, not the default.** Most
types need it for nothing at all: a repository, most `core/` Managers,
and every non-cycle dependency resolve every argument inline via `Get`
inside `construct`, exactly like a plain constructor call — including
a dependency that's itself a hand-rolled singleton with no `Get` of its
own (a database client, a stateless ID generator): register *that*
through `inject.Register` too, rather than letting `construct` reach
into another package's own memoized getter directly. A `construct`
that bypasses the registry for one of its own dependencies defeats the
whole point of centralizing construction in one place. Reach for
`RegisterFieldInjection` only for the one field that's a genuine
participant in a cross-service dependency cycle (e.g. three services
that each depend on the next one's client, forming a loop) — never for
a field that just happens to be resolved via the registry. Introducing
a new `RegisterFieldInjection` call outside the `clients/<name>` adapter
layer (below) is worth a second look before landing it — it's a signal
a design didn't manage to avoid the cycle, not a routine choice.

For a `core/<domain>/impl.Manager` that's a genuine cycle participant,
split construction so the cycle-edge field alone is left unset:

```go
func NewManager(repo Repository, dep OtherServiceClient, cycleDep CycleServiceClient) creature.Manager {
    return &Manager{repo: repo, dep: dep, cycleDep: cycleDep} // production convenience: everything at once
}
func NewIncompleteManager(repo Repository, dep OtherServiceClient) *Manager { // construct: instant, cycle field unset
    return &Manager{repo: repo, dep: dep}
}
func (m *Manager) WireCycleDep(cycleDep CycleServiceClient) { m.cycleDep = cycleDep } // field-injection target
```

`module/module.go` registers `NewIncompleteManager` as `construct`, and
a `RegisterFieldInjection[Manager, CycleServiceClient]` call whose
closure invokes `WireCycleDep` on the concrete `*Manager` (never the
interface — a caller holding the wrong concrete type is a compile
error, not a runtime panic on a failed type assertion). Every other
field is still a plain constructor argument, resolved inline in
`construct`; only the one cycle-edge field goes through this deferred
path. Calling any method that needs the cycle-edge field before its
`RegisterFieldInjection` step has run panics on a nil dependency, the
same failure mode as forgetting to wire any other dependency — not
something this type needs to guard against itself.

**`clients/<name>/module`'s `inproc.Adapter` gets blanket use of
`RegisterFieldInjection`, regardless of whether that particular
dependency happens to sit on a real cycle today** — every client adapter
is wired the same way uniformly, so the pattern doesn't silently break
the moment a future dependency addition turns a currently-acyclic client
into a cycle participant. This is the one deliberate exception to
"reach for field injection only when a real cycle demands it": client
adapters are pre-approved as a class, while a new field-injection use
anywhere else is worth that second look before landing.

**The `register` package convention** solves a different problem: a
type's `Register` call has to actually run (via that package's `init()`)
before anything calls `Get` for it, and a hand-curated, partial list of
blank imports is silently incomplete rather than a compile error — worse,
a cyclic cluster of services needs *every* member's registration
reachable, or resolving even one of them panics with "not registered."
Each service gets its own `services/<name>/register/register.go` — a
package with no exported symbols, whose only content is blank-importing
that service's own `repository/module`, every `core/<domain>/module`,
and `actions/module` packages for their `init()` side effects.
`clients/register/register.go` does the same for every
`clients/<name>/module` package. A shared framework primitive with no
owning service (e.g. a random-ID generator, a database client) has no
`services/<name>/register` home of its own, so it's blank-imported
directly by the top-level `register/register.go` instead. A single
top-level `register/register.go` blank-imports all of the above,
forming the one complete closure of the whole registry — `main.go` and
every test blank-import this one top-level package (`_ "<module>/register"`)
instead of curating their own subset.

---

## interface.go / impl/ / module/ Split

Every `core/` package (nested under `services/<name>/core/<domain>/`,
since a service commonly hosts several) and this service's one
`repository/` package (flat, directly under `services/<name>/repository/`)
follows the same three-way split:

- **`interface.go`** — the exported interface type and this package's
  own error sentinels. Imports nothing from `impl/` or `module/`.
- **`impl/`** — implements the interface, imports the parent package
  for its error sentinels and interface type.
- **`module/`** — its own subpackage (avoids the import cycle `impl`
  importing its parent would otherwise create with a DI constructor).
  Its `init()` registers the interface type into `framework/inject`'s
  registry (production) and `framework/inject/testing`'s registry
  (tests) — see **framework/inject** above. Production registers a real
  backing store (e.g. Firestore); testing registers an in-memory one.
  In-memory storage is never a production behavior — that's what the
  production/testing split enforces, not a naming nicety layered on top
  of one shared constructor.
- Tests live next to `interface.go`, resolve **this service's own**
  dependencies via `injecttesting.Get[X](t.Name())` — never mocks for
  those, and never construct the interface's implementation any other
  way (no local `impl.NewManager(...)` call, no hand-rolled fake structs
  in a `_test.go` file — see **Testing** for what replaces both). A
  dependency on *another service* resolves the same way, through that
  dependency's own `clients/<name>/module` — see **Testing**.

---

## Proto Layout

- All proto lives at `proto/` in the repo root — not nested under any
  one service — specifically so it's trivial to sync into client repos
  (web/mobile) independent of which service's release this proto change
  actually shipped with.
- Each deployable service corresponds to one (or more) proto service
  definitions. Splitting a service later means splitting its proto
  too — the two boundaries move together.
- The public `v1` wire namespace is what every service's `actions/`
  layer speaks, both to its own clients and to other services calling
  it. A service on the internal-proto pattern (see **Repository/Core
  Data Shape** above) additionally has its own internal-only proto
  namespace that its `repository/`/`core/` operate on instead — but
  that's a deliberate, human-approved exception per service, not the
  default for every service.

---

## Resource Names and Ownership

**Resource names are parsed to determine which service owns a
resource.** Each entity's owning service is fixed at creation and never
changes without an explicit transfer operation, so the name itself
(`accounts/{a}/orders/{o}`) already encodes routing information that's
permanently true — parsing it costs nothing, and it avoids both an
extra network hop and a shared ownership index (which would itself
violate no-shared-tables) just to answer "which service do I ask about
this."

If ownership can ever change after creation, that's an explicit
`Transfer` RPC on the owning service — never an implicit list update
somewhere else.

---

## Cross-Service Consistency (No Distributed Transactions)

There is no cross-service database transaction. A flow spanning two
services — e.g. debit a balance, then create a resource — writes to two
different services' own databases, and a crash between those two writes
is a real possibility that has to be designed for, not assumed away.

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
  `core/<domain>/`) are tested for real, through
  `injecttesting.Get[X](seed)` — no mocks, no hand-rolled fakes. Always
  resolve through the registry, never any other way — see below for
  what that rules out.
- **Another service's dependency** is tested against a real,
  in-memory-backed instance of that service too, not a mock: it's not a
  compromise, it's the point — see **framework/inject** above for the
  mechanism (an `inproc.Adapter` wired to the real `*actions.Server`
  that owning service registers for the same seed). **Hold the
  generated `critterv1connect.XServiceClient` interface directly as the
  dependency's type — never a hand-written interface wrapping it.**
  That generated interface already is the correct, minimal abstraction
  boundary; a hand-rolled one on top of it (`PaymentProcessor`,
  `CreatureReader`, whatever) is a redundant layer this codebase used
  to have and removed. This means a test exercises real business logic
  on both sides of a cross-service call, not a stand-in for either side
  — the adapter exists purely to satisfy the Go compiler on a genuine
  import cycle, never to change behavior.
- **A dependency that isn't a Connect service (a clock, a random-ID
  generator) goes through the same registry, not a separate mechanism**
  — the registry doesn't require a registered value to be stateless.
  `clients/clock` is the concrete pattern: production registers the real
  `clock.Client`, testing registers `clock/fake.FakeClient`, a small
  hand-written test double with a mutable `Time` field a test can flip
  mid-run (`Now()` reads it live, so setting it after construction is
  picked up by the code under test's very next call, no rebuild
  required) — resolved as `injecttesting.Get[clock.Clock](t.Name())`,
  then type-asserted back to `*fake.FakeClient` wherever a test needs to
  mutate `.Time` directly. One independent `FakeClient` per seed, same
  as everything else in the registry — never a shared, process-wide
  mutable singleton a test has to remember to reset.
- **A private helper method wrapping one RPC call is fine and expected
  — a shared type is not.** `core/<domain>/impl/manager.go` commonly
  has small unexported methods (`hold`, `confirm`, `getCreature`, ...)
  that build a `connect.NewRequest(...)`, call the generated client
  directly, and unwrap the response — purely for that one file's own
  readability, never imported by anything else. That's not "a library"
  in the sense this section warns against: it's unexported, lives in
  the one file that uses it, and every other manager with the same
  dependency writes its own copy rather than sharing one. The line is
  sharing an *implementation* across services, not writing a helper
  function at all.

**Every test seed is independent by construction, not by convention.**
`framework/inject/testing`'s registry keys every value by seed (`t.Name()`
is the normal seed), so two tests never observe each other's value and
there's nothing to reset between them — no `Reset()` call, no
`t.Cleanup`, and, unlike a shared hand-memoized singleton, genuinely
safe to run under `t.Parallel()` without extra care.

- Nothing in a test constructs `impl.NewXXX(...)` directly, and no test
  file defines its own fake/stub type for a dependency the registry
  already covers. Both are exactly what `framework/inject/testing` (for
  a service's own dependencies) and `clients/<name>` (for another
  service's) exist to centralize — a fake redefined per test file is the
  thing this whole convention removes.
- Any code reachable from a test — its own service's layers, and every
  dependency's — needs its `Register` call reachable too, or resolving
  it panics with "not registered." Blank-import the top-level `register`
  package (`_ "<module>/register"`) in every test file that calls
  `injecttesting.Get`, rather than curating a partial list of individual
  `module` imports — see **framework/inject** above for why a partial
  list is silently incomplete rather than a compile error, specifically
  for any cluster of services that depend on each other in a cycle.

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
