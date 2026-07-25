# Go Service Architecture

A Java-style hexagonal layering for a Go backend, split into three
layers — `repository/`, `core/`, `services/` — each with a narrow job.
Established for `Critter-Genetics-Breeder-Backend`; apply the same
shape to any new Go service in this workspace unless a project's own
README says otherwise.

---

## Highlights

- **Three layers, one direction of knowledge.** `repository/` → dumb
  CRUD. `core/` → all business logic, internal protos only. `services/`
  → thin orchestration, the only layer that touches `v1`/wire types.
- **`interface.go` / `impl/` / `module/` split**, for every `core/` and
  `repository/` package. `impl` imports its parent interface (for error
  sentinels); `module` imports both and is the only thing that could
  cause a cycle, so it lives in its own subpackage.
- **No interface propagates a dependency's error identity.** Every
  package declares only its own sentinel errors and wraps whatever a
  repository or another core package handed it — never returns that
  error raw.
- **Resource names are opaque keys.** Never parsed. Containment is
  parent-holds-child-reference; reverse lookups go through a
  repository-maintained index, never string surgery.
- **Validators run automatically** via a `connect.Interceptor` +
  type registry — no action ever calls a validator itself.
- **Converters are hand-written, fuzz-tested, and never fetch.** Callers
  gather everything first, then hand it to the converter.
- **Tests target interfaces, not impl**, using real in-memory
  repositories — no mocks unless a real one is genuinely impossible.

---

## Folder Structure

```
repository/
  <entity>/
    interface.go   # Repository interface + this package's own error sentinels
    impl/
      store.go      # in-memory (or real) implementation; imports parent for errors
    module/
      module.go      # NewXXXRepository() lazy singleton (sync.Once)
    <entity>_test.go # tests the interface, not impl/

core/
  <domain>/
    interface.go   # Manager interface + this package's own error sentinels
    impl/
      manager.go     # business logic; imports parent for errors, repos for storage
    module/
      module.go      # NewManager() lazy singleton, wires whatever this domain needs
    <domain>_test.go # tests the interface, using real repos (module.NewXXXRepository())

services/
  module.go        # NewXXXService() per service + NewValidationRegistry()
  <name>/
    <name>.go        # Server: thin orchestration, inline error-code mapping
    <name>_test.go
  converters/
    <entity>.go      # hand-written internal <-> v1, plus batch/list helpers
    <entity>_fuzz_test.go
  validation/
    registry.go      # generic Registry + connect.Interceptor (no domain knowledge)
  validations/
    XxxRequestValidator.go   # one per v1 request message, flat — not split by service
    XxxEntityValidator.go    # only if a request ever embeds a full entity message
```

---

## repository/ — Dumb Storage

- Accepts and returns **protos or basic Go types only** — never a
  custom Go struct.
- Verbs: `Get`, `Create`, `Update`, `Delete`, narrow `Add`/`Remove`
  patch-style mutators for containment lists, and `Find`-style reverse
  lookups. No business logic, no computed fields, no filtering beyond
  what a plain key lookup gives you — that composition lives in `core/`.
- Every method takes `ctx context.Context` as the first parameter, even
  though nothing uses it yet (transactions via
  `context.WithValue(ctx, txKey{}, tx)` are explicit future work — two
  independent repository writes in the same `core/` action are
  acceptable for now, since they'll share a transaction later).
- Defines and returns its own `ErrNotFound` / `ErrAlreadyExists` (etc.)
  in `interface.go` — no shared `repoerr` package. `impl/` imports the
  parent package directly to reference and return these.
- Defensive copies on read/write (e.g. `proto.Clone`) so callers can't
  mutate a stored entity by mutating what they got back.

## core/ — All Business Logic

- Operates exclusively on **internal-only proto entities**
  (`gen/.../internalpb/entities`) — never `v1`. `v1` is not imported
  anywhere under `core/`.
- Every cost formula, precondition check, threshold, and lazy-resolution
  rule lives here. A repository never decides anything; it only
  persists what `core/` computed.
- Every method takes `ctx context.Context`, unused for now, same reason
  as `repository/`.
- Defines its own error sentinels in `interface.go` for the same reason
  as `repository/` — see **Error Ownership** below.
- If a `core/` manager needs data assembled from several repositories,
  it fetches everything itself and returns it — a service's job is
  never to fetch-then-convert; `core/` hands back everything a
  converter needs in one call.
- A "special" or "QA-only" capability (e.g. a devtools force-complete
  action) is not a special `core/` package of its own — it's a normal
  capability on the domain it actually belongs to (e.g.
  `core/nest.Manager.ChangeBreedingTime`, reused by both a real "speed
  up" purchase and a QA action). Only the `services/` layer around it
  is special (not reachable by a release client).

## services/ — Thin Orchestration Only

- An action file is ~5 lines: validate (automatic, via the
  interceptor — never called explicitly), delegate to exactly one
  `core/` manager call, convert the result to `v1`, map errors. No
  mutation of any entity happens in `services/`.
- **Inline, duplicated error-code mapping per action** — no shared
  `errormap` package. Only map the specific sentinel errors this
  particular action actually expects to a non-Internal `connect.Code`;
  everything else falls through to `CodeInternal`. When genuinely
  unsure whether an error deserves a distinct code, leave it Internal —
  don't guess a mapping that might mask a real bug as a misleading
  client-facing code.
- Converters, validators, and the validation registry are **plain
  packages** — no `interface.go`/`impl/`/`module/` split. That split is
  reserved for `core/` and `repository/`.

---

## Error Ownership (read this before writing a return statement)

**No interface propagates a dependency's error identity — whether that
dependency is a repository or another `core` package.** A caller of
`core/nest.Manager` should never need to import `repository/player`,
`repository/creature`, or `core/player` to understand what error it
might get back. It only ever needs `core/nest`'s own sentinels.

Two cases, decided at the call site where a dependency's error comes
back:

1. **Caller-facing, on a resource named directly by the caller's own
   argument** (a nest/creature/player name passed straight into the
   method): wrap it into this package's own declared sentinel so
   identity survives, but ownership doesn't:
   ```go
   n, err := m.nests.Get(ctx, nestName)
   if err != nil {
       return nil, fmt.Errorf("%w: %v", nest.ErrNotFound, err)
   }
   ```
2. **Internal invariant violation** — a lookup on something the caller
   never directly named (an entity referenced only by another entity's
   own internal list, a second lookup on something already confirmed to
   exist a moment earlier). Wrap with `%v` only, no `%w`, no exported
   sentinel — the chain is deliberately broken so nothing upstream can
   match it to anything but `CodeInternal`:
   ```go
   owner, err := m.players.FindOwner(ctx, creatureName) // creature already confirmed to exist
   if err != nil {
       return fmt.Errorf("nest: owner of creature %q: %v", creatureName, err)
   }
   ```

**When genuinely unsure which case applies, treat it as case 2 —
internal is always a safe default.** A masked failure exposed as the
wrong error code is worse than an honest `CodeInternal`.

This means every `core/`/`repository/` package's `interface.go` ends up
with its own `ErrNotFound`, its own `ErrAlreadyExists`, its own
`ErrInsufficientFunds`, etc. — even when a sibling package already has
one with the same name and meaning. That duplication is intentional,
matching the same "each layer declares only what it directly returns"
principle as the error-code mapping rule above.

---

## interface.go / impl/ / module/ Split

Every `core/` and `repository/` package:

- **`interface.go`** — the only file that defines the exported
  interface type, and the only place this package's own error
  sentinels are declared. Nothing here imports `impl/` or `module/`.
- **`impl/`** — implements the interface. Imports the parent package
  (one directory up) to reference its error sentinels and to return the
  interface type from its constructor. This is safe (not a cycle)
  because `impl` importing its parent is one-directional as long as
  `interface.go` never imports `impl` back.
- **`module/`** — a separate subpackage (not folded into either of the
  above) exporting `NewXXX()`, memoized with `sync.Once` into a
  process-wide lazy singleton. It has to be its own subpackage because
  it imports *both* the interface package (for the type) and `impl`
  (for the constructor) — putting it in either of those would create
  the cycle `impl` importing its parent was designed to avoid.
  ```go
  // core/player/module/module.go
  package module

  import (
      "sync"
      "github.com/.../core/player"
      "github.com/.../core/player/impl"
      repoplayermodule "github.com/.../repository/player/module"
  )

  var (
      once     sync.Once
      instance player.Manager
  )

  func NewManager() player.Manager {
      once.Do(func() {
          instance = impl.NewManager(repoplayermodule.NewPlayerRepository())
      })
      return instance
  }
  ```
- Dependencies wire by hand: a `module.go` calls whatever other
  `core`/`repository` `NewXXX()` functions it needs. No central DI
  container — the graph self-assembles the first time `main.go` (via
  `services/module.go`) asks for a top-level service.
- **Tests live next to `interface.go`**, in the package's own directory
  (`<name>_test.go`, package `<name>_test`), and go through
  `<name>module.NewXXX()` — never through `impl` directly. They use
  real in-memory repositories via their own `module.NewXXX()`, not
  mocks, unless a real dependency is genuinely impossible to construct
  in a test.

---

## Proto Namespace Split

- An **internal-only proto namespace** (e.g. `proto/critter/internalpb/`,
  generated to `gen/.../internalpb/entities`) holds every entity
  `repository/` and `core/` operate on. It is never a release client's
  concern and must never be synced into a client repo (web/mobile) —
  scope any proto-sync tooling to the public `v1` tree only.
- The **public wire proto** (`v1`) is imported only from `services/`.
- `services/converters/` is the one seam where both namespaces are in
  scope. Converters:
  - Are hand-written (redaction/special-case logic can't be generated).
  - Provide **batch/list APIs** (`XxxToV1([]internal) []*v1X`) so no
    caller ever for-loops a conversion itself.
  - **Never fetch.** A converter takes exactly the data it needs as
    parameters; assembling that data (e.g. fetching a nest's occupant
    creatures) is `core/`'s job, done inside the manager method that
    returns the nest, not a service-layer helper and not the converter.
  - Are round-trip fuzz-tested: generate a random proto (e.g. via
    `protorand`), convert `a -> b -> a` and `b -> a -> b`, compare with
    a structural, proto-aware diff (e.g. `protocmp` + `go-cmp`). Any
    field requiring special handling (like redacting an unrevealed
    locus's alleles) is cleaned up explicitly in the test — deliberately
    not silently skipped — so a newly added field with no explicit
    handling makes the fuzz test fail loudly instead of passing by
    accident.

---

## Validation

- One `Validator` per `v1` request message type, in a **flat**
  `services/validations/` package: `XxxRequestValidator.go` — not split
  into a subpackage per service. If a request ever embeds a full entity
  message, its validation delegates to a matching
  `XxxEntityValidator.go` in the same flat package.
- The registry and interceptor mechanism (`services/validation/`,
  singular) is generic and has no domain knowledge: a
  `map[reflect.Type]Validator` plus a `connect.Interceptor` that looks
  up and runs the right validator before every RPC. Every request type
  gets one registered — even a trivially-always-valid one — so a
  missing validator is a loud `CodeInternal` wiring bug, never a silent
  skip.
- Format checks (resource-name shape, non-empty checks, etc.) are
  inlined per validator — no shared regex/shape-checking helper. A
  three-line check isn't worth extracting.

---

## Resource Names and Containment

- Resource names (`players/{p}`, `players/{p}/creatures/{c}`, …) are
  **opaque keys everywhere** — never parsed to derive a parent or
  owner, in `repository/`, `core/`, or `services/`.
- Containment is a strict tree, decided by which side can have "many":
  a parent stores its children's name references; a child never stores
  a reference back to its parent. Two independent containment
  relationships can coexist on the same entity (e.g. a `Player`'s
  *permanent* ownership list vs. a `Nest`'s *temporary* placement list)
  — don't collapse them into one.
- Reverse lookups ("who owns this child") go through a
  repository-maintained reverse index (e.g. `PlayerRepository.FindOwner`),
  populated at write time by whichever method adds the containment
  link — never a string-parse of the child's own name, and never a full
  table scan.
