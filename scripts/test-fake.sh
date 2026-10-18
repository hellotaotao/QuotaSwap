#!/bin/bash
# End-to-end test of the CLI against a fake Claude directory. Never touches
# the real Claude app, keychain or snapshots. Needs python3 with `cryptography`
# to forge Chromium-style encrypted cookies.
set -uo pipefail
cd "$(dirname "$0")/.."
swift build -q || exit 1
BIN="$(swift build --show-bin-path)/QuotaSwap"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export QUOTASWAP_CLAUDE_DIR="$T/claude" QUOTASWAP_STORE="$T/store" QUOTASWAP_STATE_DIR="$T/state" \
       QUOTASWAP_CLI_CONFIG="$T/cli.json" QUOTASWAP_PROJECTS_DIR="$T/projects" \
       QUOTASWAP_SAFE_STORAGE_PASSWORD="fake-password"
UA=aaaaaaaa-0000-4000-8000-000000000001
UB=bbbbbbbb-0000-4000-8000-000000000002
OA=11111111-0000-4000-8000-00000000000a
OB=22222222-0000-4000-8000-00000000000b

fail=0
pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
expect() { # expect NAME PATTERN OUTPUT
    if grep -qE -- "$2" <<<"$3"; then pass "$1"; else bad "$1"; echo "$3" | sed 's/^/     | /'; fi
}

# fake_login UUID TOKEN ORG: what signing in through the Claude UI would leave behind
fake_login() {
    python3 -I - "$T/claude" "$@" <<'EOF'
import base64, hashlib, json, os, sqlite3, sys
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
app, uuid, token, org = sys.argv[1:]
key = hashlib.pbkdf2_hmac("sha1", b"fake-password", b"saltysalt", 1003, 16)
def enc(plain):
    pad = 16 - len(plain) % 16
    e = Cipher(algorithms.AES(key), modes.CBC(b" " * 16)).encryptor()
    return b"v10" + e.update(plain + bytes([pad]) * pad) + e.finalize()
p = app + "/config.json"
c = json.load(open(p)) if os.path.exists(p) else {"locale": "zh-CN", "darkMode": "dark"}
c.update({"oauth:tokenCacheV2": base64.b64encode(enc(json.dumps({"k": {"token": token}}).encode())).decode(),
          "lastKnownAccountUuid": uuid, "bootSidebarPlaceholder": [token]})
json.dump(c, open(p, "w"))
db = app + "/Cookies"
if os.path.exists(db): os.remove(db)
con = sqlite3.connect(db)
con.execute("create table cookies(host_key text, name text, encrypted_value blob, value text)")
h = hashlib.sha256(b".claude.ai").digest()
con.execute("insert into cookies values('.claude.ai','sessionKey',?, '')", (enc(h + ("sk-" + token).encode()),))
con.execute("insert into cookies values('.claude.ai','lastActiveOrg',?, '')", (enc(h + org.encode()),))
con.commit()
EOF
}
app_token() { python3 -I -c "import json,sys; print(json.load(open(sys.argv[1])).get('bootSidebarPlaceholder',[None])[0])" "$T/claude/config.json"; }

# --- fake world ---
mkdir -p "$T/claude/claude-code-sessions/$UA/$OA" "$T/claude/claude-code-sessions/$UB/$OB" \
         "$T/claude/local-agent-mode-sessions/$UB/$OB/local_x/.claude" "$T/projects/-Users-x-proj"
mk_session() { # store id activity archived cli
    printf '{"sessionId":"local_%s","cliSessionId":"%s","lastActivityAt":%s,"isArchived":%s,"title":"%s"}' \
        "$2" "$5" "$3" "$4" "$2" > "$1/local_$2.json"
}
SA="$T/claude/claude-code-sessions/$UA/$OA"; SB="$T/claude/claude-code-sessions/$UB/$OB"
mk_session "$SA" s1 100 false c1; mk_session "$SA" s2 200 true c2; mk_session "$SA" shared 300 false c3
mk_session "$SB" s3 150 false c4; mk_session "$SB" shared 999 false c3; mk_session "$SB" gone 50 false c5
echo 1 > "$SA/deleted_gone"
touch "$T/projects/-Users-x-proj/c3.jsonl"
echo "{\"oauthAccount\":{\"accountUuid\":\"$UA\",\"emailAddress\":\"alice@example.com\"}}" > "$T/cli.json"
echo "{\"oauthAccount\":{\"accountUuid\":\"$UB\",\"emailAddress\":\"bob@example.com\"}}" \
    > "$T/claude/local-agent-mode-sessions/$UB/$OB/local_x/.claude/.claude.json"
fake_login "$UA" A1 "$OA"

# --- tests ---
out=$("$BIN" doctor 2>&1); expect "doctor passes on a healthy layout" "all checks passed" "$out"
out=$("$BIN" list 2>&1); expect "list shows the unsaved signed-in account" "signed in now: alice@example.com \(not saved\)" "$out"
out=$("$BIN" use bob 2>&1); expect "use refuses before anything is saved" "No saved account" "$out"
out=$("$BIN" save 2>&1); expect "save defaults to the email's local part" "saved 'alice' \(alice@example.com\)" "$out"
out=$("$BIN" add 2>&1); expect "add signs out locally" "signed out locally" "$out"
expect "add merged the session lists" "sessions now: 4 / 4" "$out"
[ -f "$SB/deleted_gone" ] && [ ! -f "$SB/local_gone.json" ] && pass "tombstones propagate and delete" || bad "tombstones propagate and delete"
python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d['lastActivityAt']==999 else 1)" "$SA/local_shared.json" \
    && pass "newest copy of a shared session wins" || bad "newest copy of a shared session wins"
python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d=={'v':1,'archived':['local_s2']} else 1)" "$SB/archived-sessions.idx" \
    && pass "archive index rebuilt" || bad "archive index rebuilt"
out=$("$BIN" doctor 2>&1); expect "doctor passes while signed out" "all checks passed" "$out"

fake_login "$UB" B1 "$OB"
out=$("$BIN" save B 2>&1); expect "save with an explicit name" "saved 'B' \(bob@example.com\)" "$out"
out=$("$BIN" list 2>&1); expect "list marks the signed-in account" "^\* B +bob@example.com" "$out"
out=$("$BIN" use ali 2>&1); expect "use by email prefix" "switched to 'alice'" "$out"
[ "$(app_token)" = A1 ] && pass "alice's login restored" || bad "alice's login restored ($(app_token))"
fake_login "$UA" A2 "$OA"   # token rotates while alice is signed in
out=$("$BIN" use bob@example.com 2>&1); expect "use by full email" "switched to 'B'" "$out"
[ "$(app_token)" = B1 ] && pass "bob's login restored" || bad "bob's login restored"
out=$("$BIN" use A 2>&1)
[ "$(app_token)" = A2 ] && pass "rotated token was saved on switch-away" || bad "rotated token was saved on switch-away"
out=$("$BIN" use alice 2>&1); expect "use the signed-in account is a no-op" "already signed in" "$out"
out=$("$BIN" use zzz 2>&1); expect "unknown account is rejected" "No saved account matches 'zzz'" "$out"
out=$("$BIN" rename alice A 2>&1); expect "rename" "renamed 'alice' -> 'A' \(alice@example.com\)" "$out"
out=$("$BIN" sync --dry-run 2>&1); expect "sync is idempotent" "nothing to do" "$out"

out=$("$BIN" usage 2>&1)
if grep -qE "No saved claude.ai session|organization id|Decryption|not v10" <<<"$out"; then
    bad "usage decrypts saved cookies"; echo "$out" | sed 's/^/     | /'
else
    expect "usage decrypts saved cookies and reaches claude.ai" "HTTP [0-9]+|Network error" "$out"; echo "$out" | sed "s/^/     > /"
fi

# A layout change must block writes and leave state untouched.
python3 -I -c "import json,sys; p=sys.argv[1]; c=json.load(open(p)); c['oauth:tokenCacheV3']='x'; json.dump(c,open(p,'w'))" "$T/claude/config.json"
before=$(app_token)
out=$("$BIN" use B 2>&1); expect "self-check blocks switching on unknown token fields" "Self-check failed.*oauth:tokenCacheV3" "$out"
[ "$(app_token)" = "$before" ] && pass "blocked switch changed nothing" || bad "blocked switch changed nothing"
out=$("$BIN" doctor 2>&1); expect "doctor reports the failure" "FAIL token fields" "$out"

echo
[ $fail -eq 0 ] && echo "all tests passed" || echo "SOME TESTS FAILED"
exit $fail
