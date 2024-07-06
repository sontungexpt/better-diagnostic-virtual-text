# Better Diagnostic Virtual Text

A Neovim plugin for enhanced diagnostic virtual text display, aiming to provide better performance and customization options.

## Features

- **Ease of Use**: Simple setup and configuration.
- **Beautiful UI**: Customizable colors, icons, and more.

## Installation

Add the following to your `init.lua` or `init.vim`:

```lua
-- lazy.nvim
{
    'sontungexpt/better-diagnostic-virtual-text',
    "LspAttach"
    config = function(_)
        require('better-diagnostic-virtual-text').setup()
    end
}
```

## Preview

## License

MIT[License]

## Contributors

- [sontungexpt](https://github.com/sontungexpt)
