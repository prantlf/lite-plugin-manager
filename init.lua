local core = require "core"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local command = require "core.command"
local style = require "core.style"
local View = require "core.view"
local Object = require "core.object"


-- CONSTANTS
local PLUGIN_PATH = system.absolute_path(EXEDIR .. "/data/plugins")
local PLUGIN_URL = "https://raw.githubusercontent.com/rxi/lite-plugins/master/README.md"


local ListView = View:extend()

function ListView:new(data)
  ListView.super.new(self)
  self.data = data
  self.selected = 1
  self.scrollable = true
end

function ListView:get_line_height()
  return style.code_font:get_height() + style.font:get_height() + 3 * style.padding.y
end

function ListView:get_name()
  return "List"
end

function ListView:get_scrollable_size()
  return #self.data * self:get_line_height()
end

function ListView:get_visible_line_range()
  local lh = self:get_line_height()
  local min = math.max(1, math.floor(self.scroll.y / lh))
  return min, min + math.floor(self.size.y / lh) + 1
end

function ListView:each_visible_item()
  return coroutine.wrap(function()
    local lh = self:get_line_height()
    local x, y = self:get_content_offset()
    local min, max = self:get_visible_line_range()
    y = y + lh * (min - 1) + style.padding.y
    max = math.min(max, #self.data)

    for i = min, max do
      local item = self.data[i]
      if not item then break end
      coroutine.yield(i, item, x, y, self.size.x, lh)
      y = y + lh
    end
  end)
end

function ListView:scroll_to_line(i)
  local min, max = self:get_visible_line_range()
  if i > min and i <= max then
    local lh = self:get_line_height()
    self.scroll.to.y = math.max(0, lh * (i - 1) - self.size.y / 2)
    self.scroll.y = self.scroll.to.y
  end
end

function ListView:on_mouse_moved(mx, my, ...)
  ListView.super.on_mouse_moved(self, mx, my, ...)
  for i, _, x, y, w, h in self:each_visible_item() do
    if mx >= x and my >= y and mx < x + w and my < y + h then
      self.selected = i
    end
  end
end

function ListView:on_mouse_pressed(button)
  if self.selected and self.on_selected then
    self:on_selected(self.data[self.selected], button)
  end
end

function ListView:on_selected()
  -- no op for extension
end

local function approx_slice(desired, font, text)
  local est = math.floor(desired / font:get_width(text:sub(1, 1)))
  local s, w
  for i = est, 0, -1 do
    s = text:sub(1, i)
    w = font:get_width(s)
    if w <= desired then
      return s, w
    end
  end
end

function ListView:draw()
  self:draw_background(style.background)

  local lh1, lh2 = style.code_font:get_height(), style.font:get_height()
  for i, item, x, y, w, h in self:each_visible_item() do
    local tx = x + style.padding.x
    local text, tw = approx_slice(w, style.code_font, item.text)
    local subtext, stw = approx_slice(w, style.font, item.subtext)

    if i == self.selected then
      renderer.draw_rect(x, y, self.size.x, h, style.accent)
    end

    y = y + style.padding.y
    common.draw_text(style.code_font, style.text, text, "left", tx, y, tw, lh1)
    y = y + lh1 + style.padding.y
    common.draw_text(style.font, style.dim, subtext, "left", tx, y, stw, lh2)
    y = y + lh2 + style.padding.y
  end

  self:draw_scrollbar()
end

command.add(ListView, {
  ["list:previous-entry"] = function()
    local v = core.active_view
    v.selected = common.clamp(v.selected - 1, 1, #v.data)
    v:scroll_to_line(v.selected)
  end,
  ["list:next-entry"] = function()
    local v = core.active_view
    v.selected = common.clamp(v.selected + 1, 1, #v.data)
    v:scroll_to_line(v.selected)
  end,
  ["list:select-entry"] = function()
    local v = core.active_view
    v:on_selected(v.data[v.selected], "left")
  end
})

keymap.add {
  ["up"]    = "list:previous-entry",
  ["down"]  = "list:next-entry",
  ["return"] = "list:select-entry",
  ["keypad enter"] = "list:select-entry"
}

local Cmd = Object:extend()

function Cmd:new(scan_interval)
  scan_interval = scan_interval or 0.1
  self.q = {}

  core.add_thread(function()
    while true do
      coroutine.yield(scan_interval)
      local n, j = #self.q, 1

      for _, v in ipairs(self.q) do
        if not self:dispatch(v) then
          self.q[j] = v
          j = j + 1
        end
      end
      for i = j, n do self.q[i] = nil end
    end
  end)
end

local function read_file(filename)
  local f, e = io.open(filename, "r")
  if not f then return nil, e end
  local content = f:read("*a")
  f:close()
  return content
end

local function write_file(filename, content)
  local f, e = io.open(filename, "w")
  if not f then return nil, e end
  f:write(content)
  f:close()
  return true
end

function Cmd:dispatch(item)
  if system.get_time() > item.timeout then
    coroutine.resume(item.co, nil, "Timeout reached")
    return true
  end

  -- check completion files
  local completion = read_file(item.completion)
  if completion then
    local content, err = read_file(item.output)
    if content then
      os.remove(item.script)
      os.remove(item.output)
      os.remove(item.completion)
      if item.script2 then os.remove(item.script2) end
      coroutine.resume(item.co, content, tonumber(completion))
    else
      coroutine.resume(item.co, nil, err)
    end
    return true
  end

  return false
end

function Cmd:run(cmd, timeout)
  timeout = timeout or 10
  local script = core.temp_filename(PLATFORM == "Windows" and ".bat")
  local script2 = core.temp_filename(PLATFORM == "Windows" and ".bat")
  local output = core.temp_filename()
  local completion = core.temp_filename()

  if PLATFORM == "Windows" then
    write_file(script, cmd .. "\n")
    write_file(script2, string.format([[
      @echo off
      call %q > %q 2>&1
      echo %%errorLevel%% > %q
      exit
    ]], script, output, completion))
    system.exec(string.format("call %q", script2))
  else
    write_file(script, string.format([[
      %s
      echo $? > %q
      exit
    ]], cmd, completion))
    system.exec(string.format("sh %q > %q 2>&1", script, output))
  end

  table.insert(self.q, {
    script = script,
    script2 = PLATFORM == "Windows" and script2,
    output = output,
    completion = completion,
    timeout = system.get_time() + timeout,
    co = coroutine.running()
  })
  return coroutine.yield()
end


local cmd_queue = Cmd()

local function first_line(str)
  return str:match("(.*)\r?\n?")
end

local function process_error(content, exit)
  if exit == 0 then
    return content
  else
    return nil, first_line(content)
  end
end

local curl = {
  name = "curl",
  runnable = function()
    local _, exit = cmd_queue:run("curl --version")
    return exit == 0
  end,
  get = function(url)
    local content, exit = cmd_queue:run(string.format("curl -fsSL %q", url))
    return process_error(content, exit)
  end,
  download_file = function(url, filename)
    local content, exit = cmd_queue:run(string.format("curl -o %q -fsSL %q", filename, url))
    return process_error(content, exit)
  end
}

local wget = {
  name = "wget",
  runnable = function()
    local _, exit = cmd_queue:run("wget --version")
    return exit == 0
  end,
  get = function(url)
    local content, exit = cmd_queue:run(string.format("wget -qO- %q", url))
    return process_error(content, exit)
  end,
  download_file = function(url, filename)
    local content, exit = cmd_queue:run(string.format("wget -qO %q %q", filename, url))
    return process_error(content, exit)
  end
}

local powershell = {
  name = "powershell",
  runnable = function()
    local _, exit = cmd_queue:run("powershell -Version")
    return exit == 0
  end,
  get = function(url)
    local content, exit = cmd_queue:run(string.format([[
      echo Invoke-WebRequest -UseBasicParsing -Uri %q ^| Select-Object -ExpandProperty Content ^
      | powershell -NoProfile -NonInteractive -NoLogo -Command -
    ]], url))
    return process_error(content, exit)
  end,
  download_file = function(url, filename)
    local content, exit = cmd_queue:run(string.format([[
      echo Invoke-WebRequest -UseBasicParsing -outputFile %q -Uri %q ^
      | powershell -NoProfile -NonInteractive -NoLogo -Command -
    ]], filename, url))
    return process_error(content, exit)
  end
}

local dummy = {
  name = "dummy",
  get = function() error("Client is not loaded") end,
  download_file = function() error("Client is not loaded") end
}

local client
local function select_client()
  local p, c, w = powershell.runnable(), curl.runnable(), wget.runnable()
  if p then
    client = powershell
  elseif c and not client then
    client = curl
  elseif w and not client then
    client = wget
  else
    core.error("No client is available. Remote functions does not work.")
    client = dummy
  end
  core.log_quiet("%s is used to download files.", client.name)
end
coroutine.wrap(select_client)()

local function magiclines(str)
  if str:sub(-1) ~= "\n" then str = str .. "\n" end
  return str:gmatch("(.-)\n")
end

local function md_table_parse(str)
  local sep = str:find("|", 2, true) -- check if there is a seperator in the middle of string (not the end)
  if not sep or sep == #str then return end

  local matches = {}
  if str:sub(1, 1) ~= "|" then str = "|" .. str end
  if str:sub(-1) == "|" then str = str:sub(1, -2) end
  for content in str:gmatch("|([^|]*)") do
    table.insert(matches, content)
  end
  return matches
end

local function md_parse(str)
  return coroutine.wrap(function()
    local row, last_t = false, "text"
    for line in magiclines(str) do
      local res = md_table_parse(line)
      if not res then
        last_t = "text"
        coroutine.yield("text", line)
      elseif table.concat(res):find("^%-%--%-$") then -- the seperator
        last_t = "sep"
      else
        if last_t == "sep" then row = true end
        if row then
          coroutine.yield("row", res)
        else
          coroutine.yield("header", res)
        end
      end
    end
  end)
end

local function md_url_parse(url)
  return url:match("%[([^%]]-)%]%(([^%)]+)%)")
end

local function md_url_sub(str)
  return str:gsub("%[([^%]]-)%]%(([^%)]+)%)", function(text, url) return text end)
end

local function url_segment(url)
  local res = {}
  if url:sub(-1) == "/" then url = url:sub(1, -2) end
  if url:match("%w+://[^/]+") then
    local first, s = url:match("(%w+://[^/]+)()")
    url = url:sub(s)
    table.insert(res, first)
  end
  for segment in url:gmatch("/[^/]+") do
    table.insert(res, segment)
  end
  return res
end

local function get_url_filename(url)
  local seg = url_segment(url)
  return seg[#seg]:match("/([^%?#]+)")
end

local function get_remote_plugins(src_url)
  local content, err = client.get(src_url)
  if not content then return error(err) end

  local base_url = url_segment(src_url)
  base_url = table.concat(base_url, "", 1, #base_url - 1)

  local res = {}
  for t, match in md_parse(content) do
    if t == "row" then
      local name, url = md_url_parse(match[1])
      url = base_url .. "/" .. url
      name = name:match("`([^`]-)`")
      local path = PLUGIN_PATH .. PATHSEP .. get_url_filename(url)
      local description = md_url_sub(match[2])
      local plugin_type = match[1]:find("%*%s-") and "dir" or "file"
      res[name] = {
        name = name,
        url = url,
        path = path,
        description = description,
        type = plugin_type
      }
    end
  end
  return res
end

local function get_local_plugins()
  local res = system.list_dir(PLUGIN_PATH)
  for i, v in ipairs(res) do
    res[i] = nil
    local abspath = PLUGIN_PATH .. PATHSEP .. v
    local stat = system.get_file_info(abspath)
    res[v] = {
      name = v,
      url = (PLATFORM == "Windows" and "file:///" or "file://") .. abspath,
      path = abspath,
      description = string.format("%s, last modified at %s", stat.type, os.date(nil, stat.modified)),
      type = stat.type
    }
  end
  return res
end


local PluginManager = {}

local function show_plugins(plugins)
  local list = {}
  for name, info in pairs(plugins) do
    table.insert(list, {
      text = name,
      subtext = info.description
    })
  end
  table.sort(list, function(a, b) return string.lower(a.text) < string.lower(b.text) end)

  local co = coroutine.running()
  local v = ListView(list)
  function v:on_selected(item)
    coroutine.resume(co, plugins[item.text])
  end
  local node = core.root_view:get_active_node()
  node:split("down", v)

  return coroutine.yield()
end

local function show_options(prompt, opt)
  local co = coroutine.running()
  core.command_view:enter(
    prompt,
    function(item)
      coroutine.resume(co, item)
    end,
    function(text)
      local res = common.fuzzy_match(opt, text)
      for i, name in ipairs(res) do
        res[i] = { text = name }
      end
      return res
    end
  )
  return coroutine.yield()
end

function PluginManager.list_local()
  coroutine.wrap(function()
    local plugins = get_local_plugins()
    local item = show_plugins(plugins)
    local opt = show_options("Manage local plugin", { "delete plugin", "move plugin" })
  end)()
end

function PluginManager.list_remote()
  coroutine.wrap(function()
    core.log("Getting plugin list...")
    local plugins = get_remote_plugins(PLUGIN_URL)
    local item = show_plugins(plugins)
    local opt = show_options("Manage remote plugin", { "download plugin", "copy plugin link" })
    command.perform "root:close"

    if opt == "download plugin" then
      if item.type == "file" then
        core.log("Downloading %s...", item.name)
        print(item.url, item.path)
        local status, err = client.download_file(item.url, item.path)
        if status then
          core.log("%s is installed as %q", item.name, item.path)
        else
          core.error("Error downloading plugin: %s", err)
        end
      else
        return core.error("Unable to download external URLs")
      end
    end
  end)()
end

command.add(nil, {
  ["plugin-manager:list-local"]  = PluginManager.list_local,
  ["plugin-manager:list-remote"] = PluginManager.list_remote
})