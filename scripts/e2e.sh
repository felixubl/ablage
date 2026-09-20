#!/bin/zsh
# End-to-end test: runs the built binary against a scratch inbox and checks what it did.
# Uses an isolated configuration and explicit simulation/pause overrides; user defaults are untouched.
set -u
cd "$(dirname "$0")/.."
BIN=.build/release/Ablage
[ -x "$BIN" ] || swift build -c release >/dev/null
T=$(mktemp -d /tmp/ablage-e2e.XXXXXX)
mkdir -p "$T/inbox1" "$T/inbox2" "$T/stage"
fails=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails+1)); fi }
APP_PID=""
cleanup() { if [ -n "$APP_PID" ]; then kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; fi; rm -rf "$T"; }
trap cleanup EXIT

cat > "$T/config.json" <<CFG
{
  "settleSeconds": 1, "rescanMinutes": 0, "notifications": false, "searchablePDFs": true,
  "learning": { "minExamples": 2, "confirmAfterHours": 0 },
  "inboxes": [
    { "path": "$T/inbox1", "rules": [ { "name": "Notes", "match": { "extensions": ["txt"] }, "action": { "destination": "Notes", "run": "echo hooked \$ABLAGE_RULE \$ABLAGE_TO >> $T/hook.log" } } ] },
    { "path": "$T/inbox2", "rules": [ { "name": "Notes", "match": { "extensions": ["txt"] }, "action": { "destination": "Notes2" } } ] }
  ],
  "rules": [
    { "name": "Scan", "match": { "extensions": ["png", "pdf"], "content": ["Wareneingang"] }, "action": { "destination": "$T/out/Scans", "tags": ["Scan"] } },
    { "name": "Screenshots", "match": { "extensions": ["png"], "filenameRegex": "^Screenshot" }, "action": { "destination": "$T/out/Screenshots/{year}" } },
    { "name": "Rechnungen", "match": { "extensions": ["pdf"], "content": ["Rechnung"], "fuzzy": true }, "action": { "destination": "$T/out/Finanzen/{year}", "rename": "{date}_{correspondent}", "correspondent": "Test", "dateFrom": "content", "tags": ["Rechnung"] } },
    { "name": "Memos", "match": { "extensions": ["md"], "filename": ["memo"] }, "action": { "destination": "$T/out/Memos", "rename": "{date}_memo", "dateFrom": "filename" } },
    { "name": "Keep readme", "match": { "filename": ["readme"] } },
    { "name": "Lieferscheine", "match": { "filename": ["zzz-never"] }, "action": { "destination": "$T/out/Lieferscheine" } },
    { "name": "Old folders", "match": { "kind": "folder", "minAgeDays": 0 }, "action": { "destination": "Archiv/{year}-{month}" } }
  ]
}
CFG

python3 - "$T/stage" <<'PY'
import sys, zlib, struct, os
d = sys.argv[1]
def pdf(name, text):
    stream = f"BT /F1 12 Tf 50 750 Td ({text}) Tj ET".encode()
    objs = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
      b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream", b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    out = b"%PDF-1.4\n"; offs = []
    for i, o in enumerate(objs, 1):
        offs.append(len(out)); out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    x = len(out); out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs)+1)
    for o in offs: out += b"%010d 00000 n \n" % o
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs)+1, x)
    open(os.path.join(d, name), "wb").write(out)
pdf("rechnung.pdf", "Rechnung Nr. 4711 Wien, am 15.03.2026 Betrag EUR 120,00 Testfirma GmbH Zahlbar innerhalb 14 Tagen Kundennummer 8812 UID ATU123 Bankverbindung IBAN Verwendungszweck")
pdf("rechnung-b.pdf", "Rechnung Nr. 4712 Wien, am 20.04.2026 Betrag EUR 80,00 Testfirma GmbH Zahlbar innerhalb 14 Tagen Kundennummer 8812 UID ATU123 Bankverbindung IBAN Verwendungszweck")
pdf("faktura.pdf", "Faktura Nr. 4713 Wien, am 02.06.2026 Betrag EUR 95,00 Testfirma GmbH Zahlbar innerhalb 14 Tagen Kundennummer 8812 UID ATU123 Bankverbindung IBAN Verwendungszweck")
pdf("rechnunq.pdf", "Rechnunq Nr. 9 Wien, am 10.02.2026 Betrag EUR 12,00 Testfirma GmbH")
pdf("ls-1.pdf", "Lieferschein Nr. 101 vom 02.05.2026 Testfirma GmbH Wien Lieferung Kartons Ware erhalten Unterschrift Spedition Paletten")
pdf("ls-2.pdf", "Lieferschein Nr. 102 vom 09.06.2026 Testfirma GmbH Wien Lieferung Paletten Ware erhalten Unterschrift Spedition")
pdf("ls-3.pdf", "Lieferschein Nr. 103 vom 21.07.2026 Testfirma GmbH Wien Lieferung Kartons Ware erhalten Spedition Paletten Unterschrift")
def chunk(t, b): return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00")) + chunk(b"IEND", b"")
open(os.path.join(d, "Screenshot 2026-09-20 at 10.00.00.png"), "wb").write(png)
open(os.path.join(d, "notes.txt"), "w").write("hello\n")
open(os.path.join(d, "README.md"), "w").write("keep me\n")
open(os.path.join(d, "20260102_memo.md"), "w").write("memo\n")
open(os.path.join(d, "data.csv"), "w").write("a,b\n")
PY
printf 'WARENEINGANG\n\nWareneingang Nr. 99\nTestfirma GmbH\n' > "$T/stage/scan-src.txt"
qlmanage -t -s 1200 -o "$T/stage" "$T/stage/scan-src.txt" >/dev/null 2>&1
mv "$T/stage/scan-src.txt.png" "$T/stage/scan.png"; rm "$T/stage/scan-src.txt"
sips -s format pdf "$T/stage/scan.png" --out "$T/stage/scan.pdf" >/dev/null 2>&1
mkdir -p "$T/hold"; mv "$T/stage/faktura.pdf" "$T/hold/"
mkdir -p "$T/stage/oldfolder"; echo x > "$T/stage/oldfolder/x.txt"

echo "learning via CLI"
ABLAGE_DIR="$T" $BIN learn Lieferscheine "$T/stage/ls-1.pdf" >/dev/null
ABLAGE_DIR="$T" $BIN learn Lieferscheine "$T/stage/ls-2.pdf" >/dev/null
check "two examples stored"            '[ "$(ABLAGE_DIR=$T $BIN examples | wc -l | tr -d " ")" = "2" ]'
check "similar file suggested"         'ABLAGE_DIR=$T $BIN suggest "$T/stage/ls-3.pdf" | grep -q "^Lieferscheine"'
check "unrelated file not suggested"   'ABLAGE_DIR=$T $BIN suggest "$T/stage/rechnung.pdf" | grep -q "no suggestion"'
check "validate ok"                    'ABLAGE_DIR=$T $BIN validate | grep -q "^ok"'

echo "sorting"
ABLAGE_SIMULATE=0 ABLAGE_PAUSED=0 ABLAGE_DIR="$T" "$BIN" >"$T/app.out" 2>&1 &
APP_PID=$!
sleep 2
cp -R "$T"/stage/* "$T/inbox1/"; cp "$T/stage/notes.txt" "$T/inbox2/"
sleep 12
cp "$T/stage/rechnung.pdf" "$T/inbox1/rechnung-copy.pdf"
cp "$T/hold/faktura.pdf" "$T/inbox1/"
sleep 6
Y=$(date +%Y); M=$(date +%m)
check "content match, date and rename" '[ -f "$T/out/Finanzen/2026/2026-03-15_Test.pdf" ]'
check "finder tag written"             'xattr -p com.apple.metadata:_kMDItemUserTags "$T/out/Finanzen/2026/2026-03-15_Test.pdf" 2>/dev/null | grep -q .'
check "filename regex"                 '[ -f "$T/out/Screenshots/2026/Screenshot 2026-09-20 at 10.00.00.png" ]'
check "ocr content match"              '[ -f "$T/out/Scans/scan.png" ]'
check "relative destination"           '[ -f "$T/inbox1/Notes/notes.txt" ]'
check "post-filing script ran"         'grep -q "hooked Notes $T/inbox1/Notes/notes.txt" "$T/hook.log"'
check "keep rule"                      '[ -f "$T/inbox1/README.md" ]'
check "date from filename"             '[ -f "$T/out/Memos/2026-01-02_memo.md" ]'
check "age rule on folder"             '[ -d "$T/inbox1/Archiv/$Y-$M/oldfolder" ]'
check "learned filing"                 'grep -q "moved \[Lieferscheine\].*like ls-[12].pdf" "$T/ablage.log"'
check "second inbox has own rules"     '[ -f "$T/inbox2/Notes2/notes.txt" ]'
check "duplicate trashed"              'grep -q "^.* duplicate \[Rechnungen\]" "$T/ablage.log"'
check "unmatched file stays"           '[ -f "$T/inbox1/data.csv" ]'
check "fuzzy content match"            '[ -f "$T/out/Finanzen/2026/2026-02-10_Test.pdf" ]'
check "rule filings became examples"   '[ "$(ABLAGE_DIR=$T $BIN examples | grep -c "^+	Rechnungen")" -ge 2 ]'
check "classifier filed unmatched invoice" '[ -f "$T/out/Finanzen/2026/2026-06-02_Test.pdf" ] && grep -q "moved \[Rechnungen\].*faktura.pdf.*like rechnung" "$T/ablage.log"'
check "scanned pdf got a text layer"   'ABLAGE_DIR=$T $BIN text --no-ocr "$T/out/Scans/scan.pdf" | grep -qi wareneingang'
check "original kept for undo"         'ls "$T/originals"/*.pdf >/dev/null 2>&1'
check "text layer in journal"          'grep -q "textLayer \[Scan\]" "$T/ablage.log"'

echo "adding a rule while running"
ABLAGE_DIR="$T" $BIN add-rule '{
  "name": "CSV",
  "match": { "extensions": ["csv"] },
  "action": { "destination": "'"$T"'/out/CSV" }
}' >/dev/null
check "rule appended and config valid" 'ABLAGE_DIR=$T $BIN validate | grep -q "8 shared rules"'
sleep 2; mv "$T/inbox1/data.csv" "$T/stage/"; sleep 2; cp "$T/stage/data.csv" "$T/inbox1/"; sleep 4
check "new rule applied after reload"  '[ -f "$T/out/CSV/data.csv" ]'

echo "broken config"
cp "$T/config.json" "$T/config.good"; sed -i '' 's/"filenameRegex": "^Screenshot"/"filenameRegex": "(["/' "$T/config.json"
check "validate reports bad regex"     'ABLAGE_DIR=$T $BIN validate | grep -q "invalid filenameRegex"'
cp "$T/config.good" "$T/config.json"

if [ $fails -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; echo "--- log ---"; cat "$T/ablage.log"; fi
exit $fails
