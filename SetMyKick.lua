local ADDON = ...

--------------------------------------------------------------------------------
-- Set My Focus Kick
-- Pick your interrupt (kick) raid marker, announce it to the group, and keep
-- your interrupt macro's marker number in sync with your pick. The popup
-- auto-shows on ready check and / or Mythic+ start.
--
-- Marking note: SetRaidTarget is a PROTECTED function (addons may not call it).
-- The game already ships a secure /tm command (Blizzard's TARGET_MARKER slash)
-- that does the marking. This addon never calls SetRaidTarget and never registers
-- /tm; it only rewrites the marker NUMBER inside your macro so the built-in /tm
-- marks with whatever you picked.
--
-- Announce note: a message sent from a button click is always allowed. Automated
-- announce on the trigger works outside instanced content; inside an instance it
-- can be blocked, in which case the button still works.
--------------------------------------------------------------------------------

-- {interrupt} = your spec's interrupt, {kick} = your marker. The ~ before {kick}
-- marks only if the target has no marker yet, so re-pressing never removes/overwrites
-- a mark. The default Focus+Kick casts before setting focus, so the first press sets
-- focus and the next press kicks it (no modifier, no mouseover).
local DEFAULT_MACRO =
	"#showtooltip {interrupt}\n" ..
	"/cast [@focus,harm,nodead] {interrupt}\n" ..
	"/focus [@focus,noexists] target\n" ..
	"/tm [@target,noexists][@target,dead] ~{kick}; ~{kick}"

-- Set focus + mark; no #showtooltip so it keeps the targeting icon.
local SET_FOCUS_MACRO =
	"/focus target\n" ..
	"/tm [@target,noexists][@target,dead] ~{kick}; ~{kick}"

-- Auto tab kick (default): tab to the nearest enemy, interrupt, return to your target.
local AUTOTAB_MACRO =
	"#showtooltip {interrupt}\n" ..
	"/cleartarget\n" ..
	"/targetenemy\n" ..
	"/cast {interrupt}\n" ..
	"/targetlasttarget"

-- Auto tab kick (focus first): kick your focus if you have one, else tab-interrupt
-- a casting mob without losing your current target.
local AUTOTAB_FOCUS_MACRO =
	"#showtooltip {interrupt}\n" ..
	"/cast [@focus,exists,nodead,harm] {interrupt}\n" ..
	"/stopmacro [@focus,exists,nodead,harm]\n" ..
	"/focus target\n" ..
	"/cleartarget\n" ..
	"/targetenemy\n" ..
	"/cast {interrupt}\n" ..
	"/target focus\n" ..
	"/clearfocus\n" ..
	"/startattack"

-- Auto tab kick (mouseover override): kick your mouseover or focus if valid, else
-- tab-interrupt without losing your current target.
local AUTOTAB_MOUSEOVER_MACRO =
	"#showtooltip\n" ..
	"/cast [@mouseover,harm,nodead][@focus,harm,nodead,exists] {interrupt}\n" ..
	"/stopmacro [@mouseover,harm,nodead][@focus,harm,nodead,exists]\n" ..
	"/focus target\n" ..
	"/cleartarget\n" ..
	"/targetenemy\n" ..
	"/cast {interrupt}\n" ..
	"/target focus\n" ..
	"/clearfocus"

-- Templates per macro slot: the editor shows the set for whichever macro is selected.
local TEMPLATES = {
	kick = {
		{ name = "Focus + Kick (default, re-press to kick)", body = DEFAULT_MACRO },
		{ name = "Focus + Kick (Ctrl to kick your target)",
		  body = "#showtooltip {interrupt}\n/cast [nomod:ctrl,@focus,harm,nodead][] {interrupt}\n/focus [@focus,noexists] target\n/tm [@target,noexists][@target,dead] ~{kick}; ~{kick}" },
		{ name = "Focus + Kick (mouseover)",
		  body = "#showtooltip {interrupt}\n/cast [@focus,harm,nodead] {interrupt}\n/focus [@mouseover,harm,nodead,exists] mouseover\n/tm [@mouseover,exists][] ~{kick}" },
	},
	focus = {
		{ name = "Set focus (target)", body = SET_FOCUS_MACRO },
		{ name = "Set focus (mouseover)",
		  body = "/focus [@mouseover,exists] mouseover\n/tm [@mouseover,exists][] ~{kick}" },
	},
	autotab = {
		{ name = "Auto Tab Kick (tab to nearest)", body = AUTOTAB_MACRO },
		{ name = "Auto Tab Kick (focus first, else tab)", body = AUTOTAB_FOCUS_MACRO },
		{ name = "Auto Tab Kick (mouseover or focus, else tab)", body = AUTOTAB_MOUSEOVER_MACRO },
	},
}

-- The three macro slots the editor can edit (Focus+Kick, Set Focus, Auto Tab Kick).
local SLOT_CFG = {
	kick    = { label = "Focus + Kick",  nameKey = "macroName",    tmplKey = "macroTemplate",    defName = "FocusKick",   defBody = DEFAULT_MACRO },
	focus   = { label = "Set Focus",     nameKey = "setFocusName", tmplKey = "setFocusTemplate", defName = "SetFocus",    defBody = SET_FOCUS_MACRO },
	autotab = { label = "Auto Tab Kick", nameKey = "autoTabName",  tmplKey = "autoTabTemplate",  defName = "AutoTabKick", defBody = AUTOTAB_MACRO },
}
local SLOT_ORDER = { "kick", "focus", "autotab" }

local DEFAULTS = {
	marker               = 8,            -- 1..8 raid target index, 0 = no marker (skull default)
	showOnReadyCheck     = true,         -- show on ready check while in a Mythic+ dungeon
	autoAnnounce         = false,        -- announce automatically when the popup opens (off: click to announce)
	message              = "Kicking %MARKER%",
	point                = { "CENTER", "CENTER", 0, 140 },

	macroEnabled         = false,        -- opt-in: do not touch macros until the user enables it
	macroName            = "FocusKick",  -- set-focus-and-kick macro
	macroTemplate        = DEFAULT_MACRO,
	setFocusName         = "SetFocus",   -- set-focus-and-mark macro
	setFocusTemplate     = SET_FOCUS_MACRO,
	autoTabName          = "AutoTabKick",-- auto tab-interrupt macro
	autoTabTemplate      = AUTOTAB_MACRO,
	macroPoint           = { "CENTER", "CENTER", 0, 0 },

	minimap              = { angle = 214, hide = false },
}

local MARKER_NAMES = {
	[0] = "No Marker",
	"Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull",
}

local PREFIX = "|cff33ff99Set My Focus Kick|r: "
local QUESTION_ICON = "INV_Misc_QuestionMark"
local FOCUS_ICON = 132212  -- set-focus macro icon (fileID)

local DB           -- resolved at ADDON_LOADED
local frame        -- main popup, created lazily
local macroFrame   -- macro editor, created lazily

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Chat substitution token for a raid marker; the chat system renders the icon.
local function ChatToken(index)
	if index and index >= 1 and index <= 8 then
		return "{rt" .. index .. "}"
	end
	return "no marker"
end

-- Set a texture to a single cell of the 4x4 raid-target sprite sheet.
local function SetMarkerTexture(tex, index)
	tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
	local col  = (index - 1) % 4
	local row  = math.floor((index - 1) / 4)
	local left = col * 0.25
	local top  = row * 0.25
	tex:SetTexCoord(left, left + 0.25, top, top + 0.25)
end

-- Where group chat should go right now (nil = not grouped).
local function GroupChannel()
	if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
	if IsInRaid() then return "RAID" end
	if IsInGroup() then return "PARTY" end
	return nil
end

-- True when in a Mythic+ / Mythic 5-player dungeon (covers both pre-key staging
-- and an active key). Difficulty 8 = Mythic Keystone, 23 = Mythic (DifficultyUtil).
local function InMythicDungeon()
	local inInstance, instanceType = IsInInstance()
	if not inInstance or instanceType ~= "party" then return false end
	local difficultyID = select(3, GetInstanceInfo())
	return difficultyID == 8 or difficultyID == 23
end

-- Interrupt ("kick") spell per class, with spec overrides keyed by specialization
-- ID. Verified against warcraft.wiki.gg/wiki/Interrupt. Missing = spec has no kick.
local INTERRUPTS = {
	DEATHKNIGHT = { default = 47528  },                  -- Mind Freeze
	DEMONHUNTER = { default = 183752 },                  -- Disrupt
	DRUID       = { default = 106839, [102] = 78675  },  -- Skull Bash; Balance = Solar Beam
	EVOKER      = { default = 351338 },                  -- Quell
	HUNTER      = { default = 147362, [255] = 187707 },  -- Counter Shot; Survival = Muzzle
	MAGE        = { default = 2139   },                  -- Counterspell
	MONK        = { default = 116705 },                  -- Spear Hand Strike
	PALADIN     = { default = 96231  },                  -- Rebuke (all specs)
	PRIEST      = {                   [258] = 15487 },   -- Shadow = Silence; Disc/Holy none
	ROGUE       = { default = 1766   },                  -- Kick
	SHAMAN      = { default = 57994  },                  -- Wind Shear
	WARLOCK     = { default = 19647  },                  -- Spell Lock (Felhunter pet)
	WARRIOR     = { default = 6552   },                  -- Pummel
}

-- The current character's interrupt spell ID (nil if this spec has none).
local function GetMyInterruptID()
	local _, classToken = UnitClass("player")
	local data = classToken and INTERRUPTS[classToken]
	if not data then return nil end
	local specIndex = GetSpecialization()
	local specID = specIndex and GetSpecializationInfo(specIndex)
	return (specID and data[specID]) or data.default
end

local function GetMyInterruptName()
	local id = GetMyInterruptID()
	return id and C_Spell.GetSpellName(id) or nil
end

-- Post the kick marker to group chat. Safe to call from a button OnClick (always
-- allowed) and from the trigger (allowed outside instanced content).
local function Announce()
	local token   = ChatToken(DB.marker)
	local msg     = (tostring(DB.message or DEFAULTS.message):gsub("%%MARKER%%", token))
	local channel = GroupChannel()
	if channel then
		SendChatMessage(msg, channel)
	else
		print(PREFIX .. msg .. " (not in a group, shown locally)")
	end
end

--------------------------------------------------------------------------------
-- Macro management (text only; the built-in /tm does the marking)
--------------------------------------------------------------------------------

-- Rewrite the managed macro so {kick} matches the chosen marker. Out of combat
-- only (EditMacro / CreateMacro are blocked in combat).
local function UpdateManagedMacro()
	if not (DB and DB.macroEnabled) then return end
	if InCombatLockdown() then return end

	local name = DB.macroName ~= "" and DB.macroName or DEFAULTS.macroName
	local interrupt = GetMyInterruptName() or ""
	local body = tostring(DB.macroTemplate or DEFAULT_MACRO)
	body = body:gsub("{interrupt}", interrupt):gsub("{kick}", tostring(DB.marker))
	if body == "" then return end

	local idx = GetMacroIndexByName(name)
	if idx and idx > 0 then
		EditMacro(idx, name, QUESTION_ICON, body)
	else
		local _, numChar = GetNumMacros()
		if numChar and numChar >= MAX_CHARACTER_MACROS then
			print(PREFIX .. "no free character macro slots for '" .. name .. "'.")
			return
		end
		CreateMacro(name, QUESTION_ICON, body, true) -- per-character
	end
end

-- The fixed "set focus + mark" macro. Synced if it exists; created when create=true.
local function UpdateSetFocusMacro(create)
	if InCombatLockdown() then return end
	local name = DB.setFocusName ~= "" and DB.setFocusName or DEFAULTS.setFocusName
	local interrupt = GetMyInterruptName() or ""
	local body = tostring(DB.setFocusTemplate or SET_FOCUS_MACRO):gsub("{interrupt}", interrupt):gsub("{kick}", tostring(DB.marker))
	local idx = GetMacroIndexByName(name)
	if idx and idx > 0 then
		EditMacro(idx, name, FOCUS_ICON, body)
	elseif create then
		local _, numChar = GetNumMacros()
		if numChar and numChar >= MAX_CHARACTER_MACROS then
			print(PREFIX .. "no free character macro slots for '" .. name .. "'.")
			return
		end
		CreateMacro(name, FOCUS_ICON, body, true)
	end
end

-- The auto-tab-interrupt macro. Synced if it exists; created when create=true.
local function UpdateAutoTabMacro(create)
	if InCombatLockdown() then return end
	local name = DB.autoTabName ~= "" and DB.autoTabName or DEFAULTS.autoTabName
	local interrupt = GetMyInterruptName() or ""
	local body = tostring(DB.autoTabTemplate or AUTOTAB_MACRO):gsub("{interrupt}", interrupt):gsub("{kick}", tostring(DB.marker))
	local idx = GetMacroIndexByName(name)
	if idx and idx > 0 then
		EditMacro(idx, name, QUESTION_ICON, body)
	elseif create then
		local _, numChar = GetNumMacros()
		if numChar and numChar >= MAX_CHARACTER_MACROS then
			print(PREFIX .. "no free character macro slots for '" .. name .. "'.")
			return
		end
		CreateMacro(name, QUESTION_ICON, body, true)
	end
end

-- Keep all managed macros in sync with the chosen marker; only edits ones that exist.
local function SyncMacros()
	UpdateManagedMacro()
	UpdateSetFocusMacro(false)
	UpdateAutoTabMacro(false)
end

--------------------------------------------------------------------------------
-- Main popup UI
--------------------------------------------------------------------------------

local function UpdateSelection()
	if not frame then return end
	for i = 1, 8 do
		frame.markerButtons[i].sel:SetShown(DB.marker == i)
	end
	frame.noneButton.sel:SetShown(DB.marker == 0)
end

local function MakeSelTexture(parent)
	local t = parent:CreateTexture(nil, "OVERLAY")
	t:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	t:SetBlendMode("ADD")
	t:SetPoint("TOPLEFT", -3, 3)
	t:SetPoint("BOTTOMRIGHT", 3, -3)
	t:Hide()
	return t
end

local function MakeCheck(parent, label, x, y, get, set)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", x, y)
	cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
	local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetText(label)
	cb.Refresh = function(self) self:SetChecked(get() and true or false) end
	return cb
end

local function RefreshDragIcons()
	if not frame or not frame.dragIcons then return end
	local id = GetMyInterruptID()
	local spellTex = (id and C_Spell.GetSpellTexture(id)) or 134400
	if frame.dragIcons.kick then
		frame.dragIcons.kick:SetTexture(spellTex)
		frame.dragIcons.kick:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end
	if frame.dragIcons.autotab then
		frame.dragIcons.autotab:SetTexture(spellTex)
		frame.dragIcons.autotab:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end
	if frame.dragIcons.focus then
		if type(FOCUS_ICON) == "number" then
			frame.dragIcons.focus:SetTexture(FOCUS_ICON)
		else
			frame.dragIcons.focus:SetTexture("Interface\\Icons\\" .. FOCUS_ICON)
		end
		frame.dragIcons.focus:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end
end

local function CreateUI()
	if frame then return frame end

	frame = CreateFrame("Frame", "SetMyKickFrame", UIParent, "BackdropTemplate")
	frame:SetSize(300, 452)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = false, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	frame:SetBackdropColor(0.04, 0.04, 0.04, 0.9)

	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local p, _, rp, x, y = self:GetPoint()
		DB.point = { p, rp, x, y }
	end)

	tinsert(UISpecialFrames, "SetMyKickFrame")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -16)
	title:SetText("Set My Focus Kick")

	local instr = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	instr:SetPoint("TOP", title, "BOTTOM", 0, -6)
	instr:SetText("Pick your kick marker")

	-- 8 marker buttons, 4 per row.
	frame.markerButtons = {}
	for i = 1, 8 do
		local btn = CreateFrame("Button", nil, frame)
		btn:SetSize(40, 40)
		local col = (i - 1) % 4
		local row = math.floor((i - 1) / 4)
		btn:SetPoint("TOPLEFT", 55 + col * 50, -58 - row * 50)

		local icon = btn:CreateTexture(nil, "ARTWORK")
		icon:SetAllPoints()
		SetMarkerTexture(icon, i)

		btn.sel = MakeSelTexture(btn)
		btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		btn:SetScript("OnClick", function()
			DB.marker = i
			UpdateSelection()
			RefreshDragIcons()
			SyncMacros()
			Announce()
		end)
		btn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(MARKER_NAMES[i])
			GameTooltip:Show()
		end)
		btn:SetScript("OnLeave", GameTooltip_Hide)

		frame.markerButtons[i] = btn
	end

	-- "No Marker" choice.
	local none = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	none:SetSize(100, 22)
	none:SetPoint("TOP", 0, -162)
	none:SetText("No Marker")
	none.sel = MakeSelTexture(none)
	none:SetScript("OnClick", function()
		DB.marker = 0
		UpdateSelection()
		RefreshDragIcons()
		SyncMacros()
	end)
	frame.noneButton = none

	-- Toggles.
	frame.readyCB = MakeCheck(frame, "Show on ready check (in Mythic+)", 22, -196,
		function() return DB.showOnReadyCheck end,
		function(v) DB.showOnReadyCheck = v end)

	frame.autoCB = MakeCheck(frame, "Auto-announce when opened", 22, -220,
		function() return DB.autoAnnounce end,
		function(v) DB.autoAnnounce = v end)

	-- Editable announce message. %MARKER% is replaced with your marker icon.
	local msgLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	msgLabel:SetPoint("TOPLEFT", 22, -250)
	msgLabel:SetText("Message (%MARKER% = your icon):")

	local msgBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	msgBox:SetSize(246, 20)
	msgBox:SetPoint("TOPLEFT", 28, -268)
	msgBox:SetAutoFocus(false)
	msgBox:SetText(DB.message or DEFAULTS.message)
	msgBox:SetScript("OnEscapePressed", msgBox.ClearFocus)
	msgBox:SetScript("OnEnterPressed", function(self)
		DB.message = self:GetText()
		self:ClearFocus()
	end)
	msgBox:SetScript("OnEditFocusLost", function(self) DB.message = self:GetText() end)
	frame.msgBox = msgBox

	-- Announce: always allowed from a click.
	local announce = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	announce:SetSize(170, 26)
	announce:SetPoint("TOP", 0, -300)
	announce:SetText("Announce to Group")
	announce:SetScript("OnClick", function()
		DB.message = msgBox:GetText()
		Announce()
	end)

	-- Open the macro editor (same width as the announce button).
	local macroBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	macroBtn:SetSize(170, 24)
	macroBtn:SetPoint("TOP", 0, -334)
	macroBtn:SetText("Edit Macro...")
	macroBtn:SetScript("OnClick", function() SetMyKick_ShowMacroEditor() end)

	-- Drag-to-bars: two ready macros new users can drop straight onto their bars.
	local dragHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	dragHeader:SetPoint("TOP", 0, -360)
	dragHeader:SetText("New? Drag a macro to your action bar:")

	frame.dragIcons = {}

	local function PickupSlot(nameKey, defName, updateFn)
		if InCombatLockdown() then return end
		local name = (DB[nameKey] and DB[nameKey] ~= "") and DB[nameKey] or defName
		updateFn(true)
		local idx = GetMacroIndexByName(name)
		if idx and idx > 0 then PickupMacro(idx) end
	end

	local function MakeDragBox(xOff, labelText, desc, key, pickup)
		local box = CreateFrame("Button", nil, frame, "BackdropTemplate")
		box:SetSize(40, 40)
		box:SetPoint("TOP", xOff, -378)
		box:RegisterForDrag("LeftButton")
		box:RegisterForClicks("LeftButtonUp")
		box:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
		box:SetBackdropBorderColor(1, 0.82, 0, 0.9)
		local ic = box:CreateTexture(nil, "ARTWORK")
		ic:SetPoint("TOPLEFT", 2, -2)
		ic:SetPoint("BOTTOMRIGHT", -2, 2)
		box:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		frame.dragIcons[key] = ic
		box:SetScript("OnDragStart", pickup)
		box:SetScript("OnClick", pickup)
		box:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(labelText)
			GameTooltip:AddLine(desc, 1, 1, 1, true)
			GameTooltip:AddLine("Drag onto an action bar, or click then a bar slot.", 0.6, 0.6, 0.6, true)
			GameTooltip:Show()
		end)
		box:SetScript("OnLeave", GameTooltip_Hide)
		local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		lbl:SetPoint("TOP", box, "BOTTOM", 0, -4)
		lbl:SetText(labelText)
		return box
	end

	MakeDragBox(-78, "Focus + Kick", "Interrupts your focus. First press focuses your target, then re-press to kick.", "kick", function()
		DB.macroEnabled = true
		PickupSlot("macroName", DEFAULTS.macroName, UpdateManagedMacro)
	end)
	MakeDragBox(0, "Set Focus", "Sets your current target as your focus and marks it.", "focus", function()
		PickupSlot("setFocusName", DEFAULTS.setFocusName, UpdateSetFocusMacro)
	end)
	MakeDragBox(78, "Tab Kick", "Interrupts the nearest casting enemy, then returns to your target.", "autotab", function()
		PickupSlot("autoTabName", DEFAULTS.autoTabName, UpdateAutoTabMacro)
	end)
	RefreshDragIcons()

	local p = DB.point or DEFAULTS.point
	frame:ClearAllPoints()
	frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])

	frame:Hide()
	return frame
end

local function ShowUI()
	if InCombatLockdown() then
		print(PREFIX .. "in combat, not opening (this is an out-of-combat tool).")
		return
	end
	CreateUI()
	UpdateSelection()
	frame.readyCB:Refresh()
	frame.autoCB:Refresh()
	frame.msgBox:SetText(DB.message or DEFAULTS.message)
	RefreshDragIcons()
	SyncMacros()
	frame:Show()
	frame:Raise()
	if DB.autoAnnounce then Announce() end
end

-- Global opener so ArcUI (or any addon) can open the window.
SetMyKick_Show = ShowUI

--------------------------------------------------------------------------------
-- Macro editor UI
--------------------------------------------------------------------------------

local editorSlot = "kick"  -- which macro the editor edits: "kick" or "focus"

local function MacroNoteText()
	return "{interrupt} fills in your interrupt (now: " ..
		(GetMyInterruptName() or "none for this spec") .. "); {kick} fills in your marker."
end

function SetMyKick_ShowMacroEditor()
	if macroFrame then
		macroFrame.note:SetText(MacroNoteText())
		macroFrame:Show()
		macroFrame:Raise()
		macroFrame.ReloadFields()
		return
	end

	macroFrame = CreateFrame("Frame", "SetMyKickMacroFrame", UIParent, "BackdropTemplate")
	macroFrame:SetSize(420, 380)
	macroFrame:SetFrameStrata("DIALOG")
	macroFrame:SetToplevel(true)
	macroFrame:SetClampedToScreen(true)
	macroFrame:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = false, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	macroFrame:SetBackdropColor(0.04, 0.04, 0.04, 0.9)
	macroFrame:SetMovable(true)
	macroFrame:EnableMouse(true)
	macroFrame:RegisterForDrag("LeftButton")
	macroFrame:SetScript("OnDragStart", macroFrame.StartMoving)
	macroFrame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local pt, _, rp, x, y = self:GetPoint()
		DB.macroPoint = { pt, rp, x, y }
	end)
	tinsert(UISpecialFrames, "SetMyKickMacroFrame")

	local close = CreateFrame("Button", nil, macroFrame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	local title = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -16)
	title:SetText("Edit Macro")

	local nameLabel = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	nameLabel:SetPoint("TOPLEFT", 24, -80)
	nameLabel:SetText("Macro name:")

	local nameBox = CreateFrame("EditBox", nil, macroFrame, "InputBoxTemplate")
	nameBox:SetSize(130, 20)
	nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 10, 0)
	nameBox:SetAutoFocus(false)
	nameBox:SetScript("OnEscapePressed", nameBox.ClearFocus)
	nameBox:SetScript("OnEnterPressed", nameBox.ClearFocus)
	macroFrame.nameBox = nameBox

	local note = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	note:SetPoint("TOPLEFT", 24, -106)
	note:SetPoint("TOPRIGHT", -24, -106)
	note:SetJustifyH("LEFT")
	macroFrame.note = note
	note:SetText(MacroNoteText())

	local bodyLabel = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	bodyLabel:SetPoint("TOPLEFT", 24, -132)
	bodyLabel:SetText("Macro body ({interrupt} and {kick} are filled in for you):")

	local scroll = CreateFrame("ScrollFrame", "SetMyKickMacroScroll", macroFrame, "InputScrollFrameTemplate")
	scroll:SetSize(372, 96)
	scroll:SetPoint("TOPLEFT", 24, -152)
	scroll.EditBox:SetMultiLine(true)
	scroll.EditBox:SetMaxLetters(255)
	scroll.EditBox:SetWidth(360)
	scroll.EditBox:SetFontObject(ChatFontNormal)
	if scroll.CharCount then scroll.CharCount:Hide() end
	macroFrame.scroll = scroll

	-- Frame border around the scroll for clarity.
	local border = CreateFrame("Frame", nil, macroFrame, "BackdropTemplate")
	border:SetPoint("TOPLEFT", scroll, "TOPLEFT", -6, 6)
	border:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 22, -6)
	border:SetBackdrop({
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
	})

	-- Which macro this editor is editing.
	local function CurrentName()
		local cfg = SLOT_CFG[editorSlot]
		local n = DB[cfg.nameKey]
		return (n and n ~= "") and n or cfg.defName
	end
	local function CurrentTemplate()
		local cfg = SLOT_CFG[editorSlot]
		return DB[cfg.tmplKey] or cfg.defBody
	end
	local function ReloadFields()
		nameBox:SetText(CurrentName())
		nameBox:SetCursorPosition(0)
		scroll.EditBox:SetText(CurrentTemplate())
		scroll.EditBox:SetCursorPosition(0)
		scroll:SetVerticalScroll(0)
	end
	local function ApplySlot(name, template)
		local cfg = SLOT_CFG[editorSlot]
		DB[cfg.nameKey] = name
		DB[cfg.tmplKey] = template
		if editorSlot == "kick" then
			DB.macroEnabled = true
			UpdateManagedMacro()
		elseif editorSlot == "focus" then
			UpdateSetFocusMacro(true)
		else
			UpdateAutoTabMacro(true)
		end
	end
	macroFrame.ReloadFields = ReloadFields

	-- Slot selector: pick which macro to edit.
	local editLabel = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	editLabel:SetPoint("TOPLEFT", 24, -50)
	editLabel:SetText("Editing:")

	local slotDrop = CreateFrame("DropdownButton", nil, macroFrame, "WowStyle1DropdownTemplate")
	slotDrop:SetSize(160, 22)
	slotDrop:SetPoint("LEFT", editLabel, "RIGHT", 10, 0)
	local function SlotIsSelected(sk) return editorSlot == sk end
	local function SlotSetSelected(sk) editorSlot = sk; C_Timer.After(0, ReloadFields) end
	slotDrop:SetupMenu(function(dropdown, root)
		for _, key in ipairs(SLOT_ORDER) do
			root:CreateRadio(SLOT_CFG[key].label, SlotIsSelected, SlotSetSelected, key)
		end
	end)

	-- Pick an existing macro to manage; loads its name + body so you can add {kick}.
	local macroDrop = CreateFrame("DropdownButton", nil, macroFrame, "WowStyle1DropdownTemplate")
	macroDrop:SetSize(150, 22)
	macroDrop:SetPoint("LEFT", nameBox, "RIGHT", 12, 0)
	macroDrop:SetDefaultText("Pick existing...")
	macroDrop:SetupMenu(function(dropdown, root)
		root:SetScrollMode(20 * 18)   -- cap at ~18 rows, scroll beyond that
		local function AddMacro(actualIndex)
			local mname, _, mbody = GetMacroInfo(actualIndex)
			if mname and mname ~= "" then
				root:CreateButton(mname, function()
					nameBox:SetText(mname)
					scroll.EditBox:SetText(mbody or "")
				end)
			end
		end
		local numAccount, numChar = GetNumMacros()
		for i = 1, numAccount do AddMacro(i) end
		for i = 1, numChar do AddMacro(MAX_ACCOUNT_MACROS + i) end
	end)

	local info = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	info:SetPoint("TOPLEFT", 24, -256)
	info:SetPoint("TOPRIGHT", -24, -256)
	info:SetJustifyH("LEFT")
	info:SetText("Keep {kick} in the macro (you can move it, just don't delete it). Saving updates the chosen macro; the marker re-syncs when you pick. Drag it to your bars.")

	local saveBtn = CreateFrame("Button", nil, macroFrame, "UIPanelButtonTemplate")
	saveBtn:SetSize(170, 24)
	saveBtn:SetPoint("BOTTOMLEFT", 30, 18)
	saveBtn:SetText("Save & Update Macro")
	saveBtn:SetScript("OnClick", function()
		local nm = (nameBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if nm == "" then nm = CurrentName() end
		ApplySlot(nm, scroll.EditBox:GetText())
		nameBox:SetText(nm)
	end)

	local templateDrop = CreateFrame("DropdownButton", nil, macroFrame, "WowStyle1DropdownTemplate")
	templateDrop:SetSize(190, 24)
	templateDrop:SetPoint("BOTTOMRIGHT", -30, 18)
	templateDrop:SetDefaultText("Choose a template...")
	templateDrop:SetupMenu(function(dropdown, root)
		root:SetScrollMode(20 * 16)
		for _, t in ipairs(TEMPLATES[editorSlot] or {}) do
			local body = t.body
			root:CreateButton(t.name, function()
				scroll.EditBox:SetText(body)
				local nm = (nameBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
				if nm == "" then nm = CurrentName() end
				ApplySlot(nm, body)
				nameBox:SetText(nm)
			end)
		end
	end)

	local p = DB.macroPoint or DEFAULTS.macroPoint
	macroFrame:ClearAllPoints()
	macroFrame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	macroFrame:Show()
	macroFrame:Raise()
	ReloadFields()
end

--------------------------------------------------------------------------------
-- Minimap button + Blizzard options panel
--------------------------------------------------------------------------------

local minimapBtn
local settingsCategory

local function OpenSettings()
	if settingsCategory then
		Settings.OpenToCategory(settingsCategory:GetID())
	end
end

local function UpdateMinimapShown()
	if not minimapBtn then return end
	if DB.minimap.hide then minimapBtn:Hide() else minimapBtn:Show() end
end

local function UpdateMinimapPos()
	if not minimapBtn then return end
	local angle = math.rad(DB.minimap.angle or 214)
	local r = (Minimap:GetWidth() / 2) + 5
	minimapBtn:ClearAllPoints()
	minimapBtn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

local function CreateMinimapButton()
	if minimapBtn then return end
	local b = CreateFrame("Button", "SetMyKickMinimapButton", Minimap)
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")

	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetSize(20, 20)
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	bg:SetPoint("TOPLEFT", 7, -5)

	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetSize(18, 18)
	icon:SetPoint("TOPLEFT", 7, -6)
	SetMarkerTexture(icon, 8) -- skull

	local overlay = b:CreateTexture(nil, "OVERLAY")
	overlay:SetSize(53, 53)
	overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	overlay:SetPoint("TOPLEFT")

	b:SetScript("OnClick", function(_, button)
		if button == "RightButton" then OpenSettings() else ShowUI() end
	end)

	-- Drag around the minimap edge; OnUpdate only runs while dragging.
	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local scale = Minimap:GetEffectiveScale()
			local px, py = GetCursorPosition()
			px, py = px / scale, py / scale
			DB.minimap.angle = math.deg(math.atan2(py - my, px - mx))
			UpdateMinimapPos()
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Set My Focus Kick")
		GameTooltip:AddLine("Left-click: open window", 1, 1, 1)
		GameTooltip:AddLine("Right-click: options", 1, 1, 1)
		GameTooltip:AddLine("Drag: move button", 1, 1, 1)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)

	minimapBtn = b
	UpdateMinimapPos()
	UpdateMinimapShown()
end

local function CreateSettingsPanel()
	if settingsCategory then return end
	local panel = CreateFrame("Frame", "SetMyKickSettingsPanel")
	panel.name = "Set My Focus Kick"

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("Set My Focus Kick")

	local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	desc:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
	desc:SetJustifyH("LEFT")
	desc:SetText("Pick your interrupt raid marker, announce it to the group, and keep your kick macro's marker in sync.")

	local openBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	openBtn:SetSize(220, 26)
	openBtn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
	openBtn:SetText("Open Set My Focus Kick Window")
	openBtn:SetScript("OnClick", function() ShowUI() end)

	local macroBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	macroBtn:SetSize(220, 26)
	macroBtn:SetPoint("TOPLEFT", openBtn, "BOTTOMLEFT", 0, -8)
	macroBtn:SetText("Edit Kick Macro")
	macroBtn:SetScript("OnClick", function() SetMyKick_ShowMacroEditor() end)

	local mmCB = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	mmCB:SetPoint("TOPLEFT", macroBtn, "BOTTOMLEFT", 0, -16)
	mmCB:SetChecked(not DB.minimap.hide)
	mmCB:SetScript("OnClick", function(self)
		DB.minimap.hide = not self:GetChecked()
		UpdateMinimapShown()
	end)
	local mmLabel = mmCB:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	mmLabel:SetPoint("LEFT", mmCB, "RIGHT", 2, 0)
	mmLabel:SetText("Show minimap button")

	local category = Settings.RegisterCanvasLayoutCategory(panel, "Set My Focus Kick")
	Settings.RegisterAddOnCategory(category)
	settingsCategory = category
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("READY_CHECK")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
ev:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then return end
		SetMyKickDB = SetMyKickDB or {}
		DB = SetMyKickDB
		for k, v in pairs(DEFAULTS) do
			if DB[k] == nil then
				DB[k] = (type(v) == "table") and CopyTable(v) or v
			end
		end
		CreateMinimapButton()
		CreateSettingsPanel()
		print(PREFIX .. "loaded. /smk to open.")
	elseif event == "READY_CHECK" then
		if DB and DB.showOnReadyCheck and InMythicDungeon() then ShowUI() end
	elseif event == "PLAYER_REGEN_ENABLED" then
		-- Catch up any macro edits deferred from combat.
		SyncMacros()
	elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
		-- New spec may have a different interrupt; re-sync both macros.
		if arg1 == "player" then
			SyncMacros()
			if macroFrame and macroFrame:IsShown() then macroFrame.note:SetText(MacroNoteText()) end
		end
	end
end)

--------------------------------------------------------------------------------
-- Slash
--------------------------------------------------------------------------------

SLASH_SETMYKICK1 = "/smk"
SLASH_SETMYKICK2 = "/setmykick"
SlashCmdList["SETMYKICK"] = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "hide" then
		if frame then frame:Hide() end
	elseif msg == "macro" then
		SetMyKick_ShowMacroEditor()
	elseif msg == "options" or msg == "config" then
		OpenSettings()
	elseif msg == "minimap" then
		DB.minimap.hide = not DB.minimap.hide
		UpdateMinimapShown()
	elseif msg == "" or msg == "show" then
		ShowUI()
	else
		print(PREFIX .. "commands: /smk (open), /smk macro, /smk options, /smk minimap, /smk hide")
	end
end
