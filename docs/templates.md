# Templates

The template system lets you define a standard structure for new pages based on their namespace. When you create a namespaced page (e.g. `Project/Website`), the plugin looks for a matching template and runs interactive prompts to fill in placeholders.

## Setting up a template

Templates are stored as regular Markdown files in `pages/` using the naming convention:

```
pages/Templates___<Namespace>.md
```

For example, a template for the `Project` namespace lives at `pages/Templates___Project.md`.

## Placeholder syntax

| Placeholder | Behaviour |
|-------------|-----------|
| `%TEXT%` | Prompts for free-text input |
| `%Opt A% / %Opt B%` | Prompts with a selection menu |

Multiple options are separated by ` / `.

## How it works

1. You open a new file whose name contains `___` (triple underscore — Logseq's namespace separator).
2. The plugin reads the namespace from the filename (everything before the first `___`).
3. It looks for `pages/Templates___<namespace>.md`.
4. It processes the template line by line. Each placeholder pauses execution and opens a `vim.ui.input` or `vim.ui.select` prompt.
5. Once all placeholders are filled, the processed text is written into the buffer.

The template is applied automatically on `BufNewFile`. You can also apply it manually with `<leader>t` on any page that has a matching template.
