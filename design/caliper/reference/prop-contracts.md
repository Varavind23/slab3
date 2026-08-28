# Prop contracts

The TypeScript prop interfaces for every component, as the authoritative list of what
each one takes and what each prop means. Translate these into Swift initializers.


---

## Button

```ts
/**
 * Caliper button. One cyan primary per screen; everything else outline or bare text.
 */
export interface ButtonProps {
  /** primary = filled cyan (one per screen); outline = hairline control; accent = cyan outline; text/danger = bare. */
  variant?: 'primary' | 'outline' | 'accent' | 'text' | 'danger';
  icon?: React.ReactNode;
  disabled?: boolean;
  fullWidth?: boolean;
  children?: React.ReactNode;
  onClick?: () => void;
  style?: React.CSSProperties;
}
export function Button(props: ButtonProps): JSX.Element;
```

---

## Chip

```ts
/**
 * Mono badge: grade, export column, or state tag.
 */
export interface ChipProps {
  children?: React.ReactNode;
  /** default = filled surface; quiet = outline only; filled = cyan; source = tinted to a price-source hue. */
  tone?: 'default' | 'quiet' | 'filled' | 'source';
  /** Numeric order badge, for export column chips (selection order = column order). */
  order?: number;
  /** Hue for tone="source" / the order badge, e.g. var(--src-cy). */
  color?: string;
  style?: React.CSSProperties;
}
export function Chip(props: ChipProps): JSX.Element;
```

---

## Icon

```ts
/**
 * Lucide glyph, standing in for the app's SF Symbols.
 */
export interface IconProps {
  /** Lucide icon name, kebab-case (e.g. "scan-barcode", "folder", "menu"). */
  name: string;
  /** Pixel box. Body-size glyphs are 17; caption-size 13. */
  size?: number;
  strokeWidth?: number;
  /** "none" for outlined (the default in Slabs), "currentColor" for filled. */
  fill?: string;
  color?: string;
  style?: React.CSSProperties;
}
export function Icon(props: IconProps): JSX.Element;
```

---

## SourceToggle

```ts
export type PriceSource = 'CL' | 'CY' | 'JP';
export const SOURCES: { id: PriceSource; label: string; color: string }[];

/**
 * Three-way price-source switcher. Persists across tabs; changes emphasis and sort
 * basis only — never hides the other sources.
 */
export interface SourceToggleProps {
  value?: PriceSource;
  onChange?: (source: PriceSource) => void;
}
export function SourceToggle(props: SourceToggleProps): JSX.Element;
```

---

## PriceTriple

```ts
import type { PriceSource } from './SourceToggle';

/** Prices keyed by source. JP may be a preformatted yen string (e.g. "¥1.74M"). */
export interface PriceMap { CL?: number | null; CY?: number | null; JP?: number | string | null }

/**
 * The active source's price, set large in its hue. Missing data renders an em dash.
 */
export interface PriceTripleProps {
  prices?: PriceMap;
  source?: PriceSource;
  /** Render all three side by side instead of leading with the active one. */
  inline?: boolean;
}
export function PriceTriple(props: PriceTripleProps): JSX.Element;

/** The two non-active prices as a "$4,177 CL · — JP" string, for the meta line. */
export function PriceRest(props: { prices?: PriceMap; source?: PriceSource }): JSX.Element;
```

---

## ConfidenceMeter

```ts
/**
 * Five-segment match-confidence meter, red/amber/green.
 */
export interface ConfidenceMeterProps {
  /** 0–5. 0–1 reads red, 2–3 amber, 4–5 green. */
  value?: number;
  segments?: number;
}
export function ConfidenceMeter(props: ConfidenceMeterProps): JSX.Element;
```

---

## GroupTag

```ts
export const GROUP_HUES: string[];

/**
 * Buyer-group chip: color dot plus the group's name.
 */
export interface GroupTagProps {
  /** The group's name verbatim — these are user strings, never title-cased. */
  name: string;
  /** One of GROUP_HUES. */
  color?: string;
  /** sm = on a card row; md = in a filter pill or sheet row. */
  size?: 'sm' | 'md';
}
export function GroupTag(props: GroupTagProps): JSX.Element;
```

---

## CardRow

```ts
import type { PriceMap } from './PriceTriple';
import type { PriceSource } from './SourceToggle';

/**
 * One inventory row: thumbnail, name, three prices, year/category/#, confidence,
 * cert, group, grade. The densest component in the system.
 */
export interface CardRowProps {
  /** Long flattened card name, e.g. "Japanese Rulers of the Heavens Rayquaza". Truncates. */
  name: string;
  prices?: PriceMap;
  /** Which source is emphasized. Comes from the global SourceToggle. */
  source?: PriceSource;
  year?: number | string;
  /** e.g. "Pokemon", "One Piece". */
  category?: string;
  /** Card number within the set, rendered as "#4". */
  cardNumber?: string | number;
  /** Match confidence 0–5. */
  confidence?: number;
  /** Cert number, 8–9 digits. Rendered with a leading #. */
  cert?: string;
  /** Group name, if the card is in one. A card is in zero or one group. */
  group?: string;
  groupColor?: string;
  grade?: string;
  grader?: 'PSA' | 'CGC' | string;
  /** Selection mode: shows the circle. The list must not reflow when this flips. */
  selectable?: boolean;
  selected?: boolean;
  onToggle?: () => void;
  onClick?: () => void;
  /** URL of the slab photo. Falls back to a labelled placeholder. */
  thumbnail?: string;
}
export function CardRow(props: CardRowProps): JSX.Element;

export function Thumbnail(props: { src?: string }): JSX.Element;
```

---

## SummaryBlock

```ts
/**
 * Inventory value and estimated payout, with the match counter. Recalculates on filter.
 */
export interface SummaryBlockProps {
  /** Raw inventory value in dollars. */
  total: number;
  /** What the sourcer would receive if matched cards sold into their buy ranges. */
  payout: number;
  matched: number;
  /** Total cards in the current scope. */
  of: number;
  /** True when a filter is active — swaps the label to "Group total". */
  scoped?: boolean;
}
export function SummaryBlock(props: SummaryBlockProps): JSX.Element;
```

---

## ScreenHeader

```ts
import type { PriceSource } from '../data/SourceToggle';

/**
 * Context line + source toggle + dynamic page title. On every tab, in this order.
 */
export interface ScreenHeaderProps {
  /** Live scope string, e.g. "255 cards", "3 of 255 selected", "inventory.csv · 4 rows". */
  context: React.ReactNode;
  /** "active" turns the context line cyan — used in selection mode. */
  contextTone?: 'default' | 'active';
  /** Page title. Becomes the group name when a filter is applied. */
  title: React.ReactNode;
  source?: PriceSource;
  onSource?: (s: PriceSource) => void;
  /** Extra control beside the toggle, e.g. the manual-entry pencil on Scan. */
  trailing?: React.ReactNode;
  /** Text actions on the title line, e.g. Select / Select all / Cancel. */
  actions?: React.ReactNode;
}
export function ScreenHeader(props: ScreenHeaderProps): JSX.Element;
```

---

## TabBar

```ts
/**
 * Four-tab bottom bar: Scan, Cards, Export, Settings.
 */
export interface TabBarProps {
  value?: 'scan' | 'cards' | 'export' | 'settings';
  onChange?: (tab: 'scan' | 'cards' | 'export' | 'settings') => void;
}
export function TabBar(props: TabBarProps): JSX.Element;
```

---

## Sheet

```ts
/**
 * Bottom sheet shell for Groups and Filters, with a sticky live-count confirm.
 */
export interface SheetProps {
  title: React.ReactNode;
  /** Top-right action, e.g. "Clear all" (only render it when something is active). */
  trailing?: React.ReactNode;
  children?: React.ReactNode;
  /** Sticky confirm. Its label must carry the live count. */
  confirm?: React.ReactNode;
  onClose?: () => void;
}
export function Sheet(props: SheetProps): JSX.Element;

export interface SheetRowProps {
  leading?: React.ReactNode;
  label: React.ReactNode;
  sub?: React.ReactNode;
  trailing?: React.ReactNode;
  active?: boolean;
  onClick?: () => void;
}
export function SheetRow(props: SheetRowProps): JSX.Element;
```

---

## SelectionBar

```ts
/**
 * Selection-mode action bar: count, running dollar total, and four actions.
 */
export interface SelectionBarProps {
  count?: number;
  /** Running total of the selection. The reason the mode exists — never omit it. */
  total?: number;
  onAction?: (action: 'group' | 'remove' | 'export' | 'delete') => void;
}
export function SelectionBar(props: SelectionBarProps): JSX.Element;
```

---

## FilterPill

```ts
/**
 * Filter control. Unfiltered: "All cards" + chevron. Filtered: the group chip + inline ×.
 */
export interface FilterPillProps {
  /** Active group name, or undefined for "All cards". */
  group?: string;
  groupColor?: string;
  onOpen?: () => void;
  onClear?: () => void;
}
export function FilterPill(props: FilterPillProps): JSX.Element;
```

---

## SearchSortBar

```ts
/**
 * Scope-aware search field plus the sort control.
 */
export interface SearchSortBarProps {
  /** Cards in the current scope — goes straight into the placeholder. */
  count?: number;
  sort?: string;
  dir?: '↑' | '↓';
  onSort?: () => void;
}
export function SearchSortBar(props: SearchSortBarProps): JSX.Element;
```

---

## PhoneFrame

```ts
/**
 * 393×852 dark phone viewport. No light mode exists in this system.
 */
export interface PhoneFrameProps {
  children?: React.ReactNode;
  time?: string;
  style?: React.CSSProperties;
}
export function PhoneFrame(props: PhoneFrameProps): JSX.Element;
```
