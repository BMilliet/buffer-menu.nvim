if vim.g.loaded_buffer_menu_nvim == 1 then
    return
end

vim.g.loaded_buffer_menu_nvim = 1

if vim.fn.exists(":BufferMenu") == 0 then
    vim.api.nvim_create_user_command("BufferMenu", function()
        require("buffer-menu").open()
    end, { desc = "Open buffer menu" })
end
