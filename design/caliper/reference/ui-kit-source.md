# UI kit source

The interactive prototype's full source, collected into one document so it can be read
straight through. These are **React design references**, not code to port — the target
is SwiftUI. Read them for exact values, layout order and copy.

To run the prototype: the design system it imports lives in the Slabs Design System
project at `ui_kits/scanner_app/`. Everything below is a verbatim copy.


---

## `data.js`

```js
// Mock inventory. The reference snapshot (255 cards, $121,600, $15,348 payout,
// 145 of 255 matched) sets the REGISTER — price range $310–$12,275, PSA 8/9/10,
// mostly Japanese Pokemon with some One Piece, group names exactly as a real user
// typed them. The kit ships a readable subset of rows and derives every total,
// payout and counter from that array, so no figure on screen contradicts another.
window.APP_DATA = {
  groups: [
    { id: 'pete', name: 'pete', color: 'var(--group-1)', count: 4 },
    { id: 'justin18', name: 'justin 18', color: 'var(--group-2)', count: 3 },
    { id: 'jose', name: 'jose 7/20', color: 'var(--group-3)', count: 2 },
    { id: 'triumph', name: 'Triumph 7/24', color: 'var(--group-4)', count: 0 },
    { id: 'philcgc', name: 'philcgc', color: 'var(--group-5)', count: 0 },
    { id: 'doubledown', name: 'doubledown', color: 'var(--group-6)', count: 0 },
    { id: 'bricks', name: 'bricks', color: 'var(--group-2)', count: 0 },
    { id: 'suhoon', name: 'Suhoon', color: 'var(--group-3)', count: 0 },
  ],
  ranges: [
    { id: 'justin', name: 'Justin', color: 'var(--group-2)' },
    { id: 'kazuma', name: 'Kazuma', color: 'var(--group-4)' },
  ],
  cards: [
    { id: 1, name: 'Japanese Rulers of the Heavens Rayquaza', prices: { CL: 4177, CY: 5071, JP: null }, year: 2006, category: 'Pokemon', cardNumber: '4', confidence: 5, cert: '84920117', grade: '10', grader: 'PSA', group: 'pete' },
    { id: 2, name: 'Pop Series 4 #17 Deoxys Ex', prices: { CL: 11940, CY: 12275, JP: '¥1.74M' }, year: 2003, category: 'Pokemon', cardNumber: '17', confidence: 5, cert: '71028834', grade: '9', grader: 'PSA', group: 'justin18' },
    { id: 3, name: 'Ex Dragon Frontiers 91 Dragonite', prices: { CL: 310, CY: null, JP: null }, year: 2006, category: 'Pokemon', cardNumber: '91', confidence: 1, cert: '62211903', grade: '8', grader: 'PSA', group: null },
    { id: 4, name: 'One Piece OP-01 Shanks Parallel', prices: { CL: 1905, CY: 1840, JP: '¥264K' }, year: 2023, category: 'One Piece', cardNumber: null, confidence: 3, cert: '90114427', grade: '10', grader: 'PSA', group: 'jose' },
    { id: 5, name: 'Japanese Neo Destiny Shining Charizard', prices: { CL: 8880, CY: 9420, JP: '¥1.31M' }, year: 2002, category: 'Pokemon', cardNumber: null, confidence: 5, cert: '55903118', grade: '9', grader: 'PSA', group: null },
    { id: 6, name: 'Japanese VSTAR Universe Arceus AR', prices: { CL: 622, CY: 660, JP: '¥92K' }, year: 2023, category: 'Pokemon', cardNumber: '262', confidence: 4, cert: '81477201', grade: '10', grader: 'CGC', group: 'pete' },
    { id: 7, name: 'Japanese Rulers of the Heavens Mew', prices: { CL: null, CY: null, JP: null }, year: 2006, category: 'Pokemon', cardNumber: '9', confidence: 0, cert: '84920118', grade: '9', grader: 'PSA', group: 'pete' },
    { id: 8, name: 'Ex Power Keepers 4 Blaziken', prices: { CL: 1044, CY: 998, JP: null }, year: 2016, category: 'Pokemon', cardNumber: '4', confidence: 4, cert: '73900142', grade: '10', grader: 'PSA', group: 'justin18' },
  ],
  columns: ['Cert', 'Name', 'Year', 'Card #', 'Grade', 'Grader', 'CL Price', 'CL Conf', 'CY Price', 'CY Conf', 'JP Price ¥', 'JP Price $', 'Outlet', 'Payout %', 'Payout provider', 'Payout $', 'Scanned at', 'Refreshed at'],
  sourceHue: { CL: 'var(--src-cl)', CY: 'var(--src-cy)', JP: 'var(--src-jp)' },
};
```

---

## `Onboarding.jsx`

```jsx
/* Getting started — three swipeable cards (a designed gap; the reference had none).
   Kept to the loop the whole product serves: scan, price, group, export. The dots are
   tappable and the last card's primary action drops the user straight into Scan. */
function Onboarding({ onDone }) {
  const { Button, Icon } = window.DS;
  const [i, setI] = React.useState(0);
  const cards = [
    { glyph: 'scan-line', k: 'STEP 01', h: 'Tap once per slab', p: 'The whole viewport is the shutter. PSA slabs read from their QR code, CGC from the barcode — the cert number is all the app needs to identify the card.', foot: 'Zoom and torch live under the viewfinder. Cert digits are small and slabs are shiny.' },
    { glyph: 'layers', k: 'STEP 02', h: 'Three markets, one row', p: 'Every card carries a price from CL, CY and JP, each with a confidence meter showing how sure the match is. Switch which source leads with the toggle up top — the other two never disappear.', foot: 'A source with no data shows an em dash. Nothing here ever invents a number.' },
    { glyph: 'share', k: 'STEP 03', h: 'Group by buyer, export CSV', p: 'Select cards until the running total hits your target, drop them into a buyer\'s group, then filter to that group and export. The filename carries the buyer and the date.', foot: 'The CSV is usually the only part of this app your buyer ever sees.' },
  ];
  const c = cards[i];
  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', padding: 'var(--space-8) var(--gutter) var(--space-7)' }}>
      <div style={{ display: 'flex', alignItems: 'center' }}>
        <span style={{ font: 'var(--type-meta)', fontSize: 10, letterSpacing: 'var(--tracking-label)', color: 'var(--cyan)' }}>{c.k}</span>
        <span style={{ marginLeft: 'auto' }}><Button variant="text" style={{ color: 'var(--text-secondary)' }} onClick={onDone}>Skip</Button></span>
      </div>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 'var(--space-7)' }}>
        <span style={{ width: 52, height: 52, border: 'var(--border-width) solid var(--cyan-dim)', background: 'rgba(53,224,232,.06)', display: 'grid', placeItems: 'center' }}>
          <Icon name={c.glyph} size={24} color="var(--cyan)" />
        </span>
        <h2 style={{ font: 'var(--type-title)', fontSize: 29, letterSpacing: '-1px', lineHeight: 1.12, margin: 0 }}>{c.h}</h2>
        <p style={{ font: 'var(--type-body)', fontWeight: 400, fontSize: 14, lineHeight: 1.6, color: 'var(--text-secondary)', margin: 0 }}>{c.p}</p>
        <div style={{ borderTop: 'var(--border-width) solid var(--line)', paddingTop: 'var(--space-6)' }}>
          <span style={{ font: 'var(--type-meta)', letterSpacing: 'var(--tracking-meta)', color: 'var(--text-tertiary)', lineHeight: 1.7 }}>{c.foot}</span>
        </div>
      </div>
      <div style={{ display: 'flex', gap: 'var(--space-4)', marginBottom: 'var(--space-7)' }}>
        {cards.map((_, n) => (
          <span key={n} onClick={() => setI(n)} style={{ flex: 1, height: 2, background: n <= i ? 'var(--cyan)' : 'var(--line-strong)', boxShadow: n === i ? 'var(--glow-cyan-soft)' : 'none', cursor: 'pointer' }} />
        ))}
      </div>
      <Button variant="primary" fullWidth onClick={() => (i < 2 ? setI(i + 1) : onDone())}>
        {i < 2 ? 'Next' : 'Open the scanner'}
      </Button>
    </div>
  );
}
Object.assign(window, { Onboarding });
```

---

## `ScanScreen.jsx`

```jsx
/* Scan (spec §3.1): context line, source toggle, manual-entry pencil, a 4:5 camera
   viewport with corner brackets whose entire area is the shutter, then zoom and torch.
   One tap per slab — no focus step, no confirm step.
   The post-scan feedback (a designed gap) is a toast over the viewport: cert, grade,
   and the leading price the moment it resolves. A duplicate cert says so instead. */
function ScanScreen({ source, onSource, count, onScan, toast }) {
  const { ScreenHeader, Icon, Chip } = window.DS;
  return (
    <>
      <ScreenHeader
        context={'Today · ' + count + ' scans'} title="Scan" source={source} onSource={onSource}
        trailing={<span style={{ width: 26, height: 26, border: 'var(--border-width) solid var(--line-strong)', borderRadius: 'var(--radius-control)', display: 'grid', placeItems: 'center', cursor: 'pointer' }}><Icon name="pencil" size={12} /></span>}
      />
      <div onClick={onScan} style={{ margin: '0 var(--gutter)', aspectRatio: '4/5', position: 'relative', overflow: 'hidden', background: 'linear-gradient(180deg,#0A1013,#070A0C)', border: 'var(--border-width) solid var(--line-strong)', cursor: 'pointer' }}>
        <span style={{ position: 'absolute', inset: 0, backgroundImage: 'linear-gradient(var(--line) 1px,transparent 1px),linear-gradient(90deg,var(--line) 1px,transparent 1px)', backgroundSize: 'var(--grid-cell) var(--grid-cell)', opacity: .55 }} />
        {[['top:16px;left:16px', 'border-right:0;border-bottom:0'], ['top:16px;right:16px', 'border-left:0;border-bottom:0'], ['bottom:16px;left:16px', 'border-right:0;border-top:0'], ['bottom:16px;right:16px', 'border-left:0;border-top:0']].map(([pos, cut], i) => (
          <span key={i} style={{ position: 'absolute', width: 24, height: 24, border: '2px solid var(--cyan)', ...cssObj(pos + ';' + cut) }} />
        ))}
        <span style={{ position: 'absolute', left: 16, right: 16, top: '47%', height: 'var(--scanline-height)', background: 'var(--cyan)', boxShadow: 'var(--glow-cyan)' }} />
        <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'flex-end', justifyContent: 'center', paddingBottom: 26, textAlign: 'center' }}>
          <div>
            <span style={{ font: 'var(--type-heading)' }}>Tap to scan</span>
            <span style={{ display: 'block', font: 'var(--type-meta)', letterSpacing: 'var(--tracking-label)', color: 'var(--text-secondary)', marginTop: 'var(--space-4)' }}>PSA QR · CGC BARCODE</span>
          </div>
        </div>
        {toast && (
          <div style={{ position: 'absolute', left: 14, right: 14, bottom: 14, background: 'var(--scrim)', backdropFilter: 'var(--scrim-blur)', border: 'var(--border-width) solid ' + (toast.dupe ? 'var(--line-strong)' : 'var(--cyan)'), borderLeft: '2px solid ' + (toast.dupe ? 'var(--conf-mid)' : 'var(--cyan)'), padding: 'var(--space-5) var(--space-6)', zIndex: 2 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-4)' }}>
              <span style={{ font: 'var(--type-body)', flex: 1, minWidth: 0, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{toast.name}</span>
              {toast.price != null && <span style={{ font: 'var(--type-price)', color: window.APP_DATA.sourceHue[source], fontVariantNumeric: 'var(--numeric)' }}>{'$' + toast.price.toLocaleString('en-US')}</span>}
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-4)', marginTop: 'var(--space-4)' }}>
              <span style={{ font: 'var(--type-meta)', letterSpacing: 'var(--tracking-meta)', color: toast.dupe ? 'var(--conf-mid)' : 'var(--text-secondary)' }}>{toast.note}</span>
              <span style={{ marginLeft: 'auto' }}><Chip>{toast.grader} {toast.grade}</Chip></span>
            </div>
          </div>
        )}
      </div>
      <div style={{ padding: 'var(--space-7) var(--gutter)', display: 'flex', flexDirection: 'column', gap: 'var(--space-6)' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-6)' }}>
          <span style={{ font: 'var(--type-meta)', letterSpacing: 'var(--tracking-label)', color: 'var(--text-secondary)', width: 38 }}>ZOOM</span>
          <span style={{ flex: 1, height: 2, background: 'var(--line-strong)', position: 'relative' }}>
            <i style={{ position: 'absolute', left: 0, top: 0, bottom: 0, width: '36%', background: 'var(--cyan)' }} />
            <u style={{ position: 'absolute', left: '36%', top: -6, width: 14, height: 14, marginLeft: -7, background: 'var(--cyan)', borderRadius: 'var(--radius-control)', boxShadow: 'var(--glow-cyan)' }} />
          </span>
          <span style={{ font: 'var(--type-figure-sm)', fontSize: 13, fontVariantNumeric: 'var(--numeric)', width: 42, textAlign: 'right' }}>2.0×</span>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', borderTop: 'var(--border-width) solid var(--line)', paddingTop: 'var(--space-6)' }}>
          <span style={{ font: 'var(--type-meta)', letterSpacing: 'var(--tracking-label)', color: 'var(--text-secondary)' }}>TORCH</span>
          <span style={{ marginLeft: 'auto', width: 44, height: 22, background: 'rgba(53,224,232,.15)', border: 'var(--border-width) solid var(--cyan)', position: 'relative' }}>
            <i style={{ position: 'absolute', top: 2, right: 2, width: 17, height: 16, background: 'var(--cyan)', display: 'block' }} />
          </span>
        </div>
      </div>
    </>
  );
}

/** Tiny helper so the bracket corners can be written as CSS text. */
function cssObj(s) {
  return s.split(';').filter(Boolean).reduce((o, d) => {
    const [k, v] = d.split(':');
    o[k.trim().replace(/-([a-z])/g, (m, c) => c.toUpperCase())] = v.trim();
    return o;
  }, {});
}
Object.assign(window, { ScanScreen, cssObj });
```

---

## `InventoryScreen.jsx`

```jsx
/* Cards (spec §3.2, §3.3) — the center of gravity. Summary block, filter pill,
   scope-aware search, then the rows. Selection is a MODE on this same screen: the
   list does not reflow, rows grow a circle, and the action bar rises above the tabs.
   The price-refresh trigger (a designed gap) is the circular-arrow control beside
   sort: it states when prices were last refreshed and spins in place. */
function InventoryScreen({ source, onSource, cards, filterGroup, groups, onOpenFilters, onClearFilter, selecting, selected, onToggleSelect, onStartSelect, onCancelSelect, onSelectAll, onAction, refreshing, refreshedAt, onRefresh }) {
  const { ScreenHeader, SummaryBlock, FilterPill, SearchSortBar, CardRow, SelectionBar, Button, Icon } = window.DS;
  const g = groups.find((x) => x.id === filterGroup);
  // One source of truth: every figure on this screen is derived from the rows in
  // scope, so the denominator is identical in the context line, the search
  // placeholder and the match counter (spec §5 — every count is live).
  const priceOf = (c) => (typeof c.prices[source] === 'number' ? c.prices[source] : 0);
  const scopeTotal = cards.reduce((n, c) => n + priceOf(c), 0);
  const matchedCards = cards.filter((c) => c.confidence >= 4);
  // Payout is the matched cards' value at the reference snapshot's ~12.6% rate.
  const scopePayout = Math.round(matchedCards.reduce((n, c) => n + priceOf(c), 0) * 0.126);
  const selCards = cards.filter((c) => selected.includes(c.id));
  const selTotal = selCards.reduce((n, c) => n + priceOf(c), 0);
  return (
    <>
      <ScreenHeader
        context={selecting ? selected.length + ' of ' + cards.length + ' selected' : cards.length + ' cards'}
        contextTone={selecting ? 'active' : 'default'}
        title={selecting ? 'Select cards' : g ? g.name : 'Inventory'}
        source={source} onSource={onSource}
        actions={selecting
          ? <><Button variant="text" onClick={onSelectAll}>Select all</Button><Button variant="text" style={{ color: 'var(--text-secondary)' }} onClick={onCancelSelect}>Cancel</Button></>
          : <Button variant="text" onClick={onStartSelect}>Select</Button>}
      />
      {!selecting && (
        <div style={{ padding: '0 var(--gutter) var(--space-6)' }}>
          <SummaryBlock
            total={scopeTotal}
            payout={scopePayout}
            matched={matchedCards.length}
            of={cards.length} scoped={!!g}
          />
        </div>
      )}
      <div style={{ padding: '0 var(--gutter) var(--space-5)' }}>
        <FilterPill group={g && g.name} groupColor={g && g.color} onOpen={onOpenFilters} onClear={onClearFilter} />
      </div>
      <div style={{ padding: '0 var(--gutter) var(--space-6)', display: 'flex', gap: 'var(--space-4)' }}>
        <span style={{ flex: 1 }}><SearchSortBar count={cards.length} /></span>
        <button type="button" onClick={onRefresh} title={'Prices refreshed ' + refreshedAt}
          style={{ border: 'var(--border-width) solid ' + (refreshing ? 'var(--cyan)' : 'var(--line-strong)'), background: 'var(--surface)', padding: '0 var(--space-5)', cursor: 'pointer', display: 'grid', placeItems: 'center' }}>
          <span style={{ display: 'grid', placeItems: 'center', animation: refreshing ? 'ds-spin 900ms linear infinite' : 'none' }}>
            <Icon name="refresh-cw" size={14} color={refreshing ? 'var(--cyan)' : 'var(--text-secondary)'} />
          </span>
        </button>
      </div>
      <div style={{ padding: '0 var(--gutter) var(--space-4)', display: 'flex', alignItems: 'center', gap: 'var(--space-4)' }}>
        <span style={{ font: 'var(--type-meta)', letterSpacing: 'var(--tracking-meta)', color: refreshing ? 'var(--cyan)' : 'var(--text-tertiary)' }}>
          {refreshing ? 'REFRESHING ' + cards.length + ' CARDS · CL, CY, JP' : 'PRICES REFRESHED ' + refreshedAt}
        </span>
      </div>
      <div style={{ flex: 1, minHeight: 0, overflowY: 'auto', padding: '0 var(--gutter) var(--space-6)', display: 'flex', flexDirection: 'column', gap: 'var(--row-gap)' }}>
        {cards.map((c) => {
          const grp = groups.find((x) => x.id === c.group);
          return (
            <CardRow key={c.id} {...c} source={source}
              group={grp && grp.name} groupColor={grp && grp.color}
              selectable={selecting} selected={selected.includes(c.id)}
              onToggle={() => onToggleSelect(c.id)} />
          );
        })}
        {cards.length === 0 && (
          <div style={{ padding: 'var(--space-8) 0', font: 'var(--type-body)', color: 'var(--text-secondary)', textAlign: 'center' }}>
            No cards in this group yet. Select cards on Inventory and tap Group.
          </div>
        )}
      </div>
      {selecting && <SelectionBar count={selected.length} total={selTotal} onAction={onAction} />}
    </>
  );
}
Object.assign(window, { InventoryScreen });
```

---

## `Sheets.jsx`

```jsx
/* The two sheets (spec §3.4, §3.5). Same shell, different sticky confirm.
   Groups: pick an existing buyer or type a new name — creating and assigning are one
   action, so there is never a separate "manage groups" screen.
   Filters: GROUPS and BUY RANGE sections, shared verbatim by Cards and Export; only
   the confirm verb changes ("Show 4 cards" vs "Export 4 cards"). */
function GroupSheet({ count, groups, onClose, onAssign }) {
  const { Sheet, SheetRow, GroupTag, Button, Icon } = window.DS;
  const [name, setName] = React.useState('');
  return (
    <Sheet title={'Add ' + count + ' to group'} onClose={onClose}
      trailing={<Button variant="text" style={{ color: 'var(--text-secondary)' }} onClick={onClose}>Cancel</Button>}>
      {groups.map((g) => (
        <SheetRow key={g.id} onClick={() => onAssign(g.id)}
          leading={<Icon name="folder" size={16} color={g.color} fill="currentColor" strokeWidth={0} />}
          label={g.name} sub={g.count + ' cards'} trailing="›" />
      ))}
      <div style={{ padding: 'var(--space-6) var(--gutter)', borderTop: 'var(--border-width) solid var(--cyan-dim)', display: 'flex', gap: 'var(--space-4)' }}>
        <input value={name} onChange={(e) => setName(e.target.value)} placeholder="New group name..."
          style={{ flex: 1, minWidth: 0, background: 'var(--surface)', border: 'var(--border-width) solid var(--line-strong)', color: 'var(--text-primary)', font: 'var(--type-body)', padding: 'var(--space-5) var(--space-6)', outline: 'none' }} />
        <Button variant="primary" disabled={!name.trim()} onClick={() => onAssign(null, name.trim())} style={{ padding: '0 var(--space-7)', fontSize: 13 }}>Create</Button>
      </div>
    </Sheet>
  );
}

function FiltersSheet({ mode = 'cards', groups, ranges, stats, ungrouped, unmatched, value, onChange, onClose, onConfirm, resultCount }) {
  const { Sheet, SheetRow, Button, Icon } = window.DS;
  const verb = mode === 'export' ? 'Export' : 'Show';
  return (
    <Sheet title="Filters" onClose={onClose}
      trailing={value ? <Button variant="text" onClick={() => onChange(null)}>Clear all</Button> : null}
      confirm={<Button variant="primary" fullWidth onClick={onConfirm}>{verb} {resultCount} cards</Button>}>
      <div style={{ padding: 'var(--space-6) var(--gutter) var(--space-4)', font: 'var(--type-meta)', letterSpacing: 'var(--tracking-label)', color: 'var(--text-secondary)' }}>GROUPS</div>
      <SheetRow label="All cards" trailing={<>{stats.count}{!value && ' ✓'}</>} active={!value} onClick={() => onChange(null)} />
      <SheetRow label="Ungrouped" trailing={ungrouped} onClick={() => onChange('__ungrouped')} active={value === '__ungrouped'} />
      {groups.map((g) => (
        <SheetRow key={g.id} onClick={() => onChange(g.id)} active={value === g.id}
          leading={<Icon name="folder" size={16} color={g.color} fill="currentColor" strokeWidth={0} />}
          label={g.name} trailing={<>{g.count}{value === g.id && ' ✓'}</>} />
      ))}
      <div style={{ padding: 'var(--space-6) var(--gutter) var(--space-4)', font: 'var(--type-meta)', letterSpacing: 'var(--tracking-label)', color: 'var(--text-secondary)', borderTop: 'var(--border-width) solid var(--line)' }}>BUY RANGE</div>
      <SheetRow label="All ranges" trailing={<>{stats.count} ✓</>} active />
      <SheetRow label="Unmatched" trailing={unmatched} />
      {ranges.map((r) => (
        <SheetRow key={r.id}
          leading={<span style={{ width: 8, height: 8, borderRadius: '50%', background: r.color, display: 'block' }} />}
          label={r.name} trailing={<>{r.count} ›</>} />
      ))}
    </Sheet>
  );
}
Object.assign(window, { GroupSheet, FiltersSheet });
```

---

## `ExportScreen.jsx`

```jsx
/* Export (spec §3.6): a CSV builder with a live preview. The filename encodes scope
   and date, the header row is tinted to the source of the selected columns, and the
   column chips carry a numeric order badge because selection order IS column order
   in the file. The CTA states exactly what is going out. */
function ExportScreen({ source, onSource, cards, filterGroup, groups, onOpenFilters, onClearFilter, columns, onToggleColumn }) {
  const { ScreenHeader, FilterPill, Chip, Button } = window.DS;
  const g = groups.find((x) => x.id === filterGroup);
  const file = 'inventory' + (g ? '_' + g.name.replace(/[^a-z0-9]+/gi, '') : '') + '_2026-08-19.csv';
  const total = cards.reduce((n, c) => n + (typeof c.prices[source] === 'number' ? c.prices[source] : 0), 0);
  const hue = window.APP_DATA.sourceHue;
  const srcOf = (c) => (c.startsWith('CL') ? 'CL' : c.startsWith('CY') ? 'CY' : c.startsWith('JP') ? 'JP' : null);
  const header = columns.map((c) => c.toLowerCase().replace(/[^a-z0-9]+/g, '_'));
  return (
    <>
      <ScreenHeader context={'inventory.csv · ' + cards.length + ' rows'} title="Export" source={source} onSource={onSource} />
      <div style={{ padding: '0 var(--gutter) var(--space-5)' }}>
        <FilterPill group={g && g.name} groupColor={g && g.color} onOpen={onOpenFilters} onClear={onClearFilter} />
      </div>
      <div style={{ margin: '0 var(--gutter) var(--space-6)', border: 'var(--border-width) solid var(--line-strong)', background: '#080C0F' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-4)', padding: 'var(--space-4) var(--space-5)', borderBottom: 'var(--border-width) solid var(--line)', background: 'var(--surface)' }}>
          {[0, 1, 2].map((i) => <span key={i} style={{ width: 7, height: 7, borderRadius: '50%', background: 'var(--line-strong)', display: 'block' }} />)}
          <span style={{ font: 'var(--type-meta)', letterSpacing: '.04em', color: 'var(--text-secondary)', marginLeft: 'var(--space-2)' }}>{file}</span>
        </div>
        <pre style={{ margin: 0, padding: 'var(--space-5)', font: 'var(--type-code)', color: '#8C9CA5', whiteSpace: 'pre', overflow: 'hidden' }}>
{columns.map((c, i) => <span key={c} style={{ color: srcOf(c) ? hue[srcOf(c)] : 'var(--text-primary)', fontWeight: 500 }}>{header[i]}{i < columns.length - 1 ? ',' : ''}</span>)}
{'\n'}
{cards.slice(0, 4).map((c) => columns.map((col) => cell(c, col)).join(',') + '\n')}
        </pre>
      </div>
      <div style={{ padding: '0 var(--gutter) var(--space-6)', flex: 1, minHeight: 0, overflowY: 'auto' }}>
        <div style={{ font: 'var(--type-meta)', letterSpacing: 'var(--tracking-label)', color: 'var(--text-secondary)', marginBottom: 'var(--space-5)' }}>INCLUDE COLUMNS</div>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 'var(--space-3)' }}>
          {window.APP_DATA.columns.map((c) => {
            const idx = columns.indexOf(c);
            const s = srcOf(c);
            return (
              <span key={c} onClick={() => onToggleColumn(c)} style={{ cursor: 'pointer' }}>
                <Chip tone={idx > -1 ? (s ? 'source' : 'default') : 'quiet'} order={idx > -1 ? idx + 1 : undefined} color={s ? hue[s] : undefined}>{c}</Chip>
              </span>
            );
          })}
        </div>
      </div>
      <div style={{ padding: 'var(--space-6) var(--gutter)', borderTop: 'var(--border-width) solid var(--line)', background: 'var(--surface)' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', font: 'var(--type-meta)', fontSize: 10, letterSpacing: 'var(--tracking-label)', color: 'var(--text-secondary)', marginBottom: 'var(--space-5)' }}>
          <span>{cards.length} CARDS</span><span style={{ color: 'var(--text-primary)' }}>{'$' + total.toLocaleString('en-US')}</span>
        </div>
        <Button variant="primary" fullWidth>↗  Share CSV</Button>
      </div>
    </>
  );
}

/** One CSV cell. Missing values are empty in the file, em dashes in the UI. */
function cell(c, col) {
  const m = {
    'Cert': c.cert, 'Name': c.name.slice(0, 19) + '…', 'Year': c.year, 'Card #': c.cardNumber || '',
    'Grade': c.grade, 'Grader': c.grader,
    'CL Price': c.prices.CL ?? '', 'CY Price': c.prices.CY ?? '', 'JP Price ¥': c.prices.JP ?? '',
    'CL Conf': c.confidence, 'CY Conf': c.confidence, 'JP Price $': '',
  };
  return m[col] ?? '';
}
Object.assign(window, { ExportScreen, cell });
```

---

## `SettingsScreen.jsx`

```jsx
/* Settings (a designed gap — the reference never showed this tab). Built only from
   what the rest of the product implies: three price sources that each need an account
   or key, a refresh cadence (the Refreshed at column has to come from somewhere), the
   payout provider behind the Payout % and Outlet columns, scanner defaults matching
   the Scan tab's controls, and CSV defaults matching the Export builder. */
function SettingsScreen({ source, onSource, onReplayOnboarding }) {
  const { ScreenHeader, Button, Icon } = window.DS;
  const Section = ({ title, children }) => (
    <>
      <div style={{ padding: 'var(--space-7) var(--gutter) var(--space-4)', font: 'var(--type-meta)', letterSpacing: 'var(--tracking-label)', color: 'var(--text-secondary)' }}>{title}</div>
      <div style={{ borderTop: 'var(--border-width) solid var(--line)' }}>{children}</div>
    </>
  );
  const Row = ({ label, value, dot, danger }) => (
    <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-5)', padding: 'var(--space-5) var(--gutter)', borderBottom: 'var(--border-width) solid var(--line)', background: 'var(--surface)' }}>
      {dot && <span style={{ width: 7, height: 7, borderRadius: '50%', background: dot, display: 'block' }} />}
      <span style={{ font: 'var(--type-body)', color: danger ? 'var(--danger)' : 'var(--text-primary)' }}>{label}</span>
      <span style={{ marginLeft: 'auto', font: 'var(--type-meta)', letterSpacing: 'var(--tracking-meta)', color: 'var(--text-secondary)' }}>{value}</span>
    </div>
  );
  return (
    <>
      <ScreenHeader context="4 sources · 1 device" title="Settings" source={source} onSource={onSource} />
      <div style={{ flex: 1, minHeight: 0, overflowY: 'auto' }}>
        <Section title="PRICE SOURCES">
          <Row label="Card Ladder" value="CONNECTED" dot="var(--src-cl)" />
          <Row label="Courtyard" value="CONNECTED" dot="var(--src-cy)" />
          <Row label="Japanese market" value="CONNECTED" dot="var(--src-jp)" />
          <Row label="Default emphasis" value={source} />
        </Section>
        <Section title="PRICE REFRESH">
          <Row label="Automatic refresh" value="ON SCAN + DAILY" />
          <Row label="Last full refresh" value="AUG 19 · 09:12" />
          <Row label="Refresh on pull-down" value="ON" />
        </Section>
        <Section title="PAYOUT">
          <Row label="Payout provider" value="NOT SET" />
          <Row label="Default payout %" value="—" />
          <Row label="Buy ranges" value="2 OWNERS · 100 CARDS" />
        </Section>
        <Section title="SCANNER">
          <Row label="Torch default" value="ON" />
          <Row label="Zoom default" value="2.0×" />
          <Row label="Haptic on capture" value="ON" />
          <Row label="Duplicate certs" value="WARN, DON'T BLOCK" />
        </Section>
        <Section title="CSV">
          <Row label="Default columns" value="6 SELECTED" />
          <Row label="Filename pattern" value="INVENTORY_GROUP_DATE" />
        </Section>
        <Section title="ABOUT">
          <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-5)', padding: 'var(--space-5) var(--gutter)', borderBottom: 'var(--border-width) solid var(--line)', background: 'var(--surface)' }}>
            <span style={{ font: 'var(--type-body)' }}>How it works</span>
            <span style={{ marginLeft: 'auto' }}><Button variant="text" onClick={onReplayOnboarding}>Replay</Button></span>
          </div>
          <Row label="Version" value="1.0 (255)" />
          <Row label="Sign out" value="" danger />
        </Section>
        <div style={{ height: 'var(--space-8)' }} />
      </div>
    </>
  );
}
Object.assign(window, { SettingsScreen });
```

---

## `App.jsx`

```jsx
/* Click-through recreation of the whole loop:
   Scan → build inventory → price it → group it by buyer → filter → export CSV.
   Filter state is global across tabs; every count, total and filename recalculates
   from the same state, per spec §5. */
function App() {
  const { PhoneFrame, TabBar } = window.DS;
  const D = window.APP_DATA;
  const [onboarded, setOnboarded] = React.useState(false);
  const [tab, setTab] = React.useState('scan');
  const [source, setSource] = React.useState('CL');
  const [cards, setCards] = React.useState(D.cards);
  const [groups, setGroups] = React.useState(D.groups);
  const [filter, setFilter] = React.useState(null);
  const [pending, setPending] = React.useState(null);
  const [sheet, setSheet] = React.useState(null);
  const [selecting, setSelecting] = React.useState(false);
  const [selected, setSelected] = React.useState([]);
  const [scans, setScans] = React.useState(24);
  const [toast, setToast] = React.useState(null);
  const [columns, setColumns] = React.useState(['Cert', 'Name', 'Grade', 'Grader', 'CY Price', 'CY Conf']);
  const [refreshing, setRefreshing] = React.useState(false);
  const [refreshedAt, setRefreshedAt] = React.useState('AUG 19 · 09:12');

  const visible = filter === '__ungrouped' ? cards.filter((c) => !c.group)
    : filter ? cards.filter((c) => c.group === filter) : cards;

  const scan = () => {
    const pool = [
      { name: 'Japanese Sword & Shield VMAX Climax Umbreon', prices: { CL: 3120, CY: 3390, JP: '¥465K' }, year: 2023, category: 'Pokemon', cardNumber: '288', confidence: 5, grade: '10', grader: 'PSA' },
      { name: 'Ex Holon Phantoms 100 Mew Star', prices: { CL: 7450, CY: null, JP: null }, year: 2006, category: 'Pokemon', cardNumber: '100', confidence: 2, grade: '9', grader: 'CGC' },
    ];
    const dupe = scans % 5 === 3;
    if (dupe) {
      const c = cards[0];
      setToast({ name: c.name, note: 'ALREADY IN INVENTORY · #' + c.cert, grade: c.grade, grader: c.grader, dupe: true });
    } else {
      const base = pool[scans % pool.length];
      const c = { ...base, id: Date.now(), cert: String(84920200 + scans), group: null };
      setCards((cs) => [c, ...cs]);
      setScans((n) => n + 1);
      setToast({ name: c.name, note: 'MATCHED IN 0.6s · #' + c.cert, grade: c.grade, grader: c.grader, price: c.prices[source], dupe: false });
    }
    setTimeout(() => setToast(null), 1800);
  };

  const refresh = () => {
    setRefreshing(true);
    setTimeout(() => { setRefreshing(false); setRefreshedAt('AUG 19 · 09:41'); }, 1400);
  };

  const assign = (groupId, newName) => {
    let id = groupId;
    if (newName) {
      id = newName.toLowerCase().replace(/[^a-z0-9]+/g, '');
      setGroups((gs) => [{ id, name: newName, color: window.DS.GROUP_HUES[gs.length % 6], count: selected.length }, ...gs]);
    } else {
      setGroups((gs) => gs.map((g) => (g.id === id ? { ...g, count: g.count + selected.length } : g)));
    }
    setCards((cs) => cs.map((c) => (selected.includes(c.id) ? { ...c, group: id } : c)));
    setSelected([]); setSelecting(false); setSheet(null);
  };

  if (!onboarded) {
    return <PhoneFrame><Onboarding onDone={() => setOnboarded(true)} /></PhoneFrame>;
  }

  let body;
  if (tab === 'scan') body = <ScanScreen source={source} onSource={setSource} count={scans} onScan={scan} toast={toast} />;
  else if (tab === 'cards') body = (
    <InventoryScreen
      source={source} onSource={setSource} cards={visible}
      filterGroup={filter} groups={groups}
      onOpenFilters={() => { setPending(filter); setSheet('filters'); }}
      onClearFilter={() => setFilter(null)}
      selecting={selecting} selected={selected}
      onStartSelect={() => setSelecting(true)}
      onCancelSelect={() => { setSelecting(false); setSelected([]); }}
      onSelectAll={() => setSelected(visible.map((c) => c.id))}
      onToggleSelect={(id) => setSelected((s) => (s.includes(id) ? s.filter((x) => x !== id) : [...s, id]))}
      onAction={(a) => {
        if (a === 'group') setSheet('group');
        else if (a === 'export') { setSelecting(false); setTab('export'); }
        else if (a === 'remove') { setCards((cs) => cs.map((c) => (selected.includes(c.id) ? { ...c, group: null } : c))); setSelected([]); setSelecting(false); }
        else if (a === 'delete') { setCards((cs) => cs.filter((c) => !selected.includes(c.id))); setSelected([]); setSelecting(false); }
      }}
      refreshing={refreshing} refreshedAt={refreshedAt} onRefresh={refresh}
    />
  );
  else if (tab === 'export') body = (
    <ExportScreen source={source} onSource={setSource} cards={visible} filterGroup={filter} groups={groups}
      onOpenFilters={() => { setPending(filter); setSheet('filters-export'); }}
      onClearFilter={() => setFilter(null)}
      columns={columns}
      onToggleColumn={(c) => setColumns((cs) => (cs.includes(c) ? cs.filter((x) => x !== c) : [...cs, c]))} />
  );
  else body = <SettingsScreen source={source} onSource={setSource} onReplayOnboarding={() => setOnboarded(false)} />;

  // Buy-range membership is derived so the sheet's counts add up to the inventory:
  // a card sits inside exactly one owner's range, or it is unmatched.
  const matched = cards.filter((c) => c.confidence >= 4);
  const ranges = D.ranges.map((r, i) => ({ ...r, count: i === 0 ? Math.max(matched.length - 1, 0) : Math.min(matched.length, 1) }));

  const pendingCount = pending === '__ungrouped' ? cards.filter((c) => !c.group).length
    : pending ? cards.filter((c) => c.group === pending).length : cards.length;

  return (
    <PhoneFrame>
      {body}
      {sheet === 'group' && (
        <GroupSheet count={selected.length} groups={groups} onClose={() => setSheet(null)} onAssign={assign} />
      )}
      {(sheet === 'filters' || sheet === 'filters-export') && (
        <FiltersSheet
          mode={sheet === 'filters-export' ? 'export' : 'cards'}
          groups={groups} ranges={ranges} stats={{ count: cards.length }}
          ungrouped={cards.filter((c) => !c.group).length} unmatched={cards.length - matched.length}
          value={pending} onChange={setPending}
          resultCount={pendingCount}
          onClose={() => setSheet(null)}
          onConfirm={() => { setFilter(pending); setSheet(null); }}
        />
      )}
      {!selecting && <TabBar value={tab} onChange={setTab} />}
      {selecting && <TabBar value="cards" onChange={setTab} />}
    </PhoneFrame>
  );
}
Object.assign(window, { App });
```
