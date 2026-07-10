# Integration Test Errors — `full_test_app`

> Collected by running the dummy app's test suite. Updated whenever the
> integration tests are run. Companion to `NEXT_STEPS.md` (RESUME HERE →
> "Route-coverage integration test").
>
> Run the route-coverage test with:
> ```sh
> cd full_test_app && bin/rails test test/integration/all_routes_test.rb
> ```

## Current status

- **`test/integration/all_routes_test.rb`** — four tests:
  1. *Route auto-loop* — GETs every controller-backed route (Devise GET pages,
     `posts` index/show/new/edit, `rails/health`, root), signs in a user, and
     fails on any route returning HTTP `>= 500` or raising.
  2. *Devise auth flow* — drives the real flow: `GET /users/sign_in` (form),
     `POST /users/sign_in` with valid credentials (Warden session write),
     `DELETE /users/sign_out`.
  3. *Create/delete post* — `POST /posts` (DB write) and `DELETE /posts/:id`.
  4. *Edit/update post* — `GET /posts/:id/edit` and `PATCH /posts/:id`.
  5. *New post form* — `GET /posts/new` (renders the `form_with`).
  **Result: 5 runs, 18 assertions, 0 failures, 0 errors.** No route-level
  errors in the dummy app at this time.
- **`bin/rails test` (whole suite)** — **7 runs, 20 assertions, 0 failures,
  0 errors** (incl. the 5 integration tests + trimmed `posts_controller_test`).
  Both recorded errors (E1, E2) are now FIXED (see below).

## Error → solution pairs

### Error #1 — `ActiveRecord::RecordNotUnique` on `index_users_on_email` (fixture collision) — FIXED

- **Symptom:**
  ```
  ActiveRecord::RecordNotUnique: PG::UniqueViolation: ERROR:  duplicate key
  value violates unique constraint "index_users_on_email"
  DETAIL:  Key (email)=() already exists.
  ```
  Raised in `before_setup` → `load_fixtures`, so **every** test that inherits
  `fixtures :all` (`posts_controller_test.rb`, `post_test.rb`, `user_test.rb`)
  errors out before its body runs. The route-coverage test is immune because it
  opts out of shared fixtures.

- **Root cause:** `test/fixtures/users.yml` defines empty records:
  ```yaml
  one: {}
  two: {}
  ```
  Devise `:validatable` adds a **unique** DB index on `email`. Empty fixtures
  insert `email=''`/NULL; on a dirty test DB (leftover rows) the insert
  collides, and even on a clean DB the two empty fixtures collide with each
  other on the unique index. `test/test_helper.rb` calls `fixtures :all`, so
  the crash happens for the whole suite.

- **Solution:**
  - The new `test/integration/all_routes_test.rb` already avoids this: it sets
    `self.fixture_table_names = []` and creates its own `User`/`Post` inline.
  - To make the rest of the suite green, either:
    1. Give `users.yml` real unique emails + passwords, e.g.
       ```yaml
       one:
         email: "one@example.com"
         password: "password"
         password_confirmation: "password"
       two:
         email: "two@example.com"
         password: "password"
         password_confirmation: "password"
       ```
    2. Or trim `posts_controller_test.rb` to only the routes that exist
       (`index`/`show` — `resources :posts, only: %i[index show]`), since its
       `new`/`create`/`edit`/`update`/`destroy` tests target actions that are
       not routed and would 404.

- **Fix applied:** `test/fixtures/users.yml` now provides real unique
  `email` values plus `encrypted_password` via
  `Devise::Encryptor.digest(User, "password")` (Rails fixtures support ERB).
  The `{}`-style empty fixtures are gone, so `fixtures :all` loads cleanly.

### Error #2 — stale `posts_controller_test.rb` targets non-existent actions — FIXED

- **Symptom (once fixtures load):** `should get new`, `should create post`,
  `should get edit`, `should update post`, `should destroy post` would 404 /
  routing-error because `config/routes.rb` only defines
  `resources :posts, only: %i[index show]`.

- **Root cause:** scaffold-generated controller test not kept in sync with the
  trimmed routes.

- **Solution:** delete those 5 tests (or the whole file if only used as a
  scaffold sample) and keep the route-coverage integration test as the source
  of truth for "do all routes work?".

- **Fix applied:** `test/controllers/posts_controller_test.rb` now contains
  only `should get index` and `should show post` (matching
  `resources :posts, only: %i[index show]`). The new/create/edit/update/
  destroy tests were removed.

## Notes

- The route-coverage test runs in the **main Ractor** (normal Rails test
  process), so it catches ordinary route/controller/view errors (500s,
  exceptions) but **not** Ractor-isolation errors. To catch isolation errors in
  a worker Ractor, use `verify_blockers.rb` / `kino -m ractor` per
  `NEXT_STEPS.md` (RESUME HERE → "How to reproduce").
- 19 controller-backed routes are exercised per run (verified by counting
  `Rails.application.routes.routes` entries with `defaults[:controller]`).
