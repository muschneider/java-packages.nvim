-- Plug in to show java packages
-- :nmap <leader>w :write<cr>:source<cr>
-- :luafile /home/mauro/.config/nvim/lua/scripts/show_java_packages.lua
-- require("init").show_java_packages()

local action_state = require("telescope.actions.state")
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local previewers = require("telescope.previewers")
local config = require("telescope.config").values
local sorters = require("telescope.sorters")

local Path = require("plenary.path")
local scandir = require("plenary.scandir")

local log = require("plenary.log"):new()
log.level = "debug"

local M = {}

local selected_package

-- Function to insert a Java class snippet (including package) into a specified file
local function insert_class_snippet_into_file(file_path)
	-- Define the Java class snippet content with a package declaration
	local class_snippet = [[
package ${1:package_name};

public class ${2:ClassName} {

}
]]

	-- Check if the file already exists
	local file_exists = vim.fn.filereadable(file_path) == 1
	if file_exists then
		print("File already exists, not overwriting: " .. file_path)
		return -- Exit the function without doing anything if the file exists
	end

	-- Get the directory from the file path (this assumes the file_path includes "src/main/java")
	local dir = vim.fn.fnamemodify(file_path, ":p:h")

	-- Remove the "src/main/java" part of the path to get the package structure
	local package_path = dir:match("src/main/java/(.+)$")

	-- If the package path is found, replace slashes with dots
	if package_path then
		local package_name = package_path:gsub("/", ".")
		-- Replace the placeholder in the snippet with the package name
		class_snippet = class_snippet:gsub("${1:package_name}", package_name)
	end

	-- Get the filename from the path and extract the class name (without extension)
	local class_name = vim.fn.fnamemodify(file_path, ":t:r")

	-- Replace the class name placeholder in the snippet
	class_snippet = class_snippet:gsub("${2:ClassName}", class_name)

	-- Get the directory for the file
	local file_dir = vim.fn.fnamemodify(file_path, ":p:h")

	-- Check if the directory exists, if not, create it
	if vim.fn.isdirectory(file_dir) == 0 then
		-- Directory does not exist, create it
		vim.fn.mkdir(file_dir, "p")
	end

	-- Open the file for writing (this will create the file if it doesn't exist)
	local file = io.open(file_path, "w")

	-- Check if the file was opened successfully
	if file then
		-- Write the snippet content to the file
		file:write(class_snippet)
		-- Close the file after writing
		file:close()
		print("Class snippet inserted into: " .. file_path)
	else
		print("Failed to create file: " .. file_path)
	end
end

local function create_new_class(package_name)
	vim.ui.input({
		prompt = "Class Name: ",
		default = package_name .. ".",
	}, function(input)
		-- If the user pressed Enter (input is not nil), update the line
		if input then
			input = string.gsub(input, "%.java", "") -- It'll remove the file extension if it has one
			local complete_path = "./src/main/java/" .. string.gsub(input, "%.", "/") .. ".java"
			insert_class_snippet_into_file(complete_path)
			vim.cmd("tabnew")
			vim.cmd("edit " .. complete_path)
		else
			print("Input canceled")
		end
	end)
end

--
-- Scan Java Project to search packages and Classes
--
local function get_java_packages()
	local java_folder = Path:new("src/main/java")

	-- Check if the folder exists
	if not java_folder:exists() then
		print("Error: src/main/java folder does not exist.")
		return {}, {}
	end

	-- Table to store all packages
	local packages = {}
	local package_files = {}

	-- Scan the directory recursively
	scandir.scan_dir(tostring(java_folder), {
		depth = math.huge,
		add_dirs = false,
		search_pattern = "%.java$", -- Look for .java files
		on_insert = function(file)
			-- Extract the relative path and replace / with . for package format
			local relative_path = Path:new(file):make_relative(tostring(java_folder))
			local package_path = relative_path:gsub("/[^/]+%.java$", ""):gsub("/", ".")
			packages[package_path] = true
			package_files[package_path] = package_files[package_path] or {}
			table.insert(package_files[package_path], file)
		end,
	})

	-- Convert packages to a list
	local package_list = {}
	for package_name in pairs(packages) do
		table.insert(package_list, package_name)
	end

	return package_list, package_files
end

local function close_telescope_picker_safe()
	-- Check if the popup menu is visible (this indicates a picker is open)
	if vim.fn.pumvisible() == 1 then
		-- Close the picker if it's open
		local actions = require("telescope.actions")
		actions.close()
	end
end

--
-- show java packages in Telescope
--
M.show_java_packages = function(opts)
	local packages, package_files = get_java_packages()
	if #packages == 0 then
		print("No Java packages found.")
		return
	end

	pickers
		.new(opts, {
			prompt_title = "Filter the package name",
			finder = finders.new_table({
				results = packages,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry,
						ordinal = entry,
					}
				end,
			}),
			sorter = sorters.get_generic_fuzzy_sorter(),

			attach_mappings = function(_, map)
				map("i", "<C-n>", function(prompt_bufnr)
					selected_package = action_state.get_selected_entry(prompt_bufnr).value
					create_new_class(selected_package)
					close_telescope_picker_safe()
				end)

				map("i", "<CR>", function(prompt_bufnr)
					selected_package = action_state.get_selected_entry(prompt_bufnr).value
					local files = package_files[selected_package]

					if files and #files > 0 then
						M.show_java_classes(files)
					else
						print("No files found in package: " .. selected_package)
					end
				end)
				return true
			end,

			previewer = previewers.new_buffer_previewer({
				title = "Java Classes",
				define_preview = function(self, entry)
					local pkg_path = string.gsub(entry.value, "%.", "/")
					local files = package_files[entry.value]
					for i = 1, #files do
						files[i] = Path:new(files[i]):make_relative(tostring(Path:new("src/main/java")))
						files[i] = string.gsub(files[i], pkg_path .. "/", "")
					end
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, 0, true, files)
				end,
			}),
		})
		:find()
end

--
-- Show Java Classes in the Telescope
--
M.show_java_classes = function(files)
	local opts = {}
	pickers
		.new(opts, {
			prompt_title = "Java Classes",
			finder = finders.new_table({
				results = files,
				entry_maker = function(file)
					return {
						value = file,
						display = Path:new(file):make_relative(tostring(Path:new("src/main/java"))),
						ordinal = file,
					}
				end,
			}),
			sorter = config.generic_sorter(opts),

			attach_mappings = function(_, map)
				map("i", "<leader><BS>", function(prompt_bufnr)
					M.show_java_packages()
				end)

				map("i", "<C-n>", function(prompt_bufnr)
					create_new_class(selected_package)
					close_telescope_picker_safe()
				end)

				map("i", "<CR>", function(prompt_bufnr)
					local selected_class = action_state.get_selected_entry(prompt_bufnr).value
					local filepath = "src/main/java/"
						.. string.gsub(selected_package, "%.", "/")
						.. "/"
						.. selected_class
					vim.cmd("edit! " .. filepath)
				end)
				return true
			end,

			previewer = previewers.new_buffer_previewer({
				define_preview = function(self, entry, _)
					local filepath = "src/main/java/" .. string.gsub(selected_package, "%.", "/") .. "/" .. entry.value
					local bufnr = self.state.bufnr
					if vim.fn.filereadable(filepath) == 1 then
						local content = vim.fn.readfile(filepath)
						vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, content)
						vim.bo[bufnr].filetype = "java"
					else
						vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { "File not found" })
					end
				end,
			}),
			-- end of previewer
		})
		:find()
end

--
vim.api.nvim_create_user_command("JavaPKGs", function()
	package.loaded["java_packages"] = nil
	require("java_packages").show_java_packages()
end, {})

vim.api.nvim_set_keymap("n", "<Leader>jp", [[:JavaPKGs<CR>]], { noremap = true, silent = true })

return M
