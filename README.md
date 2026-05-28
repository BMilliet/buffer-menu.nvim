# buffer-menu.nvim

A small floating buffer picker for Neovim.

It opens a two-pane popup: the left pane lists buffers with a search line at
the bottom and the right pane previews the selected buffer. Typing does not
filter by default; press `/` to enter search mode, type the filter, then press
`<CR>`. Matching text is highlighted in the buffer list.

## Installation

```lua
{
    "BMilliet/buffer-menu.nvim",
    config = function()
        require("buffer-menu").setup()
    end,
}
```

## Usage

```lua
vim.keymap.set("n", "<leader><leader>", function()
    require("buffer-menu").open()
end, { desc = "Buffer: List buffers" })
```

The plugin also provides `:BufferMenu`.

## Keys

| Key | Action |
| --- | --- |
| `j` / `<Down>` | Move down |
| `k` / `<Up>` | Move up |
| `gg` | Go to first buffer |
| `G` | Go to last buffer |
| `/` | Enter search mode |
| `<CR>` | Open selected buffer |
| `dd` | Delete selected buffer |
| `q` / `<Esc>` | Close |
