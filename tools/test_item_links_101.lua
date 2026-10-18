-- Native named item-quality colours, including the user's full transfer flow.
local support=assert(IOU_TEST_SUPPORT,"Run after test_iou.lua.")
local results={}
local function test(name,run)
    local ok,err=pcall(run);if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(a,b) assert(a==b,"expected "..tostring(b)..", got "..tostring(a)) end
local function link(id,quality) return "|cnIQ"..(quality or 1)..":|Hitem:"..(id or 2589)..":0:0:0:0:0:0:0:13|h[Linen Cloth]|h|r" end
local function session(ui)
    local state=support.Session({ui=ui,name="Amber",fullName="Amber Stone",target="Birch Vale"})
    assert(state.api.Initialize());assert(state.api.SharedService.Initialize());assert(state.api.TradeService.Initialize())
    return state,state.api
end
local function add(api,direction,kind,amount,label)
    return assert(api.Add({player="Birch Vale",direction=direction,kind=kind,amount=amount,label=label or "",note="",due=0}))
end
local function balance(api,id) return api.Ledger.Balance(api.Ledger.Get(api.GetLedger(),id)) end

test("native named item colours retain the same keys as literal colour and uncoloured links",function()
    local _,api=session()
    local raw="item:2589:0:0:0:0:0:0:0:13"
    local expected=assert(api.SharedCodec.CanonicalItem(raw))
    for quality=0,7 do
        local native=link(2589,quality)
        equal(api.SharedCodec.CanonicalItem(native),expected)
        equal(api.TradeMatching.ItemKey(native),expected)
        assert(api.TradeMatching.EquivalentItems(native,"|cffffffff|H"..raw.."|h[Linen Cloth]|h|r"))
    end
end)

test("native named colour wrappers still reject malformed and incomplete item evidence",function()
    local _,api=session()
    for _,value in ipairs({"|cnIQ1:|Hitem:2589|h[Linen Cloth]|h", "|cn:|Hitem:2589|h[Linen Cloth]|h|r",
        "|cnIQ1;|Hitem:2589|h[Linen Cloth]|h|r", "|cnIQ1:|Hitem:2589:x|h[Linen Cloth]|h|r",
        "|cnIQ1:|Hitem:0|h[Linen Cloth]|h|r", link().."trailing", "|cnIQ1:|Hitem:2589|h[Linen\nCloth]|h|r"}) do
        equal(api.SharedCodec.CanonicalItem(value),nil);equal(api.TradeMatching.ItemKey(value),nil)
    end
end)

test("existing personal named-colour labels export unchanged and start matching without migration",function()
    local _,api=session();local native=link();local e=add(api,"owed","item",5,native)
    local exported=assert(api.Export());local imported=assert(api.Codec.Import(exported))
    equal(imported.entries[1].label,native);equal(imported.entries[1].initial.label,native)
    local id=assert(api.TradeService.NewSessionID())
    local receipt=assert(api.TradeService.Record({id=id,peer="Birch Vale",outgoing={money=0,items={}},
        incoming={money=0,items={{itemID=2589,link=native,name="Linen Cloth",quantity=2}}}}))
    equal(balance(api,e.id),3);equal(receipt.incoming.items[1].link,native)
    equal(api.GetLedger().entries[1].label,native)
end)

test("native named-colour item links bind the same exact confirmed request terms",function()
    local _,api=session();local C=api.SharedCodec
    local terms={protocol=3,kind="ITEM_OBLIGATION",proposer="Amber Stone",recipient="Birch Vale",
        debtor="Birch Vale",creditor="Amber Stone",amountCopper=5,dueUTC=0,note="",
        itemKey=assert(C.CanonicalItem(link())),itemName="Linen Cloth"}
    local encoded=assert(C.CanonicalTerms(terms));equal(assert(C.ParseTerms(encoded)).itemKey,terms.itemKey)
    equal(assert(C.CanonicalTerms(assert(C.ParseTerms(encoded)))),encoded)
end)

test("native close ordering records gold Undo cloth partials unrelated items and later gold",function()
    local state,api=session(true);local env=state.env
    local m={shown=false,outgoing=0,incoming=0,player={},target={}}
    env.TradeFrame={IsShown=function() return m.shown end}
    api.PlayerContext.UnitName=function(unit) equal(unit,"NPC");return "Birch Vale" end
    env.GetPlayerTradeMoney=function() return m.outgoing end
    env.GetTargetTradeMoney=function() return m.incoming end
    env.GetTradePlayerItemInfo=function(slot)
        local row=m.player[slot];if row then return row.name,1,row.quantity,1,nil,false,false,row.itemID end
    end
    env.GetTradeTargetItemInfo=function(slot)
        local row=m.target[slot];if row then return row.name,1,row.quantity,1,false,nil,row.itemID end
    end
    env.GetTradePlayerItemLink=function(slot) return m.player[slot] and m.player[slot].link end
    env.GetTradeTargetItemLink=function(slot) return m.target[slot] and m.target[slot].link end
    env.GetGameMessageInfo=function(id) return id==42 and "ERR_TRADE_COMPLETE" or "ERR_OTHER" end
    assert(api.TradeObserver.Initialize())
    local function complete(outgoing,incoming,items)
        m.shown,m.outgoing,m.incoming,m.player,m.target=true,outgoing,incoming,{},items or {}
        state.event("TRADE_SHOW");state.event("TRADE_ACCEPT_UPDATE",1,1)
        -- Native OnHide clears money synchronously before the observer's own
        -- TRADE_CLOSED handler. Success remains a separate typed event.
        m.shown,m.outgoing,m.incoming,m.player,m.target=false,0,0,{},{}
        state.event("PLAYER_TRADE_MONEY");state.event("TRADE_ACCEPT_UPDATE",0,0)
        state.event("TRADE_UPDATE");state.event("TRADE_CLOSED")
        state.event("UI_INFO_MESSAGE",42,"localized complete")
        state.event("UI_INFO_MESSAGE",42,"duplicate complete")
        return assert(api.TradeService.List())[1]
    end
    local gold=add(api,"owe","money",1000)
    local first=complete(500,0);equal(balance(api,gold.id),500)
    assert(api.TradeService.Undo(first.id));equal(balance(api,gold.id),1000)
    local cloth=add(api,"owed","item",5,link())
    local item={itemID=2589,link=link(),name="Linen Cloth",quantity=2}
    complete(0,0,{item});equal(balance(api,cloth.id),3)
    complete(0,0,{item});equal(balance(api,cloth.id),1)
    local random=complete(0,0,{{itemID=2592,link=link(2592),name="Wool Cloth",quantity=1},
        {itemID=4540,link=link(4540),name="Bread",quantity=1}})
    equal(random.status,"unmatched");equal(#random.incoming.items,2)
    local final=complete(1000,0);equal(balance(api,gold.id),0)
    equal(final.outgoing.money,1000);equal(#assert(api.TradeService.List()),5)
    assert(api.TradeService.Validate(state.env.IOUDB.tradesByCharacter[api.Character()]))
end)

return results
