- **🔗 Backlinks**
  - The Backlinks feature allows you to instantly see all other pages and journal entries in your Logseq vault that link to the note you are currently reading.
  - **⚙️ Setup & Configuration**
    - The Backlinks module is designed to work out of the box once your plugin is initialized. It does not require creating any special markdown files in your vault.
  - **🚀 How to use**
    - **Toggle View:** Press `<Leader>b` while inside any Markdown file in your vault. A `## Backlinks` section will instantly appear at the bottom of your file.
    - **Hide View:** Press `<Leader>b` again to remove the backlinks section.
    - **Navigate:** Move your cursor to any of the listed backlinks and press your follow-link key (`<CR>` by default) to jump straight to that file.
  - **🧠 How it works**
    - Behind the scenes, the plugin performs a high-speed text search across your `pages/` and `journals/` directories for your current page's wikilink (e.g., `[[My Project]]`).
    - It then parses the context around those links and injects a temporary, read-only Markdown block at the end of your buffer.
    - It wraps this section in hidden HTML comments (``) so the plugin knows exactly what to delete when you toggle the view off.
    - Because it relies on buffer injection rather than physical file modification, your actual `.md` file remains clean when you close it.
  - **🖼️ Interface Examples**
    - Here is exactly what the interface looks like before and after pressing `<Leader>b`.
    - **State 1: Normal Editing Mode**
      - You are reviewing a note. It's just your standard Markdown text.
      - ```text
        +------------------------------------------------------------------------------+
        | ~/Logseq/pages/BJJ___Techniques___Triangle.md                                |
        +------------------------------------------------------------------------------+
        | - **Triangle Choke** |
        |   - Focus on hip elevation.                                                  |
        |   - Secure the wrist before locking the legs.                                |
        |   - If posture is broken, transition to armbar.                              |
        |                                                                              |
        |                                                                              |
        |                                                                              |
        |                                                                              |
        |                                                                              |
        |                                                                              |
        |                                                                              |
        |                                                                              |
        |                                                                              |
        |                                                                              |
        | ~                                                                            |
        | ~                                                                            |
        | NORMAL  BJJ___Techniques