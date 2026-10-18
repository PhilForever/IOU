local support = assert(IOU_TEST_SUPPORT, "Run through tools/test_iou.py.")
local results = {}
local function test(name, run)
    local ok, err = pcall(run)
    if not ok then error(name .. ": " .. tostring(err), 0) end
    results[#results + 1] = name
end
local function equal(a,b) assert(a == b, "expected " .. tostring(b) .. ", got " .. tostring(a)) end
local cloth = "|cffffffff|Hitem:2589:0:0:0:0:0:0:0|h[Linen Cloth]|h|r"
local wool = "|cffffffff|Hitem:2592:0:0:0:0:0:0:0|h[Wool Cloth]|h|r"
local variant = "|cffffffff|Hitem:2589:0:0:0:0:0:1:0|h[Linen Cloth]|h|r"
local nativeCloth = "|cnIQ1:|Hitem:2589::::::::13:257:::::::::|h[Linen Cloth]|h|r"
local nativeWool = "|cnIQ1:|Hitem:2592::::::::13:257:::::::::|h[Wool Cloth]|h|r"
local function session()
    local state = support.Session({ui=true,target="Birch Vale"})
    local api = state.api
    assert(api.Initialize())
    if not api.Crafting then
        local chunk = assert(loadstring(assert(IOU_SOURCES["crafting.lua"]), "@IOU/crafting.lua"))
        setfenv(chunk,state.env); chunk("IOU",api)
    end
    state.env.C_Item = {GetItemInfo=function(link)
        return "Cloth",link,1,1,1,"Trade Goods","Cloth",20,"",123
    end}
    return state, api, api.Crafting
end
local function bags(state, values)
    state.env.C_Container = {
        GetContainerNumSlots=function(bag) return #(values[bag] or {}) end,
        GetContainerItemInfo=function(bag,slot) return values[bag] and values[bag][slot] end,
    }
end
local function material(link,id,count) return {hyperlink=link,itemID=id,stackCount=count} end

test("bag picker groups identical native materials without merging variants", function()
    local state, _, c = session()
    bags(state,{[0]={material(cloth,2589,12),material(wool,2592,7)},
        [1]={material(cloth,2589,8),material(variant,2589,1)}})
    local rows = c.BagItems(); equal(#rows,3)
    local matched = {}
    for _, row in ipairs(rows) do matched[row.link] = row.quantity end
    equal(matched[cloth],20); equal(matched[wool],7); equal(matched[variant],1)
    rows[1].quantity = 999
    equal(c.BagItems()[1].quantity,20)
end)

test("Forever named item quality links populate bags and preserve exact item identity", function()
    local state, api, c = session()
    bags(state,{[0]={material(nativeCloth,2589,5)},
        [1]={material(nativeCloth,2589,8),material(nativeWool,2592,7)}})
    local rows, err = c.BagItems(); equal(#rows,2); equal(err,nil)
    equal(rows[1].link,nativeCloth); equal(rows[1].label,nativeCloth)
    equal(rows[1].name,"[Linen Cloth]"); equal(rows[1].itemID,2589); equal(rows[1].quantity,13)
    equal(rows[2].link,nativeWool); equal(rows[2].quantity,7)
    api.ShowAdd(); state.click(api.UI.add.kindButtons.item); state.click(api.UI.add.fromBags)
    local picker = api.UI.bagPicker
    equal(picker.rows[1].item.link,nativeCloth)
    picker.search:SetText("Linen"); equal(picker.rows[1].item.quantity,13)
    state.click(picker.rows[1]); equal(api.UI.add.label:GetText(),nativeCloth)
    equal(api.UI.add.quantity:GetText(),"13")
end)

test("bag grouping and material bundles ignore display color while retaining item payloads", function()
    local state, _, c = session()
    local literal = nativeCloth:gsub("|cnIQ1:","|cffffffff")
    bags(state,{[0]={material(nativeCloth,2589,5),material(literal,2589,7)}})
    local rows, err = c.BagItems(); equal(#rows,1); equal(err,nil); equal(rows[1].quantity,12)
    local bundle = assert(c.Stage({},nativeCloth,5))
    bundle = assert(c.Stage(bundle,literal,7)); equal(#bundle,1); equal(bundle[1].amount,12)
    equal(bundle[1].label,nativeCloth)
end)

test("bag reads skip malformed inaccessible secret and mismatched native data", function()
    local state, _, c = session()
    local secret = {}
    state.env.issecretvalue=function(value) return value == secret end
    bags(state,{[0]={material(cloth,2592,5), material(cloth,2589,0), material(cloth,2589,0.5),
        material(cloth,2589,secret), secret, material(cloth,2589,5)}})
    local rows = c.BagItems(); equal(#rows,1); equal(rows[1].quantity,5)
    state.env.C_Container.GetContainerItemInfo=function() error("unavailable") end
    local unreadable, readError = c.BagItems()
    equal(#unreadable,0); assert(readError:find("could not be read",1,true))
    state.env.C_Container=nil
    local rows, err = c.BagItems(); equal(#rows,0); assert(err:find("Shift-click",1,true))
end)

test("empty bags remain distinct from failed or unsupported native bag reads", function()
    local state, api, c = session()
    bags(state,{[0]={}})
    local rows, err = c.BagItems(); equal(#rows,0); equal(err,nil)
    state.env.C_Container.GetContainerNumSlots=function() error("unavailable") end
    rows, err = c.BagItems(); equal(#rows,0); assert(err:find("could not be read",1,true))
    bags(state,{[0]={material("not a native link",2589,5)}})
    api.ShowAdd(); state.click(api.UI.add.kindButtons.item); state.click(api.UI.add.fromBags)
    assert(api.UI.bagPicker.empty:GetText():find("could not be read",1,true))
end)

test("stack entry reads native capacity rather than bag count and keeps integer units", function()
    local state, _, c = session()
    equal(c.StackSize(cloth),20); equal(c.Quantity(cloth,3,true),60)
    equal(c.Quantity(cloth,3,false),3)
    for _, count in ipairs({0,-1,0.5,0/0,math.huge,"3",false}) do assert(not c.Quantity(cloth,count,true)) end
    assert(not c.Quantity(cloth,999999999,true))
    state.env.C_Item.GetItemInfo=function() return "Cloth",cloth,1,1,1,"Trade","Cloth",nil,"20" end
    assert(not c.StackSize(cloth)); equal(c.Quantity(cloth,2,false),2)
end)

test("stack cache failure and secret capacity fall back to units without guessing", function()
    local state, _, c = session()
    local secret = {}
    state.env.issecretvalue=function(value) return value == secret end
    state.env.C_Item.GetItemInfo=function() return "Cloth",cloth,1,1,1,"Trade","Cloth",secret end
    assert(not c.StackSize(cloth))
    state.env.C_Item.GetItemInfo=function() error("uncached") end
    assert(not c.Quantity(cloth,1,true)); equal(c.Quantity(cloth,1,false),1)
end)

test("native item cache stack count is the eighth return for named quality links", function()
    local state, _, c = session()
    local queried
    state.env.C_Item.GetItemInfo=function(link)
        queried=link
        return "Linen Cloth",nativeCloth,1,5,0,"Trade Goods","Cloth",20,"",2589,13,7,0,1,0,nil,true,""
    end
    equal(c.StackSize(nativeCloth),20); equal(queried,nativeCloth)
    equal(c.Quantity(nativeCloth,2,true),40)
    state.env.C_Item.GetItemInfo=function() return "Linen Cloth",nativeCloth,1,5,0,"Trade Goods","Cloth",nil,"",2589 end
    assert(not c.StackSize(nativeCloth)); equal(c.Quantity(nativeCloth,2,false),2)
end)

test("material bundles combine equal identities and preserve caller data", function()
    local _, _, c = session()
    local first = assert(c.Stage({},cloth,12))
    local combined = assert(c.Stage(first,cloth,8))
    equal(first[1].amount,12); equal(combined[1].amount,20)
    combined = assert(c.Stage(combined,variant,1)); equal(#combined,2)
    combined = assert(c.Stage(combined,wool,7)); equal(#combined,3)
    assert(not c.Stage(first,"",1)); assert(not c.Stage(first,"Cloth\000",1))
    assert(not c.Stage(first,cloth,999999999)); equal(first[1].amount,12)
end)

test("material bundle limits leave staged rows unchanged", function()
    local _, _, c = session()
    local bundle = {}
    for index=1,12 do bundle=assert(c.Stage(bundle,"Material "..index,index)) end
    assert(not c.Stage(bundle,"Thirteenth",1)); equal(#bundle,12)
    local merged=assert(c.Stage(bundle,"Material 1",1)); equal(#merged,12); equal(merged[1].amount,2)
    equal(bundle[1].amount,1)
end)

test("bag selection fills exact native link and available quantity without chat insertion", function()
    local state, api = session()
    bags(state,{[0]={material(cloth,2589,12),material(wool,2592,7)}})
    api.ShowAdd(); local form = api.UI.add
    state.click(form.kindButtons.item); state.click(form.fromBags)
    local picker = api.UI.bagPicker
    assert(picker:IsShown() and picker.search:HasFocus())
    picker.search:SetText("Wool"); equal(picker.rows[1].item.link,wool)
    state.click(picker.rows[1]); equal(form.label:GetText(),wool); equal(form.quantity:GetText(),"7")
    assert(not picker:IsShown()); assert(form.quantity:HasFocus()); equal(state.chatCalls,0)
    state.click(form.fromBags); form:Hide(); assert(not picker:IsShown())
end)

test("stack controls show capacity and convert full stacks without rounding partial units", function()
    local state, api = session()
    api.ShowAdd(); local form=api.UI.add
    state.click(form.kindButtons.item); form.label:SetText(cloth)
    state.click(form.unitMode); assert(form.stacks); equal(form.quantity:GetText(),"1")
    assert(form.unitMode:GetText():find("20",1,true))
    form.quantity:SetText("2"); state.click(form.unitMode)
    assert(not form.stacks); equal(tonumber(form.quantity:GetText()),40)
    form.quantity:SetText("7"); state.click(form.unitMode)
    assert(not form.stacks); equal(form.quantity:GetText(),"7"); assert(form.error:GetText() ~= "")
end)

test("item basket preserves peer direction and creates the whole crafting bundle", function()
    local state, api = session()
    api.ShowAdd("Birch Vale"); local form=api.UI.add
    state.click(form.kindButtons.item); state.click(form.dirButtons.owe)
    form.label:SetText(cloth); form.quantity:SetText("20"); state.click(form.addMaterial)
    equal(#form.bundle,1); equal(form.player:GetText(),"Birch Vale"); equal(form.direction,"owe")
    equal(form.label:GetText(),""); assert(form.label:HasFocus())
    form.label:SetText(wool); form.quantity:SetText("7"); state.click(form.create)
    assert(not form:IsShown(),form.error:GetText())
    local entries=api.GetLedger().entries; equal(#entries,2)
    equal(entries[1].label,cloth); equal(entries[1].amount,20); equal(entries[1].direction,"owe")
    equal(entries[2].label,wool); equal(entries[2].amount,7); equal(entries[2].player,"Birch Vale")
    api.ShowAdd(); equal(#form.bundle,0); assert(not form.shareWanted)
end)

test("sharing stays opt in and reuses the ordinary IOU player", function()
    local state, api = session()
    local calls={}
    api.Sharing={Share=function(id) calls[#calls+1]=id; return {id="offer"} end,GetLink=function() end}
    api.ShowAdd("Birch Vale"); local form=api.UI.add
    form.money:Fill(10000); state.click(form.create); equal(#calls,0)
    api.ShowAdd("Birch Vale"); form.money:Fill(20000); state.click(form.shareToggle)
    assert(form.shareWanted); state.click(form.create); equal(#calls,1)
    equal(api.GetLedger().entries[calls[1]].player,"Birch Vale")
    api.ShowAdd("Birch Vale"); assert(not form.shareWanted)
end)

test("ordinary ledger shares the selected row and opens an existing request", function()
    local state, api = session()
    local e=assert(api.Add({player="Birch Vale",direction="owed",kind="money",amount=10000,label="",note=""}))
    local called, opened, selected
    api.Sharing={Share=function(id) called=id; return {} end,GetLink=function() end}
    api.Toggle(); state.click(api.UI.share); equal(called,e.id)
    api.Sharing.GetLink=function(id) if id==e.id then return {offerId="o1",state="agreed"} end end
    api.ShowShared=function(peer,tab) opened={peer,tab} end
    api.SelectSharedOffer=function(id) selected=id end
    api.Refresh(); equal(api.UI.share:GetText(),"Confirmed")
    state.click(api.UI.share); equal(opened[1],"Birch Vale"); equal(opened[2],nil); equal(selected,"o1")
    api.Sharing.GetLink=function() return {offerId="pending-2",state="pending"} end
    api.Refresh(); equal(api.UI.share:GetText(),"View request")
    state.click(api.UI.share); equal(selected,"pending-2")
end)

test("failed optional sharing keeps the newly saved personal IOU", function()
    local state, api = session()
    api.Sharing={Share=function() return nil,"Player is offline." end,GetLink=function() end}
    api.ShowAdd("Birch Vale"); local form=api.UI.add
    form.money:Fill(10000); state.click(form.shareToggle); state.click(form.create)
    equal(#api.GetLedger().entries,1); assert(not form:IsShown())
    assert(state.messages[#state.messages]:find("IOU saved.",1,true))
end)

return results
