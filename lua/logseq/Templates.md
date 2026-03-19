- **📝 Templates**
	- The Templates system allows you to define a standard structure for new pages based on their **Namespace**. It automates metadata entry and boilerplate text using interactive prompts.
	- **⚙️ Setup & Configuration**
		- Templates are stored as regular Markdown files in your `pages/` directory using a specific naming convention: `Templates___[Namespace].md`.
		- **Creating a Template**
			- If you want a template for the `Project` namespace (e.g., `Project/Website`), create a page named `Templates/Project`.
			- Logseq will save this file as `pages/Templates___Project.md`.
		- **Placeholder Syntax**
			- `%TEXT%` — Triggers a free-form text input box in Neovim.
			- `%Opt 1% / %Opt 2% / %Opt 3%` — Triggers a selection menu (dropdown) to choose one value.
	- **🚀 How to use**
		- **Automatic Trigger:** When you open a brand-new, empty file that belongs to a namespace (e.g., `Project/New Project`), the plugin detects the empty buffer and automatically offers to apply the template.
		- **Manual Trigger:** Press `<Leader>t` on any page. If a matching template exists for that namespace, it will run the interactive prompts and inject the text.
		- **Selection:** Use `j/k` to navigate dropdown options and `<CR>` to confirm. For text inputs, simply type your value and hit `<CR>`.
	- **🧠 How it works**
		- The plugin identifies the namespace from the filename (everything before the first `___`).
		- It searches for a file starting with `Templates___` plus that namespace name.
		- It parses the template line-by-line. When it hits a placeholder, it halts execution and opens a Neovim UI component (`vim.ui.input` or `vim.ui.select`).
		- Once all placeholders are filled, it writes the processed text into your current buffer and saves the file.
	- **🖼️ Interface Examples** 
		- **State 1: The Template Definition (`Templates___Project.md`)**
			- ```text
			  - status:: %Active% / %On Hold% / %Completed%
			  - tags:: #project [[%TEXT%]]
			  - **Goal**
			    - %TEXT%
			  ```
		- **State 2: The Interactive Prompt (Neovim UI)**
			- When you open `Project___Website.md`, a menu appears at the top:
			- ```text
			  +------------------------------------------------------------------------------+
			  | Select for status:                                                           |
			  | 1. Active                                                                    |
			  | 2. On Hold                                                                   |
			  | 3. Completed                                                                 |
			  +------------------------------------------------------------------------------+
			  ```
		- **State 3: The Resulting Page**
			- After answering the prompts, your new page is ready:
			- ```text
			  +------------------------------------------------------------------------------+
			  | ~/Logseq/pages/Project___Website.md                                          |
			  +------------------------------------------------------------------------------+
			  | - status:: Active                                                            |
			  | - tags:: #project [[Marketing]]                                              |
			  | - **Goal** |
			  |   - Rebuild the landing page with better SEO.                                |
			  |                                                                              |
			  | ~                                                                            |
			  | NORMAL  Project___Website.md                           4:1        All      |
			  +------------------------------------------------------------------------------+
			  ```