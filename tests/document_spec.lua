---@diagnostic disable: undefined-global
-- Document (markdown/text) target extraction — design.md 5.1.

describe('parser.document', function()
  local document
  local config

  local function make_buf(lines, filetype)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    if filetype then
      vim.bo[bufnr].filetype = filetype
    end
    return bufnr
  end

  local function texts(targets)
    local out = {}
    for _, t in ipairs(targets) do
      table.insert(out, t.text)
    end
    return out
  end

  local function kinds(targets)
    local out = {}
    for _, t in ipairs(targets) do
      table.insert(out, t.kind)
    end
    return out
  end

  before_each(function()
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.parser.document'] = nil
    config = require('comment-translate.config')
    config.setup({})
    document = require('comment-translate.parser.document')
  end)

  describe('paragraphs', function()
    it('should merge consecutive non-empty lines into one target', function()
      local buf = make_buf({
        'First line of the paragraph',
        'second line of the same paragraph.',
        '',
        'A separate paragraph here.',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.equals(2, #targets)
      assert.equals(
        'First line of the paragraph second line of the same paragraph.',
        targets[1].text
      )
      assert.equals('A separate paragraph here.', targets[2].text)
    end)

    it('should anchor a paragraph at its last row', function()
      local buf = make_buf({
        'line one',
        'line two',
        'line three',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.equals(1, #targets)
      assert.equals(0, targets[1].start_row)
      assert.equals(2, targets[1].end_row)
    end)

    it('should collapse runs of whitespace', function()
      local buf = make_buf({ 'spaced    out\ttext   here' }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.equals('spaced out text here', targets[1].text)
    end)
  end)

  describe('headings', function()
    it('should extract ATX headings without markers', function()
      local buf = make_buf({
        '# Title Here',
        '',
        '### Deeper Heading',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.same({ 'heading', 'heading' }, kinds(targets))
      assert.same({ 'Title Here', 'Deeper Heading' }, texts(targets))
    end)

    it('should anchor a heading on its own line', function()
      local buf = make_buf({ '## Section' }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.equals(0, targets[1].start_row)
      assert.equals(0, targets[1].end_row)
    end)

    it('should not treat more than six hashes as a heading', function()
      local buf = make_buf({ '####### not a heading' }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.equals('paragraph', targets[1].kind)
    end)
  end)

  describe('blockquotes', function()
    it('should merge a quote run and strip markers', function()
      local buf = make_buf({
        '> first quoted line',
        '> second quoted line',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.equals(1, #targets)
      assert.equals('blockquote', targets[1].kind)
      assert.equals('first quoted line second quoted line', targets[1].text)
      assert.equals(1, targets[1].end_row)
    end)
  end)

  describe('list items', function()
    it('should emit one target per item and never merge across items', function()
      local buf = make_buf({
        '- first item',
        '- second item',
        '* third item',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.equals(3, #targets)
      assert.same({ 'list_item', 'list_item', 'list_item' }, kinds(targets))
      assert.same({ 'first item', 'second item', 'third item' }, texts(targets))
    end)

    it('should handle ordered list items', function()
      local buf = make_buf({
        '1. alpha',
        '2. beta',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.equals(2, #targets)
      assert.same({ 'alpha', 'beta' }, texts(targets))
    end)

    it('should keep nested items independent', function()
      local buf = make_buf({
        '- outer item',
        '  - nested item',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.equals(2, #targets)
      assert.same({ 'outer item', 'nested item' }, texts(targets))
    end)
  end)

  describe('skipped blocks', function()
    it('should skip fenced code blocks with backticks', function()
      local buf = make_buf({
        'before the fence',
        '```lua',
        'local x = 1',
        'print(x)',
        '```',
        'after the fence',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.same({ 'before the fence', 'after the fence' }, texts(targets))
    end)

    it('should skip fenced code blocks with tildes', function()
      local buf = make_buf({
        '~~~',
        'not translated',
        '~~~',
        'translated',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.same({ 'translated' }, texts(targets))
    end)

    it('should skip an unterminated fence to end of buffer', function()
      local buf = make_buf({
        'intro text',
        '```',
        'still code',
        'more code',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.same({ 'intro text' }, texts(targets))
    end)

    it('should skip YAML front matter', function()
      local buf = make_buf({
        '---',
        'title: My Post',
        'tags: [a, b]',
        '---',
        '',
        'Actual body text.',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.same({ 'Actual body text.' }, texts(targets))
    end)

    it('should only treat front matter at the very top of the buffer', function()
      local buf = make_buf({
        'Body first.',
        '',
        '---',
        'not front matter',
        '---',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.is_true(#targets >= 1)
      assert.equals('Body first.', targets[1].text)
    end)

    it('should skip HTML blocks', function()
      local buf = make_buf({
        '<div class="x">',
        'inside html',
        '</div>',
        '',
        'Real paragraph.',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.same({ 'Real paragraph.' }, texts(targets))
    end)

    it('should skip tables', function()
      local buf = make_buf({
        '| a | b |',
        '|---|---|',
        '| 1 | 2 |',
        '',
        'Below the table.',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.same({ 'Below the table.' }, texts(targets))
    end)

    it('should skip indented code blocks', function()
      local buf = make_buf({
        'Intro paragraph.',
        '',
        '    indented code line',
        '',
        'Outro paragraph.',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.same({ 'Intro paragraph.', 'Outro paragraph.' }, texts(targets))
    end)

    it('should skip link reference definitions', function()
      local buf = make_buf({
        '[ref]: https://example.com "Title"',
        '',
        'Body text.',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.same({ 'Body text.' }, texts(targets))
    end)

    it('should skip horizontal rules', function()
      local buf = make_buf({
        'Above rule.',
        '',
        '---',
        '',
        'Below rule.',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.same({ 'Above rule.', 'Below rule.' }, texts(targets))
    end)
  end)

  describe('inline normalization', function()
    it('should keep link label and drop the URL', function()
      local buf = make_buf({ 'See [the docs](https://example.com/page) for details.' }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.equals('See the docs for details.', targets[1].text)
    end)

    it('should normalize reference and shortcut links to their label', function()
      local buf = make_buf({ 'Read [the guide][g] and [other].' }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.equals('Read the guide and other.', targets[1].text)
    end)

    it('should remove inline images including alt text', function()
      local buf = make_buf({ 'Before ![alt words](img.png) after.' }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.equals('Before after.', targets[1].text)
    end)

    it('should remove reference images', function()
      local buf = make_buf({ 'Before ![alt][ref] after.' }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.equals('Before after.', targets[1].text)
    end)

    it('should remove autolinks and bare URLs', function()
      local buf =
        make_buf({ 'Visit <https://example.com> or https://other.example.org now.' }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.equals('Visit or now.', targets[1].text)
    end)

    it('should never leak a URL into the request text', function()
      local buf = make_buf({
        'A [link](https://secret.internal/path?token=abc) and ![i](https://cdn.example/x.png)',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      for _, t in ipairs(targets) do
        assert.is_nil(t.text:find('secret.internal', 1, true))
        assert.is_nil(t.text:find('cdn.example', 1, true))
        assert.is_nil(t.text:find('http', 1, true))
      end
    end)

    it('should skip a block that becomes empty after normalization', function()
      local buf = make_buf({ '![just an image](x.png)' }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.equals(0, #targets)
    end)
  end)

  describe('min_chars', function()
    it('should skip targets shorter than min_chars', function()
      config.setup({ immersive = { min_chars = 5 } })
      package.loaded['comment-translate.parser.document'] = nil
      document = require('comment-translate.parser.document')

      local buf = make_buf({
        'ab',
        '',
        'long enough line',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.same({ 'long enough line' }, texts(targets))
    end)
  end)

  describe('plain text filetype', function()
    it('should split on blank lines only', function()
      local buf = make_buf({
        'Para one line one',
        'para one line two',
        '',
        '# not a heading in plain text',
      }, 'text')

      local targets = document.extract(buf, 'text')

      assert.equals(2, #targets)
      assert.equals('Para one line one para one line two', targets[1].text)
      assert.equals('paragraph', targets[2].kind)
      assert.equals('# not a heading in plain text', targets[2].text)
    end)
  end)

  describe('target identity', function()
    it('should give every target an id and fingerprint', function()
      local buf = make_buf({ 'Some paragraph text.' }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.is_string(targets[1].id)
      assert.is_string(targets[1].fingerprint)
    end)

    it('should exclude row numbers from the fingerprint', function()
      local a = document.extract(make_buf({ 'Same text here.' }, 'markdown'), 'markdown')
      local b = document.extract(make_buf({ '', '', 'Same text here.' }, 'markdown'), 'markdown')

      assert.equals(a[1].fingerprint, b[1].fingerprint)
      assert.are_not.equals(a[1].id, b[1].id)
    end)

    it('should give identical text at different rows different ids', function()
      local buf = make_buf({
        'Repeated line.',
        '',
        'Repeated line.',
      }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.equals(2, #targets)
      assert.are_not.equals(targets[1].id, targets[2].id)
      assert.equals(targets[1].fingerprint, targets[2].fingerprint)
    end)

    it('should change the fingerprint when the text changes', function()
      local a = document.extract(make_buf({ 'Version one.' }, 'markdown'), 'markdown')
      local b = document.extract(make_buf({ 'Version two.' }, 'markdown'), 'markdown')

      assert.are_not.equals(a[1].fingerprint, b[1].fingerprint)
    end)

    it('should distinguish kinds with identical text in the fingerprint', function()
      local heading = document.extract(make_buf({ '# Same' }, 'markdown'), 'markdown')
      local para = document.extract(make_buf({ 'Same' }, 'markdown'), 'markdown')

      assert.equals('Same', heading[1].text)
      assert.equals('Same', para[1].text)
      assert.are_not.equals(heading[1].fingerprint, para[1].fingerprint)
    end)
  end)

  describe('unicode', function()
    it('should handle CJK text', function()
      local buf = make_buf({ '这是一个中文段落。', '继续同一段。' }, 'markdown')

      local targets = document.extract(buf, 'markdown')

      assert.equals(1, #targets)
      assert.equals('这是一个中文段落。 继续同一段。', targets[1].text)
    end)
  end)

  describe('empty buffers', function()
    it('should return an empty list for an empty buffer', function()
      local buf = make_buf({ '' }, 'markdown')

      assert.same({}, document.extract(buf, 'markdown'))
    end)

    it('should return an empty list for a whitespace-only buffer', function()
      local buf = make_buf({ '   ', '', '\t' }, 'markdown')

      assert.same({}, document.extract(buf, 'markdown'))
    end)
  end)
end)
