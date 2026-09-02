# StudyBlock task CSV format

Two ways to use this:

- **Fill it in yourself.** Save `StudyBlock-tasks-template.csv`, edit it, then
  in StudyBlock open **Tasks → CSV → Import CSV…**.
- **Have an AI write it.** Open **Tasks → CSV → Prompt for AI**, copy the
  prompt, paste it into a chat, and describe your assignments in plain
  English. Then either save the reply as a `.csv` and import it, or paste the
  reply straight into **Tasks → CSV → Paste CSV…** — commentary, code fences,
  and even a markdown table are stripped automatically.
- **Paste a snippet.** You never need a whole file. Copy one row — or twenty —
  and hit **⌘⇧V** on the Tasks board, or the clipboard button in the quick-add
  bar. A single row can also just be typed or pasted into the quick-add field
  and submitted with return.

The copied prompt is built fresh each time you open it. It states today's
date (so "next Friday" resolves to a real day), lists the categories already
on your board with the color each one uses (so the AI joins them instead of
inventing near-duplicates), and tells the AI to **ask you questions first**
about anything you left out — when a recurring task should stop, a due time,
which course something belongs to — instead of guessing. Let it ask; the CSV
comes out right the first time.

## Rules

- A file starts with a header row. **Only `title` is required** — any other
  column can be omitted entirely or left blank.
- Column order doesn't matter. Unknown columns are ignored.
- Wrap a value in `"double quotes"` if it contains a comma, a quote, or a line
  break (double a literal quote: `""`).

**Pasted snippets don't need a header.** With no header line the columns are
read in the standard order below, cut to however many you actually wrote — so
`Essay,History,amber,2026-09-04` is a title, a category, a color and a due
date. A paste where every line is a single field is treated as a plain list of
task names.

Which is why, if you paste a snippet, the column *order* does matter. Include
the header line whenever your columns aren't in the standard order.

## Columns

The columns are the controls in the app's task sheets, one for one — so
anything you can set on a task, you can write in a row.

| Column | Meaning | Accepted values |
| --- | --- | --- |
| `title` | **Required.** The task name. | any text |
| `category` | Course/subject, free text. | e.g. `History`, `CSDS302` |
| `color` | Color for that category. Set once; it applies everywhere that category appears. | `red` `orange` `amber` `lime` `green` `spring` `cyan` `sky` `blue` `violet` `magenta` `pink`, or a hue number `0`–`359` |
| `due_date` | Day it's due. For a repeating task, the **first** due date. Blank for no due date. | `YYYY-MM-DD` |
| `due_time` | Time of day. Leave blank for "sometime that day". | `HH:mm` (24-hour), e.g. `23:59` |
| `repeat` | The whole schedule, as one code. Blank means it doesn't repeat. | see the legend below |
| `repeat_until` | Last day a repeating task runs. **Blank means it repeats indefinitely.** | `YYYY-MM-DD` |
| `notes` | Anything else worth keeping. Last on the line on purpose — see below. | any text |

Those eight are the whole authoring format, and they're all the template and the
AI prompt ask for.

Two of those choices are deliberate, and both exist because the way a
generated file fails is almost never a wrong *value* — it's a row with the
wrong number of *fields*, which silently shifts every column after the
mistake:

- **The schedule is one `repeat` code**, not a rule column plus a separate
  weekday column. One fewer column is one fewer chance to misalign a row.
- **`notes` is last.** It's the field most likely to contain a comma somebody
  forgot to quote. At the end of the line that costs you a truncated note;
  anywhere else it corrupts every column after it.

Export writes a few more — `status`, `list`, `completed_at`, `created_at`,
`id`, `series_id`, `manual_order` — which are bookkeeping StudyBlock fills in
itself. You can include them (`status` = `todo`/`done` and `list` = a column
name are both honoured), but you never need to. On import, a row whose `id`
matches an existing task **updates** that task instead of adding a duplicate,
which is what makes re-importing an export safe.

A CSV written for the older format — with `category_color`, a word like
`weekly` in `repeat`, and a separate `repeat_weekdays` column — still imports
correctly.

## The `repeat` legend

| Code | Means |
| --- | --- |
| *(blank)* | doesn't repeat |
| `d` | every day |
| `3d` | every 3 days |
| `w` | every week, on whatever day `due_date` falls on |
| `2w` | every 2 weeks |
| `w:mon wed fri` | every week on Mon, Wed and Fri |
| `2w:tue` | every other Tuesday |
| `m` | every month, on the same day of the month |
| `3m` | every 3 months |
| `12m` | every year |

Read it as three parts:

```
2w:tue
│└─ unit: d = days, w = weeks, m = months
└── how many (leave it off for 1)
     └─ after the colon: which weekdays (weekly only)
```

Weekdays are `mon tue wed thu fri sat sun`, space-separated. They only apply to
a weekly code; leave them off and it repeats on whatever day `due_date` falls
on. Numbers (`1` = Sunday … `7` = Saturday) and full day names work too, and
`weekdays` on its own means Mon–Fri.

You don't have to use the codes. Plain English is accepted for the common
cases: `daily`, `weekly`, `monthly`, `yearly`, `every 3 days`,
`every other week`, `biweekly`, `weekly on mon,wed`. Anything it can't read is
reported as a warning after the import rather than guessed at.

**On `2w` and calendar weeks.** An every-other-week task skips whole calendar
weeks. `2w:mon wed fri` starting on Wednesday Sept 2 gives you Wed Sept 2 and
Fri Sept 4, then skips the week of Sept 7 entirely and resumes on Mon Sept 14 —
it does not treat "two weeks from Wednesday" as its own private cycle.

## Recurring tasks: one row, many tasks

Write **one row per recurring task, not one row per occurrence.** StudyBlock
expands it on import into real, independent copies — one per due date — the
same as if you'd used the **Recurring** button in the app.

```csv
title,category,color,due_date,due_time,repeat,repeat_until,notes
Discussion post,History,amber,2026-09-01,23:59,w:tue,2026-12-11,
```

That single line creates **15 tasks**, one for each Tuesday from Sept 1 through
Dec 11. Each is a normal task: complete, edit, reschedule, or delete any one of
them without touching the rest.

Leave `repeat_until` blank and the task repeats indefinitely. StudyBlock
materialises the first **100** copies up front, and every time you finish one
it adds another to the end, so you never run out.

Don't write this — the app does it for you:

```csv
Discussion post week 1,...,2026-09-01,...
Discussion post week 2,...,2026-09-08,...
```

After an import, StudyBlock tells you exactly how many tasks each recurring row
produced, so a single `w:tue` line becoming 100 cards is never a surprise.

## Example

```csv
title,category,color,due_date,due_time,repeat,repeat_until,notes
Essay on the Reformation,History,amber,2026-09-04,23:59,,,"Thesis, outline, then draft"
Problem set 3,CSDS302,blue,2026-09-01,,,,
Lecture reading,CSDS302,blue,2026-08-28,08:00,w:mon wed fri,2026-12-11,Ch. 5 pp. 90-120
Lab report,CSDS302,blue,2026-09-04,17:00,2w:fri,2026-12-11,
Standup,,,2026-09-01,09:00,d,,
Water the plants,,,,,,,
```

Row by row: a one-off essay, with a note containing commas so it's quoted; a
one-off problem set; a lecture reading every Mon/Wed/Fri until Dec 11
(**46 tasks**); a lab report every other Friday (**8 tasks**); a daily standup
with no end date (**100 tasks**, topped up as you complete them); and a task
with no category and no due date, which is perfectly valid.
