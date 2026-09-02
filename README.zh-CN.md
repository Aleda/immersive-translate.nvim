# comment-translate.nvim

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-%3E=0.10-blue)](https://neovim.io)

[English](README.md) | **简体中文**

在 Neovim 中直接翻译代码注释、字符串与文档正文，支持悬停查看与沉浸式双语阅读。
既可使用传统翻译 API，也可使用 LLM 后端，包括通过 Ollama 运行的完全本地模型。

![悬停翻译演示](assets/demo.gif)

## 关于本 fork

本项目 fork 自 [noir4y/comment-translate.nvim](https://github.com/noir4y/comment-translate.nvim)，
上游提供了代码注释与字符串的悬停、内联翻译能力，这些能力在本 fork 中全部保留。

本 fork 新增的核心能力是**面向正文的沉浸式双语阅读模式**：打开一篇 Markdown
文档、帮助文件或纯文本，每个段落的译文会直接渲染在原文下方，效果类似浏览器的
沉浸式翻译扩展。下表中列出的是本 fork 新增的部分，其余能力来自上游。

### 本 fork 新增的能力

| 能力 | 说明 |
|---|---|
| 文档阅读模式 | 为 `markdown`、`text`、`help`、`rst`、`org` 缓冲区提供段落级双语视图，译文以虚拟行渲染在原文下方 |
| 视口驱动翻译 | 优先翻译你正在阅读的内容，并预取窗口上下一段范围；其余部分等你滚动过去再翻译 |
| 结构感知抽取 | 标题、引用、列表项按语义单元翻译；代码块、front matter、HTML 块与表格整块跳过 |
| URL 与图片剥离 | 链接只保留可见文字并去掉 URL，图片整体移除，因此 URL、token 与文件名永远不会发送给翻译服务 |
| 译文自动折行 | 译文按窗口宽度折行，以显示列宽计算，保证中日韩文本可读 |
| 画像感知缓存 | 缓存键包含 service、provider、model、endpoint 与 prompt，两个模型不会互相命中对方的译文 |
| 推理模型支持 | 可选开启 `thinking` / `reasoning_effort`，推理过程不会出现在渲染结果中 |
| 并发上限 | 可配置的在途请求上限，在所有缓冲区之间共享 |

以下上游能力保持不变：悬停翻译、可视选区替换、基于 Tree-sitter 的注释与字符串
识别、Google 与 LLM 后端，以及既有的 `:CommentTranslate*` 命令。

## 为什么选择这个插件

许多翻译插件只能依赖外部服务。本插件面向希望自主选择的团队与个人：

- 追求质量与速度时，使用托管服务商。
- 需要更强隐私与控制时，使用本地 LLM。
- 始终把翻译流程留在 Neovim 内。

## 主要特性

- 面向文档的沉浸式双语阅读，而不仅限于代码注释
- 支持 LLM 翻译（`openai`、`anthropic`、`gemini`、`ollama`）
- 通过 Ollama 实现本地 LLM 工作流（原文不发送至云端 API）
- 悬停翻译，便于快速理解
- 将选中文本替换为译文
- 基于 Tree-sitter 的注释与字符串识别
- 源文件永不被修改 —— 译文仅存在于显示层

## 安全与隐私

本插件让你掌控文本的去向：

- `translate_service = 'google'` 或托管的 `llm` 服务商：文本会发送到所配置的远端服务。
- `llm.provider = 'ollama'` 且使用默认本地端点时，翻译全程在本地完成；若 `llm.endpoint` 指向远程主机，文本会发送到该主机。
- API key 与原文/请求体通过 stdin 配置传给 `curl`，而不是作为进程参数传递。
- 缓存仅存在于内存中，本插件不会将其写入磁盘。

对于敏感仓库，推荐使用本地 Ollama 模型。

## 环境要求

- Neovim 0.10+
- `curl`
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)（必需）
- 需要检查的语言对应的 Tree-sitter parser（推荐）

注意：如果只使用本地翻译（例如本地运行的 Ollama），则不需要联网。

Parser 可以来自 Neovim 内置 parser、手动安装，或 `nvim-treesitter` 之类提供
parser 的插件。本插件使用 Neovim 内置的 Tree-sitter API，并不要求安装
`nvim-treesitter` 插件本身。

## 安装

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

如果你已经通过 `nvim-treesitter` 管理 parser，可以继续沿用。

## 使用

### 悬停翻译

```vim
:CommentTranslateHover
```

### 沉浸式翻译

```vim
:ImmersiveTranslateToggle
```

在 `markdown` 与 `text` 等文档类缓冲区中，这会呈现双语阅读视图：每个段落、
标题、引用和列表项的译文都以虚拟行的形式显示在其正下方。**文件本身永远不会
被修改** —— 译文仅存在于显示层，因此缓冲区内容、撤销历史与 `changedtick`
都保持不变，编辑时也可以放心开着该模式。

翻译由你实际阅读的内容驱动：窗口内的段落最先请求，窗口上下各一段范围会被
预取以保证滚动流畅，其余内容则等待。因此长文档可以立即开始阅读，而不必等
待整篇翻译完成。

代码块、front matter、HTML 块、表格与缩进代码会被跳过。链接只保留可见文字
并去掉 URL，图片被整体移除，因此不会有任何 URL 被发送给翻译服务。

在其他文件类型中，同一命令保持原有行为，即翻译注释与字符串。

| 命令 | 作用 |
|---|---|
| `:ImmersiveTranslateToggle` | 开启或关闭沉浸式翻译 |
| `:ImmersiveTranslateRefresh` | 重新抽取并刷新当前缓冲区 |
| `:ImmersiveTranslateRefresh!` | 同上，并额外清除当前缓冲区的缓存译文 |
| `:ImmersiveTranslateClearCache` | 清空内存缓存并重新获取可见区域 |

原有的 `:CommentTranslateToggle` 与 `:CommentTranslateUpdate` 命令名依然可用。

### 替换所选文本

```vim
:CommentTranslateReplace
```

### 推理模型

插件支持推理（"thinking"）模型，且**默认关闭** —— 翻译很少需要深思，
而推理会带来额外的延迟与成本。

```lua
require('comment-translate').setup({
  translate_service = 'llm',
  llm = {
    provider = 'openai',      -- 或 'anthropic'
    model = 'deepseek-v4-flash',
    endpoint = 'https://api.deepseek.com/v1/chat/completions',
    reasoning = {
      enabled = true,
      effort = 'high',        -- openai / ollama 形态的服务商
      budget_tokens = 1024,   -- anthropic 形态的服务商
    },
  },
})
```

`effort` 会以 `reasoning_effort` 的形式发送给 OpenAI 兼容端点；
`budget_tokens` 则变成 Anthropic 的 `thinking` 块，其中 `max_tokens` 会被
抬高到预算之上，并按该 API 的要求省略 `temperature`。推理过程永远不会被
渲染出来：Anthropic 的 `thinking` 块与 OpenAI 的 `reasoning_content` 字段
都会被忽略，只显示译文本身。

## 配置示例

若省略 `target_language`，插件会使用系统 locale，并在无法识别时回退为 `en`。

完整的配置项说明请参见[英文 README](README.md#configuration-example)。

## LLM 服务商示例

本地（Ollama）与托管（OpenAI）的配置示例请参见
[英文 README](README.md#llm-provider-examples)。

## 命令

- `:CommentTranslateHover` —— 在光标处显示译文
- `:CommentTranslateHoverToggle` —— 开关自动悬停
- `:CommentTranslateReplace` —— 将选中文本替换为译文
- `:CommentTranslateToggle` —— 全局开关沉浸式翻译
- `:CommentTranslateUpdate` —— 更新当前缓冲区的沉浸式翻译
- `:CommentTranslateSetup` —— 以默认配置初始化插件
- `:CommentTranslateHealth` —— 健康检查，包含调用它的缓冲区的 parser 可用性

使用 `:checkhealth comment-translate` 进行通用的依赖与配置检查。
如果还想检查某个文件缓冲区的 parser 可用性，请在该缓冲区中执行
`:CommentTranslateHealth`。

## 开发

- 格式化：`make fmt`
- 格式检查：`make fmt-check`
- Lint：`make lint`
- 测试：`make test`

## 致谢

本项目 fork 自 [noir4y](https://github.com/noir4y) 的
[noir4y/comment-translate.nvim](https://github.com/noir4y/comment-translate.nvim)，
其提供的悬停、替换、服务商与缓存基础是本 fork 的构建起点。上游与本 fork 均采用
MIT 许可证。

## 许可证

MIT
