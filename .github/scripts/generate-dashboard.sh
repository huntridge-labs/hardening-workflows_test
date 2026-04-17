#!/usr/bin/env bash
# generate-dashboard.sh — Generates a self-contained HTML dashboard + history.json
# for the Argus test suite. Called from the summary job in test-suite.yml.
#
# Expected env vars:
#   ALL_JSON      — merged JSON array of all test results
#   SCOPE         — test scope (all, unit, remote, etc.)
#   RUN_URL       — link to this workflow run
#   RUN_ID        — github.run_id
#   REPO          — owner/repo
#   PAGES_DIR     — directory to write output files into
#   UNIT_JSON, ACTIONS_JSON, REMOTE_JSON, DISCOVER_JSON, COMBO_JSON, SCN_JSON, REGRESSION_JSON
#   UNIT_RESULT, ACTIONS_RESULT, REMOTE_RESULT, DISCOVER_RESULT, COMBO_RESULT, SCN_RESULT, I1_RESULT, I2_RESULT, I3_RESULT
#   ARGUS_REPO — upstream repo (e.g., huntridge-labs/argus)
#   ARGUS_REF  — branch/tag being tested (e.g., main)
#   ARGUS_SHA  — full commit SHA of the ref
#   ARGUS_SHA_SHORT — short (7-char) commit SHA
set -euo pipefail

OUT="${PAGES_DIR:?PAGES_DIR not set}"
mkdir -p "$OUT"

# ---------- safe JSON helper (empty string → []) ----------
safe_json() {
  if [ -n "$1" ] && echo "$1" | jq empty 2>/dev/null; then
    echo "$1"
  else
    echo "[]"
  fi
}

UNIT_JSON=$(safe_json "${UNIT_JSON:-}")
ACTIONS_JSON=$(safe_json "${ACTIONS_JSON:-}")
REMOTE_JSON=$(safe_json "${REMOTE_JSON:-}")
DISCOVER_JSON=$(safe_json "${DISCOVER_JSON:-}")
COMBO_JSON=$(safe_json "${COMBO_JSON:-}")
SCN_JSON=$(safe_json "${SCN_JSON:-}")
REGRESSION_JSON=$(safe_json "${REGRESSION_JSON:-}")
ALL_JSON=$(safe_json "${ALL_JSON:-}")

# ---------- compute stats ----------
TOTAL=$(echo "$ALL_JSON" | jq 'length')
PASSED=$(echo "$ALL_JSON" | jq '[.[] | select(.status == "pass")] | length')
FAILED=$(echo "$ALL_JSON" | jq '[.[] | select(.status == "FAIL")] | length')
SKIPPED=$(echo "$ALL_JSON" | jq '[.[] | select(.status == "skip" or .status == "cancel")] | length')
RUNNABLE=$((TOTAL - SKIPPED))
[ "$RUNNABLE" -eq 0 ] && RUNNABLE=1
PASS_RATE=$((PASSED * 100 / RUNNABLE))

if [ "$FAILED" -eq 0 ] && [ "$PASSED" -gt 0 ]; then
  VERDICT="PASS"
else
  VERDICT="FAIL"
fi

DATE_STR=$(date -u '+%Y-%m-%d %H:%M UTC')

# ---------- history ----------
HISTORY_FILE="$OUT/history.json"
if [ ! -f "$HISTORY_FILE" ]; then
  echo '[]' > "$HISTORY_FILE"
fi

CURRENT_RUN=$(jq -n -c \
  --arg date "$DATE_STR" \
  --arg scope "$SCOPE" \
  --argjson passed "$PASSED" \
  --argjson total "$TOTAL" \
  --argjson rate "$PASS_RATE" \
  --arg verdict "$VERDICT" \
  --arg url "$RUN_URL" \
  --arg run_id "$RUN_ID" \
  '{date:$date, scope:$scope, passed:$passed, total:$total, rate:$rate, verdict:$verdict, url:$url, run_id:$run_id}')

# Append and cap at 20
jq -c --argjson run "$CURRENT_RUN" '. + [$run] | .[-20:]' "$HISTORY_FILE" > "$HISTORY_FILE.tmp"
mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"

# ---------- build category data for HTML ----------
cat_status() {
  case "${1:-}" in
    success) echo "pass" ;;
    failure) echo "fail" ;;
    skipped) echo "skip" ;;
    cancelled) echo "skip" ;;
    *) echo "unknown" ;;
  esac
}

UNIT_RESULT="${UNIT_RESULT:-skipped}"
ACTIONS_RESULT="${ACTIONS_RESULT:-skipped}"
REMOTE_RESULT="${REMOTE_RESULT:-skipped}"
DISCOVER_RESULT="${DISCOVER_RESULT:-skipped}"
COMBO_RESULT="${COMBO_RESULT:-skipped}"
SCN_RESULT="${SCN_RESULT:-skipped}"
I1_RESULT="${I1_RESULT:-skipped}"
I2_RESULT="${I2_RESULT:-skipped}"
I3_RESULT="${I3_RESULT:-skipped}"

# Build categories JSON for embedding
CATEGORIES=$(jq -n -c \
  --arg us "$(cat_status "$UNIT_RESULT")" \
  --arg as "$(cat_status "$ACTIONS_RESULT")" \
  --arg rs "$(cat_status "$REMOTE_RESULT")" \
  --arg ds "$(cat_status "$DISCOVER_RESULT")" \
  --arg cs "$(cat_status "$COMBO_RESULT")" \
  --arg ss "$(cat_status "$SCN_RESULT")" \
  --arg i1s "$(cat_status "$I1_RESULT")" \
  --arg i2s "$(cat_status "$I2_RESULT")" \
  --arg i3s "$(cat_status "$I3_RESULT")" \
  --argjson u "$UNIT_JSON" \
  --argjson a "$ACTIONS_JSON" \
  --argjson r "$REMOTE_JSON" \
  --argjson d "$DISCOVER_JSON" \
  --argjson co "$COMBO_JSON" \
  --argjson sc "$SCN_JSON" \
  --argjson ig "$REGRESSION_JSON" \
  '[
    {name:"Unit Tests (U1–U5)",        status:$us, tests:$u},
    {name:"Direct Action Tests (A1–A5)",status:$as, tests:$a},
    {name:"Remote Mode Tests (R1–R12)", status:$rs, tests:$r},
    {name:"Discover Mode Tests (D1–D3)",status:$ds, tests:$d},
    {name:"Combination Tests (C1–C15)", status:$cs, tests:$co},
    {name:"SCN Detector Tests (S1–S25)",status:$ss, tests:$sc},
    {name:"Infrastructure Scan (I1)",   status:$i1s,tests:[$ig[0]]},
    {name:"No Hardcoded URLs (I2)",     status:$i2s,tests:[$ig[1]]},
    {name:"Config-Driven Scan (I3)",    status:$i3s,tests:[$ig[2]]}
  ]')

HISTORY_DATA=$(cat "$HISTORY_FILE")

# ---------- generate HTML ----------
cat > "$OUT/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Argus Test Suite</title>
<style>
:root {
  --bg: #ffffff; --bg2: #f6f8fa; --fg: #1f2328; --fg2: #656d76;
  --border: #d0d7de; --accent: #0969da;
  --pass-bg: #dafbe1; --pass-fg: #1a7f37;
  --fail-bg: #ffebe9; --fail-fg: #cf222e;
  --skip-bg: #fff8c5; --skip-fg: #9a6700;
  --badge-pass: #1a7f37; --badge-fail: #cf222e;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0d1117; --bg2: #161b22; --fg: #e6edf3; --fg2: #8b949e;
    --border: #30363d; --accent: #58a6ff;
    --pass-bg: #12261e; --pass-fg: #3fb950;
    --fail-bg: #2d1215; --fail-fg: #f85149;
    --skip-bg: #272115; --skip-fg: #d29922;
    --badge-pass: #3fb950; --badge-fail: #f85149;
  }
}
*, *::before, *::after { box-sizing: border-box; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
  background: var(--bg); color: var(--fg); margin: 0; padding: 0;
  line-height: 1.5;
}
.container { max-width: 1100px; margin: 0 auto; padding: 16px 24px; }
header { border-bottom: 1px solid var(--border); padding-bottom: 16px; margin-bottom: 24px; }
header h1 { margin: 0 0 4px; font-size: 1.5rem; }
header a { color: var(--accent); text-decoration: none; font-size: 0.85rem; }
.argus-info {
  margin-top: 8px; padding: 8px 12px; background: var(--bg2);
  border: 1px solid var(--border); border-radius: 6px; font-size: 0.82rem;
  display: inline-flex; align-items: center; gap: 12px; flex-wrap: wrap;
}
.argus-info .label { color: var(--fg2); }
.argus-info .value { font-family: 'SFMono-Regular', Consolas, monospace; color: var(--fg); }
.argus-info a { color: var(--accent); text-decoration: none; }
.argus-info a:hover { text-decoration: underline; }
.banner {
  display: flex; align-items: center; gap: 16px; flex-wrap: wrap;
  padding: 16px; border-radius: 8px; margin-bottom: 24px;
}
.banner.pass { background: var(--pass-bg); border: 1px solid var(--pass-fg); }
.banner.fail { background: var(--fail-bg); border: 1px solid var(--fail-fg); }
.badge {
  display: inline-block; padding: 4px 14px; border-radius: 20px;
  font-weight: 700; font-size: 1.1rem; color: #fff;
}
.badge.pass { background: var(--badge-pass); }
.badge.fail { background: var(--badge-fail); }
.banner-info { font-size: 0.9rem; color: var(--fg2); }
.banner-info strong { color: var(--fg); }
table {
  width: 100%; border-collapse: collapse; margin-bottom: 24px;
  font-size: 0.875rem;
}
th {
  text-align: left; padding: 8px 12px; background: var(--bg2);
  border-bottom: 2px solid var(--border); font-weight: 600;
}
td { padding: 8px 12px; border-bottom: 1px solid var(--border); }
tr:hover td { background: var(--bg2); }
.mono { font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace; font-size: 0.82rem; }
.status-dot {
  display: inline-block; width: 10px; height: 10px; border-radius: 50%;
}
.status-dot.pass { background: var(--pass-fg); }
.status-dot.fail { background: var(--fail-fg); }
.status-dot.skip, .status-dot.unknown { background: var(--skip-fg); }
.cat-header {
  cursor: pointer; user-select: none; padding: 10px 12px;
  background: var(--bg2); border: 1px solid var(--border); border-radius: 6px;
  margin-bottom: 4px; display: flex; align-items: center; gap: 8px;
}
.cat-header:hover { border-color: var(--accent); }
.cat-header .arrow { transition: transform 0.15s; font-size: 0.75rem; }
.cat-header.open .arrow { transform: rotate(90deg); }
.cat-body { display: none; margin-bottom: 16px; }
.cat-body.open { display: block; }
.section-title { font-size: 1.15rem; font-weight: 600; margin: 32px 0 12px; }
a.log-link { color: var(--accent); text-decoration: none; font-size: 0.82rem; }
a.log-link:hover { text-decoration: underline; }
.rate { font-weight: 600; }
.rate.good { color: var(--pass-fg); }
.rate.bad { color: var(--fail-fg); }
/* History chart */
.chart-container {
  background: var(--bg2); border: 1px solid var(--border); border-radius: 8px;
  padding: 16px; margin-bottom: 24px;
}
.chart-container h3 { margin: 0 0 12px; font-size: 0.95rem; font-weight: 600; }
.chart-svg { width: 100%; height: 180px; }
.chart-line { fill: none; stroke: var(--accent); stroke-width: 2; }
.chart-area { fill: var(--accent); opacity: 0.1; }
.chart-point { fill: var(--accent); }
.chart-point.fail { fill: var(--fail-fg); }
.chart-axis { stroke: var(--border); stroke-width: 1; }
.chart-grid { stroke: var(--border); stroke-width: 0.5; stroke-dasharray: 4,4; opacity: 0.5; }
.chart-label { font-size: 10px; fill: var(--fg2); }
.chart-tooltip {
  position: absolute; background: var(--bg); border: 1px solid var(--border);
  border-radius: 4px; padding: 6px 10px; font-size: 0.75rem; pointer-events: none;
  box-shadow: 0 2px 8px rgba(0,0,0,0.15); z-index: 100;
}
footer { margin-top: 40px; padding-top: 16px; border-top: 1px solid var(--border); font-size: 0.8rem; color: var(--fg2); }
</style>
</head>
<body>
<div class="container">
  <header>
    <h1>Argus Test Suite</h1>
    <a id="repo-link" href="#"></a>
    <div id="argus-info" class="argus-info"></div>
  </header>
  <div id="banner" class="banner"></div>
  <div class="section-title">Category Overview</div>
  <table id="cat-table">
    <thead><tr><th>Status</th><th>Category</th><th>Tests</th><th>Passed</th></tr></thead>
    <tbody></tbody>
  </table>
  <div class="section-title">Detailed Results</div>
  <div id="details"></div>
  <div class="section-title">Run History</div>
  <div id="chart-container" class="chart-container">
    <h3>Pass Rate Trend (Last 20 Runs)</h3>
    <svg id="history-chart" class="chart-svg"></svg>
  </div>
  <div id="chart-tooltip" class="chart-tooltip" style="display:none"></div>
  <table id="history-table">
    <thead><tr><th>Date</th><th>Scope</th><th>Result</th><th>Passed</th><th>Rate</th><th>Link</th></tr></thead>
    <tbody></tbody>
  </table>
  <footer>Auto-generated by the test suite CI. Data updates on every push to <code>main</code>.</footer>
</div>
<script>
HTMLEOF

# Inject the data as JS variables
{
  echo "const DATA = {"
  echo "  verdict: \"$VERDICT\","
  echo "  date: \"$DATE_STR\","
  echo "  scope: \"$SCOPE\","
  echo "  passed: $PASSED,"
  echo "  failed: $FAILED,"
  echo "  skipped: $SKIPPED,"
  echo "  total: $TOTAL,"
  echo "  passRate: $PASS_RATE,"
  echo "  runUrl: \"$RUN_URL\","
  echo "  repo: \"$REPO\","
  echo "  argusRepo: \"${ARGUS_REPO:-}\","
  echo "  argusRef: \"${ARGUS_REF:-}\","
  echo "  argusSha: \"${ARGUS_SHA:-}\","
  echo "  argusShaShort: \"${ARGUS_SHA_SHORT:-}\","
  printf '  categories: %s,\n' "$CATEGORIES"
  printf '  history: %s\n' "$HISTORY_DATA"
  echo "};"
} >> "$OUT/index.html"

cat >> "$OUT/index.html" << 'HTMLEOF2'

// --- render ---
(function() {
  const d = DATA;
  const serverUrl = d.runUrl.split('/').slice(0, 3).join('/');

  // repo link
  const repoLink = document.getElementById('repo-link');
  repoLink.href = serverUrl + '/' + d.repo;
  repoLink.textContent = d.repo;

  // argus action info
  const argusInfo = document.getElementById('argus-info');
  if (d.argusRepo && d.argusSha && d.argusSha !== 'unknown') {
    const commitUrl = serverUrl + '/' + d.argusRepo + '/commit/' + d.argusSha;
    const refUrl = serverUrl + '/' + d.argusRepo + '/tree/' + d.argusRef;
    argusInfo.innerHTML =
      '<span class="label">Testing:</span> ' +
      '<a href="' + serverUrl + '/' + d.argusRepo + '">' + d.argusRepo + '</a>' +
      '<span class="label">Ref:</span> ' +
      '<a class="value" href="' + refUrl + '">' + d.argusRef + '</a>' +
      '<span class="label">Commit:</span> ' +
      '<a class="value" href="' + commitUrl + '">' + d.argusShaShort + '</a>';
  } else if (d.argusRepo && d.argusRef) {
    argusInfo.innerHTML =
      '<span class="label">Testing:</span> ' +
      '<span class="value">' + d.argusRepo + '@' + d.argusRef + '</span>';
  } else {
    argusInfo.style.display = 'none';
  }

  // banner
  const banner = document.getElementById('banner');
  const vc = d.verdict.toLowerCase();
  banner.className = 'banner ' + vc;
  banner.innerHTML =
    '<span class="badge ' + vc + '">' + d.verdict + '</span>' +
    '<span class="banner-info">' +
      '<strong>' + d.date + '</strong> &mdash; Scope: <strong>' + d.scope + '</strong> &mdash; ' +
      d.passed + '/' + d.total + ' passed (' + d.passRate + '%) &mdash; ' +
      '<a href="' + d.runUrl + '" style="color:inherit;text-decoration:underline">View run</a>' +
    '</span>';

  // category overview table
  const catTbody = document.querySelector('#cat-table tbody');
  d.categories.forEach(function(cat) {
    const p = cat.tests.filter(function(t){return t.status==='pass'}).length;
    const tr = document.createElement('tr');
    tr.innerHTML =
      '<td><span class="status-dot ' + cat.status + '"></span></td>' +
      '<td>' + cat.name + '</td>' +
      '<td class="mono">' + cat.tests.length + '</td>' +
      '<td class="mono">' + p + '/' + cat.tests.length + '</td>';
    catTbody.appendChild(tr);
  });

  // detailed results (collapsible)
  const details = document.getElementById('details');
  d.categories.forEach(function(cat, ci) {
    const p = cat.tests.filter(function(t){return t.status==='pass'}).length;
    const hdr = document.createElement('div');
    hdr.className = 'cat-header';
    hdr.innerHTML =
      '<span class="arrow">&#9654;</span>' +
      '<span class="status-dot ' + cat.status + '"></span> ' +
      '<strong>' + cat.name + '</strong>' +
      '<span style="margin-left:auto;color:var(--fg2);font-size:0.85rem">' + p + '/' + cat.tests.length + '</span>';

    const body = document.createElement('div');
    body.className = 'cat-body';
    let tbl = '<table><thead><tr><th>Status</th><th>ID</th><th>Name</th><th>Detail</th><th>Log</th></tr></thead><tbody>';
    cat.tests.forEach(function(t) {
      const s = t.status === 'pass' ? 'pass' : t.status === 'FAIL' ? 'fail' : 'skip';
      tbl += '<tr>' +
        '<td><span class="status-dot ' + s + '"></span></td>' +
        '<td class="mono">' + t.id + '</td>' +
        '<td>' + t.name + '</td>' +
        '<td style="color:var(--fg2);font-size:0.82rem">' + (t.detail || '') + '</td>' +
        '<td><a class="log-link" href="' + d.runUrl + '">log</a></td>' +
        '</tr>';
    });
    tbl += '</tbody></table>';
    body.innerHTML = tbl;

    hdr.addEventListener('click', function() {
      hdr.classList.toggle('open');
      body.classList.toggle('open');
    });

    details.appendChild(hdr);
    details.appendChild(body);
  });

  // history table (newest first)
  const histTbody = document.querySelector('#history-table tbody');
  var hist = d.history.slice().reverse();
  hist.forEach(function(h) {
    const rc = h.verdict === 'PASS' ? 'good' : 'bad';
    const tr = document.createElement('tr');
    tr.innerHTML =
      '<td class="mono">' + h.date + '</td>' +
      '<td>' + h.scope + '</td>' +
      '<td><span class="status-dot ' + (h.verdict==='PASS'?'pass':'fail') + '"></span> ' + h.verdict + '</td>' +
      '<td class="mono">' + h.passed + '/' + h.total + '</td>' +
      '<td class="mono rate ' + rc + '">' + h.rate + '%</td>' +
      '<td><a class="log-link" href="' + h.url + '">run</a></td>';
    histTbody.appendChild(tr);
  });

  // --- history chart ---
  function renderChart() {
    const svg = document.getElementById('history-chart');
    const container = document.getElementById('chart-container');
    const tooltip = document.getElementById('chart-tooltip');
    const data = d.history; // oldest first

    if (data.length < 2) {
      container.innerHTML = '<p style="color:var(--fg2);font-size:0.85rem;margin:0">Not enough data for chart (need at least 2 runs)</p>';
      return;
    }

    const rect = svg.getBoundingClientRect();
    const W = rect.width || 800;
    const H = rect.height || 180;
    const pad = { top: 20, right: 20, bottom: 30, left: 40 };
    const chartW = W - pad.left - pad.right;
    const chartH = H - pad.top - pad.bottom;

    svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
    svg.innerHTML = '';

    // scales
    const xStep = chartW / (data.length - 1);
    const yMin = 0, yMax = 100;
    const yScale = function(v) { return pad.top + chartH - (v / yMax) * chartH; };
    const xScale = function(i) { return pad.left + i * xStep; };

    // grid lines
    var gridHtml = '';
    [0, 25, 50, 75, 100].forEach(function(v) {
      const y = yScale(v);
      gridHtml += '<line class="chart-grid" x1="' + pad.left + '" y1="' + y + '" x2="' + (W - pad.right) + '" y2="' + y + '"/>';
      gridHtml += '<text class="chart-label" x="' + (pad.left - 6) + '" y="' + (y + 3) + '" text-anchor="end">' + v + '%</text>';
    });

    // axes
    gridHtml += '<line class="chart-axis" x1="' + pad.left + '" y1="' + pad.top + '" x2="' + pad.left + '" y2="' + (H - pad.bottom) + '"/>';
    gridHtml += '<line class="chart-axis" x1="' + pad.left + '" y1="' + (H - pad.bottom) + '" x2="' + (W - pad.right) + '" y2="' + (H - pad.bottom) + '"/>';

    // area path
    var areaPath = 'M' + xScale(0) + ',' + (H - pad.bottom);
    data.forEach(function(pt, i) {
      areaPath += ' L' + xScale(i) + ',' + yScale(pt.rate);
    });
    areaPath += ' L' + xScale(data.length - 1) + ',' + (H - pad.bottom) + ' Z';
    gridHtml += '<path class="chart-area" d="' + areaPath + '"/>';

    // line path
    var linePath = '';
    data.forEach(function(pt, i) {
      linePath += (i === 0 ? 'M' : ' L') + xScale(i) + ',' + yScale(pt.rate);
    });
    gridHtml += '<path class="chart-line" d="' + linePath + '"/>';

    // points
    data.forEach(function(pt, i) {
      const cx = xScale(i);
      const cy = yScale(pt.rate);
      const cls = pt.verdict === 'PASS' ? 'chart-point' : 'chart-point fail';
      gridHtml += '<circle class="' + cls + '" cx="' + cx + '" cy="' + cy + '" r="5" data-idx="' + i + '" style="cursor:pointer"/>';
    });

    // x-axis labels (show first, last, and a few in between)
    var labelIndices = [0];
    if (data.length > 4) {
      labelIndices.push(Math.floor(data.length / 2));
    }
    labelIndices.push(data.length - 1);
    labelIndices.forEach(function(i) {
      const x = xScale(i);
      const dateShort = data[i].date.split(' ')[0]; // just YYYY-MM-DD
      gridHtml += '<text class="chart-label" x="' + x + '" y="' + (H - pad.bottom + 16) + '" text-anchor="middle">' + dateShort + '</text>';
    });

    svg.innerHTML = gridHtml;

    // tooltip interaction
    svg.querySelectorAll('circle').forEach(function(circle) {
      circle.addEventListener('mouseenter', function(e) {
        const idx = parseInt(circle.getAttribute('data-idx'));
        const pt = data[idx];
        tooltip.innerHTML =
          '<strong>' + pt.date + '</strong><br>' +
          'Scope: ' + pt.scope + '<br>' +
          'Result: ' + pt.verdict + '<br>' +
          'Passed: ' + pt.passed + '/' + pt.total + ' (' + pt.rate + '%)';
        tooltip.style.display = 'block';
        const tr = circle.getBoundingClientRect();
        tooltip.style.left = (tr.left + window.scrollX - 60) + 'px';
        tooltip.style.top = (tr.top + window.scrollY - 80) + 'px';
      });
      circle.addEventListener('mouseleave', function() {
        tooltip.style.display = 'none';
      });
      circle.addEventListener('click', function() {
        const idx = parseInt(circle.getAttribute('data-idx'));
        window.open(data[idx].url, '_blank');
      });
    });
  }

  renderChart();
  window.addEventListener('resize', renderChart);
})();
</script>
</body>
</html>
HTMLEOF2

# .nojekyll
touch "$OUT/.nojekyll"

echo "Dashboard generated: $OUT/index.html"
echo "History entries: $(jq 'length' "$HISTORY_FILE")"
