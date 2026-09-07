#!/usr/bin/env bash
# Self-check for surface.sh. Run: bash surface.test.sh
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/surface.sh"
fails=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else
    echo "FAIL - $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}

diff1='diff --git a/src/api.ts b/src/api.ts
--- a/src/api.ts
+++ b/src/api.ts
@@ -1,4 +1,4 @@
-export function handle(id: string) {
+export function handle(id: string, opts?: Opts) {
   const local = 1;
-  const removedLocal = 2;
+  const renamedLocal = 2;
   return id;
 }'

out="$(printf '%s' "$diff1" | bash "$script")"
check "emits the changed path" "src/api.ts" "$(printf '%s' "$out" | jq -r '.paths[0]')"
check "captures the altered signature" 1 \
  "$(printf '%s' "$out" | jq '[.entries[] | select(.name == "handle")] | length')"
check "signature marked altered" altered \
  "$(printf '%s' "$out" | jq -r '.entries[] | select(.name=="handle") | .change')"
check "keeps the before signature" yes \
  "$(printf '%s' "$out" | jq -r '.entries[] | select(.name=="handle") | .before' \
     | grep -q 'id: string)' && echo yes || echo no)"
check "keeps the after signature" yes \
  "$(printf '%s' "$out" | jq -r '.entries[] | select(.name=="handle") | .after' \
     | grep -q 'opts?: Opts' && echo yes || echo no)"
check "local variables are not entries" 0 \
  "$(printf '%s' "$out" | jq '[.entries[] | select(.name | test("Local"))] | length')"

# A route registration and a config key live inside bodies but are reachable.
diff2='diff --git a/src/server.py b/src/server.py
--- a/src/server.py
+++ b/src/server.py
@@ -1,3 +1,4 @@
+app.route("/api/v2/users")
+TIMEOUT = os.environ["REQUEST_TIMEOUT_MS"]
 def helper():
     pass'

out2="$(printf '%s' "$diff2" | bash "$script")"
check "route path captured" 1 \
  "$(printf '%s' "$out2" | jq '[.entries[] | select(.kind == "route")] | length')"
check "env var captured" 1 \
  "$(printf '%s' "$out2" | jq '[.entries[] | select(.kind == "env")] | length')"

# Added and removed declarations get the right change label.
diff3='diff --git a/lib/m.go b/lib/m.go
--- a/lib/m.go
+++ b/lib/m.go
@@ -1,3 +1,3 @@
-func OldName(a int) error {
+func NewName(a int) error {'
out3="$(printf '%s' "$diff3" | bash "$script")"
check "removed decl labelled removed" 1 \
  "$(printf '%s' "$out3" | jq '[.entries[] | select(.name=="OldName" and .change=="removed")] | length')"
check "added decl labelled added" 1 \
  "$(printf '%s' "$out3" | jq '[.entries[] | select(.name=="NewName" and .change=="added")] | length')"

# An empty diff is valid and yields nothing.
out4="$(printf '' | bash "$script")"
check "empty diff exits 0" 0 "$(printf '' | bash "$script" >/dev/null 2>&1; echo $?)"
check "empty diff has no paths" 0 "$(printf '%s' "$out4" | jq '.paths | length')"

# Multiple files.
diff5='diff --git a/a.ts b/a.ts
--- a/a.ts
+++ b/a.ts
@@ -1 +1 @@
-const x = 1;
+const x = 2;
diff --git a/b.ts b/b.ts
--- a/b.ts
+++ b/b.ts
@@ -1 +1 @@
-const y = 1;
+const y = 2;'
check "all changed paths listed" 2 \
  "$(printf '%s' "$diff5" | bash "$script" | jq '.paths | length')"

# --- kinds the spec requires that a declaration-keyword regex alone misses ---
# "Function, method, and class signatures reachable from outside the file" and
# "database column and index names" are both on the spec's inclusion list, and
# none of the checks above reach them.
kind_of() { printf '%s\n' "$1" | bash "$script" | jq -r '.entries[0] | "\(.name) \(.kind)"'; }

# A Go method carries a receiver before its name.
check "go method with a receiver" "Handle declaration" "$(kind_of 'diff --git a/a.go b/a.go
--- a/a.go
+++ b/a.go
@@ -1 +1 @@
+func (s *Server) Handle(w http.ResponseWriter) {}')"

# An exported binding holding a function is reachable like a declaration.
check "exported arrow function" "handler declaration" "$(kind_of 'diff --git a/a.ts b/a.ts
--- a/a.ts
+++ b/a.ts
@@ -1 +1 @@
+export const handler = (x: string) => x;')"

# ... but a local one is not on the surface.
check "local arrow function is excluded" 0 \
  "$(printf '%s\n' 'diff --git a/a.ts b/a.ts
--- a/a.ts
+++ b/a.ts
@@ -1 +1 @@
+const localThing = (x) => x;' | bash "$script" | jq '.entries | length')"

check "sql added column" "email_verified schema" "$(kind_of 'diff --git a/m.sql b/m.sql
--- a/m.sql
+++ b/m.sql
@@ -1 +1 @@
+ALTER TABLE users ADD COLUMN email_verified boolean;')"

check "sql created index" "idx_users_email schema" "$(kind_of 'diff --git a/m.sql b/m.sql
--- a/m.sql
+++ b/m.sql
@@ -1 +1 @@
+CREATE UNIQUE INDEX idx_users_email ON users(email);')"

# A config name must arrive whole. A greedy leading .* in the extractor
# truncated SENS_DIRS to "IRS" and MAX_RETRIES to "IES" - the name reached the
# integration judge as something no dependent search could ever match.
name_of() { printf '%s\n' "$1" | bash "$script" | jq -r '.entries[0].name'; }
check "config name is not truncated" "SENS_DIRS" "$(name_of 'diff --git a/a.sh b/a.sh
--- a/a.sh
+++ b/a.sh
@@ -1 +1 @@
+SENS_DIRS=(^|/)x')"
check "exported const name is whole" "MAX_RETRIES" "$(name_of 'diff --git a/a.ts b/a.ts
--- a/a.ts
+++ b/a.ts
@@ -1 +1 @@
+export const MAX_RETRIES = 3;')"

[ "$fails" -eq 0 ] && { echo "all checks passed"; exit 0; }
echo "$fails check(s) failed"; exit 1
