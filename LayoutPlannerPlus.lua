function widget:GetInfo()
  return {
    name    = "LayoutPlannerPlus",
    desc    = "Modern layout editor + library with named saves, thumbnails, and intuitive tools",
    author  = "Custom",
    date    = "2025-12-02",
    license = "MIT",
    layer   = 0,
    enabled = true
  }
end

--------------------------------------------------------------------------------
-- Constants & basics (match original LayoutPlanner where useful)
--------------------------------------------------------------------------------

local Spring = Spring
local gl     = gl
local GL     = GL
local widgetHandler = widgetHandler

local BU_SIZE     = 16         -- 1 BU = 16 game units
local HALF_BU     = BU_SIZE/2
local SQUARE_SIZE = 3 * BU_SIZE
local CHUNK_SIZE  = 4 * SQUARE_SIZE

local LAYOUT_DIR  = "LuaUI/Widgets/LayoutPlannerPlus/"

--------------------------------------------------------------------------------
-- Layout data
--------------------------------------------------------------------------------

local currentLayout = {
  buildings = {
    [1]  = {},
    [2]  = {},
    [3]  = {},
    [4]  = {},
    [6]  = {},
    [12] = {},
  },
  lines = {}
}

-- Kept for compatibility with existing layout files (buildings), but
-- not exposed in the UI anymore – LayoutPlannerPlus is line-focused.
local buildingTypes = {
  { name = "Small",  size = 2 },
  { name = "Square", size = 3 },
  { name = "Big",    size = 4 },
  { name = "Large",  size = 6 },
  { name = "Chunk",  size = 12 },
}

local currentSizeIndex = 2      -- unused in Plus UI (line-only), kept for compatibility

--------------------------------------------------------------------------------
-- State: drawing & UI
--------------------------------------------------------------------------------

local drawingMode      = false
local drawingLinesMode = false

-- Line drawing
local lineStart        = nil    -- for free lines
local removeDragStart  = nil    -- for right-drag removal box

local altMode          = false
local ctrlMode         = false

-- Remember drawing state when opening load popup
local wasDrawingBeforeLoad = false

-- Save dialog
local showSaveDialog   = false
local saveNameText     = ""

-- Line snap modes: 0=none, 1=intersections, 2=midpoints, 3=thirds
local lineSnapMode     = 1      -- default to intersections

-- Rendering queue (for gradual rendering to avoid lag)
local drawLineQueue    = {}
local renderTimer      = 0
local renderingToGame  = false

-- WASD key translation
local allowTranslationByKeys = true  -- Whether layout can be shifted using keyboard keys

-- Library / saved layouts
local savedLayouts     = {}     -- { { name, tags, filename, data }, ... }
local filteredLayouts  = {}
local exitButtonClicked = false  -- Prevent exit button message spam
local selectedIndex    = nil    -- index into filteredLayouts
local selectedData     = nil    -- layout table of selected
local searchText       = ""
local listScrollOffset = 0      -- scroll offset for layout list (in items)

-- Layout transformation state (for selected layout preview/placement)
local layoutRotation   = 0      -- rotation angle in degrees (0, 90, 180, 270)
local layoutInverted  = false  -- horizontal inversion (flip x)

-- Simple blink helper for text carets
local function IsCaretVisible()
  local t = Spring.GetGameSeconds and Spring.GetGameSeconds() or os.clock()
  return (t % 1.0) < 0.5
end

--------------------------------------------------------------------------------
-- Glass UI: FlowUI-based skin matching BAR's F11 widget selector
--
-- The panels are drawn with the game's own FlowUI primitives (chamfered
-- corners, tiled glass fill, gloss, feathered outline) and the world behind
-- them is blurred by gfx_guishader, which is what gives the widget selector
-- its look. Nothing here changes any geometry: the same rects the hit tests
-- already use are simply painted differently.
--------------------------------------------------------------------------------

local GLASS = {
  white        = { 1, 1, 1 },
  hoverOpacity = 0.14,
  selectedFill = { 1, 1, 1, 0.13 },
  buttonFill   = { 0.18, 0.18, 0.18, 1 },
  dangerFill   = { 0.46, 0.10, 0.10, 1 },
  confirmFill  = { 0.17, 0.38, 0.21, 1 },
  drawOnFill   = { 0.15, 0.42, 0.22, 1 },
  loadFill     = { 0.16, 0.26, 0.52, 1 },
  renderFill   = { 0.30, 0.20, 0.50, 1 },
  accentFill   = { 0.20, 0.42, 0.68, 1 },
  barTrack     = { 0, 0, 0, 0.35 },
  barThumb     = { 1, 1, 1, 0.35 },
}

-- FlowUI's button gradients a fill from a darker bottom to itself on top.
-- Derived once per fill and kept, because the pair is passed on every draw.
local glassGradients = setmetatable({}, {
  __index = function(self, fill)
    local pair = {
      { fill[1] * 0.55, fill[2] * 0.55, fill[3] * 0.55, fill[4] or 1 },
      { fill[1], fill[2], fill[3], fill[4] or 1 },
    }
    self[fill] = pair
    return pair
  end,
})

-- Resolved FlowUI entry points. Re-resolved on init/resize so a late-loading
-- FlowUI is picked up, and every helper degrades to a flat rect without it.
local glass = { ready = false }

local function RefreshGlass()
  local f = WG and WG.FlowUI
  if not f then
    glass.ready = false
    return
  end
  glass.element        = f.Draw.Element
  glass.button         = f.Draw.Button
  glass.rectRound      = f.Draw.RectRound
  glass.highlight      = f.Draw.SelectHighlight
  glass.elementCorner  = f.elementCorner or 4
  glass.elementPadding = f.elementPadding or 4
  glass.opacity        = f.clampedOpacity or 1
  glass.ready          = (f.Draw.Element and f.Draw.RectRound and f.Draw.Button and f.Draw.SelectHighlight)
    and true or false
end

local function InRect(mx, my, l, b, r, t)
  return mx >= l and mx <= r and my >= b and my <= t
end

-- Blur regions handed to gfx_guishader. A list is only rebuilt when its rect
-- actually moves: inserting one dirties the stencil, and doing that every
-- frame would rebuild it every frame.
local glassBlurList = {}
local glassBlurRect = {}

local function SetGlassBlur(name, l, b, r, t)
  if not l then
    local list = glassBlurList[name]
    if list then
      if WG and WG.guishader then WG.guishader.RemoveDlist(name) end
      gl.DeleteList(list)
      glassBlurList[name] = nil
      glassBlurRect[name] = nil
    end
    return
  end
  if not (glass.ready and WG and WG.guishader) then
    return
  end
  local was = glassBlurRect[name]
  if was and was[1] == l and was[2] == b and was[3] == r and was[4] == t then
    return
  end
  local old = glassBlurList[name]
  if old then gl.DeleteList(old) end

  local pad, corner, rectRound = glass.elementPadding, glass.elementCorner, glass.rectRound
  local list = gl.CreateList(function()
    gl.Texture(false)
    rectRound(l - pad, b - pad, r + pad, t + pad, corner)
  end)
  glassBlurList[name] = list
  glassBlurRect[name] = { l, b, r, t }
  WG.guishader.InsertDlist(list, name, nil, widget)
end

local function RemoveAllGlassBlur()
  local names = {}
  for name in pairs(glassBlurList) do names[#names + 1] = name end
  for _, name in ipairs(names) do SetGlassBlur(name, nil) end
end

-- A whole glass panel: the widget-selector window skin.
local function GlassPanel(l, b, r, t)
  if glass.ready then
    glass.element(l, b, r, t, 1, 1, 1, 1, 1, 1, 1, 1, glass.opacity)
  else
    gl.Color(0.08, 0.08, 0.08, 0.85)
    gl.Rect(l, b, r, t)
  end
end

-- A recessed area inside a panel: title bands, fields, list and thumb boxes.
local function GlassInset(l, b, r, t, alpha, cornerMult)
  if glass.ready then
    glass.rectRound(l, b, r, t, glass.elementCorner * (cornerMult or 0.6), 1, 1, 1, 1,
      { 0, 0, 0, alpha or 0.5 })
  else
    gl.Color(0.1, 0.1, 0.1, alpha or 0.7)
    gl.Rect(l, b, r, t)
  end
end

-- A glass button. `fill` is one of the GLASS fills; hover adds the same soft
-- white highlight the selector's rows and buttons use.
local function GlassButton(l, b, r, t, fill, hovered)
  if glass.ready then
    local g = glassGradients[fill]
    glass.button(l, b, r, t, 1, 1, 1, 1, 1, 1, 1, 1, nil, g[1], g[2])
    if hovered then
      glass.highlight(l, b, r, t, glass.elementCorner * 0.7, GLASS.hoverOpacity, GLASS.white)
    end
  else
    gl.Color(fill[1], fill[2], fill[3], fill[4])
    gl.Rect(l, b, r, t)
    if hovered then
      gl.Color(1, 1, 1, GLASS.hoverOpacity)
      gl.Rect(l, b, r, t)
    end
  end
end

--------------------------------------------------------------------------------
-- Windows: main + load popup
--------------------------------------------------------------------------------

-- Main window (draggable)
local mainX, mainY

-- Window placement -- the one place to change where the window sits.
-- Right-aligned and vertically centred, kept at least MAIN_SCREEN_MARGIN from
-- the screen edges. Return plain numbers instead of the math to pin it.
local MAIN_SCREEN_MARGIN = 20
local function MidScreen(vsx, vsy, w, h)
  return math.max(MAIN_SCREEN_MARGIN, vsx - w - MAIN_SCREEN_MARGIN),
         math.max(MAIN_SCREEN_MARGIN, (vsy - h) / 2)
end

local mainDragging     = false
local mainDragDX, mainDragDY = 0, 0
local MAIN_TITLE_H     = 24
local MAIN_WIDTH       = 360
local MAIN_PADDING     = 10   -- padding around elements
local BTN_W, BTN_H     = 80, 24

-- Saved layouts offered straight on the main window, so the ones in use do not
-- need the load popup opened for them.
local MAIN_LIST_ROWS   = 3
local MAIN_LIST_ROW_H  = 18
local MAIN_LIST_H      = 6 + MAIN_LIST_ROWS * MAIN_LIST_ROW_H
-- Bottom of the list box, measured up from mainY (drawing is bottom-up).
local MAIN_LIST_Y      = MAIN_TITLE_H + 10 + BTN_H + 8 + BTN_H + 10 + 20 + 6

-- One place for the window height: the drawing, every hit test and the drag
-- math all read it, so the list can be resized without them drifting apart.
local function MainWindowHeight()
  return MAIN_LIST_Y + MAIN_LIST_H + 5 + MAIN_PADDING * 2
end

-- A saved-layout row on the main window. Shared by the drawing and the hit test
-- so the two cannot disagree about where a row sits.
local function MainListRowRect(i)
  local l = mainX + 10
  local r = mainX + MAIN_WIDTH - 10
  local b = mainY + MAIN_LIST_Y + 3 + (i - 1) * MAIN_LIST_ROW_H
  return l, b, r, b + MAIN_LIST_ROW_H
end

-- Load popup (draggable); positioned on screen by Initialize/ViewResize
local loadPopupVisible = false
local loadX, loadY
local loadDragging     = false
local loadDragStartMX, loadDragStartMY = 0, 0
local loadOrigX, loadOrigY           = 0, 0
local LOAD_TITLE_H     = 24
local LOAD_WIDTH       = 520
local LOAD_HEIGHT      = 400

--------------------------------------------------------------------------------
-- Coordinate helpers
--------------------------------------------------------------------------------

local function WorldToBU(x, z)
  return math.floor(x / BU_SIZE), math.floor(z / BU_SIZE)
end

local function BUToWorld(bx, bz)
  return bx * BU_SIZE, bz * BU_SIZE
end

-- Snap BU coordinates based on snap mode
local function SnapBU(bx, bz, mode)
  if mode == 0 then
    -- Off: no snapping
    return bx, bz
  elseif mode == 1 then
    -- "Intersect": snap to 3 × Third = 3 BU = 48 game units
    local step = 3
    local sx = math.floor(bx / step + 0.5) * step
    local sz = math.floor(bz / step + 0.5) * step
    return sx, sz
  elseif mode == 2 then
    -- "Mid": snap to 1.5 × Third = 1.5 BU = 24 game units
    -- Convert to game units, snap, then back to BU
    local xWorld = bx * BU_SIZE
    local zWorld = bz * BU_SIZE
    local stepIGU = 16 * 1.5  -- 24 game units
    local sxWorld = math.floor(xWorld / stepIGU + 0.5) * stepIGU
    local szWorld = math.floor(zWorld / stepIGU + 0.5) * stepIGU
    return sxWorld / BU_SIZE, szWorld / BU_SIZE
  elseif mode == 3 then
    -- "Thirds": use simple 1‑BU spacing (same integer grid as cross layout)
    return math.floor(bx + 0.5), math.floor(bz + 0.5)
  end
  -- fallback: if mode is invalid, just return original
  return bx, bz
end

--------------------------------------------------------------------------------
-- Layout transformation helpers
--------------------------------------------------------------------------------

-- Transform a BU coordinate (x, z) based on rotation and inversion
-- rotation: 0, 90, 180, or 270 degrees
-- inverted: if true, flip about Y axis (mirror left/right, negate x)
local function TransformBU(x, z, rotation, inverted)
  local tx, tz = x, z
  -- Apply inversion first (flip about Y axis = mirror left/right)
  -- This makes inversion independent of rotation
  if inverted then
    tx = -tx
  end
  -- Then apply rotation (clockwise)
  if rotation == 90 then
    tx, tz = -tz, tx
  elseif rotation == 180 then
    tx, tz = -tx, -tz
  elseif rotation == 270 then
    tx, tz = tz, -tx
  end
  return tx, tz
end

--------------------------------------------------------------------------------
-- Layout helpers
--------------------------------------------------------------------------------

local function ClearCurrentLayout()
  for size, group in pairs(currentLayout.buildings) do
    currentLayout.buildings[size] = {}
  end
  currentLayout.lines = {}
  Spring.Echo("[LayoutPlus] Cleared current layout")
end

local function AddBuilding(bx, bz, size)
  -- kept for compatibility, but not used in Plus (line-focused)
  local group = currentLayout.buildings[size]
  if not group then return end
  group[#group + 1] = { bx, bz }
end

local function ToggleBuilding(bx, bz, size)
  -- disabled in Plus: we focus on line drawing only
  return
end

local function AddLineBU(x1, z1, x2, z2)
  if x1 == x2 and z1 == z2 then return end
  if x2 < x1 or (x2 == x1 and z2 < z1) then
    x1, z1, x2, z2 = x2, z2, x1, z1
  end
  currentLayout.lines[#currentLayout.lines + 1] = { x1, z1, x2, z2 }
end

-- Translate layout (for WASD movement)
local function TranslateLayout(dx, dz)
  -- Translate buildings
  for size, group in pairs(currentLayout.buildings) do
    for _, pos in ipairs(group) do
      pos[1] = pos[1] + dx
      pos[2] = pos[2] + dz
    end
  end
  -- Translate lines
  for _, line in ipairs(currentLayout.lines) do
    line[1] = line[1] + dx
    line[3] = line[3] + dx
    line[2] = line[2] + dz
    line[4] = line[4] + dz
  end
end

-- Get snapped camera direction (for WASD movement)
local function GetSnappedCameraDirection(dx, dz)
  if dx == 0 and dz == 0 then
    return 0, 0
  end

  local inputLen = math.sqrt(dx * dx + dz * dz)
  dx = dx / inputLen
  dz = dz / inputLen

  local dirX, _, dirZ = Spring.GetCameraDirection()
  local camLen = math.sqrt(dirX * dirX + dirZ * dirZ)
  if camLen < 0.0001 then
    return 0, 0
  end

  local forwardX = dirX / camLen
  local forwardZ = dirZ / camLen
  local rightX = -forwardZ
  local rightZ = forwardX

  local worldDX = dx * rightX + dz * forwardX
  local worldDZ = dx * rightZ + dz * forwardZ

  local tx = math.floor(worldDX + 0.5)
  local tz = math.floor(worldDZ + 0.5)

  return tx, tz
end

-- WASD translation is polled rather than event-driven. BAR's action handler runs
-- before every widget's KeyPress and consumes presses bound to registered
-- actions - "stop" is one of them, registered by the pregame build queue - so a
-- widget cannot count on receiving a movement key at all. Reading the pressed
-- set sidesteps both that and the engine's own binds for these letters.
local MOVE_STEP_TIME = 0.1   -- seconds between steps while a movement key is held
local moveStepTimer  = MOVE_STEP_TIME

local function UpdateKeyTranslation(dt)
  if not allowTranslationByKeys then return end
  if showSaveDialog or loadPopupVisible or selectedData then return end

  local keys = Spring.GetPressedKeys()
  local dx, dz = 0, 0

  if keys[119] then dz = dz + 1 end -- W
  if keys[115] then dz = dz - 1 end -- S
  if keys[97]  then dx = dx - 1 end -- A
  if keys[100] then dx = dx + 1 end -- D

  if dx == 0 and dz == 0 then
    moveStepTimer = MOVE_STEP_TIME   -- idle again, so the next press steps at once
    return
  end

  moveStepTimer = moveStepTimer + dt
  if moveStepTimer < MOVE_STEP_TIME then return end
  moveStepTimer = 0

  local tx, tz = GetSnappedCameraDirection(dx, dz)
  if tx ~= 0 or tz ~= 0 then
    TranslateLayout(tx, tz)
    Spring.Echo("[LayoutPlus] Translated layout by (" .. tx .. ", " .. tz .. ")")
  end
end

--------------------------------------------------------------------------------
-- Save / load: file format & IO
--------------------------------------------------------------------------------

local function EnsureLayoutDir()
  -- attempt to write a tiny test and remove it
  local f = io.open(LAYOUT_DIR .. ".test", "w")
  if f then
    f:write("ok")
    f:close()
    os.remove(LAYOUT_DIR .. ".test")
  end
end

local function ComputeBounds(layout)
  local minX, maxX = math.huge, -math.huge
  local minZ, maxZ = math.huge, -math.huge

  for size, group in pairs(layout.buildings or {}) do
    for _, pos in ipairs(group) do
      local x, z = pos[1], pos[2]
      minX = math.min(minX, x)
      maxX = math.max(maxX, x + size - 1)
      minZ = math.min(minZ, z)
      maxZ = math.max(maxZ, z + size - 1)
    end
  end

  for _, line in ipairs(layout.lines or {}) do
    local x1, z1, x2, z2 = line[1], line[2], line[3], line[4]
    minX = math.min(minX, x1, x2)
    maxX = math.max(maxX, x1, x2)
    minZ = math.min(minZ, z1, z2)
    maxZ = math.max(maxZ, z1, z2)
  end

  if minX == math.huge then
    return nil
  end

  return minX, maxX, minZ, maxZ
end

local function SaveLayoutAs(name, tags)
  if not ComputeBounds(currentLayout) then
    Spring.Echo("[LayoutPlus] Nothing to save")
    return
  end
  name = name or "layout"
  local safeName = name:gsub("[^%w_%-]", "_")
  if safeName == "" then safeName = "layout" end
  local filename = LAYOUT_DIR .. safeName .. ".txt"

  -- avoid overwriting by appending a number if exists
  local counter = 1
  local base = safeName
  while true do
    local f = io.open(filename, "r")
    if not f then break end
    f:close()
    safeName = base .. "_" .. counter
    filename = LAYOUT_DIR .. safeName .. ".txt"
    counter = counter + 1
  end

  local minX, maxX, minZ, maxZ = ComputeBounds(currentLayout)
  local width  = maxX - minX + 1
  local height = maxZ - minZ + 1

  local function serializeLayout()
    local result = {}
    local indent = 0

    local function ind() return string.rep("  ", indent) end
    local function line(s) result[#result+1] = ind() .. s end

    line("layout = {")
    indent = indent + 1

    -- buildings
    line("buildings = {")
    indent = indent + 1
    for size, group in pairs(currentLayout.buildings) do
      line("[" .. size .. "] = {")
      indent = indent + 1
      for _, pos in ipairs(group) do
        local x = pos[1] - minX
        local z = pos[2] - minZ
        line(string.format("{%d, %d},", x, z))
      end
      indent = indent - 1
      line("},")
    end
    indent = indent - 1
    line("},") -- end buildings

    -- lines
    line("lines = {")
    indent = indent + 1
    for _, ln in ipairs(currentLayout.lines) do
      local x1, z1, x2, z2 = ln[1]-minX, ln[2]-minZ, ln[3]-minX, ln[4]-minZ
      line(string.format("{%d, %d, %d, %d},", x1, z1, x2, z2))
    end
    indent = indent - 1
    line("}")

    indent = indent - 1
    line("}") -- end layout

    return table.concat(result, "\n")
  end

  local f = io.open(filename, "w")
  if not f then
    Spring.Echo("[LayoutPlus] Could not open " .. filename .. " for write")
    return
  end

  f:write("return {\n")
  f:write("  name = " .. string.format("%q", name) .. ",\n")
  if tags and #tags > 0 then
    f:write("  tags = {")
    for i, t in ipairs(tags) do
      if i > 1 then f:write(", ") end
      f:write(string.format("%q", t))
    end
    f:write("},\n")
  end
  f:write("  width = " .. width .. ",\n")
  f:write("  height = " .. height .. ",\n")
  f:write("  maxX = " .. maxX .. ",\n")
  f:write("  maxZ = " .. maxZ .. ",\n")
  f:write("  minSize = 1,\n")
  f:write("  " .. serializeLayout() .. "\n")
  f:write("}\n")
  f:close()

  Spring.Echo("[LayoutPlus] Saved layout as " .. filename)
end

local function CopyEmptyLayout()
  local copy = {
    buildings = {
      [1]  = {},
      [2]  = {},
      [3]  = {},
      [4]  = {},
      [6]  = {},
      [12] = {},
    },
    lines = {}
  }
  return copy
end

local function LoadLayoutData(raw)
  -- raw: table returned from layout file (may be old or new)
  local layout = CopyEmptyLayout()
  if not raw or type(raw) ~= "table" then
    Spring.Echo("[LayoutPlus] LoadLayoutData: raw is not a table")
    return layout
  end
  
  -- Check if it's a legacy format (layout data directly in raw) or new format (raw.layout)
  local l = raw.layout
  if not l or type(l) ~= "table" then
    -- Legacy format might have layout data directly in raw
    if raw.buildings or raw.lines then
      l = raw
      Spring.Echo("[LayoutPlus] LoadLayoutData: Using legacy format (layout data in root)")
    else
      Spring.Echo("[LayoutPlus] LoadLayoutData: No layout data found")
      return layout
    end
  end

  -- buildings
  if type(l.buildings) == "table" then
    for size, group in pairs(l.buildings) do
      if layout.buildings[size] then
        for _, pos in ipairs(group) do
          layout.buildings[size][#layout.buildings[size]+1] = { pos[1], pos[2] }
        end
      end
    end
  end

  -- lines
  if type(l.lines) == "table" then
    for _, ln in ipairs(l.lines) do
      if #ln == 4 then
        layout.lines[#layout.lines+1] = { ln[1], ln[2], ln[3], ln[4] }
      end
    end
  end

  return layout
end

-- The rows the main window shows: the first few saved layouts by file name.
-- Kept separate from filteredLayouts, which the load popup's search narrows.
local mainListLayouts = {}

local function RefreshMainList()
  local sorted = {}
  for i, item in ipairs(savedLayouts) do
    sorted[i] = item
  end

  local function baseName(path)
    return (path or ""):match("([^/\\]+)$") or ""
  end

  table.sort(sorted, function(a, b)
    return baseName(a.filename) < baseName(b.filename)
  end)

  mainListLayouts = {}
  for i = 1, math.min(MAIN_LIST_ROWS, #sorted) do
    mainListLayouts[i] = sorted[i]
  end
end

local function RefreshSavedLayouts()
  savedLayouts = {}

  if VFS and VFS.DirList then
    -- 1) New-format layouts in LayoutPlannerPlus folder
    local files = VFS.DirList(LAYOUT_DIR, "*.txt", VFS.RAW_FIRST)
    for _, full in ipairs(files or {}) do
      local short = full:match("([^/\\]+)$") or full
      local chunk, err = loadfile(full)
      if chunk then
        local ok, raw = pcall(chunk)
        if ok and type(raw) == "table" then
          local name = raw.name
          if type(name) ~= "string" or name == "" then
            name = short:gsub("%.txt$", ""):gsub("_", " ")
          end
          local tags = raw.tags or {}
          local layout = LoadLayoutData(raw)
          -- Store width/height from file for proper centering
          layout.fileWidth = raw.width
          layout.fileHeight = raw.height
          layout.fileMinSize = raw.minSize
          savedLayouts[#savedLayouts+1] = {
            name     = name,
            tags     = tags,
            filename = full,
            data     = layout,
          }
        end
      else
        Spring.Echo("[LayoutPlus] loadfile error: " .. tostring(err))
      end
    end

    -- 2) Legacy layouts in main Widgets folder: layout_*.txt
    local legacy = VFS.DirList("LuaUI/Widgets/", "layout_*.txt", VFS.RAW_FIRST)
    Spring.Echo("[LayoutPlus] Found " .. #(legacy or {}) .. " legacy layout files")
    for _, full in ipairs(legacy or {}) do
      -- Skip if already in savedLayouts list
      local already = false
      for _, it in ipairs(savedLayouts) do
        if it.filename == full then
          already = true
          break
        end
      end
      if not already then
        local short = full:match("([^/\\]+)$") or full
        -- Skip config files (not layout files)
        if short:match("config") then
          -- Silently skip config files
        else
          local chunk, err = loadfile(full)
          if chunk then
          local ok, raw = pcall(chunk)
          if ok and type(raw) == "table" then
            local baseName = short:gsub("%.txt$", ""):gsub("_", " ")
            local name = (raw.name and raw.name ~= "") and raw.name or (baseName .. " (legacy)")
            local tags = raw.tags or {}
            local layout = LoadLayoutData(raw)
            -- Store width/height from file for proper centering (legacy files have normalized coords)
            layout.fileWidth = raw.width
            layout.fileHeight = raw.height
            layout.fileMinSize = raw.minSize
            -- Debug: check if layout has data
            local lineCount = #(layout.lines or {})
            local buildingCount = 0
            for _, group in pairs(layout.buildings or {}) do
              buildingCount = buildingCount + #(group or {})
            end
            Spring.Echo("[LayoutPlus] Loaded legacy: " .. name .. " (" .. lineCount .. " lines, " .. buildingCount .. " buildings, size " .. (raw.width or "?") .. "x" .. (raw.height or "?") .. ")")
            savedLayouts[#savedLayouts+1] = {
              name     = name,
              tags     = tags,
              filename = full,
              data     = layout,
            }
          else
            -- File executed but didn't return a table (might be empty or invalid format)
            if not ok then
              Spring.Echo("[LayoutPlus] legacy file error executing " .. short .. ": " .. tostring(raw))
            else
              Spring.Echo("[LayoutPlus] legacy file " .. short .. " did not return a table (got " .. type(raw) .. ")")
            end
          end
          else
            Spring.Echo("[LayoutPlus] legacy loadfile error: " .. tostring(err))
          end
        end -- end config file skip check
      end
    end
  end

  -- initial filtered list is full list
  filteredLayouts = savedLayouts

  RefreshMainList()
end

local function ApplySearchFilter()
  -- Reset scroll when filter changes
  listScrollOffset = 0
  
  if searchText == "" then
    filteredLayouts = savedLayouts
    return
  end
  local query = searchText:lower()
  local out = {}
  for _, item in ipairs(savedLayouts) do
    local n = (item.name or ""):lower()
    local hit = n:find(query, 1, true)
    if not hit and item.tags then
      for _, t in ipairs(item.tags) do
        if t:lower():find(query, 1, true) then
          hit = true
          break
        end
      end
    end
    if hit then
      out[#out+1] = item
    end
  end
  filteredLayouts = out
end

--------------------------------------------------------------------------------
-- Thumbnail rendering for selected layout
--------------------------------------------------------------------------------

local function DrawThumbnailSelected(x0, y0, size)
  if not selectedData then
    return
  end

  local layout = selectedData
  local minX, maxX, minZ, maxZ = ComputeBounds(layout)
  if not minX then return end

  local w = maxX - minX
  local h = maxZ - minZ
  if w <= 0 or h <= 0 then return end

  local sx = (size - 16) / w
  local sz = (size - 16) / h
  local scale = math.min(sx, sz)

  local cx = (minX + maxX)/2
  local cz = (minZ + maxZ)/2

  gl.Color(0, 0, 0, 0.7)
  gl.Rect(x0, y0, x0 + size, y0 + size)

  gl.Color(0.5, 0.5, 0.5, 1)
  gl.LineWidth(1.5)
  gl.BeginEnd(GL.LINE_LOOP, function()
    gl.Vertex(x0,        y0)
    gl.Vertex(x0+size,   y0)
    gl.Vertex(x0+size,   y0+size)
    gl.Vertex(x0,        y0+size)
  end)

  -- draw buildings as small squares
  for sizeBU, group in pairs(layout.buildings) do
    for _, pos in ipairs(group) do
      local bx, bz = pos[1], pos[2]
      local lx = x0 + size/2 + (bx - cx) * scale
      local ly = y0 + size/2 + (bz - cz) * scale
      local half = (sizeBU * 0.4) * scale
      gl.Color(0.2, 0.8, 0.2, 0.9)
      gl.Rect(lx - half, ly - half, lx + half, ly + half)
    end
  end

  -- lines overlay
  gl.Color(1, 1, 0, 1)
  gl.LineWidth(1.5)
  gl.BeginEnd(GL.LINES, function()
    for _, ln in ipairs(layout.lines) do
      local x1 = x0 + size/2 + (ln[1] - cx) * scale
      local y1 = y0 + size/2 + (ln[2] - cz) * scale
      local x2 = x0 + size/2 + (ln[3] - cx) * scale
      local y2 = y0 + size/2 + (ln[4] - cz) * scale
      gl.Vertex(x1, y1)
      gl.Vertex(x2, y2)
    end
  end)
end

--------------------------------------------------------------------------------
-- Drawing tools (world)
--------------------------------------------------------------------------------

-- Remove nearest line to BU point
local function RemoveNearestLine(bx, bz, maxDist)
  maxDist = maxDist or 10
  local bestIdx = nil
  local bestDistSq = maxDist * maxDist
  for i, ln in ipairs(currentLayout.lines) do
    local x1, z1, x2, z2 = ln[1], ln[2], ln[3], ln[4]
    local dx, dz = x2 - x1, z2 - z1
    local lenSq = dx*dx + dz*dz
    local px, pz = bx, bz
    local t = 0
    if lenSq > 0 then
      t = ((px-x1)*dx + (pz-z1)*dz) / lenSq
      if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local projX = x1 + t*dx
    local projZ = z1 + t*dz
    local ddx, ddz = px - projX, pz - projZ
    local dSq = ddx*ddx + ddz*ddz
    if dSq <= bestDistSq then
      bestDistSq = dSq
      bestIdx = i
    end
  end
  if bestIdx then
    table.remove(currentLayout.lines, bestIdx)
    return true
  end
  return false
end

--------------------------------------------------------------------------------
-- Rendering to game (map markers)
--------------------------------------------------------------------------------

-- Convert BU edge coordinates to world space and queue them for rendering.
-- Long edges are split into CHUNK_SIZE segments so the render is gradual.
local function DrawEdges(edges)
  drawLineQueue = {}

  for _, edge in ipairs(edges) do
    local x1, z1 = BUToWorld(edge.x1, edge.z1)
    local x2, z2 = BUToWorld(edge.x2, edge.z2)
    local y = 100

    local dx = x2 - x1
    local dz = z2 - z1
    local dist = math.sqrt(dx * dx + dz * dz)

    local segments = math.ceil(dist / CHUNK_SIZE)
    if segments <= 1 then
      table.insert(drawLineQueue, {
        startX = x1, startZ = z1, endX = x2, endZ = z2, y = y
      })
    else
      for i = 0, segments - 1 do
        local t1 = i / segments
        local t2 = (i + 1) / segments
        local sx = x1 + dx * t1
        local sz = z1 + dz * t1
        local ex = x1 + dx * t2
        local ez = z1 + dz * t2
        table.insert(drawLineQueue, {
          startX = sx, startZ = sz, endX = ex, endZ = ez, y = y
        })
      end
    end
  end
  renderingToGame = true
end

-- Collect the outer contour of the current layout: merge shared edges of
-- adjacent same-size buildings into single lines, then add free lines.
local function CollectEdges()
  local function edgeKey(x1, z1, x2, z2)
    -- Normalize to avoid reversed duplicate keys
    if x1 > x2 or (x1 == x2 and z1 > z2) then
      x1, z1, x2, z2 = x2, z2, x1, z1
    end
    return x1 .. "," .. z1 .. "," .. x2 .. "," .. z2
  end

  local rawEdges = {}

  -- 1. Generate 4 outer edges per building
  for size, buildings in pairs(currentLayout.buildings) do
    for _, pos in ipairs(buildings) do
      local bx, bz = pos[1], pos[2]
      local edges = {
        {bx, bz, bx + size, bz},               -- top
        {bx + size, bz, bx + size, bz + size}, -- right
        {bx + size, bz + size, bx, bz + size}, -- bottom
        {bx, bz + size, bx, bz},               -- left
      }

      for _, e in ipairs(edges) do
        local k = edgeKey(unpack(e))
        if rawEdges[k] then
          rawEdges[k] = nil -- shared/internal edge — remove it
        else
          rawEdges[k] = { x1 = e[1], z1 = e[2], x2 = e[3], z2 = e[4] }
        end
      end
    end
  end

  -- 2. Group by horizontal and vertical
  local horizontal, vertical = {}, {}
  for _, edge in pairs(rawEdges) do
    if edge.z1 == edge.z2 then
      table.insert(horizontal, edge)
    elseif edge.x1 == edge.x2 then
      table.insert(vertical, edge)
    end
  end

  local function mergeLines(edges, isHorizontal)
    local merged = {}
    local axis1, axis2 = isHorizontal and "x" or "z", isHorizontal and "z" or "x"

    -- Group by fixed axis2 (e.g., all z for horizontal lines)
    local groups = {}
    for _, e in ipairs(edges) do
      local key = tostring(e[axis2 .. "1"])
      groups[key] = groups[key] or {}
      local a1 = math.min(e[axis1 .. "1"], e[axis1 .. "2"])
      local a2 = math.max(e[axis1 .. "1"], e[axis1 .. "2"])
      table.insert(groups[key], { a1 = a1, a2 = a2 })
    end

    for coord, segs in pairs(groups) do
      table.sort(segs, function(a, b) return a.a1 < b.a1 end)

      local currentA1, currentA2 = segs[1].a1, segs[1].a2
      for i = 2, #segs do
        local seg = segs[i]
        if seg.a1 <= currentA2 then
          currentA2 = math.max(currentA2, seg.a2) -- merge
        else
          -- emit previous
          local line = isHorizontal
            and { x1 = currentA1, z1 = tonumber(coord), x2 = currentA2, z2 = tonumber(coord) }
            or  { x1 = tonumber(coord), z1 = currentA1, x2 = tonumber(coord), z2 = currentA2 }
          table.insert(merged, line)
          currentA1, currentA2 = seg.a1, seg.a2
        end
      end
      -- final segment
      local line = isHorizontal
        and { x1 = currentA1, z1 = tonumber(coord), x2 = currentA2, z2 = tonumber(coord) }
        or  { x1 = tonumber(coord), z1 = currentA1, x2 = tonumber(coord), z2 = currentA2 }
      table.insert(merged, line)
    end

    return merged
  end

  -- 3. Merge all segments
  local result = {}
  for _, e in ipairs(mergeLines(horizontal, true)) do table.insert(result, e) end
  for _, e in ipairs(mergeLines(vertical, false)) do table.insert(result, e) end

  for _, line in ipairs(currentLayout.lines) do
    table.insert(result, { x1 = line[1], z1 = line[2], x2 = line[3], z2 = line[4] })
  end

  return result
end

local function CollectAndDraw()
  DrawEdges(CollectEdges())
end

--------------------------------------------------------------------------------
-- Mouse handling
--------------------------------------------------------------------------------

-- Save dialog: draw + hit-test
local function DrawSaveDialog()
  if not showSaveDialog then
    SetGlassBlur("layoutplannerplus_save", nil)
    return
  end

  local vsx, vsy = gl.GetViewSizes()
  local dialogWidth = 420
  local dialogHeight = 110
  local dialogX = (vsx - dialogWidth) / 2
  local dialogY = (vsy - dialogHeight) / 2

  -- Background: glass panel over a blurred world
  SetGlassBlur("layoutplannerplus_save", dialogX, dialogY, dialogX + dialogWidth, dialogY + dialogHeight)
  GlassPanel(dialogX, dialogY, dialogX + dialogWidth, dialogY + dialogHeight)

  -- Text
  gl.Color(1, 1, 1, 1)
  gl.Text("Save layout as:", dialogX + 10, dialogY + 78, 14, "")

  -- Input box
  GlassInset(dialogX + 10, dialogY + 48, dialogX + dialogWidth - 10, dialogY + 68, 0.45)

  gl.Color(1, 1, 1, 1)
  local displayText = saveNameText
  if #displayText == 0 then
    displayText = "e.g. corner001 or wall02"
    gl.Color(0.5, 0.5, 0.5, 1.0)
  end
  local textX = dialogX + 14
  local textY = dialogY + 52
  gl.Text(displayText, textX, textY, 13, "")
  -- Blinking caret to indicate active text input
  if IsCaretVisible() then
    local w = gl.GetTextWidth(displayText) * 13
    gl.Color(1, 1, 1, 1)
    gl.Text("|", textX + w + 2, textY, 13, "")
  end

  -- Buttons
  local mx, my = Spring.GetMouseState()
  local btnY = dialogY + 14
  local btnWidth = 80
  local btnHeight = 24

  -- OK button
  local okX1, okX2 = dialogX + 10, dialogX + 10 + btnWidth
  GlassButton(okX1, btnY, okX2, btnY + btnHeight, GLASS.confirmFill,
    InRect(mx, my, okX1, btnY, okX2, btnY + btnHeight))
  gl.Color(1, 1, 1, 1)
  gl.Text("OK", dialogX + 10 + 26, btnY + 6, 13, "")

  -- Cancel button
  local cancelX1, cancelX2 = dialogX + dialogWidth - 10 - btnWidth, dialogX + dialogWidth - 10
  GlassButton(cancelX1, btnY, cancelX2, btnY + btnHeight, GLASS.dangerFill,
    InRect(mx, my, cancelX1, btnY, cancelX2, btnY + btnHeight))
  gl.Color(1, 1, 1, 1)
  gl.Text("Cancel", dialogX + dialogWidth - 10 - 48, btnY + 6, 13, "")
end

local function HitTestSaveDialog(mx, my)
  if not showSaveDialog then return nil end

  local vsx, vsy = gl.GetViewSizes()
  local dialogWidth = 420
  local dialogHeight = 110
  local dialogX = (vsx - dialogWidth) / 2
  local dialogY = (vsy - dialogHeight) / 2

  local btnY = dialogY + 14
  local btnWidth = 80
  local btnHeight = 24

  -- OK button
  if mx >= dialogX + 10 and mx <= dialogX + 10 + btnWidth and
     my >= btnY and my <= btnY + btnHeight then
    return "ok"
  end

  -- Cancel button
  if mx >= dialogX + dialogWidth - 10 - btnWidth and mx <= dialogX + dialogWidth - 10 and
     my >= btnY and my <= btnY + btnHeight then
    return "cancel"
  end

  return nil
end

local function HitInMain(mx, my)
  return mx >= mainX and mx <= mainX + MAIN_WIDTH and
         my >= mainY and my <= mainY + MainWindowHeight()
end

local function HitInLoadPopup(mx, my)
  if not loadPopupVisible then return false end
  return mx >= loadX and mx <= loadX + LOAD_WIDTH and
         my >= loadY and my <= loadY + LOAD_HEIGHT
end

-- Simple hit regions inside main window
local function MainButtonHit(mx, my, bx, by, bw, bh)
  local lx, ly = mx - mainX, my - mainY
  return lx >= bx and lx <= bx + bw and ly >= by and ly <= by + bh
end

-- Button layout in main window
local function MainButtonsLayout()
  local y = MAIN_TITLE_H + 10
  return {
    draw   = { x = 10,            y = y },
    clear  = { x = 10 + BTN_W+8,  y = y },
    save   = { x = 10 + 2*(BTN_W+8), y = y },
    load   = { x = 10 + 3*(BTN_W+8), y = y },
    render = { x = 10,            y = y + BTN_H + 8 },
  }
end

local function LoadPopupRegions()
  -- relative coords inside popup
  -- Note: loadY is the TOP of the window, Y increases downward
  -- Title bar is at the TOP (height = LOAD_TITLE_H)
  return {
    -- Search just under the title bar
    searchBox = { x = 10, y = LOAD_TITLE_H + 8, w = 200, h = 20 },
    -- List box starts a bit under the search bar
    listBox   = { x = 10, y = LOAD_TITLE_H + 36, w = 200, h = LOAD_HEIGHT - LOAD_TITLE_H - 56 },
    -- Larger thumbnail, starts below the buttons, aligned with list vertically
    thumbBox  = { x = 220, y = LOAD_TITLE_H + 36, w = 280, h = 290 },
    -- Buttons sit just under the title bar, above search/list
    btnLoad   = { x = 220, y = LOAD_TITLE_H + 6, w = 60,  h = 24 },
    btnDel    = { x = 285, y = LOAD_TITLE_H + 6, w = 60,  h = 24 },
    btnDup    = { x = 350, y = LOAD_TITLE_H + 6, w = 60,  h = 24 },
    btnClose  = { x = LOAD_WIDTH - 70, y = LOAD_TITLE_H + 6, w = 60, h = 20 }
  }
end

function widget:MousePress(mx, my, button)
  -- Save dialog clicks
  if showSaveDialog then
    local hit = HitTestSaveDialog(mx, my)
    if hit == "ok" then
      if saveNameText ~= "" then
        SaveLayoutAs(saveNameText, {})
        RefreshSavedLayouts()
        ApplySearchFilter()
      end
      showSaveDialog = false
      saveNameText = ""
      return true
    elseif hit == "cancel" then
      showSaveDialog = false
      saveNameText = ""
      return true
    end
    return true -- consume clicks while dialog open
  end
  -- Handle load popup first
  if loadPopupVisible then
    local relX = mx - loadX
    -- Mouse Y is in bottom-up coordinates, convert loadY (top-down) to bottom-up for comparison
    local vsx, vsy = gl.GetViewSizes()
    local loadY_bu = vsy - (loadY + LOAD_HEIGHT)  -- Bottom of window in bottom-up
    local relY_bu = my - loadY_bu  -- Mouse Y relative to bottom of window (bottom-up)
    local r = LoadPopupRegions()

    -- drag popup by title bar: full title height
    local titleBarTop_bu    = vsy - loadY              -- Window top in bottom-up
    local titleBarBottom_bu = vsy - (loadY + LOAD_TITLE_H)
    if button == 1 and relX >= 0 and relX <= LOAD_WIDTH and
       my >= titleBarBottom_bu and my <= titleBarTop_bu then
      loadDragging = true
      -- Store starting mouse position (bottom-up) and original window position (top-down)
      loadDragStartMX, loadDragStartMY = mx, my
      loadOrigX, loadOrigY             = loadX, loadY
      return true
    end

    -- close button (convert button rect to bottom-up, match drawBtn exactly)
    if button == 1 then
      local btnCloseTopY    = loadY + r.btnClose.y              -- top in top-down
      local btnCloseBottomY = btnCloseTopY + r.btnClose.h       -- bottom in top-down
      local btnX1 = loadX + r.btnClose.x
      local btnX2 = btnX1 + r.btnClose.w
      local btnY1 = vsy - btnCloseBottomY   -- bottom in bottom-up
      local btnY2 = vsy - btnCloseTopY      -- top in bottom-up
      if mx >= btnX1 and mx <= btnX2 and my >= btnY1 and my <= btnY2 then
        -- Just close the popup and restore state; do NOT start/keep a preview
        loadPopupVisible = false
        drawingMode      = wasDrawingBeforeLoad
        -- Cancel any selected layout & transforms so nothing follows the cursor
        selectedIndex    = nil
        selectedData     = nil
        layoutRotation   = 0
        layoutInverted   = false
        return true
      end
    end

    -- buttons Load/Delete/Duplicate (convert button Y to bottom-up)
    -- Check buttons FIRST so they get priority over list box
    if button == 1 then
      -- Match rendering calculation exactly
      local btnLoadTopY = loadY + r.btnLoad.y  -- Top in top-down
      local btnLoadBottomY = btnLoadTopY + r.btnLoad.h  -- Bottom in top-down
      local btnLoadBottomY_bu = vsy - btnLoadBottomY  -- Bottom in bottom-up
      local btnLoadTopY_bu = vsy - btnLoadTopY  -- Top in bottom-up
      if relX >= r.btnLoad.x and relX <= r.btnLoad.x + r.btnLoad.w and
         my >= btnLoadBottomY_bu and my <= btnLoadTopY_bu then
        -- select layout; popup closes, preview will be visible via selectedData
        if selectedIndex and filteredLayouts[selectedIndex] then
          loadPopupVisible = false
          -- keep drawing off until placement completes
        end
        return true
      end
      -- Match rendering calculation exactly
      local btnDelTopY = loadY + r.btnDel.y  -- Top in top-down
      local btnDelBottomY = btnDelTopY + r.btnDel.h  -- Bottom in top-down
      local btnDelBottomY_bu = vsy - btnDelBottomY  -- Bottom in bottom-up
      local btnDelTopY_bu = vsy - btnDelTopY  -- Top in bottom-up
      if relX >= r.btnDel.x and relX <= r.btnDel.x + r.btnDel.w and
         my >= btnDelBottomY_bu and my <= btnDelTopY_bu then
        if selectedIndex and filteredLayouts[selectedIndex] then
          local item = filteredLayouts[selectedIndex]
          if item.filename then
            os.remove(item.filename)
          end
          RefreshSavedLayouts()
          ApplySearchFilter()
          selectedIndex = nil
          selectedData  = nil
          layoutRotation = 0
          layoutInverted = false
        end
        return true
      end
      -- Match rendering calculation exactly
      local btnDupTopY = loadY + r.btnDup.y  -- Top in top-down
      local btnDupBottomY = btnDupTopY + r.btnDup.h  -- Bottom in top-down
      local btnDupBottomY_bu = vsy - btnDupBottomY  -- Bottom in bottom-up
      local btnDupTopY_bu = vsy - btnDupTopY  -- Top in bottom-up
      if relX >= r.btnDup.x and relX <= r.btnDup.x + r.btnDup.w and
         my >= btnDupBottomY_bu and my <= btnDupTopY_bu then
        if selectedIndex and filteredLayouts[selectedIndex] then
          local item = filteredLayouts[selectedIndex]
          if item and item.filename then
            local f = io.open(item.filename, "r")
            if f then
              local text = f:read("*all")
              f:close()
              -- find new filename
              local base = item.filename:gsub("%.txt$", "")
              local n = 1
              local newName
              while true do
                newName = base .. "_copy" .. n .. ".txt"
                local t = io.open(newName, "r")
                if not t then break end
                t:close()
                n = n + 1
              end
              local nf = io.open(newName, "w")
              if nf then
                nf:write(text)
                nf:close()
                RefreshSavedLayouts()
                ApplySearchFilter()
              end
            end
          end
        end
        return true
      end
    end

    -- search box focus (we'll just always treat keyboard as updating search when popup visible)
    -- list click: mirror DrawScreen item rectangles exactly (bottom-up coords)
    local listBoxTopY = loadY + r.listBox.y  -- Top in top-down
    local listBoxBottomY = listBoxTopY + r.listBox.h
    local listBoxBottomY_bu = vsy - listBoxBottomY  -- Bottom in bottom-up
    local listBoxTopY_bu = vsy - listBoxTopY        -- Top in bottom-up
    if button == 1 and
       relX >= r.listBox.x and relX <= r.listBox.x + r.listBox.w and
       my >= listBoxBottomY_bu and my <= listBoxTopY_bu then
      local totalItems = #filteredLayouts
      if totalItems > 0 then
        local maxVisible  = 18
        local hasScrollbar = totalItems > maxVisible
        local scrollBarW   = 8
        local scrollBarX   = r.listBox.x + r.listBox.w - scrollBarW - 2
        if hasScrollbar and relX >= scrollBarX then
          -- Clicked on scrollbar - handled separately
          return true
        end

        -- Clamp scroll offset like in DrawScreen
        local maxScroll = math.max(0, totalItems - maxVisible)
        if totalItems <= maxVisible then
          listScrollOffset = 0
        else
          if listScrollOffset > maxScroll then listScrollOffset = maxScroll end
          if listScrollOffset < 0 then listScrollOffset = 0 end
        end

        local rowH = 18
        local itemsToShow = math.min(maxVisible, totalItems - listScrollOffset)

        -- Iterate rows and use the exact same rect math as DrawScreen
        for row = 0, itemsToShow - 1 do
          local itemIndex = listScrollOffset + row + 1
          if itemIndex > totalItems then break end

          local itemTopY    = listBoxTopY + 2 + (row * rowH)
          local itemBottomY = itemTopY + rowH
          if itemTopY + rowH > listBoxBottomY then
            break
          end

          local rectY1 = vsy - itemBottomY -- bottom in bottom-up
          local rectY2 = vsy - itemTopY    -- top in bottom-up

          if my >= rectY1 and my <= rectY2 then
            selectedIndex = itemIndex
            selectedData  = filteredLayouts[itemIndex].data
            -- Reset transformation when selecting a new layout
            layoutRotation = 0
            layoutInverted = false
            break
          end
        end
      end
      return true
    end

    -- while popup is open, block clicks from reaching world/drawing logic
    return true
  end

  -- main window buttons
  local btns = MainButtonsLayout()
  if button == 1 and HitInMain(mx, my) then
    if MainButtonHit(mx, my, btns.draw.x, btns.draw.y, BTN_W, BTN_H) then
      -- While load popup is open or a layout is attached to the mouse,
      -- do NOT allow toggling draw mode.
      if loadPopupVisible or selectedData then
        Spring.Echo("[LayoutPlus] Finish or cancel layout placement before toggling Draw")
        return true
      end
      drawingMode = not drawingMode
      Spring.Echo("[LayoutPlus] Drawing: " .. (drawingMode and "ON" or "OFF"))
      return true
    end
    if MainButtonHit(mx, my, btns.clear.x, btns.clear.y, BTN_W, BTN_H) then
      ClearCurrentLayout()
      return true
    end
    if MainButtonHit(mx, my, btns.save.x, btns.save.y, BTN_W, BTN_H) then
      -- open save name dialog
      showSaveDialog = true
      saveNameText = ""
      return true
    end
    if MainButtonHit(mx, my, btns.load.x, btns.load.y, BTN_W, BTN_H) then
      if #savedLayouts > 0 then
        -- remember drawing state, and turn drawing off while loading
        wasDrawingBeforeLoad = drawingMode
        drawingMode = false
        -- open load popup positioned over the main window (same top‑left)
        loadX, loadY       = mainX, mainY
        loadPopupVisible   = true
        listScrollOffset = 0  -- Reset scroll when opening popup
        RefreshSavedLayouts()
        ApplySearchFilter()
      else
        Spring.Echo("[LayoutPlus] No saved layouts found")
      end
      return true
    end
    if MainButtonHit(mx, my, btns.render.x, btns.render.y, BTN_W, BTN_H) then
      -- Render current layout as game map markers using queue (gradual rendering)
      Spring.Echo("[LayoutPlus] Render button clicked - queuing lines for rendering")
      CollectAndDraw()
      Spring.Echo("[LayoutPlus] Queued " .. #drawLineQueue .. " lines for gradual rendering")
      renderTimer = 0
      return true
    end
  end

  -- snap mode buttons (inside main)
  if button == 1 and HitInMain(mx, my) then
    local lx, ly = mx - mainX, my - mainY
    local snapY = MAIN_TITLE_H + 10 + BTN_H + 8 + BTN_H + 10
    if ly >= snapY + 2 and ly <= snapY + 18 then
      local x = 80
      for i = 0, 3 do
        local w = 60
        if lx >= x and lx <= x + w then
          lineSnapMode = i
          local labels = {"Off", "Intersect", "Mid", "Third"}
          local steps = {"none", "3 BU (48 IGU)", "1.5 BU (24 IGU)", "1 BU (16 IGU)"}
          Spring.Echo("[LayoutPlus] Line snap: " .. labels[i+1] .. " (mode " .. i .. ", step: " .. steps[i+1] .. ")")
          return true
        end
        x = x + w + 4
      end
    end
  end

  -- saved-layout rows on the main window: arm the layout for placement, the
  -- same state the load popup leaves behind. Rendering stays a separate step.
  if button == 1 and HitInMain(mx, my) then
    for i, item in ipairs(mainListLayouts) do
      local l, b, r, t = MainListRowRect(i)
      if InRect(mx, my, l, b, r, t) then
        selectedIndex  = nil
        selectedData   = item.data
        layoutRotation = 0
        layoutInverted = false
        Spring.Echo("[LayoutPlus] Activated layout: " .. tostring(item.name or "?"))
        return true
      end
    end
  end

  -- Exit button click (in title bar)
  if button == 1 and HitInMain(mx, my) then
    local lx, ly = mx - mainX, my - mainY
    local h        = MainWindowHeight()
    local exitBtnX = MAIN_WIDTH - 24
    local exitBtnY = h - MAIN_TITLE_H + 2
    if lx >= exitBtnX and lx <= exitBtnX + 20 and
       ly >= exitBtnY and ly <= exitBtnY + 20 then
      -- Disable widget (user can re-enable via F11 menu)
      if not exitButtonClicked then
        exitButtonClicked = true
        Spring.Echo("[LayoutPlus] Widget disabled. Re-enable via F11 menu.")
        if widgetHandler and widgetHandler.RemoveWidget then
          widgetHandler:RemoveWidget(widget)
        end
      end
      return true
    end
  end

  -- main window drag (only title bar or empty edges, after button handling)
  if button == 1 and HitInMain(mx, my) then
    local lx, ly = mx - mainX, my - mainY
    local h        = MainWindowHeight()
    local onTitleBar = ly >= h - MAIN_TITLE_H and ly <= h
    local edgeMargin = 5
    local onEdge = (lx <= edgeMargin or lx >= MAIN_WIDTH - edgeMargin or
                    ly <= edgeMargin or ly >= h - edgeMargin)
    -- Don't drag if clicking exit button
    local exitBtnX = MAIN_WIDTH - 24
    local exitBtnY = h - MAIN_TITLE_H + 2
    local onExitBtn = (lx >= exitBtnX and lx <= exitBtnX + 20 and
                       ly >= exitBtnY and ly <= exitBtnY + 20)
    if (onTitleBar or onEdge) and not onExitBtn then
      mainDragging = true
      mainDragDX, mainDragDY = mx - mainX, my - mainY
      return true
    end
  end

  -- placement of selected layout (when Draw: OFF)
  if not drawingMode and selectedData and button == 1 then
    local _, pos = Spring.TraceScreenRay(mx, my, true)
    if pos then
      local bx, bz = WorldToBU(pos[1], pos[3])
      local layout = selectedData
      -- Use file width/height if available (for legacy files with normalized coords)
      -- Otherwise compute bounds from actual coordinates
      local cx, cz
      if layout.fileWidth and layout.fileHeight then
        -- Legacy format: coordinates are normalized (start at 0,0), use file dimensions for centering
        local minSize = layout.fileMinSize or 1
        cx = math.floor((layout.fileWidth + minSize) / 2)
        cz = math.floor((layout.fileHeight + minSize) / 2)
      else
        -- New format: compute bounds from actual coordinates
        local minX, maxX, minZ, maxZ = ComputeBounds(layout)
        if not minX then return false end
        cx = (minX + maxX)/2
        cz = (minZ + maxZ)/2
      end
      if cx and cz then
        -- Calculate translation offset (like original LayoutPlanner)
        -- For legacy: shift = (width + minSize)/2, translate by (bx - shift, bz - shift)
        -- For new: shift = center, translate by (bx - shift, bz - shift)
        local shiftX, shiftZ
        if layout.fileWidth and layout.fileHeight then
          -- Legacy format: use file dimensions
          local minSize = layout.fileMinSize or 1
          shiftX = math.floor((layout.fileWidth + minSize) / 2)
          shiftZ = math.floor((layout.fileHeight + minSize) / 2)
        else
          -- New format: use computed center
          shiftX = cx
          shiftZ = cz
        end
        
        -- copy buildings as line edges (with transformation and translation)
        for size, group in pairs(layout.buildings) do
          for _, posBU in ipairs(group) do
            -- First translate to cursor-relative position (like original LayoutPlanner)
            local tx1, tz1 = posBU[1] + (bx - shiftX), posBU[2] + (bz - shiftZ)
            local tx2, tz2 = posBU[1] + size + (bx - shiftX), posBU[2] + (bz - shiftZ)
            local tx3, tz3 = posBU[1] + size + (bx - shiftX), posBU[2] + size + (bz - shiftZ)
            local tx4, tz4 = posBU[1] + (bx - shiftX), posBU[2] + size + (bz - shiftZ)
            
            -- Then apply rotation/inversion relative to the placed center (bx, bz)
            local relX1, relZ1 = TransformBU(tx1 - bx, tz1 - bz, layoutRotation, layoutInverted)
            local relX2, relZ2 = TransformBU(tx2 - bx, tz2 - bz, layoutRotation, layoutInverted)
            local relX3, relZ3 = TransformBU(tx3 - bx, tz3 - bz, layoutRotation, layoutInverted)
            local relX4, relZ4 = TransformBU(tx4 - bx, tz4 - bz, layoutRotation, layoutInverted)
            
            -- Final position
            local sx1, sz1 = relX1 + bx, relZ1 + bz
            local sx2, sz2 = relX2 + bx, relZ2 + bz
            local sx3, sz3 = relX3 + bx, relZ3 + bz
            local sx4, sz4 = relX4 + bx, relZ4 + bz
            AddLineBU(sx1, sz1, sx2, sz2)
            AddLineBU(sx2, sz2, sx3, sz3)
            AddLineBU(sx3, sz3, sx4, sz4)
            AddLineBU(sx4, sz4, sx1, sz1)
          end
        end
        -- copy layout lines (with transformation and translation)
        for _, ln in ipairs(layout.lines) do
          -- First translate to cursor-relative position
          local tx1, tz1 = ln[1] + (bx - shiftX), ln[2] + (bz - shiftZ)
          local tx2, tz2 = ln[3] + (bx - shiftX), ln[4] + (bz - shiftZ)
          
          -- Then apply rotation/inversion relative to the placed center (bx, bz)
          local relX1, relZ1 = TransformBU(tx1 - bx, tz1 - bz, layoutRotation, layoutInverted)
          local relX2, relZ2 = TransformBU(tx2 - bx, tz2 - bz, layoutRotation, layoutInverted)
          
          -- Final position
          local sx1, sz1 = relX1 + bx, relZ1 + bz
          local sx2, sz2 = relX2 + bx, relZ2 + bz
          AddLineBU(sx1, sz1, sx2, sz2)
        end
        Spring.Echo("[LayoutPlus] Placed layout at cursor")
        -- stop following the mouse after placement and restore drawing state
        selectedData  = nil
        selectedIndex = nil
        drawingMode   = wasDrawingBeforeLoad
        layoutRotation = 0
        layoutInverted = false
        return true
      end
    end
  end

  -- drawing on map
  if not drawingMode then
    return false
  end

  local _, pos = Spring.TraceScreenRay(mx, my, true)
  if not pos then
    return false
  end

  local bx, bz = WorldToBU(pos[1], pos[3])

  if button == 1 then
    -- start line drawing
    lineStart = { bx = bx, bz = bz }
    return true
  elseif button == 3 then
    -- start removal drag (click or box)
    removeDragStart = { bx = bx, bz = bz }
    return true
  end

  return false
end

function widget:MouseMove(mx, my, dx, dy, button)
  if mainDragging then
    mainX, mainY = mx - mainDragDX, my - mainDragDY
    return
  end
  if loadDragging then
    -- Mouse Y is bottom-up, loadY is top-down.
    -- Horizontal movement is the same, vertical must be inverted to feel natural.
    local dx = mx - loadDragStartMX
    local dy = my - loadDragStartMY
    loadX = loadOrigX + dx
    loadY = loadOrigY - dy
    return
  end
end

function widget:MouseRelease(mx, my, button)
  if button == 1 then
    if mainDragging then
      mainDragging = false
      return true
    end
    if loadDragging then
      loadDragging = false
      return true
    end
  end

  local _, pos = Spring.TraceScreenRay(mx, my, true)
  if not pos then
    lineStart = nil
    removeDragStart = nil
    return false
  end

  local bx, bz = WorldToBU(pos[1], pos[3])

  if button == 1 then
    -- drawing mode: finish line
    if not drawingMode then
      lineStart = nil
      removeDragStart = nil
      return false
    end

    if lineStart then
      -- free line with snap
      local sx1, sz1 = SnapBU(lineStart.bx, lineStart.bz, lineSnapMode)
      local sx2, sz2 = SnapBU(bx, bz, lineSnapMode)
      AddLineBU(sx1, sz1, sx2, sz2)
      lineStart = nil
      return true
    end
  elseif button == 3 and removeDragStart then
    -- right-drag removal: if small movement, treat as click; else box-remove
    local sx, sz = removeDragStart.bx, removeDragStart.bz
    local dx, dz = math.abs(bx - sx), math.abs(bz - sz)
    if dx <= 1 and dz <= 1 then
      -- click: remove nearest line
      if not RemoveNearestLine(bx, bz, 10) then
        Spring.Echo("[LayoutPlus] No line near click")
      end
    else
      -- box selection: remove lines whose midpoint is inside box
      local minX, maxX = math.min(sx, bx), math.max(sx, bx)
      local minZ, maxZ = math.min(sz, bz), math.max(sz, bz)
      for i = #currentLayout.lines, 1, -1 do
        local ln = currentLayout.lines[i]
        local mxl = (ln[1] + ln[3]) / 2
        local mzl = (ln[2] + ln[4]) / 2
        if mxl >= minX and mxl <= maxX and mzl >= minZ and mzl <= maxZ then
          table.remove(currentLayout.lines, i)
        end
      end
      Spring.Echo("[LayoutPlus] Removed lines in box")
    end
    removeDragStart = nil
    return true
  end

  return false
end

--------------------------------------------------------------------------------
-- Keyboard
--------------------------------------------------------------------------------

function widget:KeyPress(key, mods, isRepeat)
  if showSaveDialog then
    -- handle save name input
    if key == 8 then -- backspace
      saveNameText = saveNameText:sub(1, -2)
      return true
    elseif key == 27 then -- ESC
      showSaveDialog = false
      saveNameText = ""
      return true
    elseif key == 13 then -- ENTER
      if saveNameText ~= "" then
        SaveLayoutAs(saveNameText, {})
        RefreshSavedLayouts()
        ApplySearchFilter()
      end
      showSaveDialog = false
      saveNameText = ""
      return true
    elseif key >= 32 and key <= 126 then
      saveNameText = saveNameText .. string.char(key)
      return true
    end
    return true
  end

  if loadPopupVisible then
    -- ESC closes load popup and restores drawing state
    if key == 27 then -- ESC
      loadPopupVisible = false
      drawingMode = wasDrawingBeforeLoad
      return true
    end
    -- simple search input: letters/backspace
    if key == 8 then -- backspace
      searchText = searchText:sub(1, -2)
      ApplySearchFilter()
      return true
    elseif key >= 32 and key <= 126 then
      searchText = searchText .. string.char(key)
      ApplySearchFilter()
      return true
    end
  end

  -- ESC while a layout is preview-following the mouse cancels that preview
  if key == 27 and selectedData then
    selectedData  = nil
    selectedIndex = nil
    drawingMode   = wasDrawingBeforeLoad
    layoutRotation = 0
    layoutInverted = false
    return true
  end

  -- ESC with only main window: force Draw OFF
  if key == 27 and not loadPopupVisible and not showSaveDialog and not selectedData then
    if drawingMode then
      drawingMode = false
      Spring.Echo("[LayoutPlus] Drawing: OFF (ESC)")
      return true
    end
  end

  -- Rotation and inversion keys (only when layout is selected)
  if selectedData then
    if key == 114 then -- 'r' key
      layoutRotation = (layoutRotation + 90) % 360
      Spring.Echo("[LayoutPlus] Rotation: " .. layoutRotation .. "°")
      return true
    elseif key == 105 then -- 'i' key
      layoutInverted = not layoutInverted
      Spring.Echo("[LayoutPlus] Inverted: " .. (layoutInverted and "Yes" or "No"))
      return true
    end
  end

  -- The movement itself happens in Update, from the polled key state. The press
  -- is still claimed here so the engine's own binds for these letters - wait,
  -- attack, manualfire - do not fire while a layout is being nudged. A press
  -- BAR consumes first (S during the prepare phase) never reaches this, which
  -- is exactly why the movement could not live here in the first place.
  if allowTranslationByKeys and not showSaveDialog and not loadPopupVisible and not selectedData then
    if key == 119 or key == 115 or key == 97 or key == 100 then
      return true
    end
  end

  if key == 306 then -- CTRL
    ctrlMode = true
  elseif key == 308 then -- ALT
    altMode = true
  end

  return false
end

function widget:MouseWheel(up, value)
  if loadPopupVisible then
    local maxVisible = 18  -- Match the display maxVisible
    local totalItems = #filteredLayouts
    local maxScroll = math.max(0, totalItems - maxVisible)
    
    -- Mouse wheel: reverse the logic to match user expectation
    -- When user scrolls "up" (wheel away), they want to see items higher in the list (decrease offset)
    -- When user scrolls "down" (wheel toward), they want to see items lower in the list (increase offset)
    if not up then  -- Reversed: "not up" means scroll up in the list
      listScrollOffset = math.max(0, listScrollOffset - 1)
    else  -- "up" means scroll down in the list
      listScrollOffset = math.min(maxScroll, listScrollOffset + 1)
    end
    return true
  end
  return false
end

function widget:KeyRelease(key, mods)
  if key == 306 then
    ctrlMode = false
  elseif key == 308 then
    altMode = false
  end
end

--------------------------------------------------------------------------------
-- DrawScreen: main window + popup
--------------------------------------------------------------------------------

function widget:DrawScreen()
  gl.Color(1, 1, 1, 1)
  gl.Blending(true)
  gl.DepthTest(false)

  if not glass.ready then RefreshGlass() end
  local mx, my = Spring.GetMouseState()

  -- main window
  local h        = MainWindowHeight()
  local mainTop  = mainY + h

  SetGlassBlur("layoutplannerplus_main", mainX, mainY, mainX + MAIN_WIDTH, mainTop)
  GlassPanel(mainX, mainY, mainX + MAIN_WIDTH, mainTop)

  -- title band
  GlassInset(mainX + 1, mainTop - MAIN_TITLE_H, mainX + MAIN_WIDTH - 1, mainTop - 1, 0.5)
  gl.Color(1, 0.7, 0.2, 1)
  gl.Text("LayoutPlannerPlus", mainX + 8, mainTop - MAIN_TITLE_H + 4, 14, "")

  -- Exit button in title bar (top-right)
  local exitBtnX = mainX + MAIN_WIDTH - 24
  local exitBtnY = mainTop - MAIN_TITLE_H + 2
  GlassButton(exitBtnX, exitBtnY, exitBtnX + 20, exitBtnY + 20, GLASS.dangerFill,
    InRect(mx, my, exitBtnX, exitBtnY, exitBtnX + 20, exitBtnY + 20))
  gl.Color(1, 1, 1, 1)
  gl.Text("×", exitBtnX + 6, exitBtnY + 2, 16, "")

  local btns = MainButtonsLayout()
  -- draw buttons
  for id, pos in pairs(btns) do
    local label, fill
    if id == "draw" then
      label = drawingMode and "Draw: ON" or "Draw: OFF"
      fill = drawingMode and GLASS.drawOnFill or GLASS.buttonFill
    elseif id == "clear" then
      label = "Clear"
      fill = GLASS.dangerFill
    elseif id == "save" then
      label = "Save"
      fill = GLASS.confirmFill
    elseif id == "load" then
      label = "Load"
      if #savedLayouts == 0 then
        fill = GLASS.buttonFill  -- muted while there is nothing to load
      else
        fill = GLASS.loadFill
      end
    elseif id == "render" then
      label = "Render"
      fill = GLASS.renderFill
    end
    local l, b, r, t = mainX + pos.x, mainY + pos.y, mainX + pos.x + BTN_W, mainY + pos.y + BTN_H
    local enabled = (id ~= "load") or (#savedLayouts > 0)
    GlassButton(l, b, r, t, fill, enabled and InRect(mx, my, l, b, r, t))
    gl.Color(1,1,1,1)
    local tw = gl.GetTextWidth(label) * 12
    local tx = l + (BTN_W - tw)/2
    local ty = b + 6
    gl.Text(label, tx, ty, 12, "")
  end

  -- Line snap mode selector (only control row below main buttons)
  local snapY = mainY + MAIN_TITLE_H + 10 + BTN_H + 8 + BTN_H + 10
  GlassInset(mainX + 10, snapY, mainX + MAIN_WIDTH - 10, snapY + 20)
  gl.Color(1,1,1,1)
  gl.Text("Line Snap:", mainX + 12, snapY + 4, 10, "")
  local snapLabels = {"Off", "Intersect", "Mid", "Third"}
  local snapX = mainX + 80
  for i = 0, 3 do
    local w = 60
    local l, b, r, t = snapX, snapY + 2, snapX + w, snapY + 18
    local fill = (i == lineSnapMode) and GLASS.accentFill or GLASS.buttonFill
    GlassButton(l, b, r, t, fill, InRect(mx, my, l, b, r, t))
    gl.Color(1,1,1,1)
    gl.Text(snapLabels[i+1], l + 4, snapY + 5, 10, "")
    snapX = snapX + w + 4
  end

  -- Saved layouts, first three by file name. Picking one arms it for placement
  -- exactly as the load popup does; nothing is drawn to the map here, that is
  -- still the Render button.
  local listX1 = mainX + 10
  local listX2 = mainX + MAIN_WIDTH - 10
  local listY1 = mainY + MAIN_LIST_Y
  GlassInset(listX1, listY1, listX2, listY1 + MAIN_LIST_H)

  if #mainListLayouts == 0 then
    gl.Color(0.55,0.55,0.55,1)
    gl.Text("No saved layouts", listX1 + 6, listY1 + MAIN_LIST_H/2 - 5, 11, "")
  else
    for i, item in ipairs(mainListLayouts) do
      local l, b, r, t = MainListRowRect(i)
      local active  = selectedData ~= nil and item.data == selectedData
      local hovered = InRect(mx, my, l, b, r, t)

      if active then
        if glass.ready then
          glass.rectRound(l, b, r, t, glass.elementCorner * 0.5, 1, 1, 1, 1, GLASS.selectedFill)
        else
          gl.Color(1,1,1,0.13)
          gl.Rect(l, b, r, t)
        end
      elseif hovered and glass.ready then
        glass.highlight(l, b, r, t, glass.elementCorner * 0.5, GLASS.hoverOpacity, GLASS.white)
      end

      gl.Color(1,1,1,1)
      gl.Text(item.name or "?", l + 4, b + 4, 11, "")
    end
  end

  -- hint text
  gl.Color(1,1,1,0.8)
  local hintText = "LMB Lines, RMB remove | WASD: move placed layout"
  gl.Text(hintText, mainX + 10, mainY + 10, 11, "")

  -- load popup
  if loadPopupVisible then
    -- Get viewport size for coordinate conversion (Spring uses bottom-up coordinates)
    local vsx, vsy = gl.GetViewSizes()

    -- Window background (convert to bottom-up)
    local winY1 = vsy - (loadY + LOAD_HEIGHT)
    local winY2 = vsy - loadY
    SetGlassBlur("layoutplannerplus_load", loadX, winY1, loadX + LOAD_WIDTH, winY2)
    GlassPanel(loadX, winY1, loadX + LOAD_WIDTH, winY2)

    -- Title bar (at TOP of window)
    GlassInset(loadX + 1, winY2 - LOAD_TITLE_H, loadX + LOAD_WIDTH - 1, winY2 - 1, 0.5)

    gl.Color(1,0.7,0.2,1)
    -- Place title text closer to the vertical middle of the header (baseline from bottom)
    local titleBottom_td = loadY + LOAD_TITLE_H
    local titleTextBaseline_td = titleBottom_td - 6  -- ~6px above bottom of header
    local titleTextY = vsy - titleTextBaseline_td
    gl.Text("LayoutPlannerPlus - Load Menu", loadX + 8, titleTextY, 14, "")

    local r = LoadPopupRegions()

    -- search box (convert to bottom-up)
    local searchY1 = vsy - (loadY + r.searchBox.y + r.searchBox.h)
    local searchY2 = vsy - (loadY + r.searchBox.y)
    GlassInset(loadX + r.searchBox.x, searchY1, loadX + r.searchBox.x + r.searchBox.w, searchY2, 0.45)
    gl.Color(0.9,0.9,0.9,1)
    local searchBoxTopY = loadY + r.searchBox.y  -- Top in top-down
    local searchTextY = vsy - (searchBoxTopY + r.searchBox.h - 4)  -- Text Y in bottom-up (centered vertically)
    local sText = searchText ~= "" and searchText or "Search..."
    local sX    = loadX + r.searchBox.x + 4
    gl.Text(sText, sX, searchTextY, 11, "")
    -- Blinking caret for search input while load popup is open
    if IsCaretVisible() then
      local w = gl.GetTextWidth(sText) * 11
      gl.Color(1,1,1,1)
      gl.Text("|", sX + w + 2, searchTextY, 11, "")
    end

    -- list box (convert to bottom-up)
    local listY1 = vsy - (loadY + r.listBox.y + r.listBox.h)
    local listY2 = vsy - (loadY + r.listBox.y)
    GlassInset(loadX + r.listBox.x, listY1, loadX + r.listBox.x + r.listBox.w, listY2, 0.5)

    local rowH = 18
    local maxVisible = 18  -- Show max 18 items (increased from 10)
    local totalItems = #filteredLayouts
    local hasScrollbar = totalItems > maxVisible
    local scrollBarW = 8

    -- Clamp scroll offset to a valid range
    local maxScroll = math.max(0, totalItems - maxVisible)
    if listScrollOffset > maxScroll then listScrollOffset = maxScroll end
    if listScrollOffset < 0 then listScrollOffset = 0 end

    -- Calculate item width (account for scrollbar if present)
    local itemW = r.listBox.w - 4  -- Default: full width minus padding
    if hasScrollbar then
      itemW = itemW - scrollBarW - 2  -- Make room for scrollbar
    end

    -- Calculate positions: items start from TOP of list box
    -- Spring uses bottom-up coordinates (Y=0 at bottom), so convert coordinates
    local listBoxTopY = loadY + r.listBox.y  -- Top Y in top-down coordinates
    local listBoxBottomY = listBoxTopY + r.listBox.h
    local itemsToShow = math.min(maxVisible, totalItems - listScrollOffset)

    -- Render items from top to bottom - convert to bottom-up coordinates
    for row = 0, itemsToShow - 1 do
      local itemIndex = listScrollOffset + row + 1
      if itemIndex > totalItems then
        break
      end

      local item = filteredLayouts[itemIndex]
      -- Calculate top-down Y position
      local itemTopY = listBoxTopY + 2 + (row * rowH)
      local itemBottomY = itemTopY + rowH

      -- Check if item would go beyond list box bottom
      if itemTopY + rowH > listBoxBottomY then
        break
      end

      -- Convert to bottom-up coordinates for gl.Rect and gl.Text
      local rectY1 = vsy - itemBottomY  -- Bottom of item in bottom-up coords
      local rectY2 = vsy - itemTopY    -- Top of item in bottom-up coords
      local textY = vsy - (itemTopY + rowH - 4)  -- Text Y in bottom-up coords (centered vertically in row)

      local rowX1 = loadX + r.listBox.x + 2
      local rowX2 = rowX1 + itemW
      local sel = (selectedIndex == itemIndex)
      if sel then
        if glass.ready then
          glass.rectRound(rowX1, rectY1, rowX2, rectY2, glass.elementCorner * 0.5, 1, 1, 1, 1, GLASS.selectedFill)
        else
          gl.Color(0.3,0.5,0.8,0.6)
          gl.Rect(rowX1, rectY1, rowX2, rectY2)
        end
      elseif glass.ready and InRect(mx, my, rowX1, rectY1, rowX2, rectY2) then
        glass.highlight(rowX1, rectY1, rowX2, rectY2, glass.elementCorner * 0.5, GLASS.hoverOpacity, GLASS.white)
      end
      gl.Color(1,1,1,1)
      gl.Text(item.name or "?", loadX + r.listBox.x + 6, textY, 11, "")
    end

    -- Draw scrollbar if needed (when more than maxVisible items)
    if hasScrollbar then
      local scrollBarX = loadX + r.listBox.x + r.listBox.w - scrollBarW - 2
      local scrollBarTopY = loadY + r.listBox.y + 2  -- Top in top-down coords
      local scrollBarBottomY = scrollBarTopY + (r.listBox.h - 4)  -- Bottom in top-down coords
      local scrollBarH = r.listBox.h - 4

      -- Convert to bottom-up coordinates
      local scrollBarY1 = vsy - scrollBarBottomY  -- Bottom in bottom-up
      local scrollBarY2 = vsy - scrollBarTopY     -- Top in bottom-up

      -- Scrollbar track (darker background)
      if glass.ready then
        glass.rectRound(scrollBarX, scrollBarY1, scrollBarX + scrollBarW, scrollBarY2,
          glass.elementCorner * 0.5, 1, 1, 1, 1, GLASS.barTrack)
      else
        gl.Color(0.15,0.15,0.15,0.95)
        gl.Rect(scrollBarX, scrollBarY1, scrollBarX + scrollBarW, scrollBarY2)
      end

      -- Scrollbar thumb (brighter, more visible)
      local thumbY1, thumbY2
      if maxScroll > 0 then
        local thumbH = math.max(20, (maxVisible / totalItems) * scrollBarH)
        local thumbTopY = scrollBarTopY + (listScrollOffset / maxScroll) * (scrollBarH - thumbH)
        thumbY1 = vsy - (thumbTopY + thumbH)
        thumbY2 = vsy - thumbTopY
      else
        -- Full scrollbar when at top
        thumbY1, thumbY2 = scrollBarY1, scrollBarY2
      end
      if glass.ready then
        glass.rectRound(scrollBarX + 1, thumbY1, scrollBarX + scrollBarW - 1, thumbY2,
          glass.elementCorner * 0.4, 1, 1, 1, 1, GLASS.barThumb)
      else
        gl.Color(0.6,0.6,0.6,0.95)
        gl.Rect(scrollBarX + 1, thumbY1, scrollBarX + scrollBarW - 1, thumbY2)
      end
    end

    -- buttons (Load/Delete/Duplicate/Close)
    -- Convert to bottom-up coordinates (vsy already retrieved above)
    local function drawBtn(b, label, fill)
      -- Convert button Y coordinates to bottom-up
      local btnTopY = loadY + b.y
      local btnBottomY = btnTopY + b.h
      local rectY1 = vsy - btnBottomY
      local rectY2 = vsy - btnTopY
      local l, rr = loadX + b.x, loadX + b.x + b.w
      GlassButton(l, rectY1, rr, rectY2, fill, InRect(mx, my, l, rectY1, rr, rectY2))
      gl.Color(1,1,1,1)
      local tw = gl.GetTextWidth(label) * 11
      local tx = l + (b.w - tw)/2
      local ty = vsy - (btnTopY + b.h - 8)  -- Convert text Y to bottom-up (moved higher in button)
      gl.Text(label, tx, ty, 11, "")
    end
    drawBtn(r.btnLoad,  "Load",   GLASS.loadFill)
    drawBtn(r.btnDel,   "Delete", GLASS.dangerFill)
    drawBtn(r.btnDup,   "Copy",   GLASS.buttonFill)
    drawBtn(r.btnClose, "Close",  GLASS.buttonFill)

    -- thumbnail (convert to bottom-up coordinates)
    if selectedData then
      -- DrawThumbnailSelected uses gl.Rect which expects bottom-up coordinates
      -- thumbBox.y is top in top-down, convert to bottom in bottom-up
      local thumbTopY = loadY + r.thumbBox.y  -- Top in top-down
      local thumbBottomY_bu = vsy - (thumbTopY + 280)  -- Bottom in bottom-up (size=280)
      DrawThumbnailSelected(loadX + r.thumbBox.x, thumbBottomY_bu, 280)
    else
      local thumbY1 = vsy - (loadY + r.thumbBox.y + r.thumbBox.h)
      local thumbY2 = vsy - (loadY + r.thumbBox.y)
      GlassInset(loadX + r.thumbBox.x, thumbY1, loadX + r.thumbBox.x + r.thumbBox.w, thumbY2, 0.5)
      gl.Color(0.8,0.8,0.8,1)
      local thumbTextY = vsy - (loadY + r.thumbBox.y + 140)
      gl.Text("No layout selected", loadX + r.thumbBox.x + 90, thumbTextY, 12, "")
    end
  else
    SetGlassBlur("layoutplannerplus_load", nil)
  end

  -- save dialog
  DrawSaveDialog()
end

--------------------------------------------------------------------------------
-- DrawWorld: preview, placed layout, and rendered lines
--------------------------------------------------------------------------------

function widget:DrawWorld()
  gl.DepthTest(true)

  ----------------------------------------------------------------------
  -- 1. Current layout being edited (green)
  ----------------------------------------------------------------------
  gl.Color(0, 1, 0, 0.7)
  gl.LineWidth(2)
  gl.BeginEnd(GL.LINES, function()
    for _, ln in ipairs(currentLayout.lines) do
      local x1, z1 = BUToWorld(ln[1], ln[2])
      local x2, z2 = BUToWorld(ln[3], ln[4])
      local y1 = Spring.GetGroundHeight(x1, z1) + 4
      local y2 = Spring.GetGroundHeight(x2, z2) + 4
      gl.Vertex(x1, y1, z1)
      gl.Vertex(x2, y2, z2)
    end
  end)

  ----------------------------------------------------------------------
  -- 3. Live preview line while drawing (yellow)
  ----------------------------------------------------------------------
  if drawingMode and lineStart then
    local mx, my = Spring.GetMouseState()
    local _, pos = Spring.TraceScreenRay(mx, my, true)
    if pos then
      local bx, bz = WorldToBU(pos[1], pos[3])
      local sx1, sz1 = SnapBU(lineStart.bx, lineStart.bz, lineSnapMode)
      local sx2, sz2 = SnapBU(bx, bz, lineSnapMode)
      local x1, z1 = BUToWorld(sx1, sz1)
      local x2, z2 = BUToWorld(sx2, sz2)
      local y1 = Spring.GetGroundHeight(x1, z1) + 6
      local y2 = Spring.GetGroundHeight(x2, z2) + 6

      gl.Color(1, 1, 0, 0.9)
      gl.LineWidth(2)
      gl.BeginEnd(GL.LINES, function()
        gl.Vertex(x1, y1, z1)
        gl.Vertex(x2, y2, z2)
      end)
    end
  end

  ----------------------------------------------------------------------
  -- 4. Selected layout preview following cursor (orange)
  ----------------------------------------------------------------------
  if selectedData and not loadPopupVisible then
    local mx, my = Spring.GetMouseState()
    local _, pos = Spring.TraceScreenRay(mx, my, true)
    if pos then
      local bx, bz = WorldToBU(pos[1], pos[3])
      local layout = selectedData

      local cx, cz
      if layout.fileWidth and layout.fileHeight then
        local minSize = layout.fileMinSize or 1
        cx = math.floor((layout.fileWidth + minSize) / 2)
        cz = math.floor((layout.fileHeight + minSize) / 2)
      else
        local minX, maxX, minZ, maxZ = ComputeBounds(layout)
        if not minX then return end
        cx = (minX + maxX) / 2
        cz = (minZ + maxZ) / 2
      end

      local shiftX = cx
      local shiftZ = cz

      gl.Color(1, 0.7, 0.2, 0.6)
      gl.LineWidth(2)
      gl.BeginEnd(GL.LINES, function()
        for _, ln in ipairs(layout.lines) do
          local tx1, tz1 = ln[1] + (bx - shiftX), ln[2] + (bz - shiftZ)
          local tx2, tz2 = ln[3] + (bx - shiftX), ln[4] + (bz - shiftZ)

          local rx1, rz1 = TransformBU(tx1 - bx, tz1 - bz, layoutRotation, layoutInverted)
          local rx2, rz2 = TransformBU(tx2 - bx, tz2 - bz, layoutRotation, layoutInverted)

          local wx1, wz1 = BUToWorld(rx1 + bx, rz1 + bz)
          local wx2, wz2 = BUToWorld(rx2 + bx, rz2 + bz)

          local y1 = Spring.GetGroundHeight(wx1, wz1) + 8
          local y2 = Spring.GetGroundHeight(wx2, wz2) + 8

          gl.Vertex(wx1, y1, wz1)
          gl.Vertex(wx2, y2, wz2)
        end
      end)
    end
  end

  gl.LineWidth(1)
  gl.DepthTest(false)
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

function widget:Initialize()
  Spring.Echo("[LayoutPlus] ===== INITIALIZING LayoutPlannerPlus =====")
  RefreshGlass()
  EnsureLayoutDir()
  RefreshSavedLayouts()
  ApplySearchFilter()
  -- Position main window centered on screen
  local vsx, vsy = gl.GetViewSizes()
  local h        = MainWindowHeight()
  mainX, mainY = MidScreen(vsx, vsy, MAIN_WIDTH, h)
  -- Start load popup over the main window
  loadX, loadY = mainX, mainY
  Spring.Echo("[LayoutPlus] LayoutPlannerPlus initialized, found " .. tostring(#savedLayouts) .. " layouts")
  Spring.Echo("[LayoutPlus] To save with name: /luaui layoutplus_save <name>")
  Spring.Echo("[LayoutPlus] ===== INITIALIZATION COMPLETE =====")
end

-- Keep the main window centered when the screen size changes
function widget:ViewResize()
  local vsx, vsy = gl.GetViewSizes()
  local h        = MainWindowHeight()
  mainX, mainY = MidScreen(vsx, vsy, MAIN_WIDTH, h)
  loadX, loadY = mainX, mainY
  -- Corner radius and padding are derived from the viewport, so the glass
  -- metrics and the blur shapes are rebuilt for the new size.
  RefreshGlass()
  RemoveAllGlassBlur()
end

function widget:Shutdown()
  RemoveAllGlassBlur()
end

--------------------------------------------------------------------------------
-- Console command helper to save with a name
--------------------------------------------------------------------------------

function widget:TextCommand(cmd)
  local name = cmd:match("^layoutplus_save%s+(.+)$")
  if name then
    SaveLayoutAs(name, {})
    RefreshSavedLayouts()
    ApplySearchFilter()
    return true
  end
end

--------------------------------------------------------------------------------
-- Update: gradual rendering queue processing
--------------------------------------------------------------------------------
function widget:Update(dt)
  UpdateKeyTranslation(dt)

  if not renderingToGame then return end

  -- Draw slowly: Spring drops marker lines if they are added too quickly
  -- (draw spam protection). 10 lines per 0.1s is the proven safe rate
  -- (see map_nuttyb_raptor_grid_draw.lua).
  renderTimer = renderTimer + dt
  if renderTimer < 0.1 then return end
  renderTimer = 0

  for i = 1, 10 do
    if #drawLineQueue == 0 then break end

    local data = table.remove(drawLineQueue, 1)
    Spring.MarkerAddLine(
      data.startX, data.y, data.startZ,
      data.endX,   data.y, data.endZ
    )
  end

  if #drawLineQueue == 0 then
    renderingToGame = false
    Spring.Echo("[LayoutPlus] All lines rendered")
  end
end


