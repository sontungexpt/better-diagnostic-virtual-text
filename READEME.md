# Better Diagnostic Virtual Text

A Neovim plugin for enhanced diagnostic virtual text display, aiming to provide better performance and customization options.

Note: document is not enough.


## Features

- **Ease of Use**: Simple setup and configuration.
- **Beautiful UI**: Customizable colors, icons, and more.
- **Toggleable**: Enable and disable with vim.diagnostic.enable/disable commands.

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
https://github.com/sontungexpt/better-diagnostic-virtual-text/assets/92097639/ef3d49fb-1a47-46c3-81ba-d23df70eced9
## License

MIT[License]

## Contributors

- [sontungexpt](https://github.com/sontungexpt)
