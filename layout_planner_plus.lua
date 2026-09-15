function widget:GetInfo()
  return {
    name    = "LayoutPlannerPlus",
    desc    = "Modern layout editor + library with named saves, thumbnails, and intuitive tools",
    author  = "Noryon, loadwolf3d, timuela",
    date    = "2025-12-02",
    license = "MIT",
    layer   = 0,
    enabled = true
  }
end

--------------------------------------------------------------------------------
-- Constants & basics
--------------------------------------------------------------------------------

local Spring = Spring
local gl     = gl
local GL     = GL
local widgetHandler = widgetHandler

local BU_SIZE     = 16         -- 1 BU = 16 game units
local SQUARE_SIZE = 3 * BU_SIZE
local CHUNK_SIZE  = 4 * SQUARE_SIZE

local LAYOUT_DIR  = "LuaUI/Widgets/layout_planner_plus/"

local Json = Json
if not (Json and Json.encode and Json.decode) then
  local ok, lib = pcall(VFS.Include, "common/luaUtilities/json.lua")
  if ok and type(lib) == "table" and lib.encode and lib.decode then
    Json = lib
  else
    Spring.Echo("[LayoutPlannerPlus] JSON library unavailable: profiles cannot be read or written")
  end
end

local Editbox = VFS.Include("luaui/Include/keybind_editbox.lua")
local Search  = VFS.Include("luaui/Include/search.lua")

--------------------------------------------------------------------------------
-- Layout data
--------------------------------------------------------------------------------

local currentLayout = {
  lines = {}
}

--------------------------------------------------------------------------------
-- State: drawing & UI
--------------------------------------------------------------------------------

local drawingMode      = false
local drawingLinesMode = false

-- Line drawing
local lineStart        = nil    -- for free lines
local removeDragStart  = nil    -- for right-drag removal box

-- Remember drawing state when opening load popup
local wasDrawingBeforeLoad = false

-- Save dialog
local showSaveDialog   = false

-- Line snap modes: 0=none, 1=intersections, 2=midpoints, 3=thirds
local lineSnapMode     = 1      -- default to intersections

-- Rendering queue (for gradual rendering)
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
local listScrollOffset = 0      -- scroll offset for layout list (in items)
local scrollDragging   = false  -- the popup's scrollbar is being dragged

local searchBox, nameBox

-- Layout transformation state (for selected layout preview/placement)
local layoutRotation   = 0      -- rotation angle in degrees (0, 90, 180, 270)
local layoutInverted  = false  -- horizontal inversion (flip x)

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
  glass.element          = f.Draw.Element
  glass.button           = f.Draw.Button
  glass.rectRound        = f.Draw.RectRound
  glass.highlight        = f.Draw.SelectHighlight
  glass.scroller         = f.Draw.Scroller
  glass.scrollerGeometry = f.Draw.ScrollerGeometry
  glass.elementCorner    = f.elementCorner or 4
  glass.elementPadding   = f.elementPadding or 4
  glass.opacity          = f.clampedOpacity or 1
  glass.ready          = (f.Draw.Element and f.Draw.RectRound and f.Draw.Button and f.Draw.SelectHighlight)
    and true or false
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

-- A list row's lit state: the selector's fill for the chosen row, a soft white
-- wash under the cursor otherwise. Both lists light their rows the same way.
local function MarkRow(l, b, r, t, fill)
  if glass.ready then
    if fill then
      glass.rectRound(l, b, r, t, glass.elementCorner * 0.5, 1, 1, 1, 1, fill)
    else
      glass.highlight(l, b, r, t, glass.elementCorner * 0.5, GLASS.hoverOpacity, GLASS.white)
    end
    return
  end

  local c = fill or { 1, 1, 1, 0.13 }
  gl.Color(c[1], c[2], c[3], c[4])
  gl.Rect(l, b, r, t)
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

-- One row height for both lists, and how many rows the popup shows at once.
local ROW_H            = 18
local LIST_MAX_VISIBLE = 18

-- The snap row, and the saved-layout rows the main window offers under it.
local SNAP_Y           = MAIN_TITLE_H + 10 + BTN_H + 8 + BTN_H + 10
local MAIN_LIST_ROWS   = 3
local MAIN_LIST_H      = 6 + MAIN_LIST_ROWS * ROW_H
-- Bottom of the list box, measured up from mainY (drawing is bottom-up).
local MAIN_LIST_Y      = SNAP_Y + 20 + 6

local DIALOG_W, DIALOG_H = 420, 110

-- One place for the window height: the drawing, every hit test and the drag
-- math all read it, so the list can be resized without them drifting apart.
local function MainWindowHeight()
  return MAIN_LIST_Y + MAIN_LIST_H + 5 + MAIN_PADDING * 2
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
local LOAD_LIST_H      = LOAD_HEIGHT - LOAD_TITLE_H - 56

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
  currentLayout.lines = {}
  Spring.Echo("[LayoutPlannerPlus] Cleared current layout")
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
    Spring.Echo("[LayoutPlannerPlus] Translated layout by (" .. tx .. ", " .. tz .. ")")
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
    Spring.Echo("[LayoutPlannerPlus] Nothing to save")
    return
  end
  if not Json then
    Spring.Echo("[LayoutPlannerPlus] Cannot save: no JSON library available")
    return
  end

  name = name or "layout"
  local safeName = name:gsub("[^%w_%-]", "_")
  if safeName == "" then safeName = "layout" end
  local filename = LAYOUT_DIR .. safeName .. ".json"

  -- avoid overwriting by appending a number if exists
  local counter = 1
  local base = safeName
  while true do
    local f = io.open(filename, "r")
    if not f then break end
    f:close()
    safeName = base .. "_" .. counter
    filename = LAYOUT_DIR .. safeName .. ".json"
    counter = counter + 1
  end

  local minX, maxX, minZ, maxZ = ComputeBounds(currentLayout)

  -- Coordinates are stored relative to the layout's own corner, so a layout
  -- does not carry the map position it was drawn at.
  local lines = {}
  for _, ln in ipairs(currentLayout.lines) do
    lines[#lines + 1] = { ln[1] - minX, ln[2] - minZ, ln[3] - minX, ln[4] - minZ }
  end

  local profile = {
    name    = name,
    width   = maxX - minX + 1,
    height  = maxZ - minZ + 1,
    maxX    = maxX,
    maxZ    = maxZ,
    minSize = 1,
    layout  = { lines = lines },
  }
  if tags and #tags > 0 then
    profile.tags = tags
  end

  local ok, text = pcall(Json.encode, profile)
  if not ok then
    Spring.Echo("[LayoutPlannerPlus] Could not encode " .. filename .. ": " .. tostring(text))
    return
  end

  local f = io.open(filename, "w")
  if not f then
    Spring.Echo("[LayoutPlannerPlus] Could not open " .. filename .. " for write")
    return
  end
  f:write(text)
  f:close()

  Spring.Echo("[LayoutPlannerPlus] Saved layout as " .. filename)
end

local function CopyEmptyLayout()
  return { lines = {} }
end

local function LoadLayoutData(raw)
  local layout = CopyEmptyLayout()
  if type(raw) ~= "table" or type(raw.layout) ~= "table" then
    Spring.Echo("[LayoutPlannerPlus] LoadLayoutData: no layout data")
    return layout
  end

  for _, ln in ipairs(raw.layout.lines or {}) do
    if #ln == 4 then
      layout.lines[#layout.lines + 1] = { ln[1], ln[2], ln[3], ln[4] }
    end
  end

  return layout
end

-- Reads a profile written by SaveLayoutAs. Returns nil and a reason on failure.
local function ReadProfile(full)
  if not Json then
    return nil, "no JSON library"
  end

  local f = io.open(full, "r")
  if not f then
    return nil, "could not open for read"
  end
  local text = f:read("*all")
  f:close()

  local ok, raw = pcall(Json.decode, text)
  if not ok or type(raw) ~= "table" then
    return nil, "not valid JSON"
  end

  return raw
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
    local files = VFS.DirList(LAYOUT_DIR, "*.json", VFS.RAW_FIRST)
    for _, full in ipairs(files or {}) do
      local short = full:match("([^/\\]+)$") or full
      local raw, err = ReadProfile(full)
      if raw then
        local name = raw.name
        if type(name) ~= "string" or name == "" then
          name = short:gsub("%.json$", ""):gsub("_", " ")
        end
        local layout = LoadLayoutData(raw)
        -- Store width/height from file for proper centering
        layout.fileWidth = raw.width
        layout.fileHeight = raw.height
        layout.fileMinSize = raw.minSize
        savedLayouts[#savedLayouts+1] = {
          name     = name,
          tags     = raw.tags or {},
          filename = full,
          data     = layout,
        }
      else
        Spring.Echo("[LayoutPlannerPlus] Could not read " .. short .. ": " .. tostring(err))
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

  local query = Search.query(searchBox and searchBox:getText() or "")
  local out = {}
  for _, item in ipairs(savedLayouts) do
    -- Search.matches wants the haystack already normalised; names are plain here,
    -- so a name and its tags can simply be joined.
    local haystack = Search.normalize((item.name or "") .. " " .. table.concat(item.tags or {}, " "))
    if Search.matches(query, haystack) then
      out[#out + 1] = item
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

-- Hands the current layout to the renderer. Buildings used to be expanded into
-- their merged outer contour here; the widget is line-only now.
local function CollectAndDraw()
  local edges = {}
  for _, line in ipairs(currentLayout.lines) do
    edges[#edges + 1] = { x1 = line[1], z1 = line[2], x2 = line[3], z2 = line[4] }
  end
  DrawEdges(edges)
end

--------------------------------------------------------------------------------
-- Mouse handling
--------------------------------------------------------------------------------

-- Where the main window's buttons sit, as offsets from its bottom-left corner.
local function MainButtonOffsets()
  local y = MAIN_TITLE_H + 10
  return {
    draw   = { x = 10,            y = y },
    clear  = { x = 10 + BTN_W+8,  y = y },
    save   = { x = 10 + 2*(BTN_W+8), y = y },
    load   = { x = 10 + 3*(BTN_W+8), y = y },
    render = { x = 10,            y = y + BTN_H + 8 },
  }
end

local SNAP_LABELS = { "Off", "Intersect", "Mid", "Third" }
local SNAP_STEPS  = { "none", "3 BU (48 IGU)", "1.5 BU (24 IGU)", "1 BU (16 IGU)" }

--------------------------------------------------------------------------------
-- UI geometry
--
-- One description of where every control sits, in absolute bottom-up
-- coordinates, rebuilt each frame and read by both the drawing and the hit
-- tests. The two used to compute the same rectangles independently and in
-- different coordinate spaces, which is how a control's hit area drifts away
-- from the control itself.
--------------------------------------------------------------------------------

local ui = {}

local function RectHit(r, x, y)
  return r ~= nil and x >= r[1] and x <= r[3] and y >= r[2] and y <= r[4]
end

-- The grab margin around a window for moving it.
local function NearWindowEdge(win, x, y)
  local m = 5
  return x <= win[1] + m or x >= win[3] - m or y <= win[2] + m or y >= win[4] - m
end

local function BuildMainLayout()
  local top = mainY + MainWindowHeight()
  local L   = { buttons = {}, chips = {}, rows = {} }

  L.win      = { mainX, mainY, mainX + MAIN_WIDTH, top }
  L.titleBar = { mainX, top - MAIN_TITLE_H, mainX + MAIN_WIDTH, top }
  L.exit     = { mainX + MAIN_WIDTH - 24, top - MAIN_TITLE_H + 2,
                 mainX + MAIN_WIDTH - 4,  top - MAIN_TITLE_H + 22 }

  for id, off in pairs(MainButtonOffsets()) do
    local l, b = mainX + off.x, mainY + off.y
    L.buttons[id] = { l, b, l + BTN_W, b + BTN_H }
  end

  L.snapRow = { mainX + 10, mainY + SNAP_Y, mainX + MAIN_WIDTH - 10, mainY + SNAP_Y + 20 }
  for i = 0, 3 do
    local l = mainX + 80 + i * 64
    L.chips[i] = { l, mainY + SNAP_Y + 2, l + 60, mainY + SNAP_Y + 18 }
  end

  L.list = { mainX + 10, mainY + MAIN_LIST_Y,
             mainX + MAIN_WIDTH - 10, mainY + MAIN_LIST_Y + MAIN_LIST_H }
  for i = 1, MAIN_LIST_ROWS do
    local b = L.list[2] + 3 + (i - 1) * ROW_H
    L.rows[i] = { L.list[1], b, L.list[3], b + ROW_H }
  end

  return L
end

-- Offsets inside the popup are written the way its layout reads: from the
-- window's top-left corner, downwards. rel() makes one absolute and bottom-up.
local function BuildPopupLayout(vsy)
  local function rel(x, y, w, h)
    local top = vsy - (loadY + y)
    return { loadX + x, top - h, loadX + x + w, top }
  end

  local L = { rows = {} }
  L.win      = { loadX, vsy - (loadY + LOAD_HEIGHT), loadX + LOAD_WIDTH, vsy - loadY }
  L.titleBar = rel(0, 0, LOAD_WIDTH, LOAD_TITLE_H)
  L.search   = rel(10,  LOAD_TITLE_H + 8,  200, 20)
  L.list     = rel(10,  LOAD_TITLE_H + 36, 200, LOAD_LIST_H)
  L.thumbBox = rel(220, LOAD_TITLE_H + 36, 280, 290)
  L.btnLoad  = rel(220, LOAD_TITLE_H + 6, 60, 24)
  L.btnDel   = rel(285, LOAD_TITLE_H + 6, 60, 24)
  L.btnDup   = rel(350, LOAD_TITLE_H + 6, 60, 24)
  L.btnClose = rel(LOAD_WIDTH - 70, LOAD_TITLE_H + 6, 60, 20)

  local total = #filteredLayouts
  L.maxScroll = math.max(0, total - LIST_MAX_VISIBLE)
  if listScrollOffset > L.maxScroll then listScrollOffset = L.maxScroll end
  if listScrollOffset < 0 then listScrollOffset = 0 end

  -- The scrollbar's strip, and the thumb's rect taken from FlowUI's own
  -- geometry, so where the bar is drawn and where it can be grabbed are the
  -- same rectangle by construction.
  local barX2 = L.list[3] - 2
  L.bar           = { barX2 - 8, L.list[2] + 2, barX2, L.list[4] - 2 }
  L.scrollContent = total * ROW_H
  L.scrollPos     = listScrollOffset * ROW_H
  L.barThumb      = nil
  if glass.ready and glass.scrollerGeometry and L.bar[4] > L.bar[2] then
    local top, thumbH = glass.scrollerGeometry(L.bar[1], L.bar[2], L.bar[3], L.bar[4],
                                               L.scrollContent, L.scrollPos)
    if top then
      L.barThumb = { L.bar[1], top - thumbH, L.bar[3], top }
    end
  end

  local rowRight = L.list[3] - 2 - (L.barThumb and 10 or 0)
  local shown    = math.min(LIST_MAX_VISIBLE, total - listScrollOffset)
  for i = 1, shown do
    local top = L.list[4] - 2 - (i - 1) * ROW_H
    L.rows[i] = { L.list[1] + 2, top - ROW_H, rowRight, top }
  end

  return L
end

local function BuildDialogLayout(vsx, vsy)
  local x, y = (vsx - DIALOG_W) / 2, (vsy - DIALOG_H) / 2
  return {
    win    = { x, y, x + DIALOG_W, y + DIALOG_H },
    field  = { x + 10, y + 48, x + DIALOG_W - 10, y + 68 },
    ok     = { x + 10, y + 14, x + 10 + 80, y + 38 },
    cancel = { x + DIALOG_W - 90, y + 14, x + DIALOG_W - 10, y + 38 },
  }
end

local function RefreshUI()
  local vsx, vsy = gl.GetViewSizes()
  ui.main   = BuildMainLayout()
  ui.popup  = loadPopupVisible and BuildPopupLayout(vsy) or nil
  ui.dialog = showSaveDialog and BuildDialogLayout(vsx, vsy) or nil
end

-- The name field's own drawing is the editbox's; only the panel and the two
-- buttons are ours.
local function DrawSaveDialog()
  if not showSaveDialog then
    SetGlassBlur("layoutplannerplus_save", nil)
    return
  end

  local D = ui.dialog
  SetGlassBlur("layoutplannerplus_save", D.win[1], D.win[2], D.win[3], D.win[4])
  GlassPanel(D.win[1], D.win[2], D.win[3], D.win[4])

  gl.Color(1, 1, 1, 1)
  gl.Text("Save layout as:", D.win[1] + 10, D.win[2] + 78, 14, "")

  local mx, my = Spring.GetMouseState()
  nameBox:setRect(D.field[1], D.field[2], D.field[3], D.field[4], 13)
  nameBox:draw()

  local function button(r, label, fill)
    GlassButton(r[1], r[2], r[3], r[4], fill, RectHit(r, mx, my))
    gl.Color(1, 1, 1, 1)
    local tw = gl.GetTextWidth(label) * 13
    gl.Text(label, r[1] + ((r[3] - r[1]) - tw) / 2, r[2] + 6, 13, "")
  end
  button(D.ok,     "OK",     GLASS.confirmFill)
  button(D.cancel, "Cancel", GLASS.dangerFill)
end

function widget:MousePress(mx, my, button)
  RefreshUI()

  -- The save dialog owns the screen while it is up.
  local D = ui.dialog
  if D then
    if button == 1 then
      if RectHit(D.ok, mx, my) then
        local name = nameBox:getText():gsub("^%s*(.-)%s*$", "%1")
        if name ~= "" then
          SaveLayoutAs(name, {})
          RefreshSavedLayouts()
          ApplySearchFilter()
        end
        showSaveDialog = false
        nameBox:blur()
      elseif RectHit(D.cancel, mx, my) then
        showSaveDialog = false
        nameBox:blur()
      end
    end
    return true
  end

  local P = ui.popup
  if P then
    if button ~= 1 then
      return true
    end

    -- drag by the title band
    if RectHit(P.titleBar, mx, my) then
      loadDragging = true
      loadDragStartMX, loadDragStartMY = mx, my
      loadOrigX, loadOrigY             = loadX, loadY
      return true
    end

    -- the field takes clicks before anything behind it does
    if searchBox:mousePress(mx, my) then
      return true
    end

    if RectHit(P.btnClose, mx, my) then
      -- just close; nothing follows the cursor and no preview is kept
      loadPopupVisible = false
      drawingMode      = wasDrawingBeforeLoad
      selectedIndex    = nil
      selectedData     = nil
      layoutRotation   = 0
      layoutInverted   = false
      searchBox:blur()
      return true
    end

    if RectHit(P.btnLoad, mx, my) then
      -- the highlighted layout is what Load carries over; the popup closes and
      -- the layout follows the cursor
      if selectedIndex and filteredLayouts[selectedIndex] then
        loadPopupVisible = false
      end
      return true
    end

    if RectHit(P.btnDel, mx, my) then
      if selectedIndex and filteredLayouts[selectedIndex] then
        local item = filteredLayouts[selectedIndex]
        if item.filename then
          os.remove(item.filename)
        end
        RefreshSavedLayouts()
        ApplySearchFilter()
        selectedIndex  = nil
        selectedData   = nil
        layoutRotation = 0
        layoutInverted = false
      end
      return true
    end

    if RectHit(P.btnDup, mx, my) then
      if selectedIndex and filteredLayouts[selectedIndex] then
        local item = filteredLayouts[selectedIndex]
        if item and item.filename then
          local f = io.open(item.filename, "r")
          if f then
            local text = f:read("*all")
            f:close()
            local base = item.filename:gsub("%.json$", "")
            local n = 1
            local newName
            while true do
              newName = base .. "_copy" .. n .. ".json"
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

    -- the scrollbar's whole strip takes the drag, so a near miss still grabs it
    if P.barThumb and RectHit(P.bar, mx, my) then
      scrollDragging = true
      return true
    end

    for i, r in ipairs(P.rows) do
      if RectHit(r, mx, my) then
        selectedIndex  = listScrollOffset + i
        local item     = filteredLayouts[selectedIndex]
        selectedData   = item and item.data or nil
        layoutRotation = 0
        layoutInverted = false
        return true
      end
    end

    -- while popup is open, block clicks from reaching world/drawing logic
    return true
  end

  -- main window. A click that lands on the panel belongs to the panel, so it
  -- stops here rather than falling through to the world behind it.
  local M = ui.main
  if button == 1 and RectHit(M.win, mx, my) then
    if RectHit(M.exit, mx, my) then
      -- Disable widget (user can re-enable via F11 menu)
      if not exitButtonClicked then
        exitButtonClicked = true
        Spring.Echo("[LayoutPlannerPlus] Widget disabled. Re-enable via F11 menu.")
        if widgetHandler and widgetHandler.RemoveWidget then
          widgetHandler:RemoveWidget(widget)
        end
      end
      return true
    end

    if RectHit(M.buttons.draw, mx, my) then
      -- While a layout is attached to the mouse, do NOT allow toggling draw mode.
      if selectedData then
        Spring.Echo("[LayoutPlannerPlus] Finish or cancel layout placement before toggling Draw")
        return true
      end
      drawingMode = not drawingMode
      Spring.Echo("[LayoutPlannerPlus] Drawing: " .. (drawingMode and "ON" or "OFF"))
      return true
    end

    if RectHit(M.buttons.clear, mx, my) then
      ClearCurrentLayout()
      return true
    end

    if RectHit(M.buttons.save, mx, my) then
      showSaveDialog = true
      nameBox:setText("")
      nameBox:focus()
      return true
    end

    if RectHit(M.buttons.load, mx, my) then
      if #savedLayouts > 0 then
        -- remember drawing state, and turn drawing off while loading
        wasDrawingBeforeLoad = drawingMode
        drawingMode          = false
        -- open the popup over the main window (same origin)
        loadX, loadY         = mainX, mainY
        loadPopupVisible     = true
        listScrollOffset     = 0
        searchBox:setText("")
        searchBox:blur()
        RefreshSavedLayouts()
        ApplySearchFilter()
      else
        Spring.Echo("[LayoutPlannerPlus] No saved layouts found")
      end
      return true
    end

    if RectHit(M.buttons.render, mx, my) then
      Spring.Echo("[LayoutPlannerPlus] Render button clicked - queuing lines for rendering")
      CollectAndDraw()
      Spring.Echo("[LayoutPlannerPlus] Queued " .. #drawLineQueue .. " lines for gradual rendering")
      renderTimer = 0
      return true
    end

    for i = 0, 3 do
      if RectHit(M.chips[i], mx, my) then
        lineSnapMode = i
        Spring.Echo("[LayoutPlannerPlus] Line snap: " .. SNAP_LABELS[i+1] ..
                    " (mode " .. i .. ", step: " .. SNAP_STEPS[i+1] .. ")")
        return true
      end
    end

    -- saved-layout rows: arm the layout for placement, the same state the load
    -- popup leaves behind. Rendering stays a separate step.
    for i, item in ipairs(mainListLayouts) do
      local r = M.rows[i]
      if r and RectHit(r, mx, my) then
        selectedIndex  = nil
        selectedData   = item.data
        layoutRotation = 0
        layoutInverted = false
        Spring.Echo("[LayoutPlannerPlus] Activated layout: " .. tostring(item.name or "?"))
        return true
      end
    end

    -- the title band and the window's edges move the window
    if RectHit(M.titleBar, mx, my) or NearWindowEdge(M.win, mx, my) then
      mainDragging = true
      mainDragDX, mainDragDY = mx - mainX, my - mainY
    end
    return true
  end

  -- placement of selected layout (when Draw: OFF)
  if not drawingMode and selectedData and button == 1 then
    local _, pos = Spring.TraceScreenRay(mx, my, true)
    if pos then
      local bx, bz = WorldToBU(pos[1], pos[3])
      local layout = selectedData

      -- A profile stores its coordinates normalised to its own corner, so the
      -- width/height it was saved at is what centres it under the cursor. A
      -- profile without those falls back to its computed bounds.
      local cx, cz
      if layout.fileWidth and layout.fileHeight then
        local minSize = layout.fileMinSize or 1
        cx = math.floor((layout.fileWidth + minSize) / 2)
        cz = math.floor((layout.fileHeight + minSize) / 2)
      else
        local minX, maxX, minZ, maxZ = ComputeBounds(layout)
        if not minX then return false end
        cx = (minX + maxX) / 2
        cz = (minZ + maxZ) / 2
      end

      if cx and cz then
        local shiftX, shiftZ = cx, cz

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
        Spring.Echo("[LayoutPlannerPlus] Placed layout at cursor")
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
    local ddx = mx - loadDragStartMX
    local ddy = my - loadDragStartMY
    loadX = loadOrigX + ddx
    loadY = loadOrigY - ddy
    return
  end
  if scrollDragging and ui.popup then
    -- The whole strip scrubs, so the thumb follows the cursor and a drag that
    -- started near an end still reaches it.
    local P    = ui.popup
    local span = math.max(1, P.bar[4] - P.bar[2])
    local f    = (P.bar[4] - my) / span          -- 0 at the bottom, 1 at the top
    listScrollOffset = math.max(0, math.min(P.maxScroll, math.floor(f * P.maxScroll + 0.5)))
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
    if scrollDragging then
      scrollDragging = false
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
        Spring.Echo("[LayoutPlannerPlus] No line near click")
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
      Spring.Echo("[LayoutPlannerPlus] Removed lines in box")
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
  -- While a field has focus it takes the keys; ESC and ENTER are the panel's,
  -- and everything else (backspace, arrows, word motion, selection) is the
  -- editbox's own.
  if showSaveDialog then
    if key == 27 then
      showSaveDialog = false
      nameBox:blur()
    elseif key == 13 then
      local name = nameBox:getText():gsub("^%s*(.-)%s*$", "%1")
      if name ~= "" then
        SaveLayoutAs(name, {})
        RefreshSavedLayouts()
        ApplySearchFilter()
      end
      showSaveDialog = false
      nameBox:blur()
    else
      nameBox:keyPress(key)
    end
    return true
  end

  if loadPopupVisible then
    if key == 27 then -- ESC closes the popup and restores drawing state
      loadPopupVisible = false
      drawingMode = wasDrawingBeforeLoad
      searchBox:blur()
      return true
    end
    searchBox:keyPress(key)
    return true
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
      Spring.Echo("[LayoutPlannerPlus] Drawing: OFF (ESC)")
      return true
    end
  end

  -- Rotation and inversion keys (only when layout is selected)
  if selectedData then
    if key == 114 then -- 'r' key
      layoutRotation = (layoutRotation + 90) % 360
      Spring.Echo("[LayoutPlannerPlus] Rotation: " .. layoutRotation .. "°")
      return true
    elseif key == 105 then -- 'i' key
      layoutInverted = not layoutInverted
      Spring.Echo("[LayoutPlannerPlus] Inverted: " .. (layoutInverted and "Yes" or "No"))
      return true
    end
  end
  if allowTranslationByKeys and not showSaveDialog and not loadPopupVisible and not selectedData then
    if key == 119 or key == 115 or key == 97 or key == 100 then
      return true
    end
  end

  return false
end

-- Typed characters come through here rather than KeyPress: that is what the
-- editbox expects, and it is where the unicode and the selection live.
function widget:TextInput(char)
  if showSaveDialog then
    return nameBox:textInput(char)
  end
  if loadPopupVisible then
    return searchBox:textInput(char)
  end
  return false
end

function widget:MouseWheel(up, value)
  if not loadPopupVisible then
    return false
  end

  local maxScroll = math.max(0, #filteredLayouts - LIST_MAX_VISIBLE)
  if up then
    listScrollOffset = math.min(maxScroll, listScrollOffset + 1)
  else
    listScrollOffset = math.max(0, listScrollOffset - 1)
  end
  return true
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

  RefreshUI()
  local M = ui.main

  SetGlassBlur("layoutplannerplus_main", M.win[1], M.win[2], M.win[3], M.win[4])
  GlassPanel(M.win[1], M.win[2], M.win[3], M.win[4])

  -- title band
  GlassInset(M.titleBar[1] + 1, M.titleBar[2], M.titleBar[3] - 1, M.titleBar[4] - 1, 0.5)
  gl.Color(1, 0.7, 0.2, 1)
  gl.Text("LayoutPlannerPlus", M.titleBar[1] + 8, M.titleBar[2] + 4, 14, "")

  -- Exit button in title bar (top-right)
  GlassButton(M.exit[1], M.exit[2], M.exit[3], M.exit[4], GLASS.dangerFill, RectHit(M.exit, mx, my))
  gl.Color(1, 1, 1, 1)
  gl.Text("×", M.exit[1] + 6, M.exit[2] + 2, 16, "")

  local looks = {
    draw   = { drawingMode and "Draw: ON" or "Draw: OFF",
               drawingMode and GLASS.drawOnFill or GLASS.buttonFill, true },
    clear  = { "Clear",  GLASS.dangerFill,  true },
    save   = { "Save",   GLASS.confirmFill, true },
    load   = { "Load",   #savedLayouts > 0 and GLASS.loadFill or GLASS.buttonFill, #savedLayouts > 0 },
    render = { "Render", GLASS.renderFill,  true },
  }
  for id, r in pairs(M.buttons) do
    local look = looks[id]
    GlassButton(r[1], r[2], r[3], r[4], look[2], look[3] and RectHit(r, mx, my))
    gl.Color(1,1,1,1)
    local tw = gl.GetTextWidth(look[1]) * 12
    gl.Text(look[1], r[1] + ((r[3] - r[1]) - tw)/2, r[2] + 6, 12, "")
  end

  -- Line snap mode selector (only control row below main buttons)
  GlassInset(M.snapRow[1], M.snapRow[2], M.snapRow[3], M.snapRow[4])
  gl.Color(1,1,1,1)
  gl.Text("Line Snap:", M.snapRow[1] + 2, M.snapRow[2] + 4, 10, "")
  for i = 0, 3 do
    local r = M.chips[i]
    local fill = (i == lineSnapMode) and GLASS.accentFill or GLASS.buttonFill
    GlassButton(r[1], r[2], r[3], r[4], fill, RectHit(r, mx, my))
    gl.Color(1,1,1,1)
    gl.Text(SNAP_LABELS[i+1], r[1] + 4, r[2] + 3, 10, "")
  end

  -- Saved layouts, first three by file name. Picking one arms it for placement
  -- exactly as the load popup does; nothing is drawn to the map here, that is
  -- still the Render button.
  GlassInset(M.list[1], M.list[2], M.list[3], M.list[4])

  if #mainListLayouts == 0 then
    gl.Color(0.55,0.55,0.55,1)
    gl.Text("No saved layouts", M.list[1] + 6, M.list[2] + MAIN_LIST_H/2 - 5, 11, "")
  else
    for i, item in ipairs(mainListLayouts) do
      local r = M.rows[i]
      if r then
        if selectedData ~= nil and item.data == selectedData then
          MarkRow(r[1], r[2], r[3], r[4], GLASS.selectedFill)
        elseif RectHit(r, mx, my) then
          MarkRow(r[1], r[2], r[3], r[4])
        end

        gl.Color(1,1,1,1)
        gl.Text(item.name or "?", r[1] + 4, r[2] + 4, 11, "")
      end
    end
  end

  -- Key hints. A layout armed for placement answers to different keys than one
  -- still being drawn, so the line shows whichever set is live right now.
  gl.Color(1,1,1,0.8)
  local hintText
  if selectedData then
    hintText = "LMB place | R rotate | I invert | ESC cancel"
  else
    hintText = "LMB Lines | RMB remove | WASD move | ESC draw off"
  end
  gl.Text(hintText, mainX + 10, mainY + 10, 11, "")

  -- load popup
  local P = ui.popup
  if P then
    SetGlassBlur("layoutplannerplus_load", P.win[1], P.win[2], P.win[3], P.win[4])
    GlassPanel(P.win[1], P.win[2], P.win[3], P.win[4])

    -- Title bar (at TOP of window)
    GlassInset(P.titleBar[1] + 1, P.titleBar[2], P.titleBar[3] - 1, P.titleBar[4] - 1, 0.5)
    gl.Color(1,0.7,0.2,1)
    gl.Text("LayoutPlannerPlus - Load Menu", P.titleBar[1] + 8, P.titleBar[2] + 6, 14, "")

    -- The search field draws itself, background and all.
    searchBox:setRect(P.search[1], P.search[2], P.search[3], P.search[4], 11)
    searchBox:draw()

    GlassInset(P.list[1], P.list[2], P.list[3], P.list[4], 0.5)

    for i, r in ipairs(P.rows) do
      local index = listScrollOffset + i
      local item  = filteredLayouts[index]
      if item then
        if selectedIndex == index then
          MarkRow(r[1], r[2], r[3], r[4], GLASS.selectedFill)
        elseif RectHit(r, mx, my) then
          MarkRow(r[1], r[2], r[3], r[4])
        end

        gl.Color(1,1,1,1)
        gl.Text(item.name or "?", r[1] + 4, r[2] + 4, 11, "")
      end
    end

    -- Scrollbar, drawn and grabbable from the same geometry.
    if P.barThumb and glass.scroller then
      glass.scroller(P.bar[1], P.bar[2], P.bar[3], P.bar[4], P.scrollContent, P.scrollPos,
        RectHit(P.barThumb, mx, my), scrollDragging)
    end

    local function popupButton(r, label, fill)
      GlassButton(r[1], r[2], r[3], r[4], fill, RectHit(r, mx, my))
      gl.Color(1,1,1,1)
      local tw = gl.GetTextWidth(label) * 11
      gl.Text(label, r[1] + ((r[3] - r[1]) - tw)/2, r[2] + 8, 11, "")
    end
    popupButton(P.btnLoad,  "Load",   GLASS.loadFill)
    popupButton(P.btnDel,   "Delete", GLASS.dangerFill)
    popupButton(P.btnDup,   "Copy",   GLASS.buttonFill)
    popupButton(P.btnClose, "Close",  GLASS.buttonFill)

    if selectedData then
      DrawThumbnailSelected(P.thumbBox[1], P.thumbBox[2] + 10, 280)
    else
      GlassInset(P.thumbBox[1], P.thumbBox[2], P.thumbBox[3], P.thumbBox[4], 0.5)
      gl.Color(0.8,0.8,0.8,1)
      gl.Text("No layout selected", P.thumbBox[1] + 90, P.thumbBox[2] + 140, 12, "")
    end
  else
    SetGlassBlur("layoutplannerplus_load", nil)
  end

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

-- The two text fields. Built here rather than at file scope because the editbox
-- draws through the game's font objects, which do not exist until the game does.
local function CreateFields()
  if searchBox then
    return
  end
  searchBox = Editbox.new({
    placeholder = "Search...",
    clearable   = true,
    onChange    = ApplySearchFilter,
  })
  nameBox = Editbox.new({ placeholder = "e.g. corner001 or wall02" })
end

function widget:Initialize()
  Spring.Echo("[LayoutPlannerPlus] ===== INITIALIZING LayoutPlannerPlus =====")
  RefreshGlass()
  CreateFields()
  EnsureLayoutDir()
  RefreshSavedLayouts()
  ApplySearchFilter()
  -- Position main window centered on screen
  local vsx, vsy = gl.GetViewSizes()
  local h        = MainWindowHeight()
  mainX, mainY = MidScreen(vsx, vsy, MAIN_WIDTH, h)
  -- Start load popup over the main window
  loadX, loadY = mainX, mainY
  Spring.Echo("[LayoutPlannerPlus] LayoutPlannerPlus initialized, found " .. tostring(#savedLayouts) .. " layouts")
  Spring.Echo("[LayoutPlannerPlus] To save with name: /luaui layoutplus_save <name>")
  Spring.Echo("[LayoutPlannerPlus] ===== INITIALIZATION COMPLETE =====")
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
    Spring.Echo("[LayoutPlannerPlus] All lines rendered")
  end
end