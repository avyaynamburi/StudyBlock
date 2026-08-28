# StudyBlock task CSV format

Two ways to use this:

- **Fill it in yourself.** Save `StudyBlock-tasks-template.csv`, edit it, then
  in StudyBlock open **Tasks → CSV → Import CSV…**.
- **Have an AI write it.** Open **Tasks → CSV → Prompt for AI**, copy the
  prompt, paste it into a chat, and describe your assignments in plain
  English. Then either save the reply as a `.csv` and import it, or paste the
  reply straight into **Tasks → CSV → Paste CSV…** — commentary, code fences,
  and even a markdown table are stripped automatically.

The built-in prompt tells the AI to **ask you questions first** about anything
you didn't specify — when a recurring task should stop, what "next Friday"
means, a due time, which course something belongs to — instead of inventing an
answer. Let it ask; the CSV comes out right the first time.

## Rules

- The first line must be a header row. **Only `title` is required** — any other
  column can be omitted entirely or left blank.
- Column order doesn't matter. Unknown columns are ignored.
- Wrap a value in `"double quotes"` if it contains a comma, a quote, or a line
  break (double a literal quote: `""`).

## Columns

| Column | Meaning | Accepted values |
| --- | --- | --- |
| `title` | **Required.** The task name. | any text |
| `notes` | Longer description. | any text |
| `category` | Course/subject, free text. | e.g. `History`, `CSDS302` |
| `category_color` | Color for that category. Set once; it applies everywhere that category appears. | `red` `orange` `amber` `lime` `green` `spring` `cyan` `sky` `blue` `violet` `magenta` `pink`, or a hue number `0`–`359` |
| `due_date` | Day it's due. For a recurring task, the **first** due date. Blank for no due date. | `YYYY-MM-DD` |
| `due_time` | Time of day. Leave blank for "sometime that day". | `HH:mm` (24-hour), e.g. `23:59` |
| `priority` | | `none` `low` `medium` `high` (also accepts `!` `!!` `!!!` or `0`–`3`) |
| `repeat` | Recurrence. Blank means none. | `none` `daily` `weekly` `monthly` |
| `repeat_weekdays` | Which days, when `repeat` is `weekly`. Blank = repeat on whatever weekday `due_date` falls on. | `mon tue wed thu fri sat sun` (space- or comma-separated; full names and numbers `1`=Sun…`7`=Sat also work) |
| `repeat_until` | Last day a recurring task runs. **Blank means it repeats indefinitely.** | `YYYY-MM-DD` |

Those ten are the whole authoring format, and they're all the template and the
AI prompt ask for.

Export writes a few more — `status`, `list`, `completed_at`, `created_at`,
`id`, `series_id`, `manual_order` — which are bookkeeping StudyBlock fills in
itself. You can include them (`status` = `todo`/`done` and `list` = a column
name are both honoured), but you never need to. On import, a row whose `id`
matches an existing task **updates** that task instead of adding a duplicate,
which is what makes re-importing an export safe.

## Recurring tasks: one row, many tasks

Write **one row per recurring task, not one row per occurrence.** StudyBlock
expands it on import into real, independent copies — one per due date — the
same as if you'd used the **Recurring** button in the app.

```csv
title,notes,category,category_color,due_date,due_time,priority,repeat,repeat_weekdays,repeat_until
Discussion post,,History,amber,2026-09-01,23:59,high,weekly,tue,2026-12-11
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
produced, so a single `weekly` line becoming 100 cards is never a surprise.

## Example

```csv
title,notes,category,category_color,due_date,due_time,priority,repeat,repeat_weekdays,repeat_until
Essay on the Reformation,"Thesis, outline, then draft",History,amber,2026-09-04,23:59,high,none,,
Problem set 3,,CSDS302,blue,2026-09-01,,medium,,,
Lecture reading,Ch. 5 pp. 90-120,CSDS302,blue,2026-08-28,08:00,low,weekly,mon wed fri,2026-12-11
Standup,,,,2026-09-01,09:00,none,daily,,
Water the plants,,,,,,low,,,
```

Row by row: a one-off essay; a one-off problem set; a lecture reading every
Mon/Wed/Fri until Dec 11 (**46 tasks**); a daily standup with no end date
(**100 tasks**, topped up as you complete them); and a task with no category
and no due date, which is perfectly valid.
