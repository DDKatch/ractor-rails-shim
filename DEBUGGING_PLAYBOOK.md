# Debugging Playbook: Ractor-Isolation Errors in Rails

A reproducible methodology for resolving `Ractor::IsolationError` and
`Ractor::UnsafeError` in Rails internals. Written from the session that
cleared 10+ blockers in the ActiveRecord query path, taking `Post.count`
from "dies at PoolConfig::INSTANCES" to "returns 10 in a worker Ractor."

This document teaches the **loop**: error → read source → classify →
patch → verify → next error. Any AI engine can follow it.

---

## The Core Loop (repeat until done)

```
1. RUN the failing operation in a worker Ractor
2. READ the full backtrace — find the FIRST frame in Rails/gem source
3. OPEN that source file at that line number
4. CLASSIFY the blocker (see Classification Guide below)
5. WRITE a patch using the matching pattern (see Pattern Catalog)
6. REGISTER the patch in prepare_for_actors!
7. RUN the operation again — it either works or reveals the NEXT wall
8. GO TO step 2
```

**Key principle:** never try to fix more than one wall at a time. Each
iteration removes exactly one blocker. The next one reveals itself when
you re-run. This is faster than trying to predict all walls upfront.

**Key principle:** always verify in a worker Ractor, not in main. A
patch that works in main but not in a worker is useless. The minimal
test case is always: `Ractor.new { <operation> }.value`.

---

## Step-by-Step Walkthrough (Real Example)

### Iteration 1: PoolConfig::INSTANCES

**Step 1 — Run:** `Post.count` in a worker Ractor.

**Step 2 — Read the backtrace:**
```
Ractor::IsolationError: can not access non-shareable objects in constant
  ActiveRecord::ConnectionAdapters::PoolConfig::INSTANCES by non-main ractor.
.../pool_config.rb:36:in 'PoolConfig#initialize'
.../connection_handler.rb:277:in 'resolve_pool_config'
.../connection_handler.rb:118:in 'establish_connection'
```

**Step 3 — Open the source:**
```ruby
# activerecord/lib/active_record/connection_adapters/pool_config.rb
INSTANCES = ObjectSpace::WeakMap.new
private_constant :INSTANCES

def initialize(connection_class, db_config, role, shard)
  super()
  @server_version = nil
  self.connection_descriptor = connection_class
  @db_config = db_config
  @role = role
  @shard = shard
  @pool = nil
  INSTANCES[self] = self   # <-- LINE 36: the failing line
end
```

**Step 4 — Classify:** The backtrace says "can not access non-shareable
objects in **constant** ... by non-main ractor." The failing line reads a
**constant** (`INSTANCES`) whose value is an `ObjectSpace::WeakMap`.
WeakMaps are intrinsically unshareable (no `#freeze`).

Classification: **unshareable constant, write-side**. The constant is
read AND written to (`INSTANCES[self] = self`). But the write is only
needed for `disconnect_all!`/`discard_pools!` (reloading), which never
runs in a read-only production worker.

**Step 5 — Write the patch:** Skip the write in non-main Ractors.
```ruby
def _install_activerecord_pool_config_patch
  return if @ar_pool_config_patched
  @ar_pool_config_patched = true
  _register_patch :activerecord_pool_config, "8.1"
  return unless defined?(::ActiveRecord::ConnectionAdapters::PoolConfig)

  ::ActiveRecord::ConnectionAdapters::PoolConfig.class_eval <<-RUBY, __FILE__, __LINE__ + 1
    def initialize(connection_class, db_config, role, shard)
      super()
      @server_version = nil
      self.connection_descriptor = connection_class
      @db_config = db_config
      @role = role
      @shard = shard
      @pool = nil
      INSTANCES[self] = self if Ractor.main?
    end
  RUBY
end
```

**Key decisions:**
- `Ractor.main?` guard — the write is safe and useful in main; skip it in workers.
- `class_eval` with a STRING (heredoc), NOT `define_method` with a block.
  Blocks capture the defining Ractor's binding and can't be called from
  other Ractors. String eval produces methods with no captured binding.
- Replicate the original method body EXACTLY, changing only the one line.
  Don't refactor — that introduces bugs.

**Step 6 — Register:**
```ruby
# core.rb, in prepare_for_actors!
_install_activerecord_pool_config_patch
```

**Step 7 — Run again:** `Post.count` now gets past PoolConfig and dies at
the next wall (Reaper.register_pool). Go to step 2.

### Iteration 2: Reaper.register_pool

**Step 2 — Read:**
```
Ractor::IsolationError: can not get unshareable values from instance
  variables of classes/modules from non-main Ractors (@mutex from
  ActiveRecord::ConnectionAdapters::ConnectionPool::Reaper)
.../reaper.rb:47:in 'Reaper.register_pool'
.../reaper.rb:112:in 'Reaper#run'
.../connection_pool.rb:307:in 'ConnectionPool#initialize'
```

**Step 3 — Open:**
```ruby
# reaper.rb
class Reaper
  @mutex = Mutex.new
  @pools = {}
  @threads = {}

  def self.register_pool(pool, frequency)
    @mutex.synchronize do
      unless @threads[frequency]&.alive?
        @threads[frequency] = spawn_thread(frequency)
      end
      @pools[frequency] ||= []
      @pools[frequency] << WeakRef.new(pool)
    end
  end

  def run
    return unless frequency && frequency > 0
    self.class.register_pool(pool, frequency)  # <-- only caller
  end
end
```

**Step 4 — Classify:** The error says "instance variables of
classes/modules" — that's a **class instance variable** read. `@mutex`,
`@pools`, `@threads` are class ivars on `Reaper`. They're lazily used to
register pools for background reaping (dead-thread cleanup, idle
flushing). In a worker Ractor, the reaper thread isn't needed: each
Ractor owns its pool, and when the Ractor exits the pool is GC'd.

Classification: **class ivar, side-effect (not core logic)**. The reaper
is a background maintenance feature. No-op'ing it in workers is safe.

**Step 5 — Patch:** No-op `Reaper#run` in non-main Ractors. Patch the
instance method (not the class method) because `run` is the only caller
of `register_pool`.
```ruby
::ActiveRecord::ConnectionAdapters::ConnectionPool::Reaper.class_eval <<-RUBY, __FILE__, __LINE__ + 1
  def run
    return unless frequency && frequency > 0
    return unless Ractor.main?
    self.class.register_pool(pool, frequency)
  end
RUBY
```

**Step 7 — Run again:** Next wall is `Arel::Visitors::Visitor.dispatch_cache`.

### Iteration 3: Arel dispatch_cache (lazy class ivar with default Proc)

**Step 2 — Read:**
```
Ractor::IsolationError: can not set instance variables of classes/modules
  by non-main Ractors
.../arel/visitors/visitor.rb:18:in 'Visitor.dispatch_cache'
.../visitor.rb:24:in 'Visitor#get_dispatch_cache'
.../visitor.rb:7:in 'Visitor#initialize'
.../to_sql.rb:13:in 'ToSql#initialize'
```

**Step 3 — Open:**
```ruby
# arel/visitors/visitor.rb
class Visitor
  def initialize
    @dispatch = get_dispatch_cache
  end

  private
  def self.dispatch_cache
    @dispatch_cache ||= Hash.new do |hash, klass|
      hash[klass] = :"visit_#{(klass.name || "").gsub("::", "_")}"
    end.compare_by_identity
  end

  def get_dispatch_cache
    self.class.dispatch_cache
  end
end
```

**Step 4 — Classify:** `@dispatch_cache ||= ...` — a **lazy class ivar
with a default Proc**. The `||=` writes the class ivar (fails in
workers). The Hash has a `default_proc` (captures a binding →
intrinsically unshareable), so we can't freeze + share the value.

Classification: **lazy class ivar, per-Ractor cache**. Each Ractor needs
its own mutable Hash (with its own default proc). Route through IES so
each Ractor builds and caches its own.

**Step 5 — Patch:**
```ruby
::Arel::Visitors::Visitor.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
  def dispatch_cache
    key = :"ractor_rails_shim_arel_dispatch_\#{name || object_id}"
    v = ActiveSupport::IsolatedExecutionState[key]
    return v if v
    cache = Hash.new do |hash, klass|
      hash[klass] = :"visit_\#{(klass.name || "").gsub("::", "_")}"
    end.compare_by_identity
    ActiveSupport::IsolatedExecutionState[key] = cache
    cache
  end
RUBY
```

**Key decisions:**
- IES key includes `self.name` so each visitor subclass (ToSql, SQLite3,
  PostgreSQL) gets its own cache. This matters because the
  method-not-found fallback (`dispatch[object.class] = dispatch[superklass]`)
  resolves differently per visitor class.
- `singleton_class.module_eval` (not `class_eval`) because `dispatch_cache`
  is a class method.

---

## Classification Guide

Every `Ractor::IsolationError` falls into one of these categories. The
error message tells you which:

### 1. "can not **access** non-shareable objects in **constant** X"

A **constant** whose value is unshareable (mutable Array/Hash, Mutex,
Concurrent::Map, WeakMap, Proc, BasicObject).

**Sub-patterns:**

| Value type | Solution |
|---|---|
| Mutable Array/Hash/Set | `Ractor.make_shareable(val)` + `const_set` (deep-freeze) |
| Mutex/Monitor | Replace with `NoOpLock` |
| Concurrent::Map | Replace with frozen Hash (read-only) or route through IES (writable) |
| WeakMap | Skip the write in workers (if it's a registry); can't be frozen |
| Proc | Replace with a shareable Callable object |
| BasicObject | Replace with a frozen Symbol sentinel |

Register the constant path in `SHAREABLE_CONSTANTS` (if it can be
deep-frozen) OR patch the method that reads it (if it needs a Callable
replacement or a different approach).

### 2. "can not **get**/**set** instance variables of classes/modules"

A **class instance variable** (`@foo` on a class/module, not `@@foo`).
Class ivars are per-Ractor: main's `@foo` is invisible to workers, and
workers can't write their own.

**Sub-patterns:**

| Pattern | Example | Solution |
|---|---|---|
| Lazy cache `@x ||= compute` | `dispatch_cache`, `uncacheable_methods` | Route through IES (each Ractor builds its own) |
| `attr_accessor` on singleton | `query_transformers`, `schema_cache_ignored_tables` | IES routing + shareable fallback (main's value captured at boot) |
| Sentinel check `@x == SENTINEL` | `primary_key` vs `PRIMARY_KEY_NOT_SET` | Shareable snapshot (capture real values in main; workers read the snapshot) |
| Side-effect ivar (not core logic) | `Reaper.@mutex/@pools` | No-op the method that touches it in workers |

### 3. "can not access class variables from non-main Ractors"

A **class variable** (`@@foo`). Same isolation rules as class ivars.

**Solution:** Route through IES using `class_variable_get`/`class_variable_set`
(NOT `@@foo` directly in `module_eval` strings — class vars don't resolve
through `singleton_class.module_eval`).

```ruby
# WRONG (NameError: uninitialized class variable @@configurations):
ActiveRecord::Base.singleton_class.module_eval <<-RUBY
  def configurations
    @@configurations  # resolves in RactorRailsShim, not ActiveRecord::Core!
  end
RUBY

# RIGHT:
ActiveRecord::Base.singleton_class.module_eval <<-RUBY
  def configurations
    ActiveRecord::Core.class_variable_get(:@@configurations)
  end
RUBY
```

### 4. "allocator undefined for Proc" / "Proc's self is not shareable"

A **Proc** that captures an unshareable binding or `self`. Procs cannot
cross Ractor boundaries at all.

**Solution:** Replace with a shareable Callable object (an object with a
`call` method, holding references via ivars, made shareable via
`Ractor.make_shareable`).

```ruby
# Original (Proc, unshareable):
BIND_BLOCK = proc { |i| "$#{i}" }

# Replacement (shareable Callable):
PgBindBlock = Ractor.make_shareable(Object.new.tap do |o|
  def o.call(i); "$#{i}"; end
end)

# Patch the method that returns the constant:
Arel::Visitors::PostgreSQL.module_eval <<-RUBY, __FILE__, __LINE__ + 1
  def bind_block
    RactorRailsShim::PgBindBlock
  end
RUBY
```

### 5. "ractor unsafe method called from not main ractor" (Ractor::UnsafeError)

A **C extension method** that hasn't declared ractor-safety via
`rb_ext_ractor_safe()`. This is a **gem-level** issue, not a Rails issue.

**Diagnosis:** Test the gem in isolation:
```ruby
Ractor.new { SQLite3::Database.new(":memory:") }.value
# => Ractor::UnsafeError (gem is ractor-unsafe)
# vs
Ractor.new { PG.connect(dbname: "postgres"); ... }.value
# => OK (gem declared rb_ext_ractor_safe)
```

**Solution:** You cannot fix this from the shim. Either:
- Use a ractor-safe alternative gem (e.g., `pg` instead of `sqlite3`)
- Open an issue/PR on the gem to add `rb_ext_ractor_safe()`

---

## Pattern Catalog (Copy-Paste Templates)

### Pattern A: IES routing for lazy class ivar (`@x ||= compute`)

```ruby
def _install_X_patch
  return if @x_patched
  @x_patched = true
  _register_patch :x, "8.1"
  return unless defined?(::TargetClass)

  ::TargetClass.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
    def method_name
      key = :"ractor_rails_shim_method_name_\#{name || object_id}"
      v = ActiveSupport::IsolatedExecutionState[key]
      return v unless v.nil?
      result = <REPLICATE THE COMPUTATION HERE>
      ActiveSupport::IsolatedExecutionState[key] = result
      result
    end
  RUBY
end
```

**When to use:** The ivar is a per-class cache that's computed
deterministically. Each Ractor rebuilds its own copy.

**Critical:** Include `\#{name || object_id}` in the IES key when the
method is on a module that multiple classes include (each class needs
its own cache entry).

### Pattern B: IES routing + shareable fallback (`attr_accessor` on singleton)

```ruby
def _install_X_patch
  return if @x_patched
  @x_patched = true
  _register_patch :x, "8.1"
  return unless defined?(::TargetClass)

  # Capture main's value as a shareable snapshot BEFORE patching.
  if Ractor.main?
    begin
      val = ::TargetClass.method_name
      shareable = Ractor.make_shareable(val.dup)
      verbose, $VERBOSE = $VERBOSE, nil
      const_set(:X_SHAREABLE, shareable)
    ensure
      $VERBOSE = verbose
    end
  end

  key = :ractor_rails_shim_x
  key_str = key.inspect
  ::TargetClass.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
    def method_name
      v = ActiveSupport::IsolatedExecutionState[#{key_str}]
      return v unless v.nil?
      if Ractor.main?
        @method_name
      else
        RactorRailsShim::X_SHAREABLE
      end
    end
    def method_name=(val)
      ActiveSupport::IsolatedExecutionState[#{key_str}] = val
      @method_name = val if Ractor.main?
    end
  RUBY
end
```

**When to use:** The value is set once at boot (in main) and read by
workers. Workers need the same value (not a recomputed one).

**Critical:** Capture the value BEFORE the `module_eval` — the override
shadows the original reader, so reading after the patch returns nil.

### Pattern C: Shareable snapshot (sentinel-based lazy ivar)

```ruby
def _install_X_patch
  # ... (capture each class's real value into a frozen Hash in main)
  pk_map = {}
  classes.each { |klass| pk_map[klass.name] = klass.primary_key rescue next }
  const_set(:X_SHAREABLE, Ractor.make_shareable(pk_map))

  ::TargetClass.module_eval <<-RUBY, __FILE__, __LINE__ + 1
    def method_name
      key = :"ractor_rails_shim_method_name_\#{name}"
      v = ActiveSupport::IsolatedExecutionState[key]
      return v unless v.nil?
      if Ractor.main?
        # original logic here
      else
        RactorRailsShim::X_SHAREABLE[name]
      end
    end
  RUBY
end
```

**When to use:** The original code checks `@x == SENTINEL` (e.g.,
`PRIMARY_KEY_NOT_SET.equal?(@primary_key)`) where the sentinel is a
BasicObject that can't be frozen. Workers can't read the sentinel
constant, so patch the method to avoid it entirely.

### Pattern D: No-op in non-main Ractors

```ruby
::TargetClass.class_eval <<-RUBY, __FILE__, __LINE__ + 1
  def method_name
    return unless Ractor.main?
    # original logic here
  end
RUBY
```

**When to use:** The method has side effects (thread spawning, registry
writes) that are only useful in main. Workers don't need the
functionality.

### Pattern E: Method redefinition for unshareable constant

```ruby
::TargetClass::SubModule.module_eval <<-RUBY, __FILE__, __LINE__ + 1
  def method_name(name)
    key = :"ractor_rails_shim_cache_\#{self.name}"
    cache = ActiveSupport::IsolatedExecutionState[key]
    cache ||= (ActiveSupport::IsolatedExecutionState[key] = {})
    cache[name] ||= (<REPLICATE THE QUOTING/COMPUTATION LOGIC>)
  end
RUBY
```

**When to use:** The original method reads a `Concurrent::Map` constant
directly (`MAP[name] ||= compute`). Redefine the method to use a
per-Ractor Hash via IES instead.

**Critical:** Replicate the computation logic EXACTLY. For quoting, each
adapter (SQLite3, MySQL, PostgreSQL) has different quoting rules. Read
the original source for each.

---

## The Debug Probe (Minimal Reproduction)

Always isolate the failure to the smallest possible operation. Don't
debug through a full HTTP request — debug the data layer directly.

### Data-layer probe (no HTTP, no server):

```ruby
# debug_post_count.rb
ENV["RAILS_ENV"] = "production"
ENV["SECRET_KEY_BASE"] = "dummy"
require File.expand_path("config/boot")
require File.expand_path("config/application")
Bundler.require(*Rails.groups)
Rails.application.initialize!
RactorRailsShim.prepare_for_ractors!
app = RactorRailsShim.make_app_shareable!(Rails.application)

result = Ractor.new(app) do |a|
  RactorRailsShim.init_worker_ar_connections!
  Post.count  # the operation under test
rescue => e
  root = e; root = root.cause while root.respond_to?(:cause) && root.cause
  "ERR #{e.class}: #{e.message[0,200]}\nROOT: #{root.class}: #{root.message[0,200]}\n#{(root.backtrace || []).first(20).join("\n")}"
end.value

puts result
```

Run it:
```sh
RAILS_ENV=production SECRET_KEY_BASE=dummy bundle exec ruby debug_post_count.rb
```

The output gives you the exact error class, message, and backtrace. The
FIRST frame in Rails/gem source (not your code) is the wall.

### Incremental verification:

After each patch, re-run the SAME probe. If it returns a different
error, you broke through that wall. If it returns the same error, your
patch didn't apply (check registration in `prepare_for_ractors!`).

### Full verification (all data-layer operations):

```ruby
result = Ractor.new(app) do |a|
  RactorRailsShim.init_worker_ar_connections!
  out = {}
  out[:count] = Post.count
  out[:first] = Post.first&.attributes&.inspect[0,100]
  out[:all] = Post.all.to_a.size
  out[:page] = Post.page(1).per(10).to_a.size if defined?(Kaminari)
  out
rescue => e
  # ... (same error capture as above)
end.value
```

---

## Anti-Patterns (What NOT to Do)

### 1. DON'T use `define_method` with a block

```ruby
# WRONG — the block captures the defining Ractor's binding:
TargetClass.define_method(:foo) { |x| @bar }

# RIGHT — string eval produces a method with no captured binding:
TargetClass.module_eval <<-RUBY, __FILE__, __LINE__ + 1
  def foo(x)
    @bar
  end
RUBY
```

### 2. DON'T try to fix multiple walls at once

Predicting the next wall is unreliable — Rails' call paths branch. Fix
one, run, see the next. The loop is faster than guessing.

### 3. DON'T refactor while patching

Replicate the original method body EXACTLY, changing only the one line
that causes the error. Renaming variables, extracting helpers, or
"improving" the code introduces bugs that are hard to find in
cross-Ractor code.

### 4. DON'T forget to register the patch

```ruby
# core.rb, in prepare_for_actors!:
def prepare_for_actors!
  # ... existing patches ...
  _install_your_new_patch  # <-- ADD THIS LINE
end
```

If you forget, the patch is defined but never applied. The error doesn't
change and you waste time wondering why.

### 5. DON'T use `@@class_var` inside `module_eval` strings

Class variables don't resolve through `singleton_class.module_eval` —
they resolve in the scope of the module that calls `module_eval`, not
the target class. Use `class_variable_get`/`class_variable_set` with
explicit class references:

```ruby
# WRONG:
ActiveRecord::Base.singleton_class.module_eval <<-RUBY
  def configurations
    @@configurations  # NameError: uninitialized in RactorRailsShim!
  end
RUBY

# RIGHT:
ActiveRecord::Base.singleton_class.module_eval <<-RUBY
  def configurations
    ActiveRecord::Core.class_variable_get(:@@configurations)
  end
RUBY
```

### 6. DON'T capture the value AFTER patching the method

```ruby
# WRONG — the override shadows the original reader, returns nil:
TargetClass.singleton_class.module_eval <<-RUBY
  def foo
    # ... new implementation that reads @foo ...
  end
RUBY
orig = TargetClass.foo  # nil! The override doesn't read the old @foo.

# RIGHT — capture BEFORE patching:
orig = TargetClass.foo  # reads the original, returns the real value
TargetClass.singleton_class.module_eval <<-RUBY
  def foo
    # ... new implementation ...
  end
RUBY
```

### 7. DON'T assume BasicObject has Kernel methods

`BasicObject` doesn't include `Kernel`. It has no `is_a?`,
`respond_to?`, `freeze`, `inspect`, `class`, or `to_s`. Any code that
walks object graphs must guard:

```ruby
# WRONG:
if val.is_a?(::Monitor)  # NoMethodError if val is a BasicObject

# RIGHT:
if (val.is_a?(::Monitor) rescue false)
```

---

## Decision Tree

```
Got an error in a worker Ractor?
│
├─ Ractor::UnsafeError ("ractor unsafe method called")?
│   └─ C extension is not ractor-safe. Test the gem in isolation.
│      Can't fix from the shim. Use a different gem or upstream PR.
│
├─ Ractor::IsolationError?
│   │
│   ├─ Message mentions "constant"?
│   │   └─ Read the constant's value.
│   │      ├─ Mutable Array/Hash → make_shareable + const_set
│   │      ├─ Mutex/Monitor → NoOpLock
│   │      ├─ Concurrent::Map → frozen Hash OR IES routing
│   │      ├─ WeakMap → skip write in workers
│   │      ├─ Proc → shareable Callable replacement
│   │      └─ BasicObject → frozen Symbol sentinel OR avoid the constant
│   │
│   ├─ Message mentions "instance variables of classes/modules"?
│   │   └─ It's a class instance variable (@foo on a class).
│   │      ├─ Pattern is `@x ||= compute` → IES routing (Pattern A)
│   │      ├─ Pattern is `attr_accessor` → IES + shareable fallback (Pattern B)
│   │      ├─ Pattern is `@x == SENTINEL` → shareable snapshot (Pattern C)
│   │      └─ Method has side effects → no-op in workers (Pattern D)
│   │
│   └─ Message mentions "class variables"?
│       └─ It's a class variable (@@foo). Route through IES using
│          class_variable_get/set (NOT @@foo in module_eval strings).
│
├─ TypeError ("allocator undefined for Proc")?
│   └─ A Proc is being passed to a Ractor. Replace with a Callable.
│
└─ FrozenError ("can't modify frozen ...")?
    └─ The object was deep-frozen by make_shareable but code tries to
       mutate it. Either: warm the ivar before freezing (compute the
       lazy value in main), or route the mutation through IES.
```

---

## Checklist for Each Patch

- [ ] Read the source at the failing line (don't guess)
- [ ] Classified the blocker type (constant / class ivar / class var / Proc / C ext)
- [ ] Chose the matching pattern (A / B / C / D / E)
- [ ] Wrote the patch using `module_eval` with STRING (not `define_method`)
- [ ] Replicated the original method body exactly (no refactoring)
- [ ] Registered the patch in `prepare_for_ractors!` (core.rb)
- [ ] Ran the debug probe — error changed or resolved
- [ ] If resolved, ran the full verification probe (count + first + all + page)
- [ ] Ran unit specs (`bundle exec rake spec`) — 61/61 pass

---

## Why This Loop Works

Each Ractor isolation error is a single point failure: one specific line
of Rails source code reads/writes one specific unshareable thing. The
backtrace tells you exactly which line. You fix that one line, re-run,
and the next point failure reveals itself.

You cannot predict the sequence of walls in advance because Rails' call
paths branch (e.g., `Post.count` might hit `dispatch_cache` before
`quote_table_name`, but `Post.first` hits them in a different order, and
`Post.page(1)` adds the `uncacheable_methods` wall). The iterative loop
is the only reliable approach.

The loop is also self-verifying: if your patch is wrong, the error
doesn't change (or you get a new error at the SAME line, meaning the
patch didn't apply). If the error moves to a LATER line, the patch
worked. This binary feedback makes it easy to know when to move on.
