# comment-translate.nvim

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-%3E=0.10-blue)](https://neovim.io)

**English** | [简体中文](README.zh-CN.md)

Translate comments and strings directly in Neovim using hover or immersive inline views.
Supports classic translation APIs as well as LLM backends, including fully local models via Ollama.

![Hover translation demo](assets/demo.gif)

## About This Fork

This is a fork of [noir4y/comment-translate.nvim](https://github.com/noir4y/comment-translate.nvim),
which provides hover and inline translation of code comments and strings. All of
that behaviour is preserved here.

What this fork adds is an **immersive bilingual reading mode for prose**: open a
Markdown file, help page or plain-text document and each paragraph gets its
translation rendered directly beneath it, the way a browser reading extension
works. Everything below marked "added in this fork" is new; the rest comes from
upstream.

### Added in this fork

| Capability | Description |
|---|---|
| Document reading mode | Paragraph-level bilingual view for `markdown`, `text`, `help`, `rst` and `org` buffers, rendered as virtual lines below the source |
| Viewport-driven translation | What you are reading is translated first, with a prefetch band around the window; the rest waits until you scroll to it |
| Structure-aware extraction | Headings, quotes and list items are translated as units; code fences, front matter, HTML blocks and tables are skipped |
| URL and image stripping | Links keep only their visible label and images are dropped, so no URL, token or filename is ever sent to a translation service |
| Automatic line wrapping | Translations are wrapped to the window width, measured in display cells so CJK text stays readable |
| Profile-aware cache | Cache keys include service, provider, model, endpoint and prompt, so two models cannot return each other's translations |
| Reasoning model support | Opt-in `thinking` / `reasoning_effort` control, with reasoning traces excluded from rendered output |
| Bounded concurrency | A configurable ceiling on in-flight requests, shared across buffers |

Upstream capabilities that continue to work unchanged: hover translation,
visual-selection replace, Tree-sitter aware comment and string detection, the
Google and LLM backends, and the existing `:CommentTranslate*` commands.

## Why This Plugin

Many translation plugins rely on external services only. `comment-translate.nvim` is designed for teams and individuals who want a practical choice:

- Use hosted providers when you want quality and speed.
- Use local LLMs when you need stronger privacy and control.
- Keep your translation workflow inside Neovim.

## Key Benefits

- Immersive bilingual reading for documents, not just code comments
- LLM translation support (`openai`, `anthropic`, `gemini`, `ollama`)
- Local LLM workflow via Ollama (no source text sent to cloud APIs)
- Hover translation for quick understanding
- Replace selected text with translation
- Tree-sitter aware comment/string detection
- The source file is never modified — translations live in the display layer only

## Security and Privacy

This plugin gives you control over where your text goes:

- `translate_service = 'google'` or hosted `llm` providers: text is sent to the configured remote service.
- `llm.provider = 'ollama'` with the default local endpoint keeps translation local; if `llm.endpoint` is set to a remote host, text is sent there.
- API keys and source text/request bodies are passed to `curl` through stdin config, not through process arguments.
- Cache is in-memory only and is not persisted to disk by this plugin.

For sensitive repositories, local Ollama models are the recommended setup.

## Requirements

- Neovim 0.10+
- `curl`
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) (required)
- Tree-sitter parser support for the languages you want to inspect (recommended)

Note: Internet is not required when you use local translation only (for example, Ollama running locally).

Parsers may come from bundled Neovim parsers, manual installation, or
parser-providing plugin setups such as `nvim-treesitter`.
`comment-translate.nvim` uses Neovim's built-in Tree-sitter APIs and does not
require the `nvim-treesitter` plugin itself.

## Installation

### lazy.nvim

```lua
{
  'noir4y/comment-translate.nvim',
  dependencies = {
    'nvim-lua/plenary.nvim',
  },
  config = function()
    require('comment-translate').setup({})
  end,
}
```

### packer.nvim

```lua
use {
  'noir4y/comment-translate.nvim',
  requires = {
    'nvim-lua/plenary.nvim',
  },
  config = function()
    require('comment-translate').setup({})
  end,
}
```

If you already manage parsers through `nvim-treesitter`, you can keep doing so.

## Usage

### Hover Translation

```lua
vim.keymap.set('n', '<leader>th', '<cmd>CommentTranslateHover<CR>', { silent = true })
```

### Immersive Translation

```vim
:ImmersiveTranslateToggle
```

In `markdown` and `text` buffers this renders a bilingual reading view: each
paragraph, heading, quote and list item gets its translation shown directly
beneath it as virtual lines. The file itself is never modified — translations
live only in the display layer, so buffer contents, undo history and
`changedtick` are untouched and the mode is safe to leave on while editing.

Translation is driven by what you are actually reading. Paragraphs in the
window are fetched first, a band above and below is prefetched so scrolling
stays smooth, and the rest waits. Long documents therefore become readable
immediately instead of after the whole file has been translated.

Fenced code blocks, front matter, HTML blocks, tables and indented code are
skipped. Links keep their visible label and lose their URL, and images are
removed entirely, so no URL is ever sent to the translation service.

In other filetypes the same command keeps the previous behaviour of
translating comments and strings.

| Command | Action |
|---|---|
| `:ImmersiveTranslateToggle` | Turn immersive translation on or off |
| `:ImmersiveTranslateRefresh` | Re-extract and refresh the current buffer |
| `:ImmersiveTranslateRefresh!` | As above, but also drop this buffer's cached translations |
| `:ImmersiveTranslateClearCache` | Empty the in-memory cache and refetch the visible region |

The previous `:CommentTranslateToggle` and `:CommentTranslateUpdate` names
remain available.

### Replace Selected Text

```vim
:CommentTranslateReplace
```

### Reasoning Models

Reasoning ("thinking") models are supported and disabled by default, since
translation rarely needs deliberation and reasoning adds latency and cost.

```lua
require('comment-translate').setup({
  translate_service = 'llm',
  llm = {
    provider = 'openai',      -- or 'anthropic'
    model = 'deepseek-v4-flash',
    endpoint = 'https://api.deepseek.com/v1/chat/completions',
    reasoning = {
      enabled = true,
      effort = 'high',        -- openai/ollama-shaped providers
      budget_tokens = 1024,   -- anthropic-shaped providers
    },
  },
})
```

`effort` is sent as `reasoning_effort` to OpenAI-compatible endpoints;
`budget_tokens` becomes an Anthropic `thinking` block, with `max_tokens` raised
above the budget and `temperature` omitted, as that API requires. Reasoning
traces are never rendered: Anthropic `thinking` blocks and OpenAI
`reasoning_content` fields are ignored, and only the translation is shown.

## Configuration Example

If `target_language` is omitted, comment-translate uses your system locale and falls back to `en`.

```lua
require('comment-translate').setup({
  target_language = 'ja', -- example override; default is system locale or 'en'
  translate_service = 'google', -- 'google' or 'llm'

  hover = {
    enabled = true,
    delay = 500,
    auto = true,
  },

  immersive = {
    -- Filetypes read as documents; everything else translates comments only.
    mode_by_filetype = { markdown = 'document', text = 'document' },
    default_mode = 'comment',
    viewport = true,       -- fetch what is on screen first
    prefetch_lines = 40,   -- buffer lines above/below the window to prefetch
    concurrency = 2,       -- max simultaneous requests, shared across buffers
    debounce_ms = 120,     -- quiet period after scrolling
    min_chars = 3,         -- skip targets shorter than this
    max_target_length = 3000,
    render = { hl_group = 'Comment', prefix = '' },
    enabled = false,
  },

  cache = {
    enabled = true,
    max_entries = 1000,
  },

  max_length = 5000,

  targets = {
    comment = true,
    string = true,
  },

  llm = {
    provider = 'openai', -- 'openai' | 'anthropic' | 'gemini' | 'ollama'
    model = 'gpt-5.2',
    api_key = nil, -- can also use provider-specific env vars
    timeout = 20,
    endpoint = nil, -- optional, http(s) only
    system_prompt = nil,
  },

  keymaps = {
    hover = '<leader>th',
    hover_manual = '<leader>tc',
    replace = '<leader>tr',
    toggle = '<leader>tt',
  },
})
```

## LLM Provider Examples

### Local (Ollama)

```lua
require('comment-translate').setup({
  translate_service = 'llm',
  llm = {
    provider = 'ollama',
    model = 'translategemma:4b',
  },
})
```

### Hosted (OpenAI)

```lua
require('comment-translate').setup({
  translate_service = 'llm',
  llm = {
    provider = 'openai',
    api_key = vim.env.OPENAI_API_KEY,
    model = 'gpt-5.2',
  },
})
```

## Commands

- `:CommentTranslateHover`       — Display translation under cursor
- `:CommentTranslateHoverToggle` — Toggle auto hover on/off
- `:CommentTranslateReplace`     — Replace selected text with translation
- `:CommentTranslateToggle`      — Toggle immersive translation globally
- `:CommentTranslateUpdate`      — Update immersive translation for current buffer
- `:CommentTranslateSetup`       — Setup plugin with default settings
- `:CommentTranslateHealth`      — Health check, including parser availability for the buffer that invoked it

Use `:checkhealth comment-translate` for general dependency and configuration checks.
Use `:CommentTranslateHealth` from the file buffer you want to inspect when you
also want parser availability checked for that buffer.

## Development

- Format: `make fmt`
- Format check: `make fmt-check`
- Lint: `make lint`
- Test: `make test`

## Credits

Forked from [noir4y/comment-translate.nvim](https://github.com/noir4y/comment-translate.nvim)
by [noir4y](https://github.com/noir4y), which provides the hover, replace,
provider and caching foundations this build extends. Licensed under MIT, as is
this fork.

## License

MIT
